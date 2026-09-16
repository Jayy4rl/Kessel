import { Cl } from "@stacks/transactions";
import { useEffect, useRef, useState } from "react";
import {
  bondTiming,
  effectiveApyPct,
  fetchBonds,
  fetchBurnHeight,
  type BondSummary,
} from "./lib/bonds";
import { SBTC_TOKEN } from "./lib/config";
import { buildDeposit, loadDestinations, type Destination } from "./lib/destinations";
import { fetchEligibility, type EligibilityCheck } from "./lib/eligibility";
import {
  latestClaim,
  loadActivity,
  recordActivity,
  type ActivityRecord,
} from "./lib/history";
import { buildClaimStakerRewards } from "./lib/staking";
import {
  fetchBondPositions,
  fetchClaimableCycles,
  fetchCurrentCycle,
  fetchNetEarned,
  fetchSignerManager,
  type BondPosition,
  type CycleReward,
} from "./lib/staking-api";
import { readOnly, toBigInt, unwrapOk, type ContractId } from "./lib/tx";
import { waitForTx, type TxStatus } from "./lib/tx-status";
import {
  connectWallet,
  connectedAddress,
  disconnectWallet,
  explorerTx,
  sendContractCall,
} from "./lib/wallet";

const sats = (value: bigint) => `${(Number(value) / 1e8).toFixed(8)} sBTC`;
const btc = (value: bigint) => `${(Number(value) / 1e8).toFixed(4)} BTC`;
const stx = (value: bigint) => `${Math.round(Number(value) / 1e6).toLocaleString()} STX`;
const day = (date: Date) => date.toLocaleDateString(undefined, { dateStyle: "medium" });

interface Position extends BondPosition {
  signerManager: ContractId;
  cycles: CycleReward[];
}

interface AsyncState<T> {
  value: T | null;
  error: string | null;
  loading: boolean;
}

/** Runs `load` whenever `key` changes, ignoring results that arrive late. */
function useAsync<T>(load: () => Promise<T>, key: string): AsyncState<T> {
  const [loaded, setLoaded] = useState<{ key: string; value: T | null; error: string | null }>({
    key: "",
    value: null,
    error: null,
  });
  const loadRef = useRef(load);

  useEffect(() => {
    loadRef.current = load;
  });

  useEffect(() => {
    let cancelled = false;
    loadRef
      .current()
      .then((value) => {
        if (!cancelled) setLoaded({ key, value, error: null });
      })
      .catch((e: unknown) => {
        if (!cancelled) setLoaded({ key, value: null, error: String(e) });
      });
    return () => {
      cancelled = true;
    };
  }, [key]);

  const current = loaded.key === key;
  return {
    value: current ? loaded.value : null,
    error: current ? loaded.error : null,
    loading: !current,
  };
}

/** Polls a sent transaction until it succeeds or fails. */
function useTxWatch(txid: string | null): TxStatus | null {
  const [watched, setWatched] = useState<{ txid: string; status: TxStatus } | null>(null);

  useEffect(() => {
    if (!txid) return;
    let cancelled = false;
    void waitForTx(txid, {
      onUpdate: (status) => {
        if (!cancelled) setWatched({ txid, status });
      },
    });
    return () => {
      cancelled = true;
    };
  }, [txid]);

  return watched?.txid === txid ? watched.status : null;
}

function TxBanner({ label, txid, status }: { label: string; txid: string; status: TxStatus | null }) {
  const state = status?.state ?? "pending";
  const text =
    state === "success"
      ? `${label} confirmed`
      : state === "failed"
        ? `${label} failed (${status?.raw})`
        : `${label} pending…`;
  return (
    <p className={state === "success" ? "ok" : state === "failed" ? "error" : "muted"}>
      {text} ·{" "}
      <a href={explorerTx(txid)} target="_blank" rel="noreferrer">
        view transaction
      </a>
    </p>
  );
}

export default function App() {
  const [address, setAddress] = useState<string | null>(connectedAddress());
  const [claimTx, setClaimTx] = useState<string | null>(null);
  const [depositTx, setDepositTx] = useState<string | null>(null);
  const [actionError, setActionError] = useState<string | null>(null);
  const [amount, setAmount] = useState("");
  const [stored, setStored] = useState<{ address: string | null; records: ActivityRecord[] }>({
    address: null,
    records: [],
  });
  // Read straight from local storage until this session writes to it.
  const activity = stored.address === address ? stored.records : address ? loadActivity(address) : [];

  const claimStatus = useTxWatch(claimTx);
  const depositStatus = useTxWatch(depositTx);
  const claimConfirmed = claimStatus?.state === "success" ? claimTx : "";
  const depositConfirmed = depositStatus?.state === "success" ? depositTx : "";

  const market = useAsync(async () => {
    const [bonds, burnHeight] = await Promise.all([fetchBonds(), fetchBurnHeight()]);
    return { bonds, burnHeight };
  }, "market");

  const positions = useAsync<Position[]>(async () => {
    if (!address) return [];
    const [bonds, currentCycle] = await Promise.all([
      fetchBondPositions(address),
      fetchCurrentCycle(),
    ]);
    return Promise.all(
      bonds.map(async (bond) => {
        const signerManager = await fetchSignerManager(bond.bondIndex, address);
        return {
          ...bond,
          signerManager,
          cycles: await fetchClaimableCycles({
            signerManager,
            staker: address,
            bondIndex: bond.bondIndex,
            currentCycle,
          }),
        };
      }),
    );
  }, `positions:${address}:${claimConfirmed}`);

  const balance = useAsync<bigint>(async () => {
    if (!address) return 0n;
    return toBigInt(unwrapOk(await readOnly(SBTC_TOKEN, "get-balance", [Cl.principal(address)])));
  }, `balance:${address}:${claimConfirmed}:${depositConfirmed}`);

  const destinations = useAsync<Destination[]>(() => loadDestinations(), "destinations");

  const upcoming = market.value?.bonds.find(
    (bond) => bondTiming(bond, market.value!.burnHeight).phase === "upcoming",
  );

  const eligibility = useAsync<{ checks: EligibilityCheck[]; eligible: boolean } | null>(async () => {
    if (!address || !upcoming) return null;
    return fetchEligibility({ bond: upcoming, address, intendedSats: 100_000_000n });
  }, `eligibility:${address}:${upcoming?.index ?? ""}`);

  async function claim(position: Position, cycle: CycleReward) {
    setActionError(null);
    try {
      const net = await fetchNetEarned({
        signerManager: position.signerManager,
        staker: address!,
        bondIndex: position.bondIndex,
        cycle: cycle.cycle,
      });
      const txid = await sendContractCall(
        buildClaimStakerRewards({
          signerManager: position.signerManager,
          staker: address!,
          rewardCycle: cycle.cycle,
          bondIndex: position.bondIndex,
          minAmount: net ?? 0n,
        }),
      );
      setClaimTx(txid);
      setStored({
        address,
        records: recordActivity(address!, {
          kind: "claim",
          txId: txid,
          timestamp: new Date().toISOString(),
          amountSats: (net ?? cycle.earned).toString(),
          bondIndex: position.bondIndex,
          rewardCycle: cycle.cycle,
        }),
      });
    } catch (e) {
      setActionError(String(e));
    }
  }

  async function deposit(destination: Destination) {
    setActionError(null);
    try {
      const sent = BigInt(Math.round(Number(amount) * 1e8));
      if (sent <= 0n) throw new Error("enter an amount to deposit");
      const txid = await sendContractCall(
        await buildDeposit(destination, { amount: sent, sender: address! }),
      );
      setDepositTx(txid);
      setStored({
        address,
        records: recordActivity(address!, {
          kind: "deploy",
          txId: txid,
          timestamp: new Date().toISOString(),
          amountSats: sent.toString(),
          destination: destination.id,
          claimTxId: latestClaim(activity)?.txId,
        }),
      });
    } catch (e) {
      setActionError(String(e));
    }
  }

  return (
    <main>
      <header>
        <h1>Kessel</h1>
        {address ? (
          <div className="wallet">
            <code>{address}</code>
            <button
              type="button"
              onClick={() => {
                disconnectWallet();
                setAddress(null);
              }}
            >
              Disconnect
            </button>
          </div>
        ) : (
          <button type="button" className="primary" onClick={() => connectWallet().then(setAddress)}>
            Connect wallet
          </button>
        )}
      </header>

      <section className="card">
        <h2>Bitcoin Staking bonds</h2>
        {market.loading && <p>Loading bonds…</p>}
        {market.error && <p className="error">{market.error}</p>}
        {market.value?.bonds.map((bond: BondSummary) => {
          const timing = bondTiming(bond, market.value!.burnHeight);
          const effective = effectiveApyPct(bond, market.value!.burnHeight);
          return (
            <article key={bond.index} className="position">
              <div className="row">
                <h3>
                  Bond {bond.index} <span className="tag">{bond.status}</span>
                </h3>
                <span className="muted">
                  {timing.phase === "upcoming" ? "Opens" : timing.phase === "active" ? "Unlocks" : "Unlocked"}{" "}
                  {timing.blocksRemaining > 0
                    ? `in ${Math.round(timing.daysRemaining)} days (${day(timing.date)})`
                    : "already"}
                </span>
              </div>
              <dl>
                <div>
                  <dt>Target APY</dt>
                  <dd>{bond.targetApyPct.toFixed(2)}%</dd>
                </div>
                <div>
                  <dt>Paid out to date</dt>
                  <dd>
                    {btc(bond.paidOutSats)}
                    {effective === null ? "" : ` · ${effective.toFixed(2)}% effective`}
                  </dd>
                </div>
                <div>
                  <dt>Filled</dt>
                  <dd>
                    {bond.fillPct.toFixed(1)}% of {btc(bond.capacitySats)}
                  </dd>
                </div>
                <div>
                  <dt>Participants</dt>
                  <dd>
                    {bond.registered} of {bond.allowed}
                  </dd>
                </div>
                <div>
                  <dt>Locked</dt>
                  <dd>
                    {btc(bond.lockedSats)} · {stx(bond.lockedUstx)}
                  </dd>
                </div>
                <div>
                  <dt>Minimum STX pairing</dt>
                  <dd>{bond.minStxRatioPct}%</dd>
                </div>
              </dl>
            </article>
          );
        })}
        {!upcoming && !market.loading && (
          <p className="muted">
            No upcoming bond is open for registration. Enrollment happens at{" "}
            <a href="https://staking.stacks.co" target="_blank" rel="noreferrer">
              staking.stacks.co
            </a>
            .
          </p>
        )}
      </section>

      {!address && (
        <section className="card">
          <h2>Claim your rewards and put them to work</h2>
          <p>
            Connect a wallet to see your bond, claim the sBTC it has earned, and deposit it. Claiming
            and depositing are two transactions: most venues only accept deposits sent by your own
            wallet.
          </p>
        </section>
      )}

      {address && upcoming && (
        <section className="card">
          <h2>Can you join bond {upcoming.index}?</h2>
          <p className="muted">Checked against 1 BTC. Reads only — this costs nothing.</p>
          {eligibility.loading && <p>Checking…</p>}
          {eligibility.error && <p className="error">{eligibility.error}</p>}
          <ul className="checks">
            {eligibility.value?.checks.map((check) => (
              <li key={check.id}>
                <span className={check.ok ? "ok" : "error"}>{check.ok ? "✓" : "✗"}</span>
                <span>
                  <strong>{check.label}</strong>
                  <p className="muted">{check.detail}</p>
                </span>
              </li>
            ))}
          </ul>
        </section>
      )}

      {address && (
        <section className="card">
          <h2>Your bond</h2>
          {positions.loading && <p>Loading positions…</p>}
          {positions.error && <p className="error">{positions.error}</p>}
          {positions.value?.length === 0 && <p>No bond positions for this address.</p>}
          {positions.value?.map((position) => (
            <article key={position.bondIndex} className="position">
              <div className="row">
                <h3>
                  Bond {position.bondIndex} <span className="tag">{position.status}</span>
                </h3>
                <span className="muted">via {position.signerManager.split(".")[1]}</span>
              </div>
              <dl>
                <div>
                  <dt>BTC locked</dt>
                  <dd>{sats(position.lockedBtc)}</dd>
                </div>
                <div>
                  <dt>STX locked</dt>
                  <dd>{stx(position.lockedStx)}</dd>
                </div>
                <div>
                  <dt>Claimable</dt>
                  <dd>{sats(position.claimable)}</dd>
                </div>
                <div>
                  <dt>Claimed to date</dt>
                  <dd>{sats(position.claimed)}</dd>
                </div>
              </dl>
              {position.cycles.length === 0 ? (
                <p className="muted">Nothing to claim yet in the last six cycles.</p>
              ) : (
                <ul className="cycles">
                  {position.cycles.map((cycle) => (
                    <li key={cycle.cycle}>
                      <span>
                        Cycle {cycle.cycle} · {sats(cycle.earned)} before fees
                      </span>
                      <button type="button" className="primary" onClick={() => claim(position, cycle)}>
                        Claim
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </article>
          ))}
          {claimTx && <TxBanner label="Claim" txid={claimTx} status={claimStatus} />}
        </section>
      )}

      {address && (
        <section className="card">
          <h2>Deploy your sBTC</h2>
          <div className="row">
            <label htmlFor="amount">Amount</label>
            <input
              id="amount"
              inputMode="decimal"
              placeholder="0.00000000"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
            />
            <button
              type="button"
              onClick={() => setAmount(((Number(balance.value ?? 0n) / 1e8) || 0).toFixed(8))}
            >
              Max
            </button>
            <span className="muted">Wallet: {sats(balance.value ?? 0n)}</span>
          </div>

          {destinations.loading && <p>Loading venues…</p>}
          {destinations.error && <p className="error">{destinations.error}</p>}
          <ul className="destinations">
            {destinations.value?.map((destination) => (
              <li key={destination.id} className={destination.available ? "" : "closed"}>
                <div>
                  <strong>{destination.label}</strong>
                  <span className="apr">
                    {destination.aprPct === null ? "—" : `${destination.aprPct.toFixed(1)}% APR`}
                  </span>
                  <p className="muted">{destination.note}</p>
                </div>
                <button
                  type="button"
                  className="primary"
                  disabled={!destination.available}
                  onClick={() => deposit(destination)}
                >
                  Deposit
                </button>
              </li>
            ))}
          </ul>
          {depositTx && <TxBanner label="Deposit" txid={depositTx} status={depositStatus} />}
        </section>
      )}

      {address && activity.length > 0 && (
        <section className="card">
          <h2>Your activity</h2>
          <ul className="cycles">
            {activity.map((record) => (
              <li key={record.txId}>
                <span>
                  {record.kind === "claim"
                    ? `Claimed cycle ${record.rewardCycle} · ${sats(BigInt(record.amountSats))}`
                    : `Deposited ${sats(BigInt(record.amountSats))} into ${record.destination}`}
                  <p className="muted">{new Date(record.timestamp).toLocaleString()}</p>
                </span>
                <a href={explorerTx(record.txId)} target="_blank" rel="noreferrer">
                  view
                </a>
              </li>
            ))}
          </ul>
        </section>
      )}

      {actionError && <p className="error">{actionError}</p>}

      <footer className="muted">
        Mainnet. Yields are read live and move quickly; pool figures are trading fees, not BTC
        yield. Activity is kept in this browser only.
      </footer>
    </main>
  );
}
