// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Tick-bitmap search for the bounds of the current constant-liquidity
/// range.
///
/// @dev `internal`, so it inlines into `BatchSolver` — its only consumer, and
/// itself a deployed library. Keeping it out of the hook matters for size:
/// `BitMath` and `TickMath` both inline here.
library TickScan {
    /// @dev Words of tick bitmap to scan in each direction before giving up and
    /// using the last word boundary reached. That boundary is always a *safe*
    /// bound — no liquidity change can occur before it — so the budget trades
    /// fill size for gas, never correctness.
    ///
    /// Scanning more than one word is not optional. A single-word search
    /// returns the word's own edge when the word holds no initialised tick, and
    /// at bit position 0 that edge IS the current price — a zero-width range.
    /// Tick 0, the usual initialisation price, sits at exactly that position.
    uint256 internal constant MAX_BITMAP_WORDS = 8;

    /// @notice Bounds of the range over which active liquidity is constant.
    ///
    /// @dev Liquidity changes only at *initialised* ticks, so this searches the
    /// tick bitmap rather than snapping to the next multiple of `spacing`. The
    /// distinction is not cosmetic: most spacing multiples carry no position,
    /// and clamping to them would force nearly every batch into a partial fill.
    ///
    /// When a word contains no initialised tick, its boundary is returned,
    /// which is still a correct bound since no liquidity change can occur
    /// before it.
    function activeRangeTicks(
        IPoolManager poolManager,
        PoolId poolId,
        int24 tick,
        int24 spacing
    ) internal view returns (int24 lowerTick, int24 upperTick) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;

        lowerTick = _scanDown(poolManager, poolId, compressed, spacing);
        upperTick = _scanUp(poolManager, poolId, compressed, spacing);
    }

    /// @dev Cursor arithmetic is done in `int256`, not `int24`.
    ///
    /// A word step moves the cursor by up to 256 compressed ticks, and the
    /// cursor is only converted back to a tick by multiplying by the spacing.
    /// For a wide-spaced pool that product leaves `int24` range after a single
    /// step off the end of the initialised ticks — `-257 * 32767` is already
    /// past `int24` min — and the checked multiplication would then panic
    /// *inside* settlement. On an immutable, pool-bound hook that is permanent:
    /// every settlement for that pool reverts forever. Widening the cursor and
    /// clamping at the end keeps the out-of-range case returning the tick
    /// range's own boundary.
    function _scanDown(
        IPoolManager poolManager,
        PoolId poolId,
        int24 compressed,
        int24 spacing
    ) private view returns (int24) {
        int256 cursor = compressed;
        int256 sp = spacing;

        for (uint256 w; w < MAX_BITMAP_WORDS; ++w) {
            (int16 wordPos, uint8 bitPos) = _position(int24(cursor));
            uint256 masked =
                StateLibrary.getTickBitmap(poolManager, poolId, wordPos) & ((1 << bitPos) - 1 + (1 << bitPos));

            if (masked != 0) {
                return _clampTick((cursor - int256(uint256(bitPos - BitMath.mostSignificantBit(masked)))) * sp);
            }
            // Step to the last compressed tick of the word below and continue.
            cursor = cursor - int256(uint256(bitPos)) - 1;
            if (cursor * sp <= TickMath.MIN_TICK) break;
        }
        return _clampTick(cursor * sp);
    }

    function _scanUp(
        IPoolManager poolManager,
        PoolId poolId,
        int24 compressed,
        int24 spacing
    ) private view returns (int24) {
        int256 cursor = int256(compressed) + 1;
        int256 sp = spacing;

        for (uint256 w; w < MAX_BITMAP_WORDS; ++w) {
            (int16 wordPos, uint8 bitPos) = _position(int24(cursor));
            uint256 masked = StateLibrary.getTickBitmap(poolManager, poolId, wordPos) & ~((1 << bitPos) - 1);

            if (masked != 0) {
                return _clampTick((cursor + int256(uint256(BitMath.leastSignificantBit(masked) - bitPos))) * sp);
            }
            cursor = cursor + int256(uint256(type(uint8).max - bitPos)) + 1;
            if (cursor * sp >= TickMath.MAX_TICK) break;
        }
        return _clampTick(cursor * sp);
    }

    function _clampTick(
        int256 t
    ) private pure returns (int24) {
        if (t < TickMath.MIN_TICK) return TickMath.MIN_TICK;
        if (t > TickMath.MAX_TICK) return TickMath.MAX_TICK;
        return int24(t);
    }

    function _position(
        int24 compressed
    ) private pure returns (int16 wordPos, uint8 bitPos) {
        assembly ("memory-safe") {
            wordPos := sar(8, compressed)
            bitPos := and(compressed, 0xff)
        }
    }
}
