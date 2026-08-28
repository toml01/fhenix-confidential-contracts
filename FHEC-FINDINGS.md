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
