import { ADDRESSES, EXPLORER, MEASURED } from "../lib/config";

const advantage =
  (Number(MEASURED.slowOut - MEASURED.fastOut) / Number(MEASURED.fastOut)) * 100;

export default function Landing({ onLaunch }: { onLaunch: () => void }) {
  return (
    <div className="landing">
      <header className="l-nav">
        <div className="brand">
          <div className="brand-mark" />
          <div className="brand-name">Kessel</div>
        </div>
        <nav className="l-nav-links">
          <a href="#how">How it works</a>
          <a href="#lanes">Lanes</a>
          <a
            href={"https://github.com/Jayy4rl/Kessel"}
            target="_blank"
            rel="noreferrer"
          >
            GitHub
          </a>
        </nav>
        <button className="pill" onClick={onLaunch}>
          Launch app
        </button>
      </header>

      <section className="hero">
        <div className="tagline">Uniswap v4 hook · live on Base Sepolia</div>
        <h1 className="hero-h1">
          Two execution lanes.
          <br />
          <span className="hero-accent">One liquidity curve.</span>
        </h1>
        <p className="hero-sub">
          A pool cannot charge one fee that is both high enough to pay for immediacy and low
          enough to keep patient flow. Kessel stops trying. Traders pick a lane, and the choice
          reveals what their time is worth.
        </p>
        <div className="hero-cta">
          <button className="pill big" onClick={onLaunch}>
            Launch app
          </button>
          <a
            className="ghost-btn"
            href={EXPLORER + "/address/" + ADDRESSES.hook}
            target="_blank"
            rel="noreferrer"
          >
            View contract
          </a>
        </div>
      </section>

      <section className="lanes" id="lanes">
        <article className="lane-card">
          <div className="lane-head">
            <span className="tag fast">Fast</span>
            <span className="lane-fee">0.30% + urgency</span>
          </div>
          <h3>Execute now, in this block</h3>
          <p>
            An ordinary v4 swap. The fee rises with the priority fee you already pay to be
            ordered first, so the premium you were going to spend to jump the queue is charged by
            the pool and paid to the people whose inventory you are consuming.
          </p>
          <ul>
            <li>Same-block execution, normal UX</li>
            <li>Premium routed to LPs, not the sequencer</li>
            <li>Sandwich-resistant: a front-runner must outbid you, so pays more tax</li>
          </ul>
        </article>

        <article className="lane-card">
          <div className="lane-head">
            <span className="tag slow">Slow</span>
            <span className="lane-fee">0.05% flat</span>
          </div>
          <h3>Wait a little, pay a sixth</h3>
          <p>
            The hook escrows your input and issues a claim. Your order joins a batch, and every
            order in that batch clears at a single price computed at settlement — not at
            submission. You do not know your price when you commit, which is exactly what makes
            the lane unattackable.
          </p>
          <ul>
            <li>Uniform clearing price: no position in the batch is worth anything</li>
            <li>Opposing orders net against each other before touching the curve</li>
            <li>Your <code>minOut</code> bounds the downside</li>
          </ul>
        </article>
      </section>

      <section className="how" id="how">
        <h2>How it works</h2>
        <ol className="steps">
          <li>
            <span className="step-n">1</span>
            <div>
              <strong>You choose a lane</strong>
              <p>
                One byte of <code>hookData</code>. Send nothing and you get Fast, so routers that
                have never heard of this hook still trade normally.
              </p>
            </div>
          </li>
          <li>
            <span className="step-n">2</span>
            <div>
              <strong>Fast swaps price your urgency</strong>
              <p>
                The hook reads <code>tx.gasprice − block.basefee</code> — the only honest urgency
                signal available on chain — and charges <code>f_base + k × priorityFee</code>.
              </p>
            </div>
          </li>
          <li>
            <span className="step-n">3</span>
            <div>
              <strong>Slow orders are escrowed, not executed</strong>
              <p>
                The hook takes your input into the singleton as an ERC-6909 claim and records the
                order. No swap math runs. You hold a claim to a future fill.
              </p>
            </div>
          </li>
          <li>
            <span className="step-n">4</span>
            <div>
              <strong>A later Fast swap carries the batch</strong>
              <p>
                No keeper and no solver. The next Fast trader settles the pending batch as a side
                effect, after their own price impact is already booked — so they cannot pick a
                moment that favours them. If the pool goes quiet, anyone can force settlement.
              </p>
            </div>
          </li>
          <li>
            <span className="step-n">5</span>
            <div>
              <strong>Everyone in the batch gets the same price</strong>
              <p>
                Opposing orders net off first; only the imbalance touches the curve. Then you
                redeem.
              </p>
            </div>
          </li>
        </ol>
      </section>

      <section className="proof">
        <h2>Measured on chain</h2>
        <p className="proof-sub">
          The same 0.01 token through each lane, on the live deployment.
        </p>
        <div className="proof-grid">
          <div className="proof-cell">
            <div className="proof-label">Fast lane</div>
            <div className="proof-value mono">{MEASURED.fastOut.toLocaleString()}</div>
            <div className="proof-note">0.30% fee · immediate</div>
          </div>
          <div className="proof-cell">
            <div className="proof-label">Slow lane</div>
            <div className="proof-value mono accent">{MEASURED.slowOut.toLocaleString()}</div>
            <div className="proof-note">0.05% fee · settled in a batch</div>
          </div>
          <div className="proof-cell">
            <div className="proof-label">Patience paid</div>
            <div className="proof-value ok">+{advantage.toFixed(3)}%</div>
            <div className="proof-note">against a 0.25% fee spread</div>
          </div>
        </div>
        <p className="proof-foot">
          The gap is smaller than the fee spread because the swaps in between moved the price.
          That is the honest number, not the theoretical one.
        </p>
      </section>

      <footer className="l-foot">
        <div>
          <strong>Kessel</strong> · testnet only · mock tokens · not reviewed by a human
        </div>
        <div className="l-foot-links">
          <a href={EXPLORER + "/address/" + ADDRESSES.hook} target="_blank" rel="noreferrer">
            Hook
          </a>
          <a
            href={EXPLORER + "/address/" + ADDRESSES.batchSolver}
            target="_blank"
            rel="noreferrer"
          >
            BatchSolver
          </a>
          <a href="https://github.com/Jayy4rl/Kessel" target="_blank" rel="noreferrer">
            Source
          </a>
        </div>
      </footer>
    </div>
  );
}
