import { expect } from "chai";
import { ethers } from "hardhat";
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";

const FEE_BPS = 100n; // 1%
const AMOUNT = ethers.parseEther("1");
const REVIEW = 3n * 24n * 60n * 60n; // 3 days
const WEEK = 7 * 24 * 60 * 60;

enum State {
  None,
  Funded,
  ProofSubmitted,
  Settled,
  Refunded,
}

describe("OviaEscrow", () => {
  async function deployFixture() {
    const [deployer, client, freelancer, treasury, rando] = await ethers.getSigners();
    const escrow = await ethers.deployContract("OviaEscrow", [FEE_BPS, treasury.address]);
    const token = await ethers.deployContract("MockERC20");
    return { escrow, token, deployer, client, freelancer, treasury, rando };
  }

  async function createEthChannel(escrow: any, client: any, freelancer: any) {
    const deadline = BigInt(await time.latest()) + BigInt(WEEK);
    await escrow
      .connect(client)
      .createChannel(freelancer.address, ethers.ZeroAddress, AMOUNT, deadline, REVIEW, {
        value: AMOUNT,
      });
    return 1n; // fresh deploy per fixture -> first channel is always id 1
  }

  const proofHash = ethers.keccak256(ethers.toUtf8Bytes("delivery-v1"));

  // -- happy path ----------------------------------------------------------

  it("settles with fee on client approval", async () => {
    const { escrow, client, freelancer, treasury } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);

    await escrow.connect(freelancer).submitProof(id, proofHash);

    const fee = (AMOUNT * FEE_BPS) / 10_000n;
    await expect(escrow.connect(client).approve(id)).to.changeEtherBalances(
      [freelancer, treasury],
      [AMOUNT - fee, fee]
    );

    expect((await escrow.getChannel(id)).state).to.equal(State.Settled);
    expect(await escrow.jobsCompleted(freelancer.address)).to.equal(1n);
    expect(await escrow.volumeSettled(freelancer.address)).to.equal(AMOUNT);
  });

  it("auto-releases after the review period, callable by anyone", async () => {
    const { escrow, client, freelancer, rando } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);
    await escrow.connect(freelancer).submitProof(id, proofHash);

    // Too early: review window still open.
    await expect(escrow.connect(rando).release(id)).to.be.revertedWithCustomError(
      escrow,
      "ReviewWindowOpen"
    );

    await time.increase(REVIEW + 1n);

    const fee = (AMOUNT * FEE_BPS) / 10_000n;
    await expect(escrow.connect(rando).release(id)).to.changeEtherBalances(
      [freelancer],
      [AMOUNT - fee]
    );
  });

  it("handles the ERC20 path correctly", async () => {
    const { escrow, token, client, freelancer, treasury } = await loadFixture(deployFixture);
    const amount = 500_000_000n; // 500 mUSD (6 decimals)

    await token.mint(client.address, amount);
    await token.connect(client).approve(await escrow.getAddress(), amount);

    const deadline = BigInt(await time.latest()) + BigInt(WEEK);
    await escrow
      .connect(client)
      .createChannel(freelancer.address, await token.getAddress(), amount, deadline, REVIEW);

    await escrow.connect(freelancer).submitProof(1n, proofHash);
    await escrow.connect(client).approve(1n);

    const fee = (amount * FEE_BPS) / 10_000n;
    expect(await token.balanceOf(freelancer.address)).to.equal(amount - fee);
    expect(await token.balanceOf(treasury.address)).to.equal(fee);
  });

  // -- reject & resolution ---------------------------------------------------

  it("returns to Funded on reject and allows resubmission past the deadline", async () => {
    const { escrow, client, freelancer } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);
    await escrow.connect(freelancer).submitProof(id, proofHash);

    await escrow.connect(client).reject(id);
    let channel = await escrow.getChannel(id);
    expect(channel.state).to.equal(State.Funded);
    expect(channel.rejections).to.equal(1n);

    // Resubmission allowed even past the original delivery deadline.
    await time.increase(30 * 24 * 60 * 60);
    const proofV2 = ethers.keccak256(ethers.toUtf8Bytes("delivery-v2"));
    await escrow.connect(freelancer).submitProof(id, proofV2);
    expect((await escrow.getChannel(id)).state).to.equal(State.ProofSubmitted);
  });

  it("blocks reject after the review window closed", async () => {
    const { escrow, client, freelancer } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);
    await escrow.connect(freelancer).submitProof(id, proofHash);

    await time.increase(REVIEW + 1n);
    await expect(escrow.connect(client).reject(id)).to.be.revertedWithCustomError(
      escrow,
      "ReviewWindowClosed"
    );
  });

  it("settles at the agreed split via mutual resolution", async () => {
    const { escrow, client, freelancer, treasury } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);
    await escrow.connect(freelancer).submitProof(id, proofHash);
    await escrow.connect(client).reject(id);

    // Freelancer proposes 60/40 in their favour; client accepts.
    await escrow.connect(freelancer).proposeResolution(id, 6000);

    const gross = (AMOUNT * 6000n) / 10_000n;
    const fee = (gross * FEE_BPS) / 10_000n;
    await expect(escrow.connect(client).acceptResolution(id)).to.changeEtherBalances(
      [freelancer, client, treasury],
      [gross - fee, AMOUNT - gross, fee]
    );

    expect((await escrow.getChannel(id)).state).to.equal(State.Settled);
  });

  it("prevents accepting your own resolution proposal", async () => {
    const { escrow, client, freelancer } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);

    await escrow.connect(client).proposeResolution(id, 0);
    await expect(escrow.connect(client).acceptResolution(id)).to.be.revertedWithCustomError(
      escrow,
      "CannotAcceptOwnResolution"
    );
  });

  // -- refunds & griefing protection -------------------------------------------

  it("refunds only after the deadline, and only if no proof was ever submitted", async () => {
    const { escrow, client, freelancer } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);

    await expect(escrow.connect(client).refundExpired(id)).to.be.revertedWithCustomError(
      escrow,
      "DeadlineNotPassed"
    );

    await time.increase(WEEK + 1);
    await expect(escrow.connect(client).refundExpired(id)).to.changeEtherBalances(
      [client],
      [AMOUNT]
    );
    expect((await escrow.getChannel(id)).state).to.equal(State.Refunded);
  });

  it("blocks unilateral refund forever once any proof exists (griefing protection)", async () => {
    const { escrow, client, freelancer } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);

    await escrow.connect(freelancer).submitProof(id, proofHash);
    await escrow.connect(client).reject(id); // back to Funded, but a proof existed

    await time.increase(60 * 24 * 60 * 60);
    await expect(escrow.connect(client).refundExpired(id)).to.be.revertedWithCustomError(
      escrow,
      "ProofWasSubmitted"
    );
  });

  // -- access control & params -------------------------------------------------

  it("enforces role-based access", async () => {
    const { escrow, client, freelancer, rando } = await loadFixture(deployFixture);
    const id = await createEthChannel(escrow, client, freelancer);

    await expect(escrow.connect(rando).submitProof(id, proofHash)).to.be.revertedWithCustomError(
      escrow,
      "NotFreelancer"
    );

    await escrow.connect(freelancer).submitProof(id, proofHash);
    await expect(escrow.connect(freelancer).approve(id)).to.be.revertedWithCustomError(
      escrow,
      "NotClient"
    );
  });

  it("validates channel parameters", async () => {
    const { escrow, client, freelancer } = await loadFixture(deployFixture);
    const deadline = BigInt(await time.latest()) + BigInt(WEEK);

    // Self-deal.
    await expect(
      escrow
        .connect(client)
        .createChannel(client.address, ethers.ZeroAddress, AMOUNT, deadline, REVIEW, {
          value: AMOUNT,
        })
    ).to.be.revertedWithCustomError(escrow, "InvalidParams");

    // msg.value mismatch.
    await expect(
      escrow
        .connect(client)
        .createChannel(freelancer.address, ethers.ZeroAddress, AMOUNT, deadline, REVIEW, {
          value: AMOUNT / 2n,
        })
    ).to.be.revertedWithCustomError(escrow, "InvalidParams");

    // Review period too short (< 1 hour).
    await expect(
      escrow
        .connect(client)
        .createChannel(freelancer.address, ethers.ZeroAddress, AMOUNT, deadline, 600, {
          value: AMOUNT,
        })
    ).to.be.revertedWithCustomError(escrow, "InvalidParams");
  });

  it("enforces the fee cap and owner-only admin", async () => {
    const { escrow, treasury, rando } = await loadFixture(deployFixture);

    await expect(
      ethers.deployContract("OviaEscrow", [501, treasury.address])
    ).to.be.revertedWithCustomError(escrow, "InvalidParams");

    await expect(
      escrow.connect(rando).setFee(50, treasury.address)
    ).to.be.revertedWithCustomError(escrow, "NotOwner");
  });
});
