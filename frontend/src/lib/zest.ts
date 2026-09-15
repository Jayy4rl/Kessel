import { Cl, type TupleCV } from "@stacks/transactions";
import { ZEST_SBTC_VAULT } from "./config";
import { readOnly, sbtcSentExactly, toBigInt, toBool, unwrapOk, type ContractCall } from "./tx";

const BPS = 10_000;

export interface ZestSbtcMarket {
  borrowRateBps: number;
  utilizationBps: number;
  reserveFeeBps: number;
  /** Base lending yield, excluding incentive programs. */
  supplyAprPct: number;
  totalAssets: bigint;
  supplyCap: bigint;
  depositsPaused: boolean;
}

/**
 * Lenders earn the borrow rate on the utilised share of the vault, less the
 * reserve fee. The vault keeps rates in basis points per year
 * (`SECONDS-PER-YEAR-BPS` in v0-vault-sbtc).
 */
export function zestSupplyAprPct(borrowRateBps: number, utilizationBps: number, reserveFeeBps: number) {
  return (borrowRateBps / 100) * (utilizationBps / BPS) * (1 - reserveFeeBps / BPS);
}

export async function fetchZestSbtcMarket(): Promise<ZestSbtcMarket> {
  const read = (fn: string) => readOnly(ZEST_SBTC_VAULT, fn).then(unwrapOk);
  const [rate, utilization, fee, assets, cap, pauses] = await Promise.all([
    read("get-interest-rate"),
    read("get-utilization"),
    read("get-fee-reserve"),
    read("get-total-assets"),
    read("get-cap-supply"),
    read("get-pause-states"),
  ]);
  const borrowRateBps = Number(toBigInt(rate));
  const utilizationBps = Number(toBigInt(utilization));
  const reserveFeeBps = Number(toBigInt(fee));
  return {
    borrowRateBps,
    utilizationBps,
    reserveFeeBps,
    supplyAprPct: zestSupplyAprPct(borrowRateBps, utilizationBps, reserveFeeBps),
    totalAssets: toBigInt(assets),
    supplyCap: toBigInt(cap),
    depositsPaused: toBool((pauses as TupleCV).value.deposit),
  };
}

/** zsBTC shares `amount` sats would mint now; use it to set `minShares`. */
export async function fetchZestSharesFor(amount: bigint): Promise<bigint> {
  return toBigInt(unwrapOk(await readOnly(ZEST_SBTC_VAULT, "convert-to-shares", [Cl.uint(amount)])));
}

/**
 * Supply sBTC to Zest v2. The vault debits `contract-caller`, so this must be
 * signed and sent by the depositor's wallet directly.
 */
export function buildZestSbtcSupply({
  amount,
  minShares,
  sender,
}: {
  amount: bigint;
  minShares: bigint;
  sender: string;
}): ContractCall {
  return {
    contract: ZEST_SBTC_VAULT,
    functionName: "deposit",
    functionArgs: [Cl.uint(amount), Cl.uint(minShares), Cl.principal(sender)],
    postConditions: [sbtcSentExactly(sender, amount)],
    postConditionMode: "deny",
  };
}
