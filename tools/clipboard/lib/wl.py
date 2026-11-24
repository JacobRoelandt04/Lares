"""The programs outside: wl-paste, hyprctl, cliphist.

Each is looked up on PATH at call time, so a test puts stubs first on PATH and a machine without one
(no Hyprland, no cliphist) gets a plain "unavailable" answer instead of a crash. Every call has a
timeout: ingest runs once per copy and must never hang the watcher. Nothing here prints or logs what it
read.
"""
import json
import shutil
import subprocess


def run(argv, timeout=5, stdin=None):
    """(returncode, stdout bytes), or None when the program is missing, times out or cannot start."""
    exe = shutil.which(argv[0])
    if exe is None:
        return None
    try:
        p = subprocess.run([exe] + list(argv[1:]), input=stdin, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.returncode, p.stdout


def list_types():
    """The mime types the selection offers, in the order the owner listed them."""
    r = run(["wl-paste", "--list-types"])
    if r is None or r[0] != 0:
        return []
    return [t.strip() for t in r[1].decode("utf-8", "replace").splitlines() if t.strip()]


def paste(mime, timeout=15):
    """The selection's bytes as `mime`, or None when wl-paste could not give them."""
    r = run(["wl-paste", "-n", "-t", mime], timeout=timeout)
    if r is None or r[0] != 0:
        return None
    return r[1]


def active_window():
    """{"cls", "title", "address"} of the focused window; empty strings when there is none or no hyprctl."""
    r = run(["hyprctl", "-j", "activewindow"], timeout=2)
    if r is None or r[0] != 0:
        return {"cls": "", "title": "", "address": ""}
    try:
        d = json.loads(r[1].decode("utf-8", "replace"))
    except ValueError:
        return {"cls": "", "title": "", "address": ""}
    if not isinstance(d, dict):
        return {"cls": "", "title": "", "address": ""}
    return {"cls": str(d.get("class") or ""), "title": str(d.get("title") or ""), "address": str(d.get("address") or "")}


def cliphist_list():
    """The ids cliphist holds, newest first; None when cliphist is not installed."""
    r = run(["cliphist", "list"], timeout=30)
    if r is None or r[0] != 0:
        return None
    ids = []
    for line in r[1].decode("utf-8", "replace").splitlines():
        head = line.split("\t", 1)[0].strip()
        if head.isdigit():
            ids.append(head)
    return ids


def cliphist_decode(ident):
    r = run(["cliphist", "decode", ident], timeout=10)
    return r[1] if r is not None and r[0] == 0 else None
