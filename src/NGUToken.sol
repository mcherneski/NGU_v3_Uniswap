// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager, PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCallback} from "@uniswap/v4-periphery/src/base/SafeCallback.sol";
import {NGUGlyph} from "./NGUGlyph.sol";

/// @title NGUToken
/// @dev Implementation of the ERC20 token for the NGU project with role-based access control.
///  This contract extends OpenZeppelin's ERC20 and AccessControl implementations.
contract NGUToken is ERC20, SafeCallback, AccessControl {
    bytes32 public constant COMPTROLLER_ROLE = keccak256("COMPTROLLER_ROLE");

    NGUGlyph public immutable glyph;

    PoolKey internal _poolKey;

    /// @dev Emitted when the pool key is updated
    event PoolKeyUpdated(uint24 _fee, int24 _tickSpacing, IHooks _hooks);

    /// @dev Thrown when the caller does not have enough tokens to mint glyphs.
    error InsufficientBalance();

    /// @dev Constructor that mints the initial supply to the deployer's address and sets up the default admin role.
    /// @param _defaultAdmin The address of the default admin and where the initial supply will be minted.
    /// @param _initialSupply The initial supply of tokens to mint.
    /// @param _poolManager The address of the Uniswap V4 pool manager contract.
    /// @param _glyph The address of the glyph contract.
    constructor(address _defaultAdmin, uint256 _initialSupply, address _poolManager, address _glyph)
        ERC20("NGU Token", "NGU")
        SafeCallback(IPoolManager(_poolManager))
    {
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);

        _mint(_defaultAdmin, _initialSupply * (10 ** uint256(decimals())));

        glyph = NGUGlyph(_glyph);
    }

    /// @dev Override decimals to match the standard 18 decimal places used by most ERC20 tokens
    /// @return uint8 The number of decimal places used by the token
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Returns the pool key
    function getPoolKey() public view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice Sets the pool key for Uniswap V4
    /// @param _fee The fee for the pool
    /// @param _tickSpacing The tick spacing for the pool
    /// @param _hooks The hooks contract for the pool
    function setPoolParams(uint24 _fee, int24 _tickSpacing, IHooks _hooks) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _poolKey.currency1 = Currency.wrap(address(this));
        _poolKey.fee = _fee;
        _poolKey.tickSpacing = _tickSpacing;
        _poolKey.hooks = _hooks;
        emit PoolKeyUpdated(_fee, _tickSpacing, _hooks);
    }

    /// @notice Mints missing glyphs for the user
    /// @param user The address of the user
    function mintMissingGlyphs(address user) public {
        (uint256 amount, uint256 fee) = canMintGlyphs(user);
        require(amount > 0, InsufficientBalance());

        poolManager.unlock(
            abi.encode(
                CallbackData({
                    action: CallbackAction.DONATE,
                    data: abi.encode(CallbackDonateData({from: user, amount: fee}))
                })
            )
        );

        glyph.mintGlyphs(user, amount);
    }

    /// @notice Compares the user's token and glyph balances and returns the number of glyphs that can be minted
    /// @param user The address of the user
    /// @return amount The number of glyphs that can be minted
    /// @return fee The fee for minting the glyphs
    function canMintGlyphs(address user) public view virtual returns (uint256 amount, uint256 fee) {
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
    function _calculateGlyphMintFee(uint256 amount) internal view virtual returns (uint256 fee) {
        fee = amount * (10 ** uint256(decimals())) * _poolKey.fee / 1_000_000;
    }

    /// @dev Compares the user's token and glyph balances and returns the difference
    /// @dev Positive values mean the user has more tokens than glyphs
    /// @param user The address of the user
    /// @return The difference between the user's token and glyph balances
    function _glyphBalanceDiff(address user) internal view virtual returns (int256) {
        uint256 expectedBalance = balanceOf(user) / (10 ** uint256(decimals()));
        uint256 glyphBalance = glyph.balanceOf(user);
        return int256(expectedBalance) - int256(glyphBalance);
    }

    /// @dev Override _update to burn glyphs when tokens are transferred.
    function _update(address from, address to, uint256 value) internal virtual override {
        super._update(from, to, value);

        // When a user transfers out their tokens, we burn their glyphs
        if (from != address(0)) {
            int256 balanceDiff = _glyphBalanceDiff(from);
            if (balanceDiff < 0) {
                glyph.burnGlyphs(from, uint256(-balanceDiff));
            }
        }
    }

    enum CallbackAction {
        DONATE
    }

    struct CallbackData {
        CallbackAction action;
        bytes data;
    }

    struct CallbackDonateData {
        address from;
        uint256 amount;
    }

    error InvalidCallbackAction(uint256 action);
    error InvalidBalanceDelta(int128 amount0, int128 amount1);

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        if (callbackData.action == CallbackAction.DONATE) {
            CallbackDonateData memory donateData = abi.decode(callbackData.data, (CallbackDonateData));
            BalanceDelta delta = poolManager.donate(_poolKey, 0, donateData.amount, "");

            require(delta.amount0() == 0 && delta.amount1() < 0, InvalidBalanceDelta(delta.amount0(), delta.amount1()));

            poolManager.sync(_poolKey.currency1);
            _update(donateData.from, address(poolManager), uint256(int256(-delta.amount1())));
            poolManager.settle();

            return abi.encode(delta);
        }

        revert InvalidCallbackAction(uint256(callbackData.action));
    }
}
