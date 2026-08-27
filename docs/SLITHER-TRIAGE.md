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
| 11 | `unused-return` — `poolManager.getSlot0` in `_poolPoint` | **False positive.** Only `sqrtPriceX96` and `tick` enter `Clearing.PoolPoint`; protocol/LP fee are irrelevant to the clearing solve. | — | — |
| 12 | `reentrancy-benign` / `reentrancy-events` (10 instances across `_payoutOrder`, `_recapture`, `_openSlowOrder`, `_afterSwap`) | **False positive.** These are event-ordering and non-state observations. The one state-write case that mattered is finding 1. | — | — |
| 13 | `assembly` — `_position` | **False positive.** Mirrors v4-core's own `TickBitmap.position`, verbatim and memory-safe. | — | — |

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
