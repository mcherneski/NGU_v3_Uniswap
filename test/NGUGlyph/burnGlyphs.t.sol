// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseNGUGlyphTest, Vm, console} from "./BaseNGUGlyphTest.sol";

import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {LinkedListQueue, TokenDoesNotExist} from "../../src/libraries/LinkedListQueue.sol";
import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";

contract NGUGlyphTest_burnGlyphs is BaseNGUGlyphTest {
    using GlyphTestHelpers for NGUGlyph;

    function setUp() public override {
        super.setUp();
    }

    function test_burnGlyphs_success() public {
        glyph.mintGlyphs(alice.addr, 10); // 1 -> 10
        glyph.mintGlyphs(bob.addr, 10); // 11 -> 20
        glyph.mintGlyphs(alice.addr, 20); // 21 -> 40

        glyph.burnGlyphs(alice.addr, 15);

        assertEq(glyph.balanceOf(alice.addr), 15, "alice overall balance not correct");
        assertEq(glyph.balanceOf(alice.addr, 26), 15, "alice balance not correct");
    }
}
