// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {KesselErrors, KesselEvents} from "../../src/KesselTypes.sol";
import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice The settlement cursor's degenerate paths — the ones that run when a
/// batch does *not* clear normally.
///
/// Settlement only ever works on `oldestUnsettledEpoch`, so every one of these
/// is a liveness property before it is anything else: an epoch that cannot fill
/// and cannot get out of the way pins the entire Slow Lane, permanently, on a
/// contract with no upgrade path. SR-1 was exactly that bug, and it was found
/// by writing a test like these rather than by the invariant suite — which
/// stayed green throughout, because a frozen lane violates none of I1–I12.
contract SettlementLifecycleTest is KesselTestBase {
    uint256 internal constant EPOCH_CAP = 32; // KesselHook.MAX_ORDERS_PER_EPOCH

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ======================================================================
    // A batch with nothing left in it
    // ======================================================================

    /// @notice An epoch whose every order has expired is not fillable, and must
    /// still let the cursor past.
    ///
    /// @dev `_loadCandidates` skips expired orders, so this epoch presents an
    /// empty candidate set — a state distinct from SR-1's (where the orders
    /// were live but ineligible) and reached by a different branch. The lane
    /// must drain rather than stall: the orders themselves stay refundable
    /// through `redeem`, which reaches them by id and does not care about the
    /// cursor, but every *later* batch depends on this epoch stepping aside.
    ///
    /// Reaching the state takes two saturated epochs, and that is the point.
    /// `currentEpoch` only advances when a batch settles or when an epoch fills
    /// up, so an epoch can only expire *while still at the cursor* if newer
    /// orders pile up behind it — which is precisely the situation in which a
    /// stall would be most expensive.
    function test_anEpochOfExpiredOrdersDrainsTheCursor() public {
        // Epoch 1: a full batch, all with the shortest expiry the hook allows.
        for (uint256 i; i < EPOCH_CAP; ++i) {
            _slowOrder(alice, true, 1e14, 1e13, 1);
        }
        assertEq(hook.orderCount(1), EPOCH_CAP, "setup: epoch 1 should be full");

        // Epochs 2 and 3, which is what pushes `currentEpoch` past epoch 1's
        // expiry budget without epoch 1 ever settling.
        for (uint256 i; i < EPOCH_CAP + 1; ++i) {
            _slowOrder(bob, true, 1e14, 1e13, 200);
        }
        assertEq(hook.currentEpoch(), 3, "setup: newer orders should have opened epoch 3");
        assertEq(hook.oldestUnsettledEpoch(), 1, "setup: the cursor should still be on epoch 1");

        // The block-age half of the expiry test, and the forced-settlement gate.
        vm.roll(block.number + hook.maxDelay() + 1);
        assertGt(hook.currentEpoch(), _order(1).epochExpiry, "setup: epoch 1 should be past its budget");

        // The batch is "due" by the clock and has thirty-two order ids in its
        // index, but not one of them is a candidate. A filler asking what to
        // deliver must be told "nothing" rather than handed a quote against an
        // empty set — the two states are indistinguishable from the index
        // length alone, which is exactly why the quote recomputes candidates
        // instead of trusting it.
        (bool ok,,,,) = hook.quoteFill();
        assertFalse(ok, "quoted a fill against an epoch with no live orders");

        hook.forceSettle();

        assertGt(hook.oldestUnsettledEpoch(), 1, "an all-expired epoch pinned the settlement cursor");
    }

    /// @notice The drained epoch's orders are still redeemable afterwards.
    ///
    /// @dev Advancing the cursor past an epoch must not be a way to lose the
    /// funds inside it. This is the half that makes the previous test safe
    /// rather than merely convenient: "the lane kept moving" is worth nothing
    /// if what it moved past was somebody's escrow.
    function test_drainingAnEpochDoesNotStrandItsOrders() public {
        for (uint256 i; i < EPOCH_CAP; ++i) {
            _slowOrder(alice, true, 1e14, 1e13, 1);
        }
        for (uint256 i; i < EPOCH_CAP + 1; ++i) {
            _slowOrder(bob, true, 1e14, 1e13, 200);
        }

        vm.roll(block.number + hook.maxDelay() + 1);
        hook.forceSettle();

        uint256 before = IERC20Like(Currency.unwrap(currency0)).balanceOf(alice);
        hook.redeem(1);
        assertGt(IERC20Like(Currency.unwrap(currency0)).balanceOf(alice), before, "a drained epoch stranded its refund");
        assertEq(uint256(_statusOf(1)), uint256(KesselHook_OrderStatus.REFUNDED), "order not finalised as refunded");
    }

    /// @notice The cursor never steps past an epoch that still has work in it.
    ///
    /// @dev The mirror of the two above, and the reason `_advanceIfDrained`
    /// walks the whole index rather than sampling it: one live order among
    /// thirty-two expired ones must keep the epoch at the cursor, because
    /// skipping it would leave that order unfillable forever.
    function test_theCursorDoesNotSkipAFillableEpoch() public {
        uint256 live = _slowOrder(carol, true, 1e14, 1e13, 200); // outlives the rest
        for (uint256 i; i < EPOCH_CAP - 1; ++i) {
            _slowOrder(alice, true, 1e14, 1e13, 1);
        }
        for (uint256 i; i < EPOCH_CAP + 1; ++i) {
            _slowOrder(bob, true, 1e14, 1e13, 200);
        }

        vm.roll(block.number + hook.maxDelay() + 1);
        assertEq(hook.oldestUnsettledEpoch(), 1, "setup: the cursor should be on epoch 1");

        // One live order is enough to make the batch a real settlement rather
        // than a drain, so the cursor moves by settling — not by skipping.
        hook.forceSettle();
        assertTrue(_order(live).owedOut > 0 || _order(live).amountInRemaining > 0, "the live order was abandoned");
    }

    /// @notice An order too small to receive any of a partial fill is left
    /// pending and rolls, rather than being consumed for nothing.
    ///
    /// @dev When a batch is bigger than its liquidity range can absorb, every
    /// order is filled at the same fractional ratio — and an order small enough
    /// that its share floors to zero would otherwise have its input marked
    /// filled while receiving no output at all. Skipping it here is what keeps
    /// the two halves of the ledger together: the order stays live, its input
    /// stays escrowed, and it rolls into the next batch where the ratio may be
    /// large enough to pay it something.
    function test_anOrderTooSmallForAPartialFillIsLeftToRoll() public {
        // A range narrow enough that the batch below cannot clear inside it,
        // which is what forces a fractional fill ratio.
        _addLiquidity(-6000, 6000, -100 ether);
        _addLiquidity(-60, 60, 100 ether);

        // Three large sellers with limits the crushed price still satisfies...
        for (uint256 i; i < 3; ++i) {
            _slowOrder(alice, true, 1 ether, 1, 200);
        }
        // ...and one order of a single wei on the other side, whose share of
        // any partial fill rounds to nothing.
        uint256 dust = _slowOrder(bob, false, 1, 1, 200);

        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e12);

        assertEq(_order(dust).amountInRemaining, 1, "the dust order's input was consumed");
        assertEq(_order(dust).owedOut, 0, "the dust order was paid out of a fill it did not get");
        assertEq(uint256(_statusOf(dust)), uint256(KesselHook_OrderStatus.PENDING), "the dust order was finalised");
        assertGt(_order(1).owedOut, 0, "the batch did not partially fill at all");
        assertGt(_order(1).amountInRemaining, 0, "setup: the batch should only have PARTIALLY filled");
    }

    // ======================================================================
    // Refunds on the currency1 side
    // ======================================================================

    /// @notice A `oneForZero` order expires, refunds in currency1, and forfeits
    /// its share to the currency1 LP-claimable balance.
    ///
    /// @dev The refund path branches on direction in three places — which
    /// warehouse counter to release, which currency to pay, and which claimable
    /// balance the forfeit lands in — and the suite otherwise only ever walks
    /// the `zeroForOne` side of it. A direction mix-up here would refund a
    /// trader in the wrong asset out of another trader's escrow, which custody
    /// conservation (I2) would not catch: the totals still balance.
    function test_aOneForZeroOrderRefundsInCurrency1() public {
        uint128 amountIn = 2e16;
        // An unreachable *ceiling*: a currency1 seller's limit is an upper
        // bound on the price, and asking 2.5x for the input sets one the pool
        // can never come down to.
        uint256 id = _slowOrder(alice, false, amountIn, 5e16, 1);
        assertEq(hook.warehoused1(), amountIn, "setup: currency1 exposure not booked");

        _churnPastExpiry(id);

        uint256 before1 = _bal(currency1, alice);
        uint256 before0 = _bal(currency0, alice);
        hook.redeem(id);

        assertGt(_bal(currency1, alice), before1, "refund not paid in currency1");
        assertEq(_bal(currency0, alice), before0, "refund paid in the wrong currency");
        assertEq(hook.warehoused1(), 0, "currency1 exposure not released on refund");
        assertGt(hook.lpClaimable1(), 0, "the forfeit did not reach the currency1 LP balance");
        assertEq(hook.lpClaimable0(), 0, "the forfeit landed on the wrong side");
        assertEq(uint256(_statusOf(id)), uint256(KesselHook_OrderStatus.REFUNDED), "status should be REFUNDED");
    }

    /// @notice The forfeit is exactly `expiryForfeitBps` of the remaining
    /// input, and the trader gets the rest.
    ///
    /// @dev The forfeit is what stops "post an unreachable limit, take the
    /// input back later" from being a free option (DD-9, PRD §7.3), so its size
    /// is load-bearing rather than cosmetic: at zero, expiry *is* a cancel, and
    /// the screen that the whole mechanism rests on stops working.
    function test_theExpiryForfeitIsExactlyTheStatedFractionOnTheCurrency1Side() public {
        uint128 amountIn = 2e16;
        uint256 id = _slowOrder(alice, false, amountIn, 5e16, 1);

        _churnPastExpiry(id);

        uint256 expectedForfeit = uint256(amountIn) * hook.expiryForfeitBps() / 10_000;

        uint256 before = _bal(currency1, alice);
        hook.redeem(id);
        uint256 refunded = _bal(currency1, alice) - before;

        assertEq(hook.lpClaimable1(), expectedForfeit, "forfeit was not the stated fraction");
        assertEq(refunded, amountIn - expectedForfeit, "trader was not refunded the remainder");
    }

    // ======================================================================
    // The eligibility iteration's round budget
    // ======================================================================

    /// @notice A batch whose eligible set never stabilises is not filled at
    /// all, and is then released by the liveness escape.
    ///
    /// @dev DD-11 reprices after every exclusion, because filling survivors at
    /// a price computed over the original set is not self-funding. That makes
    /// the iteration a fixed-point search, and on a two-sided batch it need not
    /// converge quickly: dropping a currency0 seller *raises* the price and
    /// dropping a currency1 seller *lowers* it, so a ladder of limits can make
    /// each repricing strand exactly one more order on the opposite side. The
    /// batch below is tuned to do that four times in a row, which is the whole
    /// round budget.
    ///
    /// Two things must then be true, and they pull in opposite directions.
    /// Nothing may fill — the last price computed was never confirmed against
    /// the set it would fill, so honouring it could pay one side out of the
    /// other's escrow. And the batch must not sit at the cursor forever, which
    /// is what I11's absolute bound is for. The round budget is a gas limit; it
    /// must not become a liveness limit.
    function test_aBatchThatNeverConvergesIsNotFilledAndThenIsReleased() public {
        // Retuned 2026-09-01 for DD-5's residual cap. The previous ladder was
        // built on curve impact and spanned limits from 0.60 to 1.10; the cap
        // bounds a single settlement's price excursion to roughly
        // `f_base * residualCapBps` (~15 bps at the defaults), so that ladder
        // now converges on the first repricing and no longer tests anything.
        //
        // This one runs on a pool with NO liquidity, where `Clearing.solve`
        // returns the pure coincidence-of-wants price `net1 / net0`. That price
        // is set by the composition of the eligible set alone, so it is
        // untouched by the cap and moves as far as the ladder needs.
        _addLiquidity(-6000, 6000, -100 ether);

        // The chain below is arranged so exactly one order is retired in each
        // of the four rounds `MAX_CLEARING_ROUNDS` allows, which is what makes
        // the loop exhaust its budget instead of settling on a smaller set.
        //
        // Each drop must swing the price PAST the previous excursion in the
        // same direction, or a later rung would already have been retired by an
        // earlier round: a floor violated at a low price is violated at every
        // lower price. So the successive drops take a strictly growing fraction
        // of their own side — 50%, 60%, 70% — and the price alternates outward
        // 1.0 -> 2.0 -> 0.8 -> 2.67 rather than settling.
        uint256 z1 = _slowOrder(alice, true, 15 ether, 0.015 ether, 200); // floor 0.001 — anchor
        uint256 zA = _slowOrder(alice, true, 50 ether, 60 ether, 200); // floor 1.20 — drops round 1
        uint256 zC = _slowOrder(alice, true, 35 ether, 31.5 ether, 200); // floor 0.90 — drops round 3
        uint256 o1 = _slowOrder(bob, false, 20 ether, 0.00002 ether, 200); // ceiling 1e6 — anchor
        uint256 oB = _slowOrder(bob, false, 60 ether, 40 ether, 200); // ceiling 1.50 — drops round 2
        uint256 oD = _slowOrder(bob, false, 20 ether, 8.695652173913043478 ether, 200); // ceiling 2.30 — round 4

        // Forced rather than piggybacked: a carrying Fast-Lane swap would move
        // the price itself and dissolve the ladder.
        vm.roll(block.number + hook.maxDelay() + 1);
        hook.forceSettle();

        assertEq(hook.oldestUnsettledEpoch(), 1, "a non-converging batch must not be treated as settled");

        uint256[6] memory ids = [z1, zA, zC, o1, oB, oD];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(_order(ids[i]).owedOut, 0, "an order filled at a price the eligible set never confirmed");
        }
        // The ladder really did run to the end of the budget rather than
        // converging early on some smaller set.
        assertEq(_order(zA).amountInRemaining, 50 ether, "zA should be untouched");
        assertEq(_order(oB).amountInRemaining, 60 ether, "oB should be untouched");
        assertEq(_order(zC).amountInRemaining, 35 ether, "zC should be untouched");
        assertEq(_order(oD).amountInRemaining, 20 ether, "oD should be untouched");

        // ...and then released. A batch that can never converge would otherwise
        // pin `oldestUnsettledEpoch` and take the whole Slow Lane with it, so
        // I11's `absoluteMaxDelay` escape has to reach the non-converged branch
        // and not only the infeasible-pool one.
        vm.roll(block.number + hook.absoluteMaxDelay() + 1);
        hook.forceSettle();
        assertGt(hook.oldestUnsettledEpoch(), 1, "a non-converging batch pinned the settlement cursor");
    }

    // ======================================================================
    // I11 — the liveness escape
    // ======================================================================

    /// @notice A pool that cannot be solved at all does not pin the cursor
    /// forever: past `absoluteMaxDelay` the batch is moved out of the way
    /// regardless.
    ///
    /// @dev Distinct from SR-1, and this is the distinction that matters: SR-1
    /// was a batch the solver *could* price and every order failed its limit;
    /// this is a batch the solver cannot price at all, because the pool has no
    /// liquidity to price it against. The first is a complete settlement with a
    /// fill ratio of zero. The second is not a settlement at all, so it is
    /// normally retried — and I11 is the cap on how long "retry later" may go
    /// on for.
    function test_I11_anUnsolvablePoolDoesNotPinTheCursorForever() public {
        // A one-sided batch has no coincidence of wants to fall back on, so
        // with no liquidity in range the solver has nothing to work with.
        _slowOrder(alice, true, 1e16, 1e15, 200);
        _slowOrder(bob, true, 1e16, 1e15, 200);
        _addLiquidity(-6000, 6000, -100 ether);

        // Past the forced gate but well inside the absolute one: the batch is
        // retried and correctly stays put.
        vm.roll(block.number + hook.maxDelay() + 1);
        hook.forceSettle();
        assertEq(hook.oldestUnsettledEpoch(), 1, "an unsolvable batch should be retried, not discarded");

        // Past the absolute bound, it steps aside whether or not it could be
        // priced.
        vm.roll(block.number + hook.absoluteMaxDelay() + 1);
        hook.forceSettle();
        assertGt(hook.oldestUnsettledEpoch(), 1, "I11: an unsolvable batch pinned the cursor past its hard bound");
    }

    // ======================================================================
    // Piggyback isolation
    // ======================================================================

    /// @notice A settlement that reverts never takes the carrying swap with it.
    ///
    /// @dev The revert is injected rather than provoked, and deliberately so:
    /// what is under test is the *boundary*, not any particular cause. A
    /// Fast-Lane trader volunteered gas to carry someone else's batch; they did
    /// not volunteer to have their own swap fail because that batch was
    /// degenerate. Settlement is reached through an external self-call purely
    /// so that `revert` can be its refusal mechanism, and this asserts the two
    /// halves of that: the swap succeeds, and the failure is announced rather
    /// than swallowed silently.
    function test_aRevertingSettlementDoesNotBreakTheCarryingSwap() public {
        _slowOrder(alice, true, 1e16, 1e15, 200);
        _slowOrder(bob, false, 1e16, 1e15, 200);

        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);

        vm.mockCallRevert(
            address(hook), abi.encodeWithSelector(KesselHook.settleFromCallback.selector), "settlement is broken"
        );

        vm.expectEmit(true, false, false, false, address(hook));
        emit KesselEvents.SettlementSkipped(1);

        uint256 before = IERC20Like(Currency.unwrap(currency1)).balanceOf(address(this));
        _fastSwap(true, -1e15);
        assertGt(
            IERC20Like(Currency.unwrap(currency1)).balanceOf(address(this)),
            before,
            "the carrying swap did not complete"
        );

        // Nothing was settled, and the batch is still there to try again.
        vm.clearMockedCalls();
        assertEq(hook.oldestUnsettledEpoch(), 1, "a skipped settlement advanced the cursor anyway");

        vm.roll(block.number + 1);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);
        assertGt(hook.oldestUnsettledEpoch(), 1, "the batch did not settle once settlement worked again");
    }

    // ======================================================================
    // quoteFill
    // ======================================================================

    /// @notice `quoteFill` reports "nothing to fill" rather than a stale or
    /// zero-sized quote, in each of the states where no fill is possible.
    ///
    /// @dev Fillers front capital against this quote before calling — the
    /// deliver-first model gives them no callback in which to check — so a
    /// quote that said "yes, deliver 0" would invite a delivery that then
    /// reverts, or worse, a delivery against a batch that is not there.
    function test_quoteFillRefusesWhenThereIsNothingToFill() public {
        // Nothing submitted at all.
        (bool ok,,,,) = hook.quoteFill();
        assertFalse(ok, "quoted a fill with no batch open");

        // Submitted, but not yet old enough to settle (`minSettleAge`).
        _slowOrder(alice, true, 1e16, 1e15, 200);
        (ok,,,,) = hook.quoteFill();
        assertFalse(ok, "quoted a fill before the batch was due");

        // Due, but paused.
        vm.roll(block.number + 10);
        vm.prank(governance);
        hook.setPaused(true);
        (ok,,,,) = hook.quoteFill();
        assertFalse(ok, "quoted a fill while paused");
    }

    /// @notice A batch that clears entirely against itself has no residual, so
    /// there is nothing for a filler to deliver and the quote says so.
    ///
    /// @dev The coincidence-of-wants case is the one where "no fill available"
    /// and "no batch" look identical from outside and are completely different
    /// inside: there is a full, healthy, settleable batch here. It just does
    /// not need a counterparty.
    function test_quoteFillRefusesAPerfectlyMatchedBatch() public {
        _slowOrder(alice, true, 1e16, 1e15, 200);
        _slowOrder(bob, false, 1e16, 1e15, 200);
        vm.roll(block.number + 10);

        (bool ok,, uint256 minDeliver,, uint256 payout) = hook.quoteFill();
        assertFalse(ok, "a fully matched batch needs no filler");
        assertEq(minDeliver, 0, "a refusal must quote nothing");
        assertEq(payout, 0, "a refusal must quote nothing");
    }

    /// @notice And a batch that *does* need a counterparty quotes a real one.
    /// The refusals above are only meaningful against this.
    function test_quoteFillQuotesARealResidual() public {
        _slowOrder(alice, true, 1e16, 1e15, 200);
        vm.roll(block.number + 10);

        (bool ok, Currency outCurrency, uint256 minDeliver, Currency inCurrency, uint256 payout) = hook.quoteFill();
        assertTrue(ok, "a one-sided batch must be fillable");
        assertEq(Currency.unwrap(outCurrency), Currency.unwrap(currency1), "wrong delivery currency");
        assertEq(Currency.unwrap(inCurrency), Currency.unwrap(currency0), "wrong payment currency");
        assertGt(minDeliver, 0, "a real quote must ask for something");
        assertGt(payout, 0, "a real quote must pay something");
    }

    // ======================================================================
    // The external fill on a batch with no residual
    // ======================================================================

    /// @notice `settleWithFill` on a perfectly matched batch settles it with no
    /// delivery and no payment.
    ///
    /// @dev The filler path is a *substitute* for the curve, not an addition to
    /// it, so a batch that needs neither must complete without touching either.
    /// Getting this wrong in the safe direction would revert on an honest
    /// filler; getting it wrong in the unsafe direction would pay a filler for
    /// delivering nothing.
    function test_anExternalFillOfAMatchedBatchMovesNoTokens() public {
        _slowOrder(alice, true, 1e16, 1e15, 200);
        _slowOrder(bob, false, 1e16, 1e15, 200);
        vm.roll(block.number + 10);

        uint256 before0 = IERC20Like(Currency.unwrap(currency0)).balanceOf(carol);
        uint256 before1 = IERC20Like(Currency.unwrap(currency1)).balanceOf(carol);

        vm.prank(carol);
        hook.settleWithFill(0);

        assertGt(hook.oldestUnsettledEpoch(), 1, "the matched batch did not settle");
        assertEq(IERC20Like(Currency.unwrap(currency0)).balanceOf(carol), before0, "the filler was paid for nothing");
        assertEq(IERC20Like(Currency.unwrap(currency1)).balanceOf(carol), before1, "the filler was paid for nothing");
        assertGt(_order(1).owedOut, 0, "the batch settled without paying its traders");
        assertGt(_order(2).owedOut, 0, "the batch settled without paying its traders");
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    /// @dev Advance the order past both halves of the expiry test: the epoch
    /// budget, by settling enough later batches that `currentEpoch` overtakes
    /// its `epochExpiry`, and the block-age floor that stops an attacker
    /// churning epochs to force an early refund
    /// (`AdversarialTest.test_epochChurnCannotExpireAnOrderEarly`).
    function _churnPastExpiry(
        uint256 id
    ) internal {
        for (uint256 i; i < 3; ++i) {
            _slowOrder(bob, true, 1e15, 1, 8);
            vm.roll(block.number + 5);
            _setPriorityFee(1 gwei);
            _fastSwap(true, -1e15);
        }

        OrderView memory v = _order(id);
        assertEq(v.owedOut, 0, "setup: an unreachable order should never have filled");
        assertGt(hook.currentEpoch(), v.epochExpiry, "setup: order should be past its epoch budget");

        vm.roll(block.number + hook.maxDelay());
    }

    function _bal(
        Currency c,
        address who
    ) internal view returns (uint256) {
        return IERC20Like(Currency.unwrap(c)).balanceOf(who);
    }
}
