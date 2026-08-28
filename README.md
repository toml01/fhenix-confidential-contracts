# fhenix-confidential-contracts — `.fsol` port

A fork of [FhenixProtocol/fhenix-confidential-contracts](https://github.com/FhenixProtocol/fhenix-confidential-contracts), ported from
Solidity + raw `FHE.*` calls to **`.fsol`**, the Solidity dialect compiled by
[`fhec`](https://github.com/toml01/fhec).

The port is the vehicle. The goal is to find and fix the weak points of `fhec` by
building something real with it. **[`FHEC-FINDINGS.md`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/FHEC-FINDINGS.md)
is the main deliverable** — 14 findings, each with a minimal repro, a workaround,
and a suggested fix. All 14 are now fixed upstream. New findings go straight to
the [fhec issue tracker](https://github.com/toml01/fhec/issues). The ported
contracts are the by-product.

> Upstream is unaudited and in active development. This fork adds a compiler to
> that. Do not use it in production.

## Result

All 42 contracts are ported. `fhec check` is clean and **254 of 254 upstream
tests pass** — at every phase boundary, not only at the end. The TypeScript test
suite was never modified, so it stayed an honest oracle throughout.

| | before | after |
|---|---|---|
| `FHE.*` call sites | 195 | 90 (**−54%**) |
| `FHE.asEuint64` / `asEbool` | 46 | 5 |
| `FHE.shareEuint64` | 33 | 12 |
| `FHE.receiveEuint64Param` | 15 | 6 |
| `FHE.add/sub/gte/lte/eq` | 17 | 0 |
| `FHE.select` | 8 | 0 |
| source lines | 3777 | 3778 |

The win is density, not length. Over half the FHE boilerplate is gone and the
line count is flat. **Every arithmetic, comparison and `select` site is now an
operator or a ternary** — none are left.

The port ran in two rounds. Round 1 found 14 defects in `fhec`, all since fixed
(PRs #62–#68). Round 2 re-ran the port against the fixed compiler and deleted
**11 workarounds** the first round had needed. Four findings are still open,
tracked as issues: [#70](https://github.com/toml01/fhec/issues/70),
[#71](https://github.com/toml01/fhec/issues/71),
[#72](https://github.com/toml01/fhec/issues/72),
[#73](https://github.com/toml01/fhec/issues/73).

Two results are worth singling out:

- **The no-op guarantee holds on a real codebase.** Before any rewrite, `fhec
  build` on the untouched tree produced byte-identical output across all 42
  files — including inline assembly, ERC-7201 namespaced storage, two external
  libraries, `using … for`, multiple inheritance, and file-level custom errors.
- **`ERC20ConfidentialLib` was ported without moving its bytecode.** That library
  is pinned to solc 0.8.26 / `runs: 1` because it deploys once per chain and is
  linked by address into every consumer. After the port its compiled bytecode
  hash is unchanged, so no redeploy and no re-verification is needed.

## Ported contracts

Each contract links to its own diff against upstream
[`5138cb8`](https://github.com/FhenixProtocol/fhenix-confidential-contracts/commit/5138cb8) — the original `contracts/X.sol` against the
ported `contracts/X.fsol`. [Full compare](https://github.com/toml01/fhenix-confidential-contracts/compare/5138cb8...fsol-port).

Read the **diff** rows first: those 15 files carry the real port. **imports only**
means the single change is the `.sol` → `.fsol` import extension, which `fhec`
rewrites back on output. **—** means the file was renamed and nothing else.

**Transpiled output** says whether the Solidity `fhec` generates is identical to
upstream, ignoring comments. `identical` means the port is provably
behaviour-preserving for that file — 35 of 42 are. **changed** means the `in` /
`in shared` / `shared(...)` sugar altered the emitted signature: it renames the
ABI parameter of a function *with a body* to `<name>_input` / `<name>_shared`,
and on `FHERC20Core` it also moved eight entrypoints from `public` to `external`,
because `in shared` is `external`-only.

### FHERC20

| Contract | Diff vs upstream | `FHE.*` calls | Transpiled output |
|---|---|---|---|
| [`FHERC20Core`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/FHERC20Core.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/FHERC20Core.diff)** | 37 → 14 | **changed** |
| [`FHERC20ERC20WrapperCore`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/extensions/FHERC20ERC20WrapperCore.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/extensions/FHERC20ERC20WrapperCore.diff)** | 10 → 3 | **changed** |
| [`FHERC20NativeWrapperCore`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/extensions/FHERC20NativeWrapperCore.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/extensions/FHERC20NativeWrapperCore.diff)** | 11 → 3 | **changed** |
| [`FHERC20Utils`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/utils/FHERC20Utils.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/utils/FHERC20Utils.diff)** | 3 → 2 | identical |
| [`FHESafeMath`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/utils/FHESafeMath.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/utils/FHESafeMath.diff)** | 43 → 10 | identical |
| [`FHERC20`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/FHERC20.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/FHERC20.diff) | — | identical |
| [`FHERC20Upgradeable`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/FHERC20Upgradeable.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/FHERC20Upgradeable.diff) | — | identical |
| [`FHERC20ERC20Wrapper`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/extensions/FHERC20ERC20Wrapper.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/extensions/FHERC20ERC20Wrapper.diff) | — | identical |
| [`FHERC20ERC20WrapperUpgradeable`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/extensions/FHERC20ERC20WrapperUpgradeable.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/extensions/FHERC20ERC20WrapperUpgradeable.diff) | — | identical |
| [`FHERC20NativeWrapper`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/extensions/FHERC20NativeWrapper.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/extensions/FHERC20NativeWrapper.diff) | — | identical |
| [`FHERC20NativeWrapperUpgradeable`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/extensions/FHERC20NativeWrapperUpgradeable.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/extensions/FHERC20NativeWrapperUpgradeable.diff) | — | identical |
| [`FHERC20Errors`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/utils/FHERC20Errors.fsol) | — | — | identical |
| [`FHERC20WrapperClaims`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/FHERC20/utils/FHERC20WrapperClaims.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/FHERC20/utils/FHERC20WrapperClaims.diff) | — | identical |

### ERC20Confidential

| Contract | Diff vs upstream | `FHE.*` calls | Transpiled output |
|---|---|---|---|
| [`ERC20ConfidentialCoreUpgradeable`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/ERC20Confidential/ERC20ConfidentialCoreUpgradeable.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/ERC20Confidential/ERC20ConfidentialCoreUpgradeable.diff)** | 3 → 0 | identical |
| [`ERC20ConfidentialLib`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/ERC20Confidential/ERC20ConfidentialLib.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/ERC20Confidential/ERC20ConfidentialLib.diff)** | 45 → 34 | identical |
| [`ERC20Confidential`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/ERC20Confidential/ERC20Confidential.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/ERC20Confidential/ERC20Confidential.diff) | — | identical |
| [`ERC20ConfidentialIndicator`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/ERC20Confidential/ERC20ConfidentialIndicator.fsol) | — | — | identical |
| [`ERC20ConfidentialUpgradeable`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/ERC20Confidential/ERC20ConfidentialUpgradeable.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/ERC20Confidential/ERC20ConfidentialUpgradeable.diff) | — | identical |

### Interfaces

| Contract | Diff vs upstream | `FHE.*` calls | Transpiled output |
|---|---|---|---|
| [`IERC20Confidential`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IERC20Confidential.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/interfaces/IERC20Confidential.diff) | — | identical |
| [`IERC20ConfidentialCore`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IERC20ConfidentialCore.fsol) | — | — | identical |
| [`IERC7984`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IERC7984.fsol) | — | — | identical |
| [`IERC7984Receiver`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IERC7984Receiver.fsol) | — | 4 → 4 | identical |
| [`IFHERC20`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IFHERC20.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/interfaces/IFHERC20.diff) | — | identical |
| [`IFHERC20ERC20Wrapper`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IFHERC20ERC20Wrapper.fsol) | — | — | identical |
| [`IFHERC20NativeWrapper`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IFHERC20NativeWrapper.fsol) | — | — | identical |
| [`IWETH`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/interfaces/IWETH.fsol) | — | — | identical |

### Test contracts

| Contract | Diff vs upstream | `FHE.*` calls | Transpiled output |
|---|---|---|---|
| [`FHERC20Upgradeable_Harness`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/FHERC20Upgradeable_Harness.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/FHERC20Upgradeable_Harness.diff)** | 2 → 0 | identical |
| [`FHERC20_Harness`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/FHERC20_Harness.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/FHERC20_Harness.diff)** | 2 → 0 | identical |
| [`MaliciousReentrantReceiver`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/MaliciousReentrantReceiver.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/MaliciousReentrantReceiver.diff)** | 4 → 1 | **changed** |
| [`MaliciousUnshieldReceiver`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/MaliciousUnshieldReceiver.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/MaliciousUnshieldReceiver.diff)** | 4 → 1 | **changed** |
| [`MockFHERC20Receiver`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/MockFHERC20Receiver.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/MockFHERC20Receiver.diff)** | 2 → 0 | identical |
| [`MockFHESafeMath`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/MockFHESafeMath.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/MockFHESafeMath.diff)** | 13 → 10 | identical |
| [`MockFherc20Vault`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/MockFherc20Vault.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/MockFherc20Vault.diff)** | 3 → 2 | **changed** |
| [`SharedAmountReceiver`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/SharedAmountReceiver.fsol) | **[diff](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/SharedAmountReceiver.diff)** | 5 → 2 | **changed** |
| [`ConfidentialHarness`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/ConfidentialHarness.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/ConfidentialHarness.diff) | — | identical |
| [`ERC1967Proxy`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/ERC1967Proxy.fsol) | — | — | identical |
| [`ERC20ConfidentialUpgradeable_Harness`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/ERC20ConfidentialUpgradeable_Harness.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/ERC20ConfidentialUpgradeable_Harness.diff) | — | identical |
| [`ERC20_Harness`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/ERC20_Harness.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/ERC20_Harness.diff) | — | identical |
| [`FHERC20ERC20Wrapper_Harness`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/FHERC20ERC20Wrapper_Harness.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/FHERC20ERC20Wrapper_Harness.diff) | — | identical |
| [`FHERC20NativeWrapper_Harness`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/FHERC20NativeWrapper_Harness.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/FHERC20NativeWrapper_Harness.diff) | — | identical |
| [`MockERC20Confidential`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/MockERC20Confidential.fsol) | [imports only](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/diffs/test/MockERC20Confidential.diff) | — | identical |
| [`MockSharedAmountCaller`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/contracts/test/MockSharedAmountCaller.fsol) | — | 4 → 4 | identical |

## How it builds

`fhec` transpiles `contracts/*.fsol` into `generated/*.sol`, and Hardhat compiles
`generated/`. Both trees are committed, so the generated Solidity is reviewable
as a diff.

```bash
pnpm install
pnpm compile        # runs `fhec build`, then solc
pnpm test           # 254 passing
```

`@fhec/hardhat-plugin` is not published to npm yet, so this repo links it from a
local `fhec` checkout and points at a locally built binary. See
[`FHEC-FINDINGS.md`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/FHEC-FINDINGS.md) →
*"cannot be installed outside the fhec monorepo"* for the two workarounds, and
[`fhec.toml`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/fhec.toml) for the project configuration.

`acl.mode` is set to `suggest`, not the default `insert`. The reason is in
`fhec.toml` and in finding 1: on an account-keyed balance the default rule grants
read access to `msg.sender`, who in an operator transfer is a third party.

## Documents

- [`FHEC-FINDINGS.md`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/FHEC-FINDINGS.md) — the findings, ranked. Start here.
- [`PORT-PLAN.md`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/PORT-PLAN.md) — the ten-phase plan and where it had to bend.
- [`AGENTS.md`](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/AGENTS.md) — repo map, build commands, and the landmines.
- [`diffs/`](https://github.com/toml01/fhenix-confidential-contracts/tree/fsol-port/diffs) — every per-contract diff, as files.

## Upstream

Everything in `contracts/` derives from
[FhenixProtocol/fhenix-confidential-contracts](https://github.com/FhenixProtocol/fhenix-confidential-contracts) at commit
[`5138cb8`](https://github.com/FhenixProtocol/fhenix-confidential-contracts/commit/5138cb8). MIT licensed, unchanged. See
[LICENSE](https://github.com/toml01/fhenix-confidential-contracts/blob/fsol-port/LICENSE).
