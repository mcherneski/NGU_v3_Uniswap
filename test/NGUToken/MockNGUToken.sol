// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Mocked} from "../utils/Mocked.sol";
import {NGUToken} from "../../src/NGUToken.sol";

contract MockNGUToken is Mocked, NGUToken {
    constructor(address _defaultAdmin, uint256 _initialSupply, address _poolManager, address _glyph)
        NGUToken(_defaultAdmin, _initialSupply, _poolManager, _glyph)
    {}

    //////////////// poolKey

    function mock_poolKey(PoolKey memory poolKey) external {
        _poolKey = poolKey;
    }

    //////////////// canMintGlyphs

    function mock_canMintGlyphs(address user, uint256 amount, uint256 fee) external {
        _setMockedData(abi.encodePacked("canMintGlyphs", user), abi.encode(amount, fee));
    }

    function canMintGlyphs(address user) public view override returns (uint256 amount, uint256 fee) {
        (bool mocked, bytes memory data) = _getMockedData(abi.encodePacked("canMintGlyphs", user));
        if (mocked) return abi.decode(data, (uint256, uint256));

        return super.canMintGlyphs(user);
    }

    //////////////// _calculateGlyphMintFee

    function mock__calculateGlyphMintFee(uint256 amount, uint256 fee) external {
        _setMockedData(abi.encodePacked("_calculateGlyphMintFee", amount), abi.encode(fee));
    }

    function _calculateGlyphMintFee(uint256 amount) internal view override returns (uint256 fee) {
        (bool mocked, bytes memory data) = _getMockedData(abi.encodePacked("_calculateGlyphMintFee", amount));
        if (mocked) return abi.decode(data, (uint256));

        return super._calculateGlyphMintFee(amount);
    }

    //////////////// _unlockCallback

    function external_unlockCallback(bytes calldata data) external returns (bytes memory) {
        return _unlockCallback(data);
    }
}
