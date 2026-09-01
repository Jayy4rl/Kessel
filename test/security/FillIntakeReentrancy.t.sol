// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

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
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice Slow-Lane intake reached by reentrancy from inside a redemption.
///
/// @dev `_settling` is held across `_payoutOrder` (SR-6), and `poolManager.take`
/// of native currency hands control to the recipient with a bare `call`. DD-14
/// refuses native ETH only as Slow-Lane *input*, so a `oneForZero` order on an
/// ETH-quoted pool is accepted and pays out in native ETH — meaning every such
/// deployment hands an arbitrary contract control while a payout is in flight.
///
/// SR-6 closed the paths that mattered then: a reentrant settlement is stopped
/// by `_settling`, and `redeem`, `forceSettle` and `sweepRecapture` are stopped
/// by v4's nested-`unlock` prohibition. Slow-Lane *intake* was covered by
/// neither, because `poolManager.swap` is `onlyWhenUnlocked` rather than
/// `onlyByTheUnlocker` and intake needs no unlock of its own. It could therefore
/// write `warehoused*`, `orders`, `epochOrderIds` and `currentEpoch` underneath
/// an in-flight payout.
///
/// No concrete corruption was constructed through it. It is closed structurally
/// anyway: SR-4 is the standing reminder that "unreachable by argument" is not
/// the same as unreachable, and this contract cannot be patched after
/// deployment.
contract FillIntakeReentrancyTest is KesselTestBase {
    MockERC20 internal token;
    IntakeReenteringTrader internal attacker;

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

        vm.deal(address(this), 2_000 ether);
        token.mint(address(this), 2_000 ether);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        modifyLiquidityRouter.modifyLiquidity{value: 600 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ""
        );

        attacker = new IntakeReenteringTrader(manager, hook, swapRouter, key);
        token.mint(address(attacker), 100 ether);
        attacker.approveRouter(token);
    }

    /// @dev The payout must complete, and the reentrant intake must be refused
    /// rather than interleaved with it.
    function test_intakeIsRefusedDuringARedemptionPayout() public {
        uint256 id = attacker.submit(5 ether);

        vm.roll(block.number + 5);
        _setPriorityFee(1 gwei);
        swapRouter.swap{value: 1e15}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LaneCodec.encodeFast()
        );

        assertGt(_order(id).owedOut, 0, "setup: the order should have accrued output");

        uint256 ordersBefore = hook.nextOrderId();
        attacker.arm();
        hook.redeem(id);

        assertTrue(attacker.intakeReverted(), "Slow-Lane intake should be refused during a payout");
        assertEq(hook.nextOrderId(), ordersBefore, "a reentrant order was recorded mid-payout");
        assertGt(address(attacker).balance, 0, "the payout itself did not complete");

        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertGe(c0, o0, "I2: currency0 custody below obligations");
        assertGe(c1, o1, "I2: currency1 custody below obligations");
    }
}

/// @notice Opens a Slow-Lane order from inside its own ETH payout.
contract IntakeReenteringTrader {
    IPoolManager internal immutable manager;
    KesselHook internal immutable hook;
    PoolSwapTest internal immutable router;
    PoolKey internal key;

    bool internal armed;
    bool public intakeReverted;

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

    function arm() external {
        armed = true;
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
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            LaneCodec.encodeSlow(address(this), uint128(amountIn / 10), 200)
        );
    }

    /// @dev `poolManager.take` of native currency lands here, inside the hook's
    /// own redemption `unlock`, with `_settling` held.
    receive() external payable {
        if (!armed) return;
        armed = false;

        // A DIRECT `poolManager.swap` carrying SLOW hookData. `swap` is
        // `onlyWhenUnlocked`, so v4 permits this while the hook's unlock is
        // open; only the hook itself can refuse it.
        try manager.swap(
            key,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -1 ether,
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970341
            }),
            LaneCodec.encodeSlow(address(this), 1e17, 5)
        ) returns (
            BalanceDelta
        ) {
            intakeReverted = false;
        } catch {
            intakeReverted = true;
        }
    }
}
