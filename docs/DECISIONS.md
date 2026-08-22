# DECISIONS.md — Design Decisions Register

**Source of truth:** `docs/PRD.md` §20 (Design Decisions Register) and §21 (Revision Summary). This file mirrors that register so decisions can be tracked and dated as they are resolved, without editing the PRD itself.

**Rule:** Nothing in this file resolves a decision. Every item below is `OPEN` because the PRD leaves it open. A decision moves to `RESOLVED` only when a human/design-review explicitly makes the call — at that point, add a `Resolution` line (date, chosen alternative, rationale, who decided) rather than deleting the row. Do not infer a resolution from a PRD "recommendation" — several `OPEN` items carry a recommended alternative in the PRD prose, but a recommendation is not a decision (see `docs/OPEN-QUESTIONS.md` for why this distinction matters here).

Status as of this document's creation: **all 15 decisions are OPEN.**

---

## DD-1 — Default lane when `hookData` is empty
- **Status:** OPEN
- **Alternatives:** (a) default to FAST at `f_base`; (b) default to a standard static-fee lane; (c) revert.
- **PRD section(s):** §2.2, §11 (edge case 9), §17
- **Coupled to:** DD-2
- **PRD notes:** Determines behavior for most aggregator/unaware-caller flow; PRD flags this as high-priority to resolve early. PRD names (a) as a "recommendation to evaluate," not a chosen answer.
- **Resolution:** _none_

## DD-2 — Urgency signal & target chain
- **Status:** OPEN
- **Alternatives:** (a) priority-fee tax on a priority-ordered L2 (e.g., OP-Stack: Unichain, Base, OP Mainnet, Blast); (b) flat/state-based fee, required if targeting L1.
- **PRD section(s):** §2.3, §4.1
- **Coupled to:** DD-1, DD-8; also determines the Fast-Lane sandwich-resistance profile (§7.5)
- **PRD notes:** Not a cosmetic choice — the two modes have opposite sandwich-resistance properties (§7.5) and the priority-fee tax is stated to "likely not work at all on Ethereum L1" (Paradigm). Whichever is chosen, the target chain's `tx.gasprice - block.basefee` semantics must be verified to match the sequencer's actual ordering rule before relying on it.
- **Resolution:** _none_

## DD-3 — Fast→Slow fee subsidy
- **Status:** OPEN
- **Alternatives:** (a) passive — both fees accrue to LPs, `f_slow` is a fixed low constant; (b) active — Fast-Lane premium directly offsets `f_slow` toward zero.
- **PRD section(s):** §2.5, §4.2
- **Coupled to:** I10 (`0 ≤ f_slow < f_base` must hold under either mode)
- **PRD notes:** PRD recommends building (a) first and treating (b) as an extension, but does not resolve this as the shipped design.
- **Resolution:** _none_

## DD-4 — `k` calibration and governance bounds
- **Status:** OPEN
- **Alternatives:** any value of `k` in `tax = k * priorityFeePerGas`, within a bounded, governance-adjustable range (bounds fixed at deploy since the hook is immutable).
- **PRD section(s):** §4.1
- **Coupled to:** —
- **PRD notes:** PRD states there is no closed-form optimum — it depends on flow composition (too high overtaxes and drives away benign-urgent flow; too low leaks premium to the sequencer). `k` must be adjustable within pre-set bounds, not hardcoded to a single value.
- **Resolution:** _none_

## DD-5 — Uniform clearing-price definition (P) ⚠️ highest priority per PRD
- **Status:** OPEN
- **Alternatives:** (a) pool's marginal price after executing the net residual (FM-AMM style); (b) pool's pre-batch spot price; (c) time-weighted price over the deferral window.
- **PRD section(s):** §4.3, §7.4
- **Coupled to:** DD-6 (cadence); §7.6(a) settlement-residual front-running
- **PRD notes:** PRD explicitly calls this "the single most important unresolved algorithmic choice in the Slow Lane" and recommends (a) as theoretically grounded, but does not choose it. A naive "spot price at settlement block" is explicitly stated to be unacceptable regardless of which alternative is picked. Whatever is chosen must be pinned down as exact pseudocode (netting → residual → P → apply-to-all-orders) and pass the manipulation-resistance tests in PRD §15.
- **Resolution:** _none_

## DD-6 — Settlement cadence
- **Status:** OPEN
- **Alternatives:** (a) fixed block interval N; (b) fixed wall-clock time T; (c) piggyback on the next Fast-Lane swap touching the pool; (d) keeper-triggered on a schedule.
- **PRD section(s):** §4.4, §10
- **Coupled to:** DD-5, DD-7; §7.6 (settlement-MEV surfaces)
- **PRD notes:** PRD recommends (c) with a max-delay fallback (tied to I11), but flags that (c) gives unbounded delay in quiet pools and interacts with the piggyback-selection-MEV surface (§7.6b). Not resolved.
- **Resolution:** _none_

## DD-7 — Settlement trigger (keeperless vs. keeper)
- **Status:** OPEN
- **Alternatives:** piggyback + permissionless safety-valve force-settle; or a scheduled/keeper-triggered settlement.
- **PRD section(s):** §10
- **Coupled to:** DD-6; §7.6(b) piggyback selection MEV
- **PRD notes:** If a keeper exists, it must obey I7 (cannot capture the Fast-Lane premium) and the reimbursement bound in §6.3. This decision is described by the PRD as effectively riding on the same choice as DD-6 (cadence) rather than being fully independent — see `docs/OPEN-QUESTIONS.md`.
- **Resolution:** _none_

## DD-8 — `afterSwap` hook permission ⚠️ blocks CREATE2 address mining
- **Status:** OPEN
- **Alternatives:** grant `afterSwap: true` (needed if premium routing/accounting happens post-swap) or `afterSwap: false` (if fee routing lives entirely inside `beforeSwap`).
- **PRD section(s):** §8.2
- **Coupled to:** §8.1 (must be resolved **before** the hook address is mined — v4 encodes permissions in the address, and the address is immutable once deployed)
- **PRD notes:** This is the one decision with a hard, irreversible deadline: mining the hook address before resolving DD-8 is not correctable later. The PRD's own "coupled to" note only names the mining-order constraint — it does not explicitly cross-reference which other decisions (e.g., DD-3, DD-10, DD-12) determine whether `afterSwap` is actually needed. See `docs/OPEN-QUESTIONS.md` for this gap.
- **Resolution:** _none_

## DD-9 — Cancellation policy
- **Status:** OPEN
- **Alternatives:** (a) fully non-cancellable until settlement; (b) cancellable with a forfeited fee sized to remove option value.
- **PRD section(s):** §7.3
- **Coupled to:** non-transferability (already a hard requirement, not open — see `docs/CONSTRAINTS.md`)
- **PRD notes:** PRD recommends (a) for v1, noting (b) requires sizing a volatility-dependent forfeit correctly, which is hard. Not resolved.
- **Resolution:** _none_

## DD-10 — Recapture distribution
- **Status:** OPEN
- **Alternatives:** (a) all in-range LPs pro rata via `donate()`; (b) only LPs whose liquidity actually served the trade.
- **PRD section(s):** §6.2
- **Coupled to:** the empty-range `donate()` fallback (already a hard requirement — see `docs/CONSTRAINTS.md`)
- **PRD notes:** PRD calls (a) "the simplest defensible choice" but requires the team to decide and document explicitly.
- **Resolution:** _none_

## DD-11 — Failed-`minOut` policy
- **Status:** OPEN
- **Alternatives:** (a) order does not execute, input refunded; (b) order rolls into the next settlement epoch; (c) partial fill.
- **PRD section(s):** §3.3, §11 (edge case 4)
- **Coupled to:** —
- **PRD notes:** PRD calls (a) simplest and most predictable, but requires whatever is chosen to be deterministic and stated in the claim terms.
- **Resolution:** _none_

## DD-12 — Settlement-transaction MEV mitigation
- **Status:** OPEN
- **Alternatives:** (i) define P so front-running the residual is unprofitable; (ii) unpredictable/randomized cadence; (iii) execute the settlement residual as its own priority-taxed transaction.
- **PRD section(s):** §7.6
- **Coupled to:** DD-5, DD-6
- **PRD notes:** PRD states this is the mechanism's largest residual MEV surface and must be resolved before mainnet, covering both front-running the settlement residual (§7.6a) and piggyback selection MEV (§7.6b).
- **Resolution:** _none_

## DD-13 — Force-settle griefing guard
- **Status:** OPEN
- **Alternatives:** minimum batch age before force-settle is permitted; and/or a minimum batch size.
- **PRD section(s):** §12
- **Coupled to:** DD-6, I11 (liveness)
- **PRD notes:** Needed to prevent a griefer from repeatedly forcing tiny, unfavorable settlements once permissionless force-settle exists.
- **Resolution:** _none_

## DD-14 — Native-ETH Slow-Lane input
- **Status:** OPEN
- **Alternatives:** (a) reject native ETH as Slow-Lane input outright; (b) special-case it (e.g., wrap on intake).
- **PRD section(s):** §3.2, §5.3, §11 (edge case 14)
- **Coupled to:** —
- **PRD notes:** Native ETH cannot be held as an ERC-6909 claim the way an ERC-20 can. Until decided, the Slow-Lane intake path must not assume ERC-20-style custody for native ETH.
- **Resolution:** _none_

## DD-15 — Trader claim representation (and redemption model)
- **Status:** OPEN
- **Alternatives:** (a) storage record keyed by `orderId` (recommended); (b) a distinct receipt token. Redemption model (push vs. pull, §3.4) is folded into this decision by the PRD.
- **PRD section(s):** §5.1, §3.4
- **Coupled to:** claim non-transferability (already a hard requirement regardless of which alternative is chosen — see `docs/CONSTRAINTS.md`)
- **PRD notes:** PRD recommends (a) for representation and pull-based redemption for v1, but does not resolve either. Note: representation (storage record vs. token) and redemption mechanics (push vs. pull) are logically separable questions that the PRD bundles under one DD number — see `docs/OPEN-QUESTIONS.md`.
- **Resolution:** _none_

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
