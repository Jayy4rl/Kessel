// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {KesselErrors} from "../../src/KesselTypes.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice "Governance cannot strand funds", attacked rather than asserted.
///
/// The claim is load-bearing and, until now, rested on reading the setters:
/// every parameter is bounded, and `setPaused` deliberately does not block
/// `redeem`. That is the right design, but it is exactly the shape a fuzzer can
/// test — drive every knob to a random reachable value, in a random order, and
/// then check a trader who is owed output can still collect it.
///
/// The contract is immutable and has no recovery path, so a parameter
/// combination that strands a claim would be permanent. Reading the setters
/// proves each one is bounded in isolation; this checks them in combination.
contract GovernanceReachabilityTest is KesselTestBase {
    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(alice, 100_000 ether);
        _fundAndApprove(bob, 100_000 ether);
    }

    /// @dev Place a Slow order and carry it, so the trader is genuinely owed
    /// output before governance starts moving.
    function _settledOrder() internal returns (uint256 id) {
        vm.prank(alice);
        id = _slowOrder(alice, true, 0.01 ether, 1, 8);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        assertGt(_order(id).owedOut, 0, "setup: the order should be owed output");
    }

    /// @dev Drive every governance parameter to a random value inside its
    /// bounds. Anything the contract would reject is bounded into range first,
    /// so this explores the reachable configuration space rather than the
    /// rejected one.
    function _randomiseAllParameters(
        uint256 seed,
        bool pause
    ) internal {
        uint24 fBase = uint24(bound(uint256(keccak256(abi.encode(seed, "fBase"))), 100, 100_000));
        uint24 fSlow = uint24(bound(uint256(keccak256(abi.encode(seed, "fSlow"))), 0, uint256(fBase) - 1));

        uint32 minAge = uint32(bound(uint256(keccak256(abi.encode(seed, "minAge"))), 1, 300));
        uint32 maxDelay = uint32(bound(uint256(keccak256(abi.encode(seed, "maxDelay"))), uint256(minAge) + 1, 100_000));
        uint32 absMax = uint32(bound(uint256(keccak256(abi.encode(seed, "absMax"))), maxDelay, 100_000));
        uint32 minOrders = uint32(bound(uint256(keccak256(abi.encode(seed, "minOrders"))), 1, 32));

        vm.startPrank(governance);
        hook.setFees(fBase, fSlow);
        hook.setK(bound(uint256(keccak256(abi.encode(seed, "k"))), 0, 100_000));
        hook.setKGas(bound(uint256(keccak256(abi.encode(seed, "kGas"))), 0, 10_000_000));
        hook.setCadence(minAge, maxDelay, absMax, minOrders);
        hook.setResidualCapBps(uint16(bound(uint256(keccak256(abi.encode(seed, "cap"))), 500, 10_000)));
        hook.setExpiryForfeitBps(uint16(bound(uint256(keccak256(abi.encode(seed, "forfeit"))), 0, 100)));
        // The two that are unbounded by design, driven to their hostile extreme:
        // a zero warehouse and an enormous order floor both stop NEW orders.
        hook.setWarehouseCaps(uint128(bound(uint256(keccak256(abi.encode(seed, "wh0"))), 0, type(uint128).max)), 0);
        hook.setMinOrderSize(type(uint128).max, type(uint128).max);
        hook.setPaused(pause);
        vm.stopPrank();
    }

    /// @notice No reachable configuration prevents a trader collecting output
    /// they are already owed.
    function testFuzz_noParameterCombinationStrandsSettledOutput(
        uint256 seed,
        bool pause
    ) public {
        uint256 id = _settledOrder();
        uint128 owed = _order(id).owedOut;

        _randomiseAllParameters(seed, pause);

        uint256 before = currency1.balanceOf(alice);
        hook.redeem(id); // permissionless in caller, fixed in destination
        uint256 received = currency1.balanceOf(alice) - before;

        assertEq(received, owed, "the trader did not receive what they were owed");
        assertEq(_order(id).owedOut, 0, "output remained owed after redemption");
    }

    /// @notice Custody still covers obligations after arbitrary parameter
    /// movement.
    function testFuzz_custodyStillCoversObligations(
        uint256 seed,
        bool pause
    ) public {
        _settledOrder();
        _randomiseAllParameters(seed, pause);

        (uint256 c0, uint256 c1) = _custody();
        (uint256 o0, uint256 o1) = _obligations();
        assertGe(c0, o0, "currency0 custody fell below obligations");
        assertGe(c1, o1, "currency1 custody fell below obligations");
    }

    /// @notice Pausing stops new orders but never redemption.
    ///
    /// @dev The distinction the whole immutability posture rests on: governance
    /// may halt the lane, but may not trap a claim inside it.
    function test_pauseHaltsIntakeButNeverRedemption() public {
        uint256 id = _settledOrder();

        vm.prank(governance);
        hook.setPaused(true);

        // New Slow-Lane orders are refused...
        vm.expectRevert();
        vm.prank(bob);
        _slowOrder(bob, true, 0.01 ether, 1, 8);

        // ...but an existing claim is still collectable.
        uint128 owed = _order(id).owedOut;
        uint256 before = currency1.balanceOf(alice);
        hook.redeem(id);
        assertEq(currency1.balanceOf(alice) - before, owed, "a paused hook withheld settled output");
    }

    /// @notice The two refusals that protect governance itself.
    function test_governanceCannotBreakItsOwnInvariants() public {
        vm.startPrank(governance);

        // f_slow must stay strictly below f_base.
        vm.expectRevert(KesselErrors.SlowFeeBoundViolated.selector);
        hook.setFees(3_000, 3_000);

        // Handing authority to the zero address would freeze every parameter
        // forever on a contract with no recovery path.
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setGovernance(address(0));

        vm.stopPrank();
    }
}
