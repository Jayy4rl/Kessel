<!-- Explain why the work belongs on stacks and how it will be maintained -->

# Ecosystem Fit

> Tags: **[Verified]** primary source, dated · **[Estimate]** · **[Assumption]** · **[Recommendation]**. On-chain snapshot 2026-09-17 (block 967,388).

## The Stacks-specific reason this should exist

Kessel cannot exist anywhere else. Every feature depends on PoX-5 or Clarity:

| Dependency | How Kessel uses it |
|---|---|
| **PoX-5 / Bitcoin Staking** (SIP-044/045; live since 2026-07-30) | Reads bonds, registrations, per-cycle staker rewards, and the reserve from `SP000000000000000000002Q6VF78.pox-5`. Models the tranche waterfall (bonds first, then 85% to STX-only stakers and 15% to the reserve) |
| **sBTC** (`SM3VDXK3…sbtc-token`) | Rewards are paid in sBTC by default. Every deposit and claim is guarded with sBTC post-conditions |
| **Signer-managers** | PoX-5 routes *all* staking through a manager contract. Kessel claims via `claim-staker-rewards` and ships adapters for managers that differ from the reference (e.g. `native-pool-source`) |
| **Clarity** | Deny-mode post-conditions on every transaction. Clarity 4 `restrict-assets?` in the Reward Router, so an untrusted manager or venue can't move the caller's other assets |
| **Bitcoin L1** | Bond BTC stays in a self-custodial P2WSH timelock. Kessel shows the L1 lockup and the renewal window (timelock expires 1,050 blocks before the bond ends) |
| **Wallets** | Leather and Xverse via `@stacks/connect`. Transactions are built client-side and signed in the user's wallet |
| **Ecosystem protocols** | Zest v2 (`v0-vault-sbtc`), StackingDAO (`stacking-dao-core-stbtc-v1`), Hermetica (`vault-hbtc-v1-2`), Bitflow HODLMM (`dlmm-liquidity-router-v-1-2`) |
| **Hiro** | v3 staking API (bonds, positions, signers) and read-only calls |

## Maintenance, issue handling, and user support

**Who maintains it:** the founder (GitHub [@Jayy4rl](https://github.com/Jayy4rl)) is the sole maintainer during and after the grant. **[Recommendation]** Add a second maintainer with commit rights by the end of Milestone 3 (a contributor recruited from the Stacks developer community or a design partner's engineer) so the project doesn't depend on one person.

**How it stays cheap to maintain:**
- The frontend is a static build (Vercel/Netlify/IPFS). The only server component is a daily indexer cron. Target running cost is **≤ $50/month** [Estimate].
- Each venue and signer-manager sits behind its own adapter file, so a protocol upgrade (e.g. Zest v3) only touches one module.
- Venue availability is read live, never cached. If a venue closes (as StackingDAO stBTC did), it shows as closed automatically.
- The mainnet-fork test suite (`contracts/tests-fork/`) re-runs against real state whenever `FORK_HEIGHT` is bumped. This catches protocol changes before users hit them.

**Issue handling:**
- Public GitHub issues with templates for *bug*, *wrong number* (data discrepancy), and *new venue/manager request*.
- Severity targets [Recommendation]: **fund-safety or wrong-transaction bugs**: acknowledged within 24h, the affected flow disabled by feature flag the same day. **Wrong displayed data**: fixed or flagged on the page within 72h. **Feature requests**: triaged weekly.
- A **kill switch** per venue and per manager adapter in the frontend config, and the Reward Router's on-chain `set-paused` if it is ever deployed.

**What users can expect:**
- A public status note on the site whenever a data source (Hiro, Bitflow API) is degraded.
- A published methodology for every computed number (net yield, waterfall, scorecard).
- A support channel on GitHub Discussions and a Telegram/Discord handle. Best-effort community support, not an SLA, for free users.
- A clear statement that Kessel **never holds funds** and that nothing on the site is financial advice.

## Fit with the Q3 2026 Stacks Endowment themes

The Q3 2026 call runs **Aug 31 – Sep 23, 2026** and names three themes ([Stacks Endowment](https://stacksendowment.co/blog/q3-2026-stacks-endowment-grants)):

| Theme | What the Endowment says | How Kessel fits |
|---|---|---|
| **1. Bitcoin Staking & sBTC Utility** | Back teams that "turn that infrastructure into useful products": "Bitcoin-backed financial products, **portfolio management tools**, collateral management, and new sBTC use cases" | Kessel is a portfolio *decision* tool for PoX-5 positions and claimed sBTC. **Primary fit** |
| **3. Market Efficiency & Risk** | "**risk management, market analytics**, execution, collateral, treasury infrastructure" | Net-yield modelling, waterfall and reserve monitoring, signer-manager risk scorecards, and deny-mode execution. **Strong secondary fit** |
| 2. Distribution & Integrations | Connect Stacks to existing audiences | Indirect: widget and data integrations with wallets and operators (post-grant) |

**The call excludes** "core Bitcoin Staking infrastructure or … additional versions of products already well represented" without differentiation. Our response:
- Kessel is **not core infrastructure**. It runs no signer, no manager, and no bridge.
- It is **not another portfolio tracker**. Generic tracking already exists (Staxiq, the AIBTC dashboard skill, StackingDAO's Stacking Tracker). Kessel's differentiation is *net-of-STX yield, waterfall and reserve risk, neutral signer-manager diligence, and per-cycle claims across different managers*. We found none of these in the public materials of existing tools (see [BUSINESS_MODEL.md](BUSINESS_MODEL.md#competitive-landscape)).

Reviewers score strategic alignment, ecosystem impact, feasibility, budget reasonableness, risk profile, and ecosystem commitment on a 0–5 scale ([Stacks blog](https://www.stacks.co/blog/everything-you-need-to-know-about-applying-for-a-stacks-endowment-grant)). This application addresses each in turn: this file, [AUDIENCE.md](AUDIENCE.md), [MILESTONES.md](MILESTONES.md), [BUSINESS_MODEL.md](BUSINESS_MODEL.md#funding-considerations), [RISK_DISCLOSURE.md](RISK_DISCLOSURE.md), and the maintenance plan above.

## Intended ecosystem impact

**Value proposition to the ecosystem:**
1. **Trust in Bitcoin Staking.** Bitcoin Staking is sold on a 3% target. If stakers find out afterwards that the STX leg erased their yield, that damages the product. Honest, public net-yield numbers set expectations up front and protect the programme's credibility.
2. **A public check on bond sustainability.** The Endowment sets bond capacity, rate, and ratio during bootstrap ([SIP-045](https://github.com/stacksgov/sips/blob/main/sips/sip-045/sip-045-pox-5-bitcoin-staking.md)). A neutral waterfall and reserve dashboard gives the community a shared view of whether those parameters are sustainable, and whether STX-only stakers are being squeezed.
3. **Safer delegation.** Manager scorecards raise the bar for signer-managers on fees and admin controls. That matters because PoX-5 made every staker depend on one.
4. **Reusable open-source building blocks.** Per-cycle claim builders, signer-manager adapters, and live venue readers that any wallet or app can adopt.

**Projected traction (grant period) [Estimate]:** 100 connected wallets, 1,500 monthly visitors, 25+ non-team transactions, 40 alert subscribers, 1 design partner, 3 independent citations. The rationale is in [MILESTONES.md](MILESTONES.md). These targets are deliberately modest: Bond 1 has only 15 principals, and the realistic early audience is STX-only stakers and sBTC holders.

## The smallest useful impact this funding should produce

> **A free, public page that shows, for Bond 1, what participants actually earned net of the STX leg, and how each week's miner revenue flowed through the waterfall and reserve. It should be reconciled to on-chain payouts and published with its methodology.**

Even if no one connects a wallet, that page is a public good the ecosystem currently lacks, and it becomes more valuable with every distribution.

## Support from the Stacks ecosystem that would help

- **Stacks Endowment / Stacks Labs:** a methodology review of the net-yield and waterfall model; advance notice of new bond parameters; a mention in bond participant communications.
- **Hiro:** an API key or higher rate limits for the indexer; guidance on exposing reserve and waterfall fields in the v3 staking API.
- **Signer-manager operators:** confirmation of fee and interface details for the scorecard, and a heads-up before contract changes.
- **Leather / Xverse:** a conversation about linking to or embedding the scorecard and net-yield view.
- **Security:** an introduction to a Clarity auditor, or a subsidised audit slot, for the Reward Router.
- **Design partners:** 2–3 Bond 1 participants willing to give 30 minutes of feedback a month.

## What happens after funding if the work succeeds

1. **Renewal flow before the Bond 1 renewal window** (opens at block 990,500, ~2027-02-24 [Estimate]). This is the first high-stakes decision every bond participant faces.
2. **Paid institutional statements and an operator data API**, which fund continued maintenance (see [BUSINESS_MODEL.md](BUSINESS_MODEL.md#business-and-revenue-model)).
3. **Apply for a Builder grant** (up to $50k) on the strength of traction, to fund an audit and deploy the Reward Router for venues that accept contract callers.
4. **Follow PoX-6.** As bond parameters become algorithmic and consensus-encoded, the net-yield and waterfall models become more important for evaluating each new bond.

If the work does *not* show demand, the open-source libraries and methodology stay public and are offered to the incumbents (see the stop criteria in [PROBLEM_STATEMENT.md](PROBLEM_STATEMENT.md#what-evidence-would-show-the-concept-is-worth-continuing)).

## Sharing progress and learnings publicly

- **Open source:** all code in the public repository (`Jayy4rl/Kessel-v1`), with the MIT or Apache-2.0 licence [Recommendation; to be added].
- **A weekly "Waterfall Report"** on the Stacks forum and X: revenue, bond obligations, residual to STX-only stakers, reserve change, and Bond 1 net yield.
- **A milestone report** at the end of each milestone: what shipped, metrics against target, what we learned, and what changed. Posted to the Stacks forum and the Endowment portal.
- **Published methodology documents** in `docs/`, versioned, with any correction logged.
- **A public metrics page** (privacy-preserving counts only; no wallet-level data published).

## Sources

- Stacks Endowment Q3 2026 call — https://stacksendowment.co/blog/q3-2026-stacks-endowment-grants
- Stacks Endowment grant guide — https://www.stacks.co/blog/everything-you-need-to-know-about-applying-for-a-stacks-endowment-grant
- SIP-045 — https://github.com/stacksgov/sips/blob/main/sips/sip-045/sip-045-pox-5-bitcoin-staking.md
- Stacks docs, Staking — https://docs.stacks.co/learn/block-production/staking
- PoX-5 activation — https://chainwire.org/2026/07/30/stacks-successfully-activates-pox-5-laying-the-foundation-for-bitcoin-staking/
- Hiro API snapshots, 2026-09-17
- Repository: [contracts/README.md](../contracts/README.md), [frontend/README.md](../frontend/README.md)
