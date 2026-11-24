#!/usr/bin/env python3
"""themectl_libadwaita_probe.py -- the `libadwaita` target's colours, drawn by the REAL libadwaita (CLAUDE.md: A TARGET'S `ok` COUNTS ONLY IF THE REAL
PROGRAM REACTS).

    tools/dev/notifications_bus.sh python3 tools/dev/themectl_libadwaita_probe.py     last line THEMECTL_LIBADWAITA RESULT PASS|FAIL
    ARM=skip ...                                                                   the libadwaita target is not run: every colour check must FAIL
    KEEP_SHOTS=<dir> ...                                                           copy the screenshots (cropped to the dialog) into <dir>

How. themectl applies a pair in a sandbox desktop (tools/dev/themectl_sandbox.py), which writes the sandbox's ~/.config/gtk-4.0/gtk.css; then `zenity --progress`
(GTK 4 + libadwaita, as loupe is) is drawn by a private HEADLESS sway (no output anywhere, never the user's compositor) with that sandbox's HOME, beside a
stand-in for org.freedesktop.portal.Desktop that answers what this machine's portal answers (color-scheme and contrast, NO accent-color), and WITHOUT
ADW_DISABLE_PORTAL: the user's session as it is. The screenshot (grim, cairo renderer: exact colours) must hold the pair's surface in the dialog's
background and the pair's exact accent in the progress bar.
With ADW_DISABLE_PORTAL=1 (the variable the gnome-accent target once needed) the stylesheet wins too. Every variable the template sets must be one
the installed libadwaita defines (read from its own compiled stylesheet): a renamed variable is a silent no-op, and only this check sees it.
The finding the last checks pin: GTK 4 reads the user stylesheet once, when the app starts -- a running app keeps its colours when the file changes.
"""
import os
import shutil
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
# a light and a dark of each kind: a blue, a green on cream, a pink on burgundy, a cyan, a mauve (accents GNOME's nine do not have)
CASES = [("eva", "light"), ("everbox", "dark"), ("riso", "dark"), ("monokai", "light"), ("catppuccin", "dark")]


def check(cid, ok, detail=""):
    RESULTS.append((cid, bool(ok)))
    print("%-4s %s%s" % ("ok" if ok else "FAIL", cid, ("  -- " + str(detail)) if (detail and not ok) else ""))


def rgb_of(hexs):
    h = hexs.strip().lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def css_value(path, var):
    for ln in open(path).read().splitlines():
        ln = ln.strip()
        if ln.startswith(var + ":"):
            return ln.split(":", 1)[1].strip().rstrip(";")
    return None


def libadwaita_variables():
    """The CSS variables the installed libadwaita defines, from its compiled stylesheet (gi loads the library lazily: its resources register on
    the first call into it)."""
    import re
    import gi
    gi.require_version("Adw", "1")
    from gi.repository import Adw, Gio
    Adw.get_major_version()
    css = Gio.resources_lookup_data("/org/gnome/Adwaita/styles/gtk.css", 0).get_data().decode("utf-8")
    return set(re.findall(r"(--[a-z][a-z0-9-]*)\s*:", css)), "%d.%d" % (Adw.get_major_version(), Adw.get_minor_version())


def count_colour(png, rgb):
    from PIL import Image
    im = Image.open(png).convert("RGB")
    data = im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata()
    return sum(1 for p in data if p == rgb)


def main():
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS", "").startswith("unix:"):
        print("THEMECTL_LIBADWAITA RESULT FAIL (run it under tools/dev/notifications_bus.sh: a private session bus)")
        return 1
    for prog in ("sway", "grim", "zenity"):
        if shutil.which(prog) is None:
            print("THEMECTL_LIBADWAITA RESULT FAIL (%s is not installed)" % prog)
            return 1
    bus = os.environ["DBUS_SESSION_BUS_ADDRESS"]
    rt = tempfile.mkdtemp(prefix="thadw.", dir="/tmp")           # short: a Wayland socket path ends at 107 bytes
    os.chmod(rt, 0o700)
    work = tempfile.mkdtemp(prefix="themectl_adw.", dir=os.environ.get("SCRATCH") or tempfile.gettempdir())
    before = sbx.manifest()
    procs = []
    portal = [None]
    try:
        root = os.path.join(work, "sb")
        sbx.make(root, seed=FIXTURE)
        css = sbx.env_of(root)["XDG_CONFIG_HOME"] + "/gtk-4.0/gtk.css"
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
            print("THEMECTL_LIBADWAITA RESULT FAIL (the headless sway did not start: %s)" % open(work + "/sway.log").read()[-200:])
            return 1

        def start_portal(scheme):
            # the portal answers the scheme: one per mode, restarted when the mode changes (libadwaita reads the scheme from it, as on the desktop)
            if portal[0] is not None:
                portal[0].terminate()
                portal[0].wait(timeout=10)
            ready = os.path.join(work, "portal.%d.ready" % scheme)
            p = subprocess.Popen(["python3", STANDINS, "portal", "--scheme", str(scheme), "--ready", ready], stdin=subprocess.DEVNULL)
            portal[0] = p
            for _ in range(100):
                if os.path.exists(ready):
                    break
                time.sleep(0.1)
            os.unlink(ready)

        def zenity(extra=None):
            env = sbx.env_of(root)
            env.update({"XDG_RUNTIME_DIR": rt, "WAYLAND_DISPLAY": sock, "GDK_BACKEND": "wayland", "GSK_RENDERER": "cairo", "DBUS_SESSION_BUS_ADDRESS": bus})
            env.pop("ADW_DISABLE_PORTAL", None)
            env.update(extra or {})
            return subprocess.Popen(["zenity", "--progress", "--percentage=60", "--text=libadwaita probe", "--width=300", "--timeout=20"], env=env,
                                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def grab(png):
            subprocess.run(["grim", png], env={"PATH": "/usr/bin:/bin", "XDG_RUNTIME_DIR": rt, "WAYLAND_DISPLAY": sock}, check=True, timeout=30)

        def apply(name, mode):
            only = "libadwaita,gtk" if ARM != "skip" else "gtk"
            r = sbx.run(root, ["python3", THEMECTL, "set", name, mode, "--only", only])
            return r.returncode == 0, r.stdout[-300:]

        # the pair's tokens as the target wrote them; ARM=skip reads them from a render of its own (the colours libadwaita must then NOT draw)
        def want(name, mode):
            if ARM == "skip":
                r = sbx.run(root, ["python3", THEMECTL, "set", name, mode, "--only", "libadwaita"])
                w = (rgb_of(css_value(css, "--window-bg-color")), rgb_of(css_value(css, "--accent-bg-color")))
                os.unlink(css)
                return w
            return rgb_of(css_value(css, "--window-bg-color")), rgb_of(css_value(css, "--accent-bg-color"))

        mode_now = None
        for name, mode in CASES:
            if mode != mode_now:
                start_portal(1 if mode == "dark" else 2)
                mode_now = mode
            ok, out = apply(name, mode)
            if not ok:
                check("%s.%s.apply" % (name, mode), False, out)
                continue
            surf, acc = want(name, mode)
            png = "%s/%s-%s.png" % (work, name, mode)
            z = zenity()
            try:
                time.sleep(3.0)
                grab(png)
            finally:
                z.terminate()
                z.wait(timeout=10)
            ns, na = count_colour(png, surf), count_colour(png, acc)
            check("%s.%s.the-window-is-the-pairs-surface-%02X%02X%02X" % ((name, mode) + surf), ns > 5000, "%d pixels" % ns)
            check("%s.%s.the-bar-is-the-pairs-own-accent-%02X%02X%02X" % ((name, mode) + acc), na > 300, "%d pixels" % na)

        # the variables: every one the template sets is one this libadwaita defines
        import re
        try:
            have, ver = libadwaita_variables()
        except Exception as e:                                  # no gi or no libadwaita: say so, never pass
            have, ver = set(), "unreadable: %s" % e
        sets = set(re.findall(r"^\s*(--[a-z][a-z0-9-]*)\s*:", open(REPO + "/tools/theme/templates/libadwaita-gtk.css").read(), re.M))
        check("vars.every-variable-the-template-sets-is-one-libadwaita-%s-defines" % ver.split(":")[0], sets and have and sets <= have,
              sorted(sets - have) or ver)
        if ARM != "skip":
            # the variable the gnome-accent target once needed changes nothing here: the stylesheet wins either way
            start_portal(1)
            apply("riso", "dark")
            acc = rgb_of(css_value(css, "--accent-bg-color"))
            png = work + "/riso-dark-adw-disable-portal.png"
            z = zenity({"ADW_DISABLE_PORTAL": "1"})
            try:
                time.sleep(3.0)
                grab(png)
            finally:
                z.terminate()
                z.wait(timeout=10)
            check("riso.dark.with-ADW_DISABLE_PORTAL-the-bar-is-still-the-pairs-own-accent", count_colour(png, acc) > 300, count_colour(png, acc))
        # the finding: a running app keeps the stylesheet it started with (GTK 4 reads it once); the next start takes the new one
        if ARM != "skip":
            start_portal(1)
            apply("everbox", "dark")
            old = rgb_of(css_value(css, "--window-bg-color"))
            z = zenity()
            try:
                time.sleep(3.0)
                apply("riso", "dark")
                new = rgb_of(css_value(css, "--window-bg-color"))
                time.sleep(3.0)
                png = work + "/finding-running.png"
                grab(png)
            finally:
                z.terminate()
                z.wait(timeout=10)
            check("finding.a-running-app-keeps-the-colours-it-started-with", count_colour(png, old) > 5000 and count_colour(png, new) < 50,
                  (count_colour(png, old), count_colour(png, new)))
            png = work + "/finding-restarted.png"
            z = zenity()
            try:
                time.sleep(3.0)
                grab(png)
            finally:
                z.terminate()
                z.wait(timeout=10)
            check("finding.the-next-start-takes-the-new-file", count_colour(png, new) > 5000, count_colour(png, new))
    finally:
        for p in procs + [portal[0]]:
            if p is not None:
                p.terminate()
        for p in procs + [portal[0]]:
            if p is None:
                continue
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
    print("THEMECTL_LIBADWAITA %d checks, %d failed%s" % (len(RESULTS), nfail, " (ARM=%s)" % ARM if ARM else ""))
    print("THEMECTL_LIBADWAITA RESULT %s" % ("PASS" if nfail == 0 else "FAIL"))
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
