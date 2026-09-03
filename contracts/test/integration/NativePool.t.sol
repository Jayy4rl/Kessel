// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {KesselErrors} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {IERC20Like, KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice The two places Kessel refuses native ETH, on a pool that actually
/// has a native side (DD-14, SR-6).
///
/// The rest of the suite runs on ERC-20 pools, where neither refusal is
/// reachable — so without this file both are unexercised code on a contract
/// that cannot be patched. Both are *refusals*, which is the harder thing to
/// get accidentally right: a refusal that does not fire is invisible until the
/// day it should have.
///
/// The pool is native-quoted (`currency0 == address(0)`), which is the only
/// arrangement v4 permits: the native currency sorts below every ERC-20.
contract NativePoolTest is KesselTestBase {
    Currency internal token;

    function setUp() public {
        deployFreshManagerAndRouters();
        token = deployMintAndApproveCurrency();

        currency0 = CurrencyLibrary.ADDRESS_ZERO;
        currency1 = token;

        address target = address(uint160(KESSEL_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "KesselHook.sol:KesselHook",
            abi.encode(manager, currency0, currency1, TICK_SPACING, governance, uint8(0)),
            target
        );
        hook = KesselHook(target);

        (key, poolId) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1
        );

        vm.deal(address(this), 1_000 ether);
        modifyLiquidityRouter.modifyLiquidity{value: 100 ether}(
            key,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ""
        );
    }

    // ======================================================================
    // DD-14 — native ETH is not accepted as Slow-Lane input
    // ======================================================================

    /// @notice A Slow-Lane order selling the native side is refused before any
    /// custody is taken.
    ///
    /// @dev Native ETH cannot be held as an ERC-6909 claim the way an ERC-20
    /// can, so the intake path's custody model does not apply to it. The
    /// refusal comes before `take`, which is what makes it safe: nothing can be
    /// stranded by a path that never accepts anything (PRD §11 case 14).
    function test_DD14_nativeEthIsRefusedAsSlowLaneInput() public {
        vm.expectRevert(_wrappedBeforeSwapRevert(KesselErrors.NativeEthNotSupportedInSlowLane.selector));
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LaneCodec.encodeSlow(alice, 0.5 ether, 4)
        );
    }

    /// @notice The refusal is specific to the native *side*, not to the pool.
    /// An order selling the ERC-20 side of the same pool is accepted.
    ///
    /// @dev This is the half that makes the guard a refusal rather than a
    /// disablement, and it is also what makes SR-6 live: such an order is owed
    /// its output in native ETH, so redemption hands control to the trader.
    function test_DD14_theErc20SideOfANativePoolStillWorks() public {
        _fundToken(alice, 10 ether);

        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LaneCodec.encodeSlow(alice, 0.5 ether, 4)
        );

        assertEq(uint256(_statusOf(1)), uint256(KesselHook_OrderStatus.PENDING), "the ERC-20 side should be accepted");
    }

    // ======================================================================
    // SR-6 — the external-fill path refuses native pools outright
    // ======================================================================

    /// @notice `settleWithFill` is unavailable on a pool with a native side.
    ///
    /// @dev A native `take` pays its recipient with a bare `call`, and the
    /// filler payout leg goes to a caller-controlled address. Rather than guard
    /// that hand-off, the path is closed on native pools entirely; they settle
    /// against the curve as they always did, so nothing is lost but the
    /// price improvement a filler might have offered.
    function test_SR6_fillerPathIsClosedOnANativePool() public {
        vm.prank(alice);
        vm.expectRevert(KesselErrors.FillerPathRequiresERC20.selector);
        hook.settleWithFill(0);
    }

    /// @notice The refusal precedes the due-date gate, so it cannot be waited
    /// out. There is no block height at which a native pool becomes fillable.
    function test_SR6_theFillerRefusalIsNotATimingGate() public {
        _fundToken(alice, 10 ether);
        vm.prank(alice);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LaneCodec.encodeSlow(alice, 0.5 ether, 4)
        );

        vm.roll(vm.getBlockNumber() + 10_000);

        vm.prank(alice);
        vm.expectRevert(KesselErrors.FillerPathRequiresERC20.selector);
        hook.settleWithFill(0);
    }

    /// @notice Forced settlement is *not* closed on a native pool. The curve
    /// path never hands control to a caller-controlled address, so I11 is
    /// unaffected by SR-6's restriction.
    function test_forcedSettlementStillWorksOnANativePool() public {
        _fundToken(alice, 10 ether);
        for (uint256 i; i < 2; ++i) {
            vm.prank(alice);
            swapRouter.swap(
                key,
                SwapParams({zeroForOne: false, amountSpecified: -1 ether, sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                LaneCodec.encodeSlow(alice, 0.5 ether, 4)
            );
        }

        vm.roll(vm.getBlockNumber() + hook.maxDelay() + 1);
        assertTrue(hook.forceSettleDue(), "the batch should be forceable");

        hook.forceSettle();
        assertGt(_order(1).owedOut, 0, "a native-quoted pool must still settle against the curve");
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    /// @dev v4 wraps a reverting hook callback in `CustomRevert.WrappedError`,
    /// so a bare selector never matches. Unwrapping it here keeps the assertion
    /// specific: `vm.expectRevert()` with no argument would pass on any revert
    /// at all, including one from the router before the hook is ever reached.
    function _wrappedBeforeSwapRevert(
        bytes4 inner
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(inner),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _fundToken(
        address who,
        uint256 amount
    ) internal {
        deal(Currency.unwrap(token), who, amount);
        vm.prank(who);
        IERC20Like(Currency.unwrap(token)).approve(address(swapRouter), type(uint256).max);
    }
}
