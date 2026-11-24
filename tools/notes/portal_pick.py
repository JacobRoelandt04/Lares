#!/usr/bin/env python3
"""portal_pick.py FOLDER [TITLE] -- open the FileChooser portal at FOLDER.

The notes module's "Show in file manager": the xdg-desktop-portal FileChooser
(termfilechooser -> yazi on this machine) opened at the real folder of a note,
so the user sees it where it lives and can pick files there. TITLE is the
dialog's title (the portal's OpenFile `title`); without one it is "Notes", which
is what the notes' own call has always shown. The LLM's attach button asks for
its own, and the launcher's picker takes the default.

Prints the picked files' absolute paths on stdout, each followed by a NUL,
and exits 0; exits 1 when the dialog was cancelled, 2 on any error (the
reason on stderr). Multiple selection is allowed.

The request follows the portal's documented handshake: subscribe to
org.freedesktop.portal.Request.Response on the handle the portal WILL use
(derived from our unique bus name and a handle_token we choose) BEFORE
calling OpenFile, so a fast answer cannot be missed. `current_folder` is a
byte array holding the path and a terminating NUL, as the spec requires.

Never run in a test: it opens a real dialog on the desktop. A test stubs
this file or runs it against a fake portal on a private bus.
"""
import os
import random
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BUS = "org.freedesktop.portal.Desktop"
OBJ = "/org/freedesktop/portal/desktop"


def main():
    if len(sys.argv) not in (2, 3):
        print("usage: portal_pick.py FOLDER [TITLE]", file=sys.stderr)
        return 2
    folder = os.path.abspath(sys.argv[1])
    title = sys.argv[2] if len(sys.argv) == 3 and sys.argv[2] else "Notes"
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except GLib.Error as e:
        print("no session bus: %s" % e.message, file=sys.stderr)
        return 2

    token = "notes%d" % random.randrange(1 << 30)
    sender = bus.get_unique_name().lstrip(":").replace(".", "_")
    handle = "%s/request/%s/%s" % (OBJ, sender, token)
    loop = GLib.MainLoop()
    outcome = {"code": 2, "uris": []}

    def on_response(_conn, _sender, _path, _iface, _signal, params):
        code, results = params.unpack()
        outcome["code"] = 0 if code == 0 else 1
        outcome["uris"] = list(results.get("uris", []))
        loop.quit()

    sub = bus.signal_subscribe(BUS, "org.freedesktop.portal.Request", "Response",
                               handle, None, Gio.DBusSignalFlags.NONE, on_response)
    options = {
        "handle_token": GLib.Variant("s", token),
        "multiple": GLib.Variant("b", True),
        "current_folder": GLib.Variant("ay", folder.encode("utf-8") + b"\0"),
    }
    try:
        bus.call_sync(BUS, OBJ, "org.freedesktop.portal.FileChooser", "OpenFile",
                      GLib.Variant("(ssa{sv})", ("", title, options)),
                      GLib.VariantType("(o)"), Gio.DBusCallFlags.NONE, -1, None)
    except GLib.Error as e:
        bus.signal_unsubscribe(sub)
        print("OpenFile failed: %s" % e.message, file=sys.stderr)
        return 2
    loop.run()
    bus.signal_unsubscribe(sub)

    if outcome["code"] != 0:
        return outcome["code"]
    out = sys.stdout.buffer
    for uri in outcome["uris"]:
        path = Gio.File.new_for_uri(uri).get_path()
        if path:
            out.write(os.fsencode(path) + b"\0")
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
