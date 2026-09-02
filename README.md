# Kessel

A Uniswap v4 hook implementing **two execution lanes on one shared liquidity curve**. Liquidity is never fragmented; the trader picks a lane per swap.

- **Fast Lane** — synchronous, in-block. Dynamic fee `f_base + tax(priorityFeePerGas)`. The premium above `f_base` is recaptured to LPs rather than left to sequencers or searchers.
- **Slow Lane** — deferred. The hook escrows the input and issues a non-transferable, non-cancellable claim. All orders in a batch clear at a **single uniform price computed at settlement time**, which is what makes the lane sandwich-proof and removes the hedgeable basis.

Letting traders self-select by urgency is a screening mechanism: it prices **immediacy** — a real cost the LP bears for filling *now* against committed inventory — and routes that premium to LPs. It does **not** price or identify toxicity, does not remove adverse selection from the Slow Lane, and does not reduce total LVR. See `docs/PRD.md` §1–§2.

## Status

**Implemented and tested; not reviewed by a human.**

`src/` holds `KesselHook.sol` plus four libraries. **227 tests pass**, including all twelve protocol invariants as real stateful assertions (256 runs × 16,384 calls, zero reverts). Two tests skip without an RPC endpoint — see [Testing](#testing).

`docs/PRD.md` is the canonical specification and the document to review against.

## Quick start

```bash
git submodule update --init --recursive
forge build
forge test
```

Expect `227 passed, 0 failed, 2 skipped`. The two skips are the live-RPC halves of the A3 fork test and are explained below; nothing else requires configuration.

Dependencies nest — `v4-core` and `permit2` are submodules of `v4-periphery` — so `--recursive` is required, not optional.

## Architecture

```
src/
  KesselHook.sol        All state. Implements beforeSwap / afterSwap /
                        unlockCallback, and owns every stateful decision:
                        lane routing, Slow-Lane intake and custody, the order
                        book, settlement, redemption, recapture, governance.

  KesselTypes.sol       Lane, OrderStatus, Order, Epoch, errors and events.
                        One shared vocabulary, so the pure libraries and the
                        hook agree without importing each other.

  lanes/
    LaneCodec.sol       PURE. hookData encode/decode and the default-lane rule.
    FastLaneFee.sol     PURE. g(priorityFee, ...) -> uint24, saturating and
                        monotone. Two tax modes: size-denominated where one
                        side of the pool is the gas token, rate form otherwise.

  settle/
    Clearing.sol        PURE. The uniform-price closed form, the residual, and
                        the fill ratio. Accepts no submission-time state at
                        all, which is how anti-hedging is enforced structurally
                        rather than by review.
    BatchSolver.sol     Deployed library. Walks up to four constant-liquidity
                        ranges to size the settlement residual and predict the
                        batch price. Separated from the hook to stay under the
                        EIP-170 bytecode limit.
    TickScan.sol        Tick-bitmap search for the active range bounds.
                        Internal; inlines into BatchSolver.
```

`BatchSolver` is a linked library, so deployment is two transactions: deploy the library, then deploy the hook against it.

### Deployment constraint

`KesselHook` is close to the EIP-170 24,576-byte runtime limit. **Only the `optimized` profile produces a deployable contract**, and `optimizer_runs` there is tuned for size rather than runtime gas:

```bash
FOUNDRY_PROFILE=optimized forge build --sizes
```

The test suite places runtime bytecode with `vm.etch`, which bypasses the size limit entirely — so `forge test` passing is **not** evidence that the contract can be deployed. Check `--sizes` after any change to `src/`.

The hook is immutable and bound to a single pool at construction. That binding is a security requirement, not a simplification: ERC-6909 custody is held per *currency*, so a hook serving two pools that share a currency could have one pool's settlement drain the other's escrow.

## Testing

| Directory | What it covers |
|---|---|
| `test/invariant/` | All twelve invariants as stateful assertions, none skipped, driven by `KesselHandler`. A thirteenth proves a run was not vacuous. |
| `test/property/` | Fuzz tests over the pure libraries, including against v4's own `SqrtPriceMath`. |
| `test/integration/` | Fast Lane, Slow Lane, settlement, lifecycle, governance, multi-range clearing, native and gas-token pools. |
| `test/security/` | Adversarial tests. Each was written before its fix and observed to fail first, so each is a regression lock: if one starts failing, a closed attack has reopened. |
| `test/scaffold/` | Pins upstream v4 behaviours the design depends on. A failure here after a dependency bump means an assumption changed, not that a test is flaky. |
| `test/economic/` | Measurements rather than assertions: settlement-gas incidence, `k` calibration, clearing-price manipulation. |
| `test/fork/` | Assumption A3 — that the target chain orders by priority fee. |

**The two skipped tests.** `test/fork/A3PriorityOrdering.t.sol` contains two tests that fork Base mainnet and need `BASE_RPC_URL` set to an **archive** endpoint. Without it they skip with an explanatory message rather than silently passing, because a local mock would only prove the mock was written to pass.

The evidence for A3 is not lost with them: `test_A3_baseOrdersAdjacentTransactionsByPriorityFee` runs offline against committed measurements in `test/fork/data/a3-ordering.json` — Base mainnet, 12 blocks, 323,885 transaction pairs, **96.07% of adjacent pairs correctly ordered by priority fee** against a 90% floor. That is the property the Fast Lane depends on: an actor landing immediately ahead of a victim must have outbid it.

To run the live halves:

```bash
BASE_RPC_URL=<base mainnet archive endpoint> forge test --match-path 'test/fork/*' -vv
```

## Profiles

```bash
forge test                              # default: fast dev loop, via_ir off
FOUNDRY_PROFILE=lite forge test         # lowest fuzz counts, fastest iteration
FOUNDRY_PROFILE=ci forge test           # high fuzz and invariant counts
FOUNDRY_PROFILE=optimized forge build   # production settings; the only deployable build
forge test --gas-report                 # gas profiling
forge fmt --check                       # formatting, as CI runs it
```

## Documentation

| File | Role |
|---|---|
| `docs/PRD.md` | Canonical protocol specification. Source of truth, and the document to review against. |
| `docs/SKILLS.md` | Uniswap AI plugin ecosystem for coding agents. |

The PRD marks requirements `[REQUIRED]`, implementation freedom `[SUGGESTED]`, and genuine open decisions `[OPEN]`. An `[OPEN]` item is never a protocol requirement, and a "recommendation" printed next to one is not a decision.
