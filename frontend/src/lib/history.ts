// Claim and deployment history, kept per address in local storage. Nothing
// here is authoritative: the chain is. It exists so a returning user can see
// what they did and which deployment followed which claim.

const KEY = "kessel.activity.v1";

export interface ActivityRecord {
  kind: "claim" | "deploy";
  txId: string;
  /** ISO timestamp of when the transaction was sent. */
  timestamp: string;
  amountSats: string;
  bondIndex?: number;
  rewardCycle?: number;
  /** Deploys only. */
  destination?: string;
  /** Deploys only: the claim this deployment followed, when there was one. */
  claimTxId?: string;
}

/** PRD §6.7: one row per claim, carrying the deployment that followed it. */
export interface ClaimRecord {
  timestamp: string;
  bond_index: number;
  amount_sats: string;
  tx_id: string;
  deployed_to: string | null;
  deployed_amount_sats: string | null;
  deploy_tx_id: string | null;
}

type Store = Record<string, ActivityRecord[]>;

function readStore(): Store {
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? "{}") as Store;
  } catch {
    return {};
  }
}

function writeStore(store: Store): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(store));
  } catch {
    // Private windows and blocked storage are not worth failing a claim over.
  }
}

export function loadActivity(address: string): ActivityRecord[] {
  return readStore()[address] ?? [];
}

/** Adds a record, newest first, and returns the updated list. */
export function recordActivity(address: string, record: ActivityRecord): ActivityRecord[] {
  const store = readStore();
  const updated = [record, ...(store[address] ?? [])];
  writeStore({ ...store, [address]: updated });
  return updated;
}

export function clearActivity(address: string): void {
  const store = readStore();
  delete store[address];
  writeStore(store);
}

/** The most recent claim, which a deployment made now would be following. */
export function latestClaim(activity: ActivityRecord[]): ActivityRecord | null {
  return activity.find((record) => record.kind === "claim") ?? null;
}

export function toClaimRecords(activity: ActivityRecord[]): ClaimRecord[] {
  const deploys = activity.filter((record) => record.kind === "deploy");
  return activity
    .filter((record) => record.kind === "claim")
    .map((claim) => {
      const deploy = deploys.find((d) => d.claimTxId === claim.txId);
      return {
        timestamp: claim.timestamp,
        bond_index: claim.bondIndex ?? 0,
        amount_sats: claim.amountSats,
        tx_id: claim.txId,
        deployed_to: deploy?.destination ?? null,
        deployed_amount_sats: deploy?.amountSats ?? null,
        deploy_tx_id: deploy?.txId ?? null,
      };
    });
}
