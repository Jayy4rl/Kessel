# Slither triage — 2026-08-26

**Tool:** slither-analyzer 0.11.6, `forge` compilation framework, `slither.config.json`
(excludes `naming-convention`, `solc-version`, `pragma`; filters `lib/`).

```bash
slither . --config-file slither.config.json
```

Run against the working tree at 1,523 lines of `KesselHook.sol` plus three pure
libraries. **No high-severity findings, before or after.** Ten mediums on the
first run; the two that were real were reproduced with a failing test *before*
any fix, per the security-review discipline, and are recorded as SR-6 and SR-7 in
`docs/DECISIONS.md`.

## Triage

| # | Finding | Verdict | Test | Fix |
|---|---------|---------|------|-----|
| 1 | `reentrancy-no-eth` — `_payoutOrder`: `o.status = REFUNDED` / `o.amountInRemaining = 0` / `o.status = REDEEMED` written after `poolManager.take` | **REAL — high, permanent fund loss** | `test/security/RedeemReentrancy.t.sol` (3 tests; 2 failed pre-fix) | SR-6: `_settling` held across `_payoutOrder`; `FILLED -> REDEEMED` conditioned on `owedOut == 0` |
| 2 | `missing-zero-check` — `setGovernance(address).newGovernance` | **REAL — low, permanent loss of parameter control** | `test_governanceCannotBeHandedToTheZeroAddress` (failed pre-fix) | SR-7: reject `address(0)` |
| 3 | `missing-zero-check` — `constructor._governance` | **REAL — same class** | covered by the same reasoning; constructor path guarded identically | SR-7 |
| 4 | `events-access` — `setGovernance` emits nothing | **REAL — low, observability** | `test_governanceHandoverIsAnnounced` (failed pre-fix) | SR-7: emits `ParameterUpdated("governance", old, new)` |
| 5 | `redundant-statements` — `orderId;` in `_openSlowOrder` | **REAL — cosmetic** | none needed (a no-op statement) | assignment dropped; `_recordOrder` called for effect |
| 6 | `uninitialized-local` — `_loadCandidates.n` | **False positive.** Solidity zero-initialises value-type locals; `n` is a counter read only after being written. | — | — |
| 7 | `uninitialized-local` — `_executeAndDistribute.p` (`Pots memory`) | **False positive.** A `memory` struct declaration is zero-initialised, and every field is assigned before use. | — | — |
| 8 | `unused-return` — `poolManager.unlock(...)` in `redeem`, `forceSettle`, `sweepRecapture` | **False positive.** `unlockCallback` always returns `""`; there is nothing to read. | — | — |
| 9 | `unused-return` — `poolManager.donate(...)` in `_recapture` | **False positive.** `donate` debits the caller by exactly `(fee0, fee1)`, which is what the following `settle` calls pay; the returned delta carries no information the call site does not already have. | — | — |
| 10 | `unused-return` — `LaneCodec.decode` in `_afterSwap` | **False positive.** Only the lane is needed there; the Slow-Lane fields are decoded and discarded by design. | — | — |
| 11 | `unused-return` — `poolManager.getSlot0` in the settlement solve | **False positive.** Only `sqrtPriceX96` and `tick` enter `Clearing.PoolPoint`; protocol/LP fee are irrelevant to the clearing solve. (Reported against `_poolPoint` on the 2026-08-26 run; that helper was dead code and was removed on 2026-08-31, and the same pattern now sits in `_solveMultiRange`.) | — | — |
| 12 | `reentrancy-benign` / `reentrancy-events` (10 instances across `_payoutOrder`, `_recapture`, `_openSlowOrder`, `_afterSwap`) | **False positive.** These are event-ordering and non-state observations. The one state-write case that mattered is finding 1. | — | — |
| 13 | `assembly` — `_position` | **False positive.** Mirrors v4-core's own `TickBitmap.position`, verbatim and memory-safe. | — | — |
| 14 | `reentrancy-no-eth` — `_executeAndDistribute`: `epochs`, `orders` and `warehoused*` written after an external call into the filler | **REAL — resolved by restructure, not triaged away** | `test/security/ExternalFill.t.sol` (14 tests) | Shape B inverted to deliver-first: the filler transfers before calling, the hook only measures, and payment happens after every write. The callback — and with it the pattern — is gone. |
| 15 | `reentrancy-no-eth` — Slow-Lane intake reachable from inside a settlement | **REAL — found while triaging 14, not reported by Slither** | `test/security/FillIntakeReentrancy.t.sol` (failed pre-fix: the reentrant order was recorded) | `_openSlowOrder` reverts `SettlementInProgress` while `_settling` is held |

## After the fixes

Re-run: no high findings; six `unused-return`, two `uninitialized-local`, two
`reentrancy-no-eth` and the `assembly` note remain, all triaged above as false
positives. `missing-zero-check`, `events-access` and `redundant-statements` are
gone.

The two surviving `reentrancy-no-eth` reports are now on `_payoutOrderInner`.
Slither cannot see the fix: `_settling` is a boolean flag set by the wrapper
rather than a modifier the detector recognises, so it still reports the raw
write-after-call pattern. Kept as a known, documented false positive rather than
suppressed, so that a future change which *removes* the guard does not also
silently remove the warning.

## Addendum — 2026-08-29, the external-fill path (Shape B)

`settleWithFill` initially added a **third** site with the same shape as finding
1, and the first where the callee was fully untrusted rather than the
PoolManager: the hook paid the filler, called `fillKesselBatch` on a
caller-nominated contract, and then wrote `epochs`, `orders` and `warehoused*`.

That was first documented here as inherent and kept, on the reasoning that
`Clearing.fillRatio` needs the delivery before it can produce a fill ratio, so
the call must precede the writes. **That reasoning was wrong, and the finding is
now fixed rather than triaged.** It assumed the hook had to pay first and call
back. Inverting the flow removes the requirement entirely:

- the filler transfers the output currency to the hook **before** calling
  `settleWithFill`, in the same transaction;
- the hook measures its own balance, refuses anything below the curve floor,
  and completes every state write with no external call in between;
- the filler is paid the batch's input **last**, after the writes.

There is no callback, so there is no window in which a half-finished settlement
is holding an untrusted contract's control, and no write-after-untrusted-call
ordering for the detector to report. `quoteFill()` exists so a filler can size
the delivery without one.

Nothing is lost that mattered. A filler with inventory delivers directly; a
filler without one wraps the call in a flash loan from anywhere else. The
atomicity moves outside Kessel rather than being manufactured inside it, and the
hook stops being a flash-lender to arbitrary contracts mid-settlement.

The only remaining call-then-write in the path is `_settling = false` after the
outbound payment, which is the standard reentrancy-guard reset: it cannot be
moved earlier without defeating the guard.

Finding 1's disposition on `_payoutOrderInner` is **unchanged** — that one is
genuinely inherent, since a payout is an outbound transfer by definition, and
remains a documented, unsuppressed report.

### What triaging it actually found

Reasoning about the callee's reach turned up a real gap that Slither did not
report, and that no existing test covered:

`poolManager.swap` is `onlyWhenUnlocked`, not `onlyByTheUnlocker` — the SR-6
asymmetry. Any contract holding control inside the hook's own `unlock` may call
it directly with SLOW `hookData`, reach `_openSlowOrder`, and write
`warehoused*`, `orders`, `epochOrderIds` and `currentEpoch` underneath work that
is half-finished. `_settling` did not cover intake, and v4's nested-`unlock`
prohibition does not either, because intake needs no unlock of its own.

It was found via the filler callback, which no longer exists — but the gap was
never specific to it. It is still live on the **redemption** path, which is not
going away: `_settling` is held across `_payoutOrder`, `poolManager.take` of
native currency hands control to the recipient with a bare `call`, and DD-14
refuses native ETH only as Slow-Lane *input*, so a `oneForZero` order on an
ETH-quoted pool pays out in ETH. That is the same reentry point SR-6 documents,
and `test/security/FillIntakeReentrancy.t.sol` now exercises the guard there.

No concrete corruption was constructed through it. It is closed structurally
anyway, because SR-4 is the standing reminder that "unreachable by argument" is
not the same as unreachable, and this contract cannot be patched.

**This fix needs an SR number and a `docs/DECISIONS.md` entry, which only the
owner assigns.** It is recorded here because it was found during triage; it is
deliberately not written into the decision register by the agent that found it.

### What remains reachable through the filler call, and why it is inert

| Filler attempts | Outcome |
|---|---|
| Reenter settlement | `_settleEpochInner` returns early on `_settling` |
| `settleWithFill` / `forceSettle` / `redeem` / `sweepRecapture` | each opens its own `unlock` → v4 `AlreadyUnlocked` |
| Direct FAST `poolManager.swap` | permitted; `afterSwap` declines on `_settling` |
| Direct SLOW `poolManager.swap` | reverts `SettlementInProgress` (the fix above) |
| Anything at all during the fill | **not reachable** — there is no callback into the filler |
| Move the price, or add/remove liquidity | permitted, and inert for this settlement |

The last row is the one worth justifying rather than asserting. Nothing after
the filler call reads pool state: the remainder of `_executeAndDistribute` runs
on `poolDelta` (measured across the call), the `Cand[] memory` snapshot taken
before it, and `net0`/`net1` computed before it. The only post-call external
call is `poolManager.donate` in `_recapture`, which is already wrapped in
`try`/`catch` with the PRD §6.2 `lpClaimable` fallback — so a filler that pulls
all in-range liquidity mid-fill can at most divert that settlement's `f_slow`
into the deferred-donation balance, where it stays owed to LPs.

### Not re-run

Slither 0.11.6 is **not installed in the environment these changes were made
in**, so the table above is reasoning from the detector's known behaviour on
findings 1–13, not from a fresh run. Re-running it is a prerequisite for review:
the external-fill path is exactly the shape (`reentrancy-no-eth`,
`reentrancy-benign`, `unused-return` on `poolManager.settle`) that this tool is
good at, and the addendum should be replaced with real output.

## Raw output — first run (before fixes)

```
'forge clean' running (wd: /home/lenovo/Kessel)
'forge config --json' running
'forge build --build-info --deny never --skip ./test/** ./script/** --force' running (wd: /home/lenovo/Kessel)
INFO:Detectors:
Detector: reentrancy-no-eth
Reentrancy in KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1111)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1112)
	State variables written after the call(s):
	- o.amountInRemaining = 0 (src/KesselHook.sol#1119)
	KesselHook.orders (src/KesselHook.sol#160) can be used in cross function reentrancies:
	- KesselHook._advanceIfDrained(uint32) (src/KesselHook.sol#1371-1391)
	- KesselHook._applyFills(uint32,KesselHook.Cand[],KesselHook.Pots) (src/KesselHook.sol#926-991)
	- KesselHook._loadCandidates(uint32) (src/KesselHook.sol#585-616)
	- KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143)
	- KesselHook._recordOrder(address,bool,uint128,uint128,uint32) (src/KesselHook.sol#369-402)
	- KesselHook._rollUnfilled(uint32) (src/KesselHook.sol#752-789)
	- KesselHook.orders (src/KesselHook.sol#160)
	- KesselHook.redeem(uint256) (src/KesselHook.sol#1083-1096)
	- o.status = OrderStatus.REDEEMED (src/KesselHook.sol#1142)
	KesselHook.orders (src/KesselHook.sol#160) can be used in cross function reentrancies:
	- KesselHook._advanceIfDrained(uint32) (src/KesselHook.sol#1371-1391)
	- KesselHook._applyFills(uint32,KesselHook.Cand[],KesselHook.Pots) (src/KesselHook.sol#926-991)
	- KesselHook._loadCandidates(uint32) (src/KesselHook.sol#585-616)
	- KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143)
	- KesselHook._recordOrder(address,bool,uint128,uint128,uint32) (src/KesselHook.sol#369-402)
	- KesselHook._rollUnfilled(uint32) (src/KesselHook.sol#752-789)
	- KesselHook.orders (src/KesselHook.sol#160)
	- KesselHook.redeem(uint256) (src/KesselHook.sol#1083-1096)
Reentrancy in KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1111)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1112)
	- inCurrency.settle(poolManager,address(this),refund,true) (src/KesselHook.sol#1127)
	- poolManager.take(inCurrency,o.trader,refund) (src/KesselHook.sol#1128)
	State variables written after the call(s):
	- o.status = OrderStatus.REFUNDED (src/KesselHook.sol#1136)
	KesselHook.orders (src/KesselHook.sol#160) can be used in cross function reentrancies:
	- KesselHook._advanceIfDrained(uint32) (src/KesselHook.sol#1371-1391)
	- KesselHook._applyFills(uint32,KesselHook.Cand[],KesselHook.Pots) (src/KesselHook.sol#926-991)
	- KesselHook._loadCandidates(uint32) (src/KesselHook.sol#585-616)
	- KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143)
	- KesselHook._recordOrder(address,bool,uint128,uint128,uint32) (src/KesselHook.sol#369-402)
	- KesselHook._rollUnfilled(uint32) (src/KesselHook.sol#752-789)
	- KesselHook.orders (src/KesselHook.sol#160)
	- KesselHook.redeem(uint256) (src/KesselHook.sol#1083-1096)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-2
INFO:Detectors:
Detector: uninitialized-local
KesselHook._executeAndDistribute(uint32,KesselHook.Cand[],Clearing.Solution,uint256,uint256).p (src/KesselHook.sol#720) is a local variable never initialized
KesselHook._loadCandidates(uint32).n (src/KesselHook.sol#592) is a local variable never initialized
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#uninitialized-local-variables
INFO:Detectors:
Detector: unused-return
KesselHook._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes) (src/KesselHook.sol#421-454) ignores return value by (lane,None,None,None) = LaneCodec.decode(hookData,address(0)) (src/KesselHook.sol#430)
KesselHook.forceSettle() (src/KesselHook.sol#483-490) ignores return value by poolManager.unlock(abi.encode(UnlockAction.SETTLE,epoch,uint256(0))) (src/KesselHook.sol#489)
KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1021-1044) ignores return value by poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1028-1043)
KesselHook.sweepRecapture() (src/KesselHook.sol#1052-1055) ignores return value by poolManager.unlock(abi.encode(UnlockAction.SWEEP,uint32(0),uint256(0))) (src/KesselHook.sol#1054)
KesselHook.redeem(uint256) (src/KesselHook.sol#1083-1096) ignores return value by poolManager.unlock(abi.encode(UnlockAction.REDEEM,uint32(0),orderId)) (src/KesselHook.sol#1095)
KesselHook._poolPoint() (src/KesselHook.sol#1235-1244) ignores return value by (sqrtPriceX96,tick,None,None) = poolManager.getSlot0(poolId) (src/KesselHook.sol#1236)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#unused-return
INFO:Detectors:
Detector: events-access
KesselHook.setGovernance(address) (src/KesselHook.sol#1481-1485) should emit an event for: 
	- governance = newGovernance (src/KesselHook.sol#1484) 
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#missing-events-access-control
INFO:Detectors:
Detector: missing-zero-check
KesselHook.constructor(IPoolManager,Currency,Currency,int24,address)._governance (src/KesselHook.sol#212) lacks a zero-check on :
		- governance = _governance (src/KesselHook.sol#217)
KesselHook.setGovernance(address).newGovernance (src/KesselHook.sol#1482) lacks a zero-check on :
		- governance = newGovernance (src/KesselHook.sol#1484)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#missing-zero-address-validation
INFO:Detectors:
Detector: reentrancy-benign
Reentrancy in KesselHook._openSlowOrder(PoolKey,SwapParams,address,uint128,uint32) (src/KesselHook.sol#326-365):
	External calls:
	- specified.take(poolManager,address(this),amountIn256,true) (src/KesselHook.sol#356)
	State variables written after the call(s):
	- orderId = _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#358)
		- epoch = ++ currentEpoch (src/KesselHook.sol#1362)
	- orderId = _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#358)
		- epochOrderIds[epoch].push(orderId) (src/KesselHook.sol#398)
	- orderId = _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#358)
		- epochs[epoch].openedAtBlock = uint64(block.number) (src/KesselHook.sol#1365)
	- orderId = _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#358)
		- orderId = nextOrderId ++ (src/KesselHook.sol#386)
	- orderId = _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#358)
		- orders[orderId] = Order({trader:trader,zeroForOne:zeroForOne,amountInRemaining:amountIn,owedOut:0,limitPriceX96:uint160(limit),epochSubmitted:epoch,epochExpiry:expiry,status:OrderStatus.PENDING}) (src/KesselHook.sol#388-397)
Reentrancy in KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1111)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1112)
	State variables written after the call(s):
	- warehoused0 -= remaining (src/KesselHook.sol#1124)
	- warehoused1 -= remaining (src/KesselHook.sol#1125)
Reentrancy in KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1111)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1112)
	- inCurrency.settle(poolManager,address(this),refund,true) (src/KesselHook.sol#1127)
	- poolManager.take(inCurrency,o.trader,refund) (src/KesselHook.sol#1128)
	State variables written after the call(s):
	- lpClaimable0 += forfeit (src/KesselHook.sol#1132)
	- lpClaimable1 += forfeit (src/KesselHook.sol#1133)
Reentrancy in KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1021-1044):
	External calls:
	- poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1028-1043)
	State variables written after the call(s):
	- lpClaimable0 += fee0 (src/KesselHook.sol#1036)
	- lpClaimable1 += fee1 (src/KesselHook.sol#1040)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-3
INFO:Detectors:
Detector: reentrancy-events
Reentrancy in KesselHook._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes) (src/KesselHook.sol#421-454):
	External calls:
	- this.settleFromCallback(epoch) (src/KesselHook.sol#447-450)
	Event emitted after the call(s):
	- KesselEvents.SettlementSkipped(epoch) (src/KesselHook.sol#449)
Reentrancy in KesselHook._openSlowOrder(PoolKey,SwapParams,address,uint128,uint32) (src/KesselHook.sol#326-365):
	External calls:
	- specified.take(poolManager,address(this),amountIn256,true) (src/KesselHook.sol#356)
	Event emitted after the call(s):
	- KesselEvents.LaneChosen(trader,Lane.SLOW) (src/KesselHook.sol#400)
		- orderId = _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#358)
	- KesselEvents.SlowOrderSubmitted(orderId,trader,epoch,zeroForOne,amountIn,minOut,expiry) (src/KesselHook.sol#401)
		- orderId = _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#358)
Reentrancy in KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1111)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1112)
	Event emitted after the call(s):
	- KesselEvents.SlowOrderRedeemed(orderId,o.trader,out) (src/KesselHook.sol#1113)
Reentrancy in KesselHook._payoutOrder(uint256) (src/KesselHook.sol#1100-1143):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1111)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1112)
	- inCurrency.settle(poolManager,address(this),refund,true) (src/KesselHook.sol#1127)
	- poolManager.take(inCurrency,o.trader,refund) (src/KesselHook.sol#1128)
	Event emitted after the call(s):
	- KesselEvents.SlowOrderRefunded(orderId,o.trader,refund,forfeit) (src/KesselHook.sol#1137)
Reentrancy in KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1021-1044):
	External calls:
	- poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1028-1043)
	- currency0.settle(poolManager,address(this),fee0,true) (src/KesselHook.sol#1029)
	- currency1.settle(poolManager,address(this),fee1,true) (src/KesselHook.sol#1030)
	Event emitted after the call(s):
	- KesselEvents.RecaptureDonated(fee0,fee1) (src/KesselHook.sol#1031)
Reentrancy in KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1021-1044):
	External calls:
	- poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1028-1043)
	Event emitted after the call(s):
	- KesselEvents.RecaptureDeferred(Currency.unwrap(currency0),fee0) (src/KesselHook.sol#1037)
	- KesselEvents.RecaptureDeferred(Currency.unwrap(currency1),fee1) (src/KesselHook.sol#1041)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-4
INFO:Detectors:
Detector: assembly
KesselHook._position(int24) (src/KesselHook.sol#1339-1346) uses assembly
	- INLINE ASM (src/KesselHook.sol#1342-1345)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#assembly-usage
INFO:Detectors:
Detector: redundant-statements
Redundant expression "orderId (src/KesselHook.sol#363)" inKesselHook (src/KesselHook.sol#71-1523)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#redundant-statements
INFO:Slither:. analyzed (39 contracts with 99 detectors), 25 result(s) found
```

## Raw output — after fixes

```
'forge clean' running (wd: /home/lenovo/Kessel)
'forge config --json' running
'forge build --build-info --deny never --skip ./test/** ./script/** --force' running (wd: /home/lenovo/Kessel)

Detector: reentrancy-no-eth
Reentrancy in KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1140)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1141)
	State variables written after the call(s):
	- o.amountInRemaining = 0 (src/KesselHook.sol#1148)
	KesselHook.orders (src/KesselHook.sol#160) can be used in cross function reentrancies:
	- KesselHook._advanceIfDrained(uint32) (src/KesselHook.sol#1408-1428)
	- KesselHook._applyFills(uint32,KesselHook.Cand[],KesselHook.Pots) (src/KesselHook.sol#940-1005)
	- KesselHook._loadCandidates(uint32) (src/KesselHook.sol#599-630)
	- KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180)
	- KesselHook._recordOrder(address,bool,uint128,uint128,uint32) (src/KesselHook.sol#383-416)
	- KesselHook._rollUnfilled(uint32) (src/KesselHook.sol#766-803)
	- KesselHook.orders (src/KesselHook.sol#160)
	- KesselHook.redeem(uint256) (src/KesselHook.sol#1097-1110)
	- o.status = OrderStatus.REDEEMED (src/KesselHook.sol#1179)
	KesselHook.orders (src/KesselHook.sol#160) can be used in cross function reentrancies:
	- KesselHook._advanceIfDrained(uint32) (src/KesselHook.sol#1408-1428)
	- KesselHook._applyFills(uint32,KesselHook.Cand[],KesselHook.Pots) (src/KesselHook.sol#940-1005)
	- KesselHook._loadCandidates(uint32) (src/KesselHook.sol#599-630)
	- KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180)
	- KesselHook._recordOrder(address,bool,uint128,uint128,uint32) (src/KesselHook.sol#383-416)
	- KesselHook._rollUnfilled(uint32) (src/KesselHook.sol#766-803)
	- KesselHook.orders (src/KesselHook.sol#160)
	- KesselHook.redeem(uint256) (src/KesselHook.sol#1097-1110)
Reentrancy in KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1140)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1141)
	- inCurrency.settle(poolManager,address(this),refund,true) (src/KesselHook.sol#1156)
	- poolManager.take(inCurrency,o.trader,refund) (src/KesselHook.sol#1157)
	State variables written after the call(s):
	- o.status = OrderStatus.REFUNDED (src/KesselHook.sol#1165)
	KesselHook.orders (src/KesselHook.sol#160) can be used in cross function reentrancies:
	- KesselHook._advanceIfDrained(uint32) (src/KesselHook.sol#1408-1428)
	- KesselHook._applyFills(uint32,KesselHook.Cand[],KesselHook.Pots) (src/KesselHook.sol#940-1005)
	- KesselHook._loadCandidates(uint32) (src/KesselHook.sol#599-630)
	- KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180)
	- KesselHook._recordOrder(address,bool,uint128,uint128,uint32) (src/KesselHook.sol#383-416)
	- KesselHook._rollUnfilled(uint32) (src/KesselHook.sol#766-803)
	- KesselHook.orders (src/KesselHook.sol#160)
	- KesselHook.redeem(uint256) (src/KesselHook.sol#1097-1110)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-2

Detector: uninitialized-local
KesselHook._executeAndDistribute(uint32,KesselHook.Cand[],Clearing.Solution,uint256,uint256).p (src/KesselHook.sol#734) is a local variable never initialized
KesselHook._loadCandidates(uint32).n (src/KesselHook.sol#606) is a local variable never initialized
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#uninitialized-local-variables

Detector: unused-return
KesselHook._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes) (src/KesselHook.sol#435-468) ignores return value by (lane,None,None,None) = LaneCodec.decode(hookData,address(0)) (src/KesselHook.sol#444)
KesselHook.forceSettle() (src/KesselHook.sol#497-504) ignores return value by poolManager.unlock(abi.encode(UnlockAction.SETTLE,epoch,uint256(0))) (src/KesselHook.sol#503)
KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1035-1058) ignores return value by poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1042-1057)
KesselHook.sweepRecapture() (src/KesselHook.sol#1066-1069) ignores return value by poolManager.unlock(abi.encode(UnlockAction.SWEEP,uint32(0),uint256(0))) (src/KesselHook.sol#1068)
KesselHook.redeem(uint256) (src/KesselHook.sol#1097-1110) ignores return value by poolManager.unlock(abi.encode(UnlockAction.REDEEM,uint32(0),orderId)) (src/KesselHook.sol#1109)
KesselHook._poolPoint() (src/KesselHook.sol#1272-1281) ignores return value by (sqrtPriceX96,tick,None,None) = poolManager.getSlot0(poolId) (src/KesselHook.sol#1273)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#unused-return

Detector: reentrancy-benign
Reentrancy in KesselHook._openSlowOrder(PoolKey,SwapParams,address,uint128,uint32) (src/KesselHook.sol#340-379):
	External calls:
	- specified.take(poolManager,address(this),amountIn256,true) (src/KesselHook.sol#370)
	State variables written after the call(s):
	- _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#373)
		- epoch = ++ currentEpoch (src/KesselHook.sol#1399)
	- _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#373)
		- epochOrderIds[epoch].push(orderId) (src/KesselHook.sol#412)
	- _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#373)
		- epochs[epoch].openedAtBlock = uint64(block.number) (src/KesselHook.sol#1402)
	- _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#373)
		- orderId = nextOrderId ++ (src/KesselHook.sol#400)
	- _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#373)
		- orders[orderId] = Order({trader:trader,zeroForOne:zeroForOne,amountInRemaining:amountIn,owedOut:0,limitPriceX96:uint160(limit),epochSubmitted:epoch,epochExpiry:expiry,status:OrderStatus.PENDING}) (src/KesselHook.sol#402-411)
Reentrancy in KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1140)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1141)
	State variables written after the call(s):
	- warehoused0 -= remaining (src/KesselHook.sol#1153)
	- warehoused1 -= remaining (src/KesselHook.sol#1154)
Reentrancy in KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1140)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1141)
	- inCurrency.settle(poolManager,address(this),refund,true) (src/KesselHook.sol#1156)
	- poolManager.take(inCurrency,o.trader,refund) (src/KesselHook.sol#1157)
	State variables written after the call(s):
	- lpClaimable0 += forfeit (src/KesselHook.sol#1161)
	- lpClaimable1 += forfeit (src/KesselHook.sol#1162)
Reentrancy in KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1035-1058):
	External calls:
	- poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1042-1057)
	State variables written after the call(s):
	- lpClaimable0 += fee0 (src/KesselHook.sol#1050)
	- lpClaimable1 += fee1 (src/KesselHook.sol#1054)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-3

Detector: reentrancy-events
Reentrancy in KesselHook._afterSwap(address,PoolKey,SwapParams,BalanceDelta,bytes) (src/KesselHook.sol#435-468):
	External calls:
	- this.settleFromCallback(epoch) (src/KesselHook.sol#461-464)
	Event emitted after the call(s):
	- KesselEvents.SettlementSkipped(epoch) (src/KesselHook.sol#463)
Reentrancy in KesselHook._openSlowOrder(PoolKey,SwapParams,address,uint128,uint32) (src/KesselHook.sol#340-379):
	External calls:
	- specified.take(poolManager,address(this),amountIn256,true) (src/KesselHook.sol#370)
	Event emitted after the call(s):
	- KesselEvents.LaneChosen(trader,Lane.SLOW) (src/KesselHook.sol#414)
		- _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#373)
	- KesselEvents.SlowOrderSubmitted(orderId,trader,epoch,zeroForOne,amountIn,minOut,expiry) (src/KesselHook.sol#415)
		- _recordOrder(trader,zeroForOne,amountIn,minOut,expiryEpochs) (src/KesselHook.sol#373)
Reentrancy in KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1140)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1141)
	Event emitted after the call(s):
	- KesselEvents.SlowOrderRedeemed(orderId,o.trader,out) (src/KesselHook.sol#1142)
Reentrancy in KesselHook._payoutOrderInner(uint256) (src/KesselHook.sol#1129-1180):
	External calls:
	- outCurrency.settle(poolManager,address(this),out,true) (src/KesselHook.sol#1140)
	- poolManager.take(outCurrency,o.trader,out) (src/KesselHook.sol#1141)
	- inCurrency.settle(poolManager,address(this),refund,true) (src/KesselHook.sol#1156)
	- poolManager.take(inCurrency,o.trader,refund) (src/KesselHook.sol#1157)
	Event emitted after the call(s):
	- KesselEvents.SlowOrderRefunded(orderId,o.trader,refund,forfeit) (src/KesselHook.sol#1166)
Reentrancy in KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1035-1058):
	External calls:
	- poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1042-1057)
	- currency0.settle(poolManager,address(this),fee0,true) (src/KesselHook.sol#1043)
	- currency1.settle(poolManager,address(this),fee1,true) (src/KesselHook.sol#1044)
	Event emitted after the call(s):
	- KesselEvents.RecaptureDonated(fee0,fee1) (src/KesselHook.sol#1045)
Reentrancy in KesselHook._recapture(PoolKey,uint256,uint256) (src/KesselHook.sol#1035-1058):
	External calls:
	- poolManager.donate(key,fee0,fee1,) (src/KesselHook.sol#1042-1057)
	Event emitted after the call(s):
	- KesselEvents.RecaptureDeferred(Currency.unwrap(currency0),fee0) (src/KesselHook.sol#1051)
	- KesselEvents.RecaptureDeferred(Currency.unwrap(currency1),fee1) (src/KesselHook.sol#1055)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#reentrancy-vulnerabilities-4

Detector: assembly
KesselHook._position(int24) (src/KesselHook.sol#1376-1383) uses assembly
	- INLINE ASM (src/KesselHook.sol#1379-1382)
Reference: https://github.com/crytic/slither/wiki/Detector-Documentation#assembly-usage
. analyzed (39 contracts with 99 detectors), 21 result(s) found
```
