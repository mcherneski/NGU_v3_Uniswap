// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// --- Forge Standard Library Imports ---
import {Test} from "forge-std/Test.sol"; // Keep Test for other utilities
import {console2 as console} from "forge-std/console2.sol"; // Use console2 for richer logging

// --- Uniswap V4 Core Imports ---
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol"; // The main interface for interacting with the Pool Manager.
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol"; // Struct defining a unique pool.
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol"; // A condensed identifier for a pool, derived from PoolKey.
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol"; // Represents ERC20 or ETH, used in PoolKey.
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol"; // Interface for hooks contracts.
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol"; // Library for hook flags.
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol"; // Library for tick calculations.
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol"; // Represents the change in two token balances.
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol"; // Interface this contract must implement to receive callbacks from PoolManager.unlock.
// --- Uniswap V4 Periphery Imports ---
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol"; // Utility to find CREATE2 addresses for hooks.
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol"; // For ExactInputSingleParams
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol"; // For V4_SWAP actions

// --- Universal Router Imports ---
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol"; // For UniversalRouter commands

// --- Permit2 Imports ---
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

// --- Local Project Contract Imports ---
// Your Contracts - !! ADJUST PATHS & NAMES IF NEEDED !!
import {GlyphMintingHook} from "../src/GlyphMintingHook.sol"; // The custom hook contract being tested.
import {NumberGoUp} from "../src/NumberGoUp.sol"; // The ERC-404 style token.
import {INGU505Base} from "../src/interfaces/INGU505Base.sol"; // Base interface for the NGU505 token.

// Reverted to direct Solmate import paths, assuming remappings handle it.
import {ERC20} from 'solmate/src/tokens/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';

// Remove MockERC20 if WETH is used exclusively as the other token
// import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol"; 

// It's good practice to explicitly import IERC20 if the interface relies on it.
// Solmate's ERC20.sol does import an IERC20, so this might be implicitly available,
// but explicit import is safer if IWETH9 is defined before ERC20 contract usage.
// Assuming a standard IERC20 interface is accessible, e.g., from Solmate's structure or OpenZeppelin.
// For simplicity here, we'll assume Solmate makes a suitable IERC20 implicitly available or we add an import.
// If using OpenZeppelin: import {@openzeppelin/contracts/token/ERC20/IERC20.sol} for IERC20;

// Interface for WETH9 - Inherit from the imported IERC20
interface IWETH9 is IERC20 { // Renamed back to IWETH9 for simplicity, now that IERC20 is imported
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

// --- Callback Action Definition ---
// Enum to differentiate between actions requested via the unlockCallback.
enum ActionType { MODIFY_LIQUIDITY, SWAP }

// Struct to pass parameters needed for a swap action through the unlock mechanism.
struct SwapCallbackParams {
    PoolKey poolKey; // Identifies the pool to swap in.
    IPoolManager.SwapParams swapParams; // Standard V4 swap parameters (direction, amount, limit).
    address originalSender; // The EOA or contract that initiated the swap request.
}

// Struct to pass parameters needed for a modify liquidity action through the unlock mechanism.
struct ModifyLiquidityCallbackParams {
    PoolKey poolKey; // Identifies the pool to modify liquidity in.
    IPoolManager.ModifyLiquidityParams mlParams; // Standard V4 modify liquidity parameters.
}

/**
 * @title GlyphHookTest
 * @notice Test suite for the GlyphMintingHook integrated with Uniswap V4.
 * @dev This contract inherits from forge-std Test and implements IUnlockCallback
 *      to handle interactions with the Uniswap V4 PoolManager during tests.
 */
contract GlyphHookTest is Test, IUnlockCallback {
    // Apply Uniswap V4 libraries to their respective types.
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // --- State Variables ---
    IPoolManager poolManager; // Instance of the Uniswap V4 PoolManager.
    NumberGoUp ftlToken; // Instance of the FTL token (our ERC404-style token, Currency0).
    GlyphMintingHook hook; // Instance of the custom hook contract.
    IWETH9 weth; // Type updated to IWETH9

    // New state variables for Universal Router and Permit2
    UniversalRouter universalRouter;
    IPermit2 permit2;

    PoolKey poolKey; // The key defining the FTL/Token1 pool with hooks.
    PoolKey swapPoolKey; // The key defining the FTL/Token1 pool without hooks for testing.
    PoolId poolId; // The derived ID of the pool with hooks.

    // --- Test Addresses ---
    address _Admin = makeAddr("Deployer"); // Simulated deployer/admin address.
    address user1 = makeAddr("user1"); // Simulated user address for testing swaps.
    address _InitMintRecipient = makeAddr("InitMintRecipient"); // Placeholder, unused as initial mint goes to `address(this)`.

    // --- Constants ---
    uint256 constant STARTING_USER_WETH = 100 ether; // Renamed from STARTING_USER_TOKEN1
    uint256 constant UNITS = 1 ether; // Unit size for FTL token glyphs (assuming 1e18).

    // WETH9 address for Base Mainnet
    address constant WETH_BASE_MAINNET = 0x4200000000000000000000000000000000000006;

    // Official Addresses (Base Mainnet)
    // PoolManager is already set in setUp from a fixed address
    // address constant POOL_MANAGER_BASE_MAINNET = 0x498581fF718922c3f8e6A244956aF099B2652b2b; // Already used
    address payable constant UNIVERSAL_ROUTER_BASE_MAINNET = payable(0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD); // Verify this!
    IPermit2 constant PERMIT2_BASE_MAINNET = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3); // Common Permit2 address

    // --- Setup Function ---
    /**
     * @notice Sets up the test environment before each test case.
     * @dev Deploys tokens, hook, initializes the pool, and adds initial liquidity.
     */
    function setUp() public {
        // 1. Get PoolManager Instance
        // Replace with the actual deployed PoolManager address on your test network/fork.
        poolManager = IPoolManager(address(0x498581fF718922c3f8e6A244956aF099B2652b2b)); // Base mainnet address
        if (address(poolManager) == address(0)) {
             console.log("WARNING: Using placeholder PoolManager address.");
        }
        console.log("TickMath.MIN_TICK:", TickMath.MIN_TICK);
        console.log("TickMath.MAX_TICK:", TickMath.MAX_TICK);
        console.log("TickMath.minUsableTick(60):", TickMath.minUsableTick(60));
        console.log("TickMath.maxUsableTick(60):", TickMath.maxUsableTick(60));

        // Initialize WETH instance
        weth = IWETH9(WETH_BASE_MAINNET);
        console.log("Using WETH at:", address(weth));

        // Initialize UniversalRouter and Permit2 instances
        universalRouter = UniversalRouter(UNIVERSAL_ROUTER_BASE_MAINNET);
        permit2 = PERMIT2_BASE_MAINNET;

        // 2. Deploy FTL Token (ERC-404 Style)
        // Deploys the NumberGoUp token, setting initial parameters and ownership.
        // Mint initial supply to address(this) for direct liquidity provision.
        ftlToken = new NumberGoUp(
            "NumberGoUp",           // 1: name_
            "FTL",                      // 2: symbol_
            18,                         // 3: decimals_
            UNITS,                      // 4: units_
            1_000_000 * UNITS,          // 5: maxTotalSupplyERC20_
            _Admin,                     // 6: initialOwner_ (Keep _Admin as owner for other purposes if any)
            address(this),              // 7: initialMintRecipient_ (address(this) gets initial supply)
            address(0x6fF5693b99212Da76ad316178A184AB56D299b43), // 8: v4router_ (Example, adjust if needed)
            address(0x7C5f5A4bBd8fD63184577525326123B519429bDc), // 9: v4PositionManager_ (Example, adjust if needed)
            address(poolManager)        // 10: v4PoolManager_
        );
        console.log("FTL Token deployed at:", address(ftlToken));
        console.log("FTL balance of address(this) post-deploy:", ftlToken.balanceOf(address(this)));

        // 3. Deploy Hook using HookMiner and CREATE2
        // Hooks need specific flags set. Here, only AFTER_SWAP is relevant for the hook logic.
        uint160 flagsBitmap = Hooks.AFTER_SWAP_FLAG;
        bytes memory constructorArgs = abi.encode(poolManager, address(ftlToken));

        // HookMiner finds a salt that results in a hook address with the required flags (least significant bits).
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), flagsBitmap, type(GlyphMintingHook).creationCode, constructorArgs);

        // Deploy the hook using the calculated salt.
        hook = new GlyphMintingHook{salt: salt}(poolManager, address(ftlToken));
        console.log("Hook deployed at:", address(hook), "Expected:", hookAddress);
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Authorize the hook to call mintGlyphFromHook on ftlToken
        vm.startPrank(_Admin);
        ftlToken.setGlyphMintingHookAddress(address(hook));
        vm.stopPrank();
        console.log("GlyphMintingHook address set on FTL token by _Admin.");

        // Mint FTL to address(this) for liquidity provision
        // This was implicitly done by making address(this) the initialMintRecipient
        // console.log("FTL balance of address(this) post-deploy:", ftlToken.balanceOf(address(this)));

        // address(this) needs WETH to provide liquidity for the WETH/FTL pool
        uint256 wethForInitialLiquidity = 5 ether; // Arbitrary amount, ensure it's enough
        vm.deal(address(this), wethForInitialLiquidity); // Give ETH to this contract
        weth.deposit{value: wethForInitialLiquidity}(); // This contract deposits ETH for WETH
        console.log("address(this) WETH balance for liquidity provision:", weth.balanceOf(address(this)));

        // User1 needs ETH to deposit for WETH for their own test swaps later
        vm.deal(user1, STARTING_USER_WETH + 1 ether); // Give enough for WETH and some gas
        vm.startPrank(user1);
        weth.deposit{value: STARTING_USER_WETH}();
        vm.stopPrank();
        console.log("User1 WETH balance after deposit:", weth.balanceOf(user1));

        // NEW: User1 approves Permit2 for WETH, then Permit2 approves UniversalRouter
        // This amount should cover the planned swap amount.
        uint256 wethAmountForSwapApproval = 10 ether; // Matches the amount in test_MintGlyph_On_ReceiveFTL
        
        vm.startPrank(user1);
        console.log("User1 approving Permit2 for WETH amount:", _uintToString(wethAmountForSwapApproval));
        weth.approve(address(permit2), wethAmountForSwapApproval); 
        
        uint48 permit2Expiration = uint48(block.timestamp + 1 hours);
        console.log("User1 calling Permit2.approve for UniversalRouter for WETH amount:", _uintToString(wethAmountForSwapApproval));
        permit2.approve(
            address(weth),                      // token
            address(universalRouter),           // spender
            uint160(wethAmountForSwapApproval), // amount (Permit2 uses uint160)
            permit2Expiration                   // expiration
        );
        vm.stopPrank();
        console.log("Permit2 approvals for User1 completed.");

        // 6. Define Pool Keys
        // PoolKey requires currencies sorted by address.
        address token0Addr;
        address token1Addr;
        
        if (address(weth) < address(ftlToken)) {
            token0Addr = address(weth);        // WETH
            token1Addr = address(ftlToken);      // FTL
            console.log("PoolKey Config: WETH is currency0, FTL is currency1.");
        } else {
            // This case should ideally not be hit if WETH_BASE_MAINNET address is low.
            console.log("CRITICAL WARNING: FTL address is lower than WETH address.");
            token0Addr = address(ftlToken);      // FTL
            token1Addr = address(weth);        // WETH
            console.log("PoolKey Config: FTL is currency0, WETH is currency1. (This is not the desired order)");
            revert("WETH address was not less than FTL token address. Cannot guarantee WETH as currency0.");
        }
        // Use the specific flag constant in the PoolKey's hooks field
        poolKey = PoolKey({
            currency0: Currency.wrap(token0Addr), // Expected WETH
            currency1: Currency.wrap(token1Addr), // Expected FTL
            fee: 3000, // Standard fee tier (0.3%)
            tickSpacing: 60, // Standard tick spacing for 0.3% fee
            // Cast the specific flag to address, then to IHooks
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId(); // Get the PoolId for the hooked pool
        // Pool key without any hooks for isolated swap testing
        swapPoolKey = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: poolKey.fee, // Same fee
            tickSpacing: poolKey.tickSpacing, // Same tickSpacing
            hooks: IHooks(address(0)) // NO HOOKS
        });

        // Give the test contract ETH for gas fees.
        vm.deal(address(this), 10 ether);
        // Give _Admin ETH for gas fees if it needs to sign transactions (like approvals and initializations).
        vm.deal(_Admin, 1 ether);

        // 7. Initialize Pools & Add Initial Liquidity (as _Admin)
        // The pool must be initialized before any swaps or liquidity modifications.
        // We initialize it slightly above the minimum usable tick.
        int24 tickForPrice = 0; // New, more central price. Tick 0 is multiple of tickSpacing 60.
        uint160 initialSqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickForPrice);

        vm.startPrank(_Admin); // _Admin initializes both pools
        console.log("About to initialize hooked pool (caller: _Admin)...");
        poolManager.initialize{gas: 10_000_000}(poolKey, initialSqrtPriceX96);
        console.log("Hooked pool initialized successfully.");

        console.log("About to initialize hookless swapPoolKey (caller: _Admin)...");
        poolManager.initialize{gas: 10_000_000}(swapPoolKey, initialSqrtPriceX96);
        console.log("Hookless swapPoolKey initialized successfully.");

        // --- _Admin's role ends after initialization ---
        vm.stopPrank(); 

        // --- address(this) provides initial liquidity to swapPoolKey via unlock ---

        // Define Liquidity Parameters (ensure ticks are defined based on tickForPrice from Admin section)
        int24 currentPoolTick = tickForPrice;
        /* START TEMPORARY SIMPLIFIED TICK LOGIC FOR DEBUGGING
        int24 lowerTickModify = currentPoolTick - (5 * swapPoolKey.tickSpacing);
        int24 upperTickModify = currentPoolTick + (5 * swapPoolKey.tickSpacing);

        if (lowerTickModify < TickMath.minUsableTick(swapPoolKey.tickSpacing)) {
            lowerTickModify = TickMath.minUsableTick(swapPoolKey.tickSpacing);
        }
        if (upperTickModify > TickMath.maxUsableTick(swapPoolKey.tickSpacing)) {
            upperTickModify = TickMath.maxUsableTick(swapPoolKey.tickSpacing);
        }
        if (lowerTickModify >= upperTickModify) { // Ensure lower < upper
            lowerTickModify = currentPoolTick - swapPoolKey.tickSpacing;
            upperTickModify = currentPoolTick + swapPoolKey.tickSpacing;
            if (lowerTickModify < TickMath.minUsableTick(swapPoolKey.tickSpacing)) lowerTickModify = TickMath.minUsableTick(swapPoolKey.tickSpacing);
            if (upperTickModify > TickMath.maxUsableTick(swapPoolKey.tickSpacing)) upperTickModify = TickMath.maxUsableTick(swapPoolKey.tickSpacing);
            require(lowerTickModify < upperTickModify, "Could not form valid narrow tick range for swapPoolKey");
        }
        */

        // TEMPORARY SIMPLIFIED TICK LOGIC FOR DEBUGGING
        console.log("Using simplified tick logic for initial liquidity with currentPoolTick:", _int24ToString(currentPoolTick));
        int24 lowerTickModify = currentPoolTick - poolKey.tickSpacing; 
        int24 upperTickModify = currentPoolTick + poolKey.tickSpacing; 

        // Ensure ticks are within usable bounds and multiples of tickSpacing
        // (This re-clamping is similar to what's in the more complex block)
        if (lowerTickModify < TickMath.minUsableTick(poolKey.tickSpacing)) {
            lowerTickModify = TickMath.minUsableTick(poolKey.tickSpacing);
        }
        if (upperTickModify > TickMath.maxUsableTick(poolKey.tickSpacing)) {
            upperTickModify = TickMath.maxUsableTick(poolKey.tickSpacing);
        }
        // If clamping made lower >= upper (e.g. currentPoolTick is at min/maxUsableTick), adjust.
        // This specific case might need more thought if currentPoolTick is exactly minUsableTick or maxUsableTick.
        // For now, let's assume currentPoolTick is not at the absolute edge.
        if (lowerTickModify >= upperTickModify) {
            // This should ideally not happen with currentPoolTick = minUsableTick + tickSpacing
            // but as a fallback, create a minimal valid range if it does.
            lowerTickModify = TickMath.minUsableTick(poolKey.tickSpacing);
            upperTickModify = lowerTickModify + poolKey.tickSpacing; // Ensure upper is at least one tickSpacing above lower
            if (upperTickModify > TickMath.maxUsableTick(poolKey.tickSpacing)) { // Should not happen if lower started at minUsable
                 revert("Cannot form valid tick range even with simplification");
            }
        }
        require(lowerTickModify < upperTickModify, "Simplified tick range is invalid");
        require(lowerTickModify % poolKey.tickSpacing == 0, "Simplified lowerTick not multiple of spacing");
        require(upperTickModify % poolKey.tickSpacing == 0, "Simplified upperTick not multiple of spacing");
        console.log("Simplified lowerTickModify:", _int24ToString(lowerTickModify));
        console.log("Simplified upperTickModify:", _int24ToString(upperTickModify));
        // END TEMPORARY SIMPLIFIED TICK LOGIC

        IPoolManager.ModifyLiquidityParams memory mlParamsForUnlock = IPoolManager.ModifyLiquidityParams({
            tickLower: lowerTickModify,
            tickUpper: upperTickModify,
            liquidityDelta: int256(1_000 * UNITS),
            salt: bytes32(0)
        });

        // address(this) approves PoolManager for FTL and Token1
        console.log("Approving PoolManager for FTL by address(this)...");
        ftlToken.approve(address(poolManager), type(uint256).max);
        console.log("Approving PoolManager for WETH by address(this)..."); // Changed from Token1
        weth.approve(address(poolManager), type(uint256).max); // Changed from token1

        // Encode data for unlockCallback
        ModifyLiquidityCallbackParams memory mlCallbackParams = ModifyLiquidityCallbackParams({
            poolKey: poolKey, // Target the *hooked* pool for initial liquidity
            mlParams: mlParamsForUnlock
        });
        bytes memory encodedMLCallbackParams = abi.encode(mlCallbackParams);
        bytes memory modifyLiquidityActionData = abi.encode(ActionType.MODIFY_LIQUIDITY, encodedMLCallbackParams);

        console.log("address(this) calling poolManager.unlock for initial MODIFY_LIQUIDITY on hooked pool (poolKey)...");
        try poolManager.unlock(modifyLiquidityActionData) returns (bytes memory result) {
            console.log("Initial modifyLiquidity unlock call finished successfully.");
            if (result.length != 0) {
                console.log("Warning: Initial modifyLiquidity unlock callback returned non-empty data.");
            }
        } catch Error(string memory reason) {
            console.log(string(abi.encodePacked("Initial modifyLiquidity unlock call failed (Error): ", reason)));
            revert(reason);
        } catch (bytes memory lowLevelData) {
            console.log("Initial modifyLiquidity unlock call failed (LowLevel)");
            if (lowLevelData.length == 4) {
                 bytes4 selector = bytes4(lowLevelData);
                 console.log("LowLevel Revert Selector (Initial ML Unlock):", _bytes4ToString(selector));
                 revert(string(abi.encodePacked("LowLevel revert during initial ML unlock with selector: ", _bytes4ToString(selector))));
            } else {
                revert("LowLevel revert during initial ML unlock");
            }
        }
    }

    // --- Unlock Callback Implementation ---
    /**
     * @notice Handles callbacks from PoolManager.unlock.
     * @dev This function is called by the PoolManager when this contract calls `poolManager.unlock(data)`.
     *      It decodes the requested action (MODIFY_LIQUIDITY or SWAP) and performs the necessary operations.
     *      Crucially, it handles the settlement of token balances with the PoolManager.
     * @param data The ABI-encoded data originally passed to `poolManager.unlock()`.
     *             Expected format: abi.encode(ActionType, abi.encode(ActionParams))
     * @return bytes memory An empty bytes array, as required by the callback pattern.
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        console.log("Entered unlockCallback.");
        // Security check: Ensure the caller is the PoolManager.
        require(msg.sender == address(poolManager), "Callback not from PoolManager");

        // Decode the primary action type and the rest of the data containing specific parameters.
        (ActionType action, bytes memory actionData) = abi.decode(data, (ActionType, bytes));

        // --- Handle MODIFY_LIQUIDITY Action ---
        if (action == ActionType.MODIFY_LIQUIDITY) {
            // Decode the specific parameters for modifying liquidity.
            ModifyLiquidityCallbackParams memory mlCallbackParams = abi.decode(actionData, (ModifyLiquidityCallbackParams));
            console.log("unlockCallback: MODIFY_LIQUIDITY Action");
            console.log("unlockCallback: Target PoolKey currency0:", Currency.unwrap(mlCallbackParams.poolKey.currency0));
            console.log("unlockCallback: Target PoolKey currency1:", Currency.unwrap(mlCallbackParams.poolKey.currency1));
            console.log("unlockCallback: Target PoolKey fee:", mlCallbackParams.poolKey.fee);
            console.log("unlockCallback: Target PoolKey tickSpacing:", mlCallbackParams.poolKey.tickSpacing);
            console.log("unlockCallback: Target PoolKey hooks:", address(mlCallbackParams.poolKey.hooks));
            console.log("unlockCallback: mlParams.tickLower:", mlCallbackParams.mlParams.tickLower);
            console.log("unlockCallback: mlParams.tickUpper:", mlCallbackParams.mlParams.tickUpper);
            console.log("unlockCallback: mlParams.liquidityDelta:", mlCallbackParams.mlParams.liquidityDelta);
            console.log("Attempting MODIFY_LIQUIDITY with LiquidityDelta:", mlCallbackParams.mlParams.liquidityDelta);

            BalanceDelta callbackCallerDelta; // BalanceDelta is an int256 alias
            BalanceDelta callbackFeesAccrued; // BalanceDelta is an int256 alias

            // Call modifyLiquidity within a try/catch block to handle potential reverts.
            // Use the poolKey specified in mlCallbackParams.
            try poolManager.modifyLiquidity(mlCallbackParams.poolKey, mlCallbackParams.mlParams, bytes("")) returns (BalanceDelta delta, BalanceDelta fees) {
                callbackCallerDelta = delta;
                callbackFeesAccrued = fees;
                // Log the deltas returned by the PoolManager.
                // callbackCallerDelta represents the net change to *this* contract's balance with the PoolManager.
                // Use BalanceDeltaLibrary to access amounts
                console.log(string(abi.encodePacked("Callback CallerDelta0: ", _int128ToString(callbackCallerDelta.amount0()))));
                console.log(string(abi.encodePacked("Callback CallerDelta1: ", _int128ToString(callbackCallerDelta.amount1()))));
                console.log(string(abi.encodePacked("Callback FeesAccrued0: ", _int128ToString(callbackFeesAccrued.amount0()))));
                console.log(string(abi.encodePacked("Callback FeesAccrued1: ", _int128ToString(callbackFeesAccrued.amount1()))));

                // --- Settlement Logic for Modify Liquidity ---
                // The goal is to ensure this contract's balance delta with the PoolManager is zero for both currencies.
                if (mlCallbackParams.mlParams.liquidityDelta == 0) { // Poking (liquidityDelta is zero)
                    // A poke might result in collecting fees (positive delta).
                    console.log("Processing poke result.");
                    // Use BalanceDeltaLibrary to access amounts
                    if (callbackCallerDelta.amount0() > 0) { // Pool owes us token0 (fees)
                        uint256 amountToTake = uint256(uint128(callbackCallerDelta.amount0()));
                        console.log(string(abi.encodePacked("Poke: Taking token0: ", _uintToString(amountToTake))));
                        poolManager.take(mlCallbackParams.poolKey.currency0, address(this), amountToTake);
                    }
                    if (callbackCallerDelta.amount1() > 0) { // Pool owes us token1 (fees)
                        uint256 amountToTake = uint256(uint128(callbackCallerDelta.amount1()));
                        console.log(string(abi.encodePacked("Poke: Taking token1: ", _uintToString(amountToTake))));
                        poolManager.take(mlCallbackParams.poolKey.currency1, address(this), amountToTake);
                    }
                    // Negative delta during poke is unexpected.
                    if (callbackCallerDelta.amount0() < 0 || callbackCallerDelta.amount1() < 0) {
                        console.log("ERROR: Negative delta during poke! This should not happen.");
                        // This is an error condition, should probably revert or log heavily.
                    }
                } else { // Adding or removing liquidity
                    // If this contract owes tokens (negative delta), transfer them to the PoolManager.
                    // If the PoolManager owes tokens (positive delta), take them.
                    // Use BalanceDeltaLibrary to access amounts
                    if (callbackCallerDelta.amount0() < 0) { // Owe token0
                        uint256 amountOwed = uint256(uint128(-callbackCallerDelta.amount0()));
                        console.log(string(abi.encodePacked("ML Callback: Owe token0: ", _uintToString(amountOwed))));
                        poolManager.sync(mlCallbackParams.poolKey.currency0);
                        ERC20(Currency.unwrap(mlCallbackParams.poolKey.currency0)).transfer(address(poolManager), amountOwed);
                        poolManager.settle();
                    } else if (callbackCallerDelta.amount0() > 0) { // Pool owes token0
                        uint256 amountToTake = uint256(uint128(callbackCallerDelta.amount0()));
                        console.log(string(abi.encodePacked("ML Callback: Taking token0: ", _uintToString(amountToTake))));
                        poolManager.take(mlCallbackParams.poolKey.currency0, address(this), amountToTake);
                    }

                    // Use BalanceDeltaLibrary to access amounts
                    if (callbackCallerDelta.amount1() < 0) { // Owe token1
                        uint256 amountOwed = uint256(uint128(-callbackCallerDelta.amount1()));
                        console.log(string(abi.encodePacked("ML Callback: Owe token1: ", _uintToString(amountOwed))));
                        poolManager.sync(mlCallbackParams.poolKey.currency1);
                        ERC20(Currency.unwrap(mlCallbackParams.poolKey.currency1)).transfer(address(poolManager), amountOwed);
                        poolManager.settle();
                    } else if (callbackCallerDelta.amount1() > 0) { // Pool owes token1
                        uint256 amountToTake = uint256(uint128(callbackCallerDelta.amount1()));
                        console.log(string(abi.encodePacked("ML Callback: Taking token1: ", _uintToString(amountToTake))));
                        poolManager.take(mlCallbackParams.poolKey.currency1, address(this), amountToTake);
                    }
                }
            } catch Error(string memory reason) {
                // Log and re-throw or handle the error from modifyLiquidity.
                console.log(string(abi.encodePacked("unlockCallback.modifyLiquidity failed: ", reason)));
                revert(reason); // Propagate the error
            } catch (bytes memory lowLevelData) {
                 bytes4 selector = bytes4(lowLevelData);
                 console.log("Revert selector from unlockCallback.modifyLiquidity is:");
                 console.logBytes4(selector);
                 revert("unlockCallback.modifyLiquidity failed with low-level data");
            }
        }
        // --- Handle SWAP Action ---
        else if (action == ActionType.SWAP) {
            // Decode the specific parameters for a swap.
            SwapCallbackParams memory scParams = abi.decode(actionData, (SwapCallbackParams));
            console.log("Attempting SWAP action.");
            console.log(string(abi.encodePacked("Swap using PoolKey hooks: ", address(scParams.poolKey.hooks)))); // Log which pool key is used
            console.log(string(abi.encodePacked("Swap zeroForOne: ", scParams.swapParams.zeroForOne ? "true" : "false")));
            console.log(string(abi.encodePacked("Swap amountSpecified: ", _int256ToString(scParams.swapParams.amountSpecified))));
            
            Currency currencyIn; // The token being sold.
            Currency currencyOut; // The token being bought.
            uint256 amountToPayToPoolManager; // For exact input swaps.

            // Determine input/output currencies based on swap direction.
            if (scParams.swapParams.zeroForOne) { // Selling currency0 for currency1
                currencyIn = scParams.poolKey.currency0;
                currencyOut = scParams.poolKey.currency1;
            } else { // Selling currency1 for currency0
                currencyIn = scParams.poolKey.currency1;
                currencyOut = scParams.poolKey.currency0;
            }

            // --- Handle Input Payment (for Exact Input Swaps) ---
            // If amountSpecified is negative, it's an exact input swap.
            // This contract (address(this)) needs to pay the input amount to the PoolManager.
            if (scParams.swapParams.amountSpecified < 0) {
                amountToPayToPoolManager = uint256(-scParams.swapParams.amountSpecified); // Note: Solidity 0.8 handles underflow.
                console.log(string(abi.encodePacked("Exact input: Paying to PoolManager: ", _uintToString(amountToPayToPoolManager), " of tokenIn")));
                
                // Pay the input amount: sync, transfer. Do NOT settle here.
                // The final swapDelta should account for this payment.
                poolManager.sync(currencyIn); // Record PM balance BEFORE transfer.
                ERC20(Currency.unwrap(currencyIn)).transfer(address(poolManager), amountToPayToPoolManager); // This contract pays PM.
                console.log("Payment transferred to PoolManager for swap input."); // Updated log
            }
            // Note: Exact output swaps (amountSpecified > 0) are not fully handled here regarding payment.

            // --- Perform the Swap ---
            // Call poolManager.swap. This can also trigger hooks (like our GlyphMintingHook if scParams.poolKey has hooks).
            // Pass hookData containing the original sender. The GlyphMintingHook must be designed to parse this.
            bytes memory hookDataForSwap = abi.encode(scParams.originalSender);
            BalanceDelta swapDelta = poolManager.swap(scParams.poolKey, scParams.swapParams, hookDataForSwap);
            console.log(string(abi.encodePacked("Swap executed. Delta0: ", _int128ToString(swapDelta.amount0()), ", Delta1: ", _int128ToString(swapDelta.amount1()))));

            // --- Settlement/Take based on swapDelta --- 
            // swapDelta represents the change to *this* contract's balance resulting from the swap itself (including fees, slippage difference).

            // Settle any amount WE (address(this)) owe the pool due to the swap itself.
            if (swapDelta.amount0() < 0) { // We owe token0 from swap
                uint256 owe0 = uint256(uint128(-swapDelta.amount0())); // Safe conversion
                console.log(string(abi.encodePacked("Swap Delta Settlement: Owe token0: ", _uintToString(owe0))));
                poolManager.sync(scParams.poolKey.currency0);
                ERC20(Currency.unwrap(scParams.poolKey.currency0)).transfer(address(poolManager), owe0); 
                poolManager.settle();
            }
            if (swapDelta.amount1() < 0) { // We owe token1 from swap
                uint256 owe1 = uint256(uint128(-swapDelta.amount1())); // Safe conversion
                 console.log(string(abi.encodePacked("Swap Delta Settlement: Owe token1: ", _uintToString(owe1))));
                poolManager.sync(scParams.poolKey.currency1);
                ERC20(Currency.unwrap(scParams.poolKey.currency1)).transfer(address(poolManager), owe1); 
                poolManager.settle();
            }

            // Take any amount the pool owes US (address(this)) due to the swap (the output amount).
            // Send it to this contract (address(this)) first to ensure the delta is cleared correctly.
            // The test case will then forward it to the original sender (user1).
            if (swapDelta.amount0() > 0) { // Pool owes us token0
                uint256 take0 = uint256(uint128(swapDelta.amount0())); // Safe conversion
                console.log(string(abi.encodePacked("Swap Delta Take: Taking token0: ", _uintToString(take0), " to address(this)")));
                poolManager.take(scParams.poolKey.currency0, address(this), take0); // Take to this contract
            }
            if (swapDelta.amount1() > 0) { // Pool owes us token1
                uint256 take1 = uint256(uint128(swapDelta.amount1())); // Safe conversion
                console.log(string(abi.encodePacked("Swap Delta Take: Taking token1: ", _uintToString(take1), " to address(this)")));
                poolManager.take(scParams.poolKey.currency1, address(this), take1); // Take to this contract
            }
             console.log("Exiting unlockCallback after SWAP operations.");
        }
        
       // console.log("Exiting unlockCallback."); // Commented out as it might be confusing if reached after error handling in try/catch
        return bytes(""); // Callback must return bytes memory.
    }

    // --- Helper Functions ---

    /**
     * @notice Converts uint256 to string.
     * @dev Basic implementation for logging.
     */
    function _uintToString(uint256 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /**
     * @notice Converts bytes4 (e.g., function selector, error selector) to hex string.
     * @dev Useful for logging revert selectors.
     */
    function _bytes4ToString(bytes4 _bytes) private pure returns (string memory) {
        bytes memory hexChars = new bytes(8);
        for (uint i = 0; i < 4; i++) {
            uint8 b = uint8(_bytes[i]);
            uint8 val1 = b >> 4; // High nibble
            uint8 val2 = b & 0x0F; // Low nibble
            hexChars[i*2] = _valToHexChar(val1);
            hexChars[i*2+1] = _valToHexChar(val2);
        }
        return string.concat("0x", string(hexChars));
    }

    /**
     * @notice Converts a nibble (0-15) to its hex character representation.
     */
    function _valToHexChar(uint8 val) private pure returns (bytes1) {
        if (val < 10) {
            return bytes1(uint8(48 + val)); // 0-9
        } else {
            return bytes1(uint8(97 + (val - 10))); // a-f (ASCII 'a' is 97)
        }
    }

    /**
     * @notice Converts int128 to string.
     * @dev Handles negative numbers and zero.
     */
    function _int128ToString(int128 value) private pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        bytes memory buffer;
        bool isNegative = value < 0;
        // Convert to positive uint128 for digit extraction.
        // Note: int128 min value negation overflows, handled as edge case later.
        uint128 tempValue = isNegative ? uint128(-value) : uint128(value);
        
        // Count digits.
        uint256 numDigits = 0;
        uint128 temp = tempValue;
        if (temp == 0 && value != 0) { // Check if original was int128 min
             if (isNegative) numDigits = 39; // Special case for int128 min length
             else numDigits = 1; // Should not happen if value != 0
        } else if (temp == 0) {
             numDigits = 1; // For the case value = 0
        } else {
            while (temp != 0) {
                numDigits++;
                temp /= 10;
            }
        }
        
        // Allocate buffer size (add 1 for sign if negative).
        if (isNegative) {
            buffer = new bytes(numDigits + 1);
            buffer[0] = '-';
        } else {
            buffer = new bytes(numDigits);
        }
        
        // Fill buffer from right to left.
        uint256 i = buffer.length;
        // Use original tempValue again for digit extraction.
        temp = isNegative ? uint128(-value) : uint128(value);
        if (value == 0) {
            if(buffer.length > 0) buffer[0] = '0';
        } else if (value == type(int128).min) {
            // Handle int128 minimum specifically as -value overflows.
            return "-170141183460469231731687303715884105728";
        } else {
             while (temp != 0) {
                 i--;
                 buffer[i] = bytes1(uint8(48 + temp % 10));
                 temp /= 10;
             }
        }

        return string(buffer);
    }

    /**
     * @notice Converts int24 to string via int256.
     */
    function _int24ToString(int24 value) private pure returns (string memory) {
        return _int256ToString(int256(value));
    }

    /**
     * @notice Converts int256 to string.
     * @dev Handles negative numbers and zero, including int256 min.
     */
    function _int256ToString(int256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        bytes memory buffer;
        bool isNegative = value < 0;
        // Use absolute value for digit calculation, handle min value separately.
        uint256 tempValue = value == type(int256).min ? type(uint256).max / 2 + 1 : (value < 0 ? uint256(-value) : uint256(value));
        
        uint256 numDigits = 0;
        uint256 temp = tempValue;
        if (temp == 0) numDigits = 1; // for 0 case
        else while (temp != 0) { numDigits++; temp /= 10; }

        // Allocate buffer
        if (isNegative) {
            buffer = new bytes(numDigits + 1);
            buffer[0] = '-';
        } else {
            buffer = new bytes(numDigits);
        }
        
        // Fill buffer
        uint256 i = buffer.length;
         if (value == type(int256).min) {
             // Handle int256 minimum specifically
            return "-57896044618658097711785492504343953926634992332820282019728792003956564819968";
        }
         if (value == 0) {
             if(buffer.length > 0) buffer[isNegative?1:0] = '0';
         } else {
            temp = tempValue; // Use abs value again
            while (temp != 0) {
                i--;
                buffer[i] = bytes1(uint8(48 + temp % 10));
                temp /= 10;
            }
        }
        return string(buffer);
    }

    // --- Test Cases ---

    /**
     * @notice Tests that swapping token1 for FTL results in the user receiving FTL
     *         and potentially minting a glyph via the afterSwap hook.
     */
    function test_MintGlyph_On_Receive_FTL() public {
        // Arrange
        uint256 wethSwapAmount = 10 ether; // User1 will sell 10 WETH
        uint256 initialFTL_ERC20_Balance_User = ftlToken.balanceOf(user1);
        uint256 initialGlyphBalance_User = ftlToken.glyphBalanceOf(user1);
        assertEq(initialGlyphBalance_User, 0, "User should start with 0 glyphs");
        assertEq(initialFTL_ERC20_Balance_User, 0, "User should start with 0 ERC20s");

        // User1 has already approved Permit2 for WETH in setUp,
        // and Permit2 has approved UniversalRouter for WETH.

        console.log("Test contract executing swap via UniversalRouter (User sells WETH for FTL)...");

        // Determine swap direction and price limits
        bool zeroForOne; // True if selling currency0 for currency1
        uint160 sqrtPriceLimitX96;
        Currency currencyIn;
        Currency currencyOut;

        if (Currency.unwrap(poolKey.currency0) == address(weth)) { // WETH is currency0
            zeroForOne = true; // Selling WETH (curr0) for FTL (curr1)
            sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1; // Limit for selling curr0
            currencyIn = poolKey.currency0;
            currencyOut = poolKey.currency1;
            console.log("Swap Direction: User sells WETH (currency0) for FTL (currency1). zeroForOne = true.");
        } else { // FTL is currency0 (WETH is currency1)
            // This case should have been reverted in setUp if WETH wasn't currency0
            zeroForOne = false; // Selling WETH (curr1) for FTL (curr0)
            sqrtPriceLimitX96 = TickMath.MAX_SQRT_PRICE - 1; // Limit for selling curr1
            currencyIn = poolKey.currency1;
            currencyOut = poolKey.currency0;
            console.log("Swap Direction: User sells WETH (currency1) for FTL (currency0). zeroForOne = false.");
        }

        // 1. Encode Universal Router Command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // 2. Encode V4Router Actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL), // Ensure input tokens are paid by Permit2
            uint8(Actions.TAKE_ALL)   // Collect output tokens to this contract
        );

        // 3. Prepare Parameters for each action
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey, // Use the hooked pool
                zeroForOne: zeroForOne,
                amountIn: uint128(wethSwapAmount), // amount of WETH user1 is swapping
                amountOutMinimum: 0, // We are not testing slippage here primarily
                hookData: abi.encode(user1) // Pass user1 as recipient for glyphs
            })
        );
        // SETTLE_ALL: Specify input token (WETH) and amount.
        // Permit2 will handle pulling this from user1.
        params[1] = abi.encode(Currency.unwrap(currencyIn), wethSwapAmount);

        // TAKE_ALL: Specify output token (FTL) and minimum amount (0 for simplicity).
        // This contract (address(this)) will receive the FTL.
        params[2] = abi.encode(Currency.unwrap(currencyOut), 0);


        // 4. Combine actions and params into inputs for Universal Router
        inputs[0] = abi.encode(actions, params);

        // 5. Execute the swap via Universal Router
        uint256 deadline = block.timestamp + 60; // 1 minute deadline

        uint256 ftlBalanceOfTestContractBeforeSwap = ftlToken.balanceOf(address(this));
        
        // The UniversalRouter needs to be called by user1, as user1 is the one whose
        // tokens are being spent via Permit2.
        // Or, if this contract is the msg.sender to UniversalRouter, then Permit2 must
        // allow *this contract* to spend user1's tokens (more complex Permit2 setup).
        // The simpler way for testing is for user1 to call execute.
        // However, the current Permit2 approval in setUp is:
        // user1 -> weth.approve(permit2, amount)
        // user1 -> permit2.approve(weth, universalRouter, amount, expiration)
        // This means UniversalRouter can pull WETH from user1 *when user1 is the ultimate beneficiary/initiator*.
        // If `address(this)` calls `universalRouter.execute`, UR might not have the right context
        // to use user1's Permit2 allowance unless `msg.sender` for UR matches the Permit2 approver
        // or a more complex permit is used (e.g. permit on behalf of).

        // For simplicity, we assume `address(this)` can trigger the swap with user1's Permit2 allowance.
        // The Universal Router's `execute` is payable if ETH is involved in commands, not for V4_SWAP with ERC20s.
        console.log("Pranking as user1 to call universalRouter.execute...");
        vm.startPrank(user1);
        try universalRouter.execute(commands, inputs, deadline) {
            // Success
            console.log("UniversalRouter.execute call finished successfully.");
        } catch Error(string memory reason) {
            console.log(string(abi.encodePacked("UniversalRouter.execute call failed (Error): ", reason)));
            revert(reason);
        } catch (bytes memory lowLevelData) {
            console.log("UniversalRouter.execute call failed (LowLevel)");
            if (lowLevelData.length > 0 && lowLevelData.length <= 68 && lowLevelData[0] == 0x08 && lowLevelData[1] == 0xc3 && lowLevelData[2] == 0x79 && lowLevelData[3] == 0xa0 ) { // Error(string)
                 string memory revertMsg = abi.decode(lowLevelData[4:], (string));
                 console.log("LowLevel Revert Message:", revertMsg);
                 revert(string(abi.encodePacked("LowLevel revert from UR: ", revertMsg)));
            } else if (lowLevelData.length == 0) {
                revert("LowLevel revert from UR with no reason string");
            } else {
                console.logBytes(lowLevelData);
                revert("LowLevel revert from UR with other data");
            }
        }
        vm.stopPrank();


        // FTL tokens are received by `address(this)` (the caller of execute)
        uint256 ftlBalanceOfTestContractAfterSwap = ftlToken.balanceOf(address(this));
        uint256 ftlReceivedByTestContract = ftlBalanceOfTestContractAfterSwap - ftlBalanceOfTestContractBeforeSwap;
        
        console.log("FTL received by test contract:", _uintToString(ftlReceivedByTestContract));

        if (ftlReceivedByTestContract > 0) {
            console.log("Transferring FTL from test contract to user1...");
            ftlToken.transfer(user1, ftlReceivedByTestContract);
        }

        // Assertions
        uint256 finalFTL_ERC20_Balance_User = ftlToken.balanceOf(user1);
        uint256 finalGlyphBalance_User = ftlToken.glyphBalanceOf(user1);
        console.log("Final FTL ERC20 Balance for user1:", _uintToString(finalFTL_ERC20_Balance_User));
        console.log("Final Glyph Balance for user1:", _uintToString(finalGlyphBalance_User));
        
        assertTrue(finalFTL_ERC20_Balance_User > initialFTL_ERC20_Balance_User, "User FTL ERC20 balance should increase");
        // The exact glyph amount depends on the swap rate and FTL's `units`.
        // For this test, we primarily care that *some* glyphs are minted.
        assertTrue(finalGlyphBalance_User > initialGlyphBalance_User, "User glyph balance should increase due to hook");
        // A more precise assertion would require calculating expected FTL output and then expected glyphs.
        // Example: If 10 WETH swaps for exactly 10 FTL (1 FTL = 1 * UNITS), then 10 glyphs should be minted.
        // For now, checking for any increase is a good first step.
        console.log("Expected initialGlyphBalance_User:", _uintToString(initialGlyphBalance_User));
        console.log("Expected finalFTL_ERC20_Balance_User / UNITS :", _uintToString(finalFTL_ERC20_Balance_User / UNITS));
        assertEq(finalGlyphBalance_User, finalFTL_ERC20_Balance_User / UNITS, "Final glyph balance should match FTL ERC20 balance / units");


    }
} 