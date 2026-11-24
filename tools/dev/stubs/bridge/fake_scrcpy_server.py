#!/usr/bin/env python3
"""fake_scrcpy_server.py -- a fake phone: scrcpy 5.0.1's server wire protocol, with real H.264 (ffmpeg/x264) and AAC (ffmpeg).

  fake_scrcpy_server.py --port P --log FILE [--audio] [--size WxH] [--fps N] [--control-dir DIR] [--server-args "k=v k=v ..."]

Listens on 127.0.0.1:P (what `adb forward` would reach), speaks tunnel_forward (dummy byte on the first connection, then the device name,
the codec id and the session packet on the video socket), streams a 30 fps picture whose top band is the frame number in 16 binary cells
(white = 1, LSB left) over moving stripes, and logs to FILE:
  S <n> <unix time>            frame n written to the socket
  C <unix time> <hex>          one control message received, whole
  E <unix time> <text>         an event (start, reset, rotate, audio, closed)
  P <unix time> <json>         the server's key=value parameters (--server-args: what app_process was given after the version), as an
                               object; `new_display=WxH[/dpi]` makes the stream's size WxH (the virtual display's own), as the real server
                               does; every other parameter is only recorded
RESET_VIDEO (control type 17) restarts the encoder (a new config packet, a key frame first); a key frame every 240 frames (8 s) otherwise, like a phone, as the real server does. A file
<control-dir>/rotate swaps width and height (a new session packet, a new config, a key frame); it is deleted when done.
RESIZE_DISPLAY (control type 21, >BHH: width, height) re-encodes at the new size (rounded down to even) with a new session packet and a new config, as a
rotation does -- only when the server was started with flex_display=true (`E resize WxH`); otherwise it is logged and ignored (`E resize ignored`).
A file <control-dir>/drop ends the phone as an adbd restart would: the file is deleted, <control-dir>/dropped is written (the stub adb reads its mtime:
`adb devices` says offline for 300 ms), `E drop` is logged, every socket is closed and the process exits 255.
A file <control-dir>/pause stops the picture for as long as it exists (no video packet is sent: a phone whose display is dark; the real server repeats
the last frame ~10x/s on a live one, so silence means no picture).
"""
import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time

CTL_LEN = {0: 14, 2: 32, 3: 21, 4: 2, 10: 2, 17: 1, 21: 5}
P = struct.pack


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise EOFError
        b += c
    return b


def nals(data):
    pos, i = [], 0
    while True:
        i = data.find(b"\x00\x00\x01", i)
        if i < 0:
            break
        pos.append(i + 3)
        i += 3
    out = []
    for k, s in enumerate(pos):
        e = pos[k + 1] - 3 if k + 1 < len(pos) else len(data)
        out.append(data[s:e].rstrip(b"\x00"))
    return out


class Fake:
    def __init__(self, a):
        self.a = a
        self.w, self.h = [int(x) for x in a.size.split("x")]
        self.params = dict(kv.split("=", 1) for kv in a.server_args.split() if "=" in kv)
        nd = self.params.get("new_display", "")
        if nd and "x" in nd.split("/")[0]:
            self.w, self.h = [int(x) for x in nd.split("/")[0].split("x")]
        self.lock = threading.Lock()
        self.logf = open(a.log, "a", buffering=1)
        self.n = 0                  # frame counter, never restarts
        self.gen = 0                # encoder generation
        self.restart = threading.Event()
        self.closed = False

    def log(self, kind, text):
        with self.lock:
            self.logf.write(("S %d %.6f\n" % (text, time.time())) if kind == "S" else ("%s %.6f %s\n" % (kind, time.time(), text)))

    def frame(self, n, w, h):
        cell = w // 16
        band = bytearray()
        for i in range(16):
            band += bytes([235 if (n >> i) & 1 else 16]) * cell
        band = bytes(band).ljust(w, b"\x10")
        rows = [band] * 24
        for y in range(24, h):
            rows.append(bytes([90 if ((y + n * 3) // 16) % 2 == 0 else 170]) * w)
        return b"".join(rows)

    # ---- video ----
    def video_stream(self, vs):
        first = True
        while not self.closed:
            w, h = self.w, self.h
            if not first:
                vs.sendall(bytes([0x80, 0, 0, 0]) + P(">II", w, h))
            first = False
            self.restart.clear()
            self.gen += 1
            gen = self.gen
            enc = subprocess.Popen(
                ["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", "gray", "-s", "%dx%d" % (w, h), "-r", "30", "-i", "-",
                 "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-pix_fmt", "yuv420p", "-bf", "0",
                 "-x264-params", "aud=1:keyint=240:repeat-headers=1", "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            c0 = self.n
            stop = threading.Event()

            def feed(enc=enc, stop=stop, c0=c0, w=w, h=h):     # bound now: a restart must not hand this feeder the next encoder
                t0 = time.time()
                k = 0
                try:
                    while not stop.is_set() and not self.closed:
                        enc.stdin.write(self.frame(c0 + k, w, h))
                        enc.stdin.flush()
                        k += 1
                        d = t0 + k / float(self.a.fps) - time.time()
                        if d > 0:
                            time.sleep(d)
                except (OSError, ValueError):
                    pass
            threading.Thread(target=feed, daemon=True).start()
            buf = b""
            k = 0
            self.log("E", "encoder %dx%d from frame %d" % (w, h, c0))
            try:
                while not self.restart.is_set() and not self.closed:
                    chunk = os.read(enc.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    buf += chunk
                    while True:
                        i = buf.find(b"\x00\x00\x00\x01\x09", 5)
                        if i < 0:
                            break
                        au, buf = buf[:i], buf[i:]
                        k = self.send_au(vs, au, c0, k, w, h)
                        if self.restart.is_set():
                            break
            finally:
                stop.set()
                enc.kill()
                enc.wait()

    def send_au(self, vs, au, c0, k, w, h):
        ns = nals(au)
        types = [x[0] & 0x1F for x in ns]
        n = c0 + k
        if k == 0 and 7 in types:
            cfg = b"".join(b"\x00\x00\x00\x01" + x for x in ns if x[0] & 0x1F in (7, 8))
            vs.sendall(P(">QI", 1 << 62, len(cfg)) + cfg)
        body = b"".join(b"\x00\x00\x00\x01" + x for x in ns if x[0] & 0x1F not in (7, 8, 9))
        key = 5 in types
        pts = n * 33333
        pf = os.path.join(self.a.control_dir, "pause") if self.a.control_dir else ""
        if pf and os.path.exists(pf):     # a dark display: nothing is sent (the encoder's clock goes on)
            self.n = n + 1
            return k + 1
        with self.lock:
            vs.sendall(P(">QI", (pts & ((1 << 61) - 1)) | ((1 << 61) if key else 0), len(body)) + body)
        self.n = n + 1
        self.log("S", n)
        return k + 1

    # ---- audio ----
    def audio_stream(self, s):
        s.sendall(P(">I", 0x00616163))
        enc = subprocess.Popen(["ffmpeg", "-v", "error", "-re", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-ac", "2",
                                "-c:a", "aac", "-f", "adts", "-"], stdout=subprocess.PIPE)
        asc = bytes([0x11, 0x90])
        s.sendall(P(">QI", 1 << 62, 2) + asc)
        buf, k = b"", 0
        try:
            while not self.closed:
                c = os.read(enc.stdout.fileno(), 65536)
                if not c:
                    break
                buf += c
                while len(buf) >= 7:
                    ln = ((buf[3] & 3) << 11) | (buf[4] << 3) | (buf[5] >> 5)
                    if len(buf) < ln:
                        break
                    raw, buf = buf[7:ln], buf[ln:]
                    s.sendall(P(">QI", k * 21333, len(raw)) + raw)
                    k += 1
        except OSError:
            pass
        finally:
            enc.kill()
            enc.wait()

    # ---- control ----
    def control(self, cs):
        try:
            while True:
                t = recv_exact(cs, 1)
                ln = CTL_LEN.get(t[0])
                if t[0] == 1:
                    h = recv_exact(cs, 4)
                    m = t + h + recv_exact(cs, struct.unpack(">I", h)[0])
                elif ln is None:
                    self.log("E", "unknown control type %d" % t[0])
                    continue
                else:
                    m = t + recv_exact(cs, ln - 1)
                self.log("C", m.hex())
                if t[0] == 17:
                    self.log("E", "reset")
                    self.restart.set()
                elif t[0] == 21:
                    w, h = struct.unpack(">HH", m[1:5])
                    if self.params.get("flex_display") == "true":
                        self.w, self.h = max(2, w - w % 2), max(2, h - h % 2)
                        self.log("E", "resize %dx%d" % (self.w, self.h))
                        self.restart.set()
                    else:
                        self.log("E", "resize ignored %dx%d" % (w, h))
        except (EOFError, OSError):
            self.log("E", "control closed")

    def watch_rotate(self):
        f = os.path.join(self.a.control_dir, "rotate") if self.a.control_dir else None
        while not self.closed and f:
            if os.path.exists(f):
                os.unlink(f)
                self.w, self.h = self.h, self.w
                self.log("E", "rotate %dx%d" % (self.w, self.h))
                self.restart.set()
            time.sleep(0.05)

    def watch_drop(self, socks):
        f = os.path.join(self.a.control_dir, "drop") if self.a.control_dir else None
        while not self.closed and f:
            if os.path.exists(f):
                os.unlink(f)
                open(os.path.join(self.a.control_dir, "dropped"), "w").close()
                self.log("E", "drop")
                for s in socks:
                    try:
                        s.shutdown(socket.SHUT_RDWR)
                        s.close()
                    except OSError:
                        pass
                os._exit(255)
            time.sleep(0.02)

    def run(self):
        ls = socket.socket()
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind(("127.0.0.1", self.a.port))
        ls.listen(4)
        socks = []
        want = 2 + (1 if self.a.audio else 0)
        for i in range(want):
            s, _ = ls.accept()
            if i == 0:
                s.sendall(b"\x00")
            socks.append(s)
        vs, rest = socks[0], socks[1:]
        asock = rest[0] if self.a.audio else None
        cs = rest[-1]
        self.log("E", "connected")
        self.log("P", json.dumps(self.params, sort_keys=True))
        vs.sendall(b"FakePhone".ljust(64, b"\x00") + P(">I", 0x68323634) + bytes([0x80, 0, 0, 0]) + P(">II", self.w, self.h))
        threading.Thread(target=self.control, args=(cs,), daemon=True).start()
        threading.Thread(target=self.watch_rotate, daemon=True).start()
        threading.Thread(target=self.watch_drop, args=(socks,), daemon=True).start()
        if asock:
            threading.Thread(target=self.audio_stream, args=(asock,), daemon=True).start()
        try:
            self.video_stream(vs)
        except OSError:
            pass
        self.closed = True
        self.log("E", "closed")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--log", required=True)
    p.add_argument("--audio", action="store_true")
    p.add_argument("--size", default="192x384")
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--control-dir", default="")
    p.add_argument("--server-args", default="")
    Fake(p.parse_args()).run()


if __name__ == "__main__":
    main()
