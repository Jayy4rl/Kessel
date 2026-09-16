import { HIRO_API } from "./config";

export type TxState = "pending" | "success" | "failed" | "unknown";

export interface TxStatus {
  state: TxState;
  /** Hiro's own status string, e.g. `abort_by_post_condition`. */
  raw: string;
  blockHeight: number | null;
  result: string | null;
}

/** Hiro reports one success, one pending, and two aborts. */
export function mapTxStatus(status: string): TxState {
  if (status === "success") return "success";
  if (status === "pending") return "pending";
  if (status.startsWith("abort_")) return "failed";
  return "unknown";
}

export const isFinal = (state: TxState) => state === "success" || state === "failed";

export async function fetchTxStatus(txid: string): Promise<TxStatus> {
  const res = await fetch(`${HIRO_API}/extended/v1/tx/${txid}`);
  // A transaction the API has not indexed yet is still on its way.
  if (res.status === 404) return { state: "pending", raw: "not_found", blockHeight: null, result: null };
  if (!res.ok) throw new Error(`tx ${txid}: HTTP ${res.status}`);
  const tx = (await res.json()) as {
    tx_status: string;
    block_height?: number;
    tx_result?: { repr: string };
  };
  return {
    state: mapTxStatus(tx.tx_status),
    raw: tx.tx_status,
    blockHeight: tx.block_height ?? null,
    result: tx.tx_result?.repr ?? null,
  };
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Polls until the transaction succeeds or fails, reporting each reading.
 * Gives up after `timeoutMs`, returning the last state seen.
 */
export async function waitForTx(
  txid: string,
  {
    onUpdate,
    intervalMs = 5_000,
    timeoutMs = 20 * 60_000,
  }: { onUpdate?: (status: TxStatus) => void; intervalMs?: number; timeoutMs?: number } = {},
): Promise<TxStatus> {
  const deadline = Date.now() + timeoutMs;
  let status: TxStatus = { state: "pending", raw: "pending", blockHeight: null, result: null };
  onUpdate?.(status);

  while (Date.now() < deadline) {
    try {
      status = await fetchTxStatus(txid);
      onUpdate?.(status);
      if (isFinal(status.state)) return status;
    } catch {
      // A failed read is not a failed transaction; keep polling.
    }
    await sleep(intervalMs);
  }
  return status;
}
