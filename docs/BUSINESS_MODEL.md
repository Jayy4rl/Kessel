<!-- Added alongside the grant skeletons: market, competition, business model, go-to-market, KPIs and funding. The grant sections link here rather than repeating it. -->

# Market, Competition & Business Model

> Tags: **[Verified]** primary source, dated. **[Estimate]** our arithmetic on verified inputs. **[Assumption]** untested belief. **[Recommendation]** our proposed choice. On-chain snapshot: 2026-09-17, Bitcoin block 967,388, BTC $76,579, STX $0.239.

## Bottom line

- **The problem is real and specific to Stacks.** The PoX-5 net yield, the waterfall and reserve risk, and signer-manager choice are unserved (see [PROBLEM_STATEMENT.md](PROBLEM_STATEMENT.md)).
- **Today the market is small.** One bond (250 BTC cap, ≈$17.6M locked) pays about **6.9 BTC a year (≈$0.53M) to 15 principals**. Fees charged on routed rewards cannot fund a company at this scale.
- **The credible path is: grant-funded public good → B2B data, reporting and integrations → expand only if bond capacity grows** (the SIP's initial program conditions describe 3,000 BTC, and PoX-6 plans algorithmic bond parameters).
- **As a venture-scale startup, this is an option on Bitcoin Staking adoption, not a proven business yet.** A founder should run it lean, keep costs near zero, and decide by the Bond 1 renewal window (~late Feb 2027) whether the market is growing.

---

## Market size

### Top-down

| Layer | Size | Source |
|---|---|---|
| Bitcoin market cap | ≈ $1.54T | [Verified] CoinGecko, 2026-09-17 |
| BTC held by public companies | 1.26M+ BTC across ~180–190 companies | [Bit.com knowledge hub](https://www.bit.com/knowledge-hub/bitcoin-treasury-companies) (secondary) |
| BTCfi TVL (all chains) | ≈ $4.1B; 91,332 BTC, **0.46% of circulating BTC** | [Verified] DefiLlama "Bitcoin" chain TVL $4.14B; [Spark Research](https://www.spark.money/research/btcfi-bitcoin-defi-landscape-2026) |
| Babylon (largest BTC staking protocol) | $3.14B TVL | [Verified] DefiLlama API |
| Lombard LBTC | $0.67B | [Verified] DefiLlama API |
| Stacks DeFi TVL | $78.6M | [Verified] DefiLlama API |

**Trend:** BTCfi peaked at ~$9.1B (Oct 2025) and contracted once incentive programmes ended. **Native, bridge-free staking was the segment that held up** ([Spark Research](https://www.spark.money/research/btcfi-bitcoin-defi-landscape-2026)). Corporate treasuries want BTC-denominated yield: Strategy reports a "BTC yield" KPI ([SEC 8-K](https://www.sec.gov/Archives/edgar/data/0001050446/000105044626000036/mstr-20260730x8kxex991.htm)), and Hermetica's hBTC capacity "filled in 24 hours" ([X](https://x.com/HermeticaFi/status/2059981362074132823)). Demand for self-custodial BTC yield is ahead of supply.

### Bottom-up: capital whose returns depend on PoX-5

| Pool | Size (2026-09-17) | Annual BTC-denominated yield flowing |
|---|---|---|
| Bond 1 (BTC leg) | 230.17 BTC ≈ **$17.6M** [Verified] | 6.9 BTC ≈ **$0.53M** at 3% target [Estimate] |
| STX stacked (cycle 143) | 441.6M STX ≈ **$105.5M** [Verified] | ≈ **$7M** at ~6.6% BTC-denominated APY (StackingDAO's published stSTXbtc rate as a proxy) [Estimate] |
| sBTC supply | 2,463.8 sBTC ≈ **$188.7M** [Verified] | Venue-dependent; mostly low today (Zest supply 0.13%) |
| Zest v2 sBTC supplied | 660.3 sBTC ≈ **$50.6M** [Verified] | Small base rate plus a 3 BTC-equivalent STX incentive (Sep 10–Dec 10, 2026, shared with USDCx borrowers) |

**Serviceable market [Estimate]:** about **$300M of capital** (with overlap) and **about $7.5M a year of yield** depend on the decisions Kessel supports. Any monetisation measured in basis points of that flow is small. Monetisation has to come from **operators and institutions paying for tooling**, not from retail flow.

---

## Competitive landscape

| Product | What it does | Pricing | Strengths | Gaps relative to Kessel's thesis |
|---|---|---|---|---|
| **`staking.stacks.co`** (official) | Enrolment; dashboard of balances, rewards, and payouts | Free | Official, trusted, the default entry point | We found no public evidence of net-of-STX yield, waterfall/reserve views, or signer-manager diligence. Its focus is enrolment |
| **Leather** (`app.leather.io/staking`) | Lists signer-managers to stake with | Free | Wallet distribution; referenced in the official docs | A list, not a comparison; single wallet |
| **Xverse** pooled Bitcoin staking (launched 2026-09-07) | Pooled bond access for all users | Fees not disclosed | "2M+" users; anchor institutions | Only its own product; no neutral cross-venue comparison |
| **StackingDAO** app + **Stacking Tracker** | LSTs (stSTX, stBTC); tracker of pools, signers, and LSTs; Telegram bot | LSTs: 5% protocol + 5% signer cut of stacking yield; 1% instant unstake; tracker free | Incumbent with ~12.6k users; the tracker was built on a Stacks Foundation bounty | **Not neutral:** operates 60% of Bond 1. Tracker coverage of PoX-5 bonds and the waterfall is unconfirmed (its GitHub repo now returns 404; the site was not reachable from our network) |
| **Staxiq** | AI-assisted Stacks portfolio tracker with a "Wallet Health Score" across Zest, Granite, StackingDAO, Bitflow, ALEX, Hermetica, and PoX | Not stated | Broad protocol coverage | Early (1 GitHub star). No evidence of bond, true-yield, waterfall, or signer-manager features |
| **AIBTC yield-dashboard skill** | Agent skill: cross-protocol positions and APY | Free | Distribution to AI agents | Not an end-user product |
| **Protocol UIs** (Zest, Bitflow, Hermetica) | Their own markets | Protocol fees | Deep single-venue UX | Single venue; compare against no one |
| **Generic trackers** (DeBank, Zerion, Octav) | Multi-chain portfolio and P&L | DeBank free–$25/mo; Zerion Premium $99/yr; Octav $149–$499/yr per address, institutional custom | Scale, polish, accounting | We found no Stacks PoX-5 support |
| **Tax tools** (Koinly, CoinTracker) | Tax reports | CoinTracker higher tiers from $199/yr | Compliance workflows | Koinly's Stacks integration **imports native STX only**, not tokens such as sBTC |
| **Nansen** | Institutional analytics, integrated with Stacks | Enterprise | Brand, data depth | Not built for staker decisions |

### Unmet needs

1. **Net (true) bond yield** with STX/BTC sensitivity and breakeven.
2. **Waterfall and reserve transparency**, cycle by cycle, for both bond and STX-only stakers.
3. **Signer-manager due diligence** (fee, ceiling, admin keys, claim reliability) in one place, from a **neutral** party that doesn't run a manager.
4. **Per-cycle claims across different manager contracts**, which this repo already handles.
5. **sBTC reward accounting** that tax and reporting tools can import.
6. **Honest venue ranking**: fee APR labelled as fees, closed venues shown as closed, and "hold" as a valid answer.

### Differentiation and moat (candid)

**Differentiation:** neutrality (we run no manager, LST, or venue), verified PoX-5 accounting (per-cycle, rollover-aware), and deny-mode execution.

**Moat:** weak at the start. The most defensible assets, in order:
1. **A point-in-time dataset.** Venue APRs, availability flags, manager fee changes, and STX/BTC at each distribution can't be fully reconstructed later. Every week of indexing adds to it.
2. **An adapter library** for different signer-managers. It is tedious to build and becomes more valuable as managers multiply.
3. **A reference methodology.** If the Endowment, wallets, or analysts cite Kessel's net-yield and reserve numbers, we become the default public source.
4. **Distribution through integrations** (wallet or operator embeds) rather than competing with wallets for users.

Any incumbent could copy the features. The defence is being the neutral, trusted source that incumbents integrate instead of building their own.

---

## Value proposition and positioning

- **For stakers:** "What your Bitcoin Staking position actually earns, what could go wrong, and one safe click to act."
- **For operators and institutions:** "Neutral, reproducible PoX-5 data and reporting you can show your users and LPs."
- **Positioning statement [Recommendation]:** *Kessel is the neutral risk-and-yield layer for Bitcoin Staking on Stacks.* It is not a yield product, a vault, or a wallet.

---

## Business and revenue model

### Options evaluated

| Model | Unit economics | Verdict |
|---|---|---|
| **Fee on claims or deposits routed** (e.g. 0.25%) | Bond 1 pays ≈ 0.133 BTC/week in total. Routing 100% of it at 0.25% ≈ **0.017 BTC/yr (≈$1.3k)** [Estimate] | **Reject** as a primary model. It also damages neutrality |
| **Venue referral / rev-share** (Zest, Bitflow, Hermetica) | Unknown; no public referral programmes found | **Explore later.** Disclose clearly if taken |
| **Performance fee on managed vaults** (Beefy 4.5–9.5%, Yearn 20%) | Requires holding user funds or vault contracts, audits, and regulatory analysis | **Out of scope.** Contradicts the "never holds funds" design |
| **Run a Kessel signer-manager** (fee on rewards, as StackingDAO takes 5%) | Attracting 20M STX (4.5% of stacked) at ~6.6% → ≈$316k rewards/yr → 5% fee ≈ **$16k/yr** [Estimate] | **Reject for now.** Small, needs signer infrastructure (which the Endowment is not funding), and conflicts with a neutral scorecard |
| **B2B reporting and data API** | See pricing below. ~10–20 plausible buyers today (bond participants, pool operators, managers, wallets) | **Primary [Recommendation]** |
| **Integration and licensing contracts** (white-label claim, true-yield, or scorecard widgets for wallets and operators) | One-off build fees plus maintenance | **Secondary [Recommendation]** |
| **Retail premium** (alerts, CSV/tax export, multi-wallet) | Stacks retail willingness to pay is untested; generic comparables are $99–$499/yr | **Test cheaply after M3** |
| **Grants and bounties** | Endowment: up to $10k (Getting Started) or up to $50k (Builder). There is precedent for bounty-funded tooling (Stacking Tracker) | **Near-term runway, not a business** |

### Pricing hypothesis [Assumption, to test with design partners]

| Tier | Price | Includes |
|---|---|---|
| **Public** | Free, permanently | Bond market, waterfall and reserve, signer-manager scorecards, venue ranking, claim and deploy, basic alerts |
| **Pro** (individual) | ~$8/mo or $80/yr | Multi-wallet, full history, CSV export in tax-tool format, custom alert thresholds |
| **Operator** (pool, signer-manager, LST issuer) | ~$300–$800/mo | Data API, embeddable widgets, delegator reporting, manager-change monitoring |
| **Institutional** (bond participants, funds) | ~$750–$2,000/mo, or annual contract | Monthly position statements (realised vs. target, net of the STX leg), renewal analysis, multiple custody addresses, CSV/PDF, SLA |

Anchors: Octav is $149–$499/yr per address for individuals, with custom institutional pricing ([Crypto Adventure](https://cryptoadventure.com/octav-review-2026-defi-portfolio-intelligence-nav-reporting-and-pricing/)); Zerion Premium is $99/yr ([Zerion](https://zerion.io/premium)).

**[Recommendation]** No transaction fees in year 1. Publish a 0% fee pledge to reinforce neutrality.

### Revenue scenarios (12–18 months) [Estimate]

| Scenario | Trigger | Paying customers | ARR |
|---|---|---|---|
| **Downside** | Bond capacity stays ≤ 250 BTC; STX-only staking shrinks | 0–2 | $0–$20k (grants only) |
| **Base** | 1–3 more bonds; capacity 500–1,000 BTC; a few new institutions | 4–8 institutional/operator + ~50 Pro | $60k–$150k |
| **Upside** | Capacity approaches the SIP's 3,000 BTC; PoX-6 opens algorithmic, broader bonds; wallets integrate | 20–40 institutional/operator + ~500 Pro | $400k–$900k, and a case for expanding to cross-BTCfi risk analytics (Babylon, Lombard) |

---

## Go-to-market

### Timing (event-driven)

| Event | Approx. date | Hook |
|---|---|---|
| Bond 1 first distribution | Block 967,400, 2026-09-17 | "Here is what Bond 1 actually paid, net" |
| Zest sBTC incentive ends | 2026-12-10 | Venue ranking before and after incentives |
| Bond 1 renewal window opens | Block 990,500, ~2027-02-24 [Estimate from 10-min blocks] | Renewal comparison: the institutional wedge |
| Bond 1 unlock | Block 991,550, ~2027-03-03 [Estimate] | Exit or roll-over reporting |
| Future bond parameter publications | Not yet announced | "Is this bond worth it at today's STX price?" |

### Channels

1. **Public content as the acquisition engine:** a weekly "Waterfall Report" (revenue, obligations, reserve, net bond yield) posted to the Stacks forum and X, plus newsletters such as *Stacks Snacks*.
2. **Direct outreach to the ~12 Bond 1 principals and 5 operators** for design partnerships. The founder does this personally; no sales hire.
3. **Wallet and operator integrations:** offer scorecard and claim modules to Leather (already lists managers), Xverse, and Asigna-style multisig users.
4. **Developers:** publish the signer-manager claim adapters and PoX-5 accounting as an open-source npm package, so other apps depend on and cite Kessel.
5. **Agents:** ship an AIBTC skill that exposes net yield and scorecards to on-chain agents (150+ deployed on AIBTC per [Stacks Q1 2026](https://www.stacks.co/blog/q1-2026-snapshot)).
6. **Ecosystem:** the Endowment grantee showcase and Stacks community calls.

### Partnerships

| Partner type | What we offer | What we need |
|---|---|---|
| Stacks Endowment and Stacks Labs | Neutral public data on bond sustainability | Early bond parameter notices; a review of the methodology |
| Hiro | A heavy, well-behaved API consumer; feedback on v3 staking endpoints | Rate-limit headroom; waterfall and reserve fields in the API |
| Signer-managers and pool operators | Scorecard visibility; delegator reporting | Interface specs and fee-change announcements |
| Venues (Zest, Bitflow, Hermetica, StackingDAO) | Neutral distribution | Machine-readable availability and rate endpoints |
| Tax and reporting tools (Koinly, Octav) | sBTC reward exports in their format | Import support |

### Growth strategy

1. **Weeks 0–10:** grant milestones; public tools; 100 wallets; 1 design partner.
2. **Months 3–6:** the renewal flow, ready before the Feb 2027 window; first paid institutional statements; wallet integration pilot.
3. **Months 6–12:** data API; Reward Router mainnet, only after an audit; adapt to new bonds.
4. **12 months+:** only if capacity grows, expand to PoX-6 and to cross-BTCfi comparisons (Stacks bonds vs. Babylon vs. Lombard), a question institutions are already asking.

---

## Metrics and KPIs

**North-star metric:** *weekly informed stakers*, meaning wallets that viewed a personalised net-yield, scorecard, or waterfall view **and** either acted (claim, deposit, manager choice) or kept an alert active.

| Area | KPI | Grant-period target |
|---|---|---|
| Acquisition | Unique visitors/month; connected wallets (cumulative) | 1,500; 100 |
| Activation | % of connected wallets that view True Yield or a scorecard | ≥ 60% |
| Engagement | Wallets active in ≥ 2 weeks | ≥ 30% |
| Execution | Non-team claims and deposits; sBTC value claimed through Kessel | ≥ 25 txs; tracked, but capped by Bond 1's ~0.13 BTC/week total payout |
| Safety | Failed or reverted user txs caused by Kessel; incidents | < 2%; 0 |
| Data quality | Net-yield model error vs. realised on-chain payouts | ≤ 1 bp per distribution |
| Retention channel | Alert subscribers | ≥ 40 |
| B2B | Design partners; paid pilots | ≥ 1; 0–1 |
| Reach | Independent citations; integrations | ≥ 3; ≥ 1 in discussion |
| Efficiency | Monthly infrastructure cost | ≤ $50 |

---

## MVP vs. future scope

| MVP (grant period) | Next (months 3–12) | Later (conditional) |
|---|---|---|
| Hardened claim → deposit (two transactions, deny mode) | Renewal decision flow (before Feb 2027) | Reward Router on mainnet (after audit) |
| True Yield per position + methodology | Institutional statements (PDF/CSV) | Data API with paid tiers |
| Waterfall and reserve monitor + daily indexer | Wallet/operator widget integrations | PoX-6 support |
| Signer-manager scorecards | Adapters for more managers | Cross-BTCfi risk comparison |
| Alerts (email/Telegram) + CSV export | Pro tier test | Agent (AIBTC) skill |

**Removed or deferred from the original PRD:** the compounding projector as a headline feature (little value at current rates), the Zest levered vault model (not launched), the Hermetica USDh ~18.7% row (it is USD yield, not BTC, and would mislead), and blended portfolio APY (Staxiq and others cover generic tracking).

---

## Funding considerations

- **Now:** a Stacks Endowment **Getting Started** grant (up to $10k) fits a pre-PMF prototype ([Stacks blog](https://www.stacks.co/blog/everything-you-need-to-know-about-applying-for-a-stacks-endowment-grant)). Builder grants (up to $50k) reward existing traction, which we don't have yet.
- **Indicative use of a $10k grant [Recommendation]:** ~70% engineering time for the three milestones; ~10% infrastructure and data (hosting, email, a Hiro API key); ~10% an independent review of the true-yield methodology; ~10% user research and design-partner outreach. **A full audit of the Reward Router is likely to cost more than this grant [Assumption].** Budget it separately, or keep the router off mainnet.
- **Later:** after one or more paid pilots and signs that bond capacity is growing, consider a small pre-seed from Bitcoin-focused angels or funds, or a Builder grant. **Do not launch a token.** It would undermine neutrality and adds regulatory risk.
- **Burn discipline:** a static frontend plus one cron indexer should run for **under $50/month** [Estimate, based on free-tier hosting and Supabase], which keeps the option alive cheaply while the market develops.

---

## Key assumptions to test

| # | Assumption | Test | By |
|---|---|---|---|
| 1 | Stakers care about net yield once they see it | Share of wallets opening True Yield; qualitative interviews (n ≥ 10) | M2 |
| 2 | Signer-manager choice is a real pain point | Scorecard usage; Leather or operator interest | M2 |
| 3 | Institutions will pay for statements | ≥ 1 design partner; ≥ 1 paid pilot conversation | M3 / month 4 |
| 4 | Bond capacity will grow | Endowment announcements; new bond indices on Hiro | Feb 2027 |
| 5 | Bonded STX does not also earn Tranche 2 | Reconcile against on-chain payouts | M2 |
| 6 | Incumbents will integrate rather than copy | Integration conversations | Month 6 |

## Sources

- DefiLlama API (`/v2/chains`, `/protocols`, `/tvl/*`), 2026-09-17
- CoinGecko simple price API, 2026-09-17
- Hiro API (bonds, allowlist, registrations, signers, pox, token holders), 2026-09-17
- Spark Research, BTCfi 2026 — https://www.spark.money/research/btcfi-bitcoin-defi-landscape-2026
- Bitcoin treasury companies — https://www.bit.com/knowledge-hub/bitcoin-treasury-companies
- Strategy 8-K (BTC yield KPI) — https://www.sec.gov/Archives/edgar/data/0001050446/000105044626000036/mstr-20260730x8kxex991.htm
- Stacks Q1 2026 snapshot — https://www.stacks.co/blog/q1-2026-snapshot
- Stacks Bitcoin Staking — https://www.stacks.co/bitcoin-staking
- Stacks docs, Staking — https://docs.stacks.co/learn/block-production/staking
- StackingDAO — https://www.stackingdao.com/ ; fees: https://docs.stackingdao.com/stackingdao/the-stacking-dao-app/frequently-asked-questions
- Stacking Tracker announcement — https://www.stackingdao.com/post/the-stacking-tracker-is-live-stacking-insights-now-accessible-to-everyone
- Staxiq — https://github.com/natureloved/Staxiq
- AIBTC yield-dashboard skill — https://skills.lc/aibtcdev/skills/aibtcdev-skills-yield-dashboard-skill-md
- Xverse staking launch — https://cryptobriefing.com/xverse-self-custodial-bitcoin-staking-launch/
- Zest incentive — https://cryptobriefing.com/zest-protocol-stacks-defi-stx-rewards/
- Hermetica — https://x.com/HermeticaFi/status/2059981362074132823
- Octav pricing — https://cryptoadventure.com/octav-review-2026-defi-portfolio-intelligence-nav-reporting-and-pricing/
- Zerion Premium — https://zerion.io/premium ; DeBank pricing — https://comparedge.com/tools/debank
- Koinly Stacks integration — https://koinly.io/integrations/stacks/ ; CoinTracker pricing — https://www.cointracker.com/blog/koinly-vs-cointracker
- Beefy fees — https://docs.beefy.finance/ecosystem/beefy-bulletins/beefy-finance-fees-breakdown ; Yearn fee — https://www.spark.money/tools/defi-yield-aggregator-comparison
- Stacks Endowment grant guide — https://www.stacks.co/blog/everything-you-need-to-know-about-applying-for-a-stacks-endowment-grant
