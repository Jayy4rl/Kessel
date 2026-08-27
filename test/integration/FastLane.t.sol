// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Fast Lane behaviour end to end (PRD §2.3, §3.1, §6).
///
/// Covers invariants I5 (fee routing), I7 (no premium-capturing intermediary)
/// and I12 (monotonicity, here through the live hook rather than the pure
/// library), plus DD-1's default-lane policy.
contract FastLaneTest is KesselTestBase {
    using StateLibrary for IPoolManager;

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
    }

    // ======================================================================
    // I5 / I7 — the premium reaches LPs, and nothing sits in between
    // ======================================================================

    /// @notice A higher priority fee leaves strictly more fee growth with LPs.
    ///
    /// @dev This is the mechanism's central economic claim, measured where it
    /// actually matters: v4's `feeGrowthGlobal`, which is what in-range LPs can
    /// withdraw. Measuring the emitted fee rate instead would only prove the
    /// hook computed a number, not that the number reached anyone.
    function test_I5_higherUrgencyLeavesMoreFeeGrowthForLPs() public {
        uint256 snap = vm.snapshotState();

        _setPriorityFee(0);
        _fastSwap(true, -1e18);
        (uint256 lowGrowth,) = manager.getFeeGrowthGlobals(poolId);

        vm.revertToState(snap);

        _setPriorityFee(10 gwei);
        _fastSwap(true, -1e18);
        (uint256 highGrowth,) = manager.getFeeGrowthGlobals(poolId);

        assertGt(highGrowth, lowGrowth, "I5: urgency premium did not reach LPs");
    }

    /// @notice I7: the hook keeps nothing from a Fast-Lane swap.
    ///
    /// @dev The Fast-Lane premium is delivered by the dynamic-fee override, so
    /// it never passes through the hook's hands at all — v4 credits it directly
    /// to in-range liquidity. The strongest available statement of I7 is
    /// therefore that the hook's balances are untouched by fast flow.
    function test_I7_hookCapturesNothingFromFastSwaps() public {
        _setPriorityFee(50 gwei);
        _fastSwap(true, -1e18);
        _fastSwap(false, -1e18);

        (uint256 c0, uint256 c1) = _custody();
        assertEq(c0, 0, "I7: hook retained currency0 from a fast swap");
        assertEq(c1, 0, "I7: hook retained currency1 from a fast swap");
        assertEq(hook.lpClaimable0(), 0, "I7: hook accrued currency0 from a fast swap");
        assertEq(hook.lpClaimable1(), 0, "I7: hook accrued currency1 from a fast swap");
    }

    /// @notice A higher priority fee means the trader receives strictly less
    /// output for the same input — they are paying for their own urgency.
    function test_urgentTradersReceiveLessOutput() public {
        uint256 snap = vm.snapshotState();

        _setPriorityFee(0);
        uint256 balBefore = _balance1(address(this));
        _fastSwap(true, -1e18);
        uint256 calmOut = _balance1(address(this)) - balBefore;

        vm.revertToState(snap);

        _setPriorityFee(10 gwei);
        balBefore = _balance1(address(this));
        _fastSwap(true, -1e18);
        uint256 urgentOut = _balance1(address(this)) - balBefore;

        assertLt(urgentOut, calmOut, "an urgent swap should cost more than a calm one");
    }

    // ======================================================================
    // I12 through the live hook
    // ======================================================================

    /// @notice Monotonicity holds against the deployed hook, not just the pure
    /// library: fee growth is non-decreasing in the priority fee.
    function testFuzz_I12_liveFeeGrowthIsMonotone(
        uint64 p1,
        uint64 p2
    ) public {
        // Bounded because `vm.txGasPrice` rejects anything at or above 2^64,
        // and the helper adds a base fee on top. The unbounded domain — including
        // saturation at `type(uint256).max` — is covered against the pure fee
        // function in `FastLaneFeeProperties`, where no cheatcode is involved.
        uint256 a = bound(p1, 0, 1_000 gwei);
        uint256 b = bound(p2, 0, 1_000 gwei);
        (uint256 lo, uint256 hi) = a < b ? (a, b) : (b, a);

        uint256 snap = vm.snapshotState();

        _setPriorityFee(lo);
        _fastSwap(true, -1e17);
        (uint256 growthLo,) = manager.getFeeGrowthGlobals(poolId);

        vm.revertToState(snap);

        _setPriorityFee(hi);
        _fastSwap(true, -1e17);
        (uint256 growthHi,) = manager.getFeeGrowthGlobals(poolId);

        assertGe(growthHi, growthLo, "I12: fee growth decreased as priority fee rose");
    }

    // ======================================================================
    // DD-1 — default lane
    // ======================================================================

    /// @notice Empty `hookData` executes as a Fast-Lane swap rather than
    /// reverting, so aggregators that know nothing about Kessel still work.
    function test_DD1_emptyHookDataExecutesAsFast() public {
        _setPriorityFee(1 gwei);
        uint256 before = _balance1(address(this));

        _swapWithData(true, -1e18, "");

        assertGt(_balance1(address(this)), before, "empty hookData should execute a swap");
        (uint256 c0,) = _custody();
        assertEq(c0, 0, "empty hookData must not be escrowed as a Slow-Lane order");
    }

    /// @notice An unrecognised lane byte also defaults to FAST (DD-1).
    function test_DD1_unknownLaneByteDefaultsToFast() public {
        _setPriorityFee(1 gwei);
        uint256 before = _balance1(address(this));

        _swapWithData(true, -1e18, abi.encodePacked(uint8(0x7F)));

        assertGt(_balance1(address(this)), before, "unknown lane byte should fall through to FAST");
    }

    /// @notice A *malformed SLOW* payload reverts instead of silently becoming
    /// a Fast-Lane swap.
    ///
    /// @dev The asymmetry with the two tests above is deliberate. DD-1's
    /// default covers callers who said nothing; a caller who asked for
    /// deferral and was not understood must not have their order executed
    /// immediately at the higher fee.
    function test_malformedSlowPayloadRevertsRatherThanExecuting() public {
        _setPriorityFee(1 gwei);
        vm.expectRevert();
        _swapWithData(true, -1e18, abi.encodePacked(uint8(1), uint8(0xAB)));
    }

    // ======================================================================
    // Pool configuration
    // ======================================================================

    /// @notice The pool's stored LP fee is zero and stays zero.
    ///
    /// @dev Load-bearing, and easy to overlook. Every external swap overrides
    /// the fee in `beforeSwap`, so the stored value is only ever used by the
    /// hook's *own* settlement swap — which must be free, because `f_slow` is
    /// charged separately and uniformly across the whole batch (I4). A non-zero
    /// stored fee would double-charge the residual and break uniform pricing.
    function test_storedLpFeeIsZeroSoTheResidualSwapIsFree() public {
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, 0, "dynamic-fee pool should start with a zero stored LP fee");

        _setPriorityFee(5 gwei);
        _fastSwap(true, -1e18);

        (,,, lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, 0, "a fee override must not persist into the stored LP fee");
    }

    /// @notice The hook serves exactly one pool and rejects every other.
    ///
    /// @dev Custody is held per currency, so a hook shared across pools could
    /// let one pool's settlement drain another's escrow. OpenZeppelin's
    /// `BaseAsyncSwap` carries the same warning.
    function test_hookRejectsForeignPools() public {
        (key,) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            TICK_SPACING * 2, // a different key => a different pool id
            SQRT_PRICE_1_1
        );

        _setPriorityFee(1 gwei);
        vm.expectRevert();
        _fastSwap(true, -1e18);
    }

    function _balance1(
        address who
    ) private view returns (uint256) {
        return IERC20Balance(Currency.unwrap(currency1)).balanceOf(who);
    }
}

interface IERC20Balance {
    function balanceOf(
        address
    ) external view returns (uint256);
}
