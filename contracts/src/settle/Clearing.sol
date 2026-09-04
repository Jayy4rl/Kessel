// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

library Clearing {
    uint256 internal constant Q96 = 1 << 96;

    uint256 internal constant DUST_LAMBDA = Q96 / 1e12;

    struct PoolPoint {
        uint160 sqrtPriceX96;
        uint128 liquidity;

        uint160 lowerSqrtPriceX96;
        uint160 upperSqrtPriceX96;

        uint256 maxResidualIn;
    }

    struct Solution {


        bool feasible;

        uint160 sqrtPriceTargetX96;

        bool zeroForOne;
        uint256 residualIn;

        uint256 residualOut;

        uint160 priceX96;

        bool clamped;
    }

    function solve(
        PoolPoint memory p,
        uint256 net0,
        uint256 net1
    ) internal pure returns (Solution memory s) {
        if (net0 == 0 && net1 == 0) return s; // infeasible: empty batch, no-op.

        uint160 a = p.sqrtPriceX96;

        if (p.liquidity == 0) {
            if (net0 == 0 || net1 == 0) return s;
            s.feasible = true;
            s.sqrtPriceTargetX96 = a;
            s.priceX96 = _toUint160(FullMath.mulDiv(net1, Q96, net0));
            return s; // residualIn stays 0: the curve is not touched.
        }

        uint256 la = FullMath.mulDiv(p.liquidity, a, Q96);
        uint256 n0a = FullMath.mulDiv(net0, a, Q96);

        uint256 denominator = uint256(p.liquidity) + n0a;
        if (denominator == 0) return s;

        uint256 bRaw = FullMath.mulDiv(la + net1, Q96, denominator);

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

        if (p.maxResidualIn != 0) {
            uint160 bCap = SqrtPriceMath.getNextSqrtPriceFromInput(a, p.liquidity, p.maxResidualIn, bRaw < a);
            if (bRaw < a ? b < bCap : b > bCap) {
                b = bCap;
                s.clamped = true;
            }
        }

        if (b <= TickMath.MIN_SQRT_PRICE) b = TickMath.MIN_SQRT_PRICE + 1;
        if (b >= TickMath.MAX_SQRT_PRICE) b = TickMath.MAX_SQRT_PRICE - 1;

        s.sqrtPriceTargetX96 = b;
        s.priceX96 = _toUint160(FullMath.mulDiv(a, b, Q96));
        if (s.priceX96 == 0) return s; // price underflowed to zero: unusable.

        if (b < a) {
            s.zeroForOne = true;
            s.residualIn = SqrtPriceMath.getAmount0Delta(b, a, p.liquidity, false);
            s.residualOut = SqrtPriceMath.getAmount1Delta(b, a, p.liquidity, false);
        } else if (b > a) {
            s.zeroForOne = false;
            s.residualIn = SqrtPriceMath.getAmount1Delta(a, b, p.liquidity, false);
            s.residualOut = SqrtPriceMath.getAmount0Delta(a, b, p.liquidity, false);
        }

        if (s.residualIn == 0 && s.clamped) return s;

        s.feasible = true;
    }

    function fillRatio(
        uint256 netIn,
        uint256 netOut,
        uint256 amountIn,
        uint256 amountOut
    ) internal pure returns (uint256 lambdaX96) {
        if (amountIn == 0 || amountOut == 0) return Q96;

        uint256 covered = FullMath.mulDiv(netOut, amountIn, amountOut); // N_out * X / Y

        if (netIn <= covered) return 0;

        lambdaX96 = FullMath.mulDivRoundingUp(amountIn, Q96, netIn - covered);

        if (lambdaX96 > Q96) lambdaX96 = Q96;
        else if (netOut == 0 && Q96 - lambdaX96 <= DUST_LAMBDA) lambdaX96 = Q96;
    }

    function impliedPriceX96(
        uint256 pot,
        uint256 filledNetIn
    ) internal pure returns (uint256) {
        if (filledNetIn == 0) return 0;
        return FullMath.mulDiv(pot, Q96, filledNetIn);
    }

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
