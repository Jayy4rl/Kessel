# CONSTRAINTS.md — Protocol Requirements, Invariants, and Assumptions

**Source of truth:** `docs/PRD.md`. This file extracts and organizes everything the PRD marks `[REQUIRED]` / `[CONSTRAINT]`, plus the numbered invariants (I1–I12) and assumptions (A1–A4), so implementation and review work can check against a single list instead of re-deriving it from prose each time.

**How to read this file:**
- **Requirements / constraints** = must hold in the shipped protocol; the mechanism is wrong if violated. Failing to satisfy one of these is a bug, not a design choice.
- **Invariants (I1–I12)** = requirements restated as code-checkable properties; I1–I10 and I12 are safety invariants (must always hold), I11 is a liveness invariant (guarantees progress, not an instantaneous property).
- **Assumptions (A1–A4)** = empirical/economic premises the mechanism's *value proposition* depends on. They are not code-enforceable and are not proven by passing tests — they must be validated against data or explicit trust assumptions about the target chain. Do not treat an assumption as satisfied just because the invariants pass.
- Items that are still open design decisions (see `docs/OPEN-QUESTIONS.md` / `docs/DECISIONS.md`) are noted inline as "**depends on DD-N**" — the constraint itself is fixed, but its concrete implementation is not yet chosen.

---

## 1. Mechanism-defining requirements

### 1.1 Shared curve, per-swap lane choice
Relevant sources: 
- See `docs/PRD.md`(§2.1)
- See `docs/PRD.md`(§2.2)
- depends on DD-1(See `docs/DECISIONS.md`)


### 1.2 Fast Lane
Relevant sources: 
- See `docs/PRD.md`(§2.3)
- See `docs/PRD.md`(§2.3, §6)
- See `docs/PRD.md`(§4.1)
- **Ambiguity to note:** Also see `docs/PRD.md`(§2.3/§3.1/§4.1 )
- see `docs/OPEN-QUESTIONS.md`.
- depends on DD-2(See `docs/DECISIONS.md`). See `docs/PRD.md`(§7.5)

### 1.3 Slow Lane
Relevant sources: 
- See `docs/PRD.md`(§2.4, §7.2, §7.3, I6, I4)
- `fee_slow` is strictly less than the Fast-Lane baseline: `0 ≤ f_slow < f_base` at all times (I10)
- **depends on DD-9** (See `docs/DECISIONS.md`)
- **Slow-Lane orders are exact-input only.** See `docs/PRD.md`(§3.2, §17)
- **The trader's claim and the hook's ERC-6909 custody balance are distinct objects with different owners/lifecycles.** See `docs/PRD.md` (§5.1, §7.3)
- **The claim MUST be non-transferable until settled depends on DD-15** 
- See `docs/PRD.md` (§3.2, §5.3)

### 1.4 Settlement
Relevant sources: 
- See `docs/PRD.md` (§3.3, §4.3, §4.4, §7.4, §8.3, §10, I4, I11)
- **depends on DD-5, DD-6, DD-7, DD-11** (See `docs/DECISIONS.md`)

### 1.5 LP economics and recapture
Relevant sources: 
- See `docs/PRD.md` (§6.1, §6.2, §6.3, §9, I7)
- **depends on DD-10** (See `docs/DECISIONS.md`)

### 1.6 Hook architecture and callbacks
Relevant sources: 
- See `docs/PRD.md` (§8.1, §8.2, §8.3, §8.4, I1)
- (**DD-8**) (See `docs/DECISIONS.md`)

### 1.7 External dependencies
Relevant sources: 
- See `docs/PRD.md` (§9, I7)

---

## 2. Invariants (must hold in code; property-tested per PRD §15)

Relevant sources: 
- See `docs/PRD.md` (§15) 

---

## 3. Security / adversarial constraints (§12)

Relevant sources: 
- See `docs/PRD.md` (§12) 

---

## 4. Accounting / custody constraints

Relevant sources: 
- See `docs/PRD.md`(§5.1, §5.2, §5.3, §14)

---

## 5. Implementation-level constraints (v4-specific, cross-cutting)

Relevant sources: 
- See `docs/PRD.md` (§5.4, §11 edge case 8, 10, 12)
- (see §1.6 above) (See `docs/DECISIONS.md`) (DD-8).

---

## 6. Assumptions (NOT requirements — economic premises to validate, not code invariants)

| ID | Assumption | Notes |
|----|------------|-------|
| A1 | Single-crossing on time holds for the target pair | Willingness-to-pay-for-immediacy is monotonically increasing in time-value-of-trade, and enough flow has low time-value that a feasible fee spread induces genuine separation. **PRD states this must be validated with data, not code, before/during build** — measure the share of arbitrage volume bound to this pool and retail's realized delay cost. If retail's delay cost exceeds the fee saving, no one picks the Slow Lane and the mechanism degenerates to a single-fee pool. (§1.4) |
| A2 | The pool is a marginal venue for enough flow | Delaying flow must not simply push all of it to another venue (the "delay can be unbundled" risk). (§13) |
| A3 | Honest priority-fee ordering by the sequencer | Only relevant if using the priority-fee tax (DD-2 option a); the tax is defeated on a chain/sequencer that does not honor this. (§13, §12) |
| A4 | Anti-hedging holds only against deterministic, risk-free hedging | Informed traders retain a distributional/expected-value edge in the Slow Lane — this is the same irreducible Glosten-Milgrom adverse-selection floor, not a defect. The spec and any demo must not claim the Slow Lane removes distributional/EV hedging, only deterministic risk-free hedging. (§7.2, §13) |

---

## 7. Explicitly out of scope - See `docs/PRD.md` (§17) — do not build these under this PRD


