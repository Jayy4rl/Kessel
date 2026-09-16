import { HIRO_API } from "./config";

// The public half of Bond Overview (PRD §5.1): everything readable without a
// wallet and without history. Charts need the indexer; these figures do not.

export interface RawBond {
  index: number;
  status: string;
  parameters: {
    target_rate_bps: number;
    stx_value_ratio: number;
    minimum_stx_ratio: number;
    btc_capacity: string;
  };
  registrations: { allowed_count: number; registered_count: number };
  schedule: {
    activation: { bitcoin_height: number; pox_cycle: number };
    unlock: { bitcoin_height: number; pox_cycle: number };
  };
  balances: { locked: { btc: string; stx: string }; paid_out: { btc: string } };
}

export interface BondSummary {
  index: number;
  status: string;
  targetApyPct: number;
  /** Minimum STX to pair, as a percentage of the BTC value. */
  minStxRatioPct: number;
  capacitySats: bigint;
  lockedSats: bigint;
  lockedUstx: bigint;
  paidOutSats: bigint;
  registered: number;
  allowed: number;
  fillPct: number;
  activationHeight: number;
  unlockHeight: number;
}

export function deriveBond(raw: RawBond): BondSummary {
  const capacitySats = BigInt(raw.parameters.btc_capacity);
  const lockedSats = BigInt(raw.balances.locked.btc);
  return {
    index: raw.index,
    status: raw.status,
    targetApyPct: raw.parameters.target_rate_bps / 100,
    minStxRatioPct: raw.parameters.minimum_stx_ratio / 100,
    capacitySats,
    lockedSats,
    lockedUstx: BigInt(raw.balances.locked.stx),
    paidOutSats: BigInt(raw.balances.paid_out.btc),
    registered: raw.registrations.registered_count,
    allowed: raw.registrations.allowed_count,
    fillPct: capacitySats > 0n ? (Number(lockedSats) / Number(capacitySats)) * 100 : 0,
    activationHeight: raw.schedule.activation.bitcoin_height,
    unlockHeight: raw.schedule.unlock.bitcoin_height,
  };
}

const MINUTES_PER_BLOCK = 10;

export interface BondTiming {
  phase: "upcoming" | "active" | "unlocked";
  /** Bitcoin blocks until the next milestone, 0 once it has passed. */
  blocksRemaining: number;
  daysRemaining: number;
  date: Date;
}

/** Where a bond sits against the current Bitcoin block, and roughly when it turns. */
export function bondTiming(bond: BondSummary, currentBurnHeight: number): BondTiming {
  const phase =
    currentBurnHeight < bond.activationHeight
      ? "upcoming"
      : currentBurnHeight < bond.unlockHeight
        ? "active"
        : "unlocked";
  const target = phase === "upcoming" ? bond.activationHeight : bond.unlockHeight;
  const blocksRemaining = Math.max(0, target - currentBurnHeight);
  const minutes = blocksRemaining * MINUTES_PER_BLOCK;
  return {
    phase,
    blocksRemaining,
    daysRemaining: minutes / (60 * 24),
    date: new Date(Date.now() + minutes * 60_000),
  };
}

/**
 * Yield actually paid so far, annualised. Null until a distribution has run:
 * pox-5 pays nothing until `calculate-rewards` settles a cycle.
 */
export function effectiveApyPct(bond: BondSummary, currentBurnHeight: number): number | null {
  if (bond.paidOutSats === 0n || bond.lockedSats === 0n) return null;
  const elapsedBlocks = currentBurnHeight - bond.activationHeight;
  if (elapsedBlocks <= 0) return null;
  const elapsedYears = (elapsedBlocks * MINUTES_PER_BLOCK) / (60 * 24 * 365);
  return (Number(bond.paidOutSats) / Number(bond.lockedSats) / elapsedYears) * 100;
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return (await res.json()) as T;
}

export async function fetchBonds(): Promise<BondSummary[]> {
  const { results } = await getJson<{ results: RawBond[] }>(`${HIRO_API}/extended/v3/staking/bonds`);
  return results.map(deriveBond);
}

export async function fetchBurnHeight(): Promise<number> {
  const info = await getJson<{ burn_block_height: number }>(`${HIRO_API}/v2/info`);
  return info.burn_block_height;
}
