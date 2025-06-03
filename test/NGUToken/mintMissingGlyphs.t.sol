// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseNGUTokenTest, Vm, console} from "./BaseNGUTokenTest.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";
import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {MockNGUToken, NGUToken} from "./MockNGUToken.sol";

contract NGUTokenTest_mintMissingGlyphs is BaseNGUTokenTest {
    using GlyphTestHelpers for NGUGlyph;

    function setUp() public override {
        super.setUp();

        vm.mockCall(
            address(token.poolManager()),
            abi.encodeWithSelector(IPoolManager.unlock.selector),
            abi.encode(abi.encode(toBalanceDelta(0, 0)))
        );
    }

    function test_callsPoolManager_unlock() public {
        token.mock_canMintGlyphs(alice.addr, 5, 0.1 ether);

        vm.expectCall(address(glyph), abi.encodeWithSelector(NGUGlyph.mintGlyphs.selector, alice.addr, 5));
        vm.expectCall(
            address(token.poolManager()),
            abi.encodeWithSelector(
                IPoolManager.unlock.selector,
                abi.encode(
                    NGUToken.CallbackData({
                        action: NGUToken.CallbackAction.DONATE,
                        data: abi.encode(NGUToken.CallbackDonateData({from: alice.addr, amount: 0.1 ether}))
                    })
                )
            )
        );
        token.mintMissingGlyphs(alice.addr);
    }
}
