// Regression test for audit finding H-01 — OPTION C (revert on collision).
//
// CoFHE handles are content-addressed, so two users running identical operations produce the same
// burned handle. Option C keeps the claim ledger keyed by the handle (no interface change, no extra
// FHE ops) but adds an existence guard in `_createClaim`: a colliding second unshield REVERTS with
// `ClaimAlreadyExists` instead of silently overwriting the first claim and stranding its funds.
//
// This converts the fund-loss bug into a loud, no-loss liveness failure for the colliding caller
// (the same trade-off as OpenZeppelin's ERC7984 `assert(unwrapRequester(handle) == address(0))`).
//
// Placement: copy into `test/` of fhenix-confidential-contracts, then:
//   yarn hardhat test test/H01-handle-collision.test.ts --network hardhat

import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { MockERC20Confidential } from "../typechain-types";
import { ContractTransactionResponse } from "ethers";

async function getUnshieldHandle(tx: ContractTransactionResponse, token: MockERC20Confidential): Promise<string> {
  const receipt = await tx.wait();
  for (const log of receipt!.logs) {
    try {
      const parsed = token.interface.parseLog({ topics: log.topics as string[], data: log.data });
      if (parsed?.name === "TokensUnshielded") return parsed.args.amount; // burned handle == claim key
    } catch {}
  }
  throw new Error("TokensUnshielded event not found");
}

describe("H-01 — ciphertext handle collision (regression, option C / revert-on-collision)", function () {
  it("a colliding second unshield reverts with no fund loss; the first claim still settles", async function () {
    const [, alice, bob] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("MockERC20Confidential");
    const token = (await Factory.deploy("Confidential Token", "CTK", 18)) as MockERC20Confidential;
    await token.waitForDeployment();

    const aliceClient = await hre.cofhe.createClientWithBatteries(alice);

    const PUBLIC = ethers.parseEther("10");
    const CONF_FULL = BigInt(10 * 1e6);

    // Two fresh accounts, identical operations => identical balance handles (collision precondition).
    await token.mint(alice.address, PUBLIC);
    await token.mint(bob.address, PUBLIC);
    await token.connect(alice).shield(PUBLIC);
    await token.connect(bob).shield(PUBLIC);
    expect(await token.confidentialBalanceOf(bob.address)).to.equal(await token.confidentialBalanceOf(alice.address));

    // Alice unshields first -> a claim is created under the burned handle.
    const txA = await token.connect(alice)["unshield(uint64)"](CONF_FULL);
    const handleA = await getUnshieldHandle(txA, token);

    // Bob's identical unshield produces the SAME burned handle and now REVERTS instead of
    // overwriting Alice's claim. (Before the fix, this silently stranded Alice's funds.)
    await expect(token.connect(bob)["unshield(uint64)"](CONF_FULL)).to.be.revertedWithCustomError(
      token,
      "ClaimAlreadyExists",
    );

    // Bob lost nothing: the revert rolled back his burn, so his confidential balance is intact.
    await hre.cofhe.mocks.expectPlaintext(await token.confidentialBalanceOf(bob.address), CONF_FULL);

    // Alice's claim is unaffected and settles normally.
    await hre.network.provider.send("evm_increaseTime", [11]);
    await hre.network.provider.send("evm_mine");
    const dec = await aliceClient.decryptForTx(handleA).withoutPermit().execute();
    await expect(
      token.connect(alice).claimUnshielded(handleA, dec.decryptedValue, dec.signature),
    ).to.emit(token, "UnshieldedTokensClaimed");
    expect(await token.balanceOf(alice.address)).to.equal(PUBLIC);
  });
});
