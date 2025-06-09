// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest, Vm, console} from "../BaseTest.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {MockNGUToken} from "./MockNGUToken.sol";
import {LinkedListQueue, TokenDoesNotExist} from "../../src/libraries/LinkedListQueue.sol";
import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";

contract BaseNGUTokenTest is BaseTest {
    using GlyphTestHelpers for NGUGlyph;

    MockNGUToken internal token;
    NGUGlyph internal glyph;

    function setUp() public virtual override {
        super.setUp();

        glyph = new NGUGlyph(admin);

        uint256 initialSupply = 1_000_000_000 ether;
        token = new MockNGUToken(admin, initialSupply, address(new PoolManager(address(this))), address(glyph));

        token.grantRole(keccak256("COMPTROLLER_ROLE"), address(this));
        glyph.grantRole(keccak256("COMPTROLLER_ROLE"), address(this));
        glyph.grantRole(keccak256("COMPTROLLER_ROLE"), address(token));
    }
}
