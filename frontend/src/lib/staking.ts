import { Cl, Pc, type TupleCV } from "@stacks/transactions";
import { SBTC_ASSET_NAME, SBTC_TOKEN } from "./config";
import { readOnly, toBigInt, type ContractCall, type ContractId } from "./tx";

// These follow the stacks-core reference signer-manager. Managers with a
// different interface (e.g. native-pool-signer-manager) need their own builder.

export interface StakerClaim {
  signerManager: ContractId;
  staker: string;
  rewardCycle: number;
  bondIndex: number;
}

/**
 * The staker's claimable sBTC for one bond leg of `rewardCycle`, net of the
 * manager's fee. Stakers who registered an L1 payout address are paid in BTC.
 */
export async function fetchEarnedStakerRewards({
  signerManager,
  staker,
  rewardCycle,
  bondIndex,
}: StakerClaim): Promise<{ earned: bigint; fees: bigint }> {
  const result = (await readOnly(signerManager, "get-earned-staker-rewards", [
    Cl.principal(staker),
    Cl.uint(rewardCycle),
    Cl.some(Cl.uint(bondIndex)),
  ])) as TupleCV;
  return { earned: toBigInt(result.value.earned), fees: toBigInt(result.value.fees) };
}

/**
 * Claim through the manager's permissionless `claim-staker-rewards`, which
 * pays `staker`. Deny mode keeps anything from leaving the staker's wallet,
 * and the post-condition rejects a claim smaller than `minAmount`.
 */
export function buildClaimStakerRewards({
  minAmount,
  ...claim
}: StakerClaim & { minAmount: bigint }): ContractCall {
  return {
    contract: claim.signerManager,
    functionName: "claim-staker-rewards",
    functionArgs: [Cl.principal(claim.staker), Cl.uint(claim.rewardCycle), Cl.some(Cl.uint(claim.bondIndex))],
    postConditions: [
      Pc.principal(claim.signerManager).willSendGte(minAmount).ft(SBTC_TOKEN, SBTC_ASSET_NAME),
    ],
    postConditionMode: "deny",
  };
}
