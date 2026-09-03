import { useEffect, useState } from "react";
import { createPublicClient, http, type Address } from "viem";
import { baseSepolia } from "viem/chains";
import { kesselAbi } from "./abi";
import { ADDRESSES, RPC_URL } from "./config";

export const client = createPublicClient({
  chain: baseSepolia,
  transport: http(RPC_URL),
});

const hook = { address: ADDRESSES.hook as Address, abi: kesselAbi } as const;

export type Chain = {
  fBase: bigint;
  fSlow: bigint;
  k: bigint;
  currentEpoch: number;
  oldestUnsettledEpoch: number;
  pending: bigint;
  nextOrderId: bigint;
  minSettleAge: number;
  warehoused0: bigint;
  lpClaimable0: bigint;
  lpClaimable1: bigint;
  forceSettleDue: boolean;
  block: bigint;
};

/// Polls the deployed hook. `stale` distinguishes "the chain says zero" from
/// "we could not reach the chain" -- the two look identical in a stat tile and
/// only one of them means something.
export function useKessel(pollMs = 12_000) {
  const [data, setData] = useState<Chain | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [stale, setStale] = useState(true);

  useEffect(() => {
    let alive = true;

    async function read() {
      try {
        const call = (functionName: string, args: unknown[] = []) =>
          client.readContract({ ...hook, functionName, args } as never);

        const [
          fBase, fSlow, k, currentEpoch, oldest, nextOrderId,
          minSettleAge, warehoused0, lpc0, lpc1, due, block,
        ] = await Promise.all([
          call("fBase"), call("fSlow"), call("k"), call("currentEpoch"),
          call("oldestUnsettledEpoch"), call("nextOrderId"), call("minSettleAge"),
          call("warehoused0"), call("lpClaimable0"), call("lpClaimable1"),
          call("forceSettleDue"), client.getBlockNumber(),
        ]);

        const pending = await call("orderCount", [Number(oldest)]);
        if (!alive) return;

        // viem decodes integer types by width: anything <= 48 bits comes back
        // as a JS `number`, wider as a `bigint`. `fBase` and `fSlow` are uint24
        // and so arrive as numbers, which then cannot be mixed with the uint256
        // `k` in the fee arithmetic. Normalising here keeps that decision in one
        // place rather than at every call site.
        setData({
          fBase: BigInt(fBase as number | bigint),
          fSlow: BigInt(fSlow as number | bigint),
          k: BigInt(k as number | bigint),
          currentEpoch: Number(currentEpoch),
          oldestUnsettledEpoch: Number(oldest),
          pending: BigInt(pending as number | bigint),
          nextOrderId: BigInt(nextOrderId as number | bigint),
          minSettleAge: Number(minSettleAge),
          warehoused0: BigInt(warehoused0 as number | bigint),
          lpClaimable0: BigInt(lpc0 as number | bigint),
          lpClaimable1: BigInt(lpc1 as number | bigint),
          forceSettleDue: Boolean(due),
          block: BigInt(block as number | bigint),
        });
        setError(null);
        setStale(false);
      } catch (e) {
        if (!alive) return;
        setError(e instanceof Error ? e.message : String(e));
        setStale(true);
      }
    }

    read();
    const t = setInterval(read, pollMs);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [pollMs]);

  return { data, error, stale };
}
