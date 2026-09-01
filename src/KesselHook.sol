// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@uniswap/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@uniswap/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityMath} from "@uniswap/v4-core/src/libraries/LiquidityMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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
import {Clearing} from "./settle/Clearing.sol";

/// @title Kessel — a two-lane execution hook on one shared liquidity curve
///
/// @notice Kessel offers two execution contracts on a single Uniswap v4 pool
/// and lets the trader pick per swap (PRD §2.1):
///
///  * **Fast Lane** — an ordinary synchronous swap whose LP fee rises with the
///    trader's revealed urgency, `f_base + k * priorityFeePerGas`. The premium
///    is recaptured to LPs rather than left to the sequencer.
///  * **Slow Lane** — the hook escrows the input and issues a non-transferable
///    claim; the order clears later, in a batch, at one uniform price computed
///    at *settlement* time.
///
/// The mechanism prices **immediacy**, not toxicity. It does not claim to
/// remove adverse selection or LVR — see PRD §1.3 and §7.5 for the exact scope
/// of every claim, and do not restate them more strongly than they are written.
///
/// ## Where each design decision lives
///
/// | DD | Subject | Home |
/// |----|---------|------|
/// | DD-1  | default lane            | `LaneCodec.decode` |
/// | DD-2, DD-4 | urgency tax, `k`   | `FastLaneFee` |
/// | DD-3  | passive subsidy         | `fSlow` is an independent parameter |
/// | DD-5  | clearing price P        | `Clearing.solve` |
/// | DD-6, DD-7, DD-13 | cadence, trigger, guards | `_settlementDue`, `forceSettle` |
/// | DD-8  | `afterSwap` permission  | `getHookPermissions` |
/// | DD-9  | non-cancellable         | absence of any cancel entry point |
/// | DD-10 | recapture distribution  | fee override (fast) + `_recapture` (slow) |
/// | DD-11 | failed `minOut`         | `_solveEligibleSet` |
/// | DD-12 | settlement MEV          | settlement runs in `afterSwap` only |
/// | DD-14 | native ETH              | `_openSlowOrder` |
/// | DD-15 | claim + redemption      | `Order` struct, `redeem` |
///
/// ## Immutability
///
/// The permission bitmap is encoded in this contract's address, so it is frozen
/// (DD-8). Settlement math cannot be patched. Every tunable is a bounded
/// parameter with deploy-fixed bounds, and the guardian pause only ever lets
/// funds *out* — it can never strand them (PRD §11 case 12).
contract KesselHook is BaseHook, IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000; // v4 fee units
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ------------------------------------------------------------------
    // Deploy-fixed bounds. The hook is immutable, so these can never move;
    // only the parameters inside them can (PRD §5.4 immutability constraint).
    // ------------------------------------------------------------------

    uint24 internal constant F_BASE_MIN = 100; // 1 bp
    uint24 internal constant F_BASE_MAX = 100_000; // 10%
    /// @dev Hard ceiling on the total Fast-Lane fee, well under v4's
    /// `MAX_LP_FEE`. Caps the urgency tax without breaking I12.
    uint24 internal constant MAX_FAST_FEE = 50_000; // 5%
    uint256 internal constant K_MIN = 0;
    uint256 internal constant K_MAX = 100_000; // 1 gwei => +10%

    /// @dev Bound on `kGas`, the size-denominated tax multiplier (DD-4 as
    /// amended). Units are gas, so `kGas * priorityFeePerGas` is an amount of
    /// wei: at the ceiling, one gwei of priority costs 0.01 ETH of tax. Well
    /// above any plausible calibration, and the fee cap binds long before it
    /// on any ordinary trade size.
    uint256 internal constant K_GAS_MIN = 0;
    uint256 internal constant K_GAS_MAX = 10_000_000;

    /// @dev `gasTokenSide` values. Fixed at construction because the choice of
    /// tax mode must not be able to move under a live pool.
    uint8 internal constant GAS_TOKEN_NONE = 0;
    uint8 internal constant GAS_TOKEN_CURRENCY0 = 1;
    uint8 internal constant GAS_TOKEN_CURRENCY1 = 2;

    uint32 internal constant MIN_SETTLE_AGE_MIN = 1;
    uint32 internal constant MIN_SETTLE_AGE_MAX = 300;
    uint32 internal constant MAX_DELAY_MIN = 2;
    uint32 internal constant MAX_DELAY_MAX = 100_000;
    uint32 internal constant MAX_EXPIRY_EPOCHS = 256;
    /// @dev Deploy-fixed ceiling on the block-age half of the expiry test. Keeps
    /// governance from stretching the refund right out of reach by raising
    /// `maxDelay` -- funds stay reachable within a bound nobody can move.
    uint32 internal constant EXPIRY_BLOCK_FLOOR_MAX = 7_200;
    uint16 internal constant EXPIRY_FORFEIT_BPS_MAX = 100; // 1%

    /// @dev Bounds settlement gas so a piggybacking Fast-Lane trader cannot be
    /// made to pay unboundedly (DD-6). An epoch that fills opens a new one, so
    /// this caps work per settlement without ever refusing an order.
    uint256 internal constant MAX_ORDERS_PER_EPOCH = 32;
    /// @dev Eligibility rounds for the DD-11 shrinking-set iteration. The set
    /// shrinks monotonically, so this only bounds work, never correctness.
    uint256 internal constant MAX_CLEARING_ROUNDS = 4;
    /// @dev Consecutive constant-liquidity ranges one settlement may walk when
    /// solving a batch (gap-4 amendment to DD-5). Bounds gas, never
    /// correctness: stopping early yields a smaller fill and the remainder
    /// rolls, exactly as the single-range solver always did.
    uint256 internal constant MAX_CLEARING_RANGES = 4;

    /// @dev DD-5 residual cap, as a fraction of the analytic break-even. See
    /// `_residualCap` for the derivation of the break-even itself.
    ///
    /// `RESIDUAL_CAP_BPS_MAX = 10_000` is exactly break-even and is a HARD
    /// deploy-fixed ceiling: no reachable governance setting can place the cap
    /// above the point where sandwiching the settlement residual turns a
    /// profit. That is the property that makes this a closure of DD-5 rather
    /// than a tuning knob — the defence cannot be switched off.
    ///
    /// The floor stops governance from setting a cap so tight that a one-sided
    /// batch needs an unreasonable number of epochs to clear.
    uint16 internal constant RESIDUAL_CAP_BPS_MIN = 500; // 5% of break-even
    uint16 internal constant RESIDUAL_CAP_BPS_MAX = 10_000; // 100% = break-even
    /// @dev I4 tolerance. The two sides' implied prices are equal in exact
    /// arithmetic; integer division leaves at most a few wei per pot. Applied
    /// only to two-sided batches with non-dust pots — see `_assertUniformPrice`.
    uint256 internal constant I4_TOLERANCE_PPM = 100; // 0.01%
    uint256 internal constant I4_DUST_FLOOR = 1e6;

    /// @dev I8 tolerance for the post-settlement limit re-check (SR-8). The
    /// eligibility screen and the realised price are computed from different
    /// quantities — the sized residual versus the distributed pots — so they
    /// agree to within integer rounding rather than bit for bit. One part per
    /// million is several orders of magnitude above that rounding and far
    /// below any economically meaningful breach, and it is a hundred times
    /// tighter than the tolerance I4 already runs with.
    uint256 internal constant I8_TOLERANCE_PPM = 1; // 0.0001%

    // ------------------------------------------------------------------
    // Immutable pool binding
    // ------------------------------------------------------------------

    /// @dev Kessel serves exactly one pool. This is a security requirement, not
    /// a simplification: the hook's ERC-6909 custody is held per *currency*, so
    /// a hook serving two pools that share a currency could have one pool's
    /// settlement drain the other's escrow. OpenZeppelin's `BaseAsyncSwap`
    /// carries the same warning. Every callback rejects any other pool.
    PoolKey internal immutablePoolKeyStorage;
    PoolId public immutable poolId;
    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;

    /// @dev Which side of the pool, if either, is the chain's gas token — and
    /// therefore whether the Fast Lane can use the paper's size-denominated tax
    /// (DD-4 as amended) or must fall back to the rate form.
    ///
    /// Immutable on purpose. The tax mode is a protocol-visible property of the
    /// deployment, and a governance switch that could flip it under a live pool
    /// would let the fee schedule change shape without changing a parameter
    /// anyone is watching.
    uint8 public immutable gasTokenSide;

    // ------------------------------------------------------------------
    // Bounded governance parameters
    // ------------------------------------------------------------------

    address public governance;
    bool public paused;

    uint24 public fBase = 3_000; // 0.30%
    uint24 public fSlow = 500; // 0.05% — I10: strictly below fBase
    uint256 public k = 500; // DD-4 default (rate form): 1 gwei => +5 bp
    /// @dev DD-4 as amended: the size-denominated multiplier, in gas units.
    /// Used only when `gasTokenSide != GAS_TOKEN_NONE`. Default is the rough
    /// gas cost of a swap, which makes the tax comparable to the priority bid
    /// the trader is already paying for the same ordering.
    uint256 public kGas = 150_000;

    uint32 public minSettleAge = 2; // blocks (DD-6, guards I6)
    uint32 public maxDelay = 300; // blocks (I11)
    uint32 public absoluteMaxDelay = 3_000; // blocks (DD-13 liveness escape)
    uint32 public minForceSettleOrders = 2; // DD-13 anti-grief size floor
    uint16 public expiryForfeitBps = 10; // 0.10% (DD-9)

    /// @dev DD-5 (ratified 2026-09-01): how much of the analytic break-even
    /// residual a single settlement may push through the curve. Default 50%,
    /// i.e. half the residual at which sandwiching the settlement would start
    /// to pay, leaving a 2x margin against the model's own error.
    uint16 public residualCapBps = 5_000;

    /// @dev I9: warehoused exposure cap, per direction, denominated in that
    /// direction's *input token units*. A common numeraire would need a price,
    /// and PRD §9 forbids an oracle (reconnaissance finding C).
    uint128 public maxWarehouse0 = type(uint128).max;
    uint128 public maxWarehouse1 = type(uint128).max;

    /// @dev SR-12: floor on a single Slow-Lane order, per direction, in that
    /// direction's own input-token units — same reasoning as the warehouse
    /// caps above, and for the same reason it cannot be one number.
    ///
    /// Defaults to zero, i.e. off, exactly as `maxWarehouse*` defaults to its
    /// own no-op. There is no unit-independent default worth shipping: a floor
    /// meaningful on an 18-decimal pool is nonsense on a 6-decimal one, so this
    /// is a value the deployer must set with the pair in front of them.
    ///
    /// The floor applies at INTAKE ONLY. A partial fill can leave an order's
    /// remainder below it, and that remainder must keep rolling and stay
    /// redeemable — applying the floor to rolling would strand exactly the
    /// orders the protocol has already taken custody of.
    uint128 public minOrderSize0;
    uint128 public minOrderSize1;

    // ------------------------------------------------------------------
    // Order book and epoch state
    // ------------------------------------------------------------------

    uint256 public nextOrderId = 1;
    mapping(uint256 orderId => Order) public orders;

    /// @dev Epoch currently accepting orders.
    uint32 public currentEpoch = 1;
    /// @dev Oldest epoch not yet fully settled. Settlement always works on this
    /// one, so batches clear in submission order.
    uint32 public oldestUnsettledEpoch = 1;

    mapping(uint32 epoch => Epoch) public epochs;
    mapping(uint32 epoch => uint256[] orderIds) internal epochOrderIds;

    /// @dev Aggregate unsettled Slow-Lane input per direction (I9).
    uint128 public warehoused0;
    uint128 public warehoused1;

    /// @dev PRD §6.2 empty-range fallback: fees that could not be donated
    /// because no liquidity was in range. Claimable to LPs later; never kept.
    uint256 public lpClaimable0;
    uint256 public lpClaimable1;

    /// @dev "No settlement may begin right now." Held for the duration of a
    /// settlement, and also for the duration of a redemption payout.
    ///
    /// Settlement performs a swap on the pool it is settling (PRD §11 case 8),
    /// and v4 permits nested swaps, so holding it across settlement is what
    /// makes double-settlement structurally impossible rather than merely
    /// unlikely (I3).
    ///
    /// Holding it across `_payoutOrder` closes SR-6. The redemption path makes
    /// an outbound transfer to the trader, and `poolManager.swap` is
    /// `onlyWhenUnlocked` rather than `onlyByTheUnlocker` — so a trader that
    /// receives control during that transfer may run a Fast-Lane swap inside
    /// the hook's own still-open `unlock`, and that swap's `afterSwap` would
    /// otherwise settle a batch underneath an order that is mid-payout.
    bool private _settling;

    enum UnlockAction {
        SETTLE,
        REDEEM,
        SWEEP,
        SETTLE_WITH_FILL
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert KesselErrors.NotGovernance();
        _;
    }

    /// @param _poolManager The v4 singleton.
    /// @param _currency0 Lower-sorted currency of the served pool.
    /// @param _currency1 Higher-sorted currency of the served pool.
    /// @param _tickSpacing Tick spacing of the served pool.
    /// @param _governance Initial parameter authority.
    /// @param _gasTokenSide Which currency is the chain's gas token: 0 neither,
    /// 1 currency0, 2 currency1. Selects the Fast-Lane tax mode (DD-4 as
    /// amended) and cannot be changed afterwards.
    ///
    /// @dev The pool key is fixed here rather than learned at initialize time
    /// because the hook has no `beforeInitialize` permission — the bitmap is
    /// frozen by DD-8 and adding one would change this contract's address. The
    /// fee field is always `DYNAMIC_FEE_FLAG` (PRD §8.1).
    ///
    /// `_gasTokenSide` is asserted by the deployer rather than derived, because
    /// the gas token is not always the native currency: on a pool quoted in
    /// WETH the ETH-equivalent side is an ERC-20 that this contract cannot
    /// recognise. Declaring a side that is *not* gas-token-equivalent
    /// mis-denominates the tax — it does not break custody or any invariant,
    /// but it silently mis-prices the Fast Lane, so it is checked at deploy
    /// time where it can still be fixed. Passing 0 is always safe and selects
    /// the rate form.
    constructor(
        IPoolManager _poolManager,
        Currency _currency0,
        Currency _currency1,
        int24 _tickSpacing,
        address _governance,
        uint8 _gasTokenSide
    ) BaseHook(_poolManager) {
        // Same reasoning as `setGovernance`: an immutable hook deployed with no
        // governance can never have a parameter changed again.
        if (_governance == address(0)) revert KesselErrors.ParameterOutOfBounds();
        if (_gasTokenSide > GAS_TOKEN_CURRENCY1) revert KesselErrors.ParameterOutOfBounds();

        // The native currency is address(0) and is always currency0 when
        // present, so declaring currency1 as the gas token while currency0 is
        // native is contradictory on its face and is refused. Every other
        // combination is a deployer assertion this contract cannot check.
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

    /// @notice The pool this hook serves.
    function poolKey() public view returns (PoolKey memory) {
        return immutablePoolKeyStorage;
    }

    // ==================================================================
    // Hook permissions — FROZEN (DD-8, PRD §8.1)
    // ==================================================================

    /// @inheritdoc BaseHook
    /// @dev v4 encodes these bits in the contract address, so changing this
    /// function changes the address and invalidates any mined one.
    ///
    /// `afterSwap` is true **for settlement, not for fee routing**: it is the
    /// only callback that runs after the triggering swap's own price impact has
    /// been booked, which is exactly the condition PRD §7.6(b) demands before
    /// piggyback settlement is safe. The Fast-Lane premium needs no post-swap
    /// step at all — the dynamic fee override *is* the LP fee, and v4 credits
    /// it to in-range liquidity itself.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // lane routing, fee override, Slow-Lane intake
            afterSwap: true, // piggyback settlement only (DD-8)
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // async Slow-Lane intake
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ==================================================================
    // beforeSwap — lane routing (PRD §8.3)
    // ==================================================================

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
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

            // The premium reaches LPs through this override and nothing else:
            // v4 credits the whole LP fee to in-range liquidity via
            // feeGrowthGlobal inside Pool.swap (I5, I7, DD-10). No hook-held
            // intermediary ever touches it.
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                feeCharged | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        return _openSlowOrder(key, params, trader, minOut, expiryEpochs);
    }

    /// @dev The Fast-Lane fee for this swap, in whichever tax mode this
    /// deployment was fixed to (DD-4 as amended).
    ///
    /// The size-denominated mode falls back to the rate form whenever the size
    /// cannot be established — a degenerate or out-of-range price. Falling back
    /// is the safe direction: the rate form never under-charges relative to a
    /// size it could not compute, whereas treating an unknown size as large
    /// would hand out a cheap swap.
    ///
    /// I12 holds in both branches and the branch does not depend on
    /// `priorityFee`, so no monotonicity break can occur between them.
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

    /// @dev Slow-Lane intake: escrow the input, issue a claim, execute nothing.
    ///
    /// The async delta accounting is exactly as PRD §3.2 specifies, and the
    /// specification is worth restating because getting it wrong is the
    /// highest-severity failure mode in the whole design (PRD §12):
    ///
    ///  * the returned `BeforeSwapDelta` offsets `params.amountSpecified` in the
    ///    **specified** currency, so v4 swaps zero on the curve;
    ///  * the **unspecified** delta is zero — no output is owed this block;
    ///  * `take(..., claims: true)` mints the hook ERC-6909 claims against its
    ///    credit, converting the credit into custody inside the singleton;
    ///  * the trader's inbound transfer settles the router's matching debt, so
    ///    the hook's own deltas are flat before it returns control (I1).
    ///
    /// A `CurrencyNotSettled` revert here means the mint-and-settle path is
    /// broken. Do not "fix" it by adjusting the returned delta.
    function _openSlowOrder(
        PoolKey calldata key,
        SwapParams calldata params,
        address trader,
        uint128 minOut,
        uint32 expiryEpochs
    ) private returns (bytes4, BeforeSwapDelta, uint24) {
        if (paused) revert KesselErrors.Paused();

        // Intake is closed while a settlement or a redemption payout is in
        // flight, and this is load-bearing rather than defensive.
        //
        // `_executeResidualViaFiller` hands control to an untrusted contract
        // with the settlement half-finished: the epoch is closed and the
        // residual executed, but the fills, epoch record, recapture and roll
        // have not happened. `_settling` already stops that contract from
        // reentering settlement, and v4's nested-`unlock` prohibition stops
        // `redeem`, `forceSettle` and `sweepRecapture`. Intake is the one
        // mutating path neither of those covers, because `poolManager.swap` is
        // `onlyWhenUnlocked` rather than `onlyByTheUnlocker` — the same
        // asymmetry SR-6 turned on — so a filler may call it directly, land
        // here, and write `warehoused*`, `orders`, `epochOrderIds` and
        // `currentEpoch` underneath a settlement still reading them.
        //
        // No concrete corruption was found by construction, and that is
        // precisely why this is a check rather than an argument in a comment:
        // SR-4 is the standing reminder that "unreachable by argument" is not
        // the same as unreachable, and this contract cannot be patched.
        //
        // Nothing legitimate is refused. The hook's own residual swap does not
        // reach `beforeSwap` at all — v4 skips a hook's callbacks when the hook
        // is the caller — so the only way to arrive here with `_settling` set
        // is from inside someone else's reentrancy.
        if (_settling) revert KesselErrors.SettlementInProgress();

        // v4's async pattern is exact-input only (PRD §3.2); exact-output Slow
        // orders are out of scope (§17).
        if (params.amountSpecified >= 0) revert KesselErrors.SlowLaneRequiresExactInput();
        if (minOut == 0) revert KesselErrors.MinOutRequired();
        if (expiryEpochs == 0 || expiryEpochs > MAX_EXPIRY_EPOCHS) revert KesselErrors.ExpiryOutOfRange();

        bool zeroForOne = params.zeroForOne;
        Currency specified = zeroForOne ? key.currency0 : key.currency1;

        // DD-14: native ETH cannot be custodied as an ERC-6909 claim the way an
        // ERC-20 can. Refused before any custody is taken, so nothing can be
        // stranded by this path (PRD §11 case 14).
        if (specified.isAddressZero()) revert KesselErrors.NativeEthNotSupportedInSlowLane();

        uint256 amountIn256 = uint256(-params.amountSpecified);
        if (amountIn256 > type(uint128).max) revert KesselErrors.AmountTooLarge();
        uint128 amountIn = uint128(amountIn256);

        // SR-12. The Slow Lane's per-epoch work cap is a fixed number of
        // ORDERS, not a quantity of value, so the cheapest way to consume it is
        // with orders that carry no value at all: 32 dust orders whose limit
        // price the market can never reach cost a wei each, are dropped by the
        // eligibility screen every settlement, and roll to the head of the next
        // batch for as long as their expiry allows — displacing real orders
        // into later epochs and billing the repricing to whichever Fast-Lane
        // trader carries it.
        //
        // A size floor is the right lever because it prices the attack in the
        // attacker's own locked capital, which is the one cost that scales with
        // how long they keep it up, and it is taxed again by the expiry forfeit
        // on the way out. The alternatives — charging repeatedly-dropped
        // orders, or capping how many times an order may roll — both reopen
        // DD-9's free-option analysis and DD-11's rolling policy, which is a
        // large bill for a throughput grief.
        //
        // It also only makes explicit a floor the fill arithmetic already
        // imposes: `_computeFills` drops any order whose filled amount rounds
        // to zero, so a sufficiently small order was never fillable anyway.
        uint128 floorSize = zeroForOne ? minOrderSize0 : minOrderSize1;
        if (amountIn < floorSize) revert KesselErrors.OrderBelowMinimum();

        _checkAndBookWarehouse(zeroForOne, amountIn);

        // Take custody inside the singleton (PRD §5.3, §3.2).
        specified.take(poolManager, address(this), amountIn256, true);

        // The id is emitted by `_recordOrder`; nothing on this path needs it.
        _recordOrder(trader, zeroForOne, amountIn, minOut, expiryEpochs);

        // Consume the full specified amount; owe nothing in the unspecified
        // currency. No fee override: the curve trades zero, so there is no fee
        // to charge here. `f_slow` is charged at settlement instead.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(amountIn)), 0), 0);
    }

    /// @dev Split out of `_openSlowOrder` purely to keep the intake path within
    /// the EVM stack limit under the non-`via_ir` dev profile.
    function _recordOrder(
        address trader,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        uint32 expiryEpochs
    ) private returns (uint256 orderId) {
        // Convert the trader's minOut into a limit price, expressed as
        // currency1-per-currency0 in BOTH directions so one batch price can be
        // compared against every order (DD-11). This is what makes I8 exact.
        uint256 limit = zeroForOne
            ? FullMath.mulDiv(minOut, Q96, amountIn)  // floor on price
            : FullMath.mulDiv(amountIn, Q96, minOut); // ceiling on price
        if (limit > type(uint160).max) revert KesselErrors.AmountTooLarge();

        uint32 epoch = _epochAcceptingOrders();
        uint32 expiry = epoch + expiryEpochs;
        orderId = nextOrderId++;

        // SR-10: the block-age half of the expiry test, stamped now rather than
        // recomputed later from the live `maxDelay`. See `Order.expiryBlock`.
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

    // ==================================================================
    // afterSwap — piggyback settlement (DD-6, DD-8, DD-12)
    // ==================================================================

    /// @dev Settlement is attempted here and **only** here on the piggyback
    /// path, because `afterSwap` runs after the triggering swap's own price
    /// impact is booked. That is what closes PRD §7.6(b): the triggering trader
    /// cannot improve their own execution by choosing when the batch clears.
    ///
    /// Two further restrictions complete the argument:
    ///  * only FAST swaps trigger settlement, so a Slow-Lane submitter can
    ///    never select the moment their own order clears;
    ///  * `minSettleAge` forbids submit-and-settle inside one block, which
    ///    would otherwise approximate submission-time pricing and erode I6.
    ///
    /// This must never revert the triggering swap. Every gate is checked before
    /// anything is executed, and an infeasible batch is a no-op (PRD §11 case 1).
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert KesselErrors.UnknownPool();

        (Lane lane,,,) = LaneCodec.decode(hookData, address(0));
        if (lane != Lane.FAST) return (IHooks.afterSwap.selector, 0);
        if (paused || _settling) return (IHooks.afterSwap.selector, 0);

        uint32 epoch = oldestUnsettledEpoch;
        if (_piggybackDue(epoch)) {
            // Settle through an external self-call so that a settlement which
            // cannot complete safely unwinds by itself and leaves the carrying
            // swap untouched.
            //
            // This is what lets settlement use `revert` as its refusal
            // mechanism. A Fast-Lane trader volunteered gas to carry the batch;
            // they did not volunteer to have their swap fail because someone
            // else's batch was degenerate. Note the call is still inside the
            // same unlock, so the settlement core keeps using a direct
            // `poolManager.swap` for the residual and never nests an `unlock`
            // (PRD §8.3).
            try this.settleFromCallback(epoch) {}
            catch {
                emit KesselEvents.SettlementSkipped(epoch);
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    /// @notice Settlement entry point used only by this contract's own
    /// `afterSwap`, so that a reverting settlement is isolated from the swap
    /// that triggered it.
    /// @dev Not externally callable: the caller check makes it equivalent to a
    /// private function that happens to have its own revert boundary.
    function settleFromCallback(
        uint32 epoch
    ) external {
        if (msg.sender != address(this)) revert KesselErrors.NotPoolManager();
        _settleEpoch(epoch);
    }

    // ==================================================================
    // Forced settlement (DD-7, DD-13, I11)
    // ==================================================================

    /// @notice Permissionless safety valve. Callable by anyone once the batch
    /// has aged past its gate.
    ///
    /// @dev No reimbursement is paid, to anyone, ever. PRD §6.3 *permits* a
    /// capped reimbursement from `f_slow`; that permission is declined so that
    /// I7 holds by construction rather than by a bound that must be audited on
    /// an immutable contract (DD-7). The expected caller is a Slow-Lane trader
    /// in the stuck batch, already motivated by their own fill.
    ///
    /// This path enters through its OWN `unlock` — it is not inside one — which
    /// is the other half of PRD §8.3's two-path rule.
    function forceSettle() external {
        if (paused) revert KesselErrors.Paused();

        uint32 epoch = oldestUnsettledEpoch;
        if (!_forceSettleDue(epoch)) revert KesselErrors.SettlementNotDue();

        poolManager.unlock(abi.encode(UnlockAction.SETTLE, epoch, uint256(0), uint256(0)));
    }

    /// @notice Settle the oldest unsettled batch against tokens the caller has
    /// already delivered, taking the better of that delivery and the curve
    /// (Shape B).
    ///
    /// @dev **The caller states the delivery and approves this contract to pull
    /// it.** There is no callback. The hook pulls exactly `delivered` of the
    /// output currency from `msg.sender` straight into the singleton, refuses
    /// anything below what the curve would have paid, completes every state
    /// write, and pays the caller the batch's input *last*.
    ///
    /// That ordering is the whole point, and it is a deliberate reversal of the
    /// obvious design. Paying the filler first and calling back into it would
    /// be more convenient — the filler could source the output using the very
    /// input it is being paid — but it puts an untrusted call in the middle of
    /// a half-finished settlement, with the epoch closed and the residual
    /// executed but the fills, epoch record, recapture and roll still pending.
    /// Pulling removes that window rather than guarding it: a `transferFrom`
    /// hands control to the *token*, not to the filler.
    ///
    /// Nothing is lost by it. A filler with inventory approves and is pulled
    /// from; a filler without one wraps this call in its own flash loan from
    /// anywhere else, is pulled from, is paid, and repays. The atomicity moves
    /// outside Kessel instead of being manufactured inside it.
    ///
    /// SR-9. This used to be a *deliver-first* interface: transfer the tokens
    /// in, then call, and the hook took `balanceOfSelf()` to be the delivery.
    /// Two things were wrong with that, and they composed.
    ///
    ///  * `balanceOfSelf()` is unattributed. It is whatever anyone has ever
    ///    sent this contract, so a filler could satisfy the curve floor out of
    ///    someone else's tokens and be paid the batch's input for free.
    ///  * A settlement that turned out to be a no-op — every order dropped for
    ///    limit ineligibility, an infeasible pool, a candidate set that emptied
    ///    — returned *without reverting*, so the delivery was never banked,
    ///    never refunded, and simply stayed on the contract as the next
    ///    filler's free capital. An attacker could force that state by moving
    ///    the price ahead of an honest filler's transaction and then collect.
    ///
    /// Pulling a declared amount makes attribution exact, and the `filled`
    /// check below turns a no-op into a revert that returns the delivery.
    ///
    /// @param delivered Exact amount of the output currency to pull from the
    /// caller. Read `quoteFill()` for the currency and the floor; anything at
    /// or above the floor is accepted, but see `_assertLimitsHeld` — a delivery
    /// so far above it that the batch's other side is pushed through its own
    /// limit price is refused rather than filled.
    ///
    /// Permissionless, and the caller pays its own gas with no reimbursement,
    /// for the same reason `forceSettle` has none (DD-7).
    ///
    /// Gated on the piggyback clock rather than the forced one. A filler is not
    /// a grief vector the way repeated tiny forced settlements are — it fronts
    /// capital to deliver a strictly better price than the curve — so making it
    /// wait for `maxDelay` would only withhold the improvement. `minSettleAge`
    /// still applies, so this cannot approximate submission-time pricing and I6
    /// is untouched.
    ///
    /// Like `forceSettle`, this opens its OWN `unlock` (PRD §8.3).
    function settleWithFill(
        uint256 delivered
    ) external {
        if (paused) revert KesselErrors.Paused();

        // Restricted to ERC-20 pools. A native `take` pays the recipient with a
        // bare `call`, and the payout leg here is to a caller-controlled
        // address; native pools settle against the curve as they always did.
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

    /// @inheritdoc IUnlockCallback
    function unlockCallback(
        bytes calldata data
    ) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert KesselErrors.NotPoolManager();

        // One uniform payload for every action. `SETTLE_WITH_FILL` carries the
        // filler in the slot the redemption path uses for an order id, and its
        // declared delivery in the fourth; every other action leaves both zero.
        (UnlockAction action, uint32 epoch, uint256 arg, uint256 arg2) =
            abi.decode(data, (UnlockAction, uint32, uint256, uint256));

        if (action == UnlockAction.SETTLE_WITH_FILL) {
            // A settlement that could not run is a REVERT on this path, never a
            // silent return: the caller's delivery has to come back with it
            // (SR-9). The piggyback path keeps the opposite convention on
            // purpose — there, a no-op must not take the carrying swap down.
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

    // ==================================================================
    // Settlement core — shared by both entry paths (PRD §8.3)
    // ==================================================================

    /// @dev Must be called inside an unlocked context. Both entry paths reach
    /// this same function; neither of them nests an `unlock`.
    function _settleEpoch(
        uint32 epoch
    ) private {
        _settleEpochInner(epoch, address(0), 0);
    }

    /// @dev The settlement core. `filler` is `address(0)` on the curve path,
    /// which is every path that existed before Shape B; a non-zero filler makes
    /// the residual execute against that contract instead, subject to a floor
    /// of what the curve would have paid.
    ///
    /// Everything downstream of the residual is identical either way, and
    /// deliberately so: pots, fill ratio, uniform-price assertion and payout do
    /// not know or care where the tokens came from. That is what makes the
    /// amendment small — `Clearing.fillRatio` already made solvency independent
    /// of the counterparty, so a second counterparty needs no new accounting.
    /// @return settled True when the batch reached distribution. False is a
    /// refusal, not a failure: the curve paths treat it as a no-op, and the
    /// filler path turns it into a revert so the delivery is returned (SR-9).
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

        // ---- DD-11 shrinking-set iteration -------------------------------
        (Clearing.Solution memory sol, uint256 net0, uint256 net1, bool converged) = _solveEligibleSet(c);

        // Nothing to distribute. Under-filling is safe; mis-filling is not
        // (DD-11). But an epoch that produces no fill must still be able to get
        // out of the way, because settlement only ever works on
        // `oldestUnsettledEpoch` and a batch that pins it pins the whole lane.
        if (!converged || !sol.feasible || (net0 == 0 && net1 == 0)) {
            if (net0 == 0 && net1 == 0) {
                // The shrinking-set loop priced the batch and every order was
                // dropped for limit ineligibility. That is a COMPLETE
                // settlement outcome -- a fill ratio of zero for everyone -- so
                // the epoch is finished and its orders roll (DD-11).
                //
                // Without this the lane can be frozen permanently for the price
                // of 32 orders: saturate one epoch with limits the market can
                // never reach and no later batch can ever settle. Expiry is no
                // escape, because expiry is measured in epochs and epochs stop
                // advancing too.
                _closeEpoch(epoch);
                _rollUnfilled(epoch);
            } else if (_pastLivenessEscape(epoch)) {
                // The pool itself could not be solved -- no liquidity in range,
                // or the eligibility iteration did not converge. That is
                // normally transient and worth retrying, but I11 caps how long
                // "retry later" may go on for.
                _closeEpoch(epoch);
                _rollUnfilled(epoch);
            }
            _settling = false;
            return false;
        }

        if (filler != address(0)) _assertFillerNotInBatch(c, filler);

        _executeAndDistribute(epoch, c, sol, net0, net1, filler, delivered);

        // The filler is paid LAST, after every state write this settlement
        // makes. That is checks-effects-interactions in the order it is
        // supposed to be in, and it is the reason there is no untrusted call
        // anywhere in the middle of this function: the delivery arrived before
        // `settleWithFill` was even entered.
        //
        // `_settling` is still held here, so a filler that takes control on
        // receipt finds settlement closed, intake refused, and every path that
        // needs its own `unlock` unavailable. It also finds nothing left to
        // corrupt, which is the part that matters.
        if (filler != address(0) && sol.residualIn > 0) {
            Currency inCurrency = sol.zeroForOne ? currency0 : currency1;
            inCurrency.settle(poolManager, address(this), sol.residualIn, true);
            poolManager.take(inCurrency, filler, sol.residualIn);
        }

        _settling = false;
        return true;
    }

    /// @dev Shape B self-dealing guard: a filler may not be the beneficiary of
    /// an order in the batch it is filling.
    ///
    /// This is defence in depth, not the primary defence. The primary defence
    /// is the floor: every order is paid from a pot that is at least what the
    /// curve would have produced, so a self-dealing filler cannot pay itself
    /// less than it would have received by letting the settlement run normally.
    /// The guard exists because that argument is about *prices*, and an
    /// immutable contract should not rest a whole class of abuse on a pricing
    /// argument when an identity check costs one pass over 32 entries.
    ///
    /// Restricted to candidates still `live` after the eligibility screen
    /// (SR-11). Applied to every loaded candidate it was a cheap censorship
    /// primitive: `hookData` lets a submitter name ANY beneficiary, so one dust
    /// order naming a competitor — with a limit price the market can never
    /// reach, so it costs nothing and never fills — locked that address out of
    /// `settleWithFill` for the life of the batch, and rolled forward with it.
    /// An order that was screened out is not part of the batch being filled and
    /// has no self-dealing to guard against.
    function _assertFillerNotInBatch(
        Cand[] memory c,
        address filler
    ) private view {
        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live) continue;
            if (orders[c[i].id].trader == filler) revert KesselErrors.InvalidFiller();
        }
    }

    /// @dev Snapshot of one fillable order, held in memory for the duration of
    /// a settlement. Exists so the DD-11 iteration can re-price a shrinking set
    /// several times without re-reading storage, and so the settlement path
    /// stays within the EVM stack limit under the non-`via_ir` dev profile.
    struct Cand {
        uint256 id;
        bool zeroForOne;
        bool live;
        uint128 remaining;
        uint160 limitPriceX96;
        /// @dev Gross input filled this settlement, written by the first
        /// distribution pass and consumed by the second.
        uint128 grossFilled;
        /// @dev `grossFilled` net of `f_slow`.
        uint128 netFilled;
    }

    /// @dev Collect the epoch's still-fillable orders. Expired orders are left
    /// out: they are refundable, not fillable.
    function _loadCandidates(
        uint32 epoch
    ) private view returns (Cand[] memory out) {
        uint256[] storage ids = epochOrderIds[epoch];
        uint256 len = ids.length;

        Cand[] memory buf = new Cand[](len);
        uint256 n;
        for (uint256 i; i < len; ++i) {
            // Bound the work a single settlement can be made to do. Rolling can
            // grow an epoch past the submission cap, so the cap is enforced
            // here as well as at intake (DD-6).
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

    /// @dev Iterate: price the candidate set, drop orders whose limit the price
    /// does not meet, reprice. The set only ever shrinks, so this terminates.
    ///
    /// Recomputing after exclusion is not an optimisation — it is required for
    /// solvency. Filling survivors at a price computed over the original set is
    /// not self-funding, and the error is asymmetric: dropping a currency0
    /// seller leaves a harmless surplus, but dropping a currency1 seller leaves
    /// a **deficit**. See DD-11 for why the PRD's recommended refund-on-
    /// violation policy is unsound rather than merely simpler.
    function _solveEligibleSet(
        Cand[] memory c
    ) private view returns (Clearing.Solution memory sol, uint256 net0, uint256 net1, bool converged) {
        for (uint256 round; round < MAX_CLEARING_ROUNDS; ++round) {
            (net0, net1) = _aggregateNet(c);
            if (net0 == 0 && net1 == 0) return (sol, 0, 0, true);

            sol = _solveMultiRange(net0, net1);
            if (!sol.feasible) return (sol, net0, net1, false);

            if (_dropIneligible(c, sol.priceX96) == 0) return (sol, net0, net1, true);
        }

        // Round budget exhausted without a self-consistent set.
        return (sol, net0, net1, false);
    }

    /// @dev Solve the batch across up to `MAX_CLEARING_RANGES` consecutive
    /// constant-liquidity ranges (gap-4 amendment to DD-5).
    ///
    /// `Clearing.solve` is exact only inside one range, because the closed form
    /// assumes constant `L`. Previously that meant a batch big enough to reach
    /// an initialised tick was clamped to the boundary and partially filled,
    /// with the remainder rolling to the next epoch — so a large order could
    /// take several settlements to complete for no reason other than the
    /// solver's own horizon.
    ///
    /// This walks instead. Each iteration calls `solve` with that range's own
    /// liquidity and whatever of the batch is still unfilled, then crosses the
    /// boundary tick exactly as v4's own swap loop does — negating
    /// `liquidityNet` when moving down, and stepping the tick to `next - 1` in
    /// that direction. Every `solve` call therefore still sees a single
    /// constant-`L` range and stays exact.
    ///
    /// The walk only has to produce a good *target*: `Clearing.fillRatio`
    /// derives the actual fill from what the pool really did, so an imprecise
    /// prediction costs a smaller fill, never solvency (I2) and never a
    /// non-uniform price (I4). That is why an iterative approximation is
    /// admissible here at all.
    ///
    /// The residual direction cannot flip between ranges: both sides of the
    /// batch scale by the same `lambda`, so a batch that is net-selling
    /// currency0 stays net-selling currency0 however much of it is consumed.
    /// @dev DD-5's closure: the largest residual this settlement may push
    /// through the curve, in the residual's own input currency.
    ///
    /// ## The derivation
    ///
    /// `docs/DD5-SIMULATION.md` measured, against the real contracts, that
    /// sandwiching the settlement residual is profitable at every reachable
    /// `k`. Its extraction model is
    ///
    ///     extraction  =  2 * y * A * R / x^2          (in currency1)
    ///
    /// for an attacker size `A` and a residual `R`, against the attacker's own
    /// cost of `f_base` on each of two legs,
    ///
    ///     cost        =  2 * f_base * A * y / x .
    ///
    /// **`A` appears linearly on both sides and cancels.** Whether the attack
    /// pays is therefore not a question about the attacker's size, or about
    /// `k`, or about how much slack traders left in their limits — it is
    /// decided by the residual alone:
    ///
    ///     unprofitable   <=>   R  <=  f_base * x
    ///
    /// where `x` is the pool's virtual reserve of the residual's input currency.
    /// Checked against the simulation's own sweep: the analytic break-even is
    /// 0.285 ether and the measured one 0.301 ether on a 95-ether-deep pool, a
    /// 5% agreement with no fitting.
    ///
    /// ## Why this and not the other three options
    ///
    /// The simulation outlines four closures and recommends the first, a
    /// begin-of-epoch price band, as "the only one that bounds the attack
    /// independently of both trader behaviour and `k`". The cancellation above
    /// shows this one does too, and it costs materially less:
    ///
    ///  * A price band anchored at epoch open would tell a trader submitting
    ///    into a fresh epoch that their fill lands within `±delta` of the price
    ///    they can see. That is a two-sided bound known at submission, which is
    ///    precisely the hedging surface I6 exists to close. This cap carries no
    ///    submission-time information at all: it is a function of settlement-
    ///    time liquidity and price.
    ///  * A price band's failure mode is *refuse to settle*, which fights I11
    ///    and needs the `absoluteMaxDelay` escape re-argued. This cap's failure
    ///    mode is *fill less of the batch this epoch*, which is the partial-fill
    ///    path DD-11 already specifies, SR-1 already made safe, and the tick
    ///    clamp already exercises on every large batch.
    ///  * A floor on limit tightness (option 3) refuses orders traders meant to
    ///    place, and makes the defence depend on tuning against trader
    ///    behaviour rather than against pool state.
    ///
    /// The cap constrains only the *un-netted* part of a batch. Extraction on
    /// the coincidence-of-wants portion is exactly zero — the simulation
    /// measures it as such — so netting is left entirely unconstrained and the
    /// mechanism's own best case is untouched.
    ///
    /// @param sqrtPriceX96 Settlement-time price.
    /// @param liquidity Active liquidity in the range being solved.
    /// @param zeroForOne Direction of the residual.
    function _residualCap(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        bool zeroForOne
    ) private view returns (uint256) {
        if (liquidity == 0 || sqrtPriceX96 == 0) return 0; // uncapped: nothing to trade against

        // Virtual reserve of the residual's INPUT currency:
        //   currency0 (zeroForOne):  x = L / sqrtP  =  L * Q96 / sqrtPriceX96
        //   currency1 (oneForZero):  y = L * sqrtP  =  L * sqrtPriceX96 / Q96
        uint256 reserve =
            zeroForOne ? FullMath.mulDiv(liquidity, Q96, sqrtPriceX96) : FullMath.mulDiv(liquidity, sqrtPriceX96, Q96);

        // R_max = f_base * reserve * residualCapBps, with f_base in v4 fee
        // units (1e6) and the safety factor in bps (1e4).
        uint256 cap = FullMath.mulDiv(reserve, uint256(fBase) * residualCapBps, FEE_DENOMINATOR * BPS_DENOMINATOR);

        // A cap of zero would read as "uncapped" downstream. One wei is the
        // correct floor: it caps hard without ever disabling the bound.
        return cap == 0 ? 1 : cap;
    }

    function _solveMultiRange(
        uint256 net0,
        uint256 net1
    ) private view returns (Clearing.Solution memory out) {
        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        uint128 liquidity = poolManager.getLiquidity(poolId);

        uint256 rem0 = net0;
        uint256 rem1 = net1;

        // DD-5's cap is a bound on the TOTAL residual this settlement pushes
        // through the curve, so it is sized once against the depth at spot and
        // then spent down across the walk. The residual's direction follows
        // from the batch alone — the curve is sold currency0 exactly when the
        // batch is net-selling it — and cannot flip between ranges, because
        // both sides scale by the same lambda.
        uint256 capBudget;
        {
            uint256 spotX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
            bool residualZeroForOne = net1 < FullMath.mulDiv(net0, spotX96, Q96);
            capBudget = _residualCap(sqrtPriceX96, liquidity, residualZeroForOne);
        }

        for (uint256 r; r < MAX_CLEARING_RANGES; ++r) {
            (int24 lowerTick, int24 upperTick) = _activeRangeTicks(tick);

            Clearing.Solution memory seg = Clearing.solve(
                Clearing.PoolPoint({
                    sqrtPriceX96: sqrtPriceX96,
                    liquidity: liquidity,
                    lowerSqrtPriceX96: TickMath.getSqrtPriceAtTick(lowerTick),
                    upperSqrtPriceX96: TickMath.getSqrtPriceAtTick(upperTick),
                    maxResidualIn: capBudget
                }),
                rem0,
                rem1
            );

            // An infeasible range ends the walk. Anything already accumulated
            // stands: a partial answer is a valid target, and it is strictly
            // better than the single-range answer it started from.
            if (!seg.feasible) break;

            out.feasible = true;
            out.zeroForOne = seg.zeroForOne;
            out.sqrtPriceTargetX96 = seg.sqrtPriceTargetX96;
            out.residualIn += seg.residualIn;
            out.residualOut += seg.residualOut;
            out.clamped = seg.clamped;

            // Unclamped: the whole remaining batch cleared inside this range,
            // which is the terminating case and the common one.
            if (!seg.clamped) break;

            // Clamped with nothing moving means the range had no room at all.
            if (seg.residualIn == 0 || seg.residualOut == 0) break;

            // The cap is a budget for the whole walk, not for each range.
            capBudget = capBudget > seg.residualIn ? capBudget - seg.residualIn : 0;
            if (capBudget == 0) break; // DD-5 bound reached; the rest rolls.

            uint256 lambda = seg.zeroForOne
                ? Clearing.fillRatio(rem0, rem1, seg.residualIn, seg.residualOut)
                : Clearing.fillRatio(rem1, rem0, seg.residualIn, seg.residualOut);
            // `0` is an inconsistent fill and `Q96` is a complete one; neither
            // leaves a remainder for a further range to absorb.
            if (lambda == 0 || lambda >= Q96) break;

            rem0 -= FullMath.mulDiv(rem0, lambda, Q96);
            rem1 -= FullMath.mulDiv(rem1, lambda, Q96);
            if (rem0 == 0 && rem1 == 0) break;

            // Cross the boundary. An uninitialised tick — which is what a
            // bitmap-word edge is — reports a zero `liquidityNet`, so this
            // correctly leaves liquidity untouched and simply continues the
            // scan from further along. No special case is needed for it.
            int24 crossed = seg.zeroForOne ? lowerTick : upperTick;
            (, int128 liquidityNet) = poolManager.getTickLiquidity(poolId, crossed);
            if (seg.zeroForOne) liquidityNet = -liquidityNet;
            liquidity = LiquidityMath.addDelta(liquidity, liquidityNet);
            if (liquidity == 0) break; // no depth beyond this tick

            sqrtPriceX96 = seg.sqrtPriceTargetX96;
            tick = seg.zeroForOne ? crossed - 1 : crossed;
        }

        if (!out.feasible) return out;
        out.priceX96 = _predictedPrice(out, net0, net1);
        if (out.priceX96 == 0) out.feasible = false;
    }

    /// @dev The uniform price the walk predicts, taken from the residual itself.
    ///
    /// `a * b` is the average price of a move within *one* constant-liquidity
    /// range, and is simply not the average once the walk has crossed a tick.
    /// So the price has to come from the trade the walk actually sized.
    ///
    /// It comes from the residual and nothing else:
    ///
    ///   zeroForOne residual:  P = residualOut / residualIn   (pool pays c1)
    ///   oneForZero residual:  P = residualIn  / residualOut  (pool takes c1)
    ///
    /// This is exact for any number of ranges AND for any fill ratio, which is
    /// the property that matters. `Clearing.fillRatio`'s own algebra gives it
    /// directly: equalising the two sides' implied prices yields `P = Y / X`
    /// for the realised `(X, Y)`, with the batch totals cancelling out entirely.
    ///
    /// SR-8. This function previously used the *totals* identity —
    /// `P = (residualOut + N1) / N0` and `P = (N1 - residualIn) / N0` — which
    /// is the solvency relation **at a fill ratio of one**. The general
    /// relation carries lambda: `P = (Y + lambda*N1) / (lambda*N0)`. Whenever a
    /// batch was clamped (bigger than the depth the walk could absorb), lambda
    /// was dropped and the eligibility price came out wrong by a factor of
    /// roughly 1/lambda — understated for a zeroForOne residual, overstated for
    /// a oneForZero one, i.e. wrong in the unsafe direction for exactly the
    /// side whose limit was the binding one. `_dropIneligible` then admitted
    /// orders that the realised price did not satisfy and they were filled
    /// through their `minOut`, breaking I8. Solvency was never affected —
    /// `fillRatio` guarantees I2 and I4 whatever the prediction says — which is
    /// why no invariant caught it.
    ///
    /// The single-range predecessor (`Clearing.solve`'s `a * b`) was correct
    /// under clamping, because `a * b` IS `Y / X`. The multi-range amendment
    /// replaced a correct formula with one that only held in the unclamped
    /// case; this restores the property while keeping the multi-range answer.
    ///
    /// This is a prediction used for the eligibility test only. Payouts are
    /// computed from what the pool actually returned, so a prediction that is
    /// a few wei off costs an order its place in this batch at worst, never
    /// solvency.
    function _predictedPrice(
        Clearing.Solution memory out,
        uint256 net0,
        uint256 net1
    ) private pure returns (uint160) {
        // A perfectly matched batch never touches the curve, so the totals
        // identity degenerates. Its price is the coincidence-of-wants price.
        if (out.residualIn == 0) {
            if (net0 == 0) return 0;
            return _toUint160(FullMath.mulDiv(net1, Q96, net0));
        }

        // A residual that moves in one direction only cannot imply a price.
        if (out.residualOut == 0) return 0;

        // `P = Y / X`, in currency1-per-currency0 both ways round: the pool
        // pays currency1 for a zeroForOne residual and takes it for the other.
        if (out.zeroForOne) {
            return _toUint160(FullMath.mulDiv(out.residualOut, Q96, out.residualIn));
        }
        return _toUint160(FullMath.mulDiv(out.residualIn, Q96, out.residualOut));
    }

    function _toUint160(
        uint256 x
    ) private pure returns (uint160) {
        return x > type(uint160).max ? type(uint160).max : uint160(x);
    }

    /// @dev Aggregate net-of-fee input per direction over the live candidates.
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

    /// @dev Retire candidates whose limit price the batch price does not meet.
    /// Comparison uses each side's *effective* price — the price the trader
    /// actually realises once `f_slow` is applied — which is what makes I8 an
    /// exact property rather than an approximation.
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

    /// @dev The price each side actually realises at a batch price of
    /// `priceX96`, once `f_slow` is applied. A currency0 seller receives
    /// `P * (1 - f)`; a currency1 seller pays `P / (1 - f)`.
    ///
    /// Shared by the eligibility screen and the post-settlement re-check so the
    /// two can never disagree about what "effective price" means.
    function _effectivePrices(
        uint256 priceX96
    ) private view returns (uint256 effZeroForOne, uint256 effOneForZero) {
        uint256 slowFee = fSlow;
        effZeroForOne = FullMath.mulDiv(priceX96, FEE_DENOMINATOR - slowFee, FEE_DENOMINATOR);
        effOneForZero = FullMath.mulDiv(priceX96, FEE_DENOMINATOR, FEE_DENOMINATOR - slowFee);
    }

    /// @dev I8, enforced against the price the batch REALLY cleared at.
    ///
    /// `_dropIneligible` screens against `sol.priceX96`, which is a prediction
    /// made before the residual executed. Payouts come from the pots, so the
    /// realised price is `pot1 / filled0` (equivalently `filled1 / pot0` — I4
    /// says these agree). Nothing structurally forces the two to match:
    ///
    ///  * on the curve path they differ by integer rounding, and by more than
    ///    that if the multi-range walk mispredicts the pool's own swap loop;
    ///  * on the filler path a delivery ABOVE the curve floor moves the
    ///    realised price up. That is an improvement for the currency0 sellers
    ///    and, by the same amount, a *deterioration* for the currency1 sellers
    ///    on the other side of the same batch, whose limit is a ceiling. A
    ///    filler could otherwise improve one side straight through the other
    ///    side's stated `minOut` (SR-9).
    ///
    /// So the screen is re-run against the realised price and the settlement
    /// reverts if any order it was about to fill fails it. Reverting is the
    /// safe direction and it is cheap: nothing has been distributed yet, the
    /// residual unwinds with it, and the batch simply retries. On the piggyback
    /// path `settleFromCallback` absorbs it; on the filler path it returns the
    /// filler's delivery along with it.
    ///
    /// This is the primary defence for I8. `_dropIneligible` is now the
    /// optimisation — it keeps ineligible orders out of the residual sizing —
    /// and this is the guarantee.
    function _assertLimitsHeld(
        Cand[] memory c,
        Pots memory p
    ) private view {
        // Nothing was filled: no order can have been filled through its limit.
        if (p.filled0 == 0 && p.filled1 == 0) return;

        // The realised uniform price, from tokens the hook demonstrably holds.
        uint256 realised =
            p.filled0 > 0 ? Clearing.impliedPriceX96(p.pot1, p.filled0) : Clearing.impliedPriceX96(p.filled1, p.pot0);

        (uint256 effZeroForOne, uint256 effOneForZero) = _effectivePrices(realised);

        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live || c[i].grossFilled == 0) continue;

            uint256 limit = c[i].limitPriceX96;
            uint256 slack = (limit * I8_TOLERANCE_PPM) / FEE_DENOMINATOR;

            if (c[i].zeroForOne) {
                // Floor: the realised effective price must be at least the limit.
                if (effZeroForOne + slack < limit) revert KesselErrors.LimitPriceBreached();
            } else {
                // Ceiling: it must be at most the limit.
                if (effOneForZero > limit + slack) revert KesselErrors.LimitPriceBreached();
            }
        }
    }

    /// @dev Execute the residual, then distribute pots that are, by
    /// construction, exactly the tokens the hook holds.
    ///
    /// ## On the ordering
    ///
    /// There is deliberately no untrusted external call anywhere between the
    /// start of this function and its last state write. On the curve path the
    /// only counterparty is the PoolManager; on the filler path the delivery
    /// arrived *before* `settleWithFill` was entered, so `_acceptFillerDelivery`
    /// only measures and banks it. The filler is paid afterwards, by
    /// `_settleEpochInner`, once every write here has landed.
    ///
    /// That is checks-effects-interactions in the order it is supposed to be
    /// in, and it is why this path carries no write-after-untrusted-call
    /// pattern for a static analyser to report. The first version of Shape B
    /// did — it paid the filler up front and called back into it — and the
    /// inversion was worth the loss of convenience: a filler can no longer
    /// source its delivery from the very input it is being paid, and must
    /// front the capital or flash-borrow it from somewhere outside Kessel.
    ///
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

        // ---- fill ratio, derived from what ACTUALLY executed ---------------
        // The closed form only picked a target. Whatever the pool really did,
        // this ratio makes the batch exactly uniform-priced and exactly
        // solvent — so solvency never depends on the prediction being right.
        uint256 lambdaX96;
        if (sol.residualIn == 0) {
            lambdaX96 = Q96;
        } else if (sol.zeroForOne) {
            lambdaX96 = Clearing.fillRatio(net0, net1, uint256(-poolDelta0), uint256(poolDelta1));
        } else {
            lambdaX96 = Clearing.fillRatio(net1, net0, uint256(-poolDelta1), uint256(poolDelta0));
        }
        // A zero ratio means no self-consistent fill exists for what executed.
        // The residual swap has already happened, so continuing would strand
        // tokens; reverting unwinds it cleanly and the batch retries later.
        if (lambdaX96 == 0) revert KesselErrors.NothingToSettle();

        // First pass: work out each order's actual fill, and total them.
        //
        // The totals MUST come from the per-order sum rather than from
        // `net * lambda` on the aggregate. The two differ by a few wei — each
        // order's fill is floored independently — and using the aggregate
        // estimate lets a pot come out negative on a one-sided batch, which
        // then wraps on the cast to `uint256`.
        Pots memory p;
        p.lambdaX96 = lambdaX96;
        (p.filled0, p.filled1, p.gross0, p.gross1) = _computeFills(c, lambdaX96);

        uint256 fee0 = p.gross0 - p.filled0;
        uint256 fee1 = p.gross1 - p.filled1;

        // Pots: exactly the tokens the hook demonstrably holds for each side.
        (p.pot0, fee0) = _potFor(p.filled0, poolDelta0, fee0);
        (p.pot1, fee1) = _potFor(p.filled1, poolDelta1, fee1);

        _assertUniformPrice(p.pot0, p.pot1, p.filled0, p.filled1);
        _assertLimitsHeld(c, p);

        uint256 settledCount = _applyFills(epoch, c, p);

        _recordEpoch(epoch, sol.priceX96, p, net0, net1, fee0, fee1, settledCount);
        _recapture(immutablePoolKeyStorage, fee0, fee1);
        _rollUnfilled(epoch);
    }

    /// @dev Move every still-fillable order out of a just-settled epoch and
    /// into the open one, then retire the settled epoch.
    ///
    /// This is DD-11's "rolls into the next epoch" made literal, and it is what
    /// keeps settlement from head-of-line blocking. Settlement always works on
    /// the oldest unsettled epoch; without rolling, a single order whose limit
    /// price is never reached would pin that epoch open forever and no later
    /// batch could ever settle.
    ///
    /// Expired orders are deliberately left behind: they are refundable rather
    /// than fillable, and `redeem` reaches them by order id, not through the
    /// epoch index.
    function _rollUnfilled(
        uint32 from
    ) private {
        // Every caller closes the epoch first, so the destination is always
        // ahead of the source, and `_epochAcceptingOrders` only ever moves
        // forward. Checked once rather than assumed: rolling back into the
        // epoch this function is about to delete would strand every order in
        // it, and on an immutable contract that is not a failure mode worth
        // leaving to a code-reading argument.
        if (currentEpoch <= from) revert KesselErrors.EpochNotClosed();

        uint256[] storage ids = epochOrderIds[from];
        uint256 len = ids.length;

        for (uint256 i; i < len; ++i) {
            Order storage o = orders[ids[i]];
            if (o.status != OrderStatus.PENDING || o.amountInRemaining == 0) continue;
            if (_isExpired(o)) continue; // expired: leave it behind

            // Rolling goes through the same cap as intake, spilling into the
            // next epoch when one fills up. Without that cap here, an epoch's
            // index could grow without bound -- `_loadCandidates` would still
            // only look at the first `MAX_ORDERS_PER_EPOCH`, but this loop and
            // `_advanceIfDrained` walk the whole array, so a few hundred
            // resting orders would put settlement out of gas reach and take I11
            // with it.
            epochOrderIds[_epochAcceptingOrders()].push(ids[i]);
        }

        // The settled epoch's index has served its purpose; clearing it is what
        // lets the cursor move on.
        delete epochOrderIds[from];

        if (from == oldestUnsettledEpoch) {
            oldestUnsettledEpoch = from + 1;
            if (currentEpoch < oldestUnsettledEpoch) currentEpoch = oldestUnsettledEpoch;
        }
    }

    /// @dev The pots a settlement distributes, and the ratio that produced them.
    struct Pots {
        /// @dev Net-of-fee input actually filled, summed over orders.
        uint256 filled0;
        uint256 filled1;
        /// @dev Gross input actually filled, summed over orders.
        uint256 gross0;
        uint256 gross1;
        /// @dev Output available to each side. `pot1` is owed to the currency0
        /// sellers, `pot0` to the currency1 sellers.
        uint256 pot0;
        uint256 pot1;
        uint256 lambdaX96;
    }

    /// @dev First distribution pass: size every order's fill and total them.
    /// Writes the per-order amounts back into `c` so the second pass does not
    /// have to recompute them (and cannot disagree with these totals).
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

    /// @dev A side's pot, given what it committed and what the pool moved.
    ///
    /// @dev Independent flooring of each order's fill can leave the paying side
    /// a wei or two short of what the pool actually took. That shortfall is
    /// absorbed by the `f_slow` collected on the same side and in the same
    /// currency — reducing the donation rather than the trader payouts, so
    /// traders are never underpaid and the hook is never insolvent. If the fee
    /// cannot cover it, the settlement reverts and the batch retries; that is
    /// safe, because nothing has been distributed yet.
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

    /// @dev Execute the net residual against the curve and immediately resolve
    /// the hook's own deltas (I1). Custody moves between currencies and never
    /// leaves the singleton.
    ///
    /// This is a direct `poolManager.swap`, never a fresh `unlock`: on the
    /// piggyback path we are already inside one, and nesting would revert
    /// (PRD §8.3). The forced path supplies its own unlock before reaching here.
    function _executeResidual(
        Clearing.Solution memory sol
    ) private returns (int256 d0, int256 d1) {
        if (sol.residualIn == 0) return (0, 0);

        BalanceDelta d = poolManager.swap(
            immutablePoolKeyStorage,
            SwapParams({
                zeroForOne: sol.zeroForOne,
                // Reverting cast, not a truncating one: a residual that does
                // not fit an int128 could not be settled by v4 anyway, and
                // silently wrapping it would corrupt the swap direction.
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

    /// @dev Shape B: pull the delivery the filler declared, and return the SAME
    /// signed deltas the curve path returns so that everything downstream is
    /// unchanged.
    ///
    /// **There is no call to the filler here.** `CurrencySettler.settle` with an
    /// external payer is a `transferFrom` on the *token*, moving the delivery
    /// straight from the filler to the singleton; the filler itself is never
    /// handed control. It is paid at the very end of `_settleEpochInner`, after
    /// every state write — which is why the settlement path contains no
    /// write-after-untrusted-call ordering at all.
    ///
    ///  1. Refuse anything below the curve floor. That reverts the whole
    ///     settlement before a single token moves, so a filler that offers
    ///     short has spent gas to change nothing.
    ///  2. Pull exactly `delivered` from the filler into the singleton and mint
    ///     it as custody, so the pots are backed by tokens the hook
    ///     demonstrably holds, exactly as on the curve path (I2).
    ///
    /// The floor is `sol.residualOut`: what `Clearing` predicted the curve would
    /// pay for the same input. A filler therefore only ever wins by beating the
    /// pool, and every wei above the floor lands in the trader pots and is
    /// distributed at the batch's single uniform price (I4).
    ///
    /// A larger delivery produces a smaller fill ratio, so both sides of a
    /// two-sided batch still move together and I4 holds without recomputation.
    /// It does NOT leave the eligible set valid, which is a separate matter and
    /// the reason `_assertLimitsHeld` exists: the realised price is `Y / X`, so
    /// delivering above the floor raises it, improving the currency0 sellers'
    /// execution and worsening the currency1 sellers' by the same amount. A
    /// delivery generous enough to push the other side through its own ceiling
    /// is refused there (SR-9).
    ///
    /// SR-9. `delivered` is a parameter rather than `outCurrency.balanceOfSelf()`.
    /// The balance is unattributed — it is whatever anyone has ever sent this
    /// contract — so reading it let a filler satisfy the floor out of tokens it
    /// had not provided. Pulling a declared amount is exact by construction and
    /// leaves no raw balance on the hook to be claimed by anyone.
    function _acceptFillerDelivery(
        uint32 epoch,
        Clearing.Solution memory sol,
        address filler,
        uint256 delivered
    ) private returns (int256 d0, int256 d1) {
        // A perfectly matched batch never touches any counterparty, so there is
        // nothing to pull and nothing to pay for. Deliberately not a revert:
        // the settlement itself is valid and completes, and because nothing is
        // pulled the filler loses nothing by having offered.
        if (sol.residualIn == 0) return (0, 0);

        Currency outCurrency = sol.zeroForOne ? currency1 : currency0;
        uint256 floorOut = sol.residualOut;

        if (delivered < floorOut) revert KesselErrors.FillerUnderDelivered();

        // `payer = filler`, so this is a `transferFrom` into the singleton. The
        // filler must have approved this contract for `delivered`.
        outCurrency.settle(poolManager, filler, delivered, false);
        poolManager.mint(address(this), outCurrency.toId(), delivered);

        emit KesselEvents.SlowBatchFilledExternally(epoch, filler, sol.residualIn, floorOut, delivered);

        // Same sign convention as `_executeResidual`: negative is what the hook
        // paid away, positive is what it received. The negative leg is booked
        // here even though the transfer happens later, because the accounting
        // is what sizes the pots; the payment is settled against this delta at
        // the end of `_settleEpochInner`.
        //
        // Reverting casts bounded to `int128`, matching what the curve path can
        // produce: `_executeResidual` gets its deltas from a `BalanceDelta`,
        // whose halves are int128 by construction.
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
        // Reverting casts. `filled*` is bounded by the warehouse cap, but the
        // pots also carry the pool's output, so they are not bounded a priori.
        e.filledNetIn0 = p.filled0.toUint128();
        e.filledNetIn1 = p.filled1.toUint128();
        e.pot0 = p.pot0.toUint128();
        e.pot1 = p.pot1.toUint128();
        e.settled = true;

        // Coincidence-of-wants volume: the part of the batch that never touched
        // the curve. Reported for the demo's "what did the delay buy you" chart.
        uint256 matched = p.filled0 < p.filled1 ? p.filled0 : p.filled1;

        emit KesselEvents.SlowBatchSettled(epoch, priceX96, net0, net1, matched, p.lambdaX96, fee0, fee1, settledCount);
    }

    /// @dev Apply the fill ratio to every eligible order and accrue `f_slow`.
    /// Payouts are pro-rata shares of a pot, which is simultaneously the
    /// definition of a uniform price (I4) and a guarantee that the sum of
    /// payouts cannot exceed custody (I2).
    function _applyFills(
        uint32 epoch,
        Cand[] memory c,
        Pots memory p
    ) private returns (uint256 settledCount) {
        // Remaining pot on each side. Each payout is deducted, and the last
        // order can never be paid more than what is actually left — so the sum
        // of payouts cannot exceed custody even if every division rounded
        // against us (I2).
        uint256 left1 = p.pot1;
        uint256 left0 = p.pot0;

        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live || c[i].grossFilled == 0) continue;

            uint128 grossFilled = c[i].grossFilled;
            uint256 netFilled = c[i].netFilled;

            // A pro-rata share of the pot IS the uniform price (I4): every order
            // on a side receives output in exact proportion to the input it
            // contributed. Capped at what is actually left, so the sum of
            // payouts can never exceed the pot even if every division rounded
            // against us.
            uint256 out;
            if (c[i].zeroForOne) {
                out = p.filled0 == 0 ? 0 : FullMath.mulDiv(netFilled, p.pot1, p.filled0);
                if (out > left1) out = left1;
            } else {
                out = p.filled1 == 0 ? 0 : FullMath.mulDiv(netFilled, p.pot0, p.filled1);
                if (out > left0) out = left0;
            }

            // Never consume input for nothing. A zero payout against a nonzero
            // fill means the pots came out degenerate.
            //
            // This aborts the settlement rather than skipping the order,
            // because skipping would silently desynchronise the books: the
            // order's input was already included in the totals that sized the
            // residual, so declining to consume it leaves custody short of
            // obligations by exactly that share. Aborting unwinds the residual
            // too, so the batch simply retries later with nothing lost. On the
            // piggyback path this is caught by `settleFromCallback`, so the
            // carrying swap is unaffected.
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
            // Reverting cast; `+=` on a uint128 is itself checked, so an order
            // accumulating more than a uint128 of output across partial fills
            // reverts rather than wrapping.
            uint128 out128 = out.toUint128();
            o.owedOut += out128;
            if (o.amountInRemaining == 0) o.status = OrderStatus.FILLED;

            ++settledCount;
            emit KesselEvents.SlowOrderFilled(c[i].id, epoch, grossFilled, out128);
        }
    }

    /// @dev I4. In exact arithmetic the two sides' implied prices are equal;
    /// integer division leaves a few wei. Checked only for two-sided batches
    /// with non-dust pots, because at dust scale integer rounding legitimately
    /// dominates and a relative test would be meaningless.
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

        require(diff * 1_000_000 <= scale * I4_TOLERANCE_PPM, "I4: non-uniform clearing price");
    }

    /// @dev Route `f_slow` to LPs (I5, DD-10a), with PRD §6.2's mandatory
    /// empty-range fallback.
    ///
    /// `donate()` reverts when no liquidity is in range, and a fully
    /// CoW-matched batch never touches the curve, so it cannot rely on the
    /// residual swap having proven liquidity exists. Falling back to a
    /// hook-held LP-claimable balance is therefore load-bearing, not defensive.
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
            // Held for LPs, never for the hook. Distributed by `sweepRecapture`
            // once liquidity is in range again.
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

    /// @notice Donate previously-deferred recapture to LPs, and sweep any raw
    /// token balance sitting on this contract to them as well. Permissionless:
    /// all of this money is already owed to LPs and the hook must never keep it
    /// (I5).
    ///
    /// @dev Safe to call when nothing is pending, and safe to call when
    /// liquidity is still out of range — `_recapture`'s fallback simply
    /// re-defers the amount rather than reverting.
    ///
    /// The raw-balance half exists because this contract is not supposed to
    /// hold a raw balance at all: custody lives as ERC-6909 inside the
    /// singleton, and SR-9 removed the one path that used to leave tokens here.
    /// Anything that still arrives — a mistaken transfer, an order that named
    /// the hook itself as its beneficiary — would otherwise sit forever with no
    /// owner. Routing it to LPs gives it one, and gives anyone the means to
    /// move it there.
    function sweepRecapture() external {
        if (lpClaimable0 == 0 && lpClaimable1 == 0 && currency0.balanceOfSelf() == 0 && currency1.balanceOfSelf() == 0)
        {
            return;
        }
        poolManager.unlock(abi.encode(UnlockAction.SWEEP, uint32(0), uint256(0), uint256(0)));
    }

    /// @dev Inside the unlock. Zeroes the deferred balances *before* attempting
    /// the donation so that a re-deferral in the catch branch cannot
    /// double-count; `_recapture` adds them straight back if it still fails.
    function _sweep() private {
        uint256 a0 = lpClaimable0 + _absorbStray(currency0);
        uint256 a1 = lpClaimable1 + _absorbStray(currency1);
        lpClaimable0 = 0;
        lpClaimable1 = 0;
        _recapture(immutablePoolKeyStorage, a0, a1);
    }

    /// @dev Convert a raw token balance held by this contract into ERC-6909
    /// custody, so it can be donated on the same footing as every other
    /// recaptured fee.
    ///
    /// The conversion is not optional bookkeeping: `_recapture` pays the
    /// donation by BURNING 6909 (`settle(..., burn: true)`). Adding a raw
    /// balance straight into `lpClaimable*` without minting it first would make
    /// that burn come out of the traders' escrow instead — turning a stray
    /// donation into an insolvency. Minting first keeps custody and obligations
    /// moving together (I2).
    function _absorbStray(
        Currency c
    ) private returns (uint256 amount) {
        amount = c.balanceOfSelf();
        if (amount == 0) return 0;
        c.settle(poolManager, address(this), amount, false);
        poolManager.mint(address(this), c.toId(), amount);
    }

    // ==================================================================
    // Redemption (DD-15: pull)
    // ==================================================================

    /// @notice Collect an order's settled output, and its refund if expired.
    ///
    /// @dev Permissionless in caller, fixed in destination: anyone may pay the
    /// gas, but the output always goes to the recorded trader. That lets a
    /// third party unstick a trader who never returns (PRD §11 case 5) while
    /// creating no way to redirect funds.
    ///
    /// There is deliberately no `cancel` (DD-9). The expiry refund is not
    /// cancellation: it cannot be invoked early, and it forfeits a fixed
    /// fraction to LPs, which is what stops "post an unreachable limit, take
    /// the input back later" from being a free option (PRD §7.3).
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

    /// @dev Inside the unlock: move output (and any expired refund) out of the
    /// hook's ERC-6909 custody to the trader.
    ///
    /// Both outbound legs hand control to `o.trader` when the currency is
    /// native ETH — `poolManager.take` pays it with a bare `call` — and DD-14
    /// refuses native ETH only as Slow-Lane *input*, so a `oneForZero` order on
    /// an ETH-quoted pool pays out in ETH and this reentry point is live on
    /// every such deployment. `_settling` is therefore held across the whole
    /// function: see SR-6 and `test/security/RedeemReentrancy.t.sol`.
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

        // I3: settled -> redeemed happens exactly once.
        //
        // The `owedOut == 0` conjunct is defence in depth, not the primary
        // guard: `_settling` already stops anything from crediting this order
        // while the payout is in flight. It is kept because the failure it
        // prevents — an order marked terminal while it still owes output, whose
        // `redeem` then reverts `AlreadyFinalised` forever — is unrecoverable
        // on an immutable contract, and SR-4 is the standing reminder that
        // "unreachable by argument" is not the same as unreachable.
        if (o.status == OrderStatus.FILLED && o.owedOut == 0) o.status = OrderStatus.REDEEMED;
    }

    // ==================================================================
    // Settlement gates (DD-6, DD-13)
    // ==================================================================

    /// @dev Close a batch to new arrivals. Without this, an order submitted
    /// after this epoch became settlement-eligible would inherit the epoch's
    /// age and could be cleared in the very next settlement -- approximating
    /// submission-time pricing and eroding I6. It also makes `epochExpiry`
    /// meaningful, since epochs advance whenever settlement happens rather than
    /// only when a batch fills up.
    function _closeEpoch(
        uint32 epoch
    ) private {
        if (epoch >= currentEpoch) currentEpoch = epoch + 1;
    }

    /// @dev An order is expired only when BOTH its epoch budget has run out and
    /// the protocol's own maximum settlement delay has elapsed since its batch
    /// opened.
    ///
    /// The block-age half is a security requirement, not a nicety. Epochs
    /// advance whenever one saturates, and saturating an epoch is something
    /// anyone can do with `MAX_ORDERS_PER_EPOCH` dust orders in a single block.
    /// Measured in epochs alone, expiry is therefore attacker-controlled: churn
    /// epochs and every short-dated order in the book is forced into a refund,
    /// charged the expiry forfeit and denied the trade it asked for, without
    /// the market moving at all.
    ///
    /// `maxDelay` is the right floor because it is already the protocol's own
    /// statement of how long a batch may be made to rest before forced
    /// settlement (I11): an order cannot be refunded for having rested too long
    /// until it has rested at least as long as the protocol may make it.
    ///
    /// SR-10: the block half is read from the order's own `expiryBlock` stamp,
    /// not recomputed from the live `maxDelay`. Recomputing made expiry
    /// non-monotone — governance raising `maxDelay` could turn an already
    /// expired order back into an unexpired one, and `_rollUnfilled` has by
    /// then dropped it from every epoch index, so it was neither fillable nor
    /// redeemable until the raised floor elapsed. A stamp cannot move.
    function _isExpired(
        Order storage o
    ) private view returns (bool) {
        if (currentEpoch <= o.epochExpiry) return false;
        return block.number >= o.expiryBlock;
    }

    /// @dev I11's hard bound. Past this point a batch is moved out of the way
    /// even if the pool could not be solved, so an unsolvable pool state cannot
    /// pin the settlement cursor indefinitely.
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

    /// @dev DD-13. The size floor stops repeated tiny forced settlements; the
    /// `absoluteMaxDelay` escape stops that floor from silently stranding a
    /// lone order and breaking I11. This is why I11 is tested against
    /// `absoluteMaxDelay` and not `maxDelay`.
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

    /// @notice Whether `forceSettle()` would currently succeed. For keepers and
    /// for the liveness test.
    function forceSettleDue() external view returns (bool) {
        return _forceSettleDue(oldestUnsettledEpoch);
    }

    // ==================================================================
    // Internals
    // ==================================================================

    /// @dev Bounds of the range over which active liquidity is constant, as
    /// ticks. The multi-range walk needs the tick itself rather than only its
    /// price, because it has to read `liquidityNet` at the boundary it crosses.
    ///
    /// Liquidity changes only at *initialised* ticks, so this searches the tick
    /// bitmap rather than snapping to the next multiple of `tickSpacing`. The
    /// distinction is not cosmetic: most spacing multiples carry no position,
    /// and clamping to them would force nearly every batch into a partial fill.
    ///
    /// When a word contains no initialised tick, its boundary is returned —
    /// which is still a correct bound, since no liquidity change can occur
    /// before it.
    function _activeRangeTicks(
        int24 tick
    ) private view returns (int24 lowerTick, int24 upperTick) {
        int24 spacing = tickSpacing;
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;

        lowerTick = _scanDown(compressed, spacing);
        upperTick = _scanUp(compressed, spacing);
    }

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

    /// @dev Cursor arithmetic is done in `int256`, not `int24`.
    ///
    /// A word step moves the cursor by up to 256 compressed ticks, and the
    /// cursor is only converted back to a tick by multiplying by the spacing.
    /// For a wide-spaced pool that product leaves `int24` range after a single
    /// step off the end of the initialised ticks -- `-257 * 32767` is already
    /// past `int24` min -- and the checked multiplication would then panic
    /// *inside* settlement. On an immutable, pool-bound hook that is permanent:
    /// every settlement for that pool reverts forever. Widening the cursor and
    /// clamping at the end keeps the out-of-range case doing what it should,
    /// which is to return the tick range's own boundary.
    function _scanDown(
        int24 compressed,
        int24 spacing
    ) private view returns (int24) {
        int256 cursor = compressed;
        int256 sp = spacing;

        for (uint256 w; w < MAX_BITMAP_WORDS; ++w) {
            (int16 wordPos, uint8 bitPos) = _position(int24(cursor));
            uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & ((1 << bitPos) - 1 + (1 << bitPos));

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
        int24 compressed,
        int24 spacing
    ) private view returns (int24) {
        int256 cursor = int256(compressed) + 1;
        int256 sp = spacing;

        for (uint256 w; w < MAX_BITMAP_WORDS; ++w) {
            (int16 wordPos, uint8 bitPos) = _position(int24(cursor));
            uint256 masked = poolManager.getTickBitmap(poolId, wordPos) & ~((1 << bitPos) - 1);

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

    function _netOfSlowFee(
        uint256 gross,
        uint24 slowFee
    ) private pure returns (uint256) {
        return gross - FullMath.mulDiv(gross, slowFee, FEE_DENOMINATOR);
    }

    /// @dev Returns the epoch that should receive a new order, opening a fresh
    /// one when the current epoch is full. Filling an epoch never refuses an
    /// order — it just starts the next batch — so a spammer cannot block
    /// submissions, only create more batches (each of which is itself capped).
    function _epochAcceptingOrders() private returns (uint32 epoch) {
        epoch = currentEpoch;
        if (epochOrderIds[epoch].length >= MAX_ORDERS_PER_EPOCH) {
            epoch = ++currentEpoch;
        }
        if (epochs[epoch].openedAtBlock == 0) {
            epochs[epoch].openedAtBlock = uint64(block.number);
        }
    }

    /// @dev Move the settlement cursor forward once an epoch has no fillable
    /// orders left. Never skips an epoch that still has work.
    function _advanceIfDrained(
        uint32 epoch
    ) private {
        if (epoch != oldestUnsettledEpoch) return;

        uint256[] storage ids = epochOrderIds[epoch];
        uint256 len = ids.length;
        // An epoch that never received an order stays open; advancing past it
        // would inflate epoch numbers on every swap for no reason.
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

    /// @dev I9. Denominated per currency in that currency's own units — see the
    /// note on `maxWarehouse0`.
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

    // ==================================================================
    // Governance — bounded parameters only (PRD §5.4)
    // ==================================================================

    function setFees(
        uint24 newFBase,
        uint24 newFSlow
    ) external onlyGovernance {
        if (newFBase < F_BASE_MIN || newFBase > F_BASE_MAX) revert KesselErrors.ParameterOutOfBounds();
        // I10: 0 <= f_slow < f_base, enforced at the only place either can move.
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

    /// @notice Set the size-denominated tax multiplier (DD-4 as amended).
    /// @dev Settable even on a deployment fixed to the rate form, where it has
    /// no effect. Refusing there would be a second failure mode to reason
    /// about for no benefit, and the value is visible on-chain either way.
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

    /// @notice Set the per-direction minimum Slow-Lane order size (SR-12).
    ///
    /// @dev Deliberately unbounded, matching `setWarehouseCaps`. A ceiling
    /// would have to be a constant in token units, and no such constant is
    /// meaningful across decimal conventions — an 18-decimal bound is absurd on
    /// a 6-decimal pool and vice versa.
    ///
    /// Nothing is conceded by leaving it open. A floor set absurdly high
    /// refuses NEW orders and nothing else: every existing claim stays
    /// redeemable and every expired one stays refundable, because the check
    /// sits at intake, before custody is taken. That is the same capability
    /// governance already holds through `maxWarehouse* = 0` and through
    /// `setPaused`, both of which are documented and neither of which can
    /// strand funds (PRD §11 case 12). Announced like every other parameter,
    /// so it cannot be moved quietly.
    function setMinOrderSize(
        uint128 min0,
        uint128 min1
    ) external onlyGovernance {
        emit KesselEvents.ParameterUpdated("minOrderSize0", minOrderSize0, min0);
        emit KesselEvents.ParameterUpdated("minOrderSize1", minOrderSize1, min1);
        minOrderSize0 = min0;
        minOrderSize1 = min1;
    }

    /// @notice Set the DD-5 residual cap, as a fraction of the analytic
    /// break-even in bps (10,000 = exactly break-even).
    ///
    /// @dev Bounded at both ends, and the ceiling is the point of the whole
    /// mechanism: `RESIDUAL_CAP_BPS_MAX = 10_000` means no reachable governance
    /// setting can place the cap where sandwiching the settlement residual
    /// turns a profit. Governance can tune how much margin the protocol keeps
    /// above that line; it cannot cross it, and it cannot switch the bound off.
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

    /// @notice Hand parameter authority to a new address.
    ///
    /// @dev The zero-address check is load-bearing on an immutable contract:
    /// `governance` is the only authority over every tunable, and there is no
    /// recovery path, so handing it to `address(0)` would freeze all of them at
    /// whatever value they happened to hold. Announced like every other
    /// parameter change, because it is the most consequential one.
    function setGovernance(
        address newGovernance
    ) external onlyGovernance {
        if (newGovernance == address(0)) revert KesselErrors.ParameterOutOfBounds();
        emit KesselEvents.ParameterUpdated("governance", uint256(uint160(governance)), uint256(uint160(newGovernance)));
        governance = newGovernance;
    }

    /// @notice Guardian pause (PRD §11 case 12).
    /// @dev Blocks *new* Slow-Lane orders and settlement. It deliberately does
    /// NOT block `redeem`: a pause that could strand funds is exactly what the
    /// PRD forbids. Traders can always get their output and, once expired,
    /// their input back, whether or not the hook is paused.
    function setPaused(
        bool p
    ) external onlyGovernance {
        paused = p;
        emit KesselEvents.PausedSet(p);
    }

    // ==================================================================
    // Views for tests, keepers and the demo dashboard
    // ==================================================================

    /// @notice What the next external fill would need to deliver, and what it
    /// would be paid.
    ///
    /// @dev Fillers need this: the deliver-first model means the tokens have to
    /// be transferred before `settleWithFill` is called, so the amount cannot
    /// be discovered from inside a callback. Reading it and acting on it in the
    /// same transaction is the intended pattern.
    ///
    /// Quoted off the same settlement-time pool state the settlement itself
    /// will use, so a quote read and acted on in one transaction is exact. Read
    /// in one block and used in another it is only an estimate — the pool moves
    /// — and the settlement will refuse a short delivery rather than settle
    /// badly. That asymmetry is deliberate: I6 forbids pinning a Slow-Lane
    /// price to anything but settlement-time state, so this cannot be made into
    /// a binding quote without breaking the anti-hedging property.
    ///
    /// @return ok False when there is nothing fillable right now.
    /// @return outCurrency The currency the filler must deliver.
    /// @return minDeliver The minimum delivery that will be accepted — what the
    /// curve would pay for the same input.
    /// @return inCurrency The currency the filler will be paid in.
    /// @return payout How much of it the filler will receive.
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

    /// @notice The hook's ERC-6909 custody balance for a currency — the
    /// quantity I2 conserves against outstanding claims.
    function custodyOf(
        Currency currency
    ) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }
}
