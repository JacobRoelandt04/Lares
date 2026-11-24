#!/usr/bin/env python3
"""The rig's connectivity-check host and its login portal. Runs as the USER (setpriv), never as root: it writes the switch file.

    portal.py <switch-file> <address> <port>

GET /nm-check.txt answers like ping.archlinux.org does ("NetworkManager is online\n", 200) while the switch file says
"online", and with a 302 to /login while it says "portal" -- what a cafe's portal does to a check. POST /login writes "online"
(the user logged in). A test flips the file to arm a portal; the file belongs to the user, the server reads it per request.
"""
import http.server
import sys

SWITCH, ADDR, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
ONLINE = b"NetworkManager is online\n"
LOGIN = (b"<!doctype html><title>Rig portal</title><form method=post action=/login>"
         b"<button>Log in</button></form>\n")


def mode():
    try:
        with open(SWITCH) as f:
            return f.read().strip()
    except OSError:
        return "online"


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, body=b"", headers=()):
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/nm-check.txt"):
            if mode() == "portal":
                self._send(302, b"", [("Location", "http://%s:%d/login" % (ADDR, PORT))])
            else:
                self._send(200, ONLINE, [("Content-Type", "text/plain")])
        elif self.path.startswith("/login"):
            self._send(200, LOGIN, [("Content-Type", "text/html")])
        else:
            self._send(404)

    def do_POST(self):
        if self.path.startswith("/login"):
            with open(SWITCH, "w") as f:
                f.write("online\n")
            self._send(303, b"", [("Location", "http://%s:%d/login" % (ADDR, PORT))])
        else:
            self._send(404)

    def log_message(self, fmt, *args):
        sys.stderr.write("portal: " + (fmt % args) + "\n")


http.server.ThreadingHTTPServer((ADDR, PORT), Handler).serve_forever()
