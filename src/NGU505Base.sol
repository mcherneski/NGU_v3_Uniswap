// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {INGU505Base} from "./interfaces/INGU505Base.sol";
import {INGU505Events} from "./interfaces/INGU505Events.sol";
import {NGUBitMask} from "./libraries/Masks.sol";
import {StackQueue} from "./libraries/StackQueue.sol";
import {QueueMetadataLib} from "./libraries/QueueMetadataLib.sol";
import {IERC20Events} from "./interfaces/IERC20Events.sol";
import {IGlyphEvents} from "./interfaces/IGlyphEvents.sol";
import {console2 as console} from "forge-std/console2.sol";

// Custom Errors
error InvalidAddress();
error NotAuthorizedHook();
error InvalidQuantity();
error InvalidRecipient();
error BurnAmountExceedsBalance(address account, uint256 quantity, uint256 balance);
error MintToZeroAddress();

/**
 * @title NGU505Base Contract
 * @notice Base contract providing core functionality for NGU token
 * @dev Staking-related storage and functionality:
 * 1. _sellingQueues: Manages unstaked token ranges per user
 * 2. _glyphData: Stores token data including staking status
 * 3. _glyphBalance: Tracks total glyph balance per user
 * 
 * Key interactions with NGUStaking:
 * - Provides queue management for unstaked tokens
 * - Stores and manages token data and ownership
 * - Handles ERC20 balance updates during staking operations
 */
abstract contract NGU505Base is INGU505Base, ReentrancyGuard, AccessControl, INGU505Events, IGlyphEvents, IERC20Events {
    using NGUBitMask for uint256;
    using QueueMetadataLib for uint256;
    /// @notice Role identifier for exemption managers
    bytes32 public constant EXEMPTION_MANAGER_ROLE = keccak256("EXEMPTION_MANAGER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant HOOK_CONFIG_ROLE = keccak256("HOOK_CONFIG_ROLE");

    /// @notice Mapping of addresses exempt from Glyph transfers
    mapping(address => bool) public isGlyphTransferExempt;

    /// @notice Address of the authorized hook contract for special minting
    address public glyphMintingHookAddress;

    /**
     * @notice Per-user token queues for glyph management
     * @dev Critical for staking operations:
     * - Tracks unstaked tokens in efficient ranges
     * - Modified when tokens are staked/unstaked
     * - Maintains order of tokens for transfer operations
     */
    mapping(address => uint256) internal _queueMetadata;
    mapping(address => mapping(uint40 => StackQueue.TokenRange)) internal _queueRanges;

    /**
     * @notice Packed token data storage
     * @dev Used in staking operations to:
     * - Store token ownership information
     * - Track staking status of tokens
     * - Manage token ranges efficiently
     * Format: [160 bits owner][64 bits startId][31 bits size][1 bit staked]
     */
    mapping(uint256 => uint256) internal _glyphData;

    /// @notice Domain separator for EIP-2612 permit
    bytes32 private immutable _INITIAL_DOMAIN_SEPARATOR;
    
    /// @notice Chain ID at contract deployment
    uint256 private immutable _INITIAL_CHAIN_ID;
    
    /// @notice Nonces for EIP-2612 permit
    mapping(address => uint256) public nonces;

    /// @notice Amount of ERC20 tokens that equals one NFT
    uint256 private constant UNITS = 1000000000000000000;

    // Core state variables
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public immutable units;
    uint256 public totalSupply;
    uint256 public immutable _maxTotalSupplyERC20;
    uint256 public currentTokenId = 1;
    uint256 private _burnedTokens;  // Track total number of burned tokens

    // ERC20 Balance
    mapping(address => uint256) public balanceOf;
    // Approval for ERC20 transfer
    mapping(address => mapping(address => uint256)) public allowance;
    // Storage
    mapping(address => uint256) internal _glyphBalance;       // Glyph Token Balances
    mapping(uint256 => address) internal _tokenApprovals; // Token approvals
    mapping(address => mapping(address => bool)) internal _operatorApprovals; // Operator approvals

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 units_,
        uint256 maxTotalSupplyERC20_,
        address initialMintRecipient_
    ) ReentrancyGuard() AccessControl() {
        _INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
        _INITIAL_CHAIN_ID = block.chainid;
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        units = units_;
        _maxTotalSupplyERC20 = maxTotalSupplyERC20_ * units_;

        // Only set the exemption here - roles will be granted in the final contract constructor
        isGlyphTransferExempt[initialMintRecipient_] = true;

        // Grant essential roles to the deployer (msg.sender of this base constructor)
        // This assumes the deployer will also be the initialOwner in the final contract.
        _grantRole(EXEMPTION_MANAGER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, initialMintRecipient_); // Also grant burner to initial recipient if intended
        _grantRole(HOOK_CONFIG_ROLE, msg.sender);
    }
    
    function glyphBalanceOf(address owner_) public view returns (uint256) {
        return _glyphBalance[owner_];
    }

    function glyphTotalSupply() public view override returns (uint256) {
        // Return the current token ID minus burned tokens and minus 1 (since currentTokenId starts at 1)
        // Add parentheses to make order of operations explicit
        return (currentTokenId - _burnedTokens) - 1;
    }

    // Ownership and View Functions
    function ownerOf(uint256 tokenId_) public view override returns (address) {
        if (tokenId_ >= currentTokenId) revert TokenDoesNotExist();

        // Use for loop for early/mid range finding
        for (uint256 i = tokenId_; i > 0; i--) {
            uint256 packed = _glyphData[i];
            if (packed != 0) {
                uint256 startId = NGUBitMask.getStartId(packed);
                uint256 stackSize = NGUBitMask.getStackSize(packed);
                
                if (tokenId_ >= startId && tokenId_ < startId + stackSize) {
                    return NGUBitMask.getOwner(packed);
                }

                if (startId > tokenId_) {
                    i = startId;
                    continue;
                }
            }
        }
        
        revert TokenDoesNotExist();
    }

    // Core ERC20 functions with reentrancy protection
    function safeTransfer(address to, uint256 value) external virtual override nonReentrant returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    // Core ERC20 functions with reentrancy protection
    function transfer(address to, uint256 amount) public virtual override nonReentrant returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override nonReentrant returns (bool) {
        // Check allowance if sender is not the owner
        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            if (allowed < amount) revert InsufficientAllowance(amount, allowed);
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

   /**
     * @notice Internal function to mint ERC20 tokens
     * @dev Handles minting ERC20 tokens with max supply validation.
     *      Follows atomic update pattern:
     *      1. First validates max supply won't be exceeded
     *      2. Updates balances and total supply atomically
     *      3. If NFTs need to be minted, this is handled separately by other mechanisms (e.g., hooks)
     *      All operations must succeed or the entire transaction reverts.
     * @param to The address receiving the tokens
     * @param amount The amount of tokens to mint (in ERC20 units)
     */
    function _mintERC20(address to, uint256 amount) internal virtual {
        if (to == address(0)) revert InvalidRecipient();
        if (totalSupply + amount > _maxTotalSupplyERC20) revert MaxSupplyExceeded(totalSupply + amount, _maxTotalSupplyERC20);
        
        balanceOf[to] += amount;
        totalSupply += amount;
        
        // Glyphs are no longer minted directly from _mintERC20.
        // This will be handled by hooks or other specific minting functions.
        // if (!isGlyphTransferExempt[to]) {
        //     uint256 nftsToMint = amount / units;
        //     if (nftsToMint > 0) {
        //         _mintGlyph(to, nftsToMint);
        //     }
        // }
        
        emit IERC20Events.Transfer(address(0), to, amount);
    }


    function burn(uint256 amount) external {
        if (!hasRole(BURNER_ROLE, msg.sender)) revert NotAuthorized();
        _burnERC20(amount);
    }

    /**
     * @notice Burns ERC20 tokens from the caller's balance
     * @param amount The amount of tokens to burn (in ERC20 units)
     * @dev Only callable by addresses with BURNER_ROLE
     * The caller must have sufficient balance to burn the specified amount
     */
    function _burnERC20(uint256 amount) internal onlyRole(BURNER_ROLE) {
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance(amount, balanceOf[msg.sender]);
        
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        
        emit Burn(msg.sender, amount);
    }
    
    function _setStackStaked(uint256 startTokenId, bool isStaked) internal {
        uint256 packed = _glyphData[startTokenId];
        if (packed == 0) revert GlyphNotFound();
        
        address owner = NGUBitMask.getOwner(packed);
        uint256 stackSize = NGUBitMask.getStackSize(packed);
        
        // Update the token data with new staked status
        _glyphData[startTokenId] = _packTokenData(
            owner,
            startTokenId,
            stackSize,
            isStaked
        );
    }
    
    /// @notice Sets the allowance granted to `spender` by the caller
    /// @dev Protected against reentrancy by nonReentrant modifier
    /// @param spender The address being approved to spend the tokens
    /// @param value The amount of tokens to approve
    /// @return True if the operation succeeded
    /// @dev Event parameters:
    ///      - topic0: keccak256("Approval(address,address,uint256)") [event signature]
    ///      - topic1: msg.sender [indexed owner address]
    ///      - topic2: spender [indexed spender address]
    ///      - data: value [non-indexed uint256 value]
    function approve(address spender, uint256 value) external virtual override nonReentrant returns (bool) {
        if (spender == address(0)) revert InvalidRecipient();
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Handles a single fractional NFT change (either burn or mint)
    /// @dev Only handles one operation at a time for gas efficiency
    /// @param account The address to perform the operation for
    /// @param shouldBurn True if we should burn, false if we should mint
    /// @return success True if the operation was successful
    function _handleFractionalChanges(
        address account,
        bool shouldBurn
    ) internal returns (bool) {
        if (shouldBurn) {
            // When burning, we need to check if the account has enough unstaked tokens
            if (_queueMetadata[account].getSize() == 0) {
                return false;
            }
            
            // Get the front range ID
            uint40 frontRangeId = _queueMetadata[account].getHead();
            if (frontRangeId == 0) {
                 return false;
            }

            // Burn the first token from the front range
            _burnTokenRange(account, frontRangeId, 1);
            return true;
        } else {
            _mintGlyph(account, 1);
            return true;
        }
    }

    /**
     * @notice Transfers tokens from one address to another
     * @dev This is the core transfer function that handles both ERC20 and ERC721 semantics.
     *      Follows a specific execution flow to ensure atomic updates:
     *      1. First validates the transfer can be performed (amounts, approvals, exemptions)
     *      2. Handles NFT transfers/mints/burns based on exemption status
     *      3. Only updates ERC20 balances at the very end, after all NFT operations succeed
     *      4. Uses a careful sequence of operations to ensure state consistency
     *      This "validate first, modify last" pattern guarantees that all state changes
     *      either complete successfully or the entire transaction reverts, maintaining
     *      contract invariants.
     * @param from The address sending the tokens
     * @param to The address receiving the tokens
     * @param amount The amount of tokens to transfer (in ERC20 units)
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal {
        // Add balance check before proceeding with transfer
        if (balanceOf[from] < amount) revert InsufficientBalance(amount, balanceOf[from]);

        bool isFromExempt = isGlyphTransferExempt[from];
        bool isToExempt = isGlyphTransferExempt[to];
        
        // Calculate whole tokens represented by the 'amount' being transferred
        uint256 nftsInTransferAmount = amount / units;

        // Calculate sender's whole token balance before and after this specific transfer amount is deducted
        uint256 fromWholeTokensBefore = balanceOf[from] / units;
        uint256 fromBalanceAfterHypothetical = balanceOf[from] - amount; // to avoid underflow if amount > balance (already checked)
        uint256 fromWholeTokensAfter = fromBalanceAfterHypothetical / units;


        if (isFromExempt && isToExempt) {
            // Case 1: Exempt Sender -> Exempt Receiver
            // Action: Only ERC20 transfer. No glyph operations.
            // Glyphs are not minted or burned.
        } else if (isFromExempt && !isToExempt) {
            // Case 2: Exempt Sender -> Non-Exempt Receiver (e.g., User buys FTL from Pool)
            // Action: Only ERC20 transfer.
            // Glyphs are NOT minted by _transfer; the GlyphMintingHook is responsible for calling
            // a dedicated function like 'mintGlyphFromHook' on NumberGoUp/NumberGoUp.
            // No fractional minting by _transfer either.
        } else if (!isFromExempt && isToExempt) {
            // Case 3: Non-Exempt Sender -> Exempt Receiver (e.g., User sells FTL to Pool)
            // Action: Burn sender's (from) unstaked glyphs.
            if (nftsInTransferAmount > 0) {
                _handleNonExemptToExemptTransfer(from, nftsInTransferAmount); // This burns 'nftsInTransferAmount' from 'from'
            }
            // Handle fractional burn for the sender if their total ERC20 balance drops across a 'units' threshold
            // beyond the nftsInTransferAmount directly accounted for.
            if (fromWholeTokensBefore > fromWholeTokensAfter && (fromWholeTokensBefore - fromWholeTokensAfter > nftsInTransferAmount)) {
                bool burnSuccess = _handleFractionalChanges(from, true); // true for burn
                require(burnSuccess, "Fractional burn failed for sender to exempt");
            }
        } else { // Case 4: Non-Exempt Sender -> Non-Exempt Receiver (P2P Transfer)
            // Action: Burn sender's (from) unstaked glyphs. No glyph minting for receiver (to).
            if (nftsInTransferAmount > 0) {
                // Reuse burn logic: conceptually, sender is "sending away" glyphs which get burned.
                _handleNonExemptToExemptTransfer(from, nftsInTransferAmount); 
            }
            // Handle fractional burn for the sender if their total ERC20 balance drops across a 'units' threshold.
            if (fromWholeTokensBefore > fromWholeTokensAfter && (fromWholeTokensBefore - fromWholeTokensAfter > nftsInTransferAmount)) {
                bool burnSuccess = _handleFractionalChanges(from, true); // true for burn
                require(burnSuccess, "Fractional burn failed for sender P2P");
            }
            // NO MINTING for 'to'. Glyphs are only acquired from the pool hook.
            // NO fractional mint for 'to'.
        }

        // --- Final ERC20 Balance Update ---
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        emit IERC20Events.Transfer(from, to, amount);
    }

    function _handleNonExemptToExemptTransfer(
        address from,
        uint256 nftsToBurn
    ) internal {
        uint256 totalBurned = 0;
        uint256 currentBatchStartId = 0;
        uint256 currentBatchSize = 0;

        while (totalBurned < nftsToBurn && _queueMetadata[from].getSize() > 0) {
            uint40 rangeId = _queueMetadata[from].getHead();
            if (rangeId == 0) break;
            StackQueue.TokenRange storage range = _queueRanges[from][rangeId];
            uint256 burnSize = range.size;

            if (totalBurned + burnSize > nftsToBurn) {
                burnSize = nftsToBurn - totalBurned;
            }

            // Batch Burn Event Logic
            if (currentBatchSize == 0) {
                currentBatchStartId = range.startId;
                currentBatchSize = burnSize;
            } else if (range.startId == currentBatchStartId + currentBatchSize) {
                currentBatchSize += burnSize;
            } else {
                emit BatchBurn(from, currentBatchStartId, currentBatchSize);
                currentBatchStartId = range.startId;
                currentBatchSize = burnSize;
            }

            // Perform the burn operation on the range
            _burnTokenRange(from, rangeId, uint40(burnSize));
            totalBurned += burnSize;
        }

        if (totalBurned < nftsToBurn) {
            revert GlyphNotFound(); 
        }

        if (currentBatchSize > 0) {
            emit BatchBurn(from, currentBatchStartId, currentBatchSize);
        }
    }

    function _handleExemptToNonExemptTransfer(
        address to,
        uint256 nftsToMint
    ) internal {
        // No need to check nftsToMint > 0 as _transfer already did
        _mintGlyph(to, nftsToMint);
    }

    /**
     * @notice Processes the transfer of multiple glyphs between addresses
     * @param from The address sending the tokens
     * @param to The address receiving the tokens
     * @param glyphsToTransfer The number of glyphs to transfer
     */
    function _processGlyphTransfer(
        address from,
        address to,
        uint256 glyphsToTransfer
    ) internal {
        uint256 totalTransferred = 0;

        // Add explicit check to ensure we don't try to transfer 0 tokens
        if (glyphsToTransfer == 0) {
            return;
        }

        while (totalTransferred < glyphsToTransfer) {
            if (_queueMetadata[from].getSize() == 0) {
                 revert GlyphNotFound();
            }

            uint40 rangeId = _queueMetadata[from].getHead();
            if (rangeId == 0) break;
            StackQueue.TokenRange storage frontRange = _queueRanges[from][rangeId];
            uint256 transferSize = frontRange.size;

            if (transferSize > glyphsToTransfer - totalTransferred) {
                transferSize = glyphsToTransfer - totalTransferred;
                uint256 remainingSize = frontRange.size - transferSize;
                uint256 newStartId = frontRange.startId + transferSize;

                // Remove the original range - replace with manual unlink logic
                uint40 originalStartId = frontRange.startId;
                uint40 prevId = frontRange.prevId;
                uint40 nextId = frontRange.nextId;
                uint256 fromPackedMeta = _queueMetadata[from];

                // Update adjacent links
                if (prevId != 0) { _queueRanges[from][prevId].nextId = nextId; }
                if (nextId != 0) { _queueRanges[from][nextId].prevId = prevId; }

                // Update metadata head/tail/size
                if (rangeId == fromPackedMeta.getHead()) { fromPackedMeta = fromPackedMeta.setHead(nextId); }
                if (rangeId == fromPackedMeta.getTail()) { fromPackedMeta = fromPackedMeta.setTail(prevId); }
                fromPackedMeta = fromPackedMeta.decrementSize();
                _queueMetadata[from] = fromPackedMeta;

                // Delete the range node data
                delete _queueRanges[from][rangeId];

                // Clear original glyph data
                delete _glyphData[originalStartId];
                _glyphData[originalStartId] = _packTokenData(to, originalStartId, transferSize, false);

                // Create new range for transferred tokens with new owner
                uint256 toPackedMeta = _queueMetadata[to];
                if (toPackedMeta == 0) { toPackedMeta = QueueMetadataLib.pack(0, 0, 0, 1); }
                uint40 toNewRangeId;
                uint256 toNextPackedMeta;
                (toNewRangeId, toNextPackedMeta) = toPackedMeta.incrementNextRangeId();
                uint40 toCurrentTailId = toPackedMeta.getTail();
                StackQueue.TokenRange storage toNewRange = _queueRanges[to][toNewRangeId];
                toNewRange.startId = originalStartId;
                toNewRange.size = uint40(transferSize);
                toNewRange.owner = to;
                toNewRange.prevId = toCurrentTailId;
                toNewRange.nextId = 0;
                if (toCurrentTailId != 0) { _queueRanges[to][toCurrentTailId].nextId = toNewRangeId; }
                else { toNextPackedMeta = toNextPackedMeta.setHead(toNewRangeId); }
                toNextPackedMeta = toNextPackedMeta.setTail(toNewRangeId);
                toNextPackedMeta = toNextPackedMeta.incrementSize();
                _queueMetadata[to] = toNextPackedMeta;

                // Update the 'from' range in place (partial transfer)
                frontRange.startId = uint40(newStartId);
                frontRange.size = uint40(remainingSize);
                // Update glyphData for the remaining part
                _glyphData[newStartId] = _packTokenData(from, newStartId, remainingSize, false);

                // Emit BatchTransfer event for the transferred portion
                emit BatchTransfer(from, to, originalStartId, uint40(transferSize));
            } else {
                // Transferring entire range
                uint40 originalStartId = frontRange.startId;
                uint40 prevId = frontRange.prevId;
                uint40 nextId = frontRange.nextId;
                uint256 fromPackedMeta = _queueMetadata[from];

                // Update adjacent links
                if (prevId != 0) { _queueRanges[from][prevId].nextId = nextId; }
                if (nextId != 0) { _queueRanges[from][nextId].prevId = prevId; }

                // Update metadata head/tail/size
                if (rangeId == fromPackedMeta.getHead()) { fromPackedMeta = fromPackedMeta.setHead(nextId); }
                if (rangeId == fromPackedMeta.getTail()) { fromPackedMeta = fromPackedMeta.setTail(prevId); }
                fromPackedMeta = fromPackedMeta.decrementSize();
                _queueMetadata[from] = fromPackedMeta;

                // Delete the range node data
                delete _queueRanges[from][rangeId];

                // Clear original glyph data and create new one with new owner
                delete _glyphData[originalStartId];
                _glyphData[originalStartId] = _packTokenData(to, originalStartId, transferSize, false);

                // Emit BatchTransfer event for the full range
                emit BatchTransfer(from, to, originalStartId, uint40(transferSize));
            }

            // Update balances with checked arithmetic
            _glyphBalance[from] -= transferSize;
            _glyphBalance[to] += transferSize;
            totalTransferred += transferSize;
            
            // Force break if we've transferred all tokens
            if (totalTransferred >= glyphsToTransfer) {
                break;
            }
        }
    }

    function _burnFirstUnstakedToken(address from) internal {
         if (_queueMetadata[from].getSize() == 0) return;
         
         uint40 frontRangeId = _queueMetadata[from].getHead();
         if (frontRangeId == 0) return;
         _burnTokenRange(from, frontRangeId, 1);
    }

    /**
     * @notice Burns a specified quantity of tokens starting from a given range ID.
     * @param from The owner address.
     * @param rangeId The ID of the range in the StackQueue to start burning from.
     * @param quantity The number of tokens to burn.
     */
    function _burnTokenRange(address from, uint40 rangeId, uint40 quantity) internal {
        StackQueue.TokenRange storage range = _queueRanges[from][rangeId];
        if (range.owner == address(0)) {
            revert GlyphNotFound();
        }

        if (quantity == 0) return;
        if (quantity > range.size) {
            revert InvalidQuantity(); 
        }

        uint40 startIdToBurn = range.startId;

        // Clear the original glyph data for the start of the range
        delete _glyphData[startIdToBurn];

        if (quantity < range.size) {
            // Burning a partial range
            uint40 remainingSize = range.size - quantity;
            uint40 newStartId = startIdToBurn + quantity;

            // Update the existing range node in place
            range.startId = newStartId;
            range.size = remainingSize;

            // Repack _glyphData for the *new* start ID of the remaining range
            _glyphData[newStartId] = _packTokenData(from, newStartId, remainingSize, false);

        } else {
            // Burning the entire range - remove the node from the list
            uint40 prevId = range.prevId;
            uint40 nextId = range.nextId;
            uint256 packedMeta = _queueMetadata[from];

            // Update adjacent links
            if (prevId != 0) { _queueRanges[from][prevId].nextId = nextId; }
            if (nextId != 0) { _queueRanges[from][nextId].prevId = prevId; }

            // Update metadata head/tail/size
            if (rangeId == packedMeta.getHead()) { packedMeta = packedMeta.setHead(nextId); }
            if (rangeId == packedMeta.getTail()) { packedMeta = packedMeta.setTail(prevId); }
            packedMeta = packedMeta.decrementSize();
            _queueMetadata[from] = packedMeta;

            // Delete the range node data
            delete _queueRanges[from][rangeId];
        }

        // Update balances and burned counter
        _glyphBalance[from] -= quantity;
        _burnedTokens += quantity;

        // Emit BatchBurn event (Consider batching if called multiple times in a transaction)
        emit BatchBurn(from, startIdToBurn, quantity);
    }

    /// @notice Generates an array of sequential token IDs
    /// @dev Helper function to avoid stack too deep errors
    /// @param startId The first token ID
    /// @param size The number of IDs to generate
    /// @return Array of token IDs
    function _generateTokenIdArray(uint256 startId, uint256 size) internal pure returns (uint256[] memory) {
        uint256[] memory tokenIds = new uint256[](size);
        for (uint256 i = 0; i < size;) {
            tokenIds[i] = startId + i;
            unchecked { ++i; }
        }
        return tokenIds;
    }

    /// @notice Sets or unsets an operator's approval for all tokens owned by the caller
    /// @dev Protected against reentrancy by nonReentrant modifier
    /// @param operator The address to approve or revoke
    /// @param approved True to approve, false to revoke
    function setApprovalForAll(address operator, bool approved) public virtual nonReentrant {
        if (operator == msg.sender) revert InvalidOperator();
        if (operator == address(0)) revert InvalidOperator();
        _operatorApprovals[msg.sender][operator] = approved;
        
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    /// @notice Approves an address to transfer a specific NFT
    /// @dev The caller must own the token or be an approved operator
    function approveGlyph(address operator, uint256 tokenId) public virtual override nonReentrant {
        if (operator == address(0)) revert InvalidOperator();
        
        address owner = ownerOf(tokenId);
        if (operator == msg.sender) revert InvalidOperator();
        
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) {
            revert NotAuthorized();
        }

        _tokenApprovals[tokenId] = operator;
        emit Approval(owner, operator, tokenId);
    }

    /// @notice Gets the approved address for a token ID
    /// @dev Reverts if the token doesn't exist
    function getApproved(uint256 tokenId) public view virtual returns (address) {
        // This will revert if token doesn't exist
        ownerOf(tokenId);
        // If it does exist, return the approved operator
        return _tokenApprovals[tokenId];
    }

    /// @notice Query if an address is an authorized operator for another address
    function isApprovedForAll(address owner, address operator) public view virtual returns (bool) {
        if (owner == address(0)) revert InvalidOperator();
        if (operator == address(0)) revert InvalidOperator();
        return _operatorApprovals[owner][operator];
    }

    /// @notice Returns all NFTs owned by an address
    /// @param owner The address to query
    /// @return tokenIds Array of token IDs owned by the address
    function owned(address owner) public view virtual override returns (uint256[] memory tokenIds) {
        uint256 totalTokens = 0;
        uint40 countCurrentId = _queueMetadata[owner].getHead();
        while (countCurrentId != 0) {
             totalTokens += _queueRanges[owner][countCurrentId].size;
             countCurrentId = _queueRanges[owner][countCurrentId].nextId;
        }

        tokenIds = new uint256[](totalTokens);
        uint256 currentIndex = 0;

        uint40 currentId = _queueMetadata[owner].getHead();
        while (currentId != 0 && currentIndex < totalTokens) {
            StackQueue.TokenRange storage range = _queueRanges[owner][currentId];
            for (uint256 j = 0; j < range.size; ) {
                if (currentIndex < totalTokens) {
                    tokenIds[currentIndex] = range.startId + j;
                } else {
                    break;
                }
                unchecked {
                    ++j;
                    ++currentIndex;
                }
            }
            currentId = range.nextId;
        }

        return tokenIds;
    }

    /// @notice The isGlyphTransferExempt getter is the default public getter. 
    function _setIsGlyphTransferExempt(address account_, bool value_) internal {
        if (account_ == address(0)) revert InvalidExemption();
        isGlyphTransferExempt[account_] = value_;
    }

    function setIsGlyphTransferExempt(address account_, bool value_) public virtual override nonReentrant {
        if (!hasRole(EXEMPTION_MANAGER_ROLE, msg.sender)) revert NotAuthorized();
        _setIsGlyphTransferExempt(account_, value_);
    }

    /// @notice Returns whether an address has the exemption manager role
    /// @param account_ The address to check
    /// @return True if the address is an exemption manager
    function isExemptionManager(address account_) external view returns (bool) {
        return hasRole(EXEMPTION_MANAGER_ROLE, account_);
    }

    function erc20TransferFrom(
        address from_,
        address to_,
        uint256 value_
    ) external override returns (bool) {
        // Check for valid addresses
        if (from_ == address(0) || to_ == address(0)) revert InvalidRecipient();
        if (value_ == 0) revert InvalidAmount();

        // Add balance check before transfer
        if (balanceOf[from_] < value_) revert InsufficientBalance(value_, balanceOf[from_]);

        // Check if caller has sufficient allowance
        if (msg.sender != from_) {
            uint256 currentAllowance = allowance[from_][msg.sender];
            if (currentAllowance < value_) {
                revert InsufficientAllowance(value_, currentAllowance);
            }
            // Update allowance
            allowance[from_][msg.sender] = currentAllowance - value_;
            
        }

        // Perform the transfer using existing _transfer function
        _transfer(from_, to_, value_);
        return true;
    }

    // Helper function to get range info (for debugging and verification)
    function getRangeInfo(uint256 tokenId) public view returns (
        address owner,
        uint256 startId,
        uint256 size,
        bool isStaked
    ) {
        uint256 packed = _glyphData[tokenId];
        if (packed == 0) {
            // Use for loop for early/mid range finding
            for (uint256 i = tokenId; i > 0; i--) {
                packed = _glyphData[i];
                if (packed != 0) {
                    uint256 foundStartId = NGUBitMask.getStartId(packed);
                    uint256 foundSize = NGUBitMask.getStackSize(packed);
                    address foundOwner = NGUBitMask.getOwner(packed);
                    bool foundStaked = NGUBitMask.isStaked(packed);

                    if (tokenId >= foundStartId && tokenId < foundStartId + foundSize) {
                        return (foundOwner, foundStartId, foundSize, foundStaked);
                    }

                    if (foundStartId > tokenId) {
                        i = foundStartId;
                        continue;
                    }
                }
            }
            revert GlyphNotFound();
        }

        startId = NGUBitMask.getStartId(packed);
        size = NGUBitMask.getStackSize(packed);
        owner = NGUBitMask.getOwner(packed);
        isStaked = NGUBitMask.isStaked(packed);

        if (tokenId < startId || tokenId >= startId + size) {
            revert GlyphNotFound();
        }
    }

    /**
     * @notice Internal function to pack token data
     * @dev Critical for staking operations:
     * - Called when updating token state during stake/unstake
     * - Ensures consistent data format
     * - Validates data before storage
     * 
     * @param owner The owner address
     * @param startId The starting token ID
     * @param rangeSize The size of the token range
     * @param isStaked Whether the tokens are staked
     * @return The packed token data
     */
    function _packTokenData(
        address owner,
        uint256 startId,
        uint256 rangeSize,
        bool isStaked
    ) internal pure returns (uint256) {
        if (owner == address(0)) revert InvalidOwner();
        if (startId > (1 << 63) - 1) revert InvalidStartId(); // Max 63-bit integer (9.2 quintillion tokens)
        if (rangeSize > type(uint32).max) revert InvalidRangeSize();
        
        return NGUBitMask.packTokenData(owner, startId, rangeSize, isStaked);
    }

    /**
     * @notice Gets all unstaked token IDs in a user's queue
     * @dev Used by NGUStaking to:
     * - Validate tokens before staking
     * - Track unstaked tokens
     * - Verify queue state after operations
     * 
     * @param owner The address to query
     * @return tokenIds Array of unstaked token IDs in the user's queue
     */
    function getQueueGlyphIds(address owner) public view virtual override returns (uint256[] memory tokenIds) {
        uint256 totalTokens = 0;
        uint40 countCurrentId = _queueMetadata[owner].getHead();
        while(countCurrentId != 0) {
            totalTokens += _queueRanges[owner][countCurrentId].size;
            countCurrentId = _queueRanges[owner][countCurrentId].nextId;
        }

        tokenIds = new uint256[](totalTokens);
        uint256 index = 0;
        uint40 currentId = _queueMetadata[owner].getHead();
        while(currentId != 0 && index < totalTokens) {
            StackQueue.TokenRange storage range = _queueRanges[owner][currentId];
            for(uint40 i = 0; i < range.size;) {
                 if (index < totalTokens) {
                     tokenIds[index] = range.startId + i;
                 } else {
                     break;
                 }
                 unchecked { ++i; ++index; }
            }
            currentId = range.nextId;
        }
        return tokenIds;
    }
    
    /**
     * @notice Returns all ranges in a user's queue
     * @dev Used by NGUStaking for:
     * - Range management during staking/unstaking
     * - Queue validation and verification
     * - Debugging queue state
     * 
     * @param owner The address to query
     * @return rangesInfo Array of range information
     */
    function getQueueRanges(address owner) public view virtual override returns (
        INGU505Base.RangeInfo[] memory rangesInfo
    ) {
        uint256 rangeCount = 0;
        uint40 countCurrentId = _queueMetadata[owner].getHead();
        while (countCurrentId != 0) {
            rangeCount++;
            countCurrentId = _queueRanges[owner][countCurrentId].nextId;
        }

        rangesInfo = new INGU505Base.RangeInfo[](rangeCount);

        uint256 index = 0;
        uint40 currentId = _queueMetadata[owner].getHead();
        while (currentId != 0 && index < rangeCount) {
            StackQueue.TokenRange storage range = _queueRanges[owner][currentId];

            rangesInfo[index] = INGU505Base.RangeInfo({
                startId: range.startId,
                size: range.size,
                endId: range.startId + range.size - 1,
                isStaked: false,
                queueIndex: index
            });

            currentId = range.nextId;
            unchecked { ++index; }
        }

        return rangesInfo;
    }

    // ============ Interface Support ============
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AccessControl, IERC165) returns (bool) {
        return interfaceId == type(INGU505Base).interfaceId ||
               interfaceId == type(IERC165).interfaceId;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual override nonReentrant {
        if (deadline < block.timestamp) revert PermitDeadlineExpired();
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                        ),
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        if (recoveredAddress == address(0) || recoveredAddress != owner) {
            revert InvalidSigner();
        }

        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
        function _computeDomainSeparator() internal view virtual returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == _INITIAL_CHAIN_ID ? _INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
    }

        // Add ETH recovery functionality
    receive() external payable {}
    fallback() external payable {}
    
    function recoverETH() external nonReentrant {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = msg.sender.call{value: balance}("");
            require(success, "ETH recovery failed");
        }
    }

    /// @notice Sets the address of the authorized glyph minting hook.
    /// @dev Only callable by an address with HOOK_CONFIG_ROLE.
    /// @param hookAddress_ The address of the hook contract.
    function setGlyphMintingHookAddress(address hookAddress_) external virtual {
        if (!hasRole(HOOK_CONFIG_ROLE, msg.sender)) revert NotAuthorized();
        if (hookAddress_ == address(0)) revert InvalidAddress();
        glyphMintingHookAddress = hookAddress_;
        emit GlyphMintingHookAddressSet(hookAddress_);
    }

    /// @notice Modifier to ensure only the designated GlyphMintingHook can call a function
    modifier onlyGlyphMintingHook() {
        if (msg.sender != glyphMintingHookAddress) {
            revert NotAuthorizedHook();
        }
        _;
    }

    // --- Glyph Minting/Burning Logic for Hooks ---

    /**
     * @notice Called by the authorized GlyphMintingHook after a swap to adjust glyph balance.
     * @dev Calculates the required glyph change based on the ERC20 balance delta and applies it.
     *      Handles fractional amounts according to ERC404 floor logic.
     * @param recipient The address whose glyph balance needs adjustment.
     * @param erc20AmountDelta The change in the recipient's ERC20 balance (can be positive or negative).
     */
    function mintOrBurnGlyphForSwap(address recipient, int256 erc20AmountDelta) external virtual onlyGlyphMintingHook {
        if (recipient == address(0)) revert InvalidRecipient();

        uint256 currentErc20Balance = balanceOf[recipient];
        // Use SafeCast or require checks if underflow/overflow is a concern with large deltas
        uint256 newPotentialErc20Balance;
        if (erc20AmountDelta >= 0) {
             newPotentialErc20Balance = currentErc20Balance + uint256(erc20AmountDelta);
        } else {
            uint256 deltaAbs = uint256(-erc20AmountDelta);
            if (deltaAbs > currentErc20Balance) {
                 newPotentialErc20Balance = 0; // Cannot go below zero
            } else {
                 newPotentialErc20Balance = currentErc20Balance - deltaAbs;
            }
        }

        uint256 currentRequiredGlyphs = currentErc20Balance / units;
        uint256 newRequiredGlyphs = newPotentialErc20Balance / units;

        if (newRequiredGlyphs > currentRequiredGlyphs) {
            uint256 glyphsToMint = newRequiredGlyphs - currentRequiredGlyphs;
            console.log("Hook: Minting", glyphsToMint, "glyphs for", recipient);
            _mintGlyph(recipient, glyphsToMint);
        } else if (newRequiredGlyphs < currentRequiredGlyphs) {
            uint256 glyphsToBurn = currentRequiredGlyphs - newRequiredGlyphs;
            console.log("Hook: Burning", glyphsToBurn, "glyphs for", recipient);
            // Need to get the actual IDs to burn - burning a quantity isn't standard ERC721
            // This requires fetching the highest IDs owned by the user.
            // Placeholder: Call internal burn logic which should handle ID selection
            _burnGlyphQuantity(recipient, glyphsToBurn); // Assumes _burnGlyphQuantity exists and handles ID selection
        }
         // else glyphDelta == 0, do nothing
    }


    // --- Internal Core Logic ---

    /**
     * @notice Internal: Burns a specific quantity of glyphs owned by an account.
     * @dev Selects and burns the highest token IDs owned by the account.
     *      Requires implementation of how to efficiently find the highest IDs.
     * @param from The address from which to burn glyphs.
     * @param quantity The number of glyphs to burn.
     */
     function _burnGlyphQuantity(address from, uint256 quantity) internal virtual {
        uint256 ownedCount = _glyphBalance[from];
        if (quantity == 0) return; // Nothing to burn
        if (quantity > ownedCount) revert BurnAmountExceedsBalance(from, quantity, ownedCount);

        uint256 burnedSoFar = 0;
        while (burnedSoFar < quantity) {
            uint256 remainingToBurn = quantity - burnedSoFar;
            if (_queueMetadata[from].getSize() == 0) {
                // This should ideally not be reached if ownedCount check was accurate
                // and _glyphBalance is consistent with _queueMetadata.
                revert GlyphNotFound(); // Or some other appropriate error
            }

            uint40 headRangeId = _queueMetadata[from].getHead();
            if (headRangeId == 0) { // Should also not be reached if getSize > 0
                 revert GlyphNotFound();
            }
            StackQueue.TokenRange storage headRange = _queueRanges[from][headRangeId];
            
            uint256 burnInThisRange = remainingToBurn;
            if (burnInThisRange > headRange.size) {
                burnInThisRange = headRange.size;
            }

            _burnTokenRange(from, headRangeId, uint40(burnInThisRange));
            burnedSoFar += burnInThisRange;
        }
    }

    /**
     * @notice Internal: Mints a specific quantity of glyphs to an account.
     * @dev Finds the next available token IDs and mints them.
     */
    function _mintGlyph(address to, uint256 quantity) internal virtual {
        if (to == address(0)) revert InvalidRecipient();
        
        uint256 startTokenId = currentTokenId;        
        
        // Pack data and store for the range
        _glyphData[startTokenId] = _packTokenData(
            to,
            startTokenId,
            quantity,
            false // Not staked
        );
        
        currentTokenId = startTokenId + quantity;
        _glyphBalance[to] += quantity;

        // Initialize queue if it hasn't been used before
        uint256 packedMeta = _queueMetadata[to];
        if (packedMeta == 0) {
            packedMeta = QueueMetadataLib.pack(0, 0, 0, 1);
        }

        // Add to user's queue - append logic
        uint40 newRangeId;
        uint256 nextPackedMeta;
        (newRangeId, nextPackedMeta) = packedMeta.incrementNextRangeId();
        uint40 currentTailId = packedMeta.getTail();

        // Create and store the new range
        StackQueue.TokenRange storage newRange = _queueRanges[to][newRangeId];
        newRange.startId = uint40(startTokenId);
        newRange.size = uint40(quantity);
        newRange.owner = to;
        newRange.prevId = currentTailId;
        newRange.nextId = 0;

        // Update links and metadata
        if (currentTailId != 0) {
            _queueRanges[to][currentTailId].nextId = newRangeId;
        } else {
            nextPackedMeta = nextPackedMeta.setHead(newRangeId);
        }
        nextPackedMeta = nextPackedMeta.setTail(newRangeId);
        nextPackedMeta = nextPackedMeta.incrementSize();

        _queueMetadata[to] = nextPackedMeta;

        // Emit a single batch mint event instead of multiple individual events
        emit BatchMint(to, startTokenId, quantity);
    }
} 