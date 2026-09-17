# Kessel

Clarity smart contracts on Stacks, with a React frontend.

## Layout

| Folder | What's in it |
|---|---|
| [`contracts/`](contracts/) | Clarinet project — Clarity contracts in `contracts/`, Vitest + `@stacks/clarinet-sdk` tests in `tests/`, network settings in `settings/` |
| [`frontend/`](frontend/) | Vite + React + TypeScript, with `@stacks/connect`, `@stacks/transactions` and `@stacks/network` |

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
```

## WSL

Ubuntu 24.04 under WSL 2 has its own Node (via nvm) and Clarinet (`~/.local/bin`),
so every command above works from a WSL shell as well as from PowerShell. The
workspace's default VS Code terminal is `Ubuntu-24.04 (WSL)`.

`node_modules` holds platform-specific binaries. If you switch between Windows
and WSL, delete `node_modules` and run `npm install` again on the side you're
about to use.
