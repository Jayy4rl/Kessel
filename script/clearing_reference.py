#!/usr/bin/env python3
"""Exact-rational reference for the Slow-Lane clearing price.

`Clearing.solve` derives the settlement price from a closed form:

    b = (L*a + N1) / (L + N0*a)          P = a * b

where `a` is the pool's sqrt price at settlement, `L` the active liquidity, and
`N0`/`N1` the aggregate net-of-fee input per direction. That form is the part of
the protocol that can never be patched, so it is worth checking two separate
things about it, neither of which a Solidity test can do on its own:

  1. **The algebra is right.** The closed form claims to solve

         L*(a - b) = N0*a*b - N1

     which is the statement that the pool supplies exactly the imbalance the
     batch cannot match against itself. `verify_identity` checks that the
     derived `b` satisfies that equation EXACTLY, in rationals, with no
     floating point and no rounding anywhere. A re-implementation of the same
     formula would be circular; checking it against the equation it is supposed
     to solve is not.

  2. **The implementation matches the algebra.** Everything below is computed
     with `fractions.Fraction`, so the emitted values carry no rounding at all.
     `test/property/ClearingDifferential.t.sol` replays them through the real
     contract, whose integer arithmetic floors at every step, and asserts the
     two agree to within that flooring. A contract computing a *different*
     formula diverges immediately and by orders of magnitude.

Usage:

    python script/clearing_reference.py            # regenerate the fixture
    python script/clearing_reference.py --cases 5000

Writes `test/data/clearing-reference.json`. Deterministic: the seed is fixed, so
regenerating without arguments reproduces the committed file byte for byte.
"""

import argparse
import json
import random
from fractions import Fraction
from pathlib import Path

Q96 = 1 << 96

# Bounds mirroring `Clearing.solve`'s own domain. The sqrt-price window spans
# roughly a 4096x price range either side of parity, which covers any pool the
# hook would plausibly serve while staying far from the uint160 ceiling the
# closed form is proved against.
MIN_SQRT = Q96 >> 6
MAX_SQRT = Q96 << 6


def closed_form_b(a: Fraction, liquidity: int, net0: int, net1: int) -> Fraction:
    """`b` as `Clearing.solve` derives it, in exact rationals."""
    return (liquidity * a + net1) / (liquidity + net0 * a)


def verify_identity(a: Fraction, liquidity: int, net0: int, net1: int) -> None:
    """Assert the derived `b` solves the equation the derivation claims.

    `L*(a - b) == N0*a*b - N1`: the currency1 the pool pays out equals the
    imbalance the batch could not match internally. Exact, so `==` is honest.
    """
    b = closed_form_b(a, liquidity, net0, net1)
    lhs = liquidity * (a - b)
    rhs = net0 * a * b - net1
    if lhs != rhs:
        raise AssertionError(
            f"closed form does not satisfy its defining equation\n"
            f"  a={a} L={liquidity} N0={net0} N1={net1}\n"
            f"  L*(a-b) = {lhs}\n  N0*a*b - N1 = {rhs}"
        )


def make_case(rng: random.Random) -> dict:
    sqrt_price = rng.randrange(MIN_SQRT, MAX_SQRT)
    liquidity = rng.randrange(10**15, 10**24)
    net0 = rng.randrange(0, 10**21)
    net1 = rng.randrange(0, 10**21)

    a = Fraction(sqrt_price, Q96)  # real sqrt price
    verify_identity(a, liquidity, net0, net1)

    b = closed_form_b(a, liquidity, net0, net1)
    price = a * b  # currency1 per currency0

    # Emitted in the contract's own Q96 fixed-point, floored, so the Solidity
    # side compares like with like.
    return {
        "sqrtPriceX96": hex(sqrt_price),
        "liquidity": hex(liquidity),
        "net0": hex(net0),
        "net1": hex(net1),
        "expectedSqrtTargetX96": hex(int(b * Q96)),
        "expectedPriceX96": hex(int(price * Q96)),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", type=int, default=512)
    ap.add_argument("--seed", type=int, default=20260902)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = [make_case(rng) for _ in range(args.cases)]

    out = {
        "seed": args.seed,
        "count": len(cases),
        "sqrtPriceX96": [c["sqrtPriceX96"] for c in cases],
        "liquidity": [c["liquidity"] for c in cases],
        "net0": [c["net0"] for c in cases],
        "net1": [c["net1"] for c in cases],
        "expectedSqrtTargetX96": [c["expectedSqrtTargetX96"] for c in cases],
        "expectedPriceX96": [c["expectedPriceX96"] for c in cases],
    }

    path = Path(__file__).resolve().parent.parent / "test" / "data" / "clearing-reference.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")

    print(f"verified the closed form against its defining equation on {len(cases)} cases")
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
