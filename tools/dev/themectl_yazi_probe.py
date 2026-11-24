#!/usr/bin/env python3
"""The wallpapers' yazi side on the REAL yazi (the installed /usr/bin/yazi, on a pty, in a sandbox HOME -- no window, nothing of the user's):
`themectl install` sets yazi up in the sandbox, then yazi is started in ~/Pictures and its screen read back.

    python3 tools/dev/themectl_yazi_probe.py              last line THEMECTL_YAZI RESULT PASS|FAIL
    ARM=<name> python3 tools/dev/themectl_yazi_probe.py   one fault in a COPY of tools/theme; must FAIL on its needle
    ARM=all ...                                           every arm; THEMECTL_YAZI ARMS PASS only when each failed where it must

  Y1  yazi starts with the plugin and the generated rules, and says no error (a Lua error, a config error)
  Y2  the listed pictures carry the mark in the linemode column and the others do not (a name with glob characters, x[1].png, too)
  Y3  "Open with" (O) on a listed picture offers "Remove from wallpapers" and not "Set as wallpaper"; on another image the reverse
  Y4  the mark follows the list while yazi runs (a mode switch: the plugin reads the list again; the rules need a restart, the mark not)
Arms:  nomark    the plugin's column never draws a mark                       -> Y2
       globraw   the rules name the path as a bare glob (x[1] is a class)     -> Y3
       readonce  the plugin reads the list once and keeps it                  -> Y4

yazi is isolated: HOME, XDG_*, YAZI_CONFIG_HOME and TMPDIR (yazi's DDS socket lives under it) are the sandbox's, so it never meets a yazi
of the user's. Its screen is read by a small terminal model (cursor moves, text; colours ignored).
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
import termios
import time
import fcntl
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import themectl_sandbox as sbx  # noqa: E402

NAME = "THEMECTL_YAZI"
ARM = os.environ.get("ARM", "")
SCRATCH = os.environ.get("SCRATCH") or tempfile.gettempdir()
MARK = "\U000F0E09"
ROWS, COLS = 30, 140
ARMS = {
    "nomark": ("tools/theme/yazi/wallpapers.yazi/main.lua", '			if not listed[tostring(self._file.url)] then\n', '			if true then\n', ["Y2"]),
    "globraw": ("tools/theme/themectl", '    return "\\\\s" + "".join("[%s]" % c if c in "*?[]{}" else c for c in path)\n', '    return "\\\\s" + path\n', ["Y3"]),
    "readonce": ("tools/theme/yazi/wallpapers.yazi/main.lua", '	if now == read_at then\n', '	if read_at then\n', ["Y4"]),
}
YAZI_TOML = """[mgr]
ratio = [0, 3, 0]
linemode = "size"
sort_by = "natural"

[opener]
image = [
    { run = "true %s", block = false, orphan = true, desc = "view image" },
    { run = '@THEMECTL@ wallpaper set %s', block = false, orphan = true, desc = "Set as wallpaper" },
]

[open]
prepend_rules = [
    { mime = "image/*", use = "image" },
]
"""

failures = []


def check(cid, ok, detail=""):
    if not ok:
        failures.append(cid)
    print("%-4s %s%s" % ("ok" if ok else "FAIL", cid, ("  -- " + str(detail)[:600]) if (detail and not ok) else ""))
    return ok


class Screen:
    """Enough of a terminal for ratatui's output: cursor moves (CUP, CUU/CUD/CUF/CUB), erase, text; everything else is skipped."""

    def __init__(self, rows, cols):
        self.rows, self.cols = rows, cols
        self.g = [[" "] * cols for _ in range(rows)]
        self.r = self.c = 0
        self.buf = ""

    def feed(self, data):
        s = self.buf + data
        self.buf = ""
        i, n = 0, len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b":
                if i + 1 >= n:
                    self.buf = s[i:]
                    return
                nx = s[i + 1]
                if nx == "[":
                    m = re.match(r"\x1b\[([0-9;?<>=]*)([ -/]*)([@-~])", s[i:])
                    if not m:
                        self.buf = s[i:]
                        return
                    self._csi(m.group(1), m.group(3))
                    i += m.end()
                    continue
                if nx in "]P_^":                              # OSC / DCS / APC / PM: up to BEL or ST
                    j = s.find("\x07", i + 2)
                    k = s.find("\x1b\\", i + 2)
                    ends = [x for x in (j, k) if x >= 0]
                    if not ends:
                        self.buf = s[i:]
                        return
                    e = min(ends)
                    i = e + (1 if e == j else 2)
                    continue
                i += 3 if nx in "()" else 2
                continue
            if ch == "\r":
                self.c = 0
            elif ch == "\n":
                self.r = min(self.rows - 1, self.r + 1)
            elif ch == "\b":
                self.c = max(0, self.c - 1)
            elif ch >= " ":
                if 0 <= self.r < self.rows and 0 <= self.c < self.cols:
                    self.g[self.r][self.c] = ch
                self.c += 1
            i += 1

    def _csi(self, params, final):
        p = [int(x) if x.isdigit() else 0 for x in params.lstrip("?<>=").split(";")] if params else []
        a = (p[0] if p and p[0] else 1)
        if final in "Hf":
            self.r = (p[0] if len(p) > 0 and p[0] else 1) - 1
            self.c = (p[1] if len(p) > 1 and p[1] else 1) - 1
        elif final == "A":
            self.r = max(0, self.r - a)
        elif final == "B":
            self.r = min(self.rows - 1, self.r + a)
        elif final == "C":
            self.c += a
        elif final == "D":
            self.c = max(0, self.c - a)
        elif final == "G":
            self.c = a - 1
        elif final == "J" and (p[0] if p else 0) == 2:
            self.g = [[" "] * self.cols for _ in range(self.rows)]
        elif final == "K":
            mode = p[0] if p else 0
            row = self.g[self.r] if 0 <= self.r < self.rows else None
            if row is not None:
                rng = range(self.c, self.cols) if mode == 0 else range(0, self.c + 1) if mode == 1 else range(self.cols)
                for x in rng:
                    if 0 <= x < self.cols:
                        row[x] = " "

    def lines(self):
        return ["".join(r).rstrip() for r in self.g]


class Yazi:
    def __init__(self, env, cwd):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execvpe("yazi", ["yazi", cwd], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.screen = Screen(ROWS, COLS)
        self.raw = ""

    def pump(self, secs):
        end = time.time() + secs
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(self.fd, 65536).decode("utf-8", "replace")
                except OSError:
                    return
                self.raw += data
                self.screen.feed(data)
                # answer the terminal queries yazi sends at start (a cursor position report, the device attributes), as a plain VT does
                if "\x1b[6n" in data:
                    os.write(self.fd, b"\x1b[1;1R")
                if "\x1b[c" in data or "\x1b[0c" in data:
                    os.write(self.fd, b"\x1b[?62;22c")

    def send(self, s, wait=0.8):
        os.write(self.fd, s.encode())
        self.pump(wait)

    def wait_for(self, pred, secs):
        end = time.time() + secs
        while time.time() < end:
            self.pump(0.2)
            if pred(self.screen.lines()):
                return True
        return pred(self.screen.lines())

    def stop(self):
        try:
            os.write(self.fd, b"q")
            self.pump(1.0)
        except OSError:
            pass
        try:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            if pid == 0:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
        except OSError:
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass


def row_of(lines, name):
    return next((l for l in lines if name in l and ".png" in l), None)


def marked(lines, name):
    """The row of NAME ends with the mark (the hovered row has the theme's end cap after it)."""
    return MARK in (row_of(lines, name) or "")[-3:]


def main():
    if ARM == "all":
        bad = 0
        for a in ARMS:
            r = subprocess.run([sys.executable, os.path.abspath(__file__)], env=dict(os.environ, ARM=a), capture_output=True, text=True, timeout=300)
            last = (r.stdout.strip().splitlines() or [""])[-1]
            red = sorted(set(re.findall(r"^FAIL (Y\d)", r.stdout, re.M)))
            if last == "%s RESULT FAIL (ARM=%s)" % (NAME, a) and set(ARMS[a][3]) <= set(red):
                print("  ARM %s: FAIL, as it must -- red: %s" % (a, " ".join(red)))
            else:
                print("  ARM %s: NOT PROVEN -- '%s', must be red: %s, red: %s" % (a, last, " ".join(ARMS[a][3]), " ".join(red)))
                bad = 1
        print("%s ARMS %s" % (NAME, "PASS (every arm failed where it must)" if not bad else "FAIL"))
        return bad
    if ARM and ARM not in ARMS:
        print("unknown ARM=%s" % ARM)
        print("%s RESULT FAIL" % NAME)
        return 2
    if shutil.which("yazi") is None:
        print("%s RESULT FAIL (no yazi on the PATH)" % NAME)
        return 1
    work = tempfile.mkdtemp(prefix="themectl_yazi.", dir=SCRATCH)
    before = sbx.manifest()
    y = None
    try:
        tree = os.path.join(work, "tree")
        for rel in ("tools/theme", "tools/lib", "themes", "modules/common/theme"):
            shutil.copytree(os.path.join(REPO, rel), os.path.join(tree, rel), ignore=shutil.ignore_patterns("__pycache__", "*.qsb"))
        if ARM:
            rel, old, new, _ = ARMS[ARM]
            p = os.path.join(tree, rel)
            t = open(p, encoding="utf-8").read()
            if t.count(old) != 1:
                print("%s ARM %s: the anchor is gone (%d matches in %s)" % (NAME, ARM, t.count(old), rel))
                print("%s RESULT FAIL (ARM=%s)" % (NAME, ARM))
                return 1
            open(p, "w", encoding="utf-8").write(t.replace(old, new))
        themectl = os.path.join(tree, "tools/theme/themectl")
        root = os.path.join(work, "sb")
        sbx.make(root, seed=REPO + "/tools/dev/fixtures/themectl/home")
        h = os.path.join(root, "home")
        pics = h + "/Pictures"
        os.makedirs(pics)
        from PIL import Image
        for i, n in enumerate(("a.png", "b.png", "x[1].png", "z.png", "d.png")):
            Image.new("RGB", (8, 8), (40 * i, 120, 200)).save(os.path.join(pics, n))
        os.makedirs(h + "/.config/quickshell", exist_ok=True)
        open(h + "/.config/quickshell/shell.jsonc", "w").write(json.dumps({"theme": {"wallpapers": {"eva": {
            "light": ["~/Pictures/a.png", "~/Pictures/x[1].png"], "dark": ["~/Pictures/d.png"]}}}}, indent=4) + "\n")
        open(h + "/.config/theme/state.json", "w").write('{\n  "theme": "eva",\n  "mode": "light"\n}\n')
        os.makedirs(h + "/.config/yazi")
        open(h + "/.config/yazi/yazi.toml", "w").write(YAZI_TOML.replace("@THEMECTL@", themectl))
        r = sbx.run(root, ["python3", "-B", themectl, "install"])
        if r.returncode != 0:
            print(r.stdout[-800:] + r.stderr[-400:])
        env = sbx.env_of(root)
        tmp = os.path.join(work, "tmp")
        os.makedirs(tmp)
        env.update({"TERM": "xterm-256color", "TMPDIR": tmp, "YAZI_CONFIG_HOME": h + "/.config/yazi", "LANG": "C.UTF-8", "COLORTERM": "truecolor"})
        y = Yazi(env, pics)
        y.wait_for(lambda ls: row_of(ls, "z.png") is not None, 15)
        y.pump(1.5)
        ls = y.screen.lines()
        shot = "\n".join(ls)
        open(os.path.join(SCRATCH, "themectl_yazi_screen%s.txt" % ("-" + ARM if ARM else "")), "w").write(shot)
        err = [l for l in ls if re.search(r"(?i)\b(error|failed|panic)\b", l)]
        check("Y1 yazi starts with the plugin and the rules and says no error", r.returncode == 0 and row_of(ls, "z.png") is not None and not err, (r.returncode, err, shot[-600:]))
        got = {n: marked(ls, n) for n in ("a.png", "b.png", "x[1].png", "z.png", "d.png")}
        check("Y2 the listed pictures carry the mark, the others not", got == {"a.png": True, "b.png": False, "x[1].png": True, "z.png": False, "d.png": False}, (got, shot))

        def menu(n_down):
            y.send("gg", 0.5)
            for _ in range(n_down):
                y.send("j", 0.3)
            y.send("O", 1.2)
            got = "\n".join(y.screen.lines())
            y.send("\x1b", 0.8)
            return got
        # natural order: a.png b.png d.png x[1].png z.png
        on_a, on_x, on_z = menu(0), menu(3), menu(4)
        check("Y3 Open with: Remove on a listed picture, Set on another image", all("Remove from wallpapers" in m and "Set as wallpaper" not in m for m in (on_a, on_x))
              and "Set as wallpaper" in on_z and "Remove from wallpapers" not in on_z, (on_a[-500:], on_x[-500:], on_z[-500:]))
        r = sbx.run(root, ["python3", "-B", themectl, "set", "eva", "dark", "--only", "wallpaper,yazi"])
        ok = False
        for _ in range(8):                                   # the plugin reads the list at most once a second: a redraw after that shows it
            y.send("j", 0.6)
            y.send("k", 0.6)
            ls = y.screen.lines()
            ok = marked(ls, "d.png") and not marked(ls, "a.png")
            if ok:
                break
        check("Y4 the mark follows a mode switch while yazi runs", r.returncode == 0 and ok, "\n".join(y.screen.lines()))
    finally:
        if y is not None:
            y.stop()
        moved = sbx.compare(before, sbx.manifest())
        shutil.rmtree(work, ignore_errors=True)
    check("OUTSIDE nothing outside the sandbox changed", not moved, moved[:3])
    print("%s RESULT %s%s" % (NAME, "PASS" if not failures else "FAIL", " (ARM=%s)" % ARM if ARM else ""))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
