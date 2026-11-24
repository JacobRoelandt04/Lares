#!/usr/bin/env python3
"""A scripted stand-in for the desktop shell's LockOwner: the lock's socket peer.

  a1_fake_shell.py --sock PATH --dir DIR [--reply-hello] [--shown NAME[,NAME]]
                   [--shown-delay MS] [--retract-after MS] [--garbage]

It LISTENS on PATH (the lock is the client), and writes into DIR:
  recv.log    every line received, "<epoch ms> <line>", plus "<ms> #connect" /
              "#disconnect" events
  state.json  the latest `state` message's fields
  fault-free  nothing else: the runner reads these files, the fake never judges
Runtime control: append lines to DIR/cmd --
  send <json>     send one line to every connected lock
  raw <text>      send the text as a line, unparsed (garbage)
  drop            close every connection (the shell "dies", the socket stays)
  stop            close the listening socket too (connections refused)
  listen          listen again
  quit            exit
--retract-after MS: once the state's phase is "unlocking", send `retracted` after
MS (the honest shell); without it the shell stays silent (the cap case).
--garbage: send a run of malformed lines on connect (the lock must count them).
"""
import argparse, json, os, select, socket, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--sock", required=True)
ap.add_argument("--dir", required=True)
ap.add_argument("--reply-hello", action="store_true")
ap.add_argument("--shown", default="")
ap.add_argument("--shown-delay", type=int, default=0)
ap.add_argument("--retract-after", type=int, default=-1)
ap.add_argument("--garbage", action="store_true")
a = ap.parse_args()

os.makedirs(a.dir, exist_ok=True)
os.makedirs(os.path.dirname(a.sock), exist_ok=True)
recv = open(os.path.join(a.dir, "recv.log"), "a", buffering=1)
cmdpath = os.path.join(a.dir, "cmd")
open(cmdpath, "a").close()
cmdpos = 0
now = lambda: int(time.time() * 1000)
def log(s): recv.write("%d %s\n" % (now(), s))

srv = None
def listen():
    global srv
    if srv: return
    try: os.unlink(a.sock)
    except FileNotFoundError: pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(a.sock); srv.listen(4)
    log("#listen")
def unlisten():
    global srv
    if srv:
        srv.close(); srv = None
        try: os.unlink(a.sock)
        except FileNotFoundError: pass
        log("#unlisten")

conns = {}   # sock -> buffer
timers = []  # (when ms, line)
phase_seen = False
def send(line, only=None):
    for c in ([only] if only else list(conns)):
        try: c.sendall((line + "\n").encode())
        except OSError: pass

listen()
while True:
    rl = ([srv] if srv else []) + list(conns)
    r, _, _ = select.select(rl, [], [], 0.02)
    for s in r:
        if s is srv:
            c, _ = srv.accept(); conns[c] = b""; log("#connect")
            if a.reply_hello: send(json.dumps({"t": "hello", "v": 1}), c)
            if a.shown: timers.append((now() + a.shown_delay, json.dumps({"t": "shown", "screens": a.shown.split(",")}), c))
            if a.garbage:
                for g in ['{"t":', 'not json', '{"t":"hello","v":2}', '{"t":"nope"}', '[1,2]', '{"t":"shown"}', '{"t":"state","s":5}', '{"t":"unlock"}', '{"t":"bye"}']:
                    send(g, c)
            continue
        try: d = s.recv(1 << 16)
        except OSError: d = b""
        if not d:
            s.close(); conns.pop(s, None); log("#disconnect"); phase_seen = False; continue
        conns[s] += d
        while b"\n" in conns[s]:
            line, conns[s] = conns[s].split(b"\n", 1)
            line = line.decode("utf-8", "replace")
            log(line)
            try: m = json.loads(line)
            except Exception: continue
            if m.get("t") == "state" and isinstance(m.get("s"), dict):
                tmp = os.path.join(a.dir, "state.tmp")
                json.dump(m["s"], open(tmp, "w")); os.replace(tmp, os.path.join(a.dir, "state.json"))
                if m["s"].get("phase") == "unlocking" and not phase_seen:
                    phase_seen = True
                    if a.retract_after >= 0:
                        timers.append((now() + a.retract_after, json.dumps({"t": "retracted"}), None))
    for t in [t for t in timers if t[0] <= now()]:
        timers.remove(t)
        if t[2] is None: send(t[1])
        elif t[2] in conns: send(t[1], t[2])
    with open(cmdpath) as f:
        f.seek(cmdpos); new = f.read(); cmdpos = f.tell()
    for ln in new.splitlines():
        cmd, _, arg = ln.partition(" ")
        if cmd == "send": send(arg)
        elif cmd == "raw": send(arg)
        elif cmd == "drop":
            for c in list(conns): c.close(); conns.pop(c)
            log("#dropped"); phase_seen = False
        elif cmd == "stop":
            for c in list(conns): c.close(); conns.pop(c)
            unlisten()
        elif cmd == "listen": listen()
        elif cmd == "quit": sys.exit(0)
