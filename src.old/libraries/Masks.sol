// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library NGUBitMask {
    // Constants for bit positions
    uint256 internal constant BITMASK_ADDRESS = (1 << 160) - 1;                           // 160 bits [0-159]
    
    uint256 internal constant BITMASK_START_ID_BITS = (1 << 63) - 1;                     // 63 bits for masking (increased from 40)
    uint256 internal constant BITMASK_START_ID = BITMASK_START_ID_BITS << 160;           // 63 bits [160-222]
    
    uint256 internal constant BITMASK_STACK_SIZE_BITS = (1 << 32) - 1;                   // 32 bits for masking (reduced from 38)
    uint256 internal constant BITMASK_STACK_SIZE = BITMASK_STACK_SIZE_BITS << 223;       // 32 bits [223-254]
    
    uint256 internal constant BITMASK_STAKED = uint256(1) << 255;                        // 1 bit [255] (moved to the last bit)
    // All bits are now used efficiently

    // Constants for time conversion
    uint256 internal constant SECONDS_PER_DAY = 24 * 60 * 60;  // 86400

    // Helper function to calculate queue position
    function calculateQueuePosition(bool _isStaked) internal view returns (uint256) {
        return _isStaked ? 0 : block.timestamp / SECONDS_PER_DAY;
    }

    // Helper functions for bit manipulation
    function getOwner(uint256 packed) internal pure returns (address owner) {
        owner = address(uint160(packed & BITMASK_ADDRESS));
        return owner;
    }

    function getStartId(uint256 packed) internal pure returns (uint256) {
        uint256 startId = (packed & BITMASK_START_ID) >> 160;
        return startId;
    }

    function getStackSize(uint256 packed) internal pure returns (uint256) {
        uint256 stackSize = (packed & BITMASK_STACK_SIZE) >> 223; // Updated shift
        return stackSize;
    }

    function isStaked(uint256 packed) internal pure returns (bool staked) {
        staked = (packed & BITMASK_STAKED) != 0;
        return staked;
    }

    function packTokenData(
        address owner,
        uint256 startId,
        uint256 stackSize,
        bool isTokenStaked
    ) internal pure returns (uint256 packed) {
        require(owner != address(0), "Owner cannot be zero address");
        require(startId <= BITMASK_START_ID_BITS, "Start ID too large");
        require(stackSize <= BITMASK_STACK_SIZE_BITS, "Stack size too large");

        packed = uint256(uint160(owner)) |
                (startId << 160) |
                (stackSize << 223) | // Updated shift
                (isTokenStaked ? BITMASK_STAKED : 0);
        return packed;
    }
} 