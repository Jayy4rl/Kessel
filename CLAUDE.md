# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Kessel is currently **spec-only** — there is no smart-contract code, build tooling, or test suite in this repo yet. The entire technical design lives in `docs/PRD.md`. docs/PRD.md is the canonical protocol specification. Read the sections relevant to the current task before implementation. For protocol-level or architectural changes, read the PRD broadly enough to identify cross-section dependencies and invariants. Do not rely on partial recall when a requirement is ambiguous; inspect the source document. Do not load the entire PRD into context for routine, localized implementation tasks unless necessary. Prefer the smallest relevant set of documentation needed to make a correct decision.

## What Kessel is

Kessel is a Uniswap v4 hook implementing a two-lane execution mechanism on a single pool with one shared liquidity curve (liquidity is never fragmented):

- **Fast Lane** — synchronous, in-block swap. Dynamic fee = `f_base + tax(priorityFeePerGas)`. The premium above `f_base` is recaptured to LPs (via `donate()` or return-delta), not left to sequencers/searchers.
- **Slow Lane** — async: the hook escrows the trader's input (ERC-6909 claim, `beforeSwap` returns a `BeforeSwapDelta` consuming the full input) and issues a non-transferable, non-cancellable claim. Execution is deferred to a later **settlement** event where all orders in the batch clear at one uniform price computed at *settlement time* (never submission time — this is the anti-hedging property).

The economic point: letting traders self-select lane by urgency (a screening/price-discrimination mechanism) lets LPs capture the immediacy premium that a single static fee cannot price correctly. The mechanism prices *immediacy*, not *toxicity* — it does not claim to eliminate adverse selection or LVR, only to reallocate the immediacy premium to LPs and make the Slow Lane sandwich-proof. See PRD §1–§2 for the full framing; do not compress or restate this distinction incorrectly when explaining the design.

## Before implementing: unresolved design decisions

PRD §20 (Design Decisions Register) lists 15 decisions — DD-1 through DD-15 — that the spec *deliberately* leaves to the implementer (e.g. default lane when `hookData` is empty, the urgency-signal/target-chain choice, the Slow-Lane clearing-price definition P which the PRD calls the single highest-priority open item, settlement cadence/trigger, and the `afterSwap` permission). Do not silently default any of these while writing code. Before implementing a feature that touches an open DD, check whether it has since been resolved (look for a decision recorded in the repo or ask the user) rather than guessing — the PRD explicitly says `[OPEN]` items are never protocol requirements and must not be conflated with `[REQUIRED]` ones.

A handful of items that look like decisions were resolved by the PRD's engineering review into hard requirements, not left open — notably: Slow-Lane claims must be non-transferable (§5.1), the async delta accounting for Slow-Lane intake is fully specified (§3.2), settlement has two distinct entry paths that must not share one `unlock` call (§8.3), and the `afterSwap`/hook-permission bitmap must be finalized *before* the hook address is CREATE2-mined (§8.1) since v4 encodes permissions in the address.

## Core invariants (PRD §5.4, §13)

Twelve invariants (I1–I12) must hold in code and are the basis for the required property tests (PRD §15): delta settlement (I1), custody conservation (I2), no double-settle (I3), single clearing price for matched + residual orders (I4), fee routing to LPs with no capturing intermediary (I5, I7), settlement-time-only pricing / anti-hedging (I6), bounded trader downside via `minOut` (I8), a warehoused-exposure cap (I9), `0 ≤ f_slow < f_base` (I10), bounded liveness / forced settlement (I11), and fee monotonicity in priority fee (I12).

## Uniswap AI tooling

`docs/SKILLS.md` documents the Uniswap AI plugin ecosystem for coding agents. For v4 hook work, the `uniswap-hooks` plugin (`/plugin marketplace add uniswap/uniswap-ai`, then `/plugin install uniswap-hooks`) provides security-first hook guidance including a `v4-security-foundations` skill — directly relevant here since the PRD flags async-swap/custody misuse as the highest-severity audit surface (§12).

## Commands

No build, lint, or test tooling exists yet (no Foundry/Hardhat config, no package manifest). When implementation begins, add the actual build/test/lint commands here rather than assuming a toolchain.
