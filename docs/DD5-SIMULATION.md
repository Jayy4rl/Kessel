# DD-5 adversarial economic simulation — findings

**Status: CLOSED 2026-09-01 by the residual cap (SR-13). Superseded below.**
**Original status: BLOCKING. Date: 2026-08-26. Harness: `test/economic/DD5Manipulation.t.sol`.**

> **2026-09-01 — closure.** Option 2 of §6 was implemented, with the cap derived
> analytically rather than tuned. Re-running this same harness against the
> capped contract turns **every** row of **every** sweep negative: there is no
> longer a residual size, a `k`, an attacker size, or an amount of trader slack
> at which sandwiching the settlement residual pays. The tables below are the
> PRE-cap measurements and are kept as the record of what the defect was. See
> §8 for the post-cap numbers and `SR-13` in `DECISIONS.md` for the derivation.

This document reports the result of the DD-5 manipulation simulation. It does
**not** ratify DD-5 and it does not change any code. It exists because the
question it answers is invisible to the invariant suite: every run below leaves
I1–I12 intact whether the attack pays or not, so a green suite is not evidence
either way and must not be cited as such.

---

## 1. The question, and how it was answered

> Can an adversary move the pool price in the settlement block, skew the uniform
> clearing price, and profit by more than the priority-fee tax costs them?

**Yes — comfortably, at every governance-reachable `k`, whenever the batch's
un-netted residual exceeds roughly 30–50 bps of pool depth.**

The simulation runs the real `KesselHook`, the real `Clearing.solve` and a real
v4 pool; nothing is modelled. Each cell executes the attack end to end and reads
the attacker's token balances, so there is no modelling error to argue about.

The attack is the strongest form the design permits, and note what the piggyback
design forces:

```
tx1   attacker Fast-Lane swap of size A at priority p
      -> its afterSwap settles the pending batch at the price A just created
tx2   attacker unwinds
```

The perturbation and the settlement are **atomic** — a Fast-Lane swap settles a
due batch whether or not its sender wants it to — so the attacker must commit to
`A` before seeing the batch clear. That is a genuine (and previously unstated)
property of DD-6, and it is not enough.

**Extraction** is measured as `pnl(attack with a batch pending) − pnl(identical
two swaps with no batch pending)`. Differencing against the no-batch control is
what separates value taken *from the batch* from the ordinary round-trip cost of
two swaps. **Tax** is the Kessel priority-fee tax actually paid: the LP fee above
`f_base` on both legs. All figures are in units of 1e12 wei of currency1, marked
at the pre-attack spot. Pool depth is ~95 ether per side.

---

## 2. The sweep

`forge test --match-path 'test/economic/DD5Manipulation*' -vv`

### 2.1 Batch size × residual-after-netting × k

Trader limit slack held at a deliberately permissive 50%, to isolate the
mechanism. Section 4 relaxes that.

| k | batch | residual (bps of batch) | best A | extraction | tax | net P&L | verdict |
|---|-------|------|--------|-----------|-----|---------|---------|
| 0 | 1e18 | 0 | 0.001e18 | 0 | 0 | −6 | no |
| 0 | 1e18 | 10000 | 2.0e18 | 39,654 | 0 | +27,633 | profitable |
| 0 | 20e18 | 10000 | 20e18 | 7,377,606 | 0 | +7,151,214 | profitable |
| **500** (default) | 1e18 | 0 | 0.001e18 | **0** | 1 | −7 | no |
| **500** | 1e18 | 2000 | 0.2e18 | 791 | 201 | −615 | ext > tax |
| **500** | 1e18 | 6000 | 1.2e18 | 14,164 | 1,201 | +5,755 | profitable |
| **500** | 1e18 | 10000 | 2.0e18 | 39,634 | 2,001 | +25,612 | profitable |
| **500** | 5e18 | 10000 | 10e18 | 956,572 | 10,001 | +878,480 | profitable |
| **500** | 20e18 | 10000 | 20e18 | 7,374,606 | 20,001 | +7,128,404 | profitable |
| 5,000 | 20e18 | 10000 | 20e18 | 7,347,569 | 200,010 | +6,923,080 | profitable |
| 100,000 (`K_MAX`) | 1e18 | 10000 | 1.0e18 | 19,009 | 94,094 | −81,091 | no |
| 100,000 (`K_MAX`) | 20e18 | 10000 | 20e18 | 7,092,599 | 1,880,094 | +5,003,164 | profitable |

At the default `k`, extraction runs **20×–370× the tax**.

### 2.2 Netting is a complete defence — for the matched part only

Batch fixed at 20e18, `k = 500`:

| residual after netting | extraction | tax |
|---|---|---|
| 0% (perfect CoW) | **0** | 1 |
| 10% | 59,588 | 2,001 |
| 25% | 386,954 | 5,001 |
| 50% | 1,645,057 | 10,001 |
| 100% | 7,374,606 | 20,001 |

Extraction is **exactly zero** on a perfectly matched batch and scales as roughly
the *square* of the surviving residual. The coincidence-of-wants half of the
design does what FM-AMM promises. The un-netted half gets nothing.

### 2.3 Against the malicious-batch-operator bound

FM-AMM's zero-arbitrage result assumes *open* arbitrage competition; a sealed
batch removes it, so the applicable regime is Canidio–Fritsch's malicious
batch-operator bound of at most **half** the CPAMM loss. Operationalised as: the
same attacker sandwiching the same net flow when it is executed as an ordinary
Fast-Lane swap instead of a batch.

| batch (one-sided) | Kessel extraction | CPAMM benchmark | half-bound |
|---|---|---|---|
| 1e18 | 19,935 | 19,885 | 9,942 |
| 5e18 | 495,227 | 493,962 | 246,981 |
| 20e18 | 7,374,606 | 7,355,179 | 3,677,589 |

**Kessel sits at ~100.3% of the CPAMM benchmark — a fraction above it, and about
2× the half-bound.** For the residual portion, batching buys no protection at
all; the marginal excess over CPAMM comes from the residual's own interaction
with the batch price.

### 2.4 Where it turns a profit

One-sided batch, `k = 500`, permissive slack:

| residual | as bps of depth | extraction | tax | net P&L |
|---|---|---|---|---|
| 0.1e18 | 10 | 49 | 25 | −125 |
| 0.2e18 | 21 | 199 | 50 | −150 |
| **0.5e18** | **52** | 9,933 | 1,000 | **+2,932** |
| 1e18 | 105 | 39,615 | 2,000 | +25,600 |
| 20e18 | 2,105 | 7,374,307 | 20,000 | +7,128,131 |

**Crossover: ~30–50 bps of pool depth.** Below it the attacker loses money;
above it, profit grows quadratically in the residual while the tax grows only
linearly in `A`.

---

## 3. Why the tax cannot be made to bind

Three reasons, all structural:

1. **Wrong exponent.** Extraction ≈ `2·Y·A·R/X²` — quadratic in the residual.
   The tax is `2·A·k·p/1e15` — linear. Whatever `k` is chosen, there is a
   residual size above which extraction wins.
2. **The cap saturates.** `MAX_FAST_FEE` (5%) is a deploy-fixed `constant`.
   At `k = K_MAX` the fee saturates at ~0.47 gwei of priority; above that the
   attacker bids more for position and pays **no additional tax**. The tax
   cannot scale with the attacker's willingness to pay.
3. **The break-even `k` is not a usable operating point.** Break-even needs
   roughly `k ≈ 10,550 · R` (R in ether, on this pool). At R = 2 ether that is
   `k ≈ 21,000` — an extra 2.1% LP fee per gwei of priority on *every* Fast-Lane
   swap, ordinary retail flow included. At R = 20 ether the required `k` exceeds
   `K_MAX` and is unreachable. The `k` that stops the attack destroys the lane
   it is charged on.

---

## 4. The bound that does bind: trader limit slack

This is the most important table in the report and the one that decides how
serious the finding is.

An order is eligible only while the **skewed** clearing price still meets its
limit. If the attacker's skew pushes the price past every order's limit, the
whole batch drops out, nothing settles, and the attacker is left holding a
position with no victim flow to sandwich — a pure loss.

Batch 0.5e18 one-sided, `k = 500`:

| trader slack | best A | extraction | tax | net P&L | batch filled |
|---|---|---|---|---|---|
| 10 bps | 0.05e18 | 0 | 50 | −350 | **0** |
| 25 bps | 0.05e18 | 0 | 50 | −350 | **0** |
| 50 bps | 0.05e18 | 0 | 50 | −350 | **0** |
| 100 bps | 0.05e18 | 499 | 50 | +149 | 0.5e18 |
| 500 bps | 2.0e18 | 19,760 | 2,000 | +5,745 | 0.5e18 |

At ≤ 50 bps of slack the batch does not fill at all — though on this pool that is
because the batch's *own* price impact already exceeds the slack, not because of
the attacker. Sized so the batch's own impact is small (0.2e18, ~20 bps), the
attacker's best net P&L is **negative at every slack from 30 bps to 1000 bps**:
the `f_base` cost of two legs exceeds what the constrained skew can extract.

**So the honest summary is narrower than "profitable everywhere":**

- Extraction is bounded by the slack traders leave in their own `minOut` — which
  is I8 working exactly as designed. A trader who sets a tight limit cannot be
  skewed past it; they simply do not fill.
- The attack is profitable when the residual is large relative to pool depth
  **and** traders have left enough slack to absorb both the batch's own impact
  and the attacker's skew. A large batch necessarily needs loose limits to fill
  at all, so those two conditions arrive together.
- The binding cost on the attacker is `f_base` on two legs, **not** the `k` tax.
  At the default `k`, the tax is about one sixth of the `f_base` bill.

---

## 5. What DD-5 and DD-12 may and may not claim

Supported by this simulation:

- P is not a spot reading; skewing it requires actually trading against the pool.
- Netting eliminates extraction on the matched portion of a batch, exactly.
- I8 bounds each trader's realised downside under manipulation; a tight limit is
  a real defence.
- The piggyback design forces the perturbation and the settlement into one
  atomic transaction, so the attacker cannot condition `A` on the outcome.

**Not** supported, and must not be claimed anywhere:

- That the priority-fee tax makes settlement-residual front-running unprofitable.
  It does not, at any reachable `k`. DD-12 already says "mitigation, not
  elimination"; this report supplies the magnitude, which is 1–2 orders of
  magnitude short at the default `k`.
- That batching protects the residual. On the residual it measures at ~100% of
  the plain-CPAMM sandwich, i.e. ~2× the malicious-batch-operator half-bound.

---

## 6. Options that would close it — outlined, not implemented

None of these is implemented and none should be until the owner decides. Each is
a protocol change touching settlement's core loop.

1. **Begin-of-epoch price commitment.** Record `sqrtPrice` when the epoch opens
   and clamp the settlement-time `a` to within `±δ` of it, refusing to settle
   outside the band. Bounds the skew at `δ` by construction, independent of `k`.
   Cost: a batch cannot settle through a genuine large price move, which fights
   I11; needs the `absoluteMaxDelay` escape to be re-argued.
2. **A netting requirement.** Refuse to settle when the residual exceeds a
   bounded fraction of active liquidity; roll the excess. Attacks the quadratic
   term directly, since extraction is a function of the residual alone.
   Cost: large batches take more epochs, and the cap is another immutable
   constant to get right before mining.
3. **A protocol-set floor on limit tightness**, or a default `minOut` derived
   from settlement-time spot rather than accepted verbatim. Turns Section 4's
   accidental defence into a guaranteed one. Cost: refuses orders traders
   intended.
4. **Do nothing, and restate the claim.** Ratify DD-5 on the netting result
   alone, and document in the PRD and any demo that the un-netted residual is as
   sandwichable as an ordinary swap. This is honest and requires no code change,
   but it materially narrows §7.4/§7.6(a).

Option 1 is the only one that bounds the attack independently of both trader
behaviour and `k`.

---

## 7. Reproducing

```bash
forge test --match-path 'test/economic/DD5Manipulation*' -vv
```

Each test is independent and prints its own table. `test_DD5_sweep_*` is split
by `k` because a single test deploying ~250 fresh pools exhausts the EVM memory
limit.


---

## 8. Closure (2026-09-01) — the residual cap

### The derivation, which makes the cap analytic rather than tuned

This report's own extraction model is

    extraction  =  2 * y * A * R / x^2        (currency1)

against an attacker cost, established in §4 as the binding one, of `f_base` on
each of two legs:

    cost        =  2 * f_base * A * y / x .

**`A` appears linearly on both sides and cancels.** That is the whole result.
Whether the attack pays is not a question about the attacker's size, about `k`,
or about how much slack traders leave — all three drop out. It is decided by the
residual alone:

    unprofitable   <=>   R  <=  f_base * x

where `x` is the pool's virtual reserve of the residual's input currency.

Checked against §2's own sweep with no fitting: the analytic break-even is
`0.003 x 95 = 0.285` ether and the measured crossover is `0.301` ether — 5%
agreement. §2's "roughly 30-50 bps of pool depth" is this line.

`KesselHook._residualCap` implements `R_max = f_base * x * residualCapBps`, with
`residualCapBps` defaulting to 5,000 (half of break-even, a 2x margin against
the model's own error) and hard-capped at `RESIDUAL_CAP_BPS_MAX = 10_000`. No
reachable governance setting can place the cap above break-even.

### Correcting §6's recommendation

§6 says option 1 (a begin-of-epoch price band) is "the only one that bounds the
attack independently of both trader behaviour and `k`". The cancellation above
shows option 2 does too, and it costs materially less:

- A band anchored at epoch open would tell a trader submitting into a fresh
  epoch that their fill lands within `±delta` of a price they can see. That is a
  two-sided bound known at submission — precisely the hedging surface I6 exists
  to close. The cap carries no submission-time information: it is a function of
  settlement-time liquidity and price only.
- A band's failure mode is *refuse to settle*, which fights I11. The cap's is
  *fill less of the batch this epoch* — the partial-fill path DD-11 already
  specifies, SR-1 already made safe, and the tick clamp already exercises.

### Post-cap measurements

Same harness, same pool, same sweeps.

| sweep | pre-cap | post-cap |
|---|---|---|
| crossover in residual size (10 -> 2,105 bps of depth) | profitable above ~30-50 bps | **net P&L negative at every size**: -125, -200, -500, -1001, -2000, -4990, -20281 |
| vs trader slack, batch 0.5e18 | +149 at 100 bps, +5,745 at 500 bps | **-200 at every slack**, 10 bps through 5,000 bps |
| extraction as bps of batch, slack 30-1000 bps | rises with slack | **-40 at every slack**; extraction pinned at 1 bp of batch |
| `k = 0` (no tax at all) | profitable | **negative at every row** |

Profitable rows across the whole sweep, at every `k` including `k = 0`: **zero**.

### A correction to this report's own verdict column

§2's tables labelled a row PROFITABLE on `extraction > tax`. That isolated the
priority-fee tax, which was the right lens while the question was whether the
tax could be made to bind — §3 shows it cannot. Now that the closure is
`f_base`-based, that label reports "PROFITABLE" for rows where the attacker
loses money. The harness now reports net P&L, matching §4's own framing.

### What is now claimable

Added to §5's supported list:

- The residual sandwich is unprofitable at **every** attacker size, every `k`
  including zero, and every amount of trader limit slack, because the cap
  bounds the one quantity the attacker's profitability actually depends on.
- I8 remains a real defence but is no longer the *only* one. §4's "the bound
  that does bind is trader limit slack" is superseded: the bound that binds is
  now the cap, which does not depend on trader behaviour.

Still not claimable, unchanged:

- That the priority-fee tax makes it unprofitable. It does not, at any `k`. The
  cap does.

### Cost

A batch larger than the cap clears over more epochs. At the defaults a single
settlement moves the clearing price by at most about
`f_base * residualCapBps` ~ 15 bps, and consumes at most 0.15% of one side's
virtual reserves. Netting is unconstrained: extraction on the
coincidence-of-wants portion is exactly zero (measured, `resBps=0` rows), so the
cap never touches the mechanism's own best case.
