#!/usr/bin/env python3
"""A stand-in for the Secret Service's default collection on a PRIVATE session bus, for tools/dev/bridge_tool_probe.sh (and
aerial_helper_probe.sh, whose helper asks the same one property).

    BRIDGE_PRIVATE_BUS=1 BRIDGE_WORLD=<file> fake_secretservice.py

Owns org.freedesktop.secrets and exports /org/freedesktop/secrets/aliases/default with org.freedesktop.Secret.Collection's `Locked`
property, read from the world file's keyring.locked at every Get (so a case flips it by editing the world). Nothing else: the tool
only asks `Locked`, never a secret (those go through the stub secret-tool). Prints `secret-stub ready` once the name is owned.
Refuses to run anywhere but on a bus the probe made.
"""
import json
import os
import signal
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

if os.environ.get("BRIDGE_PRIVATE_BUS") != "1":
    sys.exit("fake_secretservice.py: refusing to run outside tools/dev/bridge_tool_probe.sh's private bus")
WORLD = os.environ["BRIDGE_WORLD"]
XML = """<node><interface name="org.freedesktop.Secret.Collection"><property name="Locked" type="b" access="read"/></interface></node>"""
loop = GLib.MainLoop()


def prop(conn, sender, path, iface, name):
    try:
        locked = bool(json.load(open(WORLD)).get("keyring", {}).get("locked"))
    except (OSError, ValueError):
        locked = False
    return GLib.Variant("b", locked)


def main():
    conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
    conn.register_object("/org/freedesktop/secrets/aliases/default", info, None, prop, None)
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, lambda: (loop.quit(), GLib.SOURCE_REMOVE)[1])
    Gio.bus_own_name_on_connection(conn, "org.freedesktop.secrets", Gio.BusNameOwnerFlags.NONE,
                                   lambda c, n: print("secret-stub ready", flush=True), lambda c, n: loop.quit())
    loop.run()


if __name__ == "__main__":
    main()
