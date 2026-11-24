"""Jobs: a long run (scrcpy, a mount, an adb push) as a record, a wrapper and a scope.

A job is started as `systemd-run --user --scope ... -- setsid -f <tool> _run <id> -- <argv>`. The wrapper (`_run`) is the child's parent,
writes jobs/<id>.json atomically at every phase change (figures at most every 500 ms) and forwards TERM. The watcher holds a pidfd
on each live wrapper: one that died without writing done / failed reads `failed` ("ended without a word"). A job outlives the popup,
the service and the shell: nothing here belongs to the process that asked for it.
"""
import collections
import ctypes
import fcntl
import os
import pty
import selectors
import signal
import subprocess
import tempfile
import time

from . import argv as argvlib
from . import parse
from . import trace
from . import state as st

PREFIX = {"mirror": "m", "mount": "f", "send": "s"}
PUBLIC = ("id", "kind", "device", "mode", "via", "phase", "started", "ended", "code", "reason",
          "files", "file", "name", "done", "total", "rate")
ENDED = ("done", "failed")
START_GRACE_S = 10.0
FIGURE_EVERY_S = 0.5
RUNNING_AFTER_S = 2.0
READY = ("INFO: Renderer:", "INFO: Texture:", "[server] INFO: Device:", "INFO: Device:")


def blank(kind, device, mode, via, now, **extra):
    r = {"id": "", "kind": kind, "device": device, "mode": mode, "via": via, "phase": "starting", "started": int(now), "ended": None,
         "code": None, "reason": "", "files": 0, "file": 0, "name": "", "done": 0, "total": 0, "rate": 0}
    r.update(extra)
    return r


def public(rec):
    return {k: rec.get(k) for k in PUBLIC}


def next_id(paths, kind):
    paths.ensure()
    fd = os.open(paths.seq, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        raw = os.read(fd, 32).decode() or "0"
        n = (int(raw) if raw.isdigit() else 0) + 1
        os.lseek(fd, 0, 0)
        os.ftruncate(fd, 0)
        os.write(fd, str(n).encode())
        return "%s-%d" % (PREFIX.get(kind, "j"), n)
    finally:
        os.close(fd)


def path_of(paths, job_id):
    return os.path.join(paths.jobs, job_id + ".json")


def read(paths, job_id):
    r = st.read_json(path_of(paths, job_id), {})
    return r if r.get("id") == job_id else None


def read_all(paths):
    try:
        names = sorted(os.listdir(paths.jobs))
    except OSError:
        return []
    out = []
    for n in names:
        if n.endswith(".json"):
            r = read(paths, n[:-5])
            if r:
                out.append(r)
    return out


def write(paths, rec):
    st.write_private(path_of(paths, rec["id"]), rec)


def remove(paths, job_id):
    try:
        os.unlink(path_of(paths, job_id))
    except OSError:
        pass


def proc_start(pid):
    """Field 22 of /proc/<pid>/stat (start time in ticks): a pid is the same process when this agrees."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return int(f.read().rpartition(")")[2].split()[19])
    except (OSError, ValueError, IndexError):
        return 0


def wrapper_alive(rec):
    pid = rec.get("pid") or 0
    return bool(pid) and proc_start(pid) != 0 and proc_start(pid) == rec.get("pidStart")


def end_dead(paths, rec, now, reason="ended without a word"):
    """Marks a record whose wrapper is gone and which never said done / failed."""
    if rec.get("phase") in ENDED:
        return rec
    rec = dict(rec, phase="failed", ended=int(now), reason=reason)
    write(paths, rec)
    return rec


def sweep(paths, now):
    """At the watcher's start: a record with no verdict whose wrapper is gone (or never came) is failed."""
    for r in read_all(paths):
        if r["phase"] in ENDED:
            continue
        if r.get("pid"):
            if not wrapper_alive(r):
                end_dead(paths, r, now)
        elif now - r.get("started", now) > START_GRACE_S:
            end_dead(paths, r, now, "did not start")


def start(paths, rec, argv, tool, now):
    """Writes the record and starts the wrapper in a scope. -> (ok, error)."""
    rec["id"] = rec["id"] or next_id(paths, rec["kind"])
    write(paths, rec)
    cmd = argvlib.systemd_run(rec["kind"], rec["id"], tool, argv)
    # stderr goes to a file, not a pipe: the wrapper inherits it and outlives systemd-run, so a pipe would never reach EOF
    with tempfile.TemporaryFile() as err:
        try:
            r = subprocess.run(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as e:
            end_dead(paths, rec, now, "could not start the job: %s" % e)
            return False, str(e)
        err.seek(0)
        said = err.read().decode("utf-8", "replace")
        trace.write(paths, "exec", argv=cmd, rc=r.returncode, tail=said[-600:], job=rec["id"])
        if r.returncode != 0:
            why = parse.last_error_line(said) or "systemd-run failed"
            end_dead(paths, rec, now, why)
            return False, why
    return True, ""


def wait_phase(paths, job_id, until, timeout):
    """Polls a record (a one-shot may; the watcher never) until its phase is in `until`; -> the record or the last read."""
    end = time.time() + timeout
    r = read(paths, job_id)
    while time.time() < end:
        r = read(paths, job_id)
        if r and r["phase"] in until:
            return r
        time.sleep(0.05)
    return r


def ack(paths, job_id):
    """-> "gone" | "live" | "none"."""
    r = read(paths, job_id)
    if not r:
        return "none"
    if r["phase"] not in ENDED:
        return "live"
    remove(paths, job_id)
    return "gone"


def stop(paths, job_id, run=subprocess.run, wait_s=3.0):
    """TERM to the wrapper; the scope as the last resort. -> True when the job ended."""
    r = read(paths, job_id)
    if not r:
        return False
    if r["phase"] in ENDED:
        return True
    if wrapper_alive(r):
        try:
            os.kill(r["pid"], signal.SIGTERM)
        except OSError:
            pass
        r = wait_phase(paths, job_id, ENDED, wait_s)
        if r and r["phase"] in ENDED:
            return True
    unit = "lares-bridge-%s-%s.scope" % (r["kind"], job_id)
    try:
        run(["systemctl", "--user", "stop", unit], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        pass
    r = wait_phase(paths, job_id, ENDED, 2.0)
    if r and r["phase"] not in ENDED and wrapper_alive(r):
        try:
            os.kill(r["pid"], signal.SIGKILL)
        except OSError:
            pass
    if r and r["phase"] not in ENDED:
        end_dead(paths, r, time.time(), "stopped")
    return True


# ---- why a try failed ---------------------------------------------------------------------------------------------------
def load_tries(paths):
    return st.read_json(paths.tries, {})


def record_try(paths, key, action, reason, hint, now):
    t = load_tries(paths)
    t.setdefault(key, {})[action] = {"reason": reason, "hint": hint, "at": int(now)}
    st.write_private(paths.tries, t)


def clear_try(paths, key, action):
    t = load_tries(paths)
    if t.get(key, {}).pop(action, None) is not None:
        st.write_private(paths.tries, t)


def action_of(rec):
    if rec["kind"] == "mirror":
        return "mirror"
    if rec["kind"] == "mount":
        return "mountUsb"
    return ""


# ---- the wrapper --------------------------------------------------------------------------------------------------------
class Wrapper:
    def __init__(self, paths, job_id, argv):
        self.paths = paths
        self.argv = argv
        self.rec = read(paths, job_id) or blank("mirror", "", "", "", time.time(), id=job_id)
        self.stopping = False
        self.child = None
        self.tail = collections.deque(maxlen=30)
        self.dirty = False
        self.last_write = 0.0
        self.sizes = [(i["remote"], i["size"]) for i in self.rec.get("items", [])]
        self.rate_at, self.rate_done = time.time(), 0
        self.log = None

    def flush(self, force=False):
        now = time.time()
        if self.dirty and (force or now - self.last_write >= FIGURE_EVERY_S):
            write(self.paths, self.rec)
            self.last_write = now
            self.dirty = False

    def phase(self, phase, **kw):
        self.rec.update(phase=phase, **kw)
        self.dirty = True
        self.flush(force=True)

    def on_term(self, signum, frame):
        self.stopping = True
        if self.child and self.child.poll() is None:
            try:
                self.child.send_signal(signal.SIGTERM)
            except OSError:
                pass

    def line(self, text):
        t = text.strip()
        if not t:
            return
        self.tail.append(t)
        if self.rec["kind"] == "send":
            p = parse.parse_push_line(t)
            if p:
                self.figures(p)
        elif self.rec["phase"] == "starting" and t.startswith(READY):
            self.phase("running")

    def figures(self, p):
        r = self.rec
        now = time.time()
        if "summary" in p:
            r["done"] = r["total"] or p["summary"]["bytes"]
            if p["summary"]["rate"]:
                r["rate"] = p["summary"]["rate"]
            self.dirty = True
            return
        idx = next((i for i, (remote, _) in enumerate(self.sizes) if remote == p["name"] or remote.endswith("/" + os.path.basename(p["name"]))), None)
        if idx is None:
            return
        before = sum(s for _, s in self.sizes[:idx])
        r["file"] = idx + 1
        r["name"] = os.path.basename(self.sizes[idx][0])
        r["done"] = int(before + self.sizes[idx][1] * p["percent"] / 100.0)
        dt = now - self.rate_at
        if dt >= 0.5:
            inst = max(0, (r["done"] - self.rate_done) / dt)
            r["rate"] = int(inst if not r["rate"] else 0.6 * r["rate"] + 0.4 * inst)
            self.rate_at, self.rate_done = now, r["done"]
        self.dirty = True

    def run(self):
        rec = self.rec
        rec.update(pid=os.getpid(), pidStart=proc_start(os.getpid()), phase="starting")
        write(self.paths, rec)
        signal.signal(signal.SIGTERM, self.on_term)
        signal.signal(signal.SIGINT, self.on_term)
        master = None
        try:
            if rec["kind"] == "send":
                master, slave = pty.openpty()
                self.child = subprocess.Popen(self.argv, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave,
                                              close_fds=True, cwd=self.paths.home, preexec_fn=_die_with_parent)
                os.close(slave)
                fd = master
            else:
                self.child = subprocess.Popen(self.argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                              stderr=subprocess.STDOUT, close_fds=True, cwd=self.paths.home,
                                              preexec_fn=_die_with_parent)
                fd = self.child.stdout.fileno()
        except OSError as e:
            self.phase("failed", ended=int(time.time()), code=None, reason="could not run %s: %s" % (self.argv[0], e))
            self.after_failure()
            return 1
        rec["childPid"] = self.child.pid
        write(self.paths, rec)
        self.log = trace.job_log(self.paths, rec["id"])
        self._log(("$ %s\n" % " ".join(self.argv)).encode())
        sel = selectors.DefaultSelector()
        sel.register(fd, selectors.EVENT_READ)
        buf = ""
        began = time.time()
        killed_at = 0.0
        while True:
            for _ in sel.select(0.25):
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    data = b""
                if not data:
                    sel.unregister(fd)
                    break
                self._log(data)
                lines, buf = parse.split_redraws(buf + data.decode("utf-8", "replace"))
                for ln in lines:
                    self.line(ln)
            if not sel.get_map():
                break
            if self.stopping and not killed_at:
                killed_at = time.time()
            if killed_at and time.time() - killed_at > 3.0 and self.child.poll() is None:
                self.child.kill()
            if rec["phase"] == "starting" and time.time() - began >= RUNNING_AFTER_S and self.child.poll() is None:
                self.phase("running")
            self.flush()
        if buf.strip():
            self.line(buf)
        code = self.child.wait()
        if master is not None:
            os.close(master)
        self._log(("\n[exit %d%s]\n" % (code, ", stopped" if self.stopping else "")).encode())
        if self.log:
            self.log.close()
        if self.stopping or code == 0:
            self.phase("done", ended=int(time.time()), code=0 if self.stopping else code)
            return 0
        reason = parse.last_error_line("\n".join(self.tail)) or "exited with status %d" % (code if code >= 0 else 128 - code)
        self.phase("failed", ended=int(time.time()), code=code if code >= 0 else 128 - code, reason=reason)
        self.after_failure()
        return 1

    def _log(self, data):
        if self.log:
            try:
                self.log.write(data)
            except OSError:
                self.log = None

    def after_failure(self):
        a = action_of(self.rec)
        if a and self.rec.get("device"):
            record_try(self.paths, self.rec["device"], a, self.rec["reason"], "", time.time())


def _die_with_parent():
    """The child ends with its wrapper (a wrapper killed with -9 must not leave an untracked scrcpy behind)."""
    try:
        ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, int(signal.SIGTERM))
    except OSError:
        pass


def run_wrapper(paths, job_id, argv):
    return Wrapper(paths, job_id, argv).run()


# ---- the watcher's side: a pidfd per live wrapper ------------------------------------------------------------------------
def open_pidfd(pid):
    try:
        return os.pidfd_open(pid)
    except (OSError, AttributeError):
        return -1
