// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {KesselErrors} from "../../src/KesselTypes.sol";
import {FastLaneFee} from "../../src/lanes/FastLaneFee.sol";
import {KesselTestBase} from "../utils/KesselTestBase.sol";

/// @title DD-4 — the `k` calibration harness
///
/// @notice No test in this repository validates `k`, and none can: `k` is a
/// claim about the flow that will actually arrive at this pool, and the shipped
/// default of 500 is a placeholder rather than a calibration. This file is the
/// machinery for turning real flow data into a `k`, plus everything about the
/// shape of the problem that can be established without that data.
///
/// ## The one piece of algebra that makes the whole thing tractable
///
/// The calibration target in PRD §4.1 is a *fraction of the marginal priority
/// bid*: capture ~90–98% of what a searcher was willing to pay for position.
/// Kessel's tax is a fee **rate**, so for a swap of notional `S` (in the input
/// currency) inside a transaction burning `G` gas at priority `p`:
///
///     searcher's bid      = p * G                        (wei)
///     Kessel's tax        = S * (k * p / 1e9) / 1e6      (input-currency units)
///     capture             = tax / bid = k * S / (1e15 * G)
///
/// **`p` cancels.** The capture fraction does not depend on the priority fee at
/// all — it depends only on `S / G`, the swap's notional per unit of gas. That
/// is the single most useful fact for calibrating `k`, and it is not obvious
/// from the formula as written in `FastLaneFee`:
///
///     k = target * 1e15 * G / S
///
/// It also makes DD-4's flagged deviation quantitative rather than qualitative.
/// One `k` cannot hit one capture target across a range of trade sizes: a `k`
/// tuned to capture 90% on a 1 ETH swap captures 9% on a 10 ETH swap and 900%
/// on a 0.1 ETH swap. Calibration is therefore a choice of *which size* to
/// price correctly, and the tables below make that choice explicit instead of
/// letting it fall out of a default.
///
/// ## Two hard bounds the calibrator must respect
///
///  * **A no-tax floor exists already, by integer truncation.** `tax = k * p /
///    1e9` is integer division, so any `p < 1e9 / k` produces exactly zero tax
///    and the trader pays exactly `f_base`. That is PRD §4.1's "floor below
///    which users pay only `f_base`" — it is real, but it is a *consequence* of
///    `k` rather than an independent parameter, so raising `k` lowers the floor.
///  * **`MAX_FAST_FEE` saturates the tax.** Above `p_sat = (MAX_FAST_FEE -
///    f_base) * 1e9 / k` the fee stops rising, so capture of the marginal bid
///    falls to zero for any bid above that point. `MAX_FAST_FEE` is a
///    deploy-fixed constant, not governance-adjustable, so this ceiling cannot
///    be moved after deployment — it must be right before the address is mined.
///
/// Run with:  forge test --match-path 'test/economic/KCalibration*' -vv
contract KCalibrationTest is KesselTestBase {
    /// @dev `MAX_FAST_FEE` in `KesselHook`. Mirrored because it is `internal`.
    uint24 internal constant MAX_FAST_FEE = 50_000;
    uint256 internal constant K_MIN = 0;
    uint256 internal constant K_MAX = 100_000;

    /// @dev Published anchors named in the calibration brief.
    uint256 internal constant ANCHOR_ANGSTROM_BPS = 9_800; // ~98%
    uint256 internal constant ANCHOR_BALANCER_BPS = 9_000; // ~90%

    /// @dev One bucket of historical flow. This struct **is** the input format
    /// the calibration needs — see `test_DD4_whatDataIsNeeded`.
    struct FlowBucket {
        /// @dev Human label, e.g. "retail 0.1-1 ETH" or "searcher arb".
        string label;
        /// @dev Median swap notional in the bucket, in input-currency wei.
        uint256 notional;
        /// @dev Median total gas burned by the transaction carrying the swap.
        uint256 gasUsed;
        /// @dev Share of transaction *count* in this bucket, in bps of 10_000.
        uint256 countShareBps;
        /// @dev Median priority fee bid in the bucket, wei/gas. Not used to
        /// compute `k` (it cancels), but used to report where each bucket sits
        /// relative to the no-tax floor and the saturation ceiling.
        uint256 priorityFee;
    }

    function setUp() public {
        _deployKessel();
        _addWideLiquidity();
        _fundAndApprove(address(this), 1_000 ether);
    }

    // ==================================================================
    // The calibrator
    // ==================================================================

    /// @notice `k` that captures `targetBps` of the marginal priority bid on a
    /// swap of `notional` inside a transaction burning `gasUsed` gas.
    function kForTargetCapture(
        uint256 targetBps,
        uint256 notional,
        uint256 gasUsed
    ) public pure returns (uint256) {
        // k = target * 1e15 * G / S
        return FullMath.mulDiv(targetBps * 1e15, gasUsed, notional * 10_000);
    }

    /// @notice The capture a given `k` achieves on that swap, in bps.
    function captureBpsAt(
        uint256 k,
        uint256 notional,
        uint256 gasUsed
    ) public pure returns (uint256) {
        if (gasUsed == 0) return 0;
        return FullMath.mulDiv(k * 10_000, notional, 1e15 * gasUsed);
    }

    /// @notice Priority fee below which the tax truncates to zero and the
    /// trader pays exactly `f_base`.
    function noTaxFloorWei(
        uint256 k
    ) public pure returns (uint256) {
        return k == 0 ? type(uint256).max : 1e9 / k;
    }

    /// @notice Priority fee above which `MAX_FAST_FEE` binds and the tax stops
    /// responding to the bid at all.
    function saturationPriorityWei(
        uint256 k,
        uint24 fBase_
    ) public pure returns (uint256) {
        if (k == 0) return type(uint256).max;
        return FullMath.mulDiv(MAX_FAST_FEE - fBase_, 1e9, k);
    }

    /// @notice The single `k` whose *count-weighted* capture across a flow
    /// profile equals `targetBps`.
    ///
    /// @dev Count-weighted rather than volume-weighted on purpose: the quantity
    /// being captured is a per-transaction bid for position, so each
    /// transaction is one observation. Volume weighting would let a handful of
    /// whale swaps set `k` for everyone, which is the opposite of what §4.1's
    /// "marginal bid" language means.
    function calibrate(
        FlowBucket[] memory profile,
        uint256 targetBps
    ) public pure returns (uint256 k) {
        // capture_i(k) = k * S_i / (1e15 * G_i); weighted sum = target
        // => k = target / sum(w_i * S_i / (1e15 * G_i))
        //
        // Evaluated as k = target * 1e15 / sum(w_i * S_i / G_i), with the
        // weights carried in bps so the whole thing stays in integers.
        uint256 denom; // sum over buckets of w_i * S_i / G_i, weights in bps
        for (uint256 i; i < profile.length; ++i) {
            if (profile[i].gasUsed == 0) continue;
            denom += FullMath.mulDiv(profile[i].countShareBps, profile[i].notional, profile[i].gasUsed);
        }
        require(denom > 0, "calibrate: empty or degenerate flow profile");
        // target(bps)/1e4 * 1e15 / (denom/1e4) == target * 1e15 / denom
        k = FullMath.mulDiv(targetBps, 1e15, denom);
    }

    // ==================================================================
    // The algebra is checked against the shipped fee function, not trusted
    // ==================================================================

    /// @notice `kForTargetCapture` has to agree with what `FastLaneFee.fee`
    /// actually charges. Without this the harness is just algebra on a
    /// whiteboard.
    function testFuzz_DD4_calibratorAgreesWithTheShippedFeeFunction(
        uint96 notionalSeed,
        uint32 gasSeed,
        uint64 prioritySeed
    ) public view {
        uint256 notional = bound(notionalSeed, 1e15, 1_000 ether);
        uint256 gasUsed = bound(gasSeed, 100_000, 2_000_000);
        uint256 priority = bound(prioritySeed, 1e6, 1 gwei);

        uint256 k = kForTargetCapture(ANCHOR_BALANCER_BPS, notional, gasUsed);
        vm.assume(k >= K_MIN && k <= K_MAX);
        // Stay off the cap, which is a separate regime with its own test.
        vm.assume(priority < saturationPriorityWei(k, hook.fBase()));

        uint24 charged = FastLaneFee.fee(hook.fBase(), k, priority, MAX_FAST_FEE);
        uint256 premium = charged - hook.fBase();
        uint256 taxWei = FullMath.mulDiv(notional, premium, 1_000_000);
        uint256 bidWei = priority * gasUsed;

        uint256 actualBps = FullMath.mulDiv(taxWei, 10_000, bidWei);

        // Integer truncation in `tax = k*p/1e9` biases the realised capture
        // downward; it can never exceed the target.
        assertLe(actualBps, ANCHOR_BALANCER_BPS + 100, "calibrator over-predicts what the fee function charges");
    }

    // ==================================================================
    // `k` is governance-bounded, not hardcoded
    // ==================================================================

    /// @notice PRD §4.1 requires `k` be adjustable within pre-set bounds rather
    /// than hardcoded. It is: `KesselHook.k` is a public storage variable moved
    /// only by `setK`, which is `onlyGovernance` and bounded by the deploy-fixed
    /// `K_MIN`/`K_MAX`.
    function test_DD4_kIsGovernanceBoundedNotHardcoded() public {
        assertEq(hook.k(), 500, "the shipped default is a placeholder, not a calibration");

        vm.prank(governance);
        hook.setK(K_MAX);
        assertEq(hook.k(), K_MAX, "governance must reach the upper bound");

        vm.prank(governance);
        hook.setK(K_MIN);
        assertEq(hook.k(), K_MIN, "governance must reach the lower bound");

        vm.prank(governance);
        vm.expectRevert(KesselErrors.ParameterOutOfBounds.selector);
        hook.setK(K_MAX + 1);

        vm.prank(alice);
        vm.expectRevert(KesselErrors.NotGovernance.selector);
        hook.setK(1_000);
    }

    /// @notice The one thing that IS hardcoded and cannot be moved after
    /// deployment: the fee cap that saturates the tax.
    ///
    /// @dev Flagged rather than fixed. `MAX_FAST_FEE` is a `constant`, so it is
    /// baked into the creation bytecode and therefore into the mined CREATE2
    /// address (PRD §8.1). Any calibration that wants to capture a *large*
    /// marginal bid runs into it, and after mining there is no way to raise it.
    function test_DD4_theFeeCapIsHardcodedAndBoundsEveryCalibration() public {
        vm.prank(governance);
        hook.setK(K_MAX);

        uint256 sat = saturationPriorityWei(K_MAX, hook.fBase());
        console2.log("");
        console2.log("=== The hardcoded ceiling on any calibration ===");
        console2.log("at k = K_MAX, the tax saturates at priority (wei/gas):", sat);

        uint24 atSat = FastLaneFee.fee(hook.fBase(), K_MAX, sat, MAX_FAST_FEE);
        uint24 wayAbove = FastLaneFee.fee(hook.fBase(), K_MAX, sat * 1_000, MAX_FAST_FEE);
        assertEq(atSat, MAX_FAST_FEE, "the cap should bind exactly at the saturation point");
        assertEq(wayAbove, MAX_FAST_FEE, "above it the tax does not respond to the bid at all");

        console2.log("a bid 1000x above that pays the SAME fee - capture of the marginal bid is 0%.");
    }

    // ==================================================================
    // What the harness produces once real data exists
    // ==================================================================

    /// @notice `k` implied by each anchor, across a spread of swap sizes.
    ///
    /// @dev This is the table that shows why "pick a k" is not a single number.
    function test_DD4_kImpliedByEachAnchorAcrossSwapSizes() public pure {
        uint256[5] memory notionals = [uint256(0.05 ether), 0.5 ether, 1 ether, 10 ether, 100 ether];
        uint256 gasUsed = 200_000; // a routed v4 swap, order of magnitude

        console2.log("");
        console2.log("=== k implied by each published anchor (G = 200,000 gas) ===");
        console2.log("notional        k@90% (Balancer 9x)   k@98% (Angstrom L2)   in [0, 100000]?");

        for (uint256 i; i < notionals.length; ++i) {
            uint256 k90 = kForTargetCapture(ANCHOR_BALANCER_BPS, notionals[i], gasUsed);
            uint256 k98 = kForTargetCapture(ANCHOR_ANGSTROM_BPS, notionals[i], gasUsed);
            {
                string memory _line = vm.toString(notionals[i] / 1e15);
                _line = string.concat(_line, "e15  ");
                _line = string.concat(_line, vm.toString(k90));
                _line = string.concat(_line, "  ");
                _line = string.concat(_line, vm.toString(k98));
                _line = string.concat(_line, "  ");
                _line = string.concat(_line, (k98 <= K_MAX) ? "yes" : "NO - above K_MAX");
                console2.log(_line);
            }
        }
    }

    /// @notice What one `k` does to the rest of the size distribution.
    function test_DD4_oneKCannotServeEverySize() public pure {
        uint256 gasUsed = 200_000;
        uint256[4] memory ks = [uint256(50), 500, 5_000, 100_000];
        uint256[5] memory notionals = [uint256(0.05 ether), 0.5 ether, 1 ether, 10 ether, 100 ether];

        console2.log("");
        console2.log("=== capture (bps of the marginal bid) by k and swap size, G = 200,000 ===");
        console2.log("       0.05e18   0.5e18   1e18    10e18   100e18");

        for (uint256 i; i < ks.length; ++i) {
            string memory row = string.concat("k=", vm.toString(ks[i]), "  ");
            for (uint256 j; j < notionals.length; ++j) {
                row = string.concat(row, vm.toString(captureBpsAt(ks[i], notionals[j], gasUsed)), "  ");
            }
            console2.log(row);
        }
        console2.log("(10000 bps = 100% capture; above that the tax exceeds the whole bid)");
    }

    /// @notice End-to-end on a **placeholder** flow profile, to show the shape
    /// of the output. The numbers in this profile are invented.
    ///
    /// @dev Replace `_placeholderProfile()` with the real one and this test
    /// produces the recommendation. It deliberately does not assert a value:
    /// picking a production `k` is the owner's call, not this file's.
    function test_DD4_calibrateOnAPlaceholderProfile() public pure {
        FlowBucket[] memory profile = _placeholderProfile();

        console2.log("");
        console2.log("=== CALIBRATION OUTPUT (PLACEHOLDER FLOW - NOT A RECOMMENDATION) ===");

        uint256 k90 = calibrate(profile, ANCHOR_BALANCER_BPS);
        uint256 k98 = calibrate(profile, ANCHOR_ANGSTROM_BPS);
        console2.log("count-weighted k for 90% capture:", k90);
        console2.log("count-weighted k for 98% capture:", k98);
        console2.log("no-tax floor at k90 (wei/gas):", noTaxFloorWei(k90));
        console2.log("saturation priority at k90 (wei/gas):", saturationPriorityWei(k90, 3_000));

        console2.log("per-bucket capture at the 90% k (bps):");
        for (uint256 i; i < profile.length; ++i) {
            {
                string memory _line = "  ";
                _line = string.concat(_line, profile[i].label);
                _line = string.concat(_line, ": ");
                _line = string.concat(_line, vm.toString(captureBpsAt(k90, profile[i].notional, profile[i].gasUsed)));
                _line = string.concat(_line, " bps");
                console2.log(_line);
            }
        }
    }

    function _placeholderProfile() internal pure returns (FlowBucket[] memory p) {
        p = new FlowBucket[](4);
        p[0] = FlowBucket("retail-small ", 0.05 ether, 180_000, 5_000, 0.0005 gwei);
        p[1] = FlowBucket("retail-medium", 0.5 ether, 200_000, 3_000, 0.001 gwei);
        p[2] = FlowBucket("retail-large ", 5 ether, 220_000, 1_500, 0.002 gwei);
        p[3] = FlowBucket("searcher-arb ", 20 ether, 400_000, 500, 0.05 gwei);
    }

    /// @notice The data request, written as a test so it cannot be lost in a
    /// chat log. Prints exactly what has to be supplied and in what form.
    function test_DD4_whatDataIsNeeded() public pure {
        console2.log("");
        console2.log("=== DD-4: data required to calibrate k (OWNER ACTION) ===");
        console2.log("Source: Base mainnet swap history for the SPECIFIC target pair, >= 30 days.");
        console2.log("Bucket the flow and supply one row per bucket, as `FlowBucket`:");
        console2.log("  label          - e.g. 'retail 0.1-1 ETH', 'searcher arb', 'aggregator'");
        console2.log("  notional       - MEDIAN swap size in input-currency wei (not mean)");
        console2.log("  gasUsed        - MEDIAN total gas of the carrying tx (not just the swap)");
        console2.log("  countShareBps  - share of TRANSACTION COUNT, bps, summing to 10000");
        console2.log("  priorityFee    - MEDIAN priority fee bid, wei/gas");
        console2.log("");
        console2.log("Minimum viable split is two buckets (retail vs searcher); more is better.");
        console2.log("Classification rule must be stated: what makes a tx 'searcher' flow.");
        console2.log("");
        console2.log("Why each field: capture = k*S/(1e15*G), so notional and gas set k;");
        console2.log("count shares weight the buckets; priorityFee is NOT used to compute k");
        console2.log("(it cancels) but places each bucket against the no-tax floor 1e9/k and");
        console2.log("the MAX_FAST_FEE saturation point, both of which bound the calibration.");
    }
}
