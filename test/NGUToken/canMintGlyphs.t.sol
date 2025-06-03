// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseNGUTokenTest, Vm, console} from "./BaseNGUTokenTest.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";
import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {NGUToken} from "../../src/NGUToken.sol";

contract NGUTokenTest_canMintGlyphs is BaseNGUTokenTest {
    using GlyphTestHelpers for NGUGlyph;

    function setUp() public override {
        super.setUp();
    }

    function test_noFee() public {
        deal(address(token), alice.addr, 10 ether);

        token.mock__calculateGlyphMintFee(10, 0);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0, "fee should be 0");
        assertEq(mintAmount, 10, "alice should be able to mint 10 glyphs");
    }

    function test_noFee_balanceNotFullUnit() public {
        deal(address(token), alice.addr, 0.9 ether);

        token.mock__calculateGlyphMintFee(0, 0);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0 ether, "fee should be 0 ether");
        assertEq(mintAmount, 0, "alice should be able to mint 0 glyphs");
    }

    function test_noFee_balanceFullUnit() public {
        deal(address(token), alice.addr, 1 ether);

        token.mock__calculateGlyphMintFee(1, 0);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0 ether, "fee should be 0 ether");
        assertEq(mintAmount, 1, "alice should be able to mint 1 glyph");
    }

    function test_withFee_notEnough() public {
        deal(address(token), alice.addr, 1 ether);

        token.mock__calculateGlyphMintFee(1, 0.01 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0 ether, "fee should be 0 ether");
        assertEq(mintAmount, 0, "alice should be able to mint 0 glyphs");
    }

    function test_withFee_enough() public {
        deal(address(token), alice.addr, 10.1 ether);

        token.mock__calculateGlyphMintFee(10, 0.1 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0.1 ether, "fee should be 0.1 ether");
        assertEq(mintAmount, 10, "alice should be able to mint 10 glyphs");
    }
}
