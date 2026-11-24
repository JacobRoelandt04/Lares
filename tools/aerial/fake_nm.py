#!/usr/bin/env python3
"""A fake NetworkManager + a fake BlueZ AgentManager on a PRIVATE D-Bus.

  fake_nm.py serve --dir <short dir> [--scenario <file.json>]    start the private bus + the fakes; prints `READY <bus address>`
  fake_nm.py ctl   --dir <dir> '<json>'                          one control command; prints the JSON answer
  fake_nm.py addr  --dir <dir>                                   prints the bus address

THE BUS. A dbus-daemon of its own (config written into <dir>: one unix socket, everything allowed, NO service directories: nothing
is ever activated, nothing of the machine's is reachable). Never `dbus-run-session` with the default config (it activates real
services against the real compositor).

THE WORLD. A scenario (JSON; default: modules/aerial/data/fixtures/scenario.json, built from the shapes of the user's capture, all
addresses and names fake): devices, access points (a hidden one, one SSID on two bands), saved profiles (doubles, an eduroam-like
EAP one), a wired jack without carrier. Activating a profile walks the device through prepare / config / ip-config / activated,
or ends in need-auth then failed with a reason (a wrong or missing secret, a scenario outcome, `fail_next`).

THE CONTROL CHANNEL (<dir>/ctl.sock, one JSON object per line each way): ap_add, ap_remove, ap_strength, set_carrier, wifi_hw,
dnsmasq, proton_up / proton_down (the killswitch dummy comes first, as the real CLI does), bt_request / bt_cancel (the fake BlueZ
calls the registered agent), bt_adapter / bt_dev_add / bt_dev / bt_dev_remove / bt_adapter_remove (the fake BlueZ's adapter and
devices: powerState, discovering, rssi ...; its ObjectManager is at "/"), fail_next, profile_remove, state, quit.

Only the shapes the aerial helper reads are implemented; this is not a general NetworkManager.
"""
import sys
import os
import json
import socket
import signal
import subprocess
import time
import uuid as uuidlib
import hashlib

import warnings
warnings.simplefilter("ignore")
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

NM = "org.freedesktop.NetworkManager"
NMP = "/org/freedesktop/NetworkManager"
PROPS = "org.freedesktop.DBus.Properties"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCENARIO = os.path.normpath(os.path.join(HERE, "..", "..", "modules", "aerial", "data", "fixtures", "scenario.json"))

RSN = {"open": (0, 0, 0), "wep": (1, 0, 0), "wpa2": (1, 0, 0x188), "wpa2-wpa3": (1, 0, 0x588), "sae": (1, 0, 0x488), "owe": (0, 0, 0x888),
       "eap": (1, 0, 0x288)}
KEYMGMT = {"wpa2": "wpa-psk", "wpa2-wpa3": "wpa-psk", "sae": "sae", "owe": "owe", "eap": "wpa-eap"}

SIG = {
    (NM, "Devices"): "ao", (NM, "ActiveConnections"): "ao", (NM, "PrimaryConnection"): "o", (NM, "State"): "u",
    (NM, "Connectivity"): "u", (NM, "WirelessEnabled"): "b", (NM, "WirelessHardwareEnabled"): "b", (NM, "Version"): "s",
    (NM, "NetworkingEnabled"): "b",
    (NM + ".Device", "Interface"): "s", (NM + ".Device", "DeviceType"): "u", (NM + ".Device", "Driver"): "s",
    (NM + ".Device", "DriverVersion"): "s", (NM + ".Device", "FirmwareVersion"): "s",
    (NM + ".Device", "State"): "u", (NM + ".Device", "StateReason"): "(uu)", (NM + ".Device", "Managed"): "b",
    (NM + ".Device", "ActiveConnection"): "o", (NM + ".Device", "Ip4Config"): "o", (NM + ".Device", "Ip6Config"): "o",
    (NM + ".Device", "HwAddress"): "s", (NM + ".Device", "Autoconnect"): "b",
    (NM + ".Device.Wireless", "AccessPoints"): "ao", (NM + ".Device.Wireless", "ActiveAccessPoint"): "o",
    (NM + ".Device.Wireless", "LastScan"): "x", (NM + ".Device.Wireless", "Bitrate"): "u", (NM + ".Device.Wireless", "HwAddress"): "s",
    (NM + ".Device.Wireless", "PermHwAddress"): "s", (NM + ".Device.Wireless", "Mode"): "u",
    (NM + ".Device.Wired", "Carrier"): "b", (NM + ".Device.Wired", "Speed"): "u", (NM + ".Device.Wired", "HwAddress"): "s",
    (NM + ".Device.Wired", "PermHwAddress"): "s",
    (NM + ".Device.Statistics", "RxBytes"): "t", (NM + ".Device.Statistics", "TxBytes"): "t",
    (NM + ".Device.Statistics", "RefreshRateMs"): "u",
    (NM + ".AccessPoint", "Flags"): "u", (NM + ".AccessPoint", "WpaFlags"): "u", (NM + ".AccessPoint", "RsnFlags"): "u",
    (NM + ".AccessPoint", "Ssid"): "ay", (NM + ".AccessPoint", "Frequency"): "u", (NM + ".AccessPoint", "HwAddress"): "s",
    (NM + ".AccessPoint", "Mode"): "u", (NM + ".AccessPoint", "MaxBitrate"): "u", (NM + ".AccessPoint", "Bandwidth"): "u",
    (NM + ".AccessPoint", "Strength"): "y", (NM + ".AccessPoint", "LastSeen"): "i",
    (NM + ".Connection.Active", "Connection"): "o", (NM + ".Connection.Active", "SpecificObject"): "o",
    (NM + ".Connection.Active", "Id"): "s", (NM + ".Connection.Active", "Uuid"): "s", (NM + ".Connection.Active", "Type"): "s",
    (NM + ".Connection.Active", "Devices"): "ao", (NM + ".Connection.Active", "State"): "u",
    (NM + ".Connection.Active", "Default"): "b", (NM + ".Connection.Active", "Default6"): "b",
    (NM + ".Connection.Active", "Vpn"): "b", (NM + ".Connection.Active", "Ip4Config"): "o", (NM + ".Connection.Active", "Ip6Config"): "o",
    (NM + ".IP4Config", "AddressData"): "aa{sv}", (NM + ".IP4Config", "Gateway"): "s", (NM + ".IP4Config", "NameserverData"): "aa{sv}",
    (NM + ".IP6Config", "AddressData"): "aa{sv}", (NM + ".IP6Config", "Gateway"): "s", (NM + ".IP6Config", "Nameservers"): "aay",
    (NM + ".Settings.Connection", "Unsaved"): "b", (NM + ".Settings.Connection", "Flags"): "u",
    (NM + ".Settings.Connection", "Filename"): "s",
    ("org.bluez.Adapter1", "Address"): "s", ("org.bluez.Adapter1", "Name"): "s", ("org.bluez.Adapter1", "Alias"): "s",
    ("org.bluez.Adapter1", "Powered"): "b", ("org.bluez.Adapter1", "PowerState"): "s", ("org.bluez.Adapter1", "Discovering"): "b",
    ("org.bluez.Adapter1", "Discoverable"): "b",
    ("org.bluez.Device1", "Address"): "s", ("org.bluez.Device1", "Name"): "s", ("org.bluez.Device1", "Alias"): "s",
    ("org.bluez.Device1", "Paired"): "b", ("org.bluez.Device1", "Connected"): "b", ("org.bluez.Device1", "RSSI"): "n",
}


def typed(sig, v):
    if sig == "s":
        return dbus.String(v)
    if sig == "b":
        return dbus.Boolean(bool(v))
    if sig == "u":
        return dbus.UInt32(int(v))
    if sig == "i":
        return dbus.Int32(int(v))
    if sig == "x":
        return dbus.Int64(int(v))
    if sig == "t":
        return dbus.UInt64(int(v))
    if sig == "y":
        return dbus.Byte(int(v))
    if sig == "n":
        return dbus.Int16(int(v))
    if sig == "o":
        return dbus.ObjectPath(v)
    if sig == "ay":
        return dbus.Array([dbus.Byte(b) for b in (v if isinstance(v, (bytes, bytearray)) else bytes(v))], signature="y")
    if sig == "ao":
        return dbus.Array([dbus.ObjectPath(x) for x in v], signature="o")
    if sig == "aay":
        return dbus.Array([typed("ay", x) for x in v], signature="ay")
    if sig == "(uu)":
        return dbus.Struct((dbus.UInt32(v[0]), dbus.UInt32(v[1])), signature="uu")
    if sig == "aa{sv}":
        return dbus.Array([dbus.Dictionary({k: (dbus.UInt32(x) if isinstance(x, int) and not isinstance(x, bool) else dbus.String(x))
                                            for k, x in d.items()}, signature="sv") for d in v], signature="a{sv}")
    raise ValueError(sig)


def plain(v):
    if isinstance(v, dbus.Boolean):
        return bool(v)
    if isinstance(v, (dbus.Int16, dbus.Int32, dbus.Int64, dbus.UInt16, dbus.UInt32, dbus.UInt64, dbus.Byte)):
        return int(v)
    if isinstance(v, (dbus.String, dbus.ObjectPath)):
        return str(v)
    if isinstance(v, dbus.ByteArray):
        return bytes(v)
    if isinstance(v, dbus.Array):
        if v.signature == "y":
            return bytes(bytearray(int(x) for x in v))
        return [plain(x) for x in v]
    if isinstance(v, dbus.Dictionary):
        return {str(k): plain(x) for k, x in v.items()}
    if isinstance(v, dbus.Struct):
        return [plain(x) for x in v]
    return v


SETTING_TYPES = {("802-11-wireless", "powersave"): "u", ("connection", "timestamp"): "t", ("connection", "autoconnect-priority"): "i", ("connection", "metered"): "i",
                 ("802-11-wireless", "ssid"): "ay", ("802-11-wireless", "bssid"): "ay", ("ipv4", "dns"): "au",
                 ("ipv4", "address-data"): "aa{sv}", ("802-1x", "ca-cert"): "ay", ("802-11-wireless-security", "wep-key-type"): "u",
                 ("802-11-wireless-security", "wep-tx-keyidx"): "u"}
SECRET_KEYS = {("802-11-wireless-security", "psk"), ("802-11-wireless-security", "wep-key0"), ("802-1x", "password")}


def setting_value(sec, key, v):
    t = SETTING_TYPES.get((sec, key))
    if t == "t":
        return dbus.UInt64(int(v))
    if t == "i":
        return dbus.Int32(int(v))
    if t == "u":
        return dbus.UInt32(int(v))
    if t == "ay":
        return typed("ay", v if isinstance(v, (bytes, bytearray)) else (v or b"").encode() if isinstance(v, str) else bytes(v))
    if t == "au":
        return dbus.Array([dbus.UInt32(x) for x in v], signature="u")
    if t == "aa{sv}":
        return typed("aa{sv}", v)
    if isinstance(v, bool):
        return dbus.Boolean(v)
    if isinstance(v, int):
        return dbus.Int32(v)
    if isinstance(v, (bytes, bytearray)):
        return typed("ay", v)
    if isinstance(v, list):
        return dbus.Array([dbus.String(x) for x in v], signature="s")
    return dbus.String(v)


class NmError(dbus.DBusException):
    _dbus_error_name = "org.freedesktop.NetworkManager.Failed"


class UnknownConnection(dbus.DBusException):
    _dbus_error_name = "org.freedesktop.NetworkManager.Settings.InvalidConnection"


class NotAllowed(dbus.DBusException):
    _dbus_error_name = "org.freedesktop.NetworkManager.Device.NotAllowed"


class InvalidProperty(dbus.DBusException):
    _dbus_error_name = "org.freedesktop.NetworkManager.Settings.Connection.InvalidProperty"


BUS = None
WORLD = None
NAMES = []


class Obj(dbus.service.Object):
    def __init__(self, path, props):
        super().__init__(BUS, path)
        self.p = props          # iface -> {name: plain value}
        self.path = path

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, iface, name):
        return typed(SIG[(iface, name)], self.p[iface][name])

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        if iface not in self.p:
            raise NmError("no such interface %s" % iface)
        return dbus.Dictionary({k: typed(SIG[(iface, k)], v) for k, v in self.p[iface].items()}, signature="sv")

    @dbus.service.method(PROPS, in_signature="ssv", out_signature="")
    def Set(self, iface, name, value):
        self.on_set(iface, name, plain(value))

    @dbus.service.signal(PROPS, signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated):
        pass

    def on_set(self, iface, name, value):
        raise NmError("read-only property")

    def setp(self, iface, **kw):
        changed = {}
        for k, v in kw.items():
            if self.p[iface].get(k) != v:
                self.p[iface][k] = v
                changed[k] = typed(SIG[(iface, k)], v)
        if changed:
            self.PropertiesChanged(iface, dbus.Dictionary(changed, signature="sv"), dbus.Array([], signature="s"))

    def drop(self):
        self.remove_from_connection()


class Manager(Obj):
    @dbus.service.method(NM, in_signature="", out_signature="ao")
    def GetDevices(self):
        return typed("ao", self.p[NM]["Devices"])

    @dbus.service.method(NM, in_signature="ooo", out_signature="o")
    def ActivateConnection(self, conn, dev, spec):
        return WORLD.activate(str(conn), str(dev), str(spec))

    @dbus.service.method(NM, in_signature="a{sa{sv}}oo", out_signature="oo")
    def AddAndActivateConnection(self, settings, dev, spec):
        c = WORLD.add_profile(plain(settings))
        return dbus.ObjectPath(c.path), WORLD.activate(c.path, str(dev), str(spec))

    @dbus.service.method(NM, in_signature="a{sa{sv}}ooa{sv}", out_signature="ooa{sv}")
    def AddAndActivateConnection2(self, settings, dev, spec, options):
        c = WORLD.add_profile(plain(settings))
        return dbus.ObjectPath(c.path), WORLD.activate(c.path, str(dev), str(spec)), dbus.Dictionary({}, signature="sv")

    @dbus.service.method(NM, in_signature="o", out_signature="")
    def DeactivateConnection(self, active):
        WORLD.deactivate(str(active))

    def on_set(self, iface, name, value):
        if iface == NM and name == "WirelessEnabled":
            WORLD.set_wireless(bool(value))
        else:
            raise NmError("read-only property")


class Device(Obj):
    @dbus.service.method(NM + ".Device", in_signature="", out_signature="")
    def Disconnect(self):
        WORLD.deactivate_device(self.path)

    @dbus.service.method(NM + ".Device.Wireless", in_signature="a{sv}", out_signature="", async_callbacks=("reply_cb", "error_cb"))
    def RequestScan(self, options, reply_cb, error_cb):
        if WORLD.hang.get("scan"):
            return              # a stuck NetworkManager: the call is never answered
        try:
            WORLD.request_scan(self)
        except dbus.DBusException as e:
            return error_cb(e)
        reply_cb()

    @dbus.service.method(NM + ".Device.Wireless", in_signature="", out_signature="ao")
    def GetAccessPoints(self):
        return typed("ao", self.p[NM + ".Device.Wireless"]["AccessPoints"])

    @dbus.service.signal(NM + ".Device.Wireless", signature="o")
    def AccessPointAdded(self, path):
        pass

    @dbus.service.signal(NM + ".Device.Wireless", signature="o")
    def AccessPointRemoved(self, path):
        pass

    def on_set(self, iface, name, value):
        if iface == NM + ".Device.Statistics" and name == "RefreshRateMs":
            self.setp(iface, RefreshRateMs=int(value))
            WORLD.stats_rate(self)
        else:
            raise NmError("read-only property")


class AP(Obj):
    pass


class Active(Obj):
    pass


class IPConfig(Obj):
    pass


class Settings(Obj):
    @dbus.service.method(NM + ".Settings", in_signature="", out_signature="ao")
    def ListConnections(self):
        return typed("ao", [c.path for c in WORLD.profiles.values()])

    @dbus.service.method(NM + ".Settings", in_signature="s", out_signature="o")
    def GetConnectionByUuid(self, u):
        for c in WORLD.profiles.values():
            if c.uuid == str(u):
                return dbus.ObjectPath(c.path)
        raise UnknownConnection("no such connection")

    @dbus.service.method(NM + ".Settings", in_signature="a{sa{sv}}", out_signature="o")
    def AddConnection(self, settings):
        return dbus.ObjectPath(WORLD.add_profile(plain(settings)).path)

    @dbus.service.signal(NM + ".Settings", signature="o")
    def NewConnection(self, path):
        pass

    @dbus.service.signal(NM + ".Settings", signature="o")
    def ConnectionRemoved(self, path):
        pass


class Profile(Obj):
    def __init__(self, path, settings):
        self.settings = {}
        self.secrets = {}
        self.uuid = ""
        super().__init__(path, {NM + ".Settings.Connection": {"Unsaved": False, "Flags": 0, "Filename": ""}})
        self.load(settings)

    def load(self, settings, keep_secrets=True):
        old = self.secrets if keep_secrets else {}
        self.secrets = dict(old)
        clean = {}
        for sec, d in settings.items():
            clean[sec] = {}
            for k, v in d.items():
                if (sec, k) in SECRET_KEYS:
                    self.secrets[(sec, k)] = v
                else:
                    clean[sec][k] = v
        self.settings = clean
        self.uuid = clean["connection"]["uuid"]
        self.p[NM + ".Settings.Connection"]["Filename"] = "/etc/NetworkManager/system-connections/%s.nmconnection" % clean["connection"]["id"]

    @property
    def id(self):
        return self.settings["connection"]["id"]

    @property
    def type(self):
        return self.settings["connection"]["type"]

    @property
    def ssid(self):
        s = self.settings.get("802-11-wireless", {}).get("ssid")
        return bytes(s) if s is not None else b""

    @dbus.service.method(NM + ".Settings.Connection", in_signature="", out_signature="a{sa{sv}}")
    def GetSettings(self):
        out = {}
        for sec, d in self.settings.items():
            out[sec] = dbus.Dictionary({k: setting_value(sec, k, v) for k, v in d.items()}, signature="sv")
        return dbus.Dictionary(out, signature="sa{sv}")

    @dbus.service.method(NM + ".Settings.Connection", in_signature="a{sa{sv}}", out_signature="")
    def Update(self, settings):
        s = plain(settings)
        WORLD.log.append(("update", self.uuid, sorted(s)))
        self.load(s, keep_secrets=True)
        self.Updated()

    @dbus.service.method(NM + ".Settings.Connection", in_signature="", out_signature="")
    def Delete(self):
        WORLD.remove_profile(self)

    @dbus.service.method(NM + ".Settings.Connection", in_signature="s", out_signature="a{sa{sv}}")
    def GetSecrets(self, section):
        d = {k: setting_value(sec, k, v) for (sec, k), v in self.secrets.items() if sec == str(section)}
        return dbus.Dictionary({str(section): dbus.Dictionary(d, signature="sv")}, signature="sa{sv}")

    @dbus.service.signal(NM + ".Settings.Connection", signature="")
    def Updated(self):
        pass

    @dbus.service.signal(NM + ".Settings.Connection", signature="")
    def Removed(self):
        pass


# --------------------------------------------------------------------------------------------------------------------------------
class World:
    def __init__(self, scen):
        self.s = scen
        self.step = int(scen.get("timing", {}).get("step_ms", 120))
        self.n = {"dev": 0, "ap": 0, "act": 0, "ip4": 0, "ip6": 0, "set": 0}
        self.devices = {}      # iface -> Device
        self.aps = {}          # bssid -> AP (listed ones)
        self.hidden_scan = []  # APs revealed by a scan
        self.profiles = {}     # path -> Profile
        self.actives = {}      # path -> Active
        self.ips = {}          # path -> IPConfig
        self.log = []
        self.fail_next = None
        self.hang = {}
        self.dnsmasq = bool(scen.get("dnsmasq", True))
        self.hw_on = True
        self.agent = None      # (sender, path, capability)
        self.bz = {}           # path -> BzObj (adapter + devices); the ObjectManager at "/" lists them
        self.bzman = None
        self.timers = []
        self.manager = Manager(NMP, {NM: {"Devices": [], "ActiveConnections": [], "PrimaryConnection": "/", "State": 70,
                                          "Connectivity": 4, "WirelessEnabled": bool(scen.get("wirelessEnabled", True)),
                                          "WirelessHardwareEnabled": True, "Version": scen.get("version", "1.58.1"),
                                          "NetworkingEnabled": True}})
        self.settings_obj = Settings(NMP + "/Settings", {})
        for d in scen.get("devices", []):
            self.add_device(d)
        for pr in scen.get("profiles", []):
            self.add_profile(self.profile_settings(pr))
        for a in scen.get("aps", []):
            if a.get("appearsOnScan"):
                self.hidden_scan.append(a)
            else:
                self.add_ap(a)
        for d in scen.get("devices", []):
            if d.get("active") and d["type"] == 2:
                prof = self.profile_by_id(d["active"])
                if prof:
                    self.activate(prof.path, self.devices[d["iface"]].path, "/", instant=True)

    # ---- objects --------------------------------------------------------------------------------------------------------
    def nid(self, k):
        self.n[k] += 1
        return self.n[k]

    def add_device(self, d):
        path = NMP + "/Devices/%d" % self.nid("dev")
        t = int(d["type"])
        props = {NM + ".Device": {"Interface": d["iface"], "DeviceType": t, "Driver": d.get("driver", ""), "DriverVersion": d.get("driverVersion", ""),
                                  "FirmwareVersion": d.get("firmware", ""), "State": int(d.get("state", 30)),
                                  "StateReason": [int(d.get("state", 30)), 0], "Managed": t not in (32, 13, 22, 29),
                                  "ActiveConnection": "/", "Ip4Config": "/", "Ip6Config": "/", "HwAddress": d.get("hw", ""),
                                  "Autoconnect": True},
                 NM + ".Device.Statistics": {"RxBytes": 0, "TxBytes": 0, "RefreshRateMs": 0}}
        if t == 2:
            props[NM + ".Device.Wireless"] = {"AccessPoints": [], "ActiveAccessPoint": "/", "LastScan": self.boot_ms(), "Bitrate": 0,
                                              "HwAddress": d.get("hw", ""), "PermHwAddress": d.get("perm", d.get("hw", "")), "Mode": 2}
        if t == 1:
            props[NM + ".Device.Wired"] = {"Carrier": bool(d.get("carrier", False)), "Speed": int(d.get("speed", 0)),
                                           "HwAddress": d.get("hw", ""), "PermHwAddress": d.get("perm", d.get("hw", ""))}
        dev = Device(path, props)
        dev.cfg = d
        dev.timer = None
        self.devices[d["iface"]] = dev
        self.manager.setp(NM, Devices=[x.path for x in self.devices.values()])
        return dev

    def remove_device(self, iface):
        dev = self.devices.pop(iface, None)
        if dev:
            self.manager.setp(NM, Devices=[x.path for x in self.devices.values()])
            dev.drop()

    @staticmethod
    def boot_ms():
        return int(time.clock_gettime(time.CLOCK_BOOTTIME) * 1000)

    def wifi_dev(self):
        for d in self.devices.values():
            if d.p[NM + ".Device"]["DeviceType"] == 2:
                return d
        return None

    def add_ap(self, a):
        dev = self.wifi_dev()
        if dev is None or not self.manager.p[NM]["WirelessEnabled"]:
            return None
        bssid = a["bssid"].upper()
        if bssid in self.aps:
            return self.aps[bssid]
        path = NMP + "/AccessPoint/%d" % self.nid("ap")
        flags, wpa, rsn = RSN[a.get("security", "wpa2")]
        ssid = b"" if a.get("hidden") else (bytes.fromhex(a["ssidHex"]) if a.get("ssidHex") else a["ssid"].encode("utf-8"))
        ap = AP(path, {NM + ".AccessPoint": {
            "Flags": flags, "WpaFlags": wpa, "RsnFlags": rsn, "Ssid": ssid, "Frequency": int(a["freq"]), "HwAddress": bssid, "Mode": 2,
            "MaxBitrate": int(a.get("maxBitrate", 130000)), "Bandwidth": int(a.get("width", 20)), "Strength": int(a.get("strength", 50)),
            "LastSeen": int(time.clock_gettime(time.CLOCK_BOOTTIME))}})
        ap.cfg = a
        self.aps[bssid] = ap
        w = dev.p[NM + ".Device.Wireless"]
        dev.setp(NM + ".Device.Wireless", AccessPoints=w["AccessPoints"] + [path])
        dev.AccessPointAdded(dbus.ObjectPath(path))
        return ap

    def remove_ap(self, bssid):
        ap = self.aps.pop(bssid.upper(), None)
        dev = self.wifi_dev()
        if ap and dev:
            w = dev.p[NM + ".Device.Wireless"]
            if w["ActiveAccessPoint"] == ap.path:
                dev.setp(NM + ".Device.Wireless", ActiveAccessPoint="/")
            dev.setp(NM + ".Device.Wireless", AccessPoints=[x for x in w["AccessPoints"] if x != ap.path])
            dev.AccessPointRemoved(dbus.ObjectPath(ap.path))
            ap.drop()

    def profile_settings(self, pr):
        ssid = pr.get("ssid")
        sec = pr.get("security", "wpa2")
        conn = {"id": pr["id"], "uuid": pr.get("uuid") or str(uuidlib.uuid4()), "type": pr.get("type", "802-11-wireless"),
                "autoconnect": bool(pr.get("autoconnect", True)), "autoconnect-priority": int(pr.get("priority", 0)),
                "timestamp": int(pr.get("timestamp", 0)), "metered": int(pr.get("metered", 0))}
        st = {"connection": conn}
        if conn["type"] == "802-11-wireless":
            w = {"ssid": ssid.encode("utf-8"), "mode": pr.get("mode", "infrastructure")}
            if pr.get("hidden"):
                w["hidden"] = True
            if pr.get("band"):
                w["band"] = pr["band"]
            st["802-11-wireless"] = w
            if sec != "open":
                s = {"key-mgmt": KEYMGMT.get(sec, "wpa-psk")}
                if pr.get("psk"):
                    s["psk"] = pr["psk"]
                st["802-11-wireless-security"] = s
            if sec == "eap":
                st["802-1x"] = {"eap": [pr.get("eap", "peap")], "identity": pr.get("identity", ""),
                                "anonymous-identity": pr.get("anonymousIdentity", ""), "phase2-auth": pr.get("phase2", "mschapv2")}
                if pr.get("password"):
                    st["802-1x"]["password"] = pr["password"]
            st["ipv4"] = {"method": "shared" if pr.get("mode") == "ap" else "auto"}
            st["ipv6"] = {"method": "ignore" if pr.get("mode") == "ap" else "auto"}
        elif conn["type"] == "802-3-ethernet":
            st["802-3-ethernet"] = {}
            st["ipv4"] = {"method": "auto"}
            st["ipv6"] = {"method": "auto"}
        elif conn["type"] == "wireguard":
            conn["interface-name"] = pr.get("ifname", "proton0")
            st["ipv4"] = {"method": "manual", "address-data": [{"address": "10.2.0.2", "prefix": 32}]}
        return st

    def add_profile(self, settings):
        c = settings.get("connection", {})
        c.setdefault("uuid", str(uuidlib.uuid4()))
        if c.get("type") is None:
            raise NmError("connection.type missing")
        path = NMP + "/Settings/%d" % self.nid("set")
        prof = Profile(path, settings)
        self.profiles[path] = prof
        self.settings_obj.NewConnection(dbus.ObjectPath(path))
        return prof

    def remove_profile(self, prof):
        for a in list(self.actives.values()):
            if a.p[NM + ".Connection.Active"]["Connection"] == prof.path:
                self.finish_deactivate(a, 40)
        self.profiles.pop(prof.path, None)
        prof.Removed()
        self.settings_obj.ConnectionRemoved(dbus.ObjectPath(prof.path))
        prof.drop()

    def profile_by_id(self, i):
        for p in self.profiles.values():
            if p.id == i:
                return p

    def profile_by_uuid(self, u):
        for p in self.profiles.values():
            if p.uuid == u:
                return p

    # ---- timers ---------------------------------------------------------------------------------------------------------
    def later(self, ms, fn):
        def run():
            try:
                fn()
            except Exception as e:
                sys.stderr.write("fake_nm timer: %r\n" % e)
            return False
        GLib.timeout_add(max(1, int(ms)), run)

    # ---- activation -----------------------------------------------------------------------------------------------------
    def ip4_for(self, prof, dev):
        s = prof.settings.get("ipv4", {})
        ip = self.s.get("ip", {})
        if s.get("method") == "manual" and s.get("address-data"):
            a = s["address-data"][0]
            gw = s.get("gateway", "")
            dns = [socket.inet_ntoa(int(x).to_bytes(4, "little")) for x in s.get("dns", [])] or ip.get("dns", [])
            return {"AddressData": [{"address": a["address"], "prefix": a["prefix"]}], "Gateway": gw,
                    "NameserverData": [{"address": x} for x in dns]}
        if s.get("method") == "shared":
            return {"AddressData": [{"address": "10.42.0.1", "prefix": 24}], "Gateway": "", "NameserverData": []}
        return {"AddressData": [{"address": ip.get("address", "192.0.2.30"), "prefix": ip.get("prefix", 24)}],
                "Gateway": ip.get("gateway", "192.0.2.1"), "NameserverData": [{"address": x} for x in ip.get("dns", [])]}

    def outcome_for(self, prof, dev, ap):
        if self.fail_next:
            o, self.fail_next = self.fail_next, None
            return o
        if prof.type == "802-3-ethernet" and not dev.p[NM + ".Device.Wired"]["Carrier"]:
            return {"outcome": "refuse", "error": "Connection '%s' is not available on device %s because device has no carrier"
                    % (prof.id, dev.p[NM + ".Device"]["Interface"])}
        if prof.type == "802-11-wireless":
            if prof.settings.get("802-11-wireless", {}).get("mode") == "ap":
                if not self.dnsmasq:
                    return {"outcome": "fail", "reason": 18}
                return {"outcome": "ok"}
            o = self.s.get("outcomes", {}).get(prof.ssid.decode("utf-8", "replace"))
            if o:
                return o
            if ap is None:
                return {"outcome": "fail", "reason": 11}
            need = ap.cfg.get("psk")
            if need:
                have = prof.secrets.get(("802-11-wireless-security", "psk"))
                if have is None:
                    return {"outcome": "fail", "reason": 7, "needAuth": True}
                if have != need:
                    return {"outcome": "fail", "reason": 7, "needAuth": True}
            ap_pw = ap.cfg.get("eapPassword")
            if ap_pw and prof.secrets.get(("802-1x", "password")) != ap_pw:
                return {"outcome": "fail", "reason": 7, "needAuth": True}
        return {"outcome": "ok"}

    def find_ap(self, dev, spec, prof):
        if spec and spec != "/":
            for ap in self.aps.values():
                if ap.path == spec:
                    return ap
        best = None
        for ap in self.aps.values():
            if (ap.p[NM + ".AccessPoint"]["Ssid"] == prof.ssid or (ap.cfg.get("hidden") and ap.cfg["ssid"].encode() == prof.ssid)) and (best is None or ap.p[NM + ".AccessPoint"]["Strength"] >
                                                                    best.p[NM + ".AccessPoint"]["Strength"]):
                best = ap
        return best

    def activate(self, conn_path, dev_path, spec, instant=False):
        getattr(self, "blocked", set()).discard(dev_path)     # an activation asked for lifts a Disconnect's block
        prof = self.profiles.get(conn_path)
        if prof is None:
            raise UnknownConnection("no such connection")
        dev = next((d for d in self.devices.values() if d.path == dev_path), None)
        if dev is None:
            raise NmError("unknown device")
        if dev.p[NM + ".Device"]["State"] == 20 and not instant:
            raise NmError("device %s is unavailable" % dev.p[NM + ".Device"]["Interface"])
        # as the REAL NetworkManager (the user's machine, 2026-11-20): a Wi-Fi / wired profile bound to another interface name is refused
        bound = str(prof.settings.get("connection", {}).get("interface-name", "") or "")
        if bound and dev.p[NM + ".Device"]["DeviceType"] in (1, 2) and bound != dev.p[NM + ".Device"]["Interface"]:
            raise UnknownConnection("Connection '%s' is not available on device %s because profile is not compatible with device (mismatching interface name)"
                                    % (prof.settings["connection"].get("id", ""), dev.p[NM + ".Device"]["Interface"]))
        # as the REAL NetworkManager (the test bed's first run): a specific access point whose broadcast SSID is not the connection's
        # (a hidden AP broadcasts none) is refused before anything activates
        if spec not in ("", "/") and dev.p[NM + ".Device"]["DeviceType"] == 2:
            sap = next((a for a in self.aps.values() if a.path == spec), None)
            want = bytes(bytearray(int(x) for x in prof.settings.get("802-11-wireless", {}).get("ssid", []) or []))
            if sap is not None:
                have = bytes(bytearray(int(x) for x in sap.p[NM + ".AccessPoint"].get("Ssid", []) or []))
                if have != want:
                    raise InvalidProperty("802-11-wireless.ssid: connection does not match access point")
        ap = self.find_ap(dev, spec, prof) if dev.p[NM + ".Device"]["DeviceType"] == 2 else None
        o = self.outcome_for(prof, dev, ap)
        if o.get("outcome") == "refuse":
            raise NmError(o["error"])
        # whatever is active on this device goes first
        for a in list(self.actives.values()):
            if dev.path in a.p[NM + ".Connection.Active"]["Devices"] and not a.cfg.get("fixed"):
                self.finish_deactivate(a, 41, quiet=True)
        path = NMP + "/ActiveConnection/%d" % self.nid("act")
        c = prof.settings["connection"]
        act = Active(path, {NM + ".Connection.Active": {
            "Connection": conn_path, "SpecificObject": ap.path if ap else "/", "Id": c["id"], "Uuid": c["uuid"], "Type": c["type"],
            "Devices": [dev.path], "State": 1, "Default": False, "Default6": False, "Vpn": False, "Ip4Config": "/", "Ip6Config": "/"}})
        act.cfg = {}
        self.actives[path] = act
        self.manager.setp(NM, ActiveConnections=[x.path for x in self.actives.values()])
        self.s_dev(dev, 40, 0)
        self.log.append(("activate", prof.uuid, dev.p[NM + ".Device"]["Interface"], o.get("outcome")))
        if instant:
            self.complete(act, dev, prof, ap)
            return dbus.ObjectPath(path)
        st = self.step
        self.later(st, lambda: self.s_dev(dev, 50, 0))
        if o.get("outcome") == "ok":
            self.later(st * 2, lambda: self.s_dev(dev, 70, 0))
            self.later(st * 3, lambda: self.complete(act, dev, prof, ap))
        else:
            reason = int(o.get("reason", 5))
            if o.get("needAuth"):
                self.later(st * 2, lambda: self.s_dev(dev, 60, 0))
            self.later(st * 3, lambda: self.fail(act, dev, reason))
        return dbus.ObjectPath(path)

    def s_dev(self, dev, state, reason):
        dev.setp(NM + ".Device", State=state, StateReason=[state, reason])

    def complete(self, act, dev, prof, ap):
        if act.path not in self.actives:
            return
        ip4 = IPConfig(NMP + "/IP4Config/%d" % self.nid("ip4"), {NM + ".IP4Config": self.ip4_for(prof, dev)})
        self.ips[ip4.path] = ip4
        ip6 = None
        if prof.type != "802-11-wireless" or prof.settings.get("802-11-wireless", {}).get("mode") != "ap":
            ip6 = IPConfig(NMP + "/IP6Config/%d" % self.nid("ip6"), {NM + ".IP6Config": {
                "AddressData": self.s.get("ip6", [{"address": "2001:db8:0:1::30", "prefix": 64}]), "Gateway": "",
                "Nameservers": []}})
            self.ips[ip6.path] = ip6
        isdef = prof.type in ("802-11-wireless", "802-3-ethernet") and prof.settings.get("ipv4", {}).get("method") != "shared"
        act.setp(NM + ".Connection.Active", State=2, Ip4Config=ip4.path, Ip6Config=ip6.path if ip6 else "/", Default=isdef)
        dev.setp(NM + ".Device", ActiveConnection=act.path, Ip4Config=ip4.path, Ip6Config=ip6.path if ip6 else "/")
        if ap is not None:
            dev.setp(NM + ".Device.Wireless", ActiveAccessPoint=ap.path,
                     Bitrate=int(ap.p[NM + ".AccessPoint"]["MaxBitrate"]))
        self.s_dev(dev, 100, 0)
        if isdef:
            self.manager.setp(NM, PrimaryConnection=act.path)
        self.mark_changed(prof)

    def mark_changed(self, prof):
        prof.settings["connection"]["timestamp"] = int(time.time())

    def fail(self, act, dev, reason):
        if act.path not in self.actives:
            return
        self.s_dev(dev, 120, reason)
        act.setp(NM + ".Connection.Active", State=4)
        self.later(self.step, lambda: self.drop_active(act))
        self.later(self.step * 2, lambda: self.s_dev(dev, 30, 0))

    def drop_active(self, act):
        if act.path not in self.actives:
            return
        self.actives.pop(act.path, None)
        self.manager.setp(NM, ActiveConnections=[x.path for x in self.actives.values()])
        if self.manager.p[NM]["PrimaryConnection"] == act.path:
            nxt = next((a.path for a in self.actives.values() if a.p[NM + ".Connection.Active"]["Default"]), "/")
            self.manager.setp(NM, PrimaryConnection=nxt)
        for k in ("Ip4Config", "Ip6Config"):
            ip = self.ips.pop(act.p[NM + ".Connection.Active"][k], None)
            if ip:
                ip.drop()
        act.drop()

    def finish_deactivate(self, act, reason, quiet=False):
        devs = [d for d in self.devices.values() if d.path in act.p[NM + ".Connection.Active"]["Devices"]]
        act.setp(NM + ".Connection.Active", State=3)
        for d in devs:
            self.s_dev(d, 110, reason)
            d.setp(NM + ".Device", ActiveConnection="/", Ip4Config="/", Ip6Config="/")
            if d.p[NM + ".Device"]["DeviceType"] == 2:
                d.setp(NM + ".Device.Wireless", ActiveAccessPoint="/", Bitrate=0)
        act.setp(NM + ".Connection.Active", State=4)
        self.drop_active(act)
        for d in devs:
            if not quiet:
                self.later(self.step, lambda d=d: self.s_dev(d, 30, reason))
            else:
                self.s_dev(d, 30, reason)

    def deactivate(self, path):
        act = self.actives.get(path)
        if act is None:
            raise NmError("connection is not active")
        devs = list(act.p[NM + ".Connection.Active"]["Devices"])
        gone = act.p[NM + ".Connection.Active"]["Connection"]
        self.finish_deactivate(act, 41)
        # as the REAL NetworkManager (the test bed's fourth run): its policy then autoconnects ANOTHER saved network in range on that
        # device at once, unless the device itself was disconnected (deactivate_device)
        if self.s.get("policy", {}).get("autoconnect"):       # opt-in per scenario: the integration world turns it on
            for dp in devs:
                self.later(self.step, lambda dp=dp, gone=gone: self.autoconnect(dp, skip=gone))

    def deactivate_device(self, path):
        self.blocked = getattr(self, "blocked", set())
        self.blocked.add(path)         # Device.Disconnect: nothing autoconnects here until the user activates something
        for a in list(self.actives.values()):
            if path in a.p[NM + ".Connection.Active"]["Devices"]:
                self.finish_deactivate(a, 41)

    def autoconnect(self, dev_path, skip=""):
        if dev_path in getattr(self, "blocked", set()):
            return
        dev = next((d for d in self.devices.values() if d.path == dev_path), None)
        if dev is None or dev.p[NM + ".Device"]["DeviceType"] != 2 or dev.p[NM + ".Device"]["ActiveConnection"] != "/":
            return
        if not self.manager.p[NM].get("WirelessEnabled", True):
            return
        seen = set(bytes(bytearray(int(x) for x in ap.p[NM + ".AccessPoint"].get("Ssid", []) or [])) for ap in self.aps.values())
        cands = []
        for prof in self.profiles.values():
            st = prof.settings
            c = st.get("connection", {})
            if prof.path == skip or c.get("type") != "802-11-wireless":
                continue
            if c.get("autoconnect", True) is False or st.get("802-11-wireless", {}).get("mode") == "ap":
                continue
            if bytes(bytearray(int(x) for x in st.get("802-11-wireless", {}).get("ssid", []) or [])) in seen:
                cands.append((-int(c.get("autoconnect-priority", 0) or 0), -int(c.get("timestamp", 0) or 0), prof.path))
        # NetworkManager's order: the highest autoconnect-priority, then the most recently used
        for _, _, path in sorted(cands)[:1]:
            try:
                self.activate(path, dev_path, "/")
            except Exception:
                pass

    def set_wireless(self, on):
        self.manager.setp(NM, WirelessEnabled=on)
        dev = self.wifi_dev()
        if dev is None:
            return
        if not on:
            self.deactivate_device(dev.path)
            for b in list(self.aps):
                self.remove_ap(b)
            self.s_dev(dev, 20, 0)
        else:
            self.s_dev(dev, 30, 0)
            for a in self.s.get("aps", []):
                if not a.get("appearsOnScan"):
                    self.add_ap(a)

    def request_scan(self, dev):
        gap = int(self.s.get("scanRateLimitMs", 0))
        last = getattr(self, "_last_scan", 0)
        if gap and (time.time() * 1000 - last) < gap:
            raise NotAllowed("Scanning not allowed immediately following previous scan")
        if not self.manager.p[NM]["WirelessEnabled"] or dev.p[NM + ".Device"]["State"] == 20:
            raise NotAllowed("Scanning not allowed while unavailable")
        self._last_scan = time.time() * 1000
        self.log.append(("scan",))

        def done():
            for a in self.hidden_scan:
                self.add_ap(a)
            dev.setp(NM + ".Device.Wireless", LastScan=self.boot_ms())
        self.later(int(self.s.get("scanMs", 400)), done)

    def stats_rate(self, dev):
        rate = dev.p[NM + ".Device.Statistics"]["RefreshRateMs"]
        if dev.timer:
            GLib.source_remove(dev.timer)
            dev.timer = None
        if rate > 0:
            def tick():
                if dev.p[NM + ".Device"]["State"] == 100:
                    st = dev.p[NM + ".Device.Statistics"]
                    dev.setp(NM + ".Device.Statistics", RxBytes=st["RxBytes"] + 125000, TxBytes=st["TxBytes"] + 12500)
                return True
            dev.timer = GLib.timeout_add(rate, tick)

    # ---- the Proton-like tunnel -----------------------------------------------------------------------------------------
    def proton_up(self, name="NL#1", dev_name="proton0"):
        wifi_primary = self.manager.p[NM]["PrimaryConnection"]
        ks = self.dummy("pvpn-killswitch", "pvpnksintrf0")
        self.manager.setp(NM, PrimaryConnection=ks.path)
        self.manager.setp(NM, State=40)

        def second():
            self.manager.setp(NM, State=70)
            prof = self.add_profile(self.profile_settings({"id": "ProtonVPN " + name, "type": "wireguard", "ifname": dev_name}))
            d = self.add_device({"iface": dev_name, "type": 29, "state": 100})
            a = self.raw_active(prof, d, "wireguard")
            ks6 = self.dummy("pvpn-killswitch-ipv6", "ipv6leakintrf0")
            self.later(self.step, lambda: (self.drop_active(ks), self.remove_device("pvpnksintrf0"),
                                           self.manager.setp(NM, PrimaryConnection=wifi_primary)))
        self.later(self.step * 3, second)

    def proton_down(self):
        for a in list(self.actives.values()):
            i = a.p[NM + ".Connection.Active"]["Id"]
            if i.startswith("ProtonVPN ") or i.startswith("pvpn-killswitch"):
                self.drop_active(a)
        for p in list(self.profiles.values()):
            if p.id.startswith("ProtonVPN "):
                self.remove_profile(p)
        for n in ("proton0", "ipv6leakintrf0", "pvpnksintrf0"):
            self.remove_device(n)

    def dummy(self, cid, iface):
        prof = self.profile_by_id(cid) or self.add_profile({"connection": {"id": cid, "uuid": str(uuidlib.uuid4()), "type": "dummy"}})
        d = self.add_device({"iface": iface, "type": 22, "state": 100})
        return self.raw_active(prof, d, "dummy")

    def raw_active(self, prof, dev, typ):
        path = NMP + "/ActiveConnection/%d" % self.nid("act")
        act = Active(path, {NM + ".Connection.Active": {
            "Connection": prof.path, "SpecificObject": "/", "Id": prof.id, "Uuid": prof.uuid, "Type": typ, "Devices": [dev.path],
            "State": 2, "Default": False, "Default6": False, "Vpn": False, "Ip4Config": "/", "Ip6Config": "/"}})
        act.cfg = {"fixed": True}
        self.actives[path] = act
        self.manager.setp(NM, ActiveConnections=[x.path for x in self.actives.values()])
        return act


class BluezManager(dbus.service.Object):
    @dbus.service.method("org.bluez.AgentManager1", in_signature="os", out_signature="", sender_keyword="sender")
    def RegisterAgent(self, path, cap, sender=None):
        WORLD.agent = (sender, str(path), str(cap))
        WORLD.log.append(("bt_register", str(path), str(cap)))

    @dbus.service.method("org.bluez.AgentManager1", in_signature="o", out_signature="")
    def UnregisterAgent(self, path):
        if WORLD.agent and WORLD.agent[1] == str(path):
            WORLD.agent = None
            WORLD.log.append(("bt_unregister", str(path)))
        else:
            raise dbus.DBusException("no such agent", name="org.bluez.Error.DoesNotExist")

    @dbus.service.method("org.bluez.AgentManager1", in_signature="o", out_signature="")
    def RequestDefaultAgent(self, path):
        if not WORLD.agent or WORLD.agent[1] != str(path):
            raise dbus.DBusException("not registered", name="org.bluez.Error.InvalidArguments")
        WORLD.log.append(("bt_default", str(path)))


class BzObj(Obj):
    """An org.bluez object (Adapter1 / Device1) with Properties; the ObjectManager at "/" lists them."""

    def on_set(self, iface, name, value):
        raise NmError("read-only property")


class BzManager(dbus.service.Object):
    """org.freedesktop.DBus.ObjectManager at "/" (BlueZ's own): GetManagedObjects + InterfacesAdded / Removed."""

    @dbus.service.method("org.freedesktop.DBus.ObjectManager", in_signature="", out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        out = {}
        for path, o in WORLD.bz.items():
            out[dbus.ObjectPath(path)] = dbus.Dictionary(
                {i: dbus.Dictionary({k: typed(SIG[(i, k)], v) for k, v in props.items()}, signature="sv") for i, props in o.p.items()},
                signature="sa{sv}")
        return dbus.Dictionary(out, signature="oa{sa{sv}}")

    @dbus.service.signal("org.freedesktop.DBus.ObjectManager", signature="oa{sa{sv}}")
    def InterfacesAdded(self, path, ifaces):
        pass

    @dbus.service.signal("org.freedesktop.DBus.ObjectManager", signature="oas")
    def InterfacesRemoved(self, path, ifaces):
        pass


def bz_adapter(path="/org/bluez/hci0", address="02:AE:00:00:00:2A", name="laptop", power_state="on"):
    o = BzObj(path, {"org.bluez.Adapter1": {"Address": address, "Name": name, "Alias": name, "Powered": power_state == "on",
                                            "PowerState": power_state, "Discovering": False, "Discoverable": False}})
    WORLD.bz[path] = o
    return o


def bz_device(adapter, address, name, paired=False, connected=False, rssi=None):
    path = adapter + "/dev_" + address.replace(":", "_")
    props = {"Address": address, "Name": name, "Alias": name, "Paired": paired, "Connected": connected}
    if rssi is not None:
        props["RSSI"] = int(rssi)
    o = BzObj(path, {"org.bluez.Device1": props})
    WORLD.bz[path] = o
    WORLD.bzman.InterfacesAdded(dbus.ObjectPath(path), dbus.Dictionary(
        {"org.bluez.Device1": dbus.Dictionary({k: typed(SIG[("org.bluez.Device1", k)], v) for k, v in props.items()}, signature="sv")},
        signature="sa{sv}"))
    return o


def bz_control(msg, answer):
    """bt_adapter {powered?, powerState?, discovering?, address?, name?}, bt_dev_add {address, name, paired?, connected?, rssi?},
    bt_dev {address, paired?, connected?, rssi? (null drops it)}, bt_dev_remove {address}, bt_adapter_remove."""
    op = msg["op"]
    ad = WORLD.bz.get("/org/bluez/hci0")
    if op == "bt_adapter":
        if ad is None:
            ad = bz_adapter()
            WORLD.bzman.InterfacesAdded(dbus.ObjectPath(ad.path), dbus.Dictionary(
                {"org.bluez.Adapter1": dbus.Dictionary({k: typed(SIG[("org.bluez.Adapter1", k)], v) for k, v in ad.p["org.bluez.Adapter1"].items()},
                                                       signature="sv")}, signature="sa{sv}"))
        kw = {}
        if "powerState" in msg:
            kw["PowerState"] = msg["powerState"]
            kw["Powered"] = msg["powerState"] == "on"
        for k, key in (("powered", "Powered"), ("discovering", "Discovering"), ("discoverable", "Discoverable"), ("address", "Address"),
                       ("name", "Name")):
            if k in msg:
                kw[key] = msg[k]
        ad.setp("org.bluez.Adapter1", **kw)
        return answer({"ok": True})
    if op == "bt_adapter_remove":
        for path in sorted([p for p in WORLD.bz if p.startswith("/org/bluez/hci0")], reverse=True):
            o = WORLD.bz.pop(path)
            WORLD.bzman.InterfacesRemoved(dbus.ObjectPath(path), dbus.Array(list(o.p), signature="s"))
            o.drop()
        return answer({"ok": True})
    if ad is None:
        return answer({"ok": False, "error": "no adapter"})
    path = ad.path + "/dev_" + str(msg.get("address", "")).replace(":", "_")
    if op == "bt_dev_add":
        bz_device(ad.path, msg["address"], msg.get("name", msg["address"]), bool(msg.get("paired")), bool(msg.get("connected")), msg.get("rssi"))
        return answer({"ok": True})
    d = WORLD.bz.get(path)
    if d is None:
        return answer({"ok": False, "error": "no such device"})
    if op == "bt_dev_remove":
        WORLD.bz.pop(path)
        WORLD.bzman.InterfacesRemoved(dbus.ObjectPath(path), dbus.Array(["org.bluez.Device1"], signature="s"))
        d.drop()
        return answer({"ok": True})
    kw = {}
    for k, key in (("paired", "Paired"), ("connected", "Connected")):
        if k in msg:
            kw[key] = bool(msg[k])
    if "rssi" in msg:
        if msg["rssi"] is None:     # BlueZ invalidates RSSI when discovery stops
            d.p["org.bluez.Device1"].pop("RSSI", None)
            d.PropertiesChanged("org.bluez.Device1", dbus.Dictionary({}, signature="sv"), dbus.Array(["RSSI"], signature="s"))
        else:
            kw["RSSI"] = int(msg["rssi"])
    d.setp("org.bluez.Device1", **kw)
    answer({"ok": True})


# --------------------------------------------------------------------------------------------------------------------------------
def state_dump():
    w = WORLD
    return {
        "devices": {i: {"state": d.p[NM + ".Device"]["State"], "reason": d.p[NM + ".Device"]["StateReason"][1],
                        "active": d.p[NM + ".Device"]["ActiveConnection"]} for i, d in w.devices.items()},
        "actives": [{"id": a.p[NM + ".Connection.Active"]["Id"], "uuid": a.p[NM + ".Connection.Active"]["Uuid"],
                     "state": a.p[NM + ".Connection.Active"]["State"]} for a in w.actives.values()],
        "profiles": [{"id": p.id, "uuid": p.uuid, "type": p.type, "psk": p.secrets.get(("802-11-wireless-security", "psk")),
                      "ifname": str(p.settings["connection"].get("interface-name", "") or ""),
                      "ipv4": p.settings.get("ipv4", {}).get("method"), "metered": p.settings["connection"].get("metered"),
                      "autoconnect": p.settings["connection"].get("autoconnect"),
                      "priority": p.settings["connection"].get("autoconnect-priority"),
                      "clonedMac": p.settings.get("802-11-wireless", {}).get("cloned-mac-address"),
                      "powersave": p.settings.get("802-11-wireless", {}).get("powersave"),
                      "ssid": p.ssid.decode("utf-8", "replace") if "802-11-wireless" in p.settings else None,
                      "band": p.settings.get("802-11-wireless", {}).get("band"),
                      "ipv4dns": p.settings.get("ipv4", {}).get("dns")}
                     for p in w.profiles.values()],
        "aps": sorted(w.aps), "eapPasswords": {p.id: p.secrets.get(("802-1x", "password")) for p in w.profiles.values() if ("802-1x", "password") in p.secrets},
        "hidden": {p.id: p.settings.get("802-11-wireless", {}).get("hidden") for p in w.profiles.values()},
        "eap": {p.id: {k: (list(v) if isinstance(v, (list, bytes)) else v) for k, v in p.settings["802-1x"].items() if k != "ca-cert"} for p in w.profiles.values() if "802-1x" in p.settings}, "agent": w.agent[1] if w.agent else None, "log": [list(x) for x in w.log[-60:]],
        "wirelessEnabled": w.manager.p[NM]["WirelessEnabled"], "primary": w.manager.p[NM]["PrimaryConnection"]}


def control(msg, answer):
    op = msg.get("op")
    w = WORLD
    if op == "state":
        return answer({"ok": True, "state": state_dump()})
    if op == "ap_add":
        a = dict(msg["ap"])
        ap = w.add_ap(a)
        w.s.setdefault("aps", []).append(a)
        return answer({"ok": ap is not None})
    if op == "ap_remove":
        w.remove_ap(msg["bssid"])
        w.s["aps"] = [a for a in w.s.get("aps", []) if a["bssid"].upper() != msg["bssid"].upper()]
        return answer({"ok": True})
    if op == "ap_strength":
        ap = w.aps.get(msg["bssid"].upper())
        if ap is None:
            return answer({"ok": False, "error": "no such ap"})
        ap.setp(NM + ".AccessPoint", Strength=int(msg["strength"]))
        return answer({"ok": True})
    if op == "set_carrier":
        d = w.devices.get(msg["iface"])
        if d is None:
            return answer({"ok": False, "error": "no such device"})
        on = bool(msg["on"])
        d.setp(NM + ".Device.Wired", Carrier=on, Speed=1000 if on else 0)
        w.s_dev(d, 30 if on else 20, 0)
        return answer({"ok": True})
    if op == "wifi_hw":
        w.manager.setp(NM, WirelessHardwareEnabled=bool(msg["on"]))
        return answer({"ok": True})
    if op == "dnsmasq":
        w.dnsmasq = bool(msg["on"])
        return answer({"ok": True})
    if op == "nm_name":     # NetworkManager leaves the bus (a restart, a suspend) and comes back
        if msg["on"]:
            BUS.request_name(NM, dbus.bus.NAME_FLAG_DO_NOT_QUEUE)
        else:
            BUS.release_name(NM)
        return answer({"ok": True})
    if op == "hang":
        w.hang[msg["method"]] = bool(msg["on"])
        return answer({"ok": True})
    if op == "fail_next":
        w.fail_next = {"outcome": "fail", "reason": int(msg.get("reason", 5)), "needAuth": bool(msg.get("needAuth", False))}
        return answer({"ok": True})
    if op == "proton_up":
        w.proton_up(msg.get("name", "NL#1"), msg.get("device", "proton0"))
        return answer({"ok": True})
    if op == "proton_down":
        w.proton_down()
        return answer({"ok": True})
    if op == "profile_bind":      # a profile bound to an interface name (`connection.interface-name`), as nmcli's own profiles are
        p = next((x for x in w.profiles.values() if x.uuid == msg.get("uuid") or x.id == msg.get("id")), None)
        if p is None:
            return answer({"ok": False, "error": "no such profile"})
        if msg.get("ifname"):
            p.settings["connection"]["interface-name"] = str(msg["ifname"])
        else:
            p.settings["connection"].pop("interface-name", None)
        p.Updated()
        return answer({"ok": True, "uuid": p.uuid})
    if op == "profile_remove":
        p = w.profile_by_uuid(msg["uuid"])
        if p is None:
            return answer({"ok": False, "error": "no such profile"})
        w.remove_profile(p)
        return answer({"ok": True})
    if op in ("bt_adapter", "bt_adapter_remove", "bt_dev_add", "bt_dev", "bt_dev_remove"):
        return bz_control(msg, answer)
    if op in ("bt_request", "bt_cancel"):
        if not w.agent:
            return answer({"ok": False, "error": "no agent registered"})
        sender, path, cap = w.agent
        dev = "/org/bluez/hci0/dev_" + msg.get("device", "AA:BB:CC:DD:EE:FF").replace(":", "_")
        kind = msg.get("kind", "confirm")
        proxy = BUS.get_object(sender, path, introspect=False)

        def ok(*r):
            answer({"ok": True, "value": plain(r[0]) if r else None})

        def err(e):
            answer({"ok": False, "error": e.get_dbus_name(), "message": e.get_dbus_message()})
        kw = dict(dbus_interface="org.bluez.Agent1", reply_handler=ok, error_handler=err, timeout=90)
        if op == "bt_cancel":
            return proxy.Cancel(dbus_interface="org.bluez.Agent1", reply_handler=lambda: answer({"ok": True}), error_handler=err)
        if kind == "confirm":
            proxy.RequestConfirmation(dbus.ObjectPath(dev), dbus.UInt32(int(msg.get("passkey", 123456))), **kw)
        elif kind == "pin":
            proxy.RequestPinCode(dbus.ObjectPath(dev), **kw)
        elif kind == "passkey":
            proxy.RequestPasskey(dbus.ObjectPath(dev), **kw)
        elif kind == "authorize":
            proxy.RequestAuthorization(dbus.ObjectPath(dev), **kw)
        elif kind == "display":
            proxy.DisplayPasskey(dbus.ObjectPath(dev), dbus.UInt32(int(msg.get("passkey", 123456))), dbus.UInt16(0), **kw)
        else:
            answer({"ok": False, "error": "bad kind"})
        return
    if op == "quit":
        answer({"ok": True})
        GLib.idle_add(lambda: LOOP.quit())
        return
    answer({"ok": False, "error": "unknown op"})


LOOP = None


def serve(d, scen_path):
    global BUS, WORLD, LOOP
    os.makedirs(d, exist_ok=True)
    sock = os.path.join(d, "bus.sock")
    conf = os.path.join(d, "bus.conf")
    with open(conf, "w") as f:
        f.write("""<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>custom</type>
  <listen>unix:path=%s</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
    <allow user="*"/>
  </policy>
</busconfig>
""" % sock)
    r, wfd = os.pipe()
    daemon = subprocess.Popen(["dbus-daemon", "--config-file=" + conf, "--nofork", "--print-address=%d" % wfd], pass_fds=(wfd,),
                              stdin=subprocess.DEVNULL, start_new_session=True)
    os.close(wfd)
    addr = os.read(r, 4096).decode().strip()
    os.close(r)
    if not addr:
        sys.exit("dbus-daemon did not start")
    with open(os.path.join(d, "bus.addr"), "w") as f:
        f.write(addr + "\n")
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    BUS = dbus.bus.BusConnection(addr)
    with open(scen_path or DEFAULT_SCENARIO) as f:
        scen = json.load(f)
    WORLD = World(scen)
    BluezManager(BUS, "/org/bluez")
    WORLD.bzman = BzManager(BUS, "/")
    if scen.get("bluez", True):
        bz_adapter(power_state=scen.get("bluezPowerState", "on"))
    NAMES.append(dbus.service.BusName(NM, BUS, do_not_queue=True))      # held: a dropped BusName gives the name back
    NAMES.append(dbus.service.BusName("org.bluez", BUS, do_not_queue=True))
    # the control socket
    cpath = os.path.join(d, "ctl.sock")
    try:
        os.unlink(cpath)
    except FileNotFoundError:
        pass
    ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    ls.bind(cpath)
    ls.listen(8)
    ls.setblocking(False)
    bufs = {}

    def accept(fd, cond):
        c, _ = ls.accept()
        c.setblocking(False)
        bufs[c.fileno()] = (c, b"")
        GLib.io_add_watch(c.fileno(), GLib.IO_IN | GLib.IO_HUP, readable)
        return True

    def readable(fd, cond):
        c, b = bufs.get(fd, (None, b""))
        if c is None:
            return False
        try:
            data = c.recv(65536)
        except BlockingIOError:
            return True
        if not data:
            bufs.pop(fd, None)
            c.close()
            return False
        b += data
        while b"\n" in b:
            line, b = b.split(b"\n", 1)

            def answer(obj, c=c):
                try:
                    c.sendall((json.dumps(obj) + "\n").encode())
                except Exception:
                    pass
            try:
                control(json.loads(line), answer)
            except Exception as e:
                answer({"ok": False, "error": "%s: %s" % (type(e).__name__, e)})
        bufs[fd] = (c, b)
        return True
    GLib.io_add_watch(ls.fileno(), GLib.IO_IN, accept)
    LOOP = GLib.MainLoop()

    def stop(*_):
        LOOP.quit()
        return False
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, stop)
    GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGINT, stop)
    print("READY " + addr, flush=True)
    try:
        LOOP.run()
    finally:
        try:
            daemon.terminate()
            daemon.wait(3)
        except Exception:
            daemon.kill()


def ctl(d, text):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(120)
    s.connect(os.path.join(d, "ctl.sock"))
    s.sendall(text.encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        x = s.recv(65536)
        if not x:
            break
        buf += x
    return buf.decode().strip()


def main():
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    mode = a.pop(0)
    d, scen, rest = None, None, []
    while a:
        x = a.pop(0)
        if x == "--dir":
            d = a.pop(0)
        elif x == "--scenario":
            scen = a.pop(0)
        else:
            rest.append(x)
    if mode == "serve":
        serve(d, scen)
    elif mode == "ctl":
        print(ctl(d, rest[0]))
    elif mode == "addr":
        print(open(os.path.join(d, "bus.addr")).read().strip())
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
