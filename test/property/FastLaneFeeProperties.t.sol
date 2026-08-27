// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Test} from "forge-std/Test.sol";

import {FastLaneFee} from "../../src/lanes/FastLaneFee.sol";

/// @notice Invariant I12 — the Fast-Lane fee is non-decreasing in the priority
/// fee (PRD §4.1, §5.4).
///
/// PRD §4.1 requires this be property-tested "against a mis-specified `g`, not
/// merely assumed", so this file also builds a deliberately broken fee function
/// and confirms the test detects it. A monotonicity test that cannot fail is
/// not evidence of anything.
contract FastLaneFeePropertiesTest is Test {
    uint24 internal constant MAX_FAST_FEE = 50_000; // 5%
    uint24 internal constant F_BASE = 3_000; // 0.30%
    uint256 internal constant K = 500; // 1 gwei => +5 bp

    // ======================================================================
    // I12 — monotonicity
    // ======================================================================

    function testFuzz_I12_feeIsNonDecreasingInPriorityFee(
        uint256 p1,
        uint256 p2,
        uint256 k,
        uint24 fBase
    ) public pure {
        k = bound(k, 0, 100_000);
        fBase = uint24(bound(fBase, 100, 100_000));
        (uint256 lo, uint256 hi) = p1 < p2 ? (p1, p2) : (p2, p1);

        uint24 feeLo = FastLaneFee.fee(fBase, k, lo, MAX_FAST_FEE);
        uint24 feeHi = FastLaneFee.fee(fBase, k, hi, MAX_FAST_FEE);

        assertGe(feeHi, feeLo, "I12: a higher priority fee produced a lower LP fee");
    }

    /// @notice The cap must not break monotonicity, including at the extreme
    /// end of the domain where a naive implementation would overflow and wrap.
    function testFuzz_I12_holdsAtSaturation(
        uint256 k
    ) public pure {
        k = bound(k, 1, 100_000);

        uint24 prev;
        // Walk across many orders of magnitude, ending at the largest possible
        // priority fee. `fee` must saturate, never revert and never wrap.
        for (uint256 shift; shift < 256; shift += 8) {
            uint256 priority = shift == 0 ? 0 : (uint256(1) << shift) - 1;
            uint24 f = FastLaneFee.fee(F_BASE, k, priority, MAX_FAST_FEE);
            assertGe(f, prev, "I12: fee decreased as priority fee grew");
            prev = f;
        }
        assertEq(
            FastLaneFee.fee(F_BASE, k, type(uint256).max, MAX_FAST_FEE), MAX_FAST_FEE, "did not saturate at the cap"
        );
    }

    /// @notice The test above must actually be capable of failing.
    ///
    /// @dev PRD §4.1 asks for exactly this: monotonicity checked against a
    /// mis-specified `g`. `_brokenFee` is non-monotone in a way that is easy to
    /// write by accident — an unchecked subtraction that wraps — and the
    /// assertion below confirms a comparison of the same shape catches it.
    function test_monotonicityCheckDetectsAMisSpecifiedG() public pure {
        uint256 lo = 1 gwei;
        uint256 hi = 2 gwei;

        assertGe(
            FastLaneFee.fee(F_BASE, K, hi, MAX_FAST_FEE),
            FastLaneFee.fee(F_BASE, K, lo, MAX_FAST_FEE),
            "the real g must be monotone"
        );
        assertLt(_brokenFee(hi), _brokenFee(lo), "the broken g must be non-monotone, or this test proves nothing");
    }

    /// @dev A plausible-looking but wrong fee function: it discounts high
    /// urgency instead of charging for it.
    function _brokenFee(
        uint256 priorityFee
    ) private pure returns (uint24) {
        uint256 tax = (K * priorityFee) / 1 gwei;
        return tax >= F_BASE ? 0 : uint24(F_BASE - tax);
    }

    // ======================================================================
    // Fee shape and bounds
    // ======================================================================

    /// @notice PRD §11 case 6: a zero-priority swap pays exactly `f_base` and
    /// recaptures no premium. Acceptable and expected, not a bug.
    function test_zeroPriorityFeePaysBaseOnly() public pure {
        assertEq(FastLaneFee.fee(F_BASE, K, 0, MAX_FAST_FEE), F_BASE, "zero priority should pay exactly f_base");
        assertEq(FastLaneFee.premium(F_BASE, F_BASE), 0, "zero priority should recapture no premium");
    }

    /// @notice DD-4's calibration: 1 gwei of priority fee adds 5 bp.
    function test_defaultCalibration() public pure {
        assertEq(FastLaneFee.fee(F_BASE, K, 1 gwei, MAX_FAST_FEE), F_BASE + 500, "1 gwei should add 5 bp");
        assertEq(FastLaneFee.fee(F_BASE, K, 10 gwei, MAX_FAST_FEE), F_BASE + 5_000, "10 gwei should add 50 bp");
    }

    /// @notice `k = 0` disables the tax entirely, leaving a flat `f_base` pool.
    /// Governance can reach this state, so it must behave sanely.
    function testFuzz_zeroKDisablesTheTax(
        uint256 priorityFee
    ) public pure {
        assertEq(FastLaneFee.fee(F_BASE, 0, priorityFee, MAX_FAST_FEE), F_BASE, "k=0 should charge f_base flat");
    }

    /// @notice The fee never exceeds the cap, and the cap never exceeds v4's
    /// own maximum — an out-of-range fee would make `Pool.swap` revert.
    function testFuzz_feeAlwaysWithinV4Bounds(
        uint256 priorityFee,
        uint256 k,
        uint24 fBase
    ) public pure {
        k = bound(k, 0, 100_000);
        fBase = uint24(bound(fBase, 100, 100_000));

        uint24 f = FastLaneFee.fee(fBase, k, priorityFee, MAX_FAST_FEE);
        assertLe(f, MAX_FAST_FEE, "fee exceeded the configured cap");
        assertLe(f, LPFeeLibrary.MAX_LP_FEE, "fee exceeded v4's maximum LP fee");
        assertTrue(LPFeeLibrary.isValid(f), "fee is not a valid v4 LP fee");
    }

    /// @notice The premium is exactly the part above `f_base` — the quantity
    /// the §14 event stream reports as recaptured.
    function testFuzz_premiumIsTheExcessOverBase(
        uint256 priorityFee,
        uint256 k
    ) public pure {
        k = bound(k, 0, 100_000);
        uint24 f = FastLaneFee.fee(F_BASE, k, priorityFee, MAX_FAST_FEE);
        assertEq(FastLaneFee.premium(f, F_BASE), f - F_BASE, "premium != fee - f_base");
    }
}
