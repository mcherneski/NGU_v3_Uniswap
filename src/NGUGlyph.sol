// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";

import {LinkedListQueue} from "./libraries/LinkedListQueue.sol";
import {NGUStakedGlyph} from "./NGUStakedGlyph.sol";

/// @title NGUGlyph
/// @notice Implementation of the ERC1155 token standard with a twist.
/// @dev The underlying balance mapping (`tokenId` -> `value`) represents a range, where each value within that range
///  represents a single token.
///
///  If you want to stake a single token, or sub-range of tokens, that are part of an existing range, you must split the
///  range into multiple smaller ranges of sequential token IDs. See {stakeGlyphs}
contract NGUGlyph is ERC1155, AccessControl {
    using LinkedListQueue for LinkedListQueue.Queue;
    using Arrays for uint256[];

    bytes32 public immutable COMPTROLLER_ROLE = keccak256("COMPTROLLER_ROLE");

    NGUStakedGlyph public stGlyph;

    // Counter for generating new token IDs
    uint256 private _nextTokenId = 1;

    mapping(address => LinkedListQueue.Queue) private _ownerQueue;
    mapping(address account => uint256) private _balances;

    enum RangeType {
        EXISTING,
        REQUEUE,
        STAKE
    }

    /// @dev Thrown when the amount to be minted is zero.
    error AmountMustBePositive();

    /// @dev Thrown when a stake request is empty.
    error StakeRequestEmpty();

    /// @dev Thrown when the lengths of two arrays are not equal.
    /// @param arr1 First array.
    /// @param arr2 Second array.
    /// @param len1 Length of the first array.
    /// @param len2 Length of the second array.
    error ArrayLengthMismatch(string arr1, string arr2, uint256 len1, uint256 len2);

    /// @dev Thrown when the specified range `start` is greater than `end`.
    /// @param rangeType The type of range.
    /// @param start Start of the range.
    /// @param end End of the range.
    error InvalidRange(RangeType rangeType, uint256 start, uint256 end);

    /// @dev Thrown when the splits given for requeuing and staking a range did not match exactly.
    /// @param existingQueueRangeStart Start of the existing queue range.
    /// @param existingQueueRangeValue Number of tokens in the existing queue range.
    /// @param totalSplitValueGiven Total number of tokens given from requeue and stake splits.
    error InvalidRangeSplits(
        uint256 existingQueueRangeStart, uint256 existingQueueRangeValue, uint256 totalSplitValueGiven
    );

    /// @dev Thrown when the sub-ranges are not sequential.
    /// @param rangeType The type of range.
    error RangesNotSequential(RangeType rangeType);

    /// @dev Thrown when the range is out of bounds.
    /// @param rangeType The type of range.
    /// @param lower Lower bound of the range.
    /// @param upper Upper bound of the range.
    /// @param start Start of the range.
    /// @param end End of the range.
    error RangeOutOfBounds(RangeType rangeType, uint256 lower, uint256 upper, uint256 start, uint256 end);

    /// @notice Constructor that sets up the default admin role and deploys the staked glyph contract
    constructor() ERC1155("") {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        stGlyph = new NGUStakedGlyph("");
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    /// @notice Get the token ranges in a user's queue
    /// @param user The address of the user
    /// @return tokenStart Array of starting token IDs in the queue
    /// @return tokenEnd Array of ending token IDs in the queue
    function userTokenQueue(address user)
        public
        view
        returns (uint256[] memory tokenStart, uint256[] memory tokenEnd)
    {
        LinkedListQueue.Queue storage queue = _ownerQueue[user];
        tokenStart = new uint256[](queue.length);
        tokenEnd = new uint256[](queue.length);

        uint256 cursor = queue.head;
        for (uint256 i; i < queue.length; i++) {
            tokenStart[i] = cursor;
            tokenEnd[i] = userQueueRangeEnd(user, cursor);
            cursor = queue.at(cursor).next;
        }
    }

    /// @notice Get the end of a token range for a user
    /// @param user The address of the user
    /// @param cursor The starting token ID of the range
    /// @return The ending token ID of the range, or 0 if not found
    function userQueueRangeEnd(address user, uint256 cursor) public view returns (uint256) {
        uint256 balance = balanceOf(user, cursor);
        return balance == 0 ? 0 : cursor + balance - 1;
    }

    /// @notice Creates a new glyph with an auto-incrementing ID
    /// @param to The address that will receive the minted tokens
    /// @param amount Amount of tokens to mint
    /// @param data Additional data with no specified format, sent to the receiver
    /// @return The ID of the newly created glyph
    /// @dev Only callable by addresses with the COMPTROLLER_ROLE
    function createGlyphs(address to, uint256 amount, bytes calldata data)
        external
        onlyRole(COMPTROLLER_ROLE)
        returns (uint256)
    {
        require(amount > 0, AmountMustBePositive());

        LinkedListQueue.Queue storage queue = _ownerQueue[to];
        uint256 tokenId;

        if (canMergeRanges(to, _nextTokenId, queue.tail)) {
            tokenId = queue.tail;
        } else {
            tokenId = _nextTokenId;
            queue.pushBack(tokenId);
            _nextTokenId += amount;
        }

        _mint(to, tokenId, amount, data);

        return tokenId;
    }

    /// @notice Checks if two token IDs can be merged into a single range
    /// @param user The address of the user
    /// @param rangeStart1 The first token ID
    /// @param rangeStart2 The second token ID
    /// @return True if the two token IDs can be merged, else false
    function canMergeRanges(address user, uint256 rangeStart1, uint256 rangeStart2) public view returns (bool) {
        if (rangeStart1 == 0 || rangeStart2 == 0) return false;

        uint256 rangeEnd1 = userQueueRangeEnd(user, rangeStart1);
        uint256 rangeEnd2 = userQueueRangeEnd(user, rangeStart2);

        return (rangeEnd1 != 0 && rangeEnd1 + 1 == rangeStart2) || (rangeEnd2 != 0 && rangeEnd2 + 1 == rangeStart1);
    }

    struct StakeRequest {
        // Queue range glyph IDs to burn and split
        uint256[] queueSplitRanges;
        // Number of glyph ranges in `requeueRanges` to remint from the split index in `queueSplitRanges`
        // Length must match length of `queueSplitRanges`
        uint256[] requeueRangeCount;
        // Starting glyph IDs in new ranges to remint - must be subset of range in `queueSplitRanges`
        uint256[] requeueRangesStart;
        // Ending glyph IDs in new ranges to remint - must be subset of range in `queueSplitRanges`
        uint256[] requeueRangesEnd;
        // Number of glyph ranges in `stakeRanges` to stake from the split index in `queueSplitRanges`
        // Length must match length of `queueSplitRanges`
        uint256[] stakeRangeCount;
        // Starting glyph IDs in ranges to stake - must be subset of range in `queueSplitRanges`
        uint256[] stakeRangesStart;
        // Ending glyph IDs in ranges to stake - must be subset of range in `queueSplitRanges`
        uint256[] stakeRangesEnd;
    }

    struct StakeVars {
        // Balance of existing glyph ranges in user's queue that are to be split
        uint256[] splitRangeValues;
        // Amount in each new glyph range to mint & requeue
        uint256[] requeueValues;
        // Amount in each glyph range to stake
        uint256[] stakeValues;
        uint256[] splitRangesSum;
        uint256[] requeueCursors;
        uint256 iSplit;
    }

    /// @notice Removes multiple token IDs from the user's queue and stakes them
    /// @param stakeRequest Array of requests containing the ranges in user's queue to split and stake
    function stakeGlyphs(StakeRequest memory stakeRequest) external {
        require(stakeRequest.queueSplitRanges.length > 0, StakeRequestEmpty());
        require(
            stakeRequest.queueSplitRanges.length == stakeRequest.requeueRangeCount.length,
            ArrayLengthMismatch(
                "queueSplitRanges",
                "requeueRangeCount",
                stakeRequest.queueSplitRanges.length,
                stakeRequest.requeueRangeCount.length
            )
        );
        require(
            stakeRequest.queueSplitRanges.length == stakeRequest.stakeRangeCount.length,
            ArrayLengthMismatch(
                "queueSplitRanges",
                "stakeRangeCount",
                stakeRequest.queueSplitRanges.length,
                stakeRequest.stakeRangeCount.length
            )
        );
        require(
            stakeRequest.requeueRangesStart.length == stakeRequest.requeueRangesEnd.length,
            ArrayLengthMismatch(
                "requeueRangesStart",
                "requeueRangesEnd",
                stakeRequest.requeueRangesStart.length,
                stakeRequest.requeueRangesEnd.length
            )
        );
        require(
            stakeRequest.stakeRangesStart.length == stakeRequest.stakeRangesEnd.length,
            ArrayLengthMismatch(
                "stakeRangesStart",
                "stakeRangesEnd",
                stakeRequest.stakeRangesStart.length,
                stakeRequest.stakeRangesEnd.length
            )
        );

        address owner = _msgSender();
        LinkedListQueue.Queue storage queue = _ownerQueue[owner];

        StakeVars memory vars;

        // Balance of existing glyph ranges in user's queue that are to be split
        vars.splitRangeValues = new uint256[](stakeRequest.queueSplitRanges.length);
        // Amount in each new glyph range to mint & requeue
        vars.requeueValues = new uint256[](stakeRequest.requeueRangesStart.length);
        // Amount in each glyph range to stake
        vars.stakeValues = new uint256[](stakeRequest.stakeRangesStart.length);

        vars.requeueCursors = new uint256[](stakeRequest.queueSplitRanges.length);

        uint256 totalRequeueSplits;
        uint256 totalStakeSplits;
        while (vars.iSplit < stakeRequest.queueSplitRanges.length) {
            uint256 splitStart = stakeRequest.queueSplitRanges[vars.iSplit];
            require(
                vars.iSplit == 0 || splitStart > stakeRequest.queueSplitRanges[vars.iSplit - 1],
                RangesNotSequential(RangeType.EXISTING)
            );

            vars.requeueCursors[vars.iSplit] = queue.remove(splitStart).next;

            unchecked {
                totalRequeueSplits += stakeRequest.requeueRangeCount[vars.iSplit];
                totalStakeSplits += stakeRequest.stakeRangeCount[vars.iSplit];

                vars.splitRangeValues[vars.iSplit++] = balanceOf(owner, splitStart);
            }
        }

        require(
            totalRequeueSplits == stakeRequest.requeueRangesStart.length,
            ArrayLengthMismatch(
                "totalRequeueSplits",
                "stakeRequest.requeueRangesStart",
                totalRequeueSplits,
                stakeRequest.requeueRangesStart.length
            )
        );
        require(
            totalStakeSplits == stakeRequest.stakeRangesStart.length,
            ArrayLengthMismatch(
                "totalStakeSplits",
                "stakeRequest.stakeRangesStart",
                totalStakeSplits,
                stakeRequest.stakeRangesStart.length
            )
        );

        vars.splitRangesSum = new uint256[](stakeRequest.queueSplitRanges.length);

        vars.iSplit = 0;
        for (uint256 iRequeue; iRequeue < stakeRequest.requeueRangesStart.length;) {
            uint256 requeueCursor = vars.requeueCursors[vars.iSplit];

            uint256 rangeStart = stakeRequest.requeueRangesStart[iRequeue];
            require(
                iRequeue == 0 || rangeStart > stakeRequest.requeueRangesEnd[iRequeue - 1],
                RangesNotSequential(RangeType.REQUEUE)
            );

            uint256 rangeEnd = stakeRequest.requeueRangesEnd[iRequeue];
            require(rangeStart <= rangeEnd, InvalidRange(RangeType.REQUEUE, rangeStart, rangeEnd));
            require(
                rangeStart >= stakeRequest.queueSplitRanges[vars.iSplit]
                    && rangeEnd <= stakeRequest.queueSplitRanges[vars.iSplit] + vars.splitRangeValues[vars.iSplit] - 1,
                RangeOutOfBounds(
                    RangeType.REQUEUE,
                    stakeRequest.queueSplitRanges[vars.iSplit],
                    stakeRequest.queueSplitRanges[vars.iSplit] + vars.splitRangeValues[vars.iSplit] - 1,
                    rangeStart,
                    rangeEnd
                )
            );

            requeueCursor == 0 ? queue.pushBack(rangeStart) : queue.insertBefore(requeueCursor, rangeStart);

            unchecked {
                uint256 value = rangeEnd - rangeStart + 1;
                vars.splitRangesSum[vars.iSplit] -= value;
                vars.requeueValues[iRequeue] = value;

                if (iRequeue++ + 1 % stakeRequest.requeueRangeCount[vars.iSplit] == 0) {
                    vars.iSplit++;
                }
            }
        }

        vars.iSplit = 0;
        for (uint256 iStake; iStake < stakeRequest.stakeRangesStart.length;) {
            uint256 rangeStart = stakeRequest.stakeRangesStart[iStake];
            require(
                iStake == 0 || rangeStart > stakeRequest.stakeRangesEnd[iStake - 1],
                RangesNotSequential(RangeType.STAKE)
            );

            uint256 rangeEnd = stakeRequest.stakeRangesEnd[iStake];
            require(rangeStart <= rangeEnd, InvalidRange(RangeType.STAKE, rangeStart, rangeEnd));
            require(
                rangeStart >= stakeRequest.queueSplitRanges[vars.iSplit]
                    && rangeEnd <= stakeRequest.queueSplitRanges[vars.iSplit] + vars.splitRangeValues[vars.iSplit] - 1,
                RangeOutOfBounds(
                    RangeType.STAKE,
                    stakeRequest.queueSplitRanges[vars.iSplit],
                    stakeRequest.queueSplitRanges[vars.iSplit] + vars.splitRangeValues[vars.iSplit] - 1,
                    rangeStart,
                    rangeEnd
                )
            );

            unchecked {
                uint256 value = rangeEnd - rangeStart + 1;
                vars.splitRangesSum[vars.iSplit] -= value;
                vars.stakeValues[iStake] = value;

                if (iStake++ + 1 % stakeRequest.stakeRangeCount[vars.iSplit] == 0) {
                    vars.iSplit++;
                }
            }
        }

        vars.iSplit = 0;
        while (vars.iSplit < vars.splitRangesSum.length) {
            unchecked {
                uint256 totalSplitValue = uint256(-int256(vars.splitRangesSum[vars.iSplit]));
                require(
                    vars.splitRangeValues[vars.iSplit] == totalSplitValue,
                    InvalidRangeSplits(
                        stakeRequest.queueSplitRanges[vars.iSplit], vars.splitRangeValues[vars.iSplit], totalSplitValue
                    )
                );
                vars.iSplit++;
            }
        }

        _burnBatch(owner, stakeRequest.queueSplitRanges, vars.splitRangeValues);
        _mintBatch(owner, stakeRequest.requeueRangesStart, vars.requeueValues, "");
        stGlyph.mintBatch(owner, stakeRequest.stakeRangesStart, vars.stakeValues, "");
    }

    /// @dev Extend existing transfer logic to keep track of account total balances in accordance to `tokenId` -> `value`, where each value in the range represents a single token.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        virtual
        override
    {
        super._update(from, to, ids, values);

        if (from == address(0)) {
            unchecked {
                uint256 totalMintValue;
                for (uint256 i; i < ids.length; ++i) {
                    uint256 value = values.unsafeMemoryAccess(i);
                    totalMintValue += value;
                }
                _balances[to] += totalMintValue;
            }
        }

        if (to == address(0)) {
            unchecked {
                uint256 totalBurnValue;
                for (uint256 i; i < ids.length; ++i) {
                    uint256 value = values.unsafeMemoryAccess(i);
                    totalBurnValue += value;
                }
                _balances[from] -= totalBurnValue;
            }
        }
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, AccessControl)
        returns (bool)
    {
        return ERC1155.supportsInterface(interfaceId) || AccessControl.supportsInterface(interfaceId);
    }
}
