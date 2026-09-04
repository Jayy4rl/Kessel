// Deployed 2026-09-03. See ../../../contracts and the root README.
export const CHAIN_ID = 84532;
/// Public endpoints, tried in order. The first has been unreliable in
/// practice -- returning HTTP 500 on perfectly valid calls -- and a single
/// endpoint means one flaky host looks like a broken app.
export const RPC_URLS = [
  "https://sepolia.base.org",
  "https://base-sepolia-rpc.publicnode.com",
  "https://base-sepolia.drpc.org",
] as const;

export const RPC_URL = RPC_URLS[0];
export const EXPLORER = "https://sepolia.basescan.org";

export const ADDRESSES = {
  hook: "0xD9b438e017D37bE8C3205f3814241b8D9F9d80c8",
  batchSolver: "0x25048aB11E111a43D5cfebEE567b3F1BA48BCF81",
  currency0: "0xb94817ebA9282307Fb7b1351051f9a5A7Fc483Cf",
  currency1: "0xeB8Aa36077cac1C6B5Bed16A2A1e52778e54eD4F",
  poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
  // v4 requires every pool interaction to come through a contract that holds
  // the singleton's lock. These are the test routers deployed alongside.
  swapRouter: "0xff870819bC7Cd14dEFbd32CdD076AcEfF6521D9e",
  lpRouter: "0x7CD076795953e44456dD3E8569e43C34f96Bdb09",
} as const;

export const POOL_ID =
  "0x9be8cc8e62ffa0921506a9e4ac87fa0b7f84aede541b824d9da2abd6e3496168";

/// Measured on-chain, same 0.01 input through each lane. See the README.
export const MEASURED = { fastOut: 9_969_801_202_164_028n, slowOut: 9_994_361_770_855_610n };
