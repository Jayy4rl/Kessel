// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Slow-Lane settlement (PRD §3.3, §4.3, §8.3, §10).
///
/// Covers I3 (no double settle), I4 (uniform price), I6 (settlement-time
/// pricing), I8 (bounded downside), I11 (liveness) and both settlement entry
/// paths of PRD §8.3.
contract SettlementTest is KesselTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _setPriorityFee(1 gwei);
    }

    /// @dev Age the batch past `minSettleAge`, then trigger settlement the way
    /// the protocol intends: inside the `afterSwap` of a Fast-Lane swap.
    function _piggybackSettle() internal {
        vm.roll(vm.getBlockNumber() + 5);
        _fastSwap(true, -1e15); // small, so it barely moves the price itself
    }

    // ======================================================================
    // I4 — one price for the whole batch
    // ======================================================================

    /// @notice Two same-direction orders of different sizes receive the same
    /// price per unit of input.
    ///
    /// @dev This is the property that makes the Slow Lane sandwich-proof
    /// (PRD §7.1): with one price for everyone, there is no ordering advantage
    /// inside a batch to extract.
    function test_I4_sameDirectionOrdersGetTheSamePrice() public {
        uint256 small = 1e16;
        uint256 large = 7e16;

        uint256 idSmall = _slowOrder(alice, true, small, 1, 8);
        uint256 idLarge = _slowOrder(bob, true, large, 1, 8);

        _piggybackSettle();

        OrderView memory a = _order(idSmall);
        OrderView memory b = _order(idLarge);
        assertGt(a.owedOut, 0, "small order was not filled");
        assertGt(b.owedOut, 0, "large order was not filled");

        uint256 priceA = FullMath.mulDiv(a.owedOut, Q96, small);
        uint256 priceB = FullMath.mulDiv(b.owedOut, Q96, large);
        _assertRelClose(priceA, priceB, 1e9, "I4: batch members received different prices");
    }

    /// @notice An adversary who places orders around a victim in the same batch
    /// gains nothing (PRD §15 scenario 3).
    ///
    /// @dev The intra-batch sandwich attempt. Submission order within the batch
    /// is irrelevant because everyone clears at one price, so the attacker's
    /// two legs receive exactly the rate the victim does.
    function test_intraBatchSandwichGainsNothing() public {
        uint256 attackerFront = _slowOrder(carol, true, 5e16, 1, 8);
        uint256 victim = _slowOrder(alice, true, 5e16, 1, 8);
        uint256 attackerBack = _slowOrder(carol, true, 5e16, 1, 8);

        _piggybackSettle();

        uint256 front = _order(attackerFront).owedOut;
        uint256 back = _order(attackerBack).owedOut;
        uint256 vic = _order(victim).owedOut;

        assertGt(vic, 0, "victim was not filled");
        _assertRelClose(front, vic, 1e9, "front-run leg got a different price");
        _assertRelClose(back, vic, 1e9, "back-run leg got a different price");
        _assertRelClose(front, back, 1e9, "the attacker's two legs differ");
    }

    // ======================================================================
    // Coincidence of wants
    // ======================================================================

    /// @notice Opposing orders net against each other, leaving the curve
    /// almost untouched — that is what the delay buys the trader (PRD §4.3).
    function test_opposingOrdersNetAgainstEachOther() public {
        (uint160 priceBefore,,,) = manager.getSlot0(poolId);

        _slowOrder(alice, true, 5e16, 1, 8);
        _slowOrder(bob, false, 5e16, 1, 8);

        // Settle without a price-moving trigger, so any movement observed is
        // attributable to the batch rather than to the trigger.
        vm.roll(vm.getBlockNumber() + 400);
        hook.forceSettle();

        (uint160 priceAfter,,,) = manager.getSlot0(poolId);
        _assertRelClose(priceAfter, priceBefore, 1e6, "a matched batch moved the pool materially");

        assertGt(_order(1).owedOut, 0, "currency0 seller unfilled");
        assertGt(_order(2).owedOut, 0, "currency1 seller unfilled");
    }

    // ======================================================================
    // I6 — settlement-time pricing
    // ======================================================================

    /// @notice A batch cannot be settled in the block it was opened.
    ///
    /// @dev `minSettleAge` is the guard that stops submit-and-settle in one
    /// transaction, which would let a Slow-Lane trader approximate a
    /// submission-time price and erode I6.
    function test_I6_batchCannotSettleBeforeMinAge() public {
        _slowOrder(alice, true, 1e16, 1, 8);

        _fastSwap(true, -1e15); // same block: too young

        assertEq(_order(1).owedOut, 0, "batch settled in its opening block");

        vm.roll(vm.getBlockNumber() + 5);
        _fastSwap(true, -1e15);

        assertGt(_order(1).owedOut, 0, "batch failed to settle once aged");
    }

    /// @notice The clearing price tracks the pool at settlement, not at
    /// submission.
    ///
    /// @dev Moving the pool between submission and settlement must change the
    /// fill. If it did not, the fill would have been fixed at submission —
    /// exactly the hedgeable basis PRD §7.2 prohibits.
    function test_I6_priceFollowsSettlementTimeStateNotSubmissionTime() public {
        uint256 snap = vm.snapshotState();

        _slowOrder(alice, true, 1e16, 1, 8);
        _piggybackSettle();
        uint256 undisturbed = _order(1).owedOut;

        vm.revertToState(snap);

        _slowOrder(alice, true, 1e16, 1, 8);
        vm.roll(vm.getBlockNumber() + 5);
        _fastSwap(true, -5e17); // move the pool against the batch, then settle
        uint256 disturbed = _order(1).owedOut;

        assertGt(undisturbed, 0, "control run did not fill");
        assertGt(disturbed, 0, "disturbed run did not fill");
        assertLt(disturbed, undisturbed, "I6: fill ignored settlement-time pool state");
    }

    // ======================================================================
    // I8 / DD-11 — limit prices
    // ======================================================================

    /// @notice An order whose limit the batch price does not meet is not
    /// filled, and rolls instead (DD-11).
    function test_I8_orderAboveTheClearingPriceIsNotFilled() public {
        // Demand far more output than the pool can give: unreachable limit.
        uint256 greedy = _slowOrder(alice, true, 1e16, 5e16, 8);
        uint256 reasonable = _slowOrder(bob, true, 1e16, 1, 8);

        _piggybackSettle();

        OrderView memory g = _order(greedy);
        assertEq(g.owedOut, 0, "I8: an order filled below its limit price");
        assertEq(g.amountInRemaining, 1e16, "unfilled order lost input");
        assertEq(g.status, uint8(KesselHook_OrderStatus.PENDING), "unfilled order should roll, not finalise");

        assertGt(_order(reasonable).owedOut, 0, "the reachable order should still fill");
    }

    /// @notice Every filled order receives at least its stated minimum, pro
    /// rata to the portion actually filled (I8).
    function testFuzz_I8_filledOrdersNeverBreachTheirLimit(
        uint96 amountSeed,
        uint16 limitBps
    ) public {
        uint256 amountIn = bound(amountSeed, 1e14, 5e16);
        // Ask for between 50% and ~99% of parity, so some runs fill and some do not.
        uint256 minOut = FullMath.mulDiv(amountIn, bound(limitBps, 5_000, 9_900), 10_000);

        uint256 id = _slowOrder(alice, true, amountIn, uint128(minOut), 8);
        _piggybackSettle();

        OrderView memory v = _order(id);
        if (v.owedOut == 0) return; // rolled: nothing to check

        uint256 filledIn = amountIn - v.amountInRemaining;
        // The limit is a price, so the guarantee scales with the filled portion.
        uint256 required = FullMath.mulDiv(minOut, filledIn, amountIn);
        assertGe(v.owedOut + 2, required, "I8: fill breached the order's limit price");
    }

    // ======================================================================
    // Redemption and custody (DD-15, I2, I3)
    // ======================================================================

    function test_redemptionPaysTheTraderAndIsIdempotentlyGuarded() public {
        uint256 id = _slowOrder(alice, true, 5e16, 1, 8);
        _piggybackSettle();

        uint256 owed = _order(id).owedOut;
        assertGt(owed, 0, "order did not fill");

        uint256 before = _bal(currency1, alice);
        hook.redeem(id); // permissionless caller, fixed destination
        assertEq(_bal(currency1, alice) - before, owed, "trader did not receive the settled output");

        assertEq(_statusOf(id) == KesselHook_OrderStatus.REDEEMED, true, "status should be REDEEMED");

        // I3: settled -> redeemed happens exactly once.
        vm.expectRevert();
        hook.redeem(id);
    }

    /// @notice Redemption sends output to the recorded trader even when a third
    /// party pays the gas (PRD §11 case 5).
    function test_redemptionDestinationCannotBeRedirected() public {
        uint256 id = _slowOrder(alice, true, 5e16, 1, 8);
        _piggybackSettle();

        uint256 aliceBefore = _bal(currency1, alice);
        uint256 carolBefore = _bal(currency1, carol);

        vm.prank(carol);
        hook.redeem(id);

        assertGt(_bal(currency1, alice), aliceBefore, "trader was not paid");
        assertEq(_bal(currency1, carol), carolBefore, "the caller received the trader's output");
    }

    /// @notice I2 across the whole lifecycle: submit -> settle -> redeem.
    ///
    /// @dev Custody must always cover obligations. It may exceed them by
    /// rounding dust, since payouts are floored pro-rata shares; that dust is
    /// owed to LPs, never kept, and is bounded by the order count.
    function test_I2_custodyCoversObligationsThroughTheWholeLifecycle() public {
        uint256 id0 = _slowOrder(alice, true, 4e16, 1, 8);
        uint256 id1 = _slowOrder(bob, false, 3e16, 1, 8);
        _assertCustodyCoversObligations();

        _piggybackSettle();
        _assertCustodyCoversObligations();

        hook.redeem(id0);
        _assertCustodyCoversObligations();

        hook.redeem(id1);
        _assertCustodyCoversObligations();
    }

    // ======================================================================
    // PRD §8.3 — the two entry paths
    // ======================================================================

    /// @notice Both settlement entry paths work: piggyback (already inside an
    /// unlock, direct `poolManager.swap`) and forced (its own `unlock`).
    ///
    /// @dev PRD §8.3 flags this as critical: a single settlement function that
    /// always calls `unlock` reverts on the piggyback path, because v4 forbids
    /// nesting. PRD §15 scenario 11 asks for exactly this pair of tests.
    function test_bothSettlementEntryPathsWork() public {
        // --- piggyback: inside the unlock of a Fast-Lane swap ---
        _slowOrder(alice, true, 2e16, 1, 8);
        _piggybackSettle();
        assertGt(_order(1).owedOut, 0, "piggyback path failed to settle");

        // --- forced: its own unlock, no surrounding context ---
        // Two orders, because DD-13's size floor holds a smaller batch back
        // until `absoluteMaxDelay`.
        _slowOrder(bob, true, 2e16, 1, 8);
        _slowOrder(carol, true, 2e16, 1, 8);
        vm.roll(vm.getBlockNumber() + 400);
        hook.forceSettle();
        assertGt(_order(2).owedOut, 0, "forced path failed to settle");
        assertGt(_order(3).owedOut, 0, "forced path filled only part of the batch");
    }

    /// @notice Settling inside `afterSwap` performs a nested swap on the very
    /// pool being swapped, and neither the trigger nor the settlement breaks
    /// (PRD §11 case 8).
    function test_nestedSwapDuringAfterSwapDoesNotCorruptTheTriggeringSwap() public {
        _slowOrder(alice, true, 3e16, 1, 8);
        vm.roll(vm.getBlockNumber() + 5);

        uint256 before = _bal(currency1, address(this));
        _fastSwap(true, -1e16);

        assertGt(_bal(currency1, address(this)), before, "the triggering swap did not deliver output");
        assertGt(_order(1).owedOut, 0, "the piggybacked batch did not settle");
    }

    // ======================================================================
    // I11 / DD-13 — liveness and griefing guards
    // ======================================================================

    /// @notice Force-settle is refused before the delay bound, and permitted
    /// after it.
    function test_I11_forceSettleGatedByDelayThenPermitted() public {
        _slowOrder(alice, true, 2e16, 1, 16);
        _slowOrder(bob, true, 2e16, 1, 16);

        assertFalse(hook.forceSettleDue(), "force-settle should not be due immediately");
        vm.expectRevert();
        hook.forceSettle();

        vm.roll(vm.getBlockNumber() + uint256(hook.maxDelay()) + 1);
        assertTrue(hook.forceSettleDue(), "force-settle should be due past maxDelay");

        hook.forceSettle();
        assertGt(_order(1).owedOut, 0, "forced settlement did not fill");
    }

    /// @notice DD-13: a batch below the size floor waits for the absolute
    /// bound, but is never stranded — which is why I11 is stated against
    /// `absoluteMaxDelay`.
    function test_DD13_sizeFloorDelaysButNeverStrandsALoneOrder() public {
        vm.prank(governance);
        hook.setCadence(2, 100, 1000, 3); // require 3 orders, or 1000 blocks

        _slowOrder(alice, true, 2e16, 1, 200);

        vm.roll(vm.getBlockNumber() + 150); // past maxDelay, below the size floor
        assertFalse(hook.forceSettleDue(), "size floor should hold a lone order back");
        vm.expectRevert();
        hook.forceSettle();

        vm.roll(vm.getBlockNumber() + 1000); // past absoluteMaxDelay: liveness escape
        assertTrue(hook.forceSettleDue(), "I11: a lone order was stranded past the absolute bound");

        hook.forceSettle();
        assertGt(_order(1).owedOut, 0, "lone order never settled");
    }

    /// @notice An empty batch is a no-op for the settlement core, never a
    /// revert (PRD §11 case 1).
    ///
    /// @dev Note the asymmetry between the two paths, which is intended.
    /// `forceSettle` is a gated entry point and refuses when nothing is due —
    /// telling a caller their transaction was pointless is better than silently
    /// consuming their gas. The piggyback path, which must never disturb the
    /// swap carrying it, does nothing at all.
    function test_emptyBatchIsANoOp() public {
        vm.roll(vm.getBlockNumber() + 500);

        vm.expectRevert();
        hook.forceSettle(); // gated: nothing pending

        _fastSwap(true, -1e15); // piggyback with nothing pending: silent no-op
        assertEq(hook.oldestUnsettledEpoch(), 1, "an empty batch should not advance the cursor");
    }

    /// @notice I3: a settled epoch is not settled twice, even when a piggyback
    /// and a forced settlement land in the same block (PRD §11 case 10).
    function test_I3_epochIsNotSettledTwice() public {
        uint256 id = _slowOrder(alice, true, 3e16, 1, 8);
        _piggybackSettle();

        uint256 owedAfterFirst = _order(id).owedOut;
        assertGt(owedAfterFirst, 0, "first settlement did not fill");

        // Try to settle the same epoch again by both routes. The forced path is
        // gated and refuses outright; the piggyback path runs and finds nothing
        // fillable.
        _fastSwap(true, -1e15);
        vm.roll(vm.getBlockNumber() + 500);
        vm.expectRevert();
        hook.forceSettle();

        assertEq(_order(id).owedOut, owedAfterFirst, "I3: the order was filled twice");
        assertEq(_order(id).amountInRemaining, 0, "a fully filled order should have no input left");
    }

    // ======================================================================
    // Expiry (DD-9 / DD-11)
    // ======================================================================

    /// @notice An order that can never fill becomes refundable after expiry,
    /// less the forfeit that keeps it from being a free option.
    function test_expiredOrderRefundsLessForfeit() public {
        uint256 amountIn = 2e16;
        uint256 id = _slowOrder(alice, true, amountIn, 5e16, 1); // unreachable limit

        // Advance epochs by settling repeatedly until the order is past expiry.
        for (uint256 i; i < 3; ++i) {
            _slowOrder(bob, true, 1e15, 1, 8);
            _piggybackSettle();
        }

        OrderView memory v = _order(id);
        assertEq(v.owedOut, 0, "an unreachable order should never fill");
        assertGt(hook.currentEpoch(), v.epochExpiry, "order should be past expiry by now");

        // Expiry has two halves: the epoch budget above, and a block-age floor
        // that stops an attacker churning epochs to force early refunds. See
        // `AdversarialTest.test_epochChurnCannotExpireAnOrderEarly`.
        vm.roll(vm.getBlockNumber() + hook.maxDelay());

        uint256 before = _bal(currency0, alice);
        hook.redeem(id);
        uint256 refunded = _bal(currency0, alice) - before;

        uint256 expectedForfeit = amountIn * hook.expiryForfeitBps() / 10_000;
        assertEq(refunded, amountIn - expectedForfeit, "refund did not net the forfeit");
        assertEq(_statusOf(id) == KesselHook_OrderStatus.REFUNDED, true, "status should be REFUNDED");
        assertEq(hook.lpClaimable0(), expectedForfeit, "the forfeit must be routed to LPs, not kept");
    }

    /// @notice The refund cannot be taken early — that would make the claim
    /// cancellable, which DD-9 forbids.
    function test_refundCannotBeTakenBeforeExpiry() public {
        uint256 id = _slowOrder(alice, true, 2e16, 5e16, 8);

        vm.expectRevert();
        hook.redeem(id);

        assertEq(_order(id).amountInRemaining, 2e16, "input escaped before expiry");
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    function _assertCustodyCoversObligations() private view {
        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertGe(c0, o0, "I2: custody0 does not cover obligations0");
        assertGe(c1, o1, "I2: custody1 does not cover obligations1");
        assertLe(c0 - o0, 64, "I2: currency0 surplus exceeds rounding dust");
        assertLe(c1 - o1, 64, "I2: currency1 surplus exceeds rounding dust");
    }

    function _bal(
        Currency c,
        address who
    ) private view returns (uint256) {
        return IERC20Bal(Currency.unwrap(c)).balanceOf(who);
    }

    function _assertRelClose(
        uint256 a,
        uint256 b,
        uint256 precision,
        string memory err
    ) private pure {
        if (a == b) return;
        uint256 diff = a > b ? a - b : b - a;
        uint256 scale = a > b ? a : b;
        assertLe(diff * precision, scale, err);
    }
}

interface IERC20Bal {
    function balanceOf(
        address
    ) external view returns (uint256);
}
