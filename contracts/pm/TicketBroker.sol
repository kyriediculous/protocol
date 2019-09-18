pragma solidity ^0.4.25;
// solium-disable-next-line
pragma experimental ABIEncoderV2;

import "./mixins/MixinContractRegistry.sol";
import "./mixins/MixinReserve.sol";
import "./mixins/MixinTicketBrokerCore.sol";
import "./mixins/MixinTicketProcessor.sol";
import "./mixins/MixinWrappers.sol";


contract TicketBroker is
    MixinContractRegistry,
    MixinReserve,
    MixinTicketBrokerCore,
    MixinTicketProcessor,
    MixinWrappers
{ 
    // Check if current round is initialized
    modifier currentRoundInitialized() {
        require(roundsManager().currentRoundInitialized(), "current round is not initialized");
        _;
    }

    constructor(
        address _controller,
        uint256 _unlockPeriod,
        uint256 _ticketValidityPeriod
    )
        public
        MixinContractRegistry(_controller)
        MixinReserve()
        MixinTicketBrokerCore()
        MixinTicketProcessor()
    {
        unlockPeriod = _unlockPeriod;
        ticketValidityPeriod = _ticketValidityPeriod;
    }

    /**
     * @dev Sets unlockPeriod value. Only callable by the Controller owner
     * @param _unlockPeriod Value for unlockPeriod
     */
    function setUnlockPeriod(uint256 _unlockPeriod) external onlyControllerOwner {
        unlockPeriod = _unlockPeriod;
    }

    /**
     * @dev Sets ticketValidityPeriod value. Only callable by the Controller owner
     * @param _ticketValidityPeriod Value for ticketValidityPeriod
     */
    function setTicketValidityPeriod(uint256 _ticketValidityPeriod) external onlyControllerOwner {
        ticketValidityPeriod = _ticketValidityPeriod;
    }

    /**
     * @dev Adds ETH to the caller's deposit
     */
    function fundDeposit()
        external
        payable
        whenSystemNotPaused
        processDeposit(msg.sender, msg.value)
    {
        processFunding(msg.value);
    }

    /**
     * @dev Adds ETH to the caller's reserve
     */
    function fundReserve()
        external
        payable
        whenSystemNotPaused
        processReserve(msg.sender, msg.value)
    {
        processFunding(msg.value);
    }

    /**
     * @dev Adds ETH to the caller's deposit and reserve
     * @param _depositAmount Amount of ETH to add to the caller's deposit
     * @param _reserveAmount Amount of ETH to add to the caller's reserve
     */
    function fundDepositAndReserve(
        uint256 _depositAmount,
        uint256 _reserveAmount
    )
        external
        payable
        whenSystemNotPaused
        checkDepositReserveETHValueSplit(_depositAmount, _reserveAmount)
        processDeposit(msg.sender, _depositAmount)
        processReserve(msg.sender, _reserveAmount)
    {
        processFunding(msg.value);
    }

    /**
     * @dev Redeems a winning ticket that has been signed by a sender and reveals the
     * recipient recipientRand that corresponds to the recipientRandHash included in the ticket
     * @param _ticket Winning ticket to be redeemed in order to claim payment
     * @param _sig Sender's signature over the hash of `_ticket`
     * @param _recipientRand The preimage for the recipientRandHash included in `_ticket`
     */
    function redeemWinningTicket(
        Ticket memory _ticket,
        bytes _sig,
        uint256 _recipientRand
    )
        public
        currentRoundInitialized
        whenSystemNotPaused
    {
        bytes32 ticketHash = getTicketHash(_ticket);

        // Require a valid winning ticket for redemption
        requireValidWinningTicket(_ticket, ticketHash, _sig, _recipientRand);

        Sender storage sender = senders[_ticket.sender];

        // Require sender to be locked
        require(
            isLocked(sender),
            "sender is unlocked"
        );
        // Require either a non-zero deposit or non-zero reserve for the sender
        require(
            sender.deposit > 0 || remainingReserve(_ticket.sender) > 0,
            "sender deposit and reserve are zero"
        );

        // Mark ticket as used to prevent replay attacks involving redeeming
        // the same winning ticket multiple times
        usedTickets[ticketHash] = true;

        uint256 amountToTransfer = 0;

        if (_ticket.faceValue > sender.deposit) {
            // If ticket face value > sender's deposit then claim from
            // the sender's reserve

            amountToTransfer = sender.deposit.add(claimFromReserve(
                _ticket.sender,
                _ticket.recipient,
                _ticket.faceValue.sub(sender.deposit)
            ));

            sender.deposit = 0;
        } else {
            // If ticket face value <= sender's deposit then only deduct
            // from sender's deposit

            amountToTransfer = _ticket.faceValue;
            sender.deposit = sender.deposit.sub(_ticket.faceValue);
        }

        if (amountToTransfer > 0) {
            winningTicketTransfer(_ticket.recipient, amountToTransfer, _ticket.auxData);

            emit WinningTicketTransfer(_ticket.sender, _ticket.recipient, amountToTransfer);
        }

        emit WinningTicketRedeemed(
            _ticket.sender,
            _ticket.recipient,
            _ticket.faceValue,
            _ticket.winProb,
            _ticket.senderNonce,
            _recipientRand,
            _ticket.auxData
        );
    }

    /**
     * @dev Initiates the unlock period for the caller
     */
    function unlock() public whenSystemNotPaused {
        Sender storage sender = senders[msg.sender];

        require(
            sender.deposit > 0 || remainingReserve(msg.sender) > 0,
            "sender deposit and reserve are zero"
        );
        require(!_isUnlockInProgress(sender), "unlock already initiated");

        uint256 currentRound = roundsManager().currentRound();
        sender.withdrawRound = currentRound.add(unlockPeriod);

        emit Unlock(msg.sender, currentRound, sender.withdrawRound);
    }

    /**
     * @dev Cancels the unlock period for the caller
     */
    function cancelUnlock() public whenSystemNotPaused {
        Sender storage sender = senders[msg.sender];

        _cancelUnlock(sender, msg.sender);
    }

    /**
     * @dev Withdraws all ETH from the caller's deposit and reserve
     */
    function withdraw() public whenSystemNotPaused {
        Sender storage sender = senders[msg.sender];

        uint256 deposit = sender.deposit;
        uint256 reserve = remainingReserve(msg.sender);

        require(
            deposit > 0 || reserve > 0,
            "sender deposit and reserve are zero"
        );
        require(
            _isUnlockInProgress(sender),
            "no unlock request in progress"
        );
        require(
            !isLocked(sender),
            "account is locked"
        );

        sender.deposit = 0;
        clearReserve(msg.sender);

        withdrawTransfer(msg.sender, deposit.add(reserve));

        emit Withdrawal(msg.sender, deposit, reserve);
    }

    /**
     * @dev Redeems multiple winning tickets. The function will redeem all of the provided
     * tickets and handle any failures gracefully without reverting the entire function
     * @param _tickets Array of winning tickets to be redeemed in order to claim payment
     * @param _sigs Array of sender signatures over the hash of tickets (`_sigs[i]` corresponds to `_tickets[i]`)
     * @param _recipientRands Array of preimages for the recipientRandHash included in each ticket (`_recipientRands[i]` corresponds to `_tickets[i]`)
     */
    function batchRedeemWinningTickets(
        Ticket[] memory _tickets,
        bytes[] _sigs,
        uint256[] _recipientRands
    )
        public
        currentRoundInitialized
        whenSystemNotPaused
    {
        for (uint256 i = 0; i < _tickets.length; i++) {
            redeemWinningTicketNoRevert(
                _tickets[i],
                _sigs[i],
                _recipientRands[i]
            );
        }
    }
}