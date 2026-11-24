#!/usr/bin/env python3
"""lares-migrate.py -- the move to the name Lares, for tools/shell/lares (`migrate-name`, `cleanup-old-name`) and the checks `deploy` asks.

    lares-migrate.py pending   CTX...                 exit 1 (and the list) while a directory of ours is still only under its old name
    lares-migrate.py migrate   CTX... [--dry-run]     `lares migrate-name`: the plan, a typed yes, then the moves
    lares-migrate.py shims     CTX...                 the OLD entry-point names the user's lines (or an installed old root file) still run, one per line
    lares-migrate.py scan      CTX...                 every user line that still names an old name or path (exit 1 when there is one)
    lares-migrate.py cleanup   CTX... [--dry-run]     `lares cleanup-old-name`: the plan (or the reasons it refuses), a typed yes, the symlinks removed

    CTX: --state D --cache D --data D --runtime D --home D --config-home D --bindir D --repo D --tool PATH --root-prefix D --hypr D

THE MOVE. Every directory of ours under a Quickshell directory (~/.local/state/quickshell/<ours>, ~/.cache/quickshell/<ours>,
~/.local/share/quickshell/<ours>), the tool's own dir (~/.local/state/qs-shell -> ~/.local/state/lares/tool), the dictation's home
(~/.cache/quickshell-stt -> ~/.cache/lares-stt), the lock's cache and the runtime dirs (qs-shell -> lares, qs-session -> lares-session)
goes to its Lares name, and a SYMLINK stays at the old path. What Quickshell owns (by-shell, by-id, vfs, crashes, qmlcache,
qtpipelinecache-*) is never touched. NO INSTANT WITHOUT THE OLD PATH: a running shell, supervisor and lock read the old path, so the move
is one exchange, never "rename, then link". A symlink is made at the NEW path whose target is the NEW path itself (a dangling loop is
allowed), and renameat2(RENAME_EXCHANGE) swaps the two names in one syscall: the new name is the directory, and the old name is the
symlink that was waiting at the new one -- pointing at the new name. Both paths are on one filesystem, or the move is refused.
"""
import argparse
import ctypes
import json
import os
import re
import shutil
import subprocess
import sys

# ---- what is Quickshell's, never ours ---------------------------------------------------------------------------------------
QS_OWN = {"by-shell", "by-id", "vfs", "crashes", "qmlcache"}
# Qt's own caches under the app's cache dir (QStandardPaths::CacheLocation = ~/.cache/quickshell): the RHI pipeline cache, the GL program
# binary cache (`qtshadercache-<abi>`, made again at every quickshell start) and Qt Quick Effects' shader builder (`_qt_QGfxShaderBuilder_<v>`).
# Round 9 left the last two out: the first migrate-name moved them, cleanup-old-name took the links away, the next start made an empty
# `qtshadercache-*` at the old name, and the deploy gate refused it as "not moved" (2026-11-15).
QS_OWN_PREFIXES = ("qtpipelinecache", "qtshadercache", "_qt_")


def qs_own(name):
    return name in QS_OWN or name.startswith(QS_OWN_PREFIXES)


# ---- the old names: what a user line may still say --------------------------------------------------------------------------
QS_ENV_OWN = ("APP_ID CONFIG_NAME CONFIG_PATH CRASHREPORT_URL DISABLE_CRASH_HANDLER DISABLE_DMABUF DISABLE_FILE_WATCHER DROP_EXPENSIVE_FONTS "
              "ICON_THEME MANIFEST NO_BUFFER_REUSE NO_FILTER_QT_LOGS NO_RELOAD_POPUP NO_XINERAMA_STRUTS PIPEWIRE_IMMEDIATE_RECONNECT").split()
OLD_NAMES = [   # (regexp, what it is, what to write now)
    (r"(?<![\w-])qs-shell(?![\w-])", "qs-shell", "lares"),
    (r"(?<![\w-])qs-lock-session(?![\w-])", "qs-lock-session", "lares-lock-session"),
    (r"(?<![\w-])qs-lock-held(?![\w-])", "qs-lock-held", "lares-lock-held"),
    (r"(?<![\w-])qs-lock-warm(?![\w-])", "qs-lock-warm", "lares-lock-warm"),
    (r"(?<![\w-])qs-lock-hop(?![\w-])", "qs-lock-hop", "lares-lock-hop"),
    (r"(?<![\w-])qs-lock(?![\w-])", "qs-lock", "lares-lock"),
    (r"(?<![\w-])qs-boot-lock(?![\w-])", "qs-boot-lock", "lares-boot-lock"),
    (r"(?<![\w-])qs-session(?![\w-])", "qs-session", "lares-session"),
    (r"(?<![\w-])qs-ime(?![\w-])", "qs-ime", "lares-ime"),
    (r"hyprland-qslock", "hyprland-qslock", "hyprland-lares"),
    (r"quickshell:[a-z]", "quickshell:<name> (the global shortcut's app id)", "lares:<name>"),
    (r"\.local/state/quickshell/(?!by-shell)", "~/.local/state/quickshell/<ours>", "~/.local/state/lares/<ours>"),
    (r"\.local/state/qs-shell", "~/.local/state/qs-shell", "~/.local/state/lares/tool"),
    (r"\.local/share/quickshell/(?!by-shell)", "~/.local/share/quickshell/<ours>", "~/.local/share/lares/<ours>"),
    (r"\.cache/quickshell(?:-[a-z]+)?/(?!qmlcache|qtpipelinecache|crashes|by-shell)", "~/.cache/quickshell/<ours>", "~/.cache/lares/<ours>"),
    (r"(?<![\w-])qs_(?:bar|osd_pill|auth_pill|curtain|toast_pill)_noanim|qs_bar_above_lock|qs_lock_cover", "a layer-rule name of the old namespace", "lares_*"),
    (r"\^qs-(?:bar|curtain|lock-cover)\$", "a layer namespace", "^lares-...$"),
    (r"\bQS_(?!(?:%s)\b)[A-Z][A-Z0-9_]+" % "|".join(QS_ENV_OWN), "a QS_ variable of ours", "LARES_..."),
]
OLD_NAMES = [(re.compile(rx), a, b) for rx, a, b in OLD_NAMES]
ENTRY_POINTS = ("qs-shell", "qs-lock-session", "qs-lock-held", "qs-lock-warm")   # the names a deploy can put a shim at
MARK = re.compile(r"^\s*(?:--|#|//) qs-shell deploy(?: BEGIN | END |:)")           # a mark an earlier deploy wrote: bytes of the past, cleanup-marks'

SCAN_GLOBS = [   # where a user line may name an old path: (directory under home or config-home, suffixes, depth)
    ("hypr", (".lua", ".conf", ".sh"), 5),
]
SCAN_FILES = [".local/bin/hyprlock", ".bashrc", ".bash_profile", ".profile", ".zshrc"]
SCAN_DIRS = [(".config/yazi", (".toml", ".lua"), 3), (".config/systemd/user", (".service", ".conf", ".timer"), 3),
             (".config/environment.d", (".conf",), 1), (".config/kitty", (".conf",), 1)]

ROOT_OLD = ["/usr/local/bin/qs-boot-lock", "/usr/local/share/wayland-sessions/hyprland-qslock.desktop", "/etc/pam.d/qs-lock",
            "/etc/pam.d/qs-lock-face", "/usr/share/polkit-1/actions/org.quickshell.silicon.helper.policy",
            "/etc/polkit-1/rules.d/50-quickshell-silicon-helper.rules"]
ROOT_NEW = {"/etc/pam.d/qs-lock": "/etc/pam.d/lares-lock", "/etc/pam.d/qs-lock-face": "/etc/pam.d/lares-lock-face",
            "/usr/local/bin/qs-boot-lock": "/usr/local/bin/lares-boot-lock",
            "/usr/local/share/wayland-sessions/hyprland-qslock.desktop": "/usr/local/share/wayland-sessions/hyprland-lares.desktop",
            "/usr/share/polkit-1/actions/org.quickshell.silicon.helper.policy": "/usr/share/polkit-1/actions/org.lares.silicon.helper.policy",
            "/etc/polkit-1/rules.d/50-quickshell-silicon-helper.rules": "/etc/polkit-1/rules.d/50-lares-silicon-helper.rules"}


# a root file the user may not be able to see -> the one beside it that says whether it is installed
ROOT_PAIR = {"/etc/polkit-1/rules.d/50-quickshell-silicon-helper.rules": "/usr/share/polkit-1/actions/org.quickshell.silicon.helper.policy"}


class Ctx:
    def __init__(self, a):
        self.home, self.state, self.cache, self.data = a.home, a.state, a.cache, a.data
        self.runtime, self.config_home, self.bindir = a.runtime, a.config_home, a.bindir
        self.repo, self.tool, self.root_prefix, self.hypr = a.repo, a.tool, a.root_prefix or "", a.hypr
        self.dry = getattr(a, "dry_run", False)

    def tilde(self, p):
        return "~" + p[len(self.home):] if self.home and p.startswith(self.home + "/") else p

    def root(self, p):
        return self.root_prefix + p


# ==================================================================================================
# the moves
# ==================================================================================================
def lexists(p):
    return os.path.lexists(p)


def placeholder(p):
    """The dangling loop move_one leaves at a NEW name between its two steps (a run killed there leaves it): never a conflict."""
    return os.path.islink(p) and os.readlink(p) == p


def entries(d):
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []


def moves_of(c):
    """[(old, new, what)]: every path that has a Lares name."""
    out = []
    for kind, root in (("state", c.state), ("cache", c.cache), ("data", c.data)):
        old_root, new_root = os.path.join(root, "quickshell"), os.path.join(root, "lares")
        if os.path.isdir(old_root) and not os.path.islink(old_root):
            for name in entries(old_root):
                if not qs_own(name):
                    out.append((os.path.join(old_root, name), os.path.join(new_root, name), kind))
    out.append((os.path.join(c.state, "qs-shell"), os.path.join(c.state, "lares", "tool"), "state: the tool's own dir"))
    out.append((os.path.join(c.cache, "quickshell-stt"), os.path.join(c.cache, "lares-stt"), "cache: the dictation's home"))
    out.append((os.path.join(c.cache, "quickshell-lock"), os.path.join(c.cache, "lares-lock"), "cache: the lock's shader stamp"))
    out.append((os.path.join(c.runtime, "qs-shell"), os.path.join(c.runtime, "lares"), "runtime: the supervisor's dir"))
    out.append((os.path.join(c.runtime, "qs-session"), os.path.join(c.runtime, "lares-session"), "runtime: session restore's marks"))
    return out


def classify(old, new):
    """(state, why): done | absent | move | conflict | xdev | elsewhere"""
    if not lexists(old):
        return "absent", ""
    if os.path.islink(old):
        tgt = os.readlink(old)
        if tgt == new or os.path.realpath(old) == os.path.realpath(new) and lexists(new):
            return "done", ""
        return "elsewhere", "a link to %s" % tgt
    if lexists(new) and not placeholder(new):
        if os.path.isdir(new) and not os.path.islink(new) and not entries(new):
            return "move", "(an empty directory is in the way: removed)"
        return "conflict", "both exist"
    parent = os.path.dirname(new)
    probe = parent
    while not os.path.exists(probe) and probe != "/":
        probe = os.path.dirname(probe)
    if os.lstat(old).st_dev != os.stat(probe).st_dev:
        return "xdev", "not on one filesystem"
    return "move", ""


def plan(c):
    rows = []
    for old, new, what in moves_of(c):
        st, why = classify(old, new)
        rows.append({"old": old, "new": new, "what": what, "state": st, "why": why})
    return rows


def pending(c):
    return [r for r in plan(c) if r["state"] in ("move", "conflict", "xdev")]


def returns_of(c):
    """Quickshell's / Qt's own dirs an earlier migrate-name moved under the Lares name by mistake: [(lares path, old path, how)], how =
    `link` (the old path is still our link to it: one exchange back, then the link goes), `absent` (cleanup took the link: a rename back)
    or `again` (Qt made the dir again at the old path: the moved copy is a cache nobody reads, removed). Never part of `pending`: a
    misplaced cache is no reason to refuse a deploy."""
    out = []
    for root in (c.state, c.cache, c.data):
        old_root, new_root = os.path.join(root, "quickshell"), os.path.join(root, "lares")
        for name in entries(new_root):
            new = os.path.join(new_root, name)
            if not qs_own(name) or os.path.islink(new) or not os.path.isdir(new):
                continue
            old = os.path.join(old_root, name)
            if os.path.islink(old) and os.readlink(old) == new:
                out.append((new, old, "link"))
            elif not lexists(old):
                out.append((new, old, "absent"))
            elif os.path.isdir(old) and not os.path.islink(old):
                out.append((new, old, "again"))
    return out


def put_back(new, old, how):
    if how == "link":
        exchange(old, new)             # old: the directory again; new: the link, whose target is its own name now
        if os.path.islink(new):
            os.unlink(new)
    elif how == "absent":
        os.makedirs(os.path.dirname(old), exist_ok=True)
        os.rename(new, old)
    else:
        shutil.rmtree(new)
    if os.path.islink(old) or not os.path.isdir(old) or lexists(new):
        raise RuntimeError("%s is not back at %s" % (new, old))


_libc = None


def exchange(a, b):
    """renameat2(a, b, RENAME_EXCHANGE): the two names swap in one syscall."""
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL(None, use_errno=True)
    try:
        fn = _libc.renameat2
    except AttributeError:
        subprocess.run(["mv", "--exchange", "--", a, b], check=True)
        return
    r = fn(-100, os.fsencode(a), -100, os.fsencode(b), 2)
    if r != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e), "%s <-> %s" % (a, b))


def move_one(old, new):
    """The zero-gap move. Afterwards `new` is the directory (or file) and `old` a symlink to it."""
    os.makedirs(os.path.dirname(new), exist_ok=True)
    if placeholder(new):
        os.unlink(new)
    if lexists(new) and os.path.isdir(new) and not os.path.islink(new) and not entries(new):
        os.rmdir(new)
    os.symlink(new, new)               # a dangling loop, allowed: the placeholder the exchange puts at the OLD name
    try:
        exchange(old, new)
    except BaseException:
        try:
            os.unlink(new)
        except OSError:
            pass
        raise
    if not (os.path.islink(old) and os.readlink(old) == new and lexists(new) and not os.path.islink(new)):
        raise RuntimeError("after the exchange %s is not a link to %s" % (old, new))


def our_link(c, p):
    """~/.local/bin/qs-shell: a symlink of ours (to this repo's tool, or into a snapshot's) -- never a wrapper the user wrote."""
    if not os.path.islink(p):
        return False
    t = os.readlink(p)
    return os.path.basename(t) == "qs-shell" or os.path.realpath(p).endswith("/tools/shell/qs-shell") or \
        os.path.basename(os.path.realpath(p)) == "lares"


def ime_copy(c):
    """The dictation's input method is BUILT, never deployed: its binary keeps the old name until it is rebuilt, so the Lares name is a copy
    of it (before the move it is still in ~/.cache/quickshell-stt; the copy is made after it, in the Lares home)."""
    new_bin = os.path.join(c.cache, "lares-stt", "bin")
    for h in (new_bin, os.path.join(c.cache, "quickshell-stt", "bin")):
        old = os.path.join(h, "qs-ime")
        if os.path.isfile(old) and not os.path.islink(old) and not lexists(os.path.join(new_bin, "lares-ime")):
            return os.path.join(new_bin, "qs-ime"), os.path.join(new_bin, "lares-ime")
    return None


def link_plan(c):
    items = []
    new = os.path.join(c.bindir, "lares")
    want = c.tool
    if not (os.path.islink(new) and os.readlink(new) == want):
        items.append(("LINK", new, want))
    old = os.path.join(c.bindir, "qs-shell")
    if lexists(old):
        if our_link(c, old):
            items.append(("UNLINK", old, os.readlink(old)))
        else:
            items.append(("KEEP", old, "not a link of ours (a file or a link you made): left alone"))
    return items


def cmd_pending(c):
    rows = pending(c)
    for r in rows:
        print("%s -> %s (%s)" % (c.tilde(r["old"]), c.tilde(r["new"]), r["state"] + (": " + r["why"] if r["why"] else "")))
    return 1 if rows else 0


def typed_yes(prompt):
    sys.stdout.write(prompt)
    sys.stdout.flush()
    ans = sys.stdin.readline().strip()
    if not sys.stdin.isatty():
        print()
    return ans == "yes"


def cmd_migrate(c):
    rows = plan(c)
    todo = [r for r in rows if r["state"] == "move"]
    bad = [r for r in rows if r["state"] in ("conflict", "xdev")]
    links = link_plan(c)
    ime = ime_copy(c)
    back = returns_of(c)
    print("lares migrate-name -- the project's name is Lares: what is ours moves to its Lares name, and a symlink stays at the old path")
    print("(each move is ONE exchange: no instant without the old path, so the running shell, supervisor and lock go on reading it)\n")
    for r in rows:
        if r["state"] == "move":
            print("WILL MOVE   %s  ->  %s%s" % (c.tilde(r["old"]), c.tilde(r["new"]), "  " + r["why"] if r["why"] else ""))
        elif r["state"] == "done":
            print("done        %s is a link to %s already" % (c.tilde(r["old"]), c.tilde(r["new"])))
        elif r["state"] == "conflict":
            print("REFUSED     %s and %s both exist: merge them by hand, then run this again" % (c.tilde(r["old"]), c.tilde(r["new"])))
        elif r["state"] == "xdev":
            print("REFUSED     %s and %s are on different filesystems: a move there is a copy, never an exchange" % (c.tilde(r["old"]), c.tilde(r["new"])))
        elif r["state"] == "elsewhere":
            print("left alone  %s is %s" % (c.tilde(r["old"]), r["why"]))
    for kind, path, why in links:
        if kind == "LINK":
            print("WILL LINK   %s -> %s" % (c.tilde(path), c.tilde(why)))
        elif kind == "UNLINK":
            print("WILL REMOVE %s (a link of ours, -> %s): the command is `lares` now" % (c.tilde(path), c.tilde(why)))
        else:
            print("left alone  %s (%s)" % (c.tilde(path), why))
    if ime:
        print("WILL COPY   %s -> %s (the old binary under its new name; rebuild it when it is convenient: tools/stt/ime/build.sh)"
              % (c.tilde(ime[0]), c.tilde(ime[1])))
    for new, old, how in back:
        if how == "again":
            print("WILL REMOVE %s (Qt's own, moved here by an earlier run; Qt made it again at %s)" % (c.tilde(new), c.tilde(old)))
        else:
            print("WILL PUT BACK %s  ->  %s (Quickshell's / Qt's own, moved by an earlier run)" % (c.tilde(new), c.tilde(old)))
    backing = {old for _, old, _ in back}
    own = [os.path.join(root, n) for root in (os.path.join(c.state, "quickshell"), os.path.join(c.cache, "quickshell"),
                                              os.path.join(c.data, "quickshell")) for n in entries(root) if qs_own(n)]
    for p in own:
        if p not in backing:
            print("untouched   %s (Quickshell's own)" % c.tilde(p))
    if bad:
        print("\nREFUSED: %d path(s) need you -- nothing was moved" % len(bad))
        return 1
    if not todo and not [x for x in links if x[0] in ("LINK", "UNLINK")] and not ime and not back:
        print("\nnothing to do: every directory of ours is under its Lares name already")
        return 0
    if c.dry:
        print("\nnothing was changed")
        return 0
    if not typed_yes("\nType yes to move them: "):
        print("nothing was moved")
        return 1
    moved = 0
    for r in todo:
        try:
            move_one(r["old"], r["new"])
        except (OSError, RuntimeError) as e:
            print("FAILED      %s: %s -- stopped after %d move(s); run it again to go on" % (c.tilde(r["old"]), e, moved))
            return 1
        moved += 1
        print("moved       %s  ->  %s" % (c.tilde(r["old"]), c.tilde(r["new"])))
    for kind, path, why in links:
        try:
            if kind == "LINK":
                os.makedirs(c.bindir, exist_ok=True)
                tmp = path + ".new"
                if lexists(tmp):
                    os.unlink(tmp)
                os.symlink(why, tmp)
                os.replace(tmp, path)
                print("linked      %s -> %s" % (c.tilde(path), c.tilde(why)))
            elif kind == "UNLINK":
                os.unlink(path)
                print("removed     %s" % c.tilde(path))
        except OSError as e:
            print("FAILED      %s: %s" % (c.tilde(path), e))
            return 1
    if ime:
        shutil.copy2(ime[0], ime[1])
        print("copied      %s -> %s" % (c.tilde(ime[0]), c.tilde(ime[1])))
    for new, old, how in back:
        try:
            put_back(new, old, how)
        except (OSError, RuntimeError) as e:
            print("FAILED      %s: %s" % (c.tilde(new), e))
            return 1
        print(("removed     %s" if how == "again" else "put back    %s") % c.tilde(new if how == "again" else old))
    print("\ndone: %d move(s); the old paths are symlinks until `lares cleanup-old-name`" % moved)
    return 0


# ==================================================================================================
# the user's lines
# ==================================================================================================
def scan_files(c):
    files = []
    hypr = c.hypr
    if os.path.isdir(hypr):
        base = hypr.rstrip("/").count("/")
        for d, ds, fs in os.walk(hypr):
            ds[:] = sorted(x for x in ds if not x.startswith("."))
            if d.rstrip("/").count("/") - base > 5:
                ds[:] = []
            files += [os.path.join(d, f) for f in sorted(fs) if f.endswith((".lua", ".conf", ".sh", ".toml"))]
    for rel in SCAN_FILES:
        p = os.path.join(c.home, rel)
        if os.path.isfile(p):
            files.append(p)
    for rel, suf, depth in SCAN_DIRS:
        d = os.path.join(c.home, rel)
        if os.path.isdir(d):
            for dd, ds, fs in os.walk(d):
                if dd.rstrip("/").count("/") - d.rstrip("/").count("/") >= depth:
                    ds[:] = []
                files += [os.path.join(dd, f) for f in sorted(fs) if f.endswith(suf)]
    cfg = os.path.join(c.config_home, "quickshell")
    for d in (cfg, os.path.join(cfg, "config")):
        for f in entries(d):
            if f.endswith((".json", ".jsonc")) and os.path.isfile(os.path.join(d, f)):
                files.append(os.path.join(d, f))
    seen, out = set(), []
    for f in files:
        rp = os.path.realpath(f)
        if rp not in seen:
            seen.add(rp)
            out.append(f)
    return out


def scan_lines(c):
    hits = []
    for f in scan_files(c):
        try:
            text = open(f, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for n, line in enumerate(text.split("\n"), 1):
            if MARK.match(line):
                continue
            for rx, old, new in OLD_NAMES:
                if rx.search(line):
                    hits.append({"file": f, "line": n, "old": old, "new": new, "text": line.strip()[:160]})
                    break
    return hits


def root_seen(c, p):
    """True / False, or None when the user cannot know: /etc/polkit-1/rules.d is root:polkitd 0750, so a rule there reads as absent."""
    if os.path.exists(c.root(p)):
        return True
    d = os.path.dirname(c.root(p))
    return None if os.path.isdir(d) and not os.access(d, os.X_OK) else False


def root_state(c):
    """The old root files that are installed, and the autologin line: read only (under --root-prefix). A file that cannot be seen
    counts as installed when the old file it goes with is (the old rule with the old policy): `rm -f` of it is harmless."""
    old = [p for p in ROOT_OLD if root_seen(c, p) or root_seen(c, p) is None and os.path.exists(c.root(ROOT_PAIR.get(p, p)))]
    sddm = []
    d = c.root("/etc/sddm.conf.d")
    for f in entries(d):
        try:
            for n, line in enumerate(open(os.path.join(d, f), encoding="utf-8", errors="replace").read().split("\n"), 1):
                if re.match(r"^\s*Session\s*=\s*hyprland-qslock\s*$", line):
                    sddm.append("/etc/sddm.conf.d/%s:%d" % (f, n))
        except OSError:
            pass
    return old, sddm


def wanted_shims(c):
    names = set()
    for h in scan_lines(c):
        t = h["text"]
        for e in ENTRY_POINTS:
            if re.search(r"(?<![\w-])%s(?![\w-])" % re.escape(e), t):
                names.add(e)
    old, sddm = root_state(c)
    if "/usr/local/bin/qs-boot-lock" in old or sddm:
        names.add("qs-lock-session")   # the installed boot lock runs <lock>/current/tools/lockscreen/qs-lock-session --boot
    return sorted(names)


def cmd_shims(c):
    for n in wanted_shims(c):
        print(n)
    return 0


def cmd_scan(c):
    hits = scan_lines(c)
    old, sddm = root_state(c)
    for h in hits:
        print("%s:%d  names %s (now: %s)\n      %s" % (c.tilde(h["file"]), h["line"], h["old"], h["new"], h["text"]))
    for p in old:
        print("root        %s is installed (its Lares file: %s%s)" % (p, ROOT_NEW[p], {True: "", None: " -- root's to read"}.get(root_seen(c, ROOT_NEW[p]), " -- NOT installed yet")))
    for s in sddm:
        print("root        %s still says Session=hyprland-qslock" % s)
    return 1 if hits or sddm else 0


# ==================================================================================================
# cleanup-old-name
# ==================================================================================================
def venv_hits(c):
    """The stt venv names an old path in pyvenv.cfg or a script's shebang: a venv is not relocatable, `tools/stt/setup.sh` rebuilds it."""
    out = []
    venv = os.path.join(c.data, "lares", "stt", "venv")
    if not os.path.isdir(venv):
        return out
    pat = re.compile(rb"\.local/share/quickshell/")
    for rel in ["pyvenv.cfg"] + ["bin/" + f for f in entries(os.path.join(venv, "bin"))]:
        p = os.path.join(venv, rel)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        try:
            with open(p, "rb") as fh:
                head = fh.read(4096)
        except OSError:
            continue
        if b"\0" in head:
            continue
        first = head.split(b"\n", 1)[0] if rel != "pyvenv.cfg" else head
        if pat.search(first):
            out.append(rel)
    return out


def running_old(c):
    """What of the OLD name still runs: an old-name supervisor of this session, a lock held under the old lock file."""
    why = []
    pidf = os.path.join(c.runtime, "lares", "supervise.pid")
    try:
        pid = int(open(pidf).read().strip())
        argv = open("/proc/%d/cmdline" % pid, "rb").read().replace(b"\0", b" ").decode(errors="replace")
        if "qs-shell-supervise" in argv:
            why.append("the supervisor of this session still runs under the old name (pid %d): `lares deploy` replaces it" % pid)
    except (OSError, ValueError):
        pass
    old_lock = os.path.join(c.runtime, "qs-lock.lock")
    held = os.path.join(c.repo, "tools", "lockscreen", "lares-lock-held")
    if os.path.exists(old_lock) and os.access(held, os.X_OK):
        if subprocess.run([held, old_lock], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            why.append("a lock of the old name is up ($XDG_RUNTIME_DIR/qs-lock.lock is held)")
    return why


def leaves(p):
    """What removing an old root file would leave undone while its Lares file is not there."""
    if "/pam.d/" in p:
        return "the lock without its PAM service"
    if "/bin/" in p:
        return "the boot without its lock"
    if "wayland-sessions" in p:
        return "SDDM without its session"
    return "silicon's helper asking for a password"


def cmd_cleanup(c):
    rows = plan(c)
    links = [r for r in rows if r["state"] == "done"]
    real = [r for r in rows if r["state"] in ("move", "conflict", "xdev")]
    hits = scan_lines(c)
    old_root, sddm = root_state(c)
    venv = venv_hits(c)
    run = running_old(c)
    reasons = []
    for r in real:
        reasons.append("%s is not a link to its Lares name yet: `lares migrate-name` first" % c.tilde(r["old"]))
    for h in hits:
        reasons.append("%s:%d still names %s (now: %s)" % (c.tilde(h["file"]), h["line"], h["old"], h["new"]))
    for s in sddm:
        reasons.append("root: %s still says Session=hyprland-qslock: the boot session of the old name" % s)
    for p in old_root:
        if root_seen(c, ROOT_NEW[p]) is False:   # unknown (a rule the user cannot see) is judged by its policy's row
            reasons.append("root: %s is installed and %s is not: removing the old one would leave %s" % (p, ROOT_NEW[p], leaves(p)))
    for rel in venv:
        reasons.append("the dictation's venv names the old path (%s): rebuild it with tools/stt/setup.sh (a venv is not relocatable)" % rel)
    reasons += run
    # something REAL at an old path that is not our symlink: new data was written there after the move
    for r in rows:
        if r["state"] == "elsewhere":
            reasons.append("%s is %s, not our link: look at it by hand" % (c.tilde(r["old"]), r["why"]))
    print("lares cleanup-old-name -- the symlinks the move left at the old paths go; what the old name installed as root is listed to remove\n")
    if reasons:
        for x in reasons:
            print("REFUSED     %s" % x)
        print("\nREFUSED: %d reason(s) -- nothing was removed" % len(reasons))
        return 1
    ime_old = os.path.join(c.cache, "lares-stt", "bin", "qs-ime")
    ime_new = os.path.join(c.cache, "lares-stt", "bin", "lares-ime")
    drop_ime = os.path.isfile(ime_old) and os.path.isfile(ime_new)
    for r in links:
        print("WILL REMOVE %s (a link to %s)" % (c.tilde(r["old"]), c.tilde(r["new"])))
    if drop_ime:
        print("WILL REMOVE %s (lares-ime is built: the copy under the old name goes)" % c.tilde(ime_old))
    if not links and not drop_ime:
        print("nothing to do in your home: no symlink of the old name is left")
    if old_root:
        print("\nthe root files of the old name (yours to remove, in a terminal, once nothing names them):")
        print("      sudo rm -f %s" % " ".join(old_root))
    if not links and not drop_ime:
        return 0
    if c.dry:
        print("\nnothing was changed")
        return 0
    if not typed_yes("\nType yes to remove the symlinks: "):
        print("nothing was removed")
        return 1
    for r in links:
        try:
            if os.path.islink(r["old"]) and os.readlink(r["old"]) == r["new"]:
                os.unlink(r["old"])
                print("removed     %s" % c.tilde(r["old"]))
        except OSError as e:
            print("FAILED      %s: %s" % (c.tilde(r["old"]), e))
            return 1
    if drop_ime:
        os.unlink(ime_old)
        print("removed     %s" % c.tilde(ime_old))
    print("\ndone: nothing of the old name is left in your home")
    if old_root:
        print("the root files above are the one step left: sudo rm -f %s" % " ".join(old_root))
    return 0


def main():
    ap = argparse.ArgumentParser(prog="lares-migrate.py")
    ap.add_argument("cmd", choices=["pending", "migrate", "shims", "scan", "cleanup"])
    for k in ("state", "cache", "data", "runtime", "home", "config-home", "bindir", "repo", "tool", "hypr"):
        ap.add_argument("--" + k, required=True)
    ap.add_argument("--root-prefix", default="")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    c = Ctx(a)
    return {"pending": cmd_pending, "migrate": cmd_migrate, "shims": cmd_shims, "scan": cmd_scan, "cleanup": cmd_cleanup}[a.cmd](c)


if __name__ == "__main__":
    sys.exit(main())
