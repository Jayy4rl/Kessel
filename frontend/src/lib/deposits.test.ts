import { Cl } from "@stacks/transactions";
import { describe, expect, it } from "vitest";
import { HBTC_VAULT, SBTC_TOKEN, STBTC_CORE, ZEST_SBTC_VAULT } from "./config";
import { buildHbtcDeposit } from "./hermetica";
import { buildClaimStakerRewards } from "./staking";
import { buildStbtcDeposit } from "./stackingdao";
import { buildZestSbtcSupply, zestSupplyAprPct } from "./zest";

const SENDER = "SP1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2XG1V316";
const MANAGER = "SP8HK160YD5GHXP69VGA0TC7AQJ1X4CDW3XVERSE.xverse-signer-manager-2";
const SBTC_ASSET = `${SBTC_TOKEN}::sbtc-token`;

const exactSbtcOut = (amount: string) => [
  { address: SENDER, condition: "eq", amount, asset: SBTC_ASSET },
];

describe("buildClaimStakerRewards", () => {
  const call = buildClaimStakerRewards({
    signerManager: MANAGER,
    staker: SENDER,
    rewardCycle: 144,
    bondIndex: 1,
    minAmount: 5000n,
  });

  it("calls the manager's staker claim for one bond leg", () => {
    expect(call.contract).toBe(MANAGER);
    expect(call.functionName).toBe("claim-staker-rewards");
    expect(call.functionArgs).toStrictEqual([Cl.principal(SENDER), Cl.uint(144), Cl.some(Cl.uint(1))]);
  });

  it("requires the manager to pay at least the expected claim, in deny mode", () => {
    expect(call.postConditionMode).toBe("deny");
    expect(call.postConditions).toMatchObject([
      { address: MANAGER, condition: "gte", amount: "5000", asset: SBTC_ASSET },
    ]);
  });
});

describe("Zest v2 sBTC supply", () => {
  it("computes base lending yield from the vault's basis-point rates", () => {
    // Live on 2026-09-15: 1 bps borrow rate, 11.11% utilisation, 10% reserve fee.
    expect(zestSupplyAprPct(1, 1111, 1000)).toBeCloseTo(0.001, 4);
    expect(zestSupplyAprPct(500, 8000, 1000)).toBeCloseTo(3.6, 6);
  });

  it("deposits to the vault with a share floor, crediting the sender", () => {
    const call = buildZestSbtcSupply({ amount: 10_000n, minShares: 9_900n, sender: SENDER });

    expect(call.contract).toBe(ZEST_SBTC_VAULT);
    expect(call.functionName).toBe("deposit");
    expect(call.functionArgs).toStrictEqual([Cl.uint(10_000), Cl.uint(9_900), Cl.principal(SENDER)]);
    expect(call.postConditionMode).toBe("deny");
    expect(call.postConditions).toMatchObject(exactSbtcOut("10000"));
  });
});

describe("StackingDAO stBTC deposit", () => {
  it("passes the amount and share floor", () => {
    const call = buildStbtcDeposit({ amount: 10_000n, minShares: 9_980n, sender: SENDER });

    expect(call.contract).toBe(STBTC_CORE);
    expect(call.functionName).toBe("deposit");
    expect(call.functionArgs).toStrictEqual([Cl.uint(10_000), Cl.uint(9_980)]);
    expect(call.postConditions).toMatchObject(exactSbtcOut("10000"));
  });
});

describe("Hermetica hBTC deposit", () => {
  it("passes the amount with no affiliate", () => {
    const call = buildHbtcDeposit({ amount: 10_000n, sender: SENDER });

    expect(call.contract).toBe(HBTC_VAULT);
    expect(call.functionName).toBe("deposit");
    expect(call.functionArgs).toStrictEqual([Cl.uint(10_000), Cl.none()]);
    expect(call.postConditions).toMatchObject(exactSbtcOut("10000"));
  });
});
