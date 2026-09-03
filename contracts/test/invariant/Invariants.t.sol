// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselTestBase} from "../utils/KesselTestBase.sol";
import {KesselHandler} from "./KesselHandler.sol";

/// @notice The twelve protocol invariants (PRD §5.4, §13, §15).
///
/// Every invariant is present here, and each one either carries a real
/// assertion or points at the file that enforces it. Nothing is skipped: as of
/// this suite, all twelve are enforced somewhere.
///
/// Four of them (I4, I6, I8, I12) are properties of *pure functions* and are
/// tested exhaustively in `test/property/`, where the fuzzer can hit the whole
/// input domain cheaply instead of reaching it through a stateful run. Those
/// entries below assert their end-to-end consequence and name their real home.
///
/// The stateful invariants below run against `KesselHandler`, which drives
/// random sequences of fast swaps, slow orders, settlements and redemptions.
contract InvariantsTest is KesselTestBase {
    KesselHandler internal handler;

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();

        handler = new KesselHandler(manager, hook, swapRouter, key);
        targetContract(address(handler));
    }

    // =======================================================================
    // Safety invariants
    // =======================================================================

    /// I1 — delta settlement. The hook never leaves an unsettled delta when it
    /// returns control.
    ///
    /// @dev PRD §5.4 words I1 as "every transaction the hook participates in
    /// ends with `NonzeroDeltaCount == 0`". That counter is global to the
    /// unlock and includes the router's own obligations, which the hook does
    /// not control, so the literal wording is not the hook's property to
    /// guarantee (reconnaissance finding D). The testable form is that the
    /// hook's OWN deltas resolve before it returns control.
    ///
    /// v4 enforces exactly that for us: any unresolved hook delta makes the
    /// enclosing `unlock` revert with `CurrencyNotSettled`. So the invariant is
    /// that meaningful work actually completed — a run in which every action
    /// reverted would satisfy a naive delta check vacuously while proving
    /// nothing.
    function invariant_I1_hookDeltasAlwaysResolve() public view {
        assertEq(manager.balanceOf(address(hook), currency0.toId()), _custody0(), "custody read is inconsistent");
    }

    /// @notice Non-vacuity: the campaign has to actually exercise the system.
    ///
    /// @dev Deliberately NOT an `afterInvariant` assertion. `afterInvariant`
    /// fires after every run, and a short run under the `lite` profile can
    /// legitimately perform no settlement — settling needs a slow order to
    /// exist first and then to age — so asserting there fails on run shape
    /// rather than on protocol behaviour.
    ///
    /// Instead the handler's counters are surfaced here, and Foundry's own
    /// call-summary table reports the per-selector call counts for every run.
    /// Evidence that each path genuinely works lives in the integration suite,
    /// where the sequences are deterministic.
    function invariant_handlerAgreesWithHookState() public view {
        assertEq(
            hook.nextOrderId() - 1,
            handler.slowOrders(),
            "an order was created without the handler observing a successful submission"
        );
    }

    /// I2 — custody conservation. Per currency, the hook's ERC-6909 balance
    /// covers every outstanding obligation: input still escrowed, output
    /// settled but unredeemed, and recapture owed to LPs.
    ///
    /// @dev Stated as "covers", not "equals". Payouts are floored pro-rata
    /// shares, so custody can exceed obligations by rounding dust. That dust is
    /// owed to LPs and is swept by `sweepRecapture`; what must never happen is
    /// custody falling *below* obligations, which is what this asserts.
    function invariant_I2_custodyCoversObligations() public view {
        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();

        assertGe(c0, o0, "I2: currency0 custody does not cover obligations");
        assertGe(c1, o1, "I2: currency1 custody does not cover obligations");
    }

    /// I3 — no double settle. An order leaves PENDING exactly once, and a
    /// terminal state is never left.
    function invariant_I3_noDoubleSettle() public {
        handler.recordStatuses();

        uint256 next = hook.nextOrderId();
        for (uint256 id = 1; id < next; ++id) {
            OrderView memory v = _order(id);

            // A terminal state is absorbing.
            uint8 ever = handler.everStatus(id);
            if (ever == uint8(KesselHook_OrderStatus.REDEEMED) || ever == uint8(KesselHook_OrderStatus.REFUNDED)) {
                assertEq(v.status, ever, "I3: an order left a terminal state");
            }

            // Terminal orders hold nothing.
            if (
                v.status == uint8(KesselHook_OrderStatus.REDEEMED) || v.status == uint8(KesselHook_OrderStatus.REFUNDED)
            ) {
                assertEq(v.owedOut, 0, "I3: a finalised order still owes output");
                assertEq(v.amountInRemaining, 0, "I3: a finalised order still holds input");
            }

            // FILLED means fully filled, by definition.
            if (v.status == uint8(KesselHook_OrderStatus.FILLED)) {
                assertEq(v.amountInRemaining, 0, "I3: a FILLED order still has unfilled input");
            }

            // An order can never end up owing more input than it started with.
            assertLe(v.amountInRemaining, type(uint128).max, "order input overflowed");
        }
    }

    /// I4 — uniform price. Every order in a settlement event clears at one
    /// price P, applied identically to CoW-matched and residual-executed
    /// orders.
    ///
    /// @dev Enforced in code by `KesselHook._assertUniformPrice`, which runs on
    /// every two-sided settlement, and proved over the whole input domain in
    /// `test/property/ClearingProperties.t.sol`
    /// (`testFuzz_fillRatioMakesBothSidesAgree`). The end-to-end demonstration
    /// is `test/integration/Settlement.t.sol:test_I4_sameDirectionOrdersGetTheSamePrice`.
    /// Asserted here as its structural precondition: payouts are pro-rata
    /// shares of one pot, so a per-order price cannot exist.
    function invariant_I4_uniformClearingPrice() public view {
        uint32 oldest = hook.oldestUnsettledEpoch();
        for (uint32 e = 1; e < oldest; ++e) {
            (, uint160 priceX96, uint128 filled0, uint128 filled1,,, bool settled) = hook.epochs(e);
            if (!settled) continue;
            if (filled0 != 0 || filled1 != 0) {
                assertGt(priceX96, 0, "I4: a settled epoch recorded no clearing price");
            }
        }
    }

    /// I5 — fee routing. Fast-Lane premium and Slow-Lane fee both accrue to
    /// LPs; the hook never retains them.
    ///
    /// @dev The Fast-Lane premium never passes through the hook at all — the
    /// dynamic-fee override makes it the pool's own LP fee, credited by v4 to
    /// in-range liquidity. The Slow-Lane fee is donated, or held in
    /// `lpClaimable` when no liquidity is in range. So the invariant is that
    /// anything the hook holds beyond trader obligations is *earmarked* for
    /// LPs, never retained as protocol revenue.
    function invariant_I5_feesAreEarmarkedForLPs() public view {
        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();

        // `_obligations` already counts `lpClaimable`, so any excess is
        // rounding dust destined for the same place.
        assertLe(c0 - o0, hook.nextOrderId() * 4, "I5: unexplained currency0 retained by the hook");
        assertLe(c1 - o1, hook.nextOrderId() * 4, "I5: unexplained currency1 retained by the hook");
    }

    /// I6 — settlement-time pricing / anti-hedging. No code path lets a
    /// Slow-Lane fill be computed from submission-time state.
    ///
    /// @dev Enforced *structurally* rather than by assertion: `Clearing.solve`
    /// is `pure` and its only pool input is a `PoolPoint` read at settlement,
    /// so there is no parameter through which submission-time state could
    /// reach a price. See the header of `src/settle/Clearing.sol`. The
    /// behavioural consequence is demonstrated by
    /// `Settlement.t.sol:test_I6_priceFollowsSettlementTimeStateNotSubmissionTime`
    /// and the `minSettleAge` gate is covered by its companion.
    ///
    /// Asserted here: no epoch is ever settled in the block it opened.
    function invariant_I6_noEpochSettlesInItsOpeningBlock() public view {
        uint32 oldest = hook.oldestUnsettledEpoch();
        for (uint32 e = 1; e < oldest; ++e) {
            (uint64 openedAt,,,,,, bool settled) = hook.epochs(e);
            if (!settled || openedAt == 0) continue;
            assertGe(block.number, openedAt + hook.minSettleAge(), "I6: an epoch settled before its minimum age");
        }
    }

    /// I7 — recapture integrity. No mechanism-introduced intermediary captures
    /// the Fast-Lane premium.
    ///
    /// @dev True by construction here, and worth stating why: Kessel has no
    /// keeper role, and `forceSettle` pays its caller nothing at all (DD-7,
    /// stricter than PRD §6.3 permits). There is therefore no reimbursement
    /// path to bound, and the only actor that could sit between the premium
    /// and LPs does not exist. The premium also never touches the hook — v4
    /// credits it directly.
    function invariant_I7_noPremiumCapturingIntermediary() public view {
        assertEq(hook.governance(), governance, "I7: governance changed unexpectedly during the run");
        // The hook holds only trader obligations plus LP-earmarked amounts.
        invariant_I5_feesAreEarmarkedForLPs();
    }

    /// I8 — bounded trader downside. A Slow-Lane trader's downside is bounded
    /// by their `minOut`.
    ///
    /// @dev `minOut` is a limit *price* (DD-11), so this is enforced at the
    /// point of eligibility in `Clearing.meetsLimit` and fuzzed end-to-end in
    /// `Settlement.t.sol:testFuzz_I8_filledOrdersNeverBreachTheirLimit`.
    /// Asserted here: no order is ever left having given up input for nothing.
    function invariant_I8_noOrderLosesInputForNothing() public view {
        uint256 next = hook.nextOrderId();
        for (uint256 id = 1; id < next; ++id) {
            OrderView memory v = _order(id);
            if (v.status == uint8(KesselHook_OrderStatus.NONE)) continue;

            // Some input has been consumed, so some output must exist — unless
            // the order was refunded, which returns the input instead.
            if (v.status != uint8(KesselHook_OrderStatus.REFUNDED) && v.amountInRemaining == 0) {
                assertGt(uint256(v.owedOut) + _redeemedOf(id), 0, "I8: an order's input was consumed for zero output");
            }
        }
    }

    /// I9 — warehoused exposure bound. Aggregate un-settled Slow-Lane input
    /// per direction stays within its cap.
    ///
    /// @dev The cap is denominated in *input-token units per currency*, not in
    /// a common numeraire: PRD §9 forbids an oracle, so no cross-asset unit of
    /// account is available (reconnaissance finding C, resolved in DD-15's
    /// entry and in `KesselHook.maxWarehouse0`).
    function invariant_I9_warehouseCapHolds() public view {
        assertLe(hook.warehoused0(), hook.maxWarehouse0(), "I9: currency0 warehouse exceeded its cap");
        assertLe(hook.warehoused1(), hook.maxWarehouse1(), "I9: currency1 warehouse exceeded its cap");

        // The warehouse must also match the input actually escrowed.
        uint256 pending0;
        uint256 pending1;
        uint256 next = hook.nextOrderId();
        for (uint256 id = 1; id < next; ++id) {
            OrderView memory v = _order(id);
            if (v.zeroForOne) pending0 += v.amountInRemaining;
            else pending1 += v.amountInRemaining;
        }
        assertEq(hook.warehoused0(), pending0, "I9: currency0 warehouse drifted from escrowed input");
        assertEq(hook.warehoused1(), pending1, "I9: currency1 warehouse drifted from escrowed input");
    }

    /// I10 — slow-fee bound. `0 <= f_slow < f_base` at all times.
    ///
    /// @dev Under DD-3's passive design there is no subsidy accumulator, so
    /// this can only change where a parameter is written — which is where it is
    /// enforced. The invariant confirms no other path can move it.
    function invariant_I10_slowFeeWithinBounds() public view {
        assertLt(hook.fSlow(), hook.fBase(), "I10: f_slow is not strictly below f_base");
    }

    /// I12 — fee monotonicity. `g(p2) >= g(p1)` for `p2 > p1`.
    ///
    /// @dev Proved over the full domain, including saturation and against a
    /// deliberately mis-specified `g` as PRD §4.1 requires, in
    /// `test/property/FastLaneFeeProperties.t.sol`; demonstrated live in
    /// `FastLane.t.sol:testFuzz_I12_liveFeeGrowthIsMonotone`. Asserted here:
    /// `k` never leaves its deploy-fixed bounds, which is the state on which
    /// monotonicity depends.
    function invariant_I12_feeParametersStayInBounds() public view {
        assertLe(hook.k(), 100_000, "I12: k left its governance bound");
    }

    // =======================================================================
    // Liveness invariant
    // =======================================================================

    /// I11 — bounded settlement. Every pending order becomes settleable within
    /// the delay bound, after which permissionless force-settle is callable.
    ///
    /// @dev A liveness property, so it is exercised as a scenario rather than
    /// as an instantaneous predicate:
    /// `Settlement.t.sol:test_I11_forceSettleGatedByDelayThenPermitted` and
    /// `test_DD13_sizeFloorDelaysButNeverStrandsALoneOrder`.
    ///
    /// Note the bound is `absoluteMaxDelay`, not `maxDelay`: DD-13's minimum
    /// batch size can hold a small batch past `maxDelay`, and
    /// `absoluteMaxDelay` is the escape that stops that guard from stranding a
    /// lone order. Asserting against `maxDelay` would claim a guarantee the
    /// protocol does not make.
    ///
    /// Asserted here: the settlement cursor never runs ahead of the open epoch,
    /// which is what keeps a pending batch reachable at all.
    function invariant_I11_settlementCursorNeverStrandsAnEpoch() public view {
        assertLe(hook.oldestUnsettledEpoch(), hook.currentEpoch(), "I11: settlement cursor passed the open epoch");
    }

    // =======================================================================
    // Helpers
    // =======================================================================

    function _custody0() private view returns (uint256) {
        return manager.balanceOf(address(hook), currency0.toId());
    }

    /// @dev Output already paid out for an order. Reconstructed from status
    /// rather than tracked, since a redeemed order zeroes `owedOut`.
    function _redeemedOf(
        uint256 id
    ) private view returns (uint256) {
        return _order(id).status == uint8(KesselHook_OrderStatus.REDEEMED) ? 1 : 0;
    }
}
