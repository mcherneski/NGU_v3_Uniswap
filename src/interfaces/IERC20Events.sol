// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IERC20Events
 * @dev Interface containing all ERC20-related event definitions
 */
interface IERC20Events {
  /// @notice Emitted when approval is granted for a spender
  /// @param owner The owner of the tokens
  /// @param spender The address approved to spend the tokens
  /// @param value The amount approved
  /// @dev This event is emitted when a spender is approved to transfer tokens on behalf of the owner.
  event Approval(
    address indexed owner,
    address indexed spender,
    uint256 value
  );

  /// @notice Emitted when tokens are transferred
  /// @param from The sender address
  /// @param to The recipient address
  /// @param amount The amount of tokens transferred
  /// @dev This event is emitted when tokens are transferred from one address to another.
  event Transfer(
    address indexed from, 
    address indexed to, 
    uint256 amount
  );

  /// @notice Emitted when tokens are burned
  /// @param from The sender address
  /// @param amount The amount of tokens burned
  /// @dev This event is emitted when tokens are burned.
  event Burn(
    address indexed from,
    uint256 amount
  );
} 