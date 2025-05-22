// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Import necessary interfaces and contracts from Uniswap V4 Core
// Adjust paths based on your dependency installation (e.g., forge install uniswap/v4-core)
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
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
    /// @notice Error when hookData is missing or invalid
    error InvalidHookData();
    /// @notice Error when this hook is called on a pool that does not contain the NumberGoUpToken
    error PoolMissingNGUToken();

    error glyphHookOperationError(string reason);

    // Event to signal a failed glyph operation if we choose not to revert the swap
    event GlyphOperationFailed(address indexed recipient, int256 erc20AmountDelta, string reason);

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
     *      Calculates the NGU token delta for the swap initiator ('sender')
     *      and calls the NGU token contract to adjust glyph balance.
     */
    function _afterSwap(
        address /*sender*/, // The msg.sender to the poolManager's swap/donate
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /*params*/, // Swap parameters (COMMENTED OUT as unused by this hook)
        BalanceDelta delta, // The resulting balance changes
        bytes calldata hookData // Hook data passed by the caller (should be abi.encode(actualUser))
    ) internal override returns (bytes4 magicByte, int128 hookDelta) { 
        // console.log("GlyphMintingHook._afterSwap entered. Sender:", sender); // Debug log
        address recipient;
        // hookData is expected to be the ABI encoded address of the glyph recipient.
        if (hookData.length == 32) {
            recipient = abi.decode(hookData, (address));
        } else {
            // If hookData is not a valid address, revert.
            // Alternative: could default to `sender` if hookData.length == 0, but explicit is safer.
            revert InvalidHookData();
        }
        // console.log("Glyph recipient determined as:", recipient); // Debug log

        int256 NGUAmountDelta;
        address NGUTokenAddress = address(NumberGoUpToken);

        // Determine NGU token delta based on its position (currency0 or currency1) in the PoolKey.
        if (Currency.unwrap(key.currency0) == NGUTokenAddress) {
            NGUAmountDelta = int256(delta.amount0()); // NGU is currency0
        } else if (Currency.unwrap(key.currency1) == NGUTokenAddress) {
            NGUAmountDelta = int256(delta.amount1()); // NGU is currency1
        } else {
            // This should not happen if the hook is correctly associated with NGU pools.
            revert PoolMissingNGUToken();
        }
        // console.log("NGU amount delta for recipient:", NGUAmountDelta); // Debug log

        if (NGUAmountDelta != 0) {
            // console.log("Attempting to mint/burn glyphs for", recipient, "with delta", NGUAmountDelta); // Debug log
            // Attempt to mint/burn glyphs. If this fails, the main swap transaction will still succeed.
            try NumberGoUpToken.mintOrBurnGlyphForSwap(recipient, NGUAmountDelta) {
                // Successfully minted/burned glyphs or no action was needed by the token.
                // console.log("GlyphMintingHook: mintOrBurnGlyphForSwap call successful or no-op by token."); // Optional success log
            } catch Error(string memory reason) {
                // Glyph mint/burn failed in NumberGoUpToken, but we don't revert the main swap.
                // Emitting an event here could be useful for off-chain monitoring of failed glyph operations.
                emit GlyphOperationFailed(recipient, NGUAmountDelta, reason);
                // console.log("GlyphMintingHook: mintOrBurnGlyphForSwap call failed with reason:", reason); // Debug log - Commented due to linter
            } catch (bytes memory /*lowLevelData*/) {
                // Low-level failure during call to NumberGoUpToken, also don't revert the main swap.
                // console.log("GlyphMintingHook: mintOrBurnGlyphForSwap low-level call failed. Data:"); // Debug log - Commented due to linter
                // console.log(abi.encode(lowLevelData)); // Temporarily commented out due to linter issues
            }
        } else {
            // console.log("No NGU delta for recipient; no glyph action taken."); // Debug log
        }

        magicByte = BaseHook.afterSwap.selector;
        hookDelta = 0;
        return (magicByte, hookDelta); // Explicit return for clarity, though named returns would also work.
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