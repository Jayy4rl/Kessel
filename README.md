# Kessel

**Two execution lanes on one Uniswap v4 liquidity curve.**

Traders choose between paying for immediacy and waiting for a better price. The
fast lane's fee rises with the priority fee a trader is already paying to jump
the queue, and that premium goes to LPs instead of the block builder; the slow
lane escrows the trade, batches it, and clears every order in the batch at a
single price — so position within the batch is worth nothing to a sandwicher.


## Partner integrations

Kessel has no partner integrations

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
effect of its own trade, the order clears, and the trader redeems in full.

**261 tests pass on both compiler pipelines**, including all twelve protocol
invariants as stateful assertions (256 runs × 16,384 calls, zero reverts).
Coverage 99.72% lines, 100% functions. Slither: no high or medium findings. The
settlement formula is checked against exact-rational arithmetic over 512 cases
by [`contracts/script/clearing_reference.py`](contracts/script/clearing_reference.py),
because every other test verifies the price against itself.

Testnet only
