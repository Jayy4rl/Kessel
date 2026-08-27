# OPEN-QUESTIONS.md — Items Requiring Human / Design Review

This file consolidates everything that cannot be settled by reading the PRD more carefully — it requires an actual decision from the team. It is derived from `docs/PRD.md` §20/§21 (restated as questions, with dependencies made explicit) plus a small number of additional gaps noticed while building these control documents (clearly marked as such — they are observations, not PRD content).

**Nothing in this file is answered here.** If you are implementing and hit one of these, stop and get a decision recorded in `docs/DECISIONS.md` (with date, chosen alternative, rationale, and who decided) before proceeding — do not pick the PRD's "recommended" alternative on your own authority and call it resolved. See the note on recommendations below.

---

## Status — 2026-08-25

**§1 (the 15 design decisions): all answered, none by a human.** DD-2 was resolved by the project owner on 2026-08-23. DD-1 and DD-3…DD-15 were resolved on 2026-08-25 by the implementation agent under an explicit owner directive to research each one and record the decision and its rationale in `docs/DECISIONS.md` before implementing it. That directive supersedes this file's "stop and get a decision" rule for that work — it does **not** retire the rule, and it does not make the answers reviewed. Read `docs/DECISIONS.md` as *decisions taken and argued*, not as *decisions ratified*. The questions below are left standing rather than struck out, because what this file is for is telling a human what they still need to look at, and all fifteen still qualify.

**§3 (gaps in the control documents): 3.1 and 3.4 acted on, 3.2 and 3.3 answered.**
- §3.1 — DD-6 and DD-7 were resolved jointly, as this file recommended.
- §3.2 — `g`'s signature: answered **priority-fee-only**, no size- or state-dependence. The reasoning is in DD-4. The short version: §4.1's calibration target ("~90% of the marginal searcher bid") is an absolute wei amount, v4's fee override takes a rate, and converting between them needs a price for the input token — which §9 forbids. `k` is therefore defined directly as a rate, `taxRate = k · priorityFee / 1 gwei`, and `size`/`poolState` do not enter. I12 holds unconditionally rather than only at fixed size. **This is a real departure from §4.1's calibration and is flagged as such inside DD-4.**
- §3.3 — DD-15's two axes were answered separately, as this file asked: representation is a **storage record**, redemption is **pull**.
- §3.4 — DD-8 was re-checked against DD-3 and DD-10 before being frozen. The outcome is that `afterSwap` is needed for *settlement timing*, not for fee routing: the Fast-Lane premium reaches LPs through the dynamic-fee override alone, and v4 credits it inside `Pool.swap`. The bitmap is frozen and pinned by `KESSEL_FLAGS` in `test/utils/KesselTestBase.sol`.

**§4 (validation work): all three still open.** A3 is the one now closest to blocking — PRD §2.3 makes it a hard constraint and §15 scenario 10 asks for a Base fork test, which needs an RPC endpoint that is not configured.

**The four reconnaissance findings are resolved** and implemented: trader identity travels in `hookData` (DD-15); `f_slow` is charged explicitly at settlement with the pool's stored LP fee left at 0 (DD-3); the I9 warehouse cap is per currency in its own units, because a common numeraire needs the oracle §9 forbids; and I1 is written against the hook's own deltas.

### New since implementation — please review

1. **Three resolutions depart from a PRD recommendation, and one is stricter than the PRD permits.** DD-4 (rate not wei), DD-5 (average not marginal clearing price), DD-11 (the PRD's recommended refund-on-violation is argued to be *unsound*, not merely simpler), and DD-7 (declines the keeper reimbursement §6.3 allows). Each is argued in place. DD-5 and DD-11 are the two where being wrong changes settlement's core loop.
2. **`k` cannot be validated by any test.** Its default is a placeholder, not a calibration. See the DD-4 risk note in `docs/DEVELOPMENT-LOG.md`.
3. **Five security-review amendments (SR-1…SR-5)** changed protocol-visible behaviour after the implementation was complete — most consequentially SR-3, which makes a trader's stated `expiryEpochs` a floor on how long an order rests rather than an exact deadline. All five are in `docs/DECISIONS.md`.

---

## Status — 2026-08-26 (economic & assumption review)

The implementation review is closed. This pass covered what a green test suite
cannot: static analysis, the economics, and the assumptions. **Nothing below is
ratified, and no open item has been retired.**

### Newly blocking

1. **DD-5 is BLOCKING and must not be ratified as it stands.** `docs/DD5-SIMULATION.md`
   reports an adversarial simulation run against the real contracts
   (`test/economic/DD5Manipulation.t.sol`). Result: sandwiching the settlement
   residual is profitable at every governance-reachable `k` once the un-netted
   residual exceeds roughly 30–50 bps of pool depth, by 20×–370× the tax at the
   default `k`. Netting is a **complete** defence on the matched portion
   (extraction exactly zero at zero residual) and **no** defence on the residual,
   which measures at ~100% of a plain-CPAMM sandwich — about 2× the
   malicious-batch-operator half-bound. The tax cannot be made to bind: extraction
   is quadratic in the residual while the tax is linear in the attacker's size,
   and `MAX_FAST_FEE` is a deploy-fixed constant that saturates it. The bound that
   *does* bind is trader limit slack (I8 working as designed). Four options for
   closing it are outlined in that document; **none is implemented**, because
   each is a change to settlement's core loop. **Owner decision required.**

2. **Settlement gas has an unpriced incidence.** Measured in
   `test/economic/SettlementGasIncidence.t.sol`: carrying a 32-order batch costs
   the triggering Fast-Lane trader +1,120,644 gas over an uncarried swap, with no
   reimbursement (DD-7 declined PRD §6.3's permission). Absolutely small on Base,
   but **regressive** — 338% of the LP fee paid on a 0.001 ETH swap, 32% at
   0.01 ETH, 3% at 0.1 ETH. It lands hardest on the small retail flow the A1
   thesis depends on attracting, and appears nowhere in the PRD's Fast-Lane
   pricing. Not a defect; a disclosure gap. **Owner decision: price it, cap it
   further, or document it.**

3. **The shipped `k = 500` is roughly 3–30× above what either published anchor
   implies.** `test/economic/KCalibration.t.sol` establishes that the capture
   fraction is `k·S/(1e15·G)` — *independent of the priority fee*, inversely
   proportional to swap size. At `k = 500` and 200,000 gas, a 1 ETH swap is taxed
   at 2,500% of the marginal bid. The 90%-capture `k` for that swap is 180; for a
   10 ETH swap, 18. This does not make `k = 500` wrong — it makes it a
   placeholder that has now been shown to be badly placed. **Blocked on flow
   data; see §4 below.**

### Resolved or discharged this pass

- **SR-3 floor semantics analysed and the rationale recorded** (see SR-3 in
  `docs/DECISIONS.md`). I8 is unaffected by the extension — eligibility never
  mentions time — and the extension moves DD-9's free-option balance toward the
  protocol. One asymmetry is flagged there for an owner call: the block floor is
  anchored to when the *batch* opened, not when the *order* was submitted.
  Regression tests: `test_SR3_fillAfterTheStatedDeadlineStillHonoursTheLimit`,
  `test_SR3_extensionWindowIsNotAnExit`.
- **Slither 0.11.6 run and fully triaged.** No high findings. Two real mediums,
  both fixed with regression tests first: **SR-6** (settlement running underneath
  an in-flight redemption — permanent fund loss on any ETH-quoted pool) and
  **SR-7** (`governance` settable to `address(0)` on a contract with no recovery
  path). Both are in `docs/DECISIONS.md`.
- **A load-bearing upstream assumption was undocumented and is now pinned.** v4
  skips a hook's own callbacks when the hook is the caller, which is the only
  reason the settlement residual is not charged the Fast Lane's urgency tax.
  `test/scaffold/Scaffold.t.sol::test_hookCallbacksAreSkippedWhenTheHookItselfSwaps`.
- **PRD ↔ code divergences enumerated** in `docs/PRD-RECONCILIATION.md`. The PRD
  is not edited; the list is for the owner to apply.

### Still blocked on the owner

- **A3 fork test is written and ready to run.** `test/fork/A3PriorityOrdering.t.sol`
  skips loudly without an endpoint and its offline self-checks (JSON parsing,
  ordering analysis) pass, so the first real run measures A3 rather than debugging
  the file. **Needs: a Base mainnet ARCHIVE RPC endpoint in `BASE_RPC_URL`.**
- **`k` calibration is blocked on flow data.** The harness is built and the data
  request is written into `test_DD4_whatDataIsNeeded` so it cannot be lost.

---

## A note on "recommendations" in the PRD

Many `[OPEN]` items in the PRD are followed by a sentence like "recommend (a) for v1" or "(a) is the simplest defensible choice." These are the PRD author's opinion on which alternative is easiest to ship, not a decision — the PRD is explicit elsewhere that `[OPEN]` items are never protocol requirements. The risk this document exists partly to guard against: an implementer (human or agent) reads a strong, confident recommendation next to an `[OPEN]` tag and quietly treats it as settled. Every question below states the PRD's recommendation where one exists, but flags it as **non-binding** — someone with actual authority over this project has to make the call.

---

## 1. The 15 open design decisions (from PRD §20)

Each restated as a question. Full detail, alternatives, and section references are in `docs/DECISIONS.md`; this list is oriented around *what to ask a human* and *what blocks on what*.

1. **DD-1 — What should the hook do when `hookData` is empty?** (default to Fast at `f_base`, a static-fee lane, or revert) — PRD leans toward Fast-by-default (non-binding).
2. **DD-2 — Which chain are we targeting, and does that mean priority-fee tax or flat/state fee?** This is the most consequential single choice in the register: it changes the Fast-Lane fee formula, the Fast-Lane's sandwich-resistance profile (§7.5), and whether L1 deployment is even in scope (§17).
3. **DD-3 — Does the Fast-Lane premium passively accrue to LPs alongside a fixed `f_slow`, or actively subsidize `f_slow` toward zero?**
4. **DD-4 — What is `k` (the priority-fee tax multiplier), and what are its governance-adjustable bounds?** PRD states there is no closed-form answer; this likely needs empirical/simulation work, not just a policy call.
5. **DD-5 — What exactly is the Slow-Lane clearing price P?** (post-residual marginal price / pre-batch spot / TWAP) — PRD flags this as the single highest-priority open item in the whole document. Do not let this default by omission.
6. **DD-6 — What is the settlement cadence?** (fixed block interval / fixed wall-clock / piggyback / keeper-scheduled)
7. **DD-7 — What/who triggers settlement?** (permissionless valve off a piggyback design, or a scheduled keeper)
8. **DD-8 — Does the hook need `afterSwap`?** ⚠️ **Hard deadline: must be answered before the hook's CREATE2 address is mined** — the permission bitmap is baked into the immutable address. This is the one item on this list where "we'll decide later" is not available once mining happens.
9. **DD-9 — Are Slow-Lane claims fully non-cancellable, or cancellable with a value-destroying forfeiture?**
10. **DD-10 — Which LPs receive the recapture premium?** (all in-range pro rata via `donate()`, or only liquidity that actually served the trade)
11. **DD-11 — What happens when a Slow-Lane order's `minOut` is violated at clearing?** (refund / roll to next epoch / partial fill)
12. **DD-12 — How is settlement-transaction MEV (front-running the residual, piggyback selection MEV) mitigated?** PRD calls this the mechanism's largest residual MEV surface and requires it be resolved before mainnet.
13. **DD-13 — What minimum batch age/size gates permissionless force-settle**, to prevent griefing via repeated tiny unfavorable settlements?
14. **DD-14 — Is native ETH rejected as Slow-Lane input, or specially wrapped on intake?**
15. **DD-15 — Is the trader's claim a storage record or a distinct (non-transferable) receipt token, and is redemption push or pull?**

---

## 2. Dependency graph (why order matters)

The PRD cross-references some of these explicitly; a few implicit dependencies are also worth flagging (marked *implicit* below — these are not stated as "coupled to" in the PRD's own register).

```
DD-2 (chain/urgency signal) ──> DD-1 (default lane)
                              └─> DD-4 (k calibration only meaningful once DD-2 is fixed)
                              └─> §7.5 sandwich-resistance profile (documentation/marketing claims)

DD-5 (clearing price P) ──> DD-6 (cadence)      [P's definition and when it's computed are coupled]
                        └─> DD-12 (settlement MEV mitigation, option i depends on P's definition)
                        └─> §7.6a front-running analysis

DD-6 (cadence) <──coupled──> DD-7 (trigger)      [see note below: these largely overlap]
                        └─> DD-13 (force-settle griefing guard only matters if cadence has a
                            permissionless force-settle path)
                        └─> §7.6b piggyback selection MEV (only relevant if DD-6 = piggyback)

DD-3 (subsidy mode) ──> I10 bound must hold under whichever mode is chosen
                    └─> *implicit*: likely affects DD-8 (see below) if subsidy accounting
                        happens post-swap

DD-8 (afterSwap permission) ──> HARD BLOCKS hook address mining (irreversible)
                            └─> *implicit, not in PRD's own coupling column*: whether afterSwap
                                is needed plausibly depends on DD-10 (recapture distribution
                                mechanics) and DD-3 (subsidy accounting) — i.e. on WHERE fee
                                routing math actually executes. The PRD's register lists only
                                the mining-order constraint under "coupled to" for DD-8, not
                                these architectural dependencies. Resolve DD-3/DD-10 (at least
                                at the architecture level) before finalizing DD-8.

DD-9 (cancellation) ──> independent of the above; only touches claim lifecycle
DD-14 (native ETH) ──> independent; only touches intake path
DD-15 (claim representation + push/pull) ──> independent of settlement-price questions,
                                              but blocks writing the redemption function
```

**Practical reading order if resolving these for real:** DD-2 first (it reframes DD-1 and DD-4 and the whole Fast-Lane fee model), then DD-5 (highest PRD priority, and gates DD-6/DD-12), then DD-6/DD-7 together (see note below), then DD-8 (last, immediately before address mining, once DD-3/DD-10 are at least architecturally settled), then the remaining independent items (DD-9, DD-11, DD-13, DD-14, DD-15) in any order.

---

## 3. Additional gaps noticed while building these control documents

These are **not** items from the PRD's own `[OPEN]` markers or §20 register — they are observations made while extracting the register faithfully. Flagging them here rather than silently resolving them or leaving them invisible.

1. **DD-6 vs. DD-7 conceptual overlap.** The PRD separates "cadence" (§4.4 — *when* does a batch settle) from "trigger" (§10 — *what/who* causes settlement to fire), and formally lists them as two coupled-but-distinct decisions. In practice every cadence alternative in DD-6 (fixed block interval, fixed wall-clock, piggyback, keeper-scheduled) already implies an answer to "who/what triggers it," and DD-7's own alternatives ("piggyback + permissionless valve" or "scheduled keeper") are restatements of DD-6(c) and DD-6(d) respectively. Recommend the team treat DD-6/DD-7 as **one joint decision** rather than resolving them independently, to avoid ending up with an inconsistent pair (e.g., cadence = fixed-interval but trigger = piggyback).

2. **`g()`'s declared signature vs. its concrete formula.** §2.3 and §3.1 define the Fast-Lane fee as `g(priorityFeePerGas, size, poolState)` — a function of three inputs. §4.1 gives the only concrete formula in the document, `tax = k * priorityFeePerGas`, which uses just one of the three. The fee-monotonicity invariant (I12) is also stated only in terms of priority fee (`g(p2, ·) ≥ g(p1, ·)`, with `size`/`poolState` collapsed into `·`). It's not clear from the PRD whether `size`/`poolState`-dependence is a required part of `g`, or whether the three-argument signature was illustrative/future-looking and the shipped formula is intentionally priority-fee-only. This affects whether the implementation needs a size- or state-aware fee curve or just the flat multiplier. Worth a direct answer before implementing §4.1.

3. **DD-15 bundles two logically separable questions.** "Claim representation" (storage record vs. distinct receipt token — an object-identity question) and "redemption model" (push vs. pull — a distribution-mechanics question, discussed independently in §3.4) are filed under one DD number, with the PRD stating redemption "is folded into DD-15's implementation." These don't have to move together: a storage-record claim could still be redeemed via push, and a receipt-token claim could still be pull-redeemed. Recommend the team decide these as two explicit sub-answers even though they share one DD number, so a "DD-15 resolved" note in `docs/DECISIONS.md` doesn't leave ambiguous which axis (or both) was actually decided.

4. **DD-8's real dependencies are undercounted in the PRD's own "coupled to" column.** As noted in the dependency graph above, whether `afterSwap` is needed is a function of *where the fee-routing/premium-accrual math lives* (end of `beforeSwap` vs. a separate post-swap step), which in turn plausibly depends on the subsidy mechanism (DD-3) and recapture-distribution mechanics (DD-10). The PRD's register only cross-references the mining-order constraint for DD-8, not these upstream decisions. Given that DD-8 is the one item with an irreversible deadline, recommend explicitly re-checking DD-8 against DD-3/DD-10 immediately before mining, even if DD-3/DD-10 are otherwise deprioritized.

---

## 4. Open validation work (not code decisions, but blocking for confidence in the mechanism)

These come from PRD §1.4 and the Assumptions list (`docs/CONSTRAINTS.md` §6) — they are empirical questions, not implementation decisions, but the PRD frames A1 in particular as something that should be checked **first**, before deep implementation investment:

- **A1 validation:** on the target pair, measure (a) the share of arbitrage volume bound to this specific pool, and (b) retail's realized cost of an N-block/T-second delay. If retail's delay cost exceeds the fee saving, the mechanism degenerates to a single-fee pool. PRD calls this "the first thing to check and the first chart in any demo."
- **A2 validation:** whether this pool is a marginal-enough venue that delaying Slow-Lane flow doesn't just push it to a competing venue.
- **A3 validation (chain-dependent, tied to DD-2):** confirming the target chain/sequencer actually orders by priority fee honestly, and that `tx.gasprice - block.basefee` matches the ordering component in practice (PRD §15 scenario 10: fork test against the target chain).
