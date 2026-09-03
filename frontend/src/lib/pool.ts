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

export const priceLimit = (zeroForOne: boolean) =>
  zeroForOne ? MIN_SQRT_PRICE_LIMIT : MAX_SQRT_PRICE_LIMIT;

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
