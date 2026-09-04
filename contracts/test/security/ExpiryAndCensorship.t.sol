// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselErrors} from "../../src/KesselTypes.sol";
import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

interface IERC20Approve2 {
    function approve(
        address,
        uint256
    ) external returns (bool);
}

/// @notice SR-10 and SR-11: two ways an order that should be inert was able to
/// reach out and disable something.
contract ExpiryAndCensorshipTest is KesselTestBase {
    uint256 internal constant EPOCH_CAP = 32; // KesselHook.MAX_ORDERS_PER_EPOCH

    address internal filler = address(0xF111E7);

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ======================================================================
    // SR-10 — expiry is monotone
    // ======================================================================

    /// @notice Governance raising `maxDelay` cannot un-expire an order.
    ///
    /// @dev `_isExpired` used to recompute the block half of the test from the
    /// LIVE `maxDelay`, which made expiry non-monotone: raising the parameter
    /// pushed the threshold out and turned already-expired orders back into
    /// unexpired ones. That is not a cosmetic status flip. `_rollUnfilled`
    /// deliberately leaves expired orders behind and then deletes the epoch's
    /// index, so an expired order is reachable only through `redeem` — and an
    /// order that is no longer expired has no refund to claim and no index to
    /// be filled from. The trader's input was locked, on a contract with no
    /// upgrade path, until the raised floor elapsed.
    ///
    /// The fix stamps `expiryBlock` at intake. A stamp can only ever bring the
    /// refund closer.
    function test_SR10_raisingMaxDelayDoesNotUnexpireAnOrder() public {
        uint256 id = _slowOrder(alice, true, 1e16, 1e15, 1);

        // Push `currentEpoch` past the order's epoch budget without ever
        // settling its batch, by saturating epochs behind it.
        for (uint256 i; i < EPOCH_CAP * 2 + 2; ++i) {
            _slowOrder(bob, true, 1e14, 1e13, 200);
        }
        assertGt(hook.currentEpoch(), _order(id).epochExpiry, "setup: the epoch budget should have run out");

        // And past the block half, as it stood at intake.
        vm.roll(vm.getBlockNumber() + hook.maxDelay() + 1);

        // Now stretch the parameter that used to define that half.
        vm.prank(governance);
        hook.setCadence(2, 7_200, 7_200, 2);

        uint256 before = IERC20Like(Currency.unwrap(currency0)).balanceOf(alice);
        hook.redeem(id); // must still be refundable
        assertGt(
            IERC20Like(Currency.unwrap(currency0)).balanceOf(alice),
            before,
            "raising maxDelay locked an already-expired order out of its refund"
        );
        assertEq(uint8(_statusOf(id)), uint8(KesselHook_OrderStatus.REFUNDED), "order should be REFUNDED");
    }

    /// @notice The stamp is taken from the parameter in force at intake, so
    /// lowering `maxDelay` afterwards does not retroactively expire anything
    /// either. Monotone means monotone in both directions.
    function test_SR10_theExpiryStampIsFixedAtIntake() public {
        uint256 id = _slowOrder(alice, true, 1e16, 1e15, 200);
        uint64 stamped = _order(id).expiryBlock;

        vm.prank(governance);
        hook.setCadence(2, 10, 3_000, 2);

        assertEq(_order(id).expiryBlock, stamped, "an order's expiry stamp moved under it");
    }

    // ======================================================================
    // SR-11 — a screened-out order cannot censor a filler
    // ======================================================================

    /// @notice A dust order naming a filler as its beneficiary does not lock
    /// that filler out of `settleWithFill`.
    ///
    /// @dev `hookData` lets a submitter name ANY beneficiary, so the
    /// self-dealing guard was a censorship primitive: one dust order naming a
    /// competitor — with a limit price the market can never reach, so it costs
    /// nothing and never fills — made every `settleWithFill` from that address
    /// revert `InvalidFiller` for the life of the batch, and rolled forward
    /// with it into every batch after that.
    ///
    /// The guard now only considers candidates that survived the eligibility
    /// screen. An order that is not in the batch being filled has no
    /// self-dealing to guard against.
    function test_SR11_aScreenedOutOrderNamingTheFillerDoesNotBlockIt() public {
        // The censoring order: one wei, and a floor of 100 on a pool at 1.
        _slowOrder(filler, true, 1, 100, 200);
        // The real batch.
        uint256 id = _slowOrder(alice, true, 1 ether, 1e15, 200);

        vm.roll(vm.getBlockNumber() + hook.minSettleAge() + 1);

        (bool ok, Currency outCurrency, uint256 floorOut,,) = hook.quoteFill();
        assertTrue(ok, "setup: the batch should be fillable");

        deal(Currency.unwrap(outCurrency), filler, floorOut);
        vm.startPrank(filler);
        IERC20Approve2(Currency.unwrap(outCurrency)).approve(address(hook), floorOut);
        hook.settleWithFill(floorOut);
        vm.stopPrank();

        assertGt(_order(id).owedOut, 0, "a dust order censored the filler out of a real batch");
    }

    /// @notice The guard it replaces is still there. A filler that IS the
    /// beneficiary of an order actually being filled is still refused.
    function test_SR11_theSelfDealingGuardStillHoldsForALiveOrder() public {
        _slowOrder(filler, true, 1 ether, 1e15, 200);
        _slowOrder(alice, true, 1 ether, 1e15, 200);

        vm.roll(vm.getBlockNumber() + hook.minSettleAge() + 1);

        vm.prank(filler);
        vm.expectRevert(KesselErrors.InvalidFiller.selector);
        hook.settleWithFill(0);
    }
}
