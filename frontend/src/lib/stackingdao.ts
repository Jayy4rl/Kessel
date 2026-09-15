import { Cl } from "@stacks/transactions";
import { STBTC_CORE } from "./config";
import { readOnly, sbtcSentExactly, toBool, type ContractCall } from "./tx";

/**
 * stBTC wraps StackingDAO's own Bitcoin Staking bond position, so deposits
 * close when that bond allocation is full (as on 2026-09-15).
 */
export async function fetchStbtcDepositsOpen(): Promise<boolean> {
  return !toBool(await readOnly(STBTC_CORE, "get-shutdown-deposits"));
}

/** Stake sBTC for stBTC; `minShares` comes from `data-stbtc-v1.get-sbtc-per-stbtc`. */
export function buildStbtcDeposit({
  amount,
  minShares,
  sender,
}: {
  amount: bigint;
  minShares: bigint;
  sender: string;
}): ContractCall {
  return {
    contract: STBTC_CORE,
    functionName: "deposit",
    functionArgs: [Cl.uint(amount), Cl.uint(minShares)],
    postConditions: [sbtcSentExactly(sender, amount)],
    postConditionMode: "deny",
  };
}
