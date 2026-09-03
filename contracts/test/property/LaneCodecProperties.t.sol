// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {KesselErrors, Lane} from "../../src/KesselTypes.sol";
import {LaneCodec} from "../../src/lanes/LaneCodec.sol";

/// @notice The lane selector (DD-1) and the trader-identity fallback
/// (reconnaissance finding A).
///
/// `LaneCodec` is the only thing standing between a caller's bytes and which
/// execution contract they get, and it is total by design: every possible
/// `hookData`, including bytes nobody meant to send, must decode to a lane
/// rather than revert. That totality is a policy decision (DD-1), so it is
/// tested as one.
contract LaneCodecPropertiesTest is Test {
    /// @dev `decode` takes `bytes calldata`, so it is reached through an
    /// external call rather than directly.
    function decodeExternal(
        bytes calldata hookData,
        address sender
    ) external pure returns (Lane lane, address trader, uint128 minOut, uint32 expiryEpochs) {
        return LaneCodec.decode(hookData, sender);
    }

    // ======================================================================
    // DD-1 — the default lane
    // ======================================================================

    /// @notice Empty `hookData` selects the Fast Lane.
    ///
    /// @dev This is DD-1's resolution and it is a *safety* choice, not a
    /// convenience one: an aggregator that knows nothing about this hook is
    /// demanding immediate execution by construction, and routing it to the
    /// Slow Lane would escrow its input against a claim it has no code to
    /// redeem.
    function test_DD1_emptyHookDataIsFast() public view {
        (Lane lane, address trader, uint128 minOut, uint32 expiry) = this.decodeExternal("", address(0xBEEF));
        assertEq(uint256(lane), uint256(Lane.FAST), "empty hookData must default to FAST");
        assertEq(trader, address(0), "FAST carries no trader");
        assertEq(minOut, 0, "FAST carries no limit");
        assertEq(expiry, 0, "FAST carries no expiry");
    }

    /// @notice An unrecognised lane byte also selects the Fast Lane, rather
    /// than reverting.
    ///
    /// @dev Same reasoning as the empty case, and the fuzz range deliberately
    /// includes every byte that is not `SLOW`. A revert here would make any
    /// future encoding change a liveness break for callers that had not
    /// upgraded.
    function testFuzz_DD1_anUnrecognisedLaneByteIsFast(
        uint8 laneByte
    ) public view {
        vm.assume(laneByte != uint8(Lane.SLOW));

        (Lane lane,,,) = this.decodeExternal(abi.encodePacked(laneByte), address(0xBEEF));
        assertEq(uint256(lane), uint256(Lane.FAST), "an unknown lane byte must fall back to FAST");
    }

    /// @notice The explicit Fast-Lane encoding and the empty one agree.
    function test_encodeFastIsEquivalentToEmptyData() public view {
        (Lane explicitLane,,,) = this.decodeExternal(LaneCodec.encodeFast(), address(0xBEEF));
        (Lane implicitLane,,,) = this.decodeExternal("", address(0xBEEF));
        assertEq(uint256(explicitLane), uint256(implicitLane), "explicit FAST must match the default");
    }

    // ======================================================================
    // Slow-Lane payloads
    // ======================================================================

    /// @notice A well-formed Slow-Lane payload round-trips exactly.
    function testFuzz_slowPayloadRoundTrips(
        address trader,
        uint128 minOut,
        uint32 expiryEpochs
    ) public view {
        vm.assume(trader != address(0));

        (Lane lane, address gotTrader, uint128 gotMinOut, uint32 gotExpiry) =
            this.decodeExternal(LaneCodec.encodeSlow(trader, minOut, expiryEpochs), address(0xBEEF));

        assertEq(uint256(lane), uint256(Lane.SLOW), "lane lost in the round trip");
        assertEq(gotTrader, trader, "trader lost in the round trip");
        assertEq(gotMinOut, minOut, "minOut lost in the round trip");
        assertEq(gotExpiry, expiryEpochs, "expiry lost in the round trip");
    }

    /// @notice A zero trader field falls back to the caller v4 reported.
    ///
    /// @dev v4 hands the hook the *router* as `sender`, never the trader, so
    /// the trader is normally carried in the payload. The fallback keeps
    /// direct, router-less callers working — and it is the one path on which
    /// the beneficiary of a Slow-Lane order is decided by something other than
    /// the payload, so it is worth being explicit about: a router that forgets
    /// to encode the trader makes *itself* the beneficiary. That is the
    /// intended behaviour (a trader already trusts their router by approving
    /// it), but it is not a behaviour anyone should discover by accident.
    function test_aZeroTraderFallsBackToTheReportedSender() public view {
        address sender = address(0xBEEF);
        (, address trader,,) = this.decodeExternal(LaneCodec.encodeSlow(address(0), 1e18, 4), sender);
        assertEq(trader, sender, "a zero trader field must fall back to the sender");
    }

    /// @notice A Slow-Lane payload of the wrong length is refused outright.
    ///
    /// @dev The one place the codec does revert, and deliberately: a malformed
    /// Slow payload cannot be defaulted the way a malformed *lane byte* can.
    /// Guessing at a trader, a limit price or an expiry would escrow real funds
    /// against terms nobody stated.
    function test_aMalformedSlowPayloadIsRefused() public {
        vm.expectRevert(KesselErrors.MalformedSlowOrder.selector);
        this.decodeExternal(abi.encodePacked(uint8(Lane.SLOW)), address(0xBEEF));

        vm.expectRevert(KesselErrors.MalformedSlowOrder.selector);
        this.decodeExternal(abi.encodePacked(uint8(Lane.SLOW), uint256(1)), address(0xBEEF));

        // One byte too long is as malformed as one byte too short.
        vm.expectRevert(KesselErrors.MalformedSlowOrder.selector);
        this.decodeExternal(
            abi.encodePacked(LaneCodec.encodeSlow(address(0xA11CE), 1e18, 4), uint8(0)), address(0xBEEF)
        );
    }

    /// @notice Trailing bytes cannot smuggle a Slow order past the length
    /// check, and cannot turn a Fast payload into a Slow one.
    function testFuzz_lengthIsTheOnlyThingThatMakesAPayloadSlow(
        bytes calldata junk
    ) public view {
        vm.assume(junk.length > 0);
        vm.assume(uint8(junk[0]) != uint8(Lane.SLOW));

        (Lane lane,,,) = this.decodeExternal(junk, address(0xBEEF));
        assertEq(uint256(lane), uint256(Lane.FAST), "only a SLOW lane byte may select the Slow Lane");
    }
}
