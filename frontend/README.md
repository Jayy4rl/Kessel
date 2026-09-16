# Kessel frontend

Claim PoX-5 bond rewards and deploy them, in two wallet transactions. Mainnet
only: every contract, rate and availability flag is read live.

```bash
npm install
npm run dev     # http://localhost:5173
npm test        # unit tests for src/lib
npm run build   # type-check and production build
npm run lint
```

## The page

[`src/App.tsx`](src/App.tsx) is the whole UI, in the order the PRD's
onboarding runs:

1. **Bonds, before connecting** — every bond with its target APY, fill, locked
   BTC and STX, participants, and how long until it opens or unlocks. Effective
   APY appears only once a distribution has actually paid out.
2. **Connect** a wallet (Leather, Xverse) through `@stacks/connect`.
3. **Eligibility preflight** — when a bond is open for registration: allowlist,
   STX pairing, no blocking position, capacity, and the registration window.
   All reads, no gas, as PRD §5.7 requires.
4. **Your bond** — positions from Hiro's staking API, and the cycles with
   rewards to claim. Hiro reports one lifetime claimable total but a claim
   names a single cycle, so the recent cycles are read from `pox-5` directly.
5. **Claim** through the staker's own signer-manager, with a post-condition
   requiring it to pay at least the expected amount.
6. **Deploy** the claimed sBTC into a venue, ranked by what it currently pays,
   with closed venues shown as closed and pool yields flagged as trading fees
   rather than BTC yield.
7. **Activity** — each claim and deposit, with its transaction link.

Both transactions are polled to confirmation (PRD §4.3), so the banner moves
from pending to confirmed or failed, and balances and positions reload once a
claim confirms.

## Modules

| File | Role |
|---|---|
| [`lib/wallet.ts`](src/lib/wallet.ts) | Connect, disconnect, and hand a built call to the wallet |
| [`lib/bonds.ts`](src/lib/bonds.ts) | The public bond list, with fill, phase, estimated dates and effective APY |
| [`lib/eligibility.ts`](src/lib/eligibility.ts) | The §5.7 preflight checklist, read from `pox-5` |
| [`lib/tx-status.ts`](src/lib/tx-status.ts) | Transaction polling; a 404 means not yet indexed, not failed |
| [`lib/history.ts`](src/lib/history.ts) | Per-address claim and deposit log in local storage, mappable to the PRD §6.7 record |
| [`lib/staking-api.ts`](src/lib/staking-api.ts) | Bond positions, the staker's signer-manager, and per-cycle rewards |
| [`lib/staking.ts`](src/lib/staking.ts) | The claim transaction |
| [`lib/bitflow.ts`](src/lib/bitflow.ts) | Pool ranking from the Bitflow API, bin selection, and the sBTC-only HODLMM deposit |
| [`lib/zest.ts`](src/lib/zest.ts), [`lib/stackingdao.ts`](src/lib/stackingdao.ts), [`lib/hermetica.ts`](src/lib/hermetica.ts) | Each venue's state read and deposit transaction |
| [`lib/destinations.ts`](src/lib/destinations.ts) | Assembles the venue list and builds the chosen deposit |
| [`lib/tx.ts`](src/lib/tx.ts), [`lib/config.ts`](src/lib/config.ts) | Shared call type, post-condition helper, read-only calls, mainnet addresses |

Every deposit is sent in deny mode with a post-condition capping what leaves
the wallet at exactly the deposit amount, so a protocol change cannot take
more than intended.

## Notes

- Yields move quickly. One pool's TVL fell from 4.75 to 0.99 BTC within hours
  on 2026-09-15, so venues are ranked when the page loads rather than cached.
- Deposits are separate transactions because Zest v2 and Hermetica hBTC debit
  `contract-caller`, so only the depositor's own wallet can call them.
- Claims paid to an L1 Bitcoin address arrive as BTC, not sBTC, and there is
  nothing to deploy afterwards.
