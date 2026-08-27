# src/ — module layout, as built

Phase 0 left a *plan* here, on the reasoning that the boundaries should be fixed
before code landed so that no open decision would be made silently by an
implementation detail. The plan said this file should be deleted once `src/` had
real contents. It is kept instead, rewritten to describe what was actually
built — because the as-built layout differs from the plan in one structural way,
and the reason for the difference is worth keeping.

```
src/
  KesselHook.sol        The only CREATE2-mined contract. Holds all state,
                        implements beforeSwap / afterSwap / unlockCallback,
                        and owns every stateful decision.
                        Owns DD-3, DD-6, DD-7, DD-8, DD-9, DD-10, DD-12,
                        DD-13, DD-14, DD-15.
                        Enforces I1, I2, I3, I5, I7, I9, I10, I11.

  KesselTypes.sol       Lane, OrderStatus, Order, Epoch, KesselErrors,
                        KesselEvents. One shared vocabulary, so the pure
                        libraries and the hook agree without importing each
                        other.

  lanes/
    LaneCodec.sol       PURE. hookData encode/decode.
                        Owns DD-1 and the trader-identity half of DD-15
                        (reconnaissance finding A).
    FastLaneFee.sol     PURE. g(...) -> uint24, saturating and monotone.
                        Owns DD-2, DD-4. Enforces I12.

  settle/
    Clearing.sol        PURE. (batch aggregates, settlement-time pool state)
                        -> (clearing price, residual, fill ratio). Accepts no
                        submission-time state at all, which is how I6 is
                        enforced structurally rather than by review.
                        Owns DD-5, DD-11. Enforces I4, I6, I8.
```

## Where the plan was wrong, and why

The plan had five more files: `lanes/SlowIntake.sol`, `book/OrderBook.sol`,
`settle/Settlement.sol`, `fees/Recapture.sol` and `fees/Params.sol`. All five
are now sections of `KesselHook.sol`.

The plan's own rule 3 is what collapsed them: **state lives in `KesselHook`**,
because v4 encodes permissions in the hook's address and only one contract can
be mined. Those five modules were all *stateful* — intake writes custody and the
warehouse counters, the book writes order status, settlement writes epoch
records, recapture writes the deferred-donation balances, params writes the
parameters. A library that cannot hold state can only take the storage it
mutates as arguments, which does not create a boundary; it just moves the same
writes behind an extra call and makes them harder to follow. The two things the
plan was right about — `LaneCodec` and `Clearing` being pure — are exactly the
two that own no state.

So the file boundary the plan wanted turned into a *section* boundary inside one
contract, with each decision's home marked in the contract's own header table.
The property that mattered — one home per decision, and no decision made by
accident — survives; the file count did not.

## Rules that outlive this file

1. **Pure where possible.** `Clearing` and `FastLaneFee` are stateless libraries
   over explicit inputs. This is what turns I4, I6, I8 and I12 into cheap
   exhaustive fuzz targets instead of expensive stateful runs — and, for I6, into
   a property that a reviewer can confirm from a function signature.
2. **Bounded parameters, deploy-fixed bounds.** The contract is immutable, so a
   parameter's bounds are set at deployment and only the value inside them moves.
   Every setter emits `ParameterUpdated`, and `setFees` enforces I10 at the only
   place either fee can change.
3. **The permission bitmap is frozen** (DD-8) and pinned by `KESSEL_FLAGS` in
   `test/utils/KesselTestBase.sol`. Changing `getHookPermissions()` changes this
   contract's address and invalidates any mined one.
4. **Do not change the `optimized` profile after the address is mined.** The
   CREATE2 address derives from creation bytecode, which depends on those
   compiler settings, and the address encodes the permission bitmap.

## Immutability posture

Kessel is immutable and bound to one pool at construction. There is no proxy, no
upgrade path and no migration: the settlement math that ships is the settlement
math forever, and a defect in it cannot be patched — only paused, and the pause
deliberately cannot stop `redeem`, so it can slow the protocol down but never
strand funds. The pool binding is a security requirement rather than a
simplification, because ERC-6909 custody is held per *currency*: a hook serving
two pools that share a currency could have one pool's settlement drain the
other's escrow.

That posture is why adversarial review is weighted the way it is here, and why
the review's own record matters more than a green suite. **Three brick-class
defects have been found by adversarial review, none of them by the invariant
suite, and all three were permanent rather than recoverable:**

- **SR-1** — a batch in which every order was dropped for limit ineligibility
  neither filled, rolled, nor advanced the cursor. Thirty-two orders with
  unreachable limits would have frozen the entire Slow Lane *permanently*, with
  expiry no escape because expiry is measured in epochs and epochs stop
  advancing too. `test_unfillableBatchDoesNotBlockLaterBatches`.
- **SR-4** — the tick-bitmap cursor multiplied an `int24` by the tick spacing.
  One word-step past the initialised ticks on a wide-spaced pool overflows, and
  the checked multiplication panics *inside* settlement: every settlement for
  that pool would revert forever. Invisible at conventional spacings (1/10/60/200)
  and would have been found by whoever deployed the first wide-spaced pool.
  `test_settlementSurvivesLargeTickSpacing`.
- **SR-6** — `poolManager.take` of native currency hands control to the trader
  with a bare `call`, and DD-14 refuses native ETH only as Slow-Lane *input*, so
  a `oneForZero` order on an ETH-quoted pool pays out in ETH. `poolManager.swap`
  is `onlyWhenUnlocked`, not `onlyByTheUnlocker`, so that trader could run a
  Fast-Lane swap inside the hook's own redemption `unlock`, settle the batch
  underneath an in-flight `_payoutOrder`, and have the order finalised while it
  still owed output — unreachable thereafter. `test/security/RedeemReentrancy.t.sol`.

Why the settlement loop is now believed exhaustively covered, stated as the
specific evidence rather than as a feeling:

- **The state machine.** All twelve invariants run as real stateful assertions
  against `test/invariant/KesselHandler.sol` — none skipped — plus a thirteenth,
  `invariant_handlerAgreesWithHookState`, whose only job is to prove a run was
  not vacuous. The CI profile drives 512 × 128 = 65,536 calls.
- **The pure core.** `Clearing` and `FastLaneFee` are fuzzed directly in
  `test/property/`, including against v4's own `SqrtPriceMath`. I6 is stronger
  than a test: `Clearing`'s every function is `pure` and its only pool input is a
  `PoolPoint` read at settlement time, so "no submission-time state can reach the
  price" is a property of the type signature.
- **Both entry paths.** `test_bothSettlementEntryPathsWork` and
  `test_nestedSwapDuringAfterSwapDoesNotCorruptTheTriggeringSwap` cover the
  §8.3 no-nested-`unlock` rule from both sides.
- **The closed attacks.** Every test in `test/security/` was written before its
  fix and observed to fail first. They are regression locks: if one starts
  passing for the wrong reason, or starts failing, an attack has reopened.
- **The upstream assumptions.** `test/scaffold/` pins the v4 behaviours the
  design rests on — the dynamic-fee flags, hook-address validity, `donate()`'s
  empty-range revert, priority-fee arithmetic, and (added 2026-08-26) that v4
  skips a hook's own callbacks when the hook is the caller, which is what keeps
  the settlement residual from being charged the Fast Lane's urgency tax.
- **Static analysis.** Slither 0.11.6 reports no high-severity findings; every
  medium was triaged, and the two that were real (the `_payoutOrder` reentrancy
  above, and `setGovernance` accepting `address(0)` on a contract where
  governance is the only authority and has no recovery path) were fixed with
  regression tests.

What this does **not** cover, and what no amount of state-machine testing could:
the economic questions in `docs/DD5-SIMULATION.md`. Every run of that simulation
leaves I1–I12 intact whether the attack pays or not.
