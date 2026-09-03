import { useEffect, useMemo, useState } from "react";
import { formatUnits, parseUnits, type Address } from "viem";
import {
  useAccount,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";
import { readContract } from "wagmi/actions";
import Wallet from "../components/Wallet";
import { kesselAbi } from "../lib/abi";
import { ADDRESSES, CHAIN_ID, EXPLORER } from "../lib/config";
import { asPercent } from "../lib/fee";
import { FAST_DATA, POOL_KEY, STATUS, TEST_SETTINGS, priceLimit, slowData } from "../lib/pool";
import { erc20Abi, lpRouterAbi, swapRouterAbi } from "../lib/routers";
import { wagmiConfig } from "../lib/wagmi";
import { useKessel } from "../lib/useKessel";

const MAX_UINT = (1n << 256n) - 1n;
const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);
const fmt = (v: bigint | undefined, dp = 4) =>
  v === undefined ? "—" : Number(formatUnits(v, 18)).toFixed(dp);

/* ------------------------------------------------------------------ */
/* shared tx button                                                    */
/* ------------------------------------------------------------------ */

function useTx() {
  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const { isLoading: mining, isSuccess } = useWaitForTransactionReceipt({ hash });
  return { writeContract, hash, isPending, mining, isSuccess, error, reset };
}

function TxNote({ tx }: { tx: ReturnType<typeof useTx> }) {
  if (tx.error) {
    const m = tx.error.message.split("\n")[0];
    return <div className="tx-note err-note">{m.slice(0, 160)}</div>;
  }
  if (tx.mining) {
    return (
      <div className="tx-note">
        Mining…{" "}
        <a href={EXPLORER + "/tx/" + tx.hash} target="_blank" rel="noreferrer">
          view
        </a>
      </div>
    );
  }
  if (tx.isSuccess) {
    return (
      <div className="tx-note ok-note">
        Confirmed{" "}
        <a href={EXPLORER + "/tx/" + tx.hash} target="_blank" rel="noreferrer">
          view
        </a>
      </div>
    );
  }
  return null;
}

/* ------------------------------------------------------------------ */
/* balances + faucet                                                   */
/* ------------------------------------------------------------------ */

function useBal(token: Address, owner?: Address) {
  const { data, refetch } = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: owner ? [owner] : undefined,
    query: { enabled: Boolean(owner), refetchInterval: 8000 },
  });
  return { value: data as bigint | undefined, refetch };
}

function Faucet({ owner }: { owner: Address }) {
  const tx = useTx();
  const a = useBal(ADDRESSES.currency0 as Address, owner);
  const b = useBal(ADDRESSES.currency1 as Address, owner);

  useEffect(() => {
    if (tx.isSuccess) {
      a.refetch();
      b.refetch();
    }
  }, [tx.isSuccess]);

  const mint = (token: string) =>
    tx.writeContract({
      address: token as Address,
      abi: erc20Abi,
      functionName: "mint",
      args: [owner, parseUnits("1000", 18)],
    });

  return (
    <section className="card">
      <div className="card-head">
        <h3>Test tokens</h3>
        <span className="card-note">mock ERC-20s, mintable by anyone</span>
      </div>
      <div className="bal-row">
        <div className="bal">
          <span className="bal-name">Token A</span>
          <span className="bal-val mono">{fmt(a.value)}</span>
          <button className="ghost-btn sm" onClick={() => mint(ADDRESSES.currency0)}>
            Mint 1,000
          </button>
        </div>
        <div className="bal">
          <span className="bal-name">Token B</span>
          <span className="bal-val mono">{fmt(b.value)}</span>
          <button className="ghost-btn sm" onClick={() => mint(ADDRESSES.currency1)}>
            Mint 1,000
          </button>
        </div>
      </div>
      <TxNote tx={tx} />
    </section>
  );
}

/* ------------------------------------------------------------------ */
/* approvals                                                           */
/* ------------------------------------------------------------------ */

function useAllowance(token: Address, owner: Address, spender: Address) {
  const { data, refetch } = useReadContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, spender],
    query: { refetchInterval: 8000 },
  });
  return { value: (data as bigint | undefined) ?? 0n, refetch };
}

function Approvals({ owner, spender, label }: { owner: Address; spender: Address; label: string }) {
  const tx = useTx();
  const a = useAllowance(ADDRESSES.currency0 as Address, owner, spender);
  const b = useAllowance(ADDRESSES.currency1 as Address, owner, spender);

  useEffect(() => {
    if (tx.isSuccess) {
      a.refetch();
      b.refetch();
    }
  }, [tx.isSuccess]);

  const need = a.value === 0n || b.value === 0n;
  if (!need) return <div className="approve-ok">✓ {label} approved</div>;

  const approve = (token: string) =>
    tx.writeContract({
      address: token as Address,
      abi: erc20Abi,
      functionName: "approve",
      args: [spender, MAX_UINT],
    });

  return (
    <div className="approve-row">
      <span className="card-note">Approve {label}:</span>
      {a.value === 0n && (
        <button className="ghost-btn sm" onClick={() => approve(ADDRESSES.currency0)}>
          Token A
        </button>
      )}
      {b.value === 0n && (
        <button className="ghost-btn sm" onClick={() => approve(ADDRESSES.currency1)}>
          Token B
        </button>
      )}
      <TxNote tx={tx} />
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* liquidity                                                           */
/* ------------------------------------------------------------------ */

function Liquidity({ owner }: { owner: Address }) {
  const tx = useTx();
  const [amount, setAmount] = useState("10");

  const add = () =>
    tx.writeContract({
      address: ADDRESSES.lpRouter as Address,
      abi: lpRouterAbi,
      functionName: "modifyLiquidity",
      args: [
        POOL_KEY,
        {
          tickLower: -6000,
          tickUpper: 6000,
          liquidityDelta: parseUnits(amount || "0", 18),
          salt: "0x0000000000000000000000000000000000000000000000000000000000000000",
        },
        "0x",
      ],
    });

  return (
    <section className="card">
      <div className="card-head">
        <h3>Provide liquidity</h3>
        <span className="card-note">ticks −6000 → 6000</span>
      </div>
      <Approvals owner={owner} spender={ADDRESSES.lpRouter as Address} label="LP router" />
      <label className="field">
        <span>Liquidity units</span>
        <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
      </label>
      <button className="pill wide" onClick={add} disabled={tx.isPending || tx.mining}>
        {tx.isPending || tx.mining ? "Adding…" : "Add liquidity"}
      </button>
      <TxNote tx={tx} />
    </section>
  );
}

/* ------------------------------------------------------------------ */
/* swap                                                                */
/* ------------------------------------------------------------------ */

function Swap({
  owner,
  onDone,
  sqrtPriceX96,
  liquidity,
}: {
  owner: Address;
  onDone: () => void;
  sqrtPriceX96?: bigint;
  liquidity?: bigint;
}) {
  const tx = useTx();
  const [lane, setLane] = useState<"fast" | "slow">("fast");
  const [zeroForOne, setZeroForOne] = useState(true);
  const [amount, setAmount] = useState("0.01");
  const [minOut, setMinOut] = useState("0.0001");
  const [expiry, setExpiry] = useState("20");

  useEffect(() => {
    if (tx.isSuccess) onDone();
  }, [tx.isSuccess]);

  const submit = () => {
    const amt = parseUnits(amount || "0", 18);
    const hookData =
      lane === "fast" ? FAST_DATA : slowData(owner, parseUnits(minOut || "0", 18), Number(expiry));

    tx.writeContract({
      address: ADDRESSES.swapRouter as Address,
      abi: swapRouterAbi,
      functionName: "swap",
      args: [
        POOL_KEY,
        { zeroForOne, amountSpecified: -amt, sqrtPriceLimitX96: priceLimit(zeroForOne, sqrtPriceX96) },
        TEST_SETTINGS,
        hookData,
      ],
    });
  };

  return (
    <section className="card">
      <div className="card-head">
        <h3>Swap</h3>
        <span className="card-note">exact input</span>
      </div>

      <div className="seg">
        <button
          className={lane === "fast" ? "seg-b active fast" : "seg-b"}
          onClick={() => setLane("fast")}
        >
          Fast
          <span>now · 0.30% + urgency</span>
        </button>
        <button
          className={lane === "slow" ? "seg-b active slow" : "seg-b"}
          onClick={() => setLane("slow")}
        >
          Slow
          <span>batch · 0.05%</span>
        </button>
      </div>

      {liquidity !== undefined && liquidity === 0n && (
        <div className="tx-note err-note">
          This pool has no active liquidity at the current price, so nothing can fill. Add
          liquidity first — a slow order placed now will sit until it expires.
        </div>
      )}

      <Approvals owner={owner} spender={ADDRESSES.swapRouter as Address} label="Swap router" />

      <label className="field">
        <span>Direction</span>
        <select
          value={zeroForOne ? "01" : "10"}
          onChange={(e) => setZeroForOne(e.target.value === "01")}
        >
          <option value="01">Token A → Token B</option>
          <option value="10">Token B → Token A</option>
        </select>
      </label>

      <label className="field">
        <span>Amount in</span>
        <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" />
      </label>

      {lane === "slow" && (
        <>
          <label className="field">
            <span>
              Minimum out <em>becomes your limit price</em>
            </span>
            <input value={minOut} onChange={(e) => setMinOut(e.target.value)} inputMode="decimal" />
          </label>
          <label className="field">
            <span>
              Expiry <em>epochs before the remainder is refundable</em>
            </span>
            <input value={expiry} onChange={(e) => setExpiry(e.target.value)} inputMode="numeric" />
          </label>
          <p className="hint">
            Your input is escrowed now. You will not know the price until a later Fast swap
            settles the batch — that is what makes the fill unattackable.
          </p>
        </>
      )}

      <button className="pill wide" onClick={submit} disabled={tx.isPending || tx.mining}>
        {tx.isPending || tx.mining
          ? "Submitting…"
          : lane === "fast"
            ? "Swap now"
            : "Place slow order"}
      </button>
      <TxNote tx={tx} />
    </section>
  );
}

/* ------------------------------------------------------------------ */
/* orders                                                              */
/* ------------------------------------------------------------------ */

type Row = {
  id: bigint;
  zeroForOne: boolean;
  remaining: bigint;
  owedOut: bigint;
  status: number;
};

function Orders({ owner, nextOrderId, tick }: { owner: Address; nextOrderId: bigint; tick: number }) {
  const [rows, setRows] = useState<Row[]>([]);
  const tx = useTx();

  const ids = useMemo(() => {
    const out: bigint[] = [];
    for (let i = nextOrderId - 1n; i >= 1n && out.length < 12; i -= 1n) out.push(i);
    return out;
  }, [nextOrderId]);

  useEffect(() => {
    let alive = true;
    async function load() {
      const found: Row[] = [];
      for (const id of ids) {
        try {
          const o = (await readContract(wagmiConfig, {
            address: ADDRESSES.hook as Address,
            abi: kesselAbi,
            functionName: "orders",
            args: [id],
          })) as unknown as unknown[];
          if ((o[0] as string).toLowerCase() !== owner.toLowerCase()) continue;
          found.push({
            id,
            zeroForOne: o[1] as boolean,
            remaining: BigInt(o[3] as bigint),
            owedOut: BigInt(o[4] as bigint),
            status: Number(o[8]),
          });
        } catch {
          /* an id that does not resolve is simply skipped */
        }
      }
      if (alive) setRows(found);
    }
    load();
    const t = setInterval(load, 4000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [ids, owner, tick, tx.isSuccess]);

  if (rows.length === 0) {
    return (
      <section className="card">
        <div className="card-head">
          <h3>Your slow orders</h3>
        </div>
        <p className="empty">No slow orders yet. Place one and it will appear here.</p>
      </section>
    );
  }

  return (
    <section className="card">
      <div className="card-head">
        <h3>Your slow orders</h3>
        <span className="card-note">redeem once settled</span>
      </div>
      <table>
        <thead>
          <tr>
            <th>#</th>
            <th>Side</th>
            <th>Remaining</th>
            <th>Owed</th>
            <th>Status</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id.toString()}>
              <td>{r.id.toString()}</td>
              <td>{r.zeroForOne ? "A → B" : "B → A"}</td>
              <td className="mono">{fmt(r.remaining, 5)}</td>
              <td className="mono">{fmt(r.owedOut, 5)}</td>
              <td>
                <span className="tag">{STATUS[r.status] ?? r.status}</span>
              </td>
              <td>
                {r.owedOut > 0n && (
                  <button
                    className="ghost-btn sm"
                    onClick={() =>
                      tx.writeContract({
                        address: ADDRESSES.hook as Address,
                        abi: kesselAbi,
                        functionName: "redeem",
                        args: [r.id],
                      })
                    }
                  >
                    Redeem
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <TxNote tx={tx} />
    </section>
  );
}

/* ------------------------------------------------------------------ */
/* page                                                                */
/* ------------------------------------------------------------------ */

export default function AppPage({ onHome }: { onHome: () => void }) {
  const { address, isConnected, chainId } = useAccount();
  const { data } = useKessel(10_000);
  const [tick, setTick] = useState(0);
  const ready = isConnected && chainId === CHAIN_ID && address;

  return (
    <div className="app-shell">
      <header className="a-nav">
        <button className="brand as-button" onClick={onHome}>
          <div className="brand-mark" />
          <div className="brand-name">Kessel</div>
        </button>
        <div className="a-nav-state">
          <span className="chip sm">
            Epoch <b>{data ? data.currentEpoch : "—"}</b>
          </span>
          <span className="chip sm">
            Pending <b>{data ? data.pending.toString() : "—"}</b>
          </span>
          <span className="chip sm">
            Fast <b>{data ? asPercent(data.fBase).toFixed(2) + "%" : "—"}</b>
          </span>
          <span className="chip sm">
            Slow <b>{data ? asPercent(data.fSlow).toFixed(2) + "%" : "—"}</b>
          </span>
          <Wallet />
        </div>
      </header>

      <main className="a-main">
        {!ready ? (
          <div className="connect-prompt">
            <h2>Connect a wallet to trade</h2>
            <p>
              Base Sepolia only. The tokens are mocks and mintable, so you need nothing but a
              little testnet ETH for gas.
            </p>
            <Wallet />
          </div>
        ) : (
          <div className="a-grid">
            <div className="col">
              <Swap
                owner={address!}
                onDone={() => setTick((t) => t + 1)}
                sqrtPriceX96={data?.sqrtPriceX96}
                liquidity={data?.liquidity}
              />
              <Orders
                owner={address!}
                nextOrderId={data?.nextOrderId ?? 1n}
                tick={tick}
              />
            </div>
            <div className="col">
              <Faucet owner={address!} />
              <Liquidity owner={address!} />
              <section className="card">
                <div className="card-head">
                  <h3>Pool</h3>
                </div>
                <dl className="kv">
                  <dt>Hook</dt>
                  <dd>
                    <a
                      href={EXPLORER + "/address/" + ADDRESSES.hook}
                      target="_blank"
                      rel="noreferrer"
                    >
                      {short(ADDRESSES.hook)}
                    </a>
                  </dd>
                  <dt>Block</dt>
                  <dd className="mono">{data ? data.block.toString() : "—"}</dd>
                  <dt>Settlement</dt>
                  <dd>{data ? (data.forceSettleDue ? "forceable now" : "waiting") : "—"}</dd>
                  <dt>Min age</dt>
                  <dd>{data ? data.minSettleAge + " blocks" : "—"}</dd>
                  <dt>Active liquidity</dt>
                  <dd className={data && data.liquidity === 0n ? "bad" : ""}>
                    {data ? (data.liquidity === 0n ? "none in range" : fmt(data.liquidity, 2)) : "—"}
                  </dd>
                  <dt>Tick</dt>
                  <dd className="mono">{data ? data.tick : "—"}</dd>
                </dl>
                <p className="hint">
                  A slow order settles when a later Fast swap carries it. Place one, then send a
                  Fast swap a couple of blocks later and watch it fill.
                </p>
              </section>
            </div>
          </div>
        )}
      </main>
    </div>
  );
}
