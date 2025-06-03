// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {BaseTest, Vm, console} from "../BaseTest.sol";

import {NGUGlyph} from "../../src/NGUGlyph.sol";
import {LinkedListQueue, TokenDoesNotExist} from "../../src/libraries/LinkedListQueue.sol";
import {GlyphTestHelpers} from "../utils/GlyphTestHelpers.sol";

contract BaseNGUGlyphTest is BaseTest {
    using GlyphTestHelpers for NGUGlyph;

    NGUGlyph internal glyph;

    function setUp() public virtual override {
        super.setUp();

        glyph = new NGUGlyph(address(this));
        glyph.grantRole(keccak256("COMPTROLLER_ROLE"), address(this));
    }
}
