// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHE, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @dev Upgradeable abstract helper that manages pending unshield claims for {FHERC20} wrapper contracts.
 *
 * Uses ERC-7201 namespaced storage for upgrade safety.
 */
abstract contract FHERC20WrapperClaimHelperUpgradeable is Initializable {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct Claim {
        address to;
        bytes32 ctHash;
        uint64 requestedAmount;
        uint64 decryptedAmount;
        bool claimed;
    }

    // @dev Claims are keyed by a unique `claimId`, NOT by the burned ciphertext handle.
    // CoFHE handles are content-addressed, so identical operations across users yield identical
    // handles; keying on the raw handle let a later claim overwrite an earlier one and strand
    // funds (audit finding H-01). `_claimNonce` is appended to the END of the namespaced struct
    // for upgrade safety.
    /// @custom:storage-location erc7201:fherc20.storage.FHERC20WrapperClaimHelper
    struct FHERC20WrapperClaimHelperStorage {
        mapping(bytes32 claimId => Claim) _claims;
        mapping(address => EnumerableSet.Bytes32Set) _userClaims;
        uint256 _claimNonce;
    }

    // keccak256(abi.encode(uint256(keccak256("fherc20.storage.FHERC20WrapperClaimHelper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FHERC20WrapperClaimHelperStorageLocation =
        0x90973842d0546f0dce9511f9a89cc80d5315812909eb805129843b5aeeaaae00;

    function _getFHERC20WrapperClaimHelperStorage()
        private
        pure
        returns (FHERC20WrapperClaimHelperStorage storage $)
    {
        assembly {
            $.slot := FHERC20WrapperClaimHelperStorageLocation
        }
    }

    error ClaimNotFound();
    error AlreadyClaimed();
    error LengthMismatch();

    function __FHERC20WrapperClaimHelper_init() internal onlyInitializing {}

    function __FHERC20WrapperClaimHelper_init_unchained() internal onlyInitializing {}

    /// @dev Creates a pending claim and returns its unique `claimId`. Callers MUST surface this
    /// id (e.g. via an event) so the claim can later be finalized via {_handleClaim}.
    function _createClaim(address to, uint64 requestedAmount, euint64 claimable) internal returns (bytes32 claimId) {
        FHERC20WrapperClaimHelperStorage storage $ = _getFHERC20WrapperClaimHelperStorage();
        bytes32 unwrappedHash = FHE.unwrap(claimable);
        claimId = keccak256(abi.encode(unwrappedHash, to, $._claimNonce++));
        $._claims[claimId] = Claim({
            to: to,
            ctHash: unwrappedHash,
            requestedAmount: requestedAmount,
            decryptedAmount: 0,
            claimed: false
        });
        $._userClaims[to].add(claimId);
    }

    function _handleClaim(
        bytes32 claimId,
        uint64 decryptedAmount,
        bytes memory decryptionProof
    ) internal returns (Claim memory claim) {
        FHERC20WrapperClaimHelperStorage storage $ = _getFHERC20WrapperClaimHelperStorage();
        claim = $._claims[claimId];

        if (claim.to == address(0)) revert ClaimNotFound();
        if (claim.claimed) revert AlreadyClaimed();

        // Verify against the real burned handle stored in the claim, not the lookup key.
        FHE.verifyDecryptResult(FHE.wrapEuint64(claim.ctHash), decryptedAmount, decryptionProof);

        claim.decryptedAmount = decryptedAmount;
        claim.claimed = true;

        $._claims[claimId] = claim;
        $._userClaims[claim.to].remove(claimId);
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
        return _getFHERC20WrapperClaimHelperStorage()._claims[claimId];
    }

    function getUserClaims(address user) public view returns (Claim[] memory userClaims) {
        FHERC20WrapperClaimHelperStorage storage $ = _getFHERC20WrapperClaimHelperStorage();
        bytes32[] memory claimIds = $._userClaims[user].values();
        userClaims = new Claim[](claimIds.length);
        for (uint256 i = 0; i < claimIds.length; i++) {
            userClaims[i] = $._claims[claimIds[i]];
        }
    }
}
