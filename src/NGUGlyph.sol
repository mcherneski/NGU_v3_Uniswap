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
    using Arrays for uint256[];

    bytes32 public immutable COMPTROLLER_ROLE = keccak256("COMPTROLLER_ROLE");

    NGUStakedGlyph public stGlyph;

    // Counter for generating new token IDs
    uint256 private _nextTokenId = 1;

    mapping(address => LinkedListQueue) private _ownerQueue;
    mapping(address account => uint256) private _balances;

    enum RangeType {
        EXISTING,
        REQUEUE,
        SPLIT
    }

    /// @dev Thrown when the amount to be minted is zero.
    error AmountMustBePositive();

    /// @dev Thrown when a split request is empty.
    error SplitRequestEmpty();

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
    /// @param totalSplitValueGiven Total number of tokens given from requeue and splits.
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
        LinkedListQueue storage queue = _ownerQueue[user];
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

        LinkedListQueue storage queue = _ownerQueue[to];
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

    /// @notice Removes multiple token IDs from the user's queue and splits them
    /// @param request Array of {SplitRequest}s containing the ranges in user's queue to split and stake
    function stakeGlyphs(SplitRequest memory request) external {
        (uint256[] memory queueRangeValues, uint256[] memory requeueValues, uint256[] memory splitValues) =
            _processSplitRequest(request);

        _burnBatch(_msgSender(), request.queueRanges, queueRangeValues);
        _mintBatch(_msgSender(), request.requeueRangesStart, requeueValues, "");
        stGlyph.mintBatch(_msgSender(), request.splitRangesStart, splitValues, "");
    }

    struct SplitRequest {
        // Queue range glyph IDs to split
        uint256[] queueRanges;
        // Number of glyph ranges in `requeueRanges` to remint from the split index in `queueRanges`
        // Length must match length of `queueRanges`
        uint256[] requeueRangeCount;
        // Starting glyph IDs in new ranges to remint - must be subset of range in `queueRanges`
        uint256[] requeueRangesStart;
        // Ending glyph IDs in new ranges to remint - must be subset of range in `queueRanges`
        uint256[] requeueRangesEnd;
        // Number of glyph ranges in `splitRanges` to split from the split index in `queueRanges`
        // Length must match length of `queueRanges`
        uint256[] splitRangeCount;
        // Starting glyph IDs in ranges to split - must be subset of range in `queueRanges`
        uint256[] splitRangesStart;
        // Ending glyph IDs in ranges to split - must be subset of range in `queueRanges`
        uint256[] splitRangesEnd;
    }

    struct SplitVars {
        // Balance of existing glyph ranges in user's queue that are to be split
        uint256[] queueRangeValues;
        // Existing glyph range IDs of where to position new ranges in the queue
        uint256[] requeueCursors;
        // Amount in each new glyph range to mint & requeue
        uint256[] requeueValues;
        // Amount in each glyph range to split
        uint256[] splitValues;
        uint256[] newRangesSum;
        uint256 iQueue;
    }

    /// @notice Removes multiple token IDs from the user's queue and splits them
    /// @param request Array of {SplitRequest}s containing the ranges in user's queue to split and stake
    function _processSplitRequest(SplitRequest memory request)
        internal
        returns (uint256[] memory queueRangeValues, uint256[] memory requeueValues, uint256[] memory splitValues)
    {
        require(request.queueRanges.length > 0, SplitRequestEmpty());
        require(
            request.queueRanges.length == request.requeueRangeCount.length,
            ArrayLengthMismatch(
                "queueRanges", "requeueRangeCount", request.queueRanges.length, request.requeueRangeCount.length
            )
        );
        require(
            request.queueRanges.length == request.splitRangeCount.length,
            ArrayLengthMismatch(
                "queueRanges", "splitRangeCount", request.queueRanges.length, request.splitRangeCount.length
            )
        );
        require(
            request.requeueRangesStart.length == request.requeueRangesEnd.length,
            ArrayLengthMismatch(
                "requeueRangesStart",
                "requeueRangesEnd",
                request.requeueRangesStart.length,
                request.requeueRangesEnd.length
            )
        );
        require(
            request.splitRangesStart.length == request.splitRangesEnd.length,
            ArrayLengthMismatch(
                "splitRangesStart", "splitRangesEnd", request.splitRangesStart.length, request.splitRangesEnd.length
            )
        );

        LinkedListQueue storage queue = _ownerQueue[_msgSender()];

        SplitVars memory vars;

        // Balance of existing glyph ranges in user's queue that are to be split
        vars.queueRangeValues = new uint256[](request.queueRanges.length);
        // Amount in each new glyph range to mint & requeue
        vars.requeueValues = new uint256[](request.requeueRangesStart.length);
        // Amount in each glyph range to split
        vars.splitValues = new uint256[](request.splitRangesStart.length);

        vars.requeueCursors = new uint256[](request.queueRanges.length);

        uint256 totalRequeues;
        uint256 totalSplits;
        while (vars.iQueue < request.queueRanges.length) {
            uint256 splitStart = request.queueRanges[vars.iQueue];
            require(
                vars.iQueue == 0 || splitStart > request.queueRanges[vars.iQueue - 1],
                RangesNotSequential(RangeType.EXISTING)
            );

            vars.requeueCursors[vars.iQueue] = queue.remove(splitStart).next;

            unchecked {
                totalRequeues += request.requeueRangeCount[vars.iQueue];
                totalSplits += request.splitRangeCount[vars.iQueue];

                vars.queueRangeValues[vars.iQueue++] = balanceOf(_msgSender(), splitStart);
            }
        }

        require(
            totalRequeues == request.requeueRangesStart.length,
            ArrayLengthMismatch(
                "totalRequeueSplits",
                "splitRequest.requeueRangesStart",
                totalRequeues,
                request.requeueRangesStart.length
            )
        );
        require(
            totalSplits == request.splitRangesStart.length,
            ArrayLengthMismatch(
                "totalSplits", "splitRequest.splitRangesStart", totalSplits, request.splitRangesStart.length
            )
        );

        vars.newRangesSum = new uint256[](request.queueRanges.length);

        vars.iQueue = 0;
        for (uint256 iRequeue; iRequeue < request.requeueRangesStart.length;) {
            uint256 requeueCursor = vars.requeueCursors[vars.iQueue];

            uint256 rangeStart = request.requeueRangesStart[iRequeue];
            require(
                iRequeue == 0 || rangeStart > request.requeueRangesEnd[iRequeue - 1],
                RangesNotSequential(RangeType.REQUEUE)
            );

            uint256 rangeEnd = request.requeueRangesEnd[iRequeue];
            require(rangeStart <= rangeEnd, InvalidRange(RangeType.REQUEUE, rangeStart, rangeEnd));
            require(
                rangeStart >= request.queueRanges[vars.iQueue]
                    && rangeEnd <= request.queueRanges[vars.iQueue] + vars.queueRangeValues[vars.iQueue] - 1,
                RangeOutOfBounds(
                    RangeType.REQUEUE,
                    request.queueRanges[vars.iQueue],
                    request.queueRanges[vars.iQueue] + vars.queueRangeValues[vars.iQueue] - 1,
                    rangeStart,
                    rangeEnd
                )
            );

            requeueCursor == 0 ? queue.pushBack(rangeStart) : queue.insertBefore(requeueCursor, rangeStart);

            unchecked {
                uint256 value = rangeEnd - rangeStart + 1;
                vars.newRangesSum[vars.iQueue] -= value;
                vars.requeueValues[iRequeue] = value;

                if (iRequeue++ + 1 % request.requeueRangeCount[vars.iQueue] == 0) {
                    vars.iQueue++;
                }
            }
        }

        vars.iQueue = 0;
        for (uint256 iSplit; iSplit < request.splitRangesStart.length;) {
            uint256 rangeStart = request.splitRangesStart[iSplit];
            require(
                iSplit == 0 || rangeStart > request.splitRangesEnd[iSplit - 1], RangesNotSequential(RangeType.SPLIT)
            );

            uint256 rangeEnd = request.splitRangesEnd[iSplit];
            require(rangeStart <= rangeEnd, InvalidRange(RangeType.SPLIT, rangeStart, rangeEnd));
            require(
                rangeStart >= request.queueRanges[vars.iQueue]
                    && rangeEnd <= request.queueRanges[vars.iQueue] + vars.queueRangeValues[vars.iQueue] - 1,
                RangeOutOfBounds(
                    RangeType.SPLIT,
                    request.queueRanges[vars.iQueue],
                    request.queueRanges[vars.iQueue] + vars.queueRangeValues[vars.iQueue] - 1,
                    rangeStart,
                    rangeEnd
                )
            );

            unchecked {
                uint256 value = rangeEnd - rangeStart + 1;
                vars.newRangesSum[vars.iQueue] -= value;
                vars.splitValues[iSplit] = value;

                if (iSplit++ + 1 % request.splitRangeCount[vars.iQueue] == 0) {
                    vars.iQueue++;
                }
            }
        }

        vars.iQueue = 0;
        while (vars.iQueue < vars.newRangesSum.length) {
            unchecked {
                uint256 totalSplitValue = uint256(-int256(vars.newRangesSum[vars.iQueue]));
                require(
                    vars.queueRangeValues[vars.iQueue] == totalSplitValue,
                    InvalidRangeSplits(
                        request.queueRanges[vars.iQueue], vars.queueRangeValues[vars.iQueue], totalSplitValue
                    )
                );
                vars.iQueue++;
            }
        }

        return (vars.queueRangeValues, vars.requeueValues, vars.splitValues);
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
