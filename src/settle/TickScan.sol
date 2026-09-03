// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

library TickScan {
    uint256 internal constant MAX_BITMAP_WORDS = 8;

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
