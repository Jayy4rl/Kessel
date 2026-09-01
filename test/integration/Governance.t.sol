// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselErrors} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice The governance surface. Kessel is immutable, so every one of these
/// is a *bounded* parameter: the point of these tests is that the bounds
/// actually bind, and that no reachable parameter setting can strand funds.
contract GovernanceTest is KesselTestBase {
    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ---- authority ---------------------------------------------------

    function test_everySetterRejectsANonGovernanceCaller() public {
        vm.startPrank(alice);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setFees(3000, 400);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setK(100);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setCadence(2, 300, 3000, 2);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setWarehouseCaps(1, 1);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setExpiryForfeitBps(5);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setPaused(true);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setGovernance(alice);
        vm.stopPrank();
    }

    /// @notice Governance cannot be handed to the zero address.
    ///
    /// @dev Slither `missing-zero-check`. On an immutable, pool-bound hook this
    /// is not a style nit: `governance` is the only authority over `fBase`,
    /// `fSlow`, `k`, the cadence gates and the warehouse caps, and there is no
    /// recovery path. A fat-fingered handover would freeze every parameter at
    /// whatever value it happened to hold, permanently.
    function test_governanceCannotBeHandedToTheZeroAddress() public {
        vm.prank(governance);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setGovernance(address(0));

        assertEq(hook.governance(), governance, "governance must be unchanged after a rejected handover");
    }

    /// @dev Slither `events-access`. The handover is the single most
    /// consequential state change on the contract; it must be observable.
    function test_governanceHandoverIsAnnounced() public {
        vm.expectEmit(true, false, false, true, address(hook));
        emit ParameterUpdated("governance", uint256(uint160(governance)), uint256(uint160(alice)));
        vm.prank(governance);
        hook.setGovernance(alice);
    }

    event ParameterUpdated(bytes32 indexed param, uint256 oldValue, uint256 newValue);

    function test_governanceHandover() public {
        vm.prank(governance);
        hook.setGovernance(alice);
        assertEq(hook.governance(), alice);

        vm.prank(governance);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setK(1);

        vm.prank(alice);
        hook.setK(1);
        assertEq(hook.k(), 1);
    }

    // ---- I10: 0 <= f_slow < f_base -----------------------------------

    /// @notice I10 is enforced at the only place either fee can move, so no
    /// accepted call can leave it violated.
    function testFuzz_I10_holdsAfterAnyAcceptedFeeChange(
        uint24 newFBase,
        uint24 newFSlow
    ) public {
        vm.prank(governance);
        try hook.setFees(newFBase, newFSlow) {
            assertEq(hook.fBase(), newFBase);
            assertEq(hook.fSlow(), newFSlow);
            assertLt(hook.fSlow(), hook.fBase(), "I10 violated by an accepted fee change");
        } catch {
            // Refused: the previous values must be untouched.
            assertLt(hook.fSlow(), hook.fBase(), "I10 violated by a refused fee change");
        }
    }

    function test_slowFeeCannotReachOrExceedBaseFee() public {
        vm.startPrank(governance);
        vm.expectRevert(KesselErrors.SlowFeeBoundViolated.selector);
        hook.setFees(3000, 3000);
        vm.expectRevert(KesselErrors.SlowFeeBoundViolated.selector);
        hook.setFees(3000, 3001);
        hook.setFees(3000, 2999); // the boundary itself is allowed
        vm.stopPrank();
        assertEq(hook.fSlow(), 2999);
    }

    function test_baseFeeBoundsBind() public {
        vm.startPrank(governance);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setFees(99, 50); // below F_BASE_MIN
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setFees(100_001, 50); // above F_BASE_MAX
        hook.setFees(100, 99);
        hook.setFees(100_000, 99);
        vm.stopPrank();
    }

    function test_kBoundBinds() public {
        vm.startPrank(governance);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setK(100_001);
        hook.setK(100_000);
        hook.setK(0);
        vm.stopPrank();
        assertEq(hook.k(), 0);
    }

    function test_expiryForfeitIsCappedAtOnePercent() public {
        vm.startPrank(governance);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setExpiryForfeitBps(101);
        hook.setExpiryForfeitBps(100);
        vm.stopPrank();
        assertEq(hook.expiryForfeitBps(), 100);
    }

    /// @notice `kGas`, the size-denominated tax multiplier, is bounded like
    /// every other parameter.
    ///
    /// @dev Settable on every deployment, but it only *bites* on one that
    /// declared a gas-token side (DD-4 as amended) — see
    /// `GasTokenFeeTest.test_setKGasMovesTheChargedFee` for its effect. The
    /// ceiling is where one gwei of priority would cost 0.01 ETH of tax, which
    /// is far above any plausible calibration; the point of the bound is that
    /// an immutable contract cannot get a new one later.
    function test_kGasBoundBinds() public {
        vm.startPrank(governance);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setKGas(10_000_001);
        hook.setKGas(10_000_000); // the ceiling itself is allowed
        hook.setKGas(0); // and zero disables the tax without disabling the lane
        vm.stopPrank();
        assertEq(hook.kGas(), 0);
    }

    // ---- cadence coherence -------------------------------------------

    /// @notice The three cadence bounds have to stay ordered, or the gates stop
    /// meaning anything: `minSettleAge < maxDelay <= absoluteMaxDelay`.
    function test_cadenceOrderingIsEnforced() public {
        vm.startPrank(governance);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(300, 300, 3000, 2); // maxDelay must exceed minSettleAge
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(2, 300, 299, 2); // absoluteMaxDelay below maxDelay
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(0, 300, 3000, 2); // minSettleAge below its floor
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(2, 300, 3000, 0); // a zero size floor disables the gate
        hook.setCadence(1, 2, 2, 1);
        vm.stopPrank();
        assertEq(hook.minSettleAge(), 1);
        assertEq(hook.maxDelay(), 2);
        assertEq(hook.absoluteMaxDelay(), 2);
    }

    /// @notice The cadence gates have absolute bounds as well as relative ones.
    ///
    /// @dev The ordering test above only pins them against each other, which a
    /// coherent-but-useless setting would pass: `minSettleAge = 1,
    /// maxDelay = 1` is ordered and would make forced settlement immediate,
    /// while a `maxDelay` in the millions is ordered and would put I11's bound
    /// out of reach. Both ends are checked here.
    function test_cadenceAbsoluteBoundsBind() public {
        vm.startPrank(governance);

        // maxDelay below its floor, and above its ceiling.
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(1, 1, 3000, 2);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(2, 100_001, 100_001, 2);

        // minSettleAge above its ceiling.
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(301, 400, 3000, 2);

        // absoluteMaxDelay above the shared ceiling.
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setCadence(2, 300, 100_001, 2);

        // Both extremes of the admissible range are accepted.
        hook.setCadence(1, 2, 2, 1);
        hook.setCadence(300, 100_000, 100_000, 1);
        vm.stopPrank();

        assertEq(hook.maxDelay(), 100_000);
        assertEq(hook.absoluteMaxDelay(), 100_000);
    }

    // ---- warehouse cap (I9) ------------------------------------------

    function test_warehouseCapBlocksNewOrdersAtTheBoundary() public {
        vm.prank(governance);
        hook.setWarehouseCaps(1e16, type(uint128).max);

        _slowOrder(alice, true, 1e16, 1e15, 8); // exactly at the cap: allowed
        vm.expectRevert();
        _swapWithData(true, -1, LaneCodec.encodeSlow(alice, 1, 8)); // one wei over: refused

        // The other direction is unaffected — the cap is per currency.
        _slowOrder(bob, false, 1e16, 1e15, 8);
    }

    /// @notice The currency1 cap binds on its own, in its own units.
    ///
    /// @dev I9 is denominated per currency in that currency's own units, so the
    /// two caps are independent budgets rather than two views of one. The test
    /// above pins that currency1 flow is not blocked by the currency0 cap;
    /// this pins the half that actually protects anyone — that the currency1
    /// budget is enforced at all. A cap that is only ever checked on one side
    /// is not a cap.
    function test_theCurrency1WarehouseCapBindsIndependently() public {
        vm.prank(governance);
        hook.setWarehouseCaps(type(uint128).max, 1e16);

        _slowOrder(alice, false, 1e16, 1e15, 8); // exactly at the cap: allowed
        assertEq(hook.warehoused1(), 1e16, "the currency1 budget was not booked");

        vm.expectRevert();
        _swapWithData(false, -1, LaneCodec.encodeSlow(alice, 1, 8)); // one wei over: refused

        // currency0 has its own, untouched budget.
        _slowOrder(bob, true, 1e18, 1e15, 8);
        assertEq(hook.warehoused0(), 1e18, "the currency0 budget was wrongly constrained");
    }

    // ---- pause (PRD §11 case 12) -------------------------------------

    /// @notice The guardian pause may block new risk. It may never strand
    /// funds, so `redeem` has to keep working while paused.
    function test_pauseBlocksNewRiskButNeverStrandsFunds() public {
        uint256 id = _slowOrder(alice, true, 1e16, 1e15, 200);
        uint256 partner = _slowOrder(bob, false, 1e16, 1e15, 200);
        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);
        assertGt(_order(id).owedOut, 0, "setup: the order should have filled");

        vm.prank(governance);
        hook.setPaused(true);

        // No new Slow-Lane orders.
        // v4 wraps a reverting hook call, so the inner `Paused()` arrives
        // wrapped rather than bare.
        vm.expectRevert();
        _swapWithData(true, -1e16, LaneCodec.encodeSlow(carol, 1e15, 8));

        // No settlement, by either path.
        vm.expectRevert(KesselErrors.Paused.selector);
        hook.forceSettle();

        // But the money still comes out.
        uint256 before = _bal(currency1, alice);
        hook.redeem(id);
        assertGt(_bal(currency1, alice), before, "pause stranded a settled payout");

        hook.redeem(partner);

        // And Fast-Lane swaps are untouched: a pause is not a pool halt.
        _fastSwap(true, -1e15);
    }

    function _bal(
        Currency c,
        address who
    ) internal view returns (uint256) {
        return IERC20Bal(Currency.unwrap(c)).balanceOf(who);
    }
}

interface IERC20Bal {
    function balanceOf(
        address
    ) external view returns (uint256);
}
