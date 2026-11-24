"""The adb server: started only for a need, stopped after adb.idleKillS of no need, and only when this tool started it.

The marker `adb-started` (runtime dir) is present while the running server is one the tool started; its `at` is the last need.
A detached `_adbidle` process sleeps until `at + idleKillS` (no polling) and stops the server then, unless a job that rides on adb
is still alive (that counts as a need).
"""
import fcntl
import os
import subprocess
import time

from . import adbsock, jobs, parse, trace
from . import state as st


def marker(paths):
    """{at: <s>} while the server is ours, else None."""
    if not os.path.exists(paths.adb_started):
        return None
    return st.read_json(paths.adb_started, {}) or {"at": 0}


def _run(args, timeout):
    t0 = time.time()
    try:
        r = subprocess.run(args, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout)
        rc, out = r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        rc, out = 124, "timed out"
    except OSError as e:
        rc, out = 127, str(e)
    trace.ran(args, rc, t0, out)
    return rc, out


def need(paths, cfg, tool, now=None):
    """Makes sure a server answers -> (up, error). Marks it ours when this call started it; refreshes the mark when it already is."""
    now = now or time.time()
    port = adbsock.server_port()
    text, _ = adbsock.query_sync("host:version", port, 1.5)
    ours = marker(paths)
    if text is not None:
        if ours is not None:
            _touch(paths, cfg, tool, now)
        return True, ""
    paths.ensure()
    code, out = _run(["adb", "start-server"], 15)
    text, _ = adbsock.query_sync("host:version", port, 1.5)
    if text is None:
        return False, parse.last_error_line(out) or "adb server did not start"
    st.write_private(paths.adb_started, {"at": int(now)})
    _touch(paths, cfg, tool, now, fresh=True)
    return True, ""


def _touch(paths, cfg, tool, now, fresh=False):
    if not fresh:
        st.write_private(paths.adb_started, {"at": int(now)})
    try:
        subprocess.Popen([tool, "_adbidle"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True, close_fds=True)
    except OSError:
        pass


def stop_if_ours(paths):
    if marker(paths) is None:
        return False
    _run(["adb", "kill-server"], 10)
    try:
        os.unlink(paths.adb_started)
    except OSError:
        pass
    return True


WAKE_S = 5.0


def idle_reaper(paths, cfg=None, sleep=time.sleep, clock=time.time):
    """The body of `_adbidle`: one at a time (flock), asleep until the mark's due time (at most WAKE_S at a stretch, so a changed
    config or a fresh need is seen), then the stop. It is a helper that lives only while a server of ours does, not the watcher."""
    paths.ensure()
    fd = os.open(paths.idle_lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return "another"
    try:
        while True:
            m = marker(paths)
            if m is None:
                return "gone"
            conf = st.load_config(paths)[0] if cfg is None else cfg
            due = m.get("at", 0) + conf["adb"]["idleKillS"]
            now = clock()
            if now < due:
                sleep(min(WAKE_S, max(0.0, due - now) + 0.05))
                continue
            if any(r["phase"] not in jobs.ENDED and r["via"] in ("usb", "tcp", "adb") for r in jobs.read_all(paths)):
                st.write_private(paths.adb_started, {"at": int(now)})
                continue
            stop_if_ours(paths)
            return "stopped"
    finally:
        os.close(fd)
