---
"fhenix-confidential-contracts": minor
---

Add `FHESafeMath.trySpend` and route the confidential debit path through it, cutting one FHE operation from every transfer.

The debit leg used to run two selects for one decision: `tryDecrease` selected between the old and new balance, then the call site re-derived the moved amount with a second `FHE.select(success, amount, 0)`. `trySpend` returns the debited amount alongside the updated balance, so the caller reads it off the debit instead of recomputing it — and selecting the delta first lets a single `FHE.sub` replace `tryDecrease`'s `FHE.sub` + `FHE.select` pair:

```solidity
success = FHE.gte(balance, amount);
spent   = FHE.select(success, amount, FHE.asEuint64(0));
updated = FHE.sub(balance, spent); // `spent` fits by construction, so this cannot underflow
```

Six FHE tasks per transfer become five (`gte`, `trivialEncrypt`, `select`, `sub`, `add`), which measures as ~121k gas saved per confidential transfer against the mock coprocessor (`ERC20Confidential` 986,873 → 865,224; base `FHERC20` 976,880 → 855,409, both ~12%). `confidentialTransferAndCall` runs two debits and saves twice.

Semantics are unchanged: the debit is still all-or-nothing, so an over-balance transfer moves nothing rather than partially draining the sender, and `spent` is always an initialized, caller-owned handle that is safe to `FHE.allow`.

`tryDecrease`, `tryIncrease`, `tryAdd`, and `trySub` are untouched, so nothing downstream breaks — `trySpend` is purely additive. `tryDecrease` now has no in-repo call sites and remains only as published API.
