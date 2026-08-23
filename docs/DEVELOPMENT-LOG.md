# DEVELOPMENT-LOG.md — Implementation Log

Running, dated record of implementation work on Kessel. This is a log, not a spec — `docs/PRD.md` remains the source of truth for protocol behavior, `docs/DECISIONS.md` for resolved/open decisions, `docs/CONSTRAINTS.md` for requirements/invariants, and `docs/OPEN-QUESTIONS.md` for what still needs human review. Entries here should reference those files rather than restate them.

Entries are in the [Log](#log) section at the bottom, newest first.

---

## How to add an entry

Add one entry per meaningful unit of work (a session, a PR, a milestone) — not per commit. Newest entry at the top. Use this structure:

```markdown
## YYYY-MM-DD — <short title>

**Scope:** what part of the system this entry covers (e.g., "Fast Lane fee computation skeleton," "Slow-Lane intake + custody").

**Summary:** 2-5 sentences on what was done and why.

**Decisions made or updated:**
- Reference the DD-N and link to the entry updated in `docs/DECISIONS.md`, or state "none."
- Do not describe a decision here without also updating `docs/DECISIONS.md` — this log is a narrative, that file is the record of truth for status.

**Constraints discovered or clarified:**
- Anything learned about `docs/CONSTRAINTS.md` items during implementation that wasn't obvious from the PRD alone (e.g., a v4 API detail, a gas-cost finding, a test that revealed an edge case). Update `docs/CONSTRAINTS.md` if the constraint itself needed correcting or sharpening, and note that here.

**Risks / concerns identified:**
- New risks not already tracked, or updates to known risks (e.g., in `docs/OPEN-QUESTIONS.md` §3-4). Include severity and whether it blocks further work.

**Tests added / run:**
- What was tested, against which invariant(s) (I1–I12) or scenario(s) (PRD §15), and the result. Note any invariant that is *not yet* testable because its dependent DD is unresolved.

**Items requiring human review:**
- Anything that surfaced a new open question, or that depends on an existing one in `docs/OPEN-QUESTIONS.md`. Link the relevant DD-N or add a new numbered item there if it's genuinely new — don't silently resolve it here.

**Next steps:**
- What this entry's work unblocks or should be picked up next.
```

---

## Log

## 2026-08-22 — Phase 0: project scaffold

**Scope:** Build tooling, dependencies, CI, and test harness. No protocol code.

**Summary:** Stood up a Foundry project on branch `phase-0-scaffold`: solc 0.8.26 / cancun, v4-core + v4-periphery + OpenZeppelin `uniswap-hooks` as submodules, remappings, four build profiles, CI (build, test, fmt, optimized build, Slither), and a test harness. Added `test/scaffold/` — characterization tests that pin the upstream v4 behaviours the architecture depends on — and `test/invariant/Invariants.t.sol`, twelve skipped stubs (I1–I12) that make `forge test` output a live checklist. `src/` contains only a module-layout plan (`src/README.md`). Phase 0 was gated on no design decision and none was made.

**Decisions made or updated:** None. All 15 DDs remain OPEN; `docs/DECISIONS.md` is unchanged.

Two Phase-0 *implementation* choices were made that are not DDs and are reversible:
- Depend on OpenZeppelin's `uniswap-hooks` for `BaseHook` / `BaseAsyncSwap` / `BaseOverrideFee`. `BaseHook` and `HookMiner` no longer exist in v4-periphery at HEAD; OZ's library is what the Uniswap `v4-hook-generator` skill targets. It arrives transitively as a submodule of v4-periphery, so its version is the one Uniswap itself pins.
- Default build profile has `via_ir` off for iteration speed; the `optimized` profile carries production settings and is built separately in CI.

**Constraints discovered or clarified:**
- **A dynamic-fee pool requires a hook.** `Hooks.isValidHookAddress` rejects `address(0)` when the fee is dynamic. PRD §8.1 mandates a dynamic-fee pool, so Kessel's pool and hook are inseparable — the pool cannot be initialized before the hook exists. Phase 0's fixture is therefore a hookless *static*-fee pool. Pinned as `test_dynamicFeePoolRequiresAHook`.
- **`beforeSwapReturnDelta` is only valid alongside `beforeSwap`.** A hard constraint on any bitmap DD-8 produces. Kessel needs both, so it is satisfied by construction, but it is now pinned as `test_returnsDeltaFlagRequiresItsActionFlag`.
- **`donate()` reverts on zero *active* liquidity** (`Pool.NoLiquidityToReceiveFees`), confirming the PRD §6.2 empty-range fallback is mandatory rather than defensive. Pinned as `test_donateRevertsWithNoActiveLiquidity`.
- `SwapParams` now lives in `@uniswap/v4-core/src/types/PoolOperation.sol`, not `IPoolManager` — relevant to import paths in Phase 1.
- No `CONSTRAINTS.md` item needed correcting; these sharpen §1.6 and §5 rather than contradict them.

**Risks / concerns identified:**
- The four gaps raised in the reconnaissance pass are **unresolved and now blocking specific phases**: trader identity vs. router `sender` (blocks Phase 2), `f_slow` charging mechanism (blocks Phase 3), `MAX_WAREHOUSE` numeraire (blocks I9 enforcement), and I1's wording (affects how the invariant is written). Recorded in the invariant stubs so they cannot be forgotten. None is in `docs/OPEN-QUESTIONS.md` yet — they need a human to add or dismiss them.
- Dependency nesting is deep (`lib/v4-periphery/lib/uniswap-hooks/`). A clone without `--recursive` produces confusing compile errors. Noted in `CLAUDE.md`.

**Tests added / run:** 11 characterization tests in `test/scaffold/Scaffold.t.sol`, all passing (including a 1000-run fuzz over priority-fee arithmetic). 12 invariant stubs, all skipped by design. No invariant is enforced yet — every one is blocked on a later phase, and several on an unresolved DD.

**Items requiring human review:**
- Approval of the four new findings and whether they become register entries (see reconnaissance §06 / §09).
- DD resolution order: DD-2 first, then DD-5, then DD-6/DD-7 jointly. Phase 1 cannot start without DD-2.

**Next steps:** Phase 1 (Fast Lane) is gated on DD-2, DD-1, DD-4, DD-10 and the `g()` signature question. Nothing further should be implemented until at least DD-2 is resolved.
