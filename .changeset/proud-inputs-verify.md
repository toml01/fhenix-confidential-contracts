---
"fhenix-confidential-contracts": major
---

Migrate to `@cofhe/*` 0.7 and `@fhenixprotocol/cofhe-contracts` 0.2.x (batch input verification).

`cofhe-contracts` 0.2.x deletes the `InEuintXX` structs and the `FHE.asEuint64(InEuint64)` overload. The per-ciphertext signature that the struct used to carry is replaced by one signature per batch, passed as a trailing `bytes` parameter.

Breaking changes:

- **Every function taking an encrypted input changed shape.** `InEuint64 memory encryptedAmount` becomes `externalEuint64 encryptedAmount, bytes calldata inputProof`, across `IERC7984`, `IERC20ConfidentialCore`, `FHERC20Core`, `ERC20ConfidentialCoreUpgradeable` and `ERC20ConfidentialLib`. On the wire the struct tuple `(uint256,uint8,uint8,bytes)` becomes `bytes32,bytes`, so callers selecting overloads by signature string must be updated.
- **On the `*AndCall` overloads the proof is the LAST parameter**, after `bytes data`: `confidentialTransferAndCall(address,bytes32,bytes,bytes)`. `@cofhe/abi` requires a plain `bytes` in the final slot for the batch signature, and rejects the ABI otherwise.
- **`ERC20ConfidentialLib` must be redeployed and every host relinked.** Its ABI changed, so this build is not interchangeable with library instances deployed before 0.7.
- **Callers must name the consuming contract before encrypting.** `client.encryptInputs([...])` now requires `.setConsumingContract(address)` before `.execute()`, and `execute()` returns `[...hashes, signature]` rather than one struct per value. The verifier binds the consuming contract into the signed digest, so a batch signed for one contract cannot be replayed into another.
- **`@fhenixprotocol/cofhe-contracts` is pinned to `0.2.0-beta.3`** and the `@cofhe/*` packages to a dated alpha, because 0.7.0 is not yet on the registry. Confirm the final versions before publishing this package.

Not included: the move onto the `sharedEuintXX` types for encrypted values crossing a contract boundary. That changes `IERC7984Receiver`, which third parties implement, and both sides of a handoff must migrate together. The old spelling still compiles and runs, so it is tracked separately.
