# Project guide

## What this repo is

`fhenix-confidential-contracts` — the FHERC-20 / ERC-7984 confidential token
standard for Fhenix. Solidity contracts that hold encrypted balances with the
CoFHE library (`@fhenixprotocol/cofhe-contracts`).

**This fork has one purpose: port the whole contract set to `.fsol`, the
Solidity dialect compiled by `fhec` (`~/dev/fhec`,
https://github.com/toml01/fhec).** The port is the vehicle. The real goal is to
find and fix the weak points of `fhec`. Read "Report fhec friction" below — it
is not optional.

## Build and test

```
pnpm install
pnpm compile      # hardhat compile
pnpm test         # REPORT_GAS=false hardhat test --network hardhat
pnpm gas          # same, with the gas reporter
pnpm format       # prettier, .ts and .sol
pnpm lint         # eslint, .ts only
```

Hardhat 2.26 with `@cofhe/hardhat-plugin` (mock CoFHE co-processor). Tests are
TypeScript + Mocha + Chai. They do not depend on the source dialect, so they
stay the reference oracle for the whole port. **A port step is done only when
`pnpm test` is green.**

## Architecture map

One external root: `@fhenixprotocol/cofhe-contracts/FHE.sol`. Every contract
reaches it directly or through a parent. OpenZeppelin is the second root and
needs no port.

```
L1  utils/FHESafeMath.sol (lib)            FHERC20/utils/FHERC20Errors.sol
    ERC20Confidential/ERC20ConfidentialIndicator.sol   (plain ERC20, no FHE)
    interfaces/  IERC7984 · IERC7984Receiver · IERC20ConfidentialCore
                 IFHERC20ERC20Wrapper · IFHERC20NativeWrapper · IWETH
L2  interfaces/IFHERC20 · IERC20Confidential      FHERC20/utils/FHERC20Utils (lib)
L3  ERC20Confidential/ERC20ConfidentialLib.sol (lib, 519)   <- hub A
    FHERC20/FHERC20Core.sol (abstract, 410)                 <- hub B
L4  FHERC20/utils/FHERC20WrapperClaims        ERC20ConfidentialCoreUpgradeable (375)
    FHERC20/FHERC20.sol      FHERC20/FHERC20Upgradeable.sol
L5  FHERC20/extensions/FHERC20ERC20WrapperCore (249)
    FHERC20/extensions/FHERC20NativeWrapperCore (247)
L6  FHERC20ERC20Wrapper{,Upgradeable} · FHERC20NativeWrapper{,Upgradeable}
    ERC20Confidential · ERC20ConfidentialUpgradeable
L7  contracts/test/  — 17 harnesses and mocks, used only by the test suite
```

Two families that share a base:

- **FHERC20 family** — `FHERC20Core` holds the logic; `FHERC20` and
  `FHERC20Upgradeable` are thin non-upgradeable / upgradeable faces.
- **ERC20Confidential family** — `ERC20ConfidentialLib` (an external,
  delegatecall-linked library) holds the logic; `ERC20ConfidentialCoreUpgradeable`
  calls into it.

They join at `ERC20ConfidentialLib` (both wrapper cores and
`FHERC20WrapperClaims` import it), `FHESafeMath`, `FHERC20Utils`, and the
`IFHERC20` / `IERC7984` interfaces.

Rule of thumb: each `…Core` file holds all the logic, and each upgradeable /
non-upgradeable pair shares it. Port a core once and both faces follow.

### CoFHE surface in use

24 distinct `FHE.*` functions. Types: `euint64` (193 uses), `sharedEuint64`
(117), `externalEuint64` (29), `ebool` (29), `sharedEbool` (13). The heavy
hitters map straight onto `.fsol` features:

| CoFHE call | count | `.fsol` replacement |
|---|---|---|
| `FHE.asEuint64` | 36 | `in euint64` parameter |
| `FHE.shareEuint64` / `shareEbool` | 38 | `returns (shared(addr) …)` |
| `FHE.receiveEuint64Param` | 15 | `in shared euint64` parameter |
| `FHE.select` | 13 | encrypted `if` / ternary |
| `FHE.allow*` / `isAllowed` | 35 | automatic ACL |
| `FHE.add/sub/gte/lte/eq` | 19 | operators |

## Landmines

- **`ERC20ConfidentialLib` is bytecode-sensitive, but not frozen.** It deploys
  once per chain and links by address into every consumer, and
  `hardhat.config.ts` pins it to solc 0.8.26 / `optimizer.runs: 1` / cancun so
  the artifact reproduces for explorer verification. Keeping its bytecode hash
  stable is **a nice-to-have, not a gate** — this fork is a demo of `fhec`, not
  a production deployment (owner's call, 2026-08-29). Prefer not to move it;
  say plainly when you do, and why. Read the comment block above the
  `overrides` key before you touch it.
- **The library FQN is hardcoded in 11 test files and in
  `deploy/00_deploy_confidential_lib.ts`** as
  `contracts/ERC20Confidential/ERC20ConfidentialLib.sol:ERC20ConfidentialLib`.
  `fhec` writes its output to `generated/`, which moves that FQN. The same path
  is the key of the `solidity.overrides` entry. Any move must update all of
  them together.
- **Upgradeable contracts are storage-layout sensitive.** They use namespaced
  storage. Do not let a rewrite reorder a struct field.
- **`contracts/test/` ships nothing.** `package.json` `files` excludes it. It is
  still part of the port, because the test suite compiles it.

## Report fhec friction — required

This fork exists to improve `fhec`. Every agent that touches a `.fsol` file
**must** report what went wrong. Report it even when you found a workaround —
especially then.

**Open an issue on `toml01/fhec` directly** (`gh issue create -R toml01/fhec`).
Do not add new entries to `FHEC-FINDINGS.md`; that file is now the record of
round 1 plus an index of open issues. Search the tracker first and comment on an
existing issue rather than filing a duplicate.

Log all of these:

- A diagnostic that fired wrongly, or that was correct but unclear.
- A construct the compiler refused that you believe it should accept.
- A construct it accepted that produced wrong or surprising Solidity.
- Generated output that a human auditor would not have written by hand.
- Anything slow, noisy, or awkward in the CLI or the Hardhat plugin.
- A missing feature that forced you back to raw `FHE.*` calls.
- Documentation that was absent, wrong, or hard to find.

One issue per problem. Give it: where it bit (file and line), what you
expected, what you got with the exact diagnostic text, **the smallest `.fsol`
snippet that reproduces it**, the workaround you used, and a suggested fix.
Narrow the repro before filing — a two-contract minimal case is worth more than
a paragraph of description.

Then add a row to the issue table in `FHEC-FINDINGS.md` so the port records what
it is still working around.

Do not fix `fhec` from this repo. File the issue and continue the port.

## Rules for delegated agents

- If you work in an isolated git worktree, stay inside it.
- Run the test suite before you finish.
- Commit all your work. Never push.
- Report what you did and what you did not do in your final message.
- File every `fhec` problem as an issue on `toml01/fhec` before you finish.

## Style and git rules

- Be concise. No filler. Do not restate inputs. Respect report line-caps.
- User-facing text (commits, docs, PR text, plans): short sentences, active voice, simple words (ASD-STE100 style).
- Commit messages: one sentence, imperative. Add a body only when crucial.
- One logical change per commit. Never mix unrelated changes.
- Work on a feature branch. Never commit to main directly.
