import { Cl } from "@stacks/transactions";
import { HIRO_API, POX_5 } from "./config";
import { readOnly, toBigInt, type ContractId } from "./tx";

// Bond positions and rewards come from Hiro's indexed staking API; anything
// the API does not expose per cycle is read from pox-5 directly.

export interface BondPosition {
  bondIndex: number;
  status: string;
  active: boolean;
  lockedBtc: bigint;
  lockedStx: bigint;
  accrued: bigint;
  claimed: bigint;
  claimable: bigint;
}

interface RawPosition {
  bond_index: number;
  status: string;
  active: boolean;
  locked: { btc: string; stx: string };
  rewards: { btc: { accrued: string; claimed: string; claimable: string } };
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return (await res.json()) as T;
}

export async function fetchBondPositions(principal: string): Promise<BondPosition[]> {
  const { results } = await getJson<{ results: RawPosition[] }>(
    `${HIRO_API}/extended/v3/principals/${principal}/staking/bonds`,
  );
  return results.map((r) => ({
    bondIndex: r.bond_index,
    status: r.status,
    active: r.active,
    lockedBtc: BigInt(r.locked.btc),
    lockedStx: BigInt(r.locked.stx),
    accrued: BigInt(r.rewards.btc.accrued),
    claimed: BigInt(r.rewards.btc.claimed),
    claimable: BigInt(r.rewards.btc.claimable),
  }));
}

/** The signer-manager a staker registered with; the claim goes through it. */
export async function fetchSignerManager(
  bondIndex: number,
  principal: string,
): Promise<ContractId> {
  const { signer } = await getJson<{ signer: string }>(
    `${HIRO_API}/extended/v3/staking/bonds/${bondIndex}/registrations/${principal}`,
  );
  return signer as ContractId;
}

export async function fetchCurrentCycle(): Promise<number> {
  const pox = await getJson<{ current_cycle: { id: number } }>(`${HIRO_API}/v2/pox`);
  return pox.current_cycle.id;
}

export interface CycleReward {
  cycle: number;
  /** Gross sBTC before the manager's fee. */
  earned: bigint;
}

/**
 * Rewards per cycle for one bond leg, read from pox-5.
 *
 * Hiro's API only reports a lifetime claimable total, but a claim names a
 * single cycle, so scan the recent ones. This read is the same for every
 * signer-manager, including those with no per-staker read of their own.
 */
export async function fetchClaimableCycles({
  signerManager,
  staker,
  bondIndex,
  currentCycle,
  lookback = 6,
}: {
  signerManager: ContractId;
  staker: string;
  bondIndex: number;
  currentCycle: number;
  lookback?: number;
}): Promise<CycleReward[]> {
  const cycles = Array.from({ length: lookback }, (_, i) => currentCycle - i).filter((c) => c >= 0);
  const rewards = await Promise.all(
    cycles.map(async (cycle) => ({
      cycle,
      earned: toBigInt(
        await readOnly(POX_5, "get-earned-staker-rewards", [
          Cl.principal(signerManager),
          Cl.uint(cycle),
          Cl.some(Cl.uint(bondIndex)),
          Cl.principal(staker),
        ]),
      ),
    })),
  );
  return rewards.filter((r) => r.earned > 0n);
}

/**
 * The claim net of the manager's fee, when the manager exposes it. Managers
 * without this read (e.g. native-pool) return null and the claim is sent
 * without a minimum.
 */
export async function fetchNetEarned({
  signerManager,
  staker,
  bondIndex,
  cycle,
}: {
  signerManager: ContractId;
  staker: string;
  bondIndex: number;
  cycle: number;
}): Promise<bigint | null> {
  try {
    const result = await readOnly(signerManager, "get-earned-staker-rewards", [
      Cl.principal(staker),
      Cl.uint(cycle),
      Cl.some(Cl.uint(bondIndex)),
    ]);
    const fields = (result as { value: Record<string, unknown> }).value;
    return toBigInt(fields.earned as never);
  } catch {
    return null;
  }
}
