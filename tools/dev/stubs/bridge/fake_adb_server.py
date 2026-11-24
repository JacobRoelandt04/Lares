#!/usr/bin/env python3
"""A stand-in for the adb server's smart socket (127.0.0.1:<port>), for tools/dev/bridge_tool_probe.sh.

    BRIDGE_WORLD=<file> fake_adb_server.py <port>      prints `adb-server ready <port>` once it listens

Answers host:version, host:devices-l and host:track-devices-l (a frame now and one at every change of the device list). The list
is the world file's adb.devices (lines in the `adb devices -l` format); it is re-read every 100 ms. Never talks to a real adb.
"""
import json
import os
import socketserver
import sys
import threading
import time

WORLD = os.environ.get("BRIDGE_WORLD", "")
if not WORLD:
    sys.exit("fake_adb_server.py: BRIDGE_WORLD is not set; refusing to run")


def devices():
    try:
        with open(WORLD) as f:
            lines = json.load(f).get("adb", {}).get("devices", [])
    except (OSError, ValueError):
        lines = []
    return "".join(l + "\n" for l in lines)


def frame(s):
    b = s.encode()
    return b"%04x" % len(b) + b


class H(socketserver.BaseRequestHandler):
    def handle(self):
        s = self.request
        head = s.recv(4)
        if len(head) < 4:
            return
        req = s.recv(int(head, 16)).decode()
        if req == "host:version":
            s.sendall(b"OKAY" + frame("0029"))
        elif req == "host:devices-l":
            s.sendall(b"OKAY" + frame(devices()))
        elif req == "host:track-devices-l":
            s.sendall(b"OKAY")
            last = None
            try:
                while True:
                    cur = devices()
                    if cur != last:
                        s.sendall(frame(cur))
                        last = cur
                    time.sleep(0.1)
            except OSError:
                return
        else:
            s.sendall(b"FAIL" + frame("unknown host service"))


class S(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    srv = S(("127.0.0.1", int(sys.argv[1])), H)
    print("adb-server ready %s" % sys.argv[1], flush=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
