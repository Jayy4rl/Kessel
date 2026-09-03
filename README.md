# Kessel

A Uniswap v4 hook implementing **two execution lanes on one shared liquidity curve**. Liquidity is never fragmented; the trader picks a lane per swap.

- **Fast Lane** — synchronous, in-block. Dynamic fee `f_base + tax(priorityFeePerGas)`. The premium above `f_base` is recaptured to LPs rather than left to sequencers or searchers.
- **Slow Lane** — deferred. The hook escrows the input and issues a non-transferable, non-cancellable claim. All orders in a batch clear at a **single uniform price computed at settlement time**, which is what makes the lane sandwich-proof and removes the hedgeable basis.

Letting traders self-select by urgency is a screening mechanism: it prices **immediacy** — a real cost the LP bears for filling *now* against committed inventory — and routes that premium to LPs. It does **not** price or identify toxicity, does not remove adverse selection from the Slow Lane, and does not reduce total LVR. See `docs/PRD.md` §1–§2.

## Status

**Implemented and tested; not reviewed by a human.**

`src/` holds `KesselHook.sol` plus four libraries. **261 tests pass** on both compiler pipelines, including all twelve protocol invariants as real stateful assertions (256 runs × 16,384 calls, zero reverts). Two of them need a Base RPC endpoint and skip without one — see [Testing](#testing).

`docs/PRD.md` is the canonical specification and the document to review against.

## Quick start

```bash
git submodule update --init --recursive
forge build
forge test
```

Expect `261 passed, 0 failed, 2 skipped`. The two skips are the live-RPC halves of the A3 fork test and are explained below; set `BASE_RPC_URL` to run them and the count becomes 263 passed, 0 skipped. Nothing else requires configuration.

Dependencies nest — `v4-core` and `permit2` are submodules of `v4-periphery` — so `--recursive` is required, not optional.

## Deployed — Base Sepolia (84532)

Live as of 2026-09-03. This is a testnet deployment with mock tokens; nothing
here is a production pool.

| Contract | Address |
|---|---|
| `KesselHook` | [`0x813E0c51907e09E0e447475947a819D0c66d00C8`](https://sepolia.basescan.org/address/0x813E0c51907e09E0e447475947a819D0c66d00C8) |
| `BatchSolver` (linked library) | [`0x25048aB11E111a43D5cfebEE567b3F1BA48BCF81`](https://sepolia.basescan.org/address/0x25048aB11E111a43D5cfebEE567b3F1BA48BCF81) |
| Test token A (`currency0`) | [`0x56b7936a7f0C71FC95b302271123F2cC5AF70596`](https://sepolia.basescan.org/address/0x56b7936a7f0C71FC95b302271123F2cC5AF70596) |
| Test token B (`currency1`) | [`0x750feAb85382bA28B45cd54443146E53D40a529A`](https://sepolia.basescan.org/address/0x750feAb85382bA28B45cd54443146E53D40a529A) |
| v4 `PoolManager` | [`0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

- **Pool ID** `0x5c38804e9f39fa6324ba32dce4d68315d5fd204333294e92c19ee29a0af16f28`
- **CREATE2 salt** `18109`, mined through the canonical factory `0x4e59b448…B4956C`
- **Runtime size** 22,515 bytes, 2,061 under the EIP-170 limit
- **Governance** `0xE8E0Ae7555f1a9a0479b97a86ACca2Dc81bf9922`

The address ends in `0x00C8` — the low 14 bits are v4's permission bitmap, so
`0xC8` *is* `beforeSwap | afterSwap | beforeSwapReturnDelta`. Anything else at
this address would be a different hook. Verify it yourself:

```bash
cast call 0x813E0c51907e09E0e447475947a819D0c66d00C8 'fBase()(uint24)'   --rpc-url https://sepolia.base.org        # 3000
```

### Redeploying

`script/Deploy.s.sol` runs in phases, and the order is not optional: the hook's
creation bytecode embeds `BatchSolver`'s address, and the hook address is mined
over that bytecode. Deploy the library first, pin it in **both** `foundry.toml`
(`libraries` under `[profile.optimized]`) and `BATCH_SOLVER`, recompile, then
mine and deploy. Both phases need `FOUNDRY_PROFILE=optimized` — the dev profile
compiles the hook over the size limit and the deployment simply fails.

`script/Demo.s.sol` then seeds liquidity and runs the loop end to end: a
Fast-Lane swap, a Slow-Lane order, a piggyback settlement carried by a later
Fast swap, and a redeem.

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
| `test/property/` | Fuzz tests over the pure libraries, including against v4's own `SqrtPriceMath`, plus the differential test described below. |
| `test/integration/` | Fast Lane, Slow Lane, settlement, lifecycle, governance, multi-range clearing, native and gas-token pools. |
| `test/security/` | Adversarial tests. Each was written before its fix and observed to fail first, so each is a regression lock: if one starts failing, a closed attack has reopened. |
| `test/scaffold/` | Pins upstream v4 behaviours the design depends on. A failure here after a dependency bump means an assumption changed, not that a test is flaky. |
| `test/economic/` | Measurements rather than assertions: settlement-gas incidence, `k` calibration, clearing-price manipulation. |
| `test/fork/` | Assumption A3 — that the target chain orders by priority fee. |

### The settlement price is checked against an independent model

Every other test checks the clearing price against *itself*: the invariants
confirm a batch is solvent and uniformly priced whatever price the solver
picked — which stays true even if the solver picks the wrong one. Since the
settlement formula is the one part of the protocol that can never be patched,
it is also checked against arithmetic that shares no code with it.

`script/clearing_reference.py` does two things Solidity cannot:

1. It proves the closed form satisfies `L*(a-b) = N0*a*b - N1` — the solvency
   equation the derivation claims to solve — **exactly**, in rationals. That is
   not a re-implementation of the same formula, which would be circular; it is
   a check against the condition the formula is derived from.
2. It evaluates that form with `fractions.Fraction`, so the emitted fixture
   carries no rounding at all.

`test/property/ClearingDifferential.t.sol` replays the fixture through the real
contract, whose integer arithmetic floors at every step, and asserts they agree.
A contract computing a different formula diverges by orders of magnitude.

```bash
python script/clearing_reference.py        # regenerate; the seed is fixed
forge test --match-path 'test/property/ClearingDifferential.t.sol'
```

Measured divergence is ~1e-25 relative, against the 1e-6 tolerance the
post-settlement limit re-check runs with. Note the rounding has no guaranteed
*direction*: flooring shrinks the closed form's numerator and denominator in
opposite senses, so the error can fall either way. The test asserts a bound, not
a sign.

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
