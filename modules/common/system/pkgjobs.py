#!/usr/bin/env python3
"""pkgjobs.py -- what package jobs run right now, as raw records (PackageJobWatch reads them; PackageJobRules.js judges them).

One long-lived child of the shell. It reads /proc IN PROCESS, so it forks nothing, whatever the interval: a shell that polls does it by
forking, and this one does not (CLAUDE.md, "A SHELL THAT POLLS DOES IT BY FORKING"). It prints ONE JSON line when the picture changes (and one at
start), nothing while it stands still:

  { "lock": <db.lck exists>, "others": <a GUI package manager's daemon runs>, "procs": [
      { "pid", "comm", "argv": [...], "chain": [ppid, grandparent, ...], "cwd": "<path or null>" } ] }

procs are the processes whose comm is pacman, yay, paru or makepkg (any user: /proc/<pid>/cmdline of a root process is world-readable).
Judging them (which command lines are a transaction, whose job it is) is PackageJobRules.js's, so the rule lives in one place per language,
held to one table of cases (tools/dev/pm_transact_cases.txt).

  --proc DIR       /proc (a probe builds a fake tree: <pid>/comm, cmdline, stat, a cwd link)
  --lock FILE      /var/lib/pacman/db.lck
  --interval S     seconds between two looks (default 5)
"""
import json
import os
import sys
import time

WATCH = ("pacman", "yay", "paru", "makepkg")
OTHERS = ("pamac-daemon", "packagekitd")
CHAIN_MAX = 24


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def _ppid(proc, pid):
    raw = _read("%s/%d/stat" % (proc, pid))
    if raw is None:
        return 0
    # "pid (comm) S ppid ...": the comm may hold spaces and parentheses, so cut at the LAST ')'
    rest = raw.decode("utf-8", "replace").rsplit(")", 1)
    if len(rest) < 2:
        return 0
    fields = rest[1].split()
    try:
        return int(fields[1])
    except (IndexError, ValueError):
        return 0


def scan(proc, lock):
    procs = []
    others = False
    try:
        names = os.listdir(proc)
    except OSError:
        names = []
    for n in names:
        if not n.isdigit():
            continue
        raw = _read("%s/%s/comm" % (proc, n))
        if raw is None:
            continue
        comm = raw.decode("utf-8", "replace").strip()
        if comm in OTHERS:
            others = True
            continue
        if comm not in WATCH:
            continue
        pid = int(n)
        cmd = _read("%s/%s/cmdline" % (proc, n))
        if cmd is None:
            continue
        argv = [a.decode("utf-8", "replace").replace("\n", " ") for a in cmd.split(b"\0") if a != b""][:60]
        chain = []
        p = _ppid(proc, pid)
        while p > 1 and len(chain) < CHAIN_MAX:
            chain.append(p)
            p = _ppid(proc, p)
        try:
            cwd = os.readlink("%s/%s/cwd" % (proc, n))
        except OSError:
            cwd = None
        procs.append({"pid": pid, "comm": comm, "argv": argv, "chain": chain, "cwd": cwd})
    procs.sort(key=lambda e: e["pid"])
    return {"lock": os.path.exists(lock), "others": others, "procs": procs}


def main(argv):
    proc, lock, interval = "/proc", "/var/lib/pacman/db.lck", 5.0
    i = 0
    while i < len(argv):
        if argv[i] == "--proc" and i + 1 < len(argv):
            proc = argv[i + 1]
            i += 1
        elif argv[i] == "--lock" and i + 1 < len(argv):
            lock = argv[i + 1]
            i += 1
        elif argv[i] == "--interval" and i + 1 < len(argv):
            interval = float(argv[i + 1])
            i += 1
        i += 1
    last = None
    while True:
        snap = json.dumps(scan(proc, lock), sort_keys=True)
        if snap != last:
            sys.stdout.write(snap + "\n")
            sys.stdout.flush()
            last = snap
        time.sleep(interval)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (KeyboardInterrupt, BrokenPipeError):
        pass
