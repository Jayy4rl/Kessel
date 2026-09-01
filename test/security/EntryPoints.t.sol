// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {KesselErrors} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Every externally reachable entry point, called the way it is not
/// supposed to be called.
///
/// The hook has more entry points than a v4 hook usually does — two settlement
/// paths, a redemption, an external-fill hand-off, a self-call used purely as a
/// revert boundary — and each one carries a guard whose only job is to be
/// unreachable in normal operation. Unreachable-in-normal-operation is exactly
/// the code that a passing test suite silently never runs.
///
/// These are not hypothetical guards. `unlockCallback` moves custody out of the
/// singleton; `settleFromCallback` runs a whole settlement; the pool-identity
/// check is what stops a second pool built on this same hook address from
/// settling the first pool's batch against its own liquidity. The hook is
/// immutable and bound to one pool precisely because ERC-6909 custody is held
/// per *currency*, so a second pool sharing a currency could drain the first's
/// escrow (see the immutability posture note in `src/README.md`).
contract EntryPointsTest is KesselTestBase {
    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ======================================================================
    // Pool identity
    // ======================================================================

    /// @notice `beforeSwap` refuses a pool that is not the one this hook was
    /// constructed for.
    ///
    /// @dev The second pool is a genuine v4 pool: same hook address, same
    /// currencies, a different tick spacing, hence a different pool id. v4 is
    /// perfectly happy to create it — nothing upstream binds a hook to one
    /// pool — so the binding has to be enforced here or not at all.
    function test_aSecondPoolOnTheSameHookIsRefused() public {
        (PoolKey memory foreignKey,) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING * 2, SQRT_PRICE_1_1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(KesselErrors.UnknownPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap(foreignKey, true, -1e18, LaneCodec.encodeFast());
    }

    /// @notice `afterSwap` refuses a foreign pool too, independently of
    /// `beforeSwap`.
    ///
    /// @dev Called directly as the PoolManager rather than through a swap,
    /// because `beforeSwap` refuses first and `afterSwap` would otherwise never
    /// be reached. Both checks have to stand on their own: `afterSwap` is the
    /// callback that *triggers settlement*, so a hole here settles this pool's
    /// batch on someone else's liquidity.
    function test_afterSwapRefusesAForeignPoolOnItsOwn() public {
        PoolKey memory foreignKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING * 2,
            hooks: IHooks(address(hook))
        });

        vm.prank(address(manager));
        vm.expectRevert(KesselErrors.UnknownPool.selector);
        hook.afterSwap(
            address(this),
            foreignKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            BalanceDeltaLibrary.ZERO_DELTA,
            LaneCodec.encodeFast()
        );
    }

    // ======================================================================
    // Callback authority
    // ======================================================================

    /// @notice `unlockCallback` is callable only by the PoolManager.
    ///
    /// @dev This is the single most dangerous entry point on the contract: it
    /// dispatches to settlement, redemption and recapture sweeps, each of which
    /// moves custody. v4 only ever calls it from inside an `unlock` the hook
    /// itself opened; anyone else reaching it would be running those actions
    /// outside a lock entirely.
    function test_unlockCallbackRejectsEveryCallerButThePoolManager() public {
        bytes memory payload = abi.encode(uint8(0), uint32(0), uint256(0));

        vm.prank(alice);
        vm.expectRevert(KesselErrors.NotPoolManager.selector);
        hook.unlockCallback(payload);

        vm.prank(governance);
        vm.expectRevert(KesselErrors.NotPoolManager.selector);
        hook.unlockCallback(payload);
    }

    /// @notice `settleFromCallback` is callable only by the hook itself.
    ///
    /// @dev It exists solely to give piggyback settlement its own revert
    /// boundary, so it is a private function that happens to need an external
    /// call frame. Externally it would be a settlement with none of
    /// `afterSwap`'s gates applied — no lane check, no pause check, no
    /// piggyback-due check, and no `unlock`.
    function test_settleFromCallbackIsNotAPublicSettlementEntryPoint() public {
        vm.prank(alice);
        vm.expectRevert(KesselErrors.NotPoolManager.selector);
        hook.settleFromCallback(0);

        vm.prank(address(manager));
        vm.expectRevert(KesselErrors.NotPoolManager.selector);
        hook.settleFromCallback(0);
    }

    /// @notice Neither the hook nor the PoolManager may be the filler.
    ///
    /// @dev The filler is paid by a `take` to `msg.sender` at the end of
    /// settlement. Either of these as the destination would be paying custody
    /// back into the accounting it was just measured out of.
    function test_theFillerCannotBeTheHookOrThePoolManager() public {
        vm.prank(address(hook));
        vm.expectRevert(KesselErrors.InvalidFiller.selector);
        hook.settleWithFill(0);

        vm.prank(address(manager));
        vm.expectRevert(KesselErrors.InvalidFiller.selector);
        hook.settleWithFill(0);
    }

    // ======================================================================
    // Redemption
    // ======================================================================

    /// @notice Redeeming an order that was never created is refused as
    /// unknown, not silently accepted as an empty one.
    ///
    /// @dev `orders[id]` for an unwritten id is a zero-filled struct with
    /// `status == NONE` and `trader == address(0)`. Without the explicit
    /// check it would read as a well-formed order owing nothing — harmless
    /// today, but it is the kind of "empty struct is a valid value" reading
    /// that turns into a real hole the moment a field's meaning changes.
    function test_redeemingAnUnknownOrderIsRefused() public {
        vm.expectRevert(KesselErrors.OrderNotFound.selector);
        hook.redeem(1);

        _slowOrder(alice, true, 1e18, 0.5e18, 4);

        vm.expectRevert(KesselErrors.OrderNotFound.selector);
        hook.redeem(999);
    }

    // ======================================================================
    // Intake bounds
    // ======================================================================

    /// @notice An input beyond `uint128` is refused rather than truncated.
    ///
    /// @dev Order amounts are stored as `uint128`, and every warehouse counter
    /// with them. A silent truncation here would record an order for the low
    /// 128 bits of the input while the trader was debited the whole of it.
    function test_anInputBeyondUint128IsRefused() public {
        int256 tooBig = -int256(uint256(type(uint128).max) + 1);

        vm.expectRevert(_wrappedBeforeSwapRevert(KesselErrors.AmountTooLarge.selector));
        _swapWithData(true, tooBig, LaneCodec.encodeSlow(alice, 1, 4));
    }

    /// @notice A limit price beyond `uint160` is refused rather than truncated.
    ///
    /// @dev The limit is derived from `minOut / amountIn`, so a tiny input with
    /// an enormous `minOut` overflows the field the order stores it in.
    /// Truncating would wrap an unreachable limit into a reachable one and fill
    /// an order at a price its owner never agreed to — a direct I8 break, and
    /// the one place in intake where a rounding decision changes what a trader
    /// is owed rather than merely whether they are served.
    function test_aLimitPriceBeyondUint160IsRefused() public {
        // limit = minOut * 2**96 / amountIn, so 1 wei in against a 2**100
        // minimum output is a limit of 2**196.
        vm.expectRevert(_wrappedBeforeSwapRevert(KesselErrors.AmountTooLarge.selector));
        _swapWithData(true, -1, LaneCodec.encodeSlow(alice, uint128(1) << 100, 4));
    }

    /// @notice The mirror case on the other side: a `oneForZero` order's limit
    /// is `amountIn / minOut`, so the overflow comes from a large input against
    /// a one-wei minimum.
    function test_theOppositeDirectionsLimitOverflowIsAlsoRefused() public {
        vm.expectRevert(_wrappedBeforeSwapRevert(KesselErrors.AmountTooLarge.selector));
        _swapWithData(false, -int256(uint256(1) << 70), LaneCodec.encodeSlow(alice, 1, 4));
    }

    /// @notice A refused intake leaves nothing behind — no custody, no
    /// warehouse booking, no order.
    ///
    /// @dev The two `AmountTooLarge` guards straddle the point where custody is
    /// taken: the input-size check runs before `take`, the limit check after
    /// it. Both revert the whole call, so the distinction is invisible from
    /// outside — but only as long as nothing between them can commit state
    /// independently, which is what this asserts.
    function test_aRefusedIntakeCommitsNothing() public {
        vm.expectRevert(_wrappedBeforeSwapRevert(KesselErrors.AmountTooLarge.selector));
        _swapWithData(true, -1, LaneCodec.encodeSlow(alice, uint128(1) << 100, 4));

        (uint256 c0, uint256 c1) = _custody();
        assertEq(c0, 0, "refused intake left currency0 in custody");
        assertEq(c1, 0, "refused intake left currency1 in custody");
        assertEq(hook.warehoused0(), 0, "refused intake booked warehouse exposure");
        assertEq(hook.warehoused1(), 0, "refused intake booked warehouse exposure");
        assertEq(hook.nextOrderId(), 1, "refused intake consumed an order id");
    }

    // ======================================================================
    // The read surface
    // ======================================================================

    /// @notice The views an integrator reads report what the hook actually
    /// holds and serves.
    ///
    /// @dev These are the only externally visible description of the hook's
    /// state that is not an event, and each of them is the answer to a question
    /// somebody has to get right: which pool this hook is bound to, what is in
    /// a batch, and how much custody stands behind the claims. `custodyOf` in
    /// particular is the quantity I2 conserves against, so a view that reported
    /// the wrong number would make the invariant unfalsifiable from outside.
    function test_theViewsDescribeTheHookAccurately() public {
        // `poolKey()` must reproduce the key the hook was constructed for,
        // dynamic-fee flag included — that flag is what lets the Fast Lane
        // override the fee at all.
        PoolKey memory reported = hook.poolKey();
        assertEq(Currency.unwrap(reported.currency0), Currency.unwrap(currency0), "poolKey: wrong currency0");
        assertEq(Currency.unwrap(reported.currency1), Currency.unwrap(currency1), "poolKey: wrong currency1");
        assertEq(reported.tickSpacing, TICK_SPACING, "poolKey: wrong tick spacing");
        assertEq(reported.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "poolKey: the pool must be dynamic-fee");
        assertEq(address(reported.hooks), address(hook), "poolKey: wrong hook");

        // An empty batch holds nothing, and the hook holds no custody.
        assertEq(hook.orderCount(1), 0, "an unopened epoch should hold no orders");
        assertEq(hook.custodyOf(currency0), 0, "the hook should start with no custody");

        uint256 first = _slowOrder(alice, true, 1e18, 5e17, 8);
        uint256 second = _slowOrder(bob, true, 2e18, 1e18, 8);

        assertEq(hook.orderCount(1), 2, "orderCount did not track the batch");
        assertEq(hook.orderIdAt(1, 0), first, "orderIdAt returned the wrong id");
        assertEq(hook.orderIdAt(1, 1), second, "orderIdAt returned the wrong id");

        // I2's left-hand side: escrowed input is held as ERC-6909 inside the
        // singleton, and it is exactly what was taken in.
        assertEq(hook.custodyOf(currency0), 3e18, "custodyOf did not report the escrowed input");
        assertEq(hook.custodyOf(currency1), 0, "custody appeared on the side nothing was taken from");
    }

    /// @notice Indexing past the end of a batch reverts rather than returning a
    /// zero id that would read as order 0.
    function test_orderIdAtIsBoundsChecked() public {
        _slowOrder(alice, true, 1e18, 5e17, 8);

        vm.expectRevert();
        hook.orderIdAt(1, 1);
    }

    // ======================================================================
    // Helpers
    // ======================================================================

    /// @dev v4 wraps a reverting hook callback, so a bare selector never
    /// matches. Unwrapping keeps these assertions specific — `vm.expectRevert()`
    /// with no argument would also pass on a router-side failure that never
    /// reached the hook at all.
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
}
