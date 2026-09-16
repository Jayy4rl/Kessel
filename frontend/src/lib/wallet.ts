import { connect, disconnect, getLocalStorage, isConnected, request } from "@stacks/connect";
import type { ContractCall } from "./tx";

/** The connected mainnet address, or null when no wallet is connected. */
export function connectedAddress(): string | null {
  if (!isConnected()) return null;
  return getLocalStorage()?.addresses.stx[0]?.address ?? null;
}

export async function connectWallet(): Promise<string | null> {
  await connect();
  return connectedAddress();
}

export function disconnectWallet(): void {
  disconnect();
}

/** Hands a built call to the wallet for signing; returns the transaction id. */
export async function sendContractCall(call: ContractCall): Promise<string> {
  const { txid } = await request("stx_callContract", { ...call, network: "mainnet" });
  if (!txid) throw new Error("the wallet returned no transaction id");
  return txid;
}

export const explorerTx = (txid: string) =>
  `https://explorer.hiro.so/txid/${txid}?chain=mainnet`;
