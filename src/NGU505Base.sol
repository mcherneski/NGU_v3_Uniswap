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
// import {console2 as console} from "forge-std/console2.sol"; // Keep logs commented

// Custom Errors
error InvalidAddress();
error NotAuthorizedHook();
error InvalidQuantity();
error InvalidRecipient();
error BurnAmountExceedsBalance(address account, uint256 quantity, uint256 balance);
error MintToZeroAddress();
error InvalidExemption(address account);

// Debugging event
event DebugInvalidExemptionAttempt(address indexed account, bool value);

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

    /// @notice Mapping of addresses exempt from interacting with Glyphs. 
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
        // console.log("NGU505Base Constructor: msg.sender is:", msg.sender);
        // console.log("NGU505Base Constructor: initialMintRecipient_ for isGlyphTransferExempt is:", initialMintRecipient_);
        isGlyphTransferExempt[initialMintRecipient_] = true;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // Grant admin to deployer
        _grantRole(EXEMPTION_MANAGER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender); // Add MINTER_ROLE for deployer
        _grantRole(HOOK_CONFIG_ROLE, msg.sender);
        
        if (initialMintRecipient_ != msg.sender) { // If deployer is not also initial recipient
             _grantRole(BURNER_ROLE, initialMintRecipient_);
        }
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
        
        if (!isStaked) {
            // Unstaking: Burn the glyph(s) in this stack.
            // The original _glyphData update for staked=false is now handled by the burn.
            _burnGlyphStackOnUnstake(owner, startTokenId, stackSize);
        } else {
            // Staking: Update the token data with new staked status true.
            // This implies the glyph was previously not considered staked by this contract's flag.
            // If it was in a queue, an external mechanism should have removed it.
            _glyphData[startTokenId] = _packTokenData(
                owner,
                startTokenId,
                stackSize,
                true // isStaked is true here
            );
        }
    }

    // Helper function to burn a glyph stack when it's unstaked
    function _burnGlyphStackOnUnstake(address owner, uint256 startId, uint256 stackSize) internal {
        // Ensure there's actual data to burn; an already zeroed entry means it's gone or never existed.
        if (_glyphData[startId] == 0) revert GlyphNotFound(); 
        // It's important that stackSize correctly reflects the number of glyphs in this entry.
        if (stackSize == 0) revert InvalidQuantity(); // Cannot burn zero glyphs.

        // Check if owner's balance is sufficient, though for burning a specific stack,
        // the existence of _glyphData[startId] owned by 'owner' should imply this.
        // However, a direct balance check is safer.
        if (_glyphBalance[owner] < stackSize) revert InsufficientBalance(stackSize, _glyphBalance[owner]);

        _glyphBalance[owner] -= stackSize;
        _burnedTokens += stackSize;
        delete _glyphData[startId]; // Clear the data for this stack

        emit IGlyphEvents.BatchBurn(owner, uint40(startId), uint40(stackSize));
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
    ) internal virtual {
        if (from == address(0)) revert InvalidAddress();
        if (to == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance(amount, balanceOf[from]);

        bool isFromExempt = isGlyphTransferExempt[from];
        bool isToExempt = isGlyphTransferExempt[to];

        // uint256 nftsInTransferAmount = amount / units; // Unused variable
        // uint256 fromWholeTokensBefore = balanceOf[from] / units; // Unused variable
        // Store pre-transfer balances for fractional logic
        // uint256 fromBalanceBefore = balanceOf[from]; // Unused variable
        // uint256 toBalanceBefore = balanceOf[to]; // Unused variable

        // --- Update ERC20 Balances First ---
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit IERC20Events.Transfer(from, to, amount);
        // --- ERC20 Balances Updated ---

        if (isFromExempt && isToExempt) {
            // Case 1: Exempt Sender -> Exempt Receiver. No glyph action.
            // // console.log("Transfer Case 1: Exempt -> Exempt. No glyph action.");
        } else if (isFromExempt && !isToExempt) {
            // Case 2: Exempt Sender -> Non-Exempt Receiver.
            // NO glyph action here. Glyphs are only minted via the hook.
            // // console.log("Transfer Case 2: Exempt -> Non-Exempt. No direct glyph action.");
            // _handleFractionalChanges(to, false); // REMOVED
        } else if (!isFromExempt && isToExempt) {
            // Case 3: Non-Exempt Sender -> Exempt Receiver.
            // NO glyph action here. Glyphs are only affected by hook or direct burn calls.
            // // console.log("Transfer Case 3: Non-Exempt -> Exempt. No direct glyph action.");
            // _handleFractionalChanges(from, true); // REMOVED
        } else { // Case 4: Non-Exempt Sender -> Non-Exempt Receiver (P2P)
            // NO glyph action here. Glyphs are only affected by hook or direct burn calls.
            // // console.log("Transfer Case 4: Non-Exempt -> Non-Exempt. No direct glyph action.");
            // _handleFractionalChanges(from, true); // REMOVED
        }
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
        // console.log("NGU505Base: _setIsGlyphTransferExempt called with account:", account_, "and value:", value_); // Log before check
        if (account_ == address(0)) {
            // console.log("NGU505Base: Reverting due to address(0) in _setIsGlyphTransferExempt for account:", account_);
            emit DebugInvalidExemptionAttempt(account_, value_); // Emit event before revert
            revert InvalidExemption(account_);
        }
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
     * @notice Packs token data into a uint256 for efficient storage.
     * @param owner The address of the token owner.
     * @param startId The starting ID of the token range.
     * @param stackSize The number of tokens in the range.
     * @param isTokenStaked Boolean indicating if the token range is staked.
     * @return packed The packed token data.
     */
    function _packTokenData(address owner, uint256 startId, uint256 stackSize, bool isTokenStaked) internal pure returns (uint256 packed) {
        // Constants should match those in NGUBitMask.sol or be defined here if used directly often
        uint256 BITMASK_START_ID_BITS_LOCAL = (1 << 63) - 1; 
        uint256 BITMASK_STACK_SIZE_BITS_LOCAL = (1 << 32) - 1;
        uint256 BITMASK_STAKED_FLAG_LOCAL = uint256(1) << 255;

        require(owner != address(0), "Owner cannot be zero address");
        require(startId <= BITMASK_START_ID_BITS_LOCAL, "Start ID too large");
        require(stackSize <= BITMASK_STACK_SIZE_BITS_LOCAL, "Stack size too large");

        packed = uint256(uint160(owner)) |
                (startId << 160) |
                (stackSize << 223) | // Shift for stack size from NGUBitMask
                (isTokenStaked ? BITMASK_STAKED_FLAG_LOCAL : 0);
        return packed;
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
        // console.log("onlyGlyphMintingHook: msg.sender is", msg.sender, "glyphMintingHookAddress is", glyphMintingHookAddress);
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
        
        if (erc20AmountDelta == 0) {
            // console.log("Zero ERC20 delta, no glyph action taken.");
            return;
        }

        uint256 balanceBeforeDelta = balanceOf[recipient]; // Recipient's NGU balance BEFORE this swap's delta.
        uint256 balanceAfterDelta;

        if (erc20AmountDelta > 0) {
            // Recipient is receiving tokens.
            // This is safe from overflow unless total supply is near max uint256, very unlikely for balances.
            balanceAfterDelta = balanceBeforeDelta + uint256(erc20AmountDelta);
        } else { // erc20AmountDelta < 0
            // Recipient is sending tokens.
            uint256 amountSent = uint256(-erc20AmountDelta);
            // The main swap logic should ensure `balanceBeforeDelta >= amountSent`.
            // If not, the transaction would likely have failed before reaching the hook,
            // or this indicates an issue with how deltas are passed or accounted for.
            // For robustness, ensure no underflow if an unexpected state occurs.
            if (balanceBeforeDelta < amountSent) {
                // This case implies an inconsistency; either the user didn't have enough (should have reverted earlier)
                // or the delta calculation is problematic for the hook's perspective.
                // Setting balanceAfterDelta to 0 is a conservative approach for glyph calculation here.
                // Alternatively, consider reverting if this state is deemed impossible/critical.
                balanceAfterDelta = 0;
            } else {
                balanceAfterDelta = balanceBeforeDelta - amountSent;
            }
        }

        uint256 glyphsBefore = balanceBeforeDelta / units; // Use the state variable 'units'
        uint256 glyphsAfter = balanceAfterDelta / units;   // Use the state variable 'units'

        // console.log("Recipient:", recipient);
        // console.log("ERC20 Delta:", erc20AmountDelta);
        // console.log("Balance Before Delta:", balanceBeforeDelta);
        // console.log("Balance After Delta:", balanceAfterDelta);
        // console.log("Glyphs Before (using this.units):", glyphsBefore);
        // console.log("Glyphs After (using this.units):", glyphsAfter);
        // console.log("Hook using units value:", units);


        if (glyphsAfter > glyphsBefore) {
            uint256 glyphsToMint;
            unchecked {
                glyphsToMint = glyphsAfter - glyphsBefore;
            }
            if (glyphsToMint > 0) { // Ensure we only call _mintGlyph if there's something to mint
                _mintGlyph(recipient, glyphsToMint);
            }
            // console.log("Successfully minted glyphs:", glyphsToMint);
        } else if (glyphsBefore > glyphsAfter) {
            uint256 glyphsToBurn;
            unchecked {
                glyphsToBurn = glyphsBefore - glyphsAfter;
            }
            if (glyphsToBurn > 0) { // Ensure we only call _burnGlyphQuantity if there's something to burn
                _burnGlyphQuantity(recipient, glyphsToBurn);
            }
            // console.log("Successfully burned glyphs:", glyphsToBurn);
        } else {
            // console.log("No change in whole glyph count needed based on total ERC20 balance.");
        }
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
        if (quantity == 0) return;
        if (quantity > ownedCount) revert BurnAmountExceedsBalance(from, quantity, ownedCount);

        uint256 burnedSoFar = 0;
        // Iterate from the HEAD of the queue (lowest IDs first for burning)
        uint40 currentRangeId = _queueMetadata[from].getHead();

        while (burnedSoFar < quantity && currentRangeId != 0) {
            StackQueue.TokenRange storage currentRange = _queueRanges[from][currentRangeId];
            uint256 remainingToBurnOuter = quantity - burnedSoFar;
            
            uint40 burnInThisRange = uint40(remainingToBurnOuter);
            if (burnInThisRange > currentRange.size) {
                burnInThisRange = currentRange.size;
            }

            // Actual burning of tokens and modification of this range
            // For simplicity, this placeholder will just adjust numbers.
            // A real implementation needs to emit Transfer to address(0) for each token ID.
            
            uint256 actualStartIdToBurn = currentRange.startId; // This is uint40
            for (uint256 i = 0; i < burnInThisRange; ++i) {
                // Placeholder: In a real ERC721, you'd clear approvals & emit Transfer.
                // Here, we just account for it. The actual token ID is actualStartIdToBurn + i.
                // emit Transfer(from, address(0), actualStartIdToBurn + i); // Example
            }

            if (burnInThisRange == currentRange.size) {
                // Entire range is burned, remove it from queue
                uint40 nextId = currentRange.nextId;
                uint40 prevId = currentRange.prevId;
                if (prevId != 0) _queueRanges[from][prevId].nextId = nextId; else _queueMetadata[from] = _queueMetadata[from].setHead(nextId);
                if (nextId != 0) _queueRanges[from][nextId].prevId = prevId; else _queueMetadata[from] = _queueMetadata[from].setTail(prevId);
                delete _queueRanges[from][currentRangeId];
                 _queueMetadata[from] = _queueMetadata[from].decrementSize();
                currentRangeId = nextId; // Move to next range
            } else {
                // Partial range burn (from the start of this range)
                currentRange.startId += burnInThisRange;
                currentRange.size -= burnInThisRange;
                // currentRangeId remains the same, it's just smaller
            }
            
            delete _glyphData[actualStartIdToBurn]; // Delete original packed data for this range start

            if (currentRange.size > 0) { // If range still exists, update its packed data
                 _glyphData[currentRange.startId] = _packTokenData(from, currentRange.startId, currentRange.size, NGUBitMask.isStaked(_glyphData[currentRange.startId]));
            }


            _glyphBalance[from] -= burnInThisRange;
            _burnedTokens += burnInThisRange;
            burnedSoFar += burnInThisRange;
        }
    }

    /**
     * @notice Internal: Mints a specific quantity of glyphs to an account.
     * @dev Finds the next available token IDs and mints them.
     */
    function _mintGlyph(address to, uint256 quantity) internal virtual {
        // This is a simplified version of _mintGlyphsBatch for a single new range.
        // It's called by mintOrBurnGlyphForSwap.
        if (to == address(0)) revert InvalidRecipient();
        if (quantity == 0) return; // Nothing to mint
        
        uint256 newGlyphRangeStartId = currentTokenId;
        currentTokenId += quantity;

        // Queue Management for _mintGlyph (simplified append)
        uint256 packedUserMeta = _queueMetadata[to];
        uint40 userHead = packedUserMeta.getHead();
        uint40 userTail = packedUserMeta.getTail();
        uint40 userNextRangeId = packedUserMeta.getNextRangeId();
        uint40 userQueueSize = packedUserMeta.getSize();

        if (userNextRangeId == 0) userNextRangeId = 1;

        StackQueue.TokenRange storage newRange = _queueRanges[to][userNextRangeId];
        newRange.startId = uint40(newGlyphRangeStartId);
        newRange.size = uint32(quantity); // Assumes quantity fits uint32 for a single mint op
        newRange.owner = to;
        newRange.prevId = userTail;
        newRange.nextId = 0;

        if (userTail != 0) {
            _queueRanges[to][userTail].nextId = userNextRangeId;
        } else {
            userHead = userNextRangeId;
        }
        userTail = userNextRangeId;
        _queueMetadata[to] = QueueMetadataLib.pack(userHead, userTail, userNextRangeId + 1, userQueueSize + 1);

        _glyphBalance[to] += quantity;
        _glyphData[newGlyphRangeStartId] = _packTokenData(to, newGlyphRangeStartId, quantity, false);

        emit BatchMint(to, newGlyphRangeStartId, quantity); // Use BatchMint for consistency
    }

    function _mintGlyphsBatch(address to_, uint256 quantity_) internal {
        if (to_ == address(0)) revert InvalidRecipient();
        if (quantity_ == 0) return;

        uint256 newGlyphRangeStartId = currentTokenId; 
        currentTokenId += quantity_;

        uint256 packedUserMeta = _queueMetadata[to_];
        uint40 userHead = packedUserMeta.getHead();
        uint40 userTail = packedUserMeta.getTail();
        uint40 userNextRangeId = packedUserMeta.getNextRangeId(); 
        uint40 userQueueSize = packedUserMeta.getSize();

        if (userNextRangeId == 0) userNextRangeId = 1;

        StackQueue.TokenRange storage newRange = _queueRanges[to_][userNextRangeId];
        newRange.startId = uint40(newGlyphRangeStartId); 
        newRange.size = uint32(quantity_); 
        newRange.owner = to_;
        newRange.prevId = userTail; 
        newRange.nextId = 0; 

        if (userTail != 0) {
            _queueRanges[to_][userTail].nextId = userNextRangeId;
        } else {
            userHead = userNextRangeId;
        }
        userTail = userNextRangeId; 

        _queueMetadata[to_] = QueueMetadataLib.pack(userHead, userTail, userNextRangeId + 1, userQueueSize + 1);
        
        _glyphBalance[to_] += quantity_;
        _glyphData[newGlyphRangeStartId] = _packTokenData(to_, newGlyphRangeStartId, quantity_, false);

        emit BatchMint(to_, newGlyphRangeStartId, quantity_);
    }
} 