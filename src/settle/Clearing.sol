// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice The Slow-Lane uniform clearing price (PRD §4.3, §7.4). Owns DD-5.
///
/// ============================================================================
/// I6 IS ENFORCED STRUCTURALLY BY THIS FILE'S SIGNATURE, NOT BY REVIEW.
/// ============================================================================
/// Every function here is `pure`, and the only pool state any of them accepts
/// is a `PoolPoint` read at *settlement* time. There is no parameter through
/// which submission-time state could reach the price, so "no code path lets a
/// Slow-Lane fill be computed from submission-time state" is a property of the
/// type signature. Do not add a parameter that carries submission-time data.
///
/// ============================================================================
/// The derivation (PRD §4.3 requires this be pinned down, not left to prose)
/// ============================================================================
/// Let `a` be the pool's sqrt price at settlement and `L` the active liquidity.
/// Over a range of constant `L`, moving the price `a -> b` exchanges
///
///     Y = L * (a - b)                      (currency1 the pool pays out)
///     X = L * (a - b) / (a * b)            (currency0 the pool takes in)
///
/// so the *average* execution price of that move is `Y / X = a * b`.
///
/// Let `N0` / `N1` be the aggregate net-of-fee Slow-Lane input per direction.
/// If every order clears at one price `P` (I4) then, for the hook to be exactly
/// solvent (I2), the pool must supply precisely the imbalance:
///
///     X = N0 - N1 / P                      Y = N0 * P - N1
///
/// Both of those reduce to the same equation, and combining with `P = a * b`:
///
///     L * (a - b) = N0 * a * b - N1
///  => b = (L * a + N1) / (L + N0 * a)              <-- closed form, no solver
///     P = a * b
///
/// This dissolves the circularity PRD §4.3 warns about: netting, residual size
/// and price are one simultaneous solution rather than three sequential steps.
///
/// Properties, all verified exactly in rational arithmetic and then fuzzed
/// on-chain against v4's own `SqrtPriceMath` (see `test/property/`):
///
///   * `N0 = N1 = 0`            => `b = a`; the pool is untouched.
///   * `N1 = N0 * spot`         => `b = a` EXACTLY. A perfectly matched batch
///                                 clears entirely against itself at spot with
///                                 zero price impact. Coincidence-of-wants
///                                 falls out of the algebra; it is not a
///                                 special case in the code.
///   * one-sided batch          => reduces to an ordinary exact-input swap
///                                 priced at its own average.
///   * `L = 0`                  => `P = N1 / N0`, the pure-CoW price, with no
///                                 residual. Also handled by the same formula.
///
/// ============================================================================
/// Why the average price and not the post-residual MARGINAL price
/// ============================================================================
/// PRD §4.3(a) is worded as "the pool's marginal price after executing the net
/// residual". That is `b^2`, whereas the average is `a * b`. Since `b < a` when
/// the batch is net-selling currency0, `a * b > b^2`, so clearing everyone at
/// the marginal price would leave the hook holding a surplus on every
/// settlement: an uncapped implicit fee that varies with batch size, charged to
/// Slow-Lane traders on top of `f_slow` and invisible to I10. The average-price
/// definition has exactly zero residue. See DD-5 for the full argument.
///
/// ============================================================================
/// Tick crossing
/// ============================================================================
/// The closed form assumes constant `L` across `[b, a]`. Liquidity can only
/// change at an **initialised** tick, so the caller supplies the bounds of the
/// active liquidity range and `solve` clamps `b` into them. That makes the
/// closed form exact by construction.
///
/// Note the bounds must be the next *initialised* ticks, not merely the next
/// multiples of `tickSpacing`. Most tick-spacing multiples carry no position,
/// and clamping to them would make partial fills the norm rather than the
/// exception — the active range is typically far wider than one spacing.
///
/// When the clamp binds, this library alone can only fill the batch pro rata at
/// ratio `lambda < 1` and roll the remainder (DD-11).
///
/// The caller is no longer obliged to stop there. `KesselHook._solveMultiRange`
/// walks up to `MAX_CLEARING_RANGES` consecutive ranges, calling `solve` once
/// per range with that range's own liquidity and whatever of the batch remains,
/// and crossing the initialised tick between them exactly as v4's own swap loop
/// does. Each call stays inside a single constant-`L` range, so the closed form
/// stays exact everywhere it is used.
///
/// What makes that safe to do approximately is `fillRatio` below: the walk only
/// has to choose a good *target*, and any discrepancy between the predicted and
/// realised trade is absorbed. A batch that crosses a tick now fills in one
/// settlement instead of several, and every order still receives the same price
/// and the same fill ratio, so I4 is untouched either way.
library Clearing {
    uint256 internal constant Q96 = 1 << 96;

    /// @dev Fill-ratio shortfall treated as a complete fill: one part in 1e12.
    /// Far below the tolerance any price assertion uses, so snapping to it
    /// cannot disturb uniform pricing.
    uint256 internal constant DUST_LAMBDA = Q96 / 1e12;

    /// @notice Pool state read at settlement time. See the I6 note above.
    struct PoolPoint {
        uint160 sqrtPriceX96;
        uint128 liquidity;
        /// @dev Sqrt price of the nearest initialised tick at or below the
        /// current one — the lower edge of the constant-liquidity range.
        uint160 lowerSqrtPriceX96;
        /// @dev Sqrt price of the next initialised tick above the current one.
        uint160 upperSqrtPriceX96;
        /// @dev DD-5 residual cap: the most input this settlement may push
        /// through the curve in this range. Zero means uncapped.
        ///
        /// This is settlement-time state — it is derived from the pool's own
        /// liquidity and price at settlement plus a governance constant — so it
        /// carries no submission-time information and I6 is untouched. See
        /// `KesselHook._residualCap` for the derivation.
        uint256 maxResidualIn;
    }

    /// @notice A solved batch.
    struct Solution {
        /// @dev False when there is nothing to do, or nothing that can be done
        /// safely. A settlement must treat this as a no-op, never as an error
        /// (PRD §11 case 1).
        bool feasible;
        /// @dev Target sqrt price for the residual swap, already clamped into
        /// the current liquidity range.
        uint160 sqrtPriceTargetX96;
        /// @dev Direction of the residual swap. Meaningless if `residualIn` is
        /// zero (a perfectly matched batch touches the curve not at all).
        bool zeroForOne;
        /// @dev Exact-input amount for the residual swap.
        uint256 residualIn;
        /// @dev What the pool would pay out for `residualIn` over this range.
        /// Only meaningful within one constant-liquidity range, which is the
        /// only place `solve` is ever called. The multi-range driver uses it to
        /// work out how much of the batch a single range absorbs, by feeding
        /// the pair straight into `fillRatio`.
        uint256 residualOut;
        /// @dev Predicted uniform clearing price, Q96, currency1-per-currency0.
        /// Used for the eligibility test only; the *payouts* are computed from
        /// what the pool actually returned, so rounding can never make the hook
        /// insolvent.
        uint160 priceX96;
        /// @dev True when the tick-range clamp bound, i.e. this batch can only
        /// be partially filled this epoch.
        bool clamped;
    }

    /// @notice Solve a batch: netting, residual and uniform price together.
    ///
    /// @param p Settlement-time pool state.
    /// @param net0 Aggregate net-of-fee currency0 input across eligible orders.
    /// @param net1 Aggregate net-of-fee currency1 input across eligible orders.
    function solve(
        PoolPoint memory p,
        uint256 net0,
        uint256 net1
    ) internal pure returns (Solution memory s) {
        if (net0 == 0 && net1 == 0) return s; // infeasible: empty batch, no-op.

        uint160 a = p.sqrtPriceX96;

        // ---- Degenerate pool: no active liquidity -------------------------
        // The only feasible clearing is the pure coincidence-of-wants price,
        // and it exists only if both sides are present. A one-sided batch
        // against zero liquidity has no counterparty and must wait.
        if (p.liquidity == 0) {
            if (net0 == 0 || net1 == 0) return s;
            s.feasible = true;
            s.sqrtPriceTargetX96 = a;
            s.priceX96 = _toUint160(FullMath.mulDiv(net1, Q96, net0));
            return s; // residualIn stays 0: the curve is not touched.
        }

        // ---- Closed form --------------------------------------------------
        // b = Q96 * (L*a/Q96 + N1) / (L + N0*a/Q96)
        //
        // Factored through Q96 so no intermediate exceeds 2**192: with
        // `a <= 2**160` the real sqrt price is at most 2**64, so both `la` and
        // `n0a` are bounded by 2**128 * 2**64.
        uint256 la = FullMath.mulDiv(p.liquidity, a, Q96);
        uint256 n0a = FullMath.mulDiv(net0, a, Q96);

        uint256 denominator = uint256(p.liquidity) + n0a;
        if (denominator == 0) return s;

        uint256 bRaw = FullMath.mulDiv(la + net1, Q96, denominator);

        // ---- Clamp into the active liquidity range ------------------------
        // `L` is constant across this range, so the closed form above is exact
        // inside it. Outside it the formula would be solving with the wrong
        // liquidity, so the batch is partially filled instead (DD-11).
        uint160 b;
        if (bRaw < p.lowerSqrtPriceX96) {
            b = p.lowerSqrtPriceX96;
            s.clamped = true;
        } else if (bRaw > p.upperSqrtPriceX96) {
            b = p.upperSqrtPriceX96;
            s.clamped = true;
        } else {
            b = uint160(bRaw);
        }

        // ---- Clamp to the DD-5 residual cap --------------------------------
        // The sandwich the settlement residual is exposed to extracts an amount
        // LINEAR in the residual and linear in the attacker's own size, against
        // a cost (`f_base` on two legs) that is also linear in the attacker's
        // size. The attacker's size therefore cancels: whether the attack pays
        // is decided by the residual alone. Bounding the residual bounds the
        // attack unconditionally — at every attacker size, every `k`, and every
        // amount of slack traders leave in their limits.
        //
        // Expressed as a price bound rather than an amount so that everything
        // downstream — `residualIn`, `residualOut`, `priceX96`, `clamped` — is
        // recomputed consistently from the same `b`, exactly as the liquidity
        // clamp above already is. The remainder rolls through the partial-fill
        // path that DD-11 already built and SR-1 already made safe.
        if (p.maxResidualIn != 0) {
            uint160 bCap = SqrtPriceMath.getNextSqrtPriceFromInput(a, p.liquidity, p.maxResidualIn, bRaw < a);
            if (bRaw < a ? b < bCap : b > bCap) {
                b = bCap;
                s.clamped = true;
            }
        }

        // v4 requires a strict inequality against the price limit, so a target
        // sitting exactly on a global bound cannot be used as one.
        if (b <= TickMath.MIN_SQRT_PRICE) b = TickMath.MIN_SQRT_PRICE + 1;
        if (b >= TickMath.MAX_SQRT_PRICE) b = TickMath.MAX_SQRT_PRICE - 1;

        s.sqrtPriceTargetX96 = b;
        s.priceX96 = _toUint160(FullMath.mulDiv(a, b, Q96));
        if (s.priceX96 == 0) return s; // price underflowed to zero: unusable.

        // ---- Residual ------------------------------------------------------
        // Rounded DOWN in both directions: the hook must never commit more
        // input to the pool than the price target justifies. Any shortfall is
        // absorbed by `lambda`, which is derived from what actually executed.
        //
        // The output side is rounded down for the same reason in reverse: it
        // is only ever used to *size* how much of the batch a range absorbs,
        // and under-stating it under-states the absorption, which costs a
        // partial fill rather than solvency.
        if (b < a) {
            s.zeroForOne = true;
            s.residualIn = SqrtPriceMath.getAmount0Delta(b, a, p.liquidity, false);
            s.residualOut = SqrtPriceMath.getAmount1Delta(b, a, p.liquidity, false);
        } else if (b > a) {
            s.zeroForOne = false;
            s.residualIn = SqrtPriceMath.getAmount1Delta(a, b, p.liquidity, false);
            s.residualOut = SqrtPriceMath.getAmount0Delta(a, b, p.liquidity, false);
        }
        // b == a: perfectly matched batch, residualIn stays 0.

        // A clamp that leaves no room at all is degenerate: the batch needed
        // the curve, and the curve cannot be moved. Filling here would consume
        // trader input against a zero-size residual and pay out nothing, so
        // report infeasible and let the batch roll instead.
        //
        // This is reachable in ordinary operation, not just in theory: the
        // active range is bounded by a bitmap-word edge when no initialised
        // tick is nearer, and a pool sitting exactly on such an edge has zero
        // room in one direction.
        if (s.residualIn == 0 && s.clamped) return s;

        s.feasible = true;
    }

    /// @notice The fill ratio implied by a residual that actually executed.
    ///
    /// @dev This is the load-bearing safety property of the whole design, so it
    /// is worth stating precisely.
    ///
    /// For ANY amounts `(X, Y)` the pool actually returns, filling each side at
    /// ratio
    ///
    ///     lambda = X * Y / (N_in * Y - N_out * X)
    ///
    /// makes the batch *exactly* uniform-priced and *exactly* solvent. Proof:
    /// the two implied side prices are `(lambda*N_out + Y) / (lambda*N_in)` and
    /// `lambda*N_out / (lambda*N_in - X)`; setting them equal and solving for
    /// lambda yields precisely the expression above.
    ///
    /// The consequence is that the closed form in `solve` only has to pick a
    /// good *target*. If the realised trade differs from the prediction for any
    /// reason -- rounding, a clamp, an unexpected liquidity profile -- the fill
    /// ratio absorbs the difference and I2/I4 still hold exactly. Solvency does
    /// not depend on the prediction being right.
    ///
    /// @param netIn Aggregate net-of-fee input on the side that is paying the
    /// pool (currency0 if `zeroForOne`).
    /// @param netOut Aggregate net-of-fee input on the other side.
    /// @param amountIn Input the pool actually took (`X`).
    /// @param amountOut Output the pool actually gave (`Y`).
    /// @return lambdaX96 Fill ratio in Q96, capped at 1.
    function fillRatio(
        uint256 netIn,
        uint256 netOut,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (uint256 lambdaX96) {
        // No residual: the batch matched entirely against itself, so it fills
        // completely.
        if (amountIn == 0 || amountOut == 0) return Q96;

        // Algebraically this is `X*Y / (N_in*Y - N_out*X)`, but it is evaluated
        // as `X / (N_in - N_out*X/Y)` — the same quantity with `Y` divided out
        // of both halves. That form is used deliberately, for two reasons:
        //
        //  * `N_in * Y` overflows a uint256 for large-but-legal inputs, and
        //  * evaluating the direct form needs a Q96 scale factor applied to a
        //    three-way product, which forces an intermediate that keeps only a
        //    handful of significant digits.
        //
        // This form needs exactly two divisions, each a single `mulDiv`, and is
        // accurate to one ulp.
        uint256 covered = FullMath.mulDiv(netOut, amountIn, amountOut); // N_out * X / Y

        // `netIn <= covered` means the counter-side alone more than covers the
        // residual, contradicting the residual's own direction. Refuse rather
        // than return a nonsense ratio.
        if (netIn <= covered) return 0;

        // Rounded UP deliberately. The paying side must commit at least as much
        // as the pool actually took, or its pot would be short by a wei and the
        // settlement would have to make the difference up out of the fee. One
        // ulp of extra fill is harmless; one ulp of shortfall is an accounting
        // hole.
        lambdaX96 = FullMath.mulDivRoundingUp(amountIn, Q96, netIn - covered);

        if (lambdaX96 > Q96) lambdaX96 = Q96;
        // Snap a fill that is within a part-per-trillion of complete up to
        // exactly complete. The residual is derived from a sqrt-price delta, so
        // a one-sided batch typically comes back a wei or two short of its own
        // own total; without this, such orders would sit at 99.99...% filled
        // forever and never reach a terminal state.
        //
        // Restricted to `netOut == 0` on purpose. With no counter-side there is
        // no second price for the snap to disagree with, so I4 is untouched.
        // Applying it to a two-sided batch would not be safe: the counter-side's
        // pot is `filled - amountIn`, a difference of two large numbers, so a
        // change of 1e-12 of the batch can be an arbitrarily large *relative*
        // change to that pot — and the two sides would then clear at visibly
        // different prices.
        else if (netOut == 0 && Q96 - lambdaX96 <= DUST_LAMBDA) lambdaX96 = Q96;
    }

    /// @notice Uniform price implied by a side's pot and its filled input.
    /// @dev `pot / filled`, in Q96. This is the price traders actually receive,
    /// computed from tokens the hook demonstrably holds, which is why payouts
    /// can never exceed custody.
    function impliedPriceX96(
        uint256 pot,
        uint256 filledNetIn
    ) internal pure returns (uint256) {
        if (filledNetIn == 0) return 0;
        return FullMath.mulDiv(pot, Q96, filledNetIn);
    }

    /// @notice Does a uniform price satisfy an order's limit?
    /// @param zeroForOne Direction of the order.
    /// @param limitPriceX96 Floor (zeroForOne) or ceiling (oneForZero).
    /// @param effectivePriceX96 The price the trader would actually realise,
    /// already net of `f_slow`.
    function meetsLimit(
        bool zeroForOne,
        uint160 limitPriceX96,
        uint256 effectivePriceX96
    ) internal pure returns (bool) {
        return zeroForOne ? effectivePriceX96 >= limitPriceX96 : effectivePriceX96 <= limitPriceX96;
    }

    function _toUint160(
        uint256 x
    ) private pure returns (uint160) {
        return x > type(uint160).max ? type(uint160).max : uint160(x);
    }
}
