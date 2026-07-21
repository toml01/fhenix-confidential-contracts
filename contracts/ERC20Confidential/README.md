# ERC20Confidential

A **dual-mode** confidential token: a real, fully-functional public ERC-20 **and** a second
FHE-encrypted balance, in the same contract. Value moves between the two with `shield`
(public → confidential) and `unshield` → `claimUnshielded` (confidential → public).

> `ERC20Confidential` is **abstract** — inherit it and add your own mint / access-control policy.

## Dual mode vs. FHERC20

Both share the same confidential (ERC-7984) transfer API. The difference is the public side:

| | `FHERC20` | `ERC20Confidential` |
|---|---|---|
| Public `balanceOf` | Fake indicator | **Real** balance |
| `transfer` / `approve` / `transferFrom` | Revert | Work normally |
| Public ↔ confidential bridge | Separate wrapper contracts | Built in (`shield` / `unshield`) |

**FHERC20 is confidential-only with a decorative public face. `ERC20Confidential` is a real ERC-20
with a confidential layer on top.**

## How it works

- Every confidential unit is **backed 1:1** by public tokens held at `CONFIDENTIAL_POOL`
  (`0x1011…0000`). `shield` moves public tokens into the pool and mints an encrypted balance;
  `claimUnshielded` releases them back out.
- The public token can use any decimals; the **confidential layer is capped at 6** (balances are
  `euint64`). The conversion rate is `10^(decimals - 6)` when `decimals > 6`, else `1`.
- Confidential transfers, time-based **operators** (instead of allowances), and receiver
  **callbacks** work exactly as in `FHERC20`.
- Wallet "activity" is shown by a separate, auto-deployed `ERC20ConfidentialIndicator` sidecar
  (the main token's `balanceOf` is a real balance, so it can't double as an indicator).

### Shield (public → confidential) — synchronous
Rounds down to the confidential precision, moves public tokens to the pool, mints the encrypted
balance. Reverts `AmountTooSmallForConfidentialPrecision` for sub-rate dust.

### Unshield → Claim (confidential → public) — asynchronous
1. `unshield(amount)` burns the confidential balance and marks the burned handle publicly
   decryptable (creating a pending claim).
2. Decrypt the burned amount off-chain (`decryptForTx(...).withoutPermit()`).
3. `claimUnshielded(ctHash, amount, proof)` verifies the proof and releases the public tokens from
   the pool. (`claimUnshieldedBatch` handles many at once.)

## Usage

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20Confidential } from "fhenix-confidential-contracts/contracts/ERC20Confidential/ERC20Confidential.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract MyDualToken is ERC20Confidential, Ownable {
    constructor() ERC20Confidential("My Dual Token", "MDT", 18) Ownable(msg.sender) {}

    // Mints PUBLIC tokens; holders shield them to go confidential
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
```

```ts
import { Encryptable } from '@cofhe/sdk';

await token.mint(user.address, ethers.parseUnits('1000', 18));  // public
await token.shield(ethers.parseUnits('400', 18));               // public -> confidential

// confidential transfer (150 tokens at 6 decimals)
const [enc] = await cofheClient.encryptInputs([Encryptable.uint64(150_000_000n)]).execute();
await token.confidentialTransfer(recipient.address, enc);

// confidential -> public
await token.unshield(100_000_000n);
const [claim] = await token.getUserClaims(user.address);
const { ctHash, decryptedValue, signature } =
  await cofheClient.decryptForTx(claim.ctHash).withoutPermit().execute();
await token.claimUnshielded(ctHash, decryptedValue, signature);
```

To mint straight into the confidential layer, use `_confidentialMint`, which also mints the backing
into `CONFIDENTIAL_POOL` so every confidential unit stays redeemable.

## Gotchas

- `balanceOf` is the **real public** balance — read confidential balances via `confidentialBalanceOf`
  and decrypt off-chain.
- **Shield/unshield amounts are public** (`TokensShielded` carries a plaintext amount). Privacy
  begins *after* value is inside the confidential layer.
- A `confidentialBalanceOf` handle of `0` means **"never held"**, not "zero".
- Confidential transfers/unshields **never revert on insufficient balance** — they move encrypted
  `0`. Use the returned handle, not the requested amount.
- **Never credit a confidential balance without funding the pool** — unshield claims would drain it.
- Operators get **full, all-or-nothing** access until `until` (a `uint48` seconds timestamp). Prefer
  short windows.

## Files

- `ERC20Confidential.sol` — core dual-balance token
- `ERC20ConfidentialUpgradeable.sol` — upgradeable variant (ERC-7201 storage + initializer)
- `ERC20ConfidentialIndicator.sol` — display sidecar token
- `../interfaces/IERC20Confidential.sol` — `IERC20Confidential is IFHERC20`, adds the shield/unshield bridge
</content>
