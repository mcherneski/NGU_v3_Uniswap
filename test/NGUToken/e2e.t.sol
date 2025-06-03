// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest, Vm, console} from "../BaseTest.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";
import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {NGUToken} from "../../src/NGUToken.sol";

contract NGUTokenTest_E2E is BaseTest {
    using GlyphTestHelpers for NGUGlyph;

    NGUGlyph internal glyph;
    NGUToken internal token;

    function setUp() public override {
        vm.createSelectFork("base-sepolia");

        Deploy deploy = new Deploy();
        Deploy.DeployResponse memory response = deploy.deploy(address(this));

        token = response.nguToken;
        glyph = response.nguGlyph;
    }
}
