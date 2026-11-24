#!/usr/bin/env python3
"""Two stand-ins for session services, for themectl's tests. Each runs on a PRIVATE bus (tools/dev/notifications_bus.sh) and never anywhere else.

    dbus_standins.py notifications --log LOG --mode MODE_FILE --ready READY
        org.freedesktop.Notifications. Every Notify is appended to LOG as one JSON line {app, id, summary, body, actions, timeout}. What it does
        next is the word in MODE_FILE, read at each Notify:  "revert" = invoke the action named revert 200 ms later (the click on "Revert");
        "close" = close the notification 200 ms later (it expired, nobody clicked); anything else = leave it open. READY gets the bus address
        once the name is owned.
    dbus_standins.py portal --scheme N --ready READY
        org.freedesktop.portal.Desktop with ONLY the settings this machine's xdg-desktop-portal-gtk answers: org.freedesktop.appearance
        color-scheme (N: 0 none, 1 dark, 2 light) and contrast, and NO accent-color -- the shape of the user's real portal (checked with `busctl
        --user call org.freedesktop.portal.Desktop ... ReadAll`), so libadwaita must take the accent from gsettings.
"""
import argparse
import json
import sys
from gi.repository import Gio, GLib

NOTIFY_XML = """<node><interface name="org.freedesktop.Notifications">
<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
<method name="CloseNotification"><arg type="u" direction="in"/></method>
<method name="GetCapabilities"><arg type="as" direction="out"/></method>
<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
</interface></node>"""

PORTAL_XML = """<node><interface name="org.freedesktop.portal.Settings">
<method name="ReadAll"><arg type="as" direction="in"/><arg type="a{sa{sv}}" direction="out"/></method>
<method name="Read"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<method name="ReadOne"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
<property name="version" type="u" access="read"/>
<signal name="SettingChanged"><arg type="s"/><arg type="s"/><arg type="v"/></signal>
</interface></node>"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("which", choices=["notifications", "portal"])
    ap.add_argument("--log")
    ap.add_argument("--mode")
    ap.add_argument("--ready", required=True)
    ap.add_argument("--scheme", type=int, default=2)
    a = ap.parse_args()
    loop = GLib.MainLoop()
    state = {"id": 0}

    def ready(conn, name):
        import os
        with open(a.ready + ".tmp", "w") as f:
            f.write(os.environ.get("DBUS_SESSION_BUS_ADDRESS", ""))
        os.replace(a.ready + ".tmp", a.ready)

    if a.which == "notifications":
        node = Gio.DBusNodeInfo.new_for_xml(NOTIFY_XML)

        def mode():
            try:
                return open(a.mode).read().strip()
            except OSError:
                return ""

        def call(conn, sender, path, iface, method, params, inv):
            if method == "Notify":
                app, rid, icon, summary, body, actions, hints, timeout = params.unpack()
                state["id"] += 1
                nid = state["id"]
                with open(a.log, "a") as f:
                    f.write(json.dumps({"app": app, "id": nid, "summary": summary, "body": body, "actions": actions, "timeout": timeout}) + "\n")
                m = mode()
                if m == "revert" and "revert" in actions:
                    GLib.timeout_add(200, lambda: (conn.emit_signal(None, path, iface, "ActionInvoked", GLib.Variant("(us)", (nid, "revert"))),
                                                   conn.emit_signal(None, path, iface, "NotificationClosed", GLib.Variant("(uu)", (nid, 3))), False)[-1])
                elif m == "close":
                    GLib.timeout_add(200, lambda: (conn.emit_signal(None, path, iface, "NotificationClosed", GLib.Variant("(uu)", (nid, 1))), False)[-1])
                inv.return_value(GLib.Variant("(u)", (nid,)))
            elif method == "GetCapabilities":
                inv.return_value(GLib.Variant("(as)", (["actions", "body"],)))
            elif method == "GetServerInformation":
                inv.return_value(GLib.Variant("(ssss)", ("standin", "themectl-tests", "1", "1.2")))
            else:
                inv.return_value(None)
        owner, regpath, bname = node.interfaces[0], "/org/freedesktop/Notifications", "org.freedesktop.Notifications"
    else:
        node = Gio.DBusNodeInfo.new_for_xml(PORTAL_XML)
        appearance = {"color-scheme": GLib.Variant("u", a.scheme), "contrast": GLib.Variant("u", 0)}

        def call(conn, sender, path, iface, method, params, inv):
            if method == "ReadAll":
                ns = params.unpack()[0]
                out = {"org.freedesktop.appearance": appearance} if any(n in ("org.freedesktop.appearance", "org.freedesktop.*", "*", "") for n in ns) or not ns else {}
                inv.return_value(GLib.Variant("(a{sa{sv}})", (out,)))
            elif method in ("Read", "ReadOne"):
                ns, key = params.unpack()
                if ns == "org.freedesktop.appearance" and key in appearance:
                    v = appearance[key]
                    inv.return_value(GLib.Variant("(v)", (v,)) if method == "ReadOne" else GLib.Variant("(v)", (GLib.Variant("v", v),)))
                else:
                    inv.return_dbus_error("org.freedesktop.portal.Error.NotFound", "Requested setting not found")
            else:
                inv.return_value(None)
        owner, regpath, bname = node.interfaces[0], "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Desktop"

    def on_bus(conn, name):
        conn.register_object(regpath, owner, call, lambda *x: GLib.Variant("u", 2), None)

    Gio.bus_own_name(Gio.BusType.SESSION, bname, Gio.BusNameOwnerFlags.NONE, on_bus, ready, lambda *x: loop.quit())
    try:
        loop.run()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
