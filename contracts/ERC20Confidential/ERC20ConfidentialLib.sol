// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHE, euint64, InEuint64, ebool } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { FHESafeMath } from "../utils/FHESafeMath.sol";
import { FHERC20Utils } from "../FHERC20/utils/FHERC20Utils.sol";
import { ERC20ConfidentialIndicator } from "./ERC20ConfidentialIndicator.sol";

/// @dev Self-only bridge the host token exposes so this delegatecall'd library can
/// reach the host's ledger hooks (`_ledgerTransfer` / `_ledgerMint`) for the
/// shield / unshield-claim / mint orchestration relocated here.
interface IConfidentialLedger {
    /// @dev `from == address(0)` ⇒ ledger mint; otherwise ledger transfer.
    function __ledger(address from, address to, uint256 amount) external;
}

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
        // Compliance observer (ERC-7984-style). When set, every confidential
        // balance handle produced by `update()` is also FHE.allow'd to it, so the
        // observer can decrypt going forward. Past handles are topped up via
        // `grantPast`. Append-only field — keep last for storage-layout safety.
        address _observer;
    }

    // Pool that custodies the public ledger tokens backing confidential balances.
    // Mirrors the constant in ERC20ConfidentialCoreUpgradeable.
    address constant CONFIDENTIAL_POOL = address(0x1011000000000000000000000000000000000000);

    event ConfidentialTransfer(address indexed from, address indexed to, euint64 indexed amount);
    // Signatures (and indexed-ness) must match IERC20ConfidentialCore so the
    // host token's ABI/topics are unchanged when these are emitted via delegatecall.
    event TokensShielded(address indexed account, uint256 amount);
    event TokensUnshielded(address indexed account, euint64 indexed amount);
    event UnshieldedTokensClaimed(
        address indexed account,
        bytes32 indexed unshieldRequestId,
        euint64 indexed unshieldAmount,
        uint64 unshieldAmountCleartext
    );

    error ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(euint64 value, address user);
    error ERC20ConfidentialUnauthorizedSpender(address holder, address spender);
    error ConfidentialInvalidSender(address sender);
    error ConfidentialInvalidReceiver(address receiver);
    error AmountTooSmallForConfidentialPrecision();

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
        address obs = $._observer; // compliance observer (0 = none); forward-grant below

        if (from != address(0)) {
            euint64 fromBalance = $._confidentialBalances[from];
            (success, ptr) = FHESafeMath.tryDecrease(fromBalance, amount);
            FHE.allowThis(ptr);
            FHE.allow(ptr, from);
            if (obs != address(0)) FHE.allow(ptr, obs);
            $._confidentialBalances[from] = ptr;
        }

        transferred = from != address(0) ? FHE.select(success, amount, FHE.asEuint64(0)) : amount;

        if (to != address(0)) {
            ptr = FHE.add($._confidentialBalances[to], transferred);
            FHE.allowThis(ptr);
            FHE.allow(ptr, to);
            if (obs != address(0)) FHE.allow(ptr, obs);
            $._confidentialBalances[to] = ptr;
        }

        if (from != address(0)) FHE.allow(transferred, from);
        if (to != address(0)) FHE.allow(transferred, to);
        FHE.allowThis(transferred);
        if (obs != address(0)) FHE.allow(transferred, obs);

        ERC20ConfidentialIndicator ind = $._indicatorToken;
        if (address(ind) != address(0)) ind.emitConfidentialTransfer(from, to);

        emit ConfidentialTransfer(from, to, transferred);
    }

    // =========================================================================
    //  Compliance observer — past-value top-up
    // =========================================================================

    /// @dev Grant `observer` FHE access to historical ciphertext handles the host
    /// already owns (`allowThis`'d) — past transfer amounts (from {ConfidentialTransfer}
    /// events) and/or current balance handles (from `confidentialBalanceOf`). Closes
    /// the forward-only gap of the observer hook in `update()`.
    ///
    /// Runs under delegatecall, so `FHE.allow` executes as the host token, which holds
    /// permanent ACL on every handle it created. NOTE: on real CoFHE, a ctHash the host
    /// never owned reverts the whole call — the off-chain indexer must supply only this
    /// token's handles.
    function grantPast(address observer, uint256[] calldata ctHashes) public {
        for (uint256 i = 0; i < ctHashes.length; i++) {
            FHE.allow(euint64.wrap(bytes32(ctHashes[i])), observer);
        }
    }

    // =========================================================================
    //  Shield / unshield / mint orchestration (relocated from the host token to
    //  fit under EIP-170; ledger ops reach the host via the self-only bridge).
    // =========================================================================

    function shield(ERC20ConfidentialStorage storage $, uint256 amount) public {
        uint256 rate = $._conversionRate;
        uint256 amountToShield = amount - (amount % rate);
        if (amountToShield == 0) revert AmountTooSmallForConfidentialPrecision();

        uint64 amountConfidential = SafeCast.toUint64(amountToShield / rate);

        IConfidentialLedger(address(this)).__ledger(msg.sender, CONFIDENTIAL_POOL, amountToShield);
        update($, address(0), msg.sender, FHE.asEuint64(amountConfidential));

        emit TokensShielded(msg.sender, amountToShield);
    }

    function unshield(
        ERC20ConfidentialStorage storage $,
        euint64 amount,
        uint64 requestedAmount
    ) public returns (euint64 burned) {
        burned = update($, msg.sender, address(0), amount);
        FHE.allowPublic(burned);
        createClaim(msg.sender, requestedAmount, burned);
        emit TokensUnshielded(msg.sender, burned);
    }

    function unshieldChecked(ERC20ConfidentialStorage storage $, euint64 amount) public returns (euint64) {
        if (!FHE.isAllowed(amount, msg.sender)) {
            revert ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(amount, msg.sender);
        }
        return unshield($, amount, 0);
    }

    function claimUnshielded(
        ERC20ConfidentialStorage storage $,
        bytes32 id,
        uint64 decryptedAmount,
        bytes calldata decryptionProof
    ) public {
        Claim memory claim = handleClaim(id, decryptedAmount, decryptionProof);

        uint256 amountPublic = uint256(claim.decryptedAmount) * $._conversionRate;
        IConfidentialLedger(address(this)).__ledger(CONFIDENTIAL_POOL, claim.to, amountPublic);

        emit UnshieldedTokensClaimed(claim.to, id, FHE.wrapEuint64(claim.ctHash), claim.decryptedAmount);
    }

    function confidentialMint(ERC20ConfidentialStorage storage $, address to, uint64 amount) public {
        IConfidentialLedger(address(this)).__ledger(address(0), CONFIDENTIAL_POOL, uint256(amount) * $._conversionRate);
        update($, address(0), to, FHE.asEuint64(amount));
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
        bytes32 id; // unique per-claimant key (NOT the ciphertext handle); how the claim is referenced
        address to;
        bytes32 ctHash; // the burned ciphertext handle; binds the decryption proof in handleClaim
        uint64 requestedAmount;
        uint64 decryptedAmount;
        bool claimed;
    }

    /// @custom:storage-location erc7201:fherc20.storage.FHERC20WrapperClaimHelper
    struct ClaimStorage {
        mapping(bytes32 id => Claim) _claims; // keyed by claim id, NOT by the ciphertext handle
        mapping(address => EnumerableSet.Bytes32Set) _userClaims; // holds claim ids
        mapping(address => uint256) _claimNonce; // per-claimant counter for unique id derivation
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

    /// @dev Records a pending unshield claim keyed by a UNIQUE per-claimant id, not by the
    /// ciphertext handle. CoFHE handles are content-addressed (a pure function of the operation
    /// lineage, with no per-caller or per-call salt), so two unshields of an identical
    /// burned-amount lineage produce the SAME handle; keying claims by that handle would let a
    /// second unshield overwrite the first claimant's record and redirect their payout. The
    /// handle is retained as `ctHash` to bind the decryption proof in {handleClaim}.
    function createClaim(address to, uint64 requestedAmount, euint64 claimable) public returns (bytes32 id) {
        ClaimStorage storage $ = _claimStore();
        bytes32 h = FHE.unwrap(claimable);
        id = keccak256(abi.encode(to, $._claimNonce[to]++, h));
        $._claims[id] = Claim({
            id: id,
            to: to,
            ctHash: h,
            requestedAmount: requestedAmount,
            decryptedAmount: 0,
            claimed: false
        });
        $._userClaims[to].add(id);
    }

    function handleClaim(
        bytes32 id,
        uint64 decryptedAmount,
        bytes memory decryptionProof
    ) public returns (Claim memory claim) {
        ClaimStorage storage $ = _claimStore();
        claim = $._claims[id];
        if (claim.to == address(0)) revert ClaimNotFound();
        if (claim.claimed) revert AlreadyClaimed();

        // The proof binds `decryptedAmount` to the burned handle (`ctHash`), which is fixed at
        // createClaim time — never to the caller-supplied `id`.
        FHE.verifyDecryptResult(FHE.wrapEuint64(claim.ctHash), decryptedAmount, decryptionProof);

        claim.decryptedAmount = decryptedAmount;
        claim.claimed = true;
        $._claims[id] = claim;
        $._userClaims[claim.to].remove(id);
    }

    function getClaim(bytes32 id) public view returns (Claim memory) {
        return _claimStore()._claims[id];
    }

    function getUserClaims(address user) public view returns (Claim[] memory userClaims) {
        ClaimStorage storage $ = _claimStore();
        bytes32[] memory ids = $._userClaims[user].values();
        userClaims = new Claim[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            userClaims[i] = $._claims[ids[i]];
        }
    }
}
