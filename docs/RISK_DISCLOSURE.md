<!-- Surface market risks and context -->

# Risk Disclosure

> Likelihood and impact are rated **L/M/H**. Items marked **Current** are already happening, as verified on 2026-09-17.

## Material risks

### Market and adoption

| Risk | L | I | Detail | Mitigation |
|---|---|---|---|---|
| **The bond audience is tiny** | Current | H | Bond 1 has 15 principals. StackingDAO holds 60% of capacity through a contract, and Xverse holds 10%. Neither can be routed through Kessel's claim flow. Total payout is about 0.133 BTC/week | Lead with STX-only stakers and sBTC holders (thousands of addresses). Treat bond participants as design partners, not the volume segment |
| **Bitcoin Staking capacity may not grow** | M | H | The Endowment sets bond capacity during bootstrap. Bond 1 is 250 BTC, against the SIP's initial program conditions of 3,000 BTC. Future bond schedules are unpublished | Keep costs ≤ $50/month. Decide by the renewal window (~Feb 2027) using the stop criteria in [PROBLEM_STATEMENT.md](PROBLEM_STATEMENT.md) |
| **Incumbents build the same features** | M | H | `staking.stacks.co`, Leather, Xverse, and StackingDAO (Stacking Tracker) all have distribution | Be the neutral source they integrate. Open-source the modules. Pursue integrations rather than direct competition |
| **Low yields make "deploy rewards" irrelevant** | Current | M | Zest supply 0.13%, stBTC closed, hBTC capped. Weekly rewards are too small to be worth compounding for most holders | Product value rests on risk and net-yield insight, not compounding. "Hold" is a first-class answer |
| **STX price volatility** | H | M | A ~25% STX/BTC drop wipes out a bond's 6-month yield. That is a risk to users, and also a reputational risk if the product is seen as discouraging participation | Present numbers neutrally with a published methodology. Seek Endowment review |
| **Willingness to pay is unproven** | H | M | No paying customers and no design partners yet | Milestone 3 design-partner programme. No hires until paid pilots exist |

### Technical

| Risk | L | I | Detail | Mitigation |
|---|---|---|---|---|
| **Wrong numbers mislead users** | M | H | Per-cycle accounting, the #7301 rollover behaviour, and the unresolved question of whether bonded STX earns Tranche 2 could all produce errors | Reconcile to on-chain payouts (≤ 1 bp target). Publish methodology and a correction log. Show a "data as of" timestamp |
| **Transaction safety** | L | H | A bad deposit build could send the wrong amount | Deny-mode post-conditions cap outflows at the exact amount. Adversarial tests. A kill switch per venue |
| **Reward Router smart-contract risk** | M | H | Unaudited Clarity contract | **Not deployed to mainnet without an audit.** It never holds funds, uses `restrict-assets?`, and has pause and two-step ownership. The two-transaction flow is the default path |
| **Heterogeneous signer-managers** | Current | M | Each non-reference manager needs its own adapter. Stakers paid on L1, or holding their bond through a contract, can't be routed | An adapter per manager, prioritised by stake. Clear "not supported" messaging |
| **Protocol changes** | M | M | Zest v3, StackingDAO v7, Bitflow router versions, PoX-6 | Adapter isolation. Live availability reads. Mainnet-fork tests on each `FORK_HEIGHT` bump |
| **Build environment** | Current | L | On the Windows checkout, `.clar` files have CRLF line endings, which `clarinet check` rejects. The contract test worker fails to start on Windows. Both pass under WSL/Linux. `contracts/.gitattributes` uses `* text=lf`, which is not a valid way to force LF | Run CI on Linux. Fix `.gitattributes` to `* text=auto eol=lf` |

### Dependencies that could affect delivery

| Dependency | Risk | Fallback |
|---|---|---|
| **Hiro API** (staking v3, read-only calls) | Rate limits; schema changes to a new (v3) API | Caching; an API key; the indexer reduces live calls; our own Stacks node as a last resort |
| **Bitflow app API** (`bff.bitflowapis.finance`) | Off-chain, unversioned, and has already reported volatile APRs (68% → 440% within hours) | Compute fee APR from on-chain pool data; flag a venue when the two sources disagree |
| **Venue contracts** (Zest, Hermetica, StackingDAO, Bitflow) | Pauses, shutdowns, capacity caps | Live flags; closed venues shown as closed |
| **`@stacks/connect` and wallets** (Leather, Xverse) | Breaking changes | Pinned versions; a wallet adapter layer |
| **Price data** | Manipulation or outages | Cross-check DEX prices against the Zest oracle and flag discrepancies |
| **Email/Telegram providers** | Delivery failures | Two channels; in-app notices |

### Operational

| Risk | L | I | Detail | Mitigation |
|---|---|---|---|---|
| **Single-founder (bus factor = 1)** | Current | H | All code and operations sit with one person | Recruit a second maintainer by M3. Document runbooks. Keep infrastructure minimal |
| **Limited Stacks track record** | Current | M | The founder's public history is mostly in other ecosystems (see [FOUNDER_MARKET_FIT.md](FOUNDER_MARKET_FIT.md)) | Milestones with public, verifiable artefacts. Seek an Endowment methodology review |
| **Scope creep** | M | M | The original PRD is broad (11 features) | MVP limited to the features in [MILESTONES.md](MILESTONES.md). Items deferred explicitly in [BUSINESS_MODEL.md](BUSINESS_MODEL.md#mvp-vs-future-scope) |
| **Audit cost exceeds the grant** | H | M | Router audit not budgeted in a $10k grant [Assumption] | Router stays on testnet. Seek audit support or a Builder grant later |

### Legal and regulatory

| Risk | L | I | Detail | Mitigation |
|---|---|---|---|---|
| **US market-structure uncertainty** | Current | M | The Senate cloture vote on the CLARITY Act **failed on 2026-09-15**, including its DeFi developer-protection section (§604) ([CNBC](https://www.cnbc.com/2026/09/15/senate-cloture-vote-on-clarity-act-fails-dealing-regulatory-setback-to-crypto-industry.html)). There is no statutory safe harbour for non-custodial DeFi front-ends | Non-custodial by design: no fund custody, no order routing for fees, no token. Seek legal review before any monetised routing |
| **Yield comparisons read as investment advice** | M | M | Rankings and "true yield" could be read as recommendations | Educational framing; methodology; "not financial advice" disclaimers; no personalised allocation instructions; "hold" shown neutrally |
| **Staking classification** | L | M | SEC staff said in 2025 that certain protocol and liquid staking activities are not securities transactions ([SEC, Aug 2025](https://www.sec.gov/newsroom/press-releases/2025-104-securities-exchange-commission-division-corporation-finance-issues-staff-statement-certain-liquid)). This is staff guidance, not law | Kessel does not offer staking itself. Monitor the joint SEC–CFTC taxonomy work |
| **Tax reporting accuracy** | M | L | CSV exports could be relied on for taxes. Staking rewards are generally taxed as income when received ([Koinly](https://koinly.io/blog/how-is-staking-taxed/)) | "Informational only" labelling; transaction-level links for verification |
| **Data and privacy** | L | L | Wallet addresses and alert emails | Store the minimum; no public wallet-level data; opt-in alerts only |

## Risks we considered and judged not material right now

- **Hiro API cost:** the free tier plus an API key is enough at the projected scale.
- **Indexer downtime:** on-chain data can be backfilled. The exception is point-in-time venue flags, which are a quality risk rather than a delivery risk.
