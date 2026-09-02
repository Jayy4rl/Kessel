// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Clearing} from "./Clearing.sol";
import {TickScan} from "./TickScan.sol";

/// @notice Sizes the settlement residual and predicts the batch's uniform
/// price.
///
/// @dev Deployed as its own contract and reached by DELEGATECALL. It reads pool
/// state and takes governance parameters as arguments; it touches no hook
/// storage and writes nothing. That makes it freely separable, and separating
/// it is what keeps the hook under EIP-170: the closed-form solver drags
/// `Clearing.solve`, `TickMath`, `SqrtPriceMath` and the tick-bitmap search in
/// with it, and together those are the densest arithmetic in the protocol.
///
/// Every function is `view` or `pure` and the only pool state any of them sees
/// is read at *settlement* time, so no submission-time value can reach a price.
library BatchSolver {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Consecutive constant-liquidity ranges one settlement may walk.
    /// Bounds gas, never correctness: stopping early yields a smaller fill and
    /// the remainder rolls.
    uint256 internal constant MAX_CLEARING_RANGES = 4;

    /// @dev Bundled to keep the walk within the EVM stack limit.
    struct Params {
        IPoolManager poolManager;
        PoolId poolId;
        int24 tickSpacing;
        uint24 fBase;
        uint16 residualCapBps;
    }

    /// @dev Mutable state carried across the walk. A struct rather than loose
    /// locals for the same reason `Params` is one: the walk otherwise exceeds
    /// the EVM stack limit under the non-`via_ir` dev profile.
    struct Walk {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 rem0;
        uint256 rem1;
        uint256 capBudget;
    }

    /// @notice Solve the batch across up to `MAX_CLEARING_RANGES` consecutive
    /// constant-liquidity ranges.
    ///
    /// @dev `Clearing.solve` is exact only inside one range, because the closed
    /// form assumes constant `L`. This walks instead: each iteration calls
    /// `solve` with that range's own liquidity and whatever of the batch is
    /// still unfilled, then crosses the boundary tick as v4's own swap loop
    /// does. Every `solve` call therefore still sees a single constant-`L`
    /// range and stays exact.
    ///
    /// The walk only has to produce a good *target*. `Clearing.fillRatio`
    /// derives the actual fill from what the pool really did, so an imprecise
    /// prediction costs a smaller fill, never solvency and never a non-uniform
    /// price. That is why an iterative approximation is admissible at all.
    ///
    /// The residual direction cannot flip between ranges: both sides of the
    /// batch scale by the same `lambda`, so a batch net-selling currency0 stays
    /// net-selling currency0 however much of it is consumed.
    function solveMultiRange(
        Params memory p,
        uint256 net0,
        uint256 net1
    ) public view returns (Clearing.Solution memory out) {
        Walk memory w;
        (w.sqrtPriceX96, w.tick,,) = p.poolManager.getSlot0(p.poolId);
        w.liquidity = p.poolManager.getLiquidity(p.poolId);
        w.rem0 = net0;
        w.rem1 = net1;

        // The residual cap bounds the TOTAL residual this settlement pushes
        // through the curve, so it is sized once against the depth at spot and
        // then spent down across the walk.
        {
            uint256 spotX96 = FullMath.mulDiv(w.sqrtPriceX96, w.sqrtPriceX96, Q96);
            bool residualZeroForOne = net1 < FullMath.mulDiv(net0, spotX96, Q96);
            w.capBudget = _residualCap(p, w.sqrtPriceX96, w.liquidity, residualZeroForOne);
        }

        for (uint256 r; r < MAX_CLEARING_RANGES; ++r) {
            (int24 lowerTick, int24 upperTick) =
                TickScan.activeRangeTicks(p.poolManager, p.poolId, w.tick, p.tickSpacing);

            Clearing.Solution memory seg = Clearing.solve(
                Clearing.PoolPoint({
                    sqrtPriceX96: w.sqrtPriceX96,
                    liquidity: w.liquidity,
                    lowerSqrtPriceX96: TickMath.getSqrtPriceAtTick(lowerTick),
                    upperSqrtPriceX96: TickMath.getSqrtPriceAtTick(upperTick),
                    maxResidualIn: w.capBudget
                }),
                w.rem0,
                w.rem1
            );

            // An infeasible range ends the walk. Anything already accumulated
            // stands: a partial answer is a valid target.
            if (!seg.feasible) break;

            out.feasible = true;
            out.zeroForOne = seg.zeroForOne;
            out.sqrtPriceTargetX96 = seg.sqrtPriceTargetX96;
            out.residualIn += seg.residualIn;
            out.residualOut += seg.residualOut;
            out.clamped = seg.clamped;

            // Unclamped: the whole remaining batch cleared inside this range,
            // which is the terminating case and the common one.
            if (!seg.clamped) break;

            // Clamped with nothing moving means the range had no room at all.
            if (seg.residualIn == 0 || seg.residualOut == 0) break;

            // The cap is a budget for the whole walk, not for each range.
            w.capBudget = w.capBudget > seg.residualIn ? w.capBudget - seg.residualIn : 0;
            if (w.capBudget == 0) break; // bound reached; the rest rolls.

            if (!_advance(w, seg)) break;

            // Cross the boundary.
            (w.liquidity, w.tick) = _cross(p, w.liquidity, seg.zeroForOne ? lowerTick : upperTick, seg.zeroForOne);
            if (w.liquidity == 0) break; // no depth beyond this tick

            w.sqrtPriceX96 = seg.sqrtPriceTargetX96;
        }

        if (!out.feasible) return out;
        out.priceX96 = _predictedPrice(out, net0, net1);
        if (out.priceX96 == 0) out.feasible = false;
    }

    /// @dev Consume this range's fill from the remaining batch.
    /// @return more True if any batch remains for a further range to absorb.
    function _advance(
        Walk memory w,
        Clearing.Solution memory seg
    ) private pure returns (bool more) {
        uint256 lambda = seg.zeroForOne
            ? Clearing.fillRatio(w.rem0, w.rem1, seg.residualIn, seg.residualOut)
            : Clearing.fillRatio(w.rem1, w.rem0, seg.residualIn, seg.residualOut);
        // `0` is an inconsistent fill and `Q96` is a complete one; neither
        // leaves a remainder for a further range to absorb.
        if (lambda == 0 || lambda >= Q96) return false;

        w.rem0 -= FullMath.mulDiv(w.rem0, lambda, Q96);
        w.rem1 -= FullMath.mulDiv(w.rem1, lambda, Q96);
        return !(w.rem0 == 0 && w.rem1 == 0);
    }

    /// @dev Step across an initialised tick, as v4's own swap loop does.
    ///
    /// An uninitialised tick — which is what a bitmap-word edge is — reports a
    /// zero `liquidityNet`, so this correctly leaves liquidity untouched and
    /// simply continues the scan from further along.
    ///
    /// Split out to keep `solveMultiRange` within the EVM stack limit under the
    /// non-`via_ir` dev profile.
    function _cross(
        Params memory p,
        uint128 liquidity,
        int24 crossed,
        bool zeroForOne
    ) private view returns (uint128, int24) {
        (, int128 liquidityNet) = p.poolManager.getTickLiquidity(p.poolId, crossed);
        if (zeroForOne) liquidityNet = -liquidityNet;
        return (LiquidityMath.addDelta(liquidity, liquidityNet), zeroForOne ? crossed - 1 : crossed);
    }

    /// @dev The largest residual this settlement may push through the curve, in
    /// the residual's own input currency.
    ///
    /// Sandwiching the settlement residual extracts an amount linear in the
    /// residual `R` and linear in the attacker's size `A`, against a cost
    /// (`f_base` on two legs) that is also linear in `A`. **`A` cancels**, so
    /// whether the attack pays is decided by the residual alone:
    ///
    ///     unprofitable   <=>   R  <=  f_base * x
    ///
    /// where `x` is the pool's virtual reserve of the residual's input
    /// currency. `residualCapBps` is the fraction of that break-even the
    /// protocol allows, and its deploy-fixed ceiling is exactly break-even —
    /// so no reachable governance setting can place the cap where sandwiching
    /// turns a profit. The bound cannot be switched off.
    ///
    /// The cap constrains only the *un-netted* part of a batch; extraction on
    /// the coincidence-of-wants portion is exactly zero, so netting is left
    /// unconstrained.
    function _residualCap(
        Params memory p,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        bool zeroForOne
    ) private pure returns (uint256) {
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0; // uncapped: nothing to trade against

        // Virtual reserve of the residual's INPUT currency:
        //   currency0 (zeroForOne):  x = L / sqrtP  =  L * Q96 / sqrtPriceX96
        //   currency1 (oneForZero):  y = L * sqrtP  =  L * sqrtPriceX96 / Q96
        uint256 reserve =
            zeroForOne ? FullMath.mulDiv(liquidity, Q96, sqrtPriceX96) : FullMath.mulDiv(liquidity, sqrtPriceX96, Q96);

        uint256 cap = FullMath.mulDiv(reserve, uint256(p.fBase) * p.residualCapBps, FEE_DENOMINATOR * BPS_DENOMINATOR);

        // A cap of zero would read as "uncapped" downstream. One wei is the
        // correct floor: it caps hard without ever disabling the bound.
        return cap == 0 ? 1 : cap;
    }

    /// @dev The uniform price the walk predicts, taken from the residual itself.
    ///
    /// `a * b` is the average price of a move within *one* constant-liquidity
    /// range and is not the average once the walk has crossed a tick, so the
    /// price has to come from the trade the walk actually sized:
    ///
    ///   zeroForOne residual:  P = residualOut / residualIn   (pool pays c1)
    ///   oneForZero residual:  P = residualIn  / residualOut  (pool takes c1)
    ///
    /// This is exact for any number of ranges AND any fill ratio, which is the
    /// property that matters — the totals identity it replaced held only at a
    /// fill ratio of one, and understated the price for a clamped batch in
    /// exactly the unsafe direction, admitting orders the realised price did
    /// not satisfy.
    ///
    /// A prediction used for the eligibility test only. Payouts are computed
    /// from what the pool actually returned, so a prediction a few wei off
    /// costs an order its place in this batch at worst, never solvency.
    function _predictedPrice(
        Clearing.Solution memory out,
        uint256 net0,
        uint256 net1
    ) private pure returns (uint160) {
        // A perfectly matched batch never touches the curve, so the totals
        // identity degenerates. Its price is the coincidence-of-wants price.
        if (out.residualIn == 0) {
            if (net0 == 0) return 0;
            return _toUint160(FullMath.mulDiv(net1, Q96, net0));
        }

        // A residual that moves in one direction only cannot imply a price.
        if (out.residualOut == 0) return 0;

        if (out.zeroForOne) {
            return _toUint160(FullMath.mulDiv(out.residualOut, Q96, out.residualIn));
        }
        return _toUint160(FullMath.mulDiv(out.residualIn, Q96, out.residualOut));
    }

    function _toUint160(
        uint256 x
    ) private pure returns (uint160) {
        return x > type(uint160).max ? type(uint160).max : uint160(x);
    }
}
