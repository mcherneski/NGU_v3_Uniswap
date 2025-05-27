// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {LinkedListQueue} from "./libraries/LinkedListQueue.sol";
import {NGUStakedGlyph} from "./NGUStakedGlyph.sol";

/// @title NGUGlyph
/// @notice Implementation of the ERC1155 multi-token standard for the NGU project with role-based access control.
/// @dev This contract allows for multiple glyphs, each with their own supply and metadata.
contract NGUGlyph is ERC1155, AccessControl {
    using LinkedListQueue for LinkedListQueue.Queue;

    bytes32 public constant COMPTROLLER_ROLE = keccak256("COMPTROLLER_ROLE");

    NGUStakedGlyph public stGlyph;

    // Counter for generating new token IDs
    uint128 private _nextTokenId = 1;

    mapping(address => LinkedListQueue.Queue) private _ownerQueue;

    /// @notice Emitted when a new glyph is created
    /// @param id The ID of the created glyph
    /// @param amount The amount of tokens minted
    event GlyphCreated(uint128 id, uint128 amount);

    /// @notice Emitted when glyphs are removed from the user's queue
    /// @param user The address of the user
    /// @param start The starting ID of the removed range
    /// @param end The ending ID of the removed range
    event GlyphsDequeued(address user, uint128 start, uint128 end);

    /**
     * @dev Thrown when a dequeue request is empty.
     */
    error DequeueRequestEmpty();

    /**
     * @dev Thrown when a dequeue request range is empty.
     * @param tokenId Identifier of the token.
     */
    error DequeueRequestRangeEmpty(uint128 tokenId);

    /**
     * @dev Thrown when the user does not have the specified token in their queue.
     * @param user Address of the user.
     * @param tokenId Identifier of the token.
     */
    error InvalidUserQueueToken(address user, uint128 tokenId);

    /**
     * @dev Thrown when the specified range is invalid.
     * @param tokenId Identifier of the token.
     * @param start Start of the range.
     * @param end End of the range.
     */
    error InvalidRange(uint128 tokenId, uint128 start, uint128 end);

    /**
     * @dev Thrown when the sub-range is out of bounds.
     * @param rangeMin Minimum of the range.
     * @param rangeMax Maximum of the range.
     * @param start Start of the sub-range.
     * @param end End of the sub-range.
     */
    error SubRangeOutOfBounds(uint128 rangeMin, uint128 rangeMax, uint128 start, uint128 end);

    /**
     * @dev Thrown when the sub-ranges are not sequential.
     * @param tokenId Identifier of the token.
     * @param minStart Minimum start of the sub-ranges.
     * @param start Start of the sub-range.
     */
    error SubRangesNotSequential(uint128 tokenId, uint128 minStart, uint128 start);

    /// @notice Constructor that sets up the default admin role and deploys the staked glyph contract
    constructor() ERC1155("") {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        stGlyph = new NGUStakedGlyph("");
    }

    /// @notice Get the token ranges in a user's queue
    /// @param user The address of the user
    /// @return tokenStart Array of starting token IDs in the queue
    /// @return tokenEnd Array of ending token IDs in the queue
    function userTokenQueue(address user)
        public
        view
        returns (uint128[] memory tokenStart, uint128[] memory tokenEnd)
    {
        LinkedListQueue.Queue storage queue = _ownerQueue[user];
        tokenStart = new uint128[](queue.length);
        tokenEnd = new uint128[](queue.length);

        uint128 cursor = queue.head;
        for (uint128 i; i < queue.length; i++) {
            tokenStart[i] = cursor;
            tokenEnd[i] = userQueueRangeEnd(user, cursor);
            cursor = queue.at(cursor).next;
        }
    }

    /// @notice Get the end of a token range for a user
    /// @param user The address of the user
    /// @param cursor The starting token ID of the range
    /// @return The ending token ID of the range, or 0 if not found
    function userQueueRangeEnd(address user, uint128 cursor) public view returns (uint128) {
        uint128 balance = uint128(balanceOf(user, cursor));
        return balance == 0 ? 0 : cursor + balance - 1;
    }

    /// @notice Creates a new glyph with an auto-incrementing ID
    /// @param to The address that will receive the minted tokens
    /// @param amount Amount of tokens to mint
    /// @param data Additional data with no specified format, sent to the receiver
    /// @return The ID of the newly created glyph
    /// @dev Only callable by addresses with the COMPTROLLER_ROLE
    function createGlyphs(address to, uint128 amount, bytes memory data)
        external
        onlyRole(COMPTROLLER_ROLE)
        returns (uint128)
    {
        LinkedListQueue.Queue storage queue = _ownerQueue[to];
        uint128 tokenId;

        if (canMergeRanges(to, _nextTokenId, queue.tail)) {
            tokenId = queue.tail;
        } else {
            tokenId = _nextTokenId;
            queue.pushBack(tokenId);
            _nextTokenId += amount;
        }

        _mint(to, tokenId, amount, data);
        emit GlyphCreated(tokenId, amount);

        return tokenId;
    }

    /// @notice Checks if two token IDs can be merged into a single range
    /// @param user The address of the user
    /// @param rangeStart1 The first token ID
    /// @param rangeStart2 The second token ID
    /// @return True if the two token IDs can be merged, else false
    function canMergeRanges(address user, uint128 rangeStart1, uint128 rangeStart2) public view returns (bool) {
        if (rangeStart1 == 0 || rangeStart2 == 0) return false;

        uint128 rangeEnd1 = userQueueRangeEnd(user, rangeStart1);
        uint128 rangeEnd2 = userQueueRangeEnd(user, rangeStart2);

        return (rangeEnd1 != 0 && rangeEnd1 + 1 == rangeStart2) || (rangeEnd2 != 0 && rangeEnd2 + 1 == rangeStart1);
    }

    struct RemoveQueueRequest {
        uint128 id;
        Range[] ranges;
    }

    struct Range {
        uint128 start;
        uint128 end;
    }

    /// @notice Removes multiple token IDs from the user's queue and stakes them
    /// @param dequeueRequests Array of RemoveQueueRequest structs containing the ranges to dequeue and stake
    /// @dev The function will revert if any of the requests are invalid or out of bounds
    function dequeueGlyphsAndStake(RemoveQueueRequest[] memory dequeueRequests) external {
        require(dequeueRequests.length > 0, DequeueRequestEmpty());

        address owner = _msgSender();
        LinkedListQueue.Queue storage queue = _ownerQueue[owner];

        uint256[] memory burnIds = new uint256[](dequeueRequests.length);
        uint256[] memory burnAmounts = new uint256[](dequeueRequests.length);

        uint256 stakedLength;
        uint256 upsertQueueLength;
        for (uint256 i; i < dequeueRequests.length; i++) {
            RemoveQueueRequest memory request = dequeueRequests[i];
            require(request.ranges.length > 0, DequeueRequestRangeEmpty(request.id));

            // Track the glyphs to burn from the queue range
            uint256 oldSize = balanceOf(owner, request.id);
            require(oldSize > 0, InvalidUserQueueToken(owner, request.id));
            burnIds[i] = request.id;
            burnAmounts[i] = oldSize;

            uint128 next = request.id;
            uint128 lastRangeId = request.id + uint128(oldSize) - 1;

            // Track the length of the staked glyphs to mint
            stakedLength += request.ranges.length;
            for (uint256 j; j < request.ranges.length; j++) {
                Range memory range = request.ranges[j];
                require(range.start <= range.end, InvalidRange(request.id, range.start, range.end));
                require(
                    range.start >= request.id && range.end <= lastRangeId,
                    SubRangeOutOfBounds(request.id, lastRangeId, range.start, range.end)
                );
                require(range.start >= next, SubRangesNotSequential(request.id, next, range.start));

                // Track the length of the glyphs to upsert from next section of the range
                if (range.start > next) {
                    upsertQueueLength++;
                }

                next = range.end + 1;
            }
            // Track the length of the glyphs to upsert from last section of the range
            if (request.ranges[request.ranges.length - 1].end < lastRangeId) {
                upsertQueueLength++;
            }
        }

        uint256[] memory upsertQueueTokenIds = new uint256[](upsertQueueLength);
        uint256[] memory upsertQueueAmounts = new uint256[](upsertQueueLength);
        uint256 upsertIndex;

        uint256[] memory stakedTokenIds = new uint256[](stakedLength);
        uint256[] memory stakedAmounts = new uint256[](stakedLength);

        for (uint256 i; i < dequeueRequests.length; i++) {
            RemoveQueueRequest memory request = dequeueRequests[i];

            // Set the previous node as the cursor then remove it from the queue
            uint128 next = request.id;
            uint128 cursor = queue.at(next).prev;
            uint128 lastRangeId = next + uint128(balanceOf(owner, next)) - 1;

            // Remove the range from the queue
            queue.remove(next);

            for (uint256 j; j < request.ranges.length; j++) {
                Range memory range = request.ranges[j];

                // Track the range for the staked glyphs
                stakedTokenIds[i * request.ranges.length + j] = request.ranges[j].start;
                stakedAmounts[i * request.ranges.length + j] = request.ranges[j].end - request.ranges[j].start + 1;

                if (range.start > next) {
                    // Add missing range to queue
                    cursor == 0 ? queue.pushFront(next) : queue.insertAfter(cursor, next);

                    // Track the range of glyphs to mint
                    upsertQueueTokenIds[upsertIndex] = next;
                    upsertQueueAmounts[upsertIndex++] = range.start - next;

                    cursor = next;
                }

                if (j == request.ranges.length - 1 && range.end < lastRangeId) {
                    // Add missing range to queue
                    cursor == 0 ? queue.pushFront(range.end + 1) : queue.insertAfter(cursor, range.end + 1);

                    // Track the range of glyphs to mint
                    upsertQueueTokenIds[upsertIndex] = range.end + 1;
                    upsertQueueAmounts[upsertIndex++] = lastRangeId - range.end;
                }

                next = range.end + 1;

                emit GlyphsDequeued(owner, range.start, range.end);
            }
        }

        // Burn old ranges from the queue
        _burnBatch(owner, burnIds, burnAmounts);

        // Mint new glyph ranges
        _mintBatch(owner, upsertQueueTokenIds, upsertQueueAmounts, "");

        // Mint staked glyph ranges
        stGlyph.mintBatch(owner, stakedTokenIds, stakedAmounts, "");
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
