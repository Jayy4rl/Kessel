// Mainnet contracts and APIs the claim-then-deposit flow talks to. Each was
// verified against deployed source or a live API response on 2026-09-15.

export const SBTC_TOKEN = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
export const SBTC_ASSET_NAME = "sbtc-token";

export const BITFLOW_APP_API = "https://bff.bitflowapis.finance/api/app/v1";
export const BITFLOW_QUOTES_API = "https://bff.bitflowapis.finance/api/quotes/v1";

// Pulls tokens from `tx-sender` and mints LP tokens to it (dlmm-core-v-1-1).
export const HODLMM_LIQUIDITY_ROUTER =
  "SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-liquidity-router-v-1-2";

// Zest v2. The v1 market under SP2VCQJ… (`pool-0-reserve-v2-0`) is legacy.
export const ZEST_SBTC_VAULT = "SP1A27KFY4XERQCCRCARCYD1CC5N7M6688BSYADJ7.v0-vault-sbtc";

export const STBTC_CORE = "SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.stacking-dao-core-stbtc-v1";

export const HBTC_VAULT = "SP1S1HSFH0SQQGWKB69EYFNY0B1MHRMGXR3J1FH4D.vault-hbtc-v1-2";
export const HBTC_STATE = "SP1S1HSFH0SQQGWKB69EYFNY0B1MHRMGXR3J1FH4D.state-hbtc-v1";
