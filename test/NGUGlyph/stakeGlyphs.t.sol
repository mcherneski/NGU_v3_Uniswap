// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseNGUGlyphTest, Vm, console} from "./BaseNGUGlyphTest.sol";

import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {LinkedListQueue, TokenDoesNotExist} from "../../src/libraries/LinkedListQueue.sol";
import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";

contract NGUGlyphTest_stakeGlyphs is BaseNGUGlyphTest {
    using GlyphTestHelpers for NGUGlyph;

    function setUp() public override {
        super.setUp();
    }

    function test_success() public {
        glyph.mintGlyphs(alice.addr, 120);

        NGUGlyph.SplitRequest memory request;

        request.queueRanges = new uint256[](1);
        request.queueRanges[0] = 1;

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangeCount[0] = 3;

        request.requeueRangesStart = new uint256[](3);
        request.requeueRangesStart[0] = 1;
        request.requeueRangesStart[1] = 3;
        request.requeueRangesStart[2] = 112;

        request.requeueRangesEnd = new uint256[](3);
        request.requeueRangesEnd[0] = 1;
        request.requeueRangesEnd[1] = 80;
        request.requeueRangesEnd[2] = 120;

        request.splitRangeCount = new uint256[](1);
        request.splitRangeCount[0] = 3;

        request.splitRangesStart = new uint256[](3);
        request.splitRangesStart[0] = 2;
        request.splitRangesStart[1] = 81;
        request.splitRangesStart[2] = 101;

        request.splitRangesEnd = new uint256[](3);
        request.splitRangesEnd[0] = 2;
        request.splitRangesEnd[1] = 100;
        request.splitRangesEnd[2] = 111;

        vm.prank(alice.addr);
        glyph.stakeGlyphs(request);

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

    function test_emptyRequest() public {
        glyph.mintGlyphs(alice.addr, 120);

        NGUGlyph.SplitRequest memory request;

        vm.expectRevert(NGUGlyph.SplitRequestEmpty.selector);
        glyph.stakeGlyphs(request);
    }

    function test_emptyRequestRange() public {
        glyph.mintGlyphs(alice.addr, 120);

        NGUGlyph.SplitRequest memory request;

        request.queueRanges = new uint256[](1);
        request.queueRanges[0] = 1;

        vm.expectRevert(
            abi.encodeWithSelector(NGUGlyph.ArrayLengthMismatch.selector, "queueRanges", "requeueRangeCount", 1, 0)
        );
        vm.prank(alice.addr);
        glyph.stakeGlyphs(request);
    }

    function test_invalidQueueBalance() public {
        glyph.mintGlyphs(alice.addr, 120);

        NGUGlyph.SplitRequest memory request;

        request.queueRanges = new uint256[](1);
        request.queueRanges[0] = 2;

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangeCount[0] = 0;

        request.splitRangeCount = new uint256[](1);
        request.splitRangeCount[0] = 0;

        vm.expectRevert(abi.encodeWithSelector(TokenDoesNotExist.selector, 2));
        vm.prank(alice.addr);
        glyph.stakeGlyphs(request);
    }

    function test_invalidRange() public {
        glyph.mintGlyphs(alice.addr, 120);

        NGUGlyph.SplitRequest memory request;

        request.queueRanges = new uint256[](1);
        request.queueRanges[0] = 1;

        // Scenario 1

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangeCount[0] = 1;

        request.requeueRangesStart = new uint256[](1);
        request.requeueRangesStart[0] = 15;

        request.requeueRangesEnd = new uint256[](1);
        request.requeueRangesEnd[0] = 11;

        request.splitRangeCount = new uint256[](1);

        vm.expectRevert(abi.encodeWithSelector(NGUGlyph.InvalidRange.selector, NGUGlyph.RangeType.REQUEUE, 15, 11));
        vm.prank(alice.addr);
        glyph.stakeGlyphs(request);

        // Scenario 2

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangesStart = new uint256[](0);
        request.requeueRangesEnd = new uint256[](0);

        request.splitRangeCount = new uint256[](1);
        request.splitRangeCount[0] = 1;

        request.splitRangesStart = new uint256[](1);
        request.splitRangesStart[0] = 10;

        request.splitRangesEnd = new uint256[](1);
        request.splitRangesEnd[0] = 5;

        vm.expectRevert(abi.encodeWithSelector(NGUGlyph.InvalidRange.selector, NGUGlyph.RangeType.SPLIT, 10, 5));
        vm.prank(alice.addr);
        glyph.stakeGlyphs(request);
    }

    function test_subRangeOutOfBounds() public {
        glyph.mintGlyphs(alice.addr, 10); // 1 -> 10
        glyph.mintGlyphs(bob.addr, 110); // 11 -> 120

        NGUGlyph.SplitRequest memory request;

        request.queueRanges = new uint256[](1);
        request.queueRanges[0] = 11;

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangeCount[0] = 1;
        request.requeueRangesStart = new uint256[](1);
        request.requeueRangesEnd = new uint256[](1);

        request.splitRangeCount = new uint256[](1);
        request.splitRangeCount[0] = 1;
        request.splitRangesStart = new uint256[](1);
        request.splitRangesEnd = new uint256[](1);

        // scenario 1
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            1,
            2,
            3,
            120,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.REQUEUE, 11, 120, 1, 2)
        );

        // scenario 2
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            5,
            20,
            21,
            120,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.REQUEUE, 11, 120, 5, 20)
        );

        // scenario 3
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            100,
            130,
            11,
            99,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.REQUEUE, 11, 120, 100, 130)
        );

        // scenario 4
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            121,
            130,
            11,
            120,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.REQUEUE, 11, 120, 121, 130)
        );

        // scenario 5
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            21,
            51,
            3,
            5,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.SPLIT, 11, 120, 3, 5)
        );

        // scenario 6
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            51,
            120,
            7,
            20,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.SPLIT, 11, 120, 7, 20)
        );

        // scenario 7
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            100,
            111,
            112,
            121,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.SPLIT, 11, 120, 112, 121)
        );

        // scenario 8
        _stakeGlyphs_rangeOutOfBounds(
            bob.addr,
            request,
            100,
            110,
            125,
            130,
            abi.encodeWithSelector(NGUGlyph.RangeOutOfBounds.selector, NGUGlyph.RangeType.SPLIT, 11, 120, 125, 130)
        );
    }

    function _stakeGlyphs_rangeOutOfBounds(
        address user,
        NGUGlyph.SplitRequest memory request,
        uint256 requeueStart,
        uint256 requeueEnd,
        uint256 splitStart,
        uint256 splitEnd,
        bytes memory expectedError
    ) internal {
        request.requeueRangesStart[0] = requeueStart;
        request.requeueRangesEnd[0] = requeueEnd;

        request.splitRangesStart[0] = splitStart;
        request.splitRangesEnd[0] = splitEnd;

        vm.expectRevert(expectedError);
        vm.prank(user);
        glyph.stakeGlyphs(request);
    }

    function test_rangesNotSequential() public {
        glyph.mintGlyphs(alice.addr, 120);

        NGUGlyph.SplitRequest memory request;

        request.queueRanges = new uint256[](1);
        request.queueRanges[0] = 1;

        // scenario 1

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangeCount[0] = 2;

        request.requeueRangesStart = new uint256[](2);
        request.requeueRangesStart[0] = 11;
        request.requeueRangesStart[1] = 1;

        request.requeueRangesEnd = new uint256[](2);
        request.requeueRangesEnd[0] = 120;
        request.requeueRangesEnd[1] = 10;

        // reset
        request.splitRangeCount = new uint256[](1);

        _stakeGlyphs_rangesNotSequential(alice.addr, request, NGUGlyph.RangeType.REQUEUE);

        // scenario 2

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangeCount[0] = 2;

        request.requeueRangesStart = new uint256[](2);
        request.requeueRangesStart[0] = 1;
        request.requeueRangesStart[1] = 20;

        request.requeueRangesEnd = new uint256[](2);
        request.requeueRangesEnd[0] = 21;
        request.requeueRangesEnd[1] = 120;

        // reset
        request.splitRangeCount = new uint256[](1);

        _stakeGlyphs_rangesNotSequential(alice.addr, request, NGUGlyph.RangeType.REQUEUE);

        // scenario 3

        // reset
        request.requeueRangeCount = new uint256[](1);
        request.requeueRangesStart = new uint256[](0);
        request.requeueRangesEnd = new uint256[](0);

        request.splitRangeCount = new uint256[](1);
        request.splitRangeCount[0] = 2;

        request.splitRangesStart = new uint256[](2);
        request.splitRangesStart[0] = 9;
        request.splitRangesStart[1] = 1;

        request.splitRangesEnd = new uint256[](2);
        request.splitRangesEnd[0] = 120;
        request.splitRangesEnd[1] = 8;

        _stakeGlyphs_rangesNotSequential(alice.addr, request, NGUGlyph.RangeType.SPLIT);

        // scenario 4

        // reset
        request.requeueRangeCount = new uint256[](1);
        request.requeueRangesStart = new uint256[](0);
        request.requeueRangesEnd = new uint256[](0);

        request.splitRangeCount = new uint256[](1);
        request.splitRangeCount[0] = 2;

        request.splitRangesStart = new uint256[](2);
        request.splitRangesStart[0] = 1;
        request.splitRangesStart[1] = 20;

        request.splitRangesEnd = new uint256[](2);
        request.splitRangesEnd[0] = 21;
        request.splitRangesEnd[1] = 120;

        _stakeGlyphs_rangesNotSequential(alice.addr, request, NGUGlyph.RangeType.SPLIT);
    }

    function _stakeGlyphs_rangesNotSequential(
        address user,
        NGUGlyph.SplitRequest memory request,
        NGUGlyph.RangeType rangeType
    ) internal {
        vm.expectRevert(abi.encodeWithSelector(NGUGlyph.RangesNotSequential.selector, rangeType));
        vm.prank(user);
        glyph.stakeGlyphs(request);
    }
}
