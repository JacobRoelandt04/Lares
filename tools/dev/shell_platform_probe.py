#!/usr/bin/env python3
"""The checks of tools/dev/shell_probe.sh: the REAL shell.qml (mock services) in the nested Hyprland of tools/dev/lock_env.sh.

Called by the runner with the environment up, the client (tools/dev/qml/shell_platform_probe.qml: a Background-layer window per
output that counts the clicks it gets) and the shell running. Everything is read from the compositor (hyprctl, the Lua
API's layers) and from the shell's own IPC (`shell probe`, `status`, `census`); everything is driven by the virtual
pointer. Prints one `SHELL_PLATFORM <name> PASS|FAIL (...)` per check and exits 0 when none failed.

  ARGV:  <root> <sandbox> <lock_env_name> <client_log> <shell_log> [ONLY...]

THE SCALE (round 2, stream SC). SCALE (the shell's configured global, default 1) and HYPR_SCALE (Hyprland's own scale of LOCK-1,
default 1; LOCK-2 stays 1) come in the environment. Everything the shell says (`shell probe`) is in DESIGN px and everything the
pointer and the compositor speak is in LOGICAL px; K = SCALE / the output's Hyprland scale is the bridge (the frame's Item scale),
so a design coordinate is multiplied by K on its way out through move() / click() and a compositor length is compared with the
design one times K. At SCALE = HYPR_SCALE = 1 nothing changes.

THE RATIOS (round 2, stream EL). BAR_RATIO and POPUP_RATIO (default 1) are shell.json's `scale.bar` / `scale.popup`: the main bar and its
modules are BAR_RATIO times their design size in the frame (TOP below: its thickness, its reserve, its foot), a popup's content is drawn
POPUP_RATIO times larger (BAR_RATIO for a strip that continues its bar cell). The shell's numbers (`shell probe`) are the frame's; K bridges
them to the compositor as before. At both 1 nothing changes.
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT, SB, ENVNAME, CLIENT_LOG, SHELL_LOG = sys.argv[1:6]
ONLY = set(sys.argv[6:])
E = os.path.join(ROOT, "tools", "dev", "lock_env.sh")
ENV = dict(os.environ, LOCK_ENV=ENVNAME)
SHELL_QML = os.path.join(SB, "shell.qml")
CFG_SCALE = float(os.environ.get("SCALE", "1") or 1)
HYPR_SCALE = float(os.environ.get("HYPR_SCALE", "1") or 1)
OUT2_SCALE = float(os.environ.get("SCALE_OUT2", "") or 0)       # LOCK-2's own entry in the scale block (0: none)
BAR_RATIO = float(os.environ.get("BAR_RATIO", "1") or 1)         # shell.json `scale.bar`
POPUP_RATIO = float(os.environ.get("POPUP_RATIO", "1") or 1)     # shell.json `scale.popup`
TOP = 40 * BAR_RATIO       # the main bar's thickness and reserve, in the frame's px
MID = 20 * BAR_RATIO       # its middle line


def cfgof(name):
    """The scale CONFIGURED for one output: its own entry when the block has one (it wins), else the global."""
    return OUT2_SCALE if (name == "LOCK-2" and OUT2_SCALE > 0) else CFG_SCALE


def kof(name):
    """The frame's Item scale on one output: the configured scale over Hyprland's own scale of that output."""
    return cfgof(name) / (HYPR_SCALE if name == "LOCK-1" else 1.0)

fails = 0
checks = 0


def sh(*args, timeout=30):
    r = subprocess.run(list(args), cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=timeout)
    return (r.stdout or "") + (r.stderr or "")


def say(name, ok, detail=""):
    global fails, checks
    checks += 1
    if not ok:
        fails += 1
    print(f"SHELL_PLATFORM {name} {'PASS' if ok else 'FAIL'} ({detail})", flush=True)


MANUAL = {"p13"}     # groups that need the runner told so (p13: SHP_WATCH=1, the file watcher on): run only when named


def want(group):
    if group in MANUAL:
        return group in ONLY
    return not ONLY or group in ONLY


def ipc(fn, *args):
    return sh(E, "run", "quickshell", "ipc", "-p", SHELL_QML, "call", "shell", fn, *args).strip()


def probe():
    for _ in range(5):
        t = ipc("probe")
        try:
            return json.loads(t)
        except ValueError:
            time.sleep(0.3)
    raise RuntimeError("no probe answer: " + t[:200])


def monitors():
    return json.loads(sh(E, "hyprctl", "-j", "monitors"))


def lw(m):
    """A monitor's LOGICAL width / height (its mode over its scale): what the layout, the pointer and the layers speak."""
    return m["width"] / (m["scale"] or 1.0)


def lh(m):
    return m["height"] / (m["scale"] or 1.0)


def bbox():
    ms = monitors()
    x0 = min(m["x"] for m in ms)
    y0 = min(m["y"] for m in ms)
    x1 = max(m["x"] + lw(m) for m in ms)
    y1 = max(m["y"] + lh(m) for m in ms)
    return x0, y0, round(x1 - x0), round(y1 - y0)


def mon(name):
    return [m for m in monitors() if m["name"] == name][0]


def point_cmd(name, x, y):
    """x, y in the output's LOGICAL px."""
    # WHOLE numbers: the virtual pointer ignores an `abs` with a decimal point ("1720.0"), and says nothing
    x0, y0, w, h = bbox()
    m = mon(name)
    return f"abs {round(m['x'] + x - x0)} {round(m['y'] + y - y0)} {w} {h}"


def move(name, x, y, wait=0.25):
    """x, y in DESIGN px (what `shell probe` speaks): times K on its way to the pointer."""
    k = kof(name)
    sh(E, "point", point_cmd(name, x * k, y * k))
    time.sleep(wait)


def click(name, x, y, settle=0.6, logical=False):
    # Hyprland re-evaluates what the pointer is over on MOTION only: a click on the spot it already rests on goes to
    # whatever it focused before an input region changed (the bg window, after the bars came back). So step in first.
    # x, y in DESIGN px, or in the output's LOGICAL px when `logical` (an exact distance from an edge).
    k = 1.0 if logical else kof(name)
    x, y = x * k, y * k
    sh(E, "point", point_cmd(name, x - 3, y), "sleep 80", point_cmd(name, x, y), "sleep 120", "click")
    time.sleep(settle)


def bg_clicks():
    try:
        txt = open(CLIENT_LOG, errors="ignore").read()
    except OSError:
        return []
    return re.findall(r"SHP bg click (\S+) (\d+) (\d+)", txt)


def wait_for(cond, timeout=6.0, step=0.15):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            v = cond()
        except Exception:
            v = None
        if v:
            return v
        time.sleep(step)
    return None


def screen(st, name):
    return st["screens"].get(name)


def popup(st, name):
    s = screen(st, name)
    return s["popup"] if s else None


def reel(st, name):
    """The reel slot's state (the power and idle reels' strip, beside thePopup)."""
    s = screen(st, name)
    return s["reel"] if s else None


def centre_of(st, name, module, frac=0.5):
    """Screen coordinates of a module's button: its island's rawPos + its place in the island."""
    s = screen(st, name)
    z = {"power": "topL", "idle": "topL", "theme": "topL", "notes": "topL", "llm": "topL", "windowtray": "topL",
         "weather": "topC", "clock": "topC", "stocks": "topC"}.get(module, "topR")
    bar = [b for b in s["bars"] if b["id"] == z] or [b for b in s["bars"] if b["id"] == "top"]
    b = bar[0]
    base = 0 if b["id"] != "top" else 0
    p = s["placed"][module]
    # the clock module is the groove with the button in its middle
    return b["rawPos"] + base + (p["x"] + p["width"] * frac) * BAR_RATIO, MID


def interactivity():
    """The compositor's view of each lares-bar surface's keyboard mode: { output: 0 none | 1 exclusive | 2 on demand }."""
    out = sh(E, "hyprctl", "eval",
             'local t = {} for _, l in ipairs(hl.get_layers()) do if l.namespace == "lares-bar" then '
             't[#t+1] = tostring(l.monitor):match(":(.-)%)") .. "=" .. tostring(l.keyboard_interactivity) end end '
             'error("INTERACT " .. table.concat(t, ","))')
    m = re.search(r"INTERACT (.*)", out)
    d = {}
    if m:
        for kv in m.group(1).split(","):
            if "=" in kv:
                k, v = kv.split("=")
                d[k] = int(v)
    return d


def layers():
    out = json.loads(sh(E, "hyprctl", "-j", "layers"))
    return out


# ------------------------------------------------------------------------------------------------------------------
# p1: the shell is up
# ------------------------------------------------------------------------------------------------------------------
st0 = probe()
names = sorted(st0["screens"].keys())
LAP, ULT = "LOCK-1", "LOCK-2"

if want("p1"):
    log = open(SHELL_LOG, errors="ignore").read()
    ready = re.search(r"LARES ready screens=(\d+)", log)
    say("p1.ready-line", bool(ready) and ready.group(1) == "2", ready.group(0) if ready else "none")
    say("p1.mock-mode", "LARES mode=mock" in log, "mode " + st0["mode"])
    stat = json.loads(ipc("status"))
    say("p1.status", stat["screens"] == 2 and stat["mode"] == "mock" and stat["polkit"] is True and stat["bars"] is True and stat["ready"] is True, json.dumps(stat))
    say("p1.ping", ipc("ping") == "ok", "ping")
    census = json.loads(ipc("census"))
    dup = {t: n for t, n in census["counts"].items() if n > 1}
    say("p1.census-one-of-each", not dup and "BatteryData" not in census["counts"], json.dumps(dup) if dup else f"{len(census['counts'])} types, no BatteryData")
    say("p1.two-screens", names == [LAP, ULT], ",".join(names))
    # a missing member is a FAILURE, not a skip: an owner without `shellHosted` would build its own service and register its own shortcut
    hosted = ["clock", "stocks", "silicon", "bridge", "panorama", "notes", "launcher", "clipboard", "notifications", "aerial", "windowtray"]
    missing = [k for k in hosted if not st0["hosted"].get(k)]
    say("p1.owners-take-the-hosted-contract", not missing and st0.get("osdActive") is True, ("without shellHosted: " + ",".join(missing)) if missing else f"{len(hosted)} owners hosted, the OSD owner reads the focus tracker")

# ------------------------------------------------------------------------------------------------------------------
# p2: the layers the compositor holds
# ------------------------------------------------------------------------------------------------------------------
if want("p2"):
    L = layers()
    ok = True
    parts = []
    for name in (LAP, ULT):
        mls = L.get(name, {})
        levels = mls.get("levels", {}) if isinstance(mls, dict) else {}
        top = [l for l in levels.get("2", []) if l.get("namespace") == "lares-bar"]
        ov = [l for l in levels.get("3", []) if l.get("namespace") == "osd-pill"]
        m = mon(name)
        full = bool(top) and top[0]["w"] == round(lw(m)) and top[0]["h"] == round(lh(m))
        # (perf phase 2, MAP.md #1) one exposed window per output: the bar's. The OSD pill maps while it shows, the reserve is the output's (HyprReserve): a helper
        # window mapped at rest takes every animation of the process off vsync
        extra = [l.get("namespace") for lv in levels.values() for l in lv if l.get("namespace") not in ("lares-bar", "shp-bg")]
        parts.append(f"{name}: lares-bar on Top {'full' if full else 'MISSING/SMALL'}, the shell's other layers at rest {extra}")
        ok = ok and full and not ov and not extra
    say("p2.layers", ok, "; ".join(parts))
    res = {m["name"]: m["reserved"][1] for m in monitors()}
    # the reserve is the bar's 40 design px x its ratio x K, whole (an exclusive zone is an integer of the compositor's px) and rounded UP
    # (ShellLayout.windowReserve, ENGGEO: a window stands clear of the bar's edge, never under it -- 33.3 -> 34 at K 1.25/1.5)
    want_res = {n: -(-int(round(TOP * kof(n) * 1000)) // 1000) for n in (LAP, ULT)}
    say("p2.reserve-40-on-top", res.get(LAP) == want_res[LAP] and res.get(ULT) == want_res[ULT], f"{json.dumps(res)} want {json.dumps(want_res)}")
    # r3 (ENGGEO): the slim bars reserve their own room so a window with gaps_out 0 stands clear of them -- the outlet is 6 COMPOSITOR px at
    # every scale (ShellFrame.slim = 6 / k: Hyprland's own gaps_out, never scaled) + the shell's border ring (off in this env), rounded UP
    # (ShellLayout.windowReserve); left, right and bottom. (Until 2026-10-25 this said 6 x K, which only a scale-1 run could not tell apart.)
    want_slim = {n: 6 for n in (LAP, ULT)}
    got_slim = {m["name"]: [m["reserved"][0], m["reserved"][2], m["reserved"][3]] for m in monitors()}
    say("p2.slim-bars-reserve-their-room", all(got_slim.get(n) == [want_slim[n]] * 3 for n in (LAP, ULT)),
        f"{json.dumps(got_slim)} want {json.dumps({n: [want_slim[n]] * 3 for n in (LAP, ULT)})}")

# ------------------------------------------------------------------------------------------------------------------
# p3: the input mask -- the slim bars and every void pass the pointer to what is under them
# ------------------------------------------------------------------------------------------------------------------
if want("p3"):
    st = probe()
    for name in (LAP, ULT):
        s = screen(st, name)
        W, H = s["width"], s["height"]
        isl = {b["id"]: b for b in s["bars"] if b["edge"] == "top"}
        mid_c = isl["topC"]["rawPos"] + isl["topC"]["rawLen"] / 2
        gap_x = (isl["topL"]["rawLen"] + isl["topC"]["rawPos"]) / 2
        pad_x = isl["topL"]["rawPos"] + 4
        cases = [("island-padding", pad_x, MID, "shell"), ("void", gap_x, MID, "bg"), ("bottom-edge", W / 2, H - 3, "bg"),
                 ("right-edge", W - 3, H / 2, "bg"), ("left-edge", 3, H / 2, "bg"), ("middle", W / 2, H / 2, "bg"),
                 ("under-island", mid_c, TOP + 20, "bg")]
        res = []
        for label, x, y, wantw in cases:
            n0 = len([c for c in bg_clicks() if c[0] == name])
            click(name, x, y, 0.5)
            n1 = len([c for c in bg_clicks() if c[0] == name])
            got = "bg" if n1 > n0 else "shell"
            res.append((label, got, wantw))
        bad = [f"{l}: went to {g}, want {w}" for l, g, w in res if g != w]
        say(f"p3.{name}.input-mask", not bad, "; ".join(bad) if bad else ", ".join(f"{l}->{g}" for l, g, w in res))
    # nothing under a click that the shell took opened anything (the island's own empty area)
    st = probe()
    say("p3.no-popup-from-stray-clicks", not any(s["popup"]["open"] for s in st["screens"].values()), "")

# ------------------------------------------------------------------------------------------------------------------
# p4: every button's real click opens its popup on its outlet, on the output it was clicked on; p5: and the keyboard
# ------------------------------------------------------------------------------------------------------------------
BUTTONS = [("notes", "notes", "left", 0.5), ("llm", "llm", "left", 0.5), ("windowtray", "windowtray", None, 0.18), ("clock", "clock", None, 0.5), ("stocks", "stocks", None, 0.5),
           ("weather", "weather", None, 0.5), ("player", "player", None, 0.5), ("aerial", "aerial", None, 0.5), ("bridge", "bridge", None, 0.5), ("panorama", "panorama", None, 0.5), ("silicon", "silicon", None, 0.5),
           ("update", "update", None, 0.5), ("notifications", "notifications", None, 0.5)]
KB = {0: "none", 1: "exclusive", 2: "onDemand"}
if want("p4"):
    kb_seen = {}
    for out in (LAP, ULT):
        for mod, key, bar, frac in BUTTONS:
            st = probe()
            x, y = centre_of(st, out, mod, frac)
            # the tray's strip is the reel slot's (GooeyEngine THE REEL SLOT): it opens beside thePopup, not as it
            slot = reel if mod == "windowtray" else popup
            click(out, x, y, 0.2)
            ok = wait_for(lambda: (lambda p: p["open"] and p["owner"] == key and p["phase"] == "open")(slot(probe(), out)), 20 if mod == "silicon" else 6)
            st = probe()
            p = slot(st, out)
            want_bar = bar or [b["id"] for b in screen(st, out)["bars"] if b["edge"] == "top"
                               and b["rawPos"] <= x <= b["rawPos"] + b["rawLen"]][0]
            other = LAP if out == ULT else ULT
            fine = bool(ok) and (slot is reel or p["bar"] == want_bar) and not slot(st, other)["open"]
            say(f"p4.{out}.{mod}", fine, f"{'reel' if slot is reel else 'popup'} {p['owner']}/{p['phase']} on {p.get('bar', '-')} (want {key} on {want_bar}), other output {'open' if slot(st, other)['open'] else 'closed'}")
            # p5: the layer's keyboard mode is the engine's request, as the compositor holds it
            time.sleep(0.2)
            inter = interactivity()
            eng = screen(st, out)["keyboardFocus"]
            kb_seen[(out, mod)] = (eng, inter.get(out))
            exp = {"none": 0, "onDemand": 2, "exclusive": 1}[eng]
            say(f"p5.{out}.{mod}.keyboard-mode", inter.get(out) == exp, f"engine says {eng}, compositor holds {KB.get(inter.get(out))}")
            # close with a second click (the toggle), and wait until it is shut
            click(out, x, y, 0.2)
            wait_for(lambda: not slot(probe(), out)["open"], 5)
    # one line of the table, for the report
    print("SHELL_PLATFORM p5.table " + json.dumps({f"{o}/{m}": v for (o, m), v in kb_seen.items() if o == LAP}), flush=True)

# ------------------------------------------------------------------------------------------------------------------
# p16: a LEFT click on the volume pill (the right one mutes; 2026-10-31), either half, opens the audio popup on that output; a second one closes it
# ------------------------------------------------------------------------------------------------------------------
if want("p16"):
    for out in (LAP, ULT):
        for frac, half in ((0.25, "speaker"), (0.75, "mic")):
            st = probe()
            x, y = centre_of(st, out, "volume", frac)
            k = kof(out)
            sh(E, "point", point_cmd(out, x * k - 3, y * k), "sleep 80", point_cmd(out, x * k, y * k), "sleep 120", "click")
            ok = wait_for(lambda: (lambda p: p["open"] and p["owner"] == "audio" and p["phase"] == "open")(popup(probe(), out)), 6)
            p = popup(probe(), out)
            say(f"p16.{out}.{half}.left-click-opens-the-audio-popup", bool(ok), f"popup {p['owner']}/{p['phase']} on {p['bar']}")
            sh(E, "point", point_cmd(out, x * k - 3, y * k), "sleep 80", point_cmd(out, x * k, y * k), "sleep 120", "click")
            shut = wait_for(lambda: not popup(probe(), out)["open"], 5)
            say(f"p16.{out}.{half}.a-second-closes-it", bool(shut))

# ------------------------------------------------------------------------------------------------------------------
# p6: the reels open on hover; the strip hangs from its cell
# ------------------------------------------------------------------------------------------------------------------
if want("p6"):
    for mod in ("power", "idle"):
        st = probe()
        x, y = centre_of(st, LAP, mod)
        move(LAP, x, y, 0.1)
        ok = wait_for(lambda: (lambda p: p["open"] and p["owner"] == mod and p["phase"] == "open")(reel(probe(), LAP)), 5)
        p = reel(probe(), LAP)
        say(f"p6.{mod}.opens-on-hover", bool(ok), f"reel {p['owner']}/{p['phase']}")
        say(f"p6.{mod}.leaves-thePopup-alone", not popup(probe(), LAP)["open"], f"popup {popup(probe(), LAP)['owner']}")
        move(LAP, 1400, 800, 0.2)
        say(f"p6.{mod}.closes-when-the-pointer-leaves", bool(wait_for(lambda: not reel(probe(), LAP)["open"], 5)), "")

# ------------------------------------------------------------------------------------------------------------------
# p7: the shortcuts, by dispatch (a press and no release), act on the FOCUSED output
# ------------------------------------------------------------------------------------------------------------------
def dispatch_global(name):
    return sh(E, "hyprctl", "dispatch", f'hl.dsp.global("lares:{name}")').strip()


def focused_output():
    return [m["name"] for m in monitors() if m["focused"]][0]


if want("p7"):
    for out in (LAP, ULT):
        move(out, 1200, 700, 0.5)
        say(f"p7.focus-follows-the-pointer.{out}", focused_output() == out, "focused " + focused_output())
        st = probe()
        say(f"p7.{out}.shell-agrees-on-the-focus", st["focused"] == out, "shell says " + st["focused"])
        r = dispatch_global("clipboard")
        ok = wait_for(lambda: (lambda p: p["open"] and p["owner"] == "clipboard" and p["phase"] == "open")(popup(probe(), out)), 8)
        st = probe()
        other = LAP if out == ULT else ULT
        say(f"p7.{out}.clipboard-opens-here-only", bool(ok) and not popup(st, other)["open"] and popup(st, out)["bar"] == "bottom",
            f"{out}: {popup(st, out)['owner']}/{popup(st, out)['phase']} on {popup(st, out)['bar']}, {other}: {'open' if popup(st, other)['open'] else 'closed'} ({r})")
        # A popup opened by a KEY has no pointer on it: its keys are held by a HyprlandFocusGrab over the bar window, and with
        # a grab the owner asks the layer for NO keyboard -- an Exclusive request clears the grab at once and the popup closes
        # itself. So: the layer's mode is not Exclusive, and the popup is still there two seconds on (nothing cleared the grab).
        time.sleep(2.0)
        inter = interactivity()
        still = popup(probe(), out)
        say(f"p7.{out}.clipboard-held-by-a-grab", still["open"] and still["owner"] == "clipboard" and inter.get(out) != 1,
            f"after 2 s: {still['owner']}/{still['phase']}, the layer's keyboard mode {KB.get(inter.get(out))} (engine {screen(st, out)['keyboardFocus']})")
        dispatch_global("clipboard")
        say(f"p7.{out}.clipboard-closes-on-the-second-press", bool(wait_for(lambda: not popup(probe(), out)["open"], 6)), "")
        dispatch_global("notes")
        ok = wait_for(lambda: (lambda p: p["open"] and p["owner"] == "notes" and p["phase"] == "open")(popup(probe(), out)), 6)
        st = probe()
        say(f"p7.{out}.notes-opens-out-of-the-left-bar", bool(ok) and popup(st, out)["bar"] == "left", f"{popup(st, out)['owner']} on {popup(st, out)['bar']}")
        time.sleep(2.0)
        still = popup(probe(), out)
        say(f"p7.{out}.notes-held-by-a-grab", still["open"] and still["owner"] == "notes" and interactivity().get(out) != 1,
            f"after 2 s: {still['owner']}/{still['phase']}, the layer's keyboard mode {KB.get(interactivity().get(out))}")
        dispatch_global("notes")
        wait_for(lambda: not popup(probe(), out)["open"], 6)
    # the launcher (it asks hyprctl first, then opens)
    move(LAP, 1200, 700, 0.5)
    dispatch_global("launcher")
    ok = wait_for(lambda: (lambda p: p["open"] and p["owner"] == "launcher")(popup(probe(), LAP)), 12)
    say("p7.launcher-opens-out-of-the-bottom-bar", bool(ok) and popup(probe(), LAP)["bar"] == "bottom", f"{popup(probe(), LAP)['owner']} on {popup(probe(), LAP)['bar']}")
    time.sleep(2.0)
    still = popup(probe(), LAP)
    say("p7.launcher-held-by-a-grab", still["open"] and still["owner"] == "launcher" and interactivity().get(LAP) != 1,
        f"after 2 s: {still['owner']}/{still['phase']}, the layer's keyboard mode {KB.get(interactivity().get(LAP))}")
    dispatch_global("launcher")
    wait_for(lambda: not popup(probe(), LAP)["open"], 8)

# ------------------------------------------------------------------------------------------------------------------
# p8: the OSD comes out on the focused output only
# ------------------------------------------------------------------------------------------------------------------
if want("p8"):
    for out in (LAP, ULT):
        move(out, 1200, 700, 0.5)
        sh(E, "run", "quickshell", "ipc", "-p", SHELL_QML, "call", "osd", "test", "volume")
        wait_for(lambda: screen(probe(), out)["osd"]["open"], 4)
        st = probe()
        other = LAP if out == ULT else ULT
        o, p = screen(st, out)["osd"], screen(st, other)["osd"]
        say(f"p8.{out}.osd-only-on-the-focused-output", o["open"] and not p["open"], f"{out}: {o['phase']}, {other}: {p['phase']}")
        sh(E, "run", "quickshell", "ipc", "-p", SHELL_QML, "call", "osd", "dismiss")
        time.sleep(0.8)

# ------------------------------------------------------------------------------------------------------------------
# p9: the bars toggle, with a real pointer
# ------------------------------------------------------------------------------------------------------------------
if want("p9"):
    st = probe()
    s = screen(st, LAP)
    isl = {b["id"]: b for b in s["bars"] if b["edge"] == "top"}
    mid_c = isl["topC"]["rawPos"] + isl["topC"]["rawLen"] / 2
    ipc("bars", "0")
    wait_for(lambda: screen(probe(), LAP)["hideT"] >= 0.999, 4)
    time.sleep(0.4)
    st = probe()
    res = {m["name"]: m["reserved"] for m in monitors()}
    say("p9.reserve-released", all(v == [0, 0, 0, 0] for v in res.values()), json.dumps(res))
    say("p9.every-bar-gone", all(b["thickness"] < 0.05 for sc in st["screens"].values() for b in sc["bars"]), json.dumps([b["thickness"] for sc in st["screens"].values() for b in sc["bars"]]))
    n0 = len([c for c in bg_clicks() if c[0] == LAP])
    click(LAP, mid_c, MID, 0.4)
    say("p9.a-click-where-the-island-was-passes-through", len([c for c in bg_clicks() if c[0] == LAP]) > n0, "")
    say("p9.mask-is-empty", all(len(sc["mask"]) == 0 for sc in st["screens"].values()), json.dumps([sc["mask"] for sc in st["screens"].values()]))
    ipc("bars", "1")
    wait_for(lambda: screen(probe(), LAP)["hideT"] <= 0.001, 4)
    time.sleep(0.6)
    res = {m["name"]: m["reserved"][1] for m in monitors()}
    up = lambda v: -(-int(round(v * 1000)) // 1000)
    say("p9.reserve-back-after-the-show", res.get(LAP) == up(TOP * kof(LAP)) and res.get(ULT) == up(TOP * kof(ULT)), json.dumps(res))
    n0 = len([c for c in bg_clicks() if c[0] == LAP])
    click(LAP, mid_c, MID, 0.4)
    say("p9.the-island-takes-input-again", len([c for c in bg_clicks() if c[0] == LAP]) == n0, "")
    # the key does the same
    dispatch_global("bars")
    say("p9.key-hides", bool(wait_for(lambda: probe()["barsShown"] is False, 3)), "")
    dispatch_global("bars")
    say("p9.key-shows", bool(wait_for(lambda: probe()["barsShown"] is True, 3)), "")
    time.sleep(0.8)

# ------------------------------------------------------------------------------------------------------------------
# p10: the aggregation, on the real screens: one output's popup closing does not drop what the other's still holds
# ------------------------------------------------------------------------------------------------------------------
if want("p10"):
    outs = {}
    for out in (LAP, ULT):
        st = probe()
        x, y = centre_of(st, out, "update")
        click(out, x, y, 0.2)
        wait_for(lambda: popup(probe(), out)["owner"] == "update" and popup(probe(), out)["phase"] == "open", 8)
        outs[out] = (x, y)
    st = probe()
    say("p10.both-open-the-flag-is-set", st["written"]["updatesPopupOpen"] is True, json.dumps(st["written"]))

    def settle(out, want_open):
        wait_for(lambda: popup(probe(), out)["open"] == want_open and (not want_open or popup(probe(), out)["phase"] == "open"), 8)

    # Close each output's popup in turn while the OTHER one stays open: the flag is the OR of the screens', so it holds either
    # way. (A flag written by the LAST screen only would survive one order and drop in the other -- so both orders are run.)
    for closing, staying in ((LAP, ULT), (ULT, LAP)):
        click(closing, *outs[closing], 0.2)
        settle(closing, False)
        time.sleep(0.3)
        st = probe()
        say(f"p10.closing-{closing}-keeps-it-while-{staying}-is-open", st["written"]["updatesPopupOpen"] is True and popup(st, staying)["open"],
            json.dumps(st["written"]))
        click(closing, *outs[closing], 0.2)   # open it again for the next round
        settle(closing, True)
    click(LAP, *outs[LAP], 0.2)
    click(ULT, *outs[ULT], 0.2)
    settle(LAP, False)
    settle(ULT, False)
    time.sleep(0.4)
    st = probe()
    say("p10.all-closed-drops-it", st["written"]["updatesPopupOpen"] is False, json.dumps(st["written"]))

# ------------------------------------------------------------------------------------------------------------------
# p15: an output replaced in one go keeps its frame in the registry (a GPU switch, a re-plug). The new frame registers before the old one is
# destroyed, under the same name; taking the name out at the old frame's end dropped the LIVE frame, and with it every flag of that screen:
# a popup open there told no service so (feedback/silicon.md "Instance where it all froze": silicon's ladder halted for good, the pointer deaf)
# ------------------------------------------------------------------------------------------------------------------
if want("p15"):
    sh(E, "hyprctl", "output", "create", "headless", "LOCK-3")
    ok = wait_for(lambda: "LOCK-3" in probe()["screens"], 8)
    say("p15.the-output-is-up", bool(ok), ",".join(sorted(probe()["screens"].keys())))
    kept = True
    for i in range(int(os.environ.get("P15_ROUNDS", "5"))):
        print(sh(E, "hyprctl", "--batch", "output remove LOCK-3 ; output create headless LOCK-3").strip().replace("\n", " "))
        time.sleep(1.5)
        here = any(m["name"] == "LOCK-3" for m in monitors())
        st = probe()
        if here and "LOCK-3" not in st["screens"]:
            kept = wait_for(lambda: "LOCK-3" in probe()["screens"], 4)
            if not kept:
                say("p15.replaced-output-keeps-its-frame", False, f"round {i}: the compositor has LOCK-3, the registry {sorted(st['screens'].keys())}")
                break
    if kept:
        say("p15.replaced-output-keeps-its-frame", True, "")
        # (laid out first: the replaced output's window is configured by the compositor, late under load)
        wait_for(lambda: screen(probe(), "LOCK-3").get("width", 0) > 0, 10)
        st = probe()
        s3 = screen(st, "LOCK-3")
        say("p15.and-it-has-its-bars", len(s3["bars"]) == 6, f"{len(s3['bars'])} bars")
        # the whole way: a popup opened on the replaced output reaches the service, so silicon's ladder hears it
        x, y = centre_of(st, "LOCK-3", "silicon")
        # (a new headless output comes up at scale 2: the frame's px are not the compositor's here)
        f3 = lw(mon("LOCK-3")) / s3["width"]
        time.sleep(1.0)
        click("LOCK-3", x * f3, y * f3, 0.2, logical=True)
        wait_for(lambda: popup(probe(), "LOCK-3")["owner"] == "silicon" and popup(probe(), "LOCK-3")["phase"] == "open", 20)
        st = probe()
        say("p15.a-popup-there-reaches-the-service", popup(st, "LOCK-3")["owner"] == "silicon" and st["written"]["siliconPopupOpen"] is True,
            f"{popup(st, 'LOCK-3')['owner']}/{popup(st, 'LOCK-3')['phase']} {json.dumps(st['written'])}")
        click("LOCK-3", x * f3, y * f3, 0.2, logical=True)
        wait_for(lambda: not popup(probe(), "LOCK-3")["open"], 8)
    sh(E, "hyprctl", "output", "remove", "LOCK-3")
    wait_for(lambda: "LOCK-3" not in probe()["screens"], 8)
    say("p15.the-shell-is-still-answering", ipc("ping") == "ok", "")

# ------------------------------------------------------------------------------------------------------------------
# p11: a plugged output gets a bar and an unplugged one loses it; nothing is built twice
# ------------------------------------------------------------------------------------------------------------------
if want("p11"):
    sh(E, "hyprctl", "output", "create", "headless", "LOCK-3")
    ok = wait_for(lambda: "LOCK-3" in probe()["screens"], 8)
    st = probe()
    say("p11.plug-adds-a-screen", bool(ok), ",".join(sorted(st["screens"].keys())))
    if ok:
        # Read the new frame once the compositor has configured its window (width > 0): a loaded nested compositor answers late,
        # and a frame with no size yet has no bars laid out and no reserve to read.
        wait_for(lambda: screen(probe(), "LOCK-3").get("width", 0) > 0, 10)
        st = probe()
        s3 = screen(st, "LOCK-3")
        say("p11.the-new-screen-has-its-bars", len(s3["bars"]) == 6 and abs(s3["reserve"]["top"] - TOP) < 1e-6, f"{len(s3['bars'])} bars, reserve {s3['reserve']}")
        census = json.loads(ipc("census"))
        dup = {t: n for t, n in census["counts"].items() if n > 1}
        say("p11.services-still-one-of-each", not dup, json.dumps(dup))
    sh(E, "hyprctl", "output", "remove", "LOCK-3")
    ok = wait_for(lambda: "LOCK-3" not in probe()["screens"], 8)
    st = probe()
    say("p11.unplug-removes-it", bool(ok) and sorted(st["screens"].keys()) == [LAP, ULT], ",".join(sorted(st["screens"].keys())))
    say("p11.the-shell-is-still-answering", ipc("ping") == "ok", "")

# ------------------------------------------------------------------------------------------------------------------
# p12: the scale (R2-CONTRACT 1). The frame is laid out in DESIGN px and drawn K times larger (K = SCALE / the output's Hyprland scale);
# everything the compositor is told is in LOGICAL px: the reserve, the slim bars' 6 px (Hyprland's gaps_out) and the input regions.
# ------------------------------------------------------------------------------------------------------------------
if want("p12"):
    st = probe()
    for name in (LAP, ULT):
        s = screen(st, name)
        m = mon(name)
        k = kof(name)
        sc = s["scale"]
        say(f"p12.{name}.frame-scale-and-render-scale", abs(sc["frame"] - k) < 1e-6 and abs(sc["render"] - cfgof(name)) < 1e-6,
            f"frame {sc['frame']:.4f} want {k:.4f}; render {sc['render']:.4f} want {cfgof(name):.4f} (device px per design px)")
        say(f"p12.{name}.the-ratios-are-the-configured-ones", abs(sc["bar"] - BAR_RATIO) < 1e-6 and abs(sc["popup"] - POPUP_RATIO) < 1e-6,
            f"bar {sc['bar']:.4f} want {BAR_RATIO:.4f}; popup {sc['popup']:.4f} want {POPUP_RATIO:.4f}")
        say(f"p12.{name}.the-frame-fills-the-output", abs(s["width"] * k - lw(m)) < 1.0 and abs(s["height"] * k - lh(m)) < 1.0,
            f"{s['width']:.2f} x {s['height']:.2f} design px x {k:.4f} = {s['width'] * k:.1f} x {s['height'] * k:.1f} of {lw(m):.0f} x {lh(m):.0f} logical")
        slim = [b for b in s["bars"] if b["id"] in ("right", "bottom", "left")]
        say(f"p12.{name}.slim-bars-are-6-compositor-px", len(slim) == 3 and all(abs(b["thickness"] * k - 6) < 0.05 for b in slim),
            ", ".join(f"{b['id']} {b['thickness']:.3f} design = {b['thickness'] * k:.2f} px" for b in slim))
        isl = {b["id"]: b for b in s["bars"] if b["edge"] == "top"}
        say(f"p12.{name}.islands-are-40-design-px-with-a-whole-reserve", all(abs(b["thickness"] - TOP) < 0.05 for b in isl.values())
            and abs(s["reserve"]["top"] - TOP) < 1e-6, f"thickness {[b['thickness'] for b in isl.values()]}, engine reserve {s['reserve']['top']} (want {TOP:g}: 40 x ratio {BAR_RATIO:g}; x {k:.4f} = {round(TOP * k)})")
        # real pointer, in LOGICAL px: the island's foot is 40 x the bar's ratio x K from the edge
        foot = TOP * k
        mid = (isl["topC"]["rawPos"] + isl["topC"]["rawLen"] / 2) * k
        res = []
        for label, dy, wantw in (("3 px inside the foot", -3, "shell"), ("4 px below the foot", 4, "bg")):
            n0 = len([c for c in bg_clicks() if c[0] == name])
            click(name, mid, foot + dy, 0.5, logical=True)
            n1 = len([c for c in bg_clicks() if c[0] == name])
            res.append((label, "bg" if n1 > n0 else "shell", wantw))
        bad = [f"{l}: went to {g}, want {w}" for l, g, w in res if g != w]
        say(f"p12.{name}.the-island-ends-where-the-scale-says", not bad, "; ".join(bad) if bad else ", ".join(f"{l} -> {g}" for l, g, w in res) + f" (foot {foot:.2f} logical px)")
    # an open popup's input region is the scaled box: 3 px inside its foot is the shell's, 4 px below reaches the window under
    st = probe()
    x, y = centre_of(st, LAP, "stocks", 0.5)
    click(LAP, x, y, 0.2)
    ok = wait_for(lambda: (lambda p: p["open"] and p["owner"] == "stocks" and p["phase"] == "open")(popup(probe(), LAP)), 8)
    time.sleep(0.5)
    p = popup(probe(), LAP)
    k = kof(LAP)
    if ok and p["box"]:
        bx, by, bw, bh = p["box"]
        res = []
        for label, ddy, wantw in (("3 px inside the popup's foot", -3, "shell"), ("4 px below the popup's foot", 4, "bg")):
            n0 = len([c for c in bg_clicks() if c[0] == LAP])
            click(LAP, (bx + bw / 2) * k, (by + bh) * k + ddy, 0.5, logical=True)
            n1 = len([c for c in bg_clicks() if c[0] == LAP])
            res.append((label, "bg" if n1 > n0 else "shell", wantw))
            if n1 > n0:
                pass
        bad = [f"{l}: went to {g}, want {w}" for l, g, w in res if g != w]
        say("p12.the-popup-takes-input-in-its-scaled-box", not bad, "; ".join(bad) if bad else ", ".join(f"{l} -> {g}" for l, g, w in res) + f" (box {p['box']} design px, K {k:.4f})")
    else:
        say("p12.the-popup-takes-input-in-its-scaled-box", False, f"the stocks popup did not open: {p}")
    # leave it shut for whatever runs next
    if popup(probe(), LAP)["open"]:
        sx, sy = centre_of(probe(), LAP, "stocks", 0.5)
        click(LAP, sx, sy, 0.2)
        wait_for(lambda: not popup(probe(), LAP)["open"], 6)

# ------------------------------------------------------------------------------------------------------------------
# p14: the ratios (R2-CONTRACT 1, stream EL). shell.json's `scale.bar` / `scale.popup`: the shell's numbers are the frame's, the bar's are its
# design size x BAR_RATIO (p2, p3, p4, p5, p9 and p12 hold the reserve, the mask, the clicks and the keyboard at it), and a popup's box is its
# content's implicit size x the ratio of ITS body: the popup's for an ordinary content, the bar's for a strip that continues its bar cell.
# ------------------------------------------------------------------------------------------------------------------
if want("p14"):
    st = probe()
    for name in (LAP, ULT):
        s = screen(st, name)
        isl = [b for b in s["bars"] if b["edge"] == "top"]
        slim = [b for b in s["bars"] if b["edge"] != "top"]
        k = kof(name)
        say(f"p14.{name}.bar-and-outlets", all(abs(b["thickness"] - TOP) < 0.05 for b in isl) and all(abs(b["thickness"] * k - 6) < 0.05 for b in slim),
            f"islands {[b['thickness'] for b in isl]} want {TOP:g}; outlets {[round(b['thickness'] * k, 2) for b in slim]} compositor px want 6")
        # every module stands inside its island, at the ratio: its right edge (bar units x ratio from the island's start) is not past the island's
        over = []
        for mod, cell in s["placed"].items():
            zone = {"power": "topL", "idle": "topL", "theme": "topL", "notes": "topL", "llm": "topL", "windowtray": "topL",
                    "weather": "topC", "clock": "topC", "stocks": "topC"}.get(mod, "topR")
            b = [q for q in isl if q["id"] == zone]
            if b and (cell["x"] + cell["width"]) * BAR_RATIO > b[0]["rawLen"] + 0.5:
                over.append(f"{mod} ends at {(cell['x'] + cell['width']) * BAR_RATIO:.1f} of {b[0]['rawLen']:.1f}")
        say(f"p14.{name}.the-modules-fit-the-scaled-islands", not over, "; ".join(over) if over else f"{len(s['placed'])} modules in bar units x {BAR_RATIO:g}")

    def box_vs_content(label, want_ratio):
        p = popup(probe(), LAP)
        if not (p["open"] and p["box"] and p.get("content")):
            say(f"p14.{label}", False, f"not open or no content size: {p}")
            return
        cw, ch = p["content"]
        bw, bh = p["box"][2], p["box"][3]
        okr = abs(p["ratio"] - want_ratio) < 1e-6
        okb = abs(bw - cw * want_ratio) <= 1.5 and abs(bh - ch * want_ratio) <= 1.5
        say(f"p14.{label}", okr and okb, f"body ratio {p['ratio']:.4f} want {want_ratio:g}; box {bw} x {bh}, content {cw:.1f} x {ch:.1f} x {want_ratio:g} = {cw * want_ratio:.1f} x {ch * want_ratio:.1f}")

    # an ordinary popup: the popup's ratio
    x, y = centre_of(st, LAP, "stocks", 0.5)
    click(LAP, x, y, 0.2)
    wait_for(lambda: (lambda p: p["open"] and p["owner"] == "stocks" and p["phase"] == "open")(popup(probe(), LAP)), 8)
    time.sleep(0.5)
    box_vs_content("the-popup-box-is-its-content-times-the-popup-ratio", POPUP_RATIO)
    click(LAP, x, y, 0.2)
    wait_for(lambda: not popup(probe(), LAP)["open"], 6)
    # a strip that continues its bar cell (the power reel): the bar's ratio
    x, y = centre_of(probe(), LAP, "power")
    move(LAP, x, y, 0.1)
    wait_for(lambda: (lambda p: p["open"] and p["owner"] == "power" and p["phase"] == "open")(reel(probe(), LAP)), 6)
    time.sleep(0.5)
    # (the strip sizes itself by ask, not by an implicit size: what it says is its ratio and that it is as wide as the bar is thick)
    p = reel(probe(), LAP)
    say("p14.the-reel-strip-is-at-the-bar-ratio-and-as-wide-as-the-bar", bool(p["open"] and p["box"]) and abs(p["ratio"] - BAR_RATIO) < 1e-6 and abs(p["box"][2] - TOP) <= 1.5,
        f"body ratio {p['ratio']:.4f} want {BAR_RATIO:g}; box {p['box']}, the bar is {TOP:g} thick")
    move(LAP, 1400, 800, 0.2)
    wait_for(lambda: not reel(probe(), LAP)["open"], 6)

# ------------------------------------------------------------------------------------------------------------------
# p13: the scale is hot WHERE THE FILE WATCHER IS ON (SHP_WATCH=1 ONLY=p13 tools/dev/shell_probe.sh; the trial runs with it off, and there
# a change of shell.json waits for a restart, as the user allowed): a changed `scale.global` is a changed frame scale, reserve and slim
# bars at once, on every output, and the way back is the same
# ------------------------------------------------------------------------------------------------------------------
if want("p13"):
    cfg_path = os.path.join(sh(E, "dir").strip(), "state", "lares-shell-mock", "config", "shell.json")

    def write_scale(v, bar=None, popup=None):
        os.makedirs(os.path.dirname(cfg_path), exist_ok=True)
        with open(cfg_path, "w") as fh:
            fh.write(json.dumps({"scale": {"global": v, "bar": BAR_RATIO if bar is None else bar, "popup": POPUP_RATIO if popup is None else popup}}) + "\n")

    def scale_is(v):
        st_ = probe()
        return all(abs(screen(st_, n)["scale"]["frame"] - v / (HYPR_SCALE if n == LAP else 1.0)) < 1e-6 for n in (LAP, ULT))

    for label, v in (("changed", 1.5 if CFG_SCALE != 1.5 else 1.25), ("restored", CFG_SCALE)):
        write_scale(v)
        got = wait_for(lambda: scale_is(v), 8)
        time.sleep(0.8)
        st = probe()
        res = {m["name"]: m["reserved"][1] for m in monitors()}
        want_res = {n: round(TOP * v / (HYPR_SCALE if n == LAP else 1.0)) for n in (LAP, ULT)}
        say(f"p13.{label}.the-frame-scale-follows-the-file", bool(got), f"global {v}: frame scales {[round(screen(st, n)['scale']['frame'], 4) for n in (LAP, ULT)]}")
        say(f"p13.{label}.the-reserve-follows", res == want_res, f"reserved {json.dumps(res)} want {json.dumps(want_res)}")
        slim = [b for b in screen(st, LAP)["bars"] if b["id"] in ("right", "bottom", "left")]
        kk = v / HYPR_SCALE
        say(f"p13.{label}.the-slim-bars-are-still-6-compositor-px", all(abs(b["thickness"] * kk - 6) < 0.05 for b in slim), ", ".join(f"{b['id']} {b['thickness'] * kk:.2f}" for b in slim))
        isl = {b["id"]: b for b in screen(st, LAP)["bars"] if b["edge"] == "top"}
        mid = (isl["topC"]["rawPos"] + isl["topC"]["rawLen"] / 2) * kk
        res2 = []
        for lab, dy, wantw in (("3 px inside the foot", -3, "shell"), ("4 px below the foot", 4, "bg")):
            n0 = len([c for c in bg_clicks() if c[0] == LAP])
            click(LAP, mid, TOP * kk + dy, 0.5, logical=True)
            n1 = len([c for c in bg_clicks() if c[0] == LAP])
            res2.append((lab, "bg" if n1 > n0 else "shell", wantw))
        bad = [f"{l}: went to {g}, want {w}" for l, g, w in res2 if g != w]
        say(f"p13.{label}.the-island-ends-where-the-new-scale-says", not bad, "; ".join(bad) if bad else ", ".join(f"{l} -> {g}" for l, g, w in res2))
    # the ratios are as hot as the global: a changed `scale.bar` is a changed bar (thickness, reserve, foot) and `scale.popup` a changed popup box
    for label, rb, rp in (("ratios changed", 1.5 if BAR_RATIO != 1.5 else 1.25, 1.5 if POPUP_RATIO != 1.5 else 1.25), ("ratios restored", BAR_RATIO, POPUP_RATIO)):
        write_scale(CFG_SCALE, rb, rp)
        # One probe per look (four were one look). And 20 s: the FIRST ratio other than 1 draws the parked silicon popup through
        # a layer state its prewarm never drew, and the driver compiles the board shader for it -- the window's render thread
        # sat 8.3 s in that one frame here (QSG_RENDER_TIMING, the nested Hyprland's empty shader cache; the board's cold compile
        # measured 3.4 s on the laptop's iris in silicon round 3, and a driver cache keeps it), and the probe's IPC waited behind
        # it. Every later change, to any ratio, answers in 0.2 s.
        def _ratios_are(rb=rb, rp=rp):
            st = probe()
            return all(abs(screen(st, n)["scale"]["bar"] - rb) < 1e-6 and abs(screen(st, n)["scale"]["popup"] - rp) < 1e-6 for n in (LAP, ULT))
        got = wait_for(_ratios_are, 20)
        time.sleep(0.8)
        st = probe()
        res = {m["name"]: m["reserved"][1] for m in monitors()}
        want_res = {n: round(40 * rb * kof(n)) for n in (LAP, ULT)}
        say(f"p13.{label}.the-ratios-follow-the-file", bool(got), f"bar {rb:g}, popup {rp:g}: frames say {[(screen(st, n)['scale']['bar'], screen(st, n)['scale']['popup']) for n in (LAP, ULT)]}")
        say(f"p13.{label}.the-reserve-follows", res == want_res, f"reserved {json.dumps(res)} want {json.dumps(want_res)}")
        isl = {b["id"]: b for b in screen(st, LAP)["bars"] if b["edge"] == "top"}
        say(f"p13.{label}.the-islands-are-40-x-the-bar-ratio", all(abs(b["thickness"] - 40 * rb) < 0.05 for b in isl.values()), json.dumps([b["thickness"] for b in isl.values()]))
    say("p13.the-shell-is-still-answering", ipc("ping") == "ok", "")

print(f"SHELL_PLATFORM SUMMARY checks={checks} failed={fails}", flush=True)
sys.exit(1 if fails else 0)
