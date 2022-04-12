const { parseEther } = require("ethers/lib/utils");

require("dotenv").config();
require("@nomiclabs/hardhat-waffle");
require("hardhat-gas-reporter");
require("@nomiclabs/hardhat-etherscan");

/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  networks: {
    hardhat: {
      forking: {
        url: process.env.BNB_URL,
        blockNumber: 14250342, // use this only with archival node
        enabled: true
      },
      // accounts: [{privateKey: process.env.PRIVATE_KEY, balance: parseEther("10000").toString()}],
    },
    bnb: {
      url: process.env.BNB_URL,
      accounts: process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
  },
  mocha: {
    // bail: true,
    timeout: 600000
  },
  etherscan: {
    apiKey: {
      bsc: process.env.BSCSCAN_API_KEY
    }
  },
  solidity: {
    compilers: [
      {
        version: "0.8.4",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          evmVersion: "istanbul",
          outputSelection: {
            "*": {
              "": ["ast"],
              "*": [
                "evm.bytecode.object",
                "evm.deployedBytecode.object",
                "abi",
                "evm.bytecode.sourceMap",
                "evm.deployedBytecode.sourceMap",
                "metadata",
              ],
            },
          },
        },
      },
    ]
  },
};
