# Kessel

Clarity smart contracts on Stacks, with a React frontend.

## Layout

| Folder | What's in it |
|---|---|
| [`contracts/`](contracts/) | Clarinet project — Clarity contracts in `contracts/`, Vitest + `@stacks/clarinet-sdk` tests in `tests/`, network settings in `settings/` |
| [`frontend/`](frontend/) | Vite + React + TypeScript. [`src/lib/`](frontend/src/lib/) holds the claim-then-deposit flow: sBTC pool ranking from the Bitflow API, and wallet-ready transactions for the PoX-5 staker claim and each deposit venue (Bitflow HODLMM, Zest v2, StackingDAO stBTC, Hermetica hBTC) |

## Prerequisites

- [Clarinet](https://docs.stacks.co/clarinet) 3.x
- Node.js 20+
- Docker — only for `clarinet devnet start`

## Run it

```bash
# Contracts
cd contracts
npm install
clarinet check        # type-check every contract
npm test              # unit tests against the simnet

# New contract (adds the .clar file, a test file, and the Clarinet.toml entry)
clarinet contract new <name>

# Frontend
cd frontend
npm install
npm run dev           # http://localhost:5173
npm test              # unit tests for src/lib
```

## Deploying rewards

Rewards are claimed and deployed in two wallet transactions: the staker claims
from their signer-manager, then deposits into the venue they pick. Most venues
(Zest v2, Hermetica hBTC) only accept deposits sent by the depositor's own
wallet, so a single atomic transaction can't reach them. The Reward Router in
`contracts/` is the optional one-transaction path for venues that accept
contract callers.

## WSL

Ubuntu 24.04 under WSL 2 has its own Node (via nvm) and Clarinet (`~/.local/bin`),
so every command above works from a WSL shell as well as from PowerShell. The
workspace's default VS Code terminal is `Ubuntu-24.04 (WSL)`.

`node_modules` holds platform-specific binaries. If you switch between Windows
and WSL, delete `node_modules` and run `npm install` again on the side you're
about to use.
