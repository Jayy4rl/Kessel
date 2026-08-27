// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Fast-Lane fee function `g` (PRD §2.3, §4.1). Pure and stateless,
/// which is what turns invariant I12 into a cheap exhaustive fuzz target rather
/// than a stateful run.
///
/// Owns DD-2 (priority-fee tax) and DD-4 (`k` and its bounds).
///
/// ## The fee
///
///     fee_fast = min(f_base + k * priorityFeePerGas / 1 gwei, MAX_FAST_FEE)
///
/// in v4 fee units (hundredths of a bip; `1_000_000` = 100%).
///
/// ## Why `k` is a rate and not an absolute wei amount (DD-4)
///
/// Paradigm's MEV-tax form is `tax = k * TAXED_GAS * priorityFeePerGas`, which
/// is dimensionally an amount of **wei**. v4's dynamic-fee override accepts a
/// **rate** (`uint24`). Converting a wei amount into a rate means dividing by
/// the swap size denominated in ETH, which requires the input token's ETH
/// price -- an oracle, which PRD §9/§17 forbid outright. Expressing `k`
/// directly in rate units is the only form of this tax that fits v4's fee
/// interface without an external price feed.
///
/// The consequence, recorded in DD-4 and repeated here because it is easy to
/// miss when reading only the code: at a fixed priority fee, the *absolute*
/// premium scales with trade size. That is defensible on the mechanism's own
/// terms -- the immediacy cost an LP bears is inventory risk, which does scale
/// with size (PRD §1.2) -- but it does mean the tax cannot capture a fixed
/// fraction of the marginal priority bid across all sizes, which is what §4.1's
/// "~90%+ of the marginal bid" calibration language envisages.
///
/// ## Sandwich profile
///
/// Under this tax mode on a priority-ordered chain, a sandwicher's front-run
/// leg must outbid the victim on priority and therefore pays a strictly higher
/// tax on that leg: the Fast Lane is sandwich-**resistant in proportion to k**,
/// not sandwich-proof (PRD §7.5). This is a materially different claim from
/// "sandwichable like any v4 swap", which describes only the flat-fee fallback
/// that DD-2 did not choose.
library FastLaneFee {
    /// @dev Denominator for `k`: `k` is hundredths-of-a-bip of extra LP fee per
    /// one gwei of priority fee.
    uint256 internal constant K_DENOMINATOR = 1 gwei;

    /// @notice The trader's revealed urgency signal (PRD §2.3, §8.4).
    ///
    /// @dev `tx.gasprice - block.basefee` is the only sanctioned signal. The
    /// subtraction is guarded rather than unchecked: on a chain or in a test
    /// environment where `tx.gasprice < block.basefee`, the difference is not
    /// meaningful and the correct reading is "no urgency revealed", not a
    /// wrapped enormous number.
    ///
    /// Assumption A3 rides on this: the target chain's sequencer must actually
    /// order by this quantity. PRD §2.3 makes verifying that on the specific
    /// target chain a hard constraint, discharged by the fork test (§15
    /// scenario 10), not by this function.
    function priorityFeePerGas() internal view returns (uint256) {
        uint256 gasPrice = tx.gasprice;
        uint256 baseFee = block.basefee;
        unchecked {
            return gasPrice > baseFee ? gasPrice - baseFee : 0;
        }
    }

    /// @notice `g(priorityFeePerGas)` -> the LP fee to charge this swap.
    ///
    /// @dev Non-decreasing in `priorityFee` (invariant I12). The cap preserves
    /// that: the minimum of a non-decreasing function and a constant is still
    /// non-decreasing. The saturating branch exists so that an absurd
    /// `priorityFee` produces `maxFastFee` rather than reverting on overflow --
    /// a revert there would be a monotonicity break at the top of the domain.
    ///
    /// @param fBase Floor LP fee, charged even at zero priority fee. PRD §11
    /// case 6: a zero-priority swap pays exactly `f_base` and recaptures no
    /// premium, which is acceptable and expected.
    /// @param k Tax multiplier (DD-4), hundredths-of-a-bip per gwei.
    /// @param priorityFee The urgency signal, in wei per gas.
    /// @param maxFastFee Hard cap on the total fee.
    function fee(
        uint24 fBase,
        uint256 k,
        uint256 priorityFee,
        uint24 maxFastFee
    ) internal pure returns (uint24) {
        if (k == 0 || priorityFee == 0) return fBase < maxFastFee ? fBase : maxFastFee;

        // Saturate rather than revert, to keep `g` total and monotone.
        if (priorityFee > type(uint256).max / k) return maxFastFee;

        uint256 tax = (k * priorityFee) / K_DENOMINATOR;
        uint256 total = uint256(fBase) + tax;

        // casting to 'uint24' is safe because the ternary only reaches it when
        // `total < maxFastFee`, and `maxFastFee` is itself a uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return total >= maxFastFee ? maxFastFee : uint24(total);
    }

    /// @notice The portion of `feeCharged` that is recaptured urgency premium.
    /// @dev Purely for the §14 event stream and the demo dashboard; the premium
    /// is not moved anywhere by this function. Under DD-10 the whole fee,
    /// premium included, is credited to in-range LPs by v4's own
    /// `feeGrowthGlobal` accounting during `Pool.swap`.
    function premium(
        uint24 feeCharged,
        uint24 fBase
    ) internal pure returns (uint24) {
        unchecked {
            return feeCharged > fBase ? feeCharged - fBase : 0;
        }
    }
}
