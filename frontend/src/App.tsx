import { useMemo, useState } from "react";
import { ADDRESSES, EXPLORER, MEASURED, POOL_ID } from "./lib/config";
import { asPercent, curve, fastFee, premium } from "./lib/fee";
import { useKessel } from "./lib/useKessel";

const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);
const pct = (n: number) => n.toFixed(2) + "%";

function Stat(props: { label: string; sub: string; value: string; accent?: boolean }) {
  return (
    <div className="stat">
      <div className="stat-label">{props.label}</div>
      <div className="stat-sub">{props.sub}</div>
      <div className={props.accent ? "stat-value accent" : "stat-value"}>{props.value}</div>
    </div>
  );
}

/// The Fast-Lane fee against revealed urgency, drawn from the same formula the
/// contract runs. The flat start is the point rather than an artefact: a zero
/// priority fee reveals no urgency and pays exactly `f_base`.
function FeeCurve({ fBase, k }: { fBase: bigint; k: bigint }) {
  const [hover, setHover] = useState<number | null>(null);
  const pts = useMemo(() => curve(fBase, k), [fBase, k]);

  const W = 1000;
  const H = 210;
  const PAD_L = 46;
  const PAD_B = 24;
  const PAD_T = 10;

  const maxFee = Math.max(...pts.map((p) => asPercent(p.fee)));
  const top = maxFee * 1.12;
  const maxG = pts[pts.length - 1].gwei;
  const x = (g: number) => PAD_L + (g / maxG) * (W - PAD_L - 12);
  const y = (f: number) => PAD_T + (1 - f / top) * (H - PAD_T - PAD_B);

  const line = pts.map((p, i) => (i ? "L" : "M") + x(p.gwei) + "," + y(asPercent(p.fee))).join(" ");
  const area = line + " L" + x(maxG) + "," + (H - PAD_B) + " L" + x(0) + "," + (H - PAD_B) + " Z";
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((t) => top * t);
  const hp = hover !== null ? pts[hover] : null;

  return (
    <div className="chart-wrap">
      <svg className="chart" viewBox={"0 0 " + W + " " + H} preserveAspectRatio="none">
        <defs>
          <linearGradient id="fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="var(--coral)" stopOpacity="0.42" />
            <stop offset="100%" stopColor="var(--coral)" stopOpacity="0" />
          </linearGradient>
        </defs>

        {ticks.map((t, i) => (
          <g key={i}>
            <line className="grid-line" x1={PAD_L} y1={y(t)} x2={W - 12} y2={y(t)} />
            <text className="axis-text" x={PAD_L - 8} y={y(t) + 3} textAnchor="end">
              {t.toFixed(2)}%
            </text>
          </g>
        ))}

        <path d={area} fill="url(#fill)" />
        <path d={line} fill="none" stroke="var(--coral)" strokeWidth="2" vectorEffect="non-scaling-stroke" />

        {hp && (
          <g>
            <line className="grid-line" x1={x(hp.gwei)} y1={PAD_T} x2={x(hp.gwei)} y2={H - PAD_B} />
            <circle cx={x(hp.gwei)} cy={y(asPercent(hp.fee))} r="3.5" fill="var(--coral)" />
          </g>
        )}

        {[0, maxG / 2, maxG].map((g) => (
          <text key={g} className="axis-text" x={x(g)} y={H - 6} textAnchor="middle">
            {g} gwei
          </text>
        ))}

        {pts.map((p, i) => (
          <rect
            key={i}
            className="hit"
            x={x(p.gwei) - 7}
            y={0}
            width={14}
            height={H - PAD_B}
            onMouseEnter={() => setHover(i)}
            onMouseLeave={() => setHover(null)}
          />
        ))}
      </svg>

      {hp && (
        <div
          className="tip"
          style={{
            left: (x(hp.gwei) / W) * 100 + "%",
            top: (y(asPercent(hp.fee)) / H) * 100 + "%",
          }}
        >
          <div className="t-when">priority {hp.gwei} gwei</div>
          <div className="t-val">
            fee {pct(asPercent(hp.fee))} · to LPs {pct(asPercent(premium(hp.fee, fBase)))}
          </div>
        </div>
      )}
    </div>
  );
}

export default function App() {
  const { data, error, stale } = useKessel();

  // Defaults are the deployed values, so the page is meaningful on the first
  // paint and degrades to last-known rather than to zeros if the RPC drops.
  const fBase = data?.fBase ?? 3000n;
  const fSlow = data?.fSlow ?? 500n;
  const k = data?.k ?? 500n;

  const advantage = (Number(MEASURED.slowOut - MEASURED.fastOut) / Number(MEASURED.fastOut)) * 100;

  const rows = [
    { lane: "Fast", note: "in block", fee: asPercent(fBase), out: MEASURED.fastOut },
    { lane: "Slow", note: "batch, uniform price", fee: asPercent(fSlow), out: MEASURED.slowOut },
  ];

  return (
    <div className="shell">
      <aside className="side">
        <div className="brand">
          <div className="brand-mark" />
          <div className="brand-name">Kessel</div>
        </div>
        <nav className="nav">
          <div className="nav-item active">
            <span className="nav-dot" />
            Overview
          </div>
          <div className="nav-item">
            <span className="nav-dot" />
            Lanes
          </div>
          <div className="nav-item">
            <span className="nav-dot" />
            Batches
            <span className="badge">live</span>
          </div>
          <div className="nav-item">
            <span className="nav-dot" />
            Liquidity
          </div>
        </nav>
        <div className="side-foot">
          <div className="nav-item">
            <span className="nav-dot" />
            Contracts
          </div>
          <div className="nav-item">
            <span className="nav-dot" />
            Docs
          </div>
        </div>
      </aside>

      <main className="main">
        <div className="topbar">
          <span className={stale ? "live stale" : "live"}>
            <b />
            {stale ? "reconnecting" : "Base Sepolia · live"}
          </span>
          <button className="pill">Deployed</button>
        </div>

        <h1>Overview</h1>

        <div className="chips">
          <span className="chip">
            Hook{" "}
            <b>
              <a href={EXPLORER + "/address/" + ADDRESSES.hook} target="_blank" rel="noreferrer">
                {short(ADDRESSES.hook)}
              </a>
            </b>
          </span>
          <span className="chip">
            Pool <b className="mono">{POOL_ID.slice(0, 10)}…</b>
          </span>
          <span className="chip">
            Block <b>{data ? data.block.toString() : "—"}</b>
          </span>
          <span className="chip">
            Epoch <b>{data ? data.currentEpoch : "—"}</b>
          </span>
        </div>

        {error && (
          <div className="err">
            Cannot reach the chain — showing last known values. {error.slice(0, 140)}
          </div>
        )}

        <div className="stats">
          <Stat label="Fast lane" sub="base, zero priority" value={pct(asPercent(fBase))} />
          <Stat label="Slow lane" sub="flat, batch cleared" value={pct(asPercent(fSlow))} />
          <Stat
            label="At 20 gwei"
            sub="fast lane, urgent"
            value={pct(asPercent(fastFee(fBase, k, 20_000_000_000n)))}
            accent
          />
          <Stat
            label="Pending orders"
            sub={"epoch " + (data ? data.oldestUnsettledEpoch : "—")}
            value={data ? data.pending.toString() : "—"}
          />
          <Stat
            label="Settlement"
            sub={"min age " + (data ? data.minSettleAge : "—") + " blocks"}
            value={data ? (data.forceSettleDue ? "forceable" : "waiting") : "—"}
          />
        </div>

        <div className="panel">
          <div className="panel-head">
            <span className="panel-title">Fast-lane fee against revealed urgency</span>
            <span className="panel-note">everything above the flat line is recaptured to LPs</span>
          </div>
          <FeeCurve fBase={fBase} k={k} />
        </div>

        <div className="panel">
          <div className="panel-head">
            <span className="panel-title">Breakdown by lane</span>
            <span className="panel-note">measured on Base Sepolia, identical 0.01 input</span>
          </div>
          <table>
            <thead>
              <tr>
                <th>Lane</th>
                <th>Fee</th>
                <th>Output (wei)</th>
                <th>Execution</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.lane}>
                  <td>
                    <span className={"tag " + r.lane.toLowerCase()}>{r.lane}</span>{" "}
                    <span style={{ color: "var(--dim)" }}>{r.note}</span>
                  </td>
                  <td>{pct(r.fee)}</td>
                  <td className="mono">{r.out.toLocaleString()}</td>
                  <td style={{ color: r.lane === "Slow" ? "var(--ok)" : "var(--muted)" }}>
                    {r.lane === "Slow" ? "+" + advantage.toFixed(3) + "%" : "baseline"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="foot">
          The same trade through each lane, on a live chain. The patient trader kept{" "}
          <strong style={{ color: "var(--ok)" }}>{advantage.toFixed(3)}%</strong> more against a{" "}
          {pct(asPercent(fBase - fSlow))} fee spread; the gap is price impact from the swaps in
          between.
          <br />
          Fees, epoch and batch state are read live from the hook. The two output figures are the
          recorded result of the deployment run, not a simulation.
        </div>
      </main>
    </div>
  );
}
