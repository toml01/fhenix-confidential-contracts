// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHE, euint64, InEuint64, ebool } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { FHESafeMath } from "../utils/FHESafeMath.sol";
import { FHERC20Utils } from "../FHERC20/utils/FHERC20Utils.sol";
import { ERC20ConfidentialIndicator } from "./ERC20ConfidentialIndicator.sol";

/**
 * @title  ERC20ConfidentialLib
 * @notice External (linked, delegatecall'd) home for the heaviest confidential balance logic, so
 *         that code lives in this library's own deployed bytecode instead of being embedded in
 *         every host token. Used by {ERC20ConfidentialCoreUpgradeable} to keep a token that fuses
 *         the confidential layer with a large base (e.g. M0's `JMIExtension`) under the EIP-170
 *         24 KB limit WITHOUT dropping any functionality.
 *
 * @dev    `public` library functions → the compiler emits `delegatecall`, so they run in the
 *         HOST's context: `address(this)` is the token and `msg.sender` is the original caller —
 *         exactly what the FHE ACL grants (`allowThis` / `allow(_, msg.sender)`) and the operator
 *         checks need. The storage struct is passed by reference (resolves to the host's ERC-7201
 *         slot) and is defined HERE so host and library share one type. Functions that need the
 *         host's public ledger (`shield`/`unshield`/mint) stay in the host; everything purely
 *         confidential lives here.
 */
library ERC20ConfidentialLib {
    /// @custom:storage-location erc7201:fherc20.storage.ERC20Confidential
    struct ERC20ConfidentialStorage {
        mapping(address => euint64) _confidentialBalances;
        mapping(address => mapping(address => uint48)) _operators;
        ERC20ConfidentialIndicator _indicatorToken;
        uint8 _decimals;
        uint8 _confidentialDecimals;
        uint256 _conversionRate;
    }

    event ConfidentialTransfer(address indexed from, address indexed to, euint64 indexed amount);

    error ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(euint64 value, address user);
    error ERC20ConfidentialUnauthorizedSpender(address holder, address spender);
    error ConfidentialInvalidSender(address sender);
    error ConfidentialInvalidReceiver(address receiver);

    // =========================================================================
    //  Core encrypted balance update (also used by the host for shield/mint)
    // =========================================================================

    /// @dev Saturating decrease on `from`, increase on `to`, ACL grants, indicator mirror, and the
    /// {ConfidentialTransfer} log. Returns the actually-moved (clamped) amount.
    function update(
        ERC20ConfidentialStorage storage $,
        address from,
        address to,
        euint64 amount
    ) public returns (euint64 transferred) {
        ebool success;
        euint64 ptr;

        if (from != address(0)) {
            euint64 fromBalance = $._confidentialBalances[from];
            (success, ptr) = FHESafeMath.tryDecrease(fromBalance, amount);
            FHE.allowThis(ptr);
            FHE.allow(ptr, from);
            $._confidentialBalances[from] = ptr;
        }

        transferred = from != address(0) ? FHE.select(success, amount, FHE.asEuint64(0)) : amount;

        if (to != address(0)) {
            ptr = FHE.add($._confidentialBalances[to], transferred);
            FHE.allowThis(ptr);
            FHE.allow(ptr, to);
            $._confidentialBalances[to] = ptr;
        }

        if (from != address(0)) FHE.allow(transferred, from);
        if (to != address(0)) FHE.allow(transferred, to);
        FHE.allowThis(transferred);

        ERC20ConfidentialIndicator ind = $._indicatorToken;
        if (address(ind) != address(0)) ind.emitConfidentialTransfer(from, to);

        emit ConfidentialTransfer(from, to, transferred);
    }

    // =========================================================================
    //  Confidential transfer surface (full orchestration; host wrappers are 1-liners)
    // =========================================================================

    function confTransfer(
        ERC20ConfidentialStorage storage $,
        address to,
        euint64 value
    ) public returns (euint64 transferred) {
        if (!FHE.isAllowed(value, msg.sender))
            revert ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(value, msg.sender);
        transferred = _move($, msg.sender, to, value);
        FHE.allowTransient(transferred, msg.sender);
    }

    function confTransferIn(
        ERC20ConfidentialStorage storage $,
        address to,
        InEuint64 memory inValue
    ) public returns (euint64 transferred) {
        transferred = _move($, msg.sender, to, FHE.asEuint64(inValue));
        FHE.allowTransient(transferred, msg.sender);
    }

    function confTransferFrom(
        ERC20ConfidentialStorage storage $,
        address from,
        address to,
        euint64 value
    ) public returns (euint64 transferred) {
        if (!FHE.isAllowed(value, msg.sender))
            revert ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(value, msg.sender);
        if (!_isOperator($, from, msg.sender)) revert ERC20ConfidentialUnauthorizedSpender(from, msg.sender);
        transferred = _move($, from, to, value);
        FHE.allowTransient(transferred, msg.sender);
    }

    function confTransferFromIn(
        ERC20ConfidentialStorage storage $,
        address from,
        address to,
        InEuint64 memory inValue
    ) public returns (euint64 transferred) {
        if (!_isOperator($, from, msg.sender)) revert ERC20ConfidentialUnauthorizedSpender(from, msg.sender);
        transferred = _move($, from, to, FHE.asEuint64(inValue));
        FHE.allowTransient(transferred, msg.sender);
    }

    function confTransferAndCall(
        ERC20ConfidentialStorage storage $,
        address to,
        euint64 amount,
        bytes calldata data
    ) public returns (euint64 transferred) {
        if (!FHE.isAllowed(amount, msg.sender))
            revert ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(amount, msg.sender);
        transferred = _moveAndCall($, msg.sender, to, amount, data);
        FHE.allowTransient(transferred, msg.sender);
    }

    function confTransferAndCallIn(
        ERC20ConfidentialStorage storage $,
        address to,
        InEuint64 memory inAmount,
        bytes calldata data
    ) public returns (euint64 transferred) {
        transferred = _moveAndCall($, msg.sender, to, FHE.asEuint64(inAmount), data);
        FHE.allowTransient(transferred, msg.sender);
    }

    function confTransferFromAndCall(
        ERC20ConfidentialStorage storage $,
        address from,
        address to,
        euint64 amount,
        bytes calldata data
    ) public returns (euint64 transferred) {
        if (!FHE.isAllowed(amount, msg.sender))
            revert ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(amount, msg.sender);
        if (!_isOperator($, from, msg.sender)) revert ERC20ConfidentialUnauthorizedSpender(from, msg.sender);
        transferred = _moveAndCall($, from, to, amount, data);
        FHE.allowTransient(transferred, msg.sender);
    }

    function confTransferFromAndCallIn(
        ERC20ConfidentialStorage storage $,
        address from,
        address to,
        InEuint64 memory inAmount,
        bytes calldata data
    ) public returns (euint64 transferred) {
        if (!_isOperator($, from, msg.sender)) revert ERC20ConfidentialUnauthorizedSpender(from, msg.sender);
        transferred = _moveAndCall($, from, to, FHE.asEuint64(inAmount), data);
        FHE.allowTransient(transferred, msg.sender);
    }

    function isOperator(
        ERC20ConfidentialStorage storage $,
        address holder,
        address spender
    ) public view returns (bool) {
        return _isOperator($, holder, spender);
    }

    // =========================================================================
    //  Internal helpers (inline within the library)
    // =========================================================================

    function _move(
        ERC20ConfidentialStorage storage $,
        address from,
        address to,
        euint64 value
    ) internal returns (euint64) {
        if (from == address(0)) revert ConfidentialInvalidSender(address(0));
        if (to == address(0)) revert ConfidentialInvalidReceiver(address(0));
        return update($, from, to, value);
    }

    function _moveAndCall(
        ERC20ConfidentialStorage storage $,
        address from,
        address to,
        euint64 amount,
        bytes calldata data
    ) internal returns (euint64 transferred) {
        euint64 sent = _move($, from, to, amount);
        ebool success = FHERC20Utils.checkOnTransferReceived(msg.sender, from, to, sent, data);
        euint64 refund = update($, to, from, FHE.select(success, FHE.asEuint64(0), sent));
        transferred = FHE.sub(sent, refund);
    }

    function _isOperator(
        ERC20ConfidentialStorage storage $,
        address holder,
        address spender
    ) internal view returns (bool) {
        return holder == spender || block.timestamp <= $._operators[holder][spender];
    }

    // =========================================================================
    //  Unshield-claim bookkeeping (relocated from FHERC20WrapperClaimHelper).
    //  Uses its own ERC-7201 slot; the host delegates here so the (chunky)
    //  EnumerableSet code lives in the library, not in the token.
    // =========================================================================

    using EnumerableSet for EnumerableSet.Bytes32Set;

    struct Claim {
        address to;
        bytes32 ctHash;
        uint64 requestedAmount;
        uint64 decryptedAmount;
        bool claimed;
    }

    /// @custom:storage-location erc7201:fherc20.storage.FHERC20WrapperClaimHelper
    struct ClaimStorage {
        mapping(bytes32 ctHash => Claim) _claims;
        mapping(address => EnumerableSet.Bytes32Set) _userClaims;
    }

    // keccak256(abi.encode(uint256(keccak256("fherc20.storage.FHERC20WrapperClaimHelper")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant CLAIM_SLOT = 0x90973842d0546f0dce9511f9a89cc80d5315812909eb805129843b5aeeaaae00;

    error ClaimNotFound();
    error AlreadyClaimed();

    function _claimStore() private pure returns (ClaimStorage storage $) {
        assembly {
            $.slot := CLAIM_SLOT
        }
    }

    function createClaim(address to, uint64 requestedAmount, euint64 claimable) public {
        ClaimStorage storage $ = _claimStore();
        bytes32 h = FHE.unwrap(claimable);
        $._claims[h] = Claim({
            to: to,
            ctHash: h,
            requestedAmount: requestedAmount,
            decryptedAmount: 0,
            claimed: false
        });
        $._userClaims[to].add(h);
    }

    function handleClaim(
        bytes32 ctHash,
        uint64 decryptedAmount,
        bytes memory decryptionProof
    ) public returns (Claim memory claim) {
        ClaimStorage storage $ = _claimStore();
        claim = $._claims[ctHash];
        if (claim.to == address(0)) revert ClaimNotFound();
        if (claim.claimed) revert AlreadyClaimed();

        FHE.verifyDecryptResult(FHE.wrapEuint64(ctHash), decryptedAmount, decryptionProof);

        claim.decryptedAmount = decryptedAmount;
        claim.claimed = true;
        $._claims[ctHash] = claim;
        $._userClaims[claim.to].remove(ctHash);
    }

    function getClaim(bytes32 ctHash) public view returns (Claim memory) {
        return _claimStore()._claims[ctHash];
    }

    function getUserClaims(address user) public view returns (Claim[] memory userClaims) {
        ClaimStorage storage $ = _claimStore();
        bytes32[] memory ctHashes = $._userClaims[user].values();
        userClaims = new Claim[](ctHashes.length);
        for (uint256 i = 0; i < ctHashes.length; i++) {
            userClaims[i] = $._claims[ctHashes[i]];
        }
    }
}
