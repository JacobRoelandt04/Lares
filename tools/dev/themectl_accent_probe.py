#!/usr/bin/env python3
"""themectl_accent_probe.py -- libadwaita's accent, read back by the REAL libadwaita (CLAUDE.md: A TARGET'S `ok` COUNTS ONLY IF THE REAL PROGRAM REACTS).

    tools/dev/notifications_bus.sh python3 tools/dev/themectl_accent_probe.py      last line THEMECTL_ACCENT RESULT PASS|FAIL
    ARM=skip ...                                                                 the gnome-accent target is not run: the pairs that are not blue must FAIL
    KEEP_SHOTS=<dir> ...                                                         copy the screenshots (cropped to the dialog) into <dir>

How. themectl applies a pair in a sandbox desktop (tools/dev/themectl_sandbox.py: the keyfile gsettings backend is where `accent-color` lands), then `zenity
--progress` (GTK 4 + libadwaita, as loupe is) is drawn by a private HEADLESS sway (no output anywhere, never the user's compositor) with THAT sandbox's gsettings,
and a screenshot (grim) must hold the named GNOME accent's exact colour in the bar. Run on a private bus (notifications_bus.sh): the probe starts a stand-in
for org.freedesktop.portal.Desktop that answers what this machine's portal answers (color-scheme and contrast, NO accent-color).
What it found, and what the checks pin: with ADW_DISABLE_PORTAL=1 libadwaita reads `accent-color` from gsettings and the bar is the pair's accent; with a portal
that does not carry accent-color (this desktop's xdg-desktop-portal-gtk) and no such variable it IGNORES gsettings for the accent (the bar stays blue) -- the
last check is the finding itself, so a libadwaita that changes it shows.
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import themectl_sandbox as sbx  # noqa: E402

THEMECTL = REPO + "/tools/theme/themectl"
FIXTURE = REPO + "/tools/dev/fixtures/themectl/home"
STANDINS = REPO + "/tools/dev/fixtures/themectl/dbus_standins.py"
ARM = os.environ.get("ARM", "")
RESULTS = []
GNOME = {"blue": (53, 132, 228), "teal": (33, 144, 164), "green": (58, 148, 74), "pink": (213, 97, 153), "purple": (145, 65, 172)}
CASES = [("eva", "light", "blue"), ("monokai", "light", "teal"), ("everbox", "dark", "green"), ("riso", "dark", "pink"), ("catppuccin", "dark", "purple")]


def check(cid, ok, detail=""):
    RESULTS.append((cid, bool(ok)))
    print("%-4s %s%s" % ("ok" if ok else "FAIL", cid, ("  -- " + str(detail)) if (detail and not ok) else ""))


def count_colour(png, rgb):
    from PIL import Image
    im = Image.open(png).convert("RGB")
    return sum(1 for p in im.get_flattened_data() if p == rgb) if hasattr(im, "get_flattened_data") else sum(1 for p in im.getdata() if p == rgb)


def main():
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS", "").startswith("unix:"):
        print("THEMECTL_ACCENT RESULT FAIL (run it under tools/dev/notifications_bus.sh: a private session bus)")
        return 1
    for prog in ("sway", "grim", "zenity"):
        if shutil.which(prog) is None:
            print("THEMECTL_ACCENT RESULT FAIL (%s is not installed)" % prog)
            return 1
    bus = os.environ["DBUS_SESSION_BUS_ADDRESS"]
    rt = tempfile.mkdtemp(prefix="thacc.", dir="/tmp")           # short: a Wayland socket path ends at 107 bytes
    os.chmod(rt, 0o700)
    work = tempfile.mkdtemp(prefix="themectl_accent.", dir=os.environ.get("SCRATCH") or tempfile.gettempdir())
    before = sbx.manifest()
    procs = []
    try:
        root = os.path.join(work, "sb")
        sbx.make(root, seed=FIXTURE)
        cfg = os.path.join(work, "sway.conf")
        open(cfg, "w").write("xwayland disable\n")
        sway = subprocess.Popen(["sway", "-c", cfg], env={"HOME": work, "PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": rt, "LANG": "C.UTF-8", "WLR_BACKENDS": "headless",
                                                           "WLR_LIBINPUT_NO_DEVICES": "1", "WLR_RENDERER": "pixman"},
                                stdout=open(work + "/sway.log", "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        procs.append(sway)
        sock = None
        for _ in range(100):
            socks = [n for n in os.listdir(rt) if n.startswith("wayland-") and not n.endswith(".lock")]
            if socks:
                sock = socks[0]
                break
            time.sleep(0.1)
        if not sock:
            print("THEMECTL_ACCENT RESULT FAIL (the headless sway did not start: %s)" % open(work + "/sway.log").read()[-200:])
            return 1
        ready = os.path.join(work, "portal.ready")
        portal = subprocess.Popen(["python3", STANDINS, "portal", "--scheme", "2", "--ready", ready], stdin=subprocess.DEVNULL)
        procs.append(portal)
        for _ in range(100):
            if os.path.exists(ready):
                break
            time.sleep(0.1)

        def shot(extra, png):
            env = sbx.env_of(root)
            env.update({"XDG_RUNTIME_DIR": rt, "WAYLAND_DISPLAY": sock, "GDK_BACKEND": "wayland", "GSK_RENDERER": "cairo", "DBUS_SESSION_BUS_ADDRESS": bus})
            env.update(extra)
            z = subprocess.Popen(["zenity", "--progress", "--percentage=60", "--text=accent probe", "--width=300", "--timeout=8"], env=env,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                time.sleep(3.0)
                subprocess.run(["grim", png], env={"PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": rt, "WAYLAND_DISPLAY": sock}, check=True, timeout=30)
            finally:
                z.terminate()
                z.wait(timeout=10)
        for name, mode, accent in CASES:
            args = ["set", name, mode, "--only", "gnome-accent"] if ARM != "skip" else ["set", name, mode, "--only", "gtk"]
            r = sbx.run(root, ["python3", THEMECTL] + args)
            if r.returncode != 0:
                check("%s.%s.apply" % (name, mode), False, r.stdout[-200:])
                continue
            png = "%s/%s-%s.png" % (work, name, mode)
            shot({"ADW_DISABLE_PORTAL": "1"}, png)
            n = count_colour(png, GNOME[accent])
            check("%s.%s.libadwaita-draws-the-bar-in-%s" % (name, mode, accent), n > 300, "%d pixels of %s" % (n, GNOME[accent]))
        # the finding: a portal that answers (colour-scheme only) and no ADW_DISABLE_PORTAL: gsettings' accent is ignored (pink in gsettings, blue drawn)
        sbx.run(root, ["python3", THEMECTL, "set", "riso", "dark", "--only", "gnome-accent"])
        png = work + "/finding.png"
        shot({}, png)
        check("finding.with-a-portal-that-has-no-accent-and-no-ADW_DISABLE_PORTAL-libadwaita-ignores-gsettings", count_colour(png, GNOME["pink"]) < 50
              and count_colour(png, GNOME["blue"]) > 300, (count_colour(png, GNOME["pink"]), count_colour(png, GNOME["blue"])))
    finally:
        for p in procs:
            p.terminate()
        for p in procs:
            try:
                p.wait(timeout=10)
            except subprocess.TimeoutExpired:
                p.kill()
        keep = os.environ.get("KEEP_SHOTS")
        if keep:
            from PIL import Image
            os.makedirs(keep, exist_ok=True)
            for n in sorted(os.listdir(work)):
                if n.endswith(".png"):
                    Image.open(os.path.join(work, n)).convert("RGB").crop((420, 230, 860, 490)).save(os.path.join(keep, n))
        moved = sbx.compare(before, sbx.manifest())
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(rt, ignore_errors=True)
    check("OUTSIDE.nothing-outside-the-sandbox-changed", not moved, moved[:3])
    nfail = sum(1 for _, ok in RESULTS if not ok)
    print("THEMECTL_ACCENT %d checks, %d failed%s" % (len(RESULTS), nfail, " (ARM=%s)" % ARM if ARM else ""))
    print("THEMECTL_ACCENT RESULT %s" % ("PASS" if nfail == 0 else "FAIL"))
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
