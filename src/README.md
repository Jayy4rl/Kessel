# src/ — planned module layout

Empty as of Phase 0. This file records the intended structure so the boundaries
are fixed before code lands, and is deleted once `src/` has real contents.

The architecture's organising constraint is that **15 design decisions are open
and the hook is immutable**. Every open decision therefore gets exactly one home,
so that no decision is made silently by an implementation detail.

```
src/
  KesselHook.sol        The only CREATE2-mined contract. Holds all state;
                        implements beforeSwap, unlockCallback, and afterSwap
                        iff DD-8 requires it. Thin: routes and enforces access
                        control, does not compute.

  lanes/
    LaneCodec.sol       hookData encode/decode, lane enum, per-lane params.
                        Owns DD-1 (empty hookData) and, if resolved that way,
                        the trader address (recon finding A).
    FastLaneFee.sol     Pure g(...) -> uint24 | OVERRIDE_FEE_FLAG, behind an
                        interface so the flat-fee fallback is a drop-in.
                        Owns DD-2, DD-4. Enforces I12.
    SlowIntake.sol      Exact-input assert, warehouse cap, BeforeSwapDelta
                        construction, ERC-6909 custody mint.
                        Owns DD-14. Enforces I1, I9.

  book/
    OrderBook.sol       Order records, epoch aggregates, status machine,
                        custody accounting. Sole owner of state transitions.
                        Owns DD-9, DD-15. Enforces I2, I3.

  settle/
    Clearing.sol        PURE. (batch aggregates, settlement-time pool state)
                        -> (P, residual, per-order fills). Must NOT accept
                        submission-time state -- that is how I6 is enforced
                        structurally rather than by review.
                        Owns DD-5, DD-11. Enforces I4, I6, I8.
    Settlement.sol      Two entry paths onto one shared core (PRD §8.3):
                        piggyback (already unlocked -> direct poolManager.swap)
                        and forced (own unlock -> unlockCallback). Never nest
                        unlock.
                        Owns DD-6, DD-7, DD-12, DD-13. Enforces I11.

  fees/
    Recapture.sol       Premium accrual, donate() inside a settled context, and
                        the mandatory empty-range fallback to a hook-held
                        claimable balance. Also the home of the f_slow charging
                        mechanism once recon finding B is decided.
                        Owns DD-3, DD-10. Enforces I5, I7.
    Params.sol          Bounded governance-adjustable parameters with
                        deploy-fixed bounds. Emits ParameterUpdated.
                        Enforces I10 on every write.
```

## Rules that outlive this file

1. **Pure where possible.** `Clearing` and `FastLaneFee` are stateless libraries
   over explicit inputs. This is what turns I4, I6, I8 and I12 into cheap
   exhaustive fuzz targets instead of expensive stateful runs.
2. **Unresolved decisions revert.** An open DD reached at runtime should
   `revert Unresolved_DD_N()`, never fall back to a default. A recommendation in
   the PRD is not a decision — see `docs/OPEN-QUESTIONS.md`.
3. **State lives in `KesselHook`.** v4 encodes permissions in the hook address,
   so the mined contract holds the storage; everything else is `internal`.
4. **Do not mine the address until DD-8 is resolved.** Nothing before Phase 6
   needs a production address; tests deploy to a flag-satisfying address
   directly.
