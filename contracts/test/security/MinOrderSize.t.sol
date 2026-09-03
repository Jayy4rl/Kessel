// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KesselErrors} from "../../src/KesselTypes.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice SR-12: a per-direction floor on Slow-Lane order size.
///
/// @dev The per-epoch work cap (`MAX_ORDERS_PER_EPOCH`) counts ORDERS, not
/// value, so the cheapest way to consume it is with orders carrying no value.
/// Thirty-two dust orders with a limit price the market can never reach are
/// dropped by the eligibility screen every settlement and roll to the head of
/// the next batch, displacing real orders into later epochs for as long as
/// their expiry allows — and billing the repricing to whichever Fast-Lane
/// trader happens to carry the settlement.
///
/// The floor prices that in the attacker's own locked capital, which is the
/// cost that scales with how long they sustain it, and the expiry forfeit taxes
/// it again on the way out.
contract MinOrderSizeTest is KesselTestBase {
    uint256 internal constant EPOCH_CAP = 32; // KesselHook.MAX_ORDERS_PER_EPOCH

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    /// @notice Off by default, so the floor is opt-in and this changes nothing
    /// for an existing deployment until governance sets it.
    ///
    /// @dev There is no unit-independent default worth shipping: a floor
    /// meaningful on an 18-decimal pool is nonsense on a 6-decimal one.
    function test_SR12_theFloorIsOffUntilGovernanceSetsIt() public {
        assertEq(hook.minOrderSize0(), 0, "currency0 floor should default to off");
        assertEq(hook.minOrderSize1(), 0, "currency1 floor should default to off");

        uint256 id = _slowOrder(alice, true, 1, 1, 8); // one wei
        assertEq(_order(id).amountInRemaining, 1, "a dust order should still be accepted by default");
    }

    /// @notice Once set, the floor refuses the dust the grief is built from.
    function test_SR12_dustIsRefusedOnceTheFloorIsSet() public {
        vm.prank(governance);
        hook.setMinOrderSize(1e15, 1e15);

        // v4 wraps a hook revert, so the selector is pinned by inspecting the
        // returndata rather than by `expectRevert`; the suite's usual idiom
        // (a bare `expectRevert`) would not distinguish this refusal from any
        // other, and "refused for the right reason" is the whole point.
        _assertRefusedWith(true, 1e14, KesselErrors.OrderBelowMinimum.selector);
        _assertRefusedWith(false, 1e14, KesselErrors.OrderBelowMinimum.selector);
    }

    /// @notice Exactly at the floor is accepted; the comparison is not
    /// off-by-one against the honest trader.
    function test_SR12_theBoundaryIsInclusive() public {
        vm.prank(governance);
        hook.setMinOrderSize(1e15, 1e15);

        uint256 id = _slowOrder(alice, true, 1e15, 1e14, 8);
        assertEq(_order(id).amountInRemaining, 1e15, "an order exactly at the floor was refused");
    }

    /// @notice The two directions are independent, like the warehouse caps they
    /// are modelled on: a pool may want a floor on one side only.
    function test_SR12_theDirectionsAreIndependent() public {
        vm.prank(governance);
        hook.setMinOrderSize(1e15, 0);

        _assertRefusedWith(true, 1e14, KesselErrors.OrderBelowMinimum.selector);

        uint256 id = _slowOrder(alice, false, 1e14, 1e13, 8);
        assertEq(_order(id).amountInRemaining, 1e14, "the currency1 side should be unaffected");
    }

    /// @notice The grief itself: saturating an epoch with dust becomes 32x the
    /// floor in locked capital instead of 32 wei.
    function test_SR12_saturatingAnEpochWithDustNowCostsRealCapital() public {
        vm.prank(governance);
        hook.setMinOrderSize(1e15, 1e15);

        for (uint256 i; i < EPOCH_CAP; ++i) {
            _assertRefusedWith(true, 1, KesselErrors.OrderBelowMinimum.selector);
        }
        assertEq(hook.orderCount(1), 0, "dust saturated an epoch despite the floor");

        // And the warehouse still records nothing: the refusal precedes custody.
        assertEq(hook.warehoused0(), 0, "a refused order took custody");
    }

    /// @dev Submit a Slow order expected to be refused, and pin WHY.
    ///
    /// v4 wraps a reverting hook's data in `Hooks.WrappedError`, so a plain
    /// `vm.expectRevert(selector)` cannot match it. The inner selector is still
    /// carried verbatim inside that payload, so searching the returndata for it
    /// distinguishes this refusal from every other reason intake can refuse.
    function _assertRefusedWith(
        bool zeroForOne,
        uint256 amountIn,
        bytes4 expected
    ) internal {
        (bool ok, bytes memory ret) = address(swapRouter)
            .call(
                abi.encodeWithSelector(
                    bytes4(
                        keccak256(
                            "swap((address,address,uint24,int24,address),(bool,int256,uint160),(bool,bool),bytes)"
                        )
                    ),
                    key,
                    SwapParams({
                        zeroForOne: zeroForOne,
                        amountSpecified: -int256(amountIn),
                        sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
                    }),
                    PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                    LaneCodec.encodeSlow(alice, 1, 256)
                )
            );
        assertFalse(ok, "the order was accepted when it should have been refused");
        assertTrue(_contains(ret, expected), "refused, but not for the expected reason");
    }

    function _contains(
        bytes memory haystack,
        bytes4 needle
    ) private pure returns (bool) {
        if (haystack.length < 4) return false;
        for (uint256 i; i + 4 <= haystack.length; ++i) {
            if (
                haystack[i] == needle[0] && haystack[i + 1] == needle[1] && haystack[i + 2] == needle[2]
                    && haystack[i + 3] == needle[3]
            ) return true;
        }
        return false;
    }

    /// @notice The floor is an INTAKE check and must never reach an order the
    /// hook has already taken custody of.
    ///
    /// @dev This is the failure mode worth guarding. Rolling and filling both
    /// walk resting orders, and a floor applied there would strand exactly the
    /// orders whose input the protocol is already holding — the one thing PRD
    /// §11 case 12 forbids outright. Raising the floor far above two resting
    /// orders and then settling them is the direct test: they must fill.
    function test_SR12_raisingTheFloorNeverStrandsARestingOrder() public {
        // Submitted while the floor is off, both below where it is about to go.
        uint256 aliceId = _slowOrder(alice, true, 1e15, 1e13, 8);
        uint256 bobId = _slowOrder(bob, true, 1e15, 1e13, 8);

        vm.prank(governance);
        hook.setMinOrderSize(1e18, 1e18); // a thousand times either order

        vm.roll(vm.getBlockNumber() + hook.maxDelay() + 1);
        hook.forceSettle();

        assertGt(_order(aliceId).owedOut, 0, "a resting order was stranded by a floor raised after intake");
        assertGt(_order(bobId).owedOut, 0, "a resting order was stranded by a floor raised after intake");

        // And it is still collectable.
        hook.redeem(aliceId);
        assertEq(uint8(_statusOf(aliceId)), uint8(KesselHook_OrderStatus.REDEEMED), "redemption was blocked");
    }
}
