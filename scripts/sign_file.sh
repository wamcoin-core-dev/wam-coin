#!/usr/bin/env bash
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  sign_file.sh -- detach-sign one file with the offline key
# ===========================================================================
#
#      bash scripts/sign_file.sh CHANNELS.txt [/d]
#
#  sign_release.sh does this for a whole release. This does it for a single
#  file, by the same rules, because the two files this project signs outside
#  a release -- CHANNELS.txt today, anything else tomorrow -- were being
#  signed by hand, and a hand-typed gpg command is where the wrong key gets
#  used.
#
#  WHY IT IS NOT JUST `gpg --detach-sign`
#
#  The secret key is not in the keyring on this machine and must never be.
#  It lives on a USB stick, and a bare gpg command therefore answers
#
#      gpg: no default secret key: No secret key
#
#  which reads like a broken installation and is the system working. This
#  script imports the key into a keyring created ON THE USB, signs, verifies
#  what it just wrote against the PUBLISHED key in a second throwaway
#  keyring, and destroys both. Nothing secret is ever written to this
#  computer's disk.
#
#  The verification at the end is not ceremony. A signature made by the wrong
#  key looks exactly like a good one to whoever made it; it fails only for
#  the stranger it was made for. So the check is done here, against
#  SIGNING-KEY.asc, which is the same file the stranger will use.
# ===========================================================================

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-}"
USB="${2:-/d}"
KEY="$USB/wam-secret-BACKUP.asc"

GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; BLD=$'\033[1m'; OFF=$'\033[0m'
ok()  { printf '  %sok%s    %s\n' "$GRN" "$OFF" "$1"; }
bad() { printf '  %sFAIL%s  %s\n' "$RED" "$OFF" "$1"; }
say() { printf '        %s\n' "$1"; }

printf '\n%ssigning one file with the offline key%s\n\n' "$BLD" "$OFF"

if [ -z "$TARGET" ]; then
    bad "which file? e.g. bash scripts/sign_file.sh CHANNELS.txt"
    echo; exit 2
fi
if [ ! -f "$TARGET" ]; then
    bad "$TARGET is not here. Are you in the repository?"
    say "cd $ROOT"
    echo; exit 2
fi

if [ ! -f "$KEY" ]; then
    bad "no key at $KEY"
    say "Is the USB plugged in? If it is not /d, pass its letter:"
    say "    bash scripts/sign_file.sh $TARGET /e"
    echo; exit 2
fi
ok "the key file is on the USB"

# The keyring is created on the USB and dies with this script, whatever
# happens to it -- including Ctrl-C, which is when a secret is likeliest to
# be left behind.
TMPHOME="$USB/.wam-sign-$$"
cleanup() {
    GNUPGHOME="$TMPHOME" gpgconf --kill all >/dev/null 2>&1
    rm -rf "$TMPHOME" "${VHOME:-}" 2>/dev/null
}
trap cleanup EXIT INT TERM

mkdir -p "$TMPHOME" || { bad "cannot create $TMPHOME -- is the USB writable?"; echo; exit 2; }
chmod 700 "$TMPHOME" 2>/dev/null
export GNUPGHOME="$TMPHOME"

if ! gpg --batch --quiet --import "$KEY" 2>/dev/null; then
    bad "the key would not import"
    say "Check that $KEY is the GPG secret key backup and not something else."
    echo; exit 2
fi

FPR="4BD4A8D3AFD43F5CBCB500E23798462FE00ADBA4"
if ! gpg --batch --with-colons --list-secret-keys 2>/dev/null | grep -q "$FPR"; then
    bad "the key on the USB is not the one this project publishes"
    say "This is either the wrong USB or the wrong key. Do not sign."
    echo; exit 2
fi
ok "the key on the USB is the fingerprint published in SECURITY.md"

printf '\n  %sGnuPG will now ask for the passphrase.%s\n' "$BLD" "$OFF"
printf '        It is yours. Nobody else needs it, ever.\n\n'

if ! gpg --detach-sign --armor --yes --output "$TARGET.asc" "$TARGET"; then
    bad "signing failed -- $TARGET.asc was not changed"
    echo; exit 2
fi
ok "wrote $TARGET.asc"

# Verify in a keyring that holds only the PUBLIC key -- the same one a
# stranger imports. A signature checked in the keyring that made it proves
# nothing about what anybody else will see.
VHOME="$(mktemp -d)"
chmod 700 "$VHOME"
gpg --homedir "$VHOME" --batch --quiet --import "$ROOT/SIGNING-KEY.asc" 2>/dev/null
if gpg --homedir "$VHOME" --verify "$TARGET.asc" "$TARGET" 2>&1 | grep -q "Good signature"; then
    ok "verified against the published key, as a stranger would"
    printf '\n  %s%s is signed%s\n\n' "$GRN" "$TARGET" "$OFF"
    exit 0
fi

bad "the signature does NOT verify against the published key"
say "Do not publish this. Something is wrong with the key or the file."
echo
exit 1
