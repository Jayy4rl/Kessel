import {
  Cl,
  ClarityType,
  cvToString,
  type ClarityValue,
  type ListCV,
  type ResponseOkCV,
  type TupleCV,
  type UIntCV,
} from "@stacks/transactions";
import { beforeAll, describe, expect, it } from "vitest";

// Claim-then-deposit venues, called from the wallet exactly as
// frontend/src/lib builds them, against mainnet state at FORK_HEIGHT.
const FORK_HEIGHT = 8_995_000;

const FUNDER = "SP8YMPEBK0P9W3SYCAEB1M1XJFEJTP08RWG4G16E";
const STAKER = "SP1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2XG1V316";

const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const USDCX = "SP120SBRBQJ00MCWS7TM5R8WJNTTKD5K0HFRC2CNE.usdcx";
const HODLMM_ROUTER = "SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-liquidity-router-v-1-2";
const SBTC_USDCX_POOL = "SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD.dlmm-pool-sbtc-usdcx-v-1-bps-10";
const ZEST_SBTC_VAULT = "SP1A27KFY4XERQCCRCARCYD1CC5N7M6688BSYADJ7.v0-vault-sbtc";
const HBTC_VAULT = "SP1S1HSFH0SQQGWKB69EYFNY0B1MHRMGXR3J1FH4D.vault-hbtc-v1-2";

const CENTER_BIN_ID = 500;
const DEADLINE = 4_102_444_800; // 2100-01-01

function okValue(result: ClarityValue): ClarityValue {
  if (result.type !== ClarityType.ResponseOk) {
    throw new Error(`expected (ok ...), got ${cvToString(result)}`);
  }
  return (result as ResponseOkCV).value;
}

const read = (contract: string, fn: string, args: ClarityValue[] = []) =>
  simnet.callReadOnlyFn(contract, fn, args, STAKER).result;

const sbtcBalance = (who: string) =>
  BigInt((okValue(read(SBTC, "get-balance", [Cl.principal(who)])) as UIntCV).value);

// Mirrors buildHodlmmSbtcDeposit in frontend/src/lib/bitflow.ts.
const sbtcOnlyPosition = (binId: number, amount: number) =>
  Cl.tuple({
    "pool-trait": Cl.principal(SBTC_USDCX_POOL),
    "x-token-trait": Cl.principal(SBTC),
    "y-token-trait": Cl.principal(USDCX),
    "bin-id": Cl.int(binId),
    "x-amount": Cl.uint(amount),
    "y-amount": Cl.uint(0),
    "min-dlp": Cl.uint(1),
    "max-x-liquidity-fee": Cl.uint(0),
    "max-y-liquidity-fee": Cl.uint(0),
  });

const addLiquidity = (positions: ClarityValue[]) =>
  simnet.callPublicFn(
    HODLMM_ROUTER,
    "add-liquidity-multi",
    [Cl.list(positions), Cl.some(Cl.uint(DEADLINE))],
    STAKER,
  ).result;

beforeAll(async () => {
  await simnet.initEmptySession({
    enabled: true,
    api_url: "https://api.hiro.so",
    initial_height: FORK_HEIGHT,
  });
  const { result } = simnet.callPublicFn(
    SBTC,
    "transfer",
    [Cl.uint(200_000), Cl.principal(FUNDER), Cl.principal(STAKER), Cl.none()],
    FUNDER,
  );
  expect(result).toBeOk(Cl.bool(true));
});

describe("Bitflow HODLMM sBTC-only deposit", () => {
  let activeBinId: number;
  let binsAbove: number[];

  beforeAll(() => {
    activeBinId = Number((okValue(read(SBTC_USDCX_POOL, "get-active-bin-id")) as UIntCV).value);
    // The nearest bins above the active bin that already hold sBTC.
    binsAbove = [];
    for (let offset = 1; binsAbove.length < 3 && offset <= 50; offset++) {
      const bin = okValue(
        read(SBTC_USDCX_POOL, "get-bin-balances", [Cl.uint(activeBinId + offset + CENTER_BIN_ID)]),
      ) as TupleCV;
      if (BigInt((bin.value["x-balance"] as UIntCV).value) > 0n) binsAbove.push(activeBinId + offset);
    }
    expect(binsAbove).toHaveLength(3);
  });

  it("adds sBTC above the active bin and spends exactly the deposit", () => {
    const before = sbtcBalance(STAKER);

    const minted = okValue(addLiquidity(binsAbove.map((bin) => sbtcOnlyPosition(bin, 10_000)))) as ListCV;

    expect(minted.value).toHaveLength(3);
    for (const dlp of minted.value) expect(BigInt((dlp as UIntCV).value)).toBeGreaterThan(0n);
    expect(sbtcBalance(STAKER)).toBe(before - 30_000n);
  });

  it("reverts sBTC-only liquidity below the active bin", () => {
    expect(addLiquidity([sbtcOnlyPosition(activeBinId - 1, 10_000)]).type).toBe(ClarityType.ResponseErr);
  });

  it("reverts sBTC-only liquidity in the active bin when the fee cap is zero", () => {
    expect(addLiquidity([sbtcOnlyPosition(activeBinId, 10_000)]).type).toBe(ClarityType.ResponseErr);
  });
});

describe("Zest v2 sBTC supply", () => {
  it("accepts a deposit sent from the wallet and mints zsBTC to it", () => {
    const before = sbtcBalance(STAKER);

    const { result } = simnet.callPublicFn(
      ZEST_SBTC_VAULT,
      "deposit",
      [Cl.uint(10_000), Cl.uint(1), Cl.principal(STAKER)],
      STAKER,
    );

    expect(BigInt((okValue(result) as UIntCV).value)).toBeGreaterThan(0n);
    expect(sbtcBalance(STAKER)).toBe(before - 10_000n);
    expect(
      BigInt((okValue(read(ZEST_SBTC_VAULT, "get-balance", [Cl.principal(STAKER)])) as UIntCV).value),
    ).toBeGreaterThan(0n);
  });
});

describe("Hermetica hBTC deposit", () => {
  it("is closed at FORK_HEIGHT (deposit window disabled)", () => {
    const ERR_DEPOSIT_DISABLED = 102005;
    const { result } = simnet.callPublicFn(
      HBTC_VAULT,
      "deposit",
      [Cl.uint(10_000), Cl.none()],
      STAKER,
    );
    expect(result).toBeErr(Cl.uint(ERR_DEPOSIT_DISABLED));
  });
});
