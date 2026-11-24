#!/usr/bin/env python3
"""A stand-in for KDE Connect's daemon (26.08) on a PRIVATE session bus, for tools/dev/bridge_tool_probe.sh.

    BRIDGE_PRIVATE_BUS=1 BRIDGE_WORLD=<file> BRIDGE_KDC_LOG=<file> fake_kdeconnectd.py

Owns org.kde.kdeconnect and exports /modules/kdeconnect (interface org.kde.kdeconnect.daemon), /modules/kdeconnect/devices/<id>
(org.kde.kdeconnect.device) and one object per loaded plugin (battery, connectivity_report, sftp, share, findmyphone, clipboard,
ping) with the interfaces of KDE Connect 26.08. The state is the world file's `kdc` section; it is watched, and every change is
turned into the signals the real daemon emits (deviceListChanged, reachableChanged, pairStateChanged, battery refreshed ...).
Every method call it receives is appended to the log as `<id> <iface-last> <method> <args>`. Prints `kdc-stub ready` once the name
is owned; exits on TERM or when the bus goes. It refuses to run anywhere but on a bus the probe made.

World: {"kdc": {"mountOk": false, "mountError": "Failed to start sshfs", "devices": {"<id>": {"name", "type", "reachable",
        "paired", "pairState", "addresses": [], "links": ["LAN"], "plugins": [...], "verificationKey", "pairRequested",
        "pairRequestedByPeer", "battery": {"charge", "charging"}, "cell": {"strength", "type"}, "mounted", "mountPoint"}}}}
"""
import json
import os
import signal
import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

if os.environ.get("BRIDGE_PRIVATE_BUS") != "1":
    sys.exit("fake_kdeconnectd.py: refusing to run outside tools/dev/bridge_tool_probe.sh's private bus")
WORLD = os.environ["BRIDGE_WORLD"]
LOG = os.environ.get("BRIDGE_KDC_LOG", "")
BUS = "org.kde.kdeconnect"
BASE = "/modules/kdeconnect"

DAEMON_XML = """<node><interface name="org.kde.kdeconnect.daemon">
<method name="devices"><arg type="b" direction="in"/><arg type="b" direction="in"/><arg type="as" direction="out"/></method>
<method name="deviceNames"><arg type="b" direction="in"/><arg type="b" direction="in"/><arg type="a{ss}" direction="out"/></method>
<method name="forceOnNetworkChange"/><method name="selfId"><arg type="s" direction="out"/></method>
<method name="announcedName"><arg type="s" direction="out"/></method>
<signal name="deviceAdded"><arg type="s"/></signal><signal name="deviceRemoved"><arg type="s"/></signal>
<signal name="deviceVisibilityChanged"><arg type="s"/><arg type="b"/></signal><signal name="deviceListChanged"/>
<signal name="pairingRequestsChanged"/>
<property name="pairingRequests" type="as" access="read"/></interface></node>"""
DEVICE_XML = """<node><interface name="org.kde.kdeconnect.device">
<property name="name" type="s" access="read"/><property name="type" type="s" access="read"/>
<property name="isReachable" type="b" access="read"/><property name="isPaired" type="b" access="read"/>
<property name="pairState" type="i" access="read"/><property name="reachableAddresses" type="as" access="read"/>
<property name="activeProviderNames" type="as" access="read"/><property name="supportedPlugins" type="as" access="read"/>
<property name="verificationKey" type="s" access="read"/><property name="isPairRequested" type="b" access="read"/>
<property name="isPairRequestedByPeer" type="b" access="read"/>
<method name="requestPairing"/><method name="acceptPairing"/><method name="cancelPairing"/><method name="unpair"/>
<method name="hasPlugin"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
<method name="loadedPlugins"><arg type="as" direction="out"/></method>
<signal name="reachableChanged"><arg type="b"/></signal><signal name="pairStateChanged"><arg type="i"/></signal>
<signal name="pairingFailed"><arg type="s"/></signal><signal name="nameChanged"><arg type="s"/></signal>
<signal name="pluginsChanged"/><signal name="linksChanged"/></interface></node>"""
PLUGIN_XML = {
    "battery": """<node><interface name="org.kde.kdeconnect.device.battery"><property name="charge" type="i" access="read"/>
<property name="isCharging" type="b" access="read"/><signal name="refreshed"><arg type="b"/><arg type="i"/></signal></interface></node>""",
    "connectivity_report": """<node><interface name="org.kde.kdeconnect.device.connectivity_report">
<property name="cellularNetworkStrength" type="i" access="read"/><property name="cellularNetworkType" type="s" access="read"/>
<signal name="refreshed"><arg type="s"/><arg type="i"/></signal></interface></node>""",
    "sftp": """<node><interface name="org.kde.kdeconnect.device.sftp"><method name="mount"/>
<method name="mountAndWait"><arg type="b" direction="out"/></method><method name="unmount"/>
<method name="isMounted"><arg type="b" direction="out"/></method><method name="mountPoint"><arg type="s" direction="out"/></method>
<method name="getMountError"><arg type="s" direction="out"/></method>
<method name="getDirectories"><arg type="a{sv}" direction="out"/></method>
<signal name="mounted"/><signal name="unmounted"/></interface></node>""",
    "share": """<node><interface name="org.kde.kdeconnect.device.share"><method name="shareUrl"><arg type="s" direction="in"/></method>
<method name="shareUrls"><arg type="as" direction="in"/></method><method name="shareText"><arg type="s" direction="in"/></method>
</interface></node>""",
    "findmyphone": """<node><interface name="org.kde.kdeconnect.device.findmyphone"><method name="ring"/></interface></node>""",
    "clipboard": """<node><interface name="org.kde.kdeconnect.device.clipboard"><method name="sendClipboard"/></interface></node>""",
    "ping": """<node><interface name="org.kde.kdeconnect.device.ping"><method name="sendPing"/></interface></node>""",
}

conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
world = {}
reg = {}          # (path, iface) -> registration id
known = {}        # id -> last device dict


def log(text):
    if LOG:
        with open(LOG, "a") as f:
            f.write(text + "\n")


def load():
    try:
        with open(WORLD) as f:
            return json.load(f).get("kdc", {})
    except (OSError, ValueError):
        return {}


def devs():
    return world.get("devices", {})


def dev(i):
    return devs().get(i, {})


def update(i, **kw):
    """Write a change the daemon itself makes (pairing, a mount) back into the world file."""
    try:
        with open(WORLD) as f:
            w = json.load(f)
    except (OSError, ValueError):
        return
    w.setdefault("kdc", {}).setdefault("devices", {}).setdefault(i, {}).update(kw)
    tmp = WORLD + ".kdc.tmp"
    with open(tmp, "w") as f:
        json.dump(w, f)
    os.replace(tmp, WORLD)


def ids_of(only_reachable, only_paired):
    return sorted(i for i, d in devs().items() if (d.get("reachable") or not only_reachable) and (d.get("paired") or not only_paired))


def method_daemon(c, sender, path, iface, method, params, inv):
    log("daemon %s %s" % (method, params.unpack() if params is not None else ""))
    if method == "devices":
        a = params.unpack()
        inv.return_value(GLib.Variant("(as)", (ids_of(a[0], a[1]),)))
    elif method == "deviceNames":
        a = params.unpack()
        inv.return_value(GLib.Variant("(a{ss})", ({i: dev(i).get("name", "") for i in ids_of(*a)},)))
    elif method == "selfId":
        inv.return_value(GLib.Variant("(s)", ("fakelaptop",)))
    elif method == "announcedName":
        inv.return_value(GLib.Variant("(s)", ("fake laptop",)))
    else:
        inv.return_value(None)


def prop_daemon(c, sender, path, iface, name):
    return GLib.Variant("as", [])


def device_prop(i):
    def get(c, sender, path, iface, name):
        d = dev(i)
        m = {"name": ("s", d.get("name", "")), "type": ("s", d.get("type", "phone")), "isReachable": ("b", bool(d.get("reachable"))),
             "isPaired": ("b", bool(d.get("paired"))), "pairState": ("i", int(d.get("pairState", 3 if d.get("paired") else 0))),
             "reachableAddresses": ("as", list(d.get("addresses", []))), "activeProviderNames": ("as", list(d.get("links", ["LAN"]))),
             "supportedPlugins": ("as", ["kdeconnect_" + p for p in d.get("plugins", [])]), "verificationKey": ("s", d.get("verificationKey", "")),
             "isPairRequested": ("b", bool(d.get("pairRequested"))), "isPairRequestedByPeer": ("b", bool(d.get("pairRequestedByPeer")))}
        t, v = m[name]
        return GLib.Variant(t, v)
    return get


def device_method(i):
    def call(c, sender, path, iface, method, params, inv):
        args = params.unpack() if params is not None else ()
        log("%s device %s %s" % (i, method, " ".join(map(str, args))))
        if method == "requestPairing":
            update(i, pairRequested=True)
        elif method == "acceptPairing":
            update(i, paired=True, pairState=3, pairRequested=False, pairRequestedByPeer=False)
        elif method == "cancelPairing":
            update(i, pairRequested=False, pairRequestedByPeer=False)
        elif method == "unpair":
            update(i, paired=False, pairState=0)
        elif method == "hasPlugin":
            inv.return_value(GLib.Variant("(b)", (args[0] in ["kdeconnect_" + p for p in dev(i).get("plugins", [])],)))
            return
        elif method == "loadedPlugins":
            d = dev(i)
            # the real daemon's names carry the prefix (KDE Connect 26.08, captured 2026-11-18)
            inv.return_value(GLib.Variant("(as)", (["kdeconnect_" + p for p in d.get("plugins", [])] if d.get("reachable") else [],)))
            return
        inv.return_value(None)
    return call


def plugin_prop(i, name):
    def get(c, sender, path, iface, prop):
        d = dev(i)
        if name == "battery":
            b = d.get("battery") or {"charge": 0, "charging": False}
            return GLib.Variant("i", int(b["charge"])) if prop == "charge" else GLib.Variant("b", bool(b["charging"]))
        ce = d.get("cell") or {"strength": 0, "type": ""}
        return GLib.Variant("i", int(ce["strength"])) if prop == "cellularNetworkStrength" else GLib.Variant("s", ce["type"])
    return get


def plugin_method(i, name):
    def call(c, sender, path, iface, method, params, inv):
        args = params.unpack() if params is not None else ()
        log("%s %s %s %s" % (i, name, method, " ".join(map(str, args))))
        d = dev(i)
        if name == "sftp":
            if method == "mountAndWait":
                ok = bool(world.get("mountOk"))
                if ok:
                    update(i, mounted=True)
                inv.return_value(GLib.Variant("(b)", (ok,)))
                return
            if method == "isMounted":
                inv.return_value(GLib.Variant("(b)", (bool(d.get("mounted")),)))
                return
            if method == "mountPoint":
                inv.return_value(GLib.Variant("(s)", (d.get("mountPoint", "/run/user/1000/" + i),)))
                return
            if method == "getDirectories":
                # the real daemon (26.08, read 2026-11-19): the phone's storage inside the mount, with its name
                mp = d.get("mountPoint", "/run/user/1000/" + i)
                inv.return_value(GLib.Variant("(a{sv})", ({mp + "/storage/emulated/0": GLib.Variant("s", "Internal shared storage")},)))
                return
            if method == "getMountError":
                inv.return_value(GLib.Variant("(s)", (world.get("mountError", "Failed to start sshfs"),)))
                return
            if method == "unmount":
                update(i, mounted=False)
        inv.return_value(None)
    return call


def register(path, xml, call, prop):
    info = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
    reg[(path, info.name)] = conn.register_object(path, info, call, prop, None)


def unregister_prefix(prefix):
    for k in [k for k in reg if k[0] == prefix or k[0].startswith(prefix + "/")]:
        conn.unregister_object(reg.pop(k))


def emit(path, iface, name, sig, args):
    conn.emit_signal(None, path, iface, name, GLib.Variant(sig, args) if sig else None)


def sync():
    """Make the exported objects and the signals follow the world file."""
    global world
    world = load()
    now = devs()
    for i in list(known):
        if i not in now:
            unregister_prefix(BASE + "/devices/" + i)
            emit(BASE, "org.kde.kdeconnect.daemon", "deviceRemoved", "(s)", (i,))
            del known[i]
    for i, d in now.items():
        path = BASE + "/devices/" + i
        old = known.get(i)
        if old is None:
            register(path, DEVICE_XML, device_method(i), device_prop(i))
            for p in d.get("plugins", []):
                if p in PLUGIN_XML:
                    register(path + "/" + p, PLUGIN_XML[p], plugin_method(i, p), plugin_prop(i, p))
            emit(BASE, "org.kde.kdeconnect.daemon", "deviceAdded", "(s)", (i,))
        else:
            if old.get("reachable") != d.get("reachable"):
                emit(path, "org.kde.kdeconnect.device", "reachableChanged", "(b)", (bool(d.get("reachable")),))
                emit(BASE, "org.kde.kdeconnect.daemon", "deviceVisibilityChanged", "(sb)", (i, bool(d.get("reachable"))))
            if old.get("pairState") != d.get("pairState") or old.get("paired") != d.get("paired"):
                emit(path, "org.kde.kdeconnect.device", "pairStateChanged", "(i)", (int(d.get("pairState", 0)),))
            if old.get("battery") != d.get("battery") and d.get("battery"):
                b = d["battery"]
                emit(path + "/battery", "org.kde.kdeconnect.device.battery", "refreshed", "(bi)", (bool(b["charging"]), int(b["charge"])))
            if old.get("cell") != d.get("cell") and d.get("cell"):
                c = d["cell"]
                emit(path + "/connectivity_report", "org.kde.kdeconnect.device.connectivity_report", "refreshed", "(si)",
                     (c["type"], int(c["strength"])))
            if old.get("mounted") != d.get("mounted"):
                emit(path + "/sftp", "org.kde.kdeconnect.device.sftp", "mounted" if d.get("mounted") else "unmounted", None, None)
        known[i] = json.loads(json.dumps(d))
    emit(BASE, "org.kde.kdeconnect.daemon", "deviceListChanged", None, None)
    conn.flush_sync(None)


def on_world(*_a):
    GLib.timeout_add(30, lambda: (sync(), GLib.SOURCE_REMOVE)[1])


def main():
    global world
    world = load()
    register(BASE, DAEMON_XML, method_daemon, prop_daemon)
    mon = Gio.File.new_for_path(WORLD).monitor_file(Gio.FileMonitorFlags.NONE, None)
    mon.connect("changed", on_world)
    for sig in (signal.SIGTERM, signal.SIGINT):
        GLib.unix_signal_add(GLib.PRIORITY_HIGH, sig, lambda: (loop.quit(), GLib.SOURCE_REMOVE)[1])
    Gio.bus_own_name_on_connection(conn, BUS, Gio.BusNameOwnerFlags.NONE,
                                   lambda c, n: (sync(), print("kdc-stub ready", flush=True)), lambda c, n: loop.quit())
    loop.run()


if __name__ == "__main__":
    main()
