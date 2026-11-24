#!/usr/bin/env python3
"""bridge_timeline.py -- what happened between the laptop and the phone, on ONE clock (read-only).

  tools/dev/bridge_timeline.py --since HH:MM[:SS] [--until HH:MM[:SS]] [--serial S] [--no-phone] [--all-watch]

Merges, sorted by the laptop's wall clock:
  phone   the phone's own log since --since (`adb exec-out logcat -d -b main,system,events -v epoch -T ...`): the lock screen
          (wm_set_keyguard_shown: display, SHOWN, aod, going away), the screen (screen_toggled), lock-screen gestures, the USB
          functions (UsbDeviceManager trySetEnabledFunctions), adbd's own start / transport lines, scrcpy's server and its displays.
          Shifted onto the laptop's clock by the offset measured with `adb shell date` (printed).
  adb     the laptop's adb server log (/tmp/adb.<uid>.log): a transport that went away and why.
  trace   the bridge's own trace (~/.cache/lares/bridge/trace.jsonl and .1): every cast event, every exec, call and unlock step;
          `watch` lines only where the current phone's adb state, link or PIN changed (all of them with --all-watch).

Nothing is written anywhere; the phone is only read (logcat -d is a dump of its buffer, which holds hours: no live recording is needed,
run this after the fact). The bridge's walkthrough recorder: reproduce, then run this with --since a minute before.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
TRACES = [os.path.join(HOME, ".cache/lares/bridge/trace.1.jsonl"), os.path.join(HOME, ".cache/lares/bridge/trace.jsonl")]
ADB_LOG = "/tmp/adb.%d.log" % os.getuid()

PHONE_KEEP = re.compile(
    r"wm_set_keyguard_shown|screen_toggled|sysui_lockscreen_gesture|power_sleep_requested|"
    r"UsbDeviceManager: USB trySetEnabledFunctions|"
    r" adbd *: (adbd started|adbd listening on tcp|.*connection terminated|Remote process closed)|"
    r" scrcpy *:|AndroidRuntime: Calling main entry com\.genymobile|"
    r"DisplayDeviceRepository: Display device (added|removed): DisplayDeviceInfo\{\"scrcpy\"")


def clock_of(s, day):
    """HH:MM[:SS] today -> epoch seconds."""
    parts = [int(x) for x in s.split(":")]
    while len(parts) < 3:
        parts.append(0)
    return dt.datetime(day.year, day.month, day.day, parts[0], parts[1], parts[2]).timestamp()


def stamp(t):
    return dt.datetime.fromtimestamp(t).strftime("%H:%M:%S.%f")[:-3]


def adb(serial, *args, timeout=60):
    return subprocess.run(["adb", "-s", serial] + list(args), capture_output=True, timeout=timeout)


def find_serial():
    try:
        out = subprocess.run(["adb", "devices"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    rows = [l.split("\t") for l in out.splitlines()[1:] if "\t" in l]
    live = [r[0] for r in rows if r[1].strip() == "device"]
    return live[0] if live else ""


def phone_offset(serial):
    """phone clock - laptop clock, in seconds (the midpoint of one `date` round trip; good to a few ms on Wi-Fi)."""
    best = None
    for _ in range(3):
        t0 = time.time()
        r = adb(serial, "shell", "date +%s.%N", timeout=10)
        t1 = time.time()
        try:
            ph = float(r.stdout.decode().strip())
        except ValueError:
            continue
        rtt = t1 - t0
        if best is None or rtt < best[1]:
            best = (ph - (t0 + t1) / 2, rtt)
    return best


def phone_rows(serial, since, until, off):
    since_ph = since + off
    t = dt.datetime.fromtimestamp(since_ph).strftime("%m-%d %H:%M:%S.000")
    r = adb(serial, "exec-out", "logcat", "-d", "-b", "main,system,events", "-v", "epoch", "-T", t, timeout=120)
    rows = []
    for line in r.stdout.decode("utf-8", "replace").splitlines():
        if not PHONE_KEEP.search(line):
            continue
        m = re.match(r"\s*(\d+\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.*)", line)
        if not m:
            continue
        tl = float(m.group(1)) - off
        if tl < since or tl > until:
            continue
        rows.append((tl, "phone", re.sub(r"\s+", " ", m.group(5))[:220]))
    return rows


def adb_rows(since, until, day):
    rows = []
    try:
        lines = open(ADB_LOG, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return rows
    for line in lines:
        if "Netlink: SUBSYSTEM not found" in line:
            continue
        m = re.match(r"(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+)\s+\d+\s+\d+\s+[VDIWEF]\s+(.*)", line)
        if not m:
            continue
        t = dt.datetime(day.year, int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)), int(m.group(5)),
                        int(m.group(6)[:3].ljust(3, "0")) * 1000).timestamp()
        if since <= t <= until:
            rows.append((t, "adb", re.sub(r"\s+", " ", m.group(7))[:220]))
    return rows


def trace_rows(since, until, all_watch):
    rows, prev = [], None
    for f in TRACES:
        try:
            lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        for l in lines:
            try:
                d = json.loads(l)
            except ValueError:
                continue
            t = d.get("t") or 0
            if not since <= t <= until:
                continue
            k = d.get("kind")
            if k == "watch":
                line = d.get("line") or {}
                cur = line.get("current")
                dev = next((x for x in line.get("devices", []) if x.get("key") == cur), None)
                if dev is None:
                    continue
                adbs = (dev.get("adb") or {}).get("state", "-")
                s = "watch link=%s adb=%s pin=%s" % (dev.get("link"), adbs, dev.get("pin"))
                if s == prev and not all_watch:
                    continue
                prev = s
                rows.append((t, "trace", s))
                continue
            body = {x: y for x, y in d.items() if x not in ("t", "kind", "pid")}
            if k == "exec":
                body = {"argv": " ".join(body.get("argv", []))[:120], "rc": body.get("rc"), "ms": body.get("ms")}
            if k == "call" and isinstance(body.get("answer"), dict):
                a = body["answer"]
                body["answer"] = {x: y for x, y in a.items() if x not in ("facts",)}
            rows.append((t, "trace", "%s %s" % (k, json.dumps(body, separators=(",", ":"))[:240])))
    return rows


def main():
    p = argparse.ArgumentParser(prog="bridge_timeline.py")
    p.add_argument("--since", required=True)
    p.add_argument("--until", default="")
    p.add_argument("--serial", default="")
    p.add_argument("--no-phone", action="store_true")
    p.add_argument("--all-watch", action="store_true")
    a = p.parse_args()
    day = dt.date.today()
    since = clock_of(a.since, day)
    until = clock_of(a.until, day) if a.until else time.time() + 5
    rows = adb_rows(since, until, day) + trace_rows(since, until, a.all_watch)
    if not a.no_phone:
        serial = a.serial or find_serial()
        if not serial:
            print("# no phone on adb: the phone's log is left out", file=sys.stderr)
        else:
            o = phone_offset(serial)
            if o is None:
                print("# the phone did not answer `date`: its log is left out", file=sys.stderr)
            else:
                print("# phone %s clock %+.3f s from the laptop's (round trip %.0f ms)" % (serial, o[0], o[1] * 1000))
                rows += phone_rows(serial, since, until, o[0])
    for t, src, text in sorted(rows, key=lambda r: r[0]):
        print("%s  %-5s  %s" % (stamp(t), src, text))


if __name__ == "__main__":
    main()
