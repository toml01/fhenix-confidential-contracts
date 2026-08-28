// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { sharedEbool, sharedEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @dev Interface for contracts that can receive FHERC20 transfers with a callback.
///
/// Both encrypted values on this boundary use the `sharedXX` types, because this is a
/// contract-to-contract handoff on a function that cannot authenticate its caller. A bare
/// `euint64` parameter here would be a decryption oracle: FHE operations check the permission of
/// the contract performing them, so any caller could pass any handle THIS contract is allowed on
/// (including its own stored state) and read back a value derived from it. `sharedEuint64` closes
/// that by recording who shared the value, for this transaction only, directed at this contract by
/// name.
///
/// Implementers must therefore:
///   - unwrap the amount with `FHE.receiveEuint64Param(amount)`, which requires the sharer to be
///     `msg.sender` (the token) and reverts `NotShared` / `UnexpectedSharer` otherwise; and
///   - return `FHE.shareEbool(result, msg.sender)` rather than granting the token access out of
///     band with `FHE.allowTransient`.
///
/// The received handle carries transient access only. To keep the amount past this transaction,
/// call `FHE.allowThis` on the unwrapped `euint64`, not on the `sharedEuint64`.
interface IERC7984Receiver {
    /**
     * @dev Called upon receiving a confidential token transfer. Returns an encrypted boolean indicating success
     * of the callback. If false is returned, the token contract will attempt to refund the transfer.
     *
     * WARNING: Do not manually refund the transfer AND return false, as this can lead to double refunds.
     */
    function onConfidentialTransferReceived(
        address operator,
        address from,
        sharedEuint64 amount,
        bytes calldata data
    ) external returns (sharedEbool);
}
