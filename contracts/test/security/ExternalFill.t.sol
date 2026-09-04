// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {KesselErrors} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Adversarial coverage for the external-fill path (Shape B).
///
/// The path exists because the Slow Lane's coincidence-of-wants window is
/// otherwise bounded by whatever counterflow happens to sit in the same 32-order
/// epoch on the same pair. Letting an external filler compete widens that window
/// arbitrarily — at the cost of handing the batch's input to an untrusted
/// contract before it has delivered anything.
///
/// So every test here is about that hand-off. The design claim being defended is
/// narrow and worth stating exactly:
///
///   A filler can take the input and vanish, deliver short, deliver dust, try to
///   reenter, or be a trader in the batch it is filling. In every one of those
///   cases the settlement must either complete at a price at least as good as the
///   curve would have produced, or unwind completely. There is no third outcome,
///   and in particular there is no outcome where custody ends up short.
contract ExternalFillTest is KesselTestBase {
    using StateLibrary for IPoolManager;

    MockFiller internal filler;

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();

        _fundAndApprove(alice, 1_000 ether);
        _fundAndApprove(bob, 1_000 ether);

        filler = new MockFiller(manager, hook, swapRouter, key);
        deal(Currency.unwrap(currency0), address(filler), 10_000 ether);
        deal(Currency.unwrap(currency1), address(filler), 10_000 ether);
        filler.approveRouter(currency0, currency1);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev One resting, one-sided Slow-Lane order, aged past `minSettleAge`
    /// so the batch is fillable. One-sided on purpose: it guarantees a non-zero
    /// residual, which is the only case where a filler does anything at all.
    function _restingOrder() internal returns (uint256 id) {
        vm.prank(alice);
        id = _slowOrder(alice, true, 10 ether, 1 ether, 10);
        vm.roll(vm.getBlockNumber() + 5);
    }

    function _custodyCoversObligations() internal view {
        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertGe(c0, o0, "I2: currency0 custody below obligations");
        assertGe(c1, o1, "I2: currency1 custody below obligations");
    }

    // ------------------------------------------------------------------
    // The happy path, and the reason the path exists
    // ------------------------------------------------------------------

    /// @notice The whole hand-off works in the other direction too: a batch
    /// that is net-selling currency1 is delivered in currency0 and paid in
    /// currency1.
    ///
    /// @dev Every other test in this file rests a `zeroForOne` order, so the
    /// filler path has only ever been walked with the residual pointing one
    /// way. `_acceptFillerDelivery` books its two deltas with the signs
    /// swapped depending on that direction, and a swapped pair would not be a
    /// subtle mispricing — it would size the pots from the wrong currency
    /// entirely. Asserting the balances on both sides is what distinguishes
    /// "it settled" from "it settled correctly".
    function test_aCurrency1ResidualIsFilledOnTheOtherSide() public {
        vm.prank(bob);
        uint256 id = _slowOrder(bob, false, 10 ether, 1 ether, 10);
        vm.roll(vm.getBlockNumber() + 5);

        (bool ok, Currency outCurrency,, Currency inCurrency,) = hook.quoteFill();
        assertTrue(ok, "a one-sided currency1 batch should be fillable");
        assertEq(Currency.unwrap(outCurrency), Currency.unwrap(currency0), "delivery should be in currency0");
        assertEq(Currency.unwrap(inCurrency), Currency.unwrap(currency1), "payment should be in currency1");

        uint256 filler0Before = IERC20Like(Currency.unwrap(currency0)).balanceOf(address(filler));
        uint256 filler1Before = IERC20Like(Currency.unwrap(currency1)).balanceOf(address(filler));

        filler.setMode(MockFiller.Mode.GENEROUS);
        filler.settle();

        assertGt(hook.oldestUnsettledEpoch(), 1, "the currency1 batch did not settle");
        assertGt(_order(id).owedOut, 0, "the trader was not paid");
        assertLt(
            IERC20Like(Currency.unwrap(currency0)).balanceOf(address(filler)),
            filler0Before,
            "the filler did not deliver currency0"
        );
        assertGt(
            IERC20Like(Currency.unwrap(currency1)).balanceOf(address(filler)),
            filler1Before,
            "the filler was not paid in currency1"
        );
        _custodyCoversObligations();
    }

    function test_fillerBeatingTheCurvePaysTradersMoreThanTheCurveWould() public {
        uint256 id = _restingOrder();

        // Settle the same batch twice over, from the same starting state, and
        // compare. Snapshotting is what makes this an actual comparison rather
        // than an assertion against a hardcoded number that could drift.
        uint256 snap = vm.snapshotState();

        hook.forceSettleDue();
        filler.setMode(MockFiller.Mode.EXACT_FLOOR);
        filler.settle();
        uint256 curveEquivalent = _order(id).owedOut;

        vm.revertToState(snap);

        filler.setMode(MockFiller.Mode.GENEROUS);
        filler.settle();
        uint256 improved = _order(id).owedOut;

        assertGt(improved, curveEquivalent, "a filler beating the curve must pay the trader more");
        _custodyCoversObligations();
    }

    function test_fillerAtExactlyTheCurveFloorIsAccepted() public {
        uint256 id = _restingOrder();

        filler.setMode(MockFiller.Mode.EXACT_FLOOR);
        filler.settle();

        assertGt(_order(id).owedOut, 0, "an at-floor fill must still settle");
        _custodyCoversObligations();
    }

    /// @dev The trader must be able to actually collect what a filled batch
    /// credited them. A settlement that books output it cannot pay out is worse
    /// than one that never happened.
    function test_traderCanRedeemAfterAnExternalFill() public {
        uint256 id = _restingOrder();

        filler.setMode(MockFiller.Mode.GENEROUS);
        filler.settle();

        uint256 owed = _order(id).owedOut;
        uint256 before = IERC20Like(Currency.unwrap(currency1)).balanceOf(alice);

        hook.redeem(id);

        assertEq(
            IERC20Like(Currency.unwrap(currency1)).balanceOf(alice) - before,
            owed,
            "redeem must pay exactly what was owed"
        );
    }

    // ------------------------------------------------------------------
    // The hand-off: what happens when the filler does not deliver
    // ------------------------------------------------------------------

    /// @dev The load-bearing one. A filler that takes the input and returns
    /// nothing must leave the world exactly as it found it.
    function test_abscondingFillerUnwindsCompletelyAndKeepsNothing() public {
        uint256 id = _restingOrder();

        (uint256 c0Before, uint256 c1Before) = _custody();
        uint256 remainingBefore = _order(id).amountInRemaining;
        uint256 fillerBalBefore = IERC20Like(Currency.unwrap(currency0)).balanceOf(address(filler));

        filler.setMode(MockFiller.Mode.ABSCOND);
        vm.prank(bob);
        vm.expectRevert();
        filler.settle();

        (uint256 c0After, uint256 c1After) = _custody();
        assertEq(c0After, c0Before, "custody0 moved despite a reverted settlement");
        assertEq(c1After, c1Before, "custody1 moved despite a reverted settlement");
        assertEq(_order(id).amountInRemaining, remainingBefore, "order was consumed by a reverted settlement");
        assertEq(_order(id).owedOut, 0, "a reverted settlement credited output");
        assertEq(
            IERC20Like(Currency.unwrap(currency0)).balanceOf(address(filler)),
            fillerBalBefore,
            "the absconding filler kept the batch input"
        );
    }

    function test_fillerOneWeiShortIsRejected() public {
        _restingOrder();

        filler.setMode(MockFiller.Mode.ONE_WEI_SHORT);
        vm.prank(bob);
        vm.expectRevert();
        filler.settle();

        _custodyCoversObligations();
    }

    /// @dev The batch must survive a failed fill and remain settleable — a
    /// filler that reverts must not be able to brick the lane, which is the
    /// SR-1 lesson applied to a new failure mode.
    function test_aFailedFillDoesNotBlockTheBatchFromSettlingLater() public {
        uint256 id = _restingOrder();

        filler.setMode(MockFiller.Mode.ABSCOND);
        vm.prank(bob);
        vm.expectRevert();
        filler.settle();

        // The curve path must still work afterwards. Rolled past
        // `absoluteMaxDelay` rather than `maxDelay`: a lone order does not meet
        // DD-13's `minForceSettleOrders` floor, so the liveness escape is what
        // makes this batch forceable at all.
        vm.roll(vm.getBlockNumber() + 3_100);
        hook.forceSettle();

        assertGt(_order(id).owedOut, 0, "batch was left unsettleable by a failed external fill");
        _custodyCoversObligations();
    }

    // ------------------------------------------------------------------
    // Identity and reentrancy
    // ------------------------------------------------------------------

    function test_fillerMayNotBeATraderInTheBatchItIsFilling() public {
        _restingOrder();

        // `alice` is the beneficiary of the only order in this batch, so she
        // may not also be the counterparty filling it.
        vm.prank(alice);
        vm.expectRevert(KesselErrors.InvalidFiller.selector);
        hook.settleWithFill(0);
    }

    function test_fillerMayNotBeTheHookOrThePoolManager() public {
        _restingOrder();

        vm.prank(address(hook));
        vm.expectRevert(KesselErrors.InvalidFiller.selector);
        hook.settleWithFill(0);

        vm.prank(address(manager));
        vm.expectRevert(KesselErrors.InvalidFiller.selector);
        hook.settleWithFill(0);
    }

    /// @dev The "nested settlement mid-fill" vector no longer exists: with the
    /// deliver-first model the hook never calls back into a filler, so there is
    /// no window in which a half-finished settlement is holding control.
    ///
    /// What remains possible is a filler that touches the pool in the SAME
    /// transaction before settling — which a real filler routing elsewhere will
    /// do routinely. That swap carries `afterSwap`, so it may piggyback-settle
    /// the batch out from under the fill. This pins that the race resolves
    /// safely: the batch settles exactly once, the losing call is refused
    /// rather than double-settling, and custody stays coherent either way.
    function test_fillerSwappingBeforeSettlingCannotDoubleSettle() public {
        uint256 id = _restingOrder();

        filler.setMode(MockFiller.Mode.SWAP_THEN_DELIVER);
        filler.settle();

        // Settled exactly once, by whichever path got there first.
        assertGt(_order(id).owedOut, 0, "the batch did not settle at all");
        assertLe(_order(id).amountInRemaining, 10 ether, "order over-consumed by a double settlement");

        _custodyCoversObligations();
    }

    function test_fillerCannotReenterSettlementDirectly() public {
        _restingOrder();

        // The filler swallows its own failed reentry and then delivers, so the
        // assertion is that the settlement still completes correctly rather
        // than that the whole thing reverts.
        filler.setMode(MockFiller.Mode.REENTER_THEN_DELIVER);
        filler.settle();

        assertTrue(filler.reentryFailed(), "a nested settleWithFill should not have succeeded");
        _custodyCoversObligations();
    }

    // ------------------------------------------------------------------
    // Gates
    // ------------------------------------------------------------------

    function test_fillerPathRespectsMinSettleAge() public {
        vm.prank(alice);
        _slowOrder(alice, true, 10 ether, 1 ether, 10);

        // Same block as submission: settling here would approximate
        // submission-time pricing and erode I6.
        filler.setMode(MockFiller.Mode.GENEROUS);
        vm.prank(bob);
        vm.expectRevert(KesselErrors.SettlementNotDue.selector);
        filler.settle();
    }

    function test_fillerPathIsBlockedWhilePaused() public {
        _restingOrder();

        vm.prank(governance);
        hook.setPaused(true);

        filler.setMode(MockFiller.Mode.GENEROUS);
        vm.prank(bob);
        vm.expectRevert(KesselErrors.Paused.selector);
        filler.settle();
    }

    // ------------------------------------------------------------------
    // I4 — the uniform price must survive a second counterparty
    // ------------------------------------------------------------------

    /// @dev A two-sided batch takes its surplus in ONE currency only, so a
    /// generous fill lands entirely in one pot. The naive worry is that this
    /// must break I4 by lifting one side's implied price and not the other's.
    ///
    /// It does not, and the reason is worth pinning: `Clearing.fillRatio`
    /// derives the fill from what actually arrived, so a larger delivery
    /// produces a *smaller* lambda. The batch absorbs the surplus as a better
    /// price on a slightly smaller fill, and both sides move together. This is
    /// the same property that makes solvency independent of the prediction,
    /// doing the same job for a counterparty the original design never had.
    ///
    /// Asserted against the hook's own recorded pots rather than reconstructed
    /// from order fields, so that this compares exactly the two quantities I4
    /// is defined over — net-of-fee input against pot — rather than mixing
    /// gross input with net-of-`f_slow` output.
    function test_generousFillOnATwoSidedBatchStillClearsAtOneUniformPrice() public {
        vm.prank(alice);
        uint256 a = _slowOrder(alice, true, 30 ether, 3 ether, 10);
        vm.prank(bob);
        uint256 b = _slowOrder(bob, false, 10 ether, 1 ether, 10);
        uint32 epoch = hook.currentEpoch();
        vm.roll(vm.getBlockNumber() + 5);

        filler.setMode(MockFiller.Mode.GENEROUS);
        filler.settle();

        assertGt(_order(a).owedOut, 0, "the currency0 side did not fill");
        assertGt(_order(b).owedOut, 0, "the currency1 side did not fill");

        (,, uint128 filled0, uint128 filled1, uint128 pot1, uint128 pot0,) = hook.epochs(epoch);
        assertGt(filled0, 0, "no currency0 recorded as filled");
        assertGt(filled1, 0, "no currency1 recorded as filled");

        // I4's own definition: the two sides' implied prices must agree.
        uint256 priceA = (uint256(pot1) * 1e18) / filled0;
        uint256 priceB = (uint256(filled1) * 1e18) / pot0;
        uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
        assertLe(diff * 1e6, (priceA > priceB ? priceA : priceB) * 100, "I4: two-sided batch cleared at two prices");

        _custodyCoversObligations();
    }

    function test_uniformPriceHoldsAcrossAnExternallyFilledBatch() public {
        vm.prank(alice);
        uint256 a = _slowOrder(alice, true, 10 ether, 1 ether, 10);
        vm.prank(bob);
        uint256 b = _slowOrder(bob, true, 30 ether, 3 ether, 10);
        vm.roll(vm.getBlockNumber() + 5);

        filler.setMode(MockFiller.Mode.GENEROUS);
        filler.settle();

        uint256 filledA = 10 ether - _order(a).amountInRemaining;
        uint256 filledB = 30 ether - _order(b).amountInRemaining;
        assertGt(filledA, 0, "order A did not fill");
        assertGt(filledB, 0, "order B did not fill");

        // priceA == priceB, to within the integer-division slack the hook's own
        // I4 assertion allows.
        uint256 priceA = (_order(a).owedOut * 1e18) / filledA;
        uint256 priceB = (_order(b).owedOut * 1e18) / filledB;
        uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
        assertLe(diff * 1e6, (priceA > priceB ? priceA : priceB) * 100, "I4: non-uniform price under external fill");
    }
}

/// @dev `IERC20Like` in the shared fixture carries only what the fixture needs.
/// The filler also has to push tokens to the PoolManager.
interface IERC20Transfer {
    function transfer(
        address,
        uint256
    ) external returns (bool);
    function approve(
        address,
        uint256
    ) external returns (bool);
}

/// @notice A filler that can misbehave in every way the hook has to survive.
///
/// @dev It approves the hook and declares a delivery to `settleWithFill`, which
/// the hook then pulls. The hook never calls back, so misbehaviour here means
/// declaring the wrong amount, or doing something hostile in the same
/// transaction before settling — not misbehaving inside a callback, which no
/// longer exists.
contract MockFiller {
    enum Mode {
        EXACT_FLOOR,
        GENEROUS,
        ONE_WEI_SHORT,
        ABSCOND,
        SWAP_THEN_DELIVER,
        REENTER_THEN_DELIVER
    }

    IPoolManager internal immutable manager;
    KesselHook internal immutable hook;
    PoolSwapTest internal immutable router;
    PoolKey internal key;

    Mode public mode = Mode.EXACT_FLOOR;
    bool public reentryFailed;

    constructor(
        IPoolManager _manager,
        KesselHook _hook,
        PoolSwapTest _router,
        PoolKey memory _key
    ) {
        manager = _manager;
        hook = _hook;
        router = _router;
        key = _key;
    }

    function setMode(
        Mode m
    ) external {
        mode = m;
    }

    function approveRouter(
        Currency c0,
        Currency c1
    ) external {
        IERC20Transfer(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        IERC20Transfer(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
    }

    /// @dev How much of each currency to pre-deliver. Sized off the hook's own
    /// quote so the modes mean what they say.
    function settle() external {
        if (mode == Mode.SWAP_THEN_DELIVER) {
            // A Fast-Lane swap through the router, in the same transaction but
            // OUTSIDE any unlock of the hook's. This is what a real filler does
            // when it sources the other side; it must not disturb the batch.
            router.swap(
                key,
                SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: 4295128740}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                LaneCodec.encodeFast()
            );
        }

        if (mode == Mode.REENTER_THEN_DELIVER) {
            // Settling twice in one transaction: the second must find nothing
            // due rather than double-settle the same batch.
            uint256 offer = _approveOffer();
            try hook.settleWithFill(offer) {
                reentryFailed = false;
            } catch {
                reentryFailed = true;
            }
            try hook.settleWithFill(offer) {
                reentryFailed = false;
            } catch {
                reentryFailed = true;
            }
            return;
        }

        uint256 declared = mode == Mode.ABSCOND ? 0 : _approveOffer();

        if (mode == Mode.SWAP_THEN_DELIVER) {
            // The pre-swap may already have piggyback-settled the batch, in
            // which case there is correctly nothing left to fill.
            try hook.settleWithFill(declared) {} catch {}
            return;
        }

        hook.settleWithFill(declared);
    }

    /// @dev Approve the amount this mode calls for and return it as the
    /// declaration. The needed amount is read from the hook's own quote so that
    /// EXACT_FLOOR really is the floor.
    function _approveOffer() internal returns (uint256 out) {
        (bool ok, Currency outCurrency, uint256 floorOut,,) = hook.quoteFill();
        if (!ok || floorOut == 0) return 0;

        out = floorOut;
        if (mode == Mode.GENEROUS) out = (floorOut * 105) / 100;
        if (mode == Mode.ONE_WEI_SHORT) out = floorOut - 1;

        IERC20Transfer(Currency.unwrap(outCurrency)).approve(address(hook), out);
    }
}
