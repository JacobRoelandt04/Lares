#!/usr/bin/env python3
"""The checks of tools/dev/aerial_keys_env_probe.sh (read its header). ARGV: <root> <sandbox> <lock_env_name> <app_log> <shell_log>.

K0  calibration: the stand-in app holds the keyboard and a typed word reaches it
K1  the memory panel opened by a click, the pointer RESTING on the chip: the layer asks for no keyboard (the app is being typed in) and a typed word
    goes to the app (a panel that merely appears must not steal the keys)
K2  the pointer moves into the panel and clicks the search field: the compositor holds the layer's keyboard mode, and a typed word lands in the
    FIELD and not in the app; Escape then clears the field first
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT, SB, ENVNAME, ALOG, SLOG = sys.argv[1:6]
E = os.path.join(ROOT, "tools", "dev", "lock_env.sh")
ENV = dict(os.environ, LOCK_ENV=ENVNAME)
SHELL_QML = os.path.join(SB, "shell.qml")
OUT = "LOCK-1"
fails = 0


def sh(*args, timeout=30):
    r = subprocess.run(list(args), cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=timeout)
    return (r.stdout or "") + (r.stderr or "")


def say(name, ok, detail=""):
    global fails
    if not ok:
        fails += 1
    print(f"AKE {name} {'PASS' if ok else 'FAIL'} ({detail})", flush=True)


def ipc(target, fn, *args):
    return sh(E, "run", "quickshell", "ipc", "-p", SHELL_QML, "call", target, fn, *args).strip()


def probe():
    for _ in range(5):
        t = ipc("shell", "probe")
        try:
            return json.loads(t)
        except ValueError:
            time.sleep(0.3)
    raise RuntimeError("no probe answer: " + t[:200])


def info():
    for _ in range(5):
        t = ipc("aerialkeys", "info")
        try:
            return json.loads(t)
        except ValueError:
            time.sleep(0.3)
    return {}


def pt(x, y):
    return f"abs {int(round(x))} {int(round(y))} 2880 1620"


def move(x, y, wait=0.3):
    # in two steps (a first synthetic motion into a window hovers nothing), whole numbers
    sh(E, "point", pt(x - 3, y), "sleep 80", pt(x, y))
    time.sleep(wait)


def click(x, y, settle=0.6):
    sh(E, "point", pt(x - 3, y), "sleep 80", pt(x, y), "sleep 120", "click")
    time.sleep(settle)


def typed(word):
    # `wtype -p F24`: wtype's first distinct key is keycode 9, which the shell's Escape bind reads as Escape
    sh(E, "run", "wtype", "-p", "F24", "--", word)
    time.sleep(0.5)


def key(k):
    sh(E, "key", k)
    time.sleep(0.5)


def wait_for(cond, timeout=8.0, step=0.2):
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


def interactivity():
    out = sh(E, "hyprctl", "eval",
             'local t = {} for _, l in ipairs(hl.get_layers()) do if l.namespace == "lares-bar" then '
             't[#t+1] = tostring(l.keyboard_interactivity) end end error("INTERACT " .. table.concat(t, ","))')
    m = re.search(r"INTERACT (.*)", out)
    return int(m.group(1).split(",")[0]) if m and m.group(1) else -1


def app_text():
    try:
        t = re.findall(r"AKA text (.*)", open(ALOG, errors="ignore").read())
    except OSError:
        return ""
    return t[-1] if t else ""


def activewindow():
    try:
        return json.loads(sh(E, "hyprctl", "-j", "activewindow")).get("title", "")
    except ValueError:
        return ""


# ---- K0: the app holds the keyboard
sh(E, "hyprctl", "dispatch", 'hl.dsp.focus({ window = "title:^aka-app$" })')
time.sleep(0.5)
move(1440, 800)
typed("kk")
say("K0.app-holds-keys", app_text() == "kk", f"active window '{activewindow()}', the app has '{app_text()}'")

# ---- open the popup by a click on the aerial pill, then the memory chip by a click
st = probe()
s = st["screens"][OUT]
bar = [b for b in s["bars"] if b["id"] in ("topR", "top")][0]
p = s["placed"]["aerial"]
px, py = bar["rawPos"] + p["x"] + p["width"] / 2, 20
click(px, py, 0.3)
ok = wait_for(lambda: (lambda q: q["open"] and q["owner"] == "aerial" and q["phase"] == "open")(probe()["screens"][OUT]["popup"]), 20)
say("K.popup-opens", bool(ok), "the aerial popup is open")
if not ok:
    sys.exit(1)
time.sleep(1.0)
mem = ipc("aerialkeys", "memAt").split()
mx, my = float(mem[0]), float(mem[1])
click(mx, my, 0.5)
good = wait_for(lambda: (lambda i: i.get("sec") and i.get("page") == "list" and i.get("field"))(info()), 10)
i = info()
say("K.panel-opens", bool(good), f"chip clicked at {mx:.0f},{my:.0f}: {i}")
if not good:
    sys.exit(1)
time.sleep(1.0)

# ---- K1: the pointer rests on the chip; nothing may be stolen from the app
wait_for(lambda: interactivity() == 0, 3)
mode = interactivity()
typed("aa")
t = app_text()
i = info()
say("K1.no-steal", mode == 0 and t == "kkaa" and i.get("text", "") == "",
    f"layer keyboard_interactivity {mode} (0 none), app '{t}', field '{i.get('text')}', popup asks '{i.get('req')}'")

# ---- K2: the pointer moves into the panel and clicks the search field
fx, fy = [float(v) for v in i["field"].split()]
move(fx + 40, fy + 30)
move(fx + 20, fy + 10)
click(fx, fy, 0.6)
wait_for(lambda: interactivity() == 2, 4)
mode = interactivity()
typed("zq")
i = info()
t = app_text()
say("K2.field-takes-keys", i.get("text") == "zq" and t == "kkaa",
    f"layer keyboard_interactivity {mode} (2 onDemand), field '{i.get('text')}' focus {i.get('focus')}, app '{t}', popup asks '{i.get('req')}'")
key("Escape")
i = info()
say("K2.escape-clears-first", i.get("text") == "" and i.get("sec") is True, f"field '{i.get('text')}', panel open {i.get('sec')}")
# ---- K3: the app takes the focus again while the popup is up (vscode does, now and then): the popup lets go of its keys (KeyRelease), and the
# pointer moving INTO THE PANEL (a separate body, not thePopup's rectangle) and clicking its field takes them back
time.sleep(0.8)
sh(E, "hyprctl", "dispatch", 'hl.dsp.focus({ window = "title:^aka-app$" })')
released = wait_for(lambda: probe()["screens"][OUT]["keys"]["released"], 4)
open_now = probe()["screens"][OUT]["popup"]["open"] and info().get("sec")
fx, fy = [float(v) for v in info()["field"].split()]
move(fx + 60, fy + 40)
move(fx + 30, fy + 15)
click(fx, fy, 0.6)
wait_for(lambda: interactivity() == 2, 3)
mode = interactivity()
typed("wx")
i = info()
t = app_text()
say("K3.reclaimed-in-panel", bool(released) and bool(open_now) and i.get("text") == "wx" and t == "kkaa",
    f"keys released {released}, popup+panel still open {open_now}; layer keyboard_interactivity {mode}, field '{i.get('text')}', app '{t}'")
print(f"AKE SUMMARY {fails} failed", flush=True)
sys.exit(1 if fails else 0)
