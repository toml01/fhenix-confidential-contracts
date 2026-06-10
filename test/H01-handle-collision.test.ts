import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { MockERC20Confidential } from "../typechain-types";
import { ContractTransactionResponse } from "ethers";

// Regression test for audit finding H-01 — OPTION B (salt the burned handle).
//
// CoFHE handles are content-addressed, so two users running identical operations would otherwise
// produce the same burned handle, and the second unshield's claim would overwrite the first's.
// Option B keeps the claim ledger keyed by the handle but salts the burned value in `_unshield`
// (`_uniqueizeBurnedHandle`), so the handles are now distinct and both users can claim.
//
// The external interface is unchanged: `unshield` still emits the (now unique) handle, and
// `claimUnshielded(handle, …)` / `getClaim(handle)` work as before.
//
// Run with:  yarn hardhat test test/H01-handle-collision.test.ts --network hardhat

async function getUnshieldHandle(
  tx: ContractTransactionResponse,
  token: MockERC20Confidential,
): Promise<string> {
  const receipt = await tx.wait();
  for (const log of receipt!.logs) {
    try {
      const parsed = token.interface.parseLog({ topics: log.topics as string[], data: log.data });
      if (parsed?.name === "TokensUnshielded") return parsed.args.amount; // burned handle == claim key
    } catch {}
  }
  throw new Error("TokensUnshielded event not found");
}

describe("H-01 — ciphertext handle collision (regression, option B / salt)", function () {
  it("two fresh users with identical ops get distinct burned handles and both recover funds", async function () {
    const [, alice, bob] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("MockERC20Confidential");
    const token = (await Factory.deploy("Confidential Token", "CTK", 18)) as MockERC20Confidential;
    await token.waitForDeployment();

    const aliceClient = await hre.cofhe.createClientWithBatteries(alice);
    const bobClient = await hre.cofhe.createClientWithBatteries(bob);

    const PUBLIC = ethers.parseEther("10");
    const CONF_FULL = BigInt(10 * 1e6);

    await token.mint(alice.address, PUBLIC);
    await token.mint(bob.address, PUBLIC);
    await token.connect(alice).shield(PUBLIC);
    await token.connect(bob).shield(PUBLIC);

    // Balance handles still collide (we don't touch balances)...
    expect(await token.confidentialBalanceOf(bob.address)).to.equal(
      await token.confidentialBalanceOf(alice.address),
    );

    const txA = await token.connect(alice)["unshield(uint64)"](CONF_FULL);
    const handleA = await getUnshieldHandle(txA, token);

    const txB = await token.connect(bob)["unshield(uint64)"](CONF_FULL);
    const handleB = await getUnshieldHandle(txB, token);

    // ...but the salt makes the BURNED handles distinct — this is the fix.
    expect(handleB, "salted burned handles must differ").to.not.equal(handleA);

    // Each handle maps to its own claim, owned by the right user.
    expect((await token.getClaim(handleA)).to).to.equal(alice.address);
    expect((await token.getClaim(handleB)).to).to.equal(bob.address);

    await hre.network.provider.send("evm_increaseTime", [11]);
    await hre.network.provider.send("evm_mine");

    // Both users claim independently with the (unique) handle — interface unchanged.
    const decA = await aliceClient.decryptForTx(handleA).withoutPermit().execute();
    await expect(
      token.connect(alice).claimUnshielded(handleA, decA.decryptedValue, decA.signature),
    ).to.emit(token, "UnshieldedTokensClaimed");

    const decB = await bobClient.decryptForTx(handleB).withoutPermit().execute();
    await expect(
      token.connect(bob).claimUnshielded(handleB, decB.decryptedValue, decB.signature),
    ).to.emit(token, "UnshieldedTokensClaimed");

    expect(await token.balanceOf(alice.address)).to.equal(PUBLIC);
    expect(await token.balanceOf(bob.address)).to.equal(PUBLIC);

    // Nothing stranded.
    expect(await token.balanceOf(await token.CONFIDENTIAL_POOL())).to.equal(0n);
  });
});
