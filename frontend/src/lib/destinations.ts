import {
  buildHodlmmSbtcDeposit,
  fetchBins,
  fetchPools,
  rankSbtcPools,
  selectSbtcBins,
  type RankedPool,
} from "./bitflow";
import { buildHbtcDeposit, fetchHbtcDepositsOpen } from "./hermetica";
import { buildStbtcDeposit, fetchStbtcDepositsOpen } from "./stackingdao";
import type { ContractCall } from "./tx";
import { buildZestSbtcSupply, fetchZestSbtcMarket, fetchZestSharesFor, type ZestSbtcMarket } from "./zest";

export type DestinationKind = "bitflow" | "zest" | "stbtc" | "hbtc";

export interface Destination {
  id: string;
  kind: DestinationKind;
  label: string;
  /** Null when the venue publishes no rate we can read. */
  aprPct: number | null;
  available: boolean;
  note: string;
  pool?: RankedPool;
}

export interface VenueState {
  pools: RankedPool[];
  zest: ZestSbtcMarket;
  stbtcOpen: boolean;
  hbtcOpen: boolean;
}

/** Deposit venues for claimed sBTC, best readable yield first, closed ones last. */
export function assembleDestinations({ pools, zest, stbtcOpen, hbtcOpen }: VenueState): Destination[] {
  const destinations: Destination[] = [
    ...pools.map((pool) => ({
      id: pool.poolId,
      kind: "bitflow" as const,
      label: `Bitflow ${pool.poolId} (${pool.side === "x" ? "sBTC first" : "sBTC second"})`,
      aprPct: pool.lpFeeAprPct,
      available: true,
      note: [
        "Trading fees, not BTC yield: the sBTC converts into the pair token as the price moves through your range.",
        pool.volatile ? "7-day and 30-day fees disagree by more than 2x." : "",
        pool.reportedDivergent ? `Bitflow reports ${pool.reportedAprPct.toFixed(0)}%.` : "",
      ]
        .filter(Boolean)
        .join(" "),
      pool,
    })),
    {
      id: "zest",
      kind: "zest",
      label: "Zest v2 — supply sBTC",
      aprPct: zest.supplyAprPct,
      available: !zest.depositsPaused,
      note: zest.depositsPaused
        ? "Deposits paused."
        : `Lending yield at ${(zest.utilizationBps / 100).toFixed(1)}% utilisation, before any incentives.`,
    },
    {
      id: "stbtc",
      kind: "stbtc",
      label: "StackingDAO — mint stBTC",
      aprPct: null,
      available: stbtcOpen,
      note: stbtcOpen
        ? "Bitcoin Staking yield, liquid."
        : "Deposits closed: StackingDAO's bond allocation is full.",
    },
    {
      id: "hbtc",
      kind: "hbtc",
      label: "Hermetica — hBTC vault",
      aprPct: null,
      available: hbtcOpen,
      note: hbtcOpen ? "Vault yield in BTC terms." : "Deposit window closed.",
    },
  ];

  return destinations.sort((a, b) => {
    if (a.available !== b.available) return a.available ? -1 : 1;
    return (b.aprPct ?? -1) - (a.aprPct ?? -1);
  });
}

export async function loadDestinations(): Promise<Destination[]> {
  const [pools, zest, stbtcOpen, hbtcOpen] = await Promise.all([
    fetchPools().then((p) => rankSbtcPools(p)),
    fetchZestSbtcMarket(),
    fetchStbtcDepositsOpen(),
    fetchHbtcDepositsOpen(),
  ]);
  return assembleDestinations({ pools, zest, stbtcOpen, hbtcOpen });
}

/** Percentage of the quoted output accepted as the floor, i.e. 1% slippage. */
const SLIPPAGE_BPS = 9_900n;

export async function buildDeposit(
  destination: Destination,
  { amount, sender }: { amount: bigint; sender: string },
): Promise<ContractCall> {
  switch (destination.kind) {
    case "bitflow": {
      const pool = destination.pool;
      if (!pool) throw new Error("missing pool data");
      const bins = await fetchBins(pool.poolId);
      const binIds = selectSbtcBins(bins, pool.side, 3);
      if (binIds.length === 0) throw new Error("no bins available beside the current price");
      return buildHodlmmSbtcDeposit({
        pool,
        binIds,
        amount,
        sender,
        deadline: Math.floor(Date.now() / 1000) + 600,
      });
    }
    case "zest": {
      const shares = await fetchZestSharesFor(amount);
      return buildZestSbtcSupply({
        amount,
        minShares: (shares * SLIPPAGE_BPS) / 10_000n,
        sender,
      });
    }
    case "stbtc":
      return buildStbtcDeposit({ amount, minShares: (amount * SLIPPAGE_BPS) / 10_000n, sender });
    case "hbtc":
      return buildHbtcDeposit({ amount, sender });
  }
}
