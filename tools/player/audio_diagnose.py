#!/usr/bin/env python3
"""audio_diagnose.py -- what is wrong with the audio path, read only.

The player's health check (modules/common/components/MpdHealth.qml) runs this once a problem is
confirmed, never on a timer. It prints ONE JSON object on stdout and exits 0 whatever it finds
(a tool that cannot answer says so in the object, `"pw": "missing"`):

  {
    "pw":         "ok" | "timeout" | "missing" | "error",   how pw-dump answered
    "sinks":      [{"id", "name", "desc", "state", "error", "default": bool}],
    "defaultSink": "<node.name>" | "",
    "configuredSink": "<node.name>" | "",   the preferred output (it may be unplugged)
    "procs":      {"mpd": ["S"], "wireplumber": ["D"], "pipewire": ["S"], ...},   kernel state letters
    "wchan":      {"wireplumber": "usb_start_wait_urb"}     where a process in D waits, when known
  }

WHY PROCESS STATES. A process in uninterruptible sleep (D) cannot be killed by anything, and a
`systemctl restart` of its unit waits on it for the stop timeout: the user's USB DAC locked at the
hardware level and wireplumber sat in D on usb_start_wait_urb, so "restart the audio session" is the
wrong offer. The state letter is read from /proc/<pid>/stat (the state is the field after the
parenthesised name), only for the caller's own processes.

WHY pw-dump HAS A DEADLINE AND ITS OWN SESSION. A hung audio server answers nothing; the child is
started in a new process group and the whole group is killed at the deadline, so this tool is never
the thing that hangs. Nothing here writes to PipeWire, systemd or mpd.

Environment (for the tests): AUDIO_DIAGNOSE_PROC replaces /proc, AUDIO_DIAGNOSE_TIMEOUT is the
pw-dump deadline in seconds (default 2.5), AUDIO_DIAGNOSE_UID the owner whose processes count.
"""
import json
import os
import signal
import subprocess
import sys

WATCHED = ("mpd", "wireplumber", "pipewire", "pipewire-pulse")


def procs(root, uid):
    states = {}
    wchan = {}
    try:
        names = os.listdir(root)
    except OSError:
        return states, wchan
    for n in names:
        if not n.isdigit():
            continue
        base = os.path.join(root, n)
        try:
            if os.stat(base).st_uid != uid:
                continue
            with open(os.path.join(base, "stat"), "r", errors="replace") as f:
                raw = f.read()
        except OSError:
            continue
        # "pid (comm) S ..." -- comm may contain spaces and parentheses; the LAST ')' ends it
        close = raw.rfind(")")
        if close < 0:
            continue
        comm = raw[raw.find("(") + 1:close]
        rest = raw[close + 1:].split()
        if comm not in WATCHED or not rest:
            continue
        states.setdefault(comm, []).append(rest[0])
        if rest[0] == "D":
            try:
                with open(os.path.join(base, "wchan"), "r", errors="replace") as f:
                    w = f.read().strip()
                if w and w != "0":
                    wchan[comm] = w
            except OSError:
                pass
    return states, wchan


def pw(timeout):
    try:
        p = subprocess.Popen(["pw-dump"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    except FileNotFoundError:
        return "missing", None
    except OSError:
        return "error", None
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            p.communicate(timeout=1)
        except Exception:
            pass
        return "timeout", None
    try:
        return "ok", json.loads(out.decode("utf-8", "replace"))
    except ValueError:
        return "error", None


def sinks(objs):
    default = ""
    configured = ""
    out = []
    for o in objs:
        t = str(o.get("type", ""))
        if t.endswith("Metadata"):
            for m in o.get("metadata", []):
                v = m.get("value")
                if m.get("key") == "default.audio.sink" and isinstance(v, dict):
                    default = str(v.get("name", ""))
                elif m.get("key") == "default.configured.audio.sink" and isinstance(v, dict):
                    configured = str(v.get("name", ""))
    for o in objs:
        if not str(o.get("type", "")).endswith("Node"):
            continue
        info = o.get("info", {}) or {}
        props = info.get("props", {}) or {}
        if props.get("media.class") != "Audio/Sink":
            continue
        name = str(props.get("node.name", ""))
        out.append({
            "id": o.get("id"),
            "name": name,
            "desc": str(props.get("node.description") or props.get("node.nick") or name),
            "state": str(info.get("state", "")),
            "error": str(info.get("error") or ""),
            "default": name == default,
        })
    return out, default, configured


def main():
    root = os.environ.get("AUDIO_DIAGNOSE_PROC", "/proc")
    uid = int(os.environ.get("AUDIO_DIAGNOSE_UID", str(os.getuid())))
    timeout = float(os.environ.get("AUDIO_DIAGNOSE_TIMEOUT", "2.5"))
    states, wchan = procs(root, uid)
    status, objs = pw(timeout)
    s, d, c = (sinks(objs) if objs is not None else ([], "", ""))
    json.dump({"pw": status, "sinks": s, "defaultSink": d, "configuredSink": c,
               "procs": states, "wchan": wchan}, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
