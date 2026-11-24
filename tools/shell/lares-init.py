#!/usr/bin/env python3
"""lares-init.py -- `lares init`: the config files a machine needs because of its HARDWARE, written once.

    lares init [--dry-run]

It looks at sysfs (a battery, an internal panel, a keyboard light), says what it found, and writes the few settings that follow from it to
~/.config/quickshell/config/<name>.jsonc. Only a file that does not exist is written: a file of the user's is never touched, and what it would
have said is printed for him to add by hand. Everything else a config can say is a preference and stays at its default (.examples/).

    no battery            shell.jsonc    "modules": { "silicon": false }        battery, CPU profiles, GPU modes and fans of a laptop
                          airplay.jsonc  "powersave": false                     the Wi-Fi radio's power save is the silicon helper's verb
    no internal panel     panorama.jsonc "portLabels": { "usbc": "DisplayPort" } a DP connector is a DisplayPort socket, not a laptop's USB-C
    the keyboard's light  osd.jsonc      "kbd": { "device": "<its LED>" }       named where it is not the default; "" where there is none

Exit status: 0 done (also when there was nothing to write), 2 bad arguments. LARES_SYSFS stands in for /sys (a test's).
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "lib"))
import jsonc  # noqa: E402

SYS = os.environ.get("LARES_SYSFS", "/sys")
DEFAULT_LED = "asus::kbd_backlight"      # modules/osd/data/OsdKinds.js defaultConfig().kbd.device


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return ""


def battery():
    """The machine's own battery (a mouse's or a keyboard's says scope Device)."""
    for d in sorted(glob.glob(os.path.join(SYS, "class/power_supply/*"))):
        if read(os.path.join(d, "type")) == "Battery" and read(os.path.join(d, "scope")) != "Device":
            return os.path.basename(d)
    return ""


def internal_panel():
    """A connected panel of the machine's own: eDP, LVDS or DSI (a card lists connectors it has no panel on)."""
    for d in sorted(glob.glob(os.path.join(SYS, "class/drm/card*-*"))):
        name = re.sub(r"^card\d+-", "", os.path.basename(d))
        if re.match(r"(eDP|LVDS|DSI)-", name) and read(os.path.join(d, "status")) == "connected":
            return name
    return ""


def keyboard_light():
    leds = [os.path.basename(p) for p in sorted(glob.glob(os.path.join(SYS, "class/leds/*kbd_backlight*")))]
    return DEFAULT_LED if DEFAULT_LED in leds else (leds[0] if leds else "")


def head(name):
    return ("// %s.jsonc -- only your changes: a key left out is its default. Every key, what it does, its default and its range:\n"
            "// .examples/%s.jsonc in the shell's folder. Started by `lares init` for this machine.\n" % (name, name))


def says(path, body):
    """Does the user's file say it already? (what the body says, at any depth)"""
    def holds(have, want):
        return all(holds(have.get(k), v) if isinstance(v, dict) and isinstance(have.get(k), dict) else have.get(k) == v for k, v in want.items())
    try:
        with open(path, encoding="utf-8") as f:
            have = json.loads(jsonc.strip(f.read()))
        return isinstance(have, dict) and holds(have, json.loads(jsonc.strip("{\n" + "\n".join(body) + "\n}")))
    except (OSError, ValueError):
        return False


def plan():
    """[(name, why, body lines)] for the files this machine needs."""
    out = []
    bat, panel, led = battery(), internal_panel(), keyboard_light()
    found = ["battery: %s" % (bat or "none"), "internal panel: %s" % (panel or "none"), "keyboard light: %s" % (led or "none")]
    if not bat:
        out.append(("shell", "no battery",
                    ['    // not loaded on this machine (it has no battery): silicon is the battery, CPU profiles, GPU modes and fans of a laptop',
                     '    "modules": { "silicon": false }']))
        out.append(("airplay", "no battery, so no silicon helper to ask",
                    ['    // the Wi-Fi radio\'s power save is the silicon helper\'s verb, and that module is not loaded here',
                     '    "powersave": false']))
    if not panel:
        out.append(("panorama", "no internal panel",
                    ['    // a DP connector is a DisplayPort socket here (on a laptop it is a USB-C one)',
                     '    "portLabels": { "usbc": "DisplayPort" }']))
    if led != DEFAULT_LED:
        out.append(("osd", "the keyboard light is %s" % (led or "not there"),
                    ['    // the keyboard\'s light' if led else '    // no keyboard light on this machine: nothing watches for one',
                     '    "kbd": { "device": "%s" }' % led]))
    return found, out


def main(argv):
    dry = False
    for a in argv:
        if a == "--dry-run":
            dry = True
        else:
            print("usage: lares init [--dry-run]", file=sys.stderr)
            return 2
    conf = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "quickshell", "config")
    found, files = plan()
    print("this machine: " + ", ".join(found))
    if not files:
        print("nothing to write: the defaults are right for it")
        return 0
    for name, why, body in files:
        path = os.path.join(conf, name + ".jsonc")
        old = [p for p in (path, path[:-1], os.path.join(os.path.dirname(conf), name + ".jsonc"), os.path.join(os.path.dirname(conf), name + ".json")) if os.path.exists(p)]
        if old and says(old[0], body):
            print("ok     %s says it already (%s)" % (old[0], why))
            continue
        if old:
            print("KEPT   %s is yours; for this machine (%s) it wants:" % (old[0], why))
            print("\n".join("       " + b for b in body))
            continue
        if dry:
            print("WOULD  write %s (%s)" % (path, why))
            print("\n".join("       " + b for b in body))
            continue
        os.makedirs(conf, exist_ok=True)
        with open(path, "x", encoding="utf-8") as f:
            f.write(head(name) + "{\n" + "\n".join(body) + "\n}\n")
        print("WROTE  %s (%s)" % (path, why))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
