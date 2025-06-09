// SPDX-License-Identifier: UNLICENSED
// Modified OpenZeppelin Contracts (last updated v5.1.0) (token/ERC1155/ERC1155.sol)

pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/**
 * @dev Modified OpenZeppelin implementation of the ERC1155 standard.
 */
abstract contract ERC1155NonTransferable is ERC1155 {
    error TransferNotAllowed();

    /**
     * @dev See {_setURI}.
     */
    constructor(string memory uri_) ERC1155(uri_) {}

    function setApprovalForAll(address, bool) public pure override {
        revert TransferNotAllowed();
    }

    /**
     * @dev See {IERC1155-isApprovedForAll}.
     */
    function isApprovedForAll(address, address) public pure override returns (bool) {
        revert TransferNotAllowed();
    }

    /**
     * @dev See {IERC1155-safeTransferFrom}.
     */
    function safeTransferFrom(address, address, uint256, uint256, bytes memory) public pure override {
        revert TransferNotAllowed();
    }

    /**
     * @dev See {IERC1155-safeBatchTransferFrom}.
     */
    function safeBatchTransferFrom(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        override
    {
        revert TransferNotAllowed();
    }
}
