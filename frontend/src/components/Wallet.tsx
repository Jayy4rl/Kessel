import { useState } from "react";
import { useAccount, useConnect, useConnectors, useDisconnect, useSwitchChain } from "wagmi";
import { CHAIN_ID } from "../lib/config";

const short = (a: string) => a.slice(0, 6) + "…" + a.slice(-4);

/// Connect flow.
///
/// Three things this deliberately does not do, because each of them is how the
/// previous version failed silently:
///
///   * pick `connectors[0]` and hope. wagmi discovers injected wallets at
///     runtime (EIP-6963), so the list is not fixed and the first entry is not
///     necessarily the one the visitor has.
///   * swallow `useConnect`'s error. A rejected or failed connection is
///     otherwise indistinguishable from a dead button.
///   * assume a wallet exists. With no extension there is nothing to connect
///     to, and saying so is more useful than a button that does nothing.
export default function Wallet() {
  const { address, isConnected, chainId } = useAccount();
  const connectors = useConnectors();
  const { connect, isPending, error, variables, reset } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, isPending: switching } = useSwitchChain();
  const [open, setOpen] = useState(false);

  if (isConnected && address) {
    if (chainId !== CHAIN_ID) {
      return (
        <div className="wallet-chip">
          <button className="pill warn" disabled={switching} onClick={() => switchChain({ chainId: CHAIN_ID })}>
            {switching ? "Switching…" : "Switch to Base Sepolia"}
          </button>
          <button className="ghost-btn sm" onClick={() => disconnect()}>
            Disconnect
          </button>
        </div>
      );
    }
    return (
      <div className="wallet-chip">
        <span className="live">
          <b />
          {short(address)}
        </span>
        <button className="ghost-btn sm" onClick={() => disconnect()}>
          Disconnect
        </button>
      </div>
    );
  }

  // Injected connectors report `ready` false when no provider is present.
  const available = connectors.filter((c) => c.type !== "mock");

  if (available.length === 0) {
    return (
      <div className="wallet-none">
        <span>No wallet detected</span>
        <a href="https://metamask.io/download/" target="_blank" rel="noreferrer">
          Install MetaMask
        </a>
      </div>
    );
  }

  return (
    <div className="wallet-connect">
      <button
        className="pill"
        onClick={() => {
          reset();
          if (available.length === 1) connect({ connector: available[0] });
          else setOpen((o) => !o);
        }}
        disabled={isPending}
      >
        {isPending ? "Check your wallet…" : "Connect wallet"}
      </button>

      {open && available.length > 1 && (
        <div className="wallet-menu">
          {available.map((c) => (
            <button
              key={c.uid}
              className="wallet-opt"
              onClick={() => {
                reset();
                setOpen(false);
                connect({ connector: c });
              }}
            >
              {c.icon && <img src={c.icon} alt="" width={16} height={16} />}
              {c.name}
              {isPending && variables?.connector === c && <span className="dim"> · pending</span>}
            </button>
          ))}
        </div>
      )}

      {error && (
        <div className="wallet-err">
          {/not found|no provider|not detected/i.test(error.message)
            ? "No injected wallet responded. Is the extension enabled for this site?"
            : error.message.split("\n")[0].slice(0, 150)}
        </div>
      )}
    </div>
  );
}
