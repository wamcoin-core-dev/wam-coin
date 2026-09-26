#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
"""
Replace Bitcoin's user-visible wording in the Qt GUI with WAM's.

    python3 scripts/rebrand_qt.py --tree build/wam-core [--check]

WHY THIS IS A SCRIPT AND NOT A PATCH SET
----------------------------------------
Everywhere else in this project, upstream is modified through anchored
transformations in patch_upstream.py: one edit, one anchor, one reason. That
works because those edits are surgical.

This is not surgical. There are roughly ninety occurrences of "Bitcoin" in the
GUI's user-visible text, spread across twelve .ui files and a dozen sources,
and every one of them says the same thing for the same reason. Ninety anchors
would be ninety chances to drift out of date with upstream, to guard a change
nobody needs to read individually.

WHAT IT DOES NOT TOUCH
----------------------
Only text a user can read is rewritten:

  * the contents of <string> elements in .ui files
  * the contents of tr("...") and QT_TRANSLATE_NOOP("...", "...")
  * the BIP21 URI scheme, which must not stay "bitcoin:" -- a WAM payment QR
    code that a Bitcoin wallet offers to pay is a way to lose money

Identifiers keep their names. BitcoinUnits, BitcoinGUI, BitcoinAddressValidator
and the rest stay exactly as upstream wrote them, because renaming a class
changes no one's experience and guarantees a painful merge at the next release.
Comments are left alone for the same reason.

The script is idempotent: running it twice changes nothing the second time,
which is what lets the build call it unconditionally.
"""

import argparse
import re
import sys
from pathlib import Path

# Applied in order, inside user-visible strings only. Order matters: the URI
# forms have to be rewritten before the bare word, or "bitcoin://" becomes
# "WAM://" and stops being a scheme at all.
PHRASES = [
    ('bitcoin:BC1', 'wam:wam1'),
    ('bitcoin://', 'wam://'),
    ('bitcoin:', 'wam:'),
    ('the bitcoin network', 'the WAM network'),
    ('the Bitcoin network', 'the WAM network'),
    ('Bitcoin network', 'WAM network'),
    ('bitcoin network', 'WAM network'),
    ('Bitcoin address', 'WAM address'),
    ('bitcoin address', 'WAM address'),
    ('Bitcoin Core', 'WAM Coin'),
    ('spend bitcoins', 'spend WAM'),
    ('bitcoins', 'WAM'),
    ('Bitcoins', 'WAM'),
    # Shouting, which translators do in warnings. The Spanish wallet's
    # encrypt-wallet notice said "PERDERÁS TODOS TUS BITCOINS" -- and it
    # survived the first pass, because the table knew two capitalisations and
    # not the third. Found by reading the compiled catalogue rather than the
    # source, which is the only place it shows.
    ('BITCOINS', 'WAM'),
    ('BITCOIN', 'WAM'),
    ('Bitcoin', 'WAM'),
    # Last, and only ever inside a <string> element or a tr() call, so it can
    # never reach bitcoin.qrc, :/icons/bitcoin, or the BitcoinAmountField class.
    ('bitcoin', 'WAM'),
]

# The BIP21 scheme. Not user-visible text, but changing it is the whole point:
# a receive QR code carrying "bitcoin:wam1..." invites a Bitcoin wallet to try
# to pay it.
SCHEME_EDITS = [
    ('src/qt/guiutil.cpp',
     'uri.scheme() != QString("bitcoin")',
     'uri.scheme() != QString("wam")'),
    ('src/qt/guiutil.cpp',
     'QString ret = QString("bitcoin:%1")',
     'QString ret = QString("wam:%1")'),
    ('src/qt/paymentserver.cpp',
     'const QString BITCOIN_IPC_PREFIX("bitcoin:");',
     'const QString BITCOIN_IPC_PREFIX("wam:");'),

    # THE FIRST WINDOW A NEW USER EVER SEES, AND IT DESCRIBED ANOTHER CHAIN.
    #
    # The founder opened the first Windows build on 2026-09-26 and the welcome
    # dialog told him the program would download "the full Bitcoin block chain
    # (4 GB) starting with the earliest transactions in 2009", and warned that
    # the sync "is very demanding and may expose hardware problems". WAM's
    # chain is about five megabytes and eleven days old, and syncs in four
    # minutes.
    #
    # The chain's name is handled by the phrase table above. These two are
    # not text substitutions: the year is a number in the source, and the
    # warning is simply false here -- a sentence written for a 600 GB chain,
    # frightening people away from a download smaller than a photograph.
    ('src/qt/intro.cpp', '.arg(2009)', '.arg(2026)'),
    ('src/qt/forms/intro.ui',
     'This initial synchronisation is very demanding, and may expose hardware '
     'problems with your computer that had previously gone unnoticed. Each '
     'time you run %1, it will continue downloading where it left off.',
     'The whole chain is small and takes a few minutes on an ordinary '
     'machine. Each time you run %1, it continues where it left off.'),
]

# The content class is [^<]*, not .*?, and that is the whole safety argument.
# Qt .ui files contain self-closing <string/> elements. A dot-matches-newline
# pattern treats one of those as an opening tag and then runs to the *next*
# </string>, swallowing every element in between -- which on the first attempt
# rewrote <header>qt/bitcoinamountfield.h</header> into wamamountfield.h and a
# widget named openBitcoinConfButton into openWAMConfButton. The build stopped,
# which was lucky; a rename that still compiled would have been worse.
#
# Forbidding '<' in the content makes crossing an element boundary impossible:
# a self-closing tag simply finds no match.
UI_STRING = re.compile(r'(<string[^>]*>)([^<]*)(</string>)')
TR_CALL = re.compile(r'(\btr\(\s*")((?:[^"\\]|\\.)*)(")')
NOOP_CALL = re.compile(r'(QT_TRANSLATE_NOOP\(\s*"[^"]*"\s*,\s*")((?:[^"\\]|\\.)*)(")')

# THE TRANSLATIONS, WHICH ARE 123 FILES AND WERE SAYING BITCOIN IN ALL OF THEM.
#
# The English was rebranded from the first week. The catalogues under
# src/qt/locale were not, and every one of them ships inside the wallet. In
# Spanish -- the language of a man who has been running a node for this chain
# since August -- the first Windows build said:
#
#     Ingresa una dirección de Bitcoin (p. ej., %1)
#     Estas son tus direcciones de Bitcoin para enviar pagos
#
# So anybody whose system is not English saw another coin's name on every
# screen, and none of the checks could see it because they all read English.
#
# Both halves of each entry are rewritten, and that is deliberate. <source> is
# the LOOKUP KEY: Qt matches it against the literal in the C++, and the C++ has
# already been rebranded here. Rewriting the translation alone would leave the
# key spelling "Bitcoin", the lookup would miss, and every rebranded string
# would silently fall back to English -- a translation file that exists and
# does nothing. The same table is applied to both, so the two stay in step.
#
# <name> is untouched on purpose: those are C++ class names (BitcoinGUI,
# BitcoinAmountField), not words anybody reads.
TS_SOURCE = re.compile(r'(<source>)([^<]*)(</source>)')
TS_TRANSLATION = re.compile(r'(<translation[^>]*>)([^<]*)(</translation>)')
TS_NUMERUS = re.compile(r'(<numerusform>)([^<]*)(</numerusform>)')


# THE SPELLINGS A TABLE CANNOT LIST.
#
# The table above knows Bitcoin, bitcoin, Bitcoins, bitcoins, BITCOIN and
# BITCOINS. It does not know BİTCOİN -- Azerbaijani, with the Turkish dotted
# capital I, U+0130 -- which is how bitcoin_az.ts shouted at the reader that
# forgetting his passphrase would lose him BÜTÜN BİTCOİNLƏRİNİZİ.
#
# Chasing spellings one at a time is how the capital form was missed in the
# first pass and this one in the second. So the last step is a rule rather
# than a list: the word, in any case, with either dotted or dotless i in
# either position, and a trailing s or not.
#
# It is safe for the same reason the table is: rewrite() is only ever applied
# to the CONTENTS of a <string>, a <source>, a <translation>, a
# <numerusform> or a tr() call. It never sees a class name, an #include or a
# makefile variable.
BITCOIN_ANY = re.compile(r'[Bb][İIiı][Tt][Cc][Oo][İIiı][Nn][Ss]?')


def rewrite(text: str) -> str:
    for old, new in PHRASES:
        text = text.replace(old, new)
    return BITCOIN_ANY.sub('WAM', text)


def process_ui(path: Path) -> int:
    original = path.read_text(encoding='utf-8')
    changed = UI_STRING.sub(lambda m: m.group(1) + rewrite(m.group(2)) + m.group(3), original)
    if changed == original:
        return 0
    path.write_text(changed, encoding='utf-8')
    return sum(1 for _ in re.finditer('WAM', changed)) - sum(1 for _ in re.finditer('WAM', original))


def process_source(path: Path) -> int:
    original = path.read_text(encoding='utf-8')
    changed = original
    for pattern in (TR_CALL, NOOP_CALL):
        changed = pattern.sub(lambda m: m.group(1) + rewrite(m.group(2)) + m.group(3), changed)
    if changed == original:
        return 0
    path.write_text(changed, encoding='utf-8')
    return 1


def process_ts(path: Path) -> int:
    """One translation catalogue: the key and the translation, together."""
    original = path.read_text(encoding='utf-8')
    changed = original
    for pattern in (TS_SOURCE, TS_TRANSLATION, TS_NUMERUS):
        changed = pattern.sub(
            lambda m: m.group(1) + rewrite(m.group(2)) + m.group(3), changed)
    if changed == original:
        return 0
    path.write_text(changed, encoding='utf-8')
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--tree', required=True, help='path to the Bitcoin Core checkout')
    ap.add_argument('--check', action='store_true',
                    help='report what is left without changing anything')
    args = ap.parse_args()

    tree = Path(args.tree)
    qt = tree / 'src' / 'qt'
    if not qt.is_dir():
        print(f'error: no src/qt under {tree}', file=sys.stderr)
        return 2

    if args.check:
        stale = []
        for path in sorted(list(qt.glob('forms/*.ui')) + list(qt.glob('*.cpp'))):
            text = path.read_text(encoding='utf-8')
            hits = [m.group(2) for m in UI_STRING.finditer(text)] if path.suffix == '.ui' \
                else [m.group(2) for m in TR_CALL.finditer(text)]
            for hit in hits:
                if re.search(r'[Bb]itcoin', hit):
                    stale.append((path.name, hit[:70]))

        # AND THE TRANSLATIONS, WHICH ARE MOST OF WHAT A PERSON READS.
        #
        # This block read forms/*.ui and *.cpp and nothing else, so it would
        # have reported "no user-visible string says Bitcoin" while 123
        # catalogues inside the same wallet said exactly that in 123
        # languages. A check that looks only where the fault was already
        # fixed is not a check.
        #
        # <name> is skipped here as it is in the rewriting pass: class names.
        for path in sorted((qt / 'locale').glob('*.ts')):
            text = path.read_text(encoding='utf-8')
            for pattern in (TS_SOURCE, TS_TRANSLATION, TS_NUMERUS):
                for m in pattern.finditer(text):
                    if re.search(r'[Bb]itcoin', m.group(2), re.IGNORECASE):
                        stale.append((path.name, m.group(2)[:70]))
                        break

        if stale:
            print(f'{len(stale)} user-visible strings still say Bitcoin:')
            for name, hit in stale[:20]:
                print(f'  {name}: {hit}')
            return 1
        print('ok    no user-visible string in the GUI says Bitcoin')
        return 0

    touched = 0

    for path in sorted(qt.glob('forms/*.ui')):
        if process_ui(path):
            touched += 1
            print(f'  ui      {path.name}')

    for path in sorted(list(qt.glob('*.cpp')) + list(qt.glob('*.h'))):
        if process_source(path):
            touched += 1
            print(f'  source  {path.name}')

    # The catalogues. 123 of them ship inside the wallet, and until 2026-09-26
    # every one of them said Bitcoin -- see the comment on TS_SOURCE.
    locales = sorted((qt / 'locale').glob('*.ts'))
    changed_locales = 0
    for path in locales:
        if process_ts(path):
            changed_locales += 1
    if changed_locales:
        touched += changed_locales
        print(f'  locale  {changed_locales} of {len(locales)} translation file(s)')

    for rel, old, new in SCHEME_EDITS:
        path = tree / rel
        if not path.is_file():
            print(f'  warning: {rel} not found', file=sys.stderr)
            continue
        text = path.read_text(encoding='utf-8')
        if new in text:
            continue
        if old not in text:
            print(f'  warning: could not find the URI scheme in {rel}', file=sys.stderr)
            continue
        path.write_text(text.replace(old, new), encoding='utf-8')
        touched += 1
        print(f'  scheme  {rel}')

    print(f'\n{touched} files rewritten' if touched else '\nnothing to do; already rebranded')
    return 0


if __name__ == '__main__':
    sys.exit(main())
