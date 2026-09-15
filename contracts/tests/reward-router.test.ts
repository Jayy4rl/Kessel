import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  Cl,
  type ClarityValue,
  type ResponseOkCV,
  type TupleCV,
  type UIntCV,
} from "@stacks/transactions";
import { beforeEach, describe, expect, it } from "vitest";

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const staker = accounts.get("wallet_1")!;
const outsider = accounts.get("wallet_2")!;

const ROUTER = "reward-router";
const SBTC = "SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token";

const FIXTURES = [
  "mock-manager",
  "lying-manager",
  "evil-manager",
  "mock-target",
  "greedy-target",
  "partial-target",
  "stx-pair-target",
  "router-proxy",
] as const;
type Fixture = (typeof FIXTURES)[number];

const ERR = {
  UNAUTHORIZED: 100,
  PAUSED: 101,
  UNKNOWN_TARGET: 102,
  TARGET_DISABLED: 103,
  TARGET_MISMATCH: 104,
  SOURCE_NOT_ALLOWED: 105,
  NOTHING_CLAIMED: 106,
  BELOW_MIN_AMOUNT: 107,
  CLAIM_MOVED_ASSETS: 108,
  DEPLOY_ALLOWANCE_EXCEEDED: 109,
  PARTIAL_DEPLOY: 110,
  NOT_A_CONTRACT: 111,
  INVALID_NAME: 112,
  TOO_MANY_TARGETS: 113,
  NO_PENDING_OWNER: 114,
} as const;

const REWARD = 5_000;

const contract = (name: Fixture) => `${deployer}.${name}`;
const contractCV = (name: Fixture) => Cl.contractPrincipal(deployer, name);

function deployFixture(name: Fixture) {
  const source = readFileSync(join(process.cwd(), "tests", "fixtures", `${name}.clar`), "utf8");
  simnet.deployContract(name, source, { clarityVersion: 4 }, deployer);
}

function call(fn: string, args: ClarityValue[], sender = deployer) {
  return simnet.callPublicFn(ROUTER, fn, args, sender);
}

function readOnly(fn: string, args: ClarityValue[] = []) {
  return simnet.callReadOnlyFn(ROUTER, fn, args, deployer).result;
}

function sbtcBalance(who: string): bigint {
  const { result } = simnet.callReadOnlyFn(SBTC, "get-balance", [Cl.principal(who)], deployer);
  return BigInt((result as ResponseOkCV<UIntCV>).value.value);
}

function fundSbtc(recipient: string, amount: number) {
  const { result } = simnet.callPublicFn(
    SBTC,
    "transfer",
    [Cl.uint(amount), Cl.principal(deployer), Cl.principal(recipient), Cl.none()],
    deployer,
  );
  expect(result).toBeOk(Cl.bool(true));
}

function setTarget(name: string, target: Fixture, enabled = true) {
  return call("set-target", [Cl.stringAscii(name), contractCV(target), Cl.bool(enabled)]);
}

function setSource(source: Fixture, enabled = true) {
  return call("set-source", [contractCV(source), Cl.bool(enabled)]);
}

function owe(amount: number, who = staker) {
  const { result } = simnet.callPublicFn(
    "mock-manager",
    "set-owed",
    [Cl.principal(who), Cl.uint(amount)],
    deployer,
  );
  expect(result).toBeOk(Cl.bool(true));
}

type Route = {
  source?: Fixture;
  targetName?: string;
  target?: Fixture;
  minAmount?: number;
  minOut?: number;
  maxStx?: number;
  sender?: string;
};

function claimAndDeploy({
  source = "mock-manager",
  targetName = "mock",
  target = "mock-target",
  minAmount = 0,
  minOut = 0,
  maxStx = 0,
  sender = staker,
}: Route = {}) {
  return call(
    "claim-and-deploy",
    [
      Cl.uint(1),
      Cl.uint(10),
      contractCV(source),
      Cl.stringAscii(targetName),
      contractCV(target),
      Cl.uint(minAmount),
      Cl.uint(minOut),
      Cl.uint(maxStx),
    ],
    sender,
  );
}

beforeEach(() => {
  FIXTURES.forEach(deployFixture);
  fundSbtc(contract("mock-manager"), 1_000_000);
  fundSbtc(contract("evil-manager"), 1_000_000);

  for (const source of ["mock-manager", "lying-manager", "evil-manager"] as const) {
    expect(setSource(source).result).toBeOk(Cl.bool(true));
  }
  const targets = [
    ["mock", "mock-target"],
    ["greedy", "greedy-target"],
    ["partial", "partial-target"],
    ["stx-pair", "stx-pair-target"],
  ] as const;
  for (const [name, target] of targets) {
    expect(setTarget(name, target).result).toBeOk(Cl.bool(true));
  }
  owe(REWARD);
});

describe("claim-and-deploy", () => {
  it("claims and deploys the full reward atomically", () => {
    const stakerBefore = sbtcBalance(staker);
    const managerBefore = sbtcBalance(contract("mock-manager"));

    const { result, events } = claimAndDeploy({ minAmount: REWARD, minOut: REWARD });

    expect(result).toBeOk(
      Cl.tuple({
        claimed: Cl.uint(REWARD),
        deployed: Cl.uint(REWARD),
        received: Cl.uint(REWARD),
        target: Cl.stringAscii("mock"),
      }),
    );
    // Rewards pass through the staker's wallet and end up in the position.
    expect(sbtcBalance(staker)).toBe(stakerBefore);
    expect(sbtcBalance(contract("mock-manager"))).toBe(managerBefore - BigInt(REWARD));
    expect(sbtcBalance(contract("mock-target"))).toBe(BigInt(REWARD));
    expect(events.some((e) => e.event === "print_event")).toBe(true);
  });

  it("never holds funds", () => {
    claimAndDeploy();
    expect(sbtcBalance(`${deployer}.${ROUTER}`)).toBe(0n);
  });

  it("reverts the claim when the claimed amount is below min-amount", () => {
    const managerBefore = sbtcBalance(contract("mock-manager"));

    const { result } = claimAndDeploy({ minAmount: REWARD + 1 });

    expect(result).toBeErr(Cl.uint(ERR.BELOW_MIN_AMOUNT));
    expect(sbtcBalance(contract("mock-manager"))).toBe(managerBefore);
    expect(
      simnet.callReadOnlyFn("mock-manager", "get-owed", [Cl.principal(staker)], deployer).result,
    ).toBeUint(REWARD);
  });

  it("rejects a claim that pays nothing", () => {
    owe(0);
    expect(claimAndDeploy().result).toBeErr(Cl.uint(ERR.NOTHING_CLAIMED));
  });

  it("measures the claim instead of trusting the source's reported amount", () => {
    const { result } = claimAndDeploy({ source: "lying-manager" });
    expect(result).toBeErr(Cl.uint(ERR.NOTHING_CLAIMED));
  });

  it("forwards min-out to the target", () => {
    const { result } = claimAndDeploy({ minOut: REWARD + 1 });
    expect(result).toBeErr(Cl.uint(1));
  });

  it("only runs when the staker calls directly", () => {
    const { result } = simnet.callPublicFn(
      "router-proxy",
      "route",
      [contractCV("mock-manager"), Cl.stringAscii("mock"), contractCV("mock-target")],
      staker,
    );
    expect(result).toBeErr(Cl.uint(ERR.UNAUTHORIZED));
  });

  it("stops while paused and resumes when unpaused", () => {
    call("set-paused", [Cl.bool(true)]);
    expect(claimAndDeploy().result).toBeErr(Cl.uint(ERR.PAUSED));

    call("set-paused", [Cl.bool(false)]);
    expect(claimAndDeploy().result).toBeOk(expect.anything());
  });
});

describe("registry checks", () => {
  it("rejects an unregistered target name", () => {
    expect(claimAndDeploy({ targetName: "nope" }).result).toBeErr(Cl.uint(ERR.UNKNOWN_TARGET));
  });

  it("rejects a disabled target", () => {
    setTarget("mock", "mock-target", false);
    expect(claimAndDeploy().result).toBeErr(Cl.uint(ERR.TARGET_DISABLED));
  });

  it("rejects a target contract that does not match the registered name", () => {
    const { result } = claimAndDeploy({ targetName: "mock", target: "greedy-target" });
    expect(result).toBeErr(Cl.uint(ERR.TARGET_MISMATCH));
  });

  it("rejects a source that is not allowlisted", () => {
    setSource("mock-manager", false);
    expect(claimAndDeploy().result).toBeErr(Cl.uint(ERR.SOURCE_NOT_ALLOWED));
  });
});

describe("asset restrictions on external contracts", () => {
  it("blocks a source that moves the staker's assets during the claim", () => {
    const stakerBefore = sbtcBalance(staker);

    const { result } = claimAndDeploy({ source: "evil-manager" });

    expect(result).toBeErr(Cl.uint(ERR.CLAIM_MOVED_ASSETS));
    expect(sbtcBalance(staker)).toBe(stakerBefore);
  });

  it("blocks a target that takes more sBTC than was claimed", () => {
    const stakerBefore = sbtcBalance(staker);

    const { result } = claimAndDeploy({ targetName: "greedy", target: "greedy-target" });

    expect(result).toBeErr(Cl.uint(ERR.DEPLOY_ALLOWANCE_EXCEEDED));
    expect(sbtcBalance(staker)).toBe(stakerBefore);
    // The claim leg is rolled back with it.
    expect(
      simnet.callReadOnlyFn("mock-manager", "get-owed", [Cl.principal(staker)], deployer).result,
    ).toBeUint(REWARD);
  });

  it("rejects a target that leaves part of the claim undeployed", () => {
    const { result } = claimAndDeploy({ targetName: "partial", target: "partial-target" });
    expect(result).toBeErr(Cl.uint(ERR.PARTIAL_DEPLOY));
  });

  it("lets a target pull STX only up to max-stx", () => {
    const route = { targetName: "stx-pair", target: "stx-pair-target" } as const;

    expect(claimAndDeploy({ ...route, maxStx: 999_999 }).result).toBeErr(
      Cl.uint(ERR.DEPLOY_ALLOWANCE_EXCEEDED),
    );
    expect(claimAndDeploy({ ...route, maxStx: 1_000_000 }).result).toBeOk(expect.anything());
  });
});

describe("administration", () => {
  it("restricts every admin function to the owner", () => {
    const calls: [string, ClarityValue[]][] = [
      ["set-target", [Cl.stringAscii("x"), contractCV("mock-target"), Cl.bool(true)]],
      ["set-source", [contractCV("mock-manager"), Cl.bool(true)]],
      ["set-paused", [Cl.bool(true)]],
      ["transfer-ownership", [Cl.principal(outsider)]],
    ];
    for (const [fn, args] of calls) {
      expect(call(fn, args, outsider).result).toBeErr(Cl.uint(ERR.UNAUTHORIZED));
    }
  });

  it("only registers contract principals", () => {
    const target = call("set-target", [Cl.stringAscii("x"), Cl.principal(outsider), Cl.bool(true)]);
    const source = call("set-source", [Cl.principal(outsider), Cl.bool(true)]);

    expect(target.result).toBeErr(Cl.uint(ERR.NOT_A_CONTRACT));
    expect(source.result).toBeErr(Cl.uint(ERR.NOT_A_CONTRACT));
  });

  it("rejects an empty target name", () => {
    expect(setTarget("", "mock-target").result).toBeErr(Cl.uint(ERR.INVALID_NAME));
  });

  it("lists targets in registration order without duplicating updates", () => {
    setTarget("greedy", "greedy-target", false);

    const view = (name: string, target: Fixture, enabled: boolean) =>
      Cl.tuple({ name: Cl.stringAscii(name), contract: contractCV(target), enabled: Cl.bool(enabled) });

    expect(readOnly("get-targets")).toStrictEqual(
      Cl.list([
        view("mock", "mock-target", true),
        view("greedy", "greedy-target", false),
        view("partial", "partial-target", true),
        view("stx-pair", "stx-pair-target", true),
      ]),
    );
  });

  it("caps the registry at 20 targets", () => {
    for (let i = 0; i < 16; i++) {
      expect(setTarget(`extra-${i}`, "mock-target").result).toBeOk(Cl.bool(true));
    }
    expect(setTarget("one-too-many", "mock-target").result).toBeErr(
      Cl.uint(ERR.TOO_MANY_TARGETS),
    );
  });

  it("hands over ownership in two steps", () => {
    expect(call("accept-ownership", [], outsider).result).toBeErr(Cl.uint(ERR.NO_PENDING_OWNER));

    call("transfer-ownership", [Cl.principal(outsider)]);
    expect(call("accept-ownership", [], staker).result).toBeErr(Cl.uint(ERR.UNAUTHORIZED));
    expect(call("accept-ownership", [], outsider).result).toBeOk(Cl.bool(true));

    expect(readOnly("get-owner")).toBePrincipal(outsider);
    expect(readOnly("get-pending-owner")).toBeNone();
    expect(call("set-paused", [Cl.bool(true)]).result).toBeErr(Cl.uint(ERR.UNAUTHORIZED));
    expect(call("set-paused", [Cl.bool(true)], outsider).result).toBeOk(Cl.bool(true));
  });
});

describe("preview-claim-and-deploy", () => {
  const preview = (targetName: string) =>
    readOnly("preview-claim-and-deploy", [
      Cl.principal(staker),
      contractCV("mock-manager"),
      Cl.stringAscii(targetName),
    ]);

  const previewFields = (targetName: string) => (preview(targetName) as TupleCV).value;

  it("reports a route that would pass the router's checks", () => {
    expect(preview("mock")).toStrictEqual(
      Cl.tuple({
        paused: Cl.bool(false),
        "source-enabled": Cl.bool(true),
        target: Cl.some(Cl.tuple({ contract: contractCV("mock-target"), enabled: Cl.bool(true) })),
        "sbtc-balance": Cl.uint(sbtcBalance(staker)),
        executable: Cl.bool(true),
      }),
    );
  });

  it("reports a route that would fail", () => {
    call("set-paused", [Cl.bool(true)]);
    expect(previewFields("mock").executable).toStrictEqual(Cl.bool(false));

    call("set-paused", [Cl.bool(false)]);
    const unknown = previewFields("nope");
    expect(unknown.target).toStrictEqual(Cl.none());
    expect(unknown.executable).toStrictEqual(Cl.bool(false));
  });
});
