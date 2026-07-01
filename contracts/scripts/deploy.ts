import { ethers, network } from "hardhat";

/**
 * Deploys OviaEscrow.
 *
 * Env vars:
 *   FEE_BPS        protocol fee in basis points (default: 100 = 1%, hard cap 500)
 *   FEE_RECIPIENT  address receiving protocol fees (defaults to the deployer)
 */
async function main() {
  const [deployer] = await ethers.getSigners();

  const feeBps = BigInt(process.env.FEE_BPS ?? "100");
  const feeRecipient = process.env.FEE_RECIPIENT ?? deployer.address;

  console.log(`Network:       ${network.name}`);
  console.log(`Deployer:      ${deployer.address}`);
  console.log(`Fee:           ${feeBps} bps -> ${feeRecipient}`);

  const escrow = await ethers.deployContract("OviaEscrow", [feeBps, feeRecipient]);
  await escrow.waitForDeployment();

  const address = await escrow.getAddress();
  console.log(`\nOviaEscrow deployed at: ${address}`);
  console.log(
    `\nVerify with:\n  npx hardhat verify --network ${network.name} ${address} ${feeBps} ${feeRecipient}`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
