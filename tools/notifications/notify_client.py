#!/usr/bin/env python3
"""A scriptable org.freedesktop.Notifications client for the notification probes.

notify-send cannot send image-data, cannot listen for NotificationReplied and
prints nothing about why a notification closed, so the probes talk D-Bus
directly. Every command prints ONE line of JSON on stdout.

  notify_client.py caps
  notify_client.py info
  notify_client.py close ID
  notify_client.py send --summary S [--app A] [--body B] [--icon I]
                        [--urgency 0|1|2] [--timeout MS] [--replaces ID]
                        [--action id=Label ...] [--hint name=type:value ...]
                        [--image-data WxH] [--listen SECONDS]

--hint types: string, int, uint, byte, boolean (x-canonical-private-synchronous
=string:sys-notify, value=int:40, transient=boolean:true ...).
--image-data WxH sends an RGBA gradient in the spec's (iiibiiay) form.
--listen SECONDS keeps the connection open and records every signal that names
the returned id (ActionInvoked, NotificationClosed, NotificationReplied,
ActivationToken) until the time is up or the notification closed.

Runs against whatever DBUS_SESSION_BUS_ADDRESS says -- the probes start it
under dbus-run-session so the user's own notification daemon is never touched.
"""
import argparse
import json
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BUS_NAME = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"
IFACE = "org.freedesktop.Notifications"


def iface(bus):
    return dbus.Interface(bus.get_object(BUS_NAME, PATH), IFACE)


def hint_value(spec):
    typ, _, val = spec.partition(":")
    if typ == "string":
        return dbus.String(val)
    if typ == "int":
        return dbus.Int32(int(val))
    if typ == "uint":
        return dbus.UInt32(int(val))
    if typ == "byte":
        return dbus.Byte(int(val))
    if typ == "boolean":
        return dbus.Boolean(val.lower() in ("1", "true", "yes"))
    raise SystemExit("unknown hint type: " + typ)


def image_data(w, h):
    rows = []
    for y in range(h):
        for x in range(w):
            rows += [int(255 * x / max(1, w - 1)), int(255 * y / max(1, h - 1)), 128, 255]
    return dbus.Struct((dbus.Int32(w), dbus.Int32(h), dbus.Int32(w * 4), dbus.Boolean(True),
                        dbus.Int32(8), dbus.Int32(4), dbus.ByteArray(bytes(rows))),
                       signature="iiibiiay")


def to_py(v):
    if isinstance(v, (dbus.String, dbus.ObjectPath)):
        return str(v)
    if isinstance(v, dbus.Boolean):
        return bool(v)
    if isinstance(v, (dbus.Int32, dbus.UInt32, dbus.Int64, dbus.UInt64, dbus.Byte, dbus.Int16, dbus.UInt16)):
        return int(v)
    if isinstance(v, (list, dbus.Array, tuple, dbus.Struct)):
        return [to_py(x) for x in v]
    if isinstance(v, (dict, dbus.Dictionary)):
        return {str(k): to_py(x) for k, x in v.items()}
    return v


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("caps")
    sub.add_parser("info")
    c = sub.add_parser("close")
    c.add_argument("id", type=int)
    s = sub.add_parser("send")
    s.add_argument("--app", default="NotifyClient")
    s.add_argument("--summary", required=True)
    s.add_argument("--body", default="")
    s.add_argument("--icon", default="")
    s.add_argument("--urgency", type=int, default=None)
    s.add_argument("--timeout", type=int, default=-1)
    s.add_argument("--replaces", type=int, default=0)
    s.add_argument("--action", action="append", default=[])
    s.add_argument("--hint", action="append", default=[])
    s.add_argument("--image-data", default="")
    s.add_argument("--listen", type=float, default=0.0)
    a = ap.parse_args()

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SessionBus()
    n = iface(bus)

    if a.cmd == "caps":
        print(json.dumps({"caps": to_py(n.GetCapabilities())}))
        return
    if a.cmd == "info":
        print(json.dumps({"info": to_py(n.GetServerInformation())}))
        return
    if a.cmd == "close":
        n.CloseNotification(dbus.UInt32(a.id))
        print(json.dumps({"closed": a.id}))
        return

    actions = []
    for spec in a.action:
        k, _, label = spec.partition("=")
        actions += [k, label or k]
    hints = {}
    for spec in a.hint:
        name, _, val = spec.partition("=")
        hints[name] = hint_value(val)
    if a.urgency is not None:
        hints["urgency"] = dbus.Byte(a.urgency)
    if a.image_data:
        w, _, h = a.image_data.partition("x")
        hints["image-data"] = image_data(int(w), int(h))

    signals = []
    loop = GLib.MainLoop()
    state = {"id": None, "closed": False}

    def on_signal(*args, **kw):
        member = kw.get("member")
        if not args or state["id"] is None or int(args[0]) != state["id"]:
            return
        signals.append({"signal": member, "args": to_py(list(args[1:])), "t": round(time.time() - t0, 3)})
        if member == "NotificationClosed":
            state["closed"] = True
            GLib.timeout_add(50, loop.quit)

    bus.add_signal_receiver(on_signal, dbus_interface=IFACE, path=PATH, member_keyword="member")
    t0 = time.time()
    nid = n.Notify(a.app, dbus.UInt32(a.replaces), a.icon, a.summary, a.body,
                   dbus.Array(actions, signature="s"), dbus.Dictionary(hints, signature="sv"),
                   dbus.Int32(a.timeout))
    state["id"] = int(nid)
    if a.listen > 0:
        GLib.timeout_add(int(a.listen * 1000), loop.quit)
        loop.run()
    print(json.dumps({"id": state["id"], "summary": a.summary, "signals": signals}))


if __name__ == "__main__":
    try:
        main()
    except dbus.exceptions.DBusException as e:
        print(json.dumps({"error": e.get_dbus_name(), "message": e.get_dbus_message()}))
        sys.exit(2)
