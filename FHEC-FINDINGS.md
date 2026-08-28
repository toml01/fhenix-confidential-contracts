# fhec findings

A running log of problems, gaps, and rough edges found while porting this repo
to `.fsol`. This file is the main deliverable of the fork. The ported contracts
are the by-product.

Append, never rewrite. Keep entries in the order found. See `AGENTS.md` →
"Report fhec friction" for the entry format and the rules.

Severity:

- **blocker** — stopped the port. No workaround, or the workaround gives up a
  `.fsol` feature.
- **friction** — cost real time or forced an ugly shape, but the port went on.
- **polish** — correct behaviour, poor experience. Wording, docs, speed, noise.

---

## Open questions

Things to confirm before or during the port. Move each one into the log below
once it becomes a real finding, or delete it once answered.

- Can `solidity.overrides` still pin one file to solc 0.8.26 / `runs: 1` after
  transpiling? `ERC20ConfidentialLib` must stay bytecode-reproducible.
- Does the transpiler pass inline `assembly` blocks through unchanged? All six
  FHE-bearing files use ERC-7201 storage slots set in assembly.
- Does it handle `library` definitions, `using … for`, `abstract contract`,
  multiple inheritance, and file-level custom errors?
- Does automatic ACL insertion behave inside a `library` whose storage struct
  arrives by reference?

---

## Log

<!-- Add entries below this line. Newest at the bottom. -->

### Repointing `paths.sources` to `generated/` renames every artifact FQN

- **Where:** `@fhec/hardhat-plugin` — README "Usage", and `src/index.ts`
- **Severity:** friction (blocker for any repo that links a library by FQN)
- **Expected:** adding the plugin to an existing Hardhat project is transparent
  to the rest of the config and to the tests.
- **Got:** the plugin sets `paths.sources` to `<root>/<out>`, so Hardhat now
  names every contract `generated/Path/File.sol:Name` instead of
  `contracts/Path/File.sol:Name`. Everything keyed by that string breaks at
  once. In this repo that is:
  - `LIB_FQN` in 11 test files (`ethers.getContractFactory(…, { libraries })`)
  - `LIB_FQN` in `deploy/00_deploy_confidential_lib.ts`
  - the `solidity.overrides` key in `hardhat.config.ts` that pins
    `ERC20ConfidentialLib` to solc 0.8.26 / `runs: 1`
  A linked-library address is baked into consumer bytecode, so this is not a
  cosmetic rename. The failure also arrives as an opaque Hardhat "contract not
  found" rather than as an fhec diagnostic.
- **Repro:** any Hardhat project that passes a fully-qualified name to
  `getContractFactory`, `deployments.deploy({ contract })`, `verify:verify`, or
  `solidity.overrides`. Add the plugin; nothing else changes; the name no
  longer resolves.
- **Workaround:** rewrite every FQN string to the `generated/` prefix. Works,
  but it couples application code to a compiler implementation detail, and it
  makes the same repo un-buildable without the plugin.
- **Suggested fix:** either (a) keep `out` mirroring the source path so FQNs are
  stable, (b) offer `out = "contracts"` with the `.fsol` sources held
  elsewhere, or (c) emit an FHExxxx warning at load listing config keys and
  source files that contain a `contracts/…:Name` literal.

### `@fhec/hardhat-plugin` cannot be installed outside the fhec monorepo

- **Where:** `packages/hardhat-plugin/package.json`, `packages/fhec/package.json`
- **Severity:** blocker
- **Expected:** the README says `pnpm add -D @fhec/hardhat-plugin`. That should
  work in any Hardhat project.
- **Got:** two failures in a row, each needing an undocumented workaround.

  1. The plugin declares `"fhec": "workspace:*"`. Outside the workspace, pnpm
     stops with:
     ```
     ERR_PNPM_WORKSPACE_PKG_NOT_FOUND  "fhec@workspace:*" is in the
     dependencies but no package named "fhec" is present in the workspace
     ```
     The `fhec` wrapper package is also `"private": true`, so it cannot be
     fetched from the registry either. Neither package is on npm today, so
     the documented install line cannot work for anyone.

  2. After forcing the dep through with a pnpm override, the binary still does
     not resolve. `lib/resolve.js` falls back to
     `../../../target/{release,debug}/fhec` relative to itself, which assumes
     the package sits inside the cargo checkout. pnpm materialises a `file:`
     dependency into its own store, so that relative path no longer reaches
     `~/dev/fhec/target/`. The failure text is good — it lists every path
     tried and three fixes — but it arrives where a user expects a working
     install.

- **Repro:**
  ```sh
  cd <any-hardhat-2-project>
  pnpm add -D file:$HOME/dev/fhec/packages/hardhat-plugin
  ```
- **Workaround:** both of these together.
  ```jsonc
  // package.json
  "pnpm": { "overrides": { "fhec": "file:/abs/path/to/fhec/packages/fhec" } }
  ```
  ```sh
  export FHEC_BINARY_PATH=$HOME/dev/fhec/target/release/fhec
  ```
- **Suggested fix:** publish `fhec` and `@fhec/cli-<platform>` to npm and drop
  `private: true`; until then, document the two workarounds in the plugin
  README under a "local checkout" heading. The `workspace:*` pin is the harder
  half — a published `fhec` with a real semver range fixes it for good.

### POSITIVE: the no-op guarantee holds byte-for-byte on a real codebase

Not a defect. Recorded because it is the result the port was designed to test,
and it should stay true.

- **Where:** all 42 files under `contracts/`
- **Result:** `fhec build` on the untouched Solidity tree reports
  `42 file(s) ... (42 pass-through), 0 rewrite site(s)`, and
  `diff -r contracts generated` is empty apart from `generated/.fhec/`.
  `pnpm test` then passes 254 of 254 with no source change at all.
- **Speed:** 0.26 s for the whole tree. No complaint here.
- **Worth keeping:** this repo is a good regression corpus for the guarantee —
  6 files with inline assembly, ERC-7201 namespaced storage, two external
  libraries, `using … for`, multiple inheritance, and file-level custom errors,
  none of which the transpiler disturbed.

### Third-party solc warnings are re-emitted as FHE6000 noise

- **Where:** `fhec build` output; `crates/fhec-cli/src/gate.rs`
- **Severity:** friction
- **Expected:** diagnostics about my code. Warnings from `node_modules` are not
  actionable and drown the ones that are.
- **Got:** five FHE6000 warnings on a clean build, four of them from
  OpenZeppelin sources this repo only consumes:
  ```
  warning[FHE6000]: Transient storage as defined by EIP-1153 can break ...
    --> @openzeppelin/contracts/utils/TransientSlot.sol:108:13
  warning[FHE6000]: Unreachable code.
    --> @openzeppelin/contracts/token/ERC20/ERC20.sol:145:9
  ```
  The EIP-1153 one is a 60-word paragraph. On a real project the signal-to-noise
  ratio makes the build output not worth reading, which defeats the point of
  forwarding solc diagnostics at all.
- **Repro:** any project importing OpenZeppelin v5, `fhec build` (without
  `--no-verify`).
- **Workaround:** `--no-verify`, which the Hardhat plugin passes by default. So
  most users never see this — but they also lose the verify gate.
- **Suggested fix:** suppress non-error FHE6000 for files outside `project.src`
  by default, with a flag to restore them.

### `fhec check` succeeds silently

- **Where:** `crates/fhec-cli` — `check` command
- **Severity:** polish
- **Expected:** a one-line confirmation of what was checked.
- **Got:** no output at all, exit 0. On a 42-file repo this is
  indistinguishable from "found nothing to do", which matters when `src` is
  misconfigured — a wrong `project.src` also prints nothing and exits 0.
  `--verbose` gives the useful line:
  `fhec: 42 file(s) checked clean, 0 rewrite site(s) (config hash 2ff8718ac003)`
- **Suggested fix:** print that line by default; keep silence for `--json`.
  Loudly fail, or at least warn, when zero files match `include`.
