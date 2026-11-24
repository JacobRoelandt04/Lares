"""Hyprland, without a fork: its two sockets.

Requests go to `.socket.sock` exactly as hyprctl sends them (`j/clients`, `/dispatch <lua>`, `/eval <lua>`), events
come from `.socket2.sock`. A watcher that asked through `hyprctl` would fork three times a look (the /proc law:
a poll runs inside one long-lived child).

Measured on Hyprland 0.57.2 (Lua config):
  - `dispatch` takes a Lua expression and answers `ok`; an error answers `error: ...`, a refusal `info: ...` /
    `warning: ...` -- all with a zero status from hyprctl, so the TEXT is the verdict.
  - `eval` runs a chunk and answers `ok`; it returns no value (state is read through the j/ requests).
"""
import json
import os
import select
import socket
import time


class HyprError(Exception):
    pass


def lua_str(s):
    """A Lua string literal."""
    out = ['"']
    for ch in str(s):
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\0":
            out.append("\\0")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua_table(d):
    """A flat Lua table of strings, numbers and booleans (an exec rule table)."""
    parts = []
    for k, v in d.items():
        if isinstance(v, bool):
            val = "true" if v else "false"
        elif isinstance(v, (int, float)):
            val = repr(v)
        else:
            val = lua_str(v)
        parts.append("%s = %s" % (k, val))
    return "{ " + ", ".join(parts) + " }"


class Hypr:
    def __init__(self, runtime_dir=None, sig=None):
        self.runtime_dir = runtime_dir or os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
        self.sig = sig or os.environ.get("HYPRLAND_INSTANCE_SIGNATURE") or ""
        self.dir = os.path.join(self.runtime_dir, "hypr", self.sig)

    def available(self):
        return bool(self.sig) and os.path.exists(os.path.join(self.dir, ".socket.sock"))

    # -- requests --------------------------------------------------------------------------------------------------
    def request(self, text, timeout=5.0):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        try:
            s.connect(os.path.join(self.dir, ".socket.sock"))
            s.sendall(text.encode())
            chunks = []
            while True:
                b = s.recv(65536)
                if not b:
                    break
                chunks.append(b)
        except OSError as e:
            raise HyprError("hyprland socket: %s" % e)
        finally:
            s.close()
        return b"".join(chunks).decode("utf-8", "replace")

    def json(self, what):
        text = self.request("j/" + what)
        try:
            return json.loads(text)
        except ValueError:
            raise HyprError("hyprland %s: not JSON: %s" % (what, text[:120]))

    def _lua(self, verb, lua):
        text = self.request("/%s %s" % (verb, lua)).strip()
        if text != "ok":
            raise HyprError("%s %s -> %s" % (verb, lua[:160], text[:200]))

    def dispatch(self, lua):
        """One dispatcher, e.g. `hl.dsp.window.close({ window = "address:0x.." })`."""
        self._lua("dispatch", lua)

    def eval(self, lua):
        self._lua("eval", lua)

    def try_dispatch(self, lua):
        try:
            self.dispatch(lua)
            return None
        except HyprError as e:
            return str(e)

    # -- facts -----------------------------------------------------------------------------------------------------
    def pid(self):
        """The compositor's pid: the first line of its lock file."""
        try:
            with open(os.path.join(self.dir, "hyprland.lock")) as f:
                return int(f.readline().strip())
        except (OSError, ValueError):
            return 0

    def locked(self):
        try:
            return bool(self.json("locked").get("locked"))
        except (HyprError, AttributeError):
            return False

    def focus_window(self, address):
        """Focus a window and put the pointer back where it was (focusing WARPS it): one Lua chunk, KeyRelease.qml's way."""
        self.eval("local p = hl.get_cursor_pos() hl.dispatch(hl.dsp.focus({ window = %s })) "
                  "if p then hl.dispatch(hl.dsp.cursor.move({ x = p.x, y = p.y })) end" % lua_str("address:" + address))

    def run_lua(self, chunk, runtime):
        """A Lua chunk of any length, run in one go (`dofile`): what must happen between two frames is one chunk."""
        os.makedirs(runtime, mode=0o700, exist_ok=True)
        path = os.path.join(runtime, "chunk.%d.lua" % os.getpid())
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(chunk)
        try:
            self.eval("dofile(%s)" % lua_str(path))
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def group_locks(self, runtime):
        """{address: locked} for every grouped window. `hyprctl clients` does not say whether a group is locked; the
        compositor's Lua does (`window.group.locked`), and writes it to a file this reads (eval returns no value)."""
        out = os.path.join(runtime, "groups.%d" % os.getpid())
        try:
            os.makedirs(runtime, mode=0o700, exist_ok=True)
            self.eval("local f = io.open(%s, \"w\"); if f then for _, w in ipairs(hl.get_windows()) do local g = w.group; "
                      "if g then f:write(tostring(w.address) .. \" \" .. (g.locked and \"1\" or \"0\") .. \"\\n\") end end; "
                      "f:close() end" % lua_str(out))
            with open(out, encoding="utf-8") as f:
                rows = [ln.split() for ln in f.read().splitlines()]
        except (HyprError, OSError):
            return {}
        finally:
            try:
                os.unlink(out)
            except OSError:
                pass
        locks = {}
        for r in rows:
            if len(r) == 2:
                addr = r[0] if r[0].startswith("0x") else "0x" + r[0]
                locks[addr] = r[1] == "1"
        return locks

    def safe_mode(self, proc_root="/proc"):
        """Hyprland restarted after a crash runs with --safe-mode (start-hyprland); nothing else says so."""
        pid = self.pid()
        if not pid:
            return False
        try:
            with open(os.path.join(proc_root, str(pid), "cmdline"), "rb") as f:
                return b"--safe-mode" in f.read().split(b"\0")
        except OSError:
            return False

    # -- events ----------------------------------------------------------------------------------------------------
    def events(self):
        return Events(os.path.join(self.dir, ".socket2.sock"))


class Events:
    """socket2 as lines. `wait(timeout)` returns the lines that arrived (maybe none), or None once the compositor is gone."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(path)
        except OSError as e:
            raise HyprError("hyprland event socket: %s" % e)
        self.sock.setblocking(False)
        self.buf = b""
        self.closed = False

    def fileno(self):
        return self.sock.fileno()

    def wait(self, timeout):
        if self.closed:
            return None
        end = time.monotonic() + max(0.0, timeout)
        while True:
            left = end - time.monotonic()
            try:
                r, _, _ = select.select([self.sock], [], [], max(0.0, left))
            except InterruptedError:
                continue
            if not r:
                return []
            try:
                b = self.sock.recv(65536)
            except BlockingIOError:
                continue
            except OSError:
                b = b""
            if not b:
                self.closed = True
                return None
            self.buf += b
            if b"\n" in self.buf:
                raw, self.buf = self.buf.rsplit(b"\n", 1)
                return [ln.decode("utf-8", "replace") for ln in raw.split(b"\n") if ln]

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def split_event(line):
    """`name>>data` -> (name, data)."""
    name, sep, data = line.partition(">>")
    return (name, data) if sep else (line, "")
