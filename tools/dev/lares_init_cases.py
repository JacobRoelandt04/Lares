#!/usr/bin/env python3
"""lares_init_cases.py -- `lares init` (tools/shell/lares-init.py) on fake machines: a fake /sys and a fake config home, never the real ones.

    python3 -B tools/dev/lares_init_cases.py          must end LARES_INIT RESULT PASS
    ARM=all python3 -B tools/dev/lares_init_cases.py  every ARM must turn its own check red -> LARES_INIT ARMS PASS
      overwrite   a file of the user's is written over
      anybat      a mouse's battery counts as the machine's
      anypanel    a panel connector with no panel on it counts
      dryw        --dry-run writes
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "..", "shell", "lares-init.py")
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import jsonc  # noqa: E402

ARMS = {
    "overwrite": [('        if old:\n', '        if False:\n'), ('open(path, "x", encoding="utf-8")', 'open(path, "w", encoding="utf-8")')],
    "anybat": [(' and read(os.path.join(d, "scope")) != "Device"', '')],
    "anypanel": [(' and read(os.path.join(d, "status")) == "connected"', '')],
    "dryw": [('        if dry:\n', '        if False:\n')],
}
MACHINES = {
    # name: (power supplies {name: (type, scope)}, connectors {name: status}, leds)
    "laptop": ({"BAT0": ("Battery", ""), "AC0": ("Mains", "")}, {"card0-eDP-2": "disconnected", "card1-eDP-1": "connected", "card1-DP-1": "disconnected"},
               ["asus::kbd_backlight", "input4::capslock"]),
    "desktop": ({}, {"card1-DP-1": "connected", "card1-HDMI-A-1": "disconnected"}, ["input4::capslock", "phy0-led"]),
    "wireless": ({"hidpp_battery_0": ("Battery", "Device")}, {"card1-DP-1": "connected", "card1-eDP-1": "disconnected"}, []),
    "thinkpad": ({"BAT0": ("Battery", "")}, {"card1-eDP-1": "connected"}, ["tpacpi::kbd_backlight"]),
}


def build(root, spec):
    supplies, conns, leds = spec
    for n, (t, scope) in supplies.items():
        d = os.path.join(root, "class/power_supply", n)
        os.makedirs(d)
        open(os.path.join(d, "type"), "w").write(t + "\n")
        if scope:
            open(os.path.join(d, "scope"), "w").write(scope + "\n")
    for n, st in conns.items():
        d = os.path.join(root, "class/drm", n)
        os.makedirs(d)
        open(os.path.join(d, "status"), "w").write(st + "\n")
    for n in leds:
        os.makedirs(os.path.join(root, "class/leds", n))


def run(arm=""):
    fails = []
    n = 0

    def check(name, ok, detail=""):
        nonlocal n
        n += 1
        if not ok:
            fails.append(name)
            print("FAIL %s  [%s]" % (name, str(detail)[:300]))

    W = tempfile.mkdtemp(prefix="lares-init.")
    try:
        src = open(TOOL, encoding="utf-8").read()
        for a, b in ARMS.get(arm, []):
            if src.count(a) != 1:
                print("ARM %s: anchor gone" % arm)
                return ["anchor gone"], 0
            src = src.replace(a, b)
        os.makedirs(os.path.join(W, "tools/shell"))
        os.makedirs(os.path.join(W, "tools/lib"))
        shutil.copy(os.path.join(HERE, "../lib/jsonc.py"), os.path.join(W, "tools/lib/jsonc.py"))
        tool = os.path.join(W, "tools/shell/lares-init.py")
        open(tool, "w", encoding="utf-8").write(src)

        def go(machine, *args, pre=None):
            """-> (status, output, {file: parsed}, the config dir)"""
            d = tempfile.mkdtemp(prefix=machine + ".", dir=W)
            build(os.path.join(d, "sys"), MACHINES[machine])
            os.makedirs(os.path.join(d, "sys/class"), exist_ok=True)
            conf = os.path.join(d, "cfg/quickshell/config")
            for name, text in (pre or {}).items():
                os.makedirs(os.path.dirname(os.path.join(conf, name)), exist_ok=True)
                open(os.path.join(conf, name), "w").write(text)
            r = subprocess.run([sys.executable, "-B", tool] + list(args), capture_output=True, text=True, timeout=30,
                               env={"PATH": "/usr/bin", "HOME": d, "XDG_CONFIG_HOME": os.path.join(d, "cfg"), "LARES_SYSFS": os.path.join(d, "sys")})
            files = {}
            if os.path.isdir(conf):
                for f in sorted(os.listdir(conf)):
                    t = open(os.path.join(conf, f)).read()
                    try:
                        files[f] = json.loads(jsonc.strip(t))
                    except ValueError as e:
                        files[f] = "does not parse: %s" % e
            return r.returncode, r.stdout + r.stderr, files, conf

        rc, out, files, _ = go("laptop")
        check("the laptop the shell was written on: nothing is written", rc == 0 and files == {} and "nothing to write" in out, (rc, out, files))
        rc, out, files, _ = go("desktop")
        check("a desktop: silicon off, no keyboard light, DisplayPort, no power save",
              rc == 0 and files == {"airplay.jsonc": {"powersave": False}, "osd.jsonc": {"kbd": {"device": ""}},
                                    "panorama.jsonc": {"portLabels": {"usbc": "DisplayPort"}}, "shell.jsonc": {"modules": {"silicon": False}}}, (rc, files, out))
        rc, out, files, _ = go("wireless")
        check("a wireless mouse's battery is not the machine's", files.get("shell.jsonc") == {"modules": {"silicon": False}}, (files, out))
        check("a panel connector with nothing on it is no internal panel", "panorama.jsonc" in files, (files, out))
        rc, out, files, _ = go("thinkpad")
        check("another laptop: only its keyboard light is named", rc == 0 and files == {"osd.jsonc": {"kbd": {"device": "tpacpi::kbd_backlight"}}}, (files, out))
        mine = '// mine\n{ "scale": { "global": 2 } }\n'
        rc, out, files, conf = go("desktop", pre={"shell.jsonc": mine})
        check("a file of the user's is never touched, and what it wants is printed",
              open(os.path.join(conf, "shell.jsonc")).read() == mine and "KEPT" in out and '"silicon": false' in out and "osd.jsonc" in files, (files, out))
        rc, out, files, conf = go("desktop", pre={"shell.jsonc": '// mine\n{ "modules": { "silicon": false, "wiki": false }, "scale": { "global": 2 } }\n'})
        check("a file that says it already is said to be right", "ok     " in out and "shell.jsonc says it already" in out and '"silicon": false' not in out, (files, out))
        rc, out, files, conf = go("desktop", pre={"../osd.json": "{}"})
        check("a config under its old place or extension is the user's too", "osd.jsonc" not in files and "KEPT" in out, (files, out))
        rc, out, files, _ = go("desktop", "--dry-run")
        check("--dry-run writes nothing and says what it would", rc == 0 and files == {} and out.count("WOULD") == 4, (rc, files, out))
        rc, out, files, _ = go("desktop", "--nonsense")
        check("an unknown argument is refused", rc == 2 and files == {}, (rc, files, out))
        # twice: the second run keeps what the first wrote
        d = tempfile.mkdtemp(dir=W)
        build(os.path.join(d, "sys"), MACHINES["desktop"])
        env = {"PATH": "/usr/bin", "HOME": d, "XDG_CONFIG_HOME": os.path.join(d, "cfg"), "LARES_SYSFS": os.path.join(d, "sys")}
        subprocess.run([sys.executable, "-B", tool], env=env, capture_output=True, timeout=30)
        p = os.path.join(d, "cfg/quickshell/config/shell.jsonc")
        before = open(p).read() + "// and a line of the user's\n"
        open(p, "w").write(before)
        subprocess.run([sys.executable, "-B", tool], env=env, capture_output=True, timeout=30)
        check("a second run changes nothing", open(p).read() == before)
    finally:
        shutil.rmtree(W, ignore_errors=True)
    return fails, n


if os.environ.get("ARM") == "all":
    NEEDLE = {"overwrite": "never touched", "anybat": "wireless mouse", "anypanel": "nothing on it", "dryw": "--dry-run writes nothing"}
    bad = 0
    for a in ARMS:
        sys.stdout = open(os.devnull, "w")
        f, _ = run(a)
        sys.stdout = sys.__stdout__
        ok = any(NEEDLE[a] in x for x in f)
        print("ARM %s: %s" % (a, "fails as it must" if ok else "DID NOT FAIL (%s)" % f))
        bad += 0 if ok else 1
    print("LARES_INIT ARMS " + ("FAIL" if bad else "PASS"))
    sys.exit(1 if bad else 0)
f, n = run(os.environ.get("ARM", ""))
print("LARES_INIT RESULT %s (%d of %d)" % ("FAIL" if f or not n else "PASS", n - len(f), n))
sys.exit(1 if f or not n else 0)
