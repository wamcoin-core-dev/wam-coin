#!/usr/bin/env python3
# Copyright (c) 2026 The WAM Coin developers
# Distributed under the MIT software license, see COPYING.
#
# ===========================================================================
#  sweep_pool_fee.py -- move the operator's accrued fee out of the pool wallet
# ===========================================================================
#
#      python3 scripts/sweep_pool_fee.py --node HOST              # plan only
#      python3 scripts/sweep_pool_fee.py --node HOST --send       # actually do it
#
#  WHY THIS EXISTS
#
#  The pool's wallet holds two kinds of money that are not the same money:
#  coin owed to miners, and the operator's 1% that has been earned but never
#  taken out. On chain they are one balance. While they are mixed, nobody --
#  including the operator -- can answer the only question a miner really has:
#  does this pool hold enough to pay me?
#
#  Sweeping the fee to an address that receives nothing else makes the answer
#  a measurement. Whatever is left in the pool wallet is miners' money, and
#  scripts/check_pool.py compares it against what the pool says it owes.
#
#  WHAT IT REFUSES TO DO
#
#  This is the only tool in the repository that spends from the pool wallet,
#  so it is built to stop rather than to proceed:
#
#    * it sends nothing without --send. The default is a plan, printed.
#    * it refuses if the wallet would be left unable to cover what is owed.
#      The operator's fee is the last money out, never the first.
#    * it refuses an address that is not a valid mainnet address on this
#      chain, checked by the node rather than by a regular expression.
#    * it refuses if the accrued fee is below --min, because a sweep that
#      costs a transaction fee to move dust is a loss, not a tidy-up.
#    * it decrements the counter by exactly what was sent, after the node
#      returns a txid, so a failed send leaves the accrual untouched.
#
#  The counter lives in redis as <prefix>:poolfees and is written by
#  shareProcessor on every block. Nothing else moves it except an orphan,
#  which decrements it for the block that never counted.
# ===========================================================================

import argparse
import json
import subprocess
import sys

COIN = 100_000_000

GRN = "\033[32m"; RED = "\033[31m"; YEL = "\033[33m"; BLD = "\033[1m"; OFF = "\033[0m"


def die(msg, code=2):
    print(f"  {RED}{msg}{OFF}\n")
    sys.exit(code)


def rsh(host, cmd, timeout=90):
    p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                        f"root@{host}", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def wamcli(host, args, wallet=None):
    w = f"-rpcwallet={wallet} " if wallet else ""
    flags = "-chain=main -conf=/root/.wam-mainnet/wam.conf -datadir=/root/.wam-mainnet"
    rc, out, err = rsh(host, f"wam-cli {flags} {w}{args}")
    if rc != 0:
        die(f"wam-cli {args.split()[0]} failed: {err or out}")
    return out


def redis_cmd(host, args):
    """Run a redis command using the password from the pool's own config.

    The password is read on the far side and never crosses the wire or
    appears in any argument list here.
    """
    script = (
        'P=$(python3 -c \'import json;print(json.load('
        'open("/opt/wam/pool/config.json"))["redis"].get("password",""))\'); '
        f'redis-cli --no-auth-warning -a "$P" --raw {args}'
    )
    rc, out, err = rsh(host, script)
    if rc != 0:
        die(f"redis {args.split()[0]} failed: {err or out}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", required=True, help="ssh host running the pool and its node")
    ap.add_argument("--api", default="http://127.0.0.1:8080/api/stats")
    ap.add_argument("--prefix", default="wam", help="the pool's redis key prefix")
    ap.add_argument("--min", type=float, default=10.0,
                    help="do not sweep less than this many WAM")
    ap.add_argument("--send", action="store_true",
                    help="actually send. Without it this only prints the plan")
    args = ap.parse_args()

    print(f"\n{BLD}sweeping the operator fee out of the pool wallet{OFF}")

    # --- what is owed, and what has accrued ------------------------------
    rc, out, err = rsh(args.node, f"curl -s -m 10 {args.api}")
    if rc != 0 or not out:
        die("the pool API did not answer, so nothing here can be trusted")
    stats = json.loads(out)
    pool = stats.get("pool") or stats
    cfg = stats.get("config") or {}

    owed = pool.get("totalOwed", 0)
    accrued = pool.get("poolFeesCollected", 0)
    dest = cfg.get("poolFeeAddress")

    if not dest:
        die("no poolFeeAddress is configured on the pool. Set it in config.json "
            "first -- this tool will not invent a destination")

    # --- is the destination real, on this chain? --------------------------
    info = json.loads(wamcli(args.node, f'validateaddress "{dest}"'))
    if not info.get("isvalid"):
        die(f"{dest} is not a valid address on this chain")

    # A swept fee must not land back in the pool's own wallet: that would
    # move nothing and quietly zero the counter.
    if json.loads(wamcli(args.node, f'getaddressinfo "{dest}"')).get("ismine"):
        die(f"{dest} belongs to the pool's own wallet. Sweeping there separates "
            "nothing and would clear the accrual for no movement of coin")

    # --- can the wallet afford it? ----------------------------------------
    bal = json.loads(wamcli(args.node, "getbalances"))["mine"]
    spendable = round(float(bal["trusted"]) * COIN)
    immature = round(float(bal.get("immature", 0)) * COIN)

    print(f"  accrued fee        {accrued/COIN:.8f} WAM")
    print(f"  owed to miners     {owed/COIN:.8f} WAM")
    print(f"  wallet spendable   {spendable/COIN:.8f} WAM")
    print(f"  wallet maturing    {immature/COIN:.8f} WAM")
    print(f"  destination        {dest}")

    if accrued <= 0:
        print(f"\n  {YEL}nothing has accrued; nothing to do{OFF}\n")
        return 0

    if accrued < round(args.min * COIN):
        print(f"\n  {YEL}{accrued/COIN:.8f} WAM is below the {args.min:g} WAM floor. "
              f"Leave it to accumulate.{OFF}\n")
        return 0

    # The operator is paid last. If sending the fee would leave the wallet
    # unable to cover what miners are already owed, it does not go.
    left = spendable - accrued
    if left < owed:
        die(f"sending {accrued/COIN:.8f} WAM would leave {left/COIN:.8f} WAM "
            f"spendable against {owed/COIN:.8f} WAM owed to miners. The fee "
            f"waits until the wallet can cover both")

    print(f"\n  after it: {left/COIN:.8f} WAM spendable against {owed/COIN:.8f} owed, "
          f"{(left-owed)/COIN:.8f} WAM of room")

    if not args.send:
        print(f"\n  {YEL}plan only. Re-run with --send to move it.{OFF}\n")
        return 0

    # --- send, then decrement by exactly what was sent --------------------
    amount = f"{accrued/COIN:.8f}"
    txid = wamcli(args.node, f'sendtoaddress "{dest}" {amount}')
    if len(txid) != 64:
        die(f"sendtoaddress returned something that is not a txid: {txid!r}. "
            f"The counter has NOT been touched; check the wallet before retrying")

    # Only now. A crash before this leaves the accrual intact, which means a
    # second sweep sends the same fee again -- visible, recoverable, and far
    # better than a counter zeroed for coin that never moved.
    redis_cmd(args.node, f"DECRBY {args.prefix}:poolfees {accrued}")

    print(f"\n  {GRN}sent {amount} WAM{OFF}")
    print(f"  txid {txid}")
    print(f"\n  Record it. Every movement of this pool's money is written down "
          f"or it did not happen.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
