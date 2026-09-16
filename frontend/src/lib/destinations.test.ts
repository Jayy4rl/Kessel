import { describe, expect, it } from "vitest";
import type { RankedPool } from "./bitflow";
import { assembleDestinations } from "./destinations";
import type { ZestSbtcMarket } from "./zest";

const pool = (poolId: string, lpFeeAprPct: number, over: Partial<RankedPool> = {}): RankedPool =>
  ({
    poolId,
    poolContract: `SM1FKX.${poolId}`,
    tokenX: "SM3VDX.sbtc-token",
    tokenY: "SP120.usdcx",
    active: true,
    tvlBtc: 5,
    feesBtc7d: 0.08,
    feesBtc30d: 0.38,
    reportedAprPct: 68,
    reportedApr24hPct: 70,
    lpFeeShare: 0.5,
    side: "x",
    lpFeeAprPct,
    lpFeeApr7dPct: lpFeeAprPct,
    volatile: false,
    reportedDivergent: false,
    ...over,
  }) as RankedPool;

// Live figures from 2026-09-15/16.
const zest: ZestSbtcMarket = {
  borrowRateBps: 1,
  utilizationBps: 1111,
  reserveFeeBps: 1000,
  supplyAprPct: 0.001,
  totalAssets: 66_012_686_180n,
  supplyCap: 500_000_000_000n,
  depositsPaused: false,
};

const state = { pools: [pool("dlmm_15", 35.3), pool("dlmm_1", 48.6)], zest, stbtcOpen: false, hbtcOpen: false };

describe("assembleDestinations", () => {
  const destinations = assembleDestinations(state);

  it("puts open venues first, by readable yield", () => {
    expect(destinations.map((d) => d.id)).toStrictEqual([
      "dlmm_1",
      "dlmm_15",
      "zest",
      "stbtc",
      "hbtc",
    ]);
  });

  it("marks closed venues unavailable and says why", () => {
    const closed = destinations.filter((d) => !d.available);
    expect(closed.map((d) => d.id)).toStrictEqual(["stbtc", "hbtc"]);
    expect(closed[0].note).toMatch(/bond allocation is full/);
    expect(closed[1].note).toMatch(/closed/);
  });

  it("warns that pool yield is fees, not BTC yield", () => {
    expect(destinations[0].note).toMatch(/converts into the pair token/);
  });

  it("surfaces the pool flags", () => {
    const [first] = assembleDestinations({
      ...state,
      pools: [pool("dlmm_6", 39.7, { volatile: true, reportedDivergent: true, reportedAprPct: 654 })],
    });
    expect(first.note).toMatch(/disagree by more than 2x/);
    expect(first.note).toMatch(/Bitflow reports 654%/);
  });

  it("marks Zest unavailable when deposits are paused", () => {
    const [, , paused] = assembleDestinations({ ...state, zest: { ...zest, depositsPaused: true } });
    expect(paused).toMatchObject({ id: "zest", available: false, note: "Deposits paused." });
  });
});
