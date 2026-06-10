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

    mapping(bytes32 ctHash => Claim) private _claims;
    mapping(address => EnumerableSet.Bytes32Set) private _userClaims;

    // Monotonic per-call salt. Used to make each burned ciphertext handle unique (see H-01).
    uint64 private _saltNonce;

    error ClaimNotFound();
    error AlreadyClaimed();
    error LengthMismatch();

    /// @dev Salts an encrypted value so two callers performing identical operations get DISTINCT
    /// ciphertext handles (audit finding H-01: CoFHE handles are content-addressed, so identical
    /// computation graphs collide). The plaintext is preserved — `(x + s) - s == x (mod 2^64)` —
    /// while `_saltNonce++` makes `FHE.asEuint64(salt)` a fresh handle each call, so the resulting
    /// add/sub graph hashes to a unique handle. Claims can therefore stay keyed by the handle.
    /// NOTE: relies on the coprocessor evaluating each task by handle and never folding `+s-s` away.
    function _uniqueizeBurnedHandle(euint64 value) internal returns (euint64) {
        euint64 s = FHE.asEuint64(_saltNonce++);
        return FHE.sub(FHE.add(value, s), s);
    }

    function _createClaim(address to, uint64 requestedAmount, euint64 claimable) internal {
        bytes32 unwrappedHash = FHE.unwrap(claimable);
        _claims[unwrappedHash] = Claim({
            to: to,
            ctHash: unwrappedHash,
            requestedAmount: requestedAmount,
            decryptedAmount: 0,
            claimed: false
        });
        _userClaims[to].add(unwrappedHash);
    }

    function _handleClaim(
        bytes32 ctHash,
        uint64 decryptedAmount,
        bytes memory decryptionProof
    ) internal returns (Claim memory claim) {
        claim = _claims[ctHash];

        if (claim.to == address(0)) revert ClaimNotFound();
        if (claim.claimed) revert AlreadyClaimed();

        FHE.verifyDecryptResult(FHE.wrapEuint64(ctHash), decryptedAmount, decryptionProof);

        claim.decryptedAmount = decryptedAmount;
        claim.claimed = true;

        _claims[ctHash] = claim;
        _userClaims[claim.to].remove(ctHash);
    }

    function _handleClaimBatch(
        bytes32[] memory ctHashes,
        uint64[] memory decryptedAmounts,
        bytes[] memory decryptionProofs
    ) internal returns (Claim[] memory claims) {
        if (ctHashes.length != decryptedAmounts.length || ctHashes.length != decryptionProofs.length) {
            revert LengthMismatch();
        }

        claims = new Claim[](ctHashes.length);
        for (uint256 i = 0; i < ctHashes.length; i++) {
            claims[i] = _handleClaim(ctHashes[i], decryptedAmounts[i], decryptionProofs[i]);
        }
    }

    function getClaim(bytes32 ctHash) public view returns (Claim memory) {
        return _claims[ctHash];
    }

    function getUserClaims(address user) public view returns (Claim[] memory userClaims) {
        bytes32[] memory ctHashes = _userClaims[user].values();
        userClaims = new Claim[](ctHashes.length);
        for (uint256 i = 0; i < ctHashes.length; i++) {
            userClaims[i] = _claims[ctHashes[i]];
        }
    }
}
