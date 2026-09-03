import { createConfig, http } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";
import { RPC_URL } from "./config";

export const wagmiConfig = createConfig({
  chains: [baseSepolia],
  // EIP-6963 discovery finds every injected wallet the browser announces, so
  // the list is built at runtime rather than guessed here. `injected()` stays
  // as the fallback for extensions that only expose `window.ethereum`.
  multiInjectedProviderDiscovery: true,
  connectors: [injected({ shimDisconnect: true })],
  transports: { [baseSepolia.id]: http(RPC_URL) },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
