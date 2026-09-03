// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {KesselHook} from "../../src/KesselHook.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";

/// @notice Shared fixture for Kessel tests.
///
/// Builds on v4-core's `Deployers` and adds the two things Kessel needs that a
/// generic v4 fixture does not: a hook deployed at an address whose low bits
/// match its permission bitmap, and a dynamic-fee pool bound to that hook.
///
/// A dynamic-fee pool cannot exist without a hook (`Hooks.isValidHookAddress`
/// rejects `address(0)` for a dynamic fee), so the pool and the hook are
/// created together and cannot be separated.
abstract contract KesselTestBase is Deployers {
    using StateLibrary for IPoolManager;

    int24 internal constant TICK_SPACING = 60;

    /// @dev The frozen permission bitmap (DD-8). `beforeSwap` for lane routing
    /// and the fee override, `beforeSwapReturnDelta` for async Slow-Lane
    /// intake, and `afterSwap` for piggyback settlement.
    ///
    /// This constant is what pins DD-8 in the test suite: if
    /// `getHookPermissions()` ever changes, hook deployment fails here rather
    /// than silently producing a different address.
    uint160 internal constant KESSEL_FLAGS =
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    /// @dev Retained from the Phase-0 scaffold, which pinned the flags Kessel
    /// was already known to need while DD-8 was still open. DD-8 is now
    /// resolved and `KESSEL_FLAGS` is the frozen bitmap; this subset is kept so
    /// the characterization tests that use it keep testing what they tested.
    uint160 internal constant KNOWN_REQUIRED_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;

    /// @dev Placeholder static fee for characterization fixtures that do not
    /// need a dynamic-fee pool. 0.30%, in hundredths of a bip.
    uint24 internal constant STATIC_FEE = 3000;

    KesselHook internal hook;
    PoolId internal poolId;
    address internal governance = address(0x60F);

    /// @dev Which side the deployment declares as the gas token, selecting the
    /// Fast-Lane tax mode (DD-4 as amended). Defaults to `NONE` — the rate form
    /// — so that every test written before the amendment keeps testing exactly
    /// what it tested. A test that wants the size-denominated form sets this
    /// before calling `_deployKessel()`.
    uint8 internal gasTokenSide = 0;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    /// @notice Deploy manager, currencies, the hook, and a dynamic-fee pool
    /// with a wide liquidity range.
    function _deployKessel() internal {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        _deployHookAtFlaggedAddress();

        (key, poolId) = initPool(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING, SQRT_PRICE_1_1
        );
    }

    /// @dev Deploy the hook to an address carrying `KESSEL_FLAGS` in its low
    /// bits. Production mines this address with CREATE2; tests place the code
    /// directly, which is equivalent for everything except the deploy
    /// transaction itself.
    function _deployHookAtFlaggedAddress() private {
        address target = address(uint160(KESSEL_FLAGS) | (uint160(0x4444) << 144));
        deployCodeTo(
            "KesselHook.sol:KesselHook",
            abi.encode(manager, currency0, currency1, TICK_SPACING, governance, gasTokenSide),
            target
        );
        hook = KesselHook(target);
    }

    /// @notice Phase-0 baseline: a hookless *static*-fee pool.
    ///
    /// @dev Deliberately not dynamic-fee: v4 rejects a dynamic-fee pool whose
    /// hook is `address(0)`, since nothing could ever set the fee. Used only by
    /// the characterization tests that pin upstream v4 behaviour.
    function _deployHooklessPool() internal {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (key, poolId) = initPool(currency0, currency1, IHooks(address(0)), STATIC_FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }

    /// @dev Add liquidity across a wide range so the Fast Lane always has depth.
    function _addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        int256 liquidity
    ) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidity, salt: bytes32(0)
            }),
            ""
        );
    }

    function _addWideLiquidity() internal {
        _addLiquidity(-6000, 6000, 100 ether);
    }

    // ------------------------------------------------------------------
    // Swap helpers
    // ------------------------------------------------------------------

    function _fastSwap(
        bool zeroForOne,
        int256 amountSpecified
    ) internal {
        _swapWithData(zeroForOne, amountSpecified, LaneCodec.encodeFast());
    }

    /// @notice Submit a Slow-Lane order.
    /// @param minOut Trader's limit, expressed as a minimum output for the
    /// whole input. Becomes the order's limit price (DD-11).
    function _slowOrder(
        address trader,
        bool zeroForOne,
        uint256 amountIn,
        uint128 minOut,
        uint32 expiryEpochs
    ) internal returns (uint256 orderId) {
        orderId = hook.nextOrderId();
        _swapWithData(zeroForOne, -int256(amountIn), LaneCodec.encodeSlow(trader, minOut, expiryEpochs));
    }

    function _swapWithData(
        bool zeroForOne,
        int256 amountSpecified,
        bytes memory hookData
    ) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    /// @dev Set the priority fee for the next call, which is the Fast Lane's
    /// only urgency signal (PRD §2.3). `tx.gasprice = basefee + priority`.
    function _setPriorityFee(
        uint256 priorityFeeWei
    ) internal {
        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei + priorityFeeWei);
    }

    // ------------------------------------------------------------------
    // Invariant helpers
    // ------------------------------------------------------------------

    /// @notice The hook's ERC-6909 custody balances — the quantity I2
    /// conserves against outstanding trader claims.
    function _custody() internal view returns (uint256 c0, uint256 c1) {
        c0 = manager.balanceOf(address(hook), currency0.toId());
        c1 = manager.balanceOf(address(hook), currency1.toId());
    }

    /// @notice Total obligations the hook owes: unfilled input still escrowed,
    /// plus settled output not yet redeemed, plus recapture owed to LPs.
    ///
    /// @dev Finalised orders zero both fields, so no status filtering is needed
    /// — which is deliberate: a helper that had to reason about status could
    /// hide a bug where a finalised order still carried a balance.
    function _obligations() internal view returns (uint256 o0, uint256 o1) {
        uint256 last = hook.nextOrderId();
        for (uint256 id = 1; id < last; ++id) {
            OrderView memory v = _order(id);
            if (v.zeroForOne) {
                o0 += v.amountInRemaining;
                o1 += v.owedOut;
            } else {
                o1 += v.amountInRemaining;
                o0 += v.owedOut;
            }
        }
        o0 += hook.lpClaimable0();
        o1 += hook.lpClaimable1();
    }

    /// @dev Mirror of `OrderStatus` so the helper above can name the values
    /// without importing the enum into every test.
    enum KesselHook_OrderStatus {
        NONE,
        PENDING,
        FILLED,
        REDEEMED,
        REFUNDED
    }

    /// @dev Mirror of the hook's `Order` struct. Returned as a struct rather
    /// than a tuple because the eight-value form exceeds the EVM stack limit
    /// under the non-`via_ir` dev profile.
    /// @dev All members are statically sized, so the flat tuple returned by the
    /// public `orders` getter has exactly this struct's encoding and can be
    /// decoded in one step. Decoding member-by-member exceeds the stack limit
    /// under the non-`via_ir` dev profile.
    struct OrderView {
        address trader;
        bool zeroForOne;
        uint64 expiryBlock;
        uint128 amountInRemaining;
        uint128 owedOut;
        uint160 limitPriceX96;
        uint32 epochSubmitted;
        uint32 epochExpiry;
        uint8 status;
    }

    function _order(
        uint256 id
    ) internal view returns (OrderView memory v) {
        (bool ok, bytes memory data) = address(hook).staticcall(abi.encodeWithSignature("orders(uint256)", id));
        require(ok, "orders() call failed");
        v = abi.decode(data, (OrderView));
    }

    function _statusOf(
        uint256 id
    ) internal view returns (KesselHook_OrderStatus) {
        return KesselHook_OrderStatus(_order(id).status);
    }

    function _fundAndApprove(
        address who,
        uint256 amount
    ) internal {
        deal(Currency.unwrap(currency0), who, amount);
        deal(Currency.unwrap(currency1), who, amount);
        vm.startPrank(who);
        IERC20Like(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20Like(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }
}

interface IERC20Like {
    function approve(
        address,
        uint256
    ) external returns (bool);
    function balanceOf(
        address
    ) external view returns (uint256);
}
