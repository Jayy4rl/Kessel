import { Component, StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider } from "wagmi";
import "./index.css";
import App from "./App";
import { wagmiConfig } from "./lib/wagmi";

/// A thrown render is otherwise a blank page with the reason only in the
/// console. Worth having beyond debugging: this is meant to be opened by people
/// who did not build it, and "nothing happened" is the least useful thing it
/// could tell them.
class ErrorBoundary extends Component<{ children: ReactNode }, { error: Error | null }> {
  state: { error: Error | null } = { error: null };

  static getDerivedStateFromError(error: Error) {
    return { error };
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return (
      <div style={{ padding: 28, fontFamily: "ui-monospace, Menlo, Consolas, monospace" }}>
        <h1 style={{ fontSize: 18, color: "#e8563f", margin: "0 0 10px" }}>
          The app failed to render
        </h1>
        <pre
          style={{
            whiteSpace: "pre-wrap",
            fontSize: 12,
            color: "#f1f1f3",
            background: "#141416",
            border: "1px solid #262629",
            borderRadius: 8,
            padding: 14,
            lineHeight: 1.5,
          }}
        >
          {error.message}
          {"\n\n"}
          {error.stack}
        </pre>
      </div>
    );
  }
}

const queryClient = new QueryClient();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ErrorBoundary>
      <WagmiProvider config={wagmiConfig}>
        <QueryClientProvider client={queryClient}>
          <App />
        </QueryClientProvider>
      </WagmiProvider>
    </ErrorBoundary>
  </StrictMode>,
);
