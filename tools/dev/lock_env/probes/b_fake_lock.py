#!/usr/bin/env python3
"""A FAKE lock process for the shell-side proofs (stream B): it speaks the
lock's half of the wire (modules/lockscreen/LockProtocol.js) to LockOwner and
prints everything the shell answers, so the owner can be tested without the
real lock (which owns the session and is only ever run in tools/dev/lock_env.sh).

    b_fake_lock.py --sock PATH "state dots=5 face=scanning; sleep 1; unlock; wait-retracted 2; bye"

Commands, separated by ';':
    hello                    send {"t":"hello","v":1} (sent first by default)
    state k=v ...            merge into the state and send it whole (numbers, true/false,
                             else strings; `phase=unlocking` etc. are ordinary keys)
    raw <json line>          send a line as it is (garbage included)
    sleep S                  wait S seconds, printing what arrives meanwhile
    unlock                   phase=unlocking, and remember when
    wait-shown N [S]         wait until a `shown` with N screens arrived (default S=5)
    wait-targets N [S]       wait until `targets` arrived for N distinct screens (default S=5)
    dump-targets FILE        write the last `targets` of every screen to FILE as JSON
    wait-retracted [S]       wait for `retracted`, print the milliseconds since `unlock`
    expect-no-retracted S    wait S s, fail when `retracted` arrives
    bye                      send {"t":"bye"}
    close                    drop the connection without a word (a crash)
    reconnect                open a new connection (sends hello + the state)
Every line the shell sends is printed as `FAKE recv <line>` with the time; the
last line is `FAKE RESULT PASS|FAIL <why>`. Nothing here needs a display.
"""
import argparse, json, socket, sys, time

DEFAULT = {
    "phase": "locked", "boot": False, "lockedAt": 0, "dots": 0, "caps": False,
    "auth": "idle", "failCount": 0, "authMessage": "",
    "face": "absent", "faceMessage": "", "faceReason": "", "awake": True,
}


def val(s):
    if s in ("true", "false"):
        return s == "true"
    try:
        return int(s) if s.lstrip("-").isdigit() else float(s)
    except ValueError:
        return s


class Fake:
    def __init__(self, path):
        self.path = path
        self.t0 = time.time()
        self.state = dict(DEFAULT)
        self.state["lockedAt"] = int(time.time() * 1000)
        self.buf = b""
        self.recv = []          # parsed messages, in order
        self.unlock_at = None
        self.retracted_ms = None
        self.sock = None
        self.fail = None
        self.connect()

    def log(self, what):
        print("FAKE %6.3f %s" % (time.time() - self.t0, what), flush=True)

    def connect(self):
        for _ in range(100):
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.connect(self.path)
                self.sock = s
                self.buf = b""
                self.log("connected")
                return
            except OSError:
                time.sleep(0.1)
        self.fail = "could not connect to " + self.path
        raise SystemExit(self.finish())

    def send(self, obj):
        line = obj if isinstance(obj, str) else json.dumps(obj)
        self.sock.sendall(line.encode() + b"\n")

    def send_state(self):
        self.send({"t": "state", "s": self.state})

    def pump(self, seconds):
        end = time.time() + seconds
        if self.sock is None:
            time.sleep(seconds)
            return
        while True:
            left = end - time.time()
            if left <= 0:
                return
            self.sock.settimeout(left)
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                return
            except OSError:
                return
            if not data:
                self.log("peer closed")
                return
            self.buf += data
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                self.on_line(line.decode(errors="replace"))

    def on_line(self, line):
        self.log("recv " + line)
        try:
            m = json.loads(line)
        except ValueError:
            return
        self.recv.append(m)
        if m.get("t") == "retracted" and self.unlock_at is not None and self.retracted_ms is None:
            self.retracted_ms = int((time.time() - self.unlock_at) * 1000)

    def targets(self):
        out = {}
        for m in self.recv:
            if m.get("t") == "targets":
                out[m.get("screen")] = {"field": m.get("field")}
        return out

    def wait_for(self, pred, secs):
        end = time.time() + secs
        while time.time() < end:
            if pred():
                return True
            self.pump(0.05)
        return pred()

    def run(self, script):
        self.send({"t": "hello", "v": 1})
        self.send_state()
        for cmd in [c.strip() for c in script.split(";") if c.strip()]:
            name, _, rest = cmd.partition(" ")
            if name == "hello":
                self.send({"t": "hello", "v": 1})
            elif name == "state":
                for kv in rest.split():
                    k, _, v = kv.partition("=")
                    self.state[k] = val(v)
                self.send_state()
            elif name == "raw":
                self.send(rest)
            elif name == "sleep":
                self.pump(float(rest))
            elif name == "unlock":
                self.state["phase"] = "unlocking"
                self.unlock_at = time.time()
                self.send_state()
            elif name == "wait-shown":
                n, _, s = rest.partition(" ")
                ok = self.wait_for(lambda: any(m.get("t") == "shown" and len(m.get("screens", [])) == int(n)
                                               for m in self.recv[-6:]), float(s or 5))
                if not ok:
                    self.fail = self.fail or "no `shown` with %s screens" % n
            elif name == "wait-targets":
                n, _, sec = rest.partition(" ")
                ok = self.wait_for(lambda: len(self.targets()) >= int(n), float(sec or 5))
                if not ok:
                    self.fail = self.fail or "`targets` for %d screens never arrived (got %d)" % (int(n), len(self.targets()))
            elif name == "dump-targets":
                json.dump(self.targets(), open(rest.strip(), "w"))
                self.log("dumped targets of %d screens" % len(self.targets()))
            elif name == "wait-retracted":
                ok = self.wait_for(lambda: self.retracted_ms is not None, float(rest or 5))
                self.log("retracted after %s ms" % self.retracted_ms)
                if not ok:
                    self.fail = self.fail or "no `retracted`"
            elif name == "expect-no-retracted":
                self.pump(float(rest))
                if any(m.get("t") == "retracted" for m in self.recv):
                    self.fail = self.fail or "`retracted` arrived"
            elif name == "bye":
                self.send({"t": "bye"})
                self.pump(0.2)
            elif name == "close":
                self.sock.close()
                self.sock = None
                self.log("closed")
            elif name == "reconnect":
                self.connect()
                self.send({"t": "hello", "v": 1})
                self.send_state()
            else:
                self.fail = self.fail or "unknown command " + name
        return self.finish()

    def finish(self):
        if self.fail:
            print("FAKE RESULT FAIL " + self.fail, flush=True)
            return 1
        print("FAKE RESULT PASS retracted_ms=%s" % self.retracted_ms, flush=True)
        return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("script")
    a = ap.parse_args()
    sys.exit(Fake(a.sock).run(a.script))
