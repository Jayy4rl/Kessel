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

## 2026-08-25 — Phases 1-5: full protocol implementation, test suite, and security review

**Scope:** Everything between the Phase-0 scaffold and a complete, tested hook: resolution of the fourteen remaining design decisions, the Fast Lane, Slow-Lane intake and custody, the clearing-price solver, batch settlement (both entry paths), redemption, governance, the full test suite, and an adversarial security review with fixes.

**Summary:** Resolved DD-1 and DD-3…DD-15 with recorded rationale, then built the hook against those resolutions. `src/` is now `KesselHook.sol` plus three pure libraries — `lanes/LaneCodec.sol` (DD-1 and trader identity), `lanes/FastLaneFee.sol` (DD-2/DD-4), and `settle/Clearing.sol` (DD-5). Keeping the pricing maths pure and stateless is deliberate: it makes I6 structural rather than asserted, because a function that cannot read submission-time state cannot price from it. All twelve invariant stubs were replaced with real assertions backed by a stateful handler, and the security-review stage found four defects — one of them a permanent freeze of the entire Slow Lane — each now fixed and pinned by a regression test.

**Decisions made or updated:**
- DD-1, DD-3, DD-4, DD-5, DD-6, DD-7, DD-8, DD-9, DD-10, DD-11, DD-12, DD-13, DD-14, DD-15 — all resolved, all recorded in `docs/DECISIONS.md` with alternatives, rationale and every departure from a PRD recommendation called out inside the entry. DD-2 was already resolved by the owner on 2026-08-23.
- SR-1 … SR-5 — five security-review amendments, also in `docs/DECISIONS.md`, under a separate heading because each narrows or extends a resolution that was already written down rather than answering a new question.
- Three resolutions depart from a PRD recommendation and say so explicitly: **DD-4** expresses the urgency tax as a *rate* rather than a wei amount (§4.1's "~90% of the marginal bid" calibration needs a price oracle, which §9 forbids); **DD-5** clears at the self-funding *average* price rather than the marginal price the PRD's prose implies; and **DD-11** rejects the PRD's recommended refund-on-limit-violation as unsound — dropping a currency1 seller after pricing leaves a *deficit*, not a surplus, so survivors must be repriced rather than filled at the original price. **DD-7** is stricter than the PRD permits: §6.3 allows a capped keeper reimbursement and it is declined outright, so I7 holds by construction instead of by a bound that would have to be audited on an immutable contract.
- All 15 decisions were resolved by the implementation agent under the owner's explicit directive to research and record before implementing. That directive supersedes the standing "only a human resolves an entry" rule for this work; the rule is unchanged and the entries remain reversible.

**Constraints discovered or clarified:**
- **The clearing price is a fixed point, not a formula applied to a known quantity.** DD-5's circularity — the residual depends on the price, the price depends on the residual — has a closed form on a constant-liquidity range: `b = (L·a + N₁)/(L + N₀·a)`, `P = a·b`. It was verified numerically before any Solidity was written. The on-chain arithmetic factors through Q96 to stay overflow-safe.
- **The closed form only picks a target; solvency must not depend on it.** Whatever the residual swap actually executes, a fill ratio `λ` derived from the *realised* deltas makes the batch exactly uniform-priced and exactly solvent. This is the single most load-bearing structural choice in settlement: the prediction being wrong costs fill size, never solvency.
- **`_loadCandidates` caps work, and every other loop over an epoch has to be capped the same way** — see SR-2. A cap that is enforced in one of three places is not a cap.
- **The active-liquidity range must be found by searching the tick bitmap, not by snapping to the next `tickSpacing` multiple.** Most spacing multiples carry no position, so snapping would force nearly every batch into a needless partial fill. A single-word search is also not enough: at bit position 0 the word's own edge *is* the current price, giving a zero-width range — and tick 0 is the usual initialisation price.
- Restated the four reconnaissance findings as implemented: trader identity travels in `hookData` (v4 passes the router as `sender`); `f_slow` is charged explicitly at settlement, with the pool's stored LP fee left at 0; the I9 warehouse cap is denominated per currency in its own units, because a common numeraire needs the oracle §9 forbids; and I1 is written against the hook's *own* deltas.
- `docs/CONSTRAINTS.md` needed no correction.

**Risks / concerns identified:**
- **The DD-4 calibration gap is the one open economic risk.** `k` is a governance parameter with deploy-fixed bounds, but nothing on-chain can check it against §4.1's "~90% of the marginal searcher bid" target without a price oracle. Choosing `k` well is an off-chain, empirical exercise against real Base flow. The default (500, i.e. +5bp per gwei) is a placeholder, not a calibration.
- **A3 — that `tx.gasprice − block.basefee` matches what Base's sequencer actually orders on — is still unverified.** PRD §2.3 carries this as a hard constraint and §15 scenario 10 asks for a fork test. Not blocking further work; blocking trust in the Fast Lane.
- Fee-on-transfer and rebasing tokens are unsupported. Inherited from v4 rather than introduced here, and documented rather than worked around, for the same reason DD-14 rejects native ETH: a workaround means a second custody representation, and I2 depends on custody being one conserved quantity per currency.
- The hook is bound to one pool at construction. That is a security requirement, not a simplification — ERC-6909 custody is held per *currency*, so a hook serving two pools that share a currency could let one pool's settlement drain the other's escrow.

**Tests added / run:** 103 tests, all passing; `forge fmt --check` clean; `FOUNDRY_PROFILE=optimized forge build` (via_ir, 44444444 runs) clean.
- **Invariants (`test/invariant/`)** — all twelve stubs replaced with real assertions, none skipped, driven by a new stateful handler (`KesselHandler.sol`) plus a thirteenth invariant that proves the run was not vacuous. Clean at 512 runs × 128 depth (65,536 calls per invariant, 0 reverts).
- **Property (`test/property/`)** — 19 tests over the pure libraries. `Clearing`: residual average price equals the clearing price, the pool supplies exactly the imbalance, exact-match and dust-match batches, fill-ratio agreement. `FastLaneFee`: I12 monotonicity, saturation across 256 magnitudes, and — as PRD §4.1 asks — detection of a deliberately mis-specified `g`.
- **Integration (`test/integration/`)** — 48 tests across Fast Lane, Slow Lane, settlement and governance, including both PRD §8.3 entry paths, claim non-transferability probed through every ERC-6909 mutator, and the guarantee that pausing never blocks `redeem`.
- **Security (`test/security/`, new)** — 12 tests. `Adversarial.t.sol` has 9: four encode the defects below, the rest cover PRD §15 scenarios 5 (settlement-price manipulation), 15 (sandwiching a settlement) and 16 (piggyback selection MEV). `Scale.t.sol` has 3, covering §15 scenario 9 (gas at batch size N) and scenario 18 (the empty-range recapture fallback, end to end).
- **Measured settlement cost.** A full 32-order batch carried by one Fast-Lane swap costs ~1.34M gas; a 4-order batch costs ~0.50M. Marginal cost is roughly 30k per order, so the `MAX_ORDERS_PER_EPOCH` cap bounds a linear quantity rather than a quadratic one — which is what makes DD-6's "the carrier's bill is bounded" argument hold.
- **Four defects found and fixed, each pinned by a test written before the fix and observed to fail:**
  1. **Critical, fund-freezing.** An epoch in which every order is dropped for limit ineligibility never rolled and never advanced the settlement cursor. 32 orders with unreachable limits froze the entire Slow Lane *permanently* — and expiry was no escape, because expiry counted epochs and epochs had stopped advancing. (SR-1)
  2. **High, gas DoS.** The per-epoch work cap was not enforced when rolling, so an epoch's index could grow without bound while the roll loop and drained-epoch scan walked all of it. (SR-2)
  3. **High, permanent brick.** `int24` overflow in the tick-bitmap scan. One word-step past the initialised ticks on a wide-spaced pool panics inside settlement; on an immutable pool-bound hook that is every settlement, forever. Invisible at conventional spacings — it needs roughly 4,000 or more. (SR-4)
  4. **Medium, griefing.** Expiry was measured purely in epochs, and anyone can advance an epoch by saturating it with dust. An attacker could churn epochs in one block and force every short-dated order into a refund, charging each the forfeit and denying the trade, with no market movement. (SR-3)
- Two contract bugs were also found earlier, during the testing stage rather than the review: `Clearing.fillRatio` lost the Q96 scale, and the original single-word bitmap search returned a zero-width active range at tick 0 — which let a batch "fill" with zero residual, consuming trader input for no output.

**Items requiring human review:**
1. **All fifteen DD resolutions and the five SR amendments.** They were made under the owner's directive and are recorded so they can be audited and reversed; they have not been reviewed.
2. **`k`'s value.** See the DD-4 risk above — a parameter no test can validate.
3. **DD-5's departure from the PRD's "marginal price" wording.** The average-price choice is argued in the register from self-funding and the implicit-fee framing, but it is a genuine reading of §2.4 rather than a transcription of it, and the PRD calls the definition of P its single highest-priority open item.
4. **A3 verification against Base** (PRD §15 scenario 10). Needs a fork test and an RPC endpoint; no target-chain RPC is configured.
5. **DD-11's rejection of the PRD's recommended refund-on-violation policy.** The argument is that the recommendation is unsound, not merely simpler. If that argument is wrong, settlement's core loop changes.

**Next steps:**
- PRD §15 scenario 10 (Base fork test) is the only one still unwritten, and it is blocked on an RPC endpoint rather than on any decision. Scenario 19 (keeper bound) is not applicable — DD-7 declines the keeper.
- Slither. Not installed in this environment, so it has not been run locally; CI runs it.
- Gas profiling under `FOUNDRY_PROFILE=optimized` (the profile builds clean, but the numbers above are from the dev profile and will be lower under via_ir).
- Hook-address mining (Phase 6). The permission bitmap is frozen by DD-8 and `KESSEL_FLAGS` in the test base pins it, so mining is unblocked — but nothing in the `optimized` profile may move afterwards.

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
