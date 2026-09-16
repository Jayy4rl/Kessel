import { Cl, ClarityType, type OptionalCV, type TupleCV, type UIntCV } from "@stacks/transactions";
import { fetchBurnHeight, type BondSummary } from "./bonds";
import { HIRO_API, POX_5 } from "./config";
import { readOnly, toBigInt } from "./tx";

// PRD §5.7: tell someone whether they can join a bond before they spend gas.
// Every check is a read; nothing here signs or costs anything.

export interface EligibilityInput {
  /** Maximum sats this principal may lock, or null when not allowlisted. */
  allowanceSats: bigint | null;
  /** The bond this principal is already in, if any. */
  existingBondIndex: number | null;
  capacitySats: bigint;
  lockedSats: bigint;
  /** uSTX this bond requires for `intendedSats`. */
  requiredUstx: bigint;
  availableUstx: bigint;
  currentBurnHeight: number;
  activationHeight: number;
  intendedSats: bigint;
}

export interface EligibilityCheck {
  id: "allowlist" | "stx-ratio" | "no-position" | "capacity" | "window";
  label: string;
  ok: boolean;
  detail: string;
}

const sats = (value: bigint) => `${(Number(value) / 1e8).toFixed(8)} BTC`;
const stx = (value: bigint) => `${Math.round(Number(value) / 1e6).toLocaleString()} STX`;

export function evaluateEligibility(input: EligibilityInput): {
  checks: EligibilityCheck[];
  eligible: boolean;
} {
  const {
    allowanceSats,
    existingBondIndex,
    capacitySats,
    lockedSats,
    requiredUstx,
    availableUstx,
    currentBurnHeight,
    activationHeight,
    intendedSats,
  } = input;

  const remainingCapacity = capacitySats > lockedSats ? capacitySats - lockedSats : 0n;
  const checks: EligibilityCheck[] = [
    {
      id: "allowlist",
      label: "On the allowlist",
      ok: allowanceSats !== null && intendedSats <= allowanceSats,
      detail:
        allowanceSats === null
          ? "This address has no allocation for this bond."
          : `Allocation up to ${sats(allowanceSats)}.`,
    },
    {
      id: "stx-ratio",
      label: "Enough STX to pair",
      ok: availableUstx >= requiredUstx,
      detail:
        availableUstx >= requiredUstx
          ? `Needs ${stx(requiredUstx)}; you hold ${stx(availableUstx)}.`
          : `Short by ${stx(requiredUstx - availableUstx)} of the ${stx(requiredUstx)} required.`,
    },
    {
      id: "no-position",
      label: "No position in the way",
      ok: existingBondIndex === null,
      detail:
        existingBondIndex === null
          ? "No existing bond position."
          : `Already registered for bond ${existingBondIndex}; PoX-5 allows one position per principal.`,
    },
    {
      id: "capacity",
      label: "Capacity available",
      ok: remainingCapacity >= intendedSats,
      detail: `${sats(remainingCapacity)} of ${sats(capacitySats)} still open.`,
    },
    {
      id: "window",
      label: "Registration still open",
      ok: currentBurnHeight < activationHeight,
      detail:
        currentBurnHeight < activationHeight
          ? `Closes at Bitcoin block ${activationHeight.toLocaleString()}.`
          : `Closed at Bitcoin block ${activationHeight.toLocaleString()}.`,
    },
  ];

  return { checks, eligible: checks.every((check) => check.ok) };
}

async function fetchAvailableUstx(address: string): Promise<bigint> {
  const res = await fetch(`${HIRO_API}/extended/v1/address/${address}/stx`);
  if (!res.ok) throw new Error(`stx balance: HTTP ${res.status}`);
  const { balance, locked } = (await res.json()) as { balance: string; locked: string };
  return BigInt(balance) - BigInt(locked);
}

/** Runs the checklist for one bond, reading allowance and position from pox-5. */
export async function fetchEligibility({
  bond,
  address,
  intendedSats,
}: {
  bond: BondSummary;
  address: string;
  intendedSats: bigint;
}) {
  const [allowance, membership, params, burnHeight, availableUstx] = await Promise.all([
    readOnly(POX_5, "get-bond-allowance", [Cl.uint(bond.index), Cl.principal(address)]),
    readOnly(POX_5, "get-bond-membership", [Cl.principal(address)]),
    readOnly(POX_5, "get-protocol-bond", [Cl.uint(bond.index)]),
    fetchBurnHeight(),
    fetchAvailableUstx(address),
  ]);

  const allowanceCV = allowance as OptionalCV<UIntCV>;
  const membershipCV = membership as OptionalCV<TupleCV>;
  const paramsCV = params as OptionalCV<TupleCV>;
  if (paramsCV.type !== ClarityType.OptionalSome) throw new Error(`bond ${bond.index} not found`);

  const requiredUstx = toBigInt(
    await readOnly(POX_5, "min-ustx-for-sats-amount", [
      Cl.uint(intendedSats),
      Cl.uint(toBigInt(paramsCV.value.value["stx-value-ratio"])),
      Cl.uint(toBigInt(paramsCV.value.value["min-ustx-ratio"])),
    ]),
  );

  return evaluateEligibility({
    allowanceSats:
      allowanceCV.type === ClarityType.OptionalSome ? toBigInt(allowanceCV.value) : null,
    existingBondIndex:
      membershipCV.type === ClarityType.OptionalSome
        ? Number(toBigInt(membershipCV.value.value["bond-index"]))
        : null,
    capacitySats: bond.capacitySats,
    lockedSats: bond.lockedSats,
    requiredUstx,
    availableUstx,
    currentBurnHeight: burnHeight,
    activationHeight: bond.activationHeight,
    intendedSats,
  });
}
