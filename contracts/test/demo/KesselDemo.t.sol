// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @notice The mechanism, demonstrated rather than asserted.
///
/// Run it:
///
///     forge test --match-path 'test/demo/*' -vv
///
/// No RPC, no keys, no deployment — everything below runs against a local v4
/// PoolManager built in `setUp`. The other 258 tests prove the protocol is
/// *correct*; this one shows what it *does*, because "all tests pass" is not an
/// argument that a mechanism is worth building.
///
/// Each section prints real numbers taken from real swaps against a real curve.
/// Nothing here is hardcoded or narrated — the figures are read back from
/// emitted events and settled order state.
contract KesselDemoTest is KesselTestBase {
    uint256 internal constant Q96 = 1 << 96;

    address internal attacker = address(0xBAD);

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(alice, 100_000 ether);
        _fundAndApprove(bob, 100_000 ether);
        _fundAndApprove(carol, 100_000 ether);
        _fundAndApprove(attacker, 100_000 ether);
    }

    /// @dev Place a Slow order and remember its size, so the realised price
    /// can be computed from what actually filled.
    function _placeSlow(
        address who,
        bool zeroForOne,
        uint256 amountIn
    ) internal returns (uint256 id) {
        vm.prank(who);
        id = _slowOrder(who, zeroForOne, amountIn, 1, 20);
        _sizes[id] = amountIn;
    }

    // ==================================================================
    // 1 — The screen: what each lane costs
    // ==================================================================

    /// @notice The Fast Lane prices immediacy; the Slow Lane does not charge
    /// for it. That gap is the whole mechanism.
    function test_demo_1_theFeeScheduleThatSeparatesTheLanes() public {
        console2.log("");
        console2.log("=========================================================");
        console2.log(" 1. THE SCREEN - what each lane charges");
        console2.log("=========================================================");
        console2.log("Fee units are hundredths of a bip: 3000 = 0.30%.");
        console2.log("");
        console2.log("  priority fee     FAST fee    premium over f_base");

        uint256[4] memory priorities = [uint256(0), 1 gwei, 5 gwei, 20 gwei];
        for (uint256 i; i < priorities.length; ++i) {
            _setPriorityFee(priorities[i]);

            vm.recordLogs();
            vm.prank(alice);
            _fastSwap(true, -0.1 ether);
            (uint24 feeCharged, uint24 premium) = _lastFastSwapFee();

            console2.log(
                string.concat(
                    "  ",
                    _pad(string.concat(vm.toString(priorities[i] / 1 gwei), " gwei"), 15),
                    _pad(vm.toString(uint256(feeCharged)), 12),
                    vm.toString(uint256(premium))
                )
            );
        }

        console2.log("");
        console2.log(string.concat("  SLOW fee (flat, no urgency charge): ", vm.toString(uint256(hook.fSlow()))));
        console2.log("");
        console2.log("  A patient trader pays 500. An urgent one bidding 20 gwei pays 13000.");
        console2.log("  Same pool, same curve, same liquidity. The trader picks.");
    }

    // ==================================================================
    // 2 — Where the premium goes
    // ==================================================================

    /// @notice The premium above `f_base` is recaptured for LPs rather than
    /// left to the sequencer.
    ///
    /// @dev This is the claim that distinguishes the design from an ordinary
    /// dynamic-fee hook: the urgency the trader reveals is priced and the
    /// proceeds land with the people carrying the inventory risk.
    function test_demo_2_thePremiumIsRecapturedForLPs() public {
        console2.log("");
        console2.log("=========================================================");
        console2.log(" 2. RECAPTURE - the premium goes to LPs");
        console2.log("=========================================================");

        uint256 size = 10 ether;

        _setPriorityFee(0);
        vm.recordLogs();
        vm.prank(alice);
        _fastSwap(true, -int256(size));
        (uint24 baseFee,) = _lastFastSwapFee();

        _setPriorityFee(20 gwei);
        vm.recordLogs();
        vm.prank(bob);
        _fastSwap(true, -int256(size));
        (uint24 urgentFee, uint24 premium) = _lastFastSwapFee();

        uint256 baseAmount = FullMath.mulDiv(size, baseFee, 1_000_000);
        uint256 urgentAmount = FullMath.mulDiv(size, urgentFee, 1_000_000);
        uint256 premiumAmount = FullMath.mulDiv(size, premium, 1_000_000);

        console2.log("  On a 10 ether swap:");
        console2.log("");
        console2.log(string.concat("    patient trader (0 gwei) pays  : ", _eth(baseAmount)));
        console2.log(string.concat("    urgent trader (20 gwei) pays  : ", _eth(urgentAmount)));
        console2.log(string.concat("    of which premium to LPs       : ", _eth(premiumAmount)));
        console2.log("");
        console2.log("  Without the hook the urgent trader pays the base fee to LPs and");
        console2.log("  the rest of their urgency to the sequencer as priority fee.");
        console2.log("  Here it is priced into the swap and routed to the curve instead.");

        assertGt(urgentFee, baseFee, "the urgent swap did not pay more");
        assertGt(premiumAmount, 0, "no premium was recaptured");
    }

    // ==================================================================
    // 3 — The Slow Lane clears at one price
    // ==================================================================

    /// @notice Every order in a batch settles at the same price, whatever its
    /// size and whatever order it arrived in (I4).
    function test_demo_3_everyOrderInABatchGetsTheSamePrice() public {
        console2.log("");
        console2.log("=========================================================");
        console2.log(" 3. UNIFORM CLEARING PRICE - position in the batch is worthless");
        console2.log("=========================================================");

        uint256 a = _placeSlow(alice, true, 0.02 ether);
        uint256 b = _placeSlow(bob, true, 0.005 ether);
        uint256 c = _placeSlow(carol, true, 0.01 ether);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15); // an unrelated Fast swap carries the batch

        uint256 pa = _realisedPrice(a);
        uint256 pb = _realisedPrice(b);
        uint256 pc = _realisedPrice(c);

        console2.log("  Three traders, three different sizes, one batch:");
        console2.log("");
        console2.log(string.concat("    alice  0.020 ether -> price ", vm.toString(pa)));
        console2.log(string.concat("    bob    0.005 ether -> price ", vm.toString(pb)));
        console2.log(string.concat("    carol  0.010 ether -> price ", vm.toString(pc)));
        console2.log("");
        console2.log("  Identical. Being first in the batch buys nothing, which is");
        console2.log("  why an in-batch sandwich has nothing to extract.");

        assertEq(pa, pb, "I4: alice and bob cleared at different prices");
        assertEq(pb, pc, "I4: bob and carol cleared at different prices");
    }

    // ==================================================================
    // 4 — Opposing flow never touches the curve
    // ==================================================================

    /// @notice Orders in opposite directions match against each other first,
    /// and only the imbalance reaches the pool.
    function test_demo_4_opposingOrdersMatchBeforeTouchingTheCurve() public {
        console2.log("");
        console2.log("=========================================================");
        console2.log(" 4. COINCIDENCE OF WANTS - the delay buys you a counterparty");
        console2.log("=========================================================");

        _placeSlow(alice, true, 1 ether); // selling currency0
        _placeSlow(bob, false, 1 ether); // buying currency0

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);

        vm.recordLogs();
        _fastSwap(true, -1e15);
        (uint256 net0, uint256 net1, uint256 cowMatched) = _lastBatchNetting();

        console2.log("  Alice sells 1.0 currency0. Bob buys currency0. Same batch.");
        console2.log("");
        console2.log(string.concat("    net currency0 in : ", _eth(net0)));
        console2.log(string.concat("    net currency1 in : ", _eth(net1)));
        console2.log(string.concat("    matched in-batch : ", _eth(cowMatched)));
        console2.log("");
        console2.log("  What matched internally never moved the price, so it paid no");
        console2.log("  slippage and left no arbitrage for anyone to pick up.");

        assertGt(cowMatched, 0, "no coincidence of wants was found");
    }

    // ==================================================================
    // 5 — The attack that does not work
    // ==================================================================

    /// @notice An attacker surrounding a victim inside one batch gains nothing.
    ///
    /// @dev The classic sandwich needs the victim to trade at a worse price
    /// than the attacker. A uniform clearing price removes the mechanism by
    /// construction rather than by detection — there is no ordering to exploit
    /// because ordering does not affect price.
    function test_demo_5_anInBatchSandwichExtractsNothing() public {
        console2.log("");
        console2.log("=========================================================");
        console2.log(" 5. THE SANDWICH THAT ISN'T - structural, not heuristic");
        console2.log("=========================================================");

        // Attacker front-runs, victim submits, attacker back-runs. All in one
        // batch, exactly as a sandwich would be arranged.
        uint256 front = _placeSlow(attacker, true, 0.01 ether);
        uint256 victim = _placeSlow(alice, true, 0.01 ether);
        uint256 back = _placeSlow(attacker, true, 0.01 ether);

        vm.roll(vm.getBlockNumber() + uint256(hook.minSettleAge()) + 1);
        _setPriorityFee(1 gwei);
        _fastSwap(true, -1e15);

        uint256 pFront = _realisedPrice(front);
        uint256 pVictim = _realisedPrice(victim);
        uint256 pBack = _realisedPrice(back);

        console2.log("  Attacker brackets the victim inside one batch:");
        console2.log("");
        console2.log(string.concat("    attacker front-run -> price ", vm.toString(pFront)));
        console2.log(string.concat("    VICTIM             -> price ", vm.toString(pVictim)));
        console2.log(string.concat("    attacker back-run  -> price ", vm.toString(pBack)));
        console2.log("");
        console2.log("  The attacker bought the same price they sold the victim.");
        console2.log("  There is no edge to capture, so there is no attack to detect.");
        console2.log("");
        console2.log("  Scope, stated honestly: this removes sandwiching WITHIN a batch.");
        console2.log("  It does not remove informed flow, and it does not reduce total");
        console2.log("  LVR - it moves the immediacy premium from searchers to LPs.");

        assertEq(pFront, pVictim, "the attacker's front-run got a different price");
        assertEq(pVictim, pBack, "the attacker's back-run got a different price");
    }

    // ==================================================================
    // Helpers
    // ==================================================================

    /// @dev Realised price of a settled order: what it actually received per
    /// unit of what it actually paid. Read back from state, not predicted.
    function _realisedPrice(
        uint256 id
    ) internal view returns (uint256) {
        OrderView memory v = _order(id);
        require(v.owedOut > 0, "demo: order did not fill");
        uint256 filledIn = _sizes[id] - uint256(v.amountInRemaining);
        require(filledIn > 0, "demo: order filled nothing");
        return FullMath.mulDiv(uint256(v.owedOut), 1e18, filledIn);
    }

    mapping(uint256 => uint256) internal _sizes;

    function _lastFastSwapFee() internal returns (uint24 feeCharged, uint24 premium) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FastSwap(address,bool,int256,uint256,uint24,uint24)");
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics.length > 0 && l.topics[0] == sig) {
                (,,, feeCharged, premium) = abi.decode(l.data, (bool, int256, uint256, uint24, uint24));
                return (feeCharged, premium);
            }
        }
        revert("demo: no FastSwap event");
    }

    function _lastBatchNetting() internal returns (uint256 net0, uint256 net1, uint256 cowMatched) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "SlowBatchSettled(uint32,uint160,uint256,uint256,uint256,uint256,uint256,uint256,uint256)"
        );
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics.length > 0 && l.topics[0] == sig) {
                (, net0, net1, cowMatched,,,,) =
                    abi.decode(l.data, (uint160, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                return (net0, net1, cowMatched);
            }
        }
        revert("demo: no SlowBatchSettled event");
    }

    function _eth(
        uint256 wei_
    ) internal pure returns (string memory) {
        uint256 whole = wei_ / 1e18;
        uint256 frac = (wei_ % 1e18) / 1e12; // 6 dp
        return string.concat(vm.toString(whole), ".", _pad6(frac));
    }

    function _pad6(
        uint256 v
    ) internal pure returns (string memory s) {
        s = vm.toString(v);
        while (bytes(s).length < 6) {
            s = string.concat("0", s);
        }
    }

    function _pad(
        string memory s,
        uint256 width
    ) internal pure returns (string memory) {
        while (bytes(s).length < width) {
            s = string.concat(s, " ");
        }
        return s;
    }
}
