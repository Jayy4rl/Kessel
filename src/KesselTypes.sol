// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

enum Lane {
    FAST,
    SLOW
}

enum OrderStatus {
    NONE,
    PENDING,
    FILLED,
    REDEEMED,
    REFUNDED
}

struct Order {
    address trader;
    bool zeroForOne;
    uint64 expiryBlock;
    uint128 amountInRemaining;
   uint128 owedOut;
    uint160 limitPriceX96;
    uint32 epochSubmitted;
    uint32 epochExpiry;
    OrderStatus status;
}

struct Epoch {
   uint64 openedAtBlock;
    uint160 clearingPriceX96;
    uint128 filledNetIn0;
    uint128 filledNetIn1;
    uint128 pot1;
    uint128 pot0;
    bool settled;
}

library KesselErrors {
    error SlowLaneRequiresExactInput();
    error NativeEthNotSupportedInSlowLane();
    error MalformedSlowOrder();
     error MinOutRequired();
    error AmountTooLarge();
    error ExpiryOutOfRange();
    error OrderBelowMinimum();
    error WarehouseCapExceeded();

    error OrderNotFound();
    error NothingToRedeem();
    error AlreadyFinalised();
    error NotYetExpired();

    error NotGovernance();
    error ParameterOutOfBounds();
    error SlowFeeBoundViolated();
    error Paused();

    error NotPoolManager();
    error UnknownPool();
    
    error SettlementNotDue();
    error NothingToSettle();
    error SettlementInProgress();
    error FillerUnderDelivered();
    error InvalidFiller();
    error FillerPathRequiresERC20();
    error LimitPriceBreached();
     error NonUniformClearingPrice();
     error EpochNotClosed();
}

library KesselEvents {
   event FastSwap(
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 priorityFeePerGas,
        uint24 feeCharged,
        uint24 premiumToLPs
    );
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

    event RecaptureDeferred(address indexed currency, uint256 amount);
    event RecaptureDonated(uint256 amount0, uint256 amount1);

     event SettlementSkipped(uint32 indexed epoch);

     event SlowBatchFilledExternally(
        uint32 indexed epoch, address indexed filler, uint256 amountIn, uint256 curveFloorOut, uint256 actualOut
    );

    event ParameterUpdated(bytes32 indexed param, uint256 oldValue, uint256 newValue);
    event PausedSet(bool paused);
}
