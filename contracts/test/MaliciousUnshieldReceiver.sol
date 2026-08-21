// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC7984Receiver } from "../interfaces/IERC7984Receiver.sol";
import { ebool, euint64, FHE } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @dev The wrapper's `unshield` overload this attacker re-enters.
interface IReentrantUnshield {
    function unshield(address from, address to, euint64 amount) external returns (euint64);
}

/**
 * @dev Test-only attacker probing the SECOND re-entrancy vector of the FHERC20
 * `*AndCall` flow on a wrapper: instead of sweeping via `confidentialTransfer`,
 * it re-enters `unshield` to burn its just-credited balance into a pending claim
 * for `attacker`, then returns `false` to request a refund.
 *
 * Without the reentrancy guard the refund's saturating `tryDecrease` would find a
 * zero balance (already burned) and no-op, so the sender is debited AND the
 * attacker walks away with a claim on the wrapper's underlying. The `nonReentrant`
 * guard on `unshield` makes the re-entrant call revert, which bubbles up through
 * the receiver callback and reverts the whole transfer.
 */
contract MaliciousUnshieldReceiver is IERC7984Receiver {
    address public immutable attacker;
    bool public reentered;

    constructor(address _attacker) {
        attacker = _attacker;
    }

    function onConfidentialTransferReceived(
        address /* operator */,
        address /* from */,
        euint64 amount,
        bytes calldata /* data */
    ) external returns (ebool) {
        // The forward leg already credited us `amount` and granted us ACL on the
        // handle, so we can unshield it right now — before the refund leg runs.
        if (!reentered) {
            reentered = true;
            IReentrantUnshield(msg.sender).unshield(address(this), attacker, amount);
        }

        ebool rejected = FHE.asEbool(false);
        FHE.allowTransient(rejected, msg.sender);
        return rejected;
    }
}
