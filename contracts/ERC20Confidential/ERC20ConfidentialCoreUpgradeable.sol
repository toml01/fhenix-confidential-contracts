// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { FHE, euint64, InEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { IERC20ConfidentialCore } from "../interfaces/IERC20ConfidentialCore.sol";
import { ERC20ConfidentialIndicator } from "./ERC20ConfidentialIndicator.sol";
import { ERC20ConfidentialLib } from "./ERC20ConfidentialLib.sol";

/**
 * @title ERC20ConfidentialCoreUpgradeable
 * @notice Ledger-agnostic, OZ-base-free variant of {ERC20ConfidentialUpgradeable}. It carries the
 * FULL confidential (FHE) layer — shield/unshield, confidential transfers, operators,
 * `_confidentialUpdate` — but inherits NO public ERC-20 implementation and NO OpenZeppelin base
 * contracts (`ERC20Upgradeable`, `ERC165Upgradeable`, `Initializable`). It reaches the host's
 * public ledger through three hooks ({_ledgerMint}, {_ledgerTransfer}, {_ledgerBalanceOf}).
 *
 * Why no OZ bases: this core is meant to be mixed into a contract that ALREADY brings its own
 * ledger + OZ stack (e.g. M0's `ERC20ExtendedUpgradeable` reached via `JMIExtension`, which vendors
 * its own copy of OpenZeppelin). Inheriting OZ here would put a SECOND `Initializable` / `IERC165`
 * into the combined inheritance graph and fail to compile ("Identifier already declared"). So:
 *   - The confidential-only {IERC20ConfidentialCore} interface does not extend OZ `IERC20`/`IERC165`.
 *   - The claim helper {FHERC20WrapperClaimHelperCore} drops OZ `Initializable`.
 *   - Init is plain `internal`; the HOST's initializer (its own `Initializable`) guards one-time setup.
 *
 * This is a NEW contract; {ERC20ConfidentialUpgradeable} is left untouched. State lives in the SAME
 * ERC-7201 slot (`fherc20.storage.ERC20Confidential`) so the confidential layout is portable.
 */
abstract contract ERC20ConfidentialCoreUpgradeable is IERC20ConfidentialCore {
    using ERC20ConfidentialLib for ERC20ConfidentialLib.ERC20ConfidentialStorage;

    address public constant CONFIDENTIAL_POOL = address(0x1011000000000000000000000000000000000000);

    // The confidential storage struct lives in ERC20ConfidentialLib so the library and this
    // contract share one type (the library mutates it via delegatecall). Same ERC-7201 slot.
    // keccak256(abi.encode(uint256(keccak256("fherc20.storage.ERC20Confidential")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ERC20ConfidentialStorageLocation =
        0xb440e9c559aceef9e2c75ec16e8d26ee97396e4a6978215085407b7ab0709e00;

    function _getERC20ConfidentialStorage()
        private
        pure
        returns (ERC20ConfidentialLib.ERC20ConfidentialStorage storage $)
    {
        assembly {
            $.slot := ERC20ConfidentialStorageLocation
        }
    }

    error ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(euint64 value, address user);
    error ERC20ConfidentialUnauthorizedSpender(address holder, address spender);
    error AmountTooSmallForConfidentialPrecision();
    error ConfidentialInvalidSender(address sender);
    error ConfidentialInvalidReceiver(address receiver);

    // =========================================================================
    //  Ledger hooks — implemented by the host (its public ERC-20 ledger)
    // =========================================================================

    /// @dev Mint `amount` of the PUBLIC token to `to`. Host forwards to its ledger's `_mint`.
    function _ledgerMint(address to, uint256 amount) internal virtual;

    /// @dev Move `amount` of the PUBLIC token from `from` to `to`. Host forwards to `_transfer`.
    function _ledgerTransfer(address from, address to, uint256 amount) internal virtual;

    /// @dev Public token balance of `account`. Host forwards to its ledger's `balanceOf`.
    function _ledgerBalanceOf(address account) internal view virtual returns (uint256);

    // =========================================================================
    //  Initializer (no ERC-20 init, no Initializable — host guards the call).
    //  `name`/`symbol` are passed in (not read via name()/symbol()) so the
    //  confidential layer never owns the public-ledger metadata — that stays
    //  entirely with the host ERC-20, avoiding an external-vs-public override clash.
    // =========================================================================

    function __ERC20ConfidentialCore_init(uint8 decimals_) internal {
        ERC20ConfidentialLib.ERC20ConfidentialStorage storage $ = _getERC20ConfidentialStorage();
        $._decimals = decimals_;
        $._confidentialDecimals = decimals_ <= 6 ? decimals_ : 6;
        $._conversionRate = decimals_ > 6 ? 10 ** (decimals_ - 6) : 1;
    }

    /// @dev Wire an externally-deployed indicator token. Kept out of the initializer (and not
    /// `new`-ed here) so the indicator's ~2.4 KB of creation code is NOT embedded into the host's
    /// bytecode — important for the size-constrained JMI fusion. Optional: confidential transfers
    /// work without an indicator; if set, they emit indicator mirror events.
    function _setIndicatorToken(ERC20ConfidentialIndicator token) internal {
        _getERC20ConfidentialStorage()._indicatorToken = token;
    }

    function confidentialDecimals() public view virtual returns (uint8) {
        return _getERC20ConfidentialStorage()._confidentialDecimals;
    }

    function contractURI() public view virtual returns (string memory) {
        return "";
    }

    function indicatorToken() public view virtual returns (ERC20ConfidentialIndicator) {
        return _getERC20ConfidentialStorage()._indicatorToken;
    }

    /// @dev `false` because {balanceOf} returns the real public ERC-20 balance, not an indicator.
    function balanceOfIsIndicator() public pure virtual returns (bool) {
        return false;
    }

    /// @dev Always `0`: {balanceOf} is not an indicator on this token.
    function indicatorTick() public pure virtual returns (uint256) {
        return 0;
    }

    /// @dev Derived on read from {CONFIDENTIAL_POOL}'s public balance, scaled to confidential
    /// decimals. The returned handle is not a registered ciphertext, so it is informational only.
    function confidentialTotalSupply() public view virtual returns (euint64) {
        return euint64.wrap(bytes32(_ledgerBalanceOf(CONFIDENTIAL_POOL) / _rate()));
    }

    function confidentialBalanceOf(address account) public view virtual returns (euint64) {
        return _getERC20ConfidentialStorage()._confidentialBalances[account];
    }

    function isOperator(address holder, address spender) public view virtual returns (bool) {
        return holder == spender || block.timestamp <= _getERC20ConfidentialStorage()._operators[holder][spender];
    }

    /// @dev The confidential interface id. The host's `supportsInterface` should OR this in.
    function _confidentialSupportsInterface(bytes4 interfaceId) internal pure returns (bool) {
        return interfaceId == type(IERC20ConfidentialCore).interfaceId;
    }

    // =========================================================================
    //  Shield / Unshield
    // =========================================================================

    function shield(uint256 amount) public virtual {
        uint256 rate = _rate();
        uint256 amountToShield = amount - (amount % rate);
        if (amountToShield == 0) {
            revert AmountTooSmallForConfidentialPrecision();
        }

        uint64 amountConfidential = SafeCast.toUint64(amountToShield / rate);

        _ledgerTransfer(msg.sender, CONFIDENTIAL_POOL, amountToShield);
        _confidentialUpdate(address(0), msg.sender, FHE.asEuint64(amountConfidential));

        emit TokensShielded(msg.sender, amountToShield);
    }

    function unshield(uint64 amount) public virtual returns (euint64) {
        return _unshield(FHE.asEuint64(amount), amount);
    }

    function unshield(euint64 amount) public virtual returns (euint64) {
        if (!FHE.isAllowed(amount, msg.sender)) {
            revert ERC20ConfidentialUnauthorizedUseOfEncryptedAmount(amount, msg.sender);
        }
        return _unshield(amount, 0);
    }

    function claimUnshielded(bytes32 ctHash, uint64 decryptedAmount, bytes calldata decryptionProof) public virtual {
        ERC20ConfidentialLib.Claim memory claim = ERC20ConfidentialLib.handleClaim(
            ctHash,
            decryptedAmount,
            decryptionProof
        );

        uint256 amountPublic = uint256(claim.decryptedAmount) * _rate();
        _ledgerTransfer(CONFIDENTIAL_POOL, claim.to, amountPublic);

        emit UnshieldedTokensClaimed(claim.to, ctHash, FHE.wrapEuint64(ctHash), claim.decryptedAmount);
    }

    /// @notice Pending-claim views (delegated to the library, which owns the claim storage).
    function getClaim(bytes32 ctHash) public view virtual returns (ERC20ConfidentialLib.Claim memory) {
        return ERC20ConfidentialLib.getClaim(ctHash);
    }

    function getUserClaims(address user) public view virtual returns (ERC20ConfidentialLib.Claim[] memory) {
        return ERC20ConfidentialLib.getUserClaims(user);
    }

    // =========================================================================
    //  Confidential Transfers
    // =========================================================================

    // Thin wrappers — the full orchestration lives in ERC20ConfidentialLib (delegatecall'd) so its
    // code isn't embedded in the host token. msg.sender/this are preserved under delegatecall.

    function confidentialTransfer(address to, euint64 value) public virtual returns (euint64) {
        return ERC20ConfidentialLib.confTransfer(_getERC20ConfidentialStorage(), to, value);
    }

    function confidentialTransfer(address to, InEuint64 memory inValue) public virtual returns (euint64) {
        return ERC20ConfidentialLib.confTransferIn(_getERC20ConfidentialStorage(), to, inValue);
    }

    function confidentialTransferFrom(address from, address to, euint64 value) public virtual returns (euint64) {
        return ERC20ConfidentialLib.confTransferFrom(_getERC20ConfidentialStorage(), from, to, value);
    }

    function confidentialTransferFrom(
        address from,
        address to,
        InEuint64 memory inValue
    ) public virtual returns (euint64) {
        return ERC20ConfidentialLib.confTransferFromIn(_getERC20ConfidentialStorage(), from, to, inValue);
    }

    function confidentialTransferAndCall(
        address to,
        euint64 amount,
        bytes calldata data
    ) public virtual returns (euint64) {
        return ERC20ConfidentialLib.confTransferAndCall(_getERC20ConfidentialStorage(), to, amount, data);
    }

    function confidentialTransferAndCall(
        address to,
        InEuint64 memory encryptedAmount,
        bytes calldata data
    ) public virtual returns (euint64) {
        return ERC20ConfidentialLib.confTransferAndCallIn(_getERC20ConfidentialStorage(), to, encryptedAmount, data);
    }

    function confidentialTransferFromAndCall(
        address from,
        address to,
        euint64 amount,
        bytes calldata data
    ) public virtual returns (euint64) {
        return ERC20ConfidentialLib.confTransferFromAndCall(_getERC20ConfidentialStorage(), from, to, amount, data);
    }

    function confidentialTransferFromAndCall(
        address from,
        address to,
        InEuint64 memory encryptedAmount,
        bytes calldata data
    ) public virtual returns (euint64) {
        return
            ERC20ConfidentialLib.confTransferFromAndCallIn(
                _getERC20ConfidentialStorage(),
                from,
                to,
                encryptedAmount,
                data
            );
    }

    // =========================================================================
    //  Operators
    // =========================================================================

    function setOperator(address operator, uint48 until) public virtual {
        _setOperator(msg.sender, operator, until);
    }

    // =========================================================================
    //  Confidential Mint (for inheriting contracts)
    // =========================================================================

    function _confidentialMint(address to, uint64 amount) internal virtual {
        _ledgerMint(CONFIDENTIAL_POOL, uint256(amount) * _rate());
        _confidentialUpdate(address(0), to, FHE.asEuint64(amount));
    }

    // =========================================================================
    //  Internal helpers
    // =========================================================================

    function _unshield(euint64 amount, uint64 requestedAmount) internal virtual returns (euint64 burned) {
        burned = _confidentialUpdate(msg.sender, address(0), amount);
        FHE.allowPublic(burned);
        ERC20ConfidentialLib.createClaim(msg.sender, requestedAmount, burned);
        emit TokensUnshielded(msg.sender, burned);
    }

    /// @dev Thin wrapper: the heavy encrypted-balance logic lives in {ERC20ConfidentialLib.update}
    /// (a linked library, delegatecall'd) so it isn't embedded in the host token's bytecode.
    function _confidentialUpdate(
        address from,
        address to,
        euint64 amount
    ) internal virtual returns (euint64 transferred) {
        return ERC20ConfidentialLib.update(_getERC20ConfidentialStorage(), from, to, amount);
    }

    function _setOperator(address holder, address operator, uint48 until) internal virtual {
        _getERC20ConfidentialStorage()._operators[holder][operator] = until;
        emit OperatorSet(holder, operator, until);
    }

    function _rate() internal view virtual returns (uint256) {
        return _getERC20ConfidentialStorage()._conversionRate;
    }
}
