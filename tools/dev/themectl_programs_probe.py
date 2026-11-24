#!/usr/bin/env python3
"""themectl_programs_probe.py -- every theme on disk, both modes, read back by the REAL programs (CLAUDE.md: A TARGET'S `ok` COUNTS ONLY IF
THE REAL PROGRAM REACTS).

    python3 tools/dev/themectl_programs_probe.py               kitty and btop          last line THEMECTL_PROGRAMS RESULT PASS|FAIL
    HYPR=1 python3 tools/dev/themectl_programs_probe.py        and Hyprland, in a nested tools/dev/lock_env.sh (LOCK_ENV=pdthemes by default)
    ONLY=<regex> ...                                           the themes whose name matches
    ARM=kitty|btop|hypr ...                                    one fault, the check it names must FAIL (ARM=hypr needs HYPR=1)

How. themectl applies each theme and mode in a sandbox desktop (tools/dev/themectl_sandbox.py: the fixture home after `install && migrate &&
apply`, PATH stubs, nothing of the user's), and the files it wrote are handed to the programs themselves:
  kitty      `kitty +runpy` loads current-theme.conf with kitty's own config parser: background, foreground, selection, cursor, url and the 16
             colours must be the theme's tokens, and kitty must complain about no line.
  btop       btop runs on a pseudo-terminal (truecolor, 140 x 40) with the theme current.theme links to: the frame it draws holds the theme's
             main_bg as a background and its main_fg as a foreground. Once per run: the link is moved under a running btop and SIGUSR2 makes it
             draw the other theme's background (the reload themectl relies on).
  Hyprland   (HYPR=1) the generated theme.lua is run by `hyprctl eval 'dofile(...)'` in the nested Hyprland and read back with `hyprctl -j getoption`:
             the borders, the group's active tab and the locked tab must be the theme's colours.
Nothing here starts on the user's desktop or talks to their kitty, btop or Hyprland.
"""
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import fcntl
import termios

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.dont_write_bytecode = True
import themectl_sandbox as sbx  # noqa: E402

THEMECTL = REPO + "/tools/theme/themectl"
FIXTURE = REPO + "/tools/dev/fixtures/themectl/home"
USER_LOGOS = ("archlogo_evalight.png", "archlogo_evadark.png", "archlogo_everforest.png", "archlogo_gruvbox.png")
ARM = os.environ.get("ARM", "")
RESULTS = []


def check(cid, ok, detail=""):
    RESULTS.append((cid, bool(ok)))
    print("%-4s %s%s" % ("ok" if ok else "FAIL", cid, ("  -- " + str(detail)) if (detail and not ok) else ""))


def hexof(rgb):
    return "#%02X%02X%02X" % tuple(rgb[:3])


def ctl(root, *args):
    r = sbx.run(root, ["python3", THEMECTL] + list(args))
    return r.returncode, r.stdout + r.stderr


def tokens(name, mode):
    out = subprocess.run(["python3", THEMECTL, "resolve", "--file", REPO + "/themes/%s.json" % name, "--mode", mode, "--l0",
                          REPO + "/modules/common/theme/Theme.qml"], capture_output=True, text=True, env=dict(os.environ, HOME=tempfile.gettempdir()))
    v = json.loads(out.stdout)["values"]
    fb = {"hyprGroupTab": "warn"}
    for k, w in fb.items():
        v.setdefault(k, v[w])
    return {k: hexof(c) for k, c in v.items() if isinstance(c, list)}


# ================================================================================================================ kitty

KITTY_KEYS = {"background": "surface", "foreground": "terminalFg", "selection_background": "terminalSelection",
              "selection_foreground": "terminalSelectionText", "cursor": "terminalFg", "cursor_text_color": "surface", "url_color": "accent"}
ANSI = ["ansiBlack", "ansiRed", "ansiGreen", "ansiYellow", "ansiBlue", "ansiMagenta", "ansiCyan", "ansiWhite"]
ANSI += [a.replace("ansi", "ansiBright") for a in ANSI]

KITTY_READ = r"""import sys, json
from kitty.config import load_config
o = load_config(sys.argv[-1])
keys = %r
out = {}
for k in keys:
    c = getattr(o, k)
    out[k] = "#%%02X%%02X%%02X" %% (c.red, c.green, c.blue)
print("KITTYJSON " + json.dumps(out))
"""


def kitty_check(name, mode, conf, tok):
    keys = list(KITTY_KEYS) + ["color%d" % i for i in range(16)]
    kh = os.path.join(os.path.dirname(conf), ".kitty-probe-home")        # kitty runs in the sandbox's home, never the user's
    os.makedirs(kh, exist_ok=True)
    env = {"HOME": kh, "XDG_CONFIG_HOME": kh + "/.config", "XDG_CACHE_HOME": kh + "/.cache", "XDG_RUNTIME_DIR": kh, "PATH": "/usr/bin:/bin",
           "LANG": "en_US.UTF-8"}
    r = subprocess.run(["kitty", "+runpy", KITTY_READ % keys, conf], capture_output=True, text=True, timeout=60, env=env)
    m = re.search(r"^KITTYJSON (.*)$", r.stdout, re.M)
    got = json.loads(m.group(1)) if m else {}
    want = {k: tok[t] for k, t in KITTY_KEYS.items()}
    want.update({"color%d" % i: tok[a] for i, a in enumerate(ANSI)})
    bad = {k: (got.get(k), want[k]) for k in want if got.get(k) != want[k]}
    complaints = [l for l in r.stderr.splitlines() if re.search(r"(?i)ignoring|invalid|bad line|error", l)]
    check("kitty.%s.%s.reads-every-colour-and-complains-about-nothing" % (name, mode), m and not bad and not complaints, (bad, complaints[:2], r.stderr[-200:]))


# ================================================================================================================= btop

def btop_frames(home, seconds, then=None):
    """btop on a pty in HOME; -> (bytes before `then`, bytes after it). `then(pid)` runs halfway (a relink + SIGUSR2)."""
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.clear()
        os.environ.update({"HOME": home, "XDG_CONFIG_HOME": home + "/.config", "TERM": "xterm-256color", "COLORTERM": "truecolor",
                           "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"})
        os.execvp("btop", ["btop"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    os.kill(pid, signal.SIGWINCH)
    parts = [b"", b""]
    i = 0
    t0 = time.time()
    try:
        while time.time() - t0 < seconds * (2 if then else 1):
            if then and i == 0 and time.time() - t0 >= seconds:
                then(pid)
                i = 1
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    parts[i] += os.read(fd, 1 << 16)
                except OSError:
                    break
    finally:
        with __import__("contextlib").suppress(ProcessLookupError):
            os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        os.close(fd)
    return parts


def colours(buf, kind):
    return {"#%02X%02X%02X" % tuple(int(x) for x in m) for m in re.findall(rb"%d;2;(\d+);(\d+);(\d+)" % kind, buf)}


def btop_home(work, theme_file):
    home = os.path.join(work, "bt-%d" % len(os.listdir(work)))
    d = home + "/.config/btop/themes"
    os.makedirs(d)
    with open(home + "/.config/btop/btop.conf", "w") as f:
        f.write('color_theme = "current"\ntheme_background = true\ntruecolor = true\nupdate_ms = 500\n')
    os.symlink(theme_file, d + "/current.theme")
    return home


def btop_theme_values(path):
    """theme[key] -> "#RRGGBB"; btop's two-digit form "#GG" is a grey (paper's main_fg "#00")."""
    out = {}
    for k, v in re.findall(r'^theme\[(\w+)\]="#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{2})"', open(path).read(), re.M):
        out[k] = "#" + (v * 3 if len(v) == 2 else v).upper()
    return out


def btop_check(name, mode, theme_file, work):
    want = btop_theme_values(theme_file)
    if ARM == "btop":
        others = sorted(os.path.join(REPO, "tools/theme/btop", n) for n in os.listdir(REPO + "/tools/theme/btop"))
        theme_file = next(o for o in others if btop_theme_values(o).get("main_bg") != want.get("main_bg"))
    home = btop_home(work, theme_file)
    buf, _ = btop_frames(home, 2.5)
    bg, fg = colours(buf, 48), colours(buf, 38)
    ok = len(buf) > 2000 and (not want.get("main_bg") or want["main_bg"] in bg) and want.get("main_fg") in fg
    check("btop.%s.%s.draws-the-themes-ground-and-ink" % (name, mode), ok, (len(buf), want.get("main_bg"), want.get("main_fg"), sorted(bg)[:4]))
    shutil.rmtree(home, ignore_errors=True)


def btop_reload(work):
    a = REPO + "/tools/theme/btop/riso-dark.theme"
    b = REPO + "/tools/theme/btop/catppuccin-latte.theme"
    home = btop_home(work, a)
    link = home + "/.config/btop/themes/current.theme"

    def relink(pid):
        tmp = link + ".new"
        os.symlink(b, tmp)
        os.replace(tmp, link)
        os.kill(pid, signal.SIGUSR2)
    before, after = btop_frames(home, 2.0, relink)
    wa, wb = btop_theme_values(a)["main_bg"], btop_theme_values(b)["main_bg"]
    check("btop.reload.a-moved-link-and-SIGUSR2-redraw-in-the-other-theme", wa in colours(before, 48) and wb in colours(after, 48),
          (wa, sorted(colours(before, 48))[:3], wb, sorted(colours(after, 48))[:3]))
    shutil.rmtree(home, ignore_errors=True)


# ============================================================================================================= Hyprland

LOCK_ENV = os.environ.get("LOCK_ENV", "pdthemes")


def lockenv(*args, timeout=120):
    return subprocess.run([REPO + "/tools/dev/lock_env.sh"] + list(args), capture_output=True, text=True, timeout=timeout,
                          env=dict(os.environ, LOCK_ENV=LOCK_ENV))


def hypr_colour(option):
    r = lockenv("hyprctl", "-j", "getoption", option)
    try:
        j = json.loads(r.stdout)
    except ValueError:
        return None
    s = str(j.get("gradient") or j.get("custom") or j.get("str") or "")         # 0.57: {"gradient": "aarrggbb 0deg"}
    m = re.search(r"\b([0-9a-fA-F]{8})\b", s)
    if m:
        return "#" + m.group(1)[2:].upper()                  # aarrggbb
    if isinstance(j.get("int"), int):
        return "#%06X" % (j["int"] & 0xFFFFFF)
    return None


HYPR_OPTS = {"general:col.active_border": "hyprBorderActive", "general:col.inactive_border": "hyprBorderInactive",
             "group:col.border_locked_active": "hyprBorderActive", "group:groupbar:col.active": "hyprGroupTab",
             "group:groupbar:col.locked_active": "hyprBorderLocked"}


def hypr_check(name, mode, lua, tok, env_dir):
    path = os.path.join(env_dir, "theme-%s-%s.lua" % (name, mode))
    shutil.copy(lua, path)
    if not (ARM == "hypr" and name == "eva" and mode == "dark"):         # the arm: one theme's file is never run, its read-back is the last one's
        r = lockenv("hyprctl", "eval", 'dofile("%s")' % path)
        if not r.stdout.strip().startswith("ok"):
            check("hypr.%s.%s.dofile-is-ok" % (name, mode), False, (r.stdout + r.stderr)[-300:])
            return
    got = {o: hypr_colour(o) for o in HYPR_OPTS}
    bad = {o: (got[o], tok[t]) for o, t in HYPR_OPTS.items() if got[o] != tok[t]}
    check("hypr.%s.%s.reads-back-the-borders-and-the-tabs" % (name, mode), not bad, bad)


# ================================================================================================================= main

def main():
    only = re.compile(os.environ.get("ONLY", "."))
    names = [n[:-5] for n in sorted(os.listdir(REPO + "/themes")) if n.endswith(".json") and only.search(n[:-5])]
    scratch = os.environ.get("SCRATCH") or tempfile.gettempdir()
    work = tempfile.mkdtemp(prefix="themectl_programs.", dir=scratch)
    hypr = os.environ.get("HYPR") == "1"
    env_dir = None
    before = sbx.manifest()
    try:
        root = os.path.join(work, "sb")
        sbx.make(root, seed=FIXTURE)
        for a in (("install",), ("migrate",), ("apply",)):
            rc, out = ctl(root, *a)
            if rc != 0:
                print("THEMECTL_PROGRAMS RESULT FAIL (themectl %s in the sandbox: %s)" % (a[0], out[-300:]))
                return 1
        h = root + "/home"
        for n in USER_LOGOS:
            p = h + "/.config/fastfetch/" + n
            if not os.path.exists(p):
                open(p, "w").close()
        if hypr:
            r = lockenv("up", timeout=180)
            if r.returncode != 0:
                print("THEMECTL_PROGRAMS RESULT FAIL (lock_env up: %s)" % (r.stdout + r.stderr)[-300:])
                return 1
            env_dir = os.path.join(work, "hypr")
            os.makedirs(env_dir)
        bt_work = os.path.join(work, "bt")
        os.makedirs(bt_work)
        for name in names:
            for mode in ("light", "dark"):
                rc, out = ctl(root, "set", name, mode)
                if rc != 0:
                    check("apply.%s.%s" % (name, mode), False, out[-300:])
                    continue
                tok = tokens(name, mode)
                conf = h + "/.config/kitty/current-theme.conf"
                if ARM == "kitty" and name == names[0] and mode == "light":
                    with open(conf, "a") as f:
                        f.write("colour4 #FF0000\n")                          # a key kitty does not know
                kitty_check(name, mode, conf, tok)
                btop_check(name, mode, os.path.realpath(h + "/.config/btop/themes/current.theme"), bt_work)
                if hypr:
                    hypr_check(name, mode, h + "/.config/hypr/config/theme.lua", tok, env_dir)
        btop_reload(bt_work)
    finally:
        if hypr:
            lockenv("down", timeout=120)
        moved = sbx.compare(before, sbx.manifest())
        shutil.rmtree(work, ignore_errors=True)
    check("OUTSIDE.nothing-outside-the-sandbox-changed", not moved, moved[:3])
    nfail = sum(1 for _, ok in RESULTS if not ok)
    print("THEMECTL_PROGRAMS %d checks, %d failed%s" % (len(RESULTS), nfail, " (ARM=%s)" % ARM if ARM else ""))
    print("THEMECTL_PROGRAMS RESULT %s" % ("PASS" if nfail == 0 else "FAIL"))
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
