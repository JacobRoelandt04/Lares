#!/usr/bin/env python3
"""A stand-in for `silicon-helper boost-serve` (tools/dev/boost_client_probe.sh): listens on argv[1], answers every
`boost <ms>` with `ok <ms>` the way the real server does, and logs each line it got (and CLOSE when a connection ends)
to argv[2]. It writes nothing anywhere else and exits on SIGTERM."""
import os, selectors, signal, socket, sys

path, log = sys.argv[1], sys.argv[2]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
os.chmod(path, 0o600)
srv.listen(4)
sel = selectors.DefaultSelector()
sel.register(srv, selectors.EVENT_READ)
bufs = {}
out = open(log, "a", buffering=1)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    for key, _ in sel.select():
        s = key.fileobj
        if s is srv:
            c, _ = srv.accept()
            sel.register(c, selectors.EVENT_READ)
            bufs[c] = b""
            continue
        try:
            data = s.recv(256)
        except ConnectionResetError:  # a client closing with our answer still unread is a close too
            data = b""
        if not data:
            out.write("CLOSE\n")
            sel.unregister(s)
            s.close()
            continue
        bufs[s] += data
        while b"\n" in bufs[s]:
            line, bufs[s] = bufs[s].split(b"\n", 1)
            text = line.decode(errors="replace")
            out.write(text + "\n")
            if text.startswith("boost "):
                s.sendall(("ok " + text[6:] + "\n").encode())
            else:
                s.sendall(b"refused the only verb is: boost <ms>\n")
