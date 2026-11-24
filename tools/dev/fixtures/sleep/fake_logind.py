#!/usr/bin/env python3
# A stand-in for logind's sleep signal on a PRIVATE session bus, for tools/dev/sleep_lockenv_film.sh: owns org.freedesktop.login1 there,
# answers Get/GetAll of Manager.InhibitDelayMaxUSec (FAKE_LOGIND_CAP_US, 3 s by default) and emits Manager.PrepareForSleep(b) when told on
# stdin, one command per line. It holds no inhibitor and can suspend nothing. Never run it on a real bus.
#
#   sleep | wake   PrepareForSleep(true) | PrepareForSleep(false), as logind emits them
#   decoy          a PrepareForSleep(true) from ANOTHER sender's object path -- not logind's
#   quit           leave the bus
#
# Prints "READY" once the name is owned and "EMITTED <cmd> <ms>" (wall clock) after each signal has been flushed onto the bus.
import os
import sys
import time
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

if os.environ.get("SLEEP_FADE_PRIVATE_BUS") != "1":
    sys.exit("fake_logind.py: refusing to run outside tools/dev/sleep_lockenv_film.sh's private bus")

PATH = "/org/freedesktop/login1"
MGR = "org.freedesktop.login1.Manager"
XML = """<node><interface name="org.freedesktop.login1.Manager">
<property name="InhibitDelayMaxUSec" type="t" access="read"/>
<signal name="PrepareForSleep"><arg type="b" name="start"/></signal>
</interface></node>"""
CAP = int(os.environ.get("FAKE_LOGIND_CAP_US", "3000000"))
conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()


def get_prop(conn, sender, path, iface, name):
    if name == "InhibitDelayMaxUSec":
        return GLib.Variant("t", CAP)
    return None


node = Gio.DBusNodeInfo.new_for_xml(XML)
conn.register_object(PATH, node.interfaces[0], None, get_prop, None)


def emit(path, b):
    conn.emit_signal(None, path, MGR, "PrepareForSleep", GLib.Variant("(b)", (b,)))
    conn.flush_sync(None)


def command(c):
    if c == "sleep":
        emit(PATH, True)
    elif c == "wake":
        emit(PATH, False)
    elif c == "decoy":
        emit("/org/freedesktop/login1/decoy", True)
    elif c == "quit":
        loop.quit()
        return
    else:
        print("UNKNOWN " + c, flush=True)
        return
    print("EMITTED %s %d" % (c, int(time.time() * 1000)), flush=True)


def on_stdin(ch, cond):
    line = ch.readline()
    if not line:
        loop.quit()
        return False
    command(line.strip())
    return True


def owned(conn, name):
    print("READY", flush=True)


Gio.bus_own_name_on_connection(conn, "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE, owned, None)
ch = GLib.IOChannel.unix_new(sys.stdin.fileno())
GLib.io_add_watch(ch, GLib.IO_IN | GLib.IO_HUP, on_stdin)
loop.run()
