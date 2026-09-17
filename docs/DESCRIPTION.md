<!-- Summarize what exists today, what funding would be used for, and what reviewers should understand about the project first -->

# Kessel — Project Description

**Kessel is the neutral risk-and-yield layer for Bitcoin Staking on Stacks.** It shows PoX-5 stakers what their position actually earns after the STX pairing leg, where their yield comes from in the reward waterfall, and how safe their signer-manager is. It then lets them claim and deploy rewards from their own wallet with deny-mode safeguards.

**Grant fit:** Stacks Endowment Q3 2026. Theme 1 (Bitcoin Staking & sBTC Utility, "portfolio management tools") is primary; Theme 3 (Market Efficiency & Risk, "risk management, market analytics") is secondary. **Track requested:** Getting Started (up to $10k).

## What exists today (verified 2026-09-17)

| | |
|---|---|
| **Frontend** | Mainnet-only React app: public bond list → wallet connect (Leather/Xverse) → eligibility preflight → positions and claimable cycles → claim through the staker's signer-manager → ranked deposit into Zest v2, Hermetica hBTC, or Bitflow HODLMM (stBTC shown as closed) → activity log. **41 tests passing.** |
| **Contracts** | Reward Router (Clarity 4): atomic claim-and-deploy for venues that accept contract callers; never holds funds; pause and two-step ownership. Adapters for StackingDAO stBTC and `native-pool-signer-manager`. **27 unit tests + 9 mainnet-fork tests**; `clarinet check` passes under WSL/Linux. **Not audited, not deployed.** |
| **Users / revenue / partners** | None yet. Not publicly deployed. |
| **Team** | Solo founder-engineer ([FOUNDER_MARKET_FIT.md](FOUNDER_MARKET_FIT.md)) |

## What funding would be used for

Three milestones over 10 weeks ([MILESTONES.md](MILESTONES.md)):
1. **Public mainnet beta** (claim, deploy, Bond Monitor, daily indexer). *35%*
2. **True Yield, Waterfall & Reserve Monitor, and Signer-Manager Scorecards**, each reconciled to on-chain data and published with its methodology. *35%*
3. **Alerts, CSV/tax export, a design-partner programme, and testnet readiness for the Reward Router** (no mainnet deployment without an audit). *30%*

Indicative split of a $10k grant: ~70% engineering, ~10% infrastructure and data, ~10% independent methodology review, ~10% user research and outreach. Running cost is kept to ≤ $50/month.

## What reviewers should understand first

1. **The PRD in this repo is a starting point, not the plan.** Our research against live chain data changed the product:
   - **Bond 1 has only 15 principals** (230.17 of 250 BTC filled), and StackingDAO holds 60% of the capacity through a contract. So the volume audience is **STX-only stakers (441.6M STX stacked) and sBTC holders (14.5k holder records)**. Bond participants are design partners, not the user base.
   - **Compounding weekly rewards is not a compelling pitch at today's rates** (Zest sBTC supply 0.13%, stBTC deposits closed). We lead with *net yield and risk* instead.
   - **The largest venues only accept deposits sent directly from the user's wallet** (Zest v2, hBTC debit `contract-caller`). The two-transaction flow is the product, and the router is optional.
2. **The core insight is quantitative.** A bond's 6-month yield is ~1.44% on BTC, and the required STX leg is 5% of the position. A **~25% STX/BTC drop erases the whole term's return**. STX has already fallen 3.2% against BTC since Bond 1's parameters were set. We found no existing tool that shows this.
3. **This is not another portfolio tracker.** Generic Stacks tracking exists (Staxiq, the AIBTC dashboard skill, StackingDAO's Stacking Tracker). Kessel's scope is the PoX-5-specific gap: net yield, waterfall and reserve, neutral signer-manager diligence, and per-cycle claims across different managers ([BUSINESS_MODEL.md](BUSINESS_MODEL.md#competitive-landscape)).
4. **Kessel is neutral by design.** It runs no signer-manager, LST, vault, or token, and takes no transaction fees. That neutrality is the reason incumbents could adopt its data instead of competing with it.

## Extra context reviewers should consider

- **Commercial outlook (candid):** Bond 1 pays about 6.9 BTC a year in total, so fees on routed flow cannot sustain a company. The sustainable path is **B2B reporting and data for bond participants, operators, and wallets**, and it only becomes a meaningful business if bond capacity grows toward the SIP's initial program conditions (3,000 BTC) and PoX-6 broadens access. Scenarios, pricing hypotheses, and unit economics are in [BUSINESS_MODEL.md](BUSINESS_MODEL.md).
- **The smallest useful outcome** is a free, public, on-chain-reconciled page showing Bond 1's net yield and weekly waterfall. It is valuable to the ecosystem even with no wallet connections ([ECOSYSTEM_FIT.md](ECOSYSTEM_FIT.md#the-smallest-useful-impact-this-funding-should-produce)).
- **Timing:** Bond 1's first distribution happens this week (block 967,400). The Zest sBTC incentive ends on 2026-12-10, inside the grant window. Bond 1's renewal window opens around 2027-02-24, which is the first high-stakes decision for participants and the target for the post-grant renewal flow.
- **Clear stop and pivot criteria** are defined up front ([PROBLEM_STATEMENT.md](PROBLEM_STATEMENT.md#what-evidence-would-show-the-concept-is-worth-continuing)), and all material risks are disclosed ([RISK_DISCLOSURE.md](RISK_DISCLOSURE.md)).
- **Regulatory context:** the US CLARITY Act failed cloture on 2026-09-15, so there is no statutory safe harbour for DeFi front-ends. Kessel stays non-custodial and fee-free, and frames its output as education, not advice.

### Document map

| File | Contents |
|---|---|
| [PROBLEM_STATEMENT.md](PROBLEM_STATEMENT.md) | Problems, evidence, what's built, validation criteria |
| [AUDIENCE.md](AUDIENCE.md) | Segments sized from on-chain data, beachhead, personas |
| [ECOSYSTEM_FIT.md](ECOSYSTEM_FIT.md) | Stacks dependencies, Q3 2026 theme fit, maintenance, public reporting |
| [MILESTONES.md](MILESTONES.md) | Three milestones over 10 weeks with success and adoption metrics |
| [RISK_DISCLOSURE.md](RISK_DISCLOSURE.md) | Market, technical, operational, and legal risks, and dependencies |
| [FOUNDER_MARKET_FIT.md](FOUNDER_MARKET_FIT.md) | Evidence of fit, gaps, items for the founder to complete |
| [BUSINESS_MODEL.md](BUSINESS_MODEL.md) | Market size, competitors, revenue model, pricing, GTM, KPIs, funding *(added; no skeleton existed)* |
