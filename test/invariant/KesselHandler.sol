// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {OrderStatus} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";

/// @notice Action driver for the stateful invariant run.
///
/// Foundry calls these entry points in random order with random arguments. The
/// handler's job is to keep every call *plausible* — a run in which every
/// action reverts proves nothing — while never constraining the system into the
/// happy path. Actions that the protocol may legitimately refuse (a settlement
/// that is not yet due, a redemption with nothing to collect) are swallowed, and
/// the counters below record how much real work a run actually did so the
/// invariants can assert the run was not vacuous.
contract KesselHandler is CommonBase, StdCheats, StdUtils {
    IPoolManager public immutable manager;
    KesselHook public immutable hook;
    PoolSwapTest public immutable swapRouter;
    PoolKey internal key;
    Currency public immutable currency0;
    Currency public immutable currency1;

    uint160 internal constant MIN_PRICE_LIMIT = 4295128739 + 1;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342 - 1;

    address[3] public traders = [address(0xA11CE), address(0xB0B), address(0xCA401)];

    // ---- run statistics, used to prove the run was not vacuous -----------
    uint256 public fastSwaps;
    uint256 public slowOrders;
    uint256 public settlements;
    uint256 public redemptions;

    /// @dev Highest status each order has ever reached, so the invariant can
    /// detect a terminal state being left (I3).
    mapping(uint256 orderId => uint8) public everStatus;

    constructor(
        IPoolManager _manager,
        KesselHook _hook,
        PoolSwapTest _router,
        PoolKey memory _key
    ) {
        manager = _manager;
        hook = _hook;
        swapRouter = _router;
        key = _key;
        currency0 = _key.currency0;
        currency1 = _key.currency1;
    }

    function _fund(
        uint256 amount
    ) internal {
        deal(Currency.unwrap(currency0), address(this), amount * 4);
        deal(Currency.unwrap(currency1), address(this), amount * 4);
        IERC20Approve(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Approve(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
    }

    function _swap(
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) internal returns (bool) {
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        ) {
            return true;
        } catch {
            return false;
        }
    }

    // ======================================================================
    // Actions
    // ======================================================================

    function fastSwap(
        uint96 amountSeed,
        bool zeroForOne,
        uint64 prioritySeed
    ) external {
        uint256 amount = bound(amountSeed, 1e12, 5e16);
        _fund(amount);

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + bound(prioritySeed, 0, 100 gwei));

        if (_swap(zeroForOne, -int256(amount), LaneCodec.encodeFast())) ++fastSwaps;
    }

    function slowOrder(
        uint96 amountSeed,
        bool zeroForOne,
        uint16 limitBps,
        uint8 traderSeed,
        uint8 expirySeed
    ) external {
        uint256 amount = bound(amountSeed, 1e12, 5e16);
        _fund(amount);

        // A limit somewhere between deeply in the money and unreachable, so the
        // run exercises both filled and rolled orders.
        uint256 minOut = amount * bound(limitBps, 1_000, 12_000) / 10_000;
        if (minOut == 0) minOut = 1;

        address trader = traders[traderSeed % 3];
        uint32 expiry = uint32(bound(expirySeed, 1, 8));

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei);

        if (_swap(zeroForOne, -int256(amount), LaneCodec.encodeSlow(trader, uint128(minOut), expiry))) ++slowOrders;
    }

    /// @dev Settlement via the piggyback path: a Fast-Lane swap carries it.
    function piggybackSettle(
        uint96 amountSeed,
        bool zeroForOne,
        uint8 blocksSeed
    ) external {
        vm.roll(block.number + bound(blocksSeed, 1, 20));

        uint32 before = hook.oldestUnsettledEpoch();
        this.fastSwap(amountSeed, zeroForOne, 1 gwei);
        if (hook.oldestUnsettledEpoch() != before) ++settlements;
    }

    /// @dev Settlement via the forced path: its own `unlock`.
    function forceSettle(
        uint16 blocksSeed
    ) external {
        vm.roll(block.number + bound(blocksSeed, 1, 4000));
        try hook.forceSettle() {
            ++settlements;
        } catch {}
    }

    function redeem(
        uint256 orderSeed
    ) external {
        uint256 next = hook.nextOrderId();
        if (next <= 1) return;
        uint256 id = bound(orderSeed, 1, next - 1);
        try hook.redeem(id) {
            ++redemptions;
        } catch {}
    }

    function sweep() external {
        try hook.sweepRecapture() {} catch {}
    }

    /// @dev Let a caller record the furthest state each order has reached, so
    /// the invariant can prove a terminal state is never left (I3).
    function recordStatuses() external {
        uint256 next = hook.nextOrderId();
        for (uint256 id = 1; id < next; ++id) {
            (,,,,,,, OrderStatus status) = hook.orders(id);
            if (uint8(status) > everStatus[id]) everStatus[id] = uint8(status);
        }
    }
}

interface IERC20Approve {
    function approve(
        address,
        uint256
    ) external returns (bool);
}
