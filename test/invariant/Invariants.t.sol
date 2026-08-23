// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Skeleton for the twelve protocol invariants (PRD §5.4, §13, §15).
///
/// Every invariant is present as a stub from Phase 0 onward, and every stub is
/// skipped with the reason it cannot run yet. The intent is that `forge test`
/// output is a live checklist: an invariant that is not yet enforced is visible
/// as skipped rather than absent, so it cannot be quietly forgotten.
///
/// As each phase lands, replace the corresponding `vm.skip` with a real
/// assertion and delete the note. Do NOT delete a stub to make the output
/// cleaner.
///
/// Test-form note (see reconnaissance §03): I4, I6, I8 and I12 are properties of
/// pure functions and belong in `test/property/` against `Clearing` and
/// `FastLaneFee` directly. They are listed here for completeness of the
/// checklist; the stubs point at their eventual home.
contract InvariantsTest is Test {
    // -----------------------------------------------------------------------
    // Safety invariants
    // -----------------------------------------------------------------------

    /// I1 -- delta settlement. The hook never leaves an unsettled delta when it
    /// returns control.
    ///
    /// NOTE: PRD §5.4 words I1 as "every transaction the hook participates in
    /// ends with NonzeroDeltaCount == 0". That counter is global to the unlock
    /// and includes the router's own obligations, which the hook does not
    /// control. This stub is written against the testable form -- the hook's
    /// OWN deltas resolve -- and the discrepancy is raised for human review
    /// (recon finding D). Do not implement against the literal wording without
    /// a decision.
    function invariant_I1_hookDeltasAlwaysResolve() public {
        vm.skip(true); // Phase 2: needs Slow-Lane intake.
    }

    /// I2 -- custody conservation. Per currency, inputs held == claims
    /// outstanding, across submit -> settle -> redeem and submit -> refund.
    function invariant_I2_custodyConserved() public {
        vm.skip(true); // Phase 2: needs OrderBook + custody.
    }

    /// I3 -- no double settle. pending -> (settled | refunded) exactly once;
    /// settled -> redeemed exactly once.
    function invariant_I3_noDoubleSettle() public {
        vm.skip(true); // Phase 3: needs the status machine and settlement.
    }

    /// I4 -- uniform price. Every order in a settlement event clears at one
    /// price P, applied identically to CoW-matched and residual-executed orders.
    function invariant_I4_uniformClearingPrice() public {
        vm.skip(true); // Phase 3, and belongs in test/property/ -- blocked on DD-5.
    }

    /// I5 -- fee routing. Fast-Lane premium and Slow-Lane fee both reach LPs.
    function invariant_I5_feesReachLPs() public {
        vm.skip(true); // Phase 1 (fast side); Phase 3 (slow side, blocked on recon finding B).
    }

    /// I6 -- settlement-time pricing / anti-hedging. No code path computes a
    /// Slow-Lane fill from submission-time state.
    ///
    /// Intended enforcement is structural rather than assertive: if `Clearing`
    /// does not accept submission-block state as an argument, this cannot be
    /// violated. This stub exists to record that intent.
    function invariant_I6_settlementTimePricingOnly() public {
        vm.skip(true); // Phase 3: blocked on DD-5.
    }

    /// I7 -- recapture integrity. No mechanism-introduced intermediary captures
    /// the Fast-Lane premium; any keeper draws only a capped reimbursement
    /// sourced from f_slow.
    function invariant_I7_noPremiumCapturingIntermediary() public {
        vm.skip(true); // Phase 3/4: blocked on DD-7 (whether a keeper exists at all).
    }

    /// I8 -- bounded trader downside. A Slow-Lane trader never receives less
    /// than their minOut, or is handled per the failed-minOut policy.
    function invariant_I8_minOutRespected() public {
        vm.skip(true); // Phase 3, belongs in test/property/ -- blocked on DD-11.
    }

    /// I9 -- warehoused exposure bound. Aggregate un-settled Slow-Lane notional
    /// per direction stays within MAX_WAREHOUSE.
    ///
    /// NOTE: "notional" has no permitted numeraire -- PRD §9 forbids an oracle,
    /// so no cross-asset unit of account is available. Pending a decision this
    /// must be read as input-token units per currency (recon finding C).
    function invariant_I9_warehouseCapHolds() public {
        vm.skip(true); // Phase 2: needs intake; unit of account needs a decision.
    }

    /// I10 -- slow-fee bound. 0 <= f_slow < f_base at all times, under any
    /// subsidy state.
    function invariant_I10_slowFeeWithinBounds() public {
        vm.skip(true); // Phase 1: needs Params. Enforced on every write.
    }

    /// I12 -- fee monotonicity. g(p2, .) >= g(p1, .) for p2 > p1, tested against
    /// a deliberately mis-specified g as well as the real one.
    function invariant_I12_feeMonotoneInPriorityFee() public {
        vm.skip(true); // Phase 1, belongs in test/property/ -- blocked on DD-2 and DD-4.
    }

    // -----------------------------------------------------------------------
    // Liveness invariant
    // -----------------------------------------------------------------------

    /// I11 -- bounded settlement. Every pending order becomes settleable within
    /// MAX_DELAY, after which permissionless force-settle is callable.
    ///
    /// This is a liveness property, not a safety one: it is not an
    /// instantaneous predicate over state and is exercised as a scenario rather
    /// than a stateful invariant run.
    function invariant_I11_boundedSettlementLiveness() public {
        vm.skip(true); // Phase 3: blocked on DD-6/DD-7.
    }
}
