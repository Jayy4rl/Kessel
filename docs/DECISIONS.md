# DECISIONS.md — Design Decisions Register

**Source of truth:** `docs/PRD.md` §20 (Design Decisions Register) and §21 (Revision Summary). This file mirrors that register so decisions can be tracked and dated as they are resolved, without editing the PRD itself.

**Rule:** Nothing in this file resolves a decision. Every item below is `OPEN` because the PRD leaves it open. A decision moves to `RESOLVED` only when a human/design-review explicitly makes the call — at that point, add a `Resolution` line (date, chosen alternative, rationale, who decided) rather than deleting the row. Do not infer a resolution from a PRD "recommendation" — several `OPEN` items carry a recommended alternative in the PRD prose, but a recommendation is not a decision (see `docs/OPEN-QUESTIONS.md` for why this distinction matters here).

Status as of this document's creation: **all 15 decisions are OPEN.**

**Status 2026-08-25: all 15 decisions are RESOLVED.** DD-2 was resolved by the project owner on 2026-08-23. DD-1 and DD-3…DD-15 were resolved on 2026-08-25 by the implementation agent under an explicit directive from the project owner to research each unresolved decision and record the decision and its rationale here before implementing it. That directive supersedes, for this work, the standing rule above that only a human resolves an entry; the rule itself is unchanged, and these entries remain subject to owner review and reversal. Each resolution states its reasoning, and every place where a resolution departs from the PRD's own non-binding recommendation is called out explicitly inside that entry.

---

## DD-1 — Default lane when `hookData` is empty
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (a) default to FAST at `f_base`; (b) default to a standard static-fee lane; (c) revert.
- **PRD section(s):** §2.2, §11 (edge case 9), §17
- **Coupled to:** DD-2
- **PRD notes:** Determines behavior for most aggregator/unaware-caller flow; PRD flags this as high-priority to resolve early. PRD names (a) as a "recommendation to evaluate," not a chosen answer.
- **Resolution:** **Alternative (a) — default to FAST**, priced `f_base + tax(priorityFeePerGas)` like any other Fast-Lane swap. Empty `hookData`, malformed `hookData`, and an unrecognised lane byte all take this path; none of them revert.
  - **Rationale.** (c) revert breaks every aggregator and router that does not know about Kessel — which is most of the flow the pool would otherwise see — and PRD §2.2 wants unaware-caller flow served, not rejected. (b) a "standard static-fee lane" is a *third* execution contract on the curve, contradicting the two-lane framing of §2.1 and reintroducing exactly the single-scalar-fee problem of §1.1 for that lane. (a) is correct on the mechanism's own terms: a caller who submits a synchronous swap with no deferral instruction is demanding an immediate fill by construction, and immediacy is the thing the Fast Lane prices (§1.2).
  - **Safety.** (a) is also the LP-safe default. A caller who lands in the Fast Lane by accident pays *at least* `f_base`, never less; the failure mode is an unaware trader overpaying slightly relative to the Slow Lane, not LPs being underpaid.
  - **Why SLOW can never be the default.** A Slow-Lane order requires a `minOut` limit price and an expiry from the trader. There is no safe default for either — a defaulted `minOut` of 0 hands the trader an unbounded-downside order and voids I8. So the default lane must be FAST regardless of any other consideration.
  - **Coupling to DD-2:** resolved consistently — the default is the priority-tax Fast Lane, so a zero-priority-fee unaware caller pays exactly `f_base` (PRD §11 edge case 6).

## DD-2 — Urgency signal & target chain
- **Status:** ✅ RESOLVED — 2026-08-23
- **Alternatives:** (a) priority-fee tax on a priority-ordered L2 (e.g., OP-Stack: Unichain, Base, OP Mainnet, Blast); (b) flat/state-based fee, required if targeting L1.
- **PRD section(s):** §2.3, §4.1
- **Coupled to:** DD-1, DD-8; also determines the Fast-Lane sandwich-resistance profile (§7.5)
- **PRD notes:** Not a cosmetic choice — the two modes have opposite sandwich-resistance properties (§7.5) and the priority-fee tax is stated to "likely not work at all on Ethereum L1" (Paradigm). Whichever is chosen, the target chain's `tx.gasprice - block.basefee` semantics must be verified to match the sequencer's actual ordering rule before relying on it.
- **Resolution:** **Alternative (a) — priority-fee MEV tax. Deployment target chain: Base** (OP-Stack, priority-ordered). Decided by project owner, 2026-08-23.
  - **Fee form:** `tax = k · TAXED_GAS · (tx.gasprice − block.basefee)`, monotonic in priority fee (satisfies I12), sandwich-resistant in proportion to `k` (§7.5 tax mode).
  - **Rationale:** On a priority-ordered OP-Stack chain the sequencer orders by priority fee, making the tax a sound urgency signal. On Ethereum L1 competitive builders maximize block value rather than honoring strict priority order, so the tax "would likely not work at all" (Paradigm); the Fast Lane would fall back to a flat/state-based fee and become fully sandwichable — a materially different mechanism.
  - **Assumption:** deployment stays on Base or another OP-Stack priority-ordered chain (Unichain, OP Mainnet). Moving to L1 reopens this decision.

  **⚠️ Flags recorded at resolution time — not objections, but they must not be lost:**
  1. **Two supporting claims in the submitted rationale are Unichain-specific and do not transfer to Base.** The rationale cites (i) a TEE enforcing priority ordering with public attestations, and (ii) blocks rarely reaching capacity so the "complete block" edge case is minor. Both describe Unichain. Base's ordering guarantee is operational (sequencer policy), not TEE-attested, and Base has historically seen more congestion than Unichain — so the full-block edge case (proposers dropping low-priority txs) carries **more** weight on Base, not less. The choice of (a) still holds on Base; the strength of the A3 trust assumption is simply different from what the rationale describes.
  2. **A3 verification is now a concrete, required task, not a formality.** PRD §2.3 carries a hard `[CONSTRAINT]` that the implementation verify on the *specific* target chain that `tx.gasprice − block.basefee` equals the component the sequencer actually orders on. That must be done against Base (PRD §15 scenario 10, fork test) before the Fast Lane is trusted.
  3. **`TAXED_GAS` implies a size-dependent fee rate, which touches an open question.** The tax is dimensionally an *absolute* amount (wei), while v4's dynamic-fee override takes a *rate* (`uint24`, hundredths of a bip). Converting requires dividing by swap size, which makes `g` depend on `size` — that is exactly the unresolved `g()`-signature question in `docs/OPEN-QUESTIONS.md` §3.2. Resolving DD-2 this way appears to answer it in the affirmative, but that has **not** been explicitly decided and is not treated as decided here. Monotonicity in priority fee (I12) holds either way at fixed size.

## DD-3 — Fast→Slow fee subsidy
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (a) passive — both fees accrue to LPs, `f_slow` is a fixed low constant; (b) active — Fast-Lane premium directly offsets `f_slow` toward zero.
- **PRD section(s):** §2.5, §4.2
- **Coupled to:** I10 (`0 ≤ f_slow < f_base` must hold under either mode)
- **PRD notes:** PRD recommends building (a) first and treating (b) as an extension, but does not resolve this as the shipped design.
- **Resolution:** **Alternative (a) — passive.** Both the Fast-Lane fee (including its urgency premium) and `f_slow` accrue to LPs. `f_slow` is an independent bounded parameter, not a function of Fast-Lane volume.
  - **Rationale.** (b) makes `f_slow` a function of recent Fast-Lane premium, which introduces the pathology the PRD itself names in §2.5: the Slow Lane is near-free exactly when Fast volume is high and expensive exactly when it is low — i.e. the Slow-Lane price is highest precisely when the pool is quiet and Slow-Lane traders are most captive. That is backwards as a screening instrument, because it makes the fast/slow spread *narrowest* when separation matters most.
  - **Accounting.** (b) also requires a running premium accumulator that is spent down by later settlements, which makes I10 (`0 ≤ f_slow < f_base`) a *dynamic* invariant that must hold across every intermediate accumulator state rather than a parameter-write check. Under (a), I10 is enforced at the only place `f_slow` can change — the parameter setter — which is a strictly smaller thing to prove on an immutable contract.
  - **Not foreclosed.** (a) does not prevent (b) later: `f_slow` is already a bounded governance-adjustable parameter, so governance may lower it in response to observed Fast-Lane premium. That captures most of (b)'s economic story without coupling the two fees in immutable code.

## DD-4 — `k` calibration and governance bounds
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** any value of `k` in `tax = k * priorityFeePerGas`, within a bounded, governance-adjustable range (bounds fixed at deploy since the hook is immutable).
- **PRD section(s):** §4.1
- **Coupled to:** —
- **PRD notes:** PRD states there is no closed-form optimum — it depends on flow composition (too high overtaxes and drives away benign-urgent flow; too low leaks premium to the sequencer). `k` must be adjustable within pre-set bounds, not hardcoded to a single value.
- **Resolution:** **`k` is a bounded governance-adjustable parameter expressed as a fee _rate_ per unit of priority fee**, not an absolute wei amount.
  - **Form.** `taxRate = (k * priorityFeePerGas) / 1 gwei`, in v4 fee units (hundredths of a bip). So `k` reads as "hundredths-of-a-bip of extra LP fee per 1 gwei of priority fee".
  - **Values.** Default `k = 500` (1 gwei priority ⇒ +5 bps). Deploy-fixed bounds `K_MIN = 0`, `K_MAX = 100_000` (1 gwei ⇒ +10%). The total Fast-Lane fee is capped at `MAX_FAST_FEE = 50_000` (5%), itself well under v4's `MAX_LP_FEE`.
  - **Why a rate and not an absolute amount.** This resolves `docs/OPEN-QUESTIONS.md` §3.2 and flag 3 recorded under DD-2. The Paradigm form `tax = k · TAXED_GAS · priorityFeePerGas` is dimensionally an absolute amount of **wei**, but v4's dynamic-fee override accepts a **rate** (`uint24`). Converting an absolute wei tax into a rate requires dividing by the swap's size *denominated in ETH* — which requires the input token's ETH price. That is an oracle, and PRD §9/§17 forbid one outright. Defining `k` directly in rate units is the only form of the tax expressible in v4's fee interface without an external price.
  - **⚠️ Consequence — a real deviation from §4.1, flagged for review.** Under a rate-form tax the absolute premium scales with trade size at fixed priority fee. That is a defensible reading of the mechanism rather than a defect: the immediacy cost an LP bears is the inventory risk of filling *now*, which does scale with size (§1.2, Demsetz / Grossman-Miller). But it also means the tax **cannot** be calibrated to capture a fixed fraction of the marginal priority bid across all trade sizes, which is what §4.1's "~90%+ of the marginal priority bid" language envisages. This deviation is forced by the no-oracle constraint, not chosen for convenience, and it is the one place where the shipped Fast-Lane fee departs from the PRD's suggested calibration target.
  - **`g()` signature.** Consequently `g` is a function of `priorityFeePerGas` only; `size` and `poolState` are not arguments. `docs/OPEN-QUESTIONS.md` §3.2 is answered in the negative: the three-argument signature in §2.3/§3.1 is illustrative, not required. I12 (monotonicity) holds and is fuzz-tested.
  - **Cap preserves I12.** `min(f_base + taxRate, MAX_FAST_FEE)` is the minimum of a non-decreasing function and a constant, hence still non-decreasing in the priority fee.

## DD-5 — Uniform clearing-price definition (P) ⚠️ highest priority per PRD
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (a) pool's marginal price after executing the net residual (FM-AMM style); (b) pool's pre-batch spot price; (c) time-weighted price over the deferral window.
- **PRD section(s):** §4.3, §7.4
- **Coupled to:** DD-6 (cadence); §7.6(a) settlement-residual front-running
- **PRD notes:** PRD explicitly calls this "the single most important unresolved algorithmic choice in the Slow Lane" and recommends (a) as theoretically grounded, but does not choose it. A naive "spot price at settlement block" is explicitly stated to be unacceptable regardless of which alternative is picked. Whatever is chosen must be pinned down as exact pseudocode (netting → residual → P → apply-to-all-orders) and pass the manipulation-resistance tests in PRD §15.
- **Resolution:** **A refinement of alternative (a): P is the _self-funding_ clearing price — the average execution price of the net residual against the curve — available in closed form.**
  - **Definition.** Let `a` be the pool's sqrt price at settlement, `L` the active liquidity, and `N0`/`N1` the aggregate net-of-fee Slow-Lane input per direction. The post-residual sqrt price and the clearing price are

    ```
    b = (L*a + N1) / (L + N0*a)          P = a * b
    ```

    and the residual the pool actually trades is exactly the `a → b` move. Netting, residual and price are **one simultaneous solution, not three sequential steps** — which is how the circularity PRD §4.3 warns about is dissolved rather than papered over. Exact pseudocode lives in `src/settle/Clearing.sol`; the derivation and its numerical verification are in `DEVELOPMENT-LOG.md` (2026-08-25).
  - **Why the average price and not the post-residual _marginal_ price.** This is the one substantive departure from the PRD's recommended wording, and it is an accounting requirement rather than a preference. For all orders to clear at P *and* the hook to be exactly solvent, the pool must deliver `N0*P - N1` of token1 in exchange for `N0 - N1/P` of token0 — i.e. **the residual's realised average price must equal P by definition**. For a constant-liquidity range the average price of an `a → b` move is `a*b`, while the post-trade marginal price is `b²`. Since `b < a` when the batch is net-selling token0, `a*b > b²`: clearing at the marginal price would leave the hook holding a *surplus* on every settlement — an uncapped implicit fee that varies with batch size, charged to Slow-Lane traders on top of `f_slow` and invisible to I10. The average-price definition has exactly zero residue. It is also what FM-AMM (Canidio–Fritsch) actually clears at.
  - **Verified properties** (exact in rational arithmetic, then fuzzed on-chain against v4's own `SqrtPriceMath`):
    - Empty batch ⇒ `b = a`, pool untouched.
    - **Perfectly matched batch (`N1 = N0 · spot`) ⇒ `b = a` exactly**: the pool is not touched at all and the whole batch clears at spot. Pure coincidence-of-wants with zero price impact falls out of the formula rather than being special-cased.
    - One-sided batch ⇒ reduces to an ordinary exact-input swap priced at its own average.
    - Sign-symmetric: one expression handles both dominant directions.
  - **Manipulation resistance (§7.4).** The naive "spot at settlement block" price is rejected, as §4.3 requires. P is not a spot reading: it is the price at which the pool *actually transacted*, so an adversary cannot skew P without moving the pool, and moving the pool means trading against it. What this does **not** do on its own is make pre-settlement nudging unprofitable — that is handled under DD-12, where the honest limit of the claim is also recorded.
  - **Known limitation — tick crossing.** The closed form assumes constant `L` across `[b, a]`. If the solved `b` would cross an initialised tick, settlement clamps `b` to the tick boundary and fills the whole batch **pro rata** at the boundary price with ratio `λ ∈ (0,1]`, rolling the remainder to the next epoch. Uniform pricing (I4) and exact solvency are preserved — every order in the epoch receives the same price *and* the same fill ratio. The cost is that a batch large enough to cross a tick settles over several epochs. This is a deliberate scope boundary, not an oversight: the exact multi-range solution requires a quadratic root-solve per range traversed. Recorded as future work in `DEVELOPMENT-LOG.md`.

## DD-6 — Settlement cadence
- **Status:** ✅ RESOLVED — 2026-08-25 (jointly with DD-7)
- **Alternatives:** (a) fixed block interval N; (b) fixed wall-clock time T; (c) piggyback on the next Fast-Lane swap touching the pool; (d) keeper-triggered on a schedule.
- **PRD section(s):** §4.4, §10
- **Coupled to:** DD-5, DD-7; §7.6 (settlement-MEV surfaces)
- **PRD notes:** PRD recommends (c) with a max-delay fallback (tied to I11), but flags that (c) gives unbounded delay in quiet pools and interacts with the piggyback-selection-MEV surface (§7.6b). Not resolved.
- **Resolution:** **Alternative (c) — piggyback — with a bounded max-delay valve.** Resolved jointly with DD-7, as `docs/OPEN-QUESTIONS.md` §3.1 recommends; the two are one decision.
  - **Cadence.** The pending batch settles inside the next **Fast-Lane** swap that touches the pool, provided the batch is at least `MIN_SETTLE_AGE` blocks old. Slow-Lane submissions never trigger settlement (see DD-12 for why). If no qualifying Fast-Lane swap arrives within `MAX_DELAY` blocks, any caller may force settlement (DD-7, I11).
  - **Rationale.** (c) is the only alternative that needs no external actor at all in the common case, which is what keeps §9's "no oracle, no AVS, no solver, no keeper" claim true rather than aspirational. Its stated weakness — unbounded delay in a quiet pool — is exactly what the I11 valve bounds, so (c)+valve dominates (a)/(b)/(d) rather than trading off against them.
  - **`MIN_SETTLE_AGE` is load-bearing, not a nicety.** Without it a batch could be created and settled inside the same block, letting a Slow-Lane submitter approximate submission-time pricing and eroding I6.
  - **Gas.** The piggybacking Fast-Lane trader pays settlement gas. PRD §10 permits either reimbursement or a cap; **capped** is chosen — `MAX_ORDERS_PER_SETTLEMENT` bounds the work per settlement — because any reimbursement path creates a value flow toward a settlement-triggering party and therefore an I7 surface to defend. A hard work bound has no such surface.

## DD-7 — Settlement trigger (keeperless vs. keeper)
- **Status:** ✅ RESOLVED — 2026-08-25 (jointly with DD-6)
- **Alternatives:** piggyback + permissionless safety-valve force-settle; or a scheduled/keeper-triggered settlement.
- **PRD section(s):** §10
- **Coupled to:** DD-6; §7.6(b) piggyback selection MEV
- **PRD notes:** If a keeper exists, it must obey I7 (cannot capture the Fast-Lane premium) and the reimbursement bound in §6.3. This decision is described by the PRD as effectively riding on the same choice as DD-6 (cadence) rather than being fully independent — see `docs/OPEN-QUESTIONS.md`.
- **Resolution:** **Keeperless: piggyback plus a permissionless force-settle valve.** No privileged keeper role exists.
  - After `MAX_DELAY` blocks, `forceSettle()` is callable by **anyone**, gated by DD-13's griefing guard.
  - **Reimbursement: none, to any caller, ever.** This is *stricter* than PRD §6.3, which merely *permits* a capped reimbursement sourced from `f_slow`. That permission is declined: a zero-reimbursement design makes I7 ("no mechanism-introduced intermediary may capture the Fast-Lane premium") true by construction — there is no value flow to an intermediary to bound, audit, or get wrong on an immutable contract. The force-settle caller is expected to be a Slow-Lane trader in the stuck batch, already motivated by their own fill.
  - **Consequence, stated plainly:** in a pool with no Fast-Lane flow *and* no Slow-Lane trader willing to pay gas, a batch waits. I11 guarantees settlement is *permitted* after the delay bound, not that an altruist appears. That is the honest reading of a keeperless design, and it is stated rather than hidden.
  - **Two entry paths (PRD §8.3, hard requirement).** Piggyback runs inside an already-unlocked context and executes the residual via a direct `poolManager.swap`; force-settle enters through the hook's **own** `unlock`/`unlockCallback`. They share one internal core and never nest `unlock`.

## DD-8 — `afterSwap` hook permission ⚠️ blocks CREATE2 address mining
- **Status:** ✅ RESOLVED — 2026-08-25 — **bitmap now frozen**
- **Alternatives:** grant `afterSwap: true` (needed if premium routing/accounting happens post-swap) or `afterSwap: false` (if fee routing lives entirely inside `beforeSwap`).
- **PRD section(s):** §8.2
- **Coupled to:** §8.1 (must be resolved **before** the hook address is mined — v4 encodes permissions in the address, and the address is immutable once deployed)
- **PRD notes:** This is the one decision with a hard, irreversible deadline: mining the hook address before resolving DD-8 is not correctable later. The PRD's own "coupled to" note only names the mining-order constraint — it does not explicitly cross-reference which other decisions (e.g., DD-3, DD-10, DD-12) determine whether `afterSwap` is actually needed. See `docs/OPEN-QUESTIONS.md` for this gap.
- **Resolution:** **`afterSwap: true`.** Final permission bitmap: `beforeSwap | beforeSwapReturnDelta | afterSwap`. `afterSwapReturnDelta` is **false**; every other permission is false.
  - **Why true — and note the reason is _not_ fee routing.** `docs/OPEN-QUESTIONS.md` §3.4 warned that DD-8's real dependencies were undercounted. Confirmed, though not in the direction §3.4 hypothesised: fee routing turned out **not** to need `afterSwap` at all, and `afterSwap` is required for an unrelated reason — it is the only callback that runs *after the triggering swap's own price impact has been booked*, which is precisely the condition PRD §7.6(b) sets for piggyback settlement to be safe. So DD-8 is decided by DD-6/DD-7/DD-12, not by DD-3/DD-10.
  - **Why fee routing does not need it.** The Fast-Lane premium is delivered by the dynamic-fee override itself: `f_base + tax` *is* the pool's LP fee for that swap, and v4 credits the whole LP fee to in-range liquidity through `feeGrowthGlobal` inside `Pool.swap`. There is no premium left over to route post-swap, no `donate()` on the fast path, and therefore no empty-range revert risk on the fast path. (PRD §6.2's fallback is still implemented — for the Slow-Lane fee, where a fully CoW-matched batch can leave a donation with no residual swap to guarantee in-range liquidity.)
  - **Why `afterSwapReturnDelta` is false.** Settlement inside `afterSwap` resolves all of its own deltas through `mint`/`burn`/`take`/`settle`; it never asks the swapping router to absorb a hook delta. Requesting the flag would widen the trust surface for no gain.
  - **Address mining is now unblocked** (PRD §8.1). The bitmap is frozen as of this entry; changing it invalidates any mined address. Do not alter `getHookPermissions()` after mining, and do not change the `optimized` profile's compiler settings after mining.

## DD-9 — Cancellation policy
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (a) fully non-cancellable until settlement; (b) cancellable with a forfeited fee sized to remove option value.
- **PRD section(s):** §7.3
- **Coupled to:** non-transferability (already a hard requirement, not open — see `docs/CONSTRAINTS.md`)
- **PRD notes:** PRD recommends (a) for v1, noting (b) requires sizing a volatility-dependent forfeit correctly, which is hard. Not resolved.
- **Resolution:** **Alternative (a) — fully non-cancellable until settled.** There is no cancel entry point on the contract.
  - **Rationale.** (b) requires pricing the forfeit at or above the option value of the deferral window, which is volatility-dependent. On an immutable contract that number would be either a fixed constant that is wrong in most regimes, or a governance parameter that must be re-tuned faster than governance can act. Under-pricing it reopens exactly the free-option surface §7.3 exists to close.
  - **Interaction with expiry.** An order that is never eligible at any clearing price would otherwise be locked forever, so orders carry a trader-set expiry (bounded by `MAX_EXPIRY_EPOCHS`) after which the input becomes refundable. That refund path is **not** cancellation: it cannot be invoked early, and it forfeits `EXPIRY_FORFEIT_BPS` of the input to LPs — which is what stops "post a deliberately unreachable limit, take the input back later" from being a free straddle. See DD-11.
  - **Non-transferability** is not a decision here — it is a PRD §5.1 requirement, satisfied structurally: a claim is a storage record with no transfer function, no approval, and no operator (DD-15).

## DD-10 — Recapture distribution
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (a) all in-range LPs pro rata via `donate()`; (b) only LPs whose liquidity actually served the trade.
- **PRD section(s):** §6.2
- **Coupled to:** the empty-range `donate()` fallback (already a hard requirement — see `docs/CONSTRAINTS.md`)
- **PRD notes:** PRD calls (a) "the simplest defensible choice" but requires the team to decide and document explicitly.
- **Resolution:** **Alternative (a) — all in-range LPs pro rata.**
  - **Fast-Lane premium:** delivered by the dynamic-fee override, which v4 credits to in-range liquidity via `feeGrowthGlobal`. This *is* alternative (a), reached without a `donate()` call and therefore without its gas cost or its empty-range hazard.
  - **Slow-Lane `f_slow`:** deducted from each order's input at settlement and delivered via `poolManager.donate()`, with the PRD §6.2 empty-range fallback to a hook-held LP-claimable balance.
  - **Why not (b) — "only liquidity that actually served the trade".** v4 exposes no per-position attribution to a hook: `beforeSwap` runs before the swap, and `afterSwap` receives only a net `BalanceDelta`. Identifying which positions were crossed would mean re-implementing v4's tick-traversal loop inside the hook and reconciling it against the pool's own execution — a large, permanently unpatchable surface on an immutable contract, for a distributional refinement whose benefit over (a) is second-order. Note also that for the Fast Lane, (a) is what v4's own fee accounting does natively, so choosing (b) would mean *overriding* correct native behaviour.

## DD-11 — Failed-`minOut` policy
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (a) order does not execute, input refunded; (b) order rolls into the next settlement epoch; (c) partial fill.
- **PRD section(s):** §3.3, §11 (edge case 4)
- **Coupled to:** —
- **PRD notes:** PRD calls (a) simplest and most predictable, but requires whatever is chosen to be deterministic and stated in the claim terms.
- **Resolution:** **`minOut` is reinterpreted as a limit price; the policy is a compound of (b) roll and (c) partial fill. Alternative (a) — immediate refund — is rejected as _unsound_, not merely as less convenient.**
  - **Limit price.** An order's `minOut` defines a limit price `L_i = minOut_i / amountIn_i`. The order is *eligible* in a settlement iff the uniform clearing price P satisfies its limit. This makes I8 exact by construction rather than a post-hoc check, and it is the natural reading of an order resting in a batch auction.
  - **Ineligible ⇒ roll (b).** An order whose limit is not met is simply not filled and stays pending for the next epoch, like any unfilled limit order. It is never executed at a worse price.
  - **Partial fill (c) on tick clamp.** When the residual would cross an initialised tick, the batch fills pro rata at ratio `λ` (DD-5) and the remainder rolls. Every order in the epoch receives the *same* P and the *same* `λ`, so I4 holds and netting advantages no one.
  - **⚠️ Why (a) is rejected — this contradicts the PRD's recommendation and the reason matters.** Removing an order from the batch changes `N0`/`N1`, which changes P, which changes who is eligible. Filling the survivors at a P computed over the *original* set is not self-funding, and the error is not symmetric: dropping a token0-seller leaves a harmless surplus, but **dropping a token1-seller leaves a deficit** — the hook would owe traders more than the pool returned. That is a solvency break, not a rounding artefact, and it is structural. (a) can only be made safe by recomputing P after exclusion, which is what this resolution does instead.
  - **How eligibility is actually resolved.** Settlement iterates: compute P over the candidate set, drop the ineligible, recompute — up to `MAX_CLEARING_ROUNDS`. The candidate set shrinks monotonically, so this terminates. The result is a set that is self-consistent (every member eligible at the P computed *for that exact set*) and therefore exactly self-funding. If it has not converged within the round bound, the epoch settles nothing and retries later — safe, and it under-fills rather than mis-fills. **Maximality of the filled set is an efficiency property, not a safety one, and is explicitly not guaranteed.**
  - **Expiry.** After a trader-set expiry (≤ `MAX_EXPIRY_EPOCHS`), an unfilled order becomes refundable less `EXPIRY_FORFEIT_BPS` to LPs (DD-9).

## DD-12 — Settlement-transaction MEV mitigation
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (i) define P so front-running the residual is unprofitable; (ii) unpredictable/randomized cadence; (iii) execute the settlement residual as its own priority-taxed transaction.
- **PRD section(s):** §7.6
- **Coupled to:** DD-5, DD-6
- **PRD notes:** PRD states this is the mechanism's largest residual MEV surface and must be resolved before mainnet, covering both front-running the settlement residual (§7.6a) and piggyback selection MEV (§7.6b).
- **Resolution:** **(i) + (iii) in combination. (ii) randomised cadence is rejected.** The two §7.6 surfaces are addressed differently — one structurally, one economically.
  - **§7.6(b) piggyback selection MEV — closed structurally.** Settlement runs in **`afterSwap`**, so the triggering Fast-Lane trader's own price impact is already booked before the batch clears. The triggerer cannot obtain a better price *on their own swap* by choosing to settle, which is exactly the condition §7.6(b) demands. Reinforcing this: **Slow-Lane submissions never trigger settlement**, and `MIN_SETTLE_AGE` forbids submit-and-settle in one block, so a Slow-Lane trader cannot select their own clearing moment either. This requirement is what forced DD-8.
  - **§7.6(a) front-running the settlement residual — priced, not eliminated.** P is the residual's own realised average price (DD-5), so there is no stale quote to skim: an adversary cannot move P without actually trading against the pool. To move the pool ahead of a settlement they must submit a Fast-Lane swap on this pool, paying `f_base + k·priorityFee`; and on a priority-ordered chain (DD-2, Base) getting ahead of the settling transaction requires **outbidding it on priority**, which by construction raises the tax they pay. The front-run is therefore taxed in proportion to how hard they compete for the position, and the tax goes to LPs. This obtains alternative (iii)'s economics without needing a separate priority-taxed settlement transaction.
  - **⚠️ Stated honestly: mitigation, not elimination.** A sufficiently profitable front-run still clears a tax of `k` and proceeds. The protocol converts residual front-running from free MEV into a priority auction whose proceeds go to LPs — the same claim the Fast Lane makes in §7.5, with the same `k`-proportional strength and the same enumerated limits (same-priority ordering ties, multi-block, cross-pool). **No stronger claim may be made in any demo or documentation.**
  - **Why (ii) is rejected.** Randomised cadence needs an on-chain randomness source a block producer does not control. Kessel has no oracle and no beacon (§9), so the only available entropy is block data the sequencer chooses — which hands the schedule to precisely the actor the randomisation is meant to defend against. It also directly fights the piggyback design (DD-6), as §7.6 itself notes.

## DD-13 — Force-settle griefing guard
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** minimum batch age before force-settle is permitted; and/or a minimum batch size.
- **PRD section(s):** §12
- **Coupled to:** DD-6, I11 (liveness)
- **PRD notes:** Needed to prevent a griefer from repeatedly forcing tiny, unfavorable settlements once permissionless force-settle exists.
- **Resolution:** **Both guards — a minimum age and a minimum batch size — applied asymmetrically to the two settlement paths.**
  - **Piggyback path:** requires `batchAge ≥ MIN_SETTLE_AGE` blocks. No size floor: a Fast-Lane trader is paying the gas voluntarily and is not choosing the price (DD-12), so there is nothing to grief with.
  - **Force-settle path:** requires `batchAge ≥ MAX_DELAY` blocks **and** (`ordersInBatch ≥ MIN_FORCE_SETTLE_ORDERS` **or** `batchAge ≥ ABSOLUTE_MAX_DELAY`). The size floor is what stops the griefing pattern §12 names — repeatedly forcing tiny, unfavourable settlements. The `ABSOLUTE_MAX_DELAY` escape is what stops the size floor from becoming a *liveness bug*: a single lonely order in a quiet pool must still eventually settle, or the size guard would silently strand it and break I11.
  - **Consequently I11 is tested against `ABSOLUTE_MAX_DELAY`, not `MAX_DELAY`** — the size floor means `MAX_DELAY` alone is not the true liveness bound, and testing against it would assert a guarantee the contract does not make.
  - All four are bounded governance-adjustable parameters with deploy-fixed ranges.

## DD-14 — Native-ETH Slow-Lane input
- **Status:** ✅ RESOLVED — 2026-08-25
- **Alternatives:** (a) reject native ETH as Slow-Lane input outright; (b) special-case it (e.g., wrap on intake).
- **PRD section(s):** §3.2, §5.3, §11 (edge case 14)
- **Coupled to:** —
- **PRD notes:** Native ETH cannot be held as an ERC-6909 claim the way an ERC-20 can. Until decided, the Slow-Lane intake path must not assume ERC-20-style custody for native ETH.
- **Resolution:** **Alternative (a) — reject native ETH as Slow-Lane input.** A Slow-Lane order whose input currency is native ETH reverts with `NativeEthNotSupportedInSlowLane`.
  - **Rationale.** (b) wrap-on-intake means the hook holds WETH while the pool's currency is native ETH, so settlement must unwrap before the residual swap and re-wrap on refund. That is a *second* custody representation living alongside the ERC-6909 path, and PRD §5.1/I2 depend on custody being a single, conserved quantity per currency. Two representations means two places for the conservation argument to break, on a contract that cannot be patched (§5.4).
  - **Scope, stated plainly.** The Fast Lane is unaffected — native-ETH pools work normally and get the full urgency tax and recapture. Only Slow-Lane *input* is refused, and only on the leg where the input currency is native. A native-ETH pool is therefore Fast-Lane-only in one direction, which is a real product limitation and is documented as such rather than hidden. The intended first deployment pair is ERC-20/ERC-20, where this never binds.
  - **Deterministic and non-stranding** (PRD §11 edge case 14): the order reverts inside `beforeSwap`, before any custody is taken, so this path cannot strand funds.

## DD-15 — Trader claim representation (and redemption model)
- **Status:** ✅ RESOLVED — 2026-08-25 (both axes, answered separately)
- **Alternatives:** (a) storage record keyed by `orderId` (recommended); (b) a distinct receipt token. Redemption model (push vs. pull, §3.4) is folded into this decision by the PRD.
- **PRD section(s):** §5.1, §3.4
- **Coupled to:** claim non-transferability (already a hard requirement regardless of which alternative is chosen — see `docs/CONSTRAINTS.md`)
- **PRD notes:** PRD recommends (a) for representation and pull-based redemption for v1, but does not resolve either. Note: representation (storage record vs. token) and redemption mechanics (push vs. pull) are logically separable questions that the PRD bundles under one DD number — see `docs/OPEN-QUESTIONS.md`.
- **Resolution:** `docs/OPEN-QUESTIONS.md` §3.3 asked that the two axes be answered separately. They are.
  - **Representation — alternative (a): a storage record keyed by `orderId`.** Non-transferability (a PRD §5.1 *requirement*, not a choice) then holds **structurally**: there is no transfer function, no approval, no operator, and no token id to move. Alternative (b) — a receipt token — would require non-transferability to be enforced by overriding and reverting in every transfer path of a token standard, i.e. a property maintained by code review rather than by construction, on an immutable contract. (a) also makes I2's claim-vs-custody distinction trivially auditable: the trader's claim is a struct, the hook's custody is an ERC-6909 balance inside the singleton, and they are different *types*.
  - **Redemption — pull.** `redeem(orderId)` transfers the settled output and marks the order redeemed; settlement fixes the price for the whole batch, redemption collects individually. Push settlement would put per-order transfer gas on whoever triggers settlement, making settlement cost scale with batch size — which both worsens the DD-6 gas story and hands a griefer a way to make settlement unaffordable by stuffing the batch. Pull keeps settlement O(batch) in arithmetic but O(1) in transfers.
  - **Redemption is permissionless in caller, fixed in destination:** anyone may call `redeem` for an order, but the output always goes to the recorded trader. This lets a third party pay gas to unstick a trader (PRD §11 edge case 5) without creating any way to redirect funds.
  - **Trader identity** (reconnaissance finding A) is resolved here: v4 passes the *router* as `sender`, so the trader address is carried in `hookData`, defaulting to `sender` when the field is zero. A trader must trust their router to encode them correctly — the same trust already implied by granting that router a token approval. A router cannot use this to steal *from the hook*; the worst case is a malicious router the user had already approved.

---

# Security-review amendments (2026-08-25)

The security-review stage of the build found four defects whose fixes change *protocol-visible behaviour*, not just implementation. Each is recorded here rather than folded silently into the DD it amends, because each narrows or extends a resolution that was already written down. All four are covered by regression tests in `test/security/Adversarial.t.sol`, every one of which was written **before** its fix and observed to fail.

These are agent-made calls under the same owner directive as the DD resolutions above, and are subject to the same review and reversal.

## SR-1 — A batch that fills nothing must still close and roll (amends DD-11, DD-13)

- **Defect (critical, fund-freezing).** Settlement only ever works on `oldestUnsettledEpoch`. The DD-11 shrinking-set loop drops every order whose limit the batch price does not meet; when it dropped *all* of them, the old code returned without filling, without rolling and without advancing the cursor. Because epochs cap at `MAX_ORDERS_PER_EPOCH`, an attacker could saturate one epoch with 32 orders carrying limits the market can never reach and freeze the entire Slow Lane **permanently**. Expiry was no escape: expiry was measured in epochs, and epochs stop advancing too. Reproduced by `test_unfillableBatchDoesNotBlockLaterBatches`.
- **Amendment.** An eligible set that collapses to empty is treated as a *complete* settlement outcome — a fill ratio of zero for every order — so the epoch closes and its orders roll, exactly as DD-11's "rolls into the next epoch" already prescribes for a partially-filled order. Separately, a batch the pool simply could not solve (no liquidity in range, or the eligibility iteration not converging) is retried rather than rolled, but only until `absoluteMaxDelay`, after which it is rolled regardless.
- **Why this is the right reading rather than a new rule.** DD-11 already says an unfilled order rolls. The old code applied that only when *something* filled. The amendment makes "nothing filled" a case of the same rule instead of a special case with no exit.
- **I11 consequence.** The `absoluteMaxDelay` escape is now what makes I11 true in the unsolvable-pool case as well as the size-floor case. I11's bound remains `absoluteMaxDelay`, unchanged.
- **Residual cost, acknowledged not eliminated.** A batch of resting unfillable orders now rolls once every `minSettleAge` blocks, at roughly 20k gas per rolled order, and that bill lands on whichever Fast-Lane trader happens to carry it. With the cap at 32 that is bounded (~640k gas) and rate-limited, and the attacker pays for it too — capital locked in the warehouse for the whole time, plus the expiry forfeit at the end — but it is a real cost imposed on third parties. Governance's `maxWarehouse` caps how much can be parked this way. The alternative is SR-1's original behaviour, a permanent freeze, so this is strictly the better failure mode rather than a clean one.

## SR-2 — Rolling respects the per-epoch work cap (amends DD-6)

- **Defect (high, gas DoS).** `MAX_ORDERS_PER_EPOCH` was enforced at intake and when loading candidates, but not when rolling. An epoch's index could therefore grow without bound, and while `_loadCandidates` would still only price the first 32, the roll loop and the drained-epoch scan walk the *whole* array. Enough resting orders and settlement no longer fits in a block — taking I11 with it. Regression test: `test_rollingNeverGrowsAnEpochPastTheCap`.
- **Amendment.** Rolled orders go through the same cap as new ones, spilling into the next epoch when one fills. Every epoch index is therefore ≤ `MAX_ORDERS_PER_EPOCH` by construction, which is what makes DD-6's "settlement gas is bounded so a piggybacking trader cannot be made to pay unboundedly" actually true.

## SR-3 — Expiry needs a block floor, not just an epoch budget (amends DD-9)

- **Defect (medium, griefing).** DD-9 makes the expiry refund the *only* way out of a claim, and prices it with a forfeit so that "post an unreachable limit, take the input back later" is not a free option. But expiry was measured purely in epochs, and anyone can advance an epoch by saturating it with dust orders. An attacker could churn epochs inside a single block and force every short-dated order in the book into a refund — charging each of them the forfeit and denying them the trade — with no market movement at all. Reproduced by `test_epochChurnCannotExpireAnOrderEarly`.
- **Amendment.** An order is expired only when **both** its epoch budget has run out **and** at least `min(maxDelay, EXPIRY_BLOCK_FLOOR_MAX)` blocks have passed since its batch opened. `maxDelay` is the coherent floor because it is already the protocol's own statement of how long a batch may be made to rest before forced settlement: an order cannot be refunded for having rested too long until it has rested at least as long as the protocol is allowed to make it.
- **`EXPIRY_BLOCK_FLOOR_MAX` (7,200 blocks) is deploy-fixed and exists to bound governance.** Without it, governance could raise `maxDelay` to its parameter ceiling and push every refund weeks out — which would quietly undo PRD §11 case 12's guarantee that no reachable parameter setting strands funds. With it, the refund right stays reachable inside a window nobody can move.
- **Trader-facing effect.** A trader's stated `expiryEpochs` is now a *floor* on how long the order rests, not an exact deadline; the order stays fillable for longer than asked in the low-traffic case. That direction is the safe one — the alternative is a refund the trader did not ask for.

- **Floor-semantics analysis — 2026-08-26.** SR-3 is a user-visible change to DD-11's fill policy and to the DD-9 free-option analysis, so both were traced explicitly before it was recorded as settled. Two questions, answered in order:

  **(a) Can resting longer than requested push a trader's downside beyond `minOut`? No, and the reason is structural rather than incidental.** Eligibility is a single comparison — the settlement's uniform price, taken net of `f_slow`, against `Order.limitPriceX96` (`Clearing.meetsLimit`, reached from `_dropIneligible`). `limitPriceX96` is derived once at intake from `minOut / amountIn` and no code path rewrites it. Neither side of that comparison mentions time, an epoch number or a deadline, so an order resting for one epoch and an order resting for a hundred face **the same test**. Extra resting time changes only how many chances the order gets to meet its own limit, never what the limit is. Partial fills do not erode it either: each fill is priced at a P that satisfied the limit *for that settlement*, and `owedOut` accumulates across them, so cumulative output is at least the limit price times cumulative filled input — I8 pro rata, which is exactly what `testFuzz_I8_filledOrdersNeverBreachTheirLimit` already asserts and what `test_SR3_fillAfterTheStatedDeadlineStillHonoursTheLimit` now asserts *inside the extension window specifically*.

  **(b) Does the extension hand back optionality DD-9 removed? No — it moves optionality in the opposite direction.** The free-option surface §7.3 names is the trader's *exit*: post an order, watch the market, and retract if it moves against you. SR-3 does not create an exit; it **delays the only one that exists**. The refund becomes reachable later, never earlier, and it still costs `expiryForfeitBps`. Seen from the other side, a resting order is an option the trader has *written* to the market — fillable at their limit whenever the market finds that attractive — and lengthening its life makes what they wrote worth more to the market, not less. An adversary gains no free look either: they cannot shorten another trader's order, and extending their own only locks their own capital for longer behind an option they wrote. `test_SR3_extensionWindowIsNotAnExit` pins the no-exit half.

  **Ratification rationale.** SR-3 therefore leaves I8 exactly where it was and moves DD-9's free-option balance in the protocol's favour. Its cost is a real one and is stated rather than argued away: an order's exposure window is lengthened by up to `min(maxDelay, EXPIRY_BLOCK_FLOOR_MAX)` blocks past the trader's stated deadline — at the default `maxDelay = 300` that is 300 blocks, and it can never exceed the deploy-fixed 7,200. That is the price of closing the epoch-churn grief, and it is the cheaper side of the trade: the alternative is a refund the trader did not ask for, charged a forfeit, with the trade denied.

  **⚠️ One asymmetry noticed while tracing this, flagged rather than fixed.** The block floor is anchored to `epochs[epochSubmitted].openedAtBlock` — when the *batch* opened, not when the *order* was submitted. An order joining a batch that has already been open for `k` blocks therefore receives only `floorBlocks - k` blocks of floor protection, and none at all once `k ≥ floorBlocks`. Reachability is low: an epoch stays open that long only in a pool with no Fast-Lane flow for the whole window, and `forceSettle` becomes available at `maxDelay` — the same quantity as the floor at default settings. The residual grief costs an attacker 64 dust orders plus their own locked capital and forfeits, to deny one victim their trade and charge them ≤ 1%. Recorded as a known bound on SR-3's guarantee, not as a defect: closing it would mean storing a per-order submission block, which is a storage word per order on a hot path. **Owner call.**

## SR-4 — Tick-bitmap cursor arithmetic widened to `int256` (implementation, no DD)

- **Defect (high, permanent brick).** The active-range scan stepped a compressed-tick cursor by whole bitmap words and converted back to a tick by multiplying by the tick spacing — all in `int24`. One step past the initialised ticks on a wide-spaced pool overflows: `-257 × 32767` is already outside `int24`. The checked multiplication then panics *inside* settlement, and because the hook is immutable and bound to one pool at construction, every settlement for that pool would revert forever. Reproduced by `test_settlementSurvivesLargeTickSpacing`.
- **Fix.** The cursor is carried in `int256` and clamped to the tick range at the end, so an out-of-range walk returns the tick range's own boundary — which was always the intended behaviour and is a correct bound.
- **Not a design decision**, but recorded because it constrains deployment: the defect only bites at tick spacings of roughly 4,000 and above, so it would not have shown up on any conventional spacing (1/10/60/200) and would have been found only by whoever deployed the first wide-spaced pool.

## SR-5 — Skipped piggyback settlements are announced (amends DD-6)

- **Gap (low, observability).** Piggyback settlement is deliberately non-fatal: it runs inside a `try` so a batch that cannot clear never takes the carrying Fast-Lane swap down with it. The consequence is that a persistently failing settlement is *invisible* on chain.
- **Amendment.** The catch emits `SettlementSkipped(epoch)`. Monitoring watches for a batch that keeps announcing skips instead of clearing; `forceSettle`, which has no `try` around it, then surfaces the actual revert reason.

## SR-6 — Settlement must not run underneath an in-flight redemption (implementation, no DD)

- **Defect (high, permanent fund loss).** `_payoutOrder` pays the trader with
  `poolManager.take`. For native currency v4 makes that payment with a bare
  `call`, so control passes to the trader — and DD-14 refuses native ETH only as
  Slow-Lane *input*, so a `oneForZero` order on an ETH-quoted pool is accepted
  and pays out in native ETH. Every ETH-quoted deployment therefore has this
  reentry point live, with no exotic token required.
  `poolManager.swap` is `onlyWhenUnlocked`, not `onlyByTheUnlocker`, so from
  inside that callback the trader could run a Fast-Lane swap within the hook's
  own still-open redemption `unlock`. That swap's `afterSwap` settled the pending
  batch — `_settling` was false on the redemption path — completing an order
  whose `owedOut` `_payoutOrder` had already zeroed and paid. Control then
  returned to `_payoutOrder`, which finished with
  `if (o.status == FILLED) o.status = REDEEMED`, finalising an order that once
  again owed output. `redeem` reverts `AlreadyFinalised` from then on and the
  output is unreachable, permanently, on an immutable contract. Reproduced by
  `test/security/RedeemReentrancy.t.sol`.
- **Why the earlier review missed it.** The "Reviewed and found sound" note below
  argues two things, both individually true: `owedOut`/`amountInRemaining` are
  zeroed before the outbound `take`, and a reentrant `redeem` cannot nest an
  `unlock`. Neither covers the vector, because the vector is not a reentrant
  `redeem` — it is a reentrant `swap`. That note is superseded by this entry.
- **Fix.** `_settling` is now held across `_payoutOrder` as well as across
  settlement, so no settlement can begin underneath a redemption. Its meaning is
  widened accordingly, from "a settlement is running" to "no settlement may begin
  right now". Separately, and as defence in depth rather than as the primary
  guard, the `FILLED -> REDEEMED` transition is conditioned on `owedOut == 0`.
  Both are kept: SR-4 is the standing reminder that "unreachable by argument" is
  not the same as unreachable, and the failure this prevents is unrecoverable.
- **Severity, stated honestly.** The reentry hands control to `o.trader`, so an
  attacker can only strand *their own* order's output; there is no path to a
  third party's funds, and I2 holds throughout (the stranded amount is a surplus
  in custody, which is the safe direction —
  `test_I2_holdsAcrossAReentrantRedeem`). It is fixed anyway because the loss is
  permanent and the fix is three lines.

## SR-7 — `governance` may not be set to the zero address (implementation, no DD)

- **Gap (low, permanent loss of parameter control).** Neither the constructor nor
  `setGovernance` checked for `address(0)`. On an immutable hook `governance` is
  the only authority over `fBase`, `fSlow`, `k`, the cadence gates and the
  warehouse caps, and there is no recovery path, so a fat-fingered handover would
  freeze every parameter at whatever value it happened to hold. Raised by Slither
  (`missing-zero-check`, `events-access`).
- **Fix.** Both paths reject `address(0)`, and `setGovernance` now emits
  `ParameterUpdated("governance", old, new)` like every other parameter change —
  it is the most consequential one and was the only one that was silent.
  `test_governanceCannotBeHandedToTheZeroAddress`,
  `test_governanceHandoverIsAnnounced`.

# Audit amendments (2026-09-01)

An external security audit of the implemented hook found two confirmed
vulnerabilities and two lower-severity defects, all four in the layer that
decides *which* orders enter a batch and *who* provided the tokens a batch is
filled with. None of them touched the solvency core: `Clearing.fillRatio` makes
I2 and I4 hold whatever the price prediction says, and the 219-test suite —
invariants included — was green through every one of them. That is the reason
they are recorded here rather than folded into the DDs they amend: each narrows
a resolution that was already written down, and each was invisible to the
property that was supposed to cover it.

Every amendment below has regression tests that were run against the *unfixed*
contract first and observed to fail, in `test/security/ClampedBatchLimits.t.sol`,
`test/security/FillerAttribution.t.sol` and
`test/security/ExpiryAndCensorship.t.sol`.

These are agent-made calls under the same owner directive as the DD resolutions
above, and are subject to the same review and reversal. **SR-9 changes the
`settleWithFill` ABI**, which is the only externally breaking change in the set.

## SR-8 — The eligibility price must be the price the batch actually clears at (amends DD-5, DD-11)

- **Defect (high, I8 broken, no attacker required).** `_dropIneligible` screens
  each order's limit against `sol.priceX96`, a prediction made before the
  residual executes; payouts come from the pots, so the realised price is
  `pot1 / filled0`. `_predictedPrice` computed the prediction from the *totals*
  identity — `P = (residualOut + N1) / N0` — which is the solvency relation **at
  a fill ratio of one**. The general relation carries lambda:
  `P = (Y + lambda*N1) / (lambda*N0)`. Whenever the multi-range walk could not
  absorb the whole batch (four ranges exhausted, a zero-liquidity boundary, an
  infeasible segment) the batch clamped, lambda collapsed, and the prediction
  came out wrong by roughly `1/lambda` — **understated** for a zeroForOne
  residual and **overstated** for a oneForZero one, i.e. wrong in the unsafe
  direction for exactly the side whose limit was the binding one. Orders the
  realised price did not satisfy were admitted and filled through their
  `minOut`. In the reproduction a currency1 seller who demanded at least 2
  currency0 per currency1 received 1.002 — **50.1% of his stated minimum** — on
  a batch predicted at 0.130 that cleared at 0.997.
- **How it got in.** This is a regression introduced by the multi-range
  amendment to DD-5. The single-range predecessor, `Clearing.solve`'s
  `s.priceX96 = a * b`, was *correct under clamping*, because `a * b` is
  identically `Y / X`. `a * b` genuinely stops being the average price once the
  walk crosses a tick, so it had to be replaced — but it was replaced with a
  formula that only holds in the unclamped case.
- **Why no test caught it.** `testFuzz_I8_filledOrdersNeverBreachTheirLimit`
  submits a **single one-sided order** against the wide-range fixture. That
  batch never clamps and has no counter-side, so lambda is 1 and the wrong
  formula coincides with the right one. The stateful `invariant_I8_...` only
  asserts that consumed input produced *some* output, not that it met the limit.
- **Amendment (a).** `_predictedPrice` is taken from the residual itself:
  `P = residualOut / residualIn` for a zeroForOne residual and
  `residualIn / residualOut` for the other. This is exact for any number of
  ranges **and any fill ratio**, and it falls straight out of
  `Clearing.fillRatio`'s own algebra: equalising the two sides' implied prices
  gives `P = Y / X`, with the batch totals cancelling entirely. The `net0 == 0`
  special case disappears, because it was already computing exactly this.
- **Amendment (b), the one that matters.** `_assertLimitsHeld` re-runs the
  eligibility screen against the price the batch **really** cleared at, and
  reverts the settlement if any order it was about to fill fails it. The screen
  is now the optimisation — it keeps ineligible orders out of the residual
  sizing — and this is the guarantee. Reverting is the safe direction and it is
  cheap: nothing has been distributed, the residual unwinds with it, the
  piggyback path absorbs it, and the batch retries.
- **Tolerance.** `I8_TOLERANCE_PPM = 1` (0.0001%). The screen and the realised
  price are computed from different quantities — the sized residual versus the
  distributed pots — so they agree to within integer rounding rather than bit
  for bit. One part per million is orders of magnitude above that rounding, far
  below any economically meaningful breach, and a hundred times tighter than the
  tolerance I4 already runs with.
- **Liveness cost, acknowledged.** A settlement that reverts does not advance the
  cursor, so a *persistent* breach would pin the batch until `absoluteMaxDelay`.
  This is not a new class of exposure — `_assertUniformPrice` and `_applyFills`
  already revert — and with amendment (a) in place the prediction and the
  realisation agree to rounding on the curve path, so the assertion is expected
  to fire only on the filler path it was also written for.

## SR-9 — The external fill is attributed to its caller, and a no-op fill returns their capital (amends DD-7's Shape B)

- **Defect (high, theft).** Two defects on `settleWithFill` that composed.
  **(a)** The path was *deliver-first*: transfer the output currency in, then
  call, and the hook took `outCurrency.balanceOfSelf()` to be the delivery. That
  balance is unattributed — it is whatever anyone has ever sent this contract —
  so a caller could satisfy the curve floor out of tokens it never provided and
  still be paid the batch's entire input. Reproduced: a filler with **zero
  capital** was paid 1.999 ETH of input.
  **(b)** `_settleEpochInner` returns silently when the batch cannot settle
  (every order screened out, an infeasible pool, an emptied candidate set), and
  `settleWithFill` did not check. The caller's already-transferred delivery was
  never banked, never refunded, and simply stayed on the contract.
  Chained: front-run an honest filler with a swap that moves the price until
  every order in the batch fails its limit; their transaction *succeeds and does
  nothing*, stranding their capital; then call `settleWithFill` yourself,
  delivering nothing, and collect it.
- **Why no invariant fired.** Neither step touches ERC-6909 custody. I2
  conserves custody against obligations; a raw token balance sitting on the hook
  is outside both sides of that equation, and the test fixture's `_obligations()`
  does not model it either.
- **Amendment (a) — ABI change.** `settleWithFill()` becomes
  `settleWithFill(uint256 delivered)`. The caller declares the amount and
  approves this contract; `_acceptFillerDelivery` pulls exactly that much
  straight from the filler into the singleton. Attribution is exact by
  construction, and the tokens never rest on the hook at all. This does **not**
  reintroduce the callback DD-7's Shape B write-up rejected: `transferFrom`
  hands control to the *token*, not to the filler, and the filler is still paid
  last, after every state write.
- **Amendment (b).** `_settleEpochInner` returns whether it reached
  distribution. On the filler path a `false` becomes a revert, which returns the
  delivery with it. The curve paths keep the opposite convention deliberately: a
  no-op there must not take the carrying Fast-Lane swap down.
- **Amendment (c).** `sweepRecapture` now also sweeps any raw token balance on
  the hook to LPs. With (a) and (b) the filler path leaves none, but a mistaken
  transfer — or an order that named the hook itself as its beneficiary — still
  arrives with no owner, and this gives it one and gives anyone the means to
  move it there. The sweep **mints the raw balance into custody first**, which
  is load-bearing rather than tidy: `_recapture` pays a donation by *burning*
  ERC-6909, so crediting a raw balance to `lpClaimable*` without minting it
  would take the donation out of the traders' escrow and turn a stray donation
  into an insolvency.
- **A third consequence, fixed by SR-8 rather than here.** Accepting any
  delivery at or above the curve floor was described as unambiguously good —
  "every wei above the floor lands in the trader pots". It lands there *at a
  shifted price*: the realised price is `Y / X`, so over-delivering raises it,
  improving the currency0 sellers' execution and worsening the currency1
  sellers' by exactly the same amount. A filler could therefore improve one side
  straight through the other side's stated ceiling. `_assertLimitsHeld` refuses
  that. The identity check `_assertFillerNotInBatch` never could: `hookData`
  lets anyone name any beneficiary, so a filler and the order it favours are
  trivially different addresses.

## SR-10 — Expiry is monotone (amends SR-3)

- **Defect (low, temporary fund lock).** SR-3 added the block floor as
  `min(maxDelay, EXPIRY_BLOCK_FLOOR_MAX)` blocks since the batch opened,
  recomputed on every read from the **live** `maxDelay`. That made expiry
  non-monotone: governance raising `maxDelay` (300 to 7,200 is inside the
  parameter bounds) pushed the threshold out and turned already-expired orders
  back into unexpired ones. Not a cosmetic status flip — `_rollUnfilled`
  deliberately leaves expired orders behind and then deletes the epoch's index,
  so an expired order is reachable only through `redeem`, and an order that is
  no longer expired has no refund to claim and no index to be filled from. Its
  input was locked until the raised floor elapsed, bounded by
  `EXPIRY_BLOCK_FLOOR_MAX` at roughly a day.
- **Amendment.** `Order` carries a `uint64 expiryBlock`, stamped once at intake
  from the `maxDelay` in force then, and `_isExpired` reads the stamp. A stamp
  can only ever bring the refund closer. It packs into the order's first storage
  slot alongside `trader` and `zeroForOne`, so it costs no additional slot.
- **Note.** This also closes half of the asymmetry flagged at the end of SR-3 —
  the stamp is still anchored to `epochs[epochSubmitted].openedAtBlock` rather
  than to the order's own submission block, so that **owner call** stands
  unchanged.

## SR-11 — A screened-out order cannot censor a filler (amends DD-7's Shape B)

- **Defect (low, griefing).** `_assertFillerNotInBatch` walked every *loaded*
  candidate. Since `hookData` lets a submitter name any beneficiary, one dust
  order naming a competitor — with a limit price the market can never reach, so
  it costs a wei and never fills — made every `settleWithFill` from that address
  revert `InvalidFiller` for the life of the batch. Combined with DD-11's
  rolling, the block travelled forward into every batch after it.
- **Amendment.** The guard considers only candidates still `live` after the
  eligibility screen. An order that was screened out is not part of the batch
  being filled and has no self-dealing to guard against. The guard still holds
  for an order that is actually being filled.

## SR-12 — A minimum Slow-Lane order size (amends DD-6's work cap)

- **Defect (low, throughput griefing).** `MAX_ORDERS_PER_EPOCH` bounds a
  settlement's work by counting **orders**, not value, so the cheapest way to
  consume it is with orders that carry no value at all. Thirty-two dust orders
  whose limit price the market can never reach cost a wei each; the eligibility
  screen drops them every settlement and `_rollUnfilled` pushes them to the
  *head* of the next accepting batch, where they displace real orders into
  later epochs for as long as their `expiryEpochs` allows (up to 256). The
  repricing bill lands on whichever Fast-Lane trader carries the settlement.
  The cursor still advances, so this is SR-1's acknowledged residual cost turned
  deliberate rather than a freeze.
- **Amendment.** `minOrderSize0` / `minOrderSize1`: a governance-set floor on a
  single order, per direction, in that direction's own input-token units — the
  same denomination as `maxWarehouse*`, and for the same reason (a common
  numeraire would need the oracle PRD §9 forbids). Checked at intake, before any
  custody is taken.
- **Why this lever.** It prices the attack in the attacker's own locked capital,
  which is the one cost that scales with how long they sustain it, and the
  expiry forfeit taxes it again on the way out. The two obvious alternatives —
  charging orders that are repeatedly dropped, or capping how many times an
  order may roll — both reopen DD-9's free-option analysis and DD-11's rolling
  policy, which `docs/OPEN-QUESTIONS.md` already flags as the two resolutions
  most warranting a second look. That is a large bill for a throughput grief.
  The floor also only makes explicit something the fill arithmetic already
  imposes: `_computeFills` drops any order whose filled amount rounds to zero,
  so a sufficiently small order was never fillable.
- **Default is zero, i.e. off.** There is no unit-independent default worth
  shipping: a floor meaningful on an 18-decimal pool is nonsense on a 6-decimal
  one. This is a value the deployer must set with the pair in front of them, and
  until they do, behaviour is exactly as before.
- **Deliberately unbounded, matching `setWarehouseCaps`.** A ceiling would have
  to be a constant in token units, and no such constant is meaningful across
  decimal conventions. Nothing is conceded: a floor set absurdly high refuses
  *new* orders and nothing else, because the check sits before custody is taken
  — every existing claim stays redeemable and every expired one stays
  refundable. That is the same capability governance already holds through
  `maxWarehouse* = 0` and through `setPaused`, both documented, neither able to
  strand funds (PRD §11 case 12).
- **The floor applies at intake ONLY, and this is load-bearing.** A partial fill
  can leave an order's remainder below the floor. Applying it to rolling or
  filling would strand exactly the orders the hook has already taken custody of.
  `test_SR12_raisingTheFloorNeverStrandsARestingOrder` pins it.
- **Cost, stated.** It excludes small traders from the Slow Lane. On a pool
  whose Slow-Lane value proposition is size-sensitive execution that is
  acceptable; on a low-value-token pool the parameter needs care. It also raises
  the attacker's cost for the residual grief flagged at the end of SR-3, which
  runs on the same 64-dust-order primitive.

## SR-13 — The settlement residual is capped (CLOSES DD-5 and DD-12)

- **Defect (high, economic).** `docs/DD5-SIMULATION.md` measured, against the
  real contracts, that sandwiching the settlement residual is profitable at
  every governance-reachable `k` once the un-netted residual exceeds roughly
  30-50 bps of pool depth — by 20x-370x the tax at the default. PRD DD-12
  requires this resolved before mainnet; the register carried it as BLOCKING.
- **The key observation, which the original report did not draw.** Its own
  extraction model is `2*y*A*R/x^2` against an attacker cost of
  `2*f_base*A*y/x`. **`A` cancels.** Profitability therefore does not depend on
  the attacker's size, on `k`, or on trader slack — only on the residual:
  `unprofitable <=> R <= f_base * x`. Analytic break-even 0.285 ether against a
  measured 0.301 on a 95-ether pool: 5% agreement, no fitting.
- **Amendment.** `Clearing.PoolPoint` gains `maxResidualIn`, and `solve` clamps
  the target price so the residual cannot exceed it — expressed as a price bound
  so `residualIn`, `residualOut`, `priceX96` and `clamped` all stay consistent,
  exactly as the liquidity clamp already does. `KesselHook._residualCap` sizes
  it as `f_base * virtual reserve * residualCapBps`, once per settlement against
  the depth at spot, and the walk spends it down across ranges.
- **`residualCapBps` is bounded at 10,000 = exactly break-even.** This is the
  point of the mechanism: no reachable governance setting places the cap where
  the attack pays. The default is 5,000 — half of break-even, a 2x margin
  against the model's own error. The floor of 500 stops governance making a
  batch take an unreasonable number of epochs.
- **Why option 2 and not the report's recommended option 1.** §6 called a
  begin-of-epoch price band "the only one that bounds the attack independently
  of both trader behaviour and `k`". The cancellation shows the cap does too,
  and costs less: a band anchored at epoch open would tell a trader submitting
  into a fresh epoch that their fill lands within `±delta` of a price they can
  see, which is a two-sided bound known at submission and precisely the hedging
  surface I6 exists to close. A band's failure mode is also *refuse to settle*,
  which fights I11; the cap's is *fill less this epoch*, which is DD-11's
  existing partial-fill path.
- **Result.** Re-running the same harness: **zero profitable rows across every
  sweep**, at every residual size from 10 to 2,105 bps of depth, every slack
  from 10 to 5,000 bps, and every `k` including zero. Previously +5,745 at 500
  bps of slack; now -200.
- **Cost, stated.** A batch larger than the cap clears over more epochs, and a
  single settlement can move the clearing price by at most about
  `f_base * residualCapBps` (~15 bps at the defaults). This partly supersedes
  the gap-4 multi-range amendment: the walk still lets one settlement draw on
  several ranges, but a batch large enough to cross ticks is by construction
  larger than the cap, so "completes in one settlement" is no longer a property
  the walk delivers. Netting is entirely unconstrained — extraction on the
  coincidence-of-wants portion is exactly zero — so the mechanism's best case is
  untouched.
- **Test consequences, recorded because they look like regressions and are not.**
  Three existing tests asserted behaviour the cap deliberately changes, and each
  was rewritten to assert what it was actually for rather than relaxed:
  `test_batchCrossingAnInitialisedTick...` now asserts progress-per-settlement
  and eventual completion; the scaffold's residual-fee characterization now
  measures against what the settlement actually filled; and the non-convergence
  ladder was retuned onto a zero-liquidity pool, where the clearing price is the
  pure coincidence-of-wants ratio and is therefore uncapped by construction.

## Audit findings NOT acted on, and why

One finding from the same audit is deliberately left open, and one item is
recorded as a known property rather than a defect.

- **Settlement timing is attacker-selectable (design risk).** **CLOSED by SR-13** — the residual cap bounds the extraction directly, so the exposure is no longer bounded only by trader limits. Original note retained: DD-12 argues that
  running settlement in `afterSwap` stops the triggering trader improving their
  *own* execution, which is true. It does not stop them choosing the pool price
  at which the batch clears: displace the price, let `afterSwap` settle the
  batch into it, restore. `minSettleAge` constrains the batch's age, not the
  block or the price. The protection is each order's limit — which SR-8 has now
  made real — but the framing "the Slow Lane is sandwich-proof" should be
  narrowed to "sandwich-proof *within* a batch, and bounded across batches only
  by the trader's limit price". Closing it further needs a settlement-time
  sanity band, which is a protocol change touching DD-12 and PRD §7.6.
- **A gas-limited Fast-Lane swap can suppress piggyback settlement (low).**
  Under EIP-150's 63/64 rule a caller can size the transaction so the inner
  `try this.settleFromCallback(epoch)` runs out of gas; the catch absorbs it,
  `SettlementSkipped` fires, and the outer swap succeeds. A `gasleft()` floor
  before the `try` would fix it by reverting the carrying swap, which DD-6 and
  DD-8 explicitly forbid. `forceSettle` is the escape and I11 is unaffected, so
  this is recorded as a known property — and SR-5's event is exactly the signal
  that surfaces it.

## Reviewed and found sound (no change)

- **Caller verification** — every hook callback is `onlyPoolManager` via `BaseHook`; `unlockCallback` checks the PoolManager directly; `settleFromCallback` rejects any caller but the contract itself.
- **NoOp / `beforeSwapReturnDelta`** — the returned delta consumes the specified amount only after `take(..., claims: true)` has moved an equal amount into hook custody, and I2 checks custody against obligations under stateful fuzzing.
- ~~**Redemption reentrancy** — `owedOut` and `amountInRemaining` are zeroed before the outbound `take`, and a reentrant `redeem` cannot nest an `unlock` anyway.~~ **Superseded by SR-6 (2026-08-26).** Both clauses are true and neither is sufficient: the vector was a reentrant `poolManager.swap`, not a reentrant `redeem`.
- **Destination redirection** — `redeem` is permissionless in caller and fixed in destination; no path writes `Order.trader` after intake.
- **Fee-on-transfer and rebasing tokens are not supported**, and this is inherited from v4 rather than introduced here: v4's `settle` credits the balance actually received, so a fee-on-transfer input leaves the router's debt unsettled and the swap reverts. Documented rather than worked around, because a workaround would mean a second custody representation — the same reason DD-14 rejects native ETH.
- **Governance cannot strand funds.** Every setter is bounded; `setPaused` never blocks `redeem`; and SR-3's deploy-fixed ceiling closes the one route by which a parameter change could have delayed a refund indefinitely.

---

## Items the PRD's engineering review already resolved into requirements (NOT open decisions)

Per PRD §20 and §21, the following were originally open and were converted into hard constraints by the review. They are **not** tracked as decisions here — they live in `docs/CONSTRAINTS.md` and must simply be implemented as specified:

- Claim non-transferability until settlement (§5.1)
- Explicit async delta accounting for Slow-Lane intake (§3.2)
- Two-path settlement / no nested `unlock` (§8.3)
- Keeper-reimbursement bound, capped and sourced only from `f_slow` (§6.3)
- `donate()` execution context and empty-range fallback (§6.2)
- Disclosure that Fast-Lane sandwich resistance is mode-dependent, not absolute (§7.5)
- Hook-address-mining-must-follow-permission-resolution ordering (§8.1) — the ordering rule itself is a requirement; DD-8 (which permission to choose) is still open
- Invariants I4 (corrected), I9, I10, I11, I12 (added by the review)
