// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "../script/Deploy.s.sol";

import {GlyphTestHelpers} from "./utils/GlyphTestHelpers.sol";
import {NGUGlyph} from "../src/NGUGlyph.sol";
import {Test, Vm, console} from "forge-std/Test.sol";

contract NGUTokenTest is Test {
    using GlyphTestHelpers for NGUGlyph;

    NGUGlyph internal glyph;
    NGUToken internal token;

    Vm.Wallet internal alice = vm.createWallet("alice");
    Vm.Wallet internal bob = vm.createWallet("bob");

    function setUp() public {
        vm.createSelectFork("base-sepolia");

        Deploy.Contracts memory contracts = new Deploy().deploy();

        token = contracts.nguToken;
        token.grantRole(keccak256("COMPTROLLER_ROLE"), address(this));

        glyph = contracts.nguGlyph;
        glyph.grantRole(keccak256("COMPTROLLER_ROLE"), address(this));
        glyph.grantRole(keccak256("COMPTROLLER_ROLE"), address(token));
    }

    function test__update_burnGlyphsOnTransfer() public {
        deal(address(token), alice.addr, 10 ether);
        glyph.mintGlyphs(alice.addr, 10);

        vm.prank(alice.addr);
        token.transfer(bob.addr, 2 ether);

        assertEq(token.balanceOf(alice.addr), 8 ether, "alice token balance should be 8");
        assertEq(token.balanceOf(bob.addr), 2 ether, "bob token balance should be 2");
        assertEq(glyph.balanceOf(alice.addr), 8, "alice glyph balance should be 8");
        assertEq(glyph.balanceOf(bob.addr), 0, "bob glyph balance should still be 0");
    }

    function test__update_maxBurnGlyphsOnTransfer() public {
        deal(address(token), alice.addr, 10 ether);
        glyph.mintGlyphs(alice.addr, 5);

        vm.prank(alice.addr);
        token.transfer(bob.addr, 7 ether);

        assertEq(token.balanceOf(alice.addr), 3 ether, "alice token balance should be 3");
        assertEq(token.balanceOf(bob.addr), 7 ether, "bob token balance should be 7");
        assertEq(glyph.balanceOf(alice.addr), 3, "alice glyph balance should be 3");
        assertEq(glyph.balanceOf(bob.addr), 0, "bob glyph balance should still be 0");
    }

    function test_canMintGlyphs_noFee() public {
        deal(address(token), alice.addr, 10 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0, "fee should be 0");
        assertEq(mintAmount, 10, "alice should be able to mint 10 glyphs");
    }

    function test_canMintGlyphs_withFee() public {
        // 1% fee = 10_000
        token.setPoolKey(address(0), address(token), 10_000, 0, address(0));
        deal(address(token), alice.addr, 10 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0.9 ether, "fee should be 0.9 ether");
        assertEq(mintAmount, 9, "alice should be able to mint 9 glyphs");
    }

    function test_mintMissingGlyphs() public {
        token.setPoolKey(address(0), address(token), 10_000, 0, address(0));
        deal(address(token), alice.addr, 10 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        token.mintMissingGlyphs(alice.addr);

        assertEq(token.balanceOf(alice.addr), 10 ether - fee, "alice should have paid the mint fee");
        assertEq(glyph.balanceOf(alice.addr), mintAmount, "alice should have been minted the missing glyphs");
    }
}
