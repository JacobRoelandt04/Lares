"""The USB bus, for phones: which ones are on the cable, and the plug / unplug events.

Reading is one code path: `<sys root>/bus/usb/devices/` (the real /sys, or LARES_BRIDGE_SYS's fake tree). Events come from GUdev on
the real bus and from a Gio file monitor on the fake one. A device counts as a phone when it has an adb interface (class ff,
subclass 42, protocol 01), an MTP / PTP interface (class 06, or ff/ff/00 whose interface string says MTP) or a vendor id of a
phone maker.
"""
import os

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio  # noqa: E402

ANDROID_VENDORS = {"18d1", "04e8", "22b8", "2717", "12d1", "0bb4", "0fce", "2a70", "2d95", "22d9", "19d2", "0b05", "05c6", "1004",
                   "0e8d", "2916", "1bbb", "2e04", "1782"}


def _read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().strip()
    except OSError:
        return default


def devices_dir(sys_root):
    return os.path.join(sys_root or "/sys", "bus", "usb", "devices")


def scan(sys_root=""):
    """[{serial, vendor, product, name, manufacturer, adbIface, mtpIface, bus}] for every phone on the bus."""
    base = devices_dir(sys_root)
    try:
        names = sorted(os.listdir(base))
    except OSError:
        return []
    out = []
    for n in names:
        d = os.path.join(base, n)
        vid = _read(os.path.join(d, "idVendor")).lower()
        if ":" in n or not vid:
            continue
        adb = mtp = False
        for i in names:
            if not i.startswith(n + ":"):
                continue
            ip = os.path.join(base, i)
            cls = _read(os.path.join(ip, "bInterfaceClass")).lower()
            sub = _read(os.path.join(ip, "bInterfaceSubClass")).lower()
            pro = _read(os.path.join(ip, "bInterfaceProtocol")).lower()
            label = _read(os.path.join(ip, "interface")).lower()
            if (cls, sub, pro) == ("ff", "42", "01"):
                adb = True
            if cls == "06" or (cls == "ff" and "mtp" in label):
                mtp = True
        if not (adb or mtp or vid in ANDROID_VENDORS):
            continue
        pid = _read(os.path.join(d, "idProduct")).lower()
        bus = "%s-%s" % (_read(os.path.join(d, "busnum")), _read(os.path.join(d, "devnum")))
        serial = _read(os.path.join(d, "serial")) or "%s:%s:%s" % (vid, pid, bus)
        product = _read(os.path.join(d, "product"))
        out.append({"serial": serial, "vendor": vid, "product": pid, "name": product,
                    "manufacturer": _read(os.path.join(d, "manufacturer")), "adbIface": adb, "mtpIface": mtp, "bus": n})
    return out


class Watcher:
    """on_change() when the bus changed (the owner rescans)."""

    def __init__(self, sys_root, on_change):
        self.sys_root = sys_root
        self.on_change = on_change
        self.client = None
        self.monitor = None

    def start(self):
        if self.sys_root:
            f = Gio.File.new_for_path(devices_dir(self.sys_root))
            self.monitor = f.monitor_directory(Gio.FileMonitorFlags.NONE, None)
            self.monitor.connect("changed", lambda *a: self.on_change())
            return True
        try:
            gi.require_version("GUdev", "1.0")
            from gi.repository import GUdev
        except (ValueError, ImportError):
            return False
        self.client = GUdev.Client(subsystems=["usb"])
        self.client.connect("uevent", lambda c, action, dev: self.on_change() if action in ("add", "remove", "bind", "unbind") else None)
        return True

    def stop(self):
        if self.monitor:
            self.monitor.cancel()
        self.monitor = self.client = None
