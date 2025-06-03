// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {GlyphTestHelpers} from "./utils/GlyphTestHelpers.sol";
import {NGUGlyph} from "../src/NGUGlyph.sol";
import {NGUToken} from "../src/NGUToken.sol";
import {Test, Vm, console} from "forge-std/Test.sol";

contract NGUTokenTest is Test {
    using GlyphTestHelpers for NGUGlyph;

    NGUGlyph internal glyph;
    NGUToken internal token;

    Vm.Wallet internal alice = vm.createWallet("alice");
    Vm.Wallet internal bob = vm.createWallet("bob");

    function setUp() public {
        vm.createSelectFork("base-sepolia");

        Deploy deploy = new Deploy();
        Deploy.DeployResponse memory response = deploy.deploy(address(this));

        token = response.nguToken;
        token.grantRole(keccak256("COMPTROLLER_ROLE"), address(this));

        glyph = response.nguGlyph;
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
        PoolKey memory poolKey = token.getPoolKey();
        token.setPoolParams(0, poolKey.tickSpacing, poolKey.hooks);

        deal(address(token), alice.addr, 10 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0, "fee should be 0");
        assertEq(mintAmount, 10, "alice should be able to mint 10 glyphs");
    }

    function test_canMintGlyphs_withFee() public {
        deal(address(token), alice.addr, 10 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        assertEq(fee, 0.9 ether, "fee should be 0.9 ether");
        assertEq(mintAmount, 9, "alice should be able to mint 9 glyphs");
    }

    function test_mintMissingGlyphs() public {
        deal(address(token), alice.addr, 10 ether);

        (uint256 mintAmount, uint256 fee) = token.canMintGlyphs(alice.addr);

        token.mintMissingGlyphs(alice.addr);

        assertEq(token.balanceOf(alice.addr), 10 ether - fee, "alice should have paid the mint fee");
        assertEq(glyph.balanceOf(alice.addr), mintAmount, "alice should have been minted the missing glyphs");
    }
}
