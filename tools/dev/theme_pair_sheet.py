#!/usr/bin/env python3
"""theme_pair_sheet.py -- one review sheet per theme pair: the bar and a few popups of the real shell frame, and the lock popup, in light and
dark, rendered offscreen with that theme in force.

    python3 tools/dev/theme_pair_sheet.py <outdir>                 every theme on disk: <outdir>/sheet_<theme>.png, png/<state>.png, logs/
    THEMES="riso paper" python3 tools/dev/theme_pair_sheet.py <outdir>
    STATES="rest open-weather" ...                                 some of the states below (default: all)
    JOBS=<n> (4)

Ends in THEME_PAIR_SHEET RESULT PASS|FAIL (FAIL: a state drew no picture; its log is named). The world is tools/dev/sheet_render.py's (one
sandbox.sh copy, a private config / state / cache / data home per state, the still clock, the fixed wallpaper, the mock services, no Wayland),
with one difference: the theme state seeded is the pair under review, not eva. The copy also shows every pair in the theme popup at once
(ThemeStyle.maxRows raised in the COPY: the popup scrolls past four rows, and the sheet wants every card in one picture).

A shell picture is the whole 2880 x 1620 output; the sheet crops each popup to what differs from the rest state of the same theme and mode
(plus a margin), and the bar to its top strip.
"""
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import sheet_render as SR  # noqa: E402

# name -> (kind, file, env)
STATES = {
    "rest": ("shell", "mockups/shell.qml", {}),
    "open-update": ("shell", "mockups/shell.qml", {"STATE": "open:update"}),
    "open-weather": ("shell", "mockups/shell.qml", {"STATE": "open:weather"}),
    "open-silicon": ("shell", "mockups/shell.qml", {"STATE": "open:silicon"}),
    "open-clock": ("shell", "mockups/shell.qml", {"STATE": "open:clock"}),
    "open-theme": ("shell", "mockups/shell.qml", {"STATE": "open:theme"}),
    "lock": ("mockup", "mockups/lockscreen.qml", {"STATE": "dots=5,media=vinyl,battery=82,weather=1,updates=1"}),
}
COPY_PATCHES = [("modules/theme/ThemeStyle.qml", "    property int maxRows: 4\n", "    property int maxRows: 8      // theme_pair_sheet: every pair in one picture (the COPY only)\n")]


def render(theme, mode, state, out, work, shim, wall, bus):
    kind, qml, extra = STATES[state]
    name = "%s.%s.%s" % (theme, mode, state)
    png = os.path.join(out, "png", name + ".png")
    log = os.path.join(out, "logs", name + ".log")
    d = os.path.join(work, "%d" % abs(hash(name) % 10 ** 8))
    shutil.rmtree(d, ignore_errors=True)
    for sub in ("cfg/theme", "state/lares-shell-mock/config", "cache", "data", "rt"):
        os.makedirs(os.path.join(d, sub))
    os.chmod(os.path.join(d, "rt"), 0o700)
    with open(os.path.join(d, "cfg/theme/state.json"), "w") as f:
        json.dump({"theme": theme, "mode": mode}, f)
    env = {
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", "user"), "PATH": os.path.join(work, "stubs") + ":" + os.environ["PATH"],
        "DISPLAY": os.environ.get("DISPLAY", ""), "XAUTHORITY": os.environ.get("XAUTHORITY", ""),
        "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TZ": "Europe/Brussels",
        "XDG_RUNTIME_DIR": d + "/rt", "XDG_CONFIG_HOME": d + "/cfg", "XDG_STATE_HOME": d + "/state", "XDG_CACHE_HOME": d + "/cache", "XDG_DATA_HOME": d + "/data",
        "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "rhi", "QT_QPA_PLATFORMTHEME": "", "QT_LOGGING_RULES": "qt.qpa.services.warning=false",
        "QML_DISABLE_DISTANCEFIELD": "1", "QT_HASH_SEED": "0", "QS_ICON_THEME": "Papirus", "QS_DISABLE_CRASH_HANDLER": "1", "QS_DISABLE_FILE_WATCHER": "1",
        "LARES_SLEEP_MONITOR": "off", "MOCKUP_REPO": "", "SHELL_SERVICES": "mock", "WALL": "file://" + wall, "ZOOM": "1", "SCALE": "1",
        "SHEET_GRAB": png, "GRAB_MS": str(SR.GRAB_MS),
    }
    env.update(extra)
    cmd = [bus, "timeout", "-k", "5", str(SR.TIMEOUT_S), "env", "LD_PRELOAD=" + shim, "SHEET_NOW=%d" % SR.NOW, "quickshell", "-p", qml]
    with open(log, "wb") as f:
        rc = subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT).returncode
    shutil.rmtree(d, ignore_errors=True)
    return name, rc, os.path.exists(png)


def islands(im, theme, mode):
    """The bar's islands side by side at 1:1: the columns of the top strip that are the theme's surface, in runs, with a margin."""
    from PIL import Image
    r = subprocess.run(["python3", "tools/theme/themectl", "resolve", "--file", "themes/%s.json" % theme, "--mode", mode, "--l0",
                        "modules/common/theme/Theme.qml"], capture_output=True, text=True, env=dict(os.environ, HOME=os.environ.get("SHEET_WORK", "/tmp")))
    s = tuple(json.loads(r.stdout)["values"]["surface"][:3])
    strip = im.crop((0, 0, im.width, 64))
    px = strip.load()
    on = [any(sum(abs(a - b) for a, b in zip(px[x, y], s)) < 12 for y in range(4, 40, 4)) for x in range(im.width)]
    runs, x = [], 0
    while x < im.width:
        if on[x]:
            x0 = x
            while x < im.width and (on[x] or any(on[x:x + 40])):
                x += 1
            runs.append((max(0, x0 - 10), min(im.width, x + 10)))
        x += 1
    if not runs:
        return strip
    parts = [strip.crop((a, 0, b, 64)) for a, b in runs]
    out = Image.new("RGB", (sum(p.width for p in parts) + 24 * (len(parts) - 1), 64), (128, 128, 128))
    x = 0
    for p in parts:
        out.paste(p, (x, 0))
        x += p.width + 24
    return out


def compose(out, theme, states):
    from PIL import Image, ImageChops, ImageDraw, ImageFont
    try:
        font = ImageFont.truetype("/usr/share/fonts/inter/InterVariable.ttf", 22)
        big = ImageFont.truetype("/usr/share/fonts/inter/InterVariable.ttf", 34)
    except OSError:
        font = big = ImageFont.load_default()
    cols = {}
    for mode in ("light", "dark"):
        cells = []
        rest = os.path.join(out, "png", "%s.%s.rest.png" % (theme, mode))
        base = Image.open(rest).convert("RGB") if os.path.exists(rest) else None
        for st in states:
            p = os.path.join(out, "png", "%s.%s.%s.png" % (theme, mode, st))
            if not os.path.exists(p):
                cells.append((st, None))
                continue
            im = Image.open(p).convert("RGB")
            if st == "rest":
                im = islands(im, theme, mode)
            elif STATES[st][0] == "shell" and base is not None and base.size == im.size:
                bb = ImageChops.difference(im, base).convert("L").point(lambda v: 255 if v > 6 else 0).getbbox()
                if bb:
                    m = 16
                    im = im.crop((max(0, bb[0] - m), 0, min(im.width, bb[2] + m), min(im.height, bb[3] + m)))
            cells.append((st, im))
        cols[mode] = cells
    pad, label_h = 18, 34
    widths = {m: max([c[1].width for c in cols[m] if c[1] is not None] + [400]) for m in cols}
    rows_h = [max((cols[m][i][1].height if cols[m][i][1] is not None else 60) for m in cols) for i in range(len(states))]
    W = pad * 3 + widths["light"] + widths["dark"]
    H = 70 + sum(h + label_h + pad for h in rows_h)
    sheet = Image.new("RGB", (W, H), (128, 128, 128))
    dr = ImageDraw.Draw(sheet)
    dr.text((pad, 16), "%s -- light | dark" % theme, fill=(255, 255, 255), font=big)
    y = 70
    for i, st in enumerate(states):
        x = pad
        for m in ("light", "dark"):
            name, im = cols[m][i]
            dr.text((x, y), "%s %s" % (m, name), fill=(255, 255, 255), font=font)
            if im is not None:
                sheet.paste(im, (x, y + label_h))
            else:
                dr.text((x, y + label_h), "NO PICTURE", fill=(255, 60, 60), font=font)
            x += widths[m] + pad
        y += rows_h[i] + label_h + pad
    path = os.path.join(out, "sheet_%s.png" % theme)
    sheet.save(path)
    return path


def inner(out):
    for rel, old, new in COPY_PATCHES:
        if os.path.exists(".git"):
            raise SystemExit("the copy patches are for the sandbox copy only, and this is a work tree")
        t = open(rel, encoding="utf-8").read()
        if t.count(old) != 1:
            print("THEME_PAIR_SHEET RESULT FAIL (the copy patch's anchor is not in %s exactly once)" % rel)
            return 1
        open(rel, "w", encoding="utf-8").write(t.replace(old, new))
    SR.apply_holds()
    themes = (os.environ.get("THEMES") or " ".join(n[:-5] for n in sorted(os.listdir("themes")) if n.endswith(".json"))).split()
    states = (os.environ.get("STATES") or " ".join(STATES)).split()
    if "rest" not in states:
        states.insert(0, "rest")
    work = os.environ["SHEET_WORK"]
    wall = os.path.join(work, "wall.png")
    SR.png_gradient(wall)
    shim = os.path.join(work, "stillclock.so")
    subprocess.run(["gcc", "-shared", "-fPIC", "-O2", "-o", shim, "tools/dev/sheet_stillclock.c", "-ldl"], check=True)
    bus = os.path.abspath("tools/dev/notifications_bus.sh")
    os.makedirs(os.path.join(work, "stubs"))
    for prog in SR.NO_RUN:
        with open(os.path.join(work, "stubs", prog), "w") as f:
            f.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(work, "stubs", prog), 0o755)
    for sub in ("png", "logs"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    jobs = [(t, m, s) for t in themes for m in ("light", "dark") for s in states]
    bad = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(os.environ.get("JOBS", "4"))) as pool:
        for name, rc, ok in pool.map(lambda j: render(j[0], j[1], j[2], out, work, shim, wall, bus), jobs):
            if not ok:
                bad.append((name, rc))
    for t in themes:
        print("sheet: %s" % compose(out, t, states))
    for name, rc in bad:
        print("no picture: %s (rc %s, %s)" % (name, rc, os.path.join(out, "logs", name + ".log")))
    print("THEME_PAIR_SHEET RESULT %s (%d pictures of %d)" % ("FAIL" if bad else "PASS", len(jobs) - len(bad), len(jobs)))
    return 1 if bad else 0


def main():
    args = sys.argv[1:]
    if len(args) == 2 and args[0] == "--inner":
        return inner(args[1])
    if len(args) != 1:
        print(__doc__)
        return 2
    out = os.path.abspath(args[0])
    os.makedirs(out, exist_ok=True)
    os.chdir(ROOT)
    scratch = os.environ.get("SCRATCH", "/tmp/lares-sheet")
    work = os.path.join(scratch, "pairsheet-%d" % os.getpid())
    os.makedirs(work)
    env = dict(os.environ, SHEET_WORK=work)
    env.setdefault("SANDBOX", os.path.join(scratch, "lares-sandbox-pairsheet"))
    t0 = time.time()
    rc = subprocess.run(["tools/dev/sandbox.sh", "-u", "WAYLAND_DISPLAY", "-u", "HYPRLAND_INSTANCE_SIGNATURE", "QT_QPA_PLATFORM=offscreen", "MOCKUP_REPO=",
                         "python3", "-B", "tools/dev/theme_pair_sheet.py", "--inner", out], env=env).returncode
    shutil.rmtree(work, ignore_errors=True)
    print("(%.0f s)" % (time.time() - t0))
    return rc


if __name__ == "__main__":
    sys.exit(main())
