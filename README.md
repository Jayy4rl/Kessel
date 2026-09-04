# Kessel

**Two execution lanes on one Uniswap v4 liquidity curve.**

Traders choose between paying for immediacy and waiting for a better price. The
fast lane's fee rises with the priority fee a trader is already paying to jump
the queue, and that premium goes to LPs instead of the block builder; the slow
lane escrows the trade, batches it, and clears every order in the batch at a
single price — so position within the batch is worth nothing to a sandwicher.

🎬 **Demo video:** pending  ·  🌐 **Live app:** pending (runs locally, see [Run it](#run-it))

## Hookathon submission

- **Submission type:** Uniswap Hook Incubator (UHI)
- **Public repo:** https://github.com/Jayy4rl/Kessel
- **Live app:** pending
- **Demo video:** pending

## Partner integrations

Kessel integrates the following partner technologies in working code:

| Partner / tech | Where |
|---|---|
| Uniswap v4 Hooks | [`contracts/src/KesselHook.sol`](contracts/src/KesselHook.sol) — `beforeSwap` routes lanes and prices urgency, `afterSwap` carries settlement, `beforeSwapReturnDelta` escrows slow-lane input as an ERC-6909 claim. Lifecycle tests in [`contracts/test/integration/`](contracts/test/integration/) |
| Base (OP-Stack priority ordering) | The fast-lane tax only works where the sequencer orders by priority fee. Measured against real Base blocks in [`contracts/test/fork/A3PriorityOrdering.t.sol`](contracts/test/fork/A3PriorityOrdering.t.sol) — 96.07% of adjacent transaction pairs correctly ordered, 323,885 pairs across 12 blocks |
| OpenZeppelin `uniswap-hooks` | `CurrencySettler` for the async custody path in [`contracts/src/KesselHook.sol`](contracts/src/KesselHook.sol) |

The mock ERC-20s and test routers in this repo are standard v4 test contracts
used for transparent testnet accounting; they are not submitted as external
partner integrations.

## Deployed contracts

**Base Sepolia** (chain 84532):

| Contract | Address |
|---|---|
| KesselHook | [`0xD9b438e017D37bE8C3205f3814241b8D9F9d80c8`](https://sepolia.basescan.org/address/0xD9b438e017D37bE8C3205f3814241b8D9F9d80c8) |
| BatchSolver (linked library) | [`0x25048aB11E111a43D5cfebEE567b3F1BA48BCF81`](https://sepolia.basescan.org/address/0x25048aB11E111a43D5cfebEE567b3F1BA48BCF81) |
| Token A — `currency0` (faucet) | [`0xb94817ebA9282307Fb7b1351051f9a5A7Fc483Cf`](https://sepolia.basescan.org/address/0xb94817ebA9282307Fb7b1351051f9a5A7Fc483Cf) |
| Token B — `currency1` (faucet) | [`0xeB8Aa36077cac1C6B5Bed16A2A1e52778e54eD4F`](https://sepolia.basescan.org/address/0xeB8Aa36077cac1C6B5Bed16A2A1e52778e54eD4F) |
| Swap router | [`0xff870819bC7Cd14dEFbd32CdD076AcEfF6521D9e`](https://sepolia.basescan.org/address/0xff870819bC7Cd14dEFbd32CdD076AcEfF6521D9e) |
| Liquidity router | [`0x7CD076795953e44456dD3E8569e43C34f96Bdb09`](https://sepolia.basescan.org/address/0x7CD076795953e44456dD3E8569e43C34f96Bdb09) |
| Uniswap v4 PoolManager | [`0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

Pool ID `0x9be8cc8e62ffa0921506a9e4ac87fa0b7f84aede541b824d9da2abd6e3496168`,
CREATE2 salt `1871`. The hook address ends in `0x80C8` because v4 encodes a
hook's permissions in its low address bits — `0xC8` *is*
`beforeSwap | afterSwap | beforeSwapReturnDelta`, so the address is
self-certifying.

## How it works

1. **Choose a lane** — one byte of `hookData`. Send nothing and you get FAST, so
   routers that have never heard of this hook still trade normally.
2. **Fast prices urgency** — the hook reads `tx.gasprice - block.basefee` and
   charges `f_base + k × priorityFee`, capped. At 20 gwei that is 1.30% against a
   0.30% floor, and everything above the floor is recaptured to LPs.
3. **Slow escrows instead of swapping** — `beforeSwap` returns a delta consuming
   the full input, the hook mints itself an ERC-6909 claim, and records the order.
   No swap math runs.
4. **A later fast swap settles the batch** — no keeper, no solver. Opposing
   orders net against each other first; only the imbalance touches the curve, and
   every order clears at one price. If the pool goes quiet, anyone can force
   settlement.

## Repo

| Path | What |
|---|---|
| [`contracts/`](contracts/) | Foundry contracts, tests, deploy and demo scripts |
| [`frontend/`](frontend/) | Vite + React app (wagmi, live data) |
| [`contracts/docs/PRD.md`](contracts/docs/PRD.md) | Canonical protocol specification |

## Run it

```bash
# Contracts
cd contracts && git submodule update --init --recursive && forge test

# Frontend
cd frontend && npm install && npm run dev
```

Expect `261 passed, 0 failed, 2 skipped` — the two skips are the live-RPC halves
of the A3 fork test and need `BASE_RPC_URL` set to a Base archive endpoint.

Deployment is two phases, and the order is not optional: the hook's creation
bytecode embeds `BatchSolver`'s address, and the hook address is CREATE2-mined
over that bytecode. Both phases need `FOUNDRY_PROFILE=optimized` — the dev
profile compiles the hook over the EIP-170 size limit and deployment simply
fails.

## Status

Live on testnet. Verified end-to-end on a real chain: a slow-lane order escrows
into the hook on Base Sepolia, a later fast-lane swap carries the batch as a side
effect of its own trade, the order clears, and the trader redeems in full. The
lane spread shows up in the fills — the same 0.01 input returned
`9,969,801,202,164,028` through the fast lane and `9,994,361,770,855,610` through
the slow one, a 0.246% advantage against a 0.25% fee spread.

**261 tests pass on both compiler pipelines**, including all twelve protocol
invariants as stateful assertions (256 runs × 16,384 calls, zero reverts).
Coverage 99.72% lines, 100% functions. Slither: no high or medium findings. The
settlement formula is checked against exact-rational arithmetic over 512 cases
by [`contracts/script/clearing_reference.py`](contracts/script/clearing_reference.py),
because every other test verifies the price against itself.

Testnet only — not audited, not reviewed by a human, not for production funds.
Two findings from an earlier review are deliberately open and recorded in the
repo: settlement timing is attacker-selectable across batches (uniform pricing
protects orders *within* a batch), and a gas-limited fast swap can suppress
piggyback settlement, for which `forceSettle` is the escape.
