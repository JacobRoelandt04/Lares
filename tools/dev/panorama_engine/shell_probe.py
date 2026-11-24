#!/usr/bin/env python3
"""tools/dev/panorama_engine/shell_probe.py -- the LIVE Panorama service inside the REAL shell.qml, on a nested Hyprland whose engine is
active (tools/panorama/engine.lua through the generated config/panorama.lua). Run through tools/dev/panorama_shell_env_probe.sh.

  shell_probe.py seed  <root> <sandbox> <envname>                  the store, the generated engine file, the hypr config line, the engine loaded
  shell_probe.py run   <root> <sandbox> <envname> <shell.log> <ddc.log>   the checks (prints `  ok|FAIL <name>` lines)
  shell_probe.py mirror-seed  <root> <sandbox> <envname>           the mirror phase's env (eDP-1 + LOCK-1, empty store, the engine loaded)
  shell_probe.py mirror-after <root> <sandbox> <envname> <harness.log>   the compositor's own word after the harness's mirror and revert

Nested outputs have no eDP, so the service sees no internal panel and the engine none either (no `internal_override`): the plug
rules (never-seen above the first output) are the same ones.
"""
import json
import os
import re
import subprocess
import sys
import threading
import time

mode, ROOT, SB, ENVNAME = sys.argv[1:5]
E = os.path.join(ROOT, "tools/dev/lock_env.sh")
# the engine's own version, read where it is written: a literal here is red after every change of it
ENGINE = int(re.search(r"^local ENGINE_VERSION = (\d+)", open(os.path.join(ROOT, "tools/panorama/engine.lua")).read(), re.M).group(1))
ENV = dict(os.environ, LOCK_ENV=ENVNAME)
B = "/tmp/lrlk-" + ENVNAME
SHELL_QML = os.path.join(SB, "shell.qml")
results = []


def sh(*args, timeout=40):
    p = subprocess.run(list(args), cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=timeout)
    return (p.stdout or "") + (p.stderr or "")


def hc(*args):
    return sh(E, "hyprctl", *args)


def ev(lua):
    out = hc("eval", lua)
    if "error" in out.lower():
        raise RuntimeError("eval: " + out.strip()[:300])
    return out


L1, L2 = "headless:LOCK-1", "headless:LOCK-2"


def spec(mode_, pos, scale=1):
    return {"enabled": True, "mode": mode_, "position": pos, "scale": scale, "transform": 0, "mirror": False, "vrr": 0,
            "bitdepth": 8, "cm": "srgb", "sdrbrightness": 1, "sdrsaturation": 1}


def seed():
    def disp(port):
        return {"label": port, "custom": False, "internal": False, "port": port, "placeholder": False}
    d = {"v": 1, "displays": {L1: disp("LOCK-1"), L2: disp("LOCK-2")}, "split": {"3": L2, "4": L2},
         "setups": {L1 + " + " + L2: {"name": "Desk", "custom": True, "used": 5,
                                      "outputs": {L1: spec("2880x1620@60", [0, 0]), L2: spec("3440x1440@60", [2880, -200])}}}}
    sdir = B + "/state/lares/panorama"
    os.makedirs(sdir, exist_ok=True)
    open(sdir + "/setups.json", "w").write(json.dumps(d))
    print("seeded: the store only (the engine is set up by the run, the way `lares panorama-import` does)")
    return 0


def setup_engine():
    """What the import does: the generated file, the require line in the hypr config, `hyprctl eval dofile` -- no reload."""
    sdir = B + "/state/lares/panorama"
    hypr = B + "/cfg/hypr"
    os.makedirs(hypr + "/config", exist_ok=True)
    subprocess.run([sys.executable, os.path.join(ROOT, "tools/panorama/generate.py"), sdir + "/setups.json",
                    os.path.join(SB, "tools/panorama/engine.lua"), hypr + "/config/panorama.lua"], check=True)
    line = 'package.path = "%s/?.lua;" .. package.path\npcall(require, "config/panorama")\n' % hypr
    # the file the service greps for the user's require line, and the nested compositor's own config (a reload loads it too)
    open(hypr + "/hyprland.lua", "w").write("-- the nested session's hypr dir\n" + line)
    with open(B + "/hyprland.lua", "a") as f:
        f.write("\n" + line)
    ev('dofile("%s/config/panorama.lua")' % hypr)
    st = None
    for _ in range(30):
        try:
            st = json.load(open(B + "/rt/lares/panorama.json"))
            break
        except Exception:
            time.sleep(0.2)
    return st


def mirror_seed():
    """The mirror phase's env: LOCK-2 removed, a headless eDP-1 as the laptop panel, an EMPTY store (every display never seen), the engine
    loaded the import's way. LOCK-1 is the external the harness (tools/dev/qml/panorama_mirror_env.qml) mirrors."""
    hc("output", "remove", "LOCK-2")
    time.sleep(0.6)
    hc("output", "create", "headless", "eDP-1")
    time.sleep(1.0)
    sdir = B + "/state/lares/panorama"
    os.makedirs(sdir, exist_ok=True)
    open(sdir + "/setups.json", "w").write(json.dumps({"v": 1, "displays": {}, "setups": {}, "split": {}}))
    st = setup_engine()
    check("m0 the mirror env: eDP-1 and LOCK-1, the engine answers", st and st.get("engine") == ENGINE and not set(["eDP-1", "LOCK-1"]) - set(st.get("specs", {})), st)
    return 1 if not results[-1][1] else 0


def mirror_after(slog):
    """What the compositor itself says once the harness has mirrored, reverted and tried again; and the harness's whole log."""
    ms = {m["name"]: m for m in json.loads(hc("-j", "monitors", "all"))}
    check("m5 the compositor: LOCK-1 does not mirror (the revert and the keep left it alone)", ms.get("LOCK-1", {}).get("mirrorOf") == "none", ms.get("LOCK-1", {}).get("mirrorOf"))
    st = json.load(open(B + "/rt/lares/panorama.json"))
    check("m5 the engine's state: no trial left in the air", st["trial"]["phase"] in ("kept", "reverted", "none"), st["trial"])
    w = [l for l in log_warnings(slog) if re.search(r"modules/panorama|PanoramaService|EngineLink|panorama engine", l)]
    check("m5 the harness's log: no warning naming panorama", not w, w[:3])
    failed = [n for n, ok in results if not ok]
    print("PANORAMA_SHELL_ENV MIRROR %s (%d checks)" % ("FAIL" if failed else "PASS", len(results)))
    return 1 if failed else 0


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print("  %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  [" + str(detail)[:300] + "]"), flush=True)


def wait_for(fn, timeout=8.0, step=0.2):
    end = time.time() + timeout
    v = None
    while time.time() < end:
        try:
            v = fn()
        except Exception:
            v = None
        if v:
            return v
        time.sleep(step)
    return v


def probe():
    t = ""
    for _ in range(5):
        t = sh(E, "run", "quickshell", "ipc", "-p", SHELL_QML, "call", "shell", "probe")
        try:
            return json.loads(t.strip())
        except ValueError:
            time.sleep(0.3)
    raise RuntimeError("no probe answer: " + t[:200])


def pano():
    return probe()["panorama"]


def titles():
    return probe().get("notifications", {}).get("titles", [])


def monitors():
    return json.loads(hc("-j", "monitors"))


def bbox():
    ms = monitors()
    lw = lambda m: m["width"] / (m["scale"] or 1)
    lh = lambda m: m["height"] / (m["scale"] or 1)
    x0, y0 = min(m["x"] for m in ms), min(m["y"] for m in ms)
    return x0, y0, round(max(m["x"] + lw(m) for m in ms) - x0), round(max(m["y"] + lh(m) for m in ms) - y0)


def point_cmd(name, x, y):
    x0, y0, w, h = bbox()
    m = [m for m in monitors() if m["name"] == name][0]
    return "abs %d %d %d %d" % (round(m["x"] + x - x0), round(m["y"] + y - y0), w, h)


def move(name, x, y, wait=0.3):
    sh(E, "point", point_cmd(name, x - 4, y), "sleep 80", point_cmd(name, x, y))
    time.sleep(wait)


def click(name, x, y, settle=0.7):
    sh(E, "point", point_cmd(name, x - 3, y), "sleep 80", point_cmd(name, x, y), "sleep 120", "click")
    time.sleep(settle)


def glyph_centre(st, name):
    s = st["screens"][name]
    bar = [b for b in s["bars"] if b["id"] == "topR"] or [b for b in s["bars"] if b["id"] == "top"]
    p = s["placed"]["panorama"]
    return bar[0]["rawPos"] + p["x"] + p["width"] / 2, 20


def edge_blue(png, which):
    from PIL import Image
    im = Image.open(png).convert("RGB")
    w, h = im.size
    pts = [(1, h // 2), (1, h // 3), (1, 2 * h // 3), (w - 2, h // 2), (w - 2, h // 3), (w - 2, 2 * h // 3), (w // 2, h - 2), (w // 3, h - 2)]
    blue = lambda p: p[2] > 190 and p[0] < 130 and 80 < p[1] < 170
    return sum(1 for q in pts if blue(im.getpixel(q))), len(pts)


def shot(out, name):
    path = "%s/pn_%s_%s.png" % (B, name, out)
    sh(E, "shot", path, name)
    return path


# a warning anywhere in the shell's log that is not the platform's own
NOISE = re.compile(r"quickshell.tooling|--- WARNING ---|actually running wayland|does not support setting window masks|"
                   r"Failed to register with host portal|Could not load icon \"(nm-signal-50|internet-chat|blueman-disabled)\"")
WARN = re.compile(r"^\s*(WARN|ERROR)|Unable to assign|Binding loop|non-existent property")


def log_warnings(path, start=0):
    lines = open(path, errors="replace").read().splitlines()[start:]
    lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in lines]
    return [l for l in lines if WARN.search(l) and not NOISE.search(l)]


def run():
    slog, ddclog = sys.argv[5], sys.argv[6]
    p = probe()["panorama"]
    check("0 engine not set up yet: the service says so (%s)" % p["engine"], p and p["live"] and p["engine"] != "active", p)
    est = setup_engine()
    check("0 set up the import's way (file + require line + eval dofile, no reload): the engine answers", est and est.get("engine") == ENGINE, est)
    check("0 ... and the service turns active within a few seconds", wait_for(lambda: pano()["engine"] == "active", 10), pano())
    st = probe()
    p = st["panorama"]
    check("1 live service, engine active, 2 panes LOCK-1 LOCK-2",
          p and p["live"] and p["engine"] == "active" and p["panes"] == 2 and {"LOCK-1", "LOCK-2"} <= set(p["displays"]), p)
    nlog = len(open(slog, errors="replace").read().splitlines())

    # ---- 2 a plug ----
    # (the nested env's own backend output WAYLAND-1 is a "never seen" display too and toasts at the start: count against a baseline)
    toast = lambda t, w: t.endswith(w) and (w != " connected" or not t.endswith(" disconnected"))
    base_c = len([t for t in titles() if toast(t, " connected")])
    # (unknown only until the service has recorded the display and the engine was loaded again: on a fast machine that is over before the
    # glyph has been asked, so the state file is watched from before the plug)
    seen_unknown, plugged = set(), threading.Event()

    def watch():
        while not plugged.is_set():
            try:
                seen_unknown.update(json.load(open(B + "/rt/lares/panorama.json")).get("unknown", []))
            except Exception:
                pass
            time.sleep(0.004)
    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    hc("output", "create", "headless", "LOCK-3")
    got = wait_for(lambda: pano()["panes"] == 3 and "LOCK-3" in pano()["displays"], 10)
    check("2 plug: the glyph's count follows (panes 3, LOCK-3 listed)", got, pano())
    ok = wait_for(lambda: "headless:LOCK-3" in seen_unknown, 8)
    plugged.set()
    check("2 plug: the engine's state lists LOCK-3 unknown", ok, sorted(seen_unknown))
    check("2 plug: a connected toast", wait_for(lambda: len([t for t in titles() if toast(t, " connected")]) > base_c, 6), titles())
    time.sleep(1.5)
    n = [t for t in titles() if toast(t, " connected")]
    check("2 plug: exactly one new connected toast", len(n) == base_c + 1, n)
    w = log_warnings(slog, nlog)
    check("2 plug: no new warning in the shell's log", not w, w[:3])

    # ---- 3 the popup, the hover, the identify ink ----
    st = probe()
    gx, gy = glyph_centre(st, "LOCK-1")
    click("LOCK-1", gx, gy, 1.0)
    st = probe()
    tiles = (st["screens"]["LOCK-1"]["popup"] or {}).get("panoTiles")
    def _tiles():
        pp = probe()["screens"]["LOCK-1"]["popup"] or {}
        return pp.get("panoTiles") if pp.get("owner") == "panorama" else None
    opened = wait_for(_tiles, 6)
    check("3 popup: opened by a real click on the glyph, LOCK-3's tile is there", opened and "LOCK-3" in opened, st["screens"]["LOCK-1"]["popup"])
    if opened and "LOCK-3" in opened:
        time.sleep(1.0)
        tiles = probe()["screens"]["LOCK-1"]["popup"]["panoTiles"]
        x, y, w_, h_ = tiles["LOCK-3"]
        before = shot("before", "LOCK-3")
        move("LOCK-1", x + w_ / 2, y + h_ / 2, 0.4)
        move("LOCK-1", x + w_ / 2 + 3, y + h_ / 2 + 2, 0.2)
        got = wait_for(lambda: pano()["identify"] == "LOCK-3", 4)
        check("3 identify: the service says LOCK-3 after a rest on its tile", got, pano()["identify"])
        time.sleep(0.8)      # the presence fade
        p3, p1 = shot("on", "LOCK-3"), shot("on", "LOCK-1")
        n3, tot = edge_blue(p3, "LOCK-3")
        n1, _ = edge_blue(p1, "LOCK-1")
        nb, _ = edge_blue(before, "LOCK-3")
        check("3 identify: ink -- the accent ring is at LOCK-3's edge (not before, not on LOCK-1)", n3 >= tot - 2 and nb == 0 and n1 == 0, "LOCK-3 %d/%d, before %d, LOCK-1 %d" % (n3, tot, nb, n1))
        # leave the tile: onto the popup's own title area, which is no tile
        px, py = tiles["LOCK-1"][0] + tiles["LOCK-1"][2] / 2, tiles["LOCK-1"][1] - 6
        move("LOCK-1", gx, gy + 3, 0.3)
        move("LOCK-1", gx + 2, gy + 6, 0.3)
        check("3 identify: leaving the tile clears it", wait_for(lambda: pano()["identify"] == "", 4), pano()["identify"])
        # 3b a click on a tile opens that display's settings beside the popup, ON the screen (the glyph stands near the right edge: a
        # panel asked for on the right had no room there and never showed)
        click("LOCK-1", x + w_ / 2, y + h_ / 2, 1.2)
        def _side():
            cs = probe()["screens"]["LOCK-1"].get("children") or []
            return [c for c in cs if c["owner"] == "panorama/secondary" and c["phase"] == "open"]
        side = wait_for(_side, 6)
        sw = probe()["screens"]["LOCK-1"]["width"]
        ok = bool(side) and side[0]["box"][2] > 100 and side[0]["box"][0] >= 0 and side[0]["box"][0] + side[0]["box"][2] <= sw
        check("3b a click on LOCK-3's tile opens its settings, inside the screen", ok,
              "children %s, screen width %s" % (probe()["screens"]["LOCK-1"].get("children"), sw))
    sh(E, "key", "Escape")
    sh(E, "key", "Escape")
    wait_for(lambda: not probe()["screens"]["LOCK-1"]["popup"]["open"], 4)

    # ---- 4 ddcutil ----
    calls = open(ddclog).read().splitlines() if os.path.exists(ddclog) else []
    check("4 the ddcutil stub saw only `detect` (%d calls)" % len(calls), calls and all(c.split()[:1] == ["detect"] for c in calls), calls)

    # ---- 5 unplug ----
    hc("output", "remove", "LOCK-3")
    check("5 unplug: panes back to 2", wait_for(lambda: pano()["panes"] == 2 and "LOCK-3" not in pano()["displays"], 10), pano())
    check("5 unplug: a disconnected toast", wait_for(lambda: any(t.endswith(" disconnected") for t in titles()), 6), titles())

    # ---- 6 the whole log ----
    time.sleep(1.0)
    w = [l for l in log_warnings(slog) if re.search(r"modules/(panorama|osd)|ShellServices|ShellFrame|ShellScreen", l)]
    check("6 the shell's whole log: no warning naming panorama / osd / ShellServices / ShellFrame / ShellScreen", not w, w[:3])
    failed = [n for n, ok in results if not ok]
    print("PANORAMA_SHELL_ENV RESULT %s (%d checks%s)" % ("FAIL" if failed else "PASS", len(results), ": " + "; ".join(failed) if failed else ""))
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        if mode == "mirror-seed":
            sys.exit(mirror_seed())
        if mode == "mirror-after":
            sys.exit(mirror_after(sys.argv[5]))
        sys.exit(seed() if mode == "seed" else run())
    except Exception as e:
        print("PANORAMA_SHELL_ENV RESULT FAIL (driver threw: %r)" % (e,))
        sys.exit(1)
