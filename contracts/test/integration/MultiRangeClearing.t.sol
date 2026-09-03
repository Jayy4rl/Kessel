// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice The multi-range amendment to DD-5 (gap 4).
///
/// `Clearing.solve` is exact only inside one constant-liquidity range, so the
/// solver used to stop at the first initialised tick it met, partially fill,
/// and roll the remainder. A batch large enough to move the price past one tick
/// therefore took several settlements to complete — not because the pool lacked
/// depth, but because the solver would not look past its own horizon.
///
/// `_solveMultiRange` now walks up to `MAX_CLEARING_RANGES` ranges, crossing
/// initialised ticks the way v4's own swap loop does. What makes an iterative
/// approximation admissible at all is `Clearing.fillRatio`: the walk only has to
/// pick a good target, and any discrepancy between prediction and reality is
/// absorbed. So these tests check both halves — that the fill actually improved,
/// and that the properties which were never allowed to depend on the prediction
/// still do not.
contract MultiRangeClearingTest is KesselTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployKessel();

        // A deep narrow position sitting inside a shallow wide one. Tick -600
        // is an initialised edge, so a `zeroForOne` batch big enough to push the
        // price below it must cross a liquidity change to complete.
        _addLiquidity(-60_000, 60_000, 100 ether);
        _addLiquidity(-600, 600, 500 ether);

        _fundAndApprove(alice, 100_000 ether);
        _fundAndApprove(bob, 100_000 ether);
    }

    /// @dev The headline claim. ~9 ether of currency0 exhausts the inner
    /// position; 20 ether cannot complete without crossing tick -600.
    /// @dev Rewritten for DD-5's residual cap (2026-09-01). The multi-range
    /// walk was built so a batch reaching an initialised tick would not be
    /// stopped at the boundary; the cap then deliberately bounds how much of
    /// any batch a single settlement may push through the curve, because a
    /// large single-settlement residual is precisely the sandwich target
    /// `docs/DD5-SIMULATION.md` measured. A batch this size is, by
    /// construction, larger than the cap.
    ///
    /// The two are not in conflict — the walk still lets one settlement use
    /// depth from several ranges, up to the cap — but "completes in one
    /// settlement" is no longer the property to assert. What must hold is that
    /// the batch makes real progress every settlement and completes over a
    /// bounded number of them, crossing the tick as it goes.
    function test_batchCrossingAnInitialisedTickCompletesOverSuccessiveSettlements() public {
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 20 ether, 1 ether, 20);

        uint256 previous = 20 ether;
        for (uint256 i; i < 40 && _order(id).amountInRemaining > 0; ++i) {
            vm.roll(vm.getBlockNumber() + 5);
            _setPriorityFee(1 gwei);
            _fastSwap(true, -1e15); // carries the batch

            uint256 remaining = _order(id).amountInRemaining;
            assertLt(remaining, previous, "a settlement made no progress on the batch");
            previous = remaining;
        }

        assertEq(_order(id).amountInRemaining, 0, "the batch never completed");
        assertGt(_order(id).owedOut, 0, "the completed batch credited no output");

        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertGe(c0, o0, "I2: currency0 custody below obligations");
        assertGe(c1, o1, "I2: currency1 custody below obligations");
    }

    /// @dev I4 must not depend on the batch staying inside one range. Two
    /// same-side orders in a batch that crosses a tick still clear at one price.
    function test_uniformPriceHoldsWhenTheBatchCrossesATick() public {
        vm.prank(alice);
        uint256 a = _slowOrder(alice, true, 8 ether, 1 ether, 20);
        vm.prank(bob);
        uint256 b = _slowOrder(bob, true, 16 ether, 2 ether, 20);

        vm.roll(vm.getBlockNumber() + 5);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        uint256 filledA = 8 ether - _order(a).amountInRemaining;
        uint256 filledB = 16 ether - _order(b).amountInRemaining;
        assertGt(filledA, 0, "order A did not fill");
        assertGt(filledB, 0, "order B did not fill");

        uint256 priceA = (_order(a).owedOut * 1e18) / filledA;
        uint256 priceB = (_order(b).owedOut * 1e18) / filledB;
        uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
        assertLe(diff * 1e6, (priceA > priceB ? priceA : priceB) * 100, "I4: non-uniform price across a tick crossing");
    }

    /// @dev The walk is bounded, and the bound must degrade the way the old
    /// single-range solver did — a smaller fill and a roll — rather than
    /// reverting or mispricing. This is the property that keeps
    /// `MAX_CLEARING_RANGES` a gas knob rather than a correctness one.
    function test_aBatchBeyondTheRangeBudgetStillPartiallyFillsAndRolls() public {
        // Enough initialised edges to outrun the range budget.
        _addLiquidity(-1_200, 1_200, 500 ether);
        _addLiquidity(-1_800, 1_800, 500 ether);
        _addLiquidity(-2_400, 2_400, 500 ether);
        _addLiquidity(-3_000, 3_000, 500 ether);

        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 5_000 ether, 1 ether, 20);

        vm.roll(vm.getBlockNumber() + 5);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        assertGt(_order(id).owedOut, 0, "a budget-bound batch should still fill what it can");
        assertGt(_order(id).amountInRemaining, 0, "this batch should have exceeded the range budget");
        assertEq(
            uint8(_statusOf(id)), uint8(KesselHook_OrderStatus.PENDING), "the remainder should stay PENDING to roll"
        );

        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertGe(c0, o0, "I2: currency0 custody below obligations");
        assertGe(c1, o1, "I2: currency1 custody below obligations");
    }
}
