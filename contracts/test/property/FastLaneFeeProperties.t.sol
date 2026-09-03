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

    uint256 internal constant K_GAS = 150_000; // gas units
    uint256 internal constant Q96 = 1 << 96;

    // ======================================================================
    // DD-4 as amended — the size-denominated tax
    //
    // The whole reason this mode exists is that the rate form cannot charge a
    // size-independent premium, which is what PRD §4.1's calibration language
    // requires. These pin that it now does, and that I12 survives the change.
    // ======================================================================

    /// @notice The headline property: at a fixed priority fee, the tax is a
    /// fixed *amount*, so the fee RATE falls in inverse proportion to size.
    ///
    /// @dev This is precisely what the rate form could not do, and the reason
    /// DD-4 was reopened. Stated as a ratio rather than an absolute so it holds
    /// across the whole size domain rather than at one calibration point.
    function testFuzz_DD4_taxAmountIsIndependentOfTradeSize(
        uint256 sizeWei,
        uint256 priorityFee
    ) public pure {
        sizeWei = bound(sizeWei, 1e15, 1e24);
        priorityFee = bound(priorityFee, 1, 100 gwei);

        uint24 feeSmall = FastLaneFee.feeBySize(0, K_GAS, priorityFee, sizeWei, type(uint24).max);
        uint24 feeLarge = FastLaneFee.feeBySize(0, K_GAS, priorityFee, sizeWei * 2, type(uint24).max);

        // Doubling the size halves the rate, so the absolute premium — rate
        // times size — is unchanged.
        uint256 premiumSmall = uint256(feeSmall) * sizeWei;
        uint256 premiumLarge = uint256(feeLarge) * sizeWei * 2;
        uint256 diff = premiumSmall > premiumLarge ? premiumSmall - premiumLarge : premiumLarge - premiumSmall;

        // The tolerance is the integer-truncation bound, not an invented
        // percentage. Each rate is computed by a flooring division and is
        // therefore within one fee unit of exact, so the two premia can differ
        // by at most `1 * sizeWei + 1 * 2 * sizeWei`. Stating it this way keeps
        // the property true right down to the dust end of the domain, where a
        // relative tolerance would be meaningless — a rate that truncates to 0
        // or 1 carries 100% relative error and says nothing about the tax.
        assertLe(diff, 3 * sizeWei, "DD-4: absolute premium moved with trade size beyond rounding");

        // Away from that floor the property is much tighter than the rounding
        // bound, and asserting so is what stops this test from passing
        // vacuously on a fee function that had no size-independence at all.
        if (feeSmall >= 1_000) {
            assertLe(diff * 1_000, premiumSmall, "DD-4: absolute premium moved with trade size");
        }
    }

    /// @notice I12 must survive in the size-denominated mode too.
    function testFuzz_I12_feeBySizeIsNonDecreasingInPriorityFee(
        uint256 p1,
        uint256 p2,
        uint256 sizeWei,
        uint256 kGas
    ) public pure {
        kGas = bound(kGas, 0, 10_000_000);
        sizeWei = bound(sizeWei, 1, type(uint128).max);
        (uint256 lo, uint256 hi) = p1 < p2 ? (p1, p2) : (p2, p1);

        uint24 feeLo = FastLaneFee.feeBySize(F_BASE, kGas, lo, sizeWei, MAX_FAST_FEE);
        uint24 feeHi = FastLaneFee.feeBySize(F_BASE, kGas, hi, sizeWei, MAX_FAST_FEE);

        assertGe(feeHi, feeLo, "I12: a higher priority fee produced a lower LP fee (size-denominated)");
    }

    /// @notice `g` stays total: no input reverts, and nothing exceeds the cap.
    function testFuzz_feeBySizeIsTotalAndCapped(
        uint24 fBase,
        uint256 kGas,
        uint256 priorityFee,
        uint256 sizeWei
    ) public pure {
        fBase = uint24(bound(fBase, 100, 100_000));
        uint24 f = FastLaneFee.feeBySize(fBase, kGas, priorityFee, sizeWei, MAX_FAST_FEE);
        assertLe(f, MAX_FAST_FEE, "fee exceeded its cap");
    }

    /// @notice A size of zero is an unbounded rate, so it must reach the cap —
    /// never `fBase`, which would make "present a size of zero" a way to buy
    /// priority for free.
    function test_feeBySizeChargesTheCapWhenSizeIsUnknown() public pure {
        assertEq(FastLaneFee.feeBySize(F_BASE, K_GAS, 1 gwei, 0, MAX_FAST_FEE), MAX_FAST_FEE);
    }

    /// @notice Denominating in the currency the amount is already in must not
    /// consult the price at all — the identity case has no oracle surface.
    function testFuzz_sizeInGasTokenIsExactWhenNoConversionIsNeeded(
        uint128 amount,
        uint160 sqrtPriceX96
    ) public pure {
        vm.assume(sqrtPriceX96 > 0);
        // exact-input, zeroForOne: specified currency is currency0.
        (bool ok, uint256 size) = FastLaneFee.sizeInGasToken(true, -int256(uint256(amount)), sqrtPriceX96, true);
        assertTrue(ok, "identity conversion refused");
        assertEq(size, amount, "identity conversion altered the amount");
    }

    /// @notice The conversion refuses rather than saturating when it leaves its
    /// provable range. Refusing falls back to the rate form; saturating would
    /// report a huge size and hand out a cheap swap.
    function test_sizeInGasTokenRefusesAnAbsurdPrice() public pure {
        (bool ok,) = FastLaneFee.sizeInGasToken(true, -1e18, type(uint160).max, false);
        assertFalse(ok, "an out-of-range price should refuse, not saturate");
    }

    /// @notice A degenerate price refuses. An uninitialised pool reports a zero
    /// `sqrtPriceX96`, and the conversion has no meaning against it.
    function test_sizeInGasTokenRefusesADegeneratePrice() public pure {
        (bool ok, uint256 size) = FastLaneFee.sizeInGasToken(true, -1e18, 0, false);
        assertFalse(ok, "a zero price must refuse");
        assertEq(size, 0, "a refusal must report no size");
    }

    /// @notice An amount that cannot be a v4 swap amount refuses rather than
    /// truncating. Truncation would under-state the size and over-charge; the
    /// point of the guard is that neither direction of error is taken.
    function test_sizeInGasTokenRefusesAnOversizedAmount() public pure {
        int256 tooBig = int256(uint256(type(uint128).max) + 1);
        (bool ok,) = FastLaneFee.sizeInGasToken(true, tooBig, uint160(Q96), true);
        assertFalse(ok, "an amount beyond uint128 must refuse");
    }

    /// @notice A zero amount is a zero size, and is *not* a refusal.
    ///
    /// @dev The distinction matters downstream: `feeBySize` charges the cap on
    /// a zero size (a percentage of nothing is nothing, and the cap stops
    /// "present a size of zero" from buying priority for free), whereas a
    /// refusal falls back to the rate form. Both are safe; they are not the
    /// same, so the boundary is pinned.
    function test_sizeInGasTokenTreatsZeroAsAKnownZero() public pure {
        (bool ok, uint256 size) = FastLaneFee.sizeInGasToken(true, 0, uint160(Q96), true);
        assertTrue(ok, "a zero amount is known, not unknown");
        assertEq(size, 0, "a zero amount is a zero size");
    }

    /// @notice Both conversion directions use the pool's own price, and are
    /// inverses of each other.
    ///
    /// @dev The four (direction x exactness) combinations decide which currency
    /// `amountSpecified` is denominated in, and getting that mapping wrong
    /// mis-prices the Fast Lane silently — the fee still looks plausible, it is
    /// just denominated in the wrong asset. Checked at a price of 4
    /// currency1-per-currency0, where the two directions are visibly different
    /// numbers rather than coincidentally equal.
    function test_sizeInGasTokenConvertsInBothDirections() public pure {
        // sqrtP = 2 * 2**96  =>  price = 4 currency1 per currency0.
        uint160 sqrtPriceX96 = uint160(2 * Q96);
        uint256 amount = 1e18;

        // exact-input, zeroForOne: specified is currency0; gas token is
        // currency1 => multiply by the price.
        (bool okUp, uint256 sizeUp) = FastLaneFee.sizeInGasToken(true, -int256(amount), sqrtPriceX96, false);
        assertTrue(okUp, "currency0 -> currency1 conversion refused");
        assertEq(sizeUp, amount * 4, "currency0 amount should be worth 4x in currency1");

        // exact-input, oneForZero: specified is currency1; gas token is
        // currency0 => divide by the price.
        (bool okDown, uint256 sizeDown) = FastLaneFee.sizeInGasToken(false, -int256(amount), sqrtPriceX96, true);
        assertTrue(okDown, "currency1 -> currency0 conversion refused");
        assertEq(sizeDown, amount / 4, "currency1 amount should be worth a quarter in currency0");
    }

    /// @notice Exact-output flips which currency the specified amount is in.
    ///
    /// @dev `(amountSpecified < 0) == zeroForOne` is the whole mapping, and it
    /// is easy to write as `zeroForOne` alone and be right half the time. An
    /// exact-output zeroForOne swap specifies currency1, so declaring currency1
    /// the gas token makes it the identity case — the same swap that needs a
    /// conversion when it is exact-input.
    function test_sizeInGasTokenHandlesExactOutput() public pure {
        uint160 sqrtPriceX96 = uint160(2 * Q96);
        uint256 amount = 1e18;

        // exact-output, zeroForOne: specified is currency1 (the output).
        (bool ok, uint256 size) = FastLaneFee.sizeInGasToken(true, int256(amount), sqrtPriceX96, false);
        assertTrue(ok, "exact-output identity case refused");
        assertEq(size, amount, "exact-output zeroForOne specifies currency1: no conversion");
    }

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
