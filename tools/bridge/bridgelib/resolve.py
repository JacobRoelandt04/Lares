"""The transport ladder: how a device is reached, as an ordered list of steps (a pure function of what is known).

  usb      the device's USB serial with adb in state `device`
  tcp      an adb TCP transport of that device already up
  mdns     `adb mdns services` names it (the instance carries its serial, or the address is one KDE Connect reports)
  connect  KDE Connect's addresses with the armed port, tried with `adb connect`

No address is ever written to a file: the addresses here come from the live KDE Connect object and the mDNS answer.
"""


def ladder(dev, port, mdns=()):
    k = dev.get("kdc") or {}
    adbs = dev.get("_adbs") or ([dev["adb"]] if dev.get("adb") else [])
    usb = [t for t in adbs if t["transport"] == "usb" and t["state"] == "device"]
    tcp = [t for t in adbs if t["transport"] == "tcp" and t["state"] == "device"]
    ups = [{"step": "usb", "serial": t["serial"]} for t in usb]
    tcps = [{"step": "tcp", "serial": t["serial"]} for t in tcp]
    steps = []
    steps += ups + tcps
    serials = {t["serial"] for t in adbs} | ({dev["usb"]["serial"]} if dev.get("usb") else set()) | ({dev["_linked"]} if dev.get("_linked") else set())
    addrs = list(k.get("addresses") or [])
    seen = set()
    for m in mdns:
        a = "%s:%d" % (m["ip"], m["port"])
        if (m["ip"] in addrs or any(s and s in m["instance"] for s in serials)) and a not in seen:
            seen.add(a)
            steps.append({"step": "mdns", "address": a})
    for ip in addrs:
        a = "%s:%d" % (ip, port)
        if a not in seen:
            seen.add(a)
            steps.append({"step": "connect", "address": a})
    return steps
