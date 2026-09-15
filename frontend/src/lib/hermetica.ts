import { ClarityType, Cl } from "@stacks/transactions";
import { HBTC_STATE, HBTC_VAULT } from "./config";
import { readOnly, sbtcSentExactly, type ContractCall } from "./tx";

/** hBTC opens deposits in capped windows; closed on 2026-09-15. */
export async function fetchHbtcDepositsOpen(): Promise<boolean> {
  return (await readOnly(HBTC_STATE, "check-is-deposit-enabled")).type === ClarityType.ResponseOk;
}

/**
 * Deposit sBTC into Hermetica's hBTC vault. The vault debits and credits
 * `contract-caller`, so the depositor's wallet must call it directly.
 *
 * `deposit` takes no minimum-shares argument: quote with the vault's
 * `preview-deposit` first, and expect deposits to fail once the vault's
 * capacity is reached.
 */
export function buildHbtcDeposit({ amount, sender }: { amount: bigint; sender: string }): ContractCall {
  return {
    contract: HBTC_VAULT,
    functionName: "deposit",
    functionArgs: [Cl.uint(amount), Cl.none()],
    postConditions: [sbtcSentExactly(sender, amount)],
    postConditionMode: "deny",
  };
}
