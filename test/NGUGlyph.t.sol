// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, Vm, console} from "forge-std/Test.sol";

import {NGUGlyph} from "../src/NGUGlyph.sol";
import {GlyphTestHelpers} from "./utils/GlyphTestHelpers.sol";

contract NGUGlyphTest is Test {
    using GlyphTestHelpers for NGUGlyph;

    NGUGlyph public glyph;

    Vm.Wallet public alice = vm.createWallet("alice");
    Vm.Wallet public bob = vm.createWallet("bob");

    function setUp() public {
        glyph = new NGUGlyph();
        glyph.grantRole(keccak256("COMPTROLLER_ROLE"), address(this));
    }

    function test_createGlyphs_autoIncrementID() public {
        uint256 tokenId;

        tokenId = glyph.createGlyphs(alice.addr, 100, "");
        assertEq(tokenId, 1, "token id should be 1");

        tokenId = glyph.createGlyphs(bob.addr, 100, "");
        assertEq(tokenId, 101, "token id should be 101");
    }

    function test_createGlyphs_addToQueueAlternating() public {
        glyph.createGlyphs(alice.addr, 100, "");
        glyph.createGlyphs(bob.addr, 20, "");
        glyph.createGlyphs(alice.addr, 35, "");

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

    function test_createGlyphs_mergeSequential() public {
        glyph.createGlyphs(alice.addr, 100, "");
        glyph.createGlyphs(alice.addr, 35, "");

        (uint256[] memory aliceTokenStart, uint256[] memory aliceTokenEnd) = glyph.userTokenQueue(alice.addr);
        assertEq(aliceTokenStart.length, 1, "alice queue length should be 1");

        assertEq(aliceTokenStart[0], 1, "aliceTokenStart[0] should be 1");
        assertEq(aliceTokenEnd[0], 135, "aliceTokenEnd[0] should be 135");
    }

    function test_dequeueGlyphsAndStake_success() public {
        glyph.createGlyphs(alice.addr, 120, "");

        NGUGlyph.RemoveQueueRequest[] memory requests = new NGUGlyph.RemoveQueueRequest[](1);

        requests[0].id = 1;
        requests[0].ranges = new NGUGlyph.Range[](3);

        requests[0].ranges[0].start = 2;
        requests[0].ranges[0].end = 2;

        requests[0].ranges[1].start = 81;
        requests[0].ranges[1].end = 100;

        requests[0].ranges[2].start = 101;
        requests[0].ranges[2].end = 111;

        vm.prank(alice.addr);
        glyph.dequeueGlyphsAndStake(requests);

        (uint256[] memory tokenStart, uint256[] memory tokenEnd) = glyph.userTokenQueue(alice.addr);
        assertEq(tokenStart.length, 3, "tokenStart length should be 3");

        assertEq(tokenStart[0], 1, "tokenStart[0] ID should be 1");
        assertEq(tokenEnd[0], 1, "tokenEnd[0] ID should be 1");

        assertEq(tokenStart[1], 3, "tokenStart[1] ID should be 3");
        assertEq(tokenEnd[1], 80, "tokenEnd[1] ID should be 80");

        assertEq(tokenStart[2], 112, "tokenStart[2] ID should be 112");
        assertEq(tokenEnd[2], 120, "tokenEnd[2] ID should be 120");

        address[] memory stakedBalAddrs = new address[](tokenStart.length);
        for (uint256 i; i < stakedBalAddrs.length; i++) {
            stakedBalAddrs[i] = alice.addr;
        }
        uint256[] memory stakedIds = new uint256[](3);
        stakedIds[0] = 2;
        stakedIds[1] = 81;
        stakedIds[2] = 101;
        uint256[] memory thisBalances = glyph.stGlyph().balanceOfBatch(stakedBalAddrs, stakedIds);
        assertEq(thisBalances[0], 1, "staked balance of ID 2 should be 1");
        assertEq(thisBalances[1], 20, "staked balance of ID 81 should be 20");
        assertEq(thisBalances[2], 11, "staked balance of ID 101 should be 11");
    }

    function test_dequeueGlyphsAndStake_emptyRequest() public {
        glyph.createGlyphs(alice.addr, 120, "");

        NGUGlyph.RemoveQueueRequest[] memory requests = new NGUGlyph.RemoveQueueRequest[](0);

        vm.expectRevert(NGUGlyph.DequeueRequestEmpty.selector);
        glyph.dequeueGlyphsAndStake(requests);
    }

    function test_dequeueGlyphsAndStake_emptyRequestRange() public {
        glyph.createGlyphs(alice.addr, 120, "");

        NGUGlyph.RemoveQueueRequest[] memory requests = new NGUGlyph.RemoveQueueRequest[](1);

        requests[0].id = 1;
        requests[0].ranges = new NGUGlyph.Range[](0);

        vm.expectRevert(abi.encodeWithSelector(NGUGlyph.DequeueRequestRangeEmpty.selector, requests[0].id));
        vm.prank(alice.addr);
        glyph.dequeueGlyphsAndStake(requests);
    }

    function test_dequeueGlyphsAndStake_invalidQueueBalance() public {
        glyph.createGlyphs(alice.addr, 120, "");

        NGUGlyph.RemoveQueueRequest[] memory requests = new NGUGlyph.RemoveQueueRequest[](1);

        requests[0].id = 2;
        requests[0].ranges = new NGUGlyph.Range[](1);

        requests[0].ranges[0].start = 11;
        requests[0].ranges[0].end = 20;

        vm.expectRevert(abi.encodeWithSelector(NGUGlyph.InvalidUserQueueToken.selector, alice.addr, requests[0].id));
        vm.prank(alice.addr);
        glyph.dequeueGlyphsAndStake(requests);
    }

    function test_dequeueGlyphsAndStake_invalidRange() public {
        glyph.createGlyphs(alice.addr, 120, "");

        NGUGlyph.RemoveQueueRequest[] memory requests = new NGUGlyph.RemoveQueueRequest[](1);

        requests[0].id = 1;
        requests[0].ranges = new NGUGlyph.Range[](1);

        requests[0].ranges[0].start = 10;
        requests[0].ranges[0].end = 5;

        vm.expectRevert(
            abi.encodeWithSelector(
                NGUGlyph.InvalidRange.selector, requests[0].id, requests[0].ranges[0].start, requests[0].ranges[0].end
            )
        );
        vm.prank(alice.addr);
        glyph.dequeueGlyphsAndStake(requests);
    }

    function test_dequeueGlyphsAndStake_subRangeOutOfBounds() public {
        glyph.createGlyphs(alice.addr, 10, ""); // 1 -> 10
        glyph.createGlyphs(bob.addr, 110, ""); // 11 -> 120

        NGUGlyph.RemoveQueueRequest[] memory requests = new NGUGlyph.RemoveQueueRequest[](1);

        requests[0].id = 11;
        requests[0].ranges = new NGUGlyph.Range[](1);

        // scenario 1
        _dequeueGlyphsAndStake_subRangeOutOfBounds(bob.addr, requests, 1, 2);

        // scenario 2
        _dequeueGlyphsAndStake_subRangeOutOfBounds(bob.addr, requests, 5, 20);

        // scenario 3
        _dequeueGlyphsAndStake_subRangeOutOfBounds(bob.addr, requests, 100, 130);

        // scenario 4
        _dequeueGlyphsAndStake_subRangeOutOfBounds(bob.addr, requests, 121, 130);
    }

    function _dequeueGlyphsAndStake_subRangeOutOfBounds(
        address user,
        NGUGlyph.RemoveQueueRequest[] memory requests,
        uint256 start,
        uint256 end
    ) internal {
        requests[0].ranges[0].start = start;
        requests[0].ranges[0].end = end;

        vm.expectRevert(
            abi.encodeWithSelector(
                NGUGlyph.SubRangeOutOfBounds.selector,
                requests[0].id,
                glyph.userQueueRangeEnd(user, requests[0].id),
                requests[0].ranges[0].start,
                requests[0].ranges[0].end
            )
        );
        vm.prank(user);
        glyph.dequeueGlyphsAndStake(requests);
    }

    function test_dequeueGlyphsAndStake_subRangesNotSequential() public {
        glyph.createGlyphs(alice.addr, 120, "");

        NGUGlyph.RemoveQueueRequest[] memory requests = new NGUGlyph.RemoveQueueRequest[](1);

        requests[0].id = 1;
        requests[0].ranges = new NGUGlyph.Range[](2);

        // scenario 1

        requests[0].ranges[0].start = 11;
        requests[0].ranges[0].end = 20;

        requests[0].ranges[1].start = 4;
        requests[0].ranges[1].end = 8;

        _dequeueGlyphsAndStake_subRangesNotSequential(alice.addr, requests);

        // scenario 2

        requests[0].ranges[0].start = 11;
        requests[0].ranges[0].end = 20;

        requests[0].ranges[1].start = 20;
        requests[0].ranges[1].end = 30;

        _dequeueGlyphsAndStake_subRangesNotSequential(alice.addr, requests);
    }

    function _dequeueGlyphsAndStake_subRangesNotSequential(address user, NGUGlyph.RemoveQueueRequest[] memory requests)
        internal
    {
        vm.expectRevert(
            abi.encodeWithSelector(
                NGUGlyph.SubRangesNotSequential.selector,
                requests[0].id,
                requests[0].ranges[0].end + 1,
                requests[0].ranges[1].start
            )
        );
        vm.prank(user);
        glyph.dequeueGlyphsAndStake(requests);
    }
}
