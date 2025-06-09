// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseNGUTokenTest, Vm, console} from "./BaseNGUTokenTest.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";
import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {MockNGUToken, NGUToken} from "./MockNGUToken.sol";

contract NGUTokenTest__unlockCallback is BaseNGUTokenTest {
    using GlyphTestHelpers for NGUGlyph;

    function setUp() public override {
        super.setUp();

        vm.mockCall(address(token.poolManager()), abi.encodeWithSelector(IPoolManager.sync.selector), "");
        vm.mockCall(address(token.poolManager()), abi.encodeWithSelector(IPoolManager.settle.selector), abi.encode(0));
    }

    function test_donate_transfersBalanceToPoolManager() public {
        deal(address(token), alice.addr, 10 ether);

        vm.mockCall(
            address(token.poolManager()),
            abi.encodeWithSelector(IPoolManager.donate.selector),
            abi.encode(toBalanceDelta(0, -0.5 ether))
        );

        NGUToken.CallbackData memory data = NGUToken.CallbackData({
            action: NGUToken.CallbackAction.DONATE,
            data: abi.encode(NGUToken.CallbackDonateData({from: alice.addr, amount: 0.5 ether}))
        });

        PoolKey memory poolKey;
        poolKey.currency1 = Currency.wrap(address(token));
        token.mock_poolKey(poolKey);

        address poolManager = address(token.poolManager());
        vm.expectCall(poolManager, abi.encodeWithSelector(IPoolManager.donate.selector, poolKey, 0, 0.5 ether, ""));
        vm.expectCall(poolManager, abi.encodeWithSelector(IPoolManager.sync.selector, address(token)));
        vm.expectCall(poolManager, abi.encodeWithSelector(IPoolManager.settle.selector));
        token.external_unlockCallback(abi.encode(data));

        assertEq(token.balanceOf(alice.addr), 9.5 ether, "alice should have 9.5 ether");
    }
}
