// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface INGU505Events {
    // Core Events
    /// @notice Emitted when an exempt user is added    
    /// @param user The address of the added exempt user
    /// @dev Monitor this event to track when new exempt users are added.
    event AddressAddedToExemption(address indexed user);

    /// @notice Emitted when an exempt user is removed
    /// @param user The address of the removed exempt user
    /// @dev Monitor this event to track when exempt users are removed.
    event AddressRemovedFromExemption(address indexed user);

    /// @notice Emitted when a transfer is exempt
    /// @param from The sender address
    /// @param to The recipient address
    /// @param tokenId The ID of the token transferred
    /// @dev This event is emitted when a transfer is exempt from standard checks.
    event TransferExempt(address indexed from, address indexed to, uint256 indexed tokenId);

    /// @notice Emitted when the glyph minting hook address is set or updated.
    /// @param hookAddress The new address of the glyph minting hook.
    event GlyphMintingHookAddressSet(address indexed hookAddress);
} 