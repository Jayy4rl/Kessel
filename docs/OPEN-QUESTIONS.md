# OPEN-QUESTIONS.md — Items Requiring Human / Design Review

This file consolidates everything that cannot be settled by reading the PRD more carefully — it requires an actual decision from the team. It is derived from `docs/PRD.md` §20/§21 (restated as questions, with dependencies made explicit) plus a small number of additional gaps noticed while building these control documents (clearly marked as such — they are observations, not PRD content).

**Nothing in this file is answered here.** If you are implementing and hit one of these, stop and get a decision recorded in `docs/DECISIONS.md` (with date, chosen alternative, rationale, and who decided) before proceeding — do not pick the PRD's "recommended" alternative on your own authority and call it resolved. See the note on recommendations below.

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
