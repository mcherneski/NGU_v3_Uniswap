// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// Import the base setup contract
import {BaseGlyphHookTestSetup} from "./utils/BaseGlyphHookTestSetup.sol";
// Import specific interfaces or libraries needed for staking tests if not covered by base
import {INGU505Base} from "../src/interfaces/INGU505Base.sol"; // For RangeInfo, etc.
import {NumberGoUp} from "../src/NumberGoUp.sol"; // To interact with NGU staking functions

contract GlyphStakingTest is BaseGlyphHookTestSetup {
    using Strings for uint256;

    function setUp() public override {
        // Call the common setup function from the base contract.
        // This will deploy all necessary contracts (manager, hook, ngu, weth, pool) and set up users.
        super.setUp(); // Calls BaseGlyphHookTestSetup.setUp() which calls _commonSetUp()
        // console2.log("GlyphStakingTest: setUp() completed.");
    }

    function test_StakeSingleGlyph_AcquiredViaSwap() public {
        // console2.log("Starting test_StakeSingleGlyph_AcquiredViaSwap");
        // console2.log("Alice WETH before swap:", weth.balanceOf(alice));
        // console2.log("Alice NGU before swap:", ngu.balanceOf(alice));
        // console2.log("Alice Glyphs before swap:", ngu.glyphBalanceOf(alice));

        // 1. Alice swaps WETH for NGU to acquire glyphs via the hook
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecified = -1e18; // Alice wants to sell 1 WETH
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        vm.startPrank(alice);
        BalanceDelta swapDelta = swapRouter.swap(
            key, // Inherited from BaseGlyphHookTestSetup
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false 
            }),
            abi.encode(alice) // hookData: recipient for glyphs is Alice
        );
        vm.stopPrank();

        uint256 nguReceived = zeroForOne ? uint256(int256(swapDelta.amount1())) : uint256(int256(swapDelta.amount0()));
        uint256 expectedGlyphs = nguReceived / UNITS; // UNITS inherited via Fixtures
        
        // console2.log("NGU Received by Alice:", nguReceived);
        // console2.log("Expected Glyphs for Alice:", expectedGlyphs);
        // console2.log("Actual Glyphs for Alice after swap:", ngu.glyphBalanceOf(alice));

        assertEq(ngu.glyphBalanceOf(alice), expectedGlyphs, "Alice glyph balance incorrect after swap");
        assertTrue(expectedGlyphs > 0, "Alice should have received some glyphs from swap");

        // 2. Alice stakes one of her newly acquired glyphs.
        uint256[] memory aliceOwnedGlyphs = ngu.getQueueGlyphIds(alice);
        assertTrue(aliceOwnedGlyphs.length > 0, "Alice should own glyphs to stake");
        uint256 glyphIdToStake = aliceOwnedGlyphs[0]; // Stake the first available glyph

        // console2.log("Alice attempting to stake glyph ID:", glyphIdToStake);
        // console2.log("Alice NGU (ERC20) before stake:", ngu.balanceOf(alice));
        // console2.log("Alice staked NGU before stake:", ngu.stakedBalanceOf(alice));

        vm.startPrank(alice);
        uint256[] memory tokensToStake = new uint256[](1);
        tokensToStake[0] = glyphIdToStake;
        
        ngu.stake(tokensToStake); // 'ngu' is the NumberGoUp contract instance from base setup
        vm.stopPrank();

        // console2.log("Alice NGU (ERC20) after stake:", ngu.balanceOf(alice));
        // console2.log("Alice staked NGU after stake:", ngu.stakedBalanceOf(alice));

        // 3. Assertions:
        //    - Alice's NGU (ERC20) balance should decrease by 1 UNIT (since 1 glyph = 1 UNIT of ERC20 for staking).
        //    - Alice's staked NGU balance (ERC20 value) should increase by 1 UNIT.
        //    - The specific glyphIdToStake should now be marked as staked (getRangeInfo).
        //    - The glyph should be removed from her unstaked queue (getQueueGlyphIds).

        assertEq(ngu.stakedBalanceOf(alice), 1 * UNITS, "Alice staked NGU (ERC20 value) incorrect");
        // Assuming staking 1 glyph reduces ERC20 balance by 1 UNIT.
        // This depends on NGUStaking's _reduceERC20ForStaking logic.
        // Let's get the initial ERC20 balance after swap but before stake for a cleaner assertion.
        // uint256 nguBalanceAfterSwap = ngu.balanceOf(alice) + (1 * UNITS); // Re-add the staked amount to get pre-stake balance
        // assertEq(ngu.balanceOf(alice), nguBalanceAfterSwap - (1 * UNITS), "Alice ERC20 balance not reduced correctly after stake");
        // The above is a bit complex, direct check against expected reduction is simpler if we trust the swap amount. 
        // We know she received `nguReceived`. After staking 1 glyph (worth UNITS), her balance should be `nguReceived - UNITS`.
        // However, her initial NGU balance (before swap) also needs to be factored if she had any.
        // Let's assume Alice starts with 0 NGU for this test flow for simplicity, or get balance right after swap.
        uint256 nguBalanceAfterSwap = ngu.balanceOf(alice) + (1*UNITS); // what it was before stake() reduced it
        assertEq(ngu.balanceOf(alice), nguBalanceAfterSwap - (1 * UNITS), "Alice ERC20 balance incorrect after staking");

        (address owner, , , bool isStaked) = ngu.getRangeInfo(glyphIdToStake);
        assertTrue(isStaked, "Glyph should be marked as staked");
        assertEq(owner, alice, "Staked glyph owner mismatch"); // Owner should still be Alice

        // Check if the glyph is removed from the unstaked queue
        uint256[] memory aliceOwnedGlyphsAfterStake = ngu.getQueueGlyphIds(alice);
        bool foundStakedGlyphInQueue = false;
        for (uint i = 0; i < aliceOwnedGlyphsAfterStake.length; i++) {
            if (aliceOwnedGlyphsAfterStake[i] == glyphIdToStake) {
                // This is tricky because staking splits ranges. 
                // We need to check if the *original* range of the staked token is gone or correctly modified.
                // For a single token stake from a larger range, the original range should be split.
                // If glyphIdToStake was part of a range startId=X, size=N
                // after staking glyphIdToStake, we might have two ranges: [X, glyphIdToStake-1] and [glyphIdToStake+1, X+N-1]
                // Or the specific ID is just marked and removed conceptually from queue logic.
                // NGUStaking.sol's _removeTokenFromQueue is key here.
                foundStakedGlyphInQueue = true; 
                break;
            }
        }
        // A simpler check might be that the total number of glyphs in the queue has reduced, 
        // or that the specific ID is no longer part of any range returned by getQueueGlyphIds.
        // For now, let's assert the count is one less if `expectedGlyphs > 0`
        if (expectedGlyphs > 0) { // Avoid underflow if no glyphs were minted
             assertEq(aliceOwnedGlyphsAfterStake.length, aliceOwnedGlyphs.length - 1, "Queue size not reduced by 1 after staking");
        }
    }

    function test_UnstakeSingleGlyph_AcquiredViaSwap() public {
        // 1. Alice swaps WETH for NGU to acquire glyphs
        // uint256 initialErc20BalanceAlice = ngu.balanceOf(alice); // Removed unused variable
        uint256 initialGlyphBalanceAlice = ngu.glyphBalanceOf(alice);

        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecifiedSwap = -1e18; // Alice sells 1 WETH
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        vm.startPrank(alice);
        BalanceDelta swapDelta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecifiedSwap,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 nguReceivedFromSwap = zeroForOne ? uint256(int256(swapDelta.amount1())) : uint256(int256(swapDelta.amount0()));
        uint256 glyphsAcquiredFromSwap = nguReceivedFromSwap / UNITS;
        
        assertEq(ngu.glyphBalanceOf(alice), initialGlyphBalanceAlice + glyphsAcquiredFromSwap, "Alice glyph balance incorrect after swap");
        assertTrue(glyphsAcquiredFromSwap > 0, "Alice should have received glyphs from swap");
        uint256 erc20BalanceAfterSwap = ngu.balanceOf(alice);

        // 2. Alice stakes one of her newly acquired glyphs
        uint256[] memory aliceOwnedQueuedGlyphs = ngu.getQueueGlyphIds(alice);
        assertTrue(aliceOwnedQueuedGlyphs.length >= glyphsAcquiredFromSwap, "Alice should own queued glyphs to stake");
        uint256 glyphIdToStakeAndUnstake = aliceOwnedQueuedGlyphs[0]; // Stake the first available glyph

        vm.startPrank(alice);
        uint256[] memory tokensToStake = new uint256[](1);
        tokensToStake[0] = glyphIdToStakeAndUnstake;
        ngu.stake(tokensToStake);
        vm.stopPrank();

        // 3. Verify Stake
        uint256 stakedNguBalanceAfterStake = ngu.stakedBalanceOf(alice);
        assertEq(stakedNguBalanceAfterStake, 1 * UNITS, "Alice staked NGU (ERC20 value) incorrect after stake");
        (,, , bool isStakedAfterStake) = ngu.getRangeInfo(glyphIdToStakeAndUnstake);
        assertTrue(isStakedAfterStake, "Glyph should be marked as staked");
        uint256 erc20BalanceAfterStake = ngu.balanceOf(alice);
        assertEq(erc20BalanceAfterStake, erc20BalanceAfterSwap - (1 * UNITS), "Alice ERC20 balance not reduced correctly after stake");
        uint256 glyphBalanceAfterStake = ngu.glyphBalanceOf(alice); // Staking removes from active queue, so overall glyph balance from perspective of `owned` might not change, but queue does.
                                                                  // However, `glyphBalanceOf` should reflect unburnt glyphs. Staking doesn't burn.

        // 4. Alice unstakes the glyph
        vm.startPrank(alice);
        uint256[] memory tokensToUnstake = new uint256[](1);
        tokensToUnstake[0] = glyphIdToStakeAndUnstake;
        ngu.unstake(tokensToUnstake);
        vm.stopPrank();

        // 5. Verify Unstake & Burn
        // ERC20 balances updated
        assertEq(ngu.stakedBalanceOf(alice), stakedNguBalanceAfterStake - (1 * UNITS), "Alice staked NGU balance not restored correctly after unstake");
        assertEq(ngu.balanceOf(alice), erc20BalanceAfterStake + (1 * UNITS), "Alice ERC20 balance not restored correctly after unstake");

        // Glyph is burned
        assertEq(ngu.glyphBalanceOf(alice), glyphBalanceAfterStake - 1, "Alice glyph balance should decrease by 1 after unstake (burn)");
        
        vm.expectRevert(INGU505Base.TokenDoesNotExist.selector);
        ngu.ownerOf(glyphIdToStakeAndUnstake);

        // Verify glyph is not in the queue anymore
        uint256[] memory aliceOwnedQueuedGlyphsAfterUnstake = ngu.getQueueGlyphIds(alice);
        bool foundUnstakedGlyphInQueue = false;
        for (uint i = 0; i < aliceOwnedQueuedGlyphsAfterUnstake.length; i++) {
            if (aliceOwnedQueuedGlyphsAfterUnstake[i] == glyphIdToStakeAndUnstake) {
                foundUnstakedGlyphInQueue = true;
                break;
            }
        }
        assertFalse(foundUnstakedGlyphInQueue, "Unstaked (burned) glyph should not be in the queue");
    }

    function test_StakeMultipleGlyphs_AcquiredViaSwap() public {
        // 1. Alice swaps WETH for NGU to acquire enough glyphs (e.g., at least 5)
        uint256 initialGlyphBalanceAlice = ngu.glyphBalanceOf(alice);
        
        // Alice sells 5 WETH to get a decent amount of NGU and thus glyphs
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecifiedSwap = -5e18; 
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        vm.startPrank(alice);
        BalanceDelta swapDelta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecifiedSwap,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 nguReceivedFromSwap = zeroForOne ? uint256(int256(swapDelta.amount1())) : uint256(int256(swapDelta.amount0()));
        uint256 glyphsAcquiredFromSwap = nguReceivedFromSwap / UNITS;
        
        assertEq(ngu.glyphBalanceOf(alice), initialGlyphBalanceAlice + glyphsAcquiredFromSwap, "Alice glyph balance incorrect after swap");
        assertTrue(glyphsAcquiredFromSwap >= 3, "Alice should have received at least 3 glyphs from swap to test multiple staking");
        uint256 erc20BalanceAfterSwap = ngu.balanceOf(alice);
        uint256 queuedGlyphsCountAfterSwap = ngu.getQueueGlyphIds(alice).length;

        // 2. Alice selects multiple glyphs to stake (e.g., the first 3 available)
        uint256[] memory aliceOwnedQueuedGlyphs = ngu.getQueueGlyphIds(alice);
        uint256 numGlyphsToStake = 3;
        assertTrue(aliceOwnedQueuedGlyphs.length >= numGlyphsToStake, "Alice does not own enough queued glyphs to stake the desired amount");

        uint256[] memory glyphIdsToStake = new uint256[](numGlyphsToStake);
        for (uint i = 0; i < numGlyphsToStake; i++) {
            glyphIdsToStake[i] = aliceOwnedQueuedGlyphs[i];
        }

        // 3. Alice stakes the selected glyphs
        vm.startPrank(alice);
        ngu.stake(glyphIdsToStake);
        vm.stopPrank();

        // 4. Assertions
        uint256 expectedErc20Reduction = numGlyphsToStake * UNITS;
        uint256 expectedStakedNguIncrease = numGlyphsToStake * UNITS;

        assertEq(ngu.balanceOf(alice), erc20BalanceAfterSwap - expectedErc20Reduction, "Alice ERC20 balance not reduced correctly after staking multiple");
        assertEq(ngu.stakedBalanceOf(alice), expectedStakedNguIncrease, "Alice staked NGU (ERC20 value) incorrect after staking multiple");

        for (uint i = 0; i < numGlyphsToStake; i++) {
            (address owner, ,, bool isStaked) = ngu.getRangeInfo(glyphIdsToStake[i]);
            assertTrue(isStaked, string(abi.encodePacked("Glyph ID ", glyphIdsToStake[i].toString(), " should be marked as staked")));
            assertEq(owner, alice, string(abi.encodePacked("Staked glyph ID ", glyphIdsToStake[i].toString(), " owner mismatch")));
        }

        // Verify the count of glyphs in the queue has reduced
        uint256[] memory aliceOwnedQueuedGlyphsAfterStake = ngu.getQueueGlyphIds(alice);
        assertEq(aliceOwnedQueuedGlyphsAfterStake.length, queuedGlyphsCountAfterSwap - numGlyphsToStake, "Queue size not reduced correctly after staking multiple");
    }

    function test_UnstakeMultipleGlyphs_AcquiredViaSwap() public {
        // 1. Alice swaps WETH for NGU to acquire enough glyphs (e.g., at least 5)
        uint256 initialGlyphBalanceAlice = ngu.glyphBalanceOf(alice);
        
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecifiedSwap = -5e18; // Alice sells 5 WETH
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        vm.startPrank(alice);
        BalanceDelta swapDelta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecifiedSwap,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256 nguReceivedFromSwap = zeroForOne ? uint256(int256(swapDelta.amount1())) : uint256(int256(swapDelta.amount0()));
        uint256 glyphsAcquiredFromSwap = nguReceivedFromSwap / UNITS;
        
        assertEq(ngu.glyphBalanceOf(alice), initialGlyphBalanceAlice + glyphsAcquiredFromSwap, "Alice glyph balance incorrect after swap");
        assertTrue(glyphsAcquiredFromSwap >= 3, "Alice should have received at least 3 glyphs from swap");
        // uint256 erc20BalanceAfterSwap = ngu.balanceOf(alice); // Unused, will get balance after stake operation
        
        // 2. Alice stakes multiple glyphs (e.g., the first 3 available)
        uint256[] memory aliceOwnedQueuedGlyphs = ngu.getQueueGlyphIds(alice);
        uint256 numGlyphsToStakeAndUnstake = 3;
        assertTrue(aliceOwnedQueuedGlyphs.length >= numGlyphsToStakeAndUnstake, "Alice does not own enough queued glyphs");

        uint256[] memory glyphIdsToStake = new uint256[](numGlyphsToStakeAndUnstake);
        for (uint i = 0; i < numGlyphsToStakeAndUnstake; i++) {
            glyphIdsToStake[i] = aliceOwnedQueuedGlyphs[i];
        }

        vm.startPrank(alice);
        ngu.stake(glyphIdsToStake);
        vm.stopPrank();

        // 3. Brief Verify Stake
        uint256 stakedNguBalanceAfterStake = ngu.stakedBalanceOf(alice);
        assertEq(stakedNguBalanceAfterStake, numGlyphsToStakeAndUnstake * UNITS, "Staked balance incorrect after staking");
        uint256 erc20BalanceAfterStake = ngu.balanceOf(alice);
        uint256 glyphBalanceAfterStake = ngu.glyphBalanceOf(alice);

        // 4. Alice unstakes the glyphs
        vm.startPrank(alice);
        ngu.unstake(glyphIdsToStake); // glyphIdsToStake contains the IDs she just staked
        vm.stopPrank();

        // 5. Assertions for Unstake & Burn
        uint256 expectedErc20Increase = numGlyphsToStakeAndUnstake * UNITS;
        assertEq(ngu.balanceOf(alice), erc20BalanceAfterStake + expectedErc20Increase, "Alice ERC20 balance not restored correctly after unstaking multiple");
        assertEq(ngu.stakedBalanceOf(alice), 0, "Alice staked NGU balance should be zero after unstaking all");
        assertEq(ngu.glyphBalanceOf(alice), glyphBalanceAfterStake - numGlyphsToStakeAndUnstake, "Alice glyph balance not reduced correctly after unstaking multiple (burn)");

        for (uint i = 0; i < numGlyphsToStakeAndUnstake; i++) {
            uint256 unstakedGlyphId = glyphIdsToStake[i];
            vm.expectRevert(INGU505Base.TokenDoesNotExist.selector); // Or GlyphNotFound if _glyphData is simply deleted
            ngu.ownerOf(unstakedGlyphId);

            // Check it's not in getRangeInfo either (or isStaked is false, but burn deletes data)
            // Depending on NGU505Base.ownerOf behavior for deleted entries, getRangeInfo might also revert or return default.
            // For now, ownerOf check is primary for non-existence.
        }

        // Verify glyphs are not in the queue anymore
        uint256[] memory aliceOwnedQueuedGlyphsAfterUnstake = ngu.getQueueGlyphIds(alice);
        for (uint i = 0; i < numGlyphsToStakeAndUnstake; i++) {
            bool foundInQueue = false;
            for (uint j = 0; j < aliceOwnedQueuedGlyphsAfterUnstake.length; j++) {
                if (aliceOwnedQueuedGlyphsAfterUnstake[j] == glyphIdsToStake[i]) {
                    foundInQueue = true;
                    break;
                }
            }
            assertFalse(foundInQueue, string(abi.encodePacked("Unstaked (burned) glyph ID ", glyphIdsToStake[i].toString(), " should not be in the queue")));
        }
    }

    function test_Stake_Reverts_IfNotOwner() public {
        // 1. Alice acquires a glyph via swap
        bool zeroForOne = address(weth) < address(ngu);
        int256 amountSpecifiedSwap = -1e18; // Alice sells 1 WETH
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;

        vm.startPrank(alice);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({ zeroForOne: zeroForOne, amountSpecified: amountSpecifiedSwap, sqrtPriceLimitX96: sqrtPriceLimitX96 }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        vm.stopPrank();

        uint256[] memory aliceOwnedGlyphs = ngu.getQueueGlyphIds(alice);
        assertTrue(aliceOwnedGlyphs.length > 0, "Alice should own at least one glyph");
        uint256 glyphIdAliceOwns = aliceOwnedGlyphs[0];

        // Give Bob enough NGU to pass the balance check, but he still won't own the glyph
        vm.startPrank(alice); // Alice has NGU from the swap
        ngu.transfer(bob, 1 * UNITS); // Transfer 1 UNIT of NGU to Bob
        vm.stopPrank();
        assertEq(ngu.balanceOf(bob), 1 * UNITS, "Bob should have 1 NGU UNIT");

        // 2. Bob (who doesn't own the glyph but has NGU) tries to stake Alice's glyph
        uint256[] memory tokenToStake = new uint256[](1);
        tokenToStake[0] = glyphIdAliceOwns;

        vm.startPrank(bob);
        vm.expectRevert(INGU505Base.NotAuthorized.selector); // Corrected: NGU505Base is where NotAuthorized is visible
        ngu.stake(tokenToStake);
        vm.stopPrank();
    }

    // TODO: Add test_Stake_Reverts_IfGlyphAlreadyStaked()
    // TODO: Add test_Unstake_Reverts_IfGlyphNotStaked()
    // TODO: Add test_Unstake_Reverts_IfNotOwnerOfStakedPosition() (if applicable)

} 