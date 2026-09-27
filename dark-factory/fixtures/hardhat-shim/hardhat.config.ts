// Foundry-shim fixture (#2277): a Hardhat-only project root. Parsed statically by lib/foundry_shim.py, never executed.
import { HardhatUserConfig } from "hardhat/config";

const config: HardhatUserConfig = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
  },
};

export default config;
