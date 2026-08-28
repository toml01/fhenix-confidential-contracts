/* eslint-disable @typescript-eslint/no-unused-vars */
import * as dotenv from "dotenv";
dotenv.config();

// fhec ships no npm package yet, so the plugin cannot find the native binary on
// its own from outside the fhec checkout. Point it at a local build. Override
// with FHEC_BINARY_PATH in .env to use a different one.
// See FHEC-FINDINGS.md, "cannot be installed outside the fhec monorepo".
import * as os from "os";
import * as path from "path";
process.env.FHEC_BINARY_PATH ??= path.join(os.homedir(), "dev/fhec/target/release/fhec");

import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-ethers";
import "@nomicfoundation/hardhat-chai-matchers";
import "@typechain/hardhat";
import "hardhat-gas-reporter";
import "solidity-coverage";
import "@nomicfoundation/hardhat-verify";
import "hardhat-deploy";
import "hardhat-deploy-ethers";
import "@cofhe/hardhat-plugin";
// Transpiles .fsol -> generated/ before compile, and remaps solc errors back to
// the .fsol source. It also repoints `paths.sources` at `generated/`, which is
// why every fully-qualified contract name below carries that prefix.
import "@fhec/hardhat-plugin";

// If not set, it uses ours Alchemy's default API key.
// You can get your own at https://dashboard.alchemyapi.io
const providerApiKey = process.env.ALCHEMY_API_KEY || "oKxs-03sij-U_N0iOlrSsZFr29-IqbuF";
// If not set, it uses the hardhat account 0 private key.
// You can generate a random account with `yarn generate` or `yarn account:import` to import your existing PK
const deployerPrivateKey =
  process.env.__RUNTIME_DEPLOYER_PRIVATE_KEY ?? "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
// If not set, it uses our block explorers default API keys.
const etherscanApiKey = process.env.ETHERSCAN_MAINNET_API_KEY || "DNXJA8RX2Q3VZ4URQIWP7Z68CJXQZSC6AW";
const etherscanOptimisticApiKey = process.env.ETHERSCAN_OPTIMISTIC_API_KEY || "RM62RDISS1RH448ZY379NX625ASG1N633R";
const basescanApiKey = process.env.BASESCAN_API_KEY || "ZZZEIPMT1MNJ8526VV2Y744CA7TNZR64G6";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.25",
        settings: {
          evmVersion: "cancun",
          optimizer: {
            enabled: true,
            // https://docs.soliditylang.org/en/latest/using-the-compiler.html#optimizer-options
            runs: 200,
          },
        },
      },
      {
        // Only for the pinned ERC20ConfidentialLib compile job below.
        version: "0.8.26",
        settings: {
          evmVersion: "cancun",
          optimizer: {
            enabled: true,
            runs: 1,
          },
        },
      },
    ],
    overrides: {
      // ERC20ConfidentialLib is deployed ONCE PER CHAIN and linked by address into every
      // consumer, so the artifact must be reproducible: same source + these settings must
      // always yield the same bytecode, for explorer verification and for consumers checking
      // what they linked against.
      //
      // NOTE: the cofhe 0.7 migration changed this library's ABI (InEuint64 became
      // externalEuint64 + a separate proof), and the sharedEuintXX migration changed it again
      // (the confidential values crossing the boundary became sharedEuint64, and inputProof
      // moved ahead of `bytes data` on the *AndCall variants). So this build is NOT
      // interchangeable with library instances deployed before 0.7 — it is a new deployment,
      // and every host must be relinked against it. Note that neither change moved a single
      // selector, so a stale link fails at runtime rather than at link time. The 0.8.26 /
      // runs:1 / cancun pin is retained so that this version is itself reproducible. Consumers
      // link by address, so their own bytecode is unaffected by these settings.
      // NOTE: `generated/`, not `contracts/` — @fhec/hardhat-plugin repoints
      // `paths.sources` at the transpiler output, which renames every source.
      "generated/ERC20Confidential/ERC20ConfidentialLib.sol": {
        version: "0.8.26",
        settings: { evmVersion: "cancun", optimizer: { enabled: true, runs: 1 } },
      },
    },
  },
  defaultNetwork: "localhost",
  namedAccounts: {
    deployer: {
      // By default, it will take the first Hardhat account as the deployer
      default: 0,
    },
  },
  networks: {
    // View the networks that are pre-configured.
    // If the network you are looking for is not here you can add new network settings
    hardhat: {
      forking: {
        url: `https://eth-mainnet.alchemyapi.io/v2/${providerApiKey}`,
        enabled: process.env.MAINNET_FORKING_ENABLED === "true",
      },
      mining: {
        auto: true,
        interval: [3000, 4000], // optional: simulate block time range
      },
    },
    mainnet: {
      url: `https://eth-mainnet.alchemyapi.io/v2/${providerApiKey}`,
      accounts: [deployerPrivateKey],
    },
    sepolia: {
      url: `https://eth-sepolia.g.alchemy.com/v2/${providerApiKey}`,
      accounts: [deployerPrivateKey],
    },
    arbitrum: {
      url: `https://arb-mainnet.g.alchemy.com/v2/${providerApiKey}`,
      accounts: [deployerPrivateKey],
    },
    arbitrumSepolia: {
      url: `https://arb-sepolia.g.alchemy.com/v2/${providerApiKey}`,
      accounts: [deployerPrivateKey],
    },
  },
  // configuration for harhdat-verify plugin
  etherscan: {
    apiKey: `${etherscanApiKey}`,
  },
  // configuration for etherscan-verify from hardhat-deploy plugin
  verify: {
    etherscan: {
      apiKey: `${etherscanApiKey}`,
    },
  },
  sourcify: {
    enabled: false,
  },
};

export default config;
