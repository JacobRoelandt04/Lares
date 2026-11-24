#!/usr/bin/env python3
"""A fake /sys USB tree for LARES_BRIDGE_SYS (bus/usb/devices/<name>/... as the kernel lays it out).

    make_sysfs.py <root> add <name> <vid> <pid> <serial> <product> <iface>...     iface: adb | mtp | ptp | hid
    make_sysfs.py <root> remove <name>

A device appears in ONE rename (built beside the directory first), the way a plug does, so a watcher sees it whole.
"""
import os
import shutil
import sys

IFACES = {"adb": ("ff", "42", "01", "ADB Interface"), "mtp": ("ff", "ff", "00", "MTP"), "ptp": ("06", "01", "01", "PTP"),
          "hid": ("03", "01", "02", "")}


def put(path, text):
    with open(path, "w") as f:
        f.write(text + "\n")


def add(root, name, vid, pid, serial, product, ifaces):
    base = os.path.join(root, "bus", "usb", "devices")
    os.makedirs(base, exist_ok=True)
    stage = os.path.join(root, ".stage", name)
    shutil.rmtree(stage, ignore_errors=True)
    os.makedirs(stage)
    put(os.path.join(stage, "idVendor"), vid)
    put(os.path.join(stage, "idProduct"), pid)
    if serial:
        put(os.path.join(stage, "serial"), serial)
    put(os.path.join(stage, "product"), product)
    put(os.path.join(stage, "manufacturer"), "Test")
    put(os.path.join(stage, "busnum"), "1")
    put(os.path.join(stage, "devnum"), "4")
    for i, kind in enumerate(ifaces):
        c, s, p, label = IFACES[kind]
        d = os.path.join(stage, "%s:1.%d" % (name, i))
        os.makedirs(d)
        put(os.path.join(d, "bInterfaceClass"), c)
        put(os.path.join(d, "bInterfaceSubClass"), s)
        put(os.path.join(d, "bInterfaceProtocol"), p)
        if label:
            put(os.path.join(d, "interface"), label)
    # the real tree lists interfaces beside their device: link them up
    final = os.path.join(base, name)
    os.rename(stage, final)
    for i in range(len(ifaces)):
        n = "%s:1.%d" % (name, i)
        link = os.path.join(base, n)
        if not os.path.exists(link):
            os.symlink(os.path.join(name, n), link)


def remove(root, name):
    base = os.path.join(root, "bus", "usb", "devices")
    for n in sorted(os.listdir(base)):
        if n == name or n.startswith(name + ":"):
            p = os.path.join(base, n)
            if os.path.islink(p):
                os.unlink(p)
    shutil.rmtree(os.path.join(base, name), ignore_errors=True)


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) >= 7 and a[1] == "add":
        add(a[0], a[2], a[3], a[4], a[5], a[6], a[7:])
    elif len(a) == 3 and a[1] == "remove":
        remove(a[0], a[2])
    else:
        sys.exit(__doc__)
