// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolModifyLiquidityTestNoChecks} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTestNoChecks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapRouterNoChecks} from "@uniswap/v4-core/src/test/SwapRouterNoChecks.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {PoolNestedActionsTest} from "@uniswap/v4-core/src/test/PoolNestedActionsTest.sol";
import {PoolTakeTest} from "@uniswap/v4-core/src/test/PoolTakeTest.sol";
import {PoolClaimsTest} from "@uniswap/v4-core/src/test/PoolClaimsTest.sol";
import {ActionsRouter} from "@uniswap/v4-core/src/test/ActionsRouter.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {NumberGoUp} from "../../src/NumberGoUp.sol";

contract Deployers is Test {
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // Helpful test constants
    bytes constant ZERO_BYTES = Constants.ZERO_BYTES;
    uint160 constant SQRT_PRICE_1_1 = Constants.SQRT_PRICE_1_1;
    uint160 constant SQRT_PRICE_1_2 = Constants.SQRT_PRICE_1_2;
    uint160 constant SQRT_PRICE_2_1 = Constants.SQRT_PRICE_2_1;
    uint160 constant SQRT_PRICE_1_4 = Constants.SQRT_PRICE_1_4;
    uint160 constant SQRT_PRICE_4_1 = Constants.SQRT_PRICE_4_1;

    uint160 public constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 public constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    IPoolManager.ModifyLiquidityParams public LIQUIDITY_PARAMS =
        IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0});
    IPoolManager.ModifyLiquidityParams public REMOVE_LIQUIDITY_PARAMS =
        IPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: -1e18, salt: 0});
    IPoolManager.SwapParams public SWAP_PARAMS =
        IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2});

    // Global variables
    Currency internal currency0;
    Currency internal currency1;
    IPoolManager manager;
    PoolModifyLiquidityTest modifyLiquidityRouter;
    PoolModifyLiquidityTestNoChecks modifyLiquidityNoChecks;
    SwapRouterNoChecks swapRouterNoChecks;
    PoolSwapTest swapRouter;
    PoolDonateTest donateRouter;
    PoolTakeTest takeRouter;
    ActionsRouter actionsRouter;

    PoolClaimsTest claimsRouter;
    PoolNestedActionsTest nestedActionRouter;
    address feeController;

    PoolKey key;
    PoolKey nativeKey;
    PoolKey uninitializedKey;
    PoolKey uninitializedNativeKey;

    // Update this value when you add a new hook flag.
    uint160 hookPermissionCount = 14;
    uint160 clearAllHookPermissionsMask = ~uint160(0) << (hookPermissionCount);

    // Constants
    uint256 constant UNITS = 1 ether;
    uint256 constant MAX_TOTAL_SUPPLY_ERC20 = 1_000_000 * UNITS;
    uint256 constant STARTING_USER_WETH = 100 ether;

    // Price constants for 1000 FTL = 1 WETH
    // If WETH is currency0, FTL is currency1 (FTL/WETH price = 0.001)
    uint160 constant SQRT_PRICE_FTL_PER_WETH_0_001 = 2505414483750430265;
    // If FTL is currency0, WETH is currency1 (WETH/FTL price = 1000)
    uint160 constant SQRT_PRICE_WETH_PER_FTL_1000 = 25054144837504302653614529031095261;

    // Test addresses
    address _Admin = makeAddr("Deployer");
    address user1 = makeAddr("user1");

    modifier noIsolate() {
        if (msg.sender != address(this)) {
            (bool success,) = address(this).call(msg.data);
            require(success);
        } else {
            _;
        }
    }

    function deployFreshManager() internal virtual {
        manager = new PoolManager(address(this));
    }

    function deployFreshManagerAndRouters() internal {
        deployFreshManager();
        swapRouter = new PoolSwapTest(manager);
        swapRouterNoChecks = new SwapRouterNoChecks(manager);
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        modifyLiquidityNoChecks = new PoolModifyLiquidityTestNoChecks(manager);
        donateRouter = new PoolDonateTest(manager);
        takeRouter = new PoolTakeTest(manager);
        claimsRouter = new PoolClaimsTest(manager);
        nestedActionRouter = new PoolNestedActionsTest(manager);
        feeController = makeAddr("feeController");
        actionsRouter = new ActionsRouter(manager);

        manager.setProtocolFeeController(feeController);
    }

    // You must have first initialised the routers with deployFreshManagerAndRouters
    // If you only need the currencies (and not approvals) call deployAndMint2Currencies
    function deployMintAndApprove2Currencies() internal returns (Currency, Currency) {
        Currency _currencyA = deployMintAndApproveCurrency();
        Currency _currencyB = deployMintAndApproveCurrency();

        (currency0, currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(_currencyA)), MockERC20(Currency.unwrap(_currencyB)));
        return (currency0, currency1);
    }

    function deployMintAndApproveCurrency() internal returns (Currency currency) {
        MockERC20 token = deployTokens(1, 2 ** 255)[0];

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }

    function deployMintAndApproveWETH() internal returns (Currency wethCurrency) {
        MockERC20 weth = new MockERC20("Mock Wrapped Ether", "MWETH", 18);
        console.log("Helper: Mock WETH deployed at:", address(weth));

        // Mint WETH to various addresses
        weth.mint(address(this), 100 ether);
        weth.mint(user1, STARTING_USER_WETH);
        weth.mint(_Admin, 100 ether); // For _Admin to provide liquidity

        // Approve WETH for all routers
        address[4] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            weth.approve(toApprove[i], type(uint256).max);
        }

        return Currency.wrap(address(weth));
    }

    function deployMintAndApproveNGU(
        address posm,
        address initialMintRecipient
    ) internal returns (Currency nguCurrency, NumberGoUp nguToken) {
        // Deploy NumberGoUp token
        nguToken = new NumberGoUp(
            "NumberGoUp",
            "FTL",
            18,
            UNITS,
            MAX_TOTAL_SUPPLY_ERC20,
            _Admin, // initialOwner_
            initialMintRecipient, // initialMintRecipient_
            address(swapRouter),
            posm,
            address(manager)
        );
        console.log("Helper: FTL Token deployed at:", address(nguToken));

        // Approve NGU for all routers
        address[4] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks)
        ];

        vm.startPrank(initialMintRecipient);
        for (uint256 i = 0; i < toApprove.length; i++) {
            nguToken.approve(toApprove[i], type(uint256).max);
        }
        vm.stopPrank();

        return (Currency.wrap(address(nguToken)), nguToken);
    }

    function deployAndMint2Currencies() internal returns (Currency, Currency) {
        MockERC20[] memory tokens = deployTokens(2, 2 ** 255);
        return SortTokens.sort(tokens[0], tokens[1]);
    }

    function deployTokens(uint8 count, uint256 totalSupply) internal returns (MockERC20[] memory tokens) {
        tokens = new MockERC20[](count);
        for (uint8 i = 0; i < count; i++) {
            tokens[i] = new MockERC20("TEST", "TEST", 18);
            tokens[i].mint(address(this), totalSupply);
        }
    }

    function initPool(Currency _currency0, Currency _currency1, IHooks hooks, uint24 fee, uint160 sqrtPriceX96)
        internal
        returns (PoolKey memory _key, PoolId id)
    {
        _key = PoolKey(_currency0, _currency1, fee, fee.isDynamicFee() ? int24(60) : int24(fee / 100 * 2), hooks);
        id = _key.toId();
        manager.initialize(_key, sqrtPriceX96);
    }

    function initPool(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory _key, PoolId id) {
        _key = PoolKey(_currency0, _currency1, fee, tickSpacing, hooks);
        id = _key.toId();
        manager.initialize(_key, sqrtPriceX96);
    }

    function initPoolAndAddLiquidity(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        uint160 sqrtPriceX96
    ) internal returns (PoolKey memory _key, PoolId id) {
        (_key, id) = initPool(_currency0, _currency1, hooks, fee, sqrtPriceX96);
        modifyLiquidityRouter.modifyLiquidity{value: msg.value}(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    function initPoolAndAddLiquidityETH(
        Currency _currency0,
        Currency _currency1,
        IHooks hooks,
        uint24 fee,
        uint160 sqrtPriceX96,
        uint256 msgValue
    ) internal returns (PoolKey memory _key, PoolId id) {
        (_key, id) = initPool(_currency0, _currency1, hooks, fee, sqrtPriceX96);
        modifyLiquidityRouter.modifyLiquidity{value: msgValue}(_key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // Deploys the manager, all test routers, and sets up 2 pools: with and without native
    function initializeManagerRoutersAndPoolsWithLiq(IHooks hooks) internal {
        deployFreshManagerAndRouters();
        // sets the global currencies and key
        deployMintAndApprove2Currencies();
        (key,) = initPoolAndAddLiquidity(currency0, currency1, hooks, 3000, SQRT_PRICE_1_1);
        nestedActionRouter.executor().setKey(key);
        (nativeKey,) =
            initPoolAndAddLiquidityETH(CurrencyLibrary.ADDRESS_ZERO, currency1, hooks, 3000, SQRT_PRICE_1_1, 1 ether);
        uninitializedKey = key;
        uninitializedNativeKey = nativeKey;
        uninitializedKey.fee = 100;
        uninitializedNativeKey.fee = 100;
    }

    /// @notice Helper function for a simple ERC20 swaps that allows for unlimited price impact
    function swap(PoolKey memory _key, bool zeroForOne, int256 amountSpecified, bytes memory hookData)
        internal
        returns (BalanceDelta)
    {
        // allow native input for exact-input, guide users to the `swapNativeInput` function
        bool isNativeInput = zeroForOne && _key.currency0.isAddressZero();
        if (isNativeInput) require(0 > amountSpecified, "Use swapNativeInput() for native-token exact-output swaps");

        uint256 value = isNativeInput ? uint256(-amountSpecified) : 0;

        return swapRouter.swap{value: value}(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @notice Helper function to increase balance of pool manager.
    /// Uses default LIQUIDITY_PARAMS range.
    function seedMoreLiquidity(PoolKey memory _key, uint256 amount0, uint256 amount1) internal {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(_key.toId());
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(LIQUIDITY_PARAMS.tickLower),
            TickMath.getSqrtPriceAtTick(LIQUIDITY_PARAMS.tickUpper),
            amount0,
            amount1
        );

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: LIQUIDITY_PARAMS.tickLower,
            tickUpper: LIQUIDITY_PARAMS.tickUpper,
            liquidityDelta: int128(liquidityDelta),
            salt: 0
        });

        modifyLiquidityRouter.modifyLiquidity(_key, params, ZERO_BYTES);
    }

    /// @notice Helper function for a simple Native-token swap that allows for unlimited price impact
    function swapNativeInput(
        PoolKey memory _key,
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData,
        uint256 msgValue
    ) internal returns (BalanceDelta) {
        require(_key.currency0.isAddressZero(), "currency0 is not native. Use swap() instead");
        if (zeroForOne == false) require(msgValue == 0, "msgValue must be 0 for oneForZero swaps");

        return swapRouter.swap{value: msgValue}(
            _key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // Helper function to deploy both tokens and sort them
    function deployAndSortTokens(address posm, address initialMintRecipient) 
        internal 
        returns (
            Currency currency0Sorted, 
            Currency currency1Sorted, 
            Currency wethCurrency, 
            Currency nguCurrency,
            NumberGoUp nguToken
        ) 
    {
        wethCurrency = deployMintAndApproveWETH();
        (nguCurrency, nguToken) = deployMintAndApproveNGU(posm, initialMintRecipient);

        // Sort tokens for pool creation
        if (wethCurrency < nguCurrency) {
            currency0Sorted = wethCurrency;
            currency1Sorted = nguCurrency;
        } else {
            currency0Sorted = nguCurrency;
            currency1Sorted = wethCurrency;
        }

        return (currency0Sorted, currency1Sorted, wethCurrency, nguCurrency, nguToken);
    }

    function initializeNGUWETHPool(
        Currency wethCurrency,
        Currency nguCurrency,
        IHooks hooks,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (PoolKey memory _key, PoolId id) {
        _key = PoolKey(
            wethCurrency < nguCurrency ? wethCurrency : nguCurrency,
            wethCurrency < nguCurrency ? nguCurrency : wethCurrency,
            fee,
            tickSpacing,
            hooks
        );
        id = _key.toId();

        uint160 finalSqrtPriceX96;
        if (Currency.unwrap(_key.currency0) == Currency.unwrap(wethCurrency)) {
            finalSqrtPriceX96 = SQRT_PRICE_FTL_PER_WETH_0_001;
        } else {
            finalSqrtPriceX96 = SQRT_PRICE_WETH_PER_FTL_1000;
        }

        manager.initialize(_key, finalSqrtPriceX96);
        return (_key, id);
    }

    // to receive refunds of spare eth from test helpers
    receive() external payable {}
}
