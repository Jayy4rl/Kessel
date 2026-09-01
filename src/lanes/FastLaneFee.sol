// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

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
/// ## Two tax modes (DD-4, amended)
///
/// Paradigm's MEV-tax form is `tax = k * TAXED_GAS * priorityFeePerGas`, which
/// is dimensionally an amount of **wei**. v4's dynamic-fee override accepts a
/// **rate** (`uint24`). Converting a wei amount into a rate means dividing by
/// the swap size denominated in ETH.
///
/// DD-4 originally read that requirement as needing an oracle -- which PRD
/// §9/§17 forbid -- and settled on expressing `k` directly in rate units. That
/// reading conflated two different things. An *external price feed* is
/// forbidden; the *pool's own* `sqrtPriceX96`, read in the same `beforeSwap`
/// that is about to move it, is not a feed at all. It is the state of the
/// contract we are already standing in.
///
/// So there are now two modes, chosen once at deployment and never at runtime:
///
///  * `feeBySize` -- the paper's form, available whenever one side of the pool
///    is the gas token. Trade size is denominated in that currency using the
///    pool's own price, so at a fixed priority fee the tax is a fixed *amount*
///    of wei, independent of trade size. This is what §4.1's "~90%+ of the
///    marginal bid" calibration language actually requires.
///  * `fee` -- the rate form, the only option on a pool with no gas-token side
///    (USDC/WBTC and the like), where denominating size genuinely would need an
///    external price. Retained unchanged, and still the documented fallback.
///
/// The consequence of the rate form, kept here because a deployment may still
/// be stuck with it: at a fixed priority fee the *absolute* premium scales with
/// trade size. That is defensible on the mechanism's own terms -- the immediacy
/// cost an LP bears is inventory risk, which does scale with size (PRD §1.2) --
/// but it cannot capture a fixed fraction of the marginal bid across sizes.
///
/// ## Why reading the pool's own price here is not an oracle dependency
///
/// The manipulation an attacker would want is to *inflate* the denominated size
/// so the rate comes out small. Doing that means moving the pool price away
/// from fair before their own swap and eating the curve slippage both ways --
/// against a tax that is bounded by `maxFastFee` in the first place. The
/// spend-to-save ratio is unfavourable by construction, and the saving is
/// capped while the slippage is not. `sizeInGasToken` also refuses rather than
/// saturates whenever the arithmetic leaves its provable range, so a degenerate
/// price cannot silently produce a free swap -- it falls back to the rate form.
///
/// I12 is preserved in both modes and across the choice between them: each is
/// linear and non-decreasing in `priorityFee`, each saturates at `maxFastFee`,
/// and the mode is fixed at deployment so no monotonicity break can occur at a
/// boundary between them.
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

    /// @dev v4 fee units: `1_000_000` = 100%.
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;

    uint256 internal constant Q96 = 1 << 96;

    /// @dev Upper bound on a Q96 price that `sizeInGasToken` will convert
    /// through. Chosen so that `amount * price / Q96` provably fits a uint256
    /// for any `amount` up to `type(uint128).max`: with `amount <= 2**128` and
    /// `price <= 2**223`, the quotient is at most `2**255`.
    ///
    /// A real pool never approaches this. The bound exists so the function can
    /// be *total* -- refusing rather than reverting -- because a revert inside
    /// `beforeSwap` would take down an ordinary swap, and a saturating return
    /// would hand a trader a cheaper fee for pushing the price somewhere absurd.
    uint256 internal constant MAX_CONVERTIBLE_PRICE_X96 = type(uint256).max >> 33;

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

    /// @notice `g(priorityFeePerGas, size)` in the paper's size-denominated
    /// form -> the LP fee to charge this swap.
    ///
    /// @dev The tax is a fixed *amount* of the gas token,
    /// `kGas * priorityFeePerGas` wei, expressed as a rate by dividing by the
    /// trade size in that same currency. At a fixed priority fee the absolute
    /// premium is therefore constant across trade sizes -- which is the whole
    /// point of the amendment, and the property the rate form cannot have.
    ///
    /// Non-decreasing in `priorityFee` (I12): the numerator is linear in it and
    /// `sizeWei` does not depend on it, so the quotient is monotone, and the
    /// cap preserves monotonicity as it does in `fee`.
    ///
    /// @param fBase Floor LP fee, charged even at zero priority fee.
    /// @param kGas Tax multiplier in *gas units* — the paper's `k * TAXED_GAS`
    /// folded into one parameter. `taxWei = kGas * priorityFeePerGas`.
    /// @param priorityFee The urgency signal, in wei per gas.
    /// @param sizeWei Trade size denominated in the gas token, in wei. Zero
    /// means the size could not be established, which is treated as an
    /// infinite rate and therefore the cap — see the note below.
    /// @param maxFastFee Hard cap on the total fee.
    function feeBySize(
        uint24 fBase,
        uint256 kGas,
        uint256 priorityFee,
        uint256 sizeWei,
        uint24 maxFastFee
    ) internal pure returns (uint24) {
        if (kGas == 0 || priorityFee == 0) return fBase < maxFastFee ? fBase : maxFastFee;

        // A zero-size trade has an unbounded tax *rate* and a zero tax
        // *amount*, so returning the cap is both the correct limit and
        // harmless: a percentage of nothing is nothing. It is deliberately not
        // `fBase`, which would make "present a size of zero" a way to buy
        // priority for free.
        if (sizeWei == 0) return maxFastFee;

        // Saturate rather than revert, to keep `g` total and monotone.
        if (priorityFee > type(uint256).max / kGas) return maxFastFee;
        uint256 taxWei = kGas * priorityFee;

        if (taxWei > type(uint256).max / FEE_DENOMINATOR) return maxFastFee;
        uint256 tax = (taxWei * FEE_DENOMINATOR) / sizeWei;

        uint256 total = uint256(fBase) + tax;

        // casting to 'uint24' is safe because the ternary only reaches it when
        // `total < maxFastFee`, and `maxFastFee` is itself a uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return total >= maxFastFee ? maxFastFee : uint24(total);
    }

    /// @notice Denominate a swap's specified amount in the pool's gas-token
    /// currency, using the pool's own price.
    ///
    /// @dev Returns `ok = false` rather than reverting or saturating whenever
    /// the conversion leaves its provable range. The caller must then fall back
    /// to the rate form: refusing is safe, saturating is not, because a larger
    /// reported size means a smaller fee.
    ///
    /// @param zeroForOne Swap direction.
    /// @param amountSpecified v4's signed amount. Negative is exact-input.
    /// @param sqrtPriceX96 The pool's price, read at `beforeSwap`.
    /// @param gasTokenIsCurrency0 True when currency0 is the gas token.
    /// @return ok False if the size could not be established.
    /// @return sizeWei The size in gas-token units.
    function sizeInGasToken(
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceX96,
        bool gasTokenIsCurrency0
    ) internal pure returns (bool ok, uint256 sizeWei) {
        if (sqrtPriceX96 == 0) return (false, 0);

        uint256 amount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if (amount == 0) return (true, 0);
        if (amount > type(uint128).max) return (false, 0);

        // Which currency `amountSpecified` is denominated in. For exact-input
        // it is the input currency; for exact-output, the output currency.
        //
        //   exact-in,  zeroForOne  -> currency0 (the input)
        //   exact-in,  oneForZero  -> currency1
        //   exact-out, zeroForOne  -> currency1 (the output)
        //   exact-out, oneForZero  -> currency0
        bool specifiedIsCurrency0 = (amountSpecified < 0) == zeroForOne;

        // Already in the right currency: no conversion, no price dependency.
        if (specifiedIsCurrency0 == gasTokenIsCurrency0) return (true, amount);

        // price = (sqrtP / 2**96)**2, in Q96, as currency1 per currency0.
        // `mulDiv` carries the 512-bit intermediate, and the quotient is at
        // most 2**224, so this step cannot overflow for any valid sqrt price.
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (priceX96 == 0 || priceX96 > MAX_CONVERTIBLE_PRICE_X96) return (false, 0);

        if (specifiedIsCurrency0) {
            // amount is currency0, gas token is currency1: multiply by price.
            return (true, FullMath.mulDiv(amount, priceX96, Q96));
        }
        // amount is currency1, gas token is currency0: divide by price.
        // `amount * Q96 <= 2**224`, so this cannot overflow either.
        return (true, FullMath.mulDiv(amount, Q96, priceX96));
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
