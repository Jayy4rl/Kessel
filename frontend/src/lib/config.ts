// Deployed 2026-09-03. See ../../../contracts and the root README.
export const CHAIN_ID = 84532;
export const RPC_URL = "https://sepolia.base.org";
export const EXPLORER = "https://sepolia.basescan.org";

export const ADDRESSES = {
  hook: "0x813E0c51907e09E0e447475947a819D0c66d00C8",
  batchSolver: "0x25048aB11E111a43D5cfebEE567b3F1BA48BCF81",
  currency0: "0x56b7936a7f0C71FC95b302271123F2cC5AF70596",
  currency1: "0x750feAb85382bA28B45cd54443146E53D40a529A",
  poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
  // v4 requires every pool interaction to come through a contract that holds
  // the singleton's lock. These are the test routers deployed alongside.
  swapRouter: "0xa5C0faa78B965d61A62DBb61DDdF5DF076617A2e",
  lpRouter: "0xce6A7D17ccC39013B764CAd2cb84dc617C5104f5",
} as const;

export const POOL_ID =
  "0x5c38804e9f39fa6324ba32dce4d68315d5fd204333294e92c19ee29a0af16f28";

/// Measured on-chain, same 0.01 input through each lane. See the README.
export const MEASURED = { fastOut: 9_969_006_090_092_817n, slowOut: 9_991_809_485_447_428n };
