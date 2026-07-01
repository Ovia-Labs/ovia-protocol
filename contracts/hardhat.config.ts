import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import * as dotenv from "dotenv";

dotenv.config();

const { ALCHEMY_API_KEY, PRIVATE_KEY, BASESCAN_API_KEY } = process.env;

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  paths: {
    sources: "./src",
    tests: "./test",
  },
  networks: {
    baseSepolia: {
      url: `https://base-sepolia.g.alchemy.com/v2/${ALCHEMY_API_KEY ?? ""}`,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
    base: {
      url: `https://base-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY ?? ""}`,
      accounts: PRIVATE_KEY ? [PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: {
      baseSepolia: BASESCAN_API_KEY ?? "",
      base: BASESCAN_API_KEY ?? "",
    },
    customChains: [
      {
        network: "baseSepolia",
        chainId: 84532,
        urls: {
          apiURL: "https://api-sepolia.basescan.org/api",
          browserURL: "https://sepolia.basescan.org",
        },
      },
      {
        network: "base",
        chainId: 8453,
        urls: {
          apiURL: "https://api.basescan.org/api",
          browserURL: "https://basescan.org",
        },
      },
    ],
  },
};

export default config;
