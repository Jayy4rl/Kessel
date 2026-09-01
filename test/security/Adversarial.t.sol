// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Adversarial tests written during the security-review stage.
///
/// Each test here started life as a hypothesis about a way to break the hook,
/// written *before* the corresponding fix. They are kept as regression tests:
/// if one of them starts failing, an attack that was closed has reopened.
contract AdversarialTest is KesselTestBase {
    uint256 internal constant EPOCH_CAP = 32; // KesselHook.MAX_ORDERS_PER_EPOCH

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ==================================================================
    // Head-of-line lock: an epoch nobody can fill must not pin the queue
    // ==================================================================

    /// @notice Saturate epoch 1 with orders whose limit price can never be met,
    /// then check an honest order behind them still clears.
    ///
    /// @dev The attack costs the attacker 32 swaps and the expiry forfeit, and
    /// would otherwise freeze every later batch: settlement only ever works on
    /// `oldestUnsettledEpoch`, so a batch in which every order is dropped for
    /// limit-price ineligibility used to return without filling, without
    /// rolling and without advancing the cursor — permanently.
    function test_unfillableBatchDoesNotBlockLaterBatches() public {
        // 32 orders demanding 5x the pool price: never eligible.
        for (uint256 i; i < EPOCH_CAP; ++i) {
            _slowOrder(alice, true, 1e15, uint128(5e15), 200);
        }
        assertEq(hook.orderCount(1), EPOCH_CAP, "epoch 1 should be saturated");

        // The honest order lands behind them, in a later epoch.
        uint256 honest = _slowOrder(bob, true, 1e15, uint128(5e14), 200);
        assertGt(_order(honest).epochSubmitted, 1, "honest order should be in a later epoch");

        // Give every batch every chance to settle.
        for (uint256 round; round < 6; ++round) {
            vm.roll(block.number + 10);
            _setPriorityFee(1 gwei);
            _fastSwap(true, -1e15);
        }

        assertGt(_order(honest).owedOut, 0, "honest order behind a dead batch never filled");
    }

    /// @notice The rolling that fixes the lock must not let an epoch grow past
    /// the per-settlement work cap, or settlement becomes gas-unbounded.
    function test_rollingNeverGrowsAnEpochPastTheCap() public {
        for (uint256 i; i < EPOCH_CAP; ++i) {
            _slowOrder(alice, true, 1e15, uint128(5e15), 200);
        }
        for (uint256 i; i < 10; ++i) {
            _slowOrder(bob, true, 1e15, uint128(5e14), 200);
        }

        for (uint256 round; round < 6; ++round) {
            vm.roll(block.number + 10);
            _setPriorityFee(1 gwei);
            _fastSwap(true, -1e15);
        }

        for (uint32 e = 1; e <= hook.currentEpoch() + 2; ++e) {
            assertLe(hook.orderCount(e), EPOCH_CAP, "epoch grew past the work cap");
        }
    }

    /// @notice Forced settlement is the I11 liveness escape; a dead batch must
    /// not be able to make it revert forever.
    function test_forceSettleClearsADeadBatch() public {
        for (uint256 i; i < EPOCH_CAP; ++i) {
            _slowOrder(alice, true, 1e15, uint128(5e15), 200);
        }
        uint256 honest = _slowOrder(bob, true, 1e15, uint128(5e14), 200);

        vm.roll(block.number + 4000); // past absoluteMaxDelay
        hook.forceSettle();
        assertGt(hook.oldestUnsettledEpoch(), 1, "dead batch still pinning the cursor");

        vm.roll(block.number + 4000);
        hook.forceSettle();
        assertGt(_order(honest).owedOut, 0, "honest order never reached");
    }

    // ==================================================================
    // Expiry griefing
    // ==================================================================

    /// @notice An order's expiry is measured in epochs, and anyone can advance
    /// an epoch by saturating it. If that were the whole story, an attacker
    /// could churn epochs to force honest orders into a refund -- charging them
    /// the forfeit and denying them their trade -- without the market ever
    /// moving.
    function test_epochChurnCannotExpireAnOrderEarly() public {
        // A short-dated honest order that the market can easily satisfy.
        uint256 honest = _slowOrder(bob, true, 1e15, uint128(5e14), 2);
        uint32 expiryEpoch = _order(honest).epochExpiry;

        // Churn epochs in the very next block by saturating each one. Nothing
        // settles: `minSettleAge` has not elapsed and no Fast-Lane swap runs.
        while (hook.currentEpoch() <= expiryEpoch + 1) {
            for (uint256 i; i < EPOCH_CAP; ++i) {
                _slowOrder(alice, false, 1e13, uint128(1e17), 256);
            }
        }
        assertGt(hook.currentEpoch(), expiryEpoch, "setup: epochs did not churn past the expiry");

        // The honest order must still be fillable, not refundable.
        vm.expectRevert();
        hook.redeem(honest);
    }

    /// @notice SR-3 ratification: a fill that happens in the window SR-3 adds —
    /// after the trader's stated `expiryEpochs` has run out, but before the
    /// block floor lets the order expire — still honours the order's limit
    /// price (I8).
    ///
    /// @dev This is the DD-11 question SR-3 reopened. `expiryEpochs` is now a
    /// FLOOR on how long an order rests, not an exact deadline, so an order can
    /// be filled *later than the trader asked for*. The question that matters
    /// is whether that extra resting time can push the trader below the bound
    /// they set. It cannot, and the reason is structural rather than incidental:
    /// eligibility is a comparison of the settlement's uniform price against
    /// `Order.limitPriceX96`, which is written once at intake and never
    /// re-derived. Nothing in that comparison mentions time, an epoch number, or
    /// a deadline — so an order resting for one epoch and an order resting for
    /// a hundred face exactly the same test. Resting longer changes only *how
    /// many chances* the order gets to meet its own limit, never *what* the
    /// limit is.
    ///
    /// The complementary direction — that the extension hands no optionality
    /// back to the trader (DD-9) — is covered by
    /// `test_thereIsNoCancelFunction` and `test_refundCannotBeTakenBeforeExpiry`
    /// together with `test_epochChurnCannotExpireAnOrderEarly` above: the
    /// extension delays the only exit that exists and shortens nothing, so it
    /// strictly lengthens the option the trader has *written* to the market.
    function test_SR3_fillAfterTheStatedDeadlineStillHonoursTheLimit() public {
        uint256 amountIn = 1e16;
        // 90% of parity: comfortably reachable, but a real bound.
        uint256 minOut = FullMath.mulDiv(amountIn, 9_000, 10_000);

        uint256 id = _slowOrder(bob, true, amountIn, uint128(minOut), 1);
        uint32 expiryEpoch = _order(id).epochExpiry;
        uint256 openedAt = block.number;

        // Churn epochs past the trader's stated budget, in the same block, with
        // orders whose own limits can never be met so they never interfere with
        // the price.
        while (hook.currentEpoch() <= expiryEpoch) {
            for (uint256 i; i < EPOCH_CAP; ++i) {
                _slowOrder(alice, false, 1e13, uint128(1e17), 256);
            }
        }
        assertGt(hook.currentEpoch(), expiryEpoch, "setup: epoch budget was not exhausted");

        // Settle inside the extension window: the epoch budget is spent, but
        // the SR-3 block floor (min(maxDelay, EXPIRY_BLOCK_FLOOR_MAX)) has not
        // elapsed, so the order is still fillable rather than refundable.
        vm.roll(block.number + 5);
        assertLt(block.number, openedAt + hook.maxDelay(), "setup: the block floor already lapsed");

        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        OrderView memory v = _order(id);
        // Non-vacuity: the extension window has to have actually produced a
        // fill, or this test would assert nothing.
        assertGt(v.owedOut, 0, "setup: the order was not filled in the extension window");

        uint256 filledIn = amountIn - v.amountInRemaining;
        uint256 required = FullMath.mulDiv(minOut, filledIn, amountIn);
        assertGe(v.owedOut + 2, required, "I8: a fill after the stated deadline breached the order's limit price");
    }

    /// @notice The SR-3 extension must not become an exit. An order in the
    /// extension window is fillable, and specifically NOT refundable — the
    /// trader has no way to take the input back early and no way to shorten the
    /// option they wrote (DD-9).
    function test_SR3_extensionWindowIsNotAnExit() public {
        uint256 id = _slowOrder(bob, true, 1e16, uint128(9e15), 1);
        uint32 expiryEpoch = _order(id).epochExpiry;

        while (hook.currentEpoch() <= expiryEpoch) {
            for (uint256 i; i < EPOCH_CAP; ++i) {
                _slowOrder(alice, false, 1e13, uint128(1e17), 256);
            }
        }
        vm.roll(block.number + 5);

        // Past the stated deadline, inside the floor: no refund, no cancel.
        vm.expectRevert();
        hook.redeem(id);
        assertEq(uint8(_statusOf(id)), uint8(KesselHook_OrderStatus.PENDING), "order must still be resting");
    }

    // ==================================================================
    // Tick-bitmap scan arithmetic
    // ==================================================================

    /// @notice The active-range scan multiplies a compressed tick cursor by the
    /// tick spacing. Both are `int24`, and after stepping whole bitmap words the
    /// product leaves `int24` range for large spacings — reverting settlement
    /// for the entire life of an immutable, pool-bound hook.
    function test_settlementSurvivesLargeTickSpacing() public {
        _deployKesselWithSpacing(32767);
        // Liquidity sits entirely ABOVE the current tick, so the downward scan
        // finds no initialised tick and has to walk whole empty bitmap words.
        _addLiquidity(32767, 98301, 100 ether);
        _fundAndApprove(address(this), 1_000 ether);

        _slowOrder(alice, true, 1e15, uint128(5e14), 200);
        _slowOrder(bob, false, 1e15, uint128(5e14), 200);

        vm.roll(block.number + 4000);
        // The forced path has no try/catch around it, so an arithmetic fault in
        // the scan surfaces here instead of being silently swallowed.
        hook.forceSettle();
    }

    /// @notice SR-4's mirror image: the *upward* scan must survive the same
    /// wide-spaced pool.
    ///
    /// @dev `_activeRangeTicks` runs both scans on every settlement, whatever
    /// direction the batch is going, so a cursor overflow in `_scanUp` bricks
    /// the pool exactly as one in `_scanDown` would. The two scans have
    /// separate cursor arithmetic and separate clamps, and the original defect
    /// was only ever observed downward — a fix that had been applied to one
    /// side and not the other would look identical from the outside and would
    /// pass `test_settlementSurvivesLargeTickSpacing`.
    ///
    /// Liquidity sits entirely BELOW the current tick here, so the upward scan
    /// finds no initialised tick and walks whole empty bitmap words until its
    /// cursor leaves the tick range.
    function test_settlementSurvivesLargeTickSpacingUpward() public {
        _deployKesselWithSpacing(32767);
        _addLiquidity(-98301, -32767, 100 ether);
        _fundAndApprove(address(this), 1_000 ether);

        _slowOrder(alice, true, 1e15, uint128(5e14), 200);
        _slowOrder(bob, false, 1e15, uint128(5e14), 200);

        vm.roll(block.number + 4000);
        hook.forceSettle();

        assertGt(hook.oldestUnsettledEpoch(), 1, "the batch did not settle on a wide-spaced pool");
    }

    // ==================================================================
    // PRD §15 scenario 5 — settlement-price manipulation
    // ==================================================================

    /// @notice Settlement runs inside the `afterSwap` of a Fast-Lane swap, so
    /// the swap that carries a batch also sets the price the batch clears at.
    /// A trader can therefore *choose* the clearing price by sizing that swap.
    ///
    /// The defence is not that they cannot move the price — they can, it is a
    /// public AMM — but that I8 makes moving it useless: every order states a
    /// limit, and the eligibility loop drops an order rather than filling it on
    /// the wrong side of that limit.
    function test_manipulatedSettlementPriceCannotFillBelowLimit() public {
        // Alice will sell currency0 and wants at least ~0.99 currency1 per unit.
        uint256 amountIn = 1e16;
        uint256 id = _slowOrder(alice, true, amountIn, uint128(amountIn * 99 / 100), 200);

        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);

        // The attacker slams currency0 into the pool, crushing the price, and
        // that same swap carries the settlement.
        _fastSwap(true, -50 ether);

        uint128 filled = uint128(amountIn) - _order(id).amountInRemaining;
        uint128 got = _order(id).owedOut;
        if (filled > 0) {
            // If it filled at all, it filled at or above the stated limit.
            assertGe(
                uint256(got) * 1e18 / filled,
                uint256(amountIn * 99 / 100) * 1e18 / amountIn,
                "order filled below its limit price at a manipulated settlement"
            );
        } else {
            assertEq(got, 0, "no fill must mean no output");
        }
    }

    /// @notice Sandwiching the settlement — move the price, let the batch clear
    /// against the moved price, move back — must not pay.
    function test_sandwichingASettlementIsNotProfitable() public {
        _slowOrder(alice, true, 1e16, uint128(1e15), 200); // permissive limit
        _slowOrder(bob, false, 1e16, uint128(1e15), 200);

        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);

        uint256 in0 = _bal(currency0, address(this));
        uint256 in1 = _bal(currency1, address(this));

        _fastSwap(true, -20 ether); // front: crush the price, carrying the batch
        uint256 gained1 = _bal(currency1, address(this)) - in1;
        _fastSwap(false, -int256(gained1)); // back: sell it all back

        uint256 out0 = _bal(currency0, address(this));
        uint256 out1 = _bal(currency1, address(this));
        assertLe(out0 + out1, in0 + in1, "the round trip around a settlement paid the attacker");
    }

    // ==================================================================
    // PRD §15 scenario 16 — piggyback selection MEV
    // ==================================================================

    /// @notice The trader who carries a settlement must not get a better fill
    /// for having carried it. Their own swap is priced by `Pool.swap` before
    /// `afterSwap` ever runs, which is the whole reason DD-8 puts settlement in
    /// `afterSwap` rather than `beforeSwap` (PRD §7.6(b)).
    function test_carryingASettlementDoesNotImproveTheCarriersFill() public {
        _slowOrder(alice, true, 1e16, uint128(1e15), 200);
        _slowOrder(bob, false, 1e16, uint128(1e15), 200);
        vm.roll(block.number + 10);
        _setPriorityFee(1 gwei);

        // Same swap, twice, from the same state: once where it carries the
        // batch, once where settlement is switched off underneath it.
        uint256 snap = vm.snapshotState();
        uint256 before1 = _bal(currency1, address(this));
        _fastSwap(true, -1e16);
        uint256 carried = _bal(currency1, address(this)) - before1;

        vm.revertToState(snap);
        vm.prank(governance);
        hook.setPaused(true); // pause suppresses settlement, nothing else
        uint256 before2 = _bal(currency1, address(this));
        _fastSwap(true, -1e16);
        uint256 uncarried = _bal(currency1, address(this)) - before2;

        assertEq(carried, uncarried, "carrying a settlement changed the carrier's own execution");
    }

    /// @notice A Slow-Lane submission must never settle anything, so a trader
    /// cannot select the moment their own order clears (DD-12).
    function test_slowSubmissionNeverTriggersSettlement() public {
        _slowOrder(alice, true, 1e16, uint128(1e15), 200);
        vm.roll(block.number + 100);

        uint32 cursorBefore = hook.oldestUnsettledEpoch();
        _slowOrder(bob, false, 1e16, uint128(1e15), 200);
        assertEq(hook.oldestUnsettledEpoch(), cursorBefore, "a slow submission settled a batch");
    }

    function _bal(
        Currency c,
        address who
    ) internal view returns (uint256) {
        return IERC20Balance(Currency.unwrap(c)).balanceOf(who);
    }

    function _deployKesselWithSpacing(
        int24 spacing
    ) internal {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        address target = address(uint160(KESSEL_FLAGS) | (uint160(0x5555) << 144));
        deployCodeTo(
            "KesselHook.sol:KesselHook",
            abi.encode(manager, currency0, currency1, spacing, governance, uint8(0)),
            target
        );
        hook = KesselHook(target);

        (key, poolId) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, SQRT_PRICE_1_1
        );
    }
}

interface IERC20Balance {
    function balanceOf(
        address
    ) external view returns (uint256);
}
