// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CurrencySettler} from "@uniswap/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Epoch, KesselErrors, KesselEvents, Lane, Order, OrderStatus} from "./KesselTypes.sol";
import {FastLaneFee} from "./lanes/FastLaneFee.sol";
import {LaneCodec} from "./lanes/LaneCodec.sol";
import {BatchSolver} from "./settle/BatchSolver.sol";
import {Clearing} from "./settle/Clearing.sol";

contract KesselHook is IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000; // v4 fee units
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint24 internal constant F_BASE_MIN = 100; // 1 bp
    uint24 internal constant F_BASE_MAX = 100_000; // 10%
    
    uint24 internal constant MAX_FAST_FEE = 50_000; // 5%
    uint256 internal constant K_MIN = 0;
    uint256 internal constant K_MAX = 100_000; // 1 gwei => +10%

    uint256 internal constant K_GAS_MIN = 0;
    uint256 internal constant K_GAS_MAX = 10_000_000;

    uint8 internal constant GAS_TOKEN_NONE = 0;
    uint8 internal constant GAS_TOKEN_CURRENCY0 = 1;
    uint8 internal constant GAS_TOKEN_CURRENCY1 = 2;

    uint32 internal constant MIN_SETTLE_AGE_MIN = 1;
    uint32 internal constant MIN_SETTLE_AGE_MAX = 300;
    uint32 internal constant MAX_DELAY_MIN = 2;
    uint32 internal constant MAX_DELAY_MAX = 100_000;
    uint32 internal constant MAX_EXPIRY_EPOCHS = 256;
   
    uint32 internal constant EXPIRY_BLOCK_FLOOR_MAX = 7_200;
    uint16 internal constant EXPIRY_FORFEIT_BPS_MAX = 100; // 1%

 
    uint256 internal constant MAX_ORDERS_PER_EPOCH = 32;
    
    uint256 internal constant MAX_CLEARING_ROUNDS = 4;

   
    uint16 internal constant RESIDUAL_CAP_BPS_MIN = 500; // 5% of break-even
    uint16 internal constant RESIDUAL_CAP_BPS_MAX = 10_000; // 100% = break-even
    
    uint256 internal constant I4_TOLERANCE_PPM = 100; // 0.01%
    uint256 internal constant I4_DUST_FLOOR = 1e6;

    
    uint256 internal constant I8_TOLERANCE_PPM = 1; // 0.0001%

    IPoolManager public immutable poolManager;

    PoolKey internal immutablePoolKeyStorage;
    PoolId public immutable poolId;
    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;

    
    uint8 internal immutable gasTokenSide;

    address public governance;
    bool public paused;

    uint24 public fBase = 3_000; // 0.30%
    uint24 public fSlow = 500; // 0.05% — must stay strictly below fBase
    uint256 public k = 500; // rate form: 1 gwei => +5 bp
   
    uint256 public kGas = 150_000;

    uint32 public minSettleAge = 2; // blocks; guards settlement-time pricing
    uint32 public maxDelay = 300; // blocks
    uint32 public absoluteMaxDelay = 3_000; // blocks; the liveness escape
    uint32 internal minForceSettleOrders = 2; // anti-grief size floor for forced settlement
    uint16 public expiryForfeitBps = 10; // 0.10%

   
    uint16 internal residualCapBps = 5_000;

    
    uint128 public maxWarehouse0 = type(uint128).max;
    uint128 public maxWarehouse1 = type(uint128).max;

   
    uint128 public minOrderSize0;
    uint128 public minOrderSize1;

    
    uint256 public nextOrderId = 1;
    mapping(uint256 orderId => Order) public orders;

    uint32 public currentEpoch = 1;
    
    uint32 public oldestUnsettledEpoch = 1;

    mapping(uint32 epoch => Epoch) public epochs;
    mapping(uint32 epoch => uint256[] orderIds) internal epochOrderIds;

    uint128 public warehoused0;
    uint128 public warehoused1;

   
    uint256 public lpClaimable0;
    uint256 public lpClaimable1;

    
    bool private _settling;

    enum UnlockAction {
        SETTLE,
        REDEEM,
        SWEEP,
        SETTLE_WITH_FILL
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert KesselErrors.NotPoolManager();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert KesselErrors.NotGovernance();
        _;
    }

   
    constructor(
        IPoolManager _poolManager,
        Currency _currency0,
        Currency _currency1,
        int24 _tickSpacing,
        address _governance,
        uint8 _gasTokenSide
    ) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

        if (_governance == address(0)) revert KesselErrors.ParameterOutOfBounds();
        if (_gasTokenSide > GAS_TOKEN_CURRENCY1) revert KesselErrors.ParameterOutOfBounds();

       if (_gasTokenSide == GAS_TOKEN_CURRENCY1 && _currency0.isAddressZero()) {
            revert KesselErrors.ParameterOutOfBounds();
        }
        gasTokenSide = _gasTokenSide;

        currency0 = _currency0;
        currency1 = _currency1;
        tickSpacing = _tickSpacing;
        governance = _governance;

        PoolKey memory pk = PoolKey({
            currency0: _currency0,
            currency1: _currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(this))
        });
        immutablePoolKeyStorage = pk;
        poolId = pk.toId();
    }

    function poolKey() public view returns (PoolKey memory) {
        return immutablePoolKeyStorage;
    }

   function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // lane routing, fee override, Slow-Lane intake
            afterSwap: true, // piggyback settlement only
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // async Slow-Lane intake
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

   function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert KesselErrors.UnknownPool();

        (Lane lane, address trader, uint128 minOut, uint32 expiryEpochs) = LaneCodec.decode(hookData, sender);

        if (lane == Lane.FAST) {
            uint256 priorityFee = FastLaneFee.priorityFeePerGas();
            uint24 feeCharged = _fastFee(params, priorityFee);

            emit KesselEvents.LaneChosen(sender, Lane.FAST);
            emit KesselEvents.FastSwap(
                sender,
                params.zeroForOne,
                params.amountSpecified,
                priorityFee,
                feeCharged,
                FastLaneFee.premium(feeCharged, fBase)
            );

           
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                feeCharged | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        return _openSlowOrder(key, params, trader, minOut, expiryEpochs);
    }

    
    function _fastFee(
        SwapParams calldata params,
        uint256 priorityFee
    ) private view returns (uint24) {
        uint8 side = gasTokenSide;

        if (side != GAS_TOKEN_NONE) {
            (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
            (bool ok, uint256 sizeWei) = FastLaneFee.sizeInGasToken(
                params.zeroForOne, params.amountSpecified, sqrtPriceX96, side == GAS_TOKEN_CURRENCY0
            );
            if (ok) return FastLaneFee.feeBySize(fBase, kGas, priorityFee, sizeWei, MAX_FAST_FEE);
        }

        return FastLaneFee.fee(fBase, k, priorityFee, MAX_FAST_FEE);
    }

   
    function _openSlowOrder(
        PoolKey calldata key,
        SwapParams calldata params,
        address trader,
        uint128 minOut,
        uint32 expiryEpochs
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        if (paused) revert KesselErrors.Paused();

       
        if (_settling) revert KesselErrors.SettlementInProgress();

        if (params.amountSpecified >= 0) revert KesselErrors.SlowLaneRequiresExactInput();
        if (minOut == 0) revert KesselErrors.MinOutRequired();
        if (expiryEpochs == 0 || expiryEpochs > MAX_EXPIRY_EPOCHS) revert KesselErrors.ExpiryOutOfRange();

        bool zeroForOne = params.zeroForOne;
        Currency specified = zeroForOne ? key.currency0 : key.currency1;

    if (specified.isAddressZero()) revert KesselErrors.NativeEthNotSupportedInSlowLane();

        uint256 amountIn256 = uint256(-params.amountSpecified);
        if (amountIn256 > type(uint128).max) revert KesselErrors.AmountTooLarge();
        uint128 amountIn = uint128(amountIn256);

       uint128 floorSize = zeroForOne ? minOrderSize0 : minOrderSize1;
        if (amountIn < floorSize) revert KesselErrors.OrderBelowMinimum();

        _checkAndBookWarehouse(zeroForOne, amountIn);

        specified.take(poolManager, address(this), amountIn256, true);

        _recordOrder(trader, zeroForOne, amountIn, minOut, expiryEpochs);

      return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(amountIn)), 0), 0);
    }

   function _recordOrder(
        address trader,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        uint32 expiryEpochs
    ) private returns (uint256 orderId) {
        uint256 limit = zeroForOne
            ? FullMath.mulDiv(minOut, Q96, amountIn)  // floor on price
            : FullMath.mulDiv(amountIn, Q96, minOut); // ceiling on price
        if (limit > type(uint160).max) revert KesselErrors.AmountTooLarge();

        uint32 epoch = _epochAcceptingOrders();
        uint32 expiry = epoch + expiryEpochs;
        orderId = nextOrderId++;

        uint256 floorBlocks = maxDelay < EXPIRY_BLOCK_FLOOR_MAX ? maxDelay : EXPIRY_BLOCK_FLOOR_MAX;
        uint64 expiryBlock = uint64(epochs[epoch].openedAtBlock + floorBlocks);

        orders[orderId] = Order({
            trader: trader,
            zeroForOne: zeroForOne,
            expiryBlock: expiryBlock,
            amountInRemaining: amountIn,
            owedOut: 0,
            limitPriceX96: uint160(limit),
            epochSubmitted: epoch,
            epochExpiry: expiry,
            status: OrderStatus.PENDING
        });
        epochOrderIds[epoch].push(orderId);

        emit KesselEvents.LaneChosen(trader, Lane.SLOW);
        emit KesselEvents.SlowOrderSubmitted(orderId, trader, epoch, zeroForOne, amountIn, minOut, expiry);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) private returns (bytes4, int128) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert KesselErrors.UnknownPool();

        (Lane lane,,,) = LaneCodec.decode(hookData, address(0));
        if (lane != Lane.FAST) return (IHooks.afterSwap.selector, 0);
        if (paused || _settling) return (IHooks.afterSwap.selector, 0);

        uint32 epoch = oldestUnsettledEpoch;
        if (_piggybackDue(epoch)) {
            try this.settleFromCallback(epoch) {}
            catch {
                emit KesselEvents.SettlementSkipped(epoch);
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function settleFromCallback(
        uint32 epoch
    ) external {
        if (msg.sender != address(this)) revert KesselErrors.NotPoolManager();
        _settleEpoch(epoch);
    }

    function forceSettle() external {
        if (paused) revert KesselErrors.Paused();

        uint32 epoch = oldestUnsettledEpoch;
        if (!_forceSettleDue(epoch)) revert KesselErrors.SettlementNotDue();

        poolManager.unlock(abi.encode(UnlockAction.SETTLE, epoch, uint256(0), uint256(0)));
    }

    function settleWithFill(
        uint256 delivered
    ) external {
        if (paused) revert KesselErrors.Paused();

        if (currency0.isAddressZero() || currency1.isAddressZero()) {
            revert KesselErrors.FillerPathRequiresERC20();
        }
        if (msg.sender == address(this) || msg.sender == address(poolManager)) {
            revert KesselErrors.InvalidFiller();
        }

        uint32 epoch = oldestUnsettledEpoch;
        if (!_piggybackDue(epoch)) revert KesselErrors.SettlementNotDue();

        poolManager.unlock(abi.encode(UnlockAction.SETTLE_WITH_FILL, epoch, uint256(uint160(msg.sender)), delivered));
    }

    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert KesselErrors.NotPoolManager();

        (UnlockAction action, uint32 epoch, uint256 arg, uint256 arg2) =
            abi.decode(data, (UnlockAction, uint32, uint256, uint256));

        if (action == UnlockAction.SETTLE_WITH_FILL) {
            if (!_settleEpochInner(epoch, address(uint160(arg)), arg2)) {
                revert KesselErrors.NothingToSettle();
            }
            return "";
        }

        if (action == UnlockAction.SETTLE) {
            _settleEpoch(epoch);
        } else if (action == UnlockAction.REDEEM) {
            _payoutOrder(arg);
        } else {
            _sweep();
        }
        return "";
    }

   function _settleEpoch(
        uint32 epoch
    ) private {
        _settleEpochInner(epoch, address(0), 0);
    }

    function _settleEpochInner(
        uint32 epoch,
        address filler,
        uint256 delivered
    ) private returns (bool settled) {
        if (_settling) return false;
        _settling = true;

        Cand[] memory c = _loadCandidates(epoch);
        if (c.length == 0) {
            _advanceIfDrained(epoch);
            _settling = false;
            return false;
        }

        (Clearing.Solution memory sol, uint256 net0, uint256 net1, bool converged) = _solveEligibleSet(c);

        if (!converged || !sol.feasible || (net0 == 0 && net1 == 0)) {
            if (net0 == 0 && net1 == 0) {
                 _closeEpoch(epoch);
                _rollUnfilled(epoch);
            } else if (_pastLivenessEscape(epoch)) {
               _closeEpoch(epoch);
                _rollUnfilled(epoch);
            }
            _settling = false;
            return false;
        }

        if (filler != address(0)) _assertFillerNotInBatch(c, filler);

        _executeAndDistribute(epoch, c, sol, net0, net1, filler, delivered);

       if (filler != address(0) && sol.residualIn > 0) {
            Currency inCurrency = sol.zeroForOne ? currency0 : currency1;
            inCurrency.settle(poolManager, address(this), sol.residualIn, true);
            poolManager.take(inCurrency, filler, sol.residualIn);
        }

        _settling = false;
        return true;
    }

    function _assertFillerNotInBatch(
        Cand[] memory c,
        address filler
    ) private view {
        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live) continue;
            if (orders[c[i].id].trader == filler) revert KesselErrors.InvalidFiller();
        }
    }

struct Cand {
        uint256 id;
        bool zeroForOne;
        bool live;
        uint128 remaining;
        uint160 limitPriceX96;
        uint128 grossFilled;
        uint128 netFilled;
    }

    function _loadCandidates(
        uint32 epoch
    ) private view returns (Cand[] memory out) {
        uint256[] storage ids = epochOrderIds[epoch];
        uint256 len = ids.length;

        Cand[] memory buf = new Cand[](len);
        uint256 n;
        for (uint256 i; i < len; ++i) {
            if (n == MAX_ORDERS_PER_EPOCH) break;
            Order storage o = orders[ids[i]];
            if (o.status != OrderStatus.PENDING || o.amountInRemaining == 0 || _isExpired(o)) continue;
            buf[n] = Cand({
                id: ids[i],
                zeroForOne: o.zeroForOne,
                live: true,
                remaining: o.amountInRemaining,
                limitPriceX96: o.limitPriceX96,
                grossFilled: 0,
                netFilled: 0
            });
            ++n;
        }

        out = new Cand[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = buf[i];
        }
    }

    function _solverParams() private view returns (BatchSolver.Params memory) {
        return BatchSolver.Params({
            poolManager: poolManager,
            poolId: poolId,
            tickSpacing: tickSpacing,
            fBase: fBase,
            residualCapBps: residualCapBps
        });
    }

    function _solveEligibleSet(
        Cand[] memory c
    ) private view returns (Clearing.Solution memory sol, uint256 net0, uint256 net1, bool converged) {
        for (uint256 round; round < MAX_CLEARING_ROUNDS; ++round) {
            (net0, net1) = _aggregateNet(c);
            if (net0 == 0 && net1 == 0) return (sol, 0, 0, true);

            sol = BatchSolver.solveMultiRange(_solverParams(), net0, net1);
            if (!sol.feasible) return (sol, net0, net1, false);

            if (_dropIneligible(c, sol.priceX96) == 0) return (sol, net0, net1, true);
        }

        return (sol, net0, net1, false);
    }

    function _aggregateNet(
        Cand[] memory c
    ) private view returns (uint256 net0, uint256 net1) {
        uint24 slowFee = fSlow;
        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live) continue;
            uint256 net = _netOfSlowFee(c[i].remaining, slowFee);
            if (c[i].zeroForOne) net0 += net;
            else net1 += net;
        }
    }

    function _dropIneligible(
        Cand[] memory c,
        uint160 priceX96
    ) private view returns (uint256 dropped) {
        (uint256 effZeroForOne, uint256 effOneForZero) = _effectivePrices(priceX96);

        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live) continue;
            bool ok = Clearing.meetsLimit(
                c[i].zeroForOne, c[i].limitPriceX96, c[i].zeroForOne ? effZeroForOne : effOneForZero
            );
            if (!ok) {
                c[i].live = false;
                ++dropped;
            }
        }
    }

    function _effectivePrices(
        uint256 priceX96
    ) private view returns (uint256 effZeroForOne, uint256 effOneForZero) {
        uint256 slowFee = fSlow;
        effZeroForOne = FullMath.mulDiv(priceX96, FEE_DENOMINATOR - slowFee, FEE_DENOMINATOR);
        effOneForZero = FullMath.mulDiv(priceX96, FEE_DENOMINATOR, FEE_DENOMINATOR - slowFee);
    }

    function _assertLimitsHeld(
        Cand[] memory c,
        Pots memory p
    ) private view {
        if (p.filled0 == 0 && p.filled1 == 0) return;

        uint256 realised =
            p.filled0 > 0 ? Clearing.impliedPriceX96(p.pot1, p.filled0) : Clearing.impliedPriceX96(p.filled1, p.pot0);

        (uint256 effZeroForOne, uint256 effOneForZero) = _effectivePrices(realised);

        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live || c[i].grossFilled == 0) continue;

            uint256 limit = c[i].limitPriceX96;
            uint256 slack = (limit * I8_TOLERANCE_PPM) / FEE_DENOMINATOR;

            if (c[i].zeroForOne) {
                if (effZeroForOne + slack < limit) revert KesselErrors.LimitPriceBreached();
            } else {
                if (effOneForZero > limit + slack) revert KesselErrors.LimitPriceBreached();
            }
        }
    }

    function _executeAndDistribute(
        uint32 epoch,
        Cand[] memory c,
        Clearing.Solution memory sol,
        uint256 net0,
        uint256 net1,
        address filler,
        uint256 delivered
    ) private {
        _closeEpoch(epoch);

        (int256 poolDelta0, int256 poolDelta1) =
            filler == address(0) ? _executeResidual(sol) : _acceptFillerDelivery(epoch, sol, filler, delivered);

        uint256 lambdaX96;
        if (sol.residualIn == 0) {
            lambdaX96 = Q96;
        } else if (sol.zeroForOne) {
            lambdaX96 = Clearing.fillRatio(net0, net1, uint256(-poolDelta0), uint256(poolDelta1));
        } else {
            lambdaX96 = Clearing.fillRatio(net1, net0, uint256(-poolDelta1), uint256(poolDelta0));
        }
        if (lambdaX96 == 0) revert KesselErrors.NothingToSettle();

        Pots memory p;
        p.lambdaX96 = lambdaX96;
        (p.filled0, p.filled1, p.gross0, p.gross1) = _computeFills(c, lambdaX96);

        uint256 fee0 = p.gross0 - p.filled0;
        uint256 fee1 = p.gross1 - p.filled1;

        (p.pot0, fee0) = _potFor(p.filled0, poolDelta0, fee0);
        (p.pot1, fee1) = _potFor(p.filled1, poolDelta1, fee1);

        _assertUniformPrice(p.pot0, p.pot1, p.filled0, p.filled1);
        _assertLimitsHeld(c, p);

        uint256 settledCount = _applyFills(epoch, c, p);

        _recordEpoch(epoch, sol.priceX96, p, net0, net1, fee0, fee1, settledCount);
        _recapture(immutablePoolKeyStorage, fee0, fee1);
        _rollUnfilled(epoch);
    }

    function _rollUnfilled(
        uint32 from
    ) private {
         if (currentEpoch <= from) revert KesselErrors.EpochNotClosed();

        uint256[] storage ids = epochOrderIds[from];
        uint256 len = ids.length;

        for (uint256 i; i < len; ++i) {
            Order storage o = orders[ids[i]];
            if (o.status != OrderStatus.PENDING || o.amountInRemaining == 0) continue;
            if (_isExpired(o)) continue; // expired: leave it behind

            epochOrderIds[_epochAcceptingOrders()].push(ids[i]);
        }

        delete epochOrderIds[from];

        if (from == oldestUnsettledEpoch) {
            oldestUnsettledEpoch = from + 1;
            if (currentEpoch < oldestUnsettledEpoch) currentEpoch = oldestUnsettledEpoch;
        }
    }

    struct Pots {
        uint256 filled0;
        uint256 filled1;
        uint256 gross0;
        uint256 gross1;
        uint256 pot0;
        uint256 pot1;
        uint256 lambdaX96;
    }

    function _computeFills(
        Cand[] memory c,
        uint256 lambdaX96
    ) private view returns (uint256 filled0, uint256 filled1, uint256 gross0, uint256 gross1) {
        uint24 slowFee = fSlow;

        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live) continue;

            uint128 grossFilled = uint128(FullMath.mulDiv(c[i].remaining, lambdaX96, Q96));
            if (grossFilled > c[i].remaining) grossFilled = c[i].remaining; // rounding-up guard
            uint128 netFilled = uint128(_netOfSlowFee(grossFilled, slowFee));

            if (grossFilled == 0 || netFilled == 0) {
                c[i].live = false; // nothing to fill; leave it pending to roll
                continue;
            }

            c[i].grossFilled = grossFilled;
            c[i].netFilled = netFilled;

            if (c[i].zeroForOne) {
                gross0 += grossFilled;
                filled0 += netFilled;
            } else {
                gross1 += grossFilled;
                filled1 += netFilled;
            }
        }
    }

    function _potFor(
        uint256 filled,
        int256 poolDelta,
        uint256 fee
    ) private pure returns (uint256 pot, uint256 feeOut) {
        int256 signed = int256(filled) + poolDelta;
        if (signed >= 0) return (uint256(signed), fee);

        uint256 shortfall = uint256(-signed);
        if (shortfall > fee) revert KesselErrors.NothingToSettle();
        return (0, fee - shortfall);
    }

    function _executeResidual(
        Clearing.Solution memory sol
    ) private returns (int256 d0, int256 d1) {
        if (sol.residualIn == 0) return (0, 0);

        BalanceDelta d = poolManager.swap(
            immutablePoolKeyStorage,
            SwapParams({
                zeroForOne: sol.zeroForOne,
               amountSpecified: -int256(sol.residualIn.toInt128()),
                sqrtPriceLimitX96: sol.sqrtPriceTargetX96
            }),
            ""
        );
        d0 = d.amount0();
        d1 = d.amount1();

        if (d0 < 0) currency0.settle(poolManager, address(this), uint256(-d0), true);
        if (d1 < 0) currency1.settle(poolManager, address(this), uint256(-d1), true);
        if (d0 > 0) currency0.take(poolManager, address(this), uint256(d0), true);
        if (d1 > 0) currency1.take(poolManager, address(this), uint256(d1), true);
    }

   function _acceptFillerDelivery(
        uint32 epoch,
        Clearing.Solution memory sol,
        address filler,
        uint256 delivered
    ) private returns (int256 d0, int256 d1) {
        if (sol.residualIn == 0) return (0, 0);

        Currency outCurrency = sol.zeroForOne ? currency1 : currency0;
        uint256 floorOut = sol.residualOut;

        if (delivered < floorOut) revert KesselErrors.FillerUnderDelivered();

        outCurrency.settle(poolManager, filler, delivered, false);
        poolManager.mint(address(this), outCurrency.toId(), delivered);

        emit KesselEvents.SlowBatchFilledExternally(epoch, filler, sol.residualIn, floorOut, delivered);

        int256 paid = int256(sol.residualIn.toInt128());
        int256 got = int256(delivered.toInt128());

        if (sol.zeroForOne) return (-paid, got);
        return (got, -paid);
    }

    function _recordEpoch(
        uint32 epoch,
        uint160 priceX96,
        Pots memory p,
        uint256 net0,
        uint256 net1,
        uint256 fee0,
        uint256 fee1,
        uint256 settledCount
    ) private {
        Epoch storage e = epochs[epoch];
        e.clearingPriceX96 = priceX96;
        e.filledNetIn0 = p.filled0.toUint128();
        e.filledNetIn1 = p.filled1.toUint128();
        e.pot0 = p.pot0.toUint128();
        e.pot1 = p.pot1.toUint128();
        e.settled = true;

       uint256 matched = p.filled0 < p.filled1 ? p.filled0 : p.filled1;

        emit KesselEvents.SlowBatchSettled(epoch, priceX96, net0, net1, matched, p.lambdaX96, fee0, fee1, settledCount);
    }

    function _applyFills(
        uint32 epoch,
        Cand[] memory c,
        Pots memory p
    ) private returns (uint256 settledCount) {
        uint256 left1 = p.pot1;
        uint256 left0 = p.pot0;

        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live || c[i].grossFilled == 0) continue;

            uint128 grossFilled = c[i].grossFilled;
            uint256 netFilled = c[i].netFilled;

            uint256 out;
            if (c[i].zeroForOne) {
                out = p.filled0 == 0 ? 0 : FullMath.mulDiv(netFilled, p.pot1, p.filled0);
                if (out > left1) out = left1;
            } else {
                out = p.filled1 == 0 ? 0 : FullMath.mulDiv(netFilled, p.pot0, p.filled1);
                if (out > left0) out = left0;
            }

            if (out == 0) revert KesselErrors.NothingToSettle();

            if (c[i].zeroForOne) {
                left1 -= out;
                warehoused0 -= grossFilled;
            } else {
                left0 -= out;
                warehoused1 -= grossFilled;
            }

            Order storage o = orders[c[i].id];
            o.amountInRemaining -= grossFilled;
            uint128 out128 = out.toUint128();
            o.owedOut += out128;
            if (o.amountInRemaining == 0) o.status = OrderStatus.FILLED;

            ++settledCount;
            emit KesselEvents.SlowOrderFilled(c[i].id, epoch, grossFilled, out128);
        }
    }

    function _assertUniformPrice(
        uint256 pot0,
        uint256 pot1,
        uint256 filled0,
        uint256 filled1
    ) private pure {
        if (filled0 == 0 || filled1 == 0) return; // one-sided: trivially uniform
        if (pot0 < I4_DUST_FLOOR || pot1 < I4_DUST_FLOOR) return;

        uint256 priceA = Clearing.impliedPriceX96(pot1, filled0); // currency0 sellers
        uint256 priceB = Clearing.impliedPriceX96(filled1, pot0); // currency1 sellers
        uint256 diff = priceA > priceB ? priceA - priceB : priceB - priceA;
        uint256 scale = priceA > priceB ? priceA : priceB;

        if (diff * 1_000_000 > scale * I4_TOLERANCE_PPM) revert KesselErrors.NonUniformClearingPrice();
    }

    function _recapture(
        PoolKey memory key,
        uint256 fee0,
        uint256 fee1
    ) private {
        if (fee0 == 0 && fee1 == 0) return;

        try poolManager.donate(key, fee0, fee1, "") returns (BalanceDelta) {
            if (fee0 > 0) currency0.settle(poolManager, address(this), fee0, true);
            if (fee1 > 0) currency1.settle(poolManager, address(this), fee1, true);
            emit KesselEvents.RecaptureDonated(fee0, fee1);
        } catch {
            if (fee0 > 0) {
                lpClaimable0 += fee0;
                emit KesselEvents.RecaptureDeferred(Currency.unwrap(currency0), fee0);
            }
            if (fee1 > 0) {
                lpClaimable1 += fee1;
                emit KesselEvents.RecaptureDeferred(Currency.unwrap(currency1), fee1);
            }
        }
    }

    function sweepRecapture() external {
        if (lpClaimable0 == 0 && lpClaimable1 == 0 && currency0.balanceOfSelf() == 0 && currency1.balanceOfSelf() == 0)
        {
            return;
        }
        poolManager.unlock(abi.encode(UnlockAction.SWEEP, uint32(0), uint256(0), uint256(0)));
    }

function _sweep() private {
        uint256 a0 = lpClaimable0 + _absorbStray(currency0);
        uint256 a1 = lpClaimable1 + _absorbStray(currency1);
        lpClaimable0 = 0;
        lpClaimable1 = 0;
        _recapture(immutablePoolKeyStorage, a0, a1);
    }

    function _absorbStray(
        Currency c
    ) private returns (uint256 amount) {
        amount = c.balanceOfSelf();
        if (amount == 0) return 0;
        c.settle(poolManager, address(this), amount, false);
        poolManager.mint(address(this), c.toId(), amount);
    }

    function redeem(
        uint256 orderId
    ) external {
        Order storage o = orders[orderId];
        if (o.status == OrderStatus.NONE) revert KesselErrors.OrderNotFound();
        if (o.status == OrderStatus.REDEEMED || o.status == OrderStatus.REFUNDED) {
            revert KesselErrors.AlreadyFinalised();
        }

        bool expired = _isExpired(o);
        if (o.owedOut == 0 && !(expired && o.amountInRemaining > 0)) revert KesselErrors.NothingToRedeem();

        poolManager.unlock(abi.encode(UnlockAction.REDEEM, uint32(0), orderId, uint256(0)));
    }

    function _payoutOrder(
        uint256 orderId
    ) private {
        _settling = true;
        _payoutOrderInner(orderId);
        _settling = false;
    }

    function _payoutOrderInner(
        uint256 orderId
    ) private {
        Order storage o = orders[orderId];

        uint128 out = o.owedOut;
        Currency outCurrency = o.zeroForOne ? currency1 : currency0;
        Currency inCurrency = o.zeroForOne ? currency0 : currency1;

        if (out > 0) {
            o.owedOut = 0;
            outCurrency.settle(poolManager, address(this), out, true); // burn claim
            poolManager.take(outCurrency, o.trader, out); // pay trader
            emit KesselEvents.SlowOrderRedeemed(orderId, o.trader, out);
        }

        bool expired = _isExpired(o);
        if (expired && o.amountInRemaining > 0) {
            uint128 remaining = o.amountInRemaining;
            o.amountInRemaining = 0;

            uint128 forfeit = uint128(FullMath.mulDiv(remaining, expiryForfeitBps, BPS_DENOMINATOR));
            uint128 refund = remaining - forfeit;

            if (o.zeroForOne) warehoused0 -= remaining;
            else warehoused1 -= remaining;

            inCurrency.settle(poolManager, address(this), refund, true);
            poolManager.take(inCurrency, o.trader, refund);

            // The forfeit stays in custody and is routed to LPs, never kept.
            if (forfeit > 0) {
                if (o.zeroForOne) lpClaimable0 += forfeit;
                else lpClaimable1 += forfeit;
            }

            o.status = OrderStatus.REFUNDED;
            emit KesselEvents.SlowOrderRefunded(orderId, o.trader, refund, forfeit);
            return;
        }

        if (o.status == OrderStatus.FILLED && o.owedOut == 0) o.status = OrderStatus.REDEEMED;
    }

    function _closeEpoch(
        uint32 epoch
    ) private {
        if (epoch >= currentEpoch) currentEpoch = epoch + 1;
    }

    function _isExpired(
        Order storage o
    ) private view returns (bool) {
        if (currentEpoch <= o.epochExpiry) return false;
        return block.number >= o.expiryBlock;
    }

    function _pastLivenessEscape(
        uint32 epoch
    ) private view returns (bool) {
        uint64 openedAt = epochs[epoch].openedAtBlock;
        return openedAt != 0 && block.number >= openedAt + absoluteMaxDelay;
    }

    function _piggybackDue(
        uint32 epoch
    ) private view returns (bool) {
        Epoch storage e = epochs[epoch];
        if (e.openedAtBlock == 0) return false;
        if (epochOrderIds[epoch].length == 0) return false;
        return block.number >= e.openedAtBlock + minSettleAge;
    }

    function _forceSettleDue(
        uint32 epoch
    ) private view returns (bool) {
        Epoch storage e = epochs[epoch];
        if (e.openedAtBlock == 0) return false;

        uint256 pending = epochOrderIds[epoch].length;
        if (pending == 0) return false;
        if (block.number < e.openedAtBlock + maxDelay) return false;

        return pending >= minForceSettleOrders || block.number >= e.openedAtBlock + absoluteMaxDelay;
    }

    function forceSettleDue() external view returns (bool) {
        return _forceSettleDue(oldestUnsettledEpoch);
    }

    
    function _netOfSlowFee(
        uint256 gross,
        uint24 slowFee
    ) private pure returns (uint256) {
        return gross - FullMath.mulDiv(gross, slowFee, FEE_DENOMINATOR);
    }

    function _epochAcceptingOrders() private returns (uint32 epoch) {
        epoch = currentEpoch;
        if (epochOrderIds[epoch].length >= MAX_ORDERS_PER_EPOCH) {
            epoch = ++currentEpoch;
        }
        if (epochs[epoch].openedAtBlock == 0) {
            epochs[epoch].openedAtBlock = uint64(block.number);
        }
    }
function _advanceIfDrained(
        uint32 epoch
    ) private {
        if (epoch != oldestUnsettledEpoch) return;

        uint256[] storage ids = epochOrderIds[epoch];
         uint256 len = ids.length;
        if (len == 0) return;

        for (uint256 i; i < len; ++i) {
            Order storage o = orders[ids[i]];
            if (o.status == OrderStatus.PENDING && o.amountInRemaining > 0 && !_isExpired(o)) {
                return; // still fillable
            }
        }

        oldestUnsettledEpoch = epoch + 1;
        if (currentEpoch < oldestUnsettledEpoch) currentEpoch = oldestUnsettledEpoch;
    }

    
    function _checkAndBookWarehouse(
        bool zeroForOne,
        uint128 amountIn
    ) private {
        if (zeroForOne) {
            uint256 next = uint256(warehoused0) + amountIn;
            if (next > maxWarehouse0) revert KesselErrors.WarehouseCapExceeded();
            warehoused0 = uint128(next);
        } else {
            uint256 next = uint256(warehoused1) + amountIn;
            if (next > maxWarehouse1) revert KesselErrors.WarehouseCapExceeded();
            warehoused1 = uint128(next);
        }
    }

    
    function setFees(
        uint24 newFBase,
        uint24 newFSlow
    ) external onlyGovernance {
        if (newFBase < F_BASE_MIN || newFBase > F_BASE_MAX) revert KesselErrors.ParameterOutOfBounds();
        if (newFSlow >= newFBase) revert KesselErrors.SlowFeeBoundViolated();

        emit KesselEvents.ParameterUpdated("fBase", fBase, newFBase);
        emit KesselEvents.ParameterUpdated("fSlow", fSlow, newFSlow);
        fBase = newFBase;
        fSlow = newFSlow;
    }

    function setK(
        uint256 newK
    ) external onlyGovernance {
        if (newK < K_MIN || newK > K_MAX) revert KesselErrors.ParameterOutOfBounds();
        emit KesselEvents.ParameterUpdated("k", k, newK);
        k = newK;
    }

    function setKGas(
        uint256 newKGas
    ) external onlyGovernance {
        if (newKGas < K_GAS_MIN || newKGas > K_GAS_MAX) revert KesselErrors.ParameterOutOfBounds();
        emit KesselEvents.ParameterUpdated("kGas", kGas, newKGas);
        kGas = newKGas;
    }

    function setCadence(
        uint32 newMinSettleAge,
        uint32 newMaxDelay,
        uint32 newAbsoluteMaxDelay,
        uint32 newMinOrders
    ) external onlyGovernance {
        if (newMinSettleAge < MIN_SETTLE_AGE_MIN || newMinSettleAge > MIN_SETTLE_AGE_MAX) {
            revert KesselErrors.ParameterOutOfBounds();
        }
        if (newMaxDelay < MAX_DELAY_MIN || newMaxDelay > MAX_DELAY_MAX) revert KesselErrors.ParameterOutOfBounds();
        if (newMaxDelay <= newMinSettleAge) revert KesselErrors.ParameterOutOfBounds();
        if (newAbsoluteMaxDelay < newMaxDelay || newAbsoluteMaxDelay > MAX_DELAY_MAX) {
            revert KesselErrors.ParameterOutOfBounds();
        }
        if (newMinOrders == 0) revert KesselErrors.ParameterOutOfBounds();

        emit KesselEvents.ParameterUpdated("minSettleAge", minSettleAge, newMinSettleAge);
        emit KesselEvents.ParameterUpdated("maxDelay", maxDelay, newMaxDelay);
        emit KesselEvents.ParameterUpdated("absoluteMaxDelay", absoluteMaxDelay, newAbsoluteMaxDelay);
        emit KesselEvents.ParameterUpdated("minForceSettleOrders", minForceSettleOrders, newMinOrders);

        minSettleAge = newMinSettleAge;
        maxDelay = newMaxDelay;
        absoluteMaxDelay = newAbsoluteMaxDelay;
        minForceSettleOrders = newMinOrders;
    }

    function setWarehouseCaps(
        uint128 cap0,
        uint128 cap1
    ) external onlyGovernance {
        emit KesselEvents.ParameterUpdated("maxWarehouse0", maxWarehouse0, cap0);
        emit KesselEvents.ParameterUpdated("maxWarehouse1", maxWarehouse1, cap1);
        maxWarehouse0 = cap0;
        maxWarehouse1 = cap1;
    }

    function setMinOrderSize(
        uint128 min0,
        uint128 min1
    ) external onlyGovernance {
        emit KesselEvents.ParameterUpdated("minOrderSize0", minOrderSize0, min0);
        emit KesselEvents.ParameterUpdated("minOrderSize1", minOrderSize1, min1);
        minOrderSize0 = min0;
        minOrderSize1 = min1;
    }

    function setResidualCapBps(
        uint16 bps
    ) external onlyGovernance {
        if (bps < RESIDUAL_CAP_BPS_MIN || bps > RESIDUAL_CAP_BPS_MAX) revert KesselErrors.ParameterOutOfBounds();
        emit KesselEvents.ParameterUpdated("residualCapBps", residualCapBps, bps);
        residualCapBps = bps;
    }

    function setExpiryForfeitBps(
        uint16 bps
    ) external onlyGovernance {
        if (bps > EXPIRY_FORFEIT_BPS_MAX) revert KesselErrors.ParameterOutOfBounds();
        emit KesselEvents.ParameterUpdated("expiryForfeitBps", expiryForfeitBps, bps);
        expiryForfeitBps = bps;
    }

    function setGovernance(
        address newGovernance
    ) external onlyGovernance {
        if (newGovernance == address(0)) revert KesselErrors.ParameterOutOfBounds();
        emit KesselEvents.ParameterUpdated("governance", uint256(uint160(governance)), uint256(uint160(newGovernance)));
        governance = newGovernance;
    }

    function setPaused(
        bool p
    ) external onlyGovernance {
        paused = p;
        emit KesselEvents.PausedSet(p);
    }

    function quoteFill()
        external
        view
        returns (bool ok, Currency outCurrency, uint256 minDeliver, Currency inCurrency, uint256 payout)
    {
        if (paused || _settling) return (false, currency0, 0, currency1, 0);

        uint32 epoch = oldestUnsettledEpoch;
        if (!_piggybackDue(epoch)) return (false, currency0, 0, currency1, 0);

        Cand[] memory c = _loadCandidates(epoch);
        if (c.length == 0) return (false, currency0, 0, currency1, 0);

        (Clearing.Solution memory sol,,, bool converged) = _solveEligibleSet(c);
        if (!converged || !sol.feasible || sol.residualIn == 0) return (false, currency0, 0, currency1, 0);

        outCurrency = sol.zeroForOne ? currency1 : currency0;
        inCurrency = sol.zeroForOne ? currency0 : currency1;
        return (true, outCurrency, sol.residualOut, inCurrency, sol.residualIn);
    }

    function orderCount(
        uint32 epoch
    ) external view returns (uint256) {
        return epochOrderIds[epoch].length;
    }

    function orderIdAt(
        uint32 epoch,
        uint256 index
    ) external view returns (uint256) {
        return epochOrderIds[epoch][index];
    }

    function custodyOf(
        Currency currency
    ) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }
}
