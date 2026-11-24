#!/usr/bin/env python3
"""sheet_render.py -- renders the reference sheet of tools/dev/sheet_states.txt: one PNG and one log per state.

    python3 tools/dev/sheet_render.py <outdir>                  every state: <outdir>/png/<state>.png, logs/<state>.log, exec/<state>.txt (what it ran)
    python3 tools/dev/sheet_render.py --list                    the expanded state names
    ONLY=<regex> JOBS=<n> ARM=<token|padding|delete> ...     some states; how many at once (8); one fault in the copy (below)

Ends in SHEET_RENDER RESULT PASS|FAIL, and <outdir>/sheet.json has every state's exit status and seconds. tools/dev/sheet_check.sh runs
this; it is the part that must repeat to the pixel, so everything a picture could take from the machine or the moment is fixed here:

  The tree        started INSIDE one tools/dev/sandbox.sh copy: a quickshell rewrites .qmlls.ini where it starts, and an ARM patches the tree
                  it stands in (the copy is re-synced on every sandbox.sh call, so a patch made through a second call would be gone).
  The world       a state runs on the short environment in render(), nothing else of the caller's: private config / state / cache / data
                  homes and a bare runtime dir (no Hyprland, PipeWire or mpd socket), a private session bus (tools/dev/notifications_bus.sh),
                  the theme state seeded, MOCKUP_REPO empty so that nothing is written back, no Wayland display (DISPLAY stays, for GLX),
                  no logind watcher on the system bus, and stubs for the three programs in NO_RUN. exec/<state>.txt lists what a state ran.
  The wall clock  tools/dev/sheet_stillclock.c: the date stands still at a Wednesday 16:00, and entropy is one fixed stream (so Math.random
                  and the particles are too).
  The text        QML_DISABLE_DISTANCEFIELD=1: distance-field text is not byte-reproducible across processes (CLAUDE.md).
  The wallpaper   a generated gradient, not the user's: WALL, which the shell, bar, power, windowtray and weather_popup mockups read.
  The focus       SHEET_GRAB (MockupWindow) takes the focus off every field before the grab: a caret blinks on the wall clock.
  The config      nothing but the seeded theme state, or tools/dev/sheet_user_shell.jsonc for a `cfg=user` row.
  The rolls       HOLDS, patched into the sandbox copy before any state runs: a RollingCells (the stocks strip, the summary card) never
                  starts its cycle. Its roll every 4 s ran on the animation clock from the popup's build, so under load a grab 6 s after the
                  start landed in a roll now and then (the strip's third cell half faded in: shell.open-stocks flipped between runs, C6b).

What still comes from the machine, and moves pixels if it changes: the fonts, the icon theme, /usr/share/applications (the launcher's list),
~/Music's albums (the player's mock queue is built from the real directories), Qt, Mesa and the GPU. After such a change take a new baseline
from a revision known to be right (git worktree add <dir> <rev>, <dir>/tools/dev/sheet_check.sh <out> --baseline, then SHEET_BASELINE=<out>/sheet).

ARM= is the check's own proof: one fault in the copy (never in the tree), and tools/dev/sheet_check.sh must fail on the state it names.
    token    themes/eva.json's dark `listBox` one level off: dark states move, no light one
    padding  the weather popup's padding 1 px larger: shell.open-weather moves, nothing else
    delete   the file of a component only the stocks popup uses is gone: the stocks states break, with "is not a type" in their logs
"""
import concurrent.futures
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import time
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STATES = os.path.join(ROOT, "tools", "dev", "sheet_states.txt")
NOW = 1793199600            # Wed 2026-10-28 16:00 CET: a weekday, the markets open
GRAB_MS = 6000
TIMEOUT_S = 150
MODES = ("light", "dark")
SCALES = ("1", "1.25")
# The mock worlds ask these of the machine anyway (exec/<state>.txt is how it was found): the llm mockup's VRAM reading would wake the dGPU and
# put a live figure on the card, the llm tools' scope probe would reach the user's systemd. On the sheet they answer "no".
NO_RUN = ("nvidia-smi", "nvidia-modprobe", "systemd-run")

# ARM: file, exact text, replacement (exactly one occurrence, or the run refuses: an arm that lands nowhere proves nothing)
ARMS = {
    "token": ("themes/eva.json", '        "listBox": "#282C34",\n', '        "listBox": "#282C35",\n'),
    "padding": ("modules/weather/WeatherPopup.qml", "    property real padding: 12\n", "    property real padding: 13\n"),
    "delete": ("modules/stocks/StocksIndexStrip.qml", None, None),
}


def parse_rows(path=STATES):
    """The states file as a list of expanded states, in file order."""
    states = []
    for raw in open(path, encoding="utf-8"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        words = line.split()
        kind, name = words[0], words[1]
        rest = words[2:]
        file_ = None
        if kind == "mockup":
            file_, rest = rest[0], rest[1:]
        elif kind != "shell":
            raise SystemExit(f"sheet_states.txt: bad row: {line}")
        opts = {"env": {}, "cfg": "", "scales": SCALES if kind == "shell" else ("1",), "modes": MODES, "grab": GRAB_MS, "masks": []}
        for w in rest:
            k, _, v = w.partition("=")
            if k == "cfg":
                opts["cfg"] = v
            elif k == "scales":
                opts["scales"] = tuple(v.split(","))
            elif k == "modes":
                opts["modes"] = tuple(v.split(","))
            elif k == "grab":
                opts["grab"] = int(v)
            elif k == "mask":
                label, rect, why = v.split(":", 2)
                label, _, mscale = label.partition("@")     # `<name>@<k>` names the scale the fault is at; 1.25 when none is named
                opts["masks"].append({"name": label, "rect": [int(x) for x in rect.split(",")], "why": why.replace("_", " "),
                                      "scale": mscale or "1.25"})
            else:
                opts["env"][k] = v
        for mode in opts["modes"]:
            for scale in opts["scales"]:
                sn = f"shell.{name}.{mode}.{scale}x" if kind == "shell" else f"mockup.{name}.{mode}"
                states.append({"name": sn, "kind": kind, "module": name, "file": file_, "mode": mode, "scale": scale, "env": opts["env"],
                               "cfg": opts["cfg"], "grab": opts["grab"], "masks": opts["masks"]})
    return states


def locate(state):
    """The file a state runs: the shell mockup for a shell row, its row's file for a mockup row."""
    return "mockups/shell.qml" if state["kind"] == "shell" else state["file"]


def png_gradient(path, w=160, h=90):
    """A fixed wallpaper, written by hand so that it cannot depend on an encoder's version."""
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            rows += bytes((40 + x // 2, 60 + y, 120 + (x + y) // 4))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def apply_arm(arm):
    if os.path.exists(".git"):
        raise SystemExit("an ARM patches the sandbox copy only, and this is a work tree")
    if arm not in ARMS:
        raise SystemExit(f"unknown ARM={arm} ({' '.join(ARMS)})")
    path, old, new = ARMS[arm]
    if arm == "delete":
        if not os.path.exists(path):
            raise SystemExit(f"ARM delete: no {path}")
        os.remove(path)
        print(f"ARM delete: {path} is gone")
    else:
        text = open(path, encoding="utf-8").read()
        if text.count(old) != 1:
            raise SystemExit(f"ARM {arm}: its anchor is not in {path} exactly once")
        open(path, "w", encoding="utf-8").write(text.replace(old, new))
        print(f"ARM {arm}: {path} patched")


# What the sheet holds still in the copy (never in the tree), each anchor exactly once or the run stops: see "The rolls" above.
HOLDS = [
    ("modules/common/float/FloatClock.qml", "    readonly property bool live: clock.running\n", "    readonly property bool live: false      // sheet_render HOLDS: the cards stand at rest, their faces plain\n"),
    ("modules/stocks/RollingCells.qml", "        interval: root.cycleMs\n",
     "        interval: 3600000      // sheet_render HOLDS: the sheet's pictures never catch a roll\n"),
]


def apply_holds():
    if os.path.exists(".git"):
        raise SystemExit("the holds patch the sandbox copy only, and this is a work tree")
    for path, old, new in HOLDS:
        text = open(path, encoding="utf-8").read()
        if text.count(old) != 1:
            raise SystemExit(f"HOLD: its anchor is not in {path} exactly once")
        open(path, "w", encoding="utf-8").write(text.replace(old, new))


def render(state, out, work, shim, wall, bus):
    t0 = time.time()
    name = state["name"]
    png = os.path.join(out, "png", name + ".png")
    log = os.path.join(out, "logs", name + ".log")
    d = os.path.join(work, str(state["index"]))      # short: quickshell's socket under it ends at 108 bytes
    shutil.rmtree(d, ignore_errors=True)
    for sub in ("cfg/theme", "state/lares-shell-mock/config", "cache", "data", "rt"):
        os.makedirs(os.path.join(d, sub))
    os.chmod(os.path.join(d, "rt"), 0o700)
    with open(os.path.join(d, "cfg/theme/state.json"), "w") as f:
        f.write('{"theme":"eva","mode":"%s"}\n' % state["mode"])
    if state["cfg"] == "user":
        shutil.copy("tools/dev/sheet_user_shell.jsonc", os.path.join(d, "state/lares-shell-mock/config/shell.jsonc"))
    env = {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", "user"), "PATH": os.path.join(work, "stubs") + ":" + os.environ["PATH"],
        # the offscreen platform's only GL is GLX on the session's X server: without DISPLAY Qt has no context and a window never draws
        "DISPLAY": os.environ.get("DISPLAY", ""), "XAUTHORITY": os.environ.get("XAUTHORITY", ""),
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TZ": "Europe/Brussels",
        "XDG_RUNTIME_DIR": d + "/rt", "XDG_CONFIG_HOME": d + "/cfg", "XDG_STATE_HOME": d + "/state", "XDG_CACHE_HOME": d + "/cache", "XDG_DATA_HOME": d + "/data",
        "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "rhi", "QT_QPA_PLATFORMTHEME": "", "QT_LOGGING_RULES": "qt.qpa.services.warning=false",
        "QML_DISABLE_DISTANCEFIELD": "1", "QT_HASH_SEED": "0", "QS_ICON_THEME": "Papirus", "QS_DISABLE_CRASH_HANDLER": "1", "QS_DISABLE_FILE_WATCHER": "1", "LARES_SLEEP_MONITOR": "off",
        "MOCKUP_REPO": "", "SHELL_SERVICES": "mock", "WALL": "file://" + wall, "ZOOM": "1", "SCALE": state["scale"], "SHEET_GRAB": png, "GRAB_MS": str(state["grab"]),
    }
    env.update(state["env"])
    ran = os.path.join(out, "exec", name + ".txt")
    cmd = [bus, "timeout", "-k", "5", str(TIMEOUT_S), "env", "LD_PRELOAD=" + shim, "SHEET_NOW=%d" % NOW, "SHEET_EXECLOG=" + ran, "quickshell", "-p", locate(state)]
    with open(log, "wb") as f:
        rc = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT).returncode
    shutil.rmtree(d, ignore_errors=True)
    ok = os.path.exists(png)
    return name, {"rc": rc, "png": ok, "secs": round(time.time() - t0, 1)}


def inner(out):
    jobs = int(os.environ.get("JOBS", "8"))
    only = re.compile(os.environ.get("ONLY", "."))
    states = [dict(s, index=i) for i, s in enumerate(parse_rows()) if only.search(s["name"])]
    if not states:
        print(f"SHEET_RENDER RESULT FAIL (no state matches ONLY={os.environ.get('ONLY')})")
        return 1
    apply_holds()
    arm = os.environ.get("ARM", "")
    if arm:
        apply_arm(arm)
    work = os.environ["SHEET_WORK"]
    wall = os.path.join(work, "wall.png")
    png_gradient(wall)
    shim = os.path.join(work, "stillclock.so")
    subprocess.run(["gcc", "-shared", "-fPIC", "-O2", "-o", shim, "tools/dev/sheet_stillclock.c", "-ldl"], check=True)
    bus = os.path.abspath("tools/dev/notifications_bus.sh")
    os.makedirs(os.path.join(work, "stubs"))
    for prog in NO_RUN:
        with open(os.path.join(work, "stubs", prog), "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(work, "stubs", prog), 0o755)
    for sub in ("png", "logs", "exec"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    for s in states:
        for p in (os.path.join(out, "png", s["name"] + ".png"), os.path.join(out, "logs", s["name"] + ".log"), os.path.join(out, "exec", s["name"] + ".txt")):
            if os.path.exists(p):
                os.remove(p)
    res = {}
    # One alone first: a machine that cannot draw at all (no X server for GLX) says so in one run, not in 184 timeouts.
    name, r = render(states[0], out, work, shim, wall, bus)
    res[name] = r
    if not r["png"] and not arm:
        print(f"SHEET_RENDER RESULT FAIL (the first state drew nothing: {os.path.join(out, 'logs', name + '.log')})")
        return 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for name, r in pool.map(lambda s: render(s, out, work, shim, wall, bus), states[1:]):
            res[name] = r
    with open(os.path.join(out, "sheet.json"), "w") as f:
        json.dump(res, f, indent=0, sort_keys=True)
    bad = [n for n, r in res.items() if not r["png"]]
    for n in bad:
        print(f"no picture: {n} (rc {res[n]['rc']}, {os.path.join(out, 'logs', n + '.log')})")
    if bad:
        print(f"SHEET_RENDER RESULT FAIL ({len(res) - len(bad)} of {len(res)} states drew)")
        return 1
    print(f"SHEET_RENDER RESULT PASS ({len(res)} states)")
    return 0


def main():
    args = sys.argv[1:]
    if args == ["--list"]:
        for s in parse_rows():
            print(s["name"])
        return 0
    if len(args) == 2 and args[0] == "--inner":
        return inner(args[1])
    if len(args) != 1:
        print(__doc__)
        return 2
    out = os.path.abspath(args[0])
    os.makedirs(out, exist_ok=True)
    os.chdir(ROOT)
    scratch = os.environ.get("SCRATCH", "/tmp/lares-sheet")
    work = os.path.join(scratch, f"sheet-{os.getpid()}")
    os.makedirs(work)
    env = dict(os.environ, SHEET_WORK=work)
    env.setdefault("SANDBOX", os.path.join(scratch, "lares-sandbox-sheet"))
    rc = subprocess.run(["tools/dev/sandbox.sh", "-u", "WAYLAND_DISPLAY", "-u", "HYPRLAND_INSTANCE_SIGNATURE", "QT_QPA_PLATFORM=offscreen", "MOCKUP_REPO=",
                         "python3", "-B", "tools/dev/sheet_render.py", "--inner", out], env=env).returncode
    shutil.rmtree(work, ignore_errors=True)
    return rc


if __name__ == "__main__":
    sys.exit(main())
