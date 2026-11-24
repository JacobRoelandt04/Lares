#!/usr/bin/env python3
"""cursor_overlay_check.py -- no click-through MouseArea decides the cursor, and every window that takes input has its cursor cover.

    python3 tools/dev/cursor_overlay_check.py            the shipped tree (modules/, shell.qml, lock/)
    ARM=noreset python3 tools/dev/cursor_overlay_check.py   one fault in a copy of the text: the check must FAIL and name it
    ARM=nowindow ...                                        the toast pill's window without its CursorCover: it must FAIL and name it

Qt 6.12 gives every MouseArea an Arrow cursor of its own, and the window's cursor is the topmost item under the pointer that has
one -- enabled or not (CLAUDE.md, EVERY MouseArea OWNS AN ARROW CURSOR FROM BIRTH). A MouseArea that lets the LEFT button through
(acceptedButtons: Qt.NoButton -- a wheel or swipe reader --, or only the right, middle or back button) sits over controls whose hand
cursor it would turn into Arrow. Such an area says `cursorShape: <something>`: `undefined` (the reset: the cursor is what lies under
it) or a shape of its own on purpose.

THE WINDOWS: shell.jsonc `hoverCursor` off keeps the plain arrow everywhere, by a CursorCover over each window (modules/shell/cursor). A file
that makes a PanelWindow or a FloatingWindow has one, unless it is in NO_INPUT (its input region is empty: no pointer is ever on it).

Ends in one CURSOR_OVERLAY RESULT PASS|FAIL line; the exit status follows it.
"""
import glob
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
NAME = "CURSOR_OVERLAY"
NO_INPUT = {"ThemeCurtain.qml", "SleepVeil.qml", "BootCover.qml"}


def window_faults(path, text):
    if not re.search(r"^\s*(PanelWindow|FloatingWindow)\s*\{", text, re.M) or os.path.basename(path) in NO_INPUT:
        return []
    if re.search(r"^\s*CursorCover\s*\{", text, re.M):
        return []
    return ["%s  a window with no CursorCover: hoverCursor off does not reach it" % os.path.relpath(path, ROOT)]


def blocks(text):
    """(line number, top-level property lines) of every MouseArea block in a QML text."""
    lines = text.split("\n")
    for i, ln in enumerate(lines):
        if not re.match(r"^\s*MouseArea\s*\{\s*$", ln):
            continue
        depth = 0
        top = []
        for j in range(i, len(lines)):
            s = re.sub(r'"([^"\\]|\\.)*"', '""', lines[j])
            s = re.sub(r"//.*", "", s)
            before = depth
            depth += s.count("{") - s.count("}")
            if j > i and before == 1:
                top.append(lines[j].strip())
            if depth == 0 and j > i:
                break
        yield i + 1, top


def faults(path, text):
    out = []
    for line, top in blocks(text):
        if any(l.startswith("cursorShape") for l in top):
            continue
        ab = [l for l in top if l.startswith("acceptedButtons:")]
        if not ab:
            continue                      # the left button by default: the area takes clicks, its Arrow is honest
        a = ab[0].split("//")[0]
        if "LeftButton" in a or "AllButtons" in a:
            continue
        out.append("%s:%d  %s and no cursorShape: the controls under it lose their hand" % (os.path.relpath(path, ROOT), line, a.strip()))
    return out


def tree():
    files = sorted(glob.glob(os.path.join(ROOT, "modules", "**", "*.qml"), recursive=True))
    files += sorted(glob.glob(os.path.join(ROOT, "lock", "**", "*.qml"), recursive=True))
    files.append(os.path.join(ROOT, "shell.qml"))
    seen, out = set(), []
    for f in files:                       # lock/modules is the same tree through a link: each file once
        r = os.path.realpath(f)
        if os.path.isfile(f) and os.sep + "mockup" + os.sep not in r and r not in seen:
            seen.add(r)
            out.append(f)
    return out


def main():
    arm = os.environ.get("ARM", "")
    found = []
    armed = False
    for f in tree():
        text = open(f, encoding="utf-8").read()
        if arm == "noreset" and not armed and f.endswith(os.path.join("scroll", "WheelArea.qml")):
            fixed = text.replace("cursorShape: undefined", "", 1)
            if fixed == text:
                print("%s ARM noreset: the anchor is gone (WheelArea has no cursorShape: undefined)" % NAME)
                print("%s RESULT FAIL (arm anchor lost)" % NAME)
                return 1
            text, armed = fixed, True
        if arm == "nowindow" and f.endswith("ToastPillWindow.qml"):
            fixed = text.replace("CursorCover {", "Item {", 1)
            if fixed == text:
                print("%s ARM nowindow: the anchor is gone (ToastPillWindow has no CursorCover)" % NAME)
                print("%s RESULT FAIL (arm anchor lost)" % NAME)
                return 1
            text = fixed
        found += faults(f, text) + window_faults(f, text)
    for line in found:
        print("%s FAIL %s" % (NAME, line))
    if arm in ("noreset", "nowindow"):
        aim = "WheelArea.qml" if arm == "noreset" else "ToastPillWindow.qml"
        bit = any(aim in l for l in found)
        print("%s ARM %s: %s" % (NAME, arm, "the check names " + aim + ", as it must" if bit else "the check did NOT bite"))
        print("%s RESULT %s (arm %s)" % (NAME, "PASS" if bit else "FAIL", arm))
        return 0 if bit else 1
    ok = not found
    print("%s RESULT %s (%d faults: click-through MouseAreas without a cursor, windows without a cover)" % (NAME, "PASS" if ok else "FAIL", len(found)))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
