---
"fhenix-confidential-contracts": minor
---

Move the transfer-callback boundary onto the `sharedEuintXX` types.

`IERC7984Receiver.onConfidentialTransferReceived` previously took a bare `euint64` and returned a bare `ebool`, with permission granted out of band via `FHE.allowTransient`. On a callback that cannot authenticate its caller, that is a decryption oracle: FHE operations check the permission of the _contract_ performing them, so any caller could pass any handle the receiver is allowed on (including the receiver's own stored state) and read back a value derived from it.

Breaking change:

- **`IERC7984Receiver.onConfidentialTransferReceived` now takes `sharedEuint64` and returns `sharedEbool`.** Both are `bytes32` on the wire, so existing receivers keep compiling against the old signature and fail at runtime with `NotShared`. Every receiver must migrate in the same change.

Implementers must unwrap the amount with `FHE.receiveEuint64Param(amount)`, which requires the sharer to be `msg.sender`, and return `FHE.shareEbool(result, msg.sender)` instead of granting the token access with `FHE.allowTransient`. A received handle carries transient access only; persisting it past the transaction requires `FHE.allowThis` on the unwrapped `euint64`.

`FHERC20Utils.checkOnTransferReceived` still returns a plain `ebool`, so callers inside the token are unaffected.

This scoped out the ERC-7984 user-facing entry points, which kept accepting bare handles guarded by `FHE.isAllowed(value, msg.sender)`. That is superseded within this same release — see the changeset that moves the remaining boundary values onto `sharedEuintXX`. Wallet callers use the `externalEuint64 + inputProof` overload, which is unaffected either way.
