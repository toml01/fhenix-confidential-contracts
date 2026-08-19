---
"fhenix-confidential-contracts": major
---

Move the remaining confidential boundary values onto the `sharedEuintXX` types, and pair `inputProof` with the handles it authenticates.

**Breaking, and invisible to the compiler.** `euint64`, `externalEuint64` and `sharedEuint64` are all `bytes32` on the wire, so every selector below is unchanged. Existing callers keep compiling and fail at runtime with `NotShared`.

- The `bytes32` overloads of `confidentialTransfer`, `confidentialTransferFrom`, `confidentialTransferAndCall`, `confidentialTransferFromAndCall` and `unshield` now take `sharedEuint64`. Callers must produce the value with `FHE.shareEuint64(handle, token)`; the `isAllowed` guard is replaced by the share check, which establishes provenance rather than possession. These entry points are consequently reachable only from a contract — an EOA cannot create a share, and should use the `externalEuint64 + inputProof` overload, which is unchanged.
- Those functions, plus `shield`, `shieldNative`, `shieldWrappedNative` and both `unshield` overloads, now return `sharedEuint64` instead of a bare handle with an `allowTransient` grant. Contract callers must consume the result with `FHE.receiveEuint64FromCall(returned, token)`, naming the address called in the same expression.
- On the four `*AndCall` overloads `inputProof` now precedes `bytes data`, immediately after the handle it authenticates. This is the ordering `@cofhe/abi` 0.7.0 requires: it locates the batch signature in the plain `bytes` following the contiguous run of `external*` inputs. Against the older pre-0.7 helper, which required that `bytes` in the _final_ slot, the two `bytes` arguments swap meaning silently — neither version throws on the wrong ordering, because the wrong parameter is also `bytes`. Callers must be on `@cofhe/*` 0.7.0.

`ERC20ConfidentialUnauthorizedUseOfEncryptedAmount` is removed from both `ERC20ConfidentialLib` and `ERC20ConfidentialCoreUpgradeable`: no code path throws it once the share check replaces the `isAllowed` guards. `FHERC20UnauthorizedUseOfEncryptedAmount` stays — `requestDiscloseEncryptedAmount` still throws it, and keeps its `isAllowed` guard because there is no share to consume there.
