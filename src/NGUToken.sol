// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {NGUGlyph} from "./NGUGlyph.sol";

/// @title NGUToken
/// @dev Implementation of the ERC20 token for the NGU project with role-based access control.
///  This contract extends OpenZeppelin's ERC20 and AccessControl implementations.
contract NGUToken is ERC20, AccessControl {
    bytes32 public constant COMPTROLLER_ROLE = keccak256("COMPTROLLER_ROLE");

    NGUGlyph public immutable glyph;

    PoolKey public poolKey;

    /// @dev Emitted when the pool key is updated
    event PoolKeyUpdated(PoolKey key);

    /// @dev Thrown when the caller does not have enough tokens to mint glyphs.
    error InsufficientBalance();

    /// @dev Thrown when the pool key is invalid
    error InvalidPoolKey(address currency0, address currency1);

    /// @dev Constructor that mints the initial supply to the deployer's address and sets up the default admin role.
    /// @param initialSupply The initial supply of tokens to mint.
    constructor(uint256 initialSupply) ERC20("NGU Token", "NGU") {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _mint(_msgSender(), initialSupply * (10 ** uint256(decimals())));

        glyph = new NGUGlyph(_msgSender());
    }

    /// @dev Override decimals to match the standard 18 decimal places used by most ERC20 tokens
    /// @return uint8 The number of decimal places used by the token
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Sets the pool key for Uniswap V4
    /// @param currency0 The address of the first currency in the pool
    /// @param currency1 The address of the second currency in the pool
    /// @param fee The fee for the pool
    /// @param tickSpacing The tick spacing for the pool
    /// @param hooks The hooks for the pool
    function setPoolKey(address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(currency0 < currency1 && (currency0 == address(this) || currency1 == address(this)), InvalidPoolKey(currency0, currency1));
        poolKey.currency0 = Currency.wrap(currency0);
        poolKey.currency1 = Currency.wrap(currency1);
        poolKey.fee = fee;
        poolKey.tickSpacing = tickSpacing;
        poolKey.hooks = IHooks(hooks);
        emit PoolKeyUpdated(poolKey);
    }

    /// @notice Mints missing glyphs for the user
    function mintMissingGlyphs() public {
        (uint256 amount, uint256 fee) = canMintGlyphs(_msgSender());
        require(amount > 0, InsufficientBalance());

        // TODO: collect fee
        _burn(_msgSender(), fee);

        glyph.mintGlyphs(_msgSender(), amount);
    }

    /// @notice Compares the user's token and glyph balances and returns the number of glyphs that can be minted
    /// @param user The address of the user
    /// @return amount The number of glyphs that can be minted
    /// @return fee The fee for minting the glyphs
    function canMintGlyphs(address user) public view returns (uint256 amount, uint256 fee) {
        int256 balanceDiff = _glyphBalanceDiff(user);
        if (balanceDiff > 0) {
            amount = uint256(balanceDiff);
            fee = _calculateGlyphMintFee(amount);

            // Reduce the amount to mint if they cannot afford the fee
            uint256 mintableAmount = (balanceOf(user) - fee) / (10 ** uint256(decimals()));
            if (mintableAmount == 0) {
                return (0, 0);
            } else if (mintableAmount < amount) {
                amount = mintableAmount;
                fee = _calculateGlyphMintFee(mintableAmount);
            }
        }
    }

    /// @dev Calculates the fee for minting glyphs
    /// @param amount The amount of glyphs to mint
    /// @return fee The fee for minting the glyphs
    function _calculateGlyphMintFee(uint256 amount) internal view returns (uint256 fee) {
        fee = amount * (10 ** uint256(decimals())) * poolKey.fee / 100_000;
    }

    /// @dev Compares the user's token and glyph balances and returns the difference
    /// @dev Positive values mean the user has more tokens than glyphs
    /// @param user The address of the user
    /// @return The difference between the user's token and glyph balances
    function _glyphBalanceDiff(address user) public view returns (int256) {
        uint256 expectedBalance = balanceOf(user) / (10 ** uint256(decimals()));
        uint256 glyphBalance = glyph.balanceOf(user);
        return int256(expectedBalance) - int256(glyphBalance);
    }

    /// @dev Override _update to burn glyphs when tokens are transferred.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        // When a user transfers out their tokens, we burn their glyphs
        if (from != address(0)) {
            int256 balanceDiff = _glyphBalanceDiff(from);
            if (balanceDiff < 0) {
                glyph.burnGlyphs(from, uint256(-balanceDiff));
            }
        }
    }
}
