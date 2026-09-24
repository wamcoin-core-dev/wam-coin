# v0.1.10 — what is posted, and why it says what it says

Written 2026-09-24. Every figure in these files was measured at one moment,
`2026-09-24T10:12:57Z`, not recalled:

| | |
|---|---|
| height | 6,491 |
| difficulty | 0.008814 |
| network hash rate | 235,579 H/s over the last 720 blocks (~1 day) |
| peers | 50 |
| mined to miners | 308,322.50 WAM |
| circulating | 2,324,550 of a 22,000,000 cap (10.57%) |

**If these are sent more than a day or two later, re-measure first.** A stale
number in a public thread costs more than it saves, and two different dates
inside one message cost more still.

---

## The order, and who posts what

| | where | what |
|---|---|---|
| automatic | Telegram, Discord | **the bot**, the moment the tag is published. It reads `TAG_MESSAGE.txt` |
| 1 | Discord `#announcements` | `discord.txt`, four messages, **after** the bot's |
| 2 | Telegram | `telegram.txt`, two messages, after the bot's |
| 3 | BitcoinTalk | `bitcointalk.txt`, one post in the announcement thread |
| 4 | X | `x.txt`, post 1. Post 2 a day later, or not at all |

## TAG_MESSAGE.txt is not a draft — it is what the bot will say

`git tag -a v0.1.10 -F posts/v0.1.10/TAG_MESSAGE.txt`, after deleting
everything above the rule in that file.

`bots/announce.js` posts the **first whole paragraphs that fit in twelve
lines** to Telegram and Discord automatically, with nobody reviewing it in
between. So the first two paragraphs have to stand alone to a reader who sees
nothing else. What the bot would send was rendered and read before this was
committed rather than assumed:

```
🚀 WAM Coin v0.1.10
Pre-1.0 — the chain is live, the software is still young.

You can now mine WAM on your own machine against your own node, with no pool
at all. ...

Before you spend any electricity, wam-miner --check -u YOUR_ADDRESS ...

Full notes at the link below.
```

**Both of those lines were wrong until this release.** The bot cut the notes
at line twelve wherever that fell — every previous release was announced
mid-sentence, twice mid-word — and it rendered GitHub's pre-release flag as
"Pre-release — testnet software", which was true until 15 September and false
from the moment mainnet started.

## What these texts do and do not say

**No concentration figure, no 51%, no hash-rate share.** Not in any of the
four. The posts invite people to mine and say what the release does; the
concentration figure stays published permanently on the explorer, where
anyone can read it, which is a different thing from broadcasting it. An
invitation with a warning printed underneath is not an invitation.

**Solo mining leads in all four, and the pool is second.** That is the point
of the release. A release note that buried it under bug fixes would be
describing the work instead of offering it.

**The release is stated as NOT mandatory, in each one.** No consensus rule
changed and a v0.1.9 node validates identical blocks. Telling people to
upgrade urgently would spend the one warning that has to be believed later.

**The fee change is included, and is not dressed up.** v0.1.9's post said 0%,
so saying nothing would leave a published figure wrong. It is explained by
the arithmetic — nobody can undercut zero — and not as generosity.

**The three pools are named and were tested.** From two machines, minutes
before this was written. A fourth exists and is not listed: its port refused
connections from both. A miner sent to a dead endpoint comes back thinking
the alternatives were imaginary, which is worse than not mentioning it.

**Every bug is described with what it would have cost, not as a changelog
line.** "Fixed icon handling" tells a reader nothing. "Every Windows and
macOS build since v0.1.8 showed Bitcoin's logo on a wallet holding real
coins" tells him why he should install this one.

**The hash rate carries its window.** It roughly doubles between the quietest
hour of the night and the busiest of the morning, so the figure quoted is a
day's average and says so. A peak quoted as a level is a number that will
make the next honest measurement look like a collapse.

## x.txt has no numbers in it at all

An X post outlives its own facts and cannot be edited into truth later. Every
figure in these files moves, so none of them is in the one place where a
stale number is permanent.
