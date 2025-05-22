// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title QueueMetadataLib
 * @notice Library for packing and unpacking StackQueue metadata into a single uint256.
 * @dev Layout (160 bits total):
 *      | nextRangeId (40 bits) | size (40 bits) | tail (40 bits) | head (40 bits) |
 */
library QueueMetadataLib {
    uint256 private constant BITS_PER_FIELD = 40;
    uint256 private constant HEAD_OFFSET = 0;
    uint256 private constant TAIL_OFFSET = BITS_PER_FIELD;
    uint256 private constant SIZE_OFFSET = 2 * BITS_PER_FIELD;
    uint256 private constant NEXT_RANGE_ID_OFFSET = 3 * BITS_PER_FIELD;

    // Mask to extract a 40-bit value
    uint256 private constant FIELD_MASK = (1 << BITS_PER_FIELD) - 1;

    function pack(
        uint40 head,
        uint40 tail,
        uint40 size,
        uint40 nextRangeId
    ) internal pure returns (uint256 packed) {
        packed |= uint256(head) << HEAD_OFFSET;
        packed |= uint256(tail) << TAIL_OFFSET;
        packed |= uint256(size) << SIZE_OFFSET;
        packed |= uint256(nextRangeId) << NEXT_RANGE_ID_OFFSET;
    }

    function unpack(
        uint256 packed
    ) internal pure returns (uint40 head, uint40 tail, uint40 size, uint40 nextRangeId) {
        head = getHead(packed);
        tail = getTail(packed);
        size = getSize(packed);
        nextRangeId = getNextRangeId(packed);
    }

    function getHead(uint256 packed) internal pure returns (uint40) {
        return uint40((packed >> HEAD_OFFSET) & FIELD_MASK);
    }

    function getTail(uint256 packed) internal pure returns (uint40) {
        return uint40((packed >> TAIL_OFFSET) & FIELD_MASK);
    }

    function getSize(uint256 packed) internal pure returns (uint40) {
        return uint40((packed >> SIZE_OFFSET) & FIELD_MASK);
    }

    function getNextRangeId(uint256 packed) internal pure returns (uint40) {
        return uint40((packed >> NEXT_RANGE_ID_OFFSET) & FIELD_MASK);
    }

    // --- Setters ---

    function setHead(uint256 packed, uint40 head) internal pure returns (uint256) {
        // Clear the bits for the head field, then set the new value
        return (packed & ~(FIELD_MASK << HEAD_OFFSET)) | (uint256(head) << HEAD_OFFSET);
    }

    function setTail(uint256 packed, uint40 tail) internal pure returns (uint256) {
        return (packed & ~(FIELD_MASK << TAIL_OFFSET)) | (uint256(tail) << TAIL_OFFSET);
    }

    function setSize(uint256 packed, uint40 size) internal pure returns (uint256) {
        return (packed & ~(FIELD_MASK << SIZE_OFFSET)) | (uint256(size) << SIZE_OFFSET);
    }

    function setNextRangeId(uint256 packed, uint40 nextRangeId) internal pure returns (uint256) {
        return (packed & ~(FIELD_MASK << NEXT_RANGE_ID_OFFSET)) | (uint256(nextRangeId) << NEXT_RANGE_ID_OFFSET);
    }

    // --- Modifiers ---

    function incrementSize(uint256 packed) internal pure returns (uint256 newPacked) {
        uint40 currentSize = getSize(packed);
        // Revert on overflow is default in Solidity ^0.8.0
        return setSize(packed, currentSize + 1);
    }

    function decrementSize(uint256 packed) internal pure returns (uint256 newPacked) {
        uint40 currentSize = getSize(packed);
        // Revert on underflow is default in Solidity ^0.8.0
        return setSize(packed, currentSize - 1);
    }

    /**
     * @notice Increments the nextRangeId field and returns the ID *before* incrementing.
     * @dev Used when allocating a new range ID.
     * @param packed The current packed metadata.
     * @return oldNextRangeId The ID that was just allocated.
     * @return newPacked The updated packed metadata with the incremented nextRangeId.
     */
    function incrementNextRangeId(uint256 packed) internal pure returns (uint40 oldNextRangeId, uint256 newPacked) {
        oldNextRangeId = getNextRangeId(packed);
        // Revert on overflow is default in Solidity ^0.8.0
        newPacked = setNextRangeId(packed, oldNextRangeId + 1);
    }
} 