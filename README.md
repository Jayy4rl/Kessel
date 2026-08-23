# Kessel

A Uniswap v4 hook implementing **two execution lanes on one shared liquidity curve**. Liquidity is never fragmented; the trader picks a lane per swap.

- **Fast Lane** — synchronous, in-block. Dynamic fee `f_base + tax(priorityFeePerGas)`. The premium above `f_base` is recaptured to LPs rather than left to sequencers or searchers.
- **Slow Lane** — deferred. The hook escrows the input and issues a non-transferable, non-cancellable claim. All orders in a batch clear at a **single uniform price computed at settlement time**, which is what makes the lane sandwich-proof and removes the hedgeable basis.

Letting traders self-select by urgency is a screening mechanism: it prices **immediacy** — a real cost the LP bears for filling *now* against committed inventory — and routes that premium to LPs. It does **not** price or identify toxicity, does not remove adverse selection from the Slow Lane, and does not reduce total LVR. See `docs/PRD.md` §1–§2.

## Status

**Phase 0 — scaffolded, not implemented.** Build tooling, dependencies, CI and a test harness exist. `src/` contains no protocol code; see `src/README.md` for the planned module layout.

All **15 design decisions (DD-1…DD-15) are open**, including the highest-priority one: the definition of the Slow-Lane clearing price *P*. Phase 1 is blocked on DD-2 (target chain and urgency signal).

## Documentation

| File | Role |
|---|---|
| `docs/PRD.md` | Canonical protocol specification. Source of truth. |
| `docs/CONSTRAINTS.md` | Requirements, invariants I1–I12, assumptions A1–A4. |
| `docs/DECISIONS.md` | The 15-decision register. Only a human resolves an entry. |
| `docs/OPEN-QUESTIONS.md` | What needs a human call, and what blocks on what. |
| `docs/DEVELOPMENT-LOG.md` | Dated implementation log. |
| `docs/SKILLS.md` | Uniswap AI plugin ecosystem for coding agents. |

A PRD "recommendation" next to an `[OPEN]` tag is **not** a decision. See the note at the top of `docs/OPEN-QUESTIONS.md`.

## Quick start

```bash
git submodule update --init --recursive
forge build
forge test
```

Commands, profiles and test layout are documented in `CLAUDE.md`.

## Testing

- `test/scaffold/` pins upstream v4 behaviours the design depends on. A failure here after a dependency bump means a design assumption has changed, not that a test is flaky.
- `test/invariant/` holds a stub for each of the twelve invariants, skipped with the phase that unblocks it — so `forge test` output doubles as a progress checklist.
