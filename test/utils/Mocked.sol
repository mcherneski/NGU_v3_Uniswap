// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

struct MockedData {
    bool mocked;
    bytes data;
}

contract Mocked {
    mapping(bytes32 => MockedData) private mockedData;

    function _getMockedData(bytes memory key) internal view returns (bool mocked, bytes memory data) {
        MockedData storage md = mockedData[keccak256(key)];
        mocked = md.mocked;
        data = md.data;
    }

    function _setMockedData(bytes memory key, bytes memory data) internal returns (MockedData storage) {
        return mockedData[keccak256(key)] = MockedData({mocked: true, data: data});
    }

    function _clearMockedData(bytes memory key) internal {
        delete mockedData[keccak256(key)];
    }
}
