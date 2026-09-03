import { useEffect, useState } from "react";
import {
  createPublicClient,
  encodeAbiParameters,
  hexToBigInt,
  fallback,
  http,
  keccak256,
  type Address,
} from "viem";
import { baseSepolia } from "viem/chains";
import { kesselAbi } from "./abi";
import { ADDRESSES, POOL_ID, RPC_URLS } from "./config";

export const client = createPublicClient({
  chain: baseSepolia,
  transport: fallback(
    RPC_URLS.map((url) => http(url, { retryCount: 2 })),
    { rank: false },
  ),
});

const hook = { address: ADDRESSES.hook as Address, abi: kesselAbi } as const;

const extsloadAbi = [
  {
    type: "function",
    name: "extsload",
    inputs: [{ type: "bytes32" }],
    outputs: [{ type: "bytes32" }],
    stateMutability: "view",
  },
] as const;

/// v4 keeps every pool in one mapping at slot 6. `slot0` (sqrt price, tick) is
/// the first word of that struct and `liquidity` is three along. Reading them
/// directly avoids a periphery lens contract for two numbers.
const POOL_BASE_SLOT = keccak256(
  encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [POOL_ID as `0x${string}`, 6n]),
);

async function readPool() {
  const read = (slot: `0x${string}`) =>
    client.readContract({
      address: ADDRESSES.poolManager as Address,
      abi: extsloadAbi,
      functionName: "extsload",
      args: [slot],
    });

  const raw = hexToBigInt(await read(POOL_BASE_SLOT));
  const sqrtPriceX96 = raw & ((1n << 160n) - 1n);
  let tick = Number((raw >> 160n) & ((1n << 24n) - 1n));
  if (tick >= 2 ** 23) tick -= 2 ** 24; // int24, stored two's complement

  const liqSlot = ("0x" +
    (hexToBigInt(POOL_BASE_SLOT) + 3n).toString(16).padStart(64, "0")) as `0x${string}`;
  const liquidity = hexToBigInt(await read(liqSlot)) & ((1n << 128n) - 1n);

  return { sqrtPriceX96, tick, liquidity };
}

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
  sqrtPriceX96: bigint;
  tick: number;
  liquidity: bigint;
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
          minSettleAge, warehoused0, lpc0, lpc1, due, block, pool,
        ] = await Promise.all([
          call("fBase"), call("fSlow"), call("k"), call("currentEpoch"),
          call("oldestUnsettledEpoch"), call("nextOrderId"), call("minSettleAge"),
          call("warehoused0"), call("lpClaimable0"), call("lpClaimable1"),
          call("forceSettleDue"), client.getBlockNumber(), readPool(),
        ]);

        const pending = await call("orderCount", [Number(oldest)]);
        if (!alive) return;

        // viem decodes integer types by width: anything <= 48 bits comes back
        // as a JS `number`, wider as a `bigint`. `fBase` and `fSlow` are uint24
        // and so arrive as numbers, which then cannot be mixed with the uint256
        // `k` in the fee arithmetic. Normalising here keeps that decision in
        // one place rather than at every call site.
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
          ...(pool as Awaited<ReturnType<typeof readPool>>),
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
