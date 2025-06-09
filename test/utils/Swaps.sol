// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "../../src/NGUToken.sol";

import "forge-std/Base.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {AddressRegistry} from "../../utils/AddressRegistry.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";

abstract contract Swaps is CommonBase, AddressRegistry {
    UniversalRouter internal router;

    constructor() AddressRegistry() {}

    function setUp() public virtual {
        router = UniversalRouter(payable(getAddress("UniversalRouter")));
    }

    function _swapTokens(PoolKey memory key, address user, int128 amount, function() internal beforeExecute) internal {
        // Encode the Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP), uint8(Commands.SWEEP));
        bytes[] memory inputs = new bytes[](2);

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        // Prepare parameters for each action
        bytes[] memory params = new bytes[](3);
        if (amount > 0) {
            params[0] = abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: key,
                    zeroForOne: true,
                    amountOut: uint128(amount),
                    amountInMaximum: type(uint128).max,
                    hookData: abi.encode(user)
                })
            );
        } else {
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: key,
                    zeroForOne: false,
                    amountIn: uint128(amount),
                    amountOutMinimum: 0,
                    hookData: abi.encode(user)
                })
            );
        }
        params[1] = abi.encode(key.currency0, type(uint128).max);
        params[2] = abi.encode(key.currency1, 0);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);
        inputs[1] = abi.encode(key.currency0, user);

        // Execute the swap
        uint256 valueToPass = key.currency0.isAddressZero() ? user.balance : 0;
        uint256 deadline = block.timestamp + 20;

        beforeExecute();
        vm.prank(user);
        router.execute{value: valueToPass}(commands, inputs, deadline);
    }
}
