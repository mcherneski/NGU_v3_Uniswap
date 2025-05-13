// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;  // Update to latest version

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NGUStaking} from "./NGUStaking.sol";
// import {NGU505UniswapV3Exempt} from "./lib/NGU505UniswaV3Exempt.sol";
import {NGU505Base} from "./NGU505Base.sol";

error NotAuthorizedHook();

contract NumberGoUp is Ownable, NGUStaking {
    using Strings for uint256;

    /// @notice Base URI for token metadata
    string public uriBase;
    
    /// @notice Number of different token variants.5
    uint256 public constant VARIANTS = 5;    

    /// @notice Initializes the NumberGoUp token with its core parameters
    /// @param name_ Token name
    /// @param symbol_ Token symbol
    /// @param decimals_ Number of decimals for ERC20 functionality
    /// @param units_ Number of base units per token
    /// @param maxTotalSupplyERC20_ Maximum total supply of ERC20 tokens
    /// @param initialOwner_ Address of the initial contract owner
    /// @param initialMintRecipient_ Address to receive the initial token mint
    /// @param v4router_ Address of Uniswap V4 router (for exemption)
    /// @param v4PositionManager_ Address of Uniswap V4 position manager (for exemption)
    /// @param v4PoolManager_ Address of Uniswap V4 pool manager (for exemption)
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 units_,
        uint256 maxTotalSupplyERC20_,
        address initialOwner_,
        address initialMintRecipient_,
        address v4router_,
        address v4PositionManager_,
        address v4PoolManager_
    )
        NGUStaking(
            name_, 
            symbol_, 
            decimals_, 
            units_,
            maxTotalSupplyERC20_,
            initialOwner_,
            initialMintRecipient_
        )
        Ownable(initialOwner_)
    {
        // Set V4 exemptions after roles are initialized
        setIsGlyphTransferExempt(v4router_, true);
        setIsGlyphTransferExempt(v4PositionManager_, true);
        setIsGlyphTransferExempt(v4PoolManager_, true);

        // Set initial URI base
        uriBase = "https://ipfs.io/ipfs/bafybeibepdttbmsyq35xlq2wckfdgiqvdqzxqgx5ssvy7g3ba3r5vazwre/";

        // Mint initial supply to initialMintRecipient_
        _mintERC20(initialMintRecipient_, _maxTotalSupplyERC20);

        // Grant HOOK_CONFIG_ROLE to the designated owner of this contract
        _grantRole(HOOK_CONFIG_ROLE, initialOwner_);
    }

    /// @notice Allows the designated GlyphMintingHook (or any address with MINTER_ROLE)
    /// to mint new tokens.
    /// @param recipient The address to receive the new tokens.
    /// @param amount The amount of ERC20 tokens to mint.
    function mintFromHook(address recipient, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mintERC20(recipient, amount);
    }

    /// @notice Returns the metadata URI for a specific token ID
    /// @dev Implements rarity tiers based on token ID
    /// @param id The token ID to get the URI for
    /// @return The metadata URI string
    function tokenURI(uint256 id) public view override returns (string memory) {
        if (ownerOf(id) == address(0)) revert InvalidTokenId(id);
        
        // Calculate rarity tier (1-5) based on deterministic hash
        uint256 rarity = _calculateRarity(id);
        return string(abi.encodePacked(uriBase, rarity.toString(), ".json"));
    }

    /// @notice Updates the base URI for token metadata
    /// @dev Only callable by contract owner
    /// @param newBase_ The new base URI to set
    function setURIBase(string calldata newBase_) external onlyOwner {
        uriBase = newBase_;
    }

    /// @notice Calculates the rarity tier for a token ID
    /// @dev Internal helper function for tokenURI
    /// @param id The token ID to calculate rarity for
    /// @return The rarity tier (1-5)
    function _calculateRarity(uint256 id) internal pure returns (uint256) {
        uint256 v = uint256(keccak256(abi.encode(id))) % 1000;
        
        if (v < 29) return 5;        // 3%
        if (v < 127) return 4;       // 9.7%
        if (v < 282) return 3;       // 15.5%
        if (v < 531) return 2;       // 24.9%
        return 1;                    // 46.9%
    }

    /// @notice Returns all token IDs owned by an address (staked and unstaked).
    /// @dev Overrides the function to ensure the final contract explicitly chooses an implementation.
    /// @param owner_ The address to query.
    /// @return allOwnedIds Array of all token IDs owned by the address.
    function owned(address owner_) public view override(NGUStaking) returns (uint256[] memory allOwnedIds) {
        return super.owned(owner_);
    }

    /// @notice Implementation of supportsInterface to resolve multiple inheritance
    /// @param interfaceId The interface identifier to check support for
    /// @return bool True if the interface is supported
    function supportsInterface(bytes4 interfaceId) public view virtual override(NGUStaking) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
