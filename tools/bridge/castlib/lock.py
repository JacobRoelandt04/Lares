"""What the phone's lock does, for the cast's `lock` event: the initial read's answer and the events-log lines that follow it. Pure (castlib
cases hold it).

The phone's own clock starts the follower (`logcat -T '<MM-DD hh:mm:ss.000>'`: a count would count lines BEFORE the tag filter), so the read
asks for the time first, then the lock; events older than that read are dropped by their epoch. Lines are Android 16's event log with
`-v epoch`: `<epoch> <pid> <tid> I <tag>: [..]`.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from bridgelib import parse  # noqa: E402

TAGS = ("wm_set_keyguard_shown", "power_screen_state")
READ_SCRIPT = "echo ==now; date '+%m-%d %H:%M:%S.000'; echo ==epoch; date +%s.%N; " + parse.LOCK_SCRIPT
_LINE = re.compile(r"^\s*(\d+(?:\.\d+)?)\s+\d+\s+\d+\s+[A-Z]\s+(\w+)\s*:\s*\[([^\]]*)\]")
_NOW = re.compile(r"^\d\d-\d\d \d\d:\d\d:\d\d\.\d{3}$")


def parse_read(text):
    """The answer of READ_SCRIPT -> {keyguard, awake, now, epoch} (now = the phone's clock for -T, "" when it did not say; epoch = its
    seconds or None), or None when the phone said nothing about its lock."""
    text = str(text)
    if "==trust" not in text and "==window" not in text:
        return None
    lines = text.splitlines()
    now, epoch = "", None
    for i, l in enumerate(lines):
        if l.strip() == "==now" and i + 1 < len(lines) and _NOW.match(lines[i + 1].strip()):
            now = lines[i + 1].strip()
        if l.strip() == "==epoch" and i + 1 < len(lines):
            try:
                epoch = float(lines[i + 1].strip())
            except ValueError:
                epoch = None
    ls = parse.parse_lockstate(text)
    return {"keyguard": bool(ls["keyguard"]), "awake": bool(ls["awake"]), "now": now, "epoch": epoch}


def parse_event(line):
    """One events-log line -> (epoch, "keyguard" | "awake", bool), or None for anything else (a header, another tag, another display,
    a line that does not parse). wm_set_keyguard_shown: [display, shown, aod, goingAway, occluded, reason] -- display 0 only; the keyguard is
    up when shown == 1 and it is not going away. power_screen_state: [on, why, ...] -- awake when the first field is 1."""
    m = _LINE.match(str(line))
    if not m:
        return None
    t, tag, body = float(m.group(1)), m.group(2), m.group(3)
    f = [x.strip() for x in body.split(",")]
    try:
        if tag == "wm_set_keyguard_shown":
            if len(f) < 4 or int(f[0]) != 0:
                return None
            return t, "keyguard", int(f[1]) == 1 and int(f[3]) == 0
        if tag == "power_screen_state":
            return t, "awake", int(f[0]) == 1
    except ValueError:
        return None
    return None


class Tracker:
    """The (keyguard, awake) pair; feed() answers the pair when a line CHANGED it, else None. Events from before `since` are ignored."""

    def __init__(self, keyguard, awake, since=None):
        self.keyguard, self.awake, self.since = bool(keyguard), bool(awake), since

    def pair(self):
        return self.keyguard, self.awake

    def feed(self, line):
        ev = parse_event(line)
        if ev is None:
            return None
        t, kind, value = ev
        if self.since is not None and t < self.since:
            return None
        before = self.pair()
        if kind == "keyguard":
            self.keyguard = value
        else:
            self.awake = value
        return self.pair() if self.pair() != before else None
