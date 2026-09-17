# Problem Statement

> **How to read this document.** Figures marked **[Verified]** were read from a primary source (on-chain data via the Hiro API, protocol docs, or the source's own site) and the date is given. **[Estimate]** figures are our arithmetic on verified inputs. **[Assumption]** marks something we believe but have not proven. All on-chain snapshots were taken on **2026-09-17 at Bitcoin block 967,388**, with BTC at $76,579 and STX at $0.239 (CoinGecko). Sources are listed at the end.

---

## What is the project proposing to explore or build?

**Kessel is a decision and execution layer for Bitcoin Staking on Stacks.** It shows a staker what their PoX-5 position actually earns, what could go wrong, and what to do with the rewards. It then carries out that decision from the user's own wallet.

Concretely, over the grant period we propose to take the working prototype in this repository to a public mainnet beta with four parts:

1. **Claim and deploy (built, needs hardening).** Find the cycles with claimable rewards, claim them through the staker's own signer-manager, and deposit the sBTC into a venue ranked by what it pays right now. Every transaction is sent in deny mode with post-conditions.
2. **True Yield (to build).** Bond yield net of the STX pairing leg: the STX price move against BTC, plus the yield that STX would have earned if staked on its own. The official materials quote the headline 3% target, and none of the dashboards we reviewed show the net figure.
3. **Public risk monitor (to build).** The PoX-5 reward waterfall (bond obligations, STX-only residual, the 15% reserve contribution), reserve health, and a **signer-manager scorecard** (fee, fee ceiling, admin keys, claim reliability) for the 55 registered managers.
4. **Alerts and records (to build).** Notices when rewards are claimable, when the reserve is being drawn down, and when a renewal window opens, plus an exportable claim and deposit history.

The optional **Reward Router** Clarity contract (atomic claim-and-deploy) stays at testnet or audit-ready status until an audit is funded. The two-transaction flow is the product's primary path because the largest venues (Zest v2, Hermetica hBTC) only accept deposits sent by the depositor's own wallet.

**What we are deliberately *not* proposing** (a change from the original PRD):
- A compounding projector as a headline feature. At today's rates it has little to show (see below).
- Enrollment or registration for bonds. That is handled by `staking.stacks.co`, Xverse, and the Endowment's allowlist process.
- A general-purpose multi-protocol portfolio tracker. Others already offer this (see [BUSINESS_MODEL.md](BUSINESS_MODEL.md#competitive-landscape)).

---

## What user or ecosystem problem motivates the project?

PoX-5 went live on **2026-07-30** ([Chainwire](https://chainwire.org/2026/07/30/stacks-successfully-activates-pox-5-laying-the-foundation-for-bitcoin-staking/)). The first Protocol Bond activated at Bitcoin block 966,350 (cycle 143) and pays out for the first time at block 967,400, within hours of this writing. Three problems appear right away.

### Problem 1 — The headline yield is not the yield

A Protocol Bond pays a **3% BTC target APY** on the BTC leg ([SIP-045](https://github.com/stacksgov/sips/blob/main/sips/sip-045/sip-045-pox-5-bitcoin-staking.md)). Over the 6-month term that is about **1.44%** ([stacks.co](https://www.stacks.co/bitcoin-staking)). The participant must also lock STX worth **at least 5%** of the BTC position, and that STX carries market risk.

- **[Verified]** Bond 1's `stx_value_ratio` parameter is 310,237 STX per BTC. Its locked balances are 230.17 BTC and 3,570,465 STX, which is exactly 15,512 STX per BTC (5% of 310,237).
- **[Verified]** At today's prices BTC is worth 320,446 STX. **STX has already fallen 3.2% against BTC since the bond's parameters were set.** The STX leg is now worth 4.84% of the BTC position rather than 5%.
- **[Estimate]** For each BTC bonded, the 6-month result in BTC terms is roughly `1.44% − (5% × STX opportunity yield for 6 months) + (5% × STX/BTC price change)`. We use StackingDAO's published ~6.8% STX staking APY ([stackingdao.com](https://www.stackingdao.com/)) as the opportunity cost.

| STX vs. BTC over the 6-month term | Net 6-month return on the BTC | Annualised on total capital (BTC + STX) |
|---|---|---|
| +20% | +2.27% | 4.3% |
| +10% | +1.77% | 3.4% |
| 0% | +1.27% | 2.4% |
| −10% | +0.77% | 1.5% |
| −20% | +0.27% | 0.5% |
| **−25.4%** | **0% (breakeven)** | 0% |
| −30% | −0.23% | −0.4% |
| −50% | −1.23% | −2.3% |

A 25% move in STX against BTC over six months is ordinary for this asset. STX rose **28% in a single day** on 2026-08-21 ([CoinMarketCap](https://coinmarketcap.com/top-stories/6a88bd66d927ed2cfe7ad891/)). The pairing leg is small in size but large compared with the yield. **None of the products we reviewed show this net number** (see the competitive landscape).

> **[Assumption to verify]** We treat bonded STX as not also earning the STX-only residual (Tranche 2). If SIP-045's accounting lets bonded STX earn part of Tranche 2, the opportunity-cost term shrinks. The methodology will be published and reconciled against on-chain payouts in Milestone 2.

### Problem 2 — Stakers cannot see where their yield comes from or whether it is safe

PoX-5 pays in a waterfall. Bond holders are paid first at the target rate. Any remaining miner revenue is split **85% to STX-only stakers and 15% to a reserve fund**, and the reserve covers bond payouts when miner revenue falls short ([SIP-045](https://github.com/stacksgov/sips/blob/main/sips/sip-045/sip-045-pox-5-bitcoin-staking.md); [Stacks docs](https://docs.stacks.co/learn/block-production/staking)). So:

- An **STX-only staker's** yield is whatever is left after bond obligations. As bond capacity grows, their share of miner revenue shrinks unless miner revenue grows too.
- A **bond holder's** "fixed" rate is only as good as miner revenue plus the reserve. The SIP describes it as a yield "subject to the risks inherent to the protocol."

Neither group has a public view of revenue, obligations, surplus, and reserve balance cycle by cycle. The Hiro staking API exposes bonds, registrations, and signers, but not the waterfall arithmetic.

### Problem 3 — Every staker now has to pick a signer-manager, and that choice is opaque

PoX-5 **routes all staking, solo or pooled, through a signer-manager contract** ([SIP-045](https://github.com/stacksgov/sips/blob/main/sips/sip-045/sip-045-pox-5-bitcoin-staking.md)). The manager receives rewards and "may take a fee, which is contract-level logic rather than a protocol feature." The official docs tell stakers to check "its fee, fee ceiling, admin set, and grant status, all of which are on-chain" ([Stacks docs](https://docs.stacks.co/learn/block-production/staking)). That leaves a non-technical user to read Clarity contracts.

- **[Verified]** 55 signer-managers are registered and 29 signers are active in cycle 143 (Hiro API).
- **[Verified]** Managers don't share one interface. The stacks-core reference manager and `native-pool-signer-manager` expose different claim functions, so this repo needs a separate adapter for each ([contracts/README.md](../contracts/README.md)).

### Problem 4 — Claimed rewards have few good destinations, and they change weekly

Rewards arrive as sBTC (or BTC on L1). Today the options for that sBTC are thin and unstable:

| Venue | State on 2026-09-15/17 | Source |
|---|---|---|
| Zest v2 sBTC supply | **0.13% supply APR** at 11.1% utilisation; 660 sBTC supplied; 5,000 sBTC cap. Plus an STX incentive of 0.5 BTC/month shared between sBTC suppliers and USDCx borrowers until 2026-12-10 | [Verified] on-chain read via this repo's `zest.ts`; [Crypto Briefing](https://cryptobriefing.com/zest-protocol-stacks-defi-stx-rewards/) |
| StackingDAO stBTC | **Deposits shut down** (`shutdown-deposits = true`); its 150 BTC bond allocation is full | [Verified] fork tests in this repo; Hiro allowlist |
| Hermetica hBTC | ~1.4% reported; capacity-capped, with windows that "filled in 24 hours" | [Hermetica on X](https://x.com/HermeticaFi/status/2059981362074132823) |
| Bitflow HODLMM sBTC ranges | 35–49% trailing fee APR, which is trading fees rather than BTC yield. One pool's TVL fell from 4.75 to 0.99 BTC within hours | Repo measurement, 2026-09-15 |

The sensible action differs from week to week, and sometimes the best choice is to hold. The value to the user is **knowing that, and acting safely when there is a reason to**, rather than a promise of compounding.

> **Why we dropped "compounding" as the lead message.** Bond 1 pays about **0.133 BTC per week to all 15 participants combined** [Estimate: 230.17 BTC × 3% ÷ 52]. A retail participant with 0.1 BTC bonded receives about 0.00006 BTC a week. At a 0.13% supply rate, deploying that earns effectively nothing, and the transaction fee can outweigh it. The original PRD's pitch ("you're leaving compound yield on the table every week") is not true at current rates for most holders.

---

## Why is Stacks the right environment for this work?

- **The problem only exists here.** The waterfall, bonds, signer-managers, and the STX pairing requirement are all PoX-5 constructs. Nothing like them exists on Babylon, Lombard, or EVM restaking.
- **Self-custodial BTC yield is where BTCfi demand is going.** BTCfi TVL fell sharply from its October 2025 peak (~$9.1B), and the segments that held up were native staking without bridges ([Spark Research](https://www.spark.money/research/btcfi-bitcoin-defi-landscape-2026)). Bitcoin Staking on Stacks is squarely in that category: BTC stays on L1 under the user's own timelock.
- **Clarity makes the safety guarantees checkable.** Post-conditions in deny mode let the frontend guarantee that a deposit cannot move more than the stated amount. Clarity 4's `restrict-assets?`, used in the Reward Router, lets a contract call an untrusted signer-manager while guaranteeing it cannot touch the caller's other assets. The same guarantees would be much harder to state on EVM.
- **All the data is public and free.** Hiro's v3 staking API and read-only calls to `pox-5` expose every figure we need without partnerships or API keys.
- **The Endowment is asking for this.** The Q3 2026 call names "portfolio management tools" (Theme 1) and "risk management, market analytics" (Theme 3) ([Stacks Endowment](https://stacksendowment.co/blog/q3-2026-stacks-endowment-grants)).

---

## What has already been validated, prototyped or learned?

**Built (in this repository, as of 2026-09-17):**

| Component | State | Evidence |
|---|---|---|
| Frontend (Vite + React + TS) | Mainnet-only page: public bond list → connect (Leather/Xverse) → eligibility preflight → positions and claimable cycles → claim → ranked deposit → activity log | [frontend/src/App.tsx](../frontend/src/App.tsx), [frontend/README.md](../frontend/README.md) |
| Venue integrations | Zest v2 supply, StackingDAO stBTC, Hermetica hBTC, Bitflow HODLMM (single-sided sBTC bins), each with live availability flags | [frontend/src/lib/](../frontend/src/lib/) |
| Frontend tests | **41 tests passing** across 4 files (`npx vitest run`, 2026-09-17) | `frontend/src/lib/*.test.ts` |
| Reward Router (Clarity) | `claim-and-deploy` with a source/target registry, pause, and two-step ownership; never holds funds | [contracts/contracts/reward-router.clar](../contracts/contracts/reward-router.clar) |
| Contract tests | 27 simnet unit tests with adversarial fixtures (lying, greedy, and evil managers; partial targets) plus 9 mainnet-fork tests. `clarinet check` passes under WSL | [contracts/tests/](../contracts/tests/), [contracts/tests-fork/](../contracts/tests-fork/) |

**Learned by building against mainnet (not obvious from the PRD):**
1. **Zest v2 and Hermetica hBTC debit `contract-caller`,** so no router contract can deposit into them. The atomic one-transaction path only works for a minority of venues, so the product has to be designed around two wallet transactions.
2. **Hiro reports one lifetime "claimable" total, but a claim names a single cycle.** The app has to read recent cycles from `pox-5` directly to build claims that will succeed.
3. **Signer-managers are heterogeneous.** Each non-reference manager needs its own adapter. Stakers paid on L1, or holding their bond through a contract (e.g. Xverse's `sbtc-bond-staker-v1-1`), can't be routed at all.
4. **Venues open and close without warning.** StackingDAO shut stBTC deposits (last successful deposit 2026-09-04), so availability has to be read live, never cached.
5. **Stacks-core issue [#7301](https://github.com/stacks-network/stacks-core/issues/7301)** (bond rollover leaves the old bond's final-cycle shares in place) was closed as intended behaviour. Any yield accounting has to credit that cycle to the *old* bond index and not double-count it.

**Not yet validated:** that anyone outside the team will use the product. We have no users, no waitlist, and no partner commitments. Milestone 1 exists to test this.

---

## Who will do the work and what experience do they bring?

A solo founder-engineer (GitHub [@Jayy4rl](https://github.com/Jayy4rl)) writes everything in this repository: Clarity contracts, mainnet-fork test harness, and React frontend. See [FOUNDER_MARKET_FIT.md](FOUNDER_MARKET_FIT.md) for the full assessment, including gaps (no prior shipped Stacks product, no audit history, solo team) and how we plan to close them.

---

## What evidence would show the concept is worth continuing?

We will treat the concept as validated only if, by the end of the 10-week grant period:

| Signal | Threshold | Why this threshold |
|---|---|---|
| Non-team wallets that connect and view a position | ≥ 100 cumulative | Roughly 1% of the ~9,400 addresses that stacked through pools before PoX-5 (Hiro, cycle 138) |
| Returning wallets (active in ≥ 2 distinct weeks) | ≥ 30% of connected wallets | Shows a recurring job, not curiosity |
| Claims or deposits executed through Kessel by non-team wallets | ≥ 25 transactions | Proves the execution path is trusted |
| Alert subscribers | ≥ 40 | The cheapest sign of intent to come back |
| Design partner (pool operator, signer-manager, wallet, or bond participant) | ≥ 1 written commitment to integrate or pay for data/reporting | Tests the B2B thesis in [BUSINESS_MODEL.md](BUSINESS_MODEL.md) |
| Independent references (forum, X, newsletters, docs) | ≥ 3 | Shows the risk data has value as a public good |

**Stop or pivot triggers** (the skeleton's final, truncated prompt, which we read as "what would make you stop?"):
- Fewer than 30 connected wallets after Milestone 2 **and** no design-partner interest. Pivot to a pure open-source data library (no app) or stop.
- Bond capacity does not grow beyond Bond 1's 250 BTC by the renewal window (~late Feb 2027) **and** STX-only staking keeps shrinking. Re-scope to general Stacks yield risk analytics.
- An incumbent (Leather, Xverse, StackingDAO, or `staking.stacks.co`) ships true-yield and signer-manager diligence natively. Offer our open-source modules to them and stop the standalone app.

---

## Sources

- SIP-045, PoX-5 Bitcoin Staking — https://github.com/stacksgov/sips/blob/main/sips/sip-045/sip-045-pox-5-bitcoin-staking.md
- Stacks docs, Staking under PoX-5 — https://docs.stacks.co/learn/block-production/staking
- Stacks, Bitcoin Staking product page — https://www.stacks.co/bitcoin-staking
- Chainwire, PoX-5 activation (2026-07-30) — https://chainwire.org/2026/07/30/stacks-successfully-activates-pox-5-laying-the-foundation-for-bitcoin-staking/
- CoinMarketCap, STX +28% on Genesis Bond news — https://coinmarketcap.com/top-stories/6a88bd66d927ed2cfe7ad891/
- Hiro API (on-chain snapshots, 2026-09-17): `/extended/v3/staking/bonds`, `/bonds/1/allowlist`, `/bonds/1/registrations`, `/staking/signers`, `/v2/pox`, `/extended/v2/pox/cycles/{n}/signers`
- StackingDAO — https://www.stackingdao.com/
- Zest incentive program — https://cryptobriefing.com/zest-protocol-stacks-defi-stx-rewards/
- Hermetica capacity — https://x.com/HermeticaFi/status/2059981362074132823
- Spark Research, BTCfi in 2026 — https://www.spark.money/research/btcfi-bitcoin-defi-landscape-2026
- Stacks Endowment Q3 2026 call — https://stacksendowment.co/blog/q3-2026-stacks-endowment-grants
- stacks-core #7301 — https://github.com/stacks-network/stacks-core/issues/7301
