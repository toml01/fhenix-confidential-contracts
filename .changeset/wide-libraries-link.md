---
"fhenix-confidential-contracts": major
---

Split the confidential layer into shared cores plus an external linked library, so hosts fit under EIP-170.

All FHE orchestration now lives in `ERC20ConfidentialLib`, an external library that must be deployed once per chain and linked into every consuming token. The logic that `FHERC20`/`FHERC20Upgradeable` and the two wrapper pairs each carried a full copy of moved into shared cores (`FHERC20Core`, `FHERC20ERC20WrapperCore`, `FHERC20NativeWrapperCore`, `ERC20ConfidentialCoreUpgradeable`), leaving the existing contracts as thin hosts.

Breaking changes:

- **Library linking is now mandatory.** Deploy `ERC20ConfidentialLib` and pass it via `libraries` when building any token factory (`unsafeAllowLinkedLibraries: true` for the OZ upgrades plugin). See the README.
- **Unshield claims are re-keyed.** `claimUnshielded` and `getClaim` take a unique per-claimant id (`keccak256(to, nonce++, handle)`), not the ciphertext handle, which fixes claims with colliding handles overwriting each other. The `Claim` struct gains `id` and drops `requestedAmount`; `decryptedAmount` now holds the proven settle amount. Pending claims do NOT survive an upgrade from the old `FHERC20WrapperClaimHelper` store, so settle them before upgrading a proxy.
- **`FHERC20WrapperClaimHelper` and `FHERC20WrapperClaimHelperUpgradeable` are removed**, replaced by `FHERC20WrapperClaims` over the library's claim store.
- **`confidentialTotalSupply()` now returns a real registered, publicly-decryptable ciphertext** instead of an unregistered handle wrapping a plaintext. New `confidentialTotalSupplyPlaintext()` and permissionless `syncConfidentialTotalSupply()` accompany it; the plaintext saturates at `type(uint64).max` rather than reverting, so a donation to the confidential pool cannot brick shield or deadlock claims.
- **Confidential moves are now `nonReentrant`**, which rejects reentrant callbacks that previously succeeded.
- **`ERC20Confidential` and `ERC20ConfidentialUpgradeable` no longer nominally inherit `IERC20Confidential`** (the `IERC7984`/`IERC20ConfidentialCore` trees declare overlapping events, which Solidity rejects in one graph). The full ABI is unchanged and `supportsInterface` still answers for it.

Additions: a `_beforeConfidentialMove` policy hook for freeze/pause, an optional compliance observer, and `shieldTo`/`autoShield` with the `MintMode`/`IMintModePolicy` opt-in policy surface for hosts that want freshly minted tokens auto-shielded.
