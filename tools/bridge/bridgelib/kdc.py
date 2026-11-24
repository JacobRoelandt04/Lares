"""KDE Connect over D-Bus (Gio): the daemon's device list, one device's facts, the actions, and the signals.

Every call has a callback `cb(value, error)` and a timeout. In `sync` mode (a one-shot) the call is made with call_sync and the
callback runs at once, so one chain of calls serves both the watcher and the one-shots. The daemon is never asked while its
name has no owner: that would D-Bus-activate it.
"""
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

BUS = "org.kde.kdeconnect"
DAEMON_PATH = "/modules/kdeconnect"
DAEMON = "org.kde.kdeconnect.daemon"
DEVICE = "org.kde.kdeconnect.device"
PLUGIN = "org.kde.kdeconnect.device."
DEV_PATH = DAEMON_PATH + "/devices/"
PROPS = "org.freedesktop.DBus.Properties"
TIMEOUT_MS = 2500

SERVICE_FILES = ("/usr/share/dbus-1/services/org.kde.kdeconnect.service", "/usr/lib/kdeconnectd",
                 "/usr/lib/libexec/kdeconnectd", "/usr/bin/kdeconnectd")


def installed(which, exists=os.path.exists):
    return bool(which("kdeconnectd")) or any(exists(p) for p in SERVICE_FILES)


def device_path(dev_id):
    return DEV_PATH + dev_id


def id_of_path(path):
    if not path.startswith(DEV_PATH):
        return ""
    return path[len(DEV_PATH):].split("/", 1)[0]




def _storage_of(dirs):
    """KDE Connect's `getDirectories` ({path: name}) -> the phone's internal storage path, else the first path, else ""."""
    keys = [str(k) for k in (dirs or {})]
    return next((k for k in keys if k.rstrip("/").endswith("/storage/emulated/0")), keys[0] if keys else "")

def plugin_name(p):
    """"kdeconnect_findmyphone" -> "findmyphone": the bare name the plugin's object path and interface use."""
    p = str(p)
    return p[len("kdeconnect_"):] if p.startswith("kdeconnect_") else p

class Kdc:
    def __init__(self, conn, sync=False):
        self.conn = conn
        self.sync = sync

    def has_owner(self):
        try:
            r = self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "NameHasOwner",
                                    GLib.Variant("(s)", (BUS,)), GLib.VariantType("(b)"), Gio.DBusCallFlags.NO_AUTO_START,
                                    TIMEOUT_MS, None)
            return bool(r.unpack()[0])
        except GLib.Error:
            return False

    def call(self, path, iface, method, params, reply, cb, timeout=TIMEOUT_MS):
        rt = GLib.VariantType(reply) if reply else None
        flags = Gio.DBusCallFlags.NO_AUTO_START
        if self.sync:
            try:
                r = self.conn.call_sync(BUS, path, iface, method, params, rt, flags, timeout, None)
            except GLib.Error as e:
                cb(None, _why(e))
                return
            cb(r.unpack() if r is not None else (), "")
            return

        def done(conn, res, _):
            try:
                r = conn.call_finish(res)
            except GLib.Error as e:
                cb(None, _why(e))
                return
            cb(r.unpack() if r is not None else (), "")
        self.conn.call(BUS, path, iface, method, params, rt, flags, timeout, None, done, None)

    def get_all(self, path, iface, cb):
        self.call(path, PROPS, "GetAll", GLib.Variant("(s)", (iface,)), "(a{sv})",
                  lambda v, e: cb(v[0] if v else None, e))

    # ---- reading ----------------------------------------------------------------------------------------------------
    def list_ids(self, cb):
        self.call(DAEMON_PATH, DAEMON, "devices", GLib.Variant("(bb)", (False, False)), "(as)",
                  lambda v, e: cb(list(v[0]) if v else None, e))

    def read_device(self, dev_id, cb):
        """cb(record | None): the facts of one device, in the shape merge.py takes."""
        path = device_path(dev_id)
        rec = {"id": dev_id}

        def got_props(p, err):
            if p is None:
                cb(None)
                return
            rec.update(name=str(p.get("name", "")), type=str(p.get("type", "phone")), reachable=bool(p.get("isReachable")),
                       paired=bool(p.get("isPaired")), pairState=int(p.get("pairState", 0)),
                       addresses=list(p.get("reachableAddresses") or []), links=list(p.get("activeProviderNames") or []),
                       verificationKey=str(p.get("verificationKey", "")), pairRequested=bool(p.get("isPairRequested")),
                       pairRequestedByPeer=bool(p.get("isPairRequestedByPeer")), plugins=[], battery=None, cell=None,
                       mountPoint="")
            if not rec["reachable"]:
                cb(rec)
                return
            self.call(path, DEVICE, "loadedPlugins", None, "(as)", got_plugins)

        def got_plugins(v, err):
            # the daemon names them "kdeconnect_battery", ... (KDE Connect 26.08, captured 2026-11-18); the object paths and
            # every rule here use the bare name
            rec["plugins"] = sorted(plugin_name(p) for p in v[0]) if v else []
            todo = []
            if "battery" in rec["plugins"]:
                todo.append(("battery", self._battery))
            if "connectivity_report" in rec["plugins"]:
                todo.append(("connectivity_report", self._cell))
            if "sftp" in rec["plugins"]:
                todo.append(("sftp", self._sftp))
            if not todo:
                cb(rec)
                return
            left = [len(todo)]

            def one(name, fill):
                def got(p, e):
                    if p is not None:
                        fill(rec, p)
                    left[0] -= 1
                    if left[0] == 0:
                        cb(rec)
                if name == "sftp":
                    # the mount point, then where the phone's own storage is inside it (`getDirectories`: the sftp server
                    # shows the phone's whole tree, /storage/emulated/0 is what a person means by "the phone")
                    def got_point(v, e):
                        if not v:
                            got(None, e)
                            return
                        self.call(path + "/sftp", PLUGIN + "sftp", "getDirectories", None, "(a{sv})",
                                  lambda d, e2: got({"mountPoint": v[0], "storage": _storage_of(d[0] if d else {})}, e2))
                    self.call(path + "/sftp", PLUGIN + "sftp", "mountPoint", None, "(s)", got_point)
                else:
                    self.get_all(path + "/" + name, PLUGIN + name, got)
            for name, fill in todo:
                one(name, fill)
        self.get_all(path, DEVICE, got_props)

    @staticmethod
    def _battery(rec, p):
        if "charge" in p:
            rec["battery"] = {"charge": int(p["charge"]), "charging": bool(p.get("isCharging"))}

    @staticmethod
    def _cell(rec, p):
        if "cellularNetworkStrength" in p:
            rec["cell"] = {"strength": max(0, min(4, int(p["cellularNetworkStrength"]))),
                           "type": str(p.get("cellularNetworkType", ""))}

    @staticmethod
    def _sftp(rec, p):
        rec["mountPoint"] = str(p.get("mountPoint", ""))
        rec["storage"] = str(p.get("storage", ""))

    def read_all(self, cb):
        """cb({id: record}, error): the daemon's devices (paired or reachable) with their facts."""
        def got_ids(ids, err):
            if ids is None:
                cb({}, err)
                return
            out = {}
            left = [len(ids)]
            if not ids:
                cb(out, "")
                return

            def one(i):
                def got(rec):
                    if rec is not None:
                        out[i] = rec
                    left[0] -= 1
                    if left[0] == 0:
                        cb(out, "")
                self.read_device(i, got)
            for i in ids:
                one(i)
        self.list_ids(got_ids)

    # ---- acting -----------------------------------------------------------------------------------------------------
    def act(self, dev_id, method, plugin=None, params=None, reply=None, cb=None):
        path = device_path(dev_id) + ("/" + plugin if plugin else "")
        iface = PLUGIN + plugin if plugin else DEVICE
        self.call(path, iface, method, params, reply, cb or (lambda v, e: None), timeout=30000 if method == "mountAndWait" else 5000)

    def refresh(self, cb):
        self.call(DAEMON_PATH, DAEMON, "forceOnNetworkChange", None, None, cb)

    # ---- watching ---------------------------------------------------------------------------------------------------
    def subscribe(self, handler):
        """ONE subscription for everything the daemon emits; handler(path, interface, member, params)."""
        return self.conn.signal_subscribe(BUS, None, None, None, None, Gio.DBusSignalFlags.NONE,
                                          lambda c, s, p, i, m, params, _u=None: handler(p, i, m, params.unpack() if params else ()))

    def watch_owner(self, appeared, vanished):
        return Gio.bus_watch_name_on_connection(self.conn, BUS, Gio.BusNameWatcherFlags.NONE,
                                                lambda c, n, o: appeared(), lambda c, n: vanished())


def _why(e):
    m = str(e.message if hasattr(e, "message") else e)
    return m.split(": ", 1)[-1] if m.startswith("GDBus.Error") else m


def session_bus():
    return Gio.bus_get_sync(Gio.BusType.SESSION, None)
