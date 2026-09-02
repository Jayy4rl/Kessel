// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KesselErrors, Lane} from "../KesselTypes.sol";

/// @notice Encoding and decoding of the per-swap `hookData` that selects a lane.
///
/// Wire format:
///
///   (empty)                                        -> FAST
///   0x00                                           -> FAST
///   0x01 || abi.encode(address,uint128,uint32)     -> SLOW
///   0xNN (anything else)                           -> FAST
///
/// Two asymmetries in the failure handling are deliberate:
///
/// 1. An *unrecognised* lane byte falls through to FAST: an unaware caller is
///    demanding an immediate fill by construction, and reverting would break
///    every router that does not know about this hook.
/// 2. A *recognised* SLOW byte with a malformed tail REVERTS. Defaulting it to
///    FAST would execute, immediately and at the higher fee, an order whose
///    author explicitly asked for deferral.
library LaneCodec {
    /// @dev Length of the SLOW payload: one lane byte plus three abi words.
    uint256 internal constant SLOW_DATA_LENGTH = 1 + 32 * 3;

    /// @notice Decode `hookData` into a lane and, for SLOW, its parameters.
    /// @param sender The `sender` v4 passed to `beforeSwap`. Used as the trader
    /// only when the payload leaves the trader field zero.
    /// @return lane The selected lane.
    /// @return trader Beneficiary of a Slow-Lane order (zero for FAST).
    /// @return minOut Trader's minimum acceptable output for the whole input.
    /// @return expiryEpochs How many epochs the order may rest before its
    /// remaining input becomes refundable.
    function decode(
        bytes calldata hookData,
        address sender
    ) internal pure returns (Lane lane, address trader, uint128 minOut, uint32 expiryEpochs) {
        // Empty hookData is the aggregator / unaware-caller case.
        if (hookData.length == 0) return (Lane.FAST, address(0), 0, 0);

        uint8 laneByte = uint8(hookData[0]);

        if (laneByte == uint8(Lane.SLOW)) {
            if (hookData.length != SLOW_DATA_LENGTH) revert KesselErrors.MalformedSlowOrder();
            (trader, minOut, expiryEpochs) = abi.decode(hookData[1:], (address, uint128, uint32));

            // v4 hands the hook the *router* as `sender`, never the trader, so
            // the trader travels in the payload. Falling back to `sender` keeps
            // direct, router-less callers working.
            if (trader == address(0)) trader = sender;

            return (Lane.SLOW, trader, minOut, expiryEpochs);
        }

        // FAST, or an unrecognised value.
        return (Lane.FAST, address(0), 0, 0);
    }

    /// @notice Build `hookData` selecting the Fast Lane.
    /// @dev Equivalent to passing empty bytes; provided so integrators can be
    /// explicit rather than relying on the default.
    function encodeFast() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(Lane.FAST));
    }

    /// @notice Build `hookData` selecting the Slow Lane.
    /// @param trader Beneficiary; pass `address(0)` to use the caller.
    /// @param minOut Minimum acceptable output for the full input. Becomes the
    /// order's limit price, so it is a price bound rather than a one-shot
    /// slippage check.
    /// @param expiryEpochs Epochs the order may rest before becoming refundable.
    function encodeSlow(
        address trader,
        uint128 minOut,
        uint32 expiryEpochs
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(Lane.SLOW), abi.encode(trader, minOut, expiryEpochs));
    }
}
