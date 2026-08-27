// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";

import {Clearing} from "../../src/settle/Clearing.sol";

/// @notice Properties of the Slow-Lane clearing price (DD-5, PRD §4.3).
///
/// These are the tests that make the closed form trustworthy. Everything else
/// in settlement is bookkeeping around this arithmetic, so it is checked
/// against v4's own `SqrtPriceMath` rather than against a restatement of the
/// same algebra.
///
/// Invariants covered here: I4 (uniform price), I6 (structurally — see the note
/// on the `solve` signature) and the solvency half of I2.
contract ClearingPropertiesTest is Test {
    uint256 internal constant Q96 = 1 << 96;

    /// @dev Models a pool holding one wide position centred on the current
    /// price: liquidity is constant over +/-6000 ticks (~+/-82%), which is what
    /// `_activeRangeBounds` reports for such a pool. Centring on the current
    /// tick matters — a fixed range would put the price outside its own
    /// liquidity whenever the fuzzer picks a distant tick, and every solve
    /// would then clamp for a reason that has nothing to do with the property
    /// under test. The clamped case is exercised separately.
    function _point(
        uint160 sqrtPriceX96,
        uint128 liquidity
    ) internal pure returns (Clearing.PoolPoint memory) {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        return Clearing.PoolPoint({
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity,
            lowerSqrtPriceX96: TickMath.getSqrtPriceAtTick(tick - 6000),
            upperSqrtPriceX96: TickMath.getSqrtPriceAtTick(tick + 6000)
        });
    }

    /// @dev A deliberately narrow range, to exercise the DD-11 clamp.
    function _narrowPoint(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    ) internal pure returns (Clearing.PoolPoint memory) {
        return Clearing.PoolPoint({
            sqrtPriceX96: sqrtPriceX96,
            liquidity: liquidity,
            lowerSqrtPriceX96: TickMath.getSqrtPriceAtTick(tick - 60),
            upperSqrtPriceX96: TickMath.getSqrtPriceAtTick(tick + 60)
        });
    }

    // ======================================================================
    // The defining property: the residual's average price IS the clearing price
    // ======================================================================

    /// @notice For an unclamped solve, the price the pool actually transacts at
    /// equals the price every order clears at.
    ///
    /// @dev This is the whole point of DD-5. If it fails, the batch is either
    /// insolvent (pool paid less than traders are owed) or is skimming an
    /// undisclosed implicit fee from traders (pool paid more). Checked against
    /// v4's own delta math, not against a re-derivation of the closed form.
    function testFuzz_residualAveragePriceEqualsClearingPrice(
        uint128 liquidity,
        uint128 net0,
        uint128 net1,
        uint8 tickSeed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e15, 1e24));
        net0 = uint128(bound(net0, 0, 1e18));
        net1 = uint128(bound(net1, 0, 1e18));

        int24 tick = int24(int256(uint256(tickSeed))) * 60 - 3000;
        uint160 a = TickMath.getSqrtPriceAtTick(tick);

        Clearing.Solution memory s = Clearing.solve(_point(a, liquidity), net0, net1);
        vm.assume(s.feasible);
        vm.assume(!s.clamped); // the clamped case is covered separately
        vm.assume(s.residualIn > 1e12); // below this, v4 delta rounding dominates

        uint160 b = s.sqrtPriceTargetX96;

        uint256 amountIn;
        uint256 amountOut;
        if (s.zeroForOne) {
            amountIn = SqrtPriceMath.getAmount0Delta(b, a, liquidity, false);
            amountOut = SqrtPriceMath.getAmount1Delta(b, a, liquidity, false);
        } else {
            amountIn = SqrtPriceMath.getAmount1Delta(a, b, liquidity, false);
            amountOut = SqrtPriceMath.getAmount0Delta(a, b, liquidity, false);
        }
        vm.assume(amountIn > 0 && amountOut > 0);

        // Average price of the residual, as currency1-per-currency0.
        uint256 avgX96 =
            s.zeroForOne ? FullMath.mulDiv(amountOut, Q96, amountIn) : FullMath.mulDiv(amountIn, Q96, amountOut);

        _assertRelClose(avgX96, s.priceX96, 1e9, "residual average price != clearing price");
    }

    /// @notice The self-funding identity: the pool supplies exactly the batch's
    /// imbalance, no more and no less.
    ///
    /// @dev `X == N0 - N1/P` and `Y == N0*P - N1`. Together these are what make
    /// the hook exactly solvent with zero residue (I2), which is the reason
    /// DD-5 uses the average price rather than the post-residual marginal price.
    function testFuzz_poolSuppliesExactlyTheImbalance(
        uint128 liquidity,
        uint128 net0,
        uint128 net1,
        uint8 tickSeed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e18, 1e24));
        net0 = uint128(bound(net0, 1e12, 1e18));
        net1 = uint128(bound(net1, 1e12, 1e18));

        int24 tick = int24(int256(uint256(tickSeed))) * 60 - 3000;
        uint160 a = TickMath.getSqrtPriceAtTick(tick);

        Clearing.Solution memory s = Clearing.solve(_point(a, liquidity), net0, net1);
        vm.assume(s.feasible && !s.clamped && s.residualIn > 1e12);

        uint256 p = s.priceX96;

        if (s.zeroForOne) {
            // Pool takes currency0: X == N0 - N1/P.
            uint256 expectedIn = net0 - FullMath.mulDiv(net1, Q96, p);
            _assertRelClose(s.residualIn, expectedIn, 1e10, "residual in != N0 - N1/P");
        } else {
            // Pool takes currency1: X == N1 - N0*P.
            uint256 expectedIn = net1 - FullMath.mulDiv(net0, p, Q96);
            _assertRelClose(s.residualIn, expectedIn, 1e10, "residual in != N1 - N0*P");
        }
    }

    // ======================================================================
    // Coincidence of wants
    // ======================================================================

    /// @notice A perfectly matched batch does not touch the curve at all, and
    /// the whole batch clears at spot.
    ///
    /// @dev This is the FM-AMM ideal, and it is not special-cased anywhere in
    /// the code — it falls out of the closed form. A regression here means the
    /// netting has silently started routing matched flow through the pool and
    /// charging it price impact it should never pay.
    function testFuzz_perfectlyMatchedBatchLeavesPoolUntouched(
        uint128 liquidity,
        uint128 net0,
        uint8 tickSeed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e18, 1e24));
        net0 = uint128(bound(net0, 1e12, 1e18));

        int24 tick = int24(int256(uint256(tickSeed))) * 60 - 3000;
        uint160 a = TickMath.getSqrtPriceAtTick(tick);

        // N1 chosen to exactly match N0 at the spot price.
        uint256 spotX96 = FullMath.mulDiv(a, a, Q96);
        uint256 net1 = FullMath.mulDiv(net0, spotX96, Q96);
        vm.assume(net1 > 0 && net1 <= type(uint128).max);

        Clearing.Solution memory s = Clearing.solve(_point(a, liquidity), net0, uint128(net1));
        assertTrue(s.feasible, "matched batch should be feasible");

        // The pool price does not move, and the residual is at most rounding
        // dust. `net1` is a floored product, so the match is exact only when
        // the spot price is representable without truncation — see the
        // companion test below for the exactly-matched case.
        _assertRelClose(s.sqrtPriceTargetX96, a, 1e12, "matched batch moved the pool");
        assertLe(s.residualIn, net0 / 1e12 + 2, "matched batch executed a non-dust residual");
        _assertRelClose(s.priceX96, spotX96, 1e12, "matched batch did not clear at spot");
    }

    /// @notice At a spot price of exactly 1, an exactly matched batch touches
    /// the curve not at all — zero residual, not dust.
    ///
    /// @dev The fuzz test above can only assert a dust bound, because it derives
    /// `net1` through a floored multiplication. Here the match is exact, so the
    /// strongest form of the coincidence-of-wants property is available and is
    /// worth pinning: matched flow pays no price impact whatsoever.
    function testFuzz_exactlyMatchedBatchExecutesNoResidual(
        uint128 liquidity,
        uint128 net
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e18, 1e24));
        net = uint128(bound(net, 1e12, 1e24));

        uint160 a = TickMath.getSqrtPriceAtTick(0); // spot == 1 exactly
        Clearing.Solution memory s = Clearing.solve(_point(a, liquidity), net, net);

        assertTrue(s.feasible, "matched batch should be feasible");
        assertEq(s.residualIn, 0, "exactly matched batch touched the curve");
        assertEq(s.sqrtPriceTargetX96, a, "exactly matched batch moved the pool");
        assertEq(s.priceX96, Q96, "exactly matched batch did not clear at spot");
    }

    /// @notice An empty batch is a no-op, never a revert (PRD §11 case 1).
    function test_emptyBatchIsInfeasibleNotReverting() public pure {
        Clearing.Solution memory s = Clearing.solve(_point(TickMath.getSqrtPriceAtTick(0), 1e20), 0, 0);
        assertFalse(s.feasible, "empty batch must be a no-op");
    }

    /// @notice With no active liquidity the only feasible price is the pure
    /// coincidence-of-wants price, and a one-sided batch simply waits.
    function test_zeroLiquidityClearsAtCoWPriceOrWaits() public pure {
        uint160 a = TickMath.getSqrtPriceAtTick(0);

        Clearing.Solution memory both = Clearing.solve(_point(a, 0), 100e18, 250e18);
        assertTrue(both.feasible, "two-sided batch should clear against itself");
        assertEq(both.residualIn, 0, "no liquidity means no residual is possible");
        _assertRelClose(both.priceX96, FullMath.mulDiv(250e18, Q96, 100e18), 1e12, "not the CoW price");

        Clearing.Solution memory oneSided = Clearing.solve(_point(a, 0), 100e18, 0);
        assertFalse(oneSided.feasible, "one-sided batch has no counterparty at zero liquidity");
    }

    // ======================================================================
    // Direction and monotonicity
    // ======================================================================

    /// @notice A one-sided batch reduces to an ordinary exact-input swap: the
    /// whole net input is the residual.
    function testFuzz_oneSidedBatchIsAnOrdinarySwap(
        uint128 liquidity,
        uint128 net0
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e18, 1e24));
        net0 = uint128(bound(net0, 1e12, 1e17));

        uint160 a = TickMath.getSqrtPriceAtTick(0);
        Clearing.Solution memory s = Clearing.solve(_point(a, liquidity), net0, 0);
        vm.assume(s.feasible && !s.clamped);

        assertTrue(s.zeroForOne, "selling currency0 must move the pool zeroForOne");
        assertLt(s.sqrtPriceTargetX96, a, "selling currency0 must lower the price");
        _assertRelClose(s.residualIn, net0, 1e10, "one-sided residual != full net input");
    }

    /// @notice Selling more currency0 always clears at a weakly worse price for
    /// the currency0 sellers. A violation would mean a trader could improve
    /// their own fill by enlarging the batch.
    function testFuzz_moreSellPressureNeverRaisesThePrice(
        uint128 liquidity,
        uint128 netA,
        uint128 netB
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e18, 1e24));
        netA = uint128(bound(netA, 1e12, 1e17));
        netB = uint128(bound(netB, 1e12, 1e17));
        (uint128 small, uint128 large) = netA < netB ? (netA, netB) : (netB, netA);
        vm.assume(small < large);

        uint160 a = TickMath.getSqrtPriceAtTick(0);
        Clearing.Solution memory sSmall = Clearing.solve(_point(a, liquidity), small, 0);
        Clearing.Solution memory sLarge = Clearing.solve(_point(a, liquidity), large, 0);
        vm.assume(sSmall.feasible && sLarge.feasible && !sSmall.clamped && !sLarge.clamped);

        assertLe(sLarge.priceX96, sSmall.priceX96, "a larger sell batch cleared at a better price");
    }

    // ======================================================================
    // The fill ratio's safety property
    // ======================================================================

    /// @notice For ANY realised `(X, Y)`, the derived fill ratio makes both
    /// sides' implied prices agree.
    ///
    /// @dev This is what makes solvency independent of the closed form being
    /// right. `solve` only picks a target; if the pool does something else --
    /// rounding, a clamp, an unexpected liquidity profile -- `fillRatio`
    /// absorbs it and I4/I2 still hold exactly. Fuzzed over arbitrary `(X, Y)`
    /// precisely because it must not depend on `solve`.
    function testFuzz_fillRatioMakesBothSidesAgree(
        uint128 netIn,
        uint128 netOut,
        uint96 priceSeed,
        uint16 drift
    ) public pure {
        netIn = uint128(bound(netIn, 1e18, 1e24));
        netOut = uint128(bound(netOut, 1e18, 1e24));

        // Parameterise the way a real batch is shaped — two sides and a price —
        // rather than fuzzing the pool's output freely. Free fuzzing spends
        // almost every candidate on configurations `fillRatio` correctly
        // refuses, and tests nothing.
        uint256 priceX96 = bound(priceSeed, Q96 / 1000, Q96 * 1000);
        uint256 covered = FullMath.mulDiv(netOut, Q96, priceX96);
        vm.assume(covered < netIn); // this side is the one paying the pool

        uint256 amountIn = netIn - covered;
        uint256 amountOut = FullMath.mulDiv(amountIn, priceX96, Q96);
        vm.assume(amountIn > 1e9 && amountOut > 1e9);

        // Now let the pool execute at something *other* than the predicted
        // price, by up to ~0.65%. This is the point of the test: the ratio must
        // reconcile the two sides for whatever actually happened, not only for
        // the case where the closed form was exactly right.
        amountOut = amountOut * (10_000 + uint256(drift % 65)) / 10_000;

        uint256 lambda = Clearing.fillRatio(netIn, netOut, amountIn, amountOut);
        vm.assume(lambda > 0);

        uint256 filledIn = FullMath.mulDiv(netIn, lambda, Q96);
        uint256 filledOut = FullMath.mulDiv(netOut, lambda, Q96);
        vm.assume(filledIn > amountIn && filledOut > 1e9);

        // Pot each side actually receives — exactly the tokens on hand.
        uint256 priceForInSide = FullMath.mulDiv(filledOut + amountOut, Q96, filledIn);
        uint256 priceForOutSide = FullMath.mulDiv(filledOut, Q96, filledIn - amountIn);

        _assertRelClose(priceForInSide, priceForOutSide, 1e9, "I4: the two sides received different prices");
    }

    /// @notice The fill ratio is never above one — the batch can never fill
    /// more than was submitted.
    function testFuzz_fillRatioNeverExceedsOne(
        uint128 netIn,
        uint128 netOut,
        uint128 amountIn,
        uint128 amountOut
    ) public pure {
        netIn = uint128(bound(netIn, 1, type(uint96).max));
        netOut = uint128(bound(netOut, 0, type(uint96).max));
        amountIn = uint128(bound(amountIn, 0, type(uint96).max));
        amountOut = uint128(bound(amountOut, 0, type(uint96).max));

        assertLe(Clearing.fillRatio(netIn, netOut, amountIn, amountOut), Q96, "fill ratio exceeded 100%");
    }

    // ======================================================================
    // I8 — the limit-price comparison
    // ======================================================================

    /// @notice A currency0 seller's limit is a floor; a currency1 seller's is a
    /// ceiling. Both are expressed in the same units so one batch price can be
    /// compared against every order (DD-11).
    function testFuzz_limitDirectionality(
        uint160 limit,
        uint160 price
    ) public pure {
        vm.assume(limit > 0 && price > 0);

        assertEq(Clearing.meetsLimit(true, limit, price), price >= limit, "zeroForOne limit is a floor");
        assertEq(Clearing.meetsLimit(false, limit, price), price <= limit, "oneForZero limit is a ceiling");
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    /// @dev Assert `a` and `b` agree to within one part in `precision`.
    function _assertRelClose(
        uint256 a,
        uint256 b,
        uint256 precision,
        string memory err
    ) internal pure {
        if (a == b) return;
        uint256 diff = a > b ? a - b : b - a;
        uint256 scale = a > b ? a : b;
        assertLe(diff * precision, scale, err);
    }
}
