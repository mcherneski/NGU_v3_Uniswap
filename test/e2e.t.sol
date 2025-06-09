// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest, Vm, console} from "./BaseTest.sol";

import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {GlyphTestHelpers} from "./utils/GlyphTestHelpers.sol";
import {Swaps} from "./utils/Swaps.sol";
import {NGUGlyph} from "../src/NGUGlyph.sol";
import {NGUToken} from "../src/NGUToken.sol";

contract NGUTokenTest_E2E is BaseTest, Swaps {
    using GlyphTestHelpers for NGUGlyph;

    NGUGlyph internal glyph;
    NGUToken internal token;

    function setUp() public override(BaseTest, Swaps) {
        vm.createSelectFork("base-sepolia");

        BaseTest.setUp();
        Swaps.setUp();

        Deploy deploy = new Deploy();
        Deploy.DeployResponse memory response = deploy.deploy(admin);

        token = response.nguToken;
        glyph = response.nguGlyph;
    }

    function test__afterSwap_hook() public {
        deal(alice.addr, 10 ether);

        PoolKey memory key = token.getPoolKey();
        _swapTokens(key, alice.addr, 5 ether, _beforeExecute_test__afterSwap_hook);

        assertEq(token.balanceOf(alice.addr), 5 ether, "alice should have received 5 tokens");
        assertEq(glyph.balanceOf(alice.addr), 5, "alice should have received 5 glyphs");
    }

    function _beforeExecute_test__afterSwap_hook() internal {
        vm.expectCall(
            address(token), abi.encodeWithSelector(NGUToken.mintMissingGlyphsAfterSwap.selector, alice.addr, 5 ether)
        );
        vm.expectCall(address(glyph), abi.encodeWithSelector(NGUGlyph.mintGlyphs.selector, alice.addr, 5));
    }

    function test_stakedGlyph_modifiedTokenBalance() public {
        deal(alice.addr, 11 ether);

        PoolKey memory key = token.getPoolKey();
        _swapTokens(key, alice.addr, 10 ether);

        assertEq(token.balanceOf(alice.addr), 10 ether, "alice should have 10 tokens");

        NGUGlyph.SplitRequest memory request;

        request.queueRanges = new uint256[](1);
        request.queueRanges[0] = 1;

        request.requeueRangeCount = new uint256[](1);
        request.requeueRangeCount[0] = 1;

        request.requeueRangesStart = new uint256[](1);
        request.requeueRangesStart[0] = 1;

        request.requeueRangesEnd = new uint256[](1);
        request.requeueRangesEnd[0] = 8;

        request.splitRangeCount = new uint256[](1);
        request.splitRangeCount[0] = 1;

        request.splitRangesStart = new uint256[](1);
        request.splitRangesStart[0] = 9;

        request.splitRangesEnd = new uint256[](1);
        request.splitRangesEnd[0] = 10;

        vm.prank(alice.addr);
        glyph.stakeGlyphs(request);

        assertEq(glyph.stGlyph().balanceOf(alice.addr), 2, "alice should have 2 staked glyphs");
        assertEq(glyph.balanceOf(alice.addr), 8, "alice should have 8 glyphs");
        assertEq(token.balanceOf(alice.addr), 8 ether, "alice should have 8 tokens");

        vm.expectRevert(abi.encodeWithSelector(NGUToken.InsufficientUnlockedBalance.selector, alice.addr, 8 ether, 10 ether));
        vm.prank(alice.addr);
        token.transfer(bob.addr, 10 ether);

        vm.prank(alice.addr);
        token.transfer(bob.addr, 8 ether);

        assertEq(glyph.stGlyph().balanceOf(alice.addr), 2, "alice should have 2 staked glyphs");
        assertEq(glyph.balanceOf(alice.addr), 0, "alice should have 0 glyphs");
        assertEq(token.balanceOf(alice.addr), 0 ether, "alice should have 0 tokens");
    }
}
