// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ERC1155Modified} from "./utils/ERC1155Modified.sol";

contract NGUStakedGlyph is ERC1155Modified, Ownable {
    constructor(string memory _baseURI) Ownable(_msgSender()) ERC1155(_baseURI) {}

    function mintBatch(address to, uint256[] memory ids, uint256[] memory values, bytes memory data)
        external
        onlyOwner
    {
        _mintBatch(to, ids, values, data);
    }
}
