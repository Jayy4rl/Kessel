import { useEffect, useState } from "react";
import AppPage from "./pages/AppPage";
import Landing from "./pages/Landing";

/// Hash routing rather than a router dependency: there are two views, and the
/// hash survives a refresh and a shared link without needing server rewrites.
function useHashRoute() {
  const [hash, setHash] = useState(() => window.location.hash);
  useEffect(() => {
    const on = () => setHash(window.location.hash);
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  return hash;
}

export default function App() {
  const hash = useHashRoute();
  const inApp = hash.startsWith("#/app");

  const go = (to: string) => {
    window.location.hash = to;
    window.scrollTo(0, 0);
  };

  return inApp ? (
    <AppPage onHome={() => go("/")} />
  ) : (
    <Landing onLaunch={() => go("/app")} />
  );
}
