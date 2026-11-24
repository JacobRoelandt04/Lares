"""Mounts: what /proc/self/mountinfo says, which are stale (ENOTCONN on stat) and which this tool made.

A change of the mount table is heard on /proc/self/mountinfo itself (POLLPRI); a test points LARES_BRIDGE_MOUNTINFO at a plain file,
which a Gio file monitor follows instead.
"""
import errno
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import parse  # noqa: E402
from . import state as st  # noqa: E402


def read(path="/proc/self/mountinfo"):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return parse.parse_mountinfo(f.read())
    except OSError:
        return []


def is_stale(point, forced=(), stat=os.stat):
    """A FUSE mount whose server died answers ENOTCONN (or EIO) to stat. `forced` is a test's list of points that do."""
    if point in forced:
        return True
    try:
        stat(point)
    except OSError as e:
        return e.errno in (errno.ENOTCONN, errno.EIO, errno.ESHUTDOWN)
    return False


def at(mounts, point):
    return next((m for m in mounts if m["point"] == point), None)


def state_of(mounts, point, stale_points, job_running):
    """unmounted | mounting | mounted | stale for one mount point."""
    m = at(mounts, point)
    if m:
        return "stale" if point in stale_points else "mounted"
    return "mounting" if job_running else "unmounted"


def load_mine(paths):
    return st.read_json(paths.mine, {})


def add_mine(paths, point, device, now):
    m = load_mine(paths)
    m[point] = {"device": device, "at": int(now)}
    st.write_private(paths.mine, m)


def drop_mine(paths, point):
    m = load_mine(paths)
    if point in m:
        del m[point]
        st.write_private(paths.mine, m)


class Watcher:
    def __init__(self, path, on_change):
        self.path = path
        self.on_change = on_change
        self.fd = -1
        self.source = 0
        self.monitor = None

    def start(self):
        if self.path != "/proc/self/mountinfo":
            self.monitor = Gio.File.new_for_path(self.path).monitor_file(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect("changed", lambda *a: self.on_change())
            return
        self.fd = os.open(self.path, os.O_RDONLY)
        os.read(self.fd, 1 << 20)
        self.source = GLib.unix_fd_add_full(GLib.PRIORITY_DEFAULT, self.fd, GLib.IOCondition.PRI | GLib.IOCondition.ERR, self._ready)

    def _ready(self, fd, cond):
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            os.read(fd, 1 << 20)
        except OSError:
            pass
        self.on_change()
        return True

    def stop(self):
        if self.source:
            GLib.source_remove(self.source)
        if self.fd >= 0:
            os.close(self.fd)
        if self.monitor:
            self.monitor.cancel()
        self.source, self.fd, self.monitor = 0, -1, None
