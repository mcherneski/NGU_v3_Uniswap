// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Import necessary interfaces and contracts from Uniswap V4 Core
// Adjust paths based on your dependency installation (e.g., forge install uniswap/v4-core)
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {console2 as console} from 'forge-std/console2.sol';
// Interface for the NumberGoUp token contract (reflecting NGU505Base functions needed by hook)
interface INumberGoUp {
    // Function to notify the token contract about a swap to adjust glyphs
    function mintOrBurnGlyphForSwap(address recipient, int256 erc20AmountDelta) external;
    // Function to get the decimals of the token
    function decimals() external view returns (uint8);
    // Function to get the units per glyph
    function units() external view returns (uint256);
}

/**
 * @title GlyphMintingHook
 * @notice A Uniswap V4 Hook to control the minting of NumberGoUp glyphs.
 * @dev Glyphs are minted only when NumberGoUp tokens are acquired via a swap
 *      in a pool associated with this hook.
 */
contract GlyphMintingHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    /// @notice The NumberGoUp ERC20/505 token contract.
    INumberGoUp public immutable NumberGoUpToken;

    /// @notice Error when the caller is not the Pool Manager
    error OnlyPoolManager();

    constructor(IPoolManager _poolManager, address _NumberGoUpToken) BaseHook(_poolManager) {
        NumberGoUpToken = INumberGoUp(_NumberGoUpToken);
    }

    /**
     * @notice Returns the hook permissions required by this contract.
     * @dev Specifies that we need to hook into `afterSwap`.
     * @return The hook flags.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true, // Only this hook is enabled
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @dev Internal hook function called by the PoolManager after a swap.
     *      Calculates the FTL token delta for the swap initiator ('sender')
     *      and calls the FTL token contract to adjust glyph balance.
     */
    function _afterSwap(
        address sender, // The msg.sender to the poolManager's swap/donate
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /*params*/, // Swap parameters (COMMENTED OUT as unused by this hook)
        BalanceDelta delta, // The resulting balance changes
        bytes calldata hookData // Hook data passed by the caller (should be abi.encode(actualUser))
    ) internal override returns (bytes4 magicByte, int128 hookDelta) { 
        console.log("GlyphMintingHook._afterSwap entered");
        
        address recipient;
        if (hookData.length == 32) { // Basic check for a 32-byte ABI-encoded address
            recipient = abi.decode(hookData, (address));
        } else {
            // Fallback or error if hookData is not as expected
            // For this specific hook, if no user is passed, maybe it defaults to sender or reverts
            // Defaulting to sender for now, but this should be a conscious design decision
            recipient = sender; 
            console.log("Warning: hookData not provided or invalid, defaulting recipient to sender.");
        }

        // address swapper = sender; // We now use recipient derived from hookData or sender as fallback

        // Determine which delta amount corresponds to the FTL token
        // IMPORTANT: This assumes you know which currency (0 or 1) is the FTL token
        int256 ftlAmountDelta;
        address ftlTokenAddress = address(NumberGoUpToken); // Use the correct token variable

        // THIS LOGIC IS CRUCIAL AND DEPENDS ON YOUR POOL SETUP
        if (Currency.unwrap(key.currency0) == ftlTokenAddress) {
            ftlAmountDelta = int256(delta.amount0()); // Correct: call function then cast
        } else if (Currency.unwrap(key.currency1) == ftlTokenAddress) {
            ftlAmountDelta = int256(delta.amount1()); // Correct: call function then cast
        } else {
            // Should not happen if hook is deployed correctly for an FTL pool
            revert("Hook called on pool without FTL token");
        }

        // Only proceed if there was a change in the FTL token balance
        if (ftlAmountDelta != 0) {
            console.log("GlyphMintingHook._afterSwap: Calling mintOrBurnGlyphForSwap for", recipient);
            console.log( "with delta", ftlAmountDelta);
            // Call the NumberGoUp token contract to handle glyph minting/burning based on the swap delta
            // The NumberGoUp contract itself will calculate the required glyph change based on its internal state and this delta
            try NumberGoUpToken.mintOrBurnGlyphForSwap(recipient, ftlAmountDelta) { 
                console.log("GlyphMintingHook._afterSwap: mintOrBurnGlyphForSwap call successful.");
                // Success
            } catch Error(string memory reason) {
                console.log("GlyphMintingHook._afterSwap: mintOrBurnGlyphForSwap call failed:", reason);
                revert(reason);
            } catch (bytes memory lowLevelData) {
                console.logBytes(lowLevelData);
                revert("GlyphMintingHook: Low-level call to mintOrBurnGlyphForSwap failed");
            }
        } else {
            console.log("GlyphMintingHook._afterSwap: No FTL token delta, skipping glyph adjustment.");
        }

        magicByte = BaseHook.afterSwap.selector; // Standard success selector for afterSwap
        hookDelta = 0; // This hook does not request any token delta from the PoolManager
        // return (magicByte, hookDelta); // This is how it would be if not implicitly returned by naming variables
    }

    // --- Other potential hook functions (implement if needed) ---
    // function beforeInitialize(...) ...
    // function afterInitialize(...) ...
    // function beforeModifyPosition(...) ...
    // function afterModifyPosition(...) ...
    // function beforeSwap(...) ...
    // function beforeDonate(...) ...
    // function afterDonate(...) ...
} 