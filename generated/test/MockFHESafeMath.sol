// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { FHE, ebool, euint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
import { FHESafeMath } from "../utils/FHESafeMath.sol";

/**
 * @notice Thin harness over {FHESafeMath} so its branches can be unit-tested directly, without
 *         routing through a token. Outputs are stored rather than returned: an FHE handle is only
 *         useful to a test once it is on-chain state it can read back and decrypt.
 *
 *         The seeded `_balance` starts as the zero handle (uninitialized) and only becomes a real
 *         ciphertext once {seedBalance} runs — that is how the uninitialized-balance branches are
 *         reached.
 */
contract MockFHESafeMath {
    ebool public success;
    euint64 public updated;
    euint64 public spent;

    euint64 private _balance;

    function seedBalance(uint64 value) external {
        _balance = FHE.asEuint64(value);
        FHE.allowThis(_balance);
        FHE.allowGlobal(_balance);
    }

    function balance() external view returns (euint64) {
        return _balance;
    }

    /// @dev {FHESafeMath.trySpend} against a trivially-encrypted (always initialized) amount.
    function trySpend(uint64 amount) external {
        (ebool s, euint64 u, euint64 sp) = FHESafeMath.trySpend(_balance, FHE.asEuint64(amount));
        _record(s, u, sp);
    }

    /// @dev {FHESafeMath.trySpend} against an UNINITIALIZED amount (the zero handle) — the branch a
    ///      caller hits when no ciphertext was ever produced for the delta.
    function trySpendUninitializedAmount() external {
        (ebool s, euint64 u, euint64 sp) = FHESafeMath.trySpend(_balance, euint64.wrap(bytes32(0)));
        _record(s, u, sp);
    }

    /// @dev The 2-return {FHESafeMath.tryDecrease}, so tests can pin that {FHESafeMath.trySpend}
    ///      agrees with it on `success`/`updated` for identical inputs. `spent` is left at the zero
    ///      handle, since `tryDecrease` has no such output.
    function tryDecrease(uint64 amount) external {
        (ebool s, euint64 u) = FHESafeMath.tryDecrease(_balance, FHE.asEuint64(amount));
        _record(s, u, euint64.wrap(bytes32(0)));
    }

    function _record(ebool s, euint64 u, euint64 sp) private {
        success = s;
        updated = u;
        spent = sp;

        FHE.allowThis(s);
        FHE.allowGlobal(s);
        // `tryDecrease`'s uninitialized-balance/-delta branch can hand back the zero handle; the
        // ACL calls would revert on it, and there is nothing to grant anyway.
        if (FHE.isInitialized(u)) {
            FHE.allowThis(u);
            FHE.allowGlobal(u);
        }
        if (FHE.isInitialized(sp)) {
            FHE.allowThis(sp);
            FHE.allowGlobal(sp);
        }
    }
}
