pragma solidity ^0.4.25;

import "../ManagerProxyTarget.sol";
import "./IBondingManager.sol";
import "../libraries/SortedDoublyLL.sol";
import "../libraries/MathUtils.sol";
import "./libraries/EarningsPool.sol";
import "../token/ILivepeerToken.sol";
import "../token/IMinter.sol";
import "../rounds/IRoundsManager.sol";

import "openzeppelin-solidity/contracts/math/Math.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";


/**
 * @title BondingManager
 * @dev Manages bonding, transcoder and rewards/fee accounting related operations of the Livepeer protocol
 */
contract BondingManager is ManagerProxyTarget, IBondingManager {
    using SafeMath for uint256;
    using SortedDoublyLL for SortedDoublyLL.Data;
    using EarningsPool for EarningsPool.Data;

    // Time between unbonding and possible withdrawl in rounds
    uint64 public unbondingPeriod;
    // DEPRECATED - DO NOT USE
    uint256 public numActiveTranscodersDEPRECATED;
    // Max number of rounds that a caller can claim earnings for at once
    uint256 public maxEarningsClaimsRounds;

    // Represents a transcoder's current state
    struct Transcoder {
        uint256 lastRewardRound;                                        // Last round that the transcoder called reward
        uint256 rewardCut;                                              // % of reward paid to transcoder by a delegator
        uint256 feeShare;                                               // % of fees paid to delegators by transcoder
        uint256 pricePerSegmentDEPRECATED;                              // DEPRECATED - DO NOT USE
        uint256 pendingRewardCutDEPRECATED;                             // DEPRECATED - DO NOT USE
        uint256 pendingFeeShareDEPRECATED;                              // DEPRECATED - DO NOT USE
        uint256 pendingPricePerSegmentDEPRECATED;                       // DEPRECATED - DO NOT USE
        mapping (uint256 => EarningsPool.Data) earningsPoolPerRound;    // Mapping of round => earnings pool for the round
        uint256 lastActiveStakeUpdateRound;                             // Round for which the stake was last updated while the transcoder is active
        uint256 activationRound;                                        // Round in which the transcoder became active - 0 if inactive
    }

    // The various states a transcoder can be in
    enum TranscoderStatus { NotRegistered, Registered }

    // Represents a delegator's current state
    struct Delegator {
        uint256 bondedAmount;                    // The amount of bonded tokens
        uint256 fees;                            // The amount of fees collected
        address delegateAddress;                 // The address delegated to
        uint256 delegatedAmount;                 // The amount of tokens delegated to the delegator
        uint256 startRound;                      // The round the delegator transitions to bonded phase and is delegated to someone
        uint256 withdrawRoundDEPRECATED;         // DEPRECATED - DO NOT USE
        uint256 lastClaimRound;                  // The last round during which the delegator claimed its earnings
        uint256 nextUnbondingLockId;             // ID for the next unbonding lock created
        mapping (uint256 => UnbondingLock) unbondingLocks; // Mapping of unbonding lock ID => unbonding lock
    }

    // The various states a delegator can be in
    enum DelegatorStatus { Pending, Bonded, Unbonded }

    // Represents an amount of tokens that are being unbonded
    struct UnbondingLock {
        uint256 amount;              // Amount of tokens being unbonded
        uint256 withdrawRound;       // Round at which unbonding period is over and tokens can be withdrawn
    }

    // Keep track of the known transcoders and delegators
    mapping (address => Delegator) private delegators;
    mapping (address => Transcoder) private transcoders;

    // DEPRECATED - DO NOT USE
    // The function getTotalBonded() no longer uses this variable
    // and instead calculates the total bonded value separately
    uint256 private totalBondedDEPRECATED;

    // Candidate and reserve transcoders
    SortedDoublyLL.Data private transcoderPool;

    // DEPRECATED - DO NOT USE
    struct ActiveTranscoderSetDEPRECATED {
        address[] transcoders;
        mapping (address => bool) isActive;
        uint256 totalStake;
    }

    // DEPRECATED - DO NOT USE
    mapping (uint256 => ActiveTranscoderSetDEPRECATED) public activeTranscoderSetDEPRECATED;

    // The total active stake (sum of the stake of active set members) for the current round
    uint256 public currentRoundTotalActiveStake;
    // The total active stake (sum of the stake of active set members) for the next round
    uint256 public nextRoundTotalActiveStake;

    // Check if sender is TicketBroker
    modifier onlyTicketBroker() {
        require(msg.sender == controller.getContract(keccak256("TicketBroker")));
        _;
    }

    // Check if sender is RoundsManager
    modifier onlyRoundsManager() {
        require(msg.sender == controller.getContract(keccak256("RoundsManager")));
        _;
    }

    // Check if current round is initialized
    modifier currentRoundInitialized() {
        require(roundsManager().currentRoundInitialized());
        _;
    }

    // Automatically claim earnings from lastClaimRound through the current round
    modifier autoClaimEarnings() {
        updateDelegatorWithEarnings(msg.sender, roundsManager().currentRound());
        _;
    }

    /**
     * @dev BondingManager constructor. Only invokes constructor of base Manager contract with provided Controller address
     * @param _controller Address of Controller that this contract will be registered with
     */
    constructor(address _controller) public Manager(_controller) {}

    /**
     * @dev Set unbonding period. Only callable by Controller owner
     * @param _unbondingPeriod Rounds between unbonding and possible withdrawal
     */
    function setUnbondingPeriod(uint64 _unbondingPeriod) external onlyControllerOwner {
        unbondingPeriod = _unbondingPeriod;

        emit ParameterUpdate("unbondingPeriod");
    }

    /**
     * @dev Set number of active transcoders. Only callable by Controller owner
     * @param _numActiveTranscoders Number of active transcoders
     */
    function setNumActiveTranscoders(uint256 _numActiveTranscoders) external onlyControllerOwner {
        transcoderPool.setMaxSize(_numActiveTranscoders);

        emit ParameterUpdate("numActiveTranscoders");
    }

    /**
     * @dev Set max number of rounds a caller can claim earnings for at once. Only callable by Controller owner
     * @param _maxEarningsClaimsRounds Max number of rounds a caller can claim earnings for at once
     */
    function setMaxEarningsClaimsRounds(uint256 _maxEarningsClaimsRounds) external onlyControllerOwner {
        maxEarningsClaimsRounds = _maxEarningsClaimsRounds;

        emit ParameterUpdate("maxEarningsClaimsRounds");
    }

    /**
     * @dev The sender is declaring themselves as a candidate for active transcoding.
     * @param _rewardCut % of reward paid to transcoder by a delegator
     * @param _feeShare % of fees paid to delegators by a transcoder
     */
    function transcoder(uint256 _rewardCut, uint256 _feeShare)
        external
        whenSystemNotPaused
        currentRoundInitialized
    {
        Transcoder storage t = transcoders[msg.sender];
        Delegator storage del = delegators[msg.sender];

        // No transcoder operations can take place during the round lock period
        require(
            !roundsManager().currentRoundLocked(),
            "can't update transcoder params, current round is locked"
        );

        uint256 currentRound = roundsManager().currentRound();

        require(
            !isActiveTranscoder(msg.sender) || t.lastRewardRound == currentRound,
            "caller can't be active or must have already called reward for the current round"
        );

        // Reward cut must be a valid percentage
        require(MathUtils.validPerc(_rewardCut));
        // Fee share must be a valid percentage
        require(MathUtils.validPerc(_feeShare));

        // Must have a non-zero amount bonded to self
        require(del.delegateAddress == msg.sender && del.bondedAmount > 0);

        t.rewardCut = _rewardCut;
        t.feeShare = _feeShare;

        if (!transcoderPool.contains(msg.sender)) {
            tryToJoinActiveSet(msg.sender, del.delegatedAmount, currentRound.add(1));
        }

        emit TranscoderUpdate(msg.sender, _rewardCut, _feeShare, transcoderPool.contains(msg.sender));
    }

    /**
     * @dev Delegate stake towards a specific address.
     * @param _amount The amount of LPT to stake.
     * @param _to The address of the transcoder to stake towards.
     */
    function bond(
        uint256 _amount,
        address _to
    )
        external
        whenSystemNotPaused
        currentRoundInitialized
        autoClaimEarnings
    {
        Delegator storage del = delegators[msg.sender];

        uint256 currentRound = roundsManager().currentRound();
        // Amount to delegate
        uint256 delegationAmount = _amount;
        // Current delegate
        address currentDelegate = del.delegateAddress;

        if (delegatorStatus(msg.sender) == DelegatorStatus.Unbonded) {
            // New delegate
            // Set start round
            // Don't set start round if delegator is in pending state because the start round would not change
            del.startRound = currentRound.add(1);
            // Unbonded state = no existing delegate and no bonded stake
            // Thus, delegation amount = provided amount
        } else if (currentDelegate != address(0) && currentDelegate != _to) {
            // A registered transcoder cannot delegate its bonded stake toward another address
            // because it can only be delegated toward itself
            // In the future, if delegation towards another registered transcoder as an already
            // registered transcoder becomes useful (i.e. for transitive delegation), this restriction
            // could be removed
            require(!isRegisteredTranscoder(msg.sender), "registered transcoders can't delegate towards other addresses");
            // Changing delegate
            // Set start round
            del.startRound = currentRound.add(1);
            // Update amount to delegate with previous delegation amount
            delegationAmount = delegationAmount.add(del.bondedAmount);

            decreaseTotalStake(currentDelegate, del.bondedAmount);
        }

        // Delegation amount must be > 0 - cannot delegate to someone without having bonded stake
        require(delegationAmount > 0, "delegation amount must be greater than 0");
        // Update delegate
        del.delegateAddress = _to;
        // Update bonded amount
        del.bondedAmount = del.bondedAmount.add(_amount);
        
        increaseTotalStake(_to, delegationAmount);

        if (_amount > 0) {
            // Transfer the LPT to the Minter
            livepeerToken().transferFrom(msg.sender, minter(), _amount);
        }

        emit Bond(_to, currentDelegate, msg.sender, _amount, del.bondedAmount);
    }

    /**
     * @dev Unbond an amount of the delegator's bonded stake
     * @param _amount Amount of tokens to unbond
     */
    function unbond(uint256 _amount)
        external
        whenSystemNotPaused
        currentRoundInitialized
        autoClaimEarnings
    {
        // Caller must be in bonded state
        require(delegatorStatus(msg.sender) == DelegatorStatus.Bonded, "caller must be bonded");

        Delegator storage del = delegators[msg.sender];

        // Amount must be greater than 0
        require(_amount > 0, "unbonding amount must be greater than 0");
        // Amount to unbond must be less than or equal to current bonded amount 
        require(_amount <= del.bondedAmount, "amount is greater than bonded amount");

        address currentDelegate = del.delegateAddress;
        uint256 currentRound = roundsManager().currentRound();
        uint256 withdrawRound = currentRound.add(unbondingPeriod);
        uint256 unbondingLockId = del.nextUnbondingLockId;

        // Create new unbonding lock
        del.unbondingLocks[unbondingLockId] = UnbondingLock({
            amount: _amount,
            withdrawRound: withdrawRound
        });
        // Increment ID for next unbonding lock
        del.nextUnbondingLockId = unbondingLockId.add(1);
        // Decrease delegator's bonded amount
        del.bondedAmount = del.bondedAmount.sub(_amount);

        if (currentDelegate != msg.sender || del.bondedAmount > 0) {
            decreaseTotalStake(currentDelegate, _amount);
        } else {
            resignTranscoder(msg.sender);
            // Decrease delegate's delegated amount
            delegators[currentDelegate].delegatedAmount = delegators[currentDelegate].delegatedAmount.sub(_amount);
        }   

        // Check if delegator has a zero bonded amount
        // If so, update its delegation status
        if (del.bondedAmount == 0) {
            // Delegator no longer delegated to anyone if it does not have a bonded amount
            del.delegateAddress = address(0);
            // Delegator does not have a start round if it is no longer delegated to anyone
            del.startRound = 0;
        } 

        emit Unbond(currentDelegate, msg.sender, unbondingLockId, _amount, withdrawRound);
    }

    /**
     * @dev Rebond tokens for an unbonding lock to a delegator's current delegate while a delegator
     * is in the Bonded or Pending states
     * @param _unbondingLockId ID of unbonding lock to rebond with
     */
    function rebond(
        uint256 _unbondingLockId
    ) 
        external
        whenSystemNotPaused
        currentRoundInitialized 
        autoClaimEarnings
    {
        // Caller must not be an unbonded delegator
        require(delegatorStatus(msg.sender) != DelegatorStatus.Unbonded, "caller must be bonded");

        // Process rebond using unbonding lock
        processRebond(msg.sender, _unbondingLockId);
    }

    /**
     * @dev Rebond tokens for an unbonding lock to a delegate while a delegator
     * is in the Unbonded state
     * @param _to Address of delegate
     * @param _unbondingLockId ID of unbonding lock to rebond with
     */
    function rebondFromUnbonded(
        address _to,
        uint256 _unbondingLockId
    )
        external
        whenSystemNotPaused
        currentRoundInitialized
        autoClaimEarnings
    {
        // Caller must be an unbonded delegator
        require(delegatorStatus(msg.sender) == DelegatorStatus.Unbonded);

        // Set delegator's start round and transition into Pending state
        delegators[msg.sender].startRound = roundsManager().currentRound().add(1);
        // Set delegator's delegate
        delegators[msg.sender].delegateAddress = _to;
        // Process rebond using unbonding lock
        processRebond(msg.sender, _unbondingLockId);
    }

    /**
     * @dev Withdraws tokens for an unbonding lock that has existed through an unbonding period
     * @param _unbondingLockId ID of unbonding lock to withdraw with
     */
    function withdrawStake(uint256 _unbondingLockId)
        external
        whenSystemNotPaused
        currentRoundInitialized
    {
        Delegator storage del = delegators[msg.sender];
        UnbondingLock storage lock = del.unbondingLocks[_unbondingLockId];

        // Unbonding lock must be valid
        require(isValidUnbondingLock(msg.sender, _unbondingLockId));
        // Withdrawal must be valid for the unbonding lock i.e. the withdraw round is now or in the past
        require(lock.withdrawRound <= roundsManager().currentRound());

        uint256 amount = lock.amount;
        uint256 withdrawRound = lock.withdrawRound;
        // Delete unbonding lock
        delete del.unbondingLocks[_unbondingLockId];

        // Tell Minter to transfer stake (LPT) to the delegator
        minter().trustedTransferTokens(msg.sender, amount);

        emit WithdrawStake(msg.sender, _unbondingLockId, amount, withdrawRound);
    }

    /**
     * @dev Withdraws fees to the caller
     */
    function withdrawFees()
        external
        whenSystemNotPaused
        currentRoundInitialized
        autoClaimEarnings
    {
        // Delegator must have fees
        require(delegators[msg.sender].fees > 0);

        uint256 amount = delegators[msg.sender].fees;
        delegators[msg.sender].fees = 0;

        // Tell Minter to transfer fees (ETH) to the delegator
        minter().trustedWithdrawETH(msg.sender, amount);

        emit WithdrawFees(msg.sender);
    }

    /**
     * @dev Distribute the token rewards to transcoder and delegates.
     * Active transcoders call this once per cycle when it is their turn.
     */
    function reward() external whenSystemNotPaused currentRoundInitialized {
        uint256 currentRound = roundsManager().currentRound();

        // Sender must be an active transcoder
        require(isActiveTranscoder(msg.sender), "caller must be an active transcoder");

        // Transcoder must not have called reward for this round already
        require(transcoders[msg.sender].lastRewardRound != currentRound, "caller has already called reward for the current round");
        
        Transcoder storage t = transcoders[msg.sender];
        EarningsPool.Data storage earningsPool = t.earningsPoolPerRound[currentRound];

        // Set last round that transcoder called reward
        t.lastRewardRound = currentRound;
        earningsPool.setCommission(t.rewardCut, t.feeShare);

        // If transcoder didn't receive stake updates during the previous round and hasn't called reward for > 1 round
        // the 'totalStake' and 'claimableStake' on its 'EarningsPool' for the current round wouldn't be initialized
        // Thus we sync the the transcoder's stake to when it was last updated
        // 'updateTrancoderFees()' will set the update round to 'currentRound +1' so this synchronization shouldn't occur frequently
        uint256 lastUpdateRound = lastActiveStakeUpdateRound(msg.sender);
        if (lastUpdateRound < currentRound) {
            earningsPool.setStake(activeTranscoderTotalStake(msg.sender, lastUpdateRound));
        }

        // Create reward based on active transcoder's stake relative to the total active stake
        // rewardTokens = (current mintable tokens for the round * active transcoder stake) / total active stake
        uint256 rewardTokens = minter().createReward(earningsPool.totalStake, currentRoundTotalActiveStake);

        updateTranscoderWithRewards(msg.sender, rewardTokens, currentRound);

        emit Reward(msg.sender, rewardTokens);
    }

    /**
     * @dev Update transcoder's fee pool
     * @param _transcoder Transcoder address
     * @param _fees Fees from verified job claims
     */
    function updateTranscoderWithFees(
        address _transcoder,
        uint256 _fees,
        uint256 _round
    )
        external
        whenSystemNotPaused
        onlyTicketBroker
    {
        require(isRegisteredTranscoder(_transcoder), "transcoder must be registered");

        Transcoder storage t = transcoders[_transcoder];

        EarningsPool.Data storage earningsPool = t.earningsPoolPerRound[_round];

        // if transcoder hasn't called 'reward()' for '_round' its 'transcoderFeeShare' and 'transcoderRewardCut'
        // on the 'EarningsPool' for '_round' would not be initiated and the fee distribution wouldn't happen as expected
        if (_round > t.lastRewardRound) {
            earningsPool.setCommission(
                t.rewardCut,
                t.feeShare
            );
        }

        // Add fees to fee pool
        earningsPool.addToFeePool(_fees);
    }

    /**
     * @dev Slash a transcoder. Slashing can be invoked by the protocol or a finder.
     * @param _transcoder Transcoder address
     * @param _finder Finder that proved a transcoder violated a slashing condition. Null address if there is no finder
     * @param _slashAmount Percentage of transcoder bond to be slashed
     * @param _finderFee Percentage of penalty awarded to finder. Zero if there is no finder
     */
    function slashTranscoder(
        address _transcoder,
        address _finder,
        uint256 _slashAmount,
        uint256 _finderFee
    )
        external
        whenSystemNotPaused
        onlyTicketBroker
    {
        Delegator storage del = delegators[_transcoder];

        if (del.bondedAmount > 0) {
            uint256 penalty = MathUtils.percOf(delegators[_transcoder].bondedAmount, _slashAmount);

            // If registered transcoder, resign it
            resignTranscoder(_transcoder);

            // Decrease bonded stake
            del.bondedAmount = del.bondedAmount.sub(penalty);

            // If still bonded decrease delegate's delegated amount
            if (delegatorStatus(_transcoder) == DelegatorStatus.Bonded) {
                delegators[del.delegateAddress].delegatedAmount = delegators[del.delegateAddress].delegatedAmount.sub(penalty);
            }

            // Account for penalty
            uint256 burnAmount = penalty;

            // Award finder fee if there is a finder address
            if (_finder != address(0)) {
                uint256 finderAmount = MathUtils.percOf(penalty, _finderFee);
                minter().trustedTransferTokens(_finder, finderAmount);

                // Minter burns the slashed funds - finder reward
                minter().trustedBurnTokens(burnAmount.sub(finderAmount));

                emit TranscoderSlashed(_transcoder, _finder, penalty, finderAmount);
            } else {
                // Minter burns the slashed funds
                minter().trustedBurnTokens(burnAmount);

                emit TranscoderSlashed(_transcoder, address(0), penalty, 0);
            }
        } else {
            emit TranscoderSlashed(_transcoder, _finder, 0, 0);
        }
    }

    /**
     * @dev Claim token pools shares for a delegator from its lastClaimRound through the end round
     * @param _endRound The last round for which to claim token pools shares for a delegator
     */
    function claimEarnings(uint256 _endRound) external whenSystemNotPaused currentRoundInitialized {
        require(delegators[msg.sender].lastClaimRound < _endRound, "end round must be after last claim round");
        require(_endRound <= roundsManager().currentRound(), "end round must be before or equal to current round");

        updateDelegatorWithEarnings(msg.sender, _endRound);
    }

    /**
     * @dev Called during round initialization to set the total active stake for the round
     */
    function setCurrentRoundTotalActiveStake() external onlyRoundsManager {
        currentRoundTotalActiveStake = nextRoundTotalActiveStake;
    }

    /**
     * @dev Returns pending bonded stake for a delegator from its lastClaimRound through an end round
     * @param _delegator Address of delegator
     * @param _endRound The last round to compute pending stake from
     */
    function pendingStake(address _delegator, uint256 _endRound) public view returns (uint256) {
        uint256 currentRound = roundsManager().currentRound();
        Delegator storage del = delegators[_delegator];
        
        require(_endRound <= currentRound && _endRound > del.lastClaimRound, "end round must be before or equal to current round and after lastClaimRound");

        uint256 currentBondedAmount = del.bondedAmount;

        for (uint256 i = del.lastClaimRound + 1; i <= _endRound; i++) {
            EarningsPool.Data storage earningsPool = transcoders[del.delegateAddress].earningsPoolPerRound[i];

            bool isTranscoder = _delegator == del.delegateAddress;
            if (earningsPool.hasClaimableShares()) {
                // Calculate and add reward pool share from this round
                currentBondedAmount = currentBondedAmount.add(earningsPool.rewardPoolShare(currentBondedAmount, isTranscoder));
            }
        }

        return currentBondedAmount;
    }

    /**
     * @dev Returns pending fees for a delegator from its lastClaimRound through an end round
     * @param _delegator Address of delegator
     * @param _endRound The last round to compute pending fees from
     */
    function pendingFees(address _delegator, uint256 _endRound) public view returns (uint256) {
        uint256 currentRound = roundsManager().currentRound();
        Delegator storage del = delegators[_delegator];
        // End round must be before or equal to current round and after lastClaimRound
        require(_endRound <= currentRound && _endRound > del.lastClaimRound);

        uint256 currentFees = del.fees;
        uint256 currentBondedAmount = del.bondedAmount;

        for (uint256 i = del.lastClaimRound + 1; i <= _endRound; i++) {
            EarningsPool.Data storage earningsPool = transcoders[del.delegateAddress].earningsPoolPerRound[i];

            if (earningsPool.hasClaimableShares()) {
                bool isTranscoder = _delegator == del.delegateAddress;
                // Calculate and add fee pool share from this round
                currentFees = currentFees.add(earningsPool.feePoolShare(currentBondedAmount, isTranscoder));
                // Calculate new bonded amount with rewards from this round. Updated bonded amount used
                // to calculate fee pool share in next round
                currentBondedAmount = currentBondedAmount.add(earningsPool.rewardPoolShare(currentBondedAmount, isTranscoder));
            }
        }

        return currentFees;
    }

    /**
     * @dev Returns total bonded stake for an active transcoder
     * @param _transcoder Address of a transcoder
     */
    function activeTranscoderTotalStake(address _transcoder, uint256 _round) public view returns (uint256) {
        // will return 0 if transcoder is not active
        return transcoders[_transcoder].earningsPoolPerRound[_round].totalStake;
    }

    /**
     * @dev Returns total bonded stake for a transcoder
     * @param _transcoder Address of transcoder
     */
    function transcoderTotalStake(address _transcoder) public view returns (uint256) {
        return delegators[_transcoder].delegatedAmount;
    }

    /**
     * @dev Computes delegator status
     * @param _delegator Address of delegator
     */
    function delegatorStatus(address _delegator) public view returns (DelegatorStatus) {
        Delegator storage del = delegators[_delegator];

        if (del.bondedAmount == 0) {
            // Delegator unbonded all its tokens
            return DelegatorStatus.Unbonded;
        } else if (del.startRound > roundsManager().currentRound()) {
            // Delegator round start is in the future
            return DelegatorStatus.Pending;
        } else if (del.startRound > 0 && del.startRound <= roundsManager().currentRound()) {
            // Delegator round start is now or in the past
            return DelegatorStatus.Bonded;
        } else {
            // Default to unbonded
            return DelegatorStatus.Unbonded;
        }
    }

    /**
     * @dev Return transcoder information
     * @param _transcoder Address of transcoder
     */
    function getTranscoder(
        address _transcoder
    )
        public
        view
        returns (uint256 lastRewardRound, uint256 rewardCut, uint256 feeShare, uint256 activationRound)
    {
        Transcoder storage t = transcoders[_transcoder];

        lastRewardRound = t.lastRewardRound;
        rewardCut = t.rewardCut;
        feeShare = t.feeShare;
        activationRound = t.activationRound;
    }

    /**
     * @dev Return transcoder's token pools for a given round
     * @param _transcoder Address of transcoder
     * @param _round Round number
     */
    function getTranscoderEarningsPoolForRound(
        address _transcoder,
        uint256 _round
    )
        public
        view
        returns (uint256 rewardPool, uint256 feePool, uint256 totalStake, uint256 claimableStake, uint256 transcoderRewardCut, uint256 transcoderFeeShare, uint256 transcoderRewardPool, uint256 transcoderFeePool, bool hasTranscoderRewardFeePool)
    {
        EarningsPool.Data storage earningsPool = transcoders[_transcoder].earningsPoolPerRound[_round];

        rewardPool = earningsPool.rewardPool;
        feePool = earningsPool.feePool;
        totalStake = earningsPool.totalStake;
        claimableStake = earningsPool.claimableStake;
        transcoderRewardCut = earningsPool.transcoderRewardCut;
        transcoderFeeShare = earningsPool.transcoderFeeShare;
        transcoderRewardPool = earningsPool.transcoderRewardPool;
        transcoderFeePool = earningsPool.transcoderFeePool;
        hasTranscoderRewardFeePool = earningsPool.hasTranscoderRewardFeePool;
    }

    /**
     * @dev Return delegator info
     * @param _delegator Address of delegator
     */
    function getDelegator(
        address _delegator
    )
        public
        view
        returns (uint256 bondedAmount, uint256 fees, address delegateAddress, uint256 delegatedAmount, uint256 startRound, uint256 lastClaimRound, uint256 nextUnbondingLockId)
    {
        Delegator storage del = delegators[_delegator];

        bondedAmount = del.bondedAmount;
        fees = del.fees;
        delegateAddress = del.delegateAddress;
        delegatedAmount = del.delegatedAmount;
        startRound = del.startRound;
        lastClaimRound = del.lastClaimRound;
        nextUnbondingLockId = del.nextUnbondingLockId;
    }

    /**
     * @dev Return delegator's unbonding lock info
     * @param _delegator Address of delegator
     * @param _unbondingLockId ID of unbonding lock
     */
    function getDelegatorUnbondingLock(
        address _delegator,
        uint256 _unbondingLockId
    ) 
        public
        view
        returns (uint256 amount, uint256 withdrawRound) 
    {
        UnbondingLock storage lock = delegators[_delegator].unbondingLocks[_unbondingLockId];

        return (lock.amount, lock.withdrawRound);
    }

    /**
     * @dev Returns max size of transcoder pool
     */
    function getTranscoderPoolMaxSize() public view returns (uint256) {
        return transcoderPool.getMaxSize();
    }

    /**
     * @dev Returns size of transcoder pool
     */
    function getTranscoderPoolSize() public view returns (uint256) {
        return transcoderPool.getSize();
    }

    /**
     * @dev Returns transcoder with most stake in pool
     */
    function getFirstTranscoderInPool() public view returns (address) {
        return transcoderPool.getFirst();
    }

    /**
     * @dev Returns next transcoder in pool for a given transcoder
     * @param _transcoder Address of a transcoder in the pool
     */
    function getNextTranscoderInPool(address _transcoder) public view returns (address) {
        return transcoderPool.getNext(_transcoder);
    }

    /**
     * @dev Return total bonded tokens
     */
    function getTotalBonded() public view returns (uint256) {
        uint256 totalBonded = 0;
        uint256 totalTranscoders = transcoderPool.getSize();
        address currentTranscoder = transcoderPool.getFirst();

        for (uint256 i = 0; i < totalTranscoders; i++) {
            // Add current transcoder's total delegated stake to total bonded counter
            totalBonded = totalBonded.add(transcoderTotalStake(currentTranscoder));
            // Get next transcoder in the pool
            currentTranscoder = transcoderPool.getNext(currentTranscoder);
        }

        return totalBonded;
    }

    /**
     * @dev Return the round for which a transcoder's stake was last updated
     * @param _transcoder Transcoder address
     */
    function lastActiveStakeUpdateRound(address _transcoder) public view returns (uint256) {
        return transcoders[_transcoder].lastActiveStakeUpdateRound;
    }

   /**
     * @dev Return whether a transcoder is active for the current round
     * @param _transcoder Transcoder address
     */
    function isActiveTranscoder(address _transcoder) public view returns (bool) {
        uint256 activationRound = transcoders[_transcoder].activationRound;
        return activationRound != 0 && activationRound <= roundsManager().currentRound();
    }

    /**
     * @dev Return whether a transcoder is registered
     * @param _transcoder Transcoder address
     */
    function isRegisteredTranscoder(address _transcoder) public view returns (bool) {
        Delegator storage d = delegators[_transcoder];
        return d.delegateAddress == _transcoder && d.bondedAmount > 0;
    }

    /**
     * @dev Return whether an unbonding lock for a delegator is valid
     * @param _delegator Address of delegator
     * @param _unbondingLockId ID of unbonding lock
     */
    function isValidUnbondingLock(address _delegator, uint256 _unbondingLockId) public view returns (bool) {
        // A unbonding lock is only valid if it has a non-zero withdraw round (the default value is zero)
        return delegators[_delegator].unbondingLocks[_unbondingLockId].withdrawRound > 0;
    }

    /**
     * @dev Increase the total stake for a transcoder and updates its 'lastActiveStakeUpdateRound'
     * @param _transcoder The transcoder to increase the stake for
     * @param _amount The amount to increase the stake for '_transcoder' by
     */
    function increaseTotalStake(address _transcoder, uint256 _amount) internal {
        if (isRegisteredTranscoder(_transcoder)) {
            uint256 newStake = transcoderTotalStake(_transcoder).add(_amount);
            uint256 currentRound = roundsManager().currentRound();
            uint256 nextRound = currentRound.add(1);

            // If the transcoder is already in the active set update its stake and return
            if (transcoderPool.contains(_transcoder)) {
                transcoderPool.updateKey(_transcoder, newStake, address(0), address(0));
                nextRoundTotalActiveStake = nextRoundTotalActiveStake.add(_amount);
                Transcoder storage t = transcoders[_transcoder];
                t.earningsPoolPerRound[nextRound].setStake(newStake);
                t.lastActiveStakeUpdateRound = nextRound;
            } else {
                // Check if the transcoder is eligible to join the active set in the update round
                tryToJoinActiveSet(_transcoder, newStake, nextRound);
            }
        }

        // Increase delegate's delegated amount
        delegators[_transcoder].delegatedAmount = delegators[_transcoder].delegatedAmount.add(_amount);
    }

    /**
     * @dev Decrease the total stake for a transcoder and updates its 'lastActiveStakeUpdateRound'
     * @param _transcoder The transcoder to decrease the stake for
     * @param _amount The amount to decrease the stake for '_transcoder' by
     */
    function decreaseTotalStake(address _transcoder, uint256 _amount) internal {
        if (isRegisteredTranscoder(_transcoder)) {
            if (!transcoderPool.contains(_transcoder)) {
                return;
            }

            uint256 newStake = transcoderTotalStake(_transcoder).sub(_amount);
            uint256 nextRound = roundsManager().currentRound().add(1);

            transcoderPool.updateKey(_transcoder, newStake, address(0), address(0));
            nextRoundTotalActiveStake = nextRoundTotalActiveStake.sub(_amount);
            Transcoder storage t = transcoders[_transcoder];
            t.lastActiveStakeUpdateRound = nextRound;
            t.earningsPoolPerRound[nextRound].setStake(newStake);
        }

        // Decrease old delegate's delegated amount
        delegators[_transcoder].delegatedAmount = delegators[_transcoder].delegatedAmount.sub(_amount);
    }

    /**
     * @dev Tries to add a transcoder to active transcoder pool, evicts the active transcoder with the lowest stake if the pool is full
     * @param _transcoder The transcoder to insert into the transcoder pool
     * @param _totalStake The total stake for '_transcoder'
     * @param _activationRound The round in which the transcoder should become active
     */
    function tryToJoinActiveSet(address _transcoder, uint256 _totalStake, uint256 _activationRound) internal {
        uint256 pendingNextRoundTotalActiveStake = nextRoundTotalActiveStake;

        if (transcoderPool.isFull()) {
            address lastTranscoder = transcoderPool.getLast();
            uint256 lastStake = transcoderTotalStake(lastTranscoder);

            // If the pool is full and the transcoder has less stake than the least stake transcoder in the pool
            // then the transcoder is unable to join the active set for the next round
            if (_totalStake <= lastStake) {
                return;
            }

            // Evict the least stake transcoder from the active set for the next round
            transcoderPool.remove(lastTranscoder);
            transcoders[lastTranscoder].activationRound = 0;
            transcoders[lastTranscoder].earningsPoolPerRound[_activationRound].setStake(0);
            pendingNextRoundTotalActiveStake = pendingNextRoundTotalActiveStake.sub(lastStake);

            emit TranscoderEvicted(lastTranscoder);
        }

        transcoderPool.insert(_transcoder, _totalStake, address(0), address(0));
        pendingNextRoundTotalActiveStake = pendingNextRoundTotalActiveStake.add(_totalStake);
        Transcoder storage t = transcoders[_transcoder];
        t.lastActiveStakeUpdateRound = _activationRound;
        t.activationRound = _activationRound;
        t.earningsPoolPerRound[_activationRound].setStake(_totalStake);
        nextRoundTotalActiveStake = pendingNextRoundTotalActiveStake;
    }

    /**
     * @dev Remove transcoder
     */
    function resignTranscoder(address _transcoder) internal {
        uint256 transcoderStake = transcoderTotalStake(_transcoder);
        uint256 currentRound = roundsManager().currentRound();
        transcoderPool.remove(_transcoder);
        currentRoundTotalActiveStake = currentRoundTotalActiveStake.sub(transcoderStake);
        nextRoundTotalActiveStake = nextRoundTotalActiveStake.sub(transcoderStake);
        transcoders[_transcoder].earningsPoolPerRound[currentRound].setStake(0);
        transcoders[_transcoder].activationRound = 0;
        emit TranscoderResigned(_transcoder);
    }

    /**
     * @dev Update a transcoder with rewards
     * @param _transcoder Address of transcoder
     * @param _rewards Amount of rewards
     * @param _round Round that transcoder is updated
     */
    function updateTranscoderWithRewards(address _transcoder, uint256 _rewards, uint256 _round) internal {
        Transcoder storage t = transcoders[_transcoder];
        Delegator storage del = delegators[_transcoder];

        EarningsPool.Data storage earningsPool = t.earningsPoolPerRound[_round];
        // Add rewards to reward pool
        earningsPool.addToRewardPool(_rewards);
        // Update transcoder's total stake with rewards
        uint256 newStake = transcoderTotalStake(_transcoder).add(_rewards);
        // Update transcoder's delegated amount with rewards
        del.delegatedAmount = del.delegatedAmount.add(_rewards);
        transcoderPool.updateKey(_transcoder, newStake, address(0), address(0));
        if (_round == roundsManager().currentRound()) {
            uint256 nextRound = _round.add(1);
            t.earningsPoolPerRound[nextRound].setStake(newStake);
            t.lastActiveStakeUpdateRound = nextRound;
            nextRoundTotalActiveStake = nextRoundTotalActiveStake.add(_rewards);
        }
    }

    /**
     * @dev Update a delegator with token pools shares from its lastClaimRound through a given round
     * @param _delegator Delegator address
     * @param _endRound The last round for which to update a delegator's stake with token pools shares
     */
    function updateDelegatorWithEarnings(address _delegator, uint256 _endRound) internal {
        Delegator storage del = delegators[_delegator];

        // Only will have earnings to claim if you have a delegate
        // If not delegated, skip the earnings claim process
        if (del.delegateAddress != address(0)) {
            // Cannot claim earnings for more than maxEarningsClaimsRounds
            // This is a number to cause transactions to fail early if
            // we know they will require too much gas to loop through all the necessary rounds to claim earnings
            // The user should instead manually invoke `claimEarnings` to split up the claiming process
            // across multiple transactions
            require(_endRound.sub(del.lastClaimRound) <= maxEarningsClaimsRounds, "too many rounds to claim through");

            uint256 currentBondedAmount = del.bondedAmount;
            uint256 currentFees = del.fees;

            for (uint256 i = del.lastClaimRound + 1; i <= _endRound; i++) {
                EarningsPool.Data storage earningsPool = transcoders[del.delegateAddress].earningsPoolPerRound[i];

                if (earningsPool.hasClaimableShares()) {
                    bool isTranscoder = _delegator == del.delegateAddress;

                    (uint256 fees, uint256 rewards) = earningsPool.claimShare(currentBondedAmount, isTranscoder);

                    currentFees = currentFees.add(fees);
                    currentBondedAmount = currentBondedAmount.add(rewards);
                }
            }

            // Rewards are bonded by default
            del.bondedAmount = currentBondedAmount;
            del.fees = currentFees;
        }

        del.lastClaimRound = _endRound;
    }

    /**
     * @dev Update the state of a delegator and its delegate by processing a rebond using an unbonding lock
     * @param _delegator Address of delegator
     * @param _unbondingLockId ID of unbonding lock to rebond with
     */
    function processRebond(address _delegator, uint256 _unbondingLockId) internal {
        Delegator storage del = delegators[_delegator];
        UnbondingLock storage lock = del.unbondingLocks[_unbondingLockId];

        // Unbonding lock must be valid
        require(isValidUnbondingLock(_delegator, _unbondingLockId));

        uint256 amount = lock.amount;
        // Increase delegator's bonded amount
        del.bondedAmount = del.bondedAmount.add(amount);

        // Delete lock
        delete del.unbondingLocks[_unbondingLockId];

        increaseTotalStake(del.delegateAddress, amount);

        emit Rebond(del.delegateAddress, _delegator, _unbondingLockId, amount);
    }

    /**
     * @dev Return LivepeerToken interface
     */
    function livepeerToken() internal view returns (ILivepeerToken) {
        return ILivepeerToken(controller.getContract(keccak256("LivepeerToken")));
    }

    /**
     * @dev Return Minter interface
     */
    function minter() internal view returns (IMinter) {
        return IMinter(controller.getContract(keccak256("Minter")));
    }

    /**
     * @dev Return RoundsManager interface
     */
    function roundsManager() internal view returns (IRoundsManager) {
        return IRoundsManager(controller.getContract(keccak256("RoundsManager")));
    }
}
