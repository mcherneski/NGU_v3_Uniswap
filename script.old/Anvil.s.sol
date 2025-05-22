// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "@uniswap/v4-core/src/../test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {EasyPosm} from "../test/utils/EasyPosm.sol";
import {IAllowanceTransfer} from "@uniswap/permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "../test/utils/forks/DeployPermit2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

// Local imports
import {GlyphMintingHook} from "../src/GlyphMintingHook.sol";
import {NumberGoUp} from "../src/NumberGoUp.sol";

/// @notice Forge script for deploying v4 & hooks to **anvil**
contract GlyphMintingScript is Script, DeployPermit2 {
    using EasyPosm for IPositionManager;

    address constant CREATE2_DEPLOYER = address(0x4e59b44847b379578588920cA78FbF26c0B4956C);
    IPoolManager manager;
    IPositionManager posm;
    PoolModifyLiquidityTest lpRouter;
    PoolSwapTest swapRouter;
    
    // Constants for token deployment
    uint256 constant UNITS = 1 ether;
    uint256 constant MAX_TOTAL_SUPPLY_ERC20 = 1_000_000 * UNITS;
    
    // Price constants for 1000 FTL = 1 WETH
    uint160 constant SQRT_PRICE_FTL_PER_WETH_0_001 = 2505414483750430265;
    uint160 constant SQRT_PRICE_WETH_PER_FTL_1000 = 25054144837504302653614529031095261;

    function setUp() public {}

    function run() public {
        vm.broadcast();
        manager = deployPoolManager();

        // Deploy POSM
        vm.broadcast();
        posm = deployPosm(manager);

        // Deploy routers
        vm.startBroadcast();
        (lpRouter, swapRouter,) = deployRouters(manager);
        vm.stopBroadcast();

        // Deploy tokens
        vm.startBroadcast();
        (MockERC20 weth, NumberGoUp ftlToken) = deployTokens();
        vm.stopBroadcast();

        // Configure hook permissions - we only need AFTER_SWAP_FLAG
        uint160 permissions = uint160(Hooks.AFTER_SWAP_FLAG);

        // Mine hook address with correct permissions
        bytes memory constructorArgs = abi.encode(manager, address(ftlToken));
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            permissions,
            type(GlyphMintingHook).creationCode,
            constructorArgs
        );

        // Deploy hook
        vm.broadcast();
        GlyphMintingHook hook = new GlyphMintingHook{salt: salt}(manager, address(ftlToken));
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Configure token permissions
        vm.broadcast();
        ftlToken.setGlyphMintingHookAddress(address(hook));

        // Test the lifecycle
        vm.startBroadcast();
        testLifecycle(address(hook), weth, ftlToken);
        vm.stopBroadcast();
    }

    function deployTokens() internal returns (MockERC20 weth, NumberGoUp ftlToken) {
        // Deploy WETH
        weth = new MockERC20("Mock Wrapped Ether", "MWETH", 18);
        weth.mint(msg.sender, 1000 ether);

        // Deploy NumberGoUp token
        ftlToken = new NumberGoUp(
            "NumberGoUp",
            "FTL",
            18,
            UNITS,
            MAX_TOTAL_SUPPLY_ERC20,
            msg.sender, // initialOwner_
            msg.sender, // initialMintRecipient_
            address(swapRouter),
            address(posm),
            address(manager)
        );
    }

    function testLifecycle(address hook, MockERC20 weth, NumberGoUp ftlToken) internal {
        // Approve tokens
        weth.approve(address(lpRouter), type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        ftlToken.approve(address(lpRouter), type(uint256).max);
        ftlToken.approve(address(swapRouter), type(uint256).max);
        approvePosmCurrency(Currency.wrap(address(weth)));
        approvePosmCurrency(Currency.wrap(address(ftlToken)));

        // Initialize pool
        PoolKey memory poolKey;
        if (address(weth) < address(ftlToken)) {
            poolKey = PoolKey(
                Currency.wrap(address(weth)),
                Currency.wrap(address(ftlToken)),
                3000,
                60,
                IHooks(hook)
            );
        } else {
            poolKey = PoolKey(
                Currency.wrap(address(ftlToken)),
                Currency.wrap(address(weth)),
                3000,
                60,
                IHooks(hook)
            );
        }

        // Initialize with correct sqrt price based on token ordering
        uint160 initialSqrtPrice = address(weth) < address(ftlToken) 
            ? SQRT_PRICE_FTL_PER_WETH_0_001 
            : SQRT_PRICE_WETH_PER_FTL_1000;
        manager.initialize(poolKey, initialSqrtPrice);

        // Add liquidity
        int24 currentTick = TickMath.getTickAtSqrtPrice(initialSqrtPrice);
        int24 tickSpacing = 60;
        int24 tickLower = (currentTick / tickSpacing - 100) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 100) * tickSpacing;

        _exampleAddLiquidity(poolKey, tickLower, tickUpper);
    }

    // --- Helper functions from original script ---
    function deployPoolManager() internal returns (IPoolManager) {
        return IPoolManager(address(new PoolManager(address(0))));
    }

    function deployRouters(IPoolManager _manager)
        internal
        returns (PoolModifyLiquidityTest _lpRouter, PoolSwapTest _swapRouter, PoolDonateTest _donateRouter)
    {
        _lpRouter = new PoolModifyLiquidityTest(_manager);
        _swapRouter = new PoolSwapTest(_manager);
        _donateRouter = new PoolDonateTest(_manager);
    }

    function deployPosm(IPoolManager poolManager) public returns (IPositionManager) {
        anvilPermit2();
        return IPositionManager(
            new PositionManager(poolManager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(0)))
        );
    }

    function approvePosmCurrency(Currency currency) internal {
        IERC20(Currency.unwrap(currency)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency), address(posm), type(uint160).max, type(uint48).max);
    }

    function _exampleAddLiquidity(PoolKey memory poolKey, int24 tickLower, int24 tickUpper) internal {
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: 100000 * 1e6,
            salt: bytes32(0)
        });
        lpRouter.modifyLiquidity(poolKey, params, "");

        // Also add liquidity through POSM for completeness
        posm.mint(
            poolKey,
            tickLower,
            tickUpper,
            100e18,
            10_000e18,
            10_000e18,
            msg.sender,
            block.timestamp + 300,
            ""
        );
    }
}
