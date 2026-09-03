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


library BatchSolver {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    
    uint256 internal constant MAX_CLEARING_RANGES = 4;

    struct Params {
        IPoolManager poolManager;
        PoolId poolId;
        int24 tickSpacing;
        uint24 fBase;
        uint16 residualCapBps;
    }

    
    struct Walk {
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
        uint256 rem0;
        uint256 rem1;
        uint256 capBudget;
    }

    
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

           
            if (!seg.feasible) break;

            out.feasible = true;
            out.zeroForOne = seg.zeroForOne;
            out.sqrtPriceTargetX96 = seg.sqrtPriceTargetX96;
            out.residualIn += seg.residualIn;
            out.residualOut += seg.residualOut;
            out.clamped = seg.clamped;

        
            if (!seg.clamped) break;

            if (seg.residualIn == 0 || seg.residualOut == 0) break;

            w.capBudget = w.capBudget > seg.residualIn ? w.capBudget - seg.residualIn : 0;
            if (w.capBudget == 0) break; // bound reached; the rest rolls.

            if (!_advance(w, seg)) break;

            (w.liquidity, w.tick) = _cross(p, w.liquidity, seg.zeroForOne ? lowerTick : upperTick, seg.zeroForOne);
            if (w.liquidity == 0) break; // no depth beyond this tick

            w.sqrtPriceX96 = seg.sqrtPriceTargetX96;
        }

        if (!out.feasible) return out;
        out.priceX96 = _predictedPrice(out, net0, net1);
        if (out.priceX96 == 0) out.feasible = false;
    }

    
    function _advance(
        Walk memory w,
        Clearing.Solution memory seg
    ) private pure returns (bool more) {
        uint256 lambda = seg.zeroForOne
            ? Clearing.fillRatio(w.rem0, w.rem1, seg.residualIn, seg.residualOut)
            : Clearing.fillRatio(w.rem1, w.rem0, seg.residualIn, seg.residualOut);
       
        if (lambda == 0 || lambda >= Q96) return false;

        w.rem0 -= FullMath.mulDiv(w.rem0, lambda, Q96);
        w.rem1 -= FullMath.mulDiv(w.rem1, lambda, Q96);
        return !(w.rem0 == 0 && w.rem1 == 0);
    }

    
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

    
    function _residualCap(
        Params memory p,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        bool zeroForOne
    ) private pure returns (uint256) {
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0; // uncapped: nothing to trade against

        uint256 reserve =
            zeroForOne ? FullMath.mulDiv(liquidity, Q96, sqrtPriceX96) : FullMath.mulDiv(liquidity, sqrtPriceX96, Q96);

        uint256 cap = FullMath.mulDiv(reserve, uint256(p.fBase) * p.residualCapBps, FEE_DENOMINATOR * BPS_DENOMINATOR);

        
        return cap == 0 ? 1 : cap;
    }

    
    function _predictedPrice(
        Clearing.Solution memory out,
        uint256 net0,
        uint256 net1
    ) private pure returns (uint160) {
      
        if (out.residualIn == 0) {
            if (net0 == 0) return 0;
            return _toUint160(FullMath.mulDiv(net1, Q96, net0));
        }

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
