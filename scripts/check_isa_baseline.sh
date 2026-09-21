#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  check_isa_baseline.sh -- will this binary run on the CPU someone has?
# ===========================================================================
#
#      bash scripts/check_isa_baseline.sh FILE [FILE...]
#      bash scripts/check_isa_baseline.sh out/release/wam-coin-*/bin/*
#
#  WHY THIS EXISTS
#
#  The v0.1.2 release was built by GitHub Actions, verified by the release
#  workflow, downloaded, checksum-matched, and started on a server -- where it
#  ran for ten minutes and then:
#
#      wamd.service: Main process exited, code=dumped, status=4/ILL
#
#  SIGILL. The binary carried 746 AVX-512 instructions, because RandomX was
#  built with ARCH=native and the node links it statically, so the node
#  inherited the instruction set of GitHub's runner. The machine it was sent
#  to is an AMD EPYC without AVX-512, which is most server CPUs before Genoa
#  and every consumer Intel before Ice Lake.
#
#  The release pipeline already tried to prevent this. It checked that the
#  node's own CXXFLAGS carried no -march=, which was true and beside the
#  point: the instructions came in through a linked library. It rebuilt
#  RandomX portably -- and gave that copy to the miner, not the node. Both
#  checks passed. The artifact crashed.
#
#  So this reads the shipped file. Not the flags that were meant to build it,
#  not the library it was meant to link: the instructions actually in it.
#
#  WHY AVX-512 IS THE LINE
#
#  AVX2 appears in every one of these binaries and always has, behind runtime
#  dispatch in libstdc++ and in Core's own SHA-NI selection -- code that asks
#  the CPU before it jumps. AVX-512 has never appeared in a working build and
#  appeared in exactly the one that crashed, from a library compiled to assume
#  it unconditionally. That is a line with a fact behind it rather than a
#  preference, which is the only kind worth failing a release over.
# ===========================================================================

set -uo pipefail

[ $# -ge 1 ] || {
    printf 'reason: no file was given\n'
    printf 'usage: %s FILE [FILE...]\n' "${0##*/}" >&2; exit 2; }

# The disassembler is named once. This script used to print
# "OBJDUMP=llvm-objdump (or run this on the machine that built it)" as the
# way to read a Mach-O binary, and then call `objdump` regardless -- advice
# that could be followed exactly and change nothing. If it tells you which
# tool to use, it has to be the tool it uses.
OBJDUMP="${OBJDUMP:-objdump}"
command -v "$OBJDUMP" >/dev/null 2>&1 || {
    printf 'reason: %s is not installed (apt-get install -y binutils)\n' "$OBJDUMP"
    printf '%s is required: apt-get install -y binutils\n' "$OBJDUMP" >&2; exit 2; }

# A second disassembler, because GNU objdump cannot open Mach-O at all.
#
# Without it the macOS half of every release went unexamined -- not failed,
# unexamined, which is worse: the summary said "could not check", and a line
# that says that on every run stops being read. It was amber from 12
# September, when macOS joined the release, until this.
ARM_OBJDUMP="${ARM_OBJDUMP:-}"
if [ -z "$ARM_OBJDUMP" ]; then
    for c in llvm-objdump llvm-objdump-18 llvm-objdump-17 llvm-objdump-16              llvm-objdump-15 llvm-objdump-14; do
        command -v "$c" >/dev/null 2>&1 && { ARM_OBJDUMP="$c"; break; }
    done
fi

# `file` decides which format each argument is, and a missing `file` used to
# mean every argument fell through the case below as "unknown" and was
# skipped in silence. On 12 September the Singapore seed had no `file`: this
# script examined nothing, said so, and exited 1 -- and its caller printed
# "the published binaries carry instructions many CPUs do not have" in red
# about a release whose five Linux binaries are clean. One absent 100 KB
# utility became a launch-stopping claim.
#
# Reading the magic bytes with od would remove the dependency altogether and
# is the better fix; three days before launch, this one says so instead.
command -v file >/dev/null 2>&1 || {
    printf 'reason: file(1) is not installed, so no format could be identified (apt-get install -y file)\n'
    printf 'file is required: apt-get install -y file\n' >&2; exit 2; }

GRN=$'\033[32m'; RED=$'\033[31m'; YLW=$'\033[33m'; OFF=$'\033[0m'
FAIL=0
CHECKED=0
ARM_CHECKED=0
ARM=0
UNREADABLE=0

echo "=================================================================="
echo " Instructions above the CPU baseline"
echo "=================================================================="
echo

# Two architectures, one table. The first column is what would crash a
# machine that lacks it; the second is wide SIMD that is in every build
# and always behind a runtime check, kept visible so the first column is
# read as the exception it is rather than as noise.
printf '  %-16s %-10s %-10s %s\n' "file" "above" "wide simd" "verdict"
printf '  %s\n' "--------------------------------------------------------------"

for f in "$@"; do
    [ -f "$f" ] || continue

    # Every executable format this project can ship, not only ELF.
    #
    # This line used to be `grep -q 'ELF...' || continue`, and that was written
    # when the only release was Linux. The moment a Windows or macOS binary
    # joins a release, a silent `continue` removes the one guard that exists
    # because a published node died with SIGILL on an AMD EPYC -- and removes
    # it for the audience most likely to be running an old processor. A skip
    # that reads as a pass is the exact shape of the fault it was written to
    # prevent.
    # -L follows symlinks. Without it `file` answers "symbolic link to ..."
    # and the case below skips it -- so pointing this at an installed path,
    # which is the obvious thing an operator does, reported "nothing was
    # examined" for a binary sitting right there. /opt/wam-current-bin/wamd
    # is a symlink on both servers.
    DESC="$(file -bL "$f" 2>/dev/null || echo unknown)"
    case "$DESC" in
        *ELF*executable*|*ELF*shared\ object*|*"for MS Windows"*|*PE32*|*Mach-O*) ;;
        *) continue ;;                 # scripts, tarballs, text: not our subject
    esac

    # arm64 is not an x86-64 question at all. Apple Silicon is the majority of
    # Macs sold since 2020, so this will be a real row rather than a
    # hypothetical one, and it must be visible: reporting an arm64 binary as
    # "within the x86-64 baseline" would be a confident answer to a question
    # nobody asked.
    # arm64 has its own floor, and it is the same story with different
    # letters. The v0.1.2 crash was RandomX built with ARCH=native on a
    # runner whose CPU had AVX-512; build the macOS half on an M2 with
    # -mcpu=native and it emits BF16 and I8MM, which an M1 does not have, and
    # the binary dies on the machines most WAM users on macOS actually own.
    #
    # The line, and the fact behind each part of it:
    #
    #   SVE / SVE2   no Apple Silicon implements it at all, at any generation.
    #                Its appearance means the build targeted a server ARM
    #                chip and cannot run on a Mac.
    #   BF16, I8MM   ARMv8.6. The M2 has them, the M1 does not. This is the
    #                exact analogue of AVX-512: present on the builder,
    #                absent on the user.
    #
    # NEON is not on the list for the same reason AVX2 is not: it is in every
    # arm64 binary ever produced and every Apple Silicon Mac has it.
    case "$DESC" in
        *arm64*|*aarch64*|*"ARM64"*)
            if [ -z "$ARM_OBJDUMP" ]; then
                printf '  %-16s %-10s %-10s %sno llvm-objdump -- NOT examined%s\n' \
                    "$(basename "$f")" "-" "-" "$RED" "$OFF"
                ARM=$((ARM + 1))
                UNREADABLE=$((UNREADABLE + 1))
                continue
            fi

            AD="$("$ARM_OBJDUMP" -d --no-show-raw-insn "$f" 2>/dev/null)"
            if [ -z "$AD" ]; then
                printf '  %-16s %-10s %-10s %scould not disassemble -- NOT examined%s\n' \
                    "$(basename "$f")" "-" "-" "$RED" "$OFF"
                UNREADABLE=$((UNREADABLE + 1))
                continue
            fi
            ARM_CHECKED=$((ARM_CHECKED + 1))

            # NEON wears its lane count on the MNEMONIC here, not on the
            # register: Apple's disassembler writes "sli.2s v20, v19" where
            # the GNU one writes "sli v20.2s, v19.2s". Counting registers
            # reported 68 NEON lines in a binary that has 630,013 of them.
            NEON="$(printf '%s' "$AD" | awk '{print $2}' \
                    | grep -cE '^[a-z][a-z0-9_]*\.(2d|4s|8h|16b|2s|4h|8b)$')"

            # ONE PASS, AND A MATCH NEXT TO AN UNNAMED BYTE IS DATA.
            #
            # SVE is found by its registers, because several SVE mnemonics
            # also exist as NEON forms; BF16 and I8MM are unambiguous names.
            #
            # RandomX carries its JIT templates inside __text, so a linear
            # disassembly walks straight through them and invents
            # instructions out of constants. In the published v0.1.9 macOS
            # node that produced exactly one hit --
            #
            #     ldff1sh { z23.s }, p6/z, [sp, z5.s, uxtw]
            #
            # -- an SVE load, inside randomx::CompiledVm, with three
            # <unknown> lines four instructions above it. Apple Silicon has
            # no SVE at any generation, so no compiler emitted it. Taken at
            # face value it would have failed a sound release, which is the
            # one outcome worse than not checking at all.
            #
            # A compiler never emits a byte its own disassembler cannot
            # name, so an <unknown> within eight instructions means the
            # region is not code. The window is carried in a queue of at
            # most eight entries rather than a list of matches: the list
            # was passed to awk through -v, which died with "argument list
            # too long" on a binary with many hits -- and died into a pass.
            ARM_ABOVE=-1; ARM_DATA=-1
            eval "$(printf '%s' "$AD" | awk \
                'function flush(upto,   k) {
                     while (head <= tail && upto - line[head] > 8) {
                         if (isdata[head]) data++; else real++
                         delete line[head]; delete isdata[head]; head++ } }
                 BEGIN { head = 1; tail = 0 }
                 /<unknown>/ { unk = NR
                               for (k = head; k <= tail; k++)
                                   if (NR - line[k] <= 8) isdata[k] = 1 }
                 # awk has no \b: it is a backspace here, not a word
                 # boundary. Written with \b these patterns matched nothing
                 # at all, in a check whose only job is to find something --
                 # so every binary passed, including one deliberately given
                 # an instruction it certainly contains.
                 $2 ~ /^(bfdot|bfmmla|bfcvt|bfcvtn|bfcvtn2|bfmlalb|bfmlalt|smmla|ummla|usmmla|sudot|usdot)(\.[0-9]*[bhsd])?$/ ||
                 $0 ~ /(^|[^a-zA-Z0-9_])z[0-9]+\.[bhsd]([^a-zA-Z0-9_]|$)/ ||
                 $0 ~ /(^|[^a-zA-Z0-9_])p[0-9]+\/[mz]([^a-zA-Z0-9_]|$)/ {
                     tail++; line[tail] = NR
                     isdata[tail] = (unk > 0 && NR - unk <= 8) ? 1 : 0 }
                 { flush(NR) }
                 END { for (k = head; k <= tail; k++)
                           if (isdata[k]) data++; else real++
                       printf "ARM_ABOVE=%d; ARM_DATA=%d", real + 0, data + 0 }')"

            # A check that cannot run must not pass. If awk produced
            # nothing -- killed, out of memory, argv too long -- these are
            # still the sentinels they were initialised to, and the file is
            # reported as not examined rather than as clean.
            if [ "$ARM_ABOVE" -lt 0 ] || [ "$ARM_DATA" -lt 0 ]; then
                printf '  %-16s %-10s %-10s %sthe scan did not complete -- NOT examined%s\n' \
                    "$(basename "$f")" "-" "-" "$RED" "$OFF"
                UNREADABLE=$((UNREADABLE + 1))
                ARM_CHECKED=$((ARM_CHECKED - 1))
                continue
            fi

            if [ "$ARM_ABOVE" -gt 0 ]; then
                printf '  %-16s %s%-10s%s %-10s %sWILL CRASH on an M1%s\n' \
                    "$(basename "$f")" "$RED" "$ARM_ABOVE" "$OFF" "$NEON" "$RED" "$OFF"
                printf '%s' "$AD" | grep -nE \
                    '\bz[0-9]+\.[bhsd]\b|\b(bfdot|bfmmla|smmla|usdot)\b' \
                    | head -2 | sed 's/^/                   /'
                FAIL=$((FAIL + 1))
            else
                printf '  %-16s %s%-10s%s %-10s runs on any Apple Silicon\n' \
                    "$(basename "$f")" "$GRN" "0" "$OFF" "$NEON"
                [ "$ARM_DATA" -gt 0 ] && printf \
                    '                   %s%d match(es) discarded as data, not code%s\n' \
                    "$YLW" "$ARM_DATA" "$OFF"
            fi
            continue ;;
    esac

    CHECKED=$((CHECKED + 1))

    D="$("$OBJDUMP" -d --no-show-raw-insn "$f" 2>/dev/null)"
    if [ -z "$D" ]; then
        # Not `continue`. CHECKED has already been incremented, so continuing
        # here counted an unreadable file towards "all N binaries stay within
        # the baseline" -- a pass issued for a binary that was never read.
        # True of a stripped ELF as much as of a Mach-O that GNU objdump
        # cannot open.
        printf '  %-16s %s%s%s\n' "$(basename "$f")" \
            "$RED" "could not disassemble -- NOT examined" "$OFF"
        UNREADABLE=$((UNREADABLE + 1))
        CHECKED=$((CHECKED - 1))
        continue
    fi

    # zmm registers and the k mask registers are unambiguous: nothing below
    # AVX-512 can name them.
    A512="$(printf '%s' "$D" | grep -cE '%zmm[0-9]+|\{%k[0-7]\}|vpternlog|vpcompress|vpexpand|\bkmov[bwdq]?\b')"
    A2="$(printf '%s' "$D" | grep -cE '%ymm[0-9]+')"

    if [ "$A512" -gt 0 ]; then
        printf '  %-16s %s%-10s%s %-10s %sWILL CRASH on a CPU without AVX-512%s\n' \
            "$(basename "$f")" "$RED" "$A512" "$OFF" "$A2" "$RED" "$OFF"
        printf '%s' "$D" | grep -nE '%zmm[0-9]+|vpternlog|\bkmov' | head -2 \
            | sed 's/^/                   /'
        FAIL=$((FAIL + 1))
    else
        printf '  %-16s %s%-10s%s %-10s runs on any x86-64\n' \
            "$(basename "$f")" "$GRN" "0" "$OFF" "$A2"
    fi
done

echo
echo "=================================================================="
if [ "$UNREADABLE" -gt 0 ]; then
    printf 'reason: %d binary(ies) could not be disassembled by %s\n' \
        "$UNREADABLE" "$OBJDUMP"
    printf ' %s%d binary(ies) could not be disassembled -- this check did not run%s\n' \
        "$RED" "$UNREADABLE" "$OFF"
    echo
    echo ' A pass cannot be issued for a file that was not read. GNU objdump'
    echo ' cannot open Mach-O; use the LLVM one on a macOS runner:'
    echo '     OBJDUMP=llvm-objdump  (or run this on the machine that built it)'
    echo "=================================================================="
    exit 2
fi
if [ "$CHECKED" -eq 0 ] && [ "$ARM_CHECKED" -eq 0 ] && [ "$ARM" -eq 0 ]; then
    # This exited 1, which every caller reads as "AVX-512 was found". It is
    # the opposite: nothing was opened, so nothing is known. The two are
    # indistinguishable in a summary and only one of them should stop a
    # release -- and the difference cost a FAIL on 12 September, when a
    # caller globbed a path that matched no file and this script told it the
    # published binaries were unrunnable.
    printf 'reason: no file matched, so no binary was examined\n'
    printf ' %sno binary was examined -- this proves nothing%s\n' "$RED" "$OFF"
    echo "=================================================================="
    exit 2
fi
if [ "$CHECKED" -eq 0 ] && [ "$ARM_CHECKED" -eq 0 ]; then
    printf 'reason: %d arm64 binary(ies) were seen and none could be read\n' "$ARM"
    printf ' %s%d arm64 binary(ies) and no disassembler for them%s\n' \
        "$YLW" "$ARM" "$OFF"
    echo
    echo ' Mach-O needs the LLVM disassembler; GNU objdump cannot open it.'
    echo '     apt-get install -y llvm   (or ARM_OBJDUMP=llvm-objdump)'
    echo "=================================================================="
    exit 2
fi
if [ "$FAIL" -eq 0 ]; then
    [ "$CHECKED" -gt 0 ] && printf ' %sall %d x86-64 binaries stay within the baseline%s\n' \
        "$GRN" "$CHECKED" "$OFF"
    [ "$ARM_CHECKED" -gt 0 ] && printf ' %sall %d arm64 binaries run on any Apple Silicon%s\n' \
        "$GRN" "$ARM_CHECKED" "$OFF"
else
    # Which floor was breached decides what to say and what to rebuild.
    # A single "carry AVX-512" line was wrong the moment arm64 could
    # fail too, and a wrong instruction in the remedy is worse than no
    # remedy: it sends whoever reads it to rebuild the wrong half.
    printf ' %s%d binary(ies) breach the floor -- do not publish%s\n' \
        "$RED" "$FAIL" "$OFF"
    echo
    echo ' RandomX was almost certainly built with ARCH=native, or the'
    echo ' node with -march=native / -mcpu=native. Rebuild portably and'
    echo ' relink:'
    echo '     x86-64   ARCH=x86-64      (AVX-512 is the line)'
    echo '     arm64    -mcpu=apple-m1   (BF16 and I8MM are the line)'
    echo ' See scripts/fetch-upstream.sh.'
fi
echo "=================================================================="
[ "$FAIL" -eq 0 ]
