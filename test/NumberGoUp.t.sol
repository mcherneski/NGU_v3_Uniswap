// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {NumberGoUp} from "../src/NumberGoUp.sol";
import {NGUStaking} from "../src/NGUStaking.sol";
import {StackQueue} from "../src/libraries/StackQueue.sol";
import {INGU505Base} from "../src/interfaces/INGU505Base.sol";
import {INGU505Staking} from "../src/interfaces/INGU505Staking.sol";
import {IERC20Events} from "../src/interfaces/IERC20Events.sol";
import {IGlyphEvents} from "../src/interfaces/IGlyphEvents.sol";
import {INGU505Events} from "../src/interfaces/INGU505Events.sol";
import {NGUBitMask} from "../src/libraries/Masks.sol";

// Mock Uniswap V3 Router
contract MockUniswapV3Router {
    address public factory;
    address public WETH9;

    constructor(address factory_, address weth9_) {
        factory = factory_;
        WETH9 = weth9_;
    }
}

// Mock Uniswap V3 Position Manager
contract MockUniswapV3PositionManager {
    address public factory;
    address public WETH9;

    constructor(address factory_, address weth9_) {
        factory = factory_;
        WETH9 = weth9_;
    }
}

/**
 * @title NumberGoUpTest
 * @notice Comprehensive test suite for NumberGoUp token with queue management
 * @dev Tests cover ERC20/ERC721 functions, queue operations, staking, transfers and edge cases
 */
contract NumberGoUpTest is Test, IGlyphEvents, IERC20Events, INGU505Events {
    // Constants for token setup
    string constant NAME = "NumberGoUp";
    string constant SYMBOL = "NGU";

    // Struct for defining expected queue ranges in tests
    struct ExpectedRange {
        uint256 startId;
        uint256 size;
    }

    uint8 constant DECIMALS = 18;
    uint256 constant INITIAL_SUPPLY = 1_000_000; // 1 million tokens
    // Track all addresses that have received tokens
    mapping(address => bool) public hasReceivedTokens;
    address[] public tokenReceivers;

    uint256 constant UNITS = 1000000000000000000;
    uint256 constant MAX_TOTAL_SUPPLY_ERC20 = 1_000_000; // 1 million tokens
    
    // Test addresses
    address deployer;
    address initialMintRecipient;
    address uniswapV4Router;
    address uniswapV4PositionManager;
    address uniswapV4PoolManager;
    address alice;
    address bob;
    address carol;
    address dave;
    address weth9;
    address factory;

    // Main contract
    NumberGoUp token;

    // Mock contracts
    MockUniswapV3Router mockRouter;
    MockUniswapV3PositionManager mockPositionManager;

    // Utility constants
    uint256 constant ONE_TOKEN = 1000000000000000000;

    // Import error types from interfaces
    error NotAuthorized();
    error TokenAlreadyStaked(uint256 tokenId);
    error EmptyStakingArray();
    error BatchSizeExceeded();
    error GlyphNotStaked(uint256 tokenId);
    error EmptyUnstakingArray();
    error InvalidTransfer();
    error GlyphAlreadyStaked(uint256 tokenId);

    function _logRangeInfo(uint256 tokenId) internal view {
        (address owner, uint256 startId, uint256 size, bool isStaked) = token.getRangeInfo(tokenId);
        console.log("Token range info:");
        console.log("  Owner:", owner);
        console.log("  Start ID:", startId);
        console.log("  Size:", size);
        console.log("  Is Staked:", isStaked ? "Yes" : "No");
    }

    function _logFirstNGlyphs(uint256[] memory glyphs, uint256 n) internal pure {
        console.log("First few glyphs:");
        for (uint256 i = 0; i < n && i < glyphs.length; i++) {
            console.log("  Glyph ID:", glyphs[i]);
        }
    }

    // Setup function runs before each test
    function setUp() public {
        // Create test addresses
        deployer = makeAddr("deployer");
        initialMintRecipient = makeAddr("initialMintRecipient");
        weth9 = makeAddr("weth9");
        factory = makeAddr("factory");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");
        
        // Deploy mock contracts
        uniswapV4Router = address(0x6fF5693b99212Da76ad316178A184AB56D299b43);
        uniswapV4PositionManager = address(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
        uniswapV4PoolManager = address(0x498581fF718922c3f8e6A244956aF099B2652b2b);
        
        // Deploy token contract
        vm.startPrank(deployer);
        try new NumberGoUp(
            NAME,
            SYMBOL,
            DECIMALS,
            ONE_TOKEN,
            MAX_TOTAL_SUPPLY_ERC20,
            deployer,
            initialMintRecipient,
            uniswapV4Router,
            uniswapV4PositionManager,
            uniswapV4PoolManager
        ) returns (NumberGoUp _token) {
            token = _token;
            // Mark initial mint recipient as exempt from glyph minting
            token.setIsGlyphTransferExempt(initialMintRecipient, true);
        } catch Error(string memory reason) {
            console.log("Deployment failed with reason:", reason);
            revert(reason);
        } catch (bytes memory reason) {
            console.log("Deployment failed with raw error:", string(reason));
            revert(string(reason));
        }
        vm.stopPrank();

        // Set up event listener for Transfer events
        vm.recordLogs();
        
        // Have initialMintRecipient distribute tokens
        vm.startPrank(initialMintRecipient);
        assertEq(token.balanceOf(initialMintRecipient), 1_000_000 * ONE_TOKEN, "Initial mint recipient should have 1 million tokens");
        token.transfer(alice, 15 * ONE_TOKEN);
        token.transfer(bob, 15 * ONE_TOKEN);
        token.transfer(carol, 15 * ONE_TOKEN);
        vm.stopPrank();
    }

    /// @dev Utility Functions Used in tests
    // function verifyQueueIds(uint256[] memory tokenIds) public view {
        
    // }

    /**
     * @notice Asserts that a user's queue contains the expected ranges in the correct order.
     * @param user The address of the user whose queue to check.
     * @param expectedRanges An array of ExpectedRange structs defining the expected queue state.
     */
    function assertQueueIds(
        address user,
        ExpectedRange[] memory expectedRanges
    ) internal view {
        INGU505Base.RangeInfo[] memory actualRanges = token.getQueueRanges(user);
        
        // Assert number of ranges is the same
        assertEq(actualRanges.length, expectedRanges.length, "Queue range count mismatch");
        
        // Assert each range matches
        for (uint256 i = 0; i < actualRanges.length; i++) {
            assertEq(actualRanges[i].startId, expectedRanges[i].startId, string(abi.encodePacked("Range[", Strings.toString(i), "] startId mismatch")));
            assertEq(actualRanges[i].size, expectedRanges[i].size, string(abi.encodePacked("Range[", Strings.toString(i), "] size mismatch")));
        }
    }

    function test_InitialSetup() public view {
        
        assertEq(token.balanceOf(alice), 15 * ONE_TOKEN, "Alice should have 15 ERC20s");
        assertEq(token.glyphBalanceOf(alice), 15, "Alice should have 15 glyphs");
        assertEq(token.ownerOf(1), alice, "Alice should own glyph ID 1");
        assertEq(token.ownerOf(15), alice, "Alice should own glyph ID 15");

        // Explicitly create dynamic array for expected ranges
        ExpectedRange[] memory aliceExpected = new ExpectedRange[](1);
        aliceExpected[0] = ExpectedRange({startId: 1, size: 15});
        assertQueueIds(alice, aliceExpected);

        assertEq(token.balanceOf(bob), 15 * ONE_TOKEN, "Bob should have 15 ERC20s");
        assertEq(token.glyphBalanceOf(bob), 15, "Bob should have 15 glyphs");
        assertEq(token.ownerOf(16), bob, "Bob should own glyph ID 16");
        assertEq(token.ownerOf(30), bob, "Bob should own glyph ID 30");

        // Explicitly create dynamic array for expected ranges
        ExpectedRange[] memory bobExpected = new ExpectedRange[](1);
        bobExpected[0] = ExpectedRange({startId: 16, size: 15});
        assertQueueIds(bob, bobExpected);

        assertEq(token.balanceOf(carol), 15 * ONE_TOKEN, "Carol should have 15 ERC20s");
        assertEq(token.glyphBalanceOf(carol), 15, "Carol should have 15 glyphs");
        assertEq(token.ownerOf(31), carol, "Carol should own glyph ID 31");
        assertEq(token.ownerOf(45), carol, "Carol should own glyph ID 45");

        // Explicitly create dynamic array for expected ranges
        ExpectedRange[] memory carolExpected = new ExpectedRange[](1);
        carolExpected[0] = ExpectedRange({startId: 31, size: 15});
        assertQueueIds(carol, carolExpected);
    }

    function test_AliceStakeSingleToken() public {
        vm.startPrank(alice);
        uint256[] memory tokenToStake = new uint256[](1);
        tokenToStake[0] = 10;
        token.stake(tokenToStake);

        assertEq(token.balanceOf(alice), 14 * ONE_TOKEN, "Alice should have 14 ERC-20s");
        assertEq(token.stakedBalanceOf(alice), 1 * ONE_TOKEN, "Alice should have 1 staked token in the token bank.");
        
        ExpectedRange[] memory aliceExpected = new ExpectedRange[](2);
        aliceExpected[0] = ExpectedRange({startId: 1, size: 9});
        aliceExpected[1] = ExpectedRange({startId: 11, size: 5});
        assertQueueIds(alice, aliceExpected);
        vm.stopPrank();
    }

    function test_AliceStakeMultipleTokens() public {
        vm.startPrank(alice);
        uint256[] memory tokensToStake = new uint256[](5);
        tokensToStake[0] = 3;
        tokensToStake[1] = 7;
        tokensToStake[2] = 9;
        tokensToStake[3] = 11;
        tokensToStake[4] = 13;

        token.stake(tokensToStake);

        assertEq(token.balanceOf(alice), 10 * ONE_TOKEN, "Alice should have 10 ERC-20s");
        assertEq(token.stakedBalanceOf(alice), 5 * ONE_TOKEN, "Alice should have 5 ERC20s in the token bank");

        ExpectedRange[] memory aliceExpected = new ExpectedRange[](6);
        aliceExpected[0] = ExpectedRange({startId: 1, size: 2});
        aliceExpected[1] = ExpectedRange({startId: 4, size: 3});
        aliceExpected[2] = ExpectedRange({startId: 8, size: 1});
        aliceExpected[3] = ExpectedRange({startId: 10, size: 1});
        aliceExpected[4] = ExpectedRange({startId: 12, size: 1});
        aliceExpected[5] = ExpectedRange({startId: 14, size: 2});
       
        ///=============================================================
        /// @dev - Expected Queue:
        /// < Front // [1, 2] [4, 5, 6] [8] [10] [12] [14, 15] \\ Back >
        ///=============================================================

        assertQueueIds(alice, aliceExpected);
        vm.stopPrank();
    }


} 