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

## Result

The whole repo is ported. 42 files, all `.fsol`, `fhec check` clean, 100 rewrite
sites, **254 of 254 tests passing** at every phase boundary.

| | before | after |
|---|---|---|
| `FHE.*` call sites | 195 | 95 (**-51%**) |
| `FHE.asEuint64` / `asEbool` | 46 | 5 |
| `FHE.shareEuint64` | 33 | 12 |
| `FHE.receiveEuint64Param` | 15 | 6 |
| `FHE.add/sub/gte/lte/eq` | 17 | 3 |
| `FHE.select` | 8 | 1 |
| source lines | 3777 | 3778 |

The win is density, not length. Half the FHE boilerplate is gone and the line
count is flat, which is the right trade: the remaining lines say what they mean.

Four arithmetic sites could not be converted, all blocked by the same FHE2007
false positive. The 35 `FHE.allow*` calls stay by choice — this repo's ACL policy
is account-directed and rule R1 is wrong for it.

### Findings by severity

| # | Finding | Severity |
|---|---|---|
| 1 | Default `acl.mode = "insert"` injects a confidentiality leak, after warning about it | blocker |
| 2 | Any out-of-unit base poisons call typing in the whole contract | blocker |
| 3 | `@fhec/hardhat-plugin` cannot be installed outside the fhec monorepo | blocker |
| 4 | FHE2007 false positive on tuple destructuring into a pre-declared variable | blocker (per-site) |
| 5 | FHE1015 blames the type when the real problem is the import | friction |
| 6 | `shared(...)` rejects a call whose return parameter is unnamed | friction |
| 7 | `in` / `in shared` rename the ABI parameter | friction |
| 8 | Renaming `.sol` to `.fsol` breaks every relative import, with no fix-it | friction |
| 9 | Repointing `paths.sources` to `generated/` renames every artifact FQN | friction |
| 10 | Encrypted `if` needs a dummy initializer when the target has no pre-value | friction |
| 11 | R1 dedupe misses the "grant on the local, then store" pattern | friction |
| 12 | FHE4001 and FHE4010 fire on the same line and contradict each other | friction |
| 13 | Third-party solc warnings are re-emitted as FHE6000 noise | friction |
| 14 | `fhec check` succeeds silently | polish |

If only three get fixed, make them 1, 2 and 4. Finding 1 is a correctness and
safety issue in the default configuration. Finding 2 disables the shared-return
feature in essentially every real project. Finding 4 forces working code back to
raw `FHE.*` calls.

### Answered along the way

- **`solidity.overrides` still pins one file after transpiling** — yes, once the
  key is rewritten to the `generated/` path. `ERC20ConfidentialLib` still builds
  at solc 0.8.26 / `runs: 1`.
- **Inline `assembly` passes through unchanged** — yes. All six ERC-7201 storage
  blocks are untouched.
- **`library`, `using … for`, `abstract contract`, multiple inheritance, and
  file-level custom errors** all pass through. `library` and `abstract contract`
  also accept the sugar.
- **ACL insertion inside a library taking its storage struct by reference** —
  the `$` local form (`FHERC20Storage storage $ = _get...();` then `$.x = v;`)
  is recognised and states R1 facts correctly. This repo never uses the chained
  `_get...().x = v` form, which reportedly does not.

### The headline result

`fhec build` on the untouched 42-file Solidity tree produced **byte-identical
output** and 254 passing tests. The no-op guarantee holds on a real codebase
with inline assembly, ERC-7201 namespaced storage, two external libraries,
`using … for`, multiple inheritance, and file-level custom errors.

`ERC20ConfidentialLib` is the sharper version of the same result: it is pinned
to solc 0.8.26 / `runs: 1` because it deploys once per chain and is linked by
address. After porting it, the generated Solidity is byte-identical to the
original and **its compiled bytecode hash is unchanged** — so the dialect was
adopted in a bytecode-frozen contract with no redeploy and no re-verification.
That is a strong argument for adoption, and it is worth a fixture.

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

### POSITIVE: `FHESafeMath` lowers to byte-identical hand-written Solidity

- **Where:** `contracts/utils/FHESafeMath.fsol` (Phase 2 pilot)
- **Result:** 8 `FHE.select`, 4 `FHE.add`/`FHE.sub`, 5 comparisons and 9
  `FHE.as*` casts rewritten as operators, ternaries and cast sugar. The
  generated Solidity is **byte-identical** to the 104-line hand-written
  original, apart from two doc-comment lines I reworded myself.
- **Numbers:** `FHE.*` call sites 44 → 11 (the 11 left are `FHE.isInitialized`,
  which has no sugar). Line count unchanged at 104 — the win is density, not
  length. All 254 tests pass.
- **Reads well:** `updated = success ? oldValue - delta : oldValue;` against
  `updated = FHE.select(success, FHE.sub(oldValue, delta), oldValue);`.
- **Worth keeping:** a plaintext `if (!FHE.isInitialized(x)) return ...;` guard
  next to encrypted operators is handled correctly — the plaintext condition is
  left alone and the `return` inside it is not treated as an encrypted-branch
  violation. That mix is everywhere in this codebase and it just worked.

### FHE4001 and FHE4010 fire on the same line and contradict each other

- **Where:** `ERC20ConfidentialLib.fsol:140` and `:150`,
  `FHERC20Core.fsol:386` and `:399`
- **Severity:** friction
- **Expected:** one verdict per site.
- **Got:** two, in sequence, saying opposite things:
  ```
  warning[FHE4001]: encrypted write to `$._confidentialBalances[to]` is keyed by
    an address that is not `msg.sender`; the transaction sender gains read
    access to a ciphertext filed under another address
  note[FHE4010]: ACL suggestion: after this write, add
    `FHE.allowThis($._confidentialBalances[to]); FHE.allowSender($._confidentialBalances[to]);`
  ```
  The warning says the grant leaks. The note tells me to add the grant that
  leaks. A reader following the notes top-to-bottom writes the bug the line
  above warned about.
- **Repro:** `acl.mode = "suggest"` plus any `mapping(address => euintN)` write
  keyed by something other than `msg.sender`.
- **Workaround:** ignore FHE4010 wherever FHE4001 also fires.
- **Suggested fix:** when FHE4001 applies to a site, suppress the FHE4010 note
  or reduce it to `FHE.allowThis(...)` only, and say why the `allowSender` half
  was withheld. Related to the `insert`-mode blocker above: the same rule is
  wrong in both modes, it is just louder in `insert`.
- **Cosmetic:** the two diagnostics underline different spans of the same
  statement (`^^^` stops before `= ptr;` on FHE4001, covers it on FHE4010).

### Encrypted `if` needs a dummy initializer when the target has no pre-value

- **Where:** `contracts/utils/FHESafeMath.fsol` — `trySub`, `tryAdd`, `trySpend`
- **Severity:** friction
- **Expected:** `if (cond) { res = x; }` on a named return to lower to
  `res = FHE.select(cond, x, <zero>)`.
- **Got:** the merge always selects against the *pre-value* of the target, so a
  target that was never assigned needs a hand-written initializer first:
  ```solidity
  res = euint64(0);        // <- required, purely to feed the untaken branch
  if (success) { res = difference; }
  ```
  which lowers to a trivial-encrypt plus three temps:
  ```solidity
  res = FHE.asEuint64(0);
  {
      ebool __fhe_cond_0 = success;
      euint64 __fhe_pre_1 = res;
      euint64 __fhe_then_2;
      { __fhe_then_2 = difference; }
      res = FHE.select(__fhe_cond_0, __fhe_then_2, __fhe_pre_1);
  }
  ```
  against the ternary's single `res = FHE.select(success, difference, FHE.asEuint64(0));`.
  Without the initializer it is FHE2007. So the "natural control flow" pitch
  costs an extra FHE op and 8 lines of generated code exactly where the author
  has no pre-value to merge against.
- **Repro:** any `if (encryptedCond) { namedReturn = x; }` with no prior write.
- **Workaround:** use the ternary for produce-a-fresh-value shapes; keep `if`
  for in-place updates, where the pre-value is real and wanted.
- **Also tried, also refused:** writing both arms so the pre-value is provably
  dead still fails, which is the sharper half of this finding:
  ```solidity
  if (success) { res = difference; } else { res = euint64(0); }
  ```
  ```
  error[FHE2007]: this write inside an encrypted branch merges with the
  variable's previous value, which is possibly uninitialized; assign the
  variable before the `if`
    --> utils/FHESafeMath.fsol:103:13
  ```
  Every path through the `if/else` assigns `res`, so no merge with the previous
  value is needed at all — the lowering could emit
  `res = FHE.select(cond, difference, FHE.asEuint64(0))` directly. The checker
  appears to test initialization per-write rather than after the whole
  statement, so the one form that needs no initializer is the one it rejects.
- **Suggested fix:** when an `if/else` assigns the same target on both arms,
  merge the two branch values and skip the pre-value entirely — no initializer,
  no `__fhe_pre` temp, one `select`. That makes `if/else` exactly as good as the
  ternary and lets a codebase use one style throughout. The current advice in
  the error text ("assign the variable before the `if`") pushes the author into
  the extra FHE op instead.

### FHE1015 blames the type when the real problem is the import

- **Where:** `contracts/interfaces/IERC7984Receiver.fsol:34`
- **Severity:** friction — high time-cost, the message points away from the fix
- **Expected:** either acceptance, or a message naming the actual problem.
- **Got:**
  ```
  error[FHE1015]: `in shared` must be followed by an encrypted type
                  (ebool, euint8..euint128, eaddress)
    --> interfaces/IERC7984Receiver.fsol:34:19
     |
  34 |         in shared euint64 amount,
     |                   ^^^^^^^
  ```
  **`euint64` is in the list the message prints.** The real cause is that this
  file imports only the wire types it used before:
  ```solidity
  import { sharedEbool, sharedEuint64 } from "@fhenixprotocol/cofhe-contracts/FHE.sol";
  ```
  `euint64` is not in scope, so it does not resolve through the trusted profile
  import and types as `Unknown`. Adding `ebool, euint64` to that import fixes it
  instantly. Nothing in the diagnostic hints at scope or imports.

  This is a likely first contact with the shared sugar: you reach for `in shared`
  precisely in the files that previously only needed the `shared*` types, which
  are exactly the files whose imports lack the plain ones.
- **Repro:** a file importing only `sharedEuint64`, using `in shared euint64 x`.
- **Workaround:** add the plain type to the import.
- **Suggested fix:** when the token after `in shared` / `shared(...)` names a
  profile type that is not in scope, say so — "`euint64` is not in scope; add it
  to the import from `@fhenixprotocol/cofhe-contracts/FHE.sol`" — with a
  `safe: true` fix-it that extends the import. Keep the current wording only for
  a genuinely non-encrypted type.

### `in shared` renames the ABI parameter, which is wrong for a published interface

- **Where:** `contracts/interfaces/IERC7984Receiver.fsol`
- **Severity:** friction
- **Expected:** on a bodiless interface member the sugar is signature-only, so
  it should be invisible in the output.
- **Got:** the parameter is renamed. Source `in shared euint64 amount` emits
  `sharedEuint64 amount_shared`, and that name reaches the compiled ABI:
  ```
  ['operator', 'from', 'amount_shared', 'data']
  ```
  The selector is unchanged and the 254 tests still pass, but `IERC7984Receiver`
  is a published standard interface. Its ABI JSON is what integrators read and
  what named-argument call sites use. Renaming a documented parameter to a
  compiler-internal name is not an acceptable cost.
- **Net effect on interfaces:** the sugar generates no conversion statement on a
  bodiless declaration, so it buys nothing there and costs a parameter rename.
- **Repro:** `in shared euint64 amount` in any interface; inspect the artifact ABI.
- **Workaround:** leave interfaces spelled with the plain `sharedEuint64` types
  and use the sugar only in implementations, where it actually generates the
  `FHE.receiveEuint64Param` call. That is what this port does.
- **Suggested fix:** keep the author's parameter name in the emitted signature
  and use the internal `_shared` name only for the generated local. The same
  applies to `in` / `_input`.

### FHE2007 false positive: tuple destructuring into a pre-declared variable is not counted as initialization

- **Where:** `contracts/FHERC20/FHERC20Core.fsol:371, 385, 390`
- **Severity:** blocker for those sites — it forced three expressions back to
  raw `FHE.*` calls
- **Expected:** `(ok, v) = pair(a);` initializes `ok` and `v`, exactly as
  Solidity's own definite-assignment rules say.
- **Got:** three FHE2007 errors on code whose plain-Solidity form is accepted:
  ```
  error[FHE2007]: possibly uninitialized encrypted variable used as a `select`
  condition; CoFHE silently substitutes a default ciphertext for uninitialized
  handles
    --> FHERC20/FHERC20Core.fsol:371:27
      |
  371 |             transferred = success ? amount : euint64(0);
      |                           ^^^^^^^
  ```
  `success` is assigned on the line above by
  `(success, ptr) = FHESafeMath.tryIncrease($._totalSupply, amount);`.

- **Minimal repro** — case A fails, cases B and C are clean:
  ```solidity
  function pair(euint64 a) internal returns (ebool, euint64) {
      return (FHE.asEbool(true), a);
  }

  // A: assign into pre-declared locals -> FHE2007 on BOTH `ok` and `v`
  function tupleAssign(euint64 a) external returns (euint64 r) {
      ebool ok;
      euint64 v;
      (ok, v) = pair(a);
      r = ok ? v : euint64(0);
  }

  // B: declare inside the tuple -> clean
  function tupleDecl(euint64 a) external returns (euint64 r) {
      (ebool ok, euint64 v) = pair(a);
      r = ok ? v : euint64(0);
  }

  // C: plain assignment -> clean
  function plain(euint64 a) external returns (euint64 r) {
      ebool ok = FHE.asEbool(true);
      r = ok ? a : euint64(0);
  }
  ```
  So the analysis handles `DeclMulti` but not assignment-to-existing through a
  tuple.

- **Why it bites hard here:** case A is not a style choice. It is forced whenever
  the destination must outlive the tuple — a named return, or a local declared
  before a branch. In `_update`, `ptr` is used in both arms of a plaintext
  `if/else` and `transferred` is a named return, so neither can be declared
  inside the tuple. Multi-return helpers are the whole point of `FHESafeMath`,
  so this pattern is everywhere in this codebase.

- **Extra sting:** the identical code in plain Solidity passes. `FHE.select(...)`
  written by hand is not "a lowered FHE operation", so the check never runs on
  it. Adopting the dialect turns working code into an error, which is precisely
  the adoption tax the no-op guarantee is meant to avoid.

- **Workaround:** revert those three expressions to `FHE.select` / `FHE.sub` /
  `FHE.add`. Applied, with an in-source comment at each site.
- **Suggested fix:** treat a tuple assignment as initializing every named
  component of its left-hand side, `(, x, y) = f()` included. Case B already
  proves the machinery exists; it just is not wired to the assignment form.

### BLOCKER: any out-of-unit base poisons call typing in the whole contract

- **Where:** `contracts/FHERC20/extensions/FHERC20ERC20WrapperCore.fsol:102, 113, 128`
- **Severity:** blocker — this one will hit almost every real Solidity project
- **Expected:** `return _mint(to, amount);` in a `shared(msg.sender) euint64`
  function, where `_mint` is declared `internal returns (euint64 transferred)`.
- **Got:**
  ```
  error[FHE2012]: this function shares `euint64`, but the returned expression is
  of a type the checker cannot prove is that encrypted type
  ```

- **Minimal repro** — the two contracts are otherwise identical:
  ```solidity
  import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

  contract CleanBase {
      function _mint(address to, euint64 a) internal returns (euint64 transferred) { transferred = a; }
  }
  contract UsesClean is CleanBase {
      function f(euint64 a) external returns (shared(msg.sender) euint64) {
          return _mint(msg.sender, a);          // CLEAN
      }
  }

  contract DirtyBase is ReentrancyGuardTransient {   // <-- the only difference
      function _mint(address to, euint64 a) internal returns (euint64 transferred) { transferred = a; }
  }
  contract UsesDirty is DirtyBase {
      function f(euint64 a) external returns (shared(msg.sender) euint64) {
          return _mint(msg.sender, a);          // FHE2012
      }
  }
  ```
  It took eight repro rounds to pin down, because the obvious hypotheses were
  all wrong. It is **not** about libraries, `public` vs `internal`, cross-file
  imports, overloads, or the encrypted types. The rule is:

  > If the **calling** contract's linearized base chain contains anything the
  > compilation unit cannot see, every call expression in that contract types as
  > `Unknown`.

  The callee is irrelevant — it can be fully resolvable, in another file, with a
  named return, and it is still `Unknown`. Final repro, where the *only* edit is
  the base list of the caller:
  ```solidity
  // contracts/L.fsol
  library L { function pub(euint64 a) public returns (euint64 out) { out = a; } }

  // contracts/T.fsol
  contract T {                                    // CLEAN
      function c1(euint64 a) external returns (shared(msg.sender) euint64) { return L.pub(a); }
  }
  contract T is ReentrancyGuardTransient {        // FHE2012 on the identical line
      function c1(euint64 a) external returns (shared(msg.sender) euint64) { return L.pub(a); }
  }
  ```

- **Why this is severe:** essentially every production Solidity contract
  inherits something from `node_modules` — OpenZeppelin, Solmate, an upgradeable
  base. In this repo `FHERC20Core is IFHERC20, ReentrancyGuardTransient`, so
  every helper it declares is poisoned for every subclass. The feature works in
  a self-contained fixture and stops working in a real codebase.

- **Workaround:** bind to a local of declared type first — the declaration wins
  over the call's `Unknown`:
  ```solidity
  euint64 v = _mint(msg.sender, a);
  return v;
  ```
  Applied at all three sites, with a comment. It costs the one-liner the sugar
  was supposed to buy.

- **Suggested fix:** incomplete inheritance should only make *unresolved* names
  `Unknown`. A call the binder statically resolved has a known return type, and
  that type should stand whatever the caller's base list looks like. Right now
  one unseen base disables the feature for every call in the contract.
- **Diagnostic fix, independently:** "of a type the checker cannot prove is that
  encrypted type" gives no hint that an unrelated base import is the cause. It
  should name what it resolved the expression to and why — e.g. "`L.pub` resolves
  to `Unknown` because contract `T` inherits `ReentrancyGuardTransient`, which is
  outside the compilation unit". That single sentence would have saved eight
  repro rounds.

### `shared(...)` also rejects a call whose return parameter is unnamed

- **Where:** found while narrowing the finding above
- **Severity:** friction
- **Expected:** `returns (euint64)` and `returns (euint64 out)` behave the same.
  In Solidity they do.
- **Got:** they do not. Same contract, no inheritance involved:
  ```solidity
  function unnamed(euint64 a) internal returns (euint64)     { return a; }
  function named(euint64 a)   internal returns (euint64 out) { out = a; }

  function c1(euint64 a) external returns (shared(msg.sender) euint64) { return unnamed(a); } // FHE2012
  function c2(euint64 a) external returns (shared(msg.sender) euint64) { return named(a); }   // clean
  function c3(euint64 a) external returns (shared(msg.sender) euint64) { return a; }          // clean
  function c4(euint64 a) external returns (shared(msg.sender) euint64) {
      euint64 v = unnamed(a); return v;                                                        // clean
  }
  ```
  This is what `_unshield(...) internal virtual returns (euint64)` hit in this
  repo. Whether a return parameter is named is a pure style choice with no
  semantic content, so it should not decide whether a feature compiles.
- **Workaround:** name the return parameter, or bind to a local.
- **Suggested fix:** derive the call's type from the return *type*, not the
  return *declaration*.
