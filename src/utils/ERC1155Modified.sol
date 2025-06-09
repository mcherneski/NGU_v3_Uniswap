// SPDX-License-Identifier: UNLICENSED
// Modified OpenZeppelin Contracts (last updated v5.1.0) (token/ERC1155/ERC1155.sol)

pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";

/**
 * @dev Modified OpenZeppelin implementation of the ERC1155 standard.
 */
abstract contract ERC1155Modified is ERC1155 {
    using Arrays for uint256[];

    mapping(address account => uint256) private _balances;

    error TransferNotAllowed();

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

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

    /// @dev Extend existing transfer logic to keep track of account total balances in accordance to `tokenId` -> `value`, where each value in the range represents a single token.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        virtual
        override
    {
        super._update(from, to, ids, values);

        if (from == address(0)) {
            unchecked {
                uint256 totalMintValue;
                for (uint256 i; i < ids.length; ++i) {
                    uint256 value = values.unsafeMemoryAccess(i);
                    totalMintValue += value;
                }
                _balances[to] += totalMintValue;
            }
        }

        if (to == address(0)) {
            unchecked {
                uint256 totalBurnValue;
                for (uint256 i; i < ids.length; ++i) {
                    uint256 value = values.unsafeMemoryAccess(i);
                    totalBurnValue += value;
                }
                _balances[from] -= totalBurnValue;
            }
        }
    }
}
