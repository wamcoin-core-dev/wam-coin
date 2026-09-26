#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  solo_gate.sh -- does the miner we ship still deliver a block it solves?
# ===========================================================================
#
#      bash scripts/solo_gate.sh [dir-with-wamd-wam-cli-wam-miner]
#
#  WHY THIS EXISTS, AND WHY IT RUNS BY ITSELF
#
#  v0.1.10 was announced on every channel as the release that lets anybody
#  mine alone. The next morning the first person who tried it solved a real
#  block ninety-nine seconds in, and the miner threw it away: the job he had
#  been hashing had scrolled out of a list bounded by count while he was
#  still on it. Roughly two blocks in three were unsendable.
#
#  Nothing caught it, and the reason is exact. The build gate runs --check,
#  which builds a block and asks the node whether it WOULD be accepted. It
#  proves construction. It cannot prove delivery, and delivery was what broke.
#
#  test_platform_solo.sh has proved delivery since v0.1.10 -- mine two blocks
#  for real and require the node to accept both -- but it was run by hand, on
#  the day somebody remembered. A check that depends on being remembered is
#  not a guard. This is that script on a timer, against the binaries that are
#  actually installed, on hardware this project owns, so that a regression is
#  found by us within a day instead of by a miner losing money.
#
#  IT IS DELIBERATELY NOT RUN IN CI. Mining on a hosted build service is
#  against the terms of every one of them, and this project lost its
#  code-hosting account on 2026-09-24 finding that out.
#
#  WHAT IT LEAVES BEHIND
#
#  On failure, an ALARM file in the directory the ops panel already counts,
#  and a non-zero exit so systemd records the failure and wam-alert@ fires.
#  On success it removes its own alarm, because an alarm nobody clears is an
#  alarm everybody learns to ignore.
# ===========================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
BIN="${1:-/opt/wam-current-bin}"
ALARM_DIR="/var/lib/wam-reorg"
ALARM="$ALARM_DIR/ALARM-solo-gate.txt"
LOG="$(mktemp -t solo-gate-XXXXXX.log)"

trap 'rm -f "$LOG"' EXIT

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

if [ ! -x "$BIN/wam-miner" ]; then
    echo "solo_gate: no wam-miner in $BIN -- nothing to prove, and that is"
    echo "           not a pass. Point this at the installed binaries."
    exit 2
fi

# ---------------------------------------------------------------------------
# TWO QUESTIONS, BECAUSE ONE OF THEM WOULD HAVE MISSED WHAT HAPPENED.
#
# test_platform_solo.sh mines two real blocks and requires the node to accept
# both. It is the end-to-end proof, and it would NOT have caught the defect
# of 2026-09-26: on regtest a block is solved in under a second, so the job
# never grows old enough to be forgotten. A gate that cannot fail on the bug
# it was written for is decoration.
#
# So the job bookkeeping is proved separately and deterministically, against a
# real node but without hashing: poll many times with nothing happening and
# the job must survive; move the tip and the job behind it must still be
# submittable. That is the failure, reproduced in a second, every day.
# ---------------------------------------------------------------------------
rc=0

{
    # WHAT EACH HALF ACTUALLY WATCHES, said plainly so nobody reads more
    # into a green line than it means:
    #
    #   1 is built from THIS CHECKOUT's sources. It stops the defect class
    #     coming back into the code, and it is the half that can fail on it.
    #   2 runs the INSTALLED binaries. It proves what people actually run can
    #     still mine and deliver -- but on regtest a block is solved in under
    #     a second, so it cannot see a job-ageing bug in a shipped build.
    #
    # Neither half can tell you that an already-released binary mishandles an
    # old job. Nothing run on this machine can. What covers that is in the
    # miner itself: it now counts blocks it failed to send apart from blocks
    # the node refused, says so on every status line, and exits non-zero.
    echo "=== 1. the job a worker holds must outlive the polling ==="
    if ! command -v g++ >/dev/null 2>&1; then
        echo "  !!  no g++ here, so the job test could not be built."
        echo "      That is NOT a pass: this is the half that catches the"
        echo "      2026-09-26 defect. Install g++ or run the gate elsewhere."
        rc=1
    else
        JOBDIR="$(mktemp -d -t solo-jobs-XXXXXX)"
        if ! g++ -std=c++17 -O1 -I"$HERE/miner/src" \
                 -o "$JOBDIR/solo_jobs" "$HERE/miner/test/solo_jobs_test.cpp" 2>&1; then
            echo "  FAIL  the job test would not compile"
            rc=1
        else
            RTDIR="$JOBDIR/regtest-home"
            mkdir -p "$RTDIR"
            printf 'regtest=1\n[regtest]\nrpcport=29554\nport=29555\nlisten=0\n' \
                > "$RTDIR/wam.conf"
            "$BIN/wamd" -datadir="$RTDIR" -daemon >/dev/null 2>&1
            for _ in $(seq 1 40); do
                [ -f "$RTDIR/regtest/.cookie" ] && break
                sleep 0.5
            done
            if "$JOBDIR/solo_jobs" 29554 "$RTDIR/regtest/.cookie"; then
                :
            else
                echo "  FAIL  a solved block could not have been delivered"
                rc=1
            fi
            "$BIN/wam-cli" -datadir="$RTDIR" -regtest stop >/dev/null 2>&1
            sleep 2
        fi
        rm -rf "$JOBDIR"
    fi

    echo
    echo "=== 2. mine two real blocks and have the node accept both ==="
    if ! bash "$HERE/scripts/test/test_platform_solo.sh" "$BIN"; then
        rc=1
    fi
} >"$LOG" 2>&1

cat "$LOG"

if [ "$rc" -eq 0 ]; then
    # Clear our own alarm, and only our own.
    [ -f "$ALARM" ] && rm -f "$ALARM"
    echo
    echo "solo_gate: the installed miner solved and DELIVERED blocks at $(stamp)"
    exit 0
fi

mkdir -p "$ALARM_DIR" 2>/dev/null
{
    echo "WAM solo mining gate FAILED at $(stamp)"
    echo
    echo "The installed miner at $BIN could not mine and deliver two blocks"
    echo "on a private regtest chain. Anybody mining alone with this build is"
    echo "burning electricity for blocks that may never reach a node."
    echo
    echo "Binaries: $BIN"
    echo "Checkout: $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null)"
    echo
    echo "--- the run ---"
    cat "$LOG"
} > "$ALARM" 2>/dev/null

echo
echo "solo_gate: FAILED -- alarm written to $ALARM"
exit 1
