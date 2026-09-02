// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {BatchSolver} from "../../src/settle/BatchSolver.sol";
import {Clearing} from "../../src/settle/Clearing.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice The degenerate paths through the multi-range walk.
///
/// `BatchSolver.solveMultiRange` is reached through settlement in the
/// integration suite, which exercises the ordinary case thoroughly but cannot
/// easily produce the states the walk guards against — an empty batch, a pool
/// with no active liquidity, a batch that nets out exactly. Those guards are
/// the difference between a settlement that rolls and one that consumes trader
/// input for nothing, so they are worth reaching deliberately.
///
/// The entry point is a `public` library function, so these call it directly
/// with hand-built pool state instead of trying to steer the hook into each
/// case. Same approach as `ClearingProperties`, one layer up.
contract BatchSolverPropertiesTest is KesselTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;

    /// @dev Defaults matching the hook's own, so the arithmetic under test is
    /// the arithmetic that ships.
    uint24 internal constant F_BASE = 3_000;
    uint16 internal constant RESIDUAL_CAP_BPS = 5_000;

    function setUp() public {
        _deployKessel(); // pool initialised, deliberately no liquidity yet
    }

    function _params() internal view returns (BatchSolver.Params memory) {
        return BatchSolver.Params({
            poolManager: manager,
            poolId: poolId,
            tickSpacing: TICK_SPACING,
            fBase: F_BASE,
            residualCapBps: RESIDUAL_CAP_BPS
        });
    }

    // ==================================================================
    // No active liquidity
    // ==================================================================

    /// @notice A one-sided batch against a pool with no liquidity has no
    /// counterparty and must not clear.
    ///
    /// @dev The alternative is filling against a curve that cannot move, which
    /// would consume the trader's input and pay out nothing.
    function test_aOneSidedBatchIsInfeasibleAgainstAnEmptyPool() public view {
        assertEq(manager.getLiquidity(poolId), 0, "setup: pool should have no liquidity");

        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), 1 ether, 0);
        assertFalse(s.feasible, "a one-sided batch cleared against zero liquidity");
    }

    /// @notice A two-sided batch clears against *itself* even with no
    /// liquidity, at the pure coincidence-of-wants price, touching no curve.
    function test_aTwoSidedBatchClearsAgainstItselfWithNoLiquidity() public view {
        uint256 net0 = 1 ether;
        uint256 net1 = 2 ether;

        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), net0, net1);

        assertTrue(s.feasible, "a two-sided batch should clear on its own");
        assertEq(s.residualIn, 0, "a pure CoW batch touched the curve");
        assertEq(s.priceX96, FullMath.mulDiv(net1, Q96, net0), "the CoW price is not net1/net0");
    }

    /// @notice With no liquidity and nothing on the currency0 side, no price
    /// exists to clear at.
    function test_noPriceExistsWithoutACurrency0Side() public view {
        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), 0, 1 ether);
        assertFalse(s.feasible, "a batch with no currency0 side produced a price");
    }

    // ==================================================================
    // Empty batch
    // ==================================================================

    /// @notice An empty batch is a no-op, never an error.
    function test_anEmptyBatchIsANoOp() public view {
        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), 0, 0);

        assertFalse(s.feasible, "an empty batch reported a solution");
        assertEq(s.residualIn, 0, "an empty batch sized a residual");
        assertEq(s.priceX96, 0, "an empty batch produced a price");
    }

    // ==================================================================
    // With liquidity
    // ==================================================================

    /// @notice A batch that nets out at spot never touches the curve, and its
    /// price is spot.
    ///
    /// @dev Coincidence-of-wants falls out of the algebra rather than being a
    /// special case, so this is the property that shows the two agree.
    function test_aPerfectlyMatchedBatchNeverTouchesTheCurve() public {
        _addWideLiquidity();

        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint256 spotX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);

        uint256 net0 = 1 ether;
        uint256 net1 = FullMath.mulDiv(net0, spotX96, Q96);

        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), net0, net1);

        assertTrue(s.feasible, "a matched batch was refused");
        assertEq(s.residualIn, 0, "a matched batch pushed a residual through the curve");
        assertApproxEqRel(s.priceX96, spotX96, 1e12, "a matched batch did not clear at spot");
    }

    /// @notice The `oneForZero` residual branch prices from its own trade.
    ///
    /// @dev The two directions take different arms of the price derivation —
    /// the pool pays currency1 one way and takes it the other — so a suite that
    /// only ever exercises `zeroForOne` leaves half of it unproven.
    function test_aOneForZeroResidualPricesFromItsOwnTrade() public {
        _addWideLiquidity();

        // Net-buying currency0: the residual sells currency1 to the curve.
        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), 0.01 ether, 5 ether);

        assertTrue(s.feasible, "a oneForZero batch was refused");
        assertFalse(s.zeroForOne, "the residual took the wrong direction");
        assertGt(s.residualIn, 0, "a oneForZero residual moved nothing");
        assertGt(s.priceX96, 0, "a oneForZero residual produced no price");
        assertEq(s.priceX96, FullMath.mulDiv(s.residualIn, Q96, s.residualOut), "price is not residualIn/residualOut");
    }

    /// @notice The `zeroForOne` residual takes the other arm.
    function test_aZeroForOneResidualPricesFromItsOwnTrade() public {
        _addWideLiquidity();

        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), 5 ether, 0.01 ether);

        assertTrue(s.feasible, "a zeroForOne batch was refused");
        assertTrue(s.zeroForOne, "the residual took the wrong direction");
        assertGt(s.residualIn, 0, "a zeroForOne residual moved nothing");
        assertEq(s.priceX96, FullMath.mulDiv(s.residualOut, Q96, s.residualIn), "price is not residualOut/residualIn");
    }

    // ==================================================================
    // The residual cap
    // ==================================================================

    /// @notice The cap bounds the residual, and a batch far larger than it is
    /// clamped rather than refused.
    ///
    /// @dev Clamping is what makes the sandwich bound compatible with
    /// liveness: the excess rolls to the next epoch instead of failing.
    function test_aBatchLargerThanTheCapIsClampedNotRefused() public {
        _addWideLiquidity();

        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), 500 ether, 0);

        assertTrue(s.feasible, "an oversized batch was refused outright");
        assertTrue(s.clamped, "an oversized batch was not clamped");
        assertLt(s.residualIn, 500 ether, "the cap did not bound the residual");
    }

    /// @notice A tighter cap admits strictly less residual.
    ///
    /// @dev The cap is the one governance-tunable defence whose ceiling is
    /// fixed at break-even, so its monotonicity is worth pinning: a lower
    /// setting must never admit more.
    function test_aTighterCapAdmitsLessResidual() public {
        _addWideLiquidity();

        BatchSolver.Params memory loose = _params();
        BatchSolver.Params memory tight = _params();
        tight.residualCapBps = 500; // the deploy-fixed floor

        Clearing.Solution memory sLoose = BatchSolver.solveMultiRange(loose, 500 ether, 0);
        Clearing.Solution memory sTight = BatchSolver.solveMultiRange(tight, 500 ether, 0);

        assertLt(sTight.residualIn, sLoose.residualIn, "a tighter cap admitted at least as much residual");
    }

    /// @notice Fuzzed: the walk never reports a feasible solution that implies
    /// no price, and never sizes a residual without an output to pay for it.
    ///
    /// @dev These two are the preconditions everything downstream assumes. A
    /// feasible solution with a zero price would divide by zero in the
    /// eligibility screen; one with a zero output would consume trader input
    /// for nothing.
    function testFuzz_feasibleSolutionsAlwaysCarryAPriceAndAnOutput(
        uint128 net0,
        uint128 net1
    ) public {
        _addWideLiquidity();
        net0 = uint128(bound(net0, 0, 100 ether));
        net1 = uint128(bound(net1, 0, 100 ether));

        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), net0, net1);
        if (!s.feasible) return;

        assertGt(s.priceX96, 0, "a feasible solution carried no price");
        if (s.residualIn > 0) {
            assertGt(s.residualOut, 0, "a residual was sized with no output to pay for it");
        }
    }

    // ==================================================================
    // The walk itself
    // ==================================================================

    /// @notice With the cap opened to its ceiling, a large batch walks past an
    /// initialised tick instead of stopping at it.
    ///
    /// @dev This is the continuation path: consume this range's fill, cross the
    /// boundary, re-solve with the next range's liquidity. Ordinary settlements
    /// rarely reach it, because the residual cap usually binds first — which is
    /// the cap working, but it leaves the walk's own arithmetic unexercised
    /// unless it is reached deliberately.
    function test_theWalkCrossesAnInitialisedTickWhenTheCapAllows() public {
        // A deep narrow position inside a shallow wide one. Tick -600 is an
        // initialised edge a large zeroForOne batch must cross.
        _addLiquidity(-60_000, 60_000, 100 ether);
        _addLiquidity(-600, 600, 500 ether);

        // Both levers have to be opened, and the second one is the subtle one.
        // The cap is `f_base * reserve`, so at the default 0.30% it happens to
        // sit at roughly ONE range's capacity on this pool -- the walk sizes a
        // single segment, spends its budget, and stops. Only a materially
        // higher `f_base` leaves budget to spend beyond the first tick.
        BatchSolver.Params memory p = _params();
        p.residualCapBps = 10_000; // the deploy-fixed ceiling: exactly break-even
        p.fBase = 100_000; // 10%, the governance maximum

        // What one range alone can absorb, measured at the shipped fee.
        Clearing.Solution memory single = BatchSolver.solveMultiRange(_params(), 200 ether, 0);

        Clearing.Solution memory s = BatchSolver.solveMultiRange(p, 200 ether, 0);

        assertTrue(s.feasible, "the walk refused a batch it should have sized");
        assertGt(s.residualOut, 0, "the walk sized a residual with no output");
        assertGt(
            s.residualIn, single.residualIn * 2, "the walk did not accumulate across ranges: it stopped at the first"
        );
        assertEq(s.priceX96, FullMath.mulDiv(s.residualOut, Q96, s.residualIn), "price is not residualOut/residualIn");
    }

    /// @notice A tighter cap stops the same batch earlier than a looser one.
    ///
    /// @dev The two settings take different exits from the loop — one runs out
    /// of budget, the other keeps walking — so this pins that the budget is
    /// spent across the whole walk rather than reset per range.
    function test_theCapIsABudgetForTheWholeWalkNotPerRange() public {
        _addLiquidity(-60_000, 60_000, 100 ether);
        _addLiquidity(-600, 600, 500 ether);

        BatchSolver.Params memory wide = _params();
        wide.residualCapBps = 10_000;
        wide.fBase = 100_000;
        BatchSolver.Params memory tight = _params();
        tight.residualCapBps = 500;
        tight.fBase = 100_000;

        Clearing.Solution memory sWide = BatchSolver.solveMultiRange(wide, 200 ether, 0);
        Clearing.Solution memory sTight = BatchSolver.solveMultiRange(tight, 200 ether, 0);

        assertLt(sTight.residualIn, sWide.residualIn, "the tighter budget did not stop the walk earlier");
    }

    /// @notice An extreme coincidence-of-wants price saturates rather than
    /// overflowing.
    ///
    /// @dev `priceX96` is a uint160. A batch with a vanishing currency0 side
    /// implies an unbounded price, and the conversion clamps instead of
    /// wrapping — wrapping would produce a small price from an enormous one,
    /// which is the direction that silently underpays a trader.
    function test_anExtremeCoWPriceSaturatesRatherThanWrapping() public view {
        assertEq(manager.getLiquidity(poolId), 0, "setup: pool should have no liquidity");

        Clearing.Solution memory s = BatchSolver.solveMultiRange(_params(), 1, 1_000 ether);

        assertTrue(s.feasible, "a lopsided CoW batch was refused");
        assertEq(s.residualIn, 0, "a pure CoW batch touched the curve");
        assertEq(uint256(s.priceX96), type(uint160).max, "an unbounded price did not saturate");
    }
}
