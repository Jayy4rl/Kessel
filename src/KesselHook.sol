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

/// @title Kessel — a two-lane execution hook on one shared liquidity curve
///
/// @notice Two execution contracts on a single Uniswap v4 pool, chosen by the
/// trader per swap:
///
///  * **Fast Lane** — an ordinary synchronous swap whose LP fee rises with the
///    trader's revealed urgency, `f_base + k * priorityFeePerGas`. The premium
///    is recaptured to LPs rather than left to the sequencer.
///  * **Slow Lane** — the hook escrows the input and issues a non-transferable
///    claim; the order clears later, in a batch, at one uniform price computed
///    at *settlement* time.
///
/// The mechanism prices **immediacy**, not toxicity. It does not remove adverse
/// selection or LVR — see `docs/PRD.md` §1.3 and §7.5 for the exact scope of
/// every claim, and do not restate them more strongly than they are written.
///
/// @dev The permission bitmap is encoded in this contract's address, so it is
/// frozen. Settlement math cannot be patched. Every tunable is a bounded
/// parameter with deploy-fixed bounds, and the guardian pause only ever lets
/// funds *out* — it can never strand them.
contract KesselHook is IUnlockCallback {
    using CurrencySettler for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000; // v4 fee units
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    uint24 internal constant F_BASE_MIN = 100; // 1 bp
    uint24 internal constant F_BASE_MAX = 100_000; // 10%
    /// @dev Hard ceiling on the total Fast-Lane fee, well under v4's
    /// `MAX_LP_FEE`. Caps the urgency tax without breaking fee monotonicity.
    uint24 internal constant MAX_FAST_FEE = 50_000; // 5%
    uint256 internal constant K_MIN = 0;
    uint256 internal constant K_MAX = 100_000; // 1 gwei => +10%

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
    /// made to pay unboundedly. An epoch that fills opens a new one, so
    /// this caps work per settlement without ever refusing an order.
    uint256 internal constant MAX_ORDERS_PER_EPOCH = 32;
    /// @dev Eligibility rounds for the shrinking-set iteration. The set
    /// shrinks monotonically, so this only bounds work, never correctness.
    uint256 internal constant MAX_CLEARING_ROUNDS = 4;

    /// @dev Residual cap, as a fraction of the analytic break-even. See
    /// `BatchSolver._residualCap` for the derivation of the break-even itself.
    ///
    /// `RESIDUAL_CAP_BPS_MAX = 10_000` is exactly break-even and is a HARD
    /// deploy-fixed ceiling: no reachable governance setting can place the cap
    /// above the point where sandwiching the settlement residual turns a
    /// profit. That is the property that makes this a real bound rather
    /// than a tuning knob — the defence cannot be switched off.
    ///
    /// The floor stops governance from setting a cap so tight that a one-sided
    /// batch needs an unreasonable number of epochs to clear.
    uint16 internal constant RESIDUAL_CAP_BPS_MIN = 500; // 5% of break-even
    uint16 internal constant RESIDUAL_CAP_BPS_MAX = 10_000; // 100% = break-even
    /// @dev Uniform-price tolerance. The two sides' implied prices are equal in exact
    /// arithmetic; integer division leaves at most a few wei per pot. Applied
    /// only to two-sided batches with non-dust pots — see `_assertUniformPrice`.
    uint256 internal constant I4_TOLERANCE_PPM = 100; // 0.01%
    uint256 internal constant I4_DUST_FLOOR = 1e6;

    /// @dev Tolerance for the post-settlement limit re-check (SR-8). The
    /// eligibility screen and the realised price are computed from different
    /// quantities — the sized residual versus the distributed pots — so they
    /// agree to within integer rounding rather than bit for bit. One part per
    /// million is several orders of magnitude above that rounding and far
    /// below any economically meaningful breach, and it is a hundred times
    /// tighter than the tolerance the uniform-price assertion already runs with.
    uint256 internal constant I8_TOLERANCE_PPM = 1; // 0.0001%

    // ------------------------------------------------------------------
    // Immutable pool binding
    // ------------------------------------------------------------------

    /// @dev Kessel serves exactly one pool. This is a security requirement, not
    /// a simplification: the hook's ERC-6909 custody is held per *currency*, so
    /// a hook serving two pools that share a currency could have one pool's
    /// settlement drain the other's escrow. OpenZeppelin's `BaseAsyncSwap`
    /// carries the same warning. Every callback rejects any other pool.
    /// @dev The v4 singleton. Held here rather than inherited: Kessel
    /// implements the two hook callbacks it actually uses directly, so the
    /// eight it does not are absent from the ABI entirely.
    IPoolManager public immutable poolManager;

    PoolKey internal immutablePoolKeyStorage;
    PoolId public immutable poolId;
    Currency public immutable currency0;
    Currency public immutable currency1;
    int24 public immutable tickSpacing;

    /// @dev Which side of the pool, if either, is the chain's gas token — and
    /// therefore whether the Fast Lane can use the paper's size-denominated tax
    /// or must fall back to the rate form.
    ///
    /// Immutable on purpose. The tax mode is a protocol-visible property of the
    /// deployment, and a governance switch that could flip it under a live pool
    /// would let the fee schedule change shape without changing a parameter
    /// anyone is watching.
    uint8 internal immutable gasTokenSide;

    // ------------------------------------------------------------------
    // Bounded governance parameters
    // ------------------------------------------------------------------

    address public governance;
    bool public paused;

    uint24 public fBase = 3_000; // 0.30%
    uint24 public fSlow = 500; // 0.05% — must stay strictly below fBase
    uint256 public k = 500; // rate form: 1 gwei => +5 bp
    /// @dev The size-denominated tax multiplier, in gas units.
    /// Used only when `gasTokenSide != GAS_TOKEN_NONE`. Default is the rough
    /// gas cost of a swap, which makes the tax comparable to the priority bid
    /// the trader is already paying for the same ordering.
    uint256 public kGas = 150_000;

    uint32 public minSettleAge = 2; // blocks; guards settlement-time pricing
    uint32 public maxDelay = 300; // blocks
    uint32 public absoluteMaxDelay = 3_000; // blocks; the liveness escape
    uint32 internal minForceSettleOrders = 2; // anti-grief size floor for forced settlement
    uint16 public expiryForfeitBps = 10; // 0.10%

    /// @dev How much of the analytic break-even
    /// residual a single settlement may push through the curve. Default 50%,
    /// i.e. half the residual at which sandwiching the settlement would start
    /// to pay, leaving a 2x margin against the model's own error.
    uint16 internal residualCapBps = 5_000;

    /// @dev Warehoused-exposure cap, per direction, denominated in that
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

    /// @dev Aggregate unsettled Slow-Lane input per direction.
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
    /// unlikely.
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

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert KesselErrors.NotPoolManager();
        _;
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
    /// 1 currency0, 2 currency1. Selects the Fast-Lane tax mode and
    /// cannot be changed afterwards.
    ///
    /// @dev The pool key is fixed here rather than learned at initialize time
    /// because the hook has no `beforeInitialize` permission — the bitmap is
    /// frozen and adding one would change this contract's address. The
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
    ) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());

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
    // Hook permissions — FROZEN (PRD §8.1)
    // ==================================================================

    /// @dev v4 encodes these bits in the contract address, so changing this
    /// function changes the address and invalidates any mined one.
    ///
    /// `afterSwap` is true **for settlement, not for fee routing**: it is the
    /// only callback that runs after the triggering swap's own price impact has
    /// been booked, which is exactly the condition PRD §7.6(b) demands before
    /// piggyback settlement is safe. The Fast-Lane premium needs no post-swap
    /// step at all — the dynamic fee override *is* the LP fee, and v4 credits
    /// it to in-range liquidity itself.
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

    // ==================================================================
    // beforeSwap — lane routing (PRD §8.3)
    // ==================================================================

    /// @notice v4 swap callback. Only the two callbacks this hook's permission
    /// bitmap enables exist on this contract; v4 can never invoke the others,
    /// so carrying reverting stubs for them only costs bytecode.
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    /// @notice v4 post-swap callback. Carries piggyback settlement.
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

            // The premium reaches LPs through this override and nothing else:
            // v4 credits the whole LP fee to in-range liquidity via
            // feeGrowthGlobal inside Pool.swap. No hook-held
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
    /// deployment was fixed to.
    ///
    /// The size-denominated mode falls back to the rate form whenever the size
    /// cannot be established — a degenerate or out-of-range price. Falling back
    /// is the safe direction: the rate form never under-charges relative to a
    /// size it could not compute, whereas treating an unknown size as large
    /// would hand out a cheap swap.
    ///
    /// Monotonicity holds in both branches and the branch does not depend on
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
    ///    the hook's own deltas are flat before it returns control.
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

        // Intake is closed while a settlement or redemption payout is in
        // flight, and this is load-bearing rather than defensive.
        //
        // `_executeResidualViaFiller` hands control to an untrusted contract
        // with the settlement half-finished. `_settling` stops that contract
        // reentering settlement, and v4's nested-`unlock` prohibition stops
        // `redeem`, `forceSettle` and `sweepRecapture`. Intake is the one
        // mutating path neither covers, because `poolManager.swap` is
        // `onlyWhenUnlocked` rather than `onlyByTheUnlocker` — so a filler may
        // call it directly, land here, and write `warehoused*`, `orders`,
        // `epochOrderIds` and `currentEpoch` underneath a settlement still
        // reading them.
        //
        // No concrete corruption was found by construction, which is precisely
        // why this is a check rather than an argument in a comment: this
        // contract cannot be patched. Nothing legitimate is refused — the
        // hook's own residual swap never reaches `beforeSwap`, since v4 skips a
        // hook's callbacks when the hook is the caller.
        if (_settling) revert KesselErrors.SettlementInProgress();

        // v4's async pattern is exact-input only (PRD §3.2); exact-output Slow
        // orders are out of scope (§17).
        if (params.amountSpecified >= 0) revert KesselErrors.SlowLaneRequiresExactInput();
        if (minOut == 0) revert KesselErrors.MinOutRequired();
        if (expiryEpochs == 0 || expiryEpochs > MAX_EXPIRY_EPOCHS) revert KesselErrors.ExpiryOutOfRange();

        bool zeroForOne = params.zeroForOne;
        Currency specified = zeroForOne ? key.currency0 : key.currency1;

        // native ETH cannot be custodied as an ERC-6909 claim the way an
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
        // the free-option analysis and the rolling policy, which is a
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
        // compared against every order. This is what makes the trader's
        // limit an exact bound rather than a post-hoc check.
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
    // afterSwap — piggyback settlement
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
    ///    would otherwise approximate submission-time pricing.
    ///
    /// This must never revert the triggering swap. Every gate is checked before
    /// anything is executed, and an infeasible batch is a no-op (PRD §11 case 1).
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
    // Forced settlement
    // ==================================================================

    /// @notice Permissionless safety valve. Callable by anyone once the batch
    /// has aged past its gate.
    ///
    /// @dev No reimbursement is paid, to anyone, ever. PRD §6.3 *permits* a
    /// capped reimbursement from `f_slow`; that permission is declined so that
    /// recapture integrity holds by construction rather than by a bound that
    /// must be audited on
    /// an immutable contract. The expected caller is a Slow-Lane trader
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
    /// already delivered, taking the better of that delivery and the curve.
    ///
    /// @dev Deliver-first, pay-last, and there is no callback. The hook pulls
    /// exactly `delivered` from `msg.sender`, refuses anything below what the
    /// curve would have paid, completes every state write, and pays the caller
    /// the batch's input *last*.
    ///
    /// The ordering is the point. Paying the filler first and calling back into
    /// it would let the filler source its delivery from the very input it is
    /// being paid — convenient, but it puts an untrusted call in the middle of
    /// a half-finished settlement. Pulling removes that window rather than
    /// guarding it: a `transferFrom` hands control to the *token*, not to the
    /// filler. A filler without inventory flash-borrows outside Kessel instead.
    ///
    /// SR-9. `delivered` is a parameter rather than `balanceOfSelf()`, which is
    /// unattributed — it is whatever anyone has ever sent this contract, so a
    /// filler could satisfy the floor out of someone else's tokens. A
    /// settlement that turns out to be a no-op now reverts rather than
    /// returning silently, so the delivery cannot be stranded for the next
    /// caller to collect.
    ///
    /// Gated on the piggyback clock rather than the forced one: a filler fronts
    /// capital to beat the curve and is not a grief vector, so making it wait
    /// for `maxDelay` would only withhold the improvement. `minSettleAge` still
    /// applies. Permissionless, unreimbursed, and opens its OWN `unlock`
    /// (PRD §8.3).
    ///
    /// @param delivered Exact amount of the output currency to pull from the
    /// caller. Read `quoteFill()` for the currency and the floor. A delivery so
    /// far above the floor that the batch's other side is pushed through its
    /// own limit price is refused rather than filled — see `_assertLimitsHeld`.
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

        // ---- shrinking-set iteration -------------------------------------
        (Clearing.Solution memory sol, uint256 net0, uint256 net1, bool converged) = _solveEligibleSet(c);

        // Nothing to distribute. Under-filling is safe; mis-filling is not
        //. But an epoch that produces no fill must still be able to get
        // out of the way, because settlement only ever works on
        // `oldestUnsettledEpoch` and a batch that pins it pins the whole lane.
        if (!converged || !sol.feasible || (net0 == 0 && net1 == 0)) {
            if (net0 == 0 && net1 == 0) {
                // The shrinking-set loop priced the batch and every order was
                // dropped for limit ineligibility. That is a COMPLETE
                // settlement outcome -- a fill ratio of zero for everyone -- so
                // the epoch is finished and its orders roll.
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
                // normally transient and worth retrying, but the liveness bound
                // caps how long
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
    /// a settlement. Exists so the iteration can re-price a shrinking set
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
            // here as well as at intake.
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
    /// a **deficit**. That asymmetry is why the PRD's recommended
    /// refund-on-violation policy is unsound rather than merely simpler.
    /// @dev Bundled separately to keep `_solveEligibleSet` within the EVM stack
    /// limit under the non-`via_ir` dev profile.
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

        // Round budget exhausted without a self-consistent set.
        return (sol, net0, net1, false);
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
    /// actually realises once `f_slow` is applied — which is what makes the
    /// limit an exact property rather than an approximation.
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

    /// @dev The trader's limit, enforced against the price the batch REALLY
    /// cleared at.
    ///
    /// `_dropIneligible` screens against a prediction made before the residual
    /// executed. Payouts come from the pots, so the realised price is
    /// `pot1 / filled0`. Nothing structurally forces the two to agree: on the
    /// curve path they differ by integer rounding, and on the filler path a
    /// delivery above the floor raises the realised price — an improvement for
    /// the currency0 sellers and, by the same amount, a deterioration for the
    /// currency1 sellers, whose limit is a ceiling. A filler could otherwise
    /// improve one side straight through the other side's stated `minOut`.
    ///
    /// So the screen is re-run against the realised price and the settlement
    /// reverts if any order it was about to fill fails it. Reverting is safe and
    /// cheap: nothing has been distributed, the residual unwinds with it, and
    /// the batch retries. This is the primary defence; `_dropIneligible` is the
    /// optimisation that keeps ineligible orders out of the residual sizing.
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
    /// This is "rolls into the next epoch" made literal, and it is what
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
            // resting orders would put settlement out of gas reach, and the
            // liveness bound with it.
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
    /// the hook's own deltas. Custody moves between currencies and never
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

    /// @dev Pull the delivery the filler declared, and return the SAME signed
    /// deltas the curve path returns so everything downstream is unchanged.
    ///
    /// **There is no call to the filler here.** `CurrencySettler.settle` with an
    /// external payer is a `transferFrom` on the *token*; the filler is never
    /// handed control, and is paid at the end of `_settleEpochInner` after every
    /// state write. That is why this path carries no write-after-untrusted-call
    /// ordering at all.
    ///
    /// The floor is `sol.residualOut`, what the curve was predicted to pay for
    /// the same input, so a filler only ever wins by beating the pool and every
    /// wei above the floor lands in the trader pots at the batch's single price.
    /// Below the floor the whole settlement reverts before a token moves.
    ///
    /// A larger delivery produces a smaller fill ratio, so both sides of a
    /// two-sided batch move together and the uniform price needs no
    /// recomputation. It does NOT keep the eligible set valid: the realised
    /// price is `Y / X`, so delivering above the floor raises it, improving the
    /// currency0 sellers and worsening the currency1 sellers by the same amount.
    /// A delivery generous enough to push the other side through its own ceiling
    /// is refused by `_assertLimitsHeld` (SR-9).
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
    /// definition of a uniform price and a guarantee that the sum of
    /// payouts cannot exceed custody.
    function _applyFills(
        uint32 epoch,
        Cand[] memory c,
        Pots memory p
    ) private returns (uint256 settledCount) {
        // Remaining pot on each side. Each payout is deducted, and the last
        // order can never be paid more than what is actually left — so the sum
        // of payouts cannot exceed custody even if every division rounded
        // against us.
        uint256 left1 = p.pot1;
        uint256 left0 = p.pot0;

        for (uint256 i; i < c.length; ++i) {
            if (!c[i].live || c[i].grossFilled == 0) continue;

            uint128 grossFilled = c[i].grossFilled;
            uint256 netFilled = c[i].netFilled;

            // A pro-rata share of the pot IS the uniform price: every order
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

    /// @dev In exact arithmetic the two sides' implied prices are equal;
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

        if (diff * 1_000_000 > scale * I4_TOLERANCE_PPM) revert KesselErrors.NonUniformClearingPrice();
    }

    /// @dev Route `f_slow` to LPs, with PRD §6.2's mandatory
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
    ///.
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
    /// moving together.
    function _absorbStray(
        Currency c
    ) private returns (uint256 amount) {
        amount = c.balanceOfSelf();
        if (amount == 0) return 0;
        c.settle(poolManager, address(this), amount, false);
        poolManager.mint(address(this), c.toId(), amount);
    }

    // ==================================================================
    // Redemption (pull model)
    // ==================================================================

    /// @notice Collect an order's settled output, and its refund if expired.
    ///
    /// @dev Permissionless in caller, fixed in destination: anyone may pay the
    /// gas, but the output always goes to the recorded trader. That lets a
    /// third party unstick a trader who never returns (PRD §11 case 5) while
    /// creating no way to redirect funds.
    ///
    /// There is deliberately no `cancel`. The expiry refund is not
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
    /// native ETH — `poolManager.take` pays it with a bare `call` — and native
    /// ETH is refused only as Slow-Lane *input*, so a `oneForZero` order on
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

        // settled -> redeemed happens exactly once.
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
    // Settlement gates
    // ==================================================================

    /// @dev Close a batch to new arrivals. Without this, an order submitted
    /// after this epoch became settlement-eligible would inherit the epoch's
    /// age and could be cleared in the very next settlement -- approximating
    /// submission-time pricing. It also makes `epochExpiry`
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
    /// settlement: an order cannot be refunded for having rested too long
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

    /// @dev The liveness bound. Past this point a batch is moved out of the way
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

    /// @dev The size floor stops repeated tiny forced settlements; the
    /// `absoluteMaxDelay` escape stops that floor from silently stranding a
    /// lone order. This is why liveness is tested against `absoluteMaxDelay`
    /// and not `maxDelay`.
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

    /// @dev Denominated per currency in that currency's own units — see the
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
        // 0 <= f_slow < f_base, enforced at the only place either can move.
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

    /// @notice Set the size-denominated tax multiplier.
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

    /// @notice Set the residual cap, as a fraction of the analytic
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
    /// badly. That asymmetry is deliberate: the protocol forbids pinning a Slow-Lane
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
    /// quantity conserved against outstanding claims.
    function custodyOf(
        Currency currency
    ) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }
}
