#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  Can this platform's miner build a block its own node accepts?
# ===========================================================================
#
#      bash scripts/test/test_platform_check.sh <dir-with-wamd-wam-cli-wam-miner>
#
#  THIS HASHES NOTHING, AND THAT IS THE POINT
#
#  It is safe to run anywhere, including on a hosted CI runner, because no
#  proof of work is computed and no coin is produced. `wam-miner --check`
#  builds one block from the node's live template and asks the node through
#  getblocktemplate proposal mode whether it is valid, then exits.
#
#  WHY IT EXISTS IN THIS FORM
#
#  The version of this that ran --solo mined two regtest blocks, which is a
#  stronger test and cost the project its GitHub account for a day: the repo,
#  every release download, raw.githubusercontent.com and wamcoin.org all
#  returned 404 to the public within the hour. The chain was worthless and the
#  intent was a correctness proof; neither is visible to an abuse detector,
#  and GitHub's terms forbid mining on their runners whatever the chain.
#
#  So the split is by what a machine can be seen to be doing:
#
#    CI, anywhere            --check      builds a block, hashes nothing
#    our own hardware        --solo       mines, and proves the whole path
#
#  WHAT --check ACTUALLY COVERS
#
#  Everything in a block except the proof of work: the coinbase, the BIP34
#  height push, the treasury output the consensus rule requires, the witness
#  commitment, the merkle root and the transactions. Both bugs found in the
#  solo path on Linux -- a wrong height encoding and a byte-reversed RandomX
#  seed -- were caught by --check before any hash was computed. What it does
#  not cover is hashing and submission, and that is what the run on our own
#  hardware is for.
# ===========================================================================

set -uo pipefail

BIN="${1:-}"
[ -n "$BIN" ] || { echo "usage: $0 <dir with wamd, wam-cli and wam-miner>"; exit 2; }
BIN="$(cd "$BIN" && pwd)"

GRN=$'\033[32m'; RED=$'\033[31m'; BLD=$'\033[1m'; OFF=$'\033[0m'

EXE=""
[ -x "$BIN/wamd.exe" ] && EXE=".exe"
WAMD="$BIN/wamd$EXE"; CLI="$BIN/wam-cli$EXE"; MINER="$BIN/wam-miner$EXE"

for f in "$WAMD" "$CLI" "$MINER"; do
    [ -f "$f" ] || { echo "${RED}missing: $f${OFF}"; exit 2; }
done

DATADIR="$(mktemp -d 2>/dev/null || mktemp -d -t wamchk)/regtest-check"
mkdir -p "$DATADIR"

cleanup() {
    if [ -n "${NODE_PID:-}" ]; then
        "$CLI" -regtest -datadir="$DATADIR" stop >/dev/null 2>&1
        for _ in $(seq 1 30); do kill -0 "$NODE_PID" 2>/dev/null || break; sleep 0.5; done
        kill -9 "$NODE_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

fails=0
ok()  { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; fails=$((fails + 1)); }

printf '\n%sthe miner builds a valid block on this platform%s\n' "$BLD" "$OFF"
printf '  binaries  %s\n\n' "$BIN"

# The vectors first. A miner whose RandomX disagrees with the network hashes
# all day, finds nothing, and reports no error -- and --self-test computes a
# handful of hashes against known answers, which is not mining by any reading.
if "$MINER" --self-test --no-colour >/dev/null 2>&1; then
    ok "the miner's RandomX and SHA-256 match the published vectors"
else
    bad "the miner failed its own self-test"
    exit 1
fi

"$WAMD" -regtest -datadir="$DATADIR" -server=1 -listen=0 -printtoconsole=0 \
        -fallbackfee=0.0001 >/dev/null 2>&1 &
NODE_PID=$!

ready=""
for _ in $(seq 1 120); do
    "$CLI" -regtest -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1 && { ready=1; break; }
    kill -0 "$NODE_PID" 2>/dev/null || break
    sleep 1
done
[ -n "$ready" ] || { bad "the node never answered RPC on regtest"; exit 1; }
ok "a regtest node is running and answering"

ADDR="$("$CLI" -regtest -datadir="$DATADIR" -named createwallet wallet_name=chk >/dev/null 2>&1; \
        "$CLI" -regtest -datadir="$DATADIR" -rpcwallet=chk getnewaddress 2>/dev/null)"
[ -n "$ADDR" ] || { bad "could not get a regtest address from the node"; exit 1; }
ok "a regtest address to build against: ${ADDR:0:12}..."

# No --rpc: the port follows --network, and that this works is part of what is
# being tested. It did not until 2026-09-24.
LOG="$DATADIR/check.log"
if "$MINER" --check -u "$ADDR" --network regtest --no-colour \
            --rpccookie "$DATADIR/regtest/.cookie" >"$LOG" 2>&1; then
    ok "--check: the node accepts the block this miner builds"
else
    bad "--check: the node REJECTED the block this miner builds"
    sed -e 's/\x1b\[[0-9;]*m//g' "$LOG" | tail -15 | sed 's/^/          /'
fi

printf '\n'
if [ "$fails" -gt 0 ]; then
    printf '  %s%d check(s) failed%s\n\n' "$RED" "$fails" "$OFF"
    exit 1
fi
printf '  %sthis platform builds a block its node accepts%s\n' "$GRN" "$OFF"
printf '  (hashing and submission are proved by test_platform_solo.sh, on our\n'
printf '   own hardware -- never on a hosted runner)\n\n'
