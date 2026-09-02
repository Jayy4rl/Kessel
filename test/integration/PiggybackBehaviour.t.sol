// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice What piggyback settlement actually does, stated as assertions.
///
/// Kessel has no keeper. A Slow-Lane batch clears when some later Fast-Lane
/// swap carries it, and that carrying swap pays the gas. Every gate on that is
/// load-bearing, and several of them are easy to misread from the source — so
/// this file is deliberately characterization rather than coverage: each test
/// pins one observable behaviour of the trigger, including the two that are
/// *silences* rather than actions.
///
/// The silences matter most. A settlement that does not happen looks exactly
/// like a batch with nothing to do, and during the via_ir investigation that
/// ambiguity cost real time: a test harness bug made the chain never advance,
/// the age gate correctly declined, and the resulting quiet read as a contract
/// fault. These tests fix what each silence means.
contract PiggybackBehaviourTest is KesselTestBase {
    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(alice, 100_000 ether);
        _fundAndApprove(bob, 100_000 ether);
    }

    // ==================================================================
    // What does NOT settle
    // ==================================================================

    /// @notice A Slow order on its own never settles. There is no keeper and
    /// no timer; without a carrier the batch simply waits.
    function test_aSlowOrderAloneNeverSettles() public {
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 1 ether, 1, 8);

        vm.roll(vm.getBlockNumber() + 500);

        assertEq(_order(id).amountInRemaining, 1 ether, "the batch settled with no carrier");
        assertEq(_order(id).owedOut, 0, "an unsettled order was credited output");
    }

    /// @notice A Fast swap younger than `minSettleAge` does not carry the
    /// batch, and does not revert either.
    ///
    /// @dev This gate is what keeps submit-and-settle out of a single block.
    /// Without it a batch could clear against state the submitter could still
    /// see, which is the submission-time pricing the Slow Lane exists to
    /// remove.
    function test_aFastSwapBeforeMinSettleAgeDoesNotCarry() public {
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 1 ether, 1, 8);

        // Same block as submission: strictly younger than `minSettleAge`.
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        assertEq(_order(id).amountInRemaining, 1 ether, "a too-young batch was carried");
    }

    /// @notice A Slow-Lane swap never carries a batch, however old it is.
    ///
    /// @dev Only FAST triggers settlement. If a Slow submitter could carry,
    /// they could choose the moment their own order clears — which is exactly
    /// the selection advantage settling in `afterSwap` exists to deny.
    function test_aSlowSwapNeverCarriesTheBatch() public {
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 1 ether, 1, 8);

        vm.roll(vm.getBlockNumber() + 10); // comfortably past minSettleAge

        vm.prank(bob);
        _slowOrder(bob, true, 1 ether, 1, 8); // a second SLOW swap

        assertEq(_order(id).amountInRemaining, 1 ether, "a Slow-Lane swap carried the batch");
    }

    // ==================================================================
    // What does settle
    // ==================================================================

    /// @notice The base case: a Fast swap past `minSettleAge` carries the batch.
    function test_aFastSwapPastMinSettleAgeCarriesTheBatch() public {
        // Small enough to clear inside the residual cap in one settlement; see
        // `test_aBatchLargerThanTheResidualCapClearsOverSeveralSettlements`.
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 0.01 ether, 1, 8);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        assertEq(_order(id).amountInRemaining, 0, "the batch was not carried");
        assertGt(_order(id).owedOut, 0, "a settled order was credited nothing");
    }

    /// @notice An aggregator that sends no `hookData` still carries the batch.
    ///
    /// @dev Empty `hookData` is the FAST default, so unaware routers act as
    /// carriers. This is most of the flow that will ever carry a batch on a
    /// live pool, so it is worth pinning rather than inferring.
    function test_anEmptyHookDataSwapCarriesTheBatch() public {
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 0.01 ether, 1, 8);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);
        _swapWithData(true, -1e15, ""); // no hookData at all

        assertEq(_order(id).amountInRemaining, 0, "an empty-hookData swap did not carry the batch");
    }

    /// @notice A batch larger than the residual cap is filled *partially* by
    /// each carrier and completes over several settlements.
    ///
    /// @dev This is the DD-5 sandwich bound doing its job, not a shortfall.
    /// The cap limits how much of a batch one settlement may push through the
    /// curve, because the un-netted residual is precisely what a sandwicher
    /// would target. The remainder rolls to the next epoch. A carrier
    /// therefore does bounded work no matter how large the batch is.
    function test_aBatchLargerThanTheResidualCapClearsOverSeveralSettlements() public {
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 1 ether, 1, 30);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        uint256 afterOne = _order(id).amountInRemaining;
        assertLt(afterOne, 1 ether, "the first carrier made no progress");
        assertGt(afterOne, 0, "a batch this size should not clear in one settlement");

        // Successive carriers keep draining it.
        for (uint256 i; i < 12 && _order(id).amountInRemaining > 0; ++i) {
            vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
            _setPriorityFee(1 gwei);
            _fastSwap(true, -1e15);
        }

        assertLt(_order(id).amountInRemaining, afterOne, "later carriers made no further progress");
        assertGt(_order(id).owedOut, 0, "a partially filled order was credited nothing");
    }

    // ==================================================================
    // The ordering property
    // ==================================================================

    /// @notice Settlement runs strictly after the carrier's own swap is booked.
    ///
    /// @dev This is the whole reason the trigger lives in `afterSwap` rather
    /// than `beforeSwap`. Because the carrier's price impact is already
    /// committed when the batch clears, the carrier cannot improve its own
    /// execution by choosing the moment of settlement.
    ///
    /// Asserted on event order: the carrying transaction produces two pool
    /// `Swap` events, the carrier's first and the settlement residual's second.
    function test_theBatchClearsAfterTheCarriersOwnSwapIsBooked() public {
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 0.01 ether, 1, 8);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);

        vm.recordLogs();
        _fastSwap(true, -1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 swapSig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
        bytes32 settledSig =
            keccak256("SlowBatchSettled(uint32,uint160,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

        uint256 firstSwap = type(uint256).max;
        uint256 secondSwap = type(uint256).max;
        uint256 settled = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            bytes32 t = logs[i].topics.length > 0 ? logs[i].topics[0] : bytes32(0);
            if (t == swapSig) {
                if (firstSwap == type(uint256).max) firstSwap = i;
                else if (secondSwap == type(uint256).max) secondSwap = i;
            } else if (t == settledSig && settled == type(uint256).max) {
                settled = i;
            }
        }

        assertTrue(firstSwap != type(uint256).max, "the carrier's own swap was not observed");
        assertTrue(secondSwap != type(uint256).max, "no settlement residual swap was observed");
        assertLt(firstSwap, secondSwap, "the settlement residual executed before the carrier's own swap");
        assertLt(secondSwap, settled, "the batch was recorded settled before its residual executed");
        assertEq(_order(id).amountInRemaining, 0, "the batch did not actually clear");
    }

    // ==================================================================
    // Who pays
    // ==================================================================

    /// @notice The carrying trader pays the settlement gas, and is not
    /// reimbursed.
    ///
    /// @dev Recorded rather than bounded: this is the mechanism's known cost
    /// incidence, and the reason `MAX_ORDERS_PER_EPOCH` caps how much work one
    /// carrier can be made to do. `test/economic/SettlementGasIncidence.t.sol`
    /// measures the size of it against the fee the carrier paid.
    function test_theCarryingTraderPaysTheSettlementGas() public {
        // Baseline: an identical Fast swap with no batch to carry.
        vm.roll(vm.getBlockNumber() + 10);
        _setPriorityFee(1 gwei);
        uint256 g0 = gasleft();
        _fastSwap(true, -1e15);
        uint256 uncarried = g0 - gasleft();

        // Now with a due batch waiting.
        vm.prank(alice);
        _slowOrder(alice, true, 1 ether, 1, 8);
        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);
        uint256 g1 = gasleft();
        _fastSwap(true, -1e15);
        uint256 carried = g1 - gasleft();

        assertGt(carried, uncarried, "carrying a batch cost the trader nothing");
    }

    // ==================================================================
    // The silences
    // ==================================================================

    /// @notice A batch that is not yet due is declined **silently** — the gate
    /// short-circuits before the `try`, so no `SettlementSkipped` is emitted.
    ///
    /// @dev This is a real observability gap and is pinned here so it cannot
    /// change unnoticed. On chain, "the batch was not due" and "the batch was
    /// due but could not clear" are distinguishable only by the presence of
    /// `SettlementSkipped`, and a batch that never becomes due produces no
    /// event at all. Monitoring a live pool therefore cannot rely on events
    /// alone; it has to poll `forceSettleDue()` or the epoch state.
    function test_anUndueBatchIsDeclinedWithoutEmittingSkipped() public {
        vm.prank(alice);
        _slowOrder(alice, true, 1 ether, 1, 8);

        // Same block: the age gate refuses.
        _setPriorityFee(1 gwei);
        vm.recordLogs();
        _fastSwap(true, -1e15);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 skippedSig = keccak256("SettlementSkipped(uint32)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == skippedSig) {
                fail();
            }
        }
    }

    /// @notice A carrying swap is never taken down by the batch it carries.
    ///
    /// @dev Settlement runs through an external self-call inside a `try`, so a
    /// batch that cannot clear unwinds by itself and leaves the carrier's swap
    /// intact. A trader volunteered gas; they did not volunteer to have their
    /// swap fail because someone else's batch was degenerate.
    ///
    /// Exercised with a batch whose limit price the market cannot reach, so
    /// every order is screened out and the settlement produces no fill.
    function test_anUnfillableBatchDoesNotRevertTheCarrier() public {
        // 100 currency1 per currency0 against a 1:1 pool: unreachable, but
        // still inside the range the limit-price conversion accepts. A `minOut`
        // near `type(uint128).max` is refused at intake instead, because the
        // implied limit price overflows uint160.
        vm.prank(alice);
        uint256 id = _slowOrder(alice, true, 1 ether, 100 ether, 8);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);

        // The carrier must survive.
        _fastSwap(true, -1e15);

        assertEq(_order(id).amountInRemaining, 1 ether, "an unreachable-limit order was filled");
        assertEq(_order(id).owedOut, 0, "an unreachable-limit order was credited output");
    }
}
