// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Shared types, errors and events for the Kessel hook.
///
/// Kept in one file so the pure libraries (`LaneCodec`, `FastLaneFee`,
/// `Clearing`) and the stateful hook agree on a single vocabulary without any
/// of them importing each other.
///
/// See `docs/PRD.md` for the protocol spec.

/// @notice Which execution contract the trader selected.
enum Lane {
    /// @dev Synchronous, in-block, priced by revealed urgency. Also the
    /// default when `hookData` is empty or unrecognised.
    FAST,
    /// @dev Deferred; escrowed now, cleared later at a settlement-time uniform
    /// price.
    SLOW
}

/// @notice Lifecycle of a Slow-Lane order.
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
/// next epoch.
enum OrderStatus {
    NONE,
    PENDING,
    FILLED,
    REDEEMED,
    REFUNDED
}

/// @notice A Slow-Lane order. This struct *is* the trader's claim.
///
/// @dev Non-transferability holds structurally: there is no transfer function,
/// no approval and no operator on this record, and it is keyed by an id the
/// trader cannot reassign. It is a distinct object from the hook's ERC-6909
/// custody balance.
struct Order {
    /// @dev Beneficiary. Always the destination of `redeem`, regardless of who
    /// calls it. Decoded from `hookData` because v4 passes the router, not the
    /// trader, as `sender`.
    address trader;
    /// @dev True if the trader is selling currency0 for currency1.
    bool zeroForOne;
    /// @dev Block at or after which the block-age half of the expiry test is
    /// satisfied. Stamped once, at intake, from the `maxDelay` in force then.
    ///
    /// A stored stamp rather than a value recomputed from the live `maxDelay`:
    /// recomputing let a governance *increase* of `maxDelay` retroactively
    /// un-expire an order that `_rollUnfilled` had already dropped from every
    /// epoch index, leaving it neither fillable nor redeemable. A stamp taken
    /// at intake can only move an order towards being refundable.
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
    /// A FLOOR for a `zeroForOne` order, a CEILING for `oneForZero`. Derived
    /// from the trader's `minOut`, which is what makes the downside bound exact
    /// rather than a post-hoc check.
    uint160 limitPriceX96;
    /// @dev Epoch the order was first placed into.
    uint32 epochSubmitted;
    /// @dev Last epoch in which this order may still be filled. After this, the
    /// remaining input is refundable less `expiryForfeitBps`.
    uint32 epochExpiry;
    OrderStatus status;
}

/// @notice Per-epoch settlement record.
struct Epoch {
    /// @dev Block in which this epoch received its first order. Batch age, and
    /// therefore both settlement gates, are measured from here.
    uint64 openedAtBlock;
    /// @dev Uniform clearing price of the settlement that (last) touched this
    /// epoch, Q96, currency1-per-currency0. Retained for analytics; payouts are
    /// computed from the pots below, not from this.
    uint160 clearingPriceX96;
    /// @dev Total *filled* net-of-fee input per side in this settlement. A
    /// side's payout is its pro-rata share of the matching pot, which is
    /// exactly the uniform price and is exactly solvent by construction.
    uint128 filledNetIn0;
    uint128 filledNetIn1;
    /// @dev Pot of currency1 owed to the currency0-sellers.
    uint128 pot1;
    /// @dev Pot of currency0 owed to the currency1-sellers.
    uint128 pot0;
    /// @dev True once this epoch has been settled at least once. Guards
    /// double-settlement of the same epoch.
    bool settled;
}

/// @notice Errors. Every one of these is a deliberate, documented refusal.
library KesselErrors {
    /// @dev Slow Lane is exact-input only — a hard v4 constraint on the async
    /// pattern.
    error SlowLaneRequiresExactInput();
    /// @dev Native ETH is rejected as Slow-Lane input. Raised before any
    /// custody is taken, so it cannot strand funds.
    error NativeEthNotSupportedInSlowLane();
    /// @dev The lane byte said SLOW but the trailing parameters were missing or
    /// the wrong length. Deliberately NOT defaulted to FAST: silently executing
    /// an intended-to-be-deferred order immediately, at the higher fee, is far
    /// worse than a revert.
    error MalformedSlowOrder();
    /// @dev A Slow-Lane order must state a non-zero `minOut`; there is no safe
    /// default limit price.
    error MinOutRequired();
    error AmountTooLarge();
    error ExpiryOutOfRange();
    /// @dev Below the Slow Lane's minimum order size for this direction. Raised
    /// before any custody is taken, so it cannot strand funds.
    error OrderBelowMinimum();
    /// @dev The warehoused-exposure cap for this direction would be breached.
    /// Denominated in input-token units per currency, because the protocol
    /// forbids the oracle a common numeraire would need.
    error WarehouseCapExceeded();

    error OrderNotFound();
    error NothingToRedeem();
    /// @dev An order may leave PENDING exactly once.
    error AlreadyFinalised();
    error NotYetExpired();

    error NotGovernance();
    error ParameterOutOfBounds();
    /// @dev `0 <= f_slow < f_base` must hold at all times.
    error SlowFeeBoundViolated();
    error Paused();

    error NotPoolManager();
    error UnknownPool();
    /// @dev Settlement was requested but its gate (age, or age+size) is not
    /// open.
    error SettlementNotDue();
    error NothingToSettle();
    /// @dev Slow-Lane intake was reached while a settlement or a redemption
    /// payout was still in flight. Only reachable by reentrancy, so this is a
    /// refusal of an attack, not of a user.
    error SettlementInProgress();
    /// @dev The filler delivered less than the curve would have paid for the
    /// same input. The whole settlement unwinds.
    error FillerUnderDelivered();
    /// @dev The proposed filler is the hook, the PoolManager, or the
    /// beneficiary of an order in the batch being filled.
    error InvalidFiller();
    /// @dev The filler path does not carry native currency. A native `take`
    /// hands control to the recipient with a bare `call`, and the filler path
    /// already hands control to an untrusted contract holding the batch's
    /// input. Native pools settle against the curve as they always did.
    error FillerPathRequiresERC20();
    /// @dev The price the batch actually cleared at does not meet the limit of
    /// an order this settlement was about to fill. The settlement unwinds
    /// rather than filling through a stated limit.
    error LimitPriceBreached();
    /// @dev The two sides of a two-sided batch did not clear at the same price
    /// beyond integer-rounding tolerance. Never expected; the settlement
    /// unwinds rather than distributing at two prices.
    error NonUniformClearingPrice();
    /// @dev `_rollUnfilled` was reached without its epoch having been closed
    /// first. Rolling into the epoch about to be deleted would strand every
    /// order in it, so this is checked rather than assumed.
    error EpochNotClosed();
}

/// @notice Events. Sized so an analyst can reconstruct the economic claims
/// off-chain — in particular, who paid the urgency premium and how much of it
/// reached LPs.
library KesselEvents {
    /// @dev `premiumToLPs` is the portion of `feeCharged` above `f_base`, i.e.
    /// the recaptured urgency premium.
    event FastSwap(
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 priorityFeePerGas,
        uint24 feeCharged,
        uint24 premiumToLPs
    );
    /// @dev The datum that demonstrates lane separation.
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

    /// @dev Emitted when `donate()` could not be used because no liquidity was
    /// in range, and the fee was accrued to the hook-held LP-claimable balance
    /// instead.
    event RecaptureDeferred(address indexed currency, uint256 amount);
    event RecaptureDonated(uint256 amount0, uint256 amount1);

    /// @dev Piggyback settlement runs inside a `try`, so a batch that cannot
    /// clear never takes the carrying Fast-Lane swap down with it. That makes a
    /// persistently failing settlement invisible on chain unless it says so,
    /// which is why this exists: monitoring watches for a batch that keeps
    /// announcing skips, and `forceSettle` surfaces the actual revert reason.
    event SettlementSkipped(uint32 indexed epoch);

    /// @dev `curveFloorOut` is what the pool was predicted to pay for the same
    /// input and `actualOut` is what the filler delivered; the difference goes
    /// to the traders in the batch. Emitted alongside `SlowBatchSettled`, never
    /// instead of it.
    event SlowBatchFilledExternally(
        uint32 indexed epoch, address indexed filler, uint256 amountIn, uint256 curveFloorOut, uint256 actualOut
    );

    event ParameterUpdated(bytes32 indexed param, uint256 oldValue, uint256 newValue);
    event PausedSet(bool paused);
}
