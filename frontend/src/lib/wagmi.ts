import { fallback, http } from "viem";
import { createConfig } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { RPC_URLS } from "./config";

export const wagmiConfig = createConfig({
  chains: [baseSepolia],
  // EIP-6963 discovery finds every injected wallet the browser announces, so
  // the list is built at runtime rather than guessed here. `injected()` stays
  // as the fallback for extensions that only expose `window.ethereum`.
  multiInjectedProviderDiscovery: true,
  connectors: [injected({ shimDisconnect: true })],
  // Reads fall through to the next endpoint rather than surfacing one host's
  // outage as a broken app. NOTE: this does not cover sending transactions --
  // those go out through the wallet's own RPC, not this one.
  transports: {
    [baseSepolia.id]: fallback(
      RPC_URLS.map((url) => http(url, { retryCount: 2 })),
      { rank: false },
    ),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
