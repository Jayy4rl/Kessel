import { Cl } from "@stacks/transactions";
import {
  BITFLOW_APP_API,
  BITFLOW_QUOTES_API,
  HODLMM_LIQUIDITY_ROUTER,
  SBTC_TOKEN,
} from "./config";
import { sbtcSentExactly, type ContractCall, type ContractId } from "./tx";

// HODLMM bin ids run 0..1000 in the API and -500..500 on-chain.
const CENTER_BIN_ID = 500;

/** Which token of the pair sBTC is. */
export type SbtcSide = "x" | "y";

export interface BitflowPool {
  poolId: string;
  poolContract: ContractId;
  tokenX: ContractId;
  tokenY: ContractId;
  active: boolean;
  tvlBtc: number;
  feesBtc7d: number;
  feesBtc30d: number;
  /** Bitflow's own figures; the API does not document how they are computed. */
  reportedAprPct: number;
  reportedApr24hPct: number;
  /** Share of each swap fee paid to LPs: (provider + variable) / total. */
  lpFeeShare: number;
}

export interface RawPool {
  poolId: string;
  poolContract: string;
  poolStatus: boolean;
  tokens: { tokenX: { contract: string }; tokenY: { contract: string } };
  tvlBtc: number;
  feesBtc7d: number;
  feesBtc30d: number;
  apr: number;
  apr24h: number;
  xProtocolFee: number;
  xProviderFee: number;
  xVariableFee: number;
}

export function parsePool(raw: RawPool): BitflowPool {
  const totalFee = raw.xProtocolFee + raw.xProviderFee + raw.xVariableFee;
  return {
    poolId: raw.poolId,
    poolContract: raw.poolContract as ContractId,
    tokenX: raw.tokens.tokenX.contract as ContractId,
    tokenY: raw.tokens.tokenY.contract as ContractId,
    active: raw.poolStatus,
    tvlBtc: raw.tvlBtc,
    feesBtc7d: raw.feesBtc7d,
    feesBtc30d: raw.feesBtc30d,
    reportedAprPct: raw.apr,
    reportedApr24hPct: raw.apr24h,
    lpFeeShare: totalFee > 0 ? (raw.xProviderFee + raw.xVariableFee) / totalFee : 0,
  };
}

async function getJson<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return (await res.json()) as T;
}

/** Every pool Bitflow tracks, with TVL and fee history. */
export async function fetchPools(): Promise<BitflowPool[]> {
  const { data } = await getJson<{ data: RawPool[] }>(`${BITFLOW_APP_API}/pools`);
  return data.map(parsePool);
}

export function sbtcSide(pool: Pick<BitflowPool, "tokenX" | "tokenY">): SbtcSide | null {
  if (pool.tokenX === SBTC_TOKEN) return "x";
  if (pool.tokenY === SBTC_TOKEN) return "y";
  return null;
}

export interface RankedPool extends BitflowPool {
  side: SbtcSide;
  /** Trailing 30-day LP fees, annualised over current TVL. */
  lpFeeAprPct: number;
  /** Trailing 7-day LP fees, annualised over current TVL. */
  lpFeeApr7dPct: number;
  /** The 7-day and 30-day figures disagree by more than 2x. */
  volatile: boolean;
  /** Bitflow's reported APR disagrees with the 30-day figure by more than 2x. */
  reportedDivergent: boolean;
}

const outside2x = (a: number, b: number) => b <= 0 || a / b > 2 || a / b < 0.5;

/**
 * sBTC pools worth offering, highest trailing 30-day fee yield first.
 *
 * Pool TVL can move by multiples within hours, which swings any fees-over-TVL
 * figure with it, so rank right before depositing and surface the flags.
 *
 * This is fee yield, not BTC yield: sBTC-only liquidity converts into the
 * pair token as the price moves through it, so True Yield must net out that
 * conversion before comparing against lending or staking.
 */
export function rankSbtcPools(
  pools: BitflowPool[],
  { minTvlBtc = 1 }: { minTvlBtc?: number } = {},
): RankedPool[] {
  return pools
    .flatMap((pool) => {
      const side = sbtcSide(pool);
      if (!side || !pool.active || pool.tvlBtc < minTvlBtc) return [];
      const annualise = (feesBtc: number, days: number) =>
        (feesBtc / pool.tvlBtc) * (365 / days) * pool.lpFeeShare * 100;
      const lpFeeAprPct = annualise(pool.feesBtc30d, 30);
      const lpFeeApr7dPct = annualise(pool.feesBtc7d, 7);
      return [
        {
          ...pool,
          side,
          lpFeeAprPct,
          lpFeeApr7dPct,
          volatile: outside2x(lpFeeApr7dPct, lpFeeAprPct),
          reportedDivergent: outside2x(pool.reportedAprPct, lpFeeAprPct),
        },
      ];
    })
    .sort((a, b) => b.lpFeeAprPct - a.lpFeeAprPct);
}

export interface Bin {
  binId: number;
  reserveX: bigint;
  reserveY: bigint;
}

export interface PoolBins {
  activeBinId: number;
  bins: Bin[];
}

interface RawBin {
  bin_id: number;
  reserve_x: string;
  reserve_y: string;
}

export async function fetchBins(poolId: string): Promise<PoolBins> {
  const [active, all] = await Promise.all([
    getJson<{ bin_id: number }>(`${BITFLOW_QUOTES_API}/bins/${poolId}/active`),
    getJson<{ bins: RawBin[] }>(`${BITFLOW_QUOTES_API}/bins/${poolId}`),
  ]);
  return {
    activeBinId: active.bin_id,
    bins: all.bins.map((b) => ({
      binId: b.bin_id,
      reserveX: BigInt(b.reserve_x),
      reserveY: BigInt(b.reserve_y),
    })),
  };
}

/**
 * The `count` bins nearest the active bin that can take sBTC alone and
 * already hold some (new bins must meet a minimum share size).
 *
 * HODLMM only accepts token X above the active bin and token Y below it, so
 * sBTC-only liquidity goes above when sBTC is X and below when it is Y.
 */
export function selectSbtcBins({ activeBinId, bins }: PoolBins, side: SbtcSide, count: number) {
  return bins
    .filter((b) =>
      side === "x" ? b.binId > activeBinId && b.reserveX > 0n : b.binId < activeBinId && b.reserveY > 0n,
    )
    .sort((a, b) => Math.abs(a.binId - activeBinId) - Math.abs(b.binId - activeBinId))
    .slice(0, count)
    .map((b) => b.binId);
}

export interface HodlmmDeposit {
  pool: Pick<BitflowPool, "poolContract" | "tokenX" | "tokenY">;
  /** API bin ids from `selectSbtcBins`. */
  binIds: number[];
  amount: bigint;
  sender: string;
  /** Unix seconds after which the router rejects the transaction. */
  deadline: number;
}

/**
 * sBTC-only liquidity spread evenly over `binIds`, using the router's strict
 * entrypoint (absolute bins, exact amounts) so the wallet can enforce an exact
 * post-condition.
 *
 * Zero liquidity-fee caps make the deposit revert if the price reaches a
 * chosen bin before it confirms; the core also rejects sBTC landing on the
 * wrong side of the active bin. `min-dlp` is only a non-zero floor.
 */
export function buildHodlmmSbtcDeposit({
  pool,
  binIds,
  amount,
  sender,
  deadline,
}: HodlmmDeposit): ContractCall {
  const side = sbtcSide(pool);
  if (!side) throw new Error("pool does not contain sBTC");
  if (binIds.length === 0) throw new Error("no bins to deposit into");
  const count = BigInt(binIds.length);
  if (amount < count) throw new Error("amount must cover at least 1 sat per bin");

  const share = amount / count;
  const positions = binIds.map((binId, i) => {
    const binAmount = i === 0 ? share + (amount % count) : share;
    return Cl.tuple({
      "pool-trait": Cl.principal(pool.poolContract),
      "x-token-trait": Cl.principal(pool.tokenX),
      "y-token-trait": Cl.principal(pool.tokenY),
      "bin-id": Cl.int(binId - CENTER_BIN_ID),
      "x-amount": Cl.uint(side === "x" ? binAmount : 0n),
      "y-amount": Cl.uint(side === "y" ? binAmount : 0n),
      "min-dlp": Cl.uint(1),
      "max-x-liquidity-fee": Cl.uint(0),
      "max-y-liquidity-fee": Cl.uint(0),
    });
  });

  return {
    contract: HODLMM_LIQUIDITY_ROUTER,
    functionName: "add-liquidity-multi",
    functionArgs: [Cl.list(positions), Cl.some(Cl.uint(deadline))],
    postConditions: [sbtcSentExactly(sender, amount)],
    postConditionMode: "deny",
  };
}
