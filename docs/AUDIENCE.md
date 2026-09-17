<!--Explain who benefits from this projecct  -->

# Audience

> Tags: **[Verified]** = read from a primary source (on-chain via Hiro API on 2026-09-17, block 967,388, unless stated). **[Estimate]** = our arithmetic on verified inputs. **[Assumption]** = not yet tested. Sources are at the end.

## Who benefits from this work

The original PRD aimed at "Bitcoin Staking bond participants." **On-chain data shows that group is tiny and mostly institutional today:**

- **[Verified]** Bond 1, the only bond so far, has **15 allowlisted principals, all 15 registered**, holding **230.17 BTC** of a **250.005 BTC** cap (92% full), paired with 3.57M STX.
- **[Verified]** Three of the 15 are *contracts* that pool other people's capital: StackingDAO's `stbtc-staker-bond-1-v2` (**150 BTC allowance, 60% of the bond**), Xverse's `sbtc-bond-staker-v1-1` (25 BTC), and `esbee-dao-bond-staker-1` (5 BTC). Seven standard addresses hold allowances of 5–25 BTC, and five more hold 0.001 BTC each.
- **[Verified]** The registrations sit with five signer operators: Stacks Labs (7), HashKey Cloud (5), StackingDAO (1), Xverse (1), and Fast Pool (1). Reported anchor participants include UTXO (a Nakamoto Inc. subsidiary), HashKey Cloud, and 21Shares ([Crypto Briefing](https://cryptobriefing.com/xverse-self-custodial-bitcoin-staking-launch/)).
- **[Verified]** Retail reaches bond yield *through intermediaries*. stBTC has only **73 holder records**, and **86% of stBTC supply sits in a single Zest vault** (`v0-vault-stbtc`), so most stBTC exposure is itself deposited in Zest.

The people Kessel can actually help are therefore wider than bond holders. The product is useful to **anyone whose BTC-denominated yield depends on PoX-5**, and to the **operators who sit between them and the protocol**.

## Audience segments

| # | Segment | Size today | What they need | Kessel's role | Priority |
|---|---|---|---|---|---|
| A | **STX-only stakers** (direct or pooled) | **441.6M STX stacked** (≈$105M, 23.6% of liquid supply) in cycle 143 **[Verified]**. ~9,400 pooled and 7 solo stacker addresses in cycle 138, before PoX-5 **[Verified]** | Pick a signer-manager safely; understand how bond obligations shrink their residual; claim reliably | Signer-manager scorecard, waterfall monitor, claim, alerts | **Beachhead (volume)** |
| B | **Liquid-staking holders** (stSTX, stBTC) | 45,105 stSTX and 73 stBTC holder records **[Verified]** (these counts may include zero-balance addresses) | Know what their LST is really earning and what it is exposed to | Yield comparison, waterfall context, risk flags | Secondary |
| C | **sBTC holders** looking for yield | **2,463.8 sBTC** supply (≈$189M); **14,466 holder records** **[Verified]** | A safe answer to "where should this sBTC go this week, if anywhere?" | Live venue ranking with honest labels; deny-mode deposits | Secondary (top of funnel) |
| D | **Direct bond participants** (self-custodied, allowlisted) | ~7–12 principals in Bond 1 **[Verified]** | Per-cycle claims, true yield net of the STX leg, renewal decision, reporting | Full position tooling; the renewal flow later | **Design partners** |
| E | **Intermediaries**: pool operators, signer-managers, wallets, LST issuers | 55 registered signer-managers; 5 operators hold Bond 1 registrations; 2 major wallets (Leather, Xverse) **[Verified]** | Transparency they can point users to; embeddable claim and yield components; data they don't want to build themselves | Open-source modules, data API, white-label widgets | **Revenue path** (see [BUSINESS_MODEL.md](BUSINESS_MODEL.md)) |
| F | **The ecosystem**: Endowment, researchers, analysts | Small but influential | Public, reproducible waterfall and reserve data to judge whether bond parameters are sustainable | Open dashboard and open methodology | Public good |

**Addressable reach, bottom-up [Estimate]:** Segments A–C add up to roughly **50–60k addresses** (there is overlap, and some addresses are contracts or empty). For context, Xverse says it is "trusted by 2M+ people" ([xverse.app](https://www.xverse.app/)), and Stacks reports 400k+ wallets created ([Stacks Q1 2026](https://www.stacks.co/blog/q1-2026-snapshot)). A realistic 12-month target for a new, independent tool is **1–3% of the A–C addresses (≈500–1,500 wallets)**. That is enough to test the product, but it is not a venture-scale consumer business on its own.

### Why we are not leading with institutions (yet)

The capital in bonds is institutional and custodied (Fordefi, BitGo, Fireblocks are named integrations: [stacks.co](https://www.stacks.co/bitcoin-staking), [Stacks Q1 2026](https://www.stacks.co/blog/q1-2026-snapshot)). Institutions sign through their custody platforms, not through a Leather browser extension. What they would buy is **reporting and data** (position statements, realised vs. target yield, reserve health), which we would sell through the design-partner route in Segment D/E. A consumer web app is not what they need.

## Beachhead

**Recommended beachhead: STX-only stakers choosing or reviewing a signer-manager, plus the few direct bond participants as design partners.**

Why:
1. **PoX-5 forces a new decision on every staker** (which signer-manager to use), and today that means reading contracts ([Stacks docs](https://docs.stacks.co/learn/block-production/staking)). A forced, recurring decision is the best wedge for a new tool.
2. **The segment is the largest by count** (thousands of addresses) and is directly exposed to bond growth through the waterfall.
3. **Direct bond participants are few enough to contact one by one.** Their feedback on true yield and reporting shapes the paid product.

## Personas

### Persona 1 — "Ade", self-custodial STX staker (Segment A)

- **Profile:** Holds 40,000 STX (≈$9.6k) in Leather and has stacked through a pool since 2023. Reads the Stacks forum but doesn't read Clarity.
- **Problem:** After PoX-5, their old pool flow changed and every stake must name a signer-manager. There are 55 to choose from, each with its own fee and admin keys. Their BTC yield also now depends on how much miner revenue is left after bonds are paid, and nothing shows them that.
- **How Kessel helps:** A **signer-manager scorecard** turns the on-chain checks the docs recommend (fee, fee ceiling, admin set, claim record) into a plain comparison. The **waterfall monitor** shows, cycle by cycle, how much revenue reached STX-only stakers and whether the reserve is being drawn. An **alert** tells them when rewards are claimable and when their manager changes a fee.
- **Success for Ade:** Chooses a manager in minutes, understands a drop in yield before it happens, and never misses a claim.

### Persona 2 — "Mira", treasury lead at a small Bitcoin-native fund with a Bond 1 allocation (Segment D)

- **Profile:** Holds a 10 BTC allowance, is self-custodied, and reports monthly to LPs in BTC terms.
- **Problem:** The bond is marketed at 3%, but LPs ask what the fund actually earned. The STX leg (≈15.5k STX per BTC) has already lost 3.2% against BTC since parameters were set. Rewards are credited per cycle, and a rollover leaves the final cycle's rewards under the old bond index (stacks-core #7301). The renewal window opens around late February 2027 (block 990,500), and the decision needs a comparison against stBTC, Zest, and hBTC.
- **How Kessel helps:** **True Yield** per position (gross, STX opportunity cost, STX/BTC P&L, net, breakeven), a **cycle-accurate claim history with CSV export**, and a **renewal comparison** at decision time. Claims go through their own signer-manager with deny-mode post-conditions.
- **Success for Mira:** A monthly statement they can give to LPs without a spreadsheet, and a documented renewal decision.

### Persona 3 — "Tomi", sBTC holder who just received rewards (Segment C)

- **Profile:** Holds 0.3 sBTC from bridging and a pooled bond position through Xverse. Wants "yield on Bitcoin" but has heard about DeFi exploits.
- **Problem:** Every venue shows a different number. Zest shows 0.13% supply APR plus an incentive paid in STX. stBTC is closed. hBTC fills in a day. A Bitflow pool shows 440% one hour and a fraction of that the next. They can't tell trading fees from BTC yield, or which venues are open.
- **How Kessel helps:** One ranked list, read live. Closed venues are marked closed, LP fee APR is labelled "trading fees, not BTC yield," and volatility is flagged. Deposits are built in deny mode so the wallet can't send more than the amount shown. Sometimes the honest recommendation is to **hold**, and the product says so.
- **Success for Tomi:** Makes an informed choice (including doing nothing) without being misled by headline APRs.

## Sources

- Hiro API (2026-09-17): `/extended/v3/staking/bonds`, `/staking/bonds/1/allowlist`, `/staking/bonds/1/registrations`, `/staking/signers`; `/v2/pox`; `/extended/v2/pox/cycles/{138,143}/signers`; `/extended/v1/tokens/ft/{sbtc-token, ststx-token, stbtc-token}/holders`
- Xverse pooled staking launch — https://cryptobriefing.com/xverse-self-custodial-bitcoin-staking-launch/
- Xverse homepage — https://www.xverse.app/
- Stacks Bitcoin Staking page — https://www.stacks.co/bitcoin-staking
- Stacks Q1 2026 snapshot — https://www.stacks.co/blog/q1-2026-snapshot
- Stacks docs, Staking — https://docs.stacks.co/learn/block-production/staking
- stacks-core #7301 — https://github.com/stacks-network/stacks-core/issues/7301
