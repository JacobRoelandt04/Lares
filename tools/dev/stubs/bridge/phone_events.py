#!/usr/bin/env python3
"""Append a line to the fake phone's events log (the file the stub adb's `logcat -b events` follows: $BRIDGE_PHONE_EVENTS or --file).

    phone_events.py [--file F] [--world W] keyguard <shown 0|1> [aod=0] [goingAway=0] [occluded=0] [reason]
    phone_events.py [--file F] [--world W] screen on|off
    phone_events.py [--file F] raw "<epoch> <pid> <tid> I <tag>: [..]"        (verbatim: an old epoch, a header, another tag)

`keyguard` writes `wm_set_keyguard_shown: [0,<shown>,<aod>,<goingAway>,<occluded>,<reason>]`, `screen` `power_screen_state: [<on>,0,0,0]`, both in the
real format with the current epoch. With --world the world's adb.phone follows (locked = shown and not going away, awake = on) so a lock read
agrees with the event; trustedKeyguard is not touched.
"""
import json
import os
import sys
import time


def main():
    a = sys.argv[1:]
    path, world = os.environ.get("BRIDGE_PHONE_EVENTS", ""), ""
    while a[:1] and a[0] in ("--file", "--world"):
        if a[0] == "--file":
            path = a[1]
        else:
            world = a[1]
        a = a[2:]
    if not path or not a:
        sys.exit(__doc__)
    kind, rest = a[0], a[1:]
    phone = {}
    if kind == "keyguard":
        f = (rest + ["0"] * 4)[:4]
        reason = rest[4] if len(rest) > 4 else ("keyguardGoingAway" if f[2] == "1" else "setKeyguardShown")
        line = "I wm_set_keyguard_shown: [0,%s,%s,%s,%s,%s]" % (f[0], f[1], f[2], f[3], reason)
        phone["locked"] = f[0] == "1" and f[2] != "1"
    elif kind == "screen":
        on = 1 if rest[0] == "on" else 0
        line = "I power_screen_state: [%d,0,0,0]" % on
        phone["awake"] = bool(on)
    elif kind == "raw":
        with open(path, "a") as fh:
            fh.write(rest[0] + "\n")
        return
    else:
        sys.exit(__doc__)
    with open(path, "a") as fh:
        fh.write("%15.3f %5d %5d " % (time.time(), 1234, 1300) + line + "\n")
    if world:
        try:
            w = json.load(open(world))
        except (OSError, ValueError):
            w = {}
        w.setdefault("adb", {}).setdefault("phone", {}).update(phone)
        tmp = world + ".ev.tmp"
        json.dump(w, open(tmp, "w"))
        os.replace(tmp, world)


if __name__ == "__main__":
    main()
