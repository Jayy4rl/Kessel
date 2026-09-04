# Kessel — Technical PRD (Uniswap v4 Hook)

**Status:** build-ready draft for UHI10. **Audience:** an implementing engineer/agent who has NOT seen the prior economic analysis. **Convention:** `[REQUIRED]` = mechanism-defining, must hold for the design to be correct. `[SUGGESTED]` = a reasonable implementation choice, replaceable. `[OPEN]` = a genuine unresolved design decision the implementer or team must settle before/while building — do not silently pick one.

A word on scope discipline: this spec deliberately omits features that are not necessary for the core mechanism (no tokenomics, no governance token, no cross-chain, no FHE, no oracle). If a section says a thing is out of scope, it is out of scope on purpose.

**Two-axis labeling (read this before implementing).** There are two independent distinctions in this document and they must not be conflated:
- **Protocol behavior vs. implementation freedom.** `[REQUIRED]` / `[CONSTRAINT]` = the protocol MUST behave this way; the mechanism is wrong otherwise. `[SUGGESTED]` = the implementation team MAY achieve the required behavior this way, or another way. `[OPEN]` = the team MUST decide; the spec does not choose.
- An `[OPEN]` item is never a protocol requirement. Where the review found that an implementation uncertainty had been written as though it were a protocol rule (or vice-versa), it has been relabeled. All `[OPEN]` items are consolidated in §20 (Design Decisions Register); resolving them is the development team's responsibility and several are coupled (resolving one constrains another — cross-references are given).
- This revision incorporates an engineering review. It does not redesign the mechanism: the two-lane immediacy screen, settlement-time uniform pricing, and priority-tax recapture are unchanged. The review's corrections tighten accounting, callbacks, invariants, and MEV-surface descriptions, and surface additional open decisions.

---

## 1. Problem and Core Thesis

### 1.1 The problem
A passive AMM LP commits to a curve and cannot cancel or reprice between blocks. Flow arriving at the pool is heterogeneous in a way the pool cannot observe:
- Some flow is **time-critical** (arbitrage whose edge decays within a block; liquidation-driven exits; leveraged-position closers; cross-venue hedgers with a live delta).
- Some flow is **time-insensitive** (retail spot swaps, DCA, treasury rebalances) — demonstrably tolerant of tens of seconds of delay, as evidenced by adoption of UniswapX Dutch auctions (30–60s) and CoW batches.

A single swap fee must simultaneously (a) be high enough to compensate LPs for serving time-critical flow that demands immediacy, and (b) be low enough not to drive away time-insensitive flow. One scalar cannot do both. This is a Tinbergen problem: one instrument, two targets.

### 1.2 Core thesis (the exact economic claim being implemented)
Offer **two execution contracts on one shared liquidity curve** and let the trader choose:
- a **Fast Lane** that executes in the current block at a premium priced to the trader's revealed urgency, and
- a **Slow Lane** that defers execution and settles later at a price the trader does not know at submission time, at a low fee.

The trader's choice **reveals their time-value** (second-degree price discrimination / self-selection screening). The mechanism prices **immediacy** — a real, separately-compensable cost the LP bears for providing a fill *now* while holding inventory (Demsetz 1968, "The Cost of Transacting"; Grossman-Miller 1988) — **not toxicity**.

**This distinction is load-bearing and must be preserved in all messaging and in the fee logic:** the Fast Lane charges for immediacy. Some immediacy-demanders are toxic (arbitrageurs), some are benign-but-urgent (liquidation-closers). Both consume the same scarce service (an immediate fill against committed inventory) and both correctly pay for it. The mechanism does **not** claim to identify or eliminate toxicity. It claims to (a) price immediacy correctly and route that premium to LPs, and (b) give patience-demanding flow a sandwich-proof lane.

### 1.3 What the mechanism explicitly does NOT claim
- It does **not** make the Slow Lane free of adverse selection. Patient informed flow can sit in the Slow Lane; the irreducible Glosten-Milgrom private-information adverse-selection cost remains. The Slow Lane is **sandwich-proof** (uniform clearing price) and **cross-venue-arb-reduced** (batch competition), not toxicity-free.
- It does **not** eliminate LVR. It reallocates the immediacy premium from searchers/sequencer to LPs, and prevents intra-batch sandwiching. Total LVR across all venues is unchanged.

### 1.4 The load-bearing empirical assumption (must be validated before/during build)
`[REQUIRED to validate]` Single-crossing on time: willingness-to-pay-for-immediacy is monotonically increasing in time-value-of-trade, and enough flow has low time-value that a feasible fast/slow fee spread induces genuine separation. **Validation is data, not code:** on the target pair, measure (a) the share of arbitrage volume that is *bound to this pool* (cannot be executed/hedged on another venue within the deferral window), and (b) retail's realized cost of an N-block/T-second delay. If retail's delay cost exceeds the fee saving, no one picks the Slow Lane and the mechanism degenerates to a single-fee pool. This is the first thing to check and the first chart in any demo.

---

## 2. The Exact Mechanism

### 2.1 Two lanes, one curve
A single v4 pool with a single liquidity distribution serves both lanes. Liquidity is **not** fragmented. The lane is selected per-swap by the trader.

### 2.2 Lane selection
`[REQUIRED]` The trader signals lane choice explicitly. The hook reads the choice from swap `hookData`.
`[SUGGESTED]` Encode lane as a single byte / enum in `hookData`: `0 = FAST`, `1 = SLOW`, plus lane-specific parameters (e.g., Slow Lane min-output / slippage bound).
`[OPEN — default-lane policy]` What happens when `hookData` is empty (e.g., a swap from an aggregator that doesn't know about the hook)? Options: (a) default to FAST at the fast fee (safe for LPs, worst UX for uninformed routers); (b) default to a "standard" lane priced like today's static fee; (c) revert. Pick explicitly. Recommendation to evaluate: default to FAST, because an unaware caller is demanding immediate execution by construction. Document whatever is chosen.

### 2.3 Fast Lane — behavior
`[REQUIRED]` Executes as an ordinary v4 swap against the shared curve, in the current block, synchronously.
`[REQUIRED]` Charges a fee that is an increasing function of the trader's **revealed urgency**. The canonical urgency signal is the priority fee: `priorityFeePerGas = tx.gasprice - block.basefee`, readable on-chain. The fee is `fee = g(priorityFeePerGas, size, poolState)`, where `g` is monotonically non-decreasing in the priority fee.
`[REQUIRED]` The premium (the portion above a baseline LP fee) is routed to LPs (see §6).
`[OPEN — urgency signal on non-priority-ordered chains]` (DD-2) The priority-fee tax only works where the sequencer orders by priority fee without peeking/censoring (OP-Stack L2s: Unichain, Base, OP Mainnet, Blast). It "would likely not work at all on Ethereum L1" (Paradigm, "Priority Is All You Need"). **Decision required:** target a priority-ordered chain and use the priority-fee tax (recommended), OR target L1 and fall back to a flat/state-based Fast-Lane fee (which reintroduces the fee-setting problem §1.1 for the Fast Lane and weakens recapture). This choice determines the whole Fast-Lane fee function. Do not leave it implicit.

`[CONSTRAINT — opposite sandwich properties of the two fee modes]` The priority-tax fee mode and the flat-fee fallback have **opposite** sandwich properties, and the spec must not describe them identically (see §7.5). Under the priority-tax mode on a priority-ordered chain, a sandwicher's front-run leg must bid priority above the victim and therefore pays a strictly higher MEV tax on that leg, making the Fast Lane sandwich-**resistant** in proportion to `k`. Under the flat/state-based fallback, the Fast Lane is fully sandwichable like an ordinary swap. The chosen mode (DD-2) therefore changes the protocol's protection profile, not just its fee arithmetic.

`[CONSTRAINT — chain fee semantics must be verified]` The implementation must verify, on the specific target chain, that `tx.gasprice - block.basefee` equals the priority component the sequencer actually orders on. OP-Stack chains are not assumed uniform in this respect; do not rely on L1 semantics. (See also §4.1.)

### 2.4 Slow Lane — behavior
`[REQUIRED]` Does NOT execute a swap in the current block. The hook takes custody of the trader's input and issues the trader a claim to a future settlement.
`[REQUIRED]` Settles at a price determined at **settlement time**, NOT at submission time. The trader does not know their execution price when they submit. (This is the anti-hedging property — see §7.2. It is non-negotiable; submission-time pricing breaks the mechanism.)
`[REQUIRED]` All Slow-Lane orders settling in the same settlement event clear at a **single uniform price** (this is what makes the lane sandwich-proof — see §7.1).
`[REQUIRED]` Charges a low fee `f_slow`, `[REQUIRED]` strictly less than the Fast-Lane baseline.
`[REQUIRED]` The claim is **non-cancellable or forfeiture-carrying** (see §7.3). A freely cancellable Slow-Lane claim is a free option and breaks the screen.

### 2.5 The recapture-funds-defense loop
`[REQUIRED — economic invariant, see §6.3]` Fast-Lane premium accrues to LPs. `[SUGGESTED]` A portion of it may subsidize `f_slow` toward zero, widening the fast/slow spread and sharpening separation. Whether to actively subsidize or simply let both fees accrue to LPs is `[OPEN — subsidy policy]`: (a) passive — both fees go to LPs, `f_slow` is a fixed low constant; (b) active — Fast premium directly offsets `f_slow` so the Slow Lane can run near-zero. (a) is simpler and has no circular dependency; (b) is the stronger "sustainable low-fee" story but couples the two fees and needs care to avoid a Slow Lane that's free when Fast volume is high and expensive when it's low. Recommend building (a) first, treating (b) as an extension.

---

## 3. User Flows

### 3.1 Fast-Lane swap (synchronous)
1. Trader (or router) submits a swap with `hookData = {lane: FAST, ...}` and a priority fee reflecting urgency.
2. `beforeSwap` reads lane = FAST, computes `fee = g(priorityFee, size, state)`, returns it via the dynamic-fee override.
3. Swap executes against the shared curve at that fee, in-block.
4. `afterSwap` (or the fee mechanism) routes the premium to LPs.
5. Trader receives output in the same transaction. Normal v4 UX.

### 3.2 Slow-Lane order — submission
1. Trader submits with `hookData = {lane: SLOW, minOut / slippage bound, ...}`.
2. `beforeSwap` (with `BEFORE_SWAP_RETURNS_DELTA_FLAG`) returns a `BeforeSwapDelta` consuming the **full input amount** (async pattern). No swap math runs on the curve this block.
3. The hook `IPoolManager.mint`s itself claim tokens (ERC-6909) equal to the input, i.e. takes custody of the input inside the singleton.
4. The hook records a Slow-Lane order: `{trader, tokenIn, amountIn, minOut, submissionBlock/epoch, ...}` and issues the trader a claim (see §5).
5. Transaction settles with `NonzeroDeltaCount == 0` (the input debt is resolved by the hook taking it). Trader holds a claim to a future fill. No output yet.

`[CONSTRAINT — explicit async delta accounting; do not leave to inference]` The returned `BeforeSwapDelta` must exactly offset `params.amountSpecified` for the **specified (input) currency**, and the **unspecified (output) currency delta must be zero** (no output is owed this block). The hook takes the input by `poolManager.mint(hook, inputCurrency, amount)`, which creates the hook's claim balance; the trader's inbound transfer settles the corresponding debt so that `NonzeroDeltaCount` returns to zero within the same unlock. The implementation must document the sign of each delta from the user's perspective (v4 convention: a negative user delta means the user owes the PoolManager). An implementation that does not resolve the specified-currency delta on the hook's books will revert with `CurrencyNotSettled`; do not "fix" such a revert by guessing — the correct resolution is the mint-and-settle path described here. (Review finding: the prior draft asserted `NonzeroDeltaCount == 0` without showing the counterparty delta being resolved.)

`[CONSTRAINT from v4]` AsyncSwap only works on **exact-input** swaps. `[REQUIRED]` The Slow Lane is exact-input only; the implementation must assert `params.amountSpecified < 0` (exact-input, per v4 sign convention) on the Slow-Lane path and revert otherwise. Exact-output Slow-Lane orders are out of scope (§17).

`[OPEN — native-ETH Slow-Lane input]` (DD-14) Native ETH cannot be held as an ERC-6909 claim in the same way as an ERC-20 and must be wrapped or settled through a different custody path. The team must decide whether to reject native-ETH Slow-Lane input outright or special-case it (e.g., wrap on intake). Until decided, the Slow-Lane intake path must not assume ERC-20-style custody for native ETH.

### 3.3 Slow-Lane order — settlement
1. At the settlement trigger (see §10), the hook computes a uniform clearing price for all due Slow-Lane orders and executes the netted swap(s) against the shared curve.
2. Each order's output is computed at the uniform price, subject to its `minOut`. Orders failing `minOut` are handled per `[OPEN — failed-minOut policy]` below.
3. The hook credits each trader their output (claim becomes redeemable / is pushed).
4. `f_slow` is charged; proceeds to LPs.

`[OPEN — failed-minOut policy]` If the uniform clearing price violates a trader's `minOut`, options: (a) the order does not execute and the input is returned (claim → refund); (b) the order rolls into the next settlement epoch; (c) partial fill. Pick one. (a) is simplest and most predictable. Whatever is chosen must be deterministic and stated in the claim terms.

### 3.4 Slow-Lane redemption
`[OPEN — push vs pull settlement]` Two models:
- **Pull:** trader (or anyone) calls `redeem(claimId)` after settlement to collect output. Simple, no keeper for redemption, but the trader must return.
- **Push:** the settlement transaction distributes outputs to all traders in the batch. Better UX, higher gas borne by the settlement trigger, scales poorly with batch size.
Recommend **pull** for v1 (redemption is separate from settlement; settlement fixes the price, redemption collects). State clearly which is built.

---

## 4. Fee and Settlement Logic

### 4.1 Fast-Lane fee
`[REQUIRED]` `fee_fast = f_base + tax(priorityFeePerGas)` where `tax` is monotonically non-decreasing and `f_base` is a floor LP fee.
`[SUGGESTED]` Paradigm MEV-tax form: `tax = k * priorityFeePerGas` for constant `k`, capped at `MAX_LP_FEE` (1_000_000 = 100% in v4 hundredths-of-a-bip units). Choose `k` so the tax captures a high fraction (e.g. ~90%+) of the marginal priority bid.
`[OPEN — k calibration]` (DD-4) `k` is a free parameter. Too high and even benign-urgent flow is overtaxed and routes away (pool goes stale — the recapture paradox); too low and the premium leaks to the sequencer. There is no closed-form optimum; it depends on flow composition. `[REQUIRED]` `k` must be adjustable within governance-set bounds (hook immutability means the *bounds* are fixed at deploy, but a bounded adjustable parameter is allowed). Do not hardcode a single `k`.

`[CONSTRAINT — fee monotonicity]` `g` must be non-decreasing in the priority fee (formalized as I12, §5.4) and this must be property-tested against a mis-specified `g`, not merely assumed. `[CONSTRAINT]` The priority-fee reading `tx.gasprice - block.basefee` must be validated against the target chain's actual ordering semantics (see §2.3 constraint).

### 4.2 Slow-Lane fee
`[REQUIRED]` `fee_slow` is a low constant (or Fast-subsidized per §2.5 option b), strictly `< f_base`.

### 4.3 Uniform clearing price (Slow Lane)
`[REQUIRED]` All orders in a settlement event clear at a **single price P** — this includes both CoW-matched pairs and orders executed via the residual against the curve. Matched and residual-executed orders must receive the identical price P; netting must not secretly advantage one side (see I4, §5.4, as corrected). `[REQUIRED]` Opposing-direction orders are netted against each other before the residual touches the curve (coincidence-of-wants), reducing price impact — this is part of the value the delay buys the trader.

`[CONSTRAINT — clearing price must be given as pseudocode]` Because P depends on the residual size and the residual depends on netting, the exact computation order (net → compute residual → derive P → apply P to all orders) is potentially circular if left prose-only. The implementation must pin the exact computation as pseudocode in this section so two implementers cannot produce two different clearing prices for the same batch.

`[OPEN — clearing-price definition]` (DD-5, highest priority) Exactly which price is P? Candidates: (a) the pool's marginal price after executing the net residual (FM-AMM style — pool moves along its curve, all orders clear at the post-trade marginal price); (b) the pool's pre-batch spot; (c) a time-weighted price over the deferral window. (a) is the theoretically grounded choice (it's the price at which competitive arbitrage into the batch drives the pool to equilibrium) and is recommended, but the exact definition must be pinned down and tested for manipulation resistance (§7.4). This is the single most important unresolved algorithmic choice in the Slow Lane. `[CONSTRAINT]` A naive "spot price at settlement block" is manipulable (§7.4) and is NOT acceptable as-is; whichever definition is chosen must pass the manipulation-resistance tests in §15.

### 4.4 Settlement cadence
`[OPEN — cadence]` (DD-6, coupled to DD-7/§10 and to the settlement-MEV surface §7.6) When does a Slow-Lane batch settle? Options: (a) fixed block interval N (e.g., every N blocks); (b) fixed wall-clock T; (c) piggyback — settle the pending batch inside the next Fast-Lane swap that touches the pool; (d) keeper-triggered on a schedule. (c) is keeperless (see §10) but gives unbounded delay in quiet pools; (a)/(b)/(d) bound the delay but need a trigger. Recommend (c) with a fallback max-delay bound after which a keeper (or any caller) may force settlement. Pin this down; it drives §10.

---

## 5. State and Accounting Requirements

### 5.1 Per-order state (Slow Lane) `[REQUIRED]`
- order id
- trader address
- input token (currency0/currency1 flag) and input amount
- min output / slippage bound
- submission block or epoch id
- status (pending / settled / refunded / redeemed)

`[CONSTRAINT — the trader's claim and the hook's custody balance are distinct objects]` The hook's ERC-6909 balance (minted to the hook in §3.2) represents the hook's **custody** of pooled inputs inside the singleton. The **trader's claim** is a separate object with a different owner and lifecycle. The two must not be the same token; I2 (custody conservation) depends on keeping them distinct. `[OPEN]` (DD-15) whether the trader's claim is (a) a storage record keyed by `orderId` (recommended) or (b) a distinct receipt token must be decided; if (b), see the transferability constraint below.

`[CONSTRAINT — claim non-transferability]` (Resolved by review as a constraint, not an open choice: it is coupled to the free-option prevention in §7.3/I6.) If the claim is represented as any transferable token, a transferable claim to a not-yet-known settlement price is a tradeable option and re-imports the optionality §7.3 exists to remove. Therefore the claim MUST be non-transferable until settled. This is a protocol requirement, not a design decision.

### 5.2 Batch/epoch state `[REQUIRED]`
- current epoch id
- aggregate pending input per direction (for netting)
- settled clearing price per settled epoch (retained until all orders in it are redeemed)

### 5.3 Custody `[REQUIRED]`
- The hook holds Slow-Lane inputs as ERC-6909 claims minted to itself inside the PoolManager (per the async pattern), OR as ERC-20 held by the hook. `[SUGGESTED]` Use ERC-6909 to stay inside the singleton and save gas; document the choice. `[CONSTRAINT]` Whichever is chosen, custody (this balance) remains distinct from the trader's claim (§5.1). Native-ETH custody is not assumed to follow the ERC-6909 path (DD-14, §3.2).

### 5.4 Accounting and safety/liveness invariants `[REQUIRED]`
Safety invariants (I1–I8) must always hold in code; liveness invariant (I11) guarantees progress. All are property-tested (§15).
- **I1 (delta settlement):** every transaction the hook participates in ends with `NonzeroDeltaCount == 0`. The hook may never leave an unsettled swap debt across blocks. (This is why the Slow Lane is escrow-then-settle, not a cross-block async swap — see §7.5.)
- **I2 (custody conservation):** sum of pending Slow-Lane inputs held == sum of claims outstanding (no input is created or destroyed between submission and settlement/refund). Relies on the claim-vs-custody distinction (§5.1).
- **I3 (no double settle):** an order transitions pending → (settled | refunded) exactly once; settled → redeemed exactly once.
- **I4 (uniform price — corrected):** all orders in one settlement event clear at a single price P, applied identically to CoW-matched pairs and residual-executed orders alike (§4.3). Netting must not produce a different effective price for matched vs. residual orders.
- **I5 (fee routing):** Fast-Lane premium and Slow-Lane fee both accrue to LPs (via `donate` or delta), never retained by the hook beyond a declared protocol cut.
- **I6 (settlement-time pricing / anti-hedging):** no code path may let a Slow-Lane fill be computed from submission-time state. Fills are determined only at settlement (§7.2).
- **I7 (recapture integrity):** no mechanism-introduced intermediary (auction winner, solver, keeper, AVS) may capture the Fast-Lane premium. A keeper that only triggers settlement and receives a bounded gas reimbursement from `f_slow` (not from the premium) is permitted (§9, §6.3).
- **I8 (bounded trader downside):** a Slow-Lane trader's downside is bounded by their `minOut`.
- **I9 (warehoused-exposure bound — new, review #7):** the aggregate un-settled Slow-Lane notional per direction must be capped by a parameter `MAX_WAREHOUSE`; new Slow-Lane orders beyond the cap are rejected (fall to Fast per DD-1, or revert). Rationale recorded, not eliminated: between submission and settlement the LPs carry the price risk of warehoused flow, and this exposure is worst during volatility spikes (correlated tail risk). The cap bounds, but does not remove, that risk.
- **I10 (slow-fee bound — new, review #8):** `0 ≤ f_slow < f_base` must hold at all times, regardless of any Fast→Slow subsidy state (§2.5b). `f_slow` may not go negative (paying traders to use the Slow Lane would create free-option pressure).
- **I11 (bounded settlement / liveness — new, review #9):** every pending order becomes settleable within `MAX_DELAY`, after which permissionless force-settle is callable (§10). This is a liveness guarantee, testable, elevated from the prose "safety valve."
- **I12 (fee monotonicity — new, review #10):** `g(p2, ·) ≥ g(p1, ·)` for `p2 > p1`; property-tested against a mis-specified `g`.
- **Hook-immutability constraint (review #12):** a bug in settlement math cannot be patched in place. Bounded, governance-adjustable parameters within pre-set ranges are permitted; a guardian pause that lets traders redeem/refund inputs (never one that strands funds) may be included. The `afterSwap` permission decision (DD-8) must be resolved **before** the hook address is mined, because permissions are encoded in the immutable address (§8.1).

---

## 6. LP Economics and Value Recapture

### 6.1 What LPs earn
`[REQUIRED]` (a) Fast-Lane fee including the urgency premium; (b) Slow-Lane fee; (c) reduced adverse selection on the Slow-Lane portion, because uniform-price batch execution prevents intra-batch sandwiching and lets competitive arbitrage move the batch to fair value rather than picking off a stale quote.

### 6.2 How recapture reaches LPs
`[REQUIRED]` The premium reaches LPs. `[SUGGESTED impl]` Use `PoolManager.donate()` to credit in-range LPs, or route via the return-delta so the premium lands as LP-claimable fees.
`[CONSTRAINT — donate execution context (review #5)]` `donate()` must occur inside an unlocked context with its own delta resolution, and the donated currency must be settled in the same unlock (a settled source is required). The premium must be accumulated and donated at a defined point (e.g., end of the Fast-Lane swap, after the price has moved into a populated range), not mid-swap against an unsettled balance.
`[CONSTRAINT — empty-range fallback]` `donate()` reverts if no liquidity is currently in range. The implementation must define a fallback: accrue the premium to a hook-held, LP-claimable balance and distribute later. The mechanism must not revert the Fast-Lane swap because a range is empty.
`[OPEN — recapture distribution]` (DD-10) To which LPs does the premium go — all in-range LPs pro-rata (donate), or only those whose liquidity served the trade? `donate()` distributes to current in-range liquidity, which is the simplest defensible choice; the team must decide and document.

### 6.3 Recapture economic invariant `[REQUIRED]` (I7)
The Fast-Lane premium (the part above `f_base`) must be **capturable by LPs and not by an intermediary the mechanism introduces**. Concretely: no auction winner, no solver, no keeper, and no AVS may sit between the premium and the LPs. (A keeper that only *triggers* settlement and is paid a bounded gas reimbursement is acceptable; a keeper that *captures* the premium is not.) This invariant is what distinguishes the mechanism from auction-based recapture that leaks to the marginal bidder under searcher concentration.
`[CONSTRAINT — keeper reimbursement is bounded and sourced from f_slow (review #19)]` If a keeper is used, its reimbursement must be capped at a fixed gas-cost ceiling (asserted in code) and routed from `f_slow` proceeds, never from the Fast-Lane premium, so that I7 is provably intact. Reimbursement must not scale with work in a way that lets it grow into a rent.

### 6.4 What this does for sustainable liquidity
`[REQUIRED framing]` The Slow Lane can run at a low fee *funded by* the Fast-Lane premium (§2.5b) or simply *alongside* it (§2.5a), so retail gets low-fee execution while LPs are compensated by urgent flow. That is the "sustainable low-fee liquidity" objective. The mechanism does not address mercenary-liquidity/emissions or LP short-gamma — those are out of scope (§17).

---

## 7. How MEV Protection Works (and its limits)

### 7.1 Intra-batch sandwich protection `[REQUIRED behavior]`
Because all Slow-Lane orders in a settlement event clear at one uniform price, there is no ordering advantage *within* the batch: a searcher cannot place a trade before and after a victim to profit, since everyone gets the same price. This is the primary MEV-protection property and it is structural (guaranteed by I4), not heuristic.

### 7.2 Anti-hedging (why settlement-time pricing is required) `[REQUIRED]`
If the Slow-Lane price were fixed at submission, an arbitrageur could lock a favorable pool price and hedge the opposite leg on a CEX, carrying zero-risk basis for the deferral window — turning the cheap lane into subsidized arbitrage. Pricing at settlement, unknown at submission, removes the hedgeable basis. **Therefore submission-time pricing is prohibited** (I6).
`[LIMITATION — scope of the anti-hedging claim (review #11)]` Settlement-time uniform pricing removes *deterministic, point* risk-free hedging. It does **not** remove an informed trader's *expected-value / distributional* edge: a trader with a view on the clearing-price distribution can still hedge in expectation. That residual is the same irreducible Glosten-Milgrom private-information adverse selection acknowledged in §1.3 and §7.5, not a defect to be fixed here. The spec and any demo must not claim the Slow Lane removes distributional/EV hedging — only deterministic risk-free hedging.

### 7.3 Free-option prevention `[REQUIRED]`
A Slow-Lane claim must not be a free option. If a trader could submit and costlessly cancel after observing market moves, informed traders would submit purely for optionality. `[CONSTRAINT]` The claim must be non-cancellable or carry a forfeiture; combined with the non-transferability constraint (§5.1), this closes the option surface. `[OPEN — cancellation policy]` (DD-9) Choose: (a) fully non-cancellable until settlement; (b) cancellable with a forfeited fee sized to remove option value. (a) is simplest and safest; (b) is friendlier but requires sizing the forfeit ≥ the option value, which is volatility-dependent and hard to set. Recommend (a) for v1. (Non-transferability itself is NOT open — it is required, §5.1.)

### 7.4 Slow-Lane price-manipulation resistance `[REQUIRED to analyze]`
If the uniform clearing price is derived from pool state at settlement, an adversary may try to move the pool just before settlement to skew the clearing price against the batch. Mitigations to evaluate: computing the clearing price from the post-net-residual marginal price (so moving the pool pre-settlement is itself arbitraged), and/or a settlement-window TWAP. `[OPEN]` (DD-5, same decision as the §4.3 clearing-price definition) This is unresolved and must be settled and tested (§15) before mainnet. A naive "spot at settlement block" price is manipulable and is NOT acceptable as-is.

### 7.5 What is NOT protected `[REQUIRED to state]`
- **Fast-Lane sandwich profile is mode-dependent (corrected — review headline).** The prior draft said Fast-Lane swaps "can be sandwiched like any v4 swap." That is only true of the flat-fee fallback (DD-2). Under the priority-tax mode on a priority-ordered chain, a sandwicher's front-run leg must bid priority above the victim and therefore pays a strictly higher MEV tax on that leg, making the Fast Lane sandwich-**resistant** in proportion to `k` — not sandwich-proof. The residual Fast-Lane attack surface under the tax mode is: (i) same-priority ordering ties; (ii) the flat/state-based fallback path, which is fully sandwichable; and (iii) multi-block or cross-pool sandwiches the per-swap tax does not observe. Net: the Fast Lane offers **speed plus priority-tax-proportional sandwich resistance** under the tax mode, and **speed only** under the fallback. Traders wanting structural protection choose the Slow Lane.
- The Slow Lane does not remove private-information adverse selection (patient informed flow). It removes intra-batch sandwiching (I4) and reduces cross-venue arb; the Glosten-Milgrom floor remains.

### 7.6 Settlement-transaction MEV surfaces `[REQUIRED to analyze — the mechanism's largest residual surface]`
Intra-batch uniform pricing (§7.1) protects orders *within* a batch from each other. It does **not** protect the batch *as a whole*, nor does it address MEV in the act of settling. Two surfaces, both promoted here from prior `[OPEN]` status to required analyses with mitigation directions the team must choose among (DD-12):

- **(a) Front-running the settlement residual (review #14).** The settlement swap moves the curve by the net batch size — a large, predictable trade. Anyone who knows the cadence (fixed interval, or "next fast swap") can front-run it. Mitigation directions to choose among: (i) define P such that front-running the residual is unprofitable (the residual executes *at* the clearing-price definition, not against a frontrun-movable spot); (ii) unpredictable/randomized cadence (note: fights the piggyback design, DD-6); (iii) execute the settlement residual as its own priority-taxed transaction so a front-runner pays the tax. This is the largest residual MEV surface and must be resolved before mainnet.
- **(b) Piggyback selection MEV (review #15).** If settlement is triggered inside a Fast-Lane swap (piggyback, §10), the triggering trader can choose *when* the batch clears — trading at the moment the clearing price favors their position, or against the direction they know the residual will push. Requirement: either the triggerer provably cannot profit from the settlement price (e.g., settlement executes after the triggerer's own swap price impact is booked), or piggyback is unsafe and scheduled settlement must be used. The team must resolve this as part of DD-6/DD-7.

---

## 8. Uniswap v4 Hook Architecture and Callbacks

### 8.1 Pool configuration `[REQUIRED]`
- Pool initialized with the dynamic-fee flag (`LPFeeLibrary.DYNAMIC_FEE_FLAG`, `0x800000`) so `beforeSwap` can set the fee per swap.
- Hook deployed at an address whose flag bits encode the permissions below (v4 encodes permissions in the hook address; the deploy tooling must CREATE2-mine/curate the address).
- `[CONSTRAINT — resolve permissions before mining (review #12)]` The permission bitmap is immutable once the address is mined and deployed. The `afterSwap` decision (DD-8) changes the bitmap and therefore the address, so it must be resolved **before** mining. Do not mine the address while any permission-affecting DD is open.

### 8.2 Required hook permissions `[REQUIRED]`
- `beforeSwap: true` — lane routing, fee computation, Slow-Lane intake.
- `beforeSwapReturnDelta: true` (`BEFORE_SWAP_RETURNS_DELTA_FLAG`) — for the Slow-Lane async intake (return a `BeforeSwapDelta` consuming full input).
- `afterSwap`: `[OPEN]` (DD-8, must be resolved before address mining — §8.1) needed only if premium routing / accounting is done post-swap rather than inside `beforeSwap`. Decide based on where fee routing lives.
- All other permissions `false` unless a chosen implementation detail requires them. Do not request permissions the mechanism doesn't use.

### 8.3 Callback responsibilities
- **`beforeSwap`** `[REQUIRED]`:
  - decode lane from `hookData`.
  - FAST: compute dynamic fee `g(priorityFee, size, state)`; return it (fee | `OVERRIDE_FEE_FLAG`, `0x400000`) with a zero `BeforeSwapDelta` so the normal swap proceeds.
  - SLOW: return a `BeforeSwapDelta` consuming the full specified (exact-input) amount; `mint` claim tokens to the hook; record the order; issue the trader claim. Ensure deltas resolve (I1).
- **Settlement function(s)** `[REQUIRED]`: computes uniform price, nets, executes residual against the curve, charges `f_slow`, records clearing price, marks orders settled.
  - `[CONSTRAINT — two entry paths, do not share one unlock assumption (review #3, critical)]` Settlement can be reached two ways, and `unlock` cannot be nested. (i) **Piggyback path:** settlement triggered *inside* a Fast-Lane swap is already within an unlocked context, so it must execute the residual via a direct `poolManager.swap` call from the hook, **not** a fresh `unlock`. (ii) **Keeper/forced path:** settlement triggered standalone must enter via its **own** `unlock`/callback. These are different code paths with different entry assumptions; a single settlement function that always calls `unlock` will revert on the piggyback path. The implementation must split or branch them explicitly.
- **`redeem`** (if pull model) `[REQUIRED if §3.4 = pull]`: transfers settled output to the trader; marks redeemed.

### 8.4 Interaction constraints `[REQUIRED to respect]`
- The hook cannot see the mempool, other in-block transactions, its position in the block, or any off-chain/CEX price.
- `tx.gasprice - block.basefee` is readable and is the only sanctioned urgency signal.
- Core operations (swap/donate/settle) must occur inside an `unlock` callback with all deltas resolved to zero.

---

## 9. External / Off-Chain Components

`[REQUIRED statement]` The mechanism is designed to minimize external dependencies. Specifically it requires **no oracle, no AVS, no encryption service, no solver network.**

The only potential off-chain actor is a **settlement trigger** (§4.4/§10), and only if the chosen cadence is not piggyback. If a keeper is used:
- `[REQUIRED]` it may ONLY trigger settlement; it may NOT influence the clearing price beyond invoking the deterministic on-chain computation, and may NOT capture the Fast-Lane premium (I5 / §6.3).
- `[SUGGESTED]` reimburse keeper gas from `f_slow` proceeds or a small bounded tip; keep it bounded so it cannot grow into a rent.

---

## 10. Settlement Trigger — Design `[OPEN, high-priority]` (DD-7, coupled to DD-6 cadence and §7.6 settlement MEV)
Tied to §4.4. The keeperless option: **piggyback** settlement of the pending Slow-Lane batch inside the next Fast-Lane swap. Pros: no external actor, no new claimant. Cons: unbounded delay in low-activity pools; the Fast-Lane swapper pays the settlement gas (must be reimbursed from batch fees or capped); and it exposes the piggyback selection-MEV surface (§7.6(b)) that must be resolved. `[REQUIRED]` If piggyback is chosen, add a **max-delay safety valve** (I11): after a bounded number of blocks/seconds, permit *any* caller (permissionless keeper) to force settlement, so orders can't be stranded. `[CONSTRAINT]` The piggyback path must follow the no-nested-unlock rule (§8.3): it executes the residual via a direct `poolManager.swap`, not a fresh `unlock`. Decide and document the cadence/trigger and the §7.6(b) mitigation together.

---

## 11. Edge Cases and Failure Modes `[REQUIRED to handle]`
1. **Empty Slow-Lane batch at settlement:** no-op, no revert.
2. **Single-order batch:** clears against the curve like a normal swap at the uniform-price definition; still exact-input.
3. **Quiet pool, piggyback cadence:** orders wait indefinitely → safety valve (§10) must fire.
4. **`minOut` violated at clearing price:** per §3.3 `[OPEN]` policy — refund / roll / partial. Must be deterministic.
5. **Trader never redeems (pull model):** claim persists; output held by hook indefinitely; ensure no fund loss and clear ownership.
6. **Fast-Lane priority fee = 0** (non-priority chain, or user set none): fee falls to `f_base`; acceptable, but note recapture is zero for that swap.
7. **Very large Slow-Lane order relative to depth:** uniform-price execution may move the curve significantly; slippage bound protects the trader; document impact on other orders in the same batch (they share the moved price).
8. **Reentrancy via settlement touching the curve:** must respect the lock; all state transitions before external calls.
9. **Aggregator sends no `hookData`:** default-lane policy (§2.2) applies.
10. **Two settlements in same block (piggyback + forced):** guard against double-settle (I3).
11. **Direction imbalance in netting:** residual after CoW netting executes against the curve; ensure netting math is exact and conserves value (I2).
12. **Hook immutability:** a bug in settlement math cannot be patched in place. `[REQUIRED]` bounded, governance-adjustable parameters within pre-set ranges; consider a pause/guardian for settlement if a critical bug is found (a pause that lets traders redeem inputs, not one that strands funds).
13. **Warehouse cap reached (I9):** a new Slow-Lane order that would breach `MAX_WAREHOUSE` per direction is rejected (falls to Fast per DD-1 or reverts); must be deterministic and not strand the trader's funds.
14. **Native-ETH Slow-Lane input (DD-14):** until resolved, the intake path must not assume ERC-20-style custody for native ETH; reject or special-case per the decision.
15. **Volatility spike during a large pending batch:** LPs carry warehoused price risk (I9 rationale); recorded as a correlated tail risk (§12), bounded by `MAX_WAREHOUSE`, not eliminated.

---

## 12. Security / Adversarial Considerations `[REQUIRED]`
- **Async-swap misuse:** the async pattern lets a hook "take all swap amounts for itself" (per OpenZeppelin's v4 audit). The Slow-Lane intake must provably escrow the input against a claim (I2) and never divert it. This is the highest-severity area; audit it hardest.
- **Settlement-price manipulation:** §7.4; the clearing-price definition must resist pre-settlement pool nudging. Do not ship a naive spot-at-block price.
- **Free-option / cancellation gaming:** §7.3; non-cancellable or forfeiture.
- **Griefing the settlement trigger:** if permissionless force-settle exists, ensure a griefer can't repeatedly force tiny unfavorable settlements. `[OPEN]` (DD-13) the team must decide a minimum batch age or size before force-settle is allowed.
- **Priority-fee spoofing / sequencer trust:** the urgency tax assumes honest priority ordering; on the target chain, state the sequencer trust assumption explicitly (A3). On a chain without it, the tax is defeated (fall back per §2.3, with the opposite sandwich profile noted in §7.5).
- **Settlement-transaction MEV (promoted to required analysis):** covered in §7.6 — front-running the settlement residual (§7.6a) and piggyback selection MEV (§7.6b). These are the mechanism's largest residual MEV surfaces; mitigation direction must be chosen (DD-12), not left open at mainnet.
- **Claim transferability (resolved as a constraint, not open):** Slow-Lane claims MUST be non-transferable until settled (§5.1), because a transferable claim to an unknown future price is a tradeable option that defeats §7.3/I6. This is a protocol requirement.
- **Warehouse exposure (I9):** aggregate un-settled Slow-Lane notional per direction is capped; correlated tail risk during volatility is bounded, not eliminated (§11 items 13/15).
- **Keeper reimbursement bound (I7):** if a keeper exists, its reimbursement is capped and sourced from `f_slow`, never the Fast premium (§6.3).

---

## 13. Assumptions and Invariants (consolidated) `[REQUIRED]`
**Economic assumptions:**
- A1: single-crossing on time holds for the target pair (§1.4) — validate with data.
- A2: the pool is a marginal venue for enough flow that delaying does not simply push all flow elsewhere (the "delay can be unbundled" risk).
- A3: on the target chain, the sequencer orders by priority fee honestly (if using the tax).
- A4 (recorded per review #11): the anti-hedging property holds only against *deterministic* risk-free hedging; informed traders retain a *distributional/EV* edge in the Slow Lane (the Glosten-Milgrom floor, §7.2). This is an accepted limitation, not an assumption the mechanism guarantees away.

**Hard invariants (must always hold in code):** the full set is defined in §5.4 — I1 (delta settlement), I2 (custody conservation), I3 (no double settle), I4 (single clearing price P for matched+residual), I5 (fee routing to LPs), I6 (settlement-time pricing / anti-hedging), I7 (recapture integrity / no premium-capturing intermediary), I8 (bounded trader downside via `minOut`), I9 (warehoused-exposure bound), I10 (`0 ≤ f_slow < f_base`), I11 (bounded settlement / liveness), I12 (fee monotonicity). I1–I10 and I12 are safety; I11 is liveness.

---

## 14. Events and Emitted Data `[REQUIRED]`
Emit enough to reconstruct behavior and prove the economic claims off-chain (for the demo dashboard and for analysis):
- `FastSwap(trader, size, priorityFee, feeCharged, premiumToLPs)` — lets an analyst measure who pays the premium and how much reaches LPs.
- `SlowOrderSubmitted(orderId, trader, tokenIn, amountIn, minOut, epoch)`
- `SlowBatchSettled(epoch, clearingPrice, netInput0, netInput1, cowMatchedAmount, feeToLPs, ordersSettled)`
- `SlowOrderSettled(orderId, amountOut, priceReceived)` / `SlowOrderRefunded(orderId, reason)`
- `SlowOrderRedeemed(orderId, trader, amountOut)`
- `ParameterUpdated(param, oldValue, newValue)` for any bounded-adjustable param (`k`, `f_slow`, cadence).
`[SUGGESTED]` Emit `LaneChosen(trader, lane)` for quick separation analytics — this is the data that proves single-crossing in the demo.

---

## 15. Testing Requirements and Scenarios `[REQUIRED]`
**Unit / invariant (must pass):**
- I1–I8 hold under fuzzing (property tests: random sequences of fast/slow/settle/redeem always end with zero unsettled deltas and conserved custody).
- Uniform price: every order in a settled batch, same direction, gets identical price (I4).
- Anti-hedging: no code path lets a Slow-Lane fill be computed from submission-block state (I6).
- Custody conservation across submit→settle→redeem and submit→refund (I2).

**Scenario tests (must demonstrate correct behavior):**
1. **Separation:** given a population with mixed time-value, fast flow selects FAST and pays the premium; patient flow selects SLOW; measure that the premium reaches LPs and `f_slow` stays low. (Directly tests the thesis.)
2. **Anti-hedge:** an adversary submitting to the Slow Lane and hedging on a simulated CEX cannot lock a risk-free profit because the fill price is unknown at submission.
3. **Intra-batch sandwich attempt:** an adversary placing orders around a victim in the same batch gains nothing (uniform price).
4. **Sub-threshold / patient-informed:** confirm the mechanism does NOT claim to stop patient informed flow in the Slow Lane (documented limit), and that it DOES stop sandwiching — assert the boundary of the claim.
5. **Settlement-price manipulation:** an adversary nudging the pool pre-settlement cannot profitably skew the clearing price beyond arbitrage bounds (tests §7.4 choice).
6. **Quiet pool:** piggyback fails to settle → safety valve fires → orders settle within max delay.
7. **minOut violation:** deterministic handling per chosen policy.
8. **Free-option:** cancellation is impossible or forfeits enough to remove option value.
9. **Gas / scale:** batch of N orders settles within block gas limits for target N; identify the N at which push-settlement (if chosen) breaks.
10. **Fork test on target chain:** priority-fee reading returns sane values and matches the sequencer's ordering component (A3); tax routes to LPs on a real OP-Stack testnet (Unichain Sepolia recommended).
11. **Nested-unlock paths (review #3):** piggyback settlement executes the residual via direct `poolManager.swap` without a nested `unlock` and does not revert; keeper/forced settlement enters via its own `unlock`. Both paths tested.
12. **Warehouse cap (I9):** orders beyond `MAX_WAREHOUSE` per direction are rejected deterministically; funds never stranded.
13. **Slow-fee bound (I10):** `f_slow` stays in `[0, f_base)` across all subsidy states.
14. **Fee monotonicity (I12):** fuzzed priority fees produce non-decreasing `g`.
15. **Settlement-residual front-running (§7.6a):** with the chosen clearing-price definition, front-running the settlement residual is unprofitable.
16. **Piggyback selection MEV (§7.6b):** the triggering Fast-Lane trader cannot profit from choosing when the batch clears (or scheduled settlement is used and this is N/A — assert whichever the team chose).
17. **Native-ETH input (DD-14):** the chosen policy (reject or wrap) holds; no custody assumption violated.
18. **Empty-range premium (review #5):** Fast-Lane swap with no in-range liquidity does not revert; premium accrues to the fallback claimable balance.
19. **Keeper reimbursement bound (I7):** keeper cannot draw more than the capped reimbursement and cannot touch the Fast premium.
20. **Claim non-transferability (§5.1):** a claim cannot be transferred before settlement.

**Definition of a passing implementation:** all invariant tests (I1–I12) green, scenarios 1–8 and 11–20 demonstrate the specified behavior, scenarios 5/15/16 pass for the chosen §4.3/§7.6 mechanisms, and the fork test shows real premium reaching LPs on the target chain. Scenarios that test an `[OPEN]`-dependent behavior must be written against the team's resolved choice and cannot be marked passing while that DD is unresolved.

---

## 16. What Constitutes Correct Behavior `[REQUIRED]`
The implementation is correct iff:
- Every transaction resolves all deltas (I1); custody is conserved (I2); no double-settle (I3); warehouse cap holds (I9); liveness holds (I11).
- Fast Lane executes in-block at a fee non-decreasing in priority fee (I12), with the premium reaching LPs and no intermediary capturing it (I5, I7).
- Slow Lane defers, escrows against a non-free-option, non-transferable claim (§5.1, §7.3), and settles all orders in a batch at one price P determined at settlement time and applied identically to matched and residual orders (I4, I6), bounded by each trader's `minOut` (I8), with `0 ≤ f_slow < f_base` (I10).
- The Slow-Lane clearing price is manipulation-resistant per the chosen §4.3/§7.4 mechanism, and the settlement-transaction MEV surfaces (§7.6) are mitigated per the chosen approach.
- The claim-vs-custody distinction is preserved; the two settlement entry paths respect the no-nested-unlock rule (§8.3).
- No oracle/AVS/solver is required; any keeper only triggers settlement, draws a capped reimbursement from `f_slow`, and captures no premium.

---

## 17. Explicitly Out of Scope `[REQUIRED]`
- Exact-output Slow-Lane orders (async pattern is exact-input only).
- L1 deployment with a working urgency tax (unless the flat-fee fallback §2.3 is explicitly chosen; the priority-tax version is L2/priority-ordered only).
- Oracle-based or CEX-price-based fee setting.
- FHE / encrypted orders / dark-pool matching.
- LVR auctions, searcher bonding, delta-hedging, IL insurance, tranching — these are different mechanisms, not part of this one.
- Mercenary-liquidity / emissions / LP-token incentives.
- Cross-chain settlement.
- Governance-token design.
- Eliminating private-information adverse selection in the Slow Lane (impossible; explicitly not attempted).
- Protecting Fast-Lane swaps from sandwiching (Fast Lane is speed, not protection).

---

## 18 → see §20 (Design Decisions Register)
The former inline checklist has been superseded by the consolidated register in §20, which carries stable DD-numbers referenced throughout the document, records the alternatives, and flags coupling. Nothing here is resolved on the team's behalf.

---

## 19. Build Order (suggested, not required)
1. Fast Lane only: dynamic-fee pool + priority-tax + premium-to-LPs. Ships a complete, demoable recapture mechanism on its own and de-risks the priority-tax/chain assumption.
2. Slow Lane intake: async escrow + ERC-6909 claim + order state. (No settlement yet — prove custody and I1/I2.)
3. Slow Lane settlement: uniform-price clearing + CoW netting + piggyback trigger + safety valve.
4. Redemption + minOut handling + events + dashboard.
5. Manipulation-resistant clearing price + full adversarial test suite.
6. Fork deployment on Unichain Sepolia; measure real separation and real premium-to-LP.

The Fast Lane (step 1) is independently valuable and demoable; the Slow Lane is what makes it a menu. Scope the demo so step 1 is fully live and steps 2–3 are live-in-simplified-form, with 5 as the "here's the hard part and how we solve it" narrative.

---

## 20. Design Decisions Register `[OPEN — team must resolve; spec does not choose]`
Every item is a genuine decision with more than one valid approach. The spec records the alternatives and does not pick. Stable DD-numbers are referenced inline. "Coupled to" means resolving one constrains another. Items the review converted from open to constraint (claim non-transferability; explicit async accounting; two-path settlement; opposite sandwich profiles; keeper bound) are NOT here — they are requirements and live in their sections.

| # | Decision | Alternatives | Section(s) | Coupled to | Notes |
|---|---|---|---|---|---|
| DD-1 | Default lane when `hookData` empty | (a) FAST at `f_base`; (b) a standard static-fee lane; (c) revert | §2.2, §11(9), §17 | DD-2 | Determines behavior of most aggregator flow; elevate priority. Recommendation noted (a), not chosen. |
| DD-2 | Urgency signal & chain target | (a) priority-fee tax on priority-ordered L2; (b) flat/state fee on L1 | §2.3, §4.1 | DD-1, DD-8; sandwich profile §7.5 | Changes protection profile, not just arithmetic. |
| DD-3 | Fast→Slow subsidy | (a) passive (both fees→LPs, `f_slow` fixed); (b) active (Fast premium offsets `f_slow`) | §2.5, §4.2 | I10 | (b) is the stronger low-fee story but couples the fees. |
| DD-4 | `k` calibration & governance bounds | value + bounded-adjustable range | §4.1 | — | No closed-form optimum; must be bounded-adjustable, not hardcoded. |
| DD-5 | Uniform clearing-price definition P | (a) post-residual marginal price; (b) pre-batch spot; (c) settlement-window TWAP | §4.3, §7.4 | DD-6; §7.6a | **Highest priority.** Naive spot-at-block is not acceptable. Tied to manipulation resistance. |
| DD-6 | Settlement cadence | (a) fixed block interval; (b) fixed wall-clock; (c) piggyback; (d) keeper-scheduled | §4.4, §10 | DD-5, DD-7; §7.6 | (c) keeperless but unbounded delay; needs I11 valve. |
| DD-7 | Settlement trigger / keeperless-vs-keeper | piggyback + permissionless valve, or scheduled keeper | §10 | DD-6; §7.6b | Keeper must obey I7 bound. |
| DD-8 | `afterSwap` permission | needed or not, based on where fee routing lives | §8.2 | **Must precede address mining** (§8.1) | Permission bitmap is immutable in the address. |
| DD-9 | Cancellation policy | (a) non-cancellable; (b) forfeiture-fee | §7.3 | non-transferability is already required | (a) recommended for v1. |
| DD-10 | Recapture distribution | (a) all in-range LPs (donate); (b) serving-liquidity only | §6.2 | empty-range fallback is required | (a) simplest. |
| DD-11 | Failed-`minOut` policy | (a) refund; (b) roll to next epoch; (c) partial fill | §3.3, §11(4) | — | Must be deterministic. |
| DD-12 | Settlement-tx MEV mitigation | (a) P robust to residual front-run; (b) randomized cadence; (c) priority-taxed settlement tx | §7.6 | DD-5, DD-6 | Must be resolved before mainnet. |
| DD-13 | Force-settle griefing guard | min batch age and/or min size before force-settle | §12 | DD-6, I11 | Prevents repeated tiny unfavorable settlements. |
| DD-14 | Native-ETH Slow-Lane input | (a) reject; (b) wrap on intake | §3.2, §5.3, §11(14) | — | Custody path differs from ERC-20. |
| DD-15 | Trader claim representation | (a) storage record by `orderId`; (b) distinct non-transferable receipt | §5.1, §3.4 | non-transferability required either way | Push vs pull redemption (§3.4) rides here. |

Redemption model (push vs pull, §3.4) is folded into DD-15's implementation.

---

## 21. Revision Summary

**Changes made in this revision (all from the engineering review; no mechanism redesign):**

Constraints added / clarifications made explicit:
- §0 (new labeling note): protocol-behavior vs implementation-freedom axis stated; `[OPEN]` never a protocol requirement.
- §2.3: recorded that priority-tax and flat-fee modes have **opposite** sandwich properties; added chain-fee-semantics verification constraint.
- §3.2: added explicit async delta accounting (specified-currency offset, zero output delta, mint-and-settle, `CurrencyNotSettled` guidance); exact-input assertion; native-ETH flagged (DD-14).
- §4.1: fee-monotonicity constraint (I12) and chain-semantics constraint cross-linked.
- §4.3: single clearing price P for matched+residual; pseudocode-required constraint; naive-spot prohibited.
- §5.1/§5.3: claim-vs-custody distinction made explicit; **claim non-transferability made a requirement** (was open).
- §6.2: `donate()` execution-context and empty-range-fallback constraints.
- §6.3: keeper-reimbursement bound (capped, sourced from `f_slow`, never the premium).
- §7.2: anti-hedging claim scoped to deterministic hedging only; distributional/EV edge recorded as limitation (A4).
- §7.5: **headline correction** — Fast Lane is sandwich-*resistant* under the tax mode (not "sandwichable like any swap"), sandwichable only under the flat fallback; residual surface enumerated.
- §7.6 (new): settlement-residual front-running and piggyback selection-MEV promoted from open to required analyses.
- §8.1: address-mining-after-permissions-resolved constraint.
- §8.3: **critical** — two settlement entry paths (piggyback in-context vs keeper own-unlock); no nested `unlock`.
- §10: cross-linked to DD-6/DD-7 and §7.6b; nested-unlock rule restated.

Invariants added:
- I4 corrected (single P across matched+residual). I6, I7, I8 promoted into the §5.4 list. I9 (warehouse-exposure bound), I10 (`0 ≤ f_slow < f_base`), I11 (bounded settlement/liveness), I12 (fee monotonicity) added. §13 consolidated to the full I1–I12 set; A4 assumption added.

Edge cases / tests:
- §11: added warehouse-cap, native-ETH, volatility-spike-during-batch cases.
- §15: added tests 11–20 (nested-unlock paths, warehouse cap, slow-fee bound, fee monotonicity, settlement-residual front-run, piggyback selection MEV, native ETH, empty-range premium, keeper bound, claim non-transferability); passing definition updated.
- §16: correct-behavior criteria expanded to the full invariant set and the new constraints.

Structure:
- §18 checklist superseded by §20 Design Decisions Register (DD-1…DD-15, with alternatives and coupling). §21 this summary.

**Items that remain UNRESOLVED (open, in §20) — 15 total:** DD-1 default lane; DD-2 urgency signal/chain; DD-3 subsidy mode; DD-4 `k` calibration; DD-5 clearing-price definition (highest priority); DD-6 cadence; DD-7 settlement trigger; DD-8 `afterSwap` permission (blocks address mining); DD-9 cancellation policy; DD-10 recapture distribution; DD-11 failed-`minOut`; DD-12 settlement-tx MEV mitigation; DD-13 force-settle griefing guard; DD-14 native-ETH input; DD-15 claim representation/redemption.

**Items the review RESOLVED into requirements (no longer open):** claim non-transferability (§5.1); explicit async delta accounting (§3.2); two-path settlement / no nested unlock (§8.3); keeper-reimbursement bound (§6.3); donate context + empty-range fallback (§6.2); opposite-sandwich-profile disclosure (§7.5); address-mining ordering (§8.1); the corrected/added invariants I4, I9–I12.

**Unchanged (preserved):** the two-lane immediacy screen; settlement-time uniform pricing (I6); priority-tax recapture; no oracle/AVS/solver dependency; the economic model and thesis (§1); out-of-scope list (§17); build order (§19).

**Known limitations recorded, not eliminated (per review instruction):** distributional/EV hedging in the Slow Lane remains (A4, §7.2); private-information adverse selection floor remains (§7.5); warehoused-inventory correlated tail risk is bounded but not removed (I9, §11); Fast-Lane protection is mode-dependent and, under the tax mode, proportional to `k` rather than absolute (§7.5); settlement-transaction MEV surfaces exist and require a chosen mitigation (§7.6, DD-12).
