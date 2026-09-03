// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Clearing} from "../../src/settle/Clearing.sol";

/// @notice The clearing price, checked against an exact-rational reference.
///
/// The settlement formula is the one piece of this protocol that cannot be
/// patched after deployment, and every other test checks it against *itself* —
/// invariants confirm the batch is solvent and uniformly priced whatever price
/// the solver picked, which is true even if the solver picks the wrong one.
///
/// So the price is checked here against an independent model.
/// `script/clearing_reference.py` does two things this file cannot:
///
///   * it proves the closed form satisfies `L*(a-b) = N0*a*b - N1`, the
///     equation the derivation claims to solve, exactly and in rationals; and
///   * it evaluates that form with `fractions.Fraction`, so the fixture carries
///     no rounding at all.
///
/// This replays the fixture through the real contract, whose integer arithmetic
/// floors at every step, and asserts they agree. A contract computing a
/// different formula — or the same formula with a scaling error — diverges by
/// orders of magnitude, far outside the tolerance below.
///
/// Regenerate with `python script/clearing_reference.py`. The seed is fixed, so
/// the fixture is reproducible.
contract ClearingDifferentialTest is Test {
    /// @dev The reference floors once; the contract floors at each `mulDiv`.
    /// The real divergence is on the order of 1e-20 relative. One part per
    /// billion is far above that and still many orders of magnitude below any
    /// formula error.
    uint256 internal constant TOLERANCE = 1e9; // 1e-9 relative

    struct Fixture {
        uint256[] sqrtPriceX96;
        uint256[] liquidity;
        uint256[] net0;
        uint256[] net1;
        uint256[] expectedSqrtTargetX96;
        uint256[] expectedPriceX96;
    }

    function _load() internal view returns (Fixture memory f) {
        string memory path = string.concat(vm.projectRoot(), "/test/data/clearing-reference.json");
        require(vm.exists(path), "fixture missing: run `python script/clearing_reference.py`");
        string memory json = vm.readFile(path);

        f.sqrtPriceX96 = vm.parseJsonUintArray(json, ".sqrtPriceX96");
        f.liquidity = vm.parseJsonUintArray(json, ".liquidity");
        f.net0 = vm.parseJsonUintArray(json, ".net0");
        f.net1 = vm.parseJsonUintArray(json, ".net1");
        f.expectedSqrtTargetX96 = vm.parseJsonUintArray(json, ".expectedSqrtTargetX96");
        f.expectedPriceX96 = vm.parseJsonUintArray(json, ".expectedPriceX96");
    }

    /// @notice Every case in the fixture clears where exact arithmetic says it
    /// should.
    ///
    /// @dev The tick bounds are deliberately set to the global sqrt-price
    /// limits and the residual cap to zero, so neither clamp binds. What is
    /// under test is the closed form itself, not the clamping that wraps it —
    /// the clamps have their own tests, and mixing the two would let a clamped
    /// case mask a wrong formula.
    function test_theClosedFormMatchesExactArithmetic() public view {
        Fixture memory f = _load();
        uint256 n = f.sqrtPriceX96.length;
        assertGt(n, 0, "fixture is empty");

        uint256 checked;
        for (uint256 i; i < n; ++i) {
            // An empty batch is a documented no-op with no price to compare.
            if (f.net0[i] == 0 && f.net1[i] == 0) continue;

            Clearing.Solution memory s = Clearing.solve(
                Clearing.PoolPoint({
                    sqrtPriceX96: uint160(f.sqrtPriceX96[i]),
                    liquidity: uint128(f.liquidity[i]),
                    lowerSqrtPriceX96: TickMath.MIN_SQRT_PRICE + 1,
                    upperSqrtPriceX96: TickMath.MAX_SQRT_PRICE - 1,
                    maxResidualIn: 0
                }),
                f.net0[i],
                f.net1[i]
            );

            assertTrue(s.feasible, "a non-empty batch against real liquidity was refused");
            assertFalse(s.clamped, "setup: no clamp should bind with global bounds and no cap");

            assertApproxEqRel(
                uint256(s.sqrtPriceTargetX96),
                f.expectedSqrtTargetX96[i],
                TOLERANCE,
                "settlement sqrt price diverges from exact arithmetic"
            );
            assertApproxEqRel(
                uint256(s.priceX96), f.expectedPriceX96[i], TOLERANCE, "clearing price diverges from exact arithmetic"
            );
            ++checked;
        }

        console2.log("cases checked against exact rationals:", checked);
        assertGt(checked, 400, "too few cases actually compared");
    }

    /// @notice The deviation from exact arithmetic is negligible against the
    /// tolerance the limit re-check actually runs with.
    ///
    /// @dev Note what is NOT asserted: that the solver always rounds *down*.
    /// It does not, and the reason is worth recording. `la = floor(L*a/Q96)`
    /// shrinks the numerator, pushing `b` down; `n0a = floor(N0*a/Q96)` shrinks
    /// the *denominator*, pushing `b` up. The two floors act in opposite
    /// directions, so the net error has no guaranteed sign — measured at up to
    /// ~3e-25 relative in either direction across this fixture.
    ///
    /// That is safe, and this test is what says why rather than leaving it to
    /// be assumed. An upward bias in the predicted price is the shape of the
    /// SR-8 defect: it lets the eligibility screen admit an order the realised
    /// fill cannot satisfy. The defence is `_assertLimitsHeld`, which re-checks
    /// every fill against the price the batch really cleared at with a
    /// one-part-per-million tolerance. A 3e-25 deviation is nineteen orders of
    /// magnitude below that, so it cannot reach a trader's limit. The bound
    /// below is what keeps that gap from silently closing.
    function test_deviationStaysFarBelowTheLimitCheckTolerance() public view {
        Fixture memory f = _load();

        // The limit re-check runs at 1e-6 relative. Requiring the solver to
        // stay within 1e-12 keeps a millionfold margin underneath it.
        uint256 bound = 1e6; // 1e-12 relative

        for (uint256 i; i < f.sqrtPriceX96.length; ++i) {
            if (f.net0[i] == 0 && f.net1[i] == 0) continue;

            Clearing.Solution memory s = Clearing.solve(
                Clearing.PoolPoint({
                    sqrtPriceX96: uint160(f.sqrtPriceX96[i]),
                    liquidity: uint128(f.liquidity[i]),
                    lowerSqrtPriceX96: TickMath.MIN_SQRT_PRICE + 1,
                    upperSqrtPriceX96: TickMath.MAX_SQRT_PRICE - 1,
                    maxResidualIn: 0
                }),
                f.net0[i],
                f.net1[i]
            );

            assertApproxEqRel(
                uint256(s.priceX96),
                f.expectedPriceX96[i],
                bound,
                "price deviation approached the limit-check tolerance"
            );
        }
    }
}
