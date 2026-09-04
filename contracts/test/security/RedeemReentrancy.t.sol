// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {KesselErrors} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Reentrancy through the outbound leg of `redeem` (Slither
/// `reentrancy-no-eth`, `KesselHook._payoutOrder`).
///
/// @dev This is the attack the security review's "Reviewed and found sound —
/// Redemption reentrancy" note misses. That note argues two things, and both
/// are individually true: `owedOut`/`amountInRemaining` are zeroed before the
/// outbound `take`, and a reentrant `redeem` cannot nest an `unlock`. Neither
/// covers the actual vector, which is not a reentrant `redeem` at all — it is a
/// reentrant `poolManager.swap`. `swap` is `onlyWhenUnlocked`, not
/// `onlyByTheUnlocker`, so *anyone* may call it while the hook's own redemption
/// `unlock` is open; that swap runs `afterSwap`, and `_settling` is false on
/// the redemption path, so a full settlement executes underneath an in-flight
/// `_payoutOrder`.
///
/// The reentry needs no exotic token. `poolManager.take` of native currency
/// hands control to the recipient with a bare `call`, and DD-14 only refuses
/// native ETH as Slow-Lane *input* — a `oneForZero` order on an ETH-quoted pool
/// is accepted and pays out in native ETH. Every production ETH-quoted
/// deployment therefore has this reentry point live.
///
/// Consequence, pre-fix: an order that is PENDING with a partial fill has its
/// `owedOut` zeroed and paid, then the reentrant settlement fills the remainder
/// and writes a *fresh* `owedOut` and `status = FILLED`. Control returns to
/// `_payoutOrder`, which finishes with `if (o.status == FILLED) o.status =
/// REDEEMED` — finalising an order that still owes output. `redeem` then
/// reverts `AlreadyFinalised` forever and the output is stranded in hook
/// custody on an immutable contract.
contract RedeemReentrancyTest is KesselTestBase {
    MockERC20 internal token;
    ReenteringTrader internal attacker;

    uint256 internal constant ORDER_SIZE = 100 ether;

    function setUp() public {
        deployFreshManagerAndRouters();

        token = new MockERC20("TOKEN", "TKN", 18);
        currency0 = CurrencyLibrary.ADDRESS_ZERO; // native ETH
        currency1 = Currency.wrap(address(token));

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

        // Nested positions, laid out so this order PARTIALLY fills and the
        // remainder can still be completed by a later settlement. Both halves
        // of that are load-bearing for the attack: the partial fill is what
        // leaves an order PENDING with a non-zero `owedOut` to be caught
        // mid-payout, and the completable remainder is what the reentrant
        // settlement fills underneath it.
        //
        // The mechanism producing the partial fill changed with the multi-range
        // amendment to DD-5 and this setup changed with it. It used to be
        // enough to clamp against ONE initialised tick, because the solver
        // stopped at the first one it met. The solver now walks up to
        // `MAX_CLEARING_RANGES` of them, so a single edge no longer holds it
        // back — what does is running out of range budget.
        //
        // Hence the layout: five narrow nested positions whose upper edges sit
        // at 600/1200/1800/2400/3000, plus one wide position that stays active
        // throughout and continues far beyond them. The order is `oneForZero`,
        // so it walks the price UP through those edges and exhausts the range
        // budget well before it exhausts either the order or the liquidity.
        //
        // Both properties the attack needs therefore hold structurally rather
        // than by a tuned `ORDER_SIZE`: it partially fills because the walk is
        // bounded, and the remainder stays completable because the wide
        // position still has depth past where the walk stopped.
        vm.deal(address(this), 20_000 ether);
        token.mint(address(this), 20_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        _addNativeLiquidity(-60_000, 60_000, 100 ether);
        _addNativeLiquidity(-3_000, 3_000, 100 ether);
        _addNativeLiquidity(-2_400, 2_400, 100 ether);
        _addNativeLiquidity(-1_800, 1_800, 100 ether);
        _addNativeLiquidity(-1_200, 1_200, 100 ether);
        _addNativeLiquidity(-600, 600, 100 ether);

        attacker = new ReenteringTrader(manager, hook, swapRouter, key);
        token.mint(address(attacker), ORDER_SIZE + 1 ether);
        attacker.approveRouter(token);
    }

    function _addNativeLiquidity(
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity
    ) internal {
        modifyLiquidityRouter.modifyLiquidity{value: 600 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Move the batch along with an honest Fast-Lane swap.
    function _carry() internal {
        _setPriorityFee(1 gwei);
        swapRouter.swap{value: 1e15}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LaneCodec.encodeFast()
        );
    }

    /// @dev Drive the order to a partial fill: 100 ether of currency1 walks the
    /// price up through the clustered initialised ticks laid out in `setUp`,
    /// exhausts the solver's range budget part-way, and rolls the remainder
    /// into the next epoch.
    function _partiallyFilledOrder() internal returns (uint256 id) {
        id = attacker.submit(ORDER_SIZE);

        vm.roll(vm.getBlockNumber() + 5);
        _carry();

        assertGt(_order(id).owedOut, 0, "setup: order should have accrued output");
        assertGt(_order(id).amountInRemaining, 0, "setup: order should be only partially filled");
        assertEq(uint8(_statusOf(id)), uint8(KesselHook_OrderStatus.PENDING), "setup: order should still be PENDING");

        // Let the rolled remainder's epoch age past `minSettleAge`, so the
        // settlement the attacker re-enters into is genuinely due.
        vm.roll(vm.getBlockNumber() + 5);
    }

    /// @notice An order that still owes output must never be left in a terminal
    /// status. Pre-fix this fails: the reentrant settlement completes the order
    /// and writes a fresh `owedOut`, then `_payoutOrder` finishes with
    /// `if (o.status == FILLED) o.status = REDEEMED` and finalises it anyway.
    function test_reentrantSettlementCannotFinaliseAnOrderThatStillOwesOutput() public {
        uint256 id = _partiallyFilledOrder();

        attacker.arm();
        hook.redeem(id);
        assertTrue(attacker.reentered(), "setup: the reentrant settlement did not run");

        KesselHook_OrderStatus s = _statusOf(id);
        bool terminal = s == KesselHook_OrderStatus.REDEEMED || s == KesselHook_OrderStatus.REFUNDED;
        assertFalse(
            terminal && _order(id).owedOut > 0,
            "order finalised while it still owes output: that output is unreachable forever"
        );
    }

    /// @notice The trader must end up holding every wei the settlements credited
    /// to their order. Pre-fix the second `redeem` reverts `AlreadyFinalised`
    /// and the difference is stranded in hook custody.
    function test_reentrancyDuringRedeemNeverStrandsCredit() public {
        uint256 id = _partiallyFilledOrder();

        attacker.arm();
        hook.redeem(id);

        // Whatever the order still shows as owed must be collectable.
        if (_order(id).owedOut > 0) {
            uint256 owed = _order(id).owedOut;
            uint256 before = address(attacker).balance;
            hook.redeem(id);
            assertEq(address(attacker).balance - before, owed, "the remaining credit must be payable");
        }
        assertEq(_order(id).owedOut, 0, "no credit may remain on the order after it is drained");
    }

    /// @notice I2 must survive the reentrancy: the hook's custody still covers
    /// every outstanding obligation.
    function test_I2_holdsAcrossAReentrantRedeem() public {
        uint256 id = _partiallyFilledOrder();

        attacker.arm();
        hook.redeem(id);

        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertGe(c0, o0, "I2: currency0 custody must cover obligations");
        assertGe(c1, o1, "I2: currency1 custody must cover obligations");
    }
}

/// @dev Trader contract whose `receive()` re-enters the PoolManager. It cannot
/// use a router (a router would nest `unlock`), so it calls `swap` directly and
/// resolves its own deltas — which is exactly what any address may do while the
/// manager is unlocked.
contract ReenteringTrader {
    IPoolManager internal immutable manager;
    KesselHook internal immutable hook;
    PoolSwapTest internal immutable router;

    PoolKey internal key;
    bool public armed;
    bool public reentered;

    constructor(
        IPoolManager _manager,
        KesselHook _hook,
        PoolSwapTest _router,
        PoolKey memory _key
    ) {
        manager = _manager;
        hook = _hook;
        router = _router;
        key = _key;
    }

    function approveRouter(
        MockERC20 token
    ) external {
        token.approve(address(router), type(uint256).max);
    }

    function submit(
        uint256 amountIn
    ) external returns (uint256 id) {
        id = hook.nextOrderId();
        router.swap(
            key,
            SwapParams({
                zeroForOne: false, // sell token1, receive native token0
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341 // MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            // Limit price ceiling of 10 (currency1-per-currency0) against a
            // pool at 1: permissive enough to always be eligible, but a real
            // number -- `minOut = 1` overflows the uint160 limit price.
            LaneCodec.encodeSlow(address(this), uint128(amountIn / 10), 200)
        );
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        reentered = true;

        // A Fast-Lane swap inside the still-open redemption `unlock`. `swap` is
        // `onlyWhenUnlocked`, not `onlyByTheUnlocker`, so this is permitted --
        // and it runs `afterSwap`, which settles the pending batch.
        //
        // Direction is `oneForZero` on purpose: the batch's own residual also
        // pushes the price up, so this does not walk the price back across the
        // initialised tick the previous settlement clamped against (which would
        // re-add the inner position's liquidity and starve the residual).
        // Output is taken as ERC-6909 claims so this `receive` is not re-entered.
        uint256 amountIn = 1e15;
        BalanceDelta d = manager.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341 // MAX_PRICE_LIMIT
            }),
            ""
        );

        manager.sync(key.currency1);
        MockERC20(Currency.unwrap(key.currency1)).transfer(address(manager), uint256(uint128(-d.amount1())));
        manager.settle();
        manager.mint(address(this), key.currency0.toId(), uint256(uint128(d.amount0())));
    }
}
