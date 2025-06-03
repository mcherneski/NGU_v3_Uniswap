// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseNGUTokenTest, Vm, console} from "./BaseNGUTokenTest.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";
import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {NGUToken} from "../../src/NGUToken.sol";

contract NGUTokenTest__update is BaseNGUTokenTest {
    using GlyphTestHelpers for NGUGlyph;

    function setUp() public override {
        super.setUp();

        vm.mockCall(
            address(glyph),
            abi.encodeWithSelector(glyph.burnGlyphs.selector),
            ""
        );
    }

    function test_burnGlyphsOnTransfer_balanceMatch() public {
        deal(address(token), alice.addr, 10 ether);
        glyph.mintGlyphs(alice.addr, 10);

        vm.prank(alice.addr);
        vm.expectCall(address(glyph), abi.encodeWithSelector(glyph.burnGlyphs.selector, alice.addr, 2));
        token.transfer(bob.addr, 2 ether);
    }

    function test_burnGlyphsOnTransfer_balanceMismatch() public {
        deal(address(token), alice.addr, 10 ether);
        glyph.mintGlyphs(alice.addr, 5);

        vm.prank(alice.addr);
        vm.expectCall(address(glyph), abi.encodeWithSelector(glyph.burnGlyphs.selector, alice.addr, 2));
        token.transfer(bob.addr, 7 ether);
    }
}
