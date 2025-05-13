// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";

/// @title INGU505Staking Interface
/// @notice Interface for NGU505 staking functionality
/// @dev Handles staking and unstaking of NFTs with associated ERC20 tokens
/// @notice  This interface defines the staking functionality for NGU505 tokens. 
/// It allows users to stake their NFTs (Glyphs) to earn rewards. The contract supports early access 
/// verification through Merkle proofs and batch operations for gas efficiency.
interface INGU505Staking is IERC165 { 
    // Events
    /// @notice Emitted when NFTs are staked
    /// @param account The address that staked the NFTs
    /// @param tokenId The NFT ID
    /// @dev Monitor this event to track staking activities. Each staked token emits a separate event.
    event Stake(address indexed account, uint256 tokenId);

    /// @notice Emitted when NFTs are unstaked
    /// @param account The address that unstaked the NFTs
    /// @param tokenId The NFT ID
    /// @dev Monitor this event to track unstaking activities. Each unstaked token emits a separate event.
    event Unstake(address indexed account, uint256 tokenId);
    /// @notice Emitted when a batch of tokens are staked
    /// @param account The address that staked the tokens
    /// @param tokenIds The array of token IDs that were staked
    event BatchStake(address indexed account, uint256[] tokenIds);

    /// @notice Emitted when a batch of tokens are unstaked
    /// @param account The address that unstaked the tokens
    /// @param tokenIds The array of token IDs that were unstaked
    event BatchUnstake(address indexed account, uint256[] tokenIds);
    // Errors
    
    /// @notice Thrown when a token is already staked
    /// @param tokenId The ID of the token that is already staked
    /// @notice  This error occurs when trying to stake a token that is already staked.
    /// Always check if a token is staked using isStaked before attempting to stake it.
    error GlyphAlreadyStaked(uint256 tokenId);

    /// @notice Thrown when non-allowed address attempts to stake before early access period ends
    /// @notice  This error occurs when an address not on the allowlist tries to stake during the early access period.
    /// Users should verify their early access status with verifyEarlyAccess before attempting to stake.
    error NotAllowed();

    /// @notice Thrown when attempting to unstake a token that is not staked
    /// @param tokenId The ID of the token that is not staked
    /// @notice  This error occurs when trying to unstake a token that is not currently staked.
    /// Always check if a token is staked using isStaked before attempting to unstake it.
    error GlyphNotStaked(uint256 tokenId);

    /// @notice Thrown when attempting to stake/unstake an empty array of tokens
    /// @notice  This error occurs when calling stake with an empty array of token IDs.
    /// Always include at least one token ID in the array.
    error EmptyStakingArray();

    
    error InvalidState();
    
    /// @notice Thrown when attempting to unstake with an empty array of tokens
    /// @notice  This error occurs when calling unstake with an empty array of token IDs.
    /// Always include at least one token ID in the array.
    error EmptyUnstakingArray();
    
    /// @notice Thrown when an exempt address attempts to stake
    /// @notice  This error occurs when an address that is exempt from ERC721 transfers attempts to stake.
    /// Exempt addresses cannot stake tokens.
    error InvalidStakingExemption();

    /// @notice Thrown when attempting to stake an already staked token
    /// @param tokenId The ID of the token that is already staked
    /// @notice  This error occurs when trying to stake a token that is already staked.
    /// Always check if a token is already staked using isStaked before attempting to stake it.
    error TokenAlreadyStaked(uint256 tokenId);

    /// @notice Thrown when staked token index exceeds maximum value
    /// @notice  This is an internal error related to token indexing.
    error IndexOverflow();

    /// @notice Thrown when the token is not staked
    /// @notice  This error occurs when performing operations on a token that is not staked.
    /// Always check if a token is staked using isStaked before operations.
    error NotStaked();
    
    /// @notice Thrown when the range is invalid
    /// @notice  This error occurs when the range is invalid.
    error InvalidRange();

    /// @notice Thrown when attempting to stake more tokens than allowed in a single batch
    /// @notice  This error occurs when the batch size for staking exceeds the maximum allowed.
    /// Break large batches into smaller ones to avoid this error.
    error BatchSizeExceeded();

    /// @notice Thrown when attempting to stake with insufficient balance
    /// @param required The required balance
    /// @param actual The actual balance
    /// @notice  This error occurs when trying to stake without owning the required tokens.
    /// Ensure the user owns all tokens they're attempting to stake.
    error InsufficientStakingBalance(uint256 required, uint256 actual);

    /// @notice Stakes an array of tokens
    /// @param tokenIds_ Array of token IDs to stake
    /// @return True if the staking was successful
    /// @notice  Main function for staking tokens. Before calling:
    /// 1. Ensure the user owns all tokens in the array
    /// 2. Check that none of the tokens are already staked using isStaked
    /// 3. Approve the staking contract to transfer the tokens
    /// For gas efficiency, batch multiple tokens in a single call, but be aware of BatchSizeExceeded limits.
    function stake(uint256[] calldata tokenIds_) external returns (bool);

    /// @notice Unstakes an array of tokens
    /// @param tokenIds_ Array of token IDs to unstake
    /// @return True if the unstaking was successful
    /// @notice  Main function for unstaking tokens. Before calling:
    /// 1. Ensure all tokens in the array are currently staked by the caller using isStaked
    /// 2. Check that the caller has sufficient staked balance using stakedBalanceOf
    /// For gas efficiency, batch multiple tokens in a single call.
    function unstake(uint256[] calldata tokenIds_) external returns (bool);

    /// @notice Checks if a token is staked
    /// @param tokenId_ The token ID to check
    /// @return True if the token is staked
    /// @notice  Always use this function to check if a token is staked before attempting to stake or unstake it.
    /// This helps avoid TokenAlreadyStaked and GlyphNotStaked errors.
    function isStaked(uint256 tokenId_) external view returns (bool);

    /// @notice Get the staked balance for an address
    /// @param owner_ The address to check
    /// @return The total amount of staked tokens
    /// @notice  Use this function to check how many tokens an address has staked.
    function stakedBalanceOf(address owner_) external view returns (uint256);

    /// @notice Get all staked tokens for an address
    /// @param owner_ The address to check
    /// @return tokenIds Array of staked NFT IDs
    /// @notice  Use this function to get a complete list of all tokens staked by an address.
    function getStakedGlyphs(address owner_) external view returns (uint256[] memory tokenIds);

} 

