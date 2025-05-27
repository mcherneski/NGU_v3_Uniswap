// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

import {LinkedListQueue} from "./libraries/LinkedListQueue.sol";
import {NGUStakedGlyph} from "./NGUStakedGlyph.sol";

/**
 * @title NGUGlyph
 * @dev Implementation of the ERC1155 multi-token standard for the NGU project with role-based access control.
 * This contract allows for multiple glyphs, each with their own supply and metadata.
 */
contract NGUGlyph is ERC1155, AccessControl {
    using LinkedListQueue for LinkedListQueue.Queue;

    bytes32 public constant COMPTROLLER_ROLE = keccak256("COMPTROLLER_ROLE");

    NGUStakedGlyph public stGlyph;

    // Counter for generating new token IDs
    uint128 private _nextTokenId = 1;

    mapping(address => LinkedListQueue.Queue) private _ownerQueue;

    /**
     * @dev Emitted when a new glyph is created
     */
    event GlyphCreated(uint128 id, uint128 amount);

    /**
     * @dev Emitted when glyphs are removed from the user's queue
     */
    event GlyphsDequeued(address user, uint128 start, uint128 end);

    /**
     * @dev Constructor that sets up the default admin role
     */
    constructor() ERC1155("") {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        stGlyph = new NGUStakedGlyph("");
    }

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

    function userQueueRangeEnd(address user, uint128 cursor) public view returns (uint128) {
        uint128 balance = uint128(balanceOf(user, cursor));
        return balance == 0 ? 0 : cursor + balance - 1;
    }

    /**
     * @dev Creates a new glyph with an auto-incrementing ID
     * @param amount Amount of tokens to mint
     * @param data Additional data with no specified format, sent to the receiver
     * @return The ID of the newly created glyph
     */
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

    /**
     * @dev Checks if two token IDs can be merged into a single range
     * @param user The address of the user
     * @param rangeStart1 The first token ID
     * @param rangeStart2 The second token ID
     * @return True if the two token IDs can be merged, else false
     */
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

    error DequeueRequestEmpty();
    error DequeueRequestRangeEmpty(uint128 tokenId);
    error InvalidUserQueueToken(address user, uint128 tokenId);
    error InvalidRange(uint128 tokenId, uint128 start, uint128 end);
    error SubRangeOutOfBounds(uint128 rangeMin, uint128 rangeMax, uint128 start, uint128 end);
    error SubRangesNotSequential(uint128 tokenId, uint128 minStart, uint128 start);

    /**
     * @dev Removes multiple token IDs from the user's queue
     * @param dequeueRequests Array of RemoveQueueRequest structs
     */
    function dequeueGlyphsAndStake(RemoveQueueRequest[] memory dequeueRequests) external {
        require(dequeueRequests.length > 0, DequeueRequestEmpty());

        address owner = _msgSender();
        LinkedListQueue.Queue storage queue = _ownerQueue[owner];

        uint256 stakedLength;
        for (uint256 i; i < dequeueRequests.length; i++) {
            RemoveQueueRequest memory request = dequeueRequests[i];
            require(request.ranges.length > 0, DequeueRequestRangeEmpty(request.id));

            // Burn the tokens from the queue range
            uint256 oldSize = balanceOf(owner, request.id);
            require(oldSize > 0, InvalidUserQueueToken(owner, request.id));
            uint128 lastRangeId = request.id + uint128(oldSize) - 1;
            _burn(owner, request.id, oldSize);

            // Set the previous node as the cursor then remove it from the queue
            uint128 cursor = queue.at(request.id).prev;
            uint128 next = request.id;
            queue.remove(request.id);

            stakedLength += request.ranges.length;
            for (uint256 j; j < request.ranges.length; j++) {
                Range memory range = request.ranges[j];
                require(range.start <= range.end, InvalidRange(request.id, range.start, range.end));
                require(
                    range.start >= request.id && range.end <= lastRangeId,
                    SubRangeOutOfBounds(request.id, lastRangeId, range.start, range.end)
                );
                require(range.start >= next, SubRangesNotSequential(request.id, next, range.start));

                if (range.start > next) {
                    // Add missing range to queue and mint to user
                    cursor == 0 ? queue.pushFront(next) : queue.insertAfter(cursor, next);
                    _mint(owner, next, range.start - next, "");
                    cursor = next;
                }

                if (j == request.ranges.length - 1 && range.end < lastRangeId) {
                    // Add missing range to queue and mint to user
                    cursor == 0 ? queue.pushFront(range.end + 1) : queue.insertAfter(cursor, range.end + 1);
                    _mint(owner, range.end + 1, lastRangeId - range.end, "");
                }

                next = range.end + 1;

                emit GlyphsDequeued(owner, range.start, range.end);
            }
        }

        // Mint staked glyphs
        uint256[] memory stakedTokenIds = new uint256[](stakedLength);
        uint256[] memory stakedAmounts = new uint256[](stakedLength);
        for (uint256 i; i < dequeueRequests.length; i++) {
            Range[] memory ranges = dequeueRequests[i].ranges;
            for (uint256 j; j < ranges.length; j++) {
                uint256 index = i * ranges.length + j;
                stakedTokenIds[index] = ranges[j].start;
                stakedAmounts[index] = ranges[j].end - ranges[j].start + 1;
            }
        }

        // Mint staked glyphs
        stGlyph.mintBatch(owner, stakedTokenIds, stakedAmounts, "");
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
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
