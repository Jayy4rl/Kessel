# Kessel contracts

The Reward Router from PRD §8: claim PoX-5 bond rewards and deploy them into a
DeFi position in one atomic transaction. Everything else in the product calls
PoX-5 and protocol contracts directly through their SDKs.

The product's primary flow is claim-then-deposit: two wallet transactions
built in [`frontend/src/lib`](../frontend/src/lib). Zest v2 and Hermetica hBTC
debit `contract-caller`, so only the depositor's wallet can call them. The
router is the optional one-transaction path for venues that accept contract
callers.

| Contract | Role |
|---|---|
| [`kessel-traits`](contracts/kessel-traits.clar) | `reward-source-trait` (signer-manager claim) and `deploy-target-trait` (DeFi destination) |
| [`reward-router`](contracts/reward-router.clar) | `claim-and-deploy`, target/source registry, pause, two-step ownership |
| [`stbtc-target`](contracts/stbtc-target.clar) | StackingDAO: sBTC → stBTC via `stacking-dao-core-stbtc-v1.deposit` |

## How `claim-and-deploy` works

PoX-5 pays bond rewards to the staker's signer-manager, and the manager's
permissionless `claim-staker-rewards` pays the staker. The router chains that
claim into a deposit:

1. Checks: caller is calling directly, router not paused, target registered
   and enabled and matching the passed contract, source allowlisted.
2. **Claim** — calls `source.claim-staker-rewards(tx-sender, cycle, bond)`
   inside `restrict-assets? tx-sender ()`: the source may not move *any* of the
   caller's assets. The claimed amount is the caller's sBTC balance delta, not
   the source's reported value.
3. Asserts `claimed > 0` and `claimed >= min-amount`.
4. **Deploy** — calls `target.deploy(claimed, min-out)` inside
   `restrict-assets? tx-sender` with allowances of exactly `claimed` sBTC and
   `max-stx` uSTX, then asserts all of `claimed` left the wallet.

The router never switches to its own identity, so it never holds funds:
rewards land in the caller's wallet and the position tokens are minted to the
caller. Any failed step reverts the whole transaction.

The frontend should still send the transaction in deny mode, with
post-conditions capping the caller's outflows at the expected claim in sBTC
and `max-stx` in uSTX.

## Integrations

| Protocol | Status |
|---|---|
| Signer-managers on the stacks-core reference template | Plug in directly as a source — same `claim-staker-rewards` signature |
| `native-pool-signer-manager` | [`native-pool-source`](contracts/native-pool-source.clar) — its claim takes no staker argument and pays `tx-sender` |
| Other signer-managers | Need a thin adapter implementing `reward-source-trait`, one per manager (copy `native-pool-source` and change the manager) |
| Stakers with an L1 BTC payout address | Not routable: the manager pays BTC on L1, so the router sees 0 sBTC and reverts |
| Stakers holding their bond through a contract (e.g. Xverse `sbtc-bond-staker-v1-1`) | Not routable: `claim-and-deploy` only runs when the staker calls it directly |
| StackingDAO stBTC | `stbtc-target` — **unusable while StackingDAO has deposits shut down** (`shutdown-deposits = true` on mainnet; `deposit` returns `u25001`). Register it disabled until they reopen |
| Bitflow HODLMM | No router target. The core pulls from `tx-sender`, so one is possible, but it needs bin placement and fee-cap parameters `deploy-target-trait` doesn't carry. The frontend deposits there directly |
| Bitflow XYK (legacy pool) | Not deployable: [`tests/fixtures/bitflow-xyk-target.clar`](tests/fixtures/bitflow-xyk-target.clar) exists only so the fork tests can drive the router end-to-end against a real protocol |
| Zest v2 sBTC supply | Wallet only: `v0-vault-sbtc.deposit` debits `contract-caller`. (The v1 `borrow-helper` also rejects contract callers.) |
| Hermetica hBTC | Wallet only: `vault-hbtc-v1-2.deposit` debits and credits `contract-caller` |

## Develop

```bash
npm install
clarinet check
npm test
```

Protocol contracts are pulled from mainnet as `[[project.requirements]]`, so
the adapters type-check against the real deployed code. The router's tests use
fixtures in `tests/fixtures/` — well-behaved and adversarial sources and
targets — deployed per test, so they never enter a deployment plan.

### Mainnet-fork tests

```bash
HIRO_API_KEY=... npm run test:fork
```

`tests-fork/` runs the adapters and the router against real mainnet state
through Clarinet's remote data (MXS). Each file starts one empty simnet session
forked at `FORK_HEIGHT`, deploys this project's contracts from source, and
funds test wallets by sending from real mainnet holders (simnet does not check
signatures). Tests share that session and assert on balance deltas. These
tests are kept out of `npm test` so unit tests stay offline.

Expect a cold run (empty `.cache/datastore`) to take 2–5 minutes and a warm
run about 30 seconds. MXS is beta and network-bound: Clarinet caches contract
metadata on disk but still fetches storage values from the Hiro API on every
run, and it only retries rate-limit responses. A failed fetch has shown up
both as a `fetch failed` panic that leaves vitest hanging and as a runtime
`TypeError` inside a mainnet contract. Either way, re-run; the failing test
moves between runs. Setting `HIRO_API_KEY` reduces rate limiting.

Bump `FORK_HEIGHT` deliberately: the assertions describe mainnet at that
height (for example, stBTC deposits being shut down).

## Before mainnet

- Audit (PRD §8).
- The adapters and the sBTC principal are mainnet addresses; testnet needs its
  own adapter deployments.
- Register targets and sources from the owner account, and consider moving
  ownership to a multisig with `transfer-ownership` / `accept-ownership`.
