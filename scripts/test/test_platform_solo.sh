#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  Does --solo actually mine, on THIS platform?
# ===========================================================================
#
#      bash scripts/test/test_platform_solo.sh <dir-with-wamd-wam-cli-wam-miner>
#
#  WHY THIS EXISTS
#
#  --solo and --check were written, proved on Linux over twenty-four regtest
#  blocks, and shipped in v0.1.10 to Windows and macOS where neither had ever
#  been run once. The whole point of the feature is that a person mines for
#  himself instead of joining a pool, and most of the people who would do
#  that are on Windows -- the platform it was least proved on.
#
#  test_platform_consensus.sh already answers "does this node agree with the
#  chain". It cannot answer this one: a node can be perfectly correct while
#  the miner beside it fails to build a block its own node will accept.
#
#  WHAT IS PROVED, AND WHY EACH STEP
#
#    --self-test        RandomX and SHA-256 against known vectors. A miner
#                       whose hashing disagrees with the network hashes all
#                       day, finds nothing and reports no error at all.
#
#    --check            builds a real block from the node's live template and
#                       asks the node whether it is valid. This is the step
#                       that covers the coinbase, the BIP34 height push, the
#                       treasury output, the witness commitment and the
#                       merkle root -- every part of a block except the proof
#                       of work. On Linux this is where a wrong height
#                       encoding and a byte-reversed RandomX seed were both
#                       caught.
#
#    --solo --blocks 2  end to end: hash, find, submit, and have the node
#                       accept. Twice, because the first block of a session
#                       can succeed through a path the second does not --
#                       template refresh after a submitted block is its own
#                       code.
#
#  Regtest, so nothing here touches a real chain, needs a peer, or spends a
#  minute waiting for difficulty. --blocks makes it deterministic: the miner
#  exits non-zero if it did not get what was asked for, so this script does
#  not have to read the log for a phrase that may be reworded later.
# ===========================================================================

set -uo pipefail

BIN="${1:-}"
[ -n "$BIN" ] || { echo "usage: $0 <dir with wamd, wam-cli and wam-miner>"; exit 2; }
BIN="$(cd "$BIN" && pwd)"

GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'

# Windows runners hand us .exe; Linux and macOS do not. One suffix, worked out
# once, rather than three copies of this script.
EXE=""
[ -x "$BIN/wamd.exe" ] && EXE=".exe"

WAMD="$BIN/wamd$EXE"
CLI="$BIN/wam-cli$EXE"
MINER="$BIN/wam-miner$EXE"

for f in "$WAMD" "$CLI" "$MINER"; do
    [ -f "$f" ] || { echo "${RED}missing: $f${OFF}"; exit 2; }
done

DATADIR="$(mktemp -d 2>/dev/null || mktemp -d -t wamsolo)/regtest-solo"
mkdir -p "$DATADIR"

# The node is a child of this script and must not outlive it, however this
# script ends. A leaked regtest node on a CI runner holds a port and the next
# job blames the wrong thing.
cleanup() {
    if [ -n "${NODE_PID:-}" ]; then
        "$CLI" -regtest -datadir="$DATADIR" stop >/dev/null 2>&1
        for _ in $(seq 1 30); do
            kill -0 "$NODE_PID" 2>/dev/null || break
            sleep 0.5
        done
        kill -9 "$NODE_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

fails=0
ok()   { printf '  %sok%s    %s\n'   "$GRN" "$OFF" "$1"; }
bad()  { printf '  %sFAIL%s  %s\n'   "$RED" "$OFF" "$1"; fails=$((fails + 1)); }
note() { printf '  %s!!%s    %s\n'   "$YEL" "$OFF" "$1"; }

printf '\n%s--solo on this platform%s\n' "$BLD" "$OFF"
printf '  binaries  %s\n' "$BIN"
printf '  datadir   %s\n\n' "$DATADIR"

# ---------------------------------------------------------------------------
# 1. The miner's own vectors, before anything else is believed.
# ---------------------------------------------------------------------------
if "$MINER" --self-test --no-colour >/dev/null 2>&1; then
    ok "the miner's RandomX and SHA-256 match the published vectors"
else
    bad "the miner failed its own self-test -- nothing below would mean anything"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. A regtest node, on its own, with RPC.
# ---------------------------------------------------------------------------
"$WAMD" -regtest -datadir="$DATADIR" -server=1 -listen=0 -printtoconsole=0 \
        -fallbackfee=0.0001 >/dev/null 2>&1 &
NODE_PID=$!

ready=""
for _ in $(seq 1 120); do
    if "$CLI" -regtest -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1; then
        ready=1; break
    fi
    kill -0 "$NODE_PID" 2>/dev/null || break
    sleep 1
done
if [ -z "$ready" ]; then
    bad "the node never answered RPC on regtest"
    exit 1
fi
ok "a regtest node is running and answering"

ADDR="$("$CLI" -regtest -datadir="$DATADIR" -named createwallet wallet_name=solo >/dev/null 2>&1; \
        "$CLI" -regtest -datadir="$DATADIR" -rpcwallet=solo getnewaddress 2>/dev/null)"
case "$ADDR" in
    wamrt1*|[mn2]*) ok "a regtest address to be paid at: ${ADDR:0:12}..." ;;
    *) bad "could not get a regtest address from the node (got '${ADDR:0:24}')"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 3. --check: is the block we would build actually valid?
# ---------------------------------------------------------------------------
CHECK_LOG="$DATADIR/check.log"
# No --rpc: the port follows --network, and that this works is part of what
# is being tested. It did not until 2026-09-24, when the miner reached for
# the mainnet port whatever chain it was told to mine.
if "$MINER" --check -u "$ADDR" --network regtest --no-colour \
            --rpccookie "$DATADIR/regtest/.cookie" \
            >"$CHECK_LOG" 2>&1; then
    ok "--check: the node accepts the block this miner builds"
else
    bad "--check: the node REJECTED the block this miner builds"
    sed -e 's/\x1b\[[0-9;]*m//g' "$CHECK_LOG" | tail -12 | sed 's/^/          /'
fi

# ---------------------------------------------------------------------------
# 4. --solo: hash, find, submit, accepted. Twice.
# ---------------------------------------------------------------------------
BEFORE="$("$CLI" -regtest -datadir="$DATADIR" getblockcount 2>/dev/null || echo 0)"
SOLO_LOG="$DATADIR/solo.log"

# One thread. Regtest difficulty is trivial and a hosted runner has few cores;
# more threads here buys nothing and makes the log harder to read.
if "$MINER" --solo -u "$ADDR" --network regtest --no-colour -t 1 --blocks 2 \
            --rpccookie "$DATADIR/regtest/.cookie" \
            >"$SOLO_LOG" 2>&1; then
    AFTER="$("$CLI" -regtest -datadir="$DATADIR" getblockcount 2>/dev/null || echo 0)"
    if [ "$AFTER" -ge $((BEFORE + 2)) ]; then
        ok "--solo mined 2 blocks and the node accepted both (height $BEFORE -> $AFTER)"
    else
        # The miner said it succeeded and the chain disagrees. That is worse
        # than a plain failure and must not be reported as a pass.
        bad "--solo reported success but the chain went $BEFORE -> $AFTER"
    fi

    # The reward must go where the miner was told, not to the node's wallet by
    # some other route. On regtest the coinbase is immature, so it is the
    # immature balance that carries it.
    BAL="$("$CLI" -regtest -datadir="$DATADIR" -rpcwallet=solo getbalances 2>/dev/null \
           | tr -d ' ,"' | grep -i immature | cut -d: -f2)"
    case "${BAL:-0}" in
        0|0.00000000|"") note "the wallet shows no immature balance yet (${BAL:-none})" ;;
        *) ok "the reward reached the address given: $BAL WAM immature" ;;
    esac
else
    bad "--solo did not get 2 accepted blocks on this platform"
    sed -e 's/\x1b\[[0-9;]*m//g' "$SOLO_LOG" | tail -20 | sed 's/^/          /'
fi

printf '\n'
if [ "$fails" -gt 0 ]; then
    printf '  %s%d check(s) failed -- --solo is not proved on this platform%s\n\n' \
           "$RED" "$fails" "$OFF"
    exit 1
fi
printf '  %s--solo works on this platform%s\n\n' "$GRN" "$OFF"
