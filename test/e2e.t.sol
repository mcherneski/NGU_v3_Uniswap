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
}
