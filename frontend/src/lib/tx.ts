import {
  ClarityType,
  fetchCallReadOnlyFunction,
  Pc,
  type ClarityValue,
  type PostCondition,
} from "@stacks/transactions";
import { SBTC_ASSET_NAME, SBTC_TOKEN } from "./config";

export type ContractId = `${string}.${string}`;

/** Parameters for `request("stx_callContract", …)` from `@stacks/connect`. */
export interface ContractCall {
  contract: ContractId;
  functionName: string;
  functionArgs: ClarityValue[];
  postConditions: PostCondition[];
  postConditionMode: "deny";
}

export function splitContractId(id: ContractId): [address: string, name: string] {
  const [address, name] = id.split(".");
  return [address, name];
}

/** `sender` sends exactly `amount` sats of sBTC. */
export function sbtcSentExactly(sender: string, amount: bigint): PostCondition {
  return Pc.principal(sender).willSendEq(amount).ft(SBTC_TOKEN, SBTC_ASSET_NAME);
}

export function readOnly(
  contract: ContractId,
  functionName: string,
  functionArgs: ClarityValue[] = [],
): Promise<ClarityValue> {
  const [contractAddress, contractName] = splitContractId(contract);
  return fetchCallReadOnlyFunction({
    contractAddress,
    contractName,
    functionName,
    functionArgs,
    senderAddress: contractAddress,
    network: "mainnet",
  });
}

export function unwrapOk(cv: ClarityValue): ClarityValue {
  if (cv.type !== ClarityType.ResponseOk) throw new Error(`expected (ok …), got ${cv.type}`);
  return cv.value;
}

export function toBigInt(cv: ClarityValue): bigint {
  if (cv.type !== ClarityType.UInt && cv.type !== ClarityType.Int) {
    throw new Error(`expected an integer, got ${cv.type}`);
  }
  return BigInt(cv.value);
}

export function toBool(cv: ClarityValue): boolean {
  if (cv.type === ClarityType.BoolTrue) return true;
  if (cv.type === ClarityType.BoolFalse) return false;
  throw new Error(`expected a bool, got ${cv.type}`);
}
