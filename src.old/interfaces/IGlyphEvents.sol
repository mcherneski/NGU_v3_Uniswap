// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IGlyphEvents
 * @dev Interface containing all Glyph-related event definitions
 */
interface IGlyphEvents {
  // Events
  /// @notice Emitted when approval for all tokens is set
  /// @param owner The owner of the tokens
  /// @param operator The operator address
  /// @param approved True if approved, false otherwise
  /// @dev This event is emitted when an operator is approved to manage all tokens of an owner.
  event ApprovalForAll(
    address indexed owner,
    address indexed operator,
    bool approved
  );
  
  /// @notice Emitted when a specific token is approved
  /// @param owner The owner of the token
  /// @param approved The approved address
  /// @param id The ID of the token
  /// @dev This event is emitted when a specific token is approved for transfer.
  event GlyphApproval(
    address indexed owner,
    address indexed approved,
    uint256 indexed id
  );
  
  /// @notice Emitted when a token is transferred
  /// @param from The sender address
  /// @param to The recipient address
  /// @param id The ID of the token
  /// @param nft True if the token is an NFT, false otherwise
  /// @dev This event is emitted when a token is transferred from one address to another.
  event Transfer(
    address indexed from,
    address indexed to,
    uint256 indexed id,
    bool nft
  );
  
  /// @notice Emitted when a batch of tokens is transferred
  /// @param from The sender address
  /// @param to The recipient address
  /// @param startTokenId The starting token ID of the batch
  /// @param quantity The number of tokens transferred
  /// @dev This event is emitted for batch transfers of tokens.
  event BatchTransfer(
    address indexed from,
    address indexed to,
    uint256 startTokenId,
    uint256 quantity
  );
  
  /// @notice Emitted when a batch of tokens is burned
  /// @param from The address from which tokens are burned
  /// @param startTokenId The starting token ID of the batch
  /// @param quantity The number of tokens burned
  /// @dev This event is emitted when a batch of tokens is burned.
  event BatchBurn(
    address indexed from,
    uint256 startTokenId,
    uint256 quantity
  );
  
  /// @notice Emitted when a batch of tokens is minted
  /// @param to The recipient address
  /// @param startTokenId The starting token ID of the batch
  /// @param quantity The number of tokens minted
  /// @dev This event is emitted when a batch of tokens is minted.
  event BatchMint(
    address indexed to,
    uint256 startTokenId,
    uint256 quantity
  );
} 