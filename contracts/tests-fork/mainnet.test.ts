import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  Cl,
  ClarityType,
  cvToString,
  type ClarityValue,
  type ResponseOkCV,
  type TupleCV,
  type UIntCV,
} from "@stacks/transactions";
import { beforeAll, beforeEach, describe, expect, it } from "vitest";

// Mainnet state these tests describe. Bump deliberately: assertions such as
// "stBTC deposits are shut down" are facts about this height.
const FORK_HEIGHT = 8_995_000;

// Holds sBTC and unlocked STX at FORK_HEIGHT. Simnet does not check
// signatures, so any mainnet address can send, deploy or call.
const FUNDER = "SP8YMPEBK0P9W3SYCAEB1M1XJFEJTP08RWG4G16E";
const DEPLOYER = FUNDER;
const STAKER = "SP1SJ3DTE5DN7X54YDH5D64R3BCB6A2AG2XG1V316";

const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";
const BITFLOW_POOL = "SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.xyk-pool-sbtc-stx-v-1-1";
const STBTC_CORE = "SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.stacking-dao-core-stbtc-v1";

const CONTRACTS = [
  ["kessel-traits", "contracts/kessel-traits.clar"],
  ["reward-router", "contracts/reward-router.clar"],
  ["stbtc-target", "contracts/stbtc-target.clar"],
  ["bitflow-sbtc-stx-target", "contracts/bitflow-sbtc-stx-target.clar"],
  ["mock-manager", "tests/fixtures/mock-manager.clar"],
] as const;

const AMOUNT = 10_000; // sats
const STAKER_STX = 100_000_000; // 100 STX, enough to pair AMOUNT on Bitflow twice
const ERR_SHUTDOWN = 25001;
const ERR_DEPLOY_ALLOWANCE_EXCEEDED = 109;

const own = (name: string) => `${DEPLOYER}.${name}`;
const ownCV = (name: string) => Cl.contractPrincipal(DEPLOYER, name);

// Unwraps an `ok`, failing with the actual Clarity value otherwise.
function okValue(result: ClarityValue): ClarityValue {
  if (result.type !== ClarityType.ResponseOk) {
    throw new Error(`expected (ok ...), got ${cvToString(result)}`);
  }
  return (result as ResponseOkCV).value;
}

const uintOf = (result: ClarityValue) => BigInt((okValue(result) as UIntCV).value);

const sbtcBalance = (who: string) =>
  uintOf(simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], who).result);

const lpBalance = (who: string) =>
  uintOf(simnet.callReadOnlyFn(BITFLOW_POOL, "get-balance", [Cl.principal(who)], who).result);

function sendSbtc(amount: number, recipient: string) {
  const { result } = simnet.callPublicFn(
    SBTC,
    "transfer",
    [Cl.uint(amount), Cl.principal(FUNDER), Cl.principal(recipient), Cl.none()],
    FUNDER,
  );
  expect(result).toBeOk(Cl.bool(true));
}

function admin(fn: string, args: ClarityValue[]) {
  const { result } = simnet.callPublicFn(own("reward-router"), fn, args, DEPLOYER);
  expect(result).toBeOk(Cl.bool(true));
}

// One fork per file: each session fetches mainnet state over the network, so
// tests share it and assert on balance deltas rather than absolute values.
beforeAll(async () => {
  await simnet.initEmptySession({
    enabled: true,
    api_url: "https://api.hiro.so",
    initial_height: FORK_HEIGHT,
  });
  for (const [name, path] of CONTRACTS) {
    simnet.deployContract(
      name,
      readFileSync(join(process.cwd(), path), "utf8"),
      { clarityVersion: 4 },
      DEPLOYER,
    );
  }
  sendSbtc(100_000, STAKER);
  simnet.transferSTX(STAKER_STX, STAKER, FUNDER);

  admin("set-source", [ownCV("mock-manager"), Cl.bool(true)]);
  admin("set-target", [Cl.stringAscii("bitflow"), ownCV("bitflow-sbtc-stx-target"), Cl.bool(true)]);
});

describe("adapters against mainnet state", () => {
  it("bitflow-sbtc-stx-target adds liquidity and mints LP tokens to the caller", () => {
    const sbtcBefore = sbtcBalance(STAKER);
    const lpBefore = lpBalance(STAKER);

    const { result } = simnet.callPublicFn(
      own("bitflow-sbtc-stx-target"),
      "deploy",
      [Cl.uint(AMOUNT), Cl.uint(1)],
      STAKER,
    );

    const minted = uintOf(result);
    expect(minted).toBeGreaterThan(0n);
    expect(lpBalance(STAKER)).toBe(lpBefore + minted);
    expect(sbtcBalance(STAKER)).toBe(sbtcBefore - BigInt(AMOUNT));
  });

  it("stbtc-target is blocked while StackingDAO has deposits shut down", () => {
    expect(
      simnet.callReadOnlyFn(STBTC_CORE, "get-shutdown-deposits", [], STAKER).result,
    ).toStrictEqual(Cl.bool(true));

    const { result } = simnet.callPublicFn(
      own("stbtc-target"),
      "deploy",
      [Cl.uint(AMOUNT), Cl.uint(1)],
      STAKER,
    );
    expect(result).toBeErr(Cl.uint(ERR_SHUTDOWN));
  });
});

describe("reward-router against mainnet state", () => {
  beforeEach(() => {
    sendSbtc(AMOUNT, own("mock-manager"));
    const { result } = simnet.callPublicFn(
      own("mock-manager"),
      "set-owed",
      [Cl.principal(STAKER), Cl.uint(AMOUNT)],
      DEPLOYER,
    );
    expect(result).toBeOk(Cl.bool(true));
  });

  const claimIntoBitflow = (maxStx: number) =>
    simnet.callPublicFn(
      own("reward-router"),
      "claim-and-deploy",
      [
        Cl.uint(1),
        Cl.uint(10),
        ownCV("mock-manager"),
        Cl.stringAscii("bitflow"),
        ownCV("bitflow-sbtc-stx-target"),
        Cl.uint(AMOUNT),
        Cl.uint(1),
        Cl.uint(maxStx),
      ],
      STAKER,
    ).result;

  it("claims rewards and deploys them into the live Bitflow pool atomically", () => {
    const sbtcBefore = sbtcBalance(STAKER);
    const lpBefore = lpBalance(STAKER);

    const fields = (okValue(claimIntoBitflow(STAKER_STX)) as TupleCV).value;

    expect(fields.claimed).toStrictEqual(Cl.uint(AMOUNT));
    expect(fields.deployed).toStrictEqual(Cl.uint(AMOUNT));
    const received = BigInt((fields.received as UIntCV).value);
    expect(received).toBeGreaterThan(0n);
    expect(lpBalance(STAKER)).toBe(lpBefore + received);
    // Rewards passed through the staker's wallet into the pool.
    expect(sbtcBalance(STAKER)).toBe(sbtcBefore);
  });

  it("stops the pool pulling more STX than max-stx", () => {
    const lpBefore = lpBalance(STAKER);

    expect(claimIntoBitflow(1)).toBeErr(Cl.uint(ERR_DEPLOY_ALLOWANCE_EXCEEDED));

    expect(lpBalance(STAKER)).toBe(lpBefore);
    expect(
      simnet.callReadOnlyFn(own("mock-manager"), "get-owed", [Cl.principal(STAKER)], STAKER)
        .result,
    ).toBeUint(AMOUNT);
  });
});
