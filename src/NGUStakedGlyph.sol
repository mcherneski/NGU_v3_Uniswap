// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ERC1155NonTransferable} from "./utils/ERC1155NonTransferable.sol";

contract NGUStakedGlyph is ERC1155NonTransferable, Ownable {
    constructor(string memory _baseURI) Ownable(_msgSender()) NonTransferableERC1155(_baseURI) {}
    constructor(string memory _baseURI) Ownable(_msgSender()) ERC1155NonTransferable(_baseURI) {}

    function mintBatch(address to, uint256[] memory ids, uint256[] memory values, bytes memory data)
        external
        onlyOwner
    {
        _mintBatch(to, ids, values, data);
    }
}
