// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {KesselHook} from "../src/KesselHook.sol";
import {OrderStatus} from "../src/KesselTypes.sol";
import {LaneCodec} from "../src/lanes/LaneCodec.sol";

interface IERC20Like {
    function approve(
        address,
        uint256
    ) external returns (bool);
    function balanceOf(
        address
    ) external view returns (uint256);
}

abstract contract DemoBase is Script {
    IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
    KesselHook hook = KesselHook(vm.envAddress("KESSEL_HOOK"));
    Currency c0 = Currency.wrap(vm.envAddress("CURRENCY0"));
    Currency c1 = Currency.wrap(vm.envAddress("CURRENCY1"));

    function key() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: int24(vm.envInt("TICK_SPACING")),
            hooks: IHooks(address(hook))
        });
    }

    function settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }
}

/// @notice Step 1. Routers, liquidity, one Fast-Lane swap, one Slow-Lane order.
contract DemoSeed is DemoBase {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);

        vm.startBroadcast(pk);
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(pm);
        PoolSwapTest swap = new PoolSwapTest(pm);

        IERC20Like(Currency.unwrap(c0)).approve(address(lp), type(uint256).max);
        IERC20Like(Currency.unwrap(c1)).approve(address(lp), type(uint256).max);
        IERC20Like(Currency.unwrap(c0)).approve(address(swap), type(uint256).max);
        IERC20Like(Currency.unwrap(c1)).approve(address(swap), type(uint256).max);

        lp.modifyLiquidity(
            key(),
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ""
        );

        uint256 before1 = IERC20Like(Currency.unwrap(c1)).balanceOf(me);
        swap.swap(
            key(),
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings(),
            LaneCodec.encodeFast()
        );
        uint256 got = IERC20Like(Currency.unwrap(c1)).balanceOf(me) - before1;

        uint256 orderId = hook.nextOrderId();
        swap.swap(
            key(),
            SwapParams({zeroForOne: true, amountSpecified: -1e16, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings(),
            LaneCodec.encodeSlow(me, 1, 20)
        );
        vm.stopBroadcast();

        console2.log("SWAP_ROUTER=%s", address(swap));
        console2.log("LP_ROUTER=%s", address(lp));
        console2.log("fast swap out (c1 wei)", got);
        console2.log("SLOW_ORDER_ID=%s", orderId);
        console2.log("epoch now", hook.currentEpoch());
    }
}

/// @notice Step 2, after `minSettleAge` blocks. A Fast swap carries the batch,
/// then the trader redeems.
contract DemoSettle is DemoBase {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        PoolSwapTest swap = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));
        uint256 orderId = vm.envUint("SLOW_ORDER_ID");

        vm.startBroadcast(pk);
        swap.swap(
            key(),
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            settings(),
            LaneCodec.encodeFast()
        );
        vm.stopBroadcast();

        (,,, uint128 remaining, uint128 owedOut,,,, OrderStatus status) = hook.orders(orderId);
        console2.log("after carry -- remaining", remaining);
        console2.log("after carry -- owedOut  ", owedOut);
        console2.log("after carry -- status   ", uint8(status));

        if (owedOut > 0) {
            uint256 before1 = IERC20Like(Currency.unwrap(c1)).balanceOf(me);
            vm.broadcast(pk);
            hook.redeem(orderId);
            console2.log("REDEEMED (c1 wei)", IERC20Like(Currency.unwrap(c1)).balanceOf(me) - before1);
        }
    }
}
