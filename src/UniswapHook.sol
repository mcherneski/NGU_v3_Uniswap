// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {NGUToken} from "./NGUToken.sol";

import {console} from "forge-std/console.sol";

/// @title UniswapHook
/// @notice A Uniswap V4 Hook to control the minting of NumberGoUp glyphs.
/// @dev Glyphs are minted only when NumberGoUp tokens are acquired via a swap
///      in a pool associated with this hook.
contract UniswapHook is BaseHook {
    /// @notice The NumberGoUp ERC20 token contract
    NGUToken public immutable nguToken;

    // Event to signal a failed glyph operation if we choose not to revert the swap
    event GlyphOperationFailed(address recipient, string reason);

    /// @notice Error when hookData is missing or invalid
    error InvalidHookData();

    constructor(IPoolManager _poolManager, NGUToken _nguToken) BaseHook(_poolManager) {
        nguToken = _nguToken;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterSwap = true;
    }

    /// @dev Internal hook function called by the PoolManager after a swap.
    ///  Calculates the NGU token delta for the swap initiator ('sender')
    ///  and calls the NGU token contract to adjust glyph balance.
    function _afterSwap(
        address, // caller,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        require(hookData.length == 32, InvalidHookData());

        if (
            !key.currency0.isAddressZero() // must be ETH
                || Currency.unwrap(key.currency1) != address(nguToken) // must be NGU
                || !swapParams.zeroForOne // only support ETH -> NGU
        ) {
            return (BaseHook.afterSwap.selector, 0);
        }

        address user = abi.decode(hookData, (address));
        if (delta.amount1() > 0) {
            nguToken.mintMissingGlyphsAfterSwap(user, uint256(int256(delta.amount1())));
        }

        return (BaseHook.afterSwap.selector, 0);
    }
}
