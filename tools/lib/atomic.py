"""Atomic files and flocks, shared by the tools (wiki, clipboard).

Every writer in a tool writes `<file>.part`, fsyncs it and `os.replace`s it over the target, then
fsyncs the directory: a reader (the QML service watches these files) sees the old file or the new one,
and a shell reload or kill -9 mid-write leaves at most a stray `.part`.
"""
import fcntl
import json
import os


class Busy(Exception):
    """A non-blocking Lock found the file already locked."""


def _fsync_dir(d):
    try:
        fd = os.open(d, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def write_bytes(path, data):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    part = path + ".part"
    fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        view = memoryview(data)
        while len(view):
            view = view[os.write(fd, view):]
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        try:
            os.unlink(part)
        except OSError:
            pass
        raise
    os.close(fd)
    try:
        os.replace(part, path)
    except BaseException:
        try:
            os.unlink(part)
        except OSError:
            pass
        raise
    _fsync_dir(d)


def write_json(path, obj, indent=1, scrub=None):
    """JSON (UTF-8, not ASCII-escaped) through write_bytes. `scrub`, when given, is applied to the text
    first (the wiki passes its env.scrub so a file never holds the Jev key, whatever a caller put in
    the object)."""
    text = json.dumps(obj, ensure_ascii=False, indent=indent)
    if scrub is not None:
        text = scrub(text)
    write_bytes(path, (text + "\n").encode("utf-8"))


def read_json(path, default=None):
    """The parsed file, or `default` when it is missing or not valid JSON."""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


class Lock:
    """flock(2) as a context manager: `with Lock(path): ...`. Blocking by default; Lock(path,
    blocking=False) raises Busy at once when somebody holds it. The holder's pid is written into the
    file for whoever wonders. flock belongs to the open file description, so two Locks on one path
    exclude each other inside a single process too."""

    def __init__(self, path, blocking=True):
        self.path = path
        self.blocking = blocking
        self.fd = None

    def acquire(self):
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | (0 if self.blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            os.close(fd)
            raise Busy(self.path) from None
        except BaseException:
            os.close(fd)
            raise
        try:
            os.ftruncate(fd, 0)
            os.write(fd, str(os.getpid()).encode())
        except OSError:
            pass
        self.fd = fd
        return self

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *exc):
        self.release()
