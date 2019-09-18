pragma solidity ^0.4.25;
// solium-disable-next-line
pragma experimental ABIEncoderV2;

import "./interfaces/MTicketBrokerCore.sol";


contract MixinWrappers is MTicketBrokerCore {
    /**
     * @dev Redeems a winning ticket that has been signed by a sender and reveals the
     * recipient recipientRand that corresponds to the recipientRandHash included in the ticket
     * This function wraps `redeemWinningTicket()` and returns false if the underlying call reverts
     * @param _ticket Winning ticket to be redeemed in order to claim payment
     * @param _sig Sender's signature over the hash of `_ticket`
     * @param _recipientRand The preimage for the recipientRandHash included in `_ticket`
     * @return Boolean indicating whether the underlying `redeemWinningTicket()` call succeeded
     */
    function redeemWinningTicketNoRevert(
        Ticket memory _ticket,
        bytes _sig,
        uint256 _recipientRand
    )
        internal
        returns (bool success)
    {
        // ABI encode calldata for `redeemWinningTicket()`
        // A tuple type is used to represent the Ticket struct in the function signature
        bytes memory redeemWinningTicketCalldata = abi.encodeWithSignature(
            "redeemWinningTicket((address,address,uint256,uint256,uint256,bytes32,bytes),bytes,uint256)",
            _ticket,
            _sig,
            _recipientRand
        );

        // Call `redeemWinningTicket()`
        assembly {
            // call will return false upon hitting a revert
            success := call(
                gas,                                   // Forward all gas
                address,                               // Address of this contract (calling self)
                0,                                     // Send 0 ETH
                add(redeemWinningTicketCalldata, 32),  // Start of calldata (skip first 32 bytes containing array length)
                mload(redeemWinningTicketCalldata),    // Length of calldata (first 32 bytes contains array length)
                0,                                     // Ignore start of output
                0                                      // Ignore size of output
            )
        }
    }
}