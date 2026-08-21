import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { MockFHESafeMath } from "../typechain-types";

// Direct unit coverage for FHESafeMath.trySpend, the saturating debit that also reports how much
// it actually took. The token suites exercise it end-to-end, but they only reach the branches an
// ordinary transfer walks; these cases pin every branch, including the two uninitialized-input
// paths that a token can hit but never asserts on.
//
// The contract under test:
//   - all-or-nothing, never partial: an over-balance debit leaves the balance untouched and
//     reports `spent == 0` (NOT `spent == balance`, which is what a `min`-based saturating sub
//     would do, and which would silently drain accounts).
//   - `spent` is always an initialized, caller-owned handle, so callers can FHE.allow it and feed
//     it into further FHE ops. This is the invariant the old call sites got for free from their own
//     `FHE.select(success, amount, 0)`, and the reason the uninitialized branches return an
//     explicit trivially-encrypted zero rather than passing an input handle straight through.
//   - `success`/`updated` agree with tryDecrease for identical inputs, since trySpend is only a
//     cheaper spelling of the same semantics.
const BALANCE = 1_000_000n;

describe("FHESafeMath.trySpend", function () {
  async function fixture() {
    const math = (await (await ethers.getContractFactory("MockFHESafeMath")).deploy()) as MockFHESafeMath;
    await math.waitForDeployment();
    return math;
  }

  it("debits in full when the amount fits, and reports it as spent", async function () {
    const math = await fixture();
    await (await math.seedBalance(BALANCE)).wait();

    await (await math.trySpend(400_000n)).wait();

    await hre.cofhe.mocks.expectPlaintext(await math.success(), 1n);
    await hre.cofhe.mocks.expectPlaintext(await math.updated(), 600_000n);
    await hre.cofhe.mocks.expectPlaintext(await math.spent(), 400_000n);
  });

  it("spends the exact balance (boundary: amount == balance)", async function () {
    const math = await fixture();
    await (await math.seedBalance(BALANCE)).wait();

    await (await math.trySpend(BALANCE)).wait();

    await hre.cofhe.mocks.expectPlaintext(await math.success(), 1n);
    await hre.cofhe.mocks.expectPlaintext(await math.updated(), 0n);
    await hre.cofhe.mocks.expectPlaintext(await math.spent(), BALANCE);
  });

  it("no-ops on an over-balance amount: balance untouched, spent 0 — never a partial drain", async function () {
    const math = await fixture();
    await (await math.seedBalance(BALANCE)).wait();

    await (await math.trySpend(BALANCE + 1n)).wait();

    await hre.cofhe.mocks.expectPlaintext(await math.success(), 0n);
    await hre.cofhe.mocks.expectPlaintext(await math.updated(), BALANCE);
    // The whole point: 0, not BALANCE.
    await hre.cofhe.mocks.expectPlaintext(await math.spent(), 0n);
  });

  it("no-ops without underflowing when the amount dwarfs the balance", async function () {
    const math = await fixture();
    await (await math.seedBalance(BALANCE)).wait();

    await (await math.trySpend(2n ** 64n - 1n)).wait();

    await hre.cofhe.mocks.expectPlaintext(await math.success(), 0n);
    await hre.cofhe.mocks.expectPlaintext(await math.updated(), BALANCE);
    await hre.cofhe.mocks.expectPlaintext(await math.spent(), 0n);
  });

  describe("uninitialized inputs", function () {
    it("treats an uninitialized balance as zero: fails, and still returns real zero handles", async function () {
      const math = await fixture();
      // No seedBalance — the balance slot is still the zero handle.
      expect(await math.balance()).to.equal(ethers.ZeroHash);

      await (await math.trySpend(1n)).wait();

      await hre.cofhe.mocks.expectPlaintext(await math.success(), 0n);
      // Both outputs must be REAL ciphertexts, not the zero handle: callers FHE.allow them.
      expect(await math.updated()).to.not.equal(ethers.ZeroHash);
      expect(await math.spent()).to.not.equal(ethers.ZeroHash);
      await hre.cofhe.mocks.expectPlaintext(await math.updated(), 0n);
      await hre.cofhe.mocks.expectPlaintext(await math.spent(), 0n);
    });

    it("succeeds on a zero amount against an uninitialized balance", async function () {
      const math = await fixture();

      await (await math.trySpend(0n)).wait();

      await hre.cofhe.mocks.expectPlaintext(await math.success(), 1n);
      await hre.cofhe.mocks.expectPlaintext(await math.updated(), 0n);
      await hre.cofhe.mocks.expectPlaintext(await math.spent(), 0n);
    });

    it("treats an uninitialized amount as a zero debit", async function () {
      const math = await fixture();
      await (await math.seedBalance(BALANCE)).wait();

      await (await math.trySpendUninitializedAmount()).wait();

      await hre.cofhe.mocks.expectPlaintext(await math.success(), 1n);
      await hre.cofhe.mocks.expectPlaintext(await math.updated(), BALANCE);
      await hre.cofhe.mocks.expectPlaintext(await math.spent(), 0n);
    });

    it("returns real zero handles when BOTH balance and amount are uninitialized", async function () {
      const math = await fixture();

      await (await math.trySpendUninitializedAmount()).wait();

      await hre.cofhe.mocks.expectPlaintext(await math.success(), 1n);
      expect(await math.updated()).to.not.equal(ethers.ZeroHash);
      expect(await math.spent()).to.not.equal(ethers.ZeroHash);
      await hre.cofhe.mocks.expectPlaintext(await math.updated(), 0n);
      await hre.cofhe.mocks.expectPlaintext(await math.spent(), 0n);
    });
  });

  // trySpend is meant to be tryDecrease plus the spent amount, one FHE op cheaper — not a
  // different rounding of "saturating". If these ever diverge, one of the two is wrong.
  describe("agrees with tryDecrease on success/updated", function () {
    for (const [label, amount, expectedSuccess, expectedUpdated] of [
      ["fits", 400_000n, 1n, 600_000n],
      ["exact", BALANCE, 1n, 0n],
      ["over balance", BALANCE + 1n, 0n, BALANCE],
    ] as const) {
      it(label, async function () {
        const spendMath = await fixture();
        await (await spendMath.seedBalance(BALANCE)).wait();
        await (await spendMath.trySpend(amount)).wait();

        const decreaseMath = await fixture();
        await (await decreaseMath.seedBalance(BALANCE)).wait();
        await (await decreaseMath.tryDecrease(amount)).wait();

        for (const m of [spendMath, decreaseMath]) {
          await hre.cofhe.mocks.expectPlaintext(await m.success(), expectedSuccess);
          await hre.cofhe.mocks.expectPlaintext(await m.updated(), expectedUpdated);
        }
      });
    }
  });
});
