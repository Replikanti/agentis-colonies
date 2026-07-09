// Offline hardhat-poc fixture config (#1507). Deliberately minimal — only @nomicfoundation/hardhat-ethers (not
// the full hardhat-toolbox, whose peer-dep graph is huge) so `npm install --legacy-peer-deps` resolves quickly.
// The full install + npx hardhat test path runs ONLY when the toolchain is present (the LIVE demo part); CI
// exercises detect-toolchain + the #1471 linkage gate + the --classify verdict parse against this tree with NO
// node. The solc version matches the fixture contracts.
require("@nomicfoundation/hardhat-ethers");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.20",
};
