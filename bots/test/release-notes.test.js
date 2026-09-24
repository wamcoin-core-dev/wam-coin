'use strict';
// Copyright (c) 2026 The WAM Coin developers
// Distributed under the MIT software license, see COPYING.
//
// ---------------------------------------------------------------------------
// The release announcement must not stop in the middle of a sentence, and it
// must not call a mainnet release testnet software.
//
// Both of these went out to every channel, automatically, on every release
// this project has published:
//
//   1. The body was cut with slice(0, 12). v0.1.9's announcement ended
//      "On 15 September there was no h" -- mid-word. v0.1.8's ended mid-word
//      too. A message that trails off reads as broken software, which is an
//      odd thing to advertise in the post announcing the software.
//
//   2. GitHub's "pre-release" flag means pre-1.0, and release.yml sets it for
//      every v0.x tag. The bot rendered it as "Pre-release -- testnet
//      software", which was true until 2026-09-15 and false from the moment
//      mainnet started. The flag never changed meaning; the chain did, and
//      the sentence did not follow it.
//
// Neither was found by a reader complaining. Both were found by reading what
// the bot would send before sending it, which is the only way either would
// have been found -- the bot does not think the message is wrong.
// ---------------------------------------------------------------------------

const assert = require('assert');
const A = require('../announce');

let pass = 0;
const fail = [];

function test(name, fn) {
    try { fn(); pass++; console.log(`  \x1b[32mok\x1b[0m    ${name}`); }
    catch (e) { fail.push(name); console.log(`  \x1b[31mFAIL\x1b[0m  ${name}\n        ${e.message}`); }
}

const para = (n, lines) => Array.from({ length: lines }, (_, i) => `p${n} line ${i + 1}`).join('\n');

console.log('\n=== the body is cut at a paragraph, never inside a sentence ===');

test('a short body is passed through whole', () => {
    const body = 'One paragraph.\n\nTwo paragraphs.';
    assert.strictEqual(A.headParagraphs(body, 12), body);
});

test('a paragraph that does not fit is left out, not cut', () => {
    // 4 + 1 + 4 = 9 fits; adding a third 4-line paragraph would be 14.
    const body = [para(1, 4), para(2, 4), para(3, 4)].join('\n\n');
    const out = A.headParagraphs(body, 12);
    assert.ok(out.includes('p1 line 4'), 'the first paragraph was cut short');
    assert.ok(out.includes('p2 line 4'), 'the second paragraph was cut short');
    assert.ok(!out.includes('p3 line 1'),
        'a paragraph that did not fit was included anyway');
});

test('when something is left out, the reader is told', () => {
    const body = [para(1, 6), para(2, 6), para(3, 6)].join('\n\n');
    const out = A.headParagraphs(body, 12);
    assert.ok(/Full notes at the link below\./.test(out),
        'the message trails off with no sign that there is more');
});

test('when nothing is left out, no such line is added', () => {
    const out = A.headParagraphs('Only this.', 12);
    assert.ok(!/Full notes/.test(out),
        'promised more notes when the whole body was included');
});

test('the real v0.1.9 body no longer ends mid-word', () => {
    // The first three lines of the published v0.1.9 notes, verbatim in shape:
    // a 3-line paragraph, then a 4-line one, then a long one that must not be
    // allowed to start.
    const body = [
        'This release sets nMinimumChainWork on mainnet. Until now it was zero,\n'
        + 'so a node installed today would follow whatever chain the first peer\n'
        + 'offered it, however cheaply that chain had been produced.',
        'It is not a consensus change and this release is not mandatory. A v0.1.8\n'
        + 'node accepts exactly the same blocks, stays on the same chain and needs\n'
        + 'no upgrade. The value decides only which header chains a node will\n'
        + 'consider while it is syncing.',
        'Why it was not set at launch, twice over. On 15 September there was no\n'
        + 'history to point at, and a fabricated floor would have been theatre.\n'
        + 'Then setting it on testnet on 7 September had stopped every new node\n'
        + 'syncing at all, which took two days to understand.'
    ].join('\n\n');

    const out = A.headParagraphs(body, 12);
    const last = out.trim().split('\n').pop().trim();
    assert.ok(/[.!?]$|link below\.$/.test(last),
        `the announcement ends on "${last}" -- not a finished sentence`);
    assert.ok(!/there was no$/.test(out.trim()),
        'the exact v0.1.9 truncation came back');
});

test('a single paragraph longer than the budget is cut at a line', () => {
    const out = A.headParagraphs(para(1, 30), 5);
    const lines = out.split('\n');
    assert.strictEqual(lines.length, 5, `got ${lines.length} lines`);
    assert.strictEqual(lines[4], 'p1 line 5', 'cut inside a line');
});

test('an empty body does not throw', () => {
    assert.strictEqual(A.headParagraphs('', 12), '');
});

console.log('\n=== a live chain is never announced as testnet software ===');

const rel = (extra) => A.releaseMessage(Object.assign({
    tag: 'v0.1.10', name: 'WAM Coin v0.1.10', url: 'https://example/r',
    body: 'Short notes.'
}, extra));

test('a pre-1.0 release does not call itself testnet software', () => {
    const out = rel({ prerelease: true });
    assert.ok(!/testnet/i.test(out),
        'the bot told every channel that a mainnet release is testnet software');
});

test('it does say it is pre-1.0, because that is what the flag means', () => {
    const out = rel({ prerelease: true });
    assert.ok(/Pre-1\.0/.test(out), `no pre-1.0 notice in:\n${out}`);
});

test('a 1.0 release carries no such line at all', () => {
    const out = rel({ prerelease: false });
    assert.ok(!/Pre-1\.0/.test(out) && !/testnet/i.test(out), out);
});

test('MANDATORY still rises above the title', () => {
    const out = rel({
        prerelease: true,
        body: 'MANDATORY: the treasury address moved.\n\nThe rest of the notes.'
    });
    assert.ok(out.startsWith('\u{26A0}\u{FE0F}'), 'the warning is not first');
    assert.ok(/UPDATE REQUIRED/.test(out));
    assert.ok(/treasury address moved/.test(out), 'the reason was dropped');
    assert.ok(out.indexOf('MANDATORY:') === -1,
        'the marker line was quoted back as well as acted on');
});

console.log(`\n  ${pass} passed, ${fail.length} failed`);
if (fail.length) { fail.forEach((f) => console.log(`    - ${f}`)); process.exit(1); }
