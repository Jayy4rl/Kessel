// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselEvents} from "../../src/KesselTypes.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice PRD §15 scenarios 9 and 18: settlement cost at batch scale, and the
/// mandatory empty-range recapture fallback end to end.
contract ScaleTest is KesselTestBase {
    uint256 internal constant EPOCH_CAP = 32;

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ==================================================================
    // §15 scenario 9 — settlement gas at batch size N
    // ==================================================================

    /// @notice Settlement is carried by a volunteering Fast-Lane trader (DD-6),
    /// so its cost is somebody else's bill. The cap that makes that acceptable
    /// is `MAX_ORDERS_PER_EPOCH`; this measures what the cap actually buys.
    ///
    /// @dev Asserts a ceiling rather than a fixed number, so it flags a
    /// regression in scaling without failing on every incidental gas change.
    function test_gasAtFullBatchStaysWithinABlock() public {
        for (uint256 i; i < EPOCH_CAP / 2; ++i) {
            _slowOrder(alice, true, 1e15, uint128(1e14), 200);
            _slowOrder(bob, false, 1e15, uint128(1e14), 200);
        }
        assertEq(hook.orderCount(1), EPOCH_CAP, "setup: batch should be full");

        vm.roll(vm.getBlockNumber() + 10);
        _setPriorityFee(1 gwei);

        uint256 before = gasleft();
        _fastSwap(true, -1e15);
        uint256 used = before - gasleft();

        assertGt(hook.oldestUnsettledEpoch(), 1, "the full batch did not settle");
        // Comfortably inside an OP-Stack block, with room for the swap itself.
        assertLt(used, 8_000_000, "settling a full batch costs more than a block can spare");
        emit log_named_uint("gas: full-batch settlement carried by one fast swap", used);
    }

    /// @notice Per-order cost has to be roughly linear. A superlinear settlement
    /// would make the cap meaningless — the cap bounds N, not N^2.
    function test_settlementCostIsRoughlyLinearInBatchSize() public {
        uint256 small = _measureSettlement(4);
        setUp();
        uint256 large = _measureSettlement(32);

        emit log_named_uint("gas: 4-order batch", small);
        emit log_named_uint("gas: 32-order batch", large);

        // 8x the orders must cost well under 8x, since a large part of the cost
        // (the residual swap, the donate, the epoch record) is fixed.
        assertLt(large, small * 8, "settlement cost grows superlinearly in batch size");
    }

    function _measureSettlement(
        uint256 n
    ) internal returns (uint256 used) {
        for (uint256 i; i < n / 2; ++i) {
            _slowOrder(alice, true, 1e15, uint128(1e14), 200);
            _slowOrder(bob, false, 1e15, uint128(1e14), 200);
        }
        vm.roll(vm.getBlockNumber() + 10);
        _setPriorityFee(1 gwei);

        uint256 before = gasleft();
        _fastSwap(true, -1e15);
        used = before - gasleft();
        assertGt(hook.oldestUnsettledEpoch(), 1, "batch did not settle");
    }

    // ==================================================================
    // §15 scenario 18 — empty-range recapture fallback
    // ==================================================================

    /// @notice PRD §6.2 makes the fallback mandatory, not defensive: `donate()`
    /// reverts when no liquidity is in range, and a fully CoW-matched batch
    /// never touches the curve — so it cannot rely on a residual swap having
    /// proven liquidity exists. `f_slow` must still reach LPs eventually, and
    /// must never be kept by the hook (I5, I7).
    function test_recaptureDefersWhenNoLiquidityIsInRangeThenSweeps() public {
        // Remove all liquidity, so `donate()` has nobody to pay.
        _addLiquidity(-6000, 6000, -100 ether);

        // A perfectly matched pair: settles entirely by coincidence of wants,
        // touching no curve at all.
        _slowOrder(alice, true, 1e16, uint128(1e15), 200);
        _slowOrder(bob, false, 1e16, uint128(1e15), 200);

        vm.roll(vm.getBlockNumber() + 4000);
        hook.forceSettle();

        uint256 deferred0 = hook.lpClaimable0();
        uint256 deferred1 = hook.lpClaimable1();
        assertTrue(deferred0 > 0 || deferred1 > 0, "f_slow vanished instead of being deferred");

        // Sweeping while still empty must re-defer, not revert and not lose it.
        hook.sweepRecapture();
        assertEq(hook.lpClaimable0(), deferred0, "a failed sweep changed the deferred balance");
        assertEq(hook.lpClaimable1(), deferred1, "a failed sweep changed the deferred balance");

        // Once liquidity is back, the same money reaches LPs.
        _addLiquidity(-6000, 6000, 100 ether);
        hook.sweepRecapture();
        assertEq(hook.lpClaimable0(), 0, "recapture never reached LPs");
        assertEq(hook.lpClaimable1(), 0, "recapture never reached LPs");
    }
}
