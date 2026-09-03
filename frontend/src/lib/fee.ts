/// Mirror of `FastLaneFee.fee` -- kept in sync with the contract deliberately,
/// so the curve below is the fee the pool would actually charge rather than an
/// illustration of it.
///
///   fee = f_base + k * priorityFee / 1 gwei,  saturating at MAX_FAST_FEE
///
/// A zero priority fee reveals no urgency and pays exactly the base fee.
export const MAX_FAST_FEE = 50_000n; // 5%, the contract's ceiling
const ONE_GWEI = 1_000_000_000n;

export function fastFee(fBase: bigint, k: bigint, priorityFeeWei: bigint): bigint {
  if (k === 0n || priorityFeeWei === 0n) return fBase;
  const fee = fBase + (k * priorityFeeWei) / ONE_GWEI;
  return fee > MAX_FAST_FEE ? MAX_FAST_FEE : fee;
}

/// v4 fee units are hundredths of a bip: 1_000_000 == 100%.
export const asPercent = (feeUnits: bigint) => Number(feeUnits) / 10_000;

/// The premium is the part above `f_base` -- the amount recaptured to LPs
/// rather than left to the sequencer.
export const premium = (fee: bigint, fBase: bigint) => (fee > fBase ? fee - fBase : 0n);

export function curve(fBase: bigint, k: bigint, maxGwei = 25) {
  const pts: { gwei: number; fee: bigint }[] = [];
  for (let g = 0; g <= maxGwei; g += 0.5) {
    pts.push({ gwei: g, fee: fastFee(fBase, k, BigInt(Math.round(g * 1e9))) });
  }
  return pts;
}
