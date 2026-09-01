// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselErrors} from "../../src/KesselTypes.sol";
import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

interface IERC20Approve {
    function approve(
        address,
        uint256
    ) external returns (bool);
}

/// @notice SR-8 and SR-9: an order is never filled through its own limit price.
///
/// @dev I8 says a Slow-Lane trader's downside is bounded by their `minOut`, and
/// DD-11 makes that exact by turning `minOut` into a limit *price* screened at
/// settlement. The screen ran against `sol.priceX96` — a prediction made before
/// the residual executed — while the payout came from the pots. Nothing forced
/// the two to agree, and two separate paths made them disagree materially:
///
///  * SR-8: `_predictedPrice` used the solvency identity at a fill ratio of
///    ONE. Any batch too large for the liquidity the solver could walk clamps,
///    lambda collapses, and the prediction came out wrong by roughly `1/lambda`
///    — understated for a zeroForOne residual, overstated for the other, i.e.
///    wrong in the unsafe direction for whichever side's limit was binding.
///  * SR-9: a filler delivering above the curve floor raises the realised price
///    `Y / X`. That is an improvement for the currency0 sellers and, by exactly
///    the same amount, a deterioration for the currency1 sellers sharing the
///    batch, whose limit is a ceiling.
///
/// Neither broke solvency — `Clearing.fillRatio` makes I2 and I4 hold whatever
/// the prediction says — so the invariant suite stayed green through both. The
/// fix is `_assertLimitsHeld`, which re-runs the screen against the price the
/// batch actually cleared at and unwinds the settlement rather than filling
/// through a stated limit.
contract ClampedBatchLimitsTest is KesselTestBase {
    address internal filler = address(0xF111E7);

    function setUp() public {
        _deployKessel();
        // NARROW liquidity, deliberately. One position, [-60, 60]: a batch
        // larger than this range's depth clamps, which is SR-8's trigger and
        // is otherwise very hard to reach from the wide-range fixture every
        // other test uses.
        _addLiquidity(-60, 60, 100 ether);
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ======================================================================
    // SR-8 — the curve path
    // ======================================================================

    /// @notice A clamped two-sided batch must not fill the ceiling side through
    /// its ceiling.
    ///
    /// @dev Under the totals identity the predicted price here came out at
    /// ~0.130 while the batch actually cleared at ~0.997. Bob's ceiling of 0.5
    /// sits between the two, so he passed the screen and was filled at twice
    /// the price he had refused — receiving 50.1% of his stated `minOut`.
    function test_SR8_aClampedBatchDoesNotFillTheCeilingSideThroughItsCeiling() public {
        // A currency0 seller far larger than the range can absorb, with no
        // meaningful floor of her own so she is never the one screened out.
        _slowOrder(alice, true, 10 ether, 1e15, 200);

        // Bob sells 1 currency1 and will not pay more than 0.5 currency1 per
        // currency0 for it.
        uint128 bobIn = 1 ether;
        uint128 bobMinOut = 2 ether;
        uint256 bobId = _slowOrder(bob, false, bobIn, bobMinOut, 200);

        vm.roll(block.number + hook.maxDelay() + 1);
        hook.forceSettle();

        uint256 bobGross = bobIn - _order(bobId).amountInRemaining;
        if (bobGross == 0) return; // correctly screened out: nothing to check

        // The limit is a price, so the guarantee scales with the filled portion.
        uint256 required = (bobGross * bobMinOut) / bobIn;
        assertGe(_order(bobId).owedOut, required, "I8: a clamped batch filled an order through its limit");
    }

    /// @notice The batch still settles. Refusing the ineligible side is not
    /// allowed to become a way of freezing the lane.
    ///
    /// @dev SR-1's lesson: a batch that can neither fill nor step aside pins
    /// `oldestUnsettledEpoch` and takes the whole Slow Lane with it. The
    /// shrinking-set iteration is what makes the refusal safe — Bob is dropped,
    /// the set is repriced without him, and Alice clears against the curve.
    function test_SR8_theEligibleSideStillClears() public {
        uint256 aliceId = _slowOrder(alice, true, 10 ether, 1e15, 200);
        _slowOrder(bob, false, 1 ether, 2 ether, 200);

        vm.roll(block.number + hook.maxDelay() + 1);
        hook.forceSettle();

        assertGt(_order(aliceId).owedOut, 0, "the eligible side was not filled");
        assertGt(hook.oldestUnsettledEpoch(), 1, "the settlement cursor was pinned");
    }

    /// @notice Fuzzed over the whole ceiling range: whatever limit the
    /// currency1 seller states, a fill must honour it.
    function testFuzz_SR8_clampedFillsNeverBreachACeiling(
        uint96 sizeSeed,
        uint16 limitBps
    ) public {
        uint256 aliceIn = bound(sizeSeed, 1 ether, 40 ether); // far past the range depth
        uint256 bobIn = 1 ether;
        // Ask for between 1.05x and 5x parity, i.e. a ceiling from ~0.95 down
        // to 0.2 — the band the mispricing used to slip through.
        uint256 bobMinOut = (bobIn * bound(limitBps, 10_500, 50_000)) / 10_000;

        _slowOrder(alice, true, aliceIn, 1e12, 200);
        uint256 bobId = _slowOrder(bob, false, bobIn, uint128(bobMinOut), 200);

        vm.roll(block.number + hook.maxDelay() + 1);
        try hook.forceSettle() {}
        catch { // an unwound settlement is a pass
            return;
        }

        uint256 bobGross = bobIn - _order(bobId).amountInRemaining;
        if (bobGross == 0) return;

        uint256 required = (bobGross * bobMinOut) / bobIn;
        assertGe(_order(bobId).owedOut + 2, required, "I8: fuzzed clamped fill breached a ceiling");
    }

    // ======================================================================
    // SR-9 — the filler path
    // ======================================================================

    /// @notice A filler cannot buy one side a better price at the other side's
    /// expense by over-delivering.
    ///
    /// @dev The realised price is `Y / X`, so a delivery well above the curve
    /// floor pushes it up. Every wei of that improvement reaches the currency0
    /// sellers and every wei of it is taken from the currency1 sellers, who are
    /// buying currency0 at that same price. Past their ceiling, the settlement
    /// must unwind rather than distribute the "improvement".
    ///
    /// The guard is `_assertLimitsHeld`, not the identity check: `hookData`
    /// lets anyone name any beneficiary, so a filler and the order it favours
    /// are trivially different addresses.
    function test_SR8_anOverGenerousFillCannotBreachTheCounterSideCeiling() public {
        // Wide depth on top of the narrow position, so this batch does NOT
        // clamp. That isolates the over-delivery effect from SR-8's: the
        // predicted price here is exact, and the only thing that moves the
        // realised price is the filler.
        _addLiquidity(-6000, 6000, 100 ether);

        uint256 bobIn = 1e16;
        // Ceiling of ~1.05 currency1 per currency0: comfortably above where the
        // curve alone clears this batch (~0.999), so Bob passes the screen.
        uint128 bobMinOut = 9.52e15;

        _slowOrder(alice, true, 1e17, 1e12, 200);
        uint256 bobId = _slowOrder(bob, false, bobIn, bobMinOut, 200);

        vm.roll(block.number + hook.minSettleAge() + 1);

        (bool ok, Currency outCurrency, uint256 floorOut,,) = hook.quoteFill();
        assertTrue(ok && floorOut > 0, "setup: the batch should be fillable");

        // Half again as much as the curve would have paid. The realised price
        // is `Y / X`, so this lifts it far past Bob's ceiling.
        uint256 generous = (floorOut * 150) / 100;
        deal(Currency.unwrap(outCurrency), filler, generous);

        vm.startPrank(filler);
        IERC20Approve(Currency.unwrap(outCurrency)).approve(address(hook), generous);
        try hook.settleWithFill(generous) {
            // Allowed only if Bob was not in fact pushed through his ceiling.
            uint256 bobGross = bobIn - _order(bobId).amountInRemaining;
            if (bobGross > 0) {
                uint256 required = (bobGross * bobMinOut) / bobIn;
                assertGe(_order(bobId).owedOut + 2, required, "I8: an over-generous fill breached a ceiling");
            }
        } catch (bytes memory err) {
            assertEq(bytes4(err), KesselErrors.LimitPriceBreached.selector, "unwound for the wrong reason");
        }
        vm.stopPrank();
    }

    /// @notice A filler delivering AT the floor is still accepted. The guard
    /// must refuse over-generous fills without closing the path it protects.
    function test_SR8_aFillAtTheCurveFloorStillSettles() public {
        _addLiquidity(-6000, 6000, 100 ether);

        uint256 id = _slowOrder(alice, true, 1e17, 1e12, 200);
        _slowOrder(bob, false, 1e16, 9.52e15, 200);

        vm.roll(block.number + hook.minSettleAge() + 1);

        (bool ok, Currency outCurrency, uint256 floorOut,,) = hook.quoteFill();
        assertTrue(ok && floorOut > 0, "setup: the batch should be fillable");

        deal(Currency.unwrap(outCurrency), filler, floorOut);
        vm.startPrank(filler);
        IERC20Approve(Currency.unwrap(outCurrency)).approve(address(hook), floorOut);
        hook.settleWithFill(floorOut);
        vm.stopPrank();

        assertGt(_order(id).owedOut, 0, "an at-floor fill was refused");
        assertGt(hook.oldestUnsettledEpoch(), 1, "the batch did not settle");
    }
}
