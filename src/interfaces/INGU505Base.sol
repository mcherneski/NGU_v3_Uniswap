// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";

/// @title INGU505Base Interface
/// @notice Interface for the NGU505 base functionality
/// @dev Combines ERC20 and Glyph functionality with additional features  
/// @notice  This interface defines the core functionality for the NGU505 token, which combines
/// ERC20 (fungible token) and ERC721A (Glyph) functionality in a single contract. The 721s do not adhere to the full 721 interface,
/// and have therefore beeen renamed as Glyphs - a psuedo token metadata tag. The token implements a unique
/// "stack" system where tokens can be grouped together and transferred as a unit. It also supports exemptions
/// from glyph transfers for specific addresses (like staking contracts).
interface INGU505Base is IERC165 {
    /// @notice Struct to hold range information for AI agents
    /// @dev This provides a compact representation of token ranges
    /// @dev Each RangeInfo represents a continuous sequence of token IDs with the same owner and staking status
    /// @dev This structure is optimized for gas efficiency when dealing with large token collections
    struct RangeInfo {
        uint256 startId;    // First token ID in the range
        uint256 size;       // Number of tokens in the range
        uint256 endId;      // Last token ID in the range (startId + size - 1)
        bool isStaked;      // Whether the tokens in this range are staked
        uint256 queueIndex; // Position in the queue (0 = front of queue, would be transferred first)
    }

    /// @notice Struct to hold a summary of a user's queue
    /// @dev This provides high-level information about the queue without returning all ranges
    /// @dev This structure is designed for maximum gas efficiency when only aggregate data is needed
    /// @dev All fields are computed by scanning the ranges once, avoiding multiple iterations
    struct QueueSummary {
        uint256 totalRanges;       // Total number of distinct token ranges in the queue
        uint256 totalTokens;       // Total number of tokens across all ranges
        uint256 stakedTokens;      // Number of tokens that are currently staked
        uint256 unstakedTokens;    // Number of tokens that are not staked and available for transfer
        uint256 smallestTokenId;   // Smallest token ID owned by the user
        uint256 largestTokenId;    // Largest token ID owned by the user
        bool hasStakedTokens;      // Whether the user has any staked tokens (quick check flag)
    }

    // Error definitions
    /// @notice Thrown when attempting to transfer to or from the zero address
    /// @notice  This error occurs when attempting to transfer tokens to the zero address.
    /// Always verify that recipient addresses are valid and non-zero.
    error InvalidRecipient();

    /// @notice Thrown when attempting to burn zero tokens
    /// @notice  This error occurs when attempting to burn zero tokens.
    /// Ensure the burner is Glyph Exempt.
    error InvalidBurn();

    /// @notice Thrown when attempting to transfer zero tokens
    /// @notice  This error occurs when attempting to transfer zero tokens.
    /// Always ensure transfer amounts are greater than zero.
    error InvalidAmount();

    /// @notice Thrown when attempting to transfer more than glyph ID number.
    /// @notice  This error occurs when attempting to transfer a range of tokens that exceeds valid limits.
    /// Check the range size before attempting transfers.
    error InvalidRangeSize();

    /// @notice Thrown when attempting to transfer more tokens than available
    /// @param required The amount attempted to transfer
    /// @param actual The actual balance available
    /// @notice  This error occurs when attempting to transfer more tokens than the sender owns.
    /// Always check balances before transfers using balanceOf.
    error InsufficientBalance(uint256 required, uint256 actual);

    /// @notice Thrown when attempting to transfer more tokens than allowed
    /// @param required The amount attempted to transfer
    /// @param allowed The amount allowed to transfer
    /// @notice  This error occurs when attempting to transfer more tokens than approved.
    /// Check allowances before transferFrom operations using allowance.
    error InsufficientAllowance(uint256 required, uint256 allowed);

    /// @notice Thrown when attempting to mint to the zero address
    /// @notice  This error occurs when attempting to mint tokens to the zero address.
    /// Always verify recipient addresses for minting operations.
    error MintToZeroAddress();

    /// @notice Thrown when a token does not exist
    /// @notice  This error occurs when attempting to operate on a token ID that doesn't exist.
    /// Verify token existence before operations using ownerOf.
    error TokenDoesNotExist();

    /// @notice Thrown when a glyph cannot be found
    /// @notice  This error occurs when a specific glyph (NFT) cannot be found.
    /// Check if the token exists before attempting operations.
    error GlyphNotFound();

    /// @notice Thrown when a queue is empty
    /// @notice  This error occurs when attempting to get a token from an empty transfer queue.
    /// Check if the queue has tokens using getQueueGlyphIds before operations.
    error QueueEmpty();

    /// @notice Thrown when attempting to transfer from wrong address
    /// @notice  This error occurs when the from address in a transfer doesn't match the token owner.
    /// Verify ownership before transfers using ownerOf.
    error WrongFrom();

    /// @notice Thrown when attempting to transfer an invalid quantity
    /// @notice  This error occurs when attempting to transfer an invalid quantity of tokens.
    /// Ensure transfer amounts are valid positive integers.
    error InvalidQuantity();

    /// @notice Thrown when attempting to transfer a staked token
    /// @notice  This error occurs when attempting to transfer a token that is currently staked.
    /// Check if tokens are staked before transfers using the staking contract's isStaked function.
    error InvalidTransfer();

    /// @notice Thrown when stack size exceeds maximum value
    /// @notice  This error occurs when a token stack would exceed the maximum allowed size.
    /// Check stack sizes before operations using getRangeInfo.
    error InvalidStackSize();

    /// @notice Thrown when attempting to set invalid exemption
    /// @notice  This error occurs when attempting to set invalid transfer exemption status.
    /// Only authorized addresses can manage exemptions.
    error InvalidExemption();

    /// @notice Thrown when caller is not authorized
    /// @notice  This error occurs when an unauthorized address attempts a restricted operation.
    /// Check authorization before attempting admin operations.
    error NotAuthorized();

    /// @notice Thrown when operator is invalid
    /// @notice  This error occurs when an invalid operator is specified for approval.
    /// Ensure operator addresses are valid.
    error InvalidOperator();

    /// @notice Thrown when permit deadline has expired
    /// @notice  This error occurs when attempting to use a permit after its deadline.
    /// Ensure permit deadlines are in the future when generating signatures.
    error PermitDeadlineExpired();

    /// @notice Thrown when permit signer is invalid
    /// @notice  This error occurs when the recovered signer from a permit doesn't match the owner.
    /// Verify signature parameters are correct.
    error InvalidSigner();

    /// @notice Thrown when owner is invalid
    /// @notice  This error occurs when an invalid owner address is specified.
    /// Ensure owner addresses are valid.
    error InvalidOwner();

    /// @notice Thrown when start ID exceeds maximum value
    /// @notice  This error occurs when a specified start ID for a range operation is invalid.
    /// Ensure start IDs are within valid token ID ranges.
    error InvalidStartId();

    /// @notice Thrown when invalid token ID is provided
    /// @param tokenId The invalid token ID
    /// @notice  This error occurs when an invalid token ID is provided for an operation.
    /// Ensure token IDs are valid before operations.
    error InvalidTokenId(uint256 tokenId);

    /// @notice Thrown when max supply would be exceeded
    /// @param attempted The attempted total supply
    /// @param maximum The maximum allowed supply
    /// @notice  This error occurs when a mint operation would exceed the maximum token supply.
    /// Check current supply before minting using totalSupply.
    error MaxSupplyExceeded(uint256 attempted, uint256 maximum);

    /// @notice Error thrown when fractional NFT changes are invalid
    /// @dev Should only ever burn or mint exactly 1 NFT for fractional completion
    /// @notice  This is an internal error related to the conversion between ERC20 and ERC721 tokens.
    error InvalidFractionalChange();

    // Core ERC20 functions
    /// @notice Transfer tokens to another address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return Success boolean
    /// @dev This function should only be called by the token owner or an approved operator.
    function transfer(address to, uint256 amount) external returns (bool);
    
    /// @notice Transfer tokens from one address to another
    /// @param from The sender address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return Success boolean
    /// @dev This function requires prior approval from the token owner.
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    
    /// @notice Approve another address to spend tokens
    /// @param spender The address to approve
    /// @param value The amount to approve
    /// @return Success boolean
    /// @dev Use this function to allow another address to transfer tokens on your behalf.
    function approve(address spender, uint256 value) external returns (bool);
    
    /// @notice Safely transfer tokens to another address
    /// @param to The recipient address
    /// @param value The amount to transfer
    /// @return Success boolean
    /// @dev This function includes additional checks for safe transfers.
    function safeTransfer(address to, uint256 value) external returns (bool);
    
    /// @notice ERC20 transfer from one address to another
    /// @param from_ The sender address
    /// @param to_ The recipient address
    /// @param value_ The amount to transfer
    /// @return Success boolean
    /// @dev This function is an alternative implementation of transferFrom for ERC20 functionality.
    function erc20TransferFrom(address from_, address to_, uint256 value_) external returns (bool);

    // ERC721 functions
    /// @notice Get the owner of a specific token
    /// @param tokenId The token ID to query
    /// @return The owner address
    /// @notice  This is the standard ERC721 ownerOf function. Use this to determine who owns a specific
    /// NFT (Glyph). Will revert if the token doesn't exist.
    function ownerOf(uint256 tokenId) external view returns (address);
    
    /// @notice Get the total supply of Glyphs
    /// @return The total number of Glyphs
    /// @notice  This returns the total number of Glyphs (Glyphs) that have been minted.
    function glyphTotalSupply() external view returns (uint256);
    
    /// @notice Get the number of Glyphs owned by an address
    /// @param owner The address to query
    /// @return The number of glyphs owned
    /// @notice  This returns how many Glyphs (Glyphs) are owned by a specific address.
    function glyphBalanceOf(address owner) external view returns (uint256);
    
    /// @notice Get the approved address for a specific token
    /// @param tokenId The token ID to query
    /// @return The approved address
    /// @notice  This returns the address approved to transfer a specific NFT (Glyph).
    /// Returns the zero address if no approval exists.
    function getApproved(uint256 tokenId) external view returns (address);
    
    /// @notice Check if an operator is approved for all tokens of an owner
    /// @param owner The owner address
    /// @param operator The operator address
    /// @return True if approved for all
    /// @notice  This checks if an operator is approved to manage all Glyphs (Glyphs) of an owner.
    /// Used for marketplace approvals and other delegation scenarios.
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    
    /// @notice Set approval for all tokens
    /// @param operator The operator address
    /// @param approved True to approve, false to revoke
    /// @notice  This approves or revokes an operator to manage all of the caller's Glyphs (Glyphs).
    /// Use this for marketplace approvals. Be careful as this grants full control over all your Glyphs.
    function setApprovalForAll(address operator, bool approved) external;
    
    /// @notice Approve an address to transfer a specific token
    /// @param to The address to approve
    /// @param tokenId The token ID to approve
    /// @notice  This approves a specific address to transfer a single NFT (Glyph).
    /// The caller must be the owner or an approved operator.
    function approveGlyph(address to, uint256 tokenId) external;
    
    /// @notice Owned function which needs to be overridden for staking.
    /// @param owner The address to check glyph ownership
    /// @dev The owned function with 721A compatability already uses more than a mapping, so we need a function for owned
    /// regardless of the use of the staking contract.
    function owned(address owner) external view returns (uint256[] memory);
    
    /// @notice Get all token IDs in the transfer queue
    /// @param owner The address to query
    /// @return Array of token IDs
    /// @notice  This returns all token IDs in an owner's transfer queue in the order they would be transferred.
    /// Useful for displaying which tokens would be transferred next. Horribly inefficient and should be used in emergencies only.
    function getQueueGlyphIds(address owner) external view returns (uint256[] memory);

    /// @notice Get all ranges in a user's queue without expanding to individual token IDs
    /// @param owner The address to query
    /// @return Array of range information for all ranges in the queue
    /// @dev This function is orders of magnitude more gas-efficient than getQueueGlyphIds for accounts with many tokens
    /// @notice This function provides a compact representation of token ranges in a user's queue without expanding to individual IDs.
    /// Each range includes startId, size, endId, staking status, and queue position, enabling efficient analysis of token holdings.
    /// AI agents can use this data to:
    /// - Calculate total tokens without gas-intensive operations
    /// - Check if specific token IDs exist within ranges
    /// - Analyze ownership patterns across large collections
    /// - Process token data in batches for improved performance
    /// This approach supports accounts with millions of tokens while maintaining reasonable gas costs.
    function getQueueRanges(address owner) external view returns (RangeInfo[] memory);

    // Exemption management
    /// @notice Check if an address is exempt from Glyph transfers
    /// @param target The address to check
    /// @return True if exempt
    /// @notice  This checks if an address is exempt from Glyph transfers, meaning it can only
    /// interact with the ERC20 functionality. For staking, airdrop and exchange addresses.
    function isGlyphTransferExempt(address target) external view returns (bool);
    
    /// @notice Set Glyph transfer exemption status
    /// @param account The address to update
    /// @param value True to exempt, false to allow
    /// @notice  This sets whether an address is exempt from Glyph transfers, not the ERC20 functionality.
    function setIsGlyphTransferExempt(address account, bool value) external;
    
    /// @notice Check if an address is an exemption manager
    /// @param account The address to check
    /// @return True if the address is an exemption manager
    /// @notice  This checks if an address is authorized to manage exemptions.
    function isExemptionManager(address account) external view returns (bool);

    /// @notice Get the metadata URI for a specific token ID
    /// @param id The token ID to get the URI for
    /// @return The metadata URI string
    /// @dev Implements rarity tiers based on token ID - Implement in deployment contract.
    /// @notice  This returns the URI for a token's metadata, which contains information about
    /// the NFT's attributes, image, and other details. The URI format follows the ERC721 metadata standard.
    function tokenURI(uint256 id) external view returns (string memory);

    // Stack info
    
    /// @notice Get detailed information about a stack
    /// @param tokenId The token ID to query
    /// @return owner The owner of the stack
    /// @return startId The starting token ID of the stack
    /// @return size The number of tokens in the stack
    /// @return isStaked Whether the stack is staked
    /// @notice  This returns comprehensive information about a token stack, including:
    /// - The owner of all tokens in the stack
    /// - The starting token ID of the stack
    /// - How many tokens are in the stack
    /// - Whether the stack is currently staked
    /// This is essential for understanding how tokens are grouped and transferred.
    function getRangeInfo(uint256 tokenId) external view returns (
        address owner,
        uint256 startId,
        uint256 size,
        bool isStaked
    );

    // EIP-2612 functions
    /// @notice EIP-2612 permit function for gasless approvals
    /// @param owner The token owner
    /// @param spender The spender to approve
    /// @param value The amount to approve
    /// @param deadline The deadline for the signature
    /// @param v The recovery byte of the signature
    /// @param r The first 32 bytes of the signature
    /// @param s The second 32 bytes of the signature
    /// @notice  This implements EIP-2612 permit functionality, allowing gasless approvals.
    /// Instead of calling approve (which costs gas), the owner can sign a message off-chain and anyone
    /// can submit that signature to approve a spender. Useful for first-time users without gas.
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    // Events
    /// @notice Emitted when an exemption manager is added
    /// @param account The address that was added
    /// @notice  Monitor this event to track when new exemption managers are added.
    event ExemptionManagerAdded(address indexed account);
    
    /// @notice Emitted when an exemption manager is removed
    /// @param account The address that was removed
    /// @notice  Monitor this event to track when exemption managers are removed.
    event ExemptionManagerRemoved(address indexed account);
    
    /// @notice Emitted when a batch of tokens is transferred
    /// @param from The sender address
    /// @param to The recipient address
    /// @param tokenIds Array of transferred token IDs
    /// @notice  Monitor this event to track batch transfers of Glyphs (Glyphs).
    /// This is emitted instead of multiple Transfer events for efficiency.
    event BatchTransfer(address indexed from, address indexed to, uint256[] tokenIds);
} 
