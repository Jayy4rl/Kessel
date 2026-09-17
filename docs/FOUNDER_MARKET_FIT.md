<!-- Explain why this founder/team is well placed to build this, what they have already proven, and where the gaps are -->

# Founder–Market Fit

> This assessment uses only **publicly verifiable evidence** (this repository and the founder's public GitHub, checked 2026-09-17). Fields marked **[FOUNDER TO COMPLETE]** need facts only the founder can supply. They are left blank rather than guessed.

## Summary

| Question | Assessment |
|---|---|
| Can this founder build it? | **Yes, strong evidence.** The hard, protocol-level part (per-cycle PoX-5 claims, heterogeneous signer-managers, deny-mode deposits, a Clarity 4 router with adversarial and mainnet-fork tests) is already built |
| Do they understand this market? | **Good and growing.** The repo records mainnet findings that the PRD missed (contract-caller venues, per-cycle claims, the #7301 rollover behaviour, stBTC shutdown). A March 2026 public repo shows earlier work on Stacks DeFi yield tooling |
| Can they sell and distribute it? | **Unproven.** No public evidence yet of users, partnerships, or community presence in Stacks |
| Can they sustain it? | **At risk.** Solo founder; many parallel projects across ecosystems in the public record |

## Who is building this

- **Founder:** Valerie, GitHub [@Jayy4rl](https://github.com/Jayy4rl) (account since January 2023). The sole author of every commit in this repository.
- **Role:** full-stack protocol engineer: Clarity contracts, TypeScript/React frontend, test infrastructure.
- **Location, time commitment, prior employment, education, community handles:** **[FOUNDER TO COMPLETE]**
- **Hours per week committed during the grant:** **[FOUNDER TO COMPLETE]**. Reviewers will weigh this against the many active repos below.

## Evidence of fit

### 1. Technical depth that matches this product's hardest problems (verified in this repo)

| Capability the product needs | Evidence |
|---|---|
| PoX-5 accounting | The claim builder reads per-cycle rewards from `pox-5`, because Hiro reports one lifetime claimable total while a claim names a single cycle ([frontend/src/lib/staking-api.ts](../frontend/src/lib/staking-api.ts)) |
| Security-first Clarity | The Reward Router uses `restrict-assets?`, measures the claim as a balance delta rather than trusting the manager's reported value, and requires all of the claimed amount to leave for the target ([contracts/contracts/reward-router.clar](../contracts/contracts/reward-router.clar)) |
| Adversarial testing | Fixtures for lying, greedy, and evil managers, plus partial targets; 27 unit tests ([contracts/tests/](../contracts/tests/)) |
| Testing against real mainnet state | Mainnet-fork tests via Clarinet remote data, which caught the stBTC deposit shutdown ([contracts/tests-fork/](../contracts/tests-fork/)) |
| Careful integration research | Found that Zest v2 and Hermetica hBTC debit `contract-caller`, and redesigned the product around two wallet transactions instead of forcing an atomic router ([contracts/README.md](../contracts/README.md)) |
| Frontend delivery | Working mainnet onboarding → claim → deposit page; 41 passing tests |

### 2. Prior work in the same market (public GitHub)

- **SatoshiPilot** (created 2026-03-02, original repo): an "AI-powered DeFi copilot for the Stacks blockchain" that "aggregates live yield data from eight Bitcoin DeFi protocols" and stages signed transactions. The founder has been working on Stacks yield decision tooling for about six months, before PoX-5 launched.
- **Yield and staking in other ecosystems:** original repos include `Staking-Dapp` (2025-09), `MantleYield` (2025-12), and three Uniswap v4 hook projects (`DynamicFeeHook`, `PointsHook`, `ReturnDeltaHook`, 2026). That is experience with fee and yield mechanics at the contract level.
- **Breadth:** 33 original and 67 forked public repos across Solidity, TypeScript, Rust, and Clarity, with recent activity in Stellar/Soroban and Solana/Anchor programmes.

### 3. Insight the founder has that the market lacks

The founder's own mainnet work produced this project's central insights:
- The "3% bond yield" hides a material STX/BTC exposure.
- Reward deployment is constrained by who each venue lets call it.
- Signer-manager heterogeneity is a real integration and user problem.

These came from building, not desk research.

## Gaps and how we will close them

| Gap | Why it matters | Plan |
|---|---|---|
| **No shipped, used Stacks product yet** | Reviewers weight traction; the Builder track needs it | Milestone 1 ships a public beta with verifiable mainnet transactions |
| **Split focus across many ecosystems** | Recent public activity spans Stellar, Solana, and EVM programmes at the same time as this project | Declare committed hours **[FOUNDER TO COMPLETE]**; publish weekly progress; tie grant payments to milestones |
| **Solo founder (bus factor = 1)** | Continuity and review | Recruit a second maintainer by M3; ask the Stacks community for code review |
| **No distribution or GTM track record in Stacks** | The product only matters if stakers find it | Weekly public Waterfall Report; direct outreach to Bond 1 participants and operators; seek wallet integrations |
| **No finance or institutional-reporting background (on public record)** | The B2B thesis depends on statements that funds trust | Methodology review by the Endowment or Stacks Labs; recruit one design partner from a Bond 1 institution as an adviser |
| **No audit history** | The Reward Router needs one | Router stays on testnet; an auditor introduction is requested in [ECOSYSTEM_FIT.md](ECOSYSTEM_FIT.md) |

## Why now, and why this founder

PoX-5 is seven weeks old, and Bond 1 pays for the first time this week. The tooling gap is at its widest and the incumbents are busy shipping their own products. A builder who has already mapped the protocol's rough edges on mainnet can close that gap faster than a team starting from the SIP. The open question is whether the founder can focus and distribute, and the milestones are designed to answer it publicly within 10 weeks.

## To complete before submission

- [ ] Short bio (2–3 lines): background, prior roles, notable shipped work **[FOUNDER TO COMPLETE]**
- [ ] Links: X/Twitter, Stacks forum, Discord handle, personal site **[FOUNDER TO COMPLETE]**
- [ ] Committed hours per week and other current obligations **[FOUNDER TO COMPLETE]**
- [ ] Any prior grants, hackathon wins, or audits (in any ecosystem) **[FOUNDER TO COMPLETE]**
- [ ] Advisers or prospective collaborators, if any **[FOUNDER TO COMPLETE]**
- [ ] Whether SatoshiPilot is live, has users, or will be merged into Kessel **[FOUNDER TO COMPLETE]**
