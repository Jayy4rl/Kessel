import { Component, StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";
import App from "./App";

/// A thrown render is otherwise a blank page with the reason only in the
/// console. This is worth having beyond debugging: the dashboard is meant to be
/// opened by people who did not build it, and "nothing happened" is the least
/// useful thing it could tell them.
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
          The dashboard failed to render
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

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </StrictMode>,
);
