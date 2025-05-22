// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title NGUAirdrop
 * @notice Contract for distributing NGU tokens via daily Merkle airdrops with a rollover mechanism.
 */
contract NGUAirdrop is Ownable, Pausable, ReentrancyGuard {
    using MerkleProof for bytes32[];

    // --- Errors ---
    error AirdropNotActive();
    error ClaimPeriodEnded();
    error AlreadyClaimedForDay();
    error InvalidMerkleProof();
    error InsufficientContractBalance();
    error MerkleRootAlreadyUsed();
    error NewDayTooSoon();
    error InvalidMerkleRoot();
    error InvalidAmount();
    error InvalidAddress();

    // --- Events ---
    event AirdropFunded(address indexed funder, uint256 amount);
    event FundsWithdrawn(address indexed to, uint256 amount);
    event NewAirdropDayStarted(uint256 indexed dayId, bytes32 merkleRoot, uint256 startTime, uint256 currentTotalRolloverAmount);
    event AirdropClaimed(uint256 indexed dayId, address indexed user, uint256 amountClaimed);
    event DailyPotBaseContributionChanged(uint256 newContributionAmount);

    // --- State Variables ---
    IERC20 public immutable nguToken;
    bytes32 public currentMerkleRoot;
    uint256 public currentAirdropStartTime;
    uint256 public constant CLAIM_PERIOD_DURATION = 24 hours;

    uint256 public dailyPotBaseContribution; // Reference for Merkle tree generation: base amount to consider for the daily pot
    uint256 public dailyRolloverAmount;     // Total accumulated unclaimed NGU from previous days' pots

    mapping(address => uint256) public lastClaimDayId; // user => dayId
    mapping(bytes32 => bool) public usedMerkleRoots;   // merkleRoot => bool
    uint256 public currentDayId;                      // Increments each new Merkle root
    mapping(uint256 => uint256) public totalActuallyClaimedThisDay; // dayId => sum of NGU claimed

    // --- Constructor ---
    constructor(address _nguTokenAddress, uint256 _initialDailyPotBaseContribution) Ownable(msg.sender) {
        if (_nguTokenAddress == address(0)) revert InvalidAddress();
        nguToken = IERC20(_nguTokenAddress);
        dailyPotBaseContribution = _initialDailyPotBaseContribution;
        _pause(); // Start paused
    }

    // --- Administrative Functions ---

    /**
     * @notice Allows the owner to fund the airdrop contract with NGU tokens.
     * @param amount The amount of NGU tokens to transfer to this contract.
     */
    function fundAirdrop(uint256 amount) external onlyOwner whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        bool success = nguToken.transferFrom(msg.sender, address(this), amount);
        if (!success) revert InvalidAmount(); // Or a more specific error like TransferFailed
        emit AirdropFunded(msg.sender, amount);
    }

    /**
     * @notice Allows the owner to withdraw a specific amount of NGU tokens from the contract.
     * @param amount The amount of NGU tokens to withdraw.
     * @param to The address to send the withdrawn tokens to.
     */
    function withdrawFunds(uint256 amount, address to) external onlyOwner whenNotPaused {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        uint256 balance = nguToken.balanceOf(address(this));
        if (balance < amount) revert InsufficientContractBalance();
        bool success = nguToken.transfer(to, amount);
        if (!success) revert InvalidAmount(); // Or a more specific error like TransferFailed
        emit FundsWithdrawn(to, amount);
    }

    /**
     * @notice Allows the owner to withdraw all NGU tokens from the contract.
     * @param to The address to send the withdrawn tokens to.
     */
    function withdrawAllFunds(address to) external onlyOwner whenNotPaused {
        if (to == address(0)) revert InvalidAddress();
        uint256 balance = nguToken.balanceOf(address(this));
        if (balance == 0) revert InsufficientContractBalance(); // Or just do nothing
        bool success = nguToken.transfer(to, balance);
        if (!success) revert InvalidAmount(); // Or a more specific error like TransferFailed
        emit FundsWithdrawn(to, balance);
    }

    /**
     * @notice Starts a new airdrop day with a new Merkle root and calculates rollover.
     * @param newMerkleRootForNextDay The Merkle root for the upcoming claim period.
     * @param totalAllocatedInDayThatJustEnded The total NGU amount allocated in the previous day's Merkle tree.
     */
    function startNewAirdropDay(
        bytes32 newMerkleRootForNextDay,
        uint256 totalAllocatedInDayThatJustEnded
    ) external onlyOwner whenNotPaused {
        if (newMerkleRootForNextDay == bytes32(0)) revert InvalidMerkleRoot();
        if (usedMerkleRoots[newMerkleRootForNextDay]) revert MerkleRootAlreadyUsed();
        
        if (currentAirdropStartTime != 0 && block.timestamp < currentAirdropStartTime + CLAIM_PERIOD_DURATION) {
            revert NewDayTooSoon();
        }

        // Calculate Rollover (if not the first day)
        if (currentMerkleRoot != bytes32(0) && currentDayId > 0) {
            uint256 claimedForCompletedDay = totalActuallyClaimedThisDay[currentDayId];
            if (totalAllocatedInDayThatJustEnded > claimedForCompletedDay) {
                unchecked { // Safe: totalAllocatedInDayThatJustEnded > claimedForCompletedDay
                    dailyRolloverAmount += (totalAllocatedInDayThatJustEnded - claimedForCompletedDay);
                }
            }
        }

        // Transition to New Day
        if (currentMerkleRoot != bytes32(0)) {
            usedMerkleRoots[currentMerkleRoot] = true;
        }
        currentMerkleRoot = newMerkleRootForNextDay;
        currentAirdropStartTime = block.timestamp;
        currentDayId++; 
        totalActuallyClaimedThisDay[currentDayId] = 0; 

        emit NewAirdropDayStarted(currentDayId, currentMerkleRoot, currentAirdropStartTime, dailyRolloverAmount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Allows the owner to update the reference daily pot base contribution amount.
     * @param newContributionAmount The new base contribution amount.
     */
    function setDailyPotBaseContribution(uint256 newContributionAmount) external onlyOwner whenNotPaused {
        dailyPotBaseContribution = newContributionAmount;
        emit DailyPotBaseContributionChanged(newContributionAmount);
    }

    // --- User Claim Function ---

    /**
     * @notice Allows users to claim their airdrop for the current day.
     * @param individualClaimAmountInMerkleLeaf The amount the user is entitled to as per the Merkle leaf.
     * @param merkleProof The Merkle proof for the user's claim.
     */
    function claimAirdrop(
        uint256 individualClaimAmountInMerkleLeaf,
        bytes32[] calldata merkleProof
    ) external whenNotPaused nonReentrant {
        if (currentMerkleRoot == bytes32(0)) revert AirdropNotActive();
        if (block.timestamp >= currentAirdropStartTime + CLAIM_PERIOD_DURATION) revert ClaimPeriodEnded();
        if (lastClaimDayId[msg.sender] >= currentDayId) revert AlreadyClaimedForDay();
        if (individualClaimAmountInMerkleLeaf == 0) revert InvalidAmount();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, individualClaimAmountInMerkleLeaf));
        if (!merkleProof.verify(currentMerkleRoot, leaf)) revert InvalidMerkleProof();

        uint256 contractBalance = nguToken.balanceOf(address(this));
        if (contractBalance < individualClaimAmountInMerkleLeaf) revert InsufficientContractBalance();

        lastClaimDayId[msg.sender] = currentDayId;
        unchecked { // Safe: totalActuallyClaimedThisDay is sum of claims, won't overflow before balance runs out
             totalActuallyClaimedThisDay[currentDayId] += individualClaimAmountInMerkleLeaf;
        }
       
        bool success = nguToken.transfer(msg.sender, individualClaimAmountInMerkleLeaf);
        if (!success) revert InvalidAmount(); // Or a more specific error like TransferFailed

        emit AirdropClaimed(currentDayId, msg.sender, individualClaimAmountInMerkleLeaf);
    }
} 