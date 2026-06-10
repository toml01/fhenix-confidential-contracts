// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHE, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @dev Abstract helper contract that manages pending unshield claims for {FHERC20} wrapper contracts.
 *
 * Provides claim lifecycle management: creation, single/batch handling (with decryption verification),
 * and view functions for querying claim status.
 */
abstract contract FHERC20WrapperClaimHelper {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct Claim {
        address to;
        bytes32 ctHash;
        uint64 requestedAmount;
        uint64 decryptedAmount;
        bool claimed;
    }

    // @dev Claims are keyed by a unique `claimId`, NOT by the burned ciphertext handle.
    // CoFHE handles are content-addressed (a pure function of the computation graph), so two
    // users performing identical operations produce the same burned handle. Keying claims on the
    // raw handle let a later claim overwrite an earlier one, stranding the first user's funds
    // (audit finding H-01). The real handle is retained in `Claim.ctHash` for decrypt-proof
    // verification, while `claimId` (salted with `to` and a monotonic nonce) guarantees uniqueness.
    mapping(bytes32 claimId => Claim) private _claims;
    mapping(address => EnumerableSet.Bytes32Set) private _userClaims;
    uint256 private _claimNonce;

    error ClaimNotFound();
    error AlreadyClaimed();
    error LengthMismatch();

    /// @dev Creates a pending claim and returns its unique `claimId`. Callers MUST surface this
    /// id (e.g. via an event) so the claim can later be finalized via {_handleClaim}.
    function _createClaim(address to, uint64 requestedAmount, euint64 claimable) internal returns (bytes32 claimId) {
        bytes32 unwrappedHash = FHE.unwrap(claimable);
        claimId = keccak256(abi.encode(unwrappedHash, to, _claimNonce++));
        _claims[claimId] = Claim({
            to: to,
            ctHash: unwrappedHash,
            requestedAmount: requestedAmount,
            decryptedAmount: 0,
            claimed: false
        });
        _userClaims[to].add(claimId);
    }

    function _handleClaim(
        bytes32 claimId,
        uint64 decryptedAmount,
        bytes memory decryptionProof
    ) internal returns (Claim memory claim) {
        claim = _claims[claimId];

        if (claim.to == address(0)) revert ClaimNotFound();
        if (claim.claimed) revert AlreadyClaimed();

        // Verify against the real burned handle stored in the claim, not the lookup key.
        FHE.verifyDecryptResult(FHE.wrapEuint64(claim.ctHash), decryptedAmount, decryptionProof);

        claim.decryptedAmount = decryptedAmount;
        claim.claimed = true;

        _claims[claimId] = claim;
        _userClaims[claim.to].remove(claimId);
    }

    function _handleClaimBatch(
        bytes32[] memory claimIds,
        uint64[] memory decryptedAmounts,
        bytes[] memory decryptionProofs
    ) internal returns (Claim[] memory claims) {
        if (claimIds.length != decryptedAmounts.length || claimIds.length != decryptionProofs.length) {
            revert LengthMismatch();
        }

        claims = new Claim[](claimIds.length);
        for (uint256 i = 0; i < claimIds.length; i++) {
            claims[i] = _handleClaim(claimIds[i], decryptedAmounts[i], decryptionProofs[i]);
        }
    }

    function getClaim(bytes32 claimId) public view returns (Claim memory) {
        return _claims[claimId];
    }

    function getUserClaims(address user) public view returns (Claim[] memory userClaims) {
        bytes32[] memory claimIds = _userClaims[user].values();
        userClaims = new Claim[](claimIds.length);
        for (uint256 i = 0; i < claimIds.length; i++) {
            userClaims[i] = _claims[claimIds[i]];
        }
    }
}
