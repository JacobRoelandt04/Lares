#!/usr/bin/env python3
# Quickshell's runtime directories for tools/dev/sandbox.sh: what a test run leaves
# there, and the private runtime dir an offscreen run gets instead.
#
# WHY. Every quickshell keeps a directory per instance under
# $XDG_RUNTIME_DIR/quickshell/by-id/<id>/ (instance.lock, ipc.sock, log.log,
# log.qslog: 80 KB to a few MB) and NEVER removes it. /run/user/<uid> is a
# 2.3 GB tmpfs shared with the desktop's sockets; on 2026-09-25 it held 25,314
# of them from four days of test runs, and every quickshell then logged "No
# space left on device" -- a warning, so every gate failed on it.
#
#   lares_runtime.py sweep --rt RT [--rt RT2] --sandbox SB [--scratch S] [--root R]
#       remove the instance dirs in RT whose config lies under this sandbox
#       (or under its scratch dir, when that is the sandbox's own parent, at any
#       depth -- unless it is a directory everybody uses, /tmp itself) and
#       whose process is gone; and every private runtime dir this script made
#       whose owner is gone and in which nothing runs; then the sandbox's
#       private home (<SB>.lrrt, beside it) if that is empty
#   lares_runtime.py mkrt --sandbox SB --parent RT --owner PID [--link GROUPS]
#       make a private runtime dir (0700, short enough for a socket path) and
#       print it; every entry of RT but quickshell's instance tree
#       (RT/quickshell) is linked into it -- and, unless GROUPS (a comma list:
#       pipewire, mpd) names them, the session's audio: PipeWire's sockets and
#       its PulseAudio shim (pipewire-*, pulse/) and mpd's (mpd/). A socket is
#       not read-only: a test that links one can write the user's default
#       audio device (2026-10-21: a spike moved the default source for 1.5
#       minutes). A test that needs a daemon makes its own, in a runtime dir of
#       its own; one that only
#       READS the session's audio opts in (SANDBOX_LINK=pipewire,mpd).
#   lares_runtime.py watch [--cmd PID] [--caller PID] --rt RT --sandbox SB
#                       [--scratch S] [--root R] [--private PRT]
#       wait for the command, sweep, remove its private runtime dir; then wait
#       for the caller and sweep again (one caller-watcher per caller and
#       sandbox, by a flock in the private home); the empty home goes last.
#       Closes every inherited fd but 0-2 first (sandbox.sh points 0-2 at
#       /dev/null): a watcher that held a caller's pipe would hang a `$(...)`.
#
# What an instance is and whether it lives are read the way quickshell's own
# `list` reads them -- but without starting a quickshell (a perf gate counts
# `pgrep -x quickshell`, and a watcher firing at a run's end would show up in
# it): instance.lock is a QDataStream (id, config path, shell id, app id,
# launch time, pid, display), and the instance holds a POSIX write lock on it
# for as long as it runs. An instance counts as ALIVE when that lock is held,
# OR when the pid it recorded is a running quickshell (a lock not yet taken),
# OR when anything about it cannot be read. Only a dead one is removed, and
# only its own entries: by-id/<id>, by-pid/<pid> when it points there, and
# by-shell/<shell>/<id>. by-path and by-shell/<shell> name a CONFIG, not an
# instance, and a new instance of the same config may be creating them this
# moment: never touched. Nothing outside <rt>/quickshell is touched at all,
# and never a config under ~/.config/quickshell or the git tree.
#
# SANDBOX_REAP_LOG=<file>: every removal is appended there, one line each,
# and "watch end" when a watcher is done (tools/dev/sandbox.sh writes "spawn"
# before it starts one) reads it. Nothing is
# ever printed but mkrt's path: a runner's log is not the place for a sweep's
# troubles, and a sweep must never be what fails a gate.
import argparse
import fcntl
import json
import os
import re
import select
import shutil
import struct
import sys
import tempfile
import time

MARK = ".lares-sandbox-rt"
# The entries of the real runtime dir that stay out of a private one unless asked for (--link): group -> its entries.
LINK_GROUPS = {
    "pipewire": lambda name: name.startswith("pipewire") or name == "pulse",
    "mpd": lambda name: name == "mpd",
    # The lock's socket directory: a live shell in a sandbox replaces the socket the running shell listens on, and the lock can no longer reach it.
    "lock": lambda name: name == "lares-lock",
}
SOCK_ROOM = 39          # len("/quickshell/by-id/") + an 11-char id + len("/ipc.sock") + 1
SOCK_MAX = 107          # a unix socket path, without its NUL
TMP_PREFIX = "/tmp/lrrt-sb."
ID_RE = re.compile(r"^[a-z0-9]{6,16}$")
SHELL_RE = re.compile(r"^[0-9a-f]{16,64}$")


def log(msg):
    path = os.environ.get("SANDBOX_REAP_LOG")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write("%.3f %s\n" % (time.time(), msg))
    except OSError:
        pass


def real(p):
    return os.path.realpath(p) if p else ""


def under(path, top):
    return path == top or path.startswith(top.rstrip("/") + "/")


def start_time(pid):
    """The process's start time in clock ticks (field 22 of stat), or None."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            s = f.read()
        return int(s[s.rfind(")") + 2:].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def is_quickshell(pid):
    """True when <pid> runs the quickshell binary, or when it cannot be told."""
    if pid <= 0:
        return False
    try:
        exe = os.readlink("/proc/%d/exe" % pid)
    except FileNotFoundError:
        return False
    except OSError:
        return os.path.exists("/proc/%d" % pid)
    return os.path.basename(exe.replace(" (deleted)", "")) in ("quickshell", "qs")


def lock_held(path):
    """The pid holding a write lock on <path>; 0 when free; -1 when unreadable."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return -1
    try:
        req = struct.pack("hhqqi4x", fcntl.F_WRLCK, os.SEEK_SET, 0, 0, 0)
        kind, _, _, _, pid = struct.unpack("hhqqi4x", fcntl.fcntl(fd, fcntl.F_GETLK, req))
        return 0 if kind == fcntl.F_UNLCK else max(pid, 1)
    except OSError:
        return -1
    finally:
        os.close(fd)


def read_lock(path):
    """(id, config path, shell id, pid) from an instance.lock, or None."""
    try:
        with open(path, "rb") as f:
            b = f.read(64 * 1024)

        def qstr(o):
            n = struct.unpack(">I", b[o:o + 4])[0]
            if n == 0xFFFFFFFF:
                return "", o + 4
            if n % 2 or o + 4 + n > len(b):
                raise ValueError("bad string")
            return b[o + 4:o + 4 + n].decode("utf-16-be"), o + 4 + n
        iid, o = qstr(0)
        cfg, o = qstr(o)
        shell, o = qstr(o)
        _app, o = qstr(o)
        o += 8 + 4 + 1          # launch time: julian day, msecs, time spec
        pid = struct.unpack(">i", b[o:o + 4])[0]
        return iid, cfg, shell, pid
    except (OSError, ValueError, struct.error, UnicodeDecodeError):
        return None


def instances(rt):
    """Every instance dir of <rt>: (id, dir, parsed lock or None)."""
    base = os.path.join(rt, "quickshell", "by-id")
    try:
        names = os.listdir(base)
    except OSError:
        return []
    out = []
    for name in names:
        d = os.path.join(base, name)
        if not ID_RE.match(name) or os.path.islink(d) or not os.path.isdir(d):
            continue
        out.append((name, d, read_lock(os.path.join(d, "instance.lock"))))
    return out


def alive(d, info):
    if info is None:
        return True                                   # cannot be read: leave it
    if lock_held(os.path.join(d, "instance.lock")) != 0:
        return True                                   # locked, or unreadable
    return is_quickshell(info[3])                     # not locked YET


def live_count(rt):
    return sum(1 for _, d, info in instances(rt) if alive(d, info))


def shared_dirs(home):
    """The directories that belong to everybody: the system's roots and temp areas, the session's
    runtime dir, the XDG bases. A scratch dir that IS one of them is shared; a dir BELOW one is
    some run's own, however shallow (/tmp/lares-ns): its instances are that run's."""
    dirs = ["/", "/tmp", "/var", "/var/tmp", "/dev", "/dev/shm", "/run", "/run/user", "/home", "/root",
            "/usr", "/opt", "/mnt", "/media", "/srv", "/etc", os.path.join("/run/user", str(os.getuid()))]
    dirs += [os.path.join(home, d) for d in (".cache", ".config", ".local", ".local/share", ".local/state")]
    for v in ("TMPDIR", "XDG_RUNTIME_DIR", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
        if os.environ.get(v):
            dirs.append(os.environ[v])
    return {real(d) for d in dirs}


def prefixes(sandbox, scratch, root):
    """(tops, protect): the trees whose dead instances are this run's, and the
    trees nobody's instances are ever removed from."""
    home = real(os.path.expanduser("~"))
    protect = [real(os.path.join(home, ".config", "quickshell"))]
    # (In a git WORKTREE `.git` is a file: exists, not isdir.)
    if root and os.path.exists(os.path.join(root, ".git")):
        protect.append(real(root))
    sb = real(sandbox)
    tops = [sb]
    sc = real(scratch)
    # SANDBOX defaults to $SCRATCH/lares-sandbox: when the run's scratch dir is
    # the sandbox's own PARENT it holds this run's other configs too (a probe's
    # snapshot beside the copy), at ANY depth -- SCRATCH=/tmp/lares-ns left 223
    # dead instances in the real runtime dir when two slashes were not enough.
    # What is not taken is a directory everybody uses (/tmp itself, the
    # home, an XDG base: shared_dirs) or one above a protected tree.
    if (sc and os.path.dirname(sb) == sc and sc not in shared_dirs(home)
            and not any(under(p, sc) for p in protect + [home])):
        tops.append(sc)
    return [t for t in tops if not any(under(t, p) or under(p, t) for p in protect)], protect


def sweep_rt(rt, tops, protect):
    """Remove the dead instances of <rt> whose config lies under <tops>."""
    base = os.path.join(rt, "quickshell")
    n = 0
    for iid, d, info in instances(rt):
        if info is None or info[0] != iid:
            continue
        cfg = real(info[1])
        if not any(under(cfg, t) for t in tops) or any(under(cfg, p) for p in protect):
            continue
        if alive(d, info):
            continue
        shutil.rmtree(d, ignore_errors=True)
        pidlink = os.path.join(base, "by-pid", str(info[3]))
        try:
            if os.path.islink(pidlink) and os.path.basename(os.readlink(pidlink)) == iid:
                os.unlink(pidlink)
        except OSError:
            pass
        if SHELL_RE.match(info[2] or ""):
            shelllink = os.path.join(base, "by-shell", info[2], iid)
            try:
                if os.path.islink(shelllink):
                    os.unlink(shelllink)
            except OSError:
                pass
        n += 1
        log("removed %s %s in %s" % (iid, cfg, rt))
    return n


def owner_alive(mark):
    try:
        with open(mark, encoding="utf-8") as f:
            m = json.load(f)
        st = start_time(int(m["owner"]))
        # A gone owner reads None -- and so does an owner that was already
        # gone when the dir was made: that one is not alive either.
        return st is not None and st == m["start"]
    except (OSError, ValueError, KeyError, TypeError):
        return None                                   # no readable mark: not ours


def remove_private(prt, wait_s=0.0):
    """Remove a private runtime dir this script made, once nothing lives in it.
    Waits up to <wait_s> for instances still running there; 0 = not at all.
    rmtree unlinks the links to the real runtime dir's entries; it never
    follows them."""
    if not os.path.isfile(os.path.join(prt, MARK)) or os.path.islink(prt):
        return False
    deadline = time.monotonic() + wait_s
    while live_count(prt):
        if time.monotonic() >= deadline:
            log("kept %s: an instance still runs in it" % prt)
            return False
        time.sleep(0.5)
    shutil.rmtree(prt, ignore_errors=True)
    log("removed private %s" % prt)
    return True


def private_home(sandbox):
    # BESIDE the sandbox, not in it: every call rsyncs the copy with --delete.
    return real(sandbox) + ".lrrt"


def in_home(sandbox, make):
    """make(home) inside the sandbox's private home, created for it. A
    concurrent tidy_home may remove the (empty) dir between the two steps:
    try again."""
    home = private_home(sandbox)
    for _ in range(5):
        try:
            os.makedirs(home, exist_ok=True)
            return make(home)
        except FileNotFoundError:
            continue
    return make(home)


def tidy_home(sandbox):
    """The private home goes once it is empty: nothing is left beside the
    sandbox by a run that is over."""
    try:
        os.rmdir(private_home(sandbox))
    except OSError:
        pass


def sweep_private(sandbox):
    """Private runtime dirs whose owner is gone (it was SIGKILLed, or its
    watcher was): beside this sandbox, and the short ones in /tmp."""
    cands = []
    home = private_home(sandbox)
    try:
        cands += [os.path.join(home, n) for n in os.listdir(home) if n.startswith("rt.")]
    except OSError:
        pass
    try:
        cands += [os.path.join("/tmp", n) for n in os.listdir("/tmp")
                  if ("/tmp/" + n).startswith(TMP_PREFIX)]
    except OSError:
        pass
    for prt in cands:
        mark = os.path.join(prt, MARK)
        if os.path.islink(prt) or not os.path.isdir(prt) or not os.path.isfile(mark):
            continue
        if owner_alive(mark) is False:
            remove_private(prt)


def cmd_sweep(a):
    tops, protect = prefixes(a.sandbox, a.scratch, a.root)
    for rt in a.rt:
        if rt:
            sweep_rt(rt, tops, protect)
    sweep_private(a.sandbox)
    tidy_home(a.sandbox)


def cmd_mkrt(a):
    home = private_home(a.sandbox)
    if len(home) + len("/rt.XXXXXXXX") + SOCK_ROOM <= SOCK_MAX:
        prt = in_home(a.sandbox, lambda h: tempfile.mkdtemp(prefix="rt.", dir=h))
    else:
        prt = tempfile.mkdtemp(prefix=os.path.basename(TMP_PREFIX), dir="/tmp")
    os.chmod(prt, 0o700)
    with open(os.path.join(prt, MARK), "w", encoding="utf-8") as f:
        json.dump({"owner": a.owner, "start": start_time(a.owner), "sandbox": real(a.sandbox)}, f)
    # Everything else a program finds in a runtime dir stays where it is: the
    # session bus, systemd's socket (systemd-run --user), hyprland, the Wayland
    # socket, and the mockups' own quickshell-* scratch dirs (test_notes /
    # test_launcher keep a copy there across runs). Quickshell's instance tree
    # is private, and so is the session's audio (pipewire, mpd) unless the
    # caller opted in: a link to a socket is a way to WRITE what it serves.
    want = {g for g in (a.link or "").replace(" ", "").split(",") if g}
    try:
        for name in os.listdir(a.parent):
            if name == "quickshell" or name == MARK:
                continue
            if any(g not in want and test(name) for g, test in LINK_GROUPS.items()):
                continue
            try:
                os.symlink(os.path.join(a.parent, name), os.path.join(prt, name))
            except OSError:
                pass
    except OSError:
        pass
    print(prt)


def wait_pid(pid):
    """Block until <pid> has exited (pidfd: exact, no polling, no reuse)."""
    if pid <= 1:
        return
    try:
        fd = os.pidfd_open(pid)
    except (ProcessLookupError, OSError):
        return
    try:
        p = select.poll()
        p.register(fd, select.POLLIN)
        while not p.poll(None):
            pass
    finally:
        os.close(fd)


def close_inherited():
    """A watcher lives as long as its caller: holding the caller's pipes would
    keep a reader waiting for EOF (a `$(...)`, a `| tee`) waiting for it."""
    try:
        fds = [int(n) for n in os.listdir("/proc/self/fd")]
    except OSError:
        return
    for fd in fds:
        if fd > 2:
            try:
                os.close(fd)
            except OSError:
                pass


def cmd_watch(a):
    close_inherited()
    tops, protect = prefixes(a.sandbox, a.scratch, a.root)
    lockf = None
    if a.caller and a.caller > 1 and start_time(a.caller) is not None:
        # One watcher per caller and sandbox: the first call from a runner
        # waits for it, the later ones do not pile up.
        name = "caller.%d.%d.lock" % (a.caller, start_time(a.caller))
        try:
            lockf = in_home(a.sandbox, lambda h: open(os.path.join(h, name), "a"))
            fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if lockf:
                lockf.close()
            lockf = None
    if a.cmd:
        wait_pid(a.cmd)
        for rt in a.rt:
            if rt:
                sweep_rt(rt, tops, protect)
        if a.private:
            remove_private(a.private, wait_s=3600)
    if lockf:
        wait_pid(a.caller)
        for rt in a.rt:
            if rt:
                sweep_rt(rt, tops, protect)
        sweep_private(a.sandbox)
        try:
            os.unlink(lockf.name)
        except OSError:
            pass
        lockf.close()
    tidy_home(a.sandbox)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="what", required=True)
    for name in ("sweep", "watch"):
        p = sub.add_parser(name)
        p.add_argument("--rt", action="append", default=[])
        p.add_argument("--sandbox", required=True)
        p.add_argument("--scratch", default="")
        p.add_argument("--root", default="")
        if name == "watch":
            p.add_argument("--cmd", type=int, default=0)
            p.add_argument("--caller", type=int, default=0)
            p.add_argument("--private", default="")
    p = sub.add_parser("mkrt")
    p.add_argument("--sandbox", required=True)
    p.add_argument("--parent", required=True)
    p.add_argument("--owner", type=int, required=True)
    p.add_argument("--link", default="")
    a = ap.parse_args()
    try:
        {"sweep": cmd_sweep, "mkrt": cmd_mkrt, "watch": cmd_watch}[a.what](a)
    except Exception as e:  # a sweep must never be what fails a gate
        log("%s failed: %s: %s" % (a.what, type(e).__name__, e))
        sys.exit(1 if a.what == "mkrt" else 0)
    finally:
        if a.what == "watch":
            log("watch end")


if __name__ == "__main__":
    main()
