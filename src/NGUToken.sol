// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title NGUToken
 * @dev Implementation of the ERC20 token for the NGU project with role-based access control.
 * This contract extends OpenZeppelin's ERC20 and AccessControl implementations.
 */
contract NGUToken is ERC20, AccessControl {
    bytes32 public constant COMPTROLLER_ROLE = keccak256("COMPTROLLER_ROLE");

    /**
     * @dev Constructor that mints the initial supply to the deployer's address
     * and sets up the default admin role.
     * @param initialSupply The initial supply of tokens to mint.
     */
    constructor(uint256 initialSupply) ERC20("NGU Token", "NGU") {
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());

        _mint(_msgSender(), initialSupply * (10 ** uint256(decimals())));
    }

    /**
     * @dev Creates `amount` new tokens for `to`.
     * @param to The address that will receive the minted tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyRole(COMPTROLLER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @dev Destroys `amount` tokens from the caller.
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external onlyRole(COMPTROLLER_ROLE) {
        _burn(_msgSender(), amount);
    }

    /**
     * @dev Override decimals to match the standard 18 decimal places used by most ERC20 tokens.
     * @return uint8 The number of decimal places used by the token.
     */
    function decimals() public pure override returns (uint8) {
        return 18;
    }
}
