// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KesselErrors, Lane} from "../KesselTypes.sol";

library LaneCodec {
    uint256 internal constant SLOW_DATA_LENGTH = 1 + 32 * 3;

    function decode(
        bytes calldata hookData,
        address sender
    ) internal pure returns (Lane lane, address trader, uint128 minOut, uint32 expiryEpochs) {
        if (hookData.length == 0) return (Lane.FAST, address(0), 0, 0);

        uint8 laneByte = uint8(hookData[0]);

        if (laneByte == uint8(Lane.SLOW)) {
            if (hookData.length != SLOW_DATA_LENGTH) revert KesselErrors.MalformedSlowOrder();
            (trader, minOut, expiryEpochs) = abi.decode(hookData[1:], (address, uint128, uint32));

            if (trader == address(0)) trader = sender;

            return (Lane.SLOW, trader, minOut, expiryEpochs);
        }

        return (Lane.FAST, address(0), 0, 0);
    }

    function encodeFast() internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(Lane.FAST));
    }

    function encodeSlow(
        address trader,
        uint128 minOut,
        uint32 expiryEpochs
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(Lane.SLOW), abi.encode(trader, minOut, expiryEpochs));
    }
}
