// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseNGUGlyphTest, Vm, console} from "./BaseNGUGlyphTest.sol";

import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {LinkedListQueue, TokenDoesNotExist} from "../../src/libraries/LinkedListQueue.sol";
import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";

contract NGUGlyphTest_mintGlyphs is BaseNGUGlyphTest {
    using GlyphTestHelpers for NGUGlyph;

    function setUp() public override {
        super.setUp();
    }

    function test_amount_0_fail() public {
        vm.expectRevert(NGUGlyph.AmountMustBePositive.selector);
        glyph.mintGlyphs(alice.addr, 0);
    }

    function test_autoIncrementID(uint256 aliceAmount, uint256 bobAmount) public {
        vm.assume(aliceAmount > 0 && aliceAmount < 50 ether);
        vm.assume(bobAmount > 0 && bobAmount < 50 ether);

        uint256 tokenId;

        // first mint
        tokenId = glyph.mintGlyphs(alice.addr, aliceAmount);
        assertEq(tokenId, 1, "alice token id should be 1");

        tokenId = glyph.mintGlyphs(bob.addr, bobAmount);
        assertEq(tokenId, aliceAmount + 1, "bob token id should be the next after alice");
    }

    function test_addToQueueAlternating() public {
        glyph.mintGlyphs(alice.addr, 100);
        glyph.mintGlyphs(bob.addr, 20);
        glyph.mintGlyphs(alice.addr, 35);

        (uint256[] memory aliceTokenStart, uint256[] memory aliceTokenEnd) = glyph.userTokenQueue(alice.addr);
        assertEq(aliceTokenStart.length, 2, "alice queue length should be 2");

        assertEq(aliceTokenStart[0], 1, "aliceTokenStart[0] should be 1");
        assertEq(aliceTokenEnd[0], 100, "aliceTokenEnd[0] should be 100");

        assertEq(aliceTokenStart[1], 121, "aliceTokenStart[1] should be 121");
        assertEq(aliceTokenEnd[1], 155, "aliceTokenEnd[1] should be 155");

        (uint256[] memory bobTokenStart, uint256[] memory bobTokenEnd) = glyph.userTokenQueue(bob.addr);
        assertEq(bobTokenStart.length, 1, "bob queue length should be 1");

        assertEq(bobTokenStart[0], 101, "bobTokenStart[0] should be 101");
        assertEq(bobTokenEnd[0], 120, "bobTokenEnd[0] should be 120");
    }

    function test_mergeSequential() public {
        glyph.mintGlyphs(alice.addr, 100);
        glyph.mintGlyphs(alice.addr, 35);

        (uint256[] memory aliceTokenStart, uint256[] memory aliceTokenEnd) = glyph.userTokenQueue(alice.addr);
        assertEq(aliceTokenStart.length, 1, "alice queue length should be 1");

        assertEq(aliceTokenStart[0], 1, "aliceTokenStart[0] should be 1");
        assertEq(aliceTokenEnd[0], 135, "aliceTokenEnd[0] should be 135");
    }

    function test_trackAccountTotalBalance(uint256[5] calldata mintAmounts) public {
        uint256 totalBalance;
        for (uint256 i; i < mintAmounts.length; i++) {
            vm.assume(mintAmounts[i] > 0 && mintAmounts[i] < 50 ether);

            glyph.mintGlyphs(alice.addr, mintAmounts[i]);
            totalBalance += mintAmounts[i];

            assertEq(glyph.balanceOf(alice.addr), totalBalance, "alice overall balance not correct");
        }
    }
}
