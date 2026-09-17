<!-- This section should be split into 3 milestones over a period of 10 weeks. -->

# Milestones (10 weeks)

**Timeline assumption:** week 1 starts on the award date. Indicative dates assume a start on **Mon 2026-10-12**. Budget shares assume a $10,000 Getting Started grant (see [BUSINESS_MODEL.md](BUSINESS_MODEL.md#funding-considerations)).

**Starting point (verified 2026-09-17):** the claim → deposit prototype runs against mainnet with 41 passing frontend tests. The Reward Router passes `clarinet check` (under WSL) and has 27 unit tests and 9 mainnet-fork tests. Nothing is publicly deployed, and there are no users yet.

**Why the adoption targets are modest:** Bond 1 has **15 principals** and pays about **0.133 BTC per week in total**. The reachable audience is mainly STX-only stakers (441.6M STX stacked) and sBTC holders (14,466 holder records). Targets are sized to that reality (see [AUDIENCE.md](AUDIENCE.md)).

| # | Milestone | Weeks | Indicative end | Budget share |
|---|---|---|---|---|
| 1 | Public mainnet beta: claim, deploy, and Bond Monitor | 1–3 | 2026-11-01 | 35% |
| 2 | True Yield, Waterfall & Reserve, and Signer-Manager Scorecards | 4–7 | 2026-11-29 | 35% |
| 3 | Alerts, records, design partner, and router readiness | 8–10 | 2026-12-20 | 30% |

---

## Milestone 1 — Public mainnet beta: claim, deploy, and Bond Monitor (weeks 1–3)

**Description**
Take the existing prototype to a public, hardened beta, and start collecting the historical data every later feature depends on.
- Deploy the frontend to a public URL (static hosting) with privacy-preserving analytics.
- Harden the claim flow: per-cycle claims through the reference signer-manager and `native-pool-signer-manager`, plus **two more manager adapters** chosen from the managers holding the most stake. Show clear "not routable" messages for L1-payout stakers and contract-held bonds.
- Harden the deposit flow for Zest v2, Hermetica hBTC, and Bitflow HODLMM. Keep stBTC listed but marked closed while `shutdown-deposits = true`.
- **Bond Monitor (public, no wallet):** bond parameters, fill, locked BTC/STX, schedule with estimated dates, and effective APY once distributions start.
- **Daily indexer:** snapshots of bond balances and payouts, per-cycle stacked STX, the signer set, venue rates and availability flags, and STX/BTC prices, starting from Bond 1 activation (block 966,350). Backfill whatever can be reconstructed from chain history.
- Add a licence, a security policy (`SECURITY.md`), and issue templates.

**Success criteria**
- The public URL is live, and every flow works on mainnet from Leather and Xverse.
- At least **one real claim and one real deposit** executed end-to-end, with links to the transactions.
- The indexer has run for ≥ 14 consecutive days with no gaps (or gaps backfilled). The data is exported publicly as CSV.
- Frontend test suite ≥ 60 tests, all passing. The contract suite runs in CI on Linux.
- Kill switch per venue and adapter verified.

**Adoption metric**
- ≥ **300 unique visitors** and ≥ **25 non-team connected wallets**
- ≥ **5 non-team claim or deposit transactions**
- First public "Waterfall Report" post published

---

## Milestone 2 — True Yield, Waterfall & Reserve, and Signer-Manager Scorecards (weeks 4–7)

**Description**
Ship the differentiated analytics the ecosystem lacks, each with a published methodology.
- **True Yield Calculator**, inline for connected positions and standalone for prospects: gross BTC yield, STX opportunity cost, STX/BTC P&L, net yield, net APY on total capital, a sensitivity table, and the breakeven STX/BTC move. It accounts for rollover per stacks-core #7301 (final-cycle rewards stay with the old bond index).
- **Waterfall & Reserve Monitor:** for each distribution interval, miner revenue, bond obligation, surplus or deficit, the 85% share to STX-only stakers, the 15% reserve contribution, the reserve balance, and a health state (green when there is surplus, amber when the reserve is covering a shortfall, red when it is depleting).
- **Signer-manager scorecards** for all registered managers (55 as of 2026-09-17): fee, fee ceiling, admin set, grant status, stake, participation in Bond 1, and claim reliability from indexed history.
- **Yield comparison** that labels LP fee APR as trading fees, shows incentives paid in STX separately, and treats "hold" as a valid option.
- Methodology documents in `docs/methodology/`, and a request for review sent to the Endowment and Stacks Labs.

**Success criteria**
- Net-yield output **reconciles to realised on-chain Bond 1 payouts within ≤ 1 bp** for every distribution since activation.
- Waterfall arithmetic **matches the reserve balance read from `pox-5`** for every indexed interval (differences are explained and logged).
- Scorecards cover **100%** of registered signer-managers, and every field links to its on-chain source.
- The assumption about whether bonded STX earns any Tranche 2 residual is resolved against chain data and documented.

**Adoption metric**
- ≥ **1,000 unique visitors/month** and ≥ **60 cumulative non-team connected wallets**
- ≥ **60%** of connected wallets open True Yield or a scorecard
- ≥ **30%** of connected wallets return in a second week
- ≥ **2 independent references** (forum, X, newsletter, or docs) to Kessel's data
- ≥ **10 user interviews** completed (stakers, bond participants, operators)

---

## Milestone 3 — Alerts, records, design partner, and router readiness (weeks 8–10)

**Description**
Turn one-off visits into repeat use, and test whether operators and institutions will pay.
- **Alerts** (email and Telegram): rewards claimable above a threshold, a signer-manager fee or admin change, reserve health changes, a venue opening or closing, and the Bond 1 renewal-window countdown (opens around block 990,500).
- **Claim and deposit history** stored per wallet, with **CSV export** in a format Koinly can import. This fills the sBTC gap, since Koinly's Stacks integration imports native STX only.
- **Venue ranking before and after the Zest incentive ends** (2026-12-10), published as a report.
- **Design-partner programme:** outreach to all 12 direct Bond 1 principals and the 5 registering operators, and a draft institutional statement (position, realised vs. target, net of the STX leg, cycle-by-cycle claims).
- **Reward Router readiness:** internal security review against the adversarial fixtures, testnet deployment of the router and adapters, and an audit scope with quotes. **No mainnet deployment without an audit.**
- Milestone report and a public retrospective, including a continue, pivot, or stop decision against the criteria in [PROBLEM_STATEMENT.md](PROBLEM_STATEMENT.md#what-evidence-would-show-the-concept-is-worth-continuing).

**Success criteria**
- Alerts are delivered for all five event types, with a measured delivery latency under 15 minutes of the on-chain event.
- The CSV export round-trips through a Koinly custom-CSV import for a test wallet.
- The router is deployed on testnet with an audit scope document published, and unit and fork suites are green in CI.
- **≥ 1 written design-partner commitment** (LOI, integration agreement, or a paid pilot conversation) from a bond participant, operator, or wallet.

**Adoption metric**
- ≥ **100 cumulative non-team connected wallets**; ≥ **1,500 unique visitors/month**
- ≥ **40 alert subscribers**
- ≥ **25 cumulative non-team claim or deposit transactions**
- ≥ **3 independent references**; ≥ **1 integration in discussion**

---

## Summary of verification artefacts

| Milestone | Public evidence reviewers can check |
|---|---|
| 1 | Live URL; mainnet transaction links; indexer CSV; CI runs; `SECURITY.md` |
| 2 | Methodology docs; reconciliation report vs. on-chain payouts; scorecard page; interview summary |
| 3 | Alert demo; CSV import screenshot; testnet router address; audit scope; design-partner letter (redacted if needed); retrospective post |
