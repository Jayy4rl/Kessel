# PRD ↔ as-built reconciliation

**Date: 2026-08-26. Status: a list, not a change.**

`docs/PRD.md` is the spec of record and is not edited here — that is the owner's
call (and the standing rule). This file lists every point at which the PRD and
the shipped code currently tell different stories about the settlement core, so
the two can be brought back into line deliberately rather than by whoever reads
one of them next and assumes it is current.

Each entry states what the PRD says, what the code does, why, and what the PRD
would have to say to match. Nothing here is a defect unless it says so.

---

## A. Divergences that change what the protocol does

### A1. The clearing price is the residual's **average** price, not its marginal price
- **PRD §4.3 / §20 DD-5:** "the pool's marginal price after executing the net residual (FM-AMM style)".
- **Code (`src/settle/Clearing.sol`):** `P = a·b`, the average execution price of
  the `a → b` move. The post-residual marginal price is `b²`.
- **Why:** for every order to clear at P *and* the hook to be exactly solvent,
  the residual's realised average price must equal P by definition. Clearing at
  `b²` leaves the hook a surplus on every settlement — an uncapped implicit fee
  that varies with batch size, charged to Slow-Lane traders on top of `f_slow`
  and invisible to I10. Argued in full in DD-5.
- **PRD change needed:** §4.3's `[OPEN]` alternative (a) should be restated as
  the *average* price, with the solvency argument, and the §20 register row for
  DD-5 updated to match.

### A2. `minOut` is a limit **price**, and a violated limit rolls rather than refunds
- **PRD §3.3, §11 case 4:** `minOut` is a per-order minimum output; refund on
  violation is the recommended policy.
- **Code:** `minOut` becomes `Order.limitPriceX96` at intake; an ineligible order
  is not filled, stays PENDING, and rolls to the next epoch. Partial fills are
  pro rata at a shared `λ`.
- **Why:** refund-on-violation is *unsound*, not merely simpler — dropping an
  order changes `N0`/`N1`, which changes P, which changes eligibility. Filling
  survivors at a P computed over the original set is not self-funding, and
  dropping a currency1-seller leaves a **deficit**. DD-11.
- **PRD change needed:** §3.3 and §11 case 4 restated; the recommendation in §20
  DD-11 marked as rejected with the reason.

### A3. There is no keeper reimbursement at all, and the carrier's bill is unpriced
- **PRD §6.3 / I7 / §10:** a capped reimbursement sourced from `f_slow` is
  permitted; §10 requires the piggyback gas be "reimbursed from batch fees **or**
  capped".
- **Code:** capped (`MAX_ORDERS_PER_EPOCH = 32`), reimbursement zero, to anyone,
  ever (DD-7). The disjunction in §10 is satisfied.
- **Measured (`test/economic/SettlementGasIncidence.t.sol`):** carrying a
  32-order batch costs the triggering Fast-Lane trader **+1,120,644 gas** over an
  uncarried swap (98,026 → 1,218,670). For a 0.001 ETH swap that is **338% of the
  LP fee they paid**; 32% at 0.01 ETH; 3% at 0.1 ETH. In absolute terms on Base
  it is small (~1.1e13 wei at 0.01 gwei), but it is **regressive** — it lands
  hardest on exactly the small retail flow the A1 thesis depends on attracting.
- **Not a defect:** DD-6 discloses that the carrier pays. What is missing is the
  number, and its absence from the Fast-Lane pricing in §4.1/§6.
- **PRD change needed:** §6.3's reimbursement mechanism marked as declined; a
  line in §4.1 or §6 stating that a Fast-Lane trader's total cost is
  `f_base + tax` **plus** an occasional settlement-gas bill, with the magnitude
  and its size-regressivity stated.

### A4. The Fast-Lane tax is a **rate**, and cannot hit §4.1's calibration target
- **PRD §4.1:** `tax = k · TAXED_GAS · priorityFeePerGas` (an absolute wei
  amount), calibrated to capture "~90%+ of the marginal priority bid".
- **Code (`src/lanes/FastLaneFee.sol`):** `taxRate = k · p / 1 gwei`, in v4 fee
  units. Forced by v4's `uint24` rate interface plus §9's no-oracle rule.
- **Consequence, now quantified (`test/economic/KCalibration.t.sol`):** capture
  fraction is `k·S/(1e15·G)` — **independent of the priority fee**, and inversely
  proportional to swap size. One `k` cannot hit one capture target across sizes:
  at `k = 500` and G = 200,000 gas, a 0.05 ETH swap is taxed at 125% of the
  marginal bid, a 1 ETH swap at 2,500%, a 100 ETH swap at 25,000%. The shipped
  default is roughly **3–30× above** the value either published anchor implies.
- **PRD change needed:** §4.1's formula and calibration target restated in rate
  form, with the size-dependence stated as a property rather than a defect.

### A5. `expiryEpochs` is a floor, and expiry did not exist in the PRD at all
- **PRD:** claims have no expiry; §7.3 relies on non-cancellability alone.
- **Code:** orders carry a trader-set `expiryEpochs` (DD-9), and SR-3 made it a
  **floor**: an order is expirable only once its epoch budget has run out *and*
  `min(maxDelay, EXPIRY_BLOCK_FLOOR_MAX)` blocks have passed since its batch
  opened. So an order can rest longer than the trader asked.
- **Analysed 2026-08-26** (see the SR-3 entry in `DECISIONS.md`): I8 is
  unaffected — eligibility never mentions time — and the extension moves DD-9's
  free-option balance toward the protocol, not away from it.
- **PRD change needed:** §5.1 and §7.3 to describe the expiry/refund path, the
  forfeit, and the floor semantics.

### A6. Native ETH is refused as Slow-Lane **input** only
- **PRD §11 case 14:** "reject or special-case" native ETH on the intake path.
- **Code:** input is refused (DD-14); native ETH as slow-lane *output* — a
  `oneForZero` order on an ETH-quoted pool — is fully supported.
- **Consequence:** `poolManager.take` of native currency hands control to the
  trader with a bare `call`. That was a live reentrancy vector until SR-6
  (2026-08-26); see `test/security/RedeemReentrancy.t.sol`.
- **PRD change needed:** §11 case 14 to distinguish input from output and note
  that the output side carries a reentrancy obligation.

---

## B. Bounds and behaviour the PRD does not mention

### B1. Batch size is capped at 32 orders per epoch
No PRD analogue. `MAX_ORDERS_PER_EPOCH` bounds settlement gas (DD-6), is
enforced at intake, when loading candidates *and* when rolling (SR-2), and is the
reason SR-1's grief is bounded rather than permanent.

### B2. Three cadence bounds, not one; I11's true bound is `absoluteMaxDelay`
PRD §4.4/§10 describe a single max-delay valve. The code has `minSettleAge`
(guards I6), `maxDelay` (force-settle gate), `absoluteMaxDelay` (the liveness
escape) and `minForceSettleOrders` (DD-13's anti-grief size floor). Because the
size floor can hold a lone order past `maxDelay`, **I11's real bound is
`absoluteMaxDelay`**, and PRD §5.4's I11 does not say which.

### B3. I4 is asserted to a tolerance, not exactly
`_assertUniformPrice` checks the two sides' implied prices agree to 100 ppm, and
skips one-sided batches and pots below 1e6 wei. PRD §5.4 states I4 as exact.
Integer division makes exact equality unachievable; the tolerance and its floor
should be in the spec so nobody later "fixes" it to an exact check.

### B4. Settlement runs eligibility to a fixed round budget, and may under-fill
`MAX_CLEARING_ROUNDS = 4`. If the shrinking set has not converged, the epoch
settles nothing and retries. **Maximality of the filled set is an efficiency
property, not a safety one, and is explicitly not guaranteed** (DD-11). The PRD
does not say this.

### B5. The settlement residual pays **no** LP fee, and that depends on upstream v4
`_executeResidual` calls `poolManager.swap` on the pool the hook serves, and v4's
`Hooks` library skips a hook's own callbacks (`noSelfCall`). So `_beforeSwap`
never runs on the residual and no fee override is applied — which is what makes
DD-3's "stored LP fee left at 0" actually true.

**This was undocumented and is load-bearing.** Were `noSelfCall` to change
upstream, the residual would be classified FAST (empty `hookData`, DD-1) and
charged `f_base + k·p` at the *carrying* trader's priority fee — up to
`MAX_FAST_FEE` (5%) — silently making the Slow Lane cost more than the Fast Lane
while I10 still read as satisfied. Now pinned by
`test/scaffold/Scaffold.t.sol::test_hookCallbacksAreSkippedWhenTheHookItselfSwaps`.

### B6. The §4.3 pseudocode constraint is satisfied elsewhere than it asks
§4.3 carries a `[CONSTRAINT]` that the exact clearing computation be pinned "as
pseudocode **in this section**". It is pinned — in `src/settle/Clearing.sol`'s
header and in DD-5 — but not in §4.3. Satisfied in substance, unsatisfied as
written.

---

## C. Event-stream divergences (§14)

The PRD's §14 list is not the shipped list. Additive changes are noted so an
analyst building the demo dashboard against §14 is not surprised.

| PRD §14 | As built |
|---|---|
| `FastSwap(trader, size, priorityFee, feeCharged, premiumToLPs)` | `FastSwap(sender, zeroForOne, amountSpecified, priorityFeePerGas, feeCharged, premiumToLPs)` |
| `SlowOrderSubmitted(orderId, trader, tokenIn, amountIn, minOut, epoch)` | `SlowOrderSubmitted(orderId, trader, epoch, zeroForOne, amountIn, minOut, epochExpiry)` |
| `SlowBatchSettled(…, feeToLPs, ordersSettled)` | adds `fillRatioX96`, splits the fee into `feeToLPs0`/`feeToLPs1` |
| `SlowOrderSettled(orderId, amountOut, priceReceived)` | `SlowOrderFilled(orderId, epoch, filledIn, amountOut)` — an order can be filled more than once |
| `SlowOrderRefunded(orderId, reason)` | `SlowOrderRefunded(orderId, trader, amountRefunded, forfeited)` |
| — | `SettlementSkipped(epoch)` (SR-5), `RecaptureDeferred`, `RecaptureDonated`, `PausedSet` |
| `LaneChosen` marked `[SUGGESTED]` | emitted on both lanes |

`SlowOrderFilled` deliberately reports the filled amount rather than a
`priceReceived`: a partially filled order has no single price until it is done,
and the batch price is on `SlowBatchSettled`.

---

## D. Nothing diverges on these

Recorded so the list above is read as complete rather than as a sample.

- **Two settlement entry paths, no nested `unlock`** (§8.3): piggyback executes
  the residual via a direct `poolManager.swap`; `forceSettle` enters through the
  hook's own `unlock`. Both tested.
- **Async intake delta accounting** (§3.2): implemented exactly as specified.
- **Claim non-transferability** (§5.1): structural — no transfer, approval or
  operator on the record.
- **`donate()` empty-range fallback** (§6.2): implemented and exercised.
- **Permission bitmap frozen before mining** (§8.1): pinned by `KESSEL_FLAGS`.
- **I5/I7 fee routing**: the Fast-Lane premium reaches LPs through v4's own
  `feeGrowthGlobal` and touches no hook-held intermediary.
