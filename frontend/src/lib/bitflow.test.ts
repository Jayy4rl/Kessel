import { Cl } from "@stacks/transactions";
import { describe, expect, it } from "vitest";
import {
  buildHodlmmSbtcDeposit,
  parsePool,
  rankSbtcPools,
  selectSbtcBins,
  type PoolBins,
} from "./bitflow";
import { HODLMM_LIQUIDITY_ROUTER, SBTC_TOKEN } from "./config";

const USDCX = "SP120SBRBQJ00MCWS7TM5R8WJNTTKD5K0HFRC2CNE.usdcx";
const STX = "SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.token-stx-v-1-2";
const POOLS = "SM1FKXGNZJWSTWDWXQZJNF7B5TV5ZB235JTCXYXKD";
const SENDER = "SP1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2XG1V316";

function pool(
  poolId: string,
  x: string,
  y: string,
  [tvlBtc, feesBtc7d, feesBtc30d, apr, apr24h]: [number, number, number, number, number],
) {
  return parsePool({
    poolId,
    poolContract: `${POOLS}.${poolId}`,
    poolStatus: true,
    tokens: { tokenX: { contract: x }, tokenY: { contract: y } },
    tvlBtc,
    feesBtc7d,
    feesBtc30d,
    apr,
    apr24h,
    xProtocolFee: 25,
    xProviderFee: 25,
    xVariableFee: 0,
  });
}

// Two snapshots of Bitflow's app API taken hours apart on 2026-09-15:
// [tvlBtc, feesBtc7d, feesBtc30d, apr, apr24h].
const morning = {
  sbtcUsdcx: pool("dlmm_1", SBTC_TOKEN, USDCX, [4.75, 0.08183, 0.37952, 68.43, 77.43]),
  stxSbtc: pool("dlmm_15", STX, SBTC_TOKEN, [5.28, 0.0746, 0.29772, 73.66, 32.3]),
  thinStxSbtc: pool("dlmm_6", STX, SBTC_TOKEN, [0.89, 0.11219, 0.18001, 200.87, 234.32]),
  dust: pool("dlmm_2", SBTC_TOKEN, USDCX, [0.0008, 0, 0.00006, 0, 0]),
  noSbtc: pool("dlmm_5", STX, USDCX, [10, 0.1, 0.5, 40, 40]),
};
const afternoon = {
  // TVL fell from 4.75 to 0.99 BTC; Bitflow's APR jumped from 68% to 440%.
  sbtcUsdcx: pool("dlmm_1", SBTC_TOKEN, USDCX, [0.98883, 0.08361, 0.38417, 439.65, 504.81]),
  stxSbtc: pool("dlmm_6", STX, SBTC_TOKEN, [2.81685, 0.11533, 0.18365, 654.51, 779.49]),
};
const { sbtcUsdcx, stxSbtc, noSbtc } = morning;

describe("rankSbtcPools", () => {
  const ranked = rankSbtcPools(Object.values(morning));

  it("keeps active sBTC pools above the TVL floor, best 30-day LP fee yield first", () => {
    expect(ranked.map((p) => p.poolId)).toStrictEqual(["dlmm_1", "dlmm_15"]);
  });

  it("annualises trailing fees and counts only the LP share", () => {
    expect(ranked[0].lpFeeAprPct).toBeCloseTo(48.6, 1);
    expect(ranked[0].lpFeeApr7dPct).toBeCloseTo(44.9, 1);
    expect(ranked[1].lpFeeAprPct).toBeCloseTo(34.3, 1);
  });

  it("records which side of the pair sBTC is on", () => {
    expect(ranked.map((p) => p.side)).toStrictEqual(["x", "y"]);
  });

  it("flags only the figures that disagree", () => {
    // dlmm_15: Bitflow reported 73.7% against a trailing 34.3%.
    expect(ranked.map((p) => [p.volatile, p.reportedDivergent])).toStrictEqual([
      [false, false],
      [false, true],
    ]);
  });

  it("drops a pool whose TVL falls below the floor", () => {
    expect(rankSbtcPools(Object.values(afternoon)).map((p) => p.poolId)).toStrictEqual(["dlmm_6"]);
  });

  it("flags diverging 7-day vs 30-day fees and an outlying reported APR", () => {
    const [thin] = rankSbtcPools([afternoon.stxSbtc]);
    expect(thin.lpFeeAprPct).toBeCloseTo(39.7, 1);
    expect(thin.lpFeeApr7dPct).toBeCloseTo(106.7, 1);
    expect(thin.volatile).toBe(true);
    expect(thin.reportedDivergent).toBe(true);
  });

  it("can lower the TVL floor", () => {
    expect(rankSbtcPools([morning.thinStxSbtc], { minTvlBtc: 0.5 })).toHaveLength(1);
  });

  it("ignores inactive pools", () => {
    expect(rankSbtcPools([{ ...sbtcUsdcx, active: false }])).toHaveLength(0);
  });
});

describe("selectSbtcBins", () => {
  const bins: PoolBins = {
    activeBinId: 637,
    bins: [
      { binId: 634, reserveX: 0n, reserveY: 0n },
      { binId: 635, reserveX: 0n, reserveY: 900n },
      { binId: 636, reserveX: 0n, reserveY: 500n },
      { binId: 637, reserveX: 800n, reserveY: 300n },
      { binId: 638, reserveX: 400n, reserveY: 0n },
      { binId: 639, reserveX: 0n, reserveY: 0n },
      { binId: 640, reserveX: 700n, reserveY: 0n },
      { binId: 641, reserveX: 100n, reserveY: 0n },
    ],
  };

  it("picks occupied bins above the active bin when sBTC is token X", () => {
    expect(selectSbtcBins(bins, "x", 2)).toStrictEqual([638, 640]);
  });

  it("picks occupied bins below the active bin when sBTC is token Y", () => {
    expect(selectSbtcBins(bins, "y", 5)).toStrictEqual([636, 635]);
  });

  it("never selects the active bin", () => {
    expect(selectSbtcBins(bins, "x", 10)).not.toContain(637);
    expect(selectSbtcBins(bins, "y", 10)).not.toContain(637);
  });
});

describe("buildHodlmmSbtcDeposit", () => {
  const position = (poolContract: string, x: string, y: string, binId: number, xAmount: number, yAmount: number) =>
    Cl.tuple({
      "pool-trait": Cl.principal(poolContract),
      "x-token-trait": Cl.principal(x),
      "y-token-trait": Cl.principal(y),
      "bin-id": Cl.int(binId),
      "x-amount": Cl.uint(xAmount),
      "y-amount": Cl.uint(yAmount),
      "min-dlp": Cl.uint(1),
      "max-x-liquidity-fee": Cl.uint(0),
      "max-y-liquidity-fee": Cl.uint(0),
    });

  it("spreads sBTC as token X over bins above the active bin", () => {
    const call = buildHodlmmSbtcDeposit({
      pool: sbtcUsdcx,
      binIds: [638, 640],
      amount: 1001n,
      sender: SENDER,
      deadline: 1_800_000_000,
    });

    expect(call.contract).toBe(HODLMM_LIQUIDITY_ROUTER);
    expect(call.functionName).toBe("add-liquidity-multi");
    expect(call.functionArgs).toStrictEqual([
      Cl.list([
        position(sbtcUsdcx.poolContract, SBTC_TOKEN, USDCX, 138, 501, 0),
        position(sbtcUsdcx.poolContract, SBTC_TOKEN, USDCX, 140, 500, 0),
      ]),
      Cl.some(Cl.uint(1_800_000_000)),
    ]);
  });

  it("deposits sBTC as token Y when it is the second token", () => {
    const call = buildHodlmmSbtcDeposit({
      pool: stxSbtc,
      binIds: [861],
      amount: 5000n,
      sender: SENDER,
      deadline: 1_800_000_000,
    });

    expect(call.functionArgs[0]).toStrictEqual(
      Cl.list([position(stxSbtc.poolContract, STX, SBTC_TOKEN, 361, 0, 5000)]),
    );
  });

  it("requires the wallet to send exactly the deposit, in deny mode", () => {
    const call = buildHodlmmSbtcDeposit({
      pool: sbtcUsdcx,
      binIds: [638, 640],
      amount: 1001n,
      sender: SENDER,
      deadline: 1_800_000_000,
    });

    expect(call.postConditionMode).toBe("deny");
    expect(call.postConditions).toMatchObject([
      { address: SENDER, condition: "eq", amount: "1001", asset: `${SBTC_TOKEN}::sbtc-token` },
    ]);
  });

  it("rejects a deposit that cannot cover every bin, or has no bins", () => {
    const base = { pool: sbtcUsdcx, sender: SENDER, deadline: 1 };
    expect(() => buildHodlmmSbtcDeposit({ ...base, binIds: [638, 640], amount: 1n })).toThrow();
    expect(() => buildHodlmmSbtcDeposit({ ...base, binIds: [], amount: 100n })).toThrow();
  });

  it("rejects a pool without sBTC", () => {
    expect(() =>
      buildHodlmmSbtcDeposit({ pool: noSbtc, binIds: [1], amount: 100n, sender: SENDER, deadline: 1 }),
    ).toThrow();
  });
});
