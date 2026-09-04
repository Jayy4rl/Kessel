import { useMemo } from "react";
import { ADDRESSES, EXPLORER, MEASURED } from "../lib/config";
import { asPercent, curve, fastFee } from "../lib/fee";

const F_BASE = 3_000n;
const F_SLOW = 500n;
const K = 500n;

const advantage =
  (Number(MEASURED.slowOut - MEASURED.fastOut) / Number(MEASURED.fastOut)) * 100;

/// Drawn from the same arithmetic the contract runs, so the shape is the fee
/// the pool would actually charge.
function FeeCurve() {
  const pts = useMemo(() => curve(F_BASE, K, 25), []);
  const w = 560;
  const h = 150;
  const maxFee = asPercent(pts[pts.length - 1].fee);

  const x = (g: number) => (g / 25) * w;
  const y = (feePct: number) => h - (feePct / maxFee) * (h - 16) - 8;

  const line = pts.map((p, i) => `${i ? "L" : "M"}${x(p.gwei)},${y(asPercent(p.fee))}`).join(" ");
  const area = `${line} L${w},${h} L0,${h} Z`;
  const slowY = y(asPercent(F_SLOW));

  return (
    <svg className="curve" viewBox={`0 0 ${w} ${h}`} role="img" aria-label="Fast-lane fee against priority fee">
      <defs>
        <linearGradient id="fill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#e8563f" stopOpacity="0.34" />
          <stop offset="100%" stopColor="#e8563f" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={area} fill="url(#fill)" />
      <path d={line} fill="none" stroke="#e8563f" strokeWidth="2" />
      <line x1="0" y1={slowY} x2={w} y2={slowY} stroke="#7aa7ff" strokeWidth="1.5" strokeDasharray="4 4" />
      <text x="6" y={slowY - 7} fill="#7aa7ff" fontSize="11">
        slow · flat 0.05%
      </text>
      <text x={w - 6} y="20" fill="#e8563f" fontSize="11" textAnchor="end">
        fast · rises with urgency
      </text>
    </svg>
  );
}

export default function Landing({ onLaunch }: { onLaunch: () => void }) {
  const at20 = asPercent(fastFee(F_BASE, K, 20_000_000_000n));

  return (
    <div className="landing">
      <header className="l-nav">
        <div className="brand">
          <div className="brand-mark" />
          <div className="brand-name">Kessel</div>
        </div>
        <nav className="l-nav-links">
          <a href="#traders">Traders</a>
          <a href="#lps">LPs</a>
          <a href="#how">How</a>
          <a href="https://github.com/Jayy4rl/Kessel" target="_blank" rel="noreferrer">
            GitHub
          </a>
        </nav>
        <button className="pill" onClick={onLaunch}>
          Launch app
        </button>
      </header>

      {/* hero */}
      <section className="hero">
        <div className="hero-glow" aria-hidden="true" />
        <div className="tagline">
          <span className="live">
            <b />
            Live on Base Sepolia
          </span>
          <span className="sep">·</span> Uniswap v4 hook
        </div>

        <h1 className="hero-h1">
          Not everyone is
          <br />
          in a <span className="hero-accent">hurry.</span>
        </h1>

        <p className="hero-sub">So why does everyone pay the same fee?</p>

        <div className="hero-cta">
          <button className="pill big" onClick={onLaunch}>
            Try it on testnet
          </button>
          <a className="ghost-btn" href="#how">
            How it works
          </a>
        </div>

        <div className="hero-strip">
          <div>
            <b>0.05%</b>
            <span>slow lane</span>
          </div>
          <div>
            <b>6×</b>
            <span>cheaper</span>
          </div>
          <div>
            <b>0</b>
            <span>middlemen</span>
          </div>
          <div>
            <b>100%</b>
            <span>premium to LPs</span>
          </div>
        </div>
      </section>

      {/* audiences */}
      <section className="who">
        <article className="who-card" id="traders">
          <div className="who-eyebrow">Traders</div>
          <h2>Stop paying for speed you didn't need.</h2>
          <ul className="ticks">
            <li>
              <b>0.05%</b>, not 0.30%
            </li>
            <li>
              <b>Un-sandwichable</b> — one price for the whole batch
            </li>
            <li>
              <b>Set your floor</b> and the fill can't go below it
            </li>
            <li>
              <b>In a rush?</b> Take the fast lane instead
            </li>
          </ul>
          <button className="pill" onClick={onLaunch}>
            Make a trade
          </button>
        </article>

        <article className="who-card" id="lps">
          <div className="who-eyebrow">Liquidity providers</div>
          <h2>Get paid for the urgency you already serve.</h2>
          <ul className="ticks">
            <li>
              <b>Keep the premium</b> that goes to block builders today
            </li>
            <li>
              <b>{at20.toFixed(2)}%</b> from urgent flow, against a 0.30% floor
            </li>
            <li>
              <b>Patient flow stays</b> instead of leaving for a cheaper venue
            </li>
            <li>
              <b>One curve</b> — your depth is never split
            </li>
          </ul>
          <button className="ghost-btn" onClick={onLaunch}>
            Add liquidity
          </button>
        </article>
      </section>

      {/* curve */}
      <section className="curve-block">
        <div className="curve-copy">
          <h2>The fee follows the hurry.</h2>
          <p>No rush, no premium. In a hurry, you pay more — and it goes to the LPs.</p>
          <p className="muted-p">The slow lane never moves. Flat 0.05%.</p>
        </div>
        <div className="curve-wrap">
          <FeeCurve />
          <div className="curve-axis">
            <span>0 gwei</span>
            <span>priority fee →</span>
            <span>25 gwei</span>
          </div>
        </div>
      </section>

      {/* how */}
      <section className="how" id="how">
        <h2>Four steps, no middlemen</h2>
        <p className="how-sub">No keeper. No solver. No oracle. It runs on people trading.</p>
        <ol className="steps">
          <li>
            <span className="step-n">1</span>
            <div>
              <strong>Pick a lane</strong>
              <p>Fast or slow, per trade. Aggregators get fast automatically.</p>
            </div>
          </li>
          <li>
            <span className="step-n">2</span>
            <div>
              <strong>Slow orders wait</strong>
              <p>The pool holds your tokens. Nothing executes, so there's no price to attack.</p>
            </div>
          </li>
          <li>
            <span className="step-n">3</span>
            <div>
              <strong>A fast trader settles them</strong>
              <p>They trade, clear the queue on the way past, and pay the gas. That's the engine.</p>
            </div>
          </li>
          <li>
            <span className="step-n">4</span>
            <div>
              <strong>One price for everyone</strong>
              <p>Opposite orders cancel out first. Being first in the batch is worth nothing.</p>
            </div>
          </li>
        </ol>
      </section>

      {/* proof */}
      <section className="proof">
        <h2>It already works</h2>
        <p className="proof-sub">Same trade, both lanes, on the live deployment.</p>
        <div className="proof-grid">
          <div className="proof-cell">
            <div className="proof-label">Fast lane</div>
            <div className="proof-value mono">{MEASURED.fastOut.toLocaleString()}</div>
            <div className="proof-note">immediate · 0.30%</div>
          </div>
          <div className="proof-cell">
            <div className="proof-label">Slow lane</div>
            <div className="proof-value mono accent">{MEASURED.slowOut.toLocaleString()}</div>
            <div className="proof-note">batched · 0.05%</div>
          </div>
          <div className="proof-cell">
            <div className="proof-label">Waiting paid</div>
            <div className="proof-value ok">+{advantage.toFixed(3)}%</div>
            <div className="proof-note">identical trade</div>
          </div>
        </div>
        <p className="proof-foot">Measured, not modelled.</p>
      </section>

      {/* closing */}
      <section className="closing">
        <h2>Two lanes. One pool. Your choice.</h2>
        <p>Free test tokens. No signup. Nothing to lose.</p>
        <button className="pill big" onClick={onLaunch}>
          Launch app
        </button>
        <p className="disclaimer">
          Testnet, mock tokens, unaudited. Keep real money away from it.
        </p>
      </section>

      <footer className="l-foot">
        <div>
          <strong>Kessel</strong> · Uniswap v4 hook · Base Sepolia
        </div>
        <div className="l-foot-links">
          <a href={EXPLORER + "/address/" + ADDRESSES.hook} target="_blank" rel="noreferrer">
            Contract
          </a>
          <a href="https://github.com/Jayy4rl/Kessel" target="_blank" rel="noreferrer">
            Source
          </a>
        </div>
      </footer>
    </div>
  );
}
