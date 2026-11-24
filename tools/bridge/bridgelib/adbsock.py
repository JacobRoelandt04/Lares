"""adb's smart socket (127.0.0.1:5037, or ANDROID_ADB_SERVER_PORT): a request is 4 hex digits of length + the text, the answer
`OKAY` and then, for track-devices-l, frames of 4 hex digits + payload in the `devices -l` format. Nothing here starts a server.
"""
import os
import socket

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

from . import parse  # noqa: E402


def server_port(env=None):
    env = os.environ if env is None else env
    try:
        return int(env.get("ANDROID_ADB_SERVER_PORT") or 5037)
    except ValueError:
        return 5037


def query_sync(service, port=None, timeout=2.0):
    """One request/answer on a fresh connection -> (text | None, error). None / "adb server is not running" when it is down."""
    port = port or server_port()
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    except OSError:
        return None, "adb server is not running"
    try:
        s.settimeout(timeout)
        s.sendall(parse.frame(service))
        fp = parse.FrameParser()
        out = []
        while not fp.failed:
            data = s.recv(65536)
            if not data:
                break
            out += fp.feed(data)
            if fp.ok and out:
                break
        if fp.failed:
            return None, fp.failed
        return ("".join(out) if out else ""), ""
    except OSError as e:
        return None, str(e)
    finally:
        s.close()


def devices_sync(port=None):
    text, err = query_sync("host:devices-l", port)
    return (parse.parse_devices_l(text) if text is not None else None), err


class Tracker:
    """`host:track-devices-l`, on the GLib loop. on_devices(list) at every frame; on_down() when the server is not there or goes.
    It never retries by itself (no timer at rest): the owner calls kick() when something else changed."""

    def __init__(self, port, on_devices, on_down):
        self.port = port
        self.on_devices = on_devices
        self.on_down = on_down
        self.up = False
        self.busy = False
        self.conn = None
        self.parser = None
        self.gen = 0

    def kick(self):
        if self.up or self.busy:
            return
        self.busy = True
        self.gen += 1
        gen = self.gen
        addr = Gio.InetSocketAddress.new_from_string("127.0.0.1", self.port)
        Gio.SocketClient().connect_async(addr, None, lambda c, r: self._connected(gen, c, r))

    def _connected(self, gen, client, res):
        if gen != self.gen:
            return
        try:
            self.conn = client.connect_finish(res)
            self.conn.get_output_stream().write_all(parse.frame("host:track-devices-l"), None)
        except GLib.Error:
            self._down()
            return
        self.parser = parse.FrameParser()
        self._read(gen)

    def _read(self, gen):
        self.conn.get_input_stream().read_bytes_async(4096, GLib.PRIORITY_DEFAULT, None, lambda s, r: self._got(gen, s, r))

    def _got(self, gen, stream, res):
        if gen != self.gen:
            return
        try:
            data = stream.read_bytes_finish(res).get_data()
        except GLib.Error:
            data = b""
        if not data:
            self._down()
            return
        frames = self.parser.feed(data)
        if self.parser.failed:
            self._down()
            return
        if self.parser.ok and not self.up:
            self.up = True
            self.busy = False
        for f in frames:
            self.on_devices(parse.parse_devices_l(f))
        self._read(gen)

    def _down(self):
        was = self.up or self.busy
        self.up = False
        self.busy = False
        if self.conn is not None:
            try:
                self.conn.close(None)
            except GLib.Error:
                pass
            self.conn = None
        if was:
            self.on_down()

    def stop(self):
        self.gen += 1
        self.up = False
        self.busy = False
        if self.conn is not None:
            try:
                self.conn.close(None)
            except GLib.Error:
                pass
            self.conn = None
