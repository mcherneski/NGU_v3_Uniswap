// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Vm, console} from "forge-std/Test.sol";
import {NGUGlyph} from "../../src/NGUGlyph.sol";

library GlyphTestHelpers {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function printQueue(NGUGlyph glyph, address user) public {
        (uint128[] memory tokenStart, uint128[] memory tokenEnd) = glyph.userTokenQueue(user);

        console.log("Queue for user:", vm.getLabel(user));
        for (uint256 i; i < tokenStart.length; i++) {
            console.log("");
            console.log("Start:", tokenStart[i]);
            console.log("End:", tokenEnd[i]);
        }
        console.log("");
    }
}
