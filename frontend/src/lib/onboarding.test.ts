import { describe, expect, it } from "vitest";
import { bondTiming, deriveBond, effectiveApyPct, type RawBond } from "./bonds";
import { evaluateEligibility, type EligibilityInput } from "./eligibility";
import { latestClaim, toClaimRecords, type ActivityRecord } from "./history";
import { isFinal, mapTxStatus } from "./tx-status";

// Bond 1 as Hiro reported it on 2026-09-16.
const rawBond: RawBond = {
  index: 1,
  status: "active",
  parameters: {
    target_rate_bps: 300,
    stx_value_ratio: 310237,
    minimum_stx_ratio: 500,
    btc_capacity: "25000500000",
  },
  registrations: { allowed_count: 15, registered_count: 15 },
  schedule: {
    activation: { bitcoin_height: 966350, pox_cycle: 143 },
    unlock: { bitcoin_height: 991550, pox_cycle: 155 },
  },
  balances: { locked: { btc: "23017037628", stx: "3570465300381" }, paid_out: { btc: "0" } },
};

describe("bond overview figures", () => {
  const bond = deriveBond(rawBond);

  it("derives the headline numbers", () => {
    expect(bond.targetApyPct).toBe(3);
    expect(bond.minStxRatioPct).toBe(5);
    expect(bond.fillPct).toBeCloseTo(92.07, 1);
    expect(bond.registered).toBe(15);
  });

  it("places the bond against the current Bitcoin block", () => {
    const timing = bondTiming(bond, 967_257);
    expect(timing.phase).toBe("active");
    expect(timing.blocksRemaining).toBe(24_293);
    expect(timing.daysRemaining).toBeCloseTo(168.7, 1);
  });

  it("reports upcoming and unlocked phases", () => {
    expect(bondTiming(bond, 966_000).phase).toBe("upcoming");
    expect(bondTiming(bond, 999_999).phase).toBe("unlocked");
    expect(bondTiming(bond, 999_999).blocksRemaining).toBe(0);
  });

  it("has no effective APY until a distribution has run", () => {
    expect(effectiveApyPct(bond, 967_257)).toBeNull();
    const paying = deriveBond({
      ...rawBond,
      balances: { ...rawBond.balances, paid_out: { btc: "115085188" } },
    });
    // 0.5% of the locked BTC paid over ~6.3 days.
    expect(effectiveApyPct(paying, 967_257)).toBeCloseTo(28.97, 1);
  });
});

describe("eligibility checklist", () => {
  const passing: EligibilityInput = {
    allowanceSats: 2_500_000_000n,
    existingBondIndex: null,
    capacitySats: 25_000_500_000n,
    lockedSats: 23_017_037_628n,
    requiredUstx: 15_511_850_000n,
    availableUstx: 20_000_000_000n,
    currentBurnHeight: 966_000,
    activationHeight: 966_350,
    intendedSats: 100_000_000n,
  };

  it("passes when every condition holds", () => {
    const { checks, eligible } = evaluateEligibility(passing);
    expect(eligible).toBe(true);
    expect(checks.map((c) => c.id)).toStrictEqual([
      "allowlist",
      "stx-ratio",
      "no-position",
      "capacity",
      "window",
    ]);
  });

  it("fails an address with no allocation", () => {
    const { checks, eligible } = evaluateEligibility({ ...passing, allowanceSats: null });
    expect(eligible).toBe(false);
    expect(checks[0]).toMatchObject({ ok: false, detail: expect.stringContaining("no allocation") });
  });

  it("reports the STX shortfall", () => {
    const { checks } = evaluateEligibility({ ...passing, availableUstx: 10_000_000_000n });
    expect(checks[1].ok).toBe(false);
    expect(checks[1].detail).toMatch(/Short by 5,512 STX/);
  });

  it("blocks a principal that already holds a bond", () => {
    const { checks } = evaluateEligibility({ ...passing, existingBondIndex: 1 });
    expect(checks[2]).toMatchObject({ ok: false, detail: expect.stringContaining("bond 1") });
  });

  it("fails once capacity or the window is gone", () => {
    const full = evaluateEligibility({ ...passing, lockedSats: 25_000_500_000n });
    expect(full.checks[3].ok).toBe(false);
    const late = evaluateEligibility({ ...passing, currentBurnHeight: 966_350 });
    expect(late.checks[4]).toMatchObject({ ok: false, detail: expect.stringContaining("Closed at") });
  });
});

describe("transaction status", () => {
  it("maps Hiro's statuses", () => {
    expect(mapTxStatus("success")).toBe("success");
    expect(mapTxStatus("pending")).toBe("pending");
    expect(mapTxStatus("abort_by_response")).toBe("failed");
    expect(mapTxStatus("abort_by_post_condition")).toBe("failed");
    expect(mapTxStatus("something_else")).toBe("unknown");
  });

  it("knows which states stop the polling", () => {
    expect([isFinal("success"), isFinal("failed")]).toStrictEqual([true, true]);
    expect([isFinal("pending"), isFinal("unknown")]).toStrictEqual([false, false]);
  });
});

describe("activity history", () => {
  const activity: ActivityRecord[] = [
    {
      kind: "deploy",
      txId: "0xdeploy",
      timestamp: "2026-09-16T10:05:00.000Z",
      amountSats: "5000",
      destination: "dlmm_1",
      claimTxId: "0xclaim",
    },
    {
      kind: "claim",
      txId: "0xclaim",
      timestamp: "2026-09-16T10:00:00.000Z",
      amountSats: "5000",
      bondIndex: 1,
      rewardCycle: 143,
    },
  ];

  it("finds the claim a deployment would follow", () => {
    expect(latestClaim(activity)?.txId).toBe("0xclaim");
    expect(latestClaim([activity[0]])).toBeNull();
  });

  it("maps to the PRD claim record, pairing each claim with its deployment", () => {
    expect(toClaimRecords(activity)).toStrictEqual([
      {
        timestamp: "2026-09-16T10:00:00.000Z",
        bond_index: 1,
        amount_sats: "5000",
        tx_id: "0xclaim",
        deployed_to: "dlmm_1",
        deployed_amount_sats: "5000",
        deploy_tx_id: "0xdeploy",
      },
    ]);
  });

  it("leaves deployment fields null for a claim that was not deployed", () => {
    const [record] = toClaimRecords([activity[1]]);
    expect(record).toMatchObject({ deployed_to: null, deploy_tx_id: null });
  });
});
