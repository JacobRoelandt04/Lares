"""One device from the three things that know it: KDE Connect (an id), adb (a serial, over USB or TCP) and the USB bus (a serial).

Pure. The rules, in the order they are tried -- an earlier link is never undone by a later one:
  1. a USB device and the adb USB transport of the same serial are one;
  2. a stored link (state.links: <kdc id> -> <usb serial>) wins;
  3. an adb TCP transport whose address is one of the phone's KDE Connect addresses;
  4. a name both sides have exactly once (KDE Connect's name against the adb model / the USB product);
  5. an adb TCP transport and an adb USB transport that report the same product / model / device (once each);
  3c. an adb transport adb made by itself from mDNS (Wireless debugging: `adb-<serialno>-..._adb-tls-connect._tcp`) whose serialno
     a stored link or a cable names;
  6. an adb USB transport whose phone, asked over the cable (`ident`: parse.IDENT_SCRIPT), reports an address KDE Connect
     reaches exactly one phone on, or the device name exactly one KDE Connect phone has.
Computers KDE Connect knows (type desktop / laptop) are not the bridge's: they are left out, from the devices and from pairing.
A group holds at most one KDE Connect id and one USB serial. No address is ever kept: the links this finds are
KDE Connect id -> USB serial (`links` in the result), and a serial that is an address is never one.
"""
import re

from . import parse
from . import state as st

SKIN_NAMES = [(re.compile(r"^(REDMAGIC 10|NX789)", re.I), "redmagic-10s-pro-moonlight")]
GENERIC = "generic"
COMPUTERS = ("desktop", "laptop")


def norm(s):
    return re.sub(r"[^a-z0-9]", "", str(s).lower())


def skin_of(cfg, key, name):
    devs = cfg.get("devices", {})
    for k in (key, name):
        e = devs.get(k)
        if isinstance(e, dict) and e.get("skin"):
            return e["skin"]
    for rx, skin in SKIN_NAMES:
        if rx.search(str(name)):
            return skin
    return GENERIC


def hidden(cfg, key, name):
    devs = cfg.get("devices", {})
    return any(isinstance(devs.get(k), dict) and devs[k].get("hidden") is True for k in (key, name))


class _Groups:
    def __init__(self):
        self.parent = {}

    def add(self, n):
        self.parent.setdefault(n, n)

    def find(self, n):
        while self.parent[n] != n:
            self.parent[n] = self.parent[self.parent[n]]
            n = self.parent[n]
        return n

    def members(self, root):
        return [n for n in self.parent if self.find(n) == root]

    def union(self, a, b):
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return True
        ma, mb = self.members(ra), self.members(rb)
        if sum(n.startswith("kdc:") for n in ma + mb) > 1:
            return False
        serials = {n.split(":", 1)[1] for n in ma + mb if n.startswith("usb:")}
        serials |= {n.split(":", 1)[1] for n in ma + mb if n.startswith("adbusb:")}
        if len(serials) > 1:
            return False
        self.parent[ra] = rb
        return True


def _adb_node(t):
    return ("adbusb:" if t["transport"] == "usb" else "adbtcp:") + t["serial"]


def _name_candidates(adbs, usb, ident=None):
    out = set()
    for t in adbs:
        n = ((ident or {}).get(t["serial"]) or {}).get("name")
        if n:
            out.add(norm(n))
    for t in adbs:
        if t.get("model"):
            out.add(norm(t["model"].replace("_", " ")))
    if usb:
        for k in ("product", "name"):
            if usb.get(k):
                out.add(norm(usb[k]))
        if usb.get("manufacturer") and usb.get("name"):
            out.add(norm(usb["manufacturer"] + usb["name"]))
    out.discard("")
    return out


def merge(facts, state, cfg, now):
    """-> {devices: [device without mounts / can / facts], pairing: [...], links: {<kdc id>: <serial>}, present: [key]}"""
    kdc = {i: d for i, d in facts.get("kdc", {}).items()
           if (d.get("paired") or d.get("reachable")) and d.get("type", "phone") not in COMPUTERS}
    ident = facts.get("ident") or {}
    adbs = {t["serial"]: t for t in facts.get("adb", [])}
    usbs = {u["serial"]: u for u in facts.get("usb", [])}
    g = _Groups()
    for i in kdc:
        g.add("kdc:" + i)
    for t in adbs.values():
        g.add(_adb_node(t))
    for s in usbs:
        g.add("usb:" + s)

    # 1. the same serial on the bus and in adb
    for s in usbs:
        if s in adbs and adbs[s]["transport"] == "usb":
            g.union("usb:" + s, "adbusb:" + s)
    # 2. stored links
    for i, s in state.get("links", {}).items():
        if i in kdc:
            for n in ("usb:" + s, "adbusb:" + s):
                if n in g.parent:
                    g.union("kdc:" + i, n)
    # 3. the phone's Wi-Fi address
    for t in adbs.values():
        if t["transport"] != "tcp" or not t.get("address"):
            continue
        ip = t["address"].rpartition(":")[0]
        owners = [i for i, d in kdc.items() if ip in (d.get("addresses") or [])]
        if len(owners) == 1:
            g.union("kdc:" + owners[0], _adb_node(t))
    # 3c. Wireless debugging's own transport, named after the phone's serialno
    for t in adbs.values():
        sn = parse.mdns_serial(t["serial"])
        if not sn:
            continue
        if "usb:" + sn in g.parent:
            g.union("usb:" + sn, _adb_node(t))
        owners = [i for i, s in state.get("links", {}).items() if s == sn and i in kdc]
        if len(owners) == 1:
            g.union("kdc:" + owners[0], _adb_node(t))
    # 3b. the addresses the phone itself reports over the cable
    for t in adbs.values():
        mine = set(((ident.get(t["serial"]) or {}).get("addresses")) or [])
        if t["transport"] != "usb" or not mine:
            continue
        owners = [i for i, d in kdc.items() if mine & set(d.get("addresses") or [])]
        if len(owners) == 1:
            g.union("kdc:" + owners[0], _adb_node(t))
    # 4. a name each side has exactly once
    def roots_now():
        out = {}
        for n in g.parent:
            out.setdefault(g.find(n), []).append(n)
        return out

    def group_info(members):
        a = [adbs[n.split(":", 1)[1]] for n in members if n.startswith("adb")]
        u = next((usbs[n.split(":", 1)[1]] for n in members if n.startswith("usb:")), None)
        return a, u

    for i, d in kdc.items():
        if not d.get("name"):
            continue
        roots = roots_now()
        if len(roots[g.find("kdc:" + i)]) > 1:
            continue
        same_kdc = [j for j, e in kdc.items() if norm(e.get("name", "")) == norm(d["name"])]
        cands = [ms for ms in roots.values()
                 if not any(n.startswith("kdc:") for n in ms) and norm(d["name"]) in _name_candidates(*group_info(ms), ident)]
        if len(cands) == 1 and len(same_kdc) == 1:
            g.union("kdc:" + i, cands[0][0])
    # 5. the same phone over both transports
    seen = {}
    for t in adbs.values():
        trip = (t.get("product"), t.get("model"), t.get("device"))
        if all(trip):
            seen.setdefault(trip, []).append(t)
    for ts in seen.values():
        usb_t = [t for t in ts if t["transport"] == "usb"]
        tcp_t = [t for t in ts if t["transport"] == "tcp"]
        if len(usb_t) == 1 and tcp_t:
            for t in tcp_t:
                g.union(_adb_node(usb_t[0]), _adb_node(t))

    devices, pairing, links = [], [], {}
    for members in roots_now().values():
        kid = next((n[4:] for n in members if n.startswith("kdc:")), None)
        k = kdc.get(kid) if kid else None
        a, u = group_info(members)
        usb_serial = u["serial"] if u else next((t["serial"] for t in a if t["transport"] == "usb"), None)
        if not a and not u and k and not k.get("paired"):
            continue
        prim = None
        for pick in (lambda t: t["transport"] == "usb" and t["state"] == "device",
                     lambda t: t["state"] == "device", lambda t: t["transport"] == "usb", lambda t: True):
            prim = next((t for t in a if pick(t)), None)
            if prim:
                break
        key = "kdc:" + kid if kid else "adb:" + (usb_serial or (prim["serial"] if prim else ""))
        idn = next(((ident.get(t["serial"]) or {}).get("name") for t in a if (ident.get(t["serial"]) or {}).get("name")), "")
        name = (k or {}).get("name") or idn or (u or {}).get("name") or (prim or {}).get("model", "").replace("_", " ") \
            or (usb_serial or (prim or {}).get("serial", ""))
        if hidden(cfg, key, name):
            continue
        usb_on = bool(u) or any(t["transport"] == "usb" for t in a)
        wifi_on = bool(k and k.get("reachable")) or any(t["transport"] == "tcp" for t in a)
        present = bool(k and k.get("reachable")) or usb_on or bool(a)
        if kid and usb_serial and not st.looks_like_address(usb_serial):
            links[kid] = usb_serial
        dev = {
            "key": key, "name": name, "type": (k or {}).get("type") or "phone", "skin": skin_of(cfg, key, name),
            "present": present, "link": "both" if usb_on and wifi_on else "usb" if usb_on else "wifi" if wifi_on else "none",
            "lastSeen": int(now) if present else int(state.get("lastSeen", {}).get(key, 0) or 0),
            "kdc": None if not k else {
                "id": k["id"], "paired": bool(k.get("paired")), "pairState": int(k.get("pairState", 0)),
                "reachable": bool(k.get("reachable")), "links": list(k.get("links") or []),
                "addresses": list(k.get("addresses") or []), "plugins": list(k.get("plugins") or []),
                "verificationKey": k.get("verificationKey", ""), "pairRequested": bool(k.get("pairRequested")),
                "pairRequestedByPeer": bool(k.get("pairRequestedByPeer"))},
            "battery": (k or {}).get("battery"), "cell": (k or {}).get("cell"),
            "usb": None if not u else {"serial": u["serial"], "vendor": u.get("vendor", ""), "product": u.get("product", ""),
                                       "adbIface": bool(u.get("adbIface")), "mtpIface": bool(u.get("mtpIface"))},
            "adb": None if not prim else {"serial": prim["serial"], "transport": prim["transport"], "state": prim["state"],
                                          "address": prim.get("address", "")},
            "prefs": st.prefs_of(state, key),
            "pin": st.pin_of(state, key),
            "_adbs": a, "_mount": (k or {}).get("mountPoint", ""), "_storage": (k or {}).get("storage", ""),
            "_linked": usb_serial or (state.get("links", {}).get(kid, "") if kid else ""),
        }
        devices.append(dev)
    for i, d in kdc.items():
        if d.get("reachable") and not d.get("paired"):
            pairing.append({"key": "kdc:" + i, "name": d.get("name", ""), "type": d.get("type", "phone"),
                            "byPeer": bool(d.get("pairRequestedByPeer")), "verificationKey": d.get("verificationKey", "")})
    devices.sort(key=lambda d: (0 if d["kdc"] and d["kdc"]["paired"] else 1, -d["lastSeen"], d["key"]))
    pairing.sort(key=lambda p: p["key"])
    return {"devices": devices, "pairing": pairing, "links": links, "present": [d["key"] for d in devices if d["present"]]}


def seen_update(state, prev_present, present, now):
    """The lastSeen table after a change in who is present: a device that arrives or leaves gets `now`. -> (table, changed)"""
    table = dict(state.get("lastSeen", {}))
    changed = False
    for k in set(prev_present) ^ set(present):
        table[k] = int(now)
        changed = True
    return table, changed


def current_of(state, devices):
    keys = [d["key"] for d in devices]
    cur = state.get("current", "")
    return cur if cur in keys else (keys[0] if keys else "")
