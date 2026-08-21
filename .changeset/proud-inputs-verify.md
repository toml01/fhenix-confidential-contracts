---
"fhenix-confidential-contracts": minor
---

Migrate to `@cofhe/*` 0.7 and `@fhenixprotocol/cofhe-contracts` 0.2.x (batch input verification).

`cofhe-contracts` 0.2.x deletes the `InEuintXX` structs and the `FHE.asEuint64(InEuint64)` overload. The per-ciphertext signature that the struct used to carry is replaced by one signature per batch, passed as a trailing `bytes` parameter.

Breaking changes:

- **Every function taking an encrypted input changed shape.** `InEuint64 memory encryptedAmount` becomes `externalEuint64 encryptedAmount, bytes calldata inputProof`, across `IERC7984`, `IERC20ConfidentialCore`, `FHERC20Core`, `ERC20ConfidentialCoreUpgradeable` and `ERC20ConfidentialLib`. On the wire the struct tuple `(uint256,uint8,uint8,bytes)` becomes `bytes32,bytes`, so callers selecting overloads by signature string must be updated.
- **The `*AndCall` overloads gained a second `bytes` parameter**: `confidentialTransferAndCall(address,bytes32,bytes,bytes)`. `inputProof` sits immediately after the handle it authenticates, ahead of `bytes data` — `@cofhe/abi` locates the batch signature in the plain `bytes` following the contiguous run of `external*` inputs (cofhesdk changeset `proof-follows-hash`). Callers selecting this overload by signature string get an unchanged selector, so the two `bytes` arguments must be ordered by hand.
- **`ERC20ConfidentialLib` must be redeployed and every host relinked.** Its ABI changed, so this build is not interchangeable with library instances deployed before 0.7.
- **Callers must name the consuming contract before encrypting.** `client.encryptInputs([...])` now requires `.setConsumingContract(address)` before `.execute()`, and `execute()` returns `[...hashes, signature]` rather than one struct per value. The verifier binds the consuming contract into the signed digest, so a batch signed for one contract cannot be replayed into another.
- **The `@cofhe/*` packages are on `0.7.0`.** `@fhenixprotocol/cofhe-contracts` stays pinned to `0.2.0-beta.3`: the 0.2.x line is what carries `externalEuint64` / `sharedEuint64`, and it has no stable release yet (`latest` is still 0.1.5). Confirm that pin before publishing this package.

The move onto the `sharedEuintXX` types for encrypted values crossing a contract boundary is tracked separately, in its own changeset in this release.
