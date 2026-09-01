# Coverage triage — 2026-08-31

**Tool:** `forge coverage`, lcov report, invariant suite included, fork suite
excluded (it is skipped without `BASE_RPC_URL`).

```bash
FOUNDRY_PROFILE=lite forge coverage \
  --no-match-coverage '(test|script)' --no-match-path 'test/fork/*' \
  --report summary
```

| File | Lines | Statements | Branches | Functions |
|------|-------|-----------|----------|-----------|
| `src/KesselHook.sol` | 99.82% (551/552) | 97.40% (749/769) | 87.35% (145/166) | 100% (65/65) |
| `src/lanes/FastLaneFee.sol` | 100% | 100% | 100% | 100% |
| `src/lanes/LaneCodec.sol` | 100% | 100% | 100% | 100% |
| `src/settle/Clearing.sol` | 100% | 98.68% | 95.24% (20/21) | 100% |
| **Total** | **99.85%** | **97.72%** | **89.16% (181/203)** | **100%** |

The 22 unreached branches are enumerated below. Each is triaged the way the
Slither findings were: a claim, and the argument for it. **The purpose of the
table is to make "not covered" mean something specific.** A branch listed as
UNREACHABLE is a claim that no input can take it, and if that claim is wrong the
line is a live untested path — so each one names the guard that makes it true,
and a future change that removes that guard should bring the branch back into
reach and be caught here rather than in production.

Nothing in this table is a known defect. Everything in it is a guard that fires
only on a state the contract's own upstream checks already exclude.

## Why they were kept rather than deleted

Kessel is immutable and bound to one pool. `src/README.md` records that all
three brick-class defects found so far were permanent rather than recoverable,
and that SR-4 in particular was an arithmetic fault "unreachable by argument"
right up until a wide-spaced pool reached it. That is the standing reason this
codebase prefers a redundant check to a code-reading argument, and it is why
100% branch coverage is not the goal: a defensive guard that can be provoked is
not defensive.

## Triage

### `src/settle/Clearing.sol`

| Line | Guard | Verdict |
|------|-------|---------|
| 183 | `if (denominator == 0) return s;` | **UNREACHABLE.** `denominator = uint256(p.liquidity) + n0a`, and the `p.liquidity == 0` case returns at line 168. So `denominator >= 1` at every reachable evaluation. |

### `src/KesselHook.sol` — the multi-range walk

| Line | Guard | Verdict |
|------|-------|---------|
| 954 | `seg.residualIn == 0 \|\| seg.residualOut == 0` | **UNREACHABLE for `residualIn`; dust-only for `residualOut`.** `Clearing.solve` already reports infeasible when a clamp leaves `residualIn == 0` (`Clearing.sol:240`, covered by `test_aClampWithNoRoomIsInfeasible`), so a clamped-and-feasible segment always moved some input. A zero `residualOut` against a non-zero `residualIn` is a range that absorbed input and paid nothing, which `SqrtPriceMath` produces only at dust scale. |
| 961 | `lambda == 0 \|\| lambda >= Q96` | **UNREACHABLE.** `Clearing.fillRatio` clamps its result to `Q96`, and `lambda == Q96` means the range absorbed the whole remainder — which the `!seg.clamped` break at line 951 already caught. |
| 965 | `rem0 == 0 && rem1 == 0` | **Dust-only.** Both remainders exhausted by a `lambda` strictly below `Q96` requires each side to round to zero. |
| 983 | `out.priceX96 == 0` | **Extreme-price only.** The walk's predicted price truncating to zero in Q96. This is the multi-range mirror of `Clearing.sol:209`, which *is* covered (`test_bottomOfThePriceDomainIsRefusedNotReturned`); reaching it here additionally needs the walk to survive several ranges at the very bottom of the price domain. |

### `src/KesselHook.sol` — `_predictedPrice`

| Line | Guard | Verdict |
|------|-------|---------|
| 1013 | `net0 == 0` on a zero-residual batch | **UNREACHABLE.** A zero residual means the batch cleared entirely against itself, which requires both sides present. A batch with `net0 == 0` and `net1 > 0` has no counter-side and must touch the curve, so `residualIn > 0`. |
| 1020 | `out.residualOut == 0` on a one-sided currency1 batch | **Dust-only.** Same shape as line 954. |
| 1029 | `out.residualIn > net1` | **UNREACHABLE.** A `oneForZero` residual larger than the whole currency1 input contradicts the residual's own direction. Kept because the alternative to the check is an underflow. |

### `src/KesselHook.sol` — distribution

| Line | Guard | Verdict |
|------|-------|---------|
| 1124 | `lambdaX96 == 0` → revert | **Not provoked.** `Clearing.fillRatio` returning zero for amounts that actually executed. The revert is the correct response (it unwinds the residual swap), and `test_aRevertingSettlementDoesNotBreakTheCarryingSwap` covers what happens when settlement reverts, by any cause. |
| 1232 | `grossFilled > c[i].remaining` | **UNREACHABLE.** `FullMath.mulDiv` floors and `lambdaX96 <= Q96`, so `grossFilled <= remaining` always. Explicitly a rounding-up guard against a `mulDiv` that does not round up. |
| 1271 | `shortfall > fee` → revert | **Not provoked.** Independent flooring leaving a side short by more than the `f_slow` collected on that same side. Requires `fSlow == 0` or a pathological batch; the shortfall itself is exercised, only the over-the-fee case is not. |
| 1432, 1435 | `out > left1` / `out > left0` | **Not provoked.** The pro-rata cap. The sum of independently floored shares cannot exceed the pot it was divided from, so the cap is a backstop against a division that rounds the wrong way. |
| 1449 | `out == 0` → revert | **Not provoked.** A non-zero fill receiving a zero payout, which needs a degenerate pot that `_potFor` and the eligibility loop already exclude. |
| 1491 | the I4 uniform-price `require` failing | **Should be unreachable, and is asserted independently.** A failure here is an I4 violation. `test/invariant/Invariants.t.sol` asserts I4 statefully and `test/property/ClearingProperties.t.sol` proves the underlying identity, so the `require` is a last line rather than the only one. |

### `src/KesselHook.sol` — gates and the cursor

| Line | Guard | Verdict |
|------|-------|---------|
| 1174 | `currentEpoch <= from` → `EpochNotClosed` | **UNREACHABLE by construction.** Every caller of `_rollUnfilled` calls `_closeEpoch(from)` first, which guarantees `currentEpoch >= from + 1`. The comment at the call site says as much and checks anyway: rolling orders back into the epoch the next statement deletes would strand every one of them. |
| 1200 | `currentEpoch < oldestUnsettledEpoch` in `_rollUnfilled` | **UNREACHABLE.** After `_closeEpoch(from)`, `currentEpoch == from + 1`, and the line above sets `oldestUnsettledEpoch = from + 1`. They are equal, never less. |
| 1686 | `openedAt == 0` in `_isExpired` | **UNREACHABLE.** `_epochAcceptingOrders` writes `openedAtBlock` before `_recordOrder` pushes the id, and epoch records are never deleted (only `epochOrderIds` is). Every order therefore has a batch record. |
| 1722 | `pending == 0` in `_forceSettleDue` | **UNREACHABLE.** An epoch with a block record but an empty index. `_rollUnfilled` empties an index only while advancing the cursor past that epoch, so the cursor never rests on one. |
| 1873 | `len == 0` in `_advanceIfDrained` | **UNREACHABLE.** `_advanceIfDrained` is reached only from `_settleEpochInner`, which is gated on `_piggybackDue` or `_forceSettleDue` — both of which require a non-empty index. |
| 1877, 1878 | the "still fillable" early return in `_advanceIfDrained` | **UNREACHABLE — and redundant with `_loadCandidates`.** `_advanceIfDrained` runs only when `_loadCandidates` returned an empty set, and its per-order filter (`PENDING && amountInRemaining > 0 && !_isExpired`) is character-for-character the same test. If `_loadCandidates` found nothing fillable, neither can this loop. See the note below. |
| 1883 | `currentEpoch < oldestUnsettledEpoch` in `_advanceIfDrained` | **UNREACHABLE.** The epoch drains only when every order in it is expired, and expiry requires `currentEpoch > epochExpiry >= epoch + 1`. So `currentEpoch >= epoch + 2`, while the line above sets `oldestUnsettledEpoch = epoch + 1`. |

## Observation — the redundant scan in `_advanceIfDrained`

Lines 1877–1878 are not merely unreached; they are *unreachable because they
duplicate the filter that got us here*. `_loadCandidates` and
`_advanceIfDrained` apply the same three-part test to the same order list, and
`_advanceIfDrained` only runs when the first returned nothing.

This is not a defect and it has not been changed. It is worth recording for two
reasons. First, it costs a full pass over the epoch index on every drained
settlement, which is real gas on the path DD-6 makes a volunteering Fast-Lane
trader pay. Second, and more important, the duplication means the two filters
must be kept in step by hand: if a future change makes an order fillable in one
and not the other, this loop stops being redundant and starts being a cursor
that either skips a live order or refuses to advance. Whoever touches either
filter should read both.

## What coverage does not say

Two things, both worth stating plainly because a table of high percentages
invites the opposite conclusion.

**Branch coverage is not attack coverage.** All three brick-class defects this
project has found (SR-1, SR-4, SR-6, recorded in `src/README.md`) were found by
writing adversarial tests, not by chasing uncovered lines, and the invariant
suite stayed green through all three. A frozen Slow Lane violates none of
I1–I12. Coverage tells you the code ran; it does not tell you the code was right
to run.

**And none of it reaches the economics.** `docs/DD5-SIMULATION.md` holds the
questions no amount of state-machine testing can answer, and every run of that
simulation leaves I1–I12 intact whether the attack pays or not.
