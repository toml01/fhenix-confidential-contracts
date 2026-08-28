# `.fsol` port plan

Goal: move every contract in this repo from Solidity + raw `FHE.*` calls to
`.fsol`, compiled by `fhec`. Second goal, and the more important one: find every
weak point of `fhec` on the way and record it in `FHEC-FINDINGS.md`.

Ground rules for all phases:

- The TypeScript test suite never changes to fit the port. If a test must
  change, that is a finding first and a change second.
- `pnpm test` must be green at the end of every phase. Commit per phase.
- `git diff` the generated Solidity against the previous generated Solidity.
  A phase that should be behaviour-neutral must produce a behaviour-neutral
  diff.
- Append to `FHEC-FINDINGS.md` as you go, not at the end.

---

## Phase 0 — toolchain

Prove the build works before any source changes.

1. Build `fhec` from `~/dev/fhec`: the CLI and `@fhec/hardhat-plugin`.
2. Add the plugin to `hardhat.config.ts`. Run `fhec init`, keep `fhec.toml`.
3. Fix the FQN break. The plugin repoints `paths.sources` at `generated/`, so
   every artifact name gains that prefix. Update `LIB_FQN` in 11 test files, in
   `deploy/00_deploy_confidential_lib.ts`, and the `solidity.overrides` key in
   `hardhat.config.ts`. Logged as finding 1.
4. Answer the remaining open questions in `FHEC-FINDINGS.md`:
   - Can `solidity.overrides` still pin `ERC20ConfidentialLib` to solc 0.8.26 /
     `runs: 1` once the file lives under `generated/`?
   - Do inline `assembly` blocks pass through unchanged?
   - Do `library`, `using … for`, `abstract contract`, and file-level custom
     errors pass through?
5. Commit `generated/`. It is meant to be committed and it is the audit
   artifact — every later phase is reviewed as a diff of that tree.

**Exit:** `pnpm compile` and `pnpm test` pass with the plugin installed and
zero source files renamed.

## Phase 1 — rename, no rewrite

`git mv` all 41 `.sol` files to `.fsol`. Change nothing else. Update import
paths and the `package.json` `files` glob.

`fhec` guarantees that valid CoFHE Solidity passes through byte-identical. This
phase tests that guarantee against a real codebase, which is the single most
valuable thing this fork can do for `fhec`.

**Exit:** `pnpm test` green, and the generated Solidity is byte-identical to
today's `contracts/` tree. Any byte that differs is a finding.

## Phase 2 — `FHESafeMath` (pilot)

`contracts/utils/FHESafeMath.fsol`. 104 lines, 44 `FHE.*` calls, 8 of the
repo's 13 `FHE.select` sites, no shared handles, no assembly, no inheritance.
It has a dedicated test (`FHESafeMath.test.ts`) and a dedicated mock
(`MockFHESafeMath.sol`), so the round trip is provable in isolation. Only three
files import it.

Convert: `FHE.add/sub/gte/lte/eq` → operators, `FHE.select` → ternary. Keep the
plaintext `if (!FHE.isInitialized(x)) return …` guards as they are — the
condition is plaintext, so no encrypted-`if` lowering applies.

Watch for: does `success ? amount : 0` coerce the plaintext `0`, or must it stay
`FHE.asEuint64(0)`? Does `--acl=insert` add grants inside an `internal` library
function that returns a handle?

**Exit:** `FHESafeMath.test.ts` green, and the generated Solidity is
semantically equal to the original. Diff it by hand, line by line. This is the
one file where a full manual audit of the output is worth the time.

## Phase 3 — leaves

`FHERC20Utils` (58), `FHERC20Errors` (29), and the eight interfaces. Interfaces
carry signatures only, so they mostly test the `in shared euint64` and
`shared(addr)` return syntax at declaration sites — `IERC7984`,
`IERC7984Receiver`, and `IERC20ConfidentialCore` are the interesting ones.

Open question to settle here: can an interface declare `in`/`shared`
parameters, and does the implementing contract then have to match?

**Exit:** `pnpm test` green.

## Phase 4 — `FHERC20Core`

410 lines, 38 `FHE.*` calls, 3 selects, 12 shared-handle calls, 11 ACL calls,
one ERC-7201 assembly block. This is where `in shared` / `shared(msg.sender)`
and automatic ACL first pay off at scale.

Do it in three commits so each mechanism is isolated and each generated diff is
readable:

1. operators and `select`
2. `in` / `in shared` parameters and `shared(...)` returns
3. drop the now-redundant `FHE.allow*` calls, let `--acl=insert` place them

Step 3 is the risky one. The generated ACL grants must match the hand-written
ones exactly. Diff them. A missing grant is a runtime revert, not a compile
error.

**Exit:** `FHERC20.test.ts`, `FHERC20.behavior.ts`, `FHERC20Reentrancy.test.ts`,
`SharedEuintBoundary.test.ts` green.

## Phase 5 — `FHERC20` faces and harnesses

`FHERC20.fsol`, `FHERC20Upgradeable.fsol`, and their harnesses. Thin files that
follow the core for free. Cheap phase, real regression value.

**Exit:** `FHERC20Upgradeable.test.ts` green.

## Phase 6 — wrapper cores

`FHERC20ERC20WrapperCore` (249) and `FHERC20NativeWrapperCore` (247), then the
four thin wrapper faces and `FHERC20WrapperClaims`. Both cores hold ERC-7201
assembly and both import `ERC20ConfidentialLib`, so run them after Phase 4 and
before Phase 8.

**Exit:** `FHERC20ERC20Wrapper.test.ts`, `FHERC20NativeWrapper.test.ts`,
`ClaimCollision.test.ts`, `ClaimUnshieldedBatch.test.ts` green.

## Phase 7 — `ERC20ConfidentialCoreUpgradeable` and the faces

375 lines, but light on FHE (4 calls). Mostly delegation into the library. Port
it with `ERC20Confidential`, `ERC20ConfidentialUpgradeable`, and
`ERC20ConfidentialIndicator` (which has no FHE at all).

**Exit:** `ERC20Confidential.test.ts`, `ERC20ConfidentialUpgradeable.test.ts`,
`ConfidentialDecimals.test.ts`, `ConfidentialObserver.test.ts`,
`ReentrancyExploit.test.ts`, `SyncSupplyOverflow.test.ts` green.

## Phase 8 — `ERC20ConfidentialLib`

519 lines, 46 `FHE.*` calls, 13 shared-handle calls, 15 ACL calls, two assembly
blocks, `using EnumerableSet for …`, two embedded interfaces, and a storage
struct passed by reference. The hardest file, and the one with the most to
teach `fhec`.

Deliberately last, because it is the only file whose bytecode must reproduce.
Treat the port as a new library version: rebuild, re-deploy, re-verify, and
tell every consumer to relink. Confirm that the 0.8.26 / `runs: 1` pin still
applies to the generated file.

**Exit:** the full suite green, and a written note on whether the bytecode
changed and why.

## Phase 9 — the remaining test contracts

The 12 mocks and malicious receivers not covered above. Low risk, and they
exercise the receiver-side `shared` syntax that production contracts do not.

**Exit:** `pnpm test` green.

## Phase 10 — write it up

1. Read `FHEC-FINDINGS.md` end to end. Group, deduplicate, rank by severity.
2. Measure: source lines before and after, `FHE.*` call count before and after,
   gas before and after (`pnpm gas` on both trees).
3. Produce the report for the `fhec` repo: what worked, what broke, what is
   missing, ranked by the pain it caused here.

---

## Order at a glance

```
0 toolchain → 1 rename → 2 FHESafeMath → 3 leaves → 4 FHERC20Core
  → 5 FHERC20 faces → 6 wrapper cores → 7 ERC20Confidential faces
  → 8 ERC20ConfidentialLib → 9 test contracts → 10 report
```

Phases 5 and 6 can run in parallel with 7. Everything else is a chain.
