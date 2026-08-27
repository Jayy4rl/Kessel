// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselErrors} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Slow-Lane intake and custody (PRD §3.2, §5, §12).
///
/// PRD §12 names async-swap misuse as the highest-severity area in the design:
/// the pattern lets a hook "take all swap amounts for itself", so the intake
/// path must provably escrow the input against a claim and never divert it.
/// These tests are written against that specific failure mode.
///
/// Covers I1 (delta settlement), I2 (custody conservation), I9 (warehouse cap)
/// and the DD-14/DD-15 policies.
contract SlowLaneIntakeTest is KesselTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
    }

    // ======================================================================
    // I1 / I2 — escrow, do not divert
    // ======================================================================

    /// @notice A Slow-Lane order escrows exactly the input as ERC-6909 custody
    /// and issues a matching claim.
    function test_I2_intakeEscrowsExactlyTheInput() public {
        uint256 amountIn = 5e17;

        uint256 orderId = _slowOrder(alice, true, amountIn, 1, 4);

        (uint256 c0, uint256 c1) = _custody();
        assertEq(c0, amountIn, "custody should hold exactly the input");
        assertEq(c1, 0, "no output currency should be held yet");

        OrderView memory v = _order(orderId);
        assertEq(v.trader, alice, "trader must be the address encoded in hookData, not the router");
        assertTrue(v.zeroForOne, "direction not recorded");
        assertEq(v.amountInRemaining, amountIn, "claim does not match escrow");
        assertEq(v.owedOut, 0, "no output should be owed before settlement");
        assertEq(v.status, uint8(KesselHook_OrderStatus.PENDING), "order should be pending");

        (uint256 o0, uint256 o1) = _obligations();
        assertEq(c0, o0, "I2: custody0 != obligations0");
        assertEq(c1, o1, "I2: custody1 != obligations1");
    }

    /// @notice The Slow Lane does not execute against the curve at submission.
    ///
    /// @dev This is what makes it a *deferred* contract rather than a delayed
    /// one, and it is the observable half of I6: if submission moved the price,
    /// the order would have a submission-time execution.
    function test_intakeDoesNotTouchTheCurve() public {
        (uint160 priceBefore,,,) = manager.getSlot0(poolId);
        uint128 liqBefore = manager.getLiquidity(poolId);

        _slowOrder(alice, true, 1e18, 1, 4);

        (uint160 priceAfter,,,) = manager.getSlot0(poolId);
        assertEq(priceAfter, priceBefore, "Slow-Lane intake moved the pool price");
        assertEq(manager.getLiquidity(poolId), liqBefore, "Slow-Lane intake changed liquidity");
    }

    /// @notice Custody is conserved across many interleaved orders in both
    /// directions (I2).
    function testFuzz_I2_custodyConservedAcrossManyOrders(
        uint96[8] memory amounts,
        uint8 directions
    ) public {
        uint256 expected0;
        uint256 expected1;

        for (uint256 i; i < amounts.length; ++i) {
            uint256 amt = bound(amounts[i], 1e12, 1e17);
            bool zeroForOne = (directions >> i) & 1 == 1;
            _slowOrder(alice, zeroForOne, amt, 1, 8);
            if (zeroForOne) expected0 += amt;
            else expected1 += amt;
        }

        (uint256 c0, uint256 c1) = _custody();
        assertEq(c0, expected0, "custody0 drifted from the sum of inputs");
        assertEq(c1, expected1, "custody1 drifted from the sum of inputs");

        (uint256 o0, uint256 o1) = _obligations();
        assertEq(c0, o0, "I2: custody0 != obligations0");
        assertEq(c1, o1, "I2: custody1 != obligations1");
    }

    // ======================================================================
    // Intake validation
    // ======================================================================

    /// @notice Exact-output Slow-Lane orders are refused (PRD §3.2, §17).
    /// v4's async pattern only works on exact input.
    function test_exactOutputIsRefused() public {
        vm.expectRevert();
        _swapWithData(true, int256(1e18), LaneCodec.encodeSlow(alice, 1, 4));
    }

    /// @notice A Slow-Lane order must state a limit price (I8). There is no
    /// safe default: `minOut = 0` is an unbounded-downside order.
    function test_zeroMinOutIsRefused() public {
        vm.expectRevert();
        _swapWithData(true, -int256(1e18), LaneCodec.encodeSlow(alice, 0, 4));
    }

    function test_expiryOutOfRangeIsRefused() public {
        vm.expectRevert();
        _swapWithData(true, -int256(1e18), LaneCodec.encodeSlow(alice, 1, 0));

        vm.expectRevert();
        _swapWithData(true, -int256(1e18), LaneCodec.encodeSlow(alice, 1, 100_000));
    }

    /// @notice I9: orders beyond the per-direction warehouse cap are refused
    /// deterministically, and nothing is stranded (PRD §11 case 13).
    function test_I9_warehouseCapIsEnforcedPerDirection() public {
        vm.prank(governance);
        hook.setWarehouseCaps(1e18, 1e18);

        _slowOrder(alice, true, 9e17, 1, 4);

        // Over the cap in currency0...
        vm.expectRevert();
        _swapWithData(true, -int256(2e17), LaneCodec.encodeSlow(alice, 1, 4));

        // ...but the opposite direction has its own budget, untouched.
        _slowOrder(bob, false, 9e17, 1, 4);

        assertEq(hook.warehoused0(), 9e17, "currency0 warehouse mis-accounted");
        assertEq(hook.warehoused1(), 9e17, "currency1 warehouse mis-accounted");

        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertEq(c0, o0, "I2 broken by a rejected order");
        assertEq(c1, o1, "I2 broken by a rejected order");
    }

    /// @notice The refused order takes no custody at all — a rejected intake
    /// must not leave dust behind.
    function test_rejectedOrderLeavesNoResidue() public {
        vm.prank(governance);
        hook.setWarehouseCaps(1e15, 1e15);

        vm.expectRevert();
        _swapWithData(true, -int256(1e18), LaneCodec.encodeSlow(alice, 1, 4));

        (uint256 c0, uint256 c1) = _custody();
        assertEq(c0, 0, "rejected order left currency0 in custody");
        assertEq(c1, 0, "rejected order left currency1 in custody");
        assertEq(hook.nextOrderId(), 1, "rejected order consumed an id");
    }

    // ======================================================================
    // DD-15 — the claim is a storage record, and cannot move
    // ======================================================================

    /// @notice Claim non-transferability (PRD §5.1, a requirement rather than a
    /// decision) holds structurally: the hook exposes no way to move a claim.
    ///
    /// @dev Asserted by probing for the transfer surfaces a token-based claim
    /// would have had. A storage-record claim makes this property true by
    /// construction, which is exactly why DD-15 chose it over a receipt token —
    /// on an immutable contract, "no such function exists" is a stronger
    /// guarantee than "every transfer path reverts".
    function test_claimIsNotTransferable() public {
        uint256 orderId = _slowOrder(alice, true, 1e17, 1, 4);

        string[4] memory sigs = [
            "transfer(address,uint256)",
            "transferFrom(address,address,uint256)",
            "approve(address,uint256)",
            "setOperator(address,bool)"
        ];

        for (uint256 i; i < sigs.length; ++i) {
            (bool ok,) = address(hook).call(abi.encodeWithSignature(sigs[i], bob, orderId));
            assertFalse(ok, "the hook must expose no claim-transfer surface");
        }

        assertEq(_order(orderId).trader, alice, "claim ownership changed");
    }

    /// @notice DD-9: there is no cancel entry point at all.
    function test_thereIsNoCancelFunction() public {
        uint256 orderId = _slowOrder(alice, true, 1e17, 1, 4);

        (bool ok,) = address(hook).call(abi.encodeWithSignature("cancel(uint256)", orderId));
        assertFalse(ok, "a cancellable claim would be a free option (PRD 7.3)");

        assertEq(_order(orderId).amountInRemaining, 1e17, "order was altered");
    }

    // ======================================================================
    // DD-12 — a Slow-Lane submission never triggers settlement
    // ======================================================================

    /// @notice Slow-Lane submissions do not settle the pending batch.
    ///
    /// @dev Half of the §7.6(b) argument. If a Slow-Lane submitter could
    /// trigger settlement, they would choose the moment their own batch clears,
    /// which is precisely the selection MEV DD-12 exists to close.
    function test_DD12_slowSubmissionNeverTriggersSettlement() public {
        _slowOrder(alice, true, 1e17, 1, 8);
        vm.roll(block.number + 50); // well past minSettleAge

        _slowOrder(bob, true, 1e17, 1, 8);

        assertEq(_order(1).owedOut, 0, "a Slow-Lane submission settled the pending batch");
        assertEq(hook.oldestUnsettledEpoch(), 1, "settlement advanced on a slow submission");
    }
}
