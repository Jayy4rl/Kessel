import { concatHex, encodeAbiParameters, encodePacked, type Address, type Hex } from "viem";
import { ADDRESSES } from "./config";

/// The pool this hook is bound to. The hook is immutable and serves exactly one
/// pool, so this is a constant rather than something the UI can choose.
export const POOL_KEY = {
  currency0: ADDRESSES.currency0 as Address,
  currency1: ADDRESSES.currency1 as Address,
  fee: 0x800000, // LPFeeLibrary.DYNAMIC_FEE_FLAG
  tickSpacing: 60,
  hooks: ADDRESSES.hook as Address,
} as const;

/// v4's price bounds, nudged inside by one so a swap never sits exactly on the
/// limit and revert for it.
export const MIN_SQRT_PRICE_LIMIT = 4295128740n;
export const MAX_SQRT_PRICE_LIMIT =
  1461446703485210103287273052203988822378723970341n;

/// A swap needs a price limit, and passing the extreme bound means "no limit
/// at all" -- the swap will walk the curve as far as it can. That is how this
/// pool's price was driven to MIN_TICK with a single oversized trade, leaving
/// zero active liquidity behind. So bound it near the current price instead.
///
/// The bound is applied to the SQRT price, so a given bps here is roughly twice
/// that in price terms. Falls back to the extreme only when the pool price is
/// unreadable, which should not happen.
export function priceLimit(zeroForOne: boolean, sqrtPriceX96?: bigint, slippageBps = 500n): bigint {
  if (!sqrtPriceX96 || sqrtPriceX96 === 0n) {
    return zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT;
  }
  const limit = zeroForOne
    ? (sqrtPriceX96 * (10_000n - slippageBps)) / 10_000n
    : (sqrtPriceX96 * (10_000n + slippageBps)) / 10_000n;

  if (zeroForOne) return limit < MIN_SQRT_PRICE_LIMIT ? MIN_SQRT_PRICE_LIMIT : limit;
  return limit > MAX_SQRT_PRICE_LIMIT ? MAX_SQRT_PRICE_LIMIT : limit;
}

/// `hookData` selects the lane. Empty bytes and an unrecognised byte both mean
/// FAST, so an aggregator that knows nothing about this hook still trades.
export const FAST_DATA: Hex = "0x00";

/// SLOW carries its parameters: who the fill belongs to, the minimum output
/// that becomes the order's limit price, and how many epochs it may rest before
/// the remainder is refundable.
export function slowData(trader: Address, minOut: bigint, expiryEpochs: number): Hex {
  return concatHex([
    encodePacked(["uint8"], [1]),
    encodeAbiParameters(
      [{ type: "address" }, { type: "uint128" }, { type: "uint32" }],
      [trader, minOut, expiryEpochs],
    ),
  ]);
}

export const TEST_SETTINGS = { takeClaims: false, settleUsingBurn: false } as const;

/// Order status, mirroring the contract's enum.
export const STATUS = ["NONE", "PENDING", "SETTLED", "REDEEMED", "REFUNDED"] as const;
