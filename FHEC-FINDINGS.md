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

### Renaming `.sol` to `.fsol` breaks every relative import, with no fix-it

- **Where:** all 42 files; `crates/fhec-bind/src/binder.rs` (FHE1003)
- **Severity:** friction — but it is the very first thing every adopter hits
- **Expected:** renaming a file to opt it into the dialect is the documented
  adoption path ("adopt it one function at a time", GUIDE.md). I expected the
  rename alone to work, or to be told exactly what else to change.
- **Got:** 76 `FHE1003` errors at once. Every relative import specifier still
  ends in `.sol`, and the file it names is now `.fsol`, so nothing resolves:
  ```
  error[FHE1003]: cannot resolve relative import `../interfaces/IFHERC20.sol`
    --> ERC20Confidential/ERC20Confidential.fsol:8:36
  ```
  The compiler knows `../interfaces/IFHERC20.fsol` was discovered in this same
  compilation unit. It does not say so.
  - **0 fix-its** across all 76 diagnostics (`--json`).
  - `--fix` prints `fhec: no safe fix-its to apply` and then re-prints all 76
    errors.
- **Repro:**
  ```sh
  git mv contracts/A.sol contracts/A.fsol   # A is imported by B
  fhec check                                 # FHE1003 on B, no suggestion
  ```
- **Workaround:** rewrite every relative specifier `.sol` → `.fsol` with sed.
  Mechanical, but it must be done in the same commit as the rename, so a
  file-by-file adoption is not actually file-by-file — renaming one file edits
  every file that imports it.
- **Suggested fix:** when a relative import fails to resolve and swapping the
  extension *does* resolve to a discovered file, attach a `safe: true` fix-it.
  `--fix` then makes the whole rename a two-command operation. This is cheap
  and it removes the worst first-run experience in the tool.

### BLOCKER: default `acl.mode = "insert"` injects a confidentiality leak, after warning about it

- **Where:** `contracts/FHERC20/FHERC20Core.fsol:376-407`,
  `contracts/ERC20Confidential/ERC20ConfidentialLib.fsol:140,150`;
  rule R1 in `crates/fhec-lower/src/pass_acl.rs`
- **Severity:** blocker
- **Expected:** renaming `.sol` → `.fsol` is documented as the opt-in switch and
  "everything that was valid Solidity stays valid". I expected the rename to be
  behaviour-neutral until I rewrote something.
- **Got:** the rename alone changed the behaviour of 5 files. R1 fires on every
  encrypted storage write and appends `allowThis` + **`allowSender`**. On an
  account-keyed balance slot that grants the *transaction sender* read access to
  a ciphertext owned by someone else.

  The hand-written source is deliberately not that:
  ```solidity
  (, ptr, transferred) = FHESafeMath.trySpend(fromBalance, amount);
  FHE.allowThis(ptr);
  FHE.allow(ptr, from);        // the OWNER, not msg.sender
  $._balances[from] = ptr;
  ```
  and fhec appends:
  ```solidity
  FHE.allowThis($._balances[from]);
  FHE.allowSender($._balances[from]);   // <-- msg.sender, who in transferFrom
                                        //     is an operator, not `from`
  ```
  In `confidentialTransferFrom` / operator flows `msg.sender != from`, so this
  hands a third party permanent read access to the sender's balance. The same
  happens to `$._totalSupply`, which becomes readable by any caller who moves
  tokens.

  The compiler *knows*. It emits FHE4001 on all four sites:
  > `encrypted write to '$._balances[from]' is keyed by an address that is not
  > 'msg.sender'; the transaction sender gains read access to a ciphertext filed
  > under another address`

  Then it inserts the grant anyway. **Warning about a leak and then writing it
  is the wrong pairing.** For a confidentiality tool this is the one default
  that must not be "do it and warn".
- **Repro:** rename any contract with `mapping(address => euint64)` balances and
  an operator-style transfer to `.fsol`, `fhec build`, diff the output.
- **Workaround:** `acl.mode = "suggest"` in `fhec.toml`. Correct for this repo,
  and fhec's own `packages/difftest/fhec.fherc20.toml` already documents that
  reasoning — but it is not the default, and nothing points a new user at it
  before the damage is in the generated tree.
- **Suggested fix:** make FHE4001 downgrade R1 to *suggest* for that site
  automatically — emit the note, insert nothing, require the author to choose.
  Inserting `allowThis` alone would also be safe and useful; it is `allowSender`
  on a non-`msg.sender`-keyed slot that is never safe to guess. Failing that,
  flip the default to `suggest` and let `insert` be the opt-in.

### R1 dedupe misses the "grant on the local, then store" pattern

- **Where:** `contracts/FHERC20/FHERC20Core.fsol:373-384`; §8.6 dedupe in
  `crates/fhec-lower/src/pass_acl.rs`
- **Severity:** friction
- **Expected:** no insertion where an equivalent grant is already present.
- **Got:** the idiomatic CoFHE shape is compute into a local, grant on the
  local, then store it:
  ```solidity
  FHE.allowThis(ptr);
  $._totalSupply = ptr;
  ```
  §8.6 compares syntactically, so `FHE.allowThis(ptr)` does not match the
  would-be `FHE.allowThis($._totalSupply)` and a redundant grant is appended.
  The handle is the same one; the call is pure gas and noise in output that is
  meant to be audited. It fires at all four `_update` sites.
- **Repro:** any `FHE.allowThis(x); slot = x;` pair.
- **Suggested fix:** extend the dedupe window to treat `slot = local;` as making
  a preceding grant on `local` equivalent to a grant on `slot`, when `local` is
  not reassigned in between. This is the single most common CoFHE idiom.
