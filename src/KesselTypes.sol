// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared types, errors and events for the Kessel hook.
///
/// Kept in one file so that the pure libraries (`LaneCodec`, `FastLaneFee`,
/// `Clearing`) and the stateful hook agree on a single vocabulary without any
/// of them importing each other.
///
/// See `docs/PRD.md` for the protocol spec and `docs/DECISIONS.md` for the
/// resolution of every DD referenced below.

/// @notice Which execution contract the trader selected (PRD §2.2).
enum Lane {
    /// @dev Synchronous, in-block, priced by revealed urgency. Also the
    /// default when `hookData` is empty or unrecognised (DD-1).
    FAST,
    /// @dev Deferred; escrowed now, cleared later at a settlement-time uniform
    /// price (PRD §2.4).
    SLOW
}

/// @notice Lifecycle of a Slow-Lane order (PRD §5.1, invariant I3).
///
/// @dev The state machine is deliberately small:
///
///   PENDING --(fully filled)--> FILLED --(redeem)--> REDEEMED
///      |                           ^
///      |                           | (partial fill leaves it PENDING)
///      +--(expired, then redeem)---+--> REFUNDED
///
/// A partial fill does NOT change the status: the order stays PENDING with a
/// reduced `amountInRemaining` and an increased `owedOut`, and rolls into the
/// next epoch (DD-11).
enum OrderStatus {
    NONE,
    PENDING,
    FILLED,
    REDEEMED,
    REFUNDED
}

/// @notice A Slow-Lane order. This struct *is* the trader's claim (DD-15a).
///
/// @dev Non-transferability (a PRD §5.1 requirement, not a design choice) holds
/// structurally: there is no transfer function, no approval and no operator on
/// this record, and it is keyed by an id the trader cannot reassign. It is a
/// distinct object from the hook's ERC-6909 custody balance, which is what I2
/// requires (PRD §5.1).
struct Order {
    /// @dev Beneficiary. Always the destination of `redeem`, regardless of who
    /// calls it (DD-15). Decoded from `hookData` because v4 passes the router,
    /// not the trader, as `sender` (reconnaissance finding A).
    address trader;
    /// @dev True if the trader is selling currency0 for currency1.
    bool zeroForOne;
    /// @dev Block at or after which the block-age half of the expiry test is
    /// satisfied. Stamped once, at intake, from the `maxDelay` in force then.
    ///
    /// Deliberately a stored stamp rather than a quantity recomputed from the
    /// live `maxDelay` (SR-10). Recomputing let a governance *increase* of
    /// `maxDelay` retroactively un-expire an order that `_rollUnfilled` had
    /// already dropped from every epoch index -- leaving it unfillable (in no
    /// index) and unredeemable (no longer expired) until the raised floor
    /// elapsed. A stamp taken at intake can only ever move an order towards
    /// being refundable, never away from it.
    uint64 expiryBlock;
    /// @dev Gross input still unfilled. Decreases as the order is partially
    /// filled across epochs.
    uint128 amountInRemaining;
    /// @dev Output accumulated so far across one or more partial fills, net of
    /// `f_slow`. Paid out by `redeem`.
    uint128 owedOut;
    /// @dev Limit price in Q96, expressed as currency1-per-currency0 in both
    /// directions so a single batch price can be compared against it.
    ///
    /// For a `zeroForOne` order this is a FLOOR (fill only if the effective
    /// price is at least this). For a `oneForZero` order it is a CEILING.
    /// Derived from the trader's `minOut`; this is what makes I8 exact rather
    /// than a post-hoc check (DD-11).
    uint160 limitPriceX96;
    /// @dev Epoch the order was first placed into.
    uint32 epochSubmitted;
    /// @dev Last epoch in which this order may still be filled. After this,
    /// the remaining input is refundable less `expiryForfeitBps` (DD-9/DD-11).
    uint32 epochExpiry;
    OrderStatus status;
}

/// @notice Per-epoch settlement record (PRD §5.2).
struct Epoch {
    /// @dev Block in which this epoch received its first order. Batch age, and
    /// therefore both settlement gates (DD-13), are measured from here.
    uint64 openedAtBlock;
    /// @dev Uniform clearing price of the settlement that (last) touched this
    /// epoch, Q96, currency1-per-currency0. Retained for analytics and for the
    /// I4 assertion; payouts are computed from the pots below, not from this.
    uint160 clearingPriceX96;
    /// @dev Total *filled* net-of-fee input per side in this settlement, and
    /// the pot of output tokens available to that side. A side's payout is its
    /// pro-rata share of the pot, which is exactly the uniform price (I4) and
    /// is exactly solvent by construction (I2).
    uint128 filledNetIn0;
    uint128 filledNetIn1;
    /// @dev Pot of currency1 owed to the currency0-sellers.
    uint128 pot1;
    /// @dev Pot of currency0 owed to the currency1-sellers.
    uint128 pot0;
    /// @dev True once this epoch has been settled at least once. Guards
    /// double-settlement of the same epoch (I3, PRD §11 case 10).
    bool settled;
}

/// @notice Errors. Every one of these is a deliberate, documented refusal.
library KesselErrors {
    /// @dev Slow Lane is exact-input only — a hard v4 constraint on the async
    /// pattern, restated as a protocol requirement in PRD §3.2.
    error SlowLaneRequiresExactInput();
    /// @dev DD-14: native ETH is rejected as Slow-Lane input. Raised before any
    /// custody is taken, so it cannot strand funds (PRD §11 case 14).
    error NativeEthNotSupportedInSlowLane();
    /// @dev The lane byte said SLOW but the trailing parameters were missing or
    /// the wrong length. Deliberately NOT defaulted to FAST: silently executing
    /// an intended-to-be-deferred order immediately, at the higher fee, is a
    /// far worse failure than a revert. DD-1's default applies to *empty* and
    /// *unrecognised-lane* `hookData`, not to a malformed SLOW payload.
    error MalformedSlowOrder();
    /// @dev A Slow-Lane order must state a non-zero `minOut`; there is no safe
    /// default limit price (I8).
    error MinOutRequired();
    error AmountTooLarge();
    error ExpiryOutOfRange();
    /// @dev SR-12: below the Slow Lane's minimum order size for this direction.
    /// Raised before any custody is taken, so it cannot strand funds.
    error OrderBelowMinimum();
    /// @dev I9: the warehoused-exposure cap for this direction would be
    /// breached. Denominated in input-token units per currency, because §9
    /// forbids the oracle a common numeraire would need (reconnaissance
    /// finding C).
    error WarehouseCapExceeded();

    error OrderNotFound();
    error NothingToRedeem();
    /// @dev I3: an order may leave PENDING exactly once.
    error AlreadyFinalised();
    error NotYetExpired();

    error NotGovernance();
    error ParameterOutOfBounds();
    /// @dev I10: `0 <= f_slow < f_base` must hold at all times.
    error SlowFeeBoundViolated();
    error Paused();

    error NotPoolManager();
    error UnknownPool();
    /// @dev Settlement was requested but its gate (age, or age+size) is not
    /// open. See DD-13.
    error SettlementNotDue();
    error NothingToSettle();
    /// @dev Slow-Lane intake was reached while a settlement or a redemption
    /// payout was still in flight. Only reachable by reentrancy — no ordinary
    /// caller can be inside the hook's own `unlock` — so this is a refusal of
    /// an attack, not of a user.
    error SettlementInProgress();
    /// @dev Shape B: the filler delivered less than the curve would have paid
    /// for the same input. The whole settlement unwinds.
    error FillerUnderDelivered();
    /// @dev Shape B: the proposed filler is the hook, the PoolManager, or the
    /// beneficiary of an order in the batch being filled.
    error InvalidFiller();
    /// @dev Shape B: the filler path does not carry native currency. A native
    /// `take` hands control to the recipient with a bare `call`, and the filler
    /// path already hands control to an untrusted contract holding the batch's
    /// input — the combination is not worth the surface. Native pools settle
    /// against the curve as they always did.
    error FillerPathRequiresERC20();
    /// @dev SR-8: the price the batch actually cleared at does not meet the
    /// limit of an order this settlement was about to fill. I8 is a hard
    /// bound, so the settlement unwinds rather than filling through it.
    error LimitPriceBreached();
    /// @dev `_rollUnfilled` was reached without its epoch having been closed
    /// first. Rolling into the epoch about to be deleted would strand every
    /// order in it, so this is checked rather than assumed.
    error EpochNotClosed();
}

/// @notice Events (PRD §14). Sized so an analyst can reconstruct the economic
/// claims off-chain — in particular, who paid the urgency premium and how much
/// of it reached LPs.
library KesselEvents {
    /// @dev PRD §14. `premiumToLPs` is the portion of `feeCharged` above
    /// `f_base`, i.e. the recaptured urgency premium.
    event FastSwap(
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 priorityFeePerGas,
        uint24 feeCharged,
        uint24 premiumToLPs
    );
    /// @dev PRD §14 `LaneChosen` — the datum that demonstrates separation (the
    /// single-crossing assumption A1) in the demo.
    event LaneChosen(address indexed trader, Lane lane);

    event SlowOrderSubmitted(
        uint256 indexed orderId,
        address indexed trader,
        uint32 indexed epoch,
        bool zeroForOne,
        uint128 amountIn,
        uint128 minOut,
        uint32 epochExpiry
    );
    event SlowBatchSettled(
        uint32 indexed epoch,
        uint160 clearingPriceX96,
        uint256 netInput0,
        uint256 netInput1,
        uint256 cowMatchedAmount,
        uint256 fillRatioX96,
        uint256 feeToLPs0,
        uint256 feeToLPs1,
        uint256 ordersSettled
    );
    event SlowOrderFilled(uint256 indexed orderId, uint32 indexed epoch, uint128 filledIn, uint128 amountOut);
    event SlowOrderRedeemed(uint256 indexed orderId, address indexed trader, uint128 amountOut);
    event SlowOrderRefunded(uint256 indexed orderId, address indexed trader, uint128 amountRefunded, uint128 forfeited);

    /// @dev PRD §6.2: emitted when `donate()` could not be used because no
    /// liquidity was in range, and the fee was accrued to the hook-held
    /// LP-claimable balance instead.
    event RecaptureDeferred(address indexed currency, uint256 amount);
    event RecaptureDonated(uint256 amount0, uint256 amount1);

    /// @dev Piggyback settlement is deliberately non-fatal: it runs inside a
    /// `try` so a batch that cannot clear never takes the carrying Fast-Lane
    /// swap down with it. That makes a persistently failing settlement
    /// *invisible* on chain unless it says so, which is why this exists —
    /// monitoring watches for a batch that keeps announcing skips instead of
    /// clearing, and `forceSettle` surfaces the actual revert reason.
    event SettlementSkipped(uint32 indexed epoch);

    /// @dev Shape B. `curveFloorOut` is what the pool was predicted to pay for
    /// the same input and `actualOut` is what the filler delivered; the
    /// difference is the improvement, and it goes to the traders in the batch.
    /// Emitted alongside `SlowBatchSettled`, never instead of it, so an analyst
    /// can measure how much of the Slow Lane's execution quality is coming from
    /// competition rather than from the curve.
    event SlowBatchFilledExternally(
        uint32 indexed epoch, address indexed filler, uint256 amountIn, uint256 curveFloorOut, uint256 actualOut
    );

    event ParameterUpdated(bytes32 indexed param, uint256 oldValue, uint256 newValue);
    event PausedSet(bool paused);
}
