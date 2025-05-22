// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {NGUBitMask} from "./Masks.sol";
import {console2 as console} from "forge-std/console2.sol";

/**
 * @title StackQueue
 * @notice An optimized queue implementation for managing token ranges using a linked list structure.
 * This implementation provides O(1) operations for most common operations while maintaining
 * the ability to efficiently handle token ranges.
 */
library StackQueue {
    // Error definitions
    error QueueEmpty();
    error QueueFull();
    error QueueOutOfBounds();
    error NotFound();
    error InvalidRange();
    error RangeSplitError();
    error InvalidMerge();
    error TokenAlreadyRemoved();
    error RangeNotFound();
    error InvalidOperation();

    // Struct to represent a token range with linked list pointers
    struct TokenRange {
        uint40 startId;      // Start of the token range
        uint40 size;         // Number of tokens in range
        uint40 prevId;       // ID of previous range (0 if none)
        uint40 nextId;       // ID of next range (0 if none)
        address owner;       // Owner of the range
    }

    // Main queue structure
    struct RangeList {
        uint40 head;         // First range ID (0 if empty)
        uint40 tail;         // Last range ID (0 if empty)
        uint40 nextRangeId;  // Counter for generating unique range IDs
        uint40 size;         // Number of ranges in the list
        mapping(uint40 => TokenRange) ranges;  // Mapping of range ID to range data
    }

    // Events for debugging and monitoring
    event RangeAdded(uint40 rangeId, uint40 startId, uint40 size);
    event RangeRemoved(uint40 rangeId);
    event RangeSplit(uint40 originalRangeId, uint40 leftRangeId, uint40 rightRangeId);

    /**
     * @notice Initialize a new range list
     * @param list The range list to initialize
     */
    function init(RangeList storage list) internal {
        list.head = 0;
        list.tail = 0;
        list.nextRangeId = 1; // Start from 1 since 0 is used as null
        list.size = 0;
    }

    /**
     * @notice Clear the list
     * @param list The range list to clear
     */
    function clear(RangeList storage list) internal {
        uint40 currentId = list.head;
        while (currentId != 0) {
            uint40 nextId = list.ranges[currentId].nextId;
            delete list.ranges[currentId];
            currentId = nextId;
        }
        list.head = 0;
        list.tail = 0;
        list.size = 0;
        // Keep nextRangeId as is to maintain unique IDs
    }

    /**
     * @notice Get the front range without removing it
     * @param list The range list to query
     * @return range The front range
     */
    function frontRange(RangeList storage list) internal view returns (TokenRange memory) {
        if (empty(list)) revert QueueEmpty();
        return list.ranges[list.head];
    }

    /**
     * @notice Remove and return the front range
     * @param list The range list to modify
     * @return range The removed range
     */
    function popFrontRange(RangeList storage list) internal returns (TokenRange memory range) {
        if (empty(list)) revert QueueEmpty();
        
        uint40 frontId = list.head;
        range = list.ranges[frontId];
        
        // Update head
        list.head = range.nextId;
        if (list.head != 0) {
            list.ranges[list.head].prevId = 0;
        } else {
            // List is now empty
            list.tail = 0;
        }
        
        delete list.ranges[frontId];
        list.size--;
        
        emit RangeRemoved(frontId);
        return range;
    }

    /**
     * @notice Find a range by exact start ID
     * @param list The range list to search
     * @param startId The exact start ID to find
     * @return rangeId The ID of the range found
     * @return found Whether the range was found
     */
    function findRangeByStartId(
        RangeList storage list,
        uint40 startId
    ) internal view returns (uint40 rangeId, bool found) {
        uint40 currentId = list.head;
        while (currentId != 0) {
            TokenRange storage range = list.ranges[currentId];
            if (range.startId == startId) {
                return (currentId, true);
            }
            currentId = range.nextId;
        }
        return (0, false);
    }

    /**
     * @notice Add a new range to the end of the queue
     * @param list The range list to modify
     * @param startId The start ID of the range
     * @param size The size of the range
     * @param owner The owner of the range
     * @return rangeId The ID of the newly created range
     */
    function appendRange(
        RangeList storage list,
        uint40 startId,
        uint40 size,
        address owner
    ) internal returns (uint40) {
        if (size == 0) revert InvalidRange();
        
        uint40 newRangeId = list.nextRangeId++;
        TokenRange storage newRange = list.ranges[newRangeId];
        newRange.startId = startId;
        newRange.size = size;
        newRange.owner = owner;

        if (list.tail == 0) {
            // First range in the list
            list.head = newRangeId;
            list.tail = newRangeId;
        } else {
            // Add to end of list
            newRange.prevId = list.tail;
            list.ranges[list.tail].nextId = newRangeId;
            list.tail = newRangeId;
        }

        list.size++;
        emit RangeAdded(newRangeId, startId, size);

        // // Debug logs inside appendRange
        // console.log("[appendRange] newRangeId:", newRangeId);
        // console.log("[appendRange] list.head:", list.head);
        // console.log("[appendRange] list.tail:", list.tail);
        // console.log("[appendRange] new range startId:", list.ranges[newRangeId].startId);
        // console.log("[appendRange] new range size:", list.ranges[newRangeId].size);

        return newRangeId;
    }

    /**
     * @notice Add a new range to the front of the queue
     * @param list The range list to modify
     * @param startId The start ID of the range
     * @param size The size of the range
     * @param owner The owner of the range
     * @return rangeId The ID of the newly created range
     */
    function prependRange(
        RangeList storage list,
        uint40 startId,
        uint40 size,
        address owner
    ) internal returns (uint40) {
        if (size == 0) revert InvalidRange();
        
        uint40 newRangeId = list.nextRangeId++;
        TokenRange storage newRange = list.ranges[newRangeId];
        newRange.startId = startId;
        newRange.size = size;
        newRange.owner = owner;

        if (list.head == 0) {
            // First range in the list
            list.head = newRangeId;
            list.tail = newRangeId;
        } else {
            // Add to front of list
            newRange.nextId = list.head;
            list.ranges[list.head].prevId = newRangeId;
            list.head = newRangeId;
        }

        emit RangeAdded(newRangeId, startId, size);
        return newRangeId;
    }

    /**
     * @notice Remove a range from the list
     * @param list The range list to modify
     * @param rangeId The ID of the range to remove
     */
    function removeRange(RangeList storage list, uint40 rangeId) internal {
        TokenRange storage range = list.ranges[rangeId];
        if (range.owner == address(0)) revert RangeNotFound();

        // Update adjacent ranges
        if (range.prevId != 0) {
            list.ranges[range.prevId].nextId = range.nextId;
        } else {
            list.head = range.nextId;
        }

        if (range.nextId != 0) {
            list.ranges[range.nextId].prevId = range.prevId;
        } else {
            list.tail = range.prevId;
        }

        emit RangeRemoved(rangeId);
        delete list.ranges[rangeId];
    }

    /**
     * @notice Split a range at a specific token ID
     * @param list The range list to modify
     * @param rangeId The ID of the range to split
     * @param tokenId The token ID where to split
     * @return leftRangeId The ID of the left part of the split
     * @return rightRangeId The ID of the right part of the split
     */
    function splitRange(
        RangeList storage list,
        uint40 rangeId,
        uint40 tokenId
    ) internal returns (uint40 leftRangeId, uint40 rightRangeId) {
        TokenRange storage range = list.ranges[rangeId];
        if (range.owner == address(0)) revert RangeNotFound();
        
        if (tokenId <= range.startId || tokenId >= range.startId + range.size) {
            revert InvalidRange();
        }

        // Calculate sizes for new ranges
        uint40 leftSize = tokenId - range.startId;
        uint40 rightSize = range.size - leftSize - 1; // -1 for the split token

        // Create left range if needed
        if (leftSize > 0) {
            leftRangeId = list.nextRangeId++;
            TokenRange storage leftRange = list.ranges[leftRangeId];
            leftRange.startId = range.startId;
            leftRange.size = leftSize;
            leftRange.owner = range.owner;
            leftRange.prevId = range.prevId;
            if (range.prevId != 0) {
                list.ranges[range.prevId].nextId = leftRangeId;
            } else {
                list.head = leftRangeId;
            }
        }

        // Create right range if needed
        if (rightSize > 0) {
            rightRangeId = list.nextRangeId++;
            TokenRange storage rightRange = list.ranges[rightRangeId];
            rightRange.startId = tokenId + 1;
            rightRange.size = rightSize;
            rightRange.owner = range.owner;
            rightRange.nextId = range.nextId;
            if (range.nextId != 0) {
                list.ranges[range.nextId].prevId = rightRangeId;
            } else {
                list.tail = rightRangeId;
            }
        }

        // Link the new ranges together if both exist
        if (leftRangeId != 0 && rightRangeId != 0) {
            list.ranges[leftRangeId].nextId = rightRangeId;
            list.ranges[rightRangeId].prevId = leftRangeId;
        }

        emit RangeSplit(rangeId, leftRangeId, rightRangeId);
        
        // Remove the original range's data
        delete list.ranges[rangeId];
        
        // Adjust size based on net change in ranges
        if (leftRangeId != 0 && rightRangeId != 0) {
             // Added two ranges (left and right), removed one (original)
             list.size++; 
        } else if (leftRangeId == 0 && rightRangeId == 0) {
             // This case shouldn't happen iftokenId is validated correctly,
             // but if it did, we removed one range and added none.
             list.size--; 
        } 
        // If only one of left/right was created, size remains unchanged (1 added, 1 removed)
        
        return (leftRangeId, rightRangeId);
    }

    /**
     * @notice Find a range containing a specific token ID
     * @param list The range list to search
     * @param tokenId The token ID to find
     * @return rangeId The ID of the range containing the token
     * @return found Whether the token was found in any range
     */
    function findRangeByToken(
        RangeList storage list,
        uint40 tokenId
    ) internal view returns (uint40 rangeId, bool found) {
        uint40 currentId = list.head;
        while (currentId != 0) {
            TokenRange storage range = list.ranges[currentId];
            if (tokenId >= range.startId && tokenId < range.startId + range.size) {
                return (currentId, true);
            }
            currentId = range.nextId;
        }
        return (0, false);
    }

    /**
     * @notice Get all token IDs in the queue
     * @param list The range list to query
     * @return tokenIds Array of all token IDs in the queue
     */
    function getAllTokenIds(RangeList storage list) internal view returns (uint256[] memory tokenIds) {
        // First count total tokens
        uint256 totalTokens = 0;
        uint40 currentId = list.head;
        while (currentId != 0) {
            totalTokens += list.ranges[currentId].size;
            currentId = list.ranges[currentId].nextId;
        }

        // Allocate array and populate
        tokenIds = new uint256[](totalTokens);
        uint256 currentIndex = 0;
        currentId = list.head;
        
        while (currentId != 0) {
            TokenRange storage range = list.ranges[currentId];
            for (uint40 i = 0; i < range.size; i++) {
                tokenIds[currentIndex++] = range.startId + i;
            }
            currentId = range.nextId;
        }

        return tokenIds;
    }

    /**
     * @notice Get all ranges in the queue
     * @param list The range list to query
     * @return ranges Array of all ranges
     */
    function getAllRanges(RangeList storage list) internal view returns (TokenRange[] memory ranges) {
        // First count ranges
        uint256 count = 0;
        uint40 currentId = list.head;
        while (currentId != 0) {
            count++;
            currentId = list.ranges[currentId].nextId;
        }

        // Allocate array and populate
        ranges = new TokenRange[](count);
        currentId = list.head;
        for (uint256 i = 0; i < count; i++) {
            ranges[i] = list.ranges[currentId];
            currentId = list.ranges[currentId].nextId;
        }

        return ranges;
    }

    /**
     * @notice Check if the queue is empty
     * @param list The range list to check
     * @return True if the queue is empty
     */
    function empty(RangeList storage list) internal view returns (bool) {
        return list.head == 0;
    }
} 