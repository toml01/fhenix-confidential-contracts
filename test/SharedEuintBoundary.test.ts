import { expect } from "chai";
import hre, { ethers } from "hardhat";
import { Encryptable } from "@cofhe/sdk";
import { FHERC20_Harness, SharedAmountReceiver } from "../typechain-types";

// Proves the `sharedEuintXX` migration of the transfer-callback boundary actually bought the
// protection it is supposed to, rather than just changing types.
//
// The boundary is FHERC20Utils.checkOnTransferReceived ->
// IERC7984Receiver.onConfidentialTransferReceived. Before the migration both encrypted values on
// that boundary were bare handles with an out-of-band `allowTransient` grant, which makes an
// unauthenticated callback into a decryption oracle: FHE operations check the permission of the
// CONTRACT performing them, so any caller could pass any handle the receiver is allowed on and
// read back a value derived from it.
//
// A clean compile proves nothing here (the old spelling compiled too), and neither does the
// existing *AndCall suite, which only walks the happy path. These two cases are the actual
// evidence: the round trip delivers the real value, and the direct-call oracle path is closed.
const AMOUNT = BigInt(1e6); // 1.0 confidential unit at 6 decimals

describe("sharedEuint64 transfer-callback boundary", function () {
  async function fixture() {
    const [, bob] = await ethers.getSigners();
    // FHERC20 base does not use the claims lib — no linking needed.
    const token = (await (
      await ethers.getContractFactory("FHERC20_Harness")
    ).deploy("Confidential Token", "CTK", 6, "")) as FHERC20_Harness;
    await token.waitForDeployment();
    await (await token.mint(bob.address, 10n * AMOUNT)).wait();

    const receiver = (await (await ethers.getContractFactory("SharedAmountReceiver")).deploy()) as SharedAmountReceiver;
    await receiver.waitForDeployment();

    const bobClient = await hre.cofhe.createClientWithBatteries(bob);
    return { bob, token, receiver, bobClient };
  }

  it("round trip: the receiver really receives the transferred amount", async function () {
    const { bob, token, receiver, bobClient } = await fixture();
    const receiverAddr = await receiver.getAddress();

    const [hash, proof] = await bobClient
      .encryptInputs([Encryptable.uint64(AMOUNT)])
      .setConsumingContract(await token.getAddress())
      .execute();

    await (
      await token
        .connect(bob)
        ["confidentialTransferAndCall(address,bytes32,bytes,bytes)"](receiverAddr, hash, "0x", proof)
    ).wait();

    // The callback ran, unwrapped the directed share, and persisted the handle.
    expect(await receiver.callbackCount()).to.equal(1n);
    // And what it unwrapped is the real transferred amount, not a zero or a stray handle.
    await hre.cofhe.mocks.expectPlaintext(await receiver.lastAmount(), AMOUNT);
  });

  it("oracle path is closed: calling the callback directly with an unshared handle reverts", async function () {
    const { bob, token, receiver } = await fixture();

    // A handle the RECEIVER is legitimately allowed on would be the strongest input, but any
    // handle demonstrates the check: nothing was shared with the receiver in this transaction,
    // so `receiveEuint64Param` has no share record to consume and must refuse. Before the
    // migration this call succeeded and performed FHE work on the attacker's chosen handle.
    const someHandle = await token.confidentialBalanceOf(bob.address);

    // Assert the SPECIFIC refusal, not just "it reverted": NotShared is the ACL reporting that
    // no share record exists for this receiver. A generic `to.be.reverted` would also pass on an
    // unrelated failure and would not prove the oracle path is what closed.
    const aclAbi = await ethers.getContractAt("MockACL", ethers.ZeroAddress);
    await expect(
      receiver.connect(bob).onConfidentialTransferReceived(bob.address, bob.address, someHandle, "0x"),
    ).to.be.revertedWithCustomError(aclAbi, "NotShared");

    // No callback was recorded, so the receiver did no FHE work on the supplied handle.
    expect(await receiver.callbackCount()).to.equal(0n);
  });
});
