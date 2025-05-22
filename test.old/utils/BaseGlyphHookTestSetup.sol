// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol"; // Not directly used in setup
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol"; // Not directly used in setup
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

// import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol"; // Not directly used in setup
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./EasyPosm.sol"; // Assuming EasyPosm.sol is in test/utils
import {Fixtures} from "./Fixtures.sol";   // Assuming Fixtures.sol is in test/utils
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

// Local imports
import {GlyphMintingHook} from "../../src/GlyphMintingHook.sol";
import {NumberGoUp} from "../../src/NumberGoUp.sol";

contract BaseGlyphHookTestSetup is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Constants that might be overridden or used by inheriting contracts
    uint256 internal constant INITIAL_LIQUIDITY_BASE_DEFAULT = 100 * UNITS; 
    uint256 internal constant LIQUIDITY_MULTIPLIER_DEFAULT = 100;
    
    // Price constants for NGU/WETH pair (1 WETH = 10 NGU) - these are fairly fixed for this pair
    uint160 internal constant SQRT_PRICE_NGU_PER_WETH_10 = 792281625142643375935439503360;
    uint160 internal constant SQRT_PRICE_WETH_PER_NGU_0_1 = 250541448375047931186413801500;

    // Test contracts - declared as internal so inheriting contracts can use them
    GlyphMintingHook internal hook;
    NumberGoUp internal ngu;
    MockERC20 internal weth;
    PoolKey internal key; // Made internal to allow access in inheriting contracts
    PoolId internal poolId;

    // Test addresses - declared as internal
    address internal alice;
    address internal bob;
    // Add other common addresses if needed, e.g., deployer

    // Base setUp function, can be overridden by inheriting contracts
    function setUp() public virtual {
        _commonSetUp();
    }

    // Internal setup function to be called by inheriting contracts
    function _commonSetUp() internal virtual {
        // console2.log("BaseGlyphHookTestSetup: Starting _commonSetUp()");
        
        etchPermit2();
        // console2.log("BaseGlyphHookTestSetup: Permit2 deployed at:", address(permit2));
        
        deployFreshManagerAndRouters();
        // console2.log("BaseGlyphHookTestSetup: Manager deployed at:", address(manager));
        // console2.log("BaseGlyphHookTestSetup: SwapRouter deployed at:", address(swapRouter));

        alice = makeAddr("alice_base_setup"); // Suffix to avoid collision if redefined
        bob = makeAddr("bob_base_setup");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.label(alice, "Alice (BaseSetup)");
        vm.label(bob, "Bob (BaseSetup)");

        weth = new MockERC20("Wrapped Ether (BaseSetup)", "WETH_BASE", 18);
        weth.mint(address(this), 10000 ether); 
        weth.mint(alice, 10 ether);
        weth.mint(bob, 10 ether);
        vm.label(address(weth), "WETH (BaseSetup)");

        deployPosm(manager);
        // console2.log("BaseGlyphHookTestSetup: POSM deployed at:", address(posm));

        ngu = new NumberGoUp(
            "Number Go Up (BaseSetup)",
            "NGU_BASE",
            18,
            UNITS, // Assuming UNITS is defined in Fixtures or Test
            MAX_TOTAL_SUPPLY_ERC20, // Assuming MAX_TOTAL_SUPPLY_ERC20 is in Fixtures or Test
            address(this), 
            address(this), 
            address(swapRouter),
            address(posm),
            address(manager)
        );
        vm.label(address(ngu), "NGU Token (BaseSetup)");

        ngu.setIsGlyphTransferExempt(address(permit2), true);
        ngu.setIsGlyphTransferExempt(address(this), true);

        uint160 permissions = uint160(Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(manager, address(ngu));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            permissions,
            type(GlyphMintingHook).creationCode,
            constructorArgs
        );
        hook = new GlyphMintingHook{salt: salt}(manager, address(ngu));
        require(address(hook) == hookAddress, "BaseGlyphHookTestSetup: Hook address mismatch");
        vm.label(address(hook), "GlyphMintingHook (BaseSetup)");

        ngu.setGlyphMintingHookAddress(address(hook));

        (Currency currency0, Currency currency1) = address(weth) < address(ngu) 
            ? (Currency.wrap(address(weth)), Currency.wrap(address(ngu)))
            : (Currency.wrap(address(ngu)), Currency.wrap(address(weth)));

        key = PoolKey( // Assign to the state variable
            currency0,
            currency1,
            3000,
            60,   
            IHooks(hook)
        );
        poolId = key.toId();
        
        uint160 initialPrice = address(weth) < address(ngu) 
            ? SQRT_PRICE_NGU_PER_WETH_10 
            : SQRT_PRICE_WETH_PER_NGU_0_1;
        manager.initialize(key, initialPrice);

        vm.startPrank(address(this));
        weth.approve(address(manager), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        ngu.approve(address(manager), type(uint256).max);
        ngu.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(posm), type(uint256).max);
        ngu.approve(address(posm), type(uint256).max);
        weth.approve(address(permit2), type(uint256).max);
        ngu.approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(Currency.wrap(address(weth))), address(posm), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(Currency.wrap(address(ngu))), address(posm), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(manager), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        ngu.approve(address(manager), type(uint256).max);
        ngu.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        weth.approve(address(manager), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        ngu.approve(address(manager), type(uint256).max);
        ngu.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        int24 tickSpacing = 60;
        int24 currentTick = TickMath.getTickAtSqrtPrice(initialPrice);
        int24 tickLower = (currentTick / tickSpacing - 2) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 2) * tickSpacing;

        uint256 wethAmountForLiquidity = 1e18 * LIQUIDITY_MULTIPLIER_DEFAULT;
        uint256 nguAmountForLiquidity = 10e18 * LIQUIDITY_MULTIPLIER_DEFAULT; 

        // console2.log("BaseGlyphHookTestSetup: Adding initial liquidity...");
        posm.mint(
            key,
            tickLower,
            tickUpper,
            INITIAL_LIQUIDITY_BASE_DEFAULT * LIQUIDITY_MULTIPLIER_DEFAULT,
            wethAmountForLiquidity,
            nguAmountForLiquidity,
            address(this),
            block.timestamp + 1000,
            ""
        );
        // console2.log("BaseGlyphHookTestSetup: _commonSetUp() finished.");
    }
} 