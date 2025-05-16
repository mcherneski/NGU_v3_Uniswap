// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {NGU505Base} from "./NGU505Base.sol";
import {INGU505Staking} from "./interfaces/INGU505Staking.sol";
import {NGUBitMask} from "./libraries/Masks.sol";
import {StackQueue} from "./libraries/StackQueue.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {INGU505Base} from "./interfaces/INGU505Base.sol";
import {INGU505Staking} from "./interfaces/INGU505Staking.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {console} from "forge-std/console.sol";
import {QueueMetadataLib} from "./libraries/QueueMetadataLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NGU Staking Contract
 * @notice Handles staking functionality for the NGU token using StackQueue for unstaked ranges.
 * @dev Flow of staking operations:
 * 1. User calls stake() with array of token IDs
 * 2. Contract validates tokens can be staked (ownership, not already staked via _glyphData)
 * 3. For each token:
 *    - Finds the containing range in _glyphData and corresponding rangeId in _sellingQueues
 *    - Removes/splits the range in _sellingQueues using StackQueue methods
 *    - Updates _glyphData for the staked token (size 1, staked=true)
 *    - Adds token to user's staked tokens array (_userStakedTokens)
 * 4. Updates ERC20 balances atomically at the end
 */
abstract contract NGUStaking is NGU505Base, INGU505Staking {
    using QueueMetadataLib for uint256;
    /// @notice Maximum tokens that can be staked in a single transaction
    uint256 internal constant MAX_STAKE_BATCH = 10;

    /// @notice Tracks staked ERC20 balances per user
    mapping(address => uint256) public stakedTokenBank;
    
    /// @notice Array of staked tokens per user
    mapping(address => uint256[]) private _userStakedTokens;
    
    /// @notice Maps tokenId -> packed(owner address, array index) for staked tokens
    /// @dev Enables O(1) lookups and removals from the staked tokens array
    /// Format: [160 bits owner address][96 bits array index]
    mapping(uint256 => uint256) private _stakedTokenIndexes;
    
    /// @notice Constants for bit positions in packed staked token index data
    uint256 private constant OWNER_BITS = 160;  // Address is 160 bits
    uint256 private constant INDEX_BITS = 96;   // Index uses 96 bits
    
    /// @notice Masks for extracting data from packed staked token index
    uint256 private constant OWNER_MASK = (1 << OWNER_BITS) - 1;
    uint256 private constant INDEX_MASK = ((1 << INDEX_BITS) - 1) << OWNER_BITS;

    /// @notice Restricts function access to admin role holders
    /// @dev Reverts with NotAuthorized if caller doesn't have admin role
    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        uint256 units_,
        uint256 maxTotalSupplyERC20_,
        address initialOwner_,
        address initialMintRecipient_
    ) NGU505Base(name_, symbol_, decimals_, units_, maxTotalSupplyERC20_, initialMintRecipient_) {
        // Roles (DEFAULT_ADMIN, EXEMPTION_MANAGER, BURNER for owner) are granted in NGU505Base constructor
        // to msg.sender (deployer). We assume initialOwner_ == deployer.
        // BURNER_ROLE is also granted to initialMintRecipient_ in NGU505Base.
        // If NumberGoUp needs specific MINTER_ROLE, grant it here:
        // _grantRole(MINTER_ROLE, initialOwner_);
    }

    /**
     * @notice Stakes multiple tokens in a single transaction
     * @dev Interaction flow:
     * 1. NGUStaking.stake() is called
     * 2. Validates basic conditions (array length, batch size)
     * 3. Checks ERC20 balance in NGU505Base
     * 4. Validate each token using _glyphData (owner, not staked)
     * 5. Stake each token using _stakeToken
     * 6. Updates ERC20 balances atomically
     * 7. Emits BatchStake event
     *
     * @param tokenIds Array of token IDs to stake
     * @return bool True if staking was successful
     */
    function stake(uint256[] calldata tokenIds) public override nonReentrant returns (bool) {
        uint256 stakeAmount = tokenIds.length;
        if (stakeAmount == 0) revert EmptyStakingArray();
        if (stakeAmount > MAX_STAKE_BATCH) revert INGU505Staking.BatchSizeExceeded();

        // Check ERC20 balance upfront
        uint256 erc20StakeAmount = stakeAmount * units;
        if (balanceOf[msg.sender] < erc20StakeAmount) 
            revert InsufficientBalance(erc20StakeAmount, balanceOf[msg.sender]);
    
        // First pass: validate all tokens using _glyphData
        for (uint256 i = 0; i < stakeAmount;) {
            uint256 tokenId = tokenIds[i];
            
            // Find token data using backward search
            uint256 packed = 0;
            address owner = address(0);
            for (uint256 j = tokenId; j > 0; --j) {
                 packed = _glyphData[j];
                 if (packed != 0) {
                     uint256 startId = NGUBitMask.getStartId(packed);
                     uint256 stackSize = NGUBitMask.getStackSize(packed);
                     if (tokenId >= startId && tokenId < startId + stackSize) {
                         owner = NGUBitMask.getOwner(packed);
                         break; // Found the range
                     }
                     if (startId > tokenId) { // Jump optimization
                         j = startId;
                         continue;
                     }
                 }
            }
            if (owner == address(0)) revert GlyphNotFound(); // Token or its range doesn't exist

            // Ownership check
            if (owner != msg.sender) revert NotAuthorized();

            unchecked { ++i; }
        }

        // Second pass: stake all tokens (only after all validations pass)
        for (uint256 i = 0; i < stakeAmount;) {
            _stakeToken(tokenIds[i]); // Call updated _stakeToken
            unchecked { ++i; }
        }

        // Update ERC20 balances atomically after all stakes succeed
        balanceOf[msg.sender] -= erc20StakeAmount;
        stakedTokenBank[msg.sender] += erc20StakeAmount;
        
        emit BatchStake(msg.sender, tokenIds);
        
        return true;
    }

    /**
     * @notice Internal function to stake a single token
     * @dev Handles state changes for staking: modifies _sellingQueues and _glyphData.
     *      Assumes validation (ownership, not already staked) was done in stake().
     * @param tokenId The ID of the token to stake
     */
    function _stakeToken(uint256 tokenId) internal {
        // Find the range containing tokenId again (needed for startId and size)
        uint256 foundStartId = 0;
        uint256 originalSize = 0;
        uint256 packedData = 0;
        for (uint256 j = tokenId; j > 0; --j) {
             packedData = _glyphData[j];
             if (packedData != 0) {
                 uint256 currentStartId = NGUBitMask.getStartId(packedData);
                 uint256 currentSize = NGUBitMask.getStackSize(packedData);
                 if (tokenId >= currentStartId && tokenId < currentStartId + currentSize) {
                     foundStartId = currentStartId;
                     originalSize = currentSize;
                     // Ensure owner matches msg.sender and it's not staked (redundant check)
                     if (NGUBitMask.getOwner(packedData) != msg.sender || NGUBitMask.isStaked(packedData)) {
                         revert InvalidState();
                     }
                     break; // Found the range
                 }
                 if (currentStartId > tokenId) { // Jump optimization
                     j = currentStartId;
                     continue;
                 }
             }
        }
        if (foundStartId == 0) revert InvalidState();

        // Find the rangeId in the StackQueue
        uint40 rangeId = 0;
        bool found = false;
        uint256 userPackedMeta = _queueMetadata[msg.sender];
        uint40 currentId = userPackedMeta.getHead();
        while (currentId != 0) {
            if (_queueRanges[msg.sender][currentId].startId == foundStartId) {
                rangeId = currentId;
                found = true;
                break;
            }
            currentId = _queueRanges[msg.sender][currentId].nextId;
        }

        if (!found) {
             // This indicates an inconsistency between _glyphData and _sellingQueues for unstaked tokens
             revert InvalidState(); // Or more specific error: UnstakedRangeNotFound
        }

        // --- Modify the queue ---
        if (originalSize == 1) {
            // Staking the only token in the range - remove the node
             _removeQueueRange(msg.sender, rangeId);
        } else if (tokenId == foundStartId) {
            // Staking the first token in the range - update the existing node
             uint40 newStartId = uint40(tokenId + 1);
             uint40 remainingSize = uint40(originalSize - 1);
             StackQueue.TokenRange storage rangeToUpdate = _queueRanges[msg.sender][rangeId];
             rangeToUpdate.startId = newStartId;
             rangeToUpdate.size = remainingSize;
             // Update _glyphData for the new start of the remaining range
             _glyphData[newStartId] = _packTokenData(msg.sender, newStartId, remainingSize, false);
        } else if (tokenId == foundStartId + originalSize - 1) {
            // Staking the last token in the range - update the existing node
            uint40 leftSize = uint40(originalSize - 1);
            StackQueue.TokenRange storage rangeToUpdate = _queueRanges[msg.sender][rangeId];
            rangeToUpdate.size = leftSize; // StartId remains the same
             // Update _glyphData for the existing startId with the reduced size
             _glyphData[foundStartId] = _packTokenData(msg.sender, foundStartId, leftSize, false);
        } else {
            // Staking in the middle - requires splitting the range node
             uint40 leftStartId = uint40(foundStartId);
             uint40 leftSize = uint40(tokenId - foundStartId);
             uint40 rightStartId = uint40(tokenId + 1);
             uint40 rightSize = uint40(originalSize - leftSize - 1);

             // Update the existing node (rangeId) to become the left part
             StackQueue.TokenRange storage leftRange = _queueRanges[msg.sender][rangeId];
             leftRange.size = leftSize;
             uint40 originalNextId = leftRange.nextId; // Store original next link

             // Allocate a new range ID for the right part
             uint40 rightRangeId;
             uint256 nextUserPackedMeta;
             userPackedMeta = _queueMetadata[msg.sender]; // Fetch fresh meta before incrementing nextId
             (rightRangeId, nextUserPackedMeta) = userPackedMeta.incrementNextRangeId(); // Note: uses potentially stale userPackedMeta, fetch fresh below
             _queueMetadata[msg.sender] = nextUserPackedMeta; // Update metadata immediately with new nextId

             // Create the right range node
             StackQueue.TokenRange storage rightRange = _queueRanges[msg.sender][rightRangeId];
             rightRange.startId = rightStartId;
             rightRange.size = rightSize;
             rightRange.owner = msg.sender;
             rightRange.prevId = rangeId; // Link right part to left part
             rightRange.nextId = originalNextId; // Link right part to original next

             // Update links
             leftRange.nextId = rightRangeId; // Link left part to new right part
             if (originalNextId != 0) {
                 _queueRanges[msg.sender][originalNextId].prevId = rightRangeId; // Link original next back to right part
             }

             // Fetch fresh metadata again *before* potentially modifying tail/size
             userPackedMeta = _queueMetadata[msg.sender];

             // Update metadata tail if the original range was the tail
             if (rangeId == userPackedMeta.getTail()) {
                 userPackedMeta = userPackedMeta.setTail(rightRangeId);
             }
             // Size of queue *ranges* increases by 1 due to split
             userPackedMeta = userPackedMeta.incrementSize();
             _queueMetadata[msg.sender] = userPackedMeta; // Store final metadata

             // Update _glyphData for both new range starts
             // _glyphData already updated for leftStartId (foundStartId) earlier if needed, but ensure it reflects new size
             _glyphData[leftStartId] = _packTokenData(msg.sender, leftStartId, leftSize, false);
             _glyphData[rightStartId] = _packTokenData(msg.sender, rightStartId, rightSize, false);
        }

        // --- Update _glyphData for the staked token ---
        // This overwrites any previous entry for tokenId if it was a startId
        _glyphData[tokenId] = _packTokenData(msg.sender, tokenId, 1, true); // size 1, staked = true

        // --- Update staking tracking arrays ---
        uint256 stakedIndex = _userStakedTokens[msg.sender].length;
        _userStakedTokens[msg.sender].push(tokenId);
        _stakedTokenIndexes[tokenId] = _packStakedIndex(msg.sender, stakedIndex);
    }

    /**
     * @notice Unstakes multiple tokens in a single transaction
     * @dev Interaction flow with NGU505Base:
     * 1. Validates basic conditions (array length, batch size)
     * 2. Checks staked balance
     * 3. First pass: validates all tokens can be unstaked using _glyphData and _stakedTokenIndexes
     * 4. Second pass: unstakes each token using _unstakeToken()
     * 5. Updates ERC20 balances atomically
     * 6. Emits BatchUnstake event
     *
     * Key interactions with NGU505Base (via StackQueue):
     * - Modifies _sellingQueues when adding unstaked tokens back (using prependRange)
     * - Handles potential merges of adjacent ranges in _sellingQueues
     * - Updates _glyphData to mark tokens as unstaked
     * - Updates balanceOf and stakedTokenBank mappings
     *
     * @param tokenIds Array of token IDs to unstake
     * @return bool True if unstaking was successful
     */
    function unstake(uint256[] calldata tokenIds) public override nonReentrant returns (bool) {
        if (tokenIds.length == 0) revert EmptyUnstakingArray();
        if (tokenIds.length > MAX_STAKE_BATCH) revert INGU505Staking.BatchSizeExceeded();

        uint256 totalUnstakeAmount = tokenIds.length * units;
        if (stakedTokenBank[msg.sender] < totalUnstakeAmount) 
            revert InsufficientBalance(totalUnstakeAmount, stakedTokenBank[msg.sender]);

        // First pass: validate all tokens can be unstaked without modifying state
        for (uint256 i = 0; i < tokenIds.length;) {
            uint256 tokenId = tokenIds[i];
            
            // Validate token state in _glyphData
            uint256 packed = _glyphData[tokenId];
            if (packed == 0) revert GlyphNotFound(); // Should exist as a staked token (size 1)
            if (!NGUBitMask.isStaked(packed)) revert GlyphNotStaked(tokenId);

            // Although staked tokens have size 1, check just in case of state corruption
            uint256 stackSize = NGUBitMask.getStackSize(packed);
            if (stackSize != 1) {
                 revert InvalidState();
            }

            address owner = NGUBitMask.getOwner(packed);
            if (owner != msg.sender) revert NotAuthorized();

            // Verify the token exists in the staked array tracking
            uint256 packedIndex = _stakedTokenIndexes[tokenId];
            if (packedIndex == 0) revert GlyphNotStaked(tokenId); // Internal consistency check

            address indexOwner = _getStakedOwner(packedIndex);
            if (indexOwner != msg.sender) revert NotAuthorized(); // Internal consistency check

            unchecked { ++i; }
        }
        
        // Second pass: actually unstake the tokens
        for (uint256 i = 0; i < tokenIds.length;) {
            _unstakeToken(tokenIds[i]);
            unchecked { ++i; }
        }

        // Update balances in one atomic operation
        uint256 actualUnstakeAmount = tokenIds.length * units; // Use actual length in case of future modifications
        stakedTokenBank[msg.sender] -= actualUnstakeAmount;
        balanceOf[msg.sender] += actualUnstakeAmount;

        // Emit a single batch event
        emit BatchUnstake(msg.sender, tokenIds);
        
        return true;
    }

    /**
     * @notice Internal function to unstake a single token
     * @dev Interaction flow with NGU505Base (StackQueue):
     * 1. Updates token data in _glyphData to mark as unstaked (size 1)
     * 2. Attempts to merge with adjacent ranges in _sellingQueues (if they exist and are owned by user)
     * 3. Adds token back to _sellingQueues (either merged or as a new range at the front)
     * 4. Updates staking tracking arrays (_userStakedTokens, _stakedTokenIndexes)
     *
     * @param tokenId The ID of the token to unstake
     */
    function _unstakeToken(uint256 tokenId) internal {
        // Mark as unstaked in glyphData (still size 1 for now)
        _glyphData[tokenId] = _packTokenData(msg.sender, tokenId, 1, false);

        // --- Merge Logic ---
        bool merged = false;
        uint40 prevStartId = 0; uint40 prevSize = 0; uint40 prevRangeId = 0; bool mergePrev = false;
        uint40 nextStartId = 0; uint40 nextSize = 0; uint40 nextRangeId = 0; bool mergeNext = false;

        // Check previous token (if tokenId > 0)
        if (tokenId > 0) {
            uint256 prevTokenId = tokenId - 1;
            // Check if prevTokenId is end of an existing unstaked range owned by sender
             uint256 prevPacked = _glyphData[prevTokenId];
             if (prevPacked != 0 && NGUBitMask.getOwner(prevPacked) == msg.sender && !NGUBitMask.isStaked(prevPacked)) {
                  // prevTokenId itself is unstaked, now find which range it belongs to and if it's the *end*
                  uint40 searchId = _queueMetadata[msg.sender].getHead();
                  while (searchId != 0) {
                      StackQueue.TokenRange storage range = _queueRanges[msg.sender][searchId];
                      if (prevTokenId >= range.startId && prevTokenId < range.startId + range.size) {
                           // Found the range, check if prevTokenId is the last token
                           if (range.startId + range.size - 1 == prevTokenId) {
                                prevRangeId = searchId;
                                prevStartId = range.startId;
                                prevSize = range.size;
                                mergePrev = true;
                           }
                           break; // Found the containing range
                      }
                      searchId = range.nextId;
                  }
             }
        }

        // Check next token
        uint256 nextTokenId = tokenId + 1;
        // Check if nextTokenId is the start of an existing unstaked range owned by sender
        uint256 nextPacked = _glyphData[nextTokenId];
        if (nextPacked != 0 && NGUBitMask.getOwner(nextPacked) == msg.sender && !NGUBitMask.isStaked(nextPacked)) {
            // nextTokenId starts a range, find its ID
            uint40 searchId = _queueMetadata[msg.sender].getHead();
             while (searchId != 0) {
                 StackQueue.TokenRange storage range = _queueRanges[msg.sender][searchId];
                 if (range.startId == nextTokenId) {
                      nextRangeId = searchId;
                      nextStartId = range.startId; // == nextTokenId
                      nextSize = range.size;
                      mergeNext = true;
                      break; // Found the range
                 }
                 // Optimization: if range.startId > nextTokenId, we won't find it later
                 if (range.startId > nextTokenId) break;
                 searchId = range.nextId;
             }
        }


        // Perform merges
        if (mergePrev && mergeNext) {
            // Merge previous, current (tokenId), and next
            // Absorb current and next into previous range
            uint40 newMergedSize = prevSize + 1 + nextSize;
             StackQueue.TokenRange storage prevRangeToUpdate = _queueRanges[msg.sender][prevRangeId]; // Get storage ref
             uint40 afterNextId = _queueRanges[msg.sender][nextRangeId].nextId; // Get this *before* modifying/deleting nextRangeId

             prevRangeToUpdate.size = newMergedSize; // Update size of prev range
             prevRangeToUpdate.nextId = afterNextId; // Link prev range directly to the one after next range
             if (afterNextId != 0) {
                 _queueRanges[msg.sender][afterNextId].prevId = prevRangeId;
             }

            // Remove the next range node (and update metadata)
            _removeQueueRange(msg.sender, nextRangeId);

            // Update metadata tail if next range was the tail (handle inside _removeQueueRange now)
            // We might still need this if _removeQueueRange doesn't know it was the tail *before* removal
            // Let's re-check metadata tail after removal
            uint256 userPackedMeta = _queueMetadata[msg.sender];
            if (userPackedMeta.getTail() == prevRangeId && afterNextId == 0) { // If prev is now the tail
                 // Tail is correctly set
            } else if (userPackedMeta.getTail() == 0 && prevRangeId == 0 && afterNextId == 0) {
                 // If the list became empty, tail is 0, which is correct
                 // This case shouldn't happen if prevRangeId exists, but covers edge cases
            } else if (prevRangeToUpdate.nextId == 0) {
                 // If the updated prev range is now the last item, set it as tail
                 _queueMetadata[msg.sender] = userPackedMeta.setTail(prevRangeId);
            }

            // Update glyphData
            _glyphData[prevStartId] = _packTokenData(msg.sender, prevStartId, newMergedSize, false);
            delete _glyphData[nextStartId]; // Clean up glyph data for start of removed 'next' range
            delete _glyphData[tokenId];    // Clean up glyph data for the single unstaked token

            merged = true;
        } else if (mergePrev) {
            // Merge previous and current (tokenId)
            // Absorb current into previous range
            uint40 newMergedSize = prevSize + 1;
            _queueRanges[msg.sender][prevRangeId].size = newMergedSize; // Update size

            // Update glyphData
            _glyphData[prevStartId] = _packTokenData(msg.sender, prevStartId, newMergedSize, false);
            delete _glyphData[tokenId]; // Clean up glyph data for the single unstaked token

            merged = true;
        } else if (mergeNext) {
            // Merge current (tokenId) and next
            // Absorb current into next range (update startId and size)
            uint40 newMergedSize = 1 + nextSize;
            StackQueue.TokenRange storage nextRange = _queueRanges[msg.sender][nextRangeId];
            nextRange.startId = uint40(tokenId); // New start ID is the current token
            nextRange.size = newMergedSize;

            // Update glyphData
            _glyphData[tokenId] = _packTokenData(msg.sender, tokenId, newMergedSize, false); // Update data for the new start
            delete _glyphData[nextStartId]; // Clean up glyph data for the original start of the next range

            merged = true;
        }

        // If no merge happened, add the single token as a new range to the front
        if (!merged) {
            // _glyphData[tokenId] is already set to size 1, unstaked
            // Prepend a new range node
             _prependQueueRange(msg.sender, uint40(tokenId), 1);
        }

        // --- Update staked tokens array tracking ---
        uint256 packedIndex = _stakedTokenIndexes[tokenId];
        // address indexOwner = _getStakedOwner(packedIndex); // Already validated owner == msg.sender
        uint256 index = _getStakedIndex(packedIndex);

        uint256[] storage userStakedTokens = _userStakedTokens[msg.sender];
        uint256 lastIndex = userStakedTokens.length - 1;

        if (index != lastIndex) {
            uint256 lastTokenId = userStakedTokens[lastIndex];
            userStakedTokens[index] = lastTokenId;

            // Update the index of the moved token
            _stakedTokenIndexes[lastTokenId] = _packStakedIndex(msg.sender, index);
        }

        // Remove the last element and clear the mapping
        userStakedTokens.pop();
        delete _stakedTokenIndexes[tokenId];
    }

    /**
     * @notice Checks if a token is staked using _glyphData
     * @dev Interaction with NGU505Base: Reads _glyphData.
     * @param tokenId_ The token ID to check
     * @return bool True if the token is staked
     */
    function isStaked(uint256 tokenId_) public view override returns (bool) {
        if (tokenId_ >= currentTokenId) revert TokenDoesNotExist();

        // Use backward search on _glyphData
        for (uint256 i = tokenId_; i > 0; i--) {
            uint256 packed = _glyphData[i];
            if (packed != 0) {
                uint256 startId = NGUBitMask.getStartId(packed);
                uint256 stackSize = NGUBitMask.getStackSize(packed);

                if (tokenId_ >= startId && tokenId_ < startId + stackSize) {
                    // Found the range, return its staked status
                    return NGUBitMask.isStaked(packed);
                }

                // Optimization: If the found range starts after the token we're looking for,
                // we can jump our search pointer back to the start of that range.
                if (startId > tokenId_) {
                    i = startId; // Set i to startId for the next iteration (loop does i--)
                    continue;
                }
                // If startId <= tokenId_, but token wasn't in range, continue searching backwards
            }
        }

        // If loop completes without finding the token in any range
        revert TokenDoesNotExist();
    }

    function stakedBalanceOf(address owner_) public view override returns (uint256) {
        return stakedTokenBank[owner_];
    }

    function getStakedGlyphs(address owner_) public view override returns (uint256[] memory tokenIds) {
        return _userStakedTokens[owner_];
    }

    /**
     * @notice Returns all token IDs owned by an address (staked and unstaked).
     * @dev Overrides NGU505Base.owned to provide a complete list.
     *      Combines results from the base function (unstaked) and _userStakedTokens (staked).
     *      Warning: This function can be gas-intensive due to array creation and copying.
     * @param owner_ The address to query.
     * @return allOwnedIds Array of all token IDs owned by the address.
     */
    function owned(address owner_) public view virtual override(NGU505Base) returns (uint256[] memory allOwnedIds) {
        // Get unstaked tokens from the base function
        uint256[] memory unstakedIds = super.owned(owner_);

        // Get staked tokens (storage reference)
        uint256[] storage stakedIdsStorage = _userStakedTokens[owner_];
        uint256 numStaked = stakedIdsStorage.length;

        // Calculate total size and create the result array
        uint256 totalOwned = unstakedIds.length + numStaked;
        allOwnedIds = new uint256[](totalOwned);

        // Copy unstaked IDs
        uint256 currentIndex = 0;
        for (uint256 i = 0; i < unstakedIds.length; ++i) {
            allOwnedIds[currentIndex++] = unstakedIds[i];
        }

        // Copy staked IDs
        for (uint256 i = 0; i < numStaked; ++i) {
            allOwnedIds[currentIndex++] = stakedIdsStorage[i];
        }

        // Return the combined array
        return allOwnedIds;
    }

    // --- Internal Helper Functions for Queue Manipulation ---

    /**
     * @notice Removes a range node from the queue's linked list and updates metadata.
     * @dev Does NOT delete associated _glyphData entries.
     * @param user The address of the queue owner.
     * @param rangeId The ID of the range node to remove.
     */
    function _removeQueueRange(address user, uint40 rangeId) internal {
        // Check if range exists before proceeding
        if (_queueRanges[user][rangeId].owner == address(0)) return; // Or revert

        StackQueue.TokenRange storage rangeToRemove = _queueRanges[user][rangeId];
        uint40 prevId = rangeToRemove.prevId;
        uint40 nextId = rangeToRemove.nextId;
        uint256 packedMeta = _queueMetadata[user];

        // Update adjacent links
        if (prevId != 0) { _queueRanges[user][prevId].nextId = nextId; }
        if (nextId != 0) { _queueRanges[user][nextId].prevId = prevId; }

        // Update metadata head/tail/size
        if (rangeId == packedMeta.getHead()) { packedMeta = packedMeta.setHead(nextId); }
        if (rangeId == packedMeta.getTail()) { packedMeta = packedMeta.setTail(prevId); }
        // Decrement size only if packedMeta is not zero (avoid underflow on empty queue delete attempt)
        if (packedMeta != 0) {
             uint40 currentSize = packedMeta.getSize();
             if (currentSize > 0) { // Ensure size is positive before decrementing
                  packedMeta = packedMeta.setSize(currentSize - 1);
             }
        }
        _queueMetadata[user] = packedMeta;

        // Delete the range node data
        delete _queueRanges[user][rangeId];
    }

    /**
     * @notice Adds a new range node to the front (head) of the queue's linked list.
     * @dev Does NOT create associated _glyphData entry (caller must handle).
     * @param user The address of the queue owner.
     * @param startId The start ID of the new range.
     * @param size The size of the new range.
     */
     function _prependQueueRange(address user, uint40 startId, uint40 size) internal {
         uint256 packedMeta = _queueMetadata[user];
         uint40 oldHeadId = packedMeta.getHead();
         uint40 newRangeId;
         uint256 nextPackedMeta;

         // Allocate new ID and update metadata nextId counter
         (newRangeId, nextPackedMeta) = packedMeta.incrementNextRangeId();

         // Create the new range node
         StackQueue.TokenRange storage newRange = _queueRanges[user][newRangeId];
         newRange.startId = startId;
         newRange.size = size;
         newRange.owner = user;
         newRange.prevId = 0; // It's the new head
         newRange.nextId = oldHeadId; // Link to the old head

         // Update links and metadata
         if (oldHeadId != 0) {
             _queueRanges[user][oldHeadId].prevId = newRangeId; // Link old head back to new head
         } else {
             // Queue was empty, new range is also the tail
             nextPackedMeta = nextPackedMeta.setTail(newRangeId);
         }
         nextPackedMeta = nextPackedMeta.setHead(newRangeId); // Set new head
         nextPackedMeta = nextPackedMeta.incrementSize(); // Increment range count

         _queueMetadata[user] = nextPackedMeta; // Store updated metadata
     }

    // --- Internal Helper Functions for Staked Index Packing ---

    function _packStakedIndex(address owner, uint256 index) internal pure returns (uint256) {
        return uint256(uint160(owner)) | (index << OWNER_BITS);
    }

    function _getStakedOwner(uint256 packed) internal pure returns (address) {
        return address(uint160(packed & OWNER_MASK));
    }

    function _getStakedIndex(uint256 packed) internal pure returns (uint256) {
        return (packed & INDEX_MASK) >> OWNER_BITS;
    }

    // --- Interface Support ---

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(NGU505Base, IERC165) returns (bool) {
        return interfaceId == type(INGU505Base).interfaceId ||
               interfaceId == type(INGU505Staking).interfaceId ||
               super.supportsInterface(interfaceId);
    }

}