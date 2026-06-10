import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { MockERC20Confidential } from "../typechain-types";
import { ContractTransactionResponse } from "ethers";

// Regression test for audit finding H-01:
// "Deterministic ciphertext handles collide across users, overwriting claims and locking funds"
//
// BEFORE the fix (claims keyed by the raw burned handle): the two users' unshield requests
// collided, the second overwrote the first, and one user's funds were stranded.
//
// AFTER the fix (claims keyed by a unique claimId): the burned handles may still collide
// (that is inherent to content-addressed FHE handles), but each unshield gets a distinct
// claimId, so both users can claim independently and recover their funds.
//
// Run with:  yarn hardhat test test/H01-handle-collision.test.ts --network hardhat

interface UnshieldRequest {
  claimId: string; // unique key passed to claimUnshielded
  handle: string; // burned ciphertext handle, used off-chain to obtain the decryption proof
}

async function getUnshieldRequest(
  tx: ContractTransactionResponse,
  token: MockERC20Confidential,
): Promise<UnshieldRequest> {
  const receipt = await tx.wait();
  for (const log of receipt!.logs) {
    try {
      const parsed = token.interface.parseLog({ topics: log.topics as string[], data: log.data });
      if (parsed?.name === "TokensUnshielded") {
        return { claimId: parsed.args.claimId, handle: parsed.args.amount };
      }
    } catch {}
  }
  throw new Error("TokensUnshielded event not found");
}

describe("H-01 — ciphertext handle collision (regression)", function () {
  it("two fresh users with identical ops each get a distinct claim and both recover funds", async function () {
    const [, alice, bob] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("MockERC20Confidential");
    const token = (await Factory.deploy("Confidential Token", "CTK", 18)) as MockERC20Confidential;
    await token.waitForDeployment();

    const aliceClient = await hre.cofhe.createClientWithBatteries(alice);
    const bobClient = await hre.cofhe.createClientWithBatteries(bob);

    const PUBLIC = ethers.parseEther("10");
    const CONF_FULL = BigInt(10 * 1e6);

    // Identical sequence on two fresh accounts — the scenario that used to lose funds.
    await token.mint(alice.address, PUBLIC);
    await token.mint(bob.address, PUBLIC);
    await token.connect(alice).shield(PUBLIC);
    await token.connect(bob).shield(PUBLIC);

    const txA = await token.connect(alice)["unshield(uint64)"](CONF_FULL);
    const reqA = await getUnshieldRequest(txA, token);

    const txB = await token.connect(bob)["unshield(uint64)"](CONF_FULL);
    const reqB = await getUnshieldRequest(txB, token);

    // The burned handles may still collide (inherent to content-addressed handles)...
    // ...but the claim keys MUST be distinct now. This is the core of the fix.
    expect(reqB.claimId, "claim ids must be unique per user").to.not.equal(reqA.claimId);

    // Each claim points to the correct owner — no overwrite.
    expect((await token.getClaim(reqA.claimId)).to).to.equal(alice.address);
    expect((await token.getClaim(reqB.claimId)).to).to.equal(bob.address);

    // Both users can independently finalize their claims and recover their public tokens.
    const decA = await aliceClient.decryptForTx(reqA.handle).withoutPermit().execute();
    await expect(
      token.connect(alice).claimUnshielded(reqA.claimId, decA.decryptedValue, decA.signature),
    ).to.emit(token, "UnshieldedTokensClaimed");

    const decB = await bobClient.decryptForTx(reqB.handle).withoutPermit().execute();
    await expect(
      token.connect(bob).claimUnshielded(reqB.claimId, decB.decryptedValue, decB.signature),
    ).to.emit(token, "UnshieldedTokensClaimed");

    expect(await token.balanceOf(alice.address)).to.equal(PUBLIC);
    expect(await token.balanceOf(bob.address)).to.equal(PUBLIC);

    // Nothing stranded: the pool released both deposits.
    const POOL = await token.CONFIDENTIAL_POOL();
    expect(await token.balanceOf(POOL)).to.equal(0n);
  });
});
