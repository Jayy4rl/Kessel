#!/usr/bin/env python3
"""A3 measurement: does the target chain order transactions by priority fee?

PRD §2.3 makes verifying A3 on the specific target chain a hard constraint, and
§15 scenario 10 asks for it against a real fork. The Solidity test cannot do the
fetching itself: `vm.rpc` hands back a JSON value ABI-encoded, so an object
result like `eth_getBlockByNumber` is not parseable on the Solidity side. This
script does the fetching and writes a summary the test asserts against.

The headline number is deliberately NOT a single ordered-pair share. Ordering on
an OP-Stack chain with sub-block building (Base's Flashblocks) is local: pairs
close together in the block are ordered by priority, distant ones are ordered by
arrival time. A single share averages those two regimes into a number that
describes neither, so the distance breakdown is the output that matters.

Usage:  BASE_RPC_URL=... python3 script/a3_ordering.py [blocks]
"""
import json, os, subprocess, sys, time
from collections import defaultdict

URL = os.environ.get("BASE_RPC_URL", "")
if not URL:
    sys.exit("BASE_RPC_URL is not set")
NBLOCKS = int(sys.argv[1]) if len(sys.argv) > 1 else 12
OUT = os.path.join(os.path.dirname(__file__), "..", "test", "fork", "data", "a3-ordering.json")
BUCKETS = [1, 2, 4, 8, 16, 32, 64, 128]


def rpc(method, *params):
    for attempt in range(5):
        r = subprocess.run(["cast", "rpc", method, *params, "--rpc-url", URL],
                           capture_output=True, text=True, timeout=60)
        if r.returncode == 0 and r.stdout.strip():
            try:
                return json.loads(r.stdout)
            except json.JSONDecodeError:
                return r.stdout.strip().strip('"')
        time.sleep(1.5 * (attempt + 1))
    return None


def bucket(d):
    for hi in BUCKETS:
        if d <= hi:
            return hi
    return 0  # 0 means "beyond the largest bucket"


head = int(rpc("eth_blockNumber"), 16)
start = head - NBLOCKS - 8  # step back so sampled blocks are certainly final
blocks, chain_id = [], int(rpc("eth_chainId"), 16)

for b in range(start, start + NBLOCKS):
    blk = rpc("eth_getBlockByNumber", hex(b), "true")
    if not blk:
        continue
    base = int(blk.get("baseFeePerGas", "0x0"), 16)
    # OP-Stack deposit transactions (type 0x7e) are system transactions: always
    # first, never carry a priority fee, and are not ordered economically.
    pr = [int(t["gasPrice"], 16) - base for t in blk["transactions"] if t.get("type") != "0x7e"]
    if len(pr) >= 2:
        blocks.append(pr)

by_dist = defaultdict(lambda: [0, 0])
total = ordered = 0
for pr in blocks:
    for i in range(len(pr)):
        for j in range(i + 1, len(pr)):
            ok = pr[i] >= pr[j]           # ties count as ordered: generous on purpose
            total += 1
            ordered += ok
            k = bucket(j - i)
            by_dist[k][1] += 1
            by_dist[k][0] += ok

result = {
    "chainId": chain_id,
    "headBlock": head,
    "firstBlock": start,
    "blocksSampled": len(blocks),
    "totalPairs": total,
    "orderedPairs": ordered,
    "orderedShareBps": (10000 * ordered // total) if total else 0,
    "adjacentShareBps": (10000 * by_dist[1][0] // by_dist[1][1]) if by_dist[1][1] else 0,
    "buckets": [
        {"maxDistance": k, "ordered": by_dist[k][0], "total": by_dist[k][1],
         "shareBps": 10000 * by_dist[k][0] // by_dist[k][1]}
        for k in BUCKETS if by_dist[k][1]
    ],
}

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")

print(f"chain {chain_id}, {len(blocks)} blocks from {start} (head {head})")
print(f"{'distance <=':>12} {'ordered/total':>22} {'share':>8}")
for e in result["buckets"]:
    print(f"{e['maxDistance']:>12} {e['ordered']:>10}/{e['total']:<11} {e['shareBps']/100:>7.2f}%")
print(f"\nall pairs: {ordered}/{total} = {result['orderedShareBps']/100}%")
print(f"adjacent : {result['adjacentShareBps']/100}%")
print(f"\nwrote {os.path.normpath(OUT)}")
