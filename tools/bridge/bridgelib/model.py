"""The watch line from the facts: one function shared by `watch` (facts kept current by events) and the one-shots (facts gathered once).

The facts (`World`) are plain data; building the line asks nothing of the machine except two `stat`s (a mount's staleness is
read by the caller and arrives as `stale`).
"""
import os
import time

from . import caps, doctor, jobs, merge, mounts, state as st, usb as usblib

SCHEMA = 1
FIGURES = ("done", "rate", "file", "name", "files", "total")


class World:
    def __init__(self, paths, cfg):
        self.paths = paths
        self.cfg = cfg
        self.state = st.load_state(paths)
        self.kdc_state = "down"          # running | down | missing
        self.kdc = {}                    # id -> record (kdc.read_device)
        self.adb = []                    # parse.parse_devices_l
        self.adb_up = False
        self.usb = []
        self.wifipair = None             # wifipair.json: a Wireless debugging pairing in progress or just ended
        self.ident = {}                  # adb serial -> parse.parse_ident (the watcher asks the phone over the cable; one-shots leave it empty)
        self.mounts = []
        self.stale = set()
        self.jobs = []
        self.mine = {}
        self.tries = {}                  # key -> action -> {reason, hint, at}   (the watcher's memory; one-shots leave it empty)
        self.changed_at = {}             # key -> when its links last changed
        self.have = {}
        self.usb_mount_ok = True
        self.now = time.time()


def gather_local(w):
    """Everything that is read from the machine without a bus: USB, mounts, jobs, files."""
    p = w.paths
    w.usb = usblib.scan(p.sys_root)
    w.mounts = mounts.read(p.mountinfo)
    w.mine = mounts.load_mine(p)
    w.jobs = jobs.read_all(p)
    w.wifipair = read_wifipair(p)
    w.have = doctor.have()
    w.usb_mount_ok = doctor.usb_mount_ok(p, w.cfg)
    w.stale = stale_points(w)


def read_wifipair(paths):
    """The pairing's record as the line carries it (`wifiPair`), or None; a record older than ten minutes is gone."""
    r = st.read_json(paths.wifipair, {})
    if not r.get("name") or time.time() - float(r.get("at", 0) or 0) > 600:
        return None
    return {k: r.get(k, "") for k in ("key", "name", "state", "reason", "png")}


def points_of_interest(w):
    pts = {w.paths.expand(w.cfg["files"]["usbMount"])}
    pts |= {d.get("mountPoint") for d in w.kdc.values() if d.get("mountPoint")}
    pts |= set(w.mine)
    return {x for x in pts if x}


def stale_points(w):
    here = {m["point"] for m in w.mounts}
    return {pt for pt in points_of_interest(w) if pt in here and mounts.is_stale(pt, w.paths.enotconn)}


def env_of(w):
    return {"kdeconnect": w.kdc_state, "adbServer": "up" if w.adb_up else "down", "have": w.have}


def _job_running(w, key, kind):
    return any(r["device"] == key and r["kind"] == kind and r["phase"] not in jobs.ENDED for r in w.jobs)


def _mounts_of(w, dev):
    p = w.paths
    key = dev["key"]
    upoint = p.expand(w.cfg["files"]["usbMount"])
    mine = w.mine.get(upoint, {})
    relevant = bool(dev["usb"]) or mine.get("device") == key
    ust = mounts.state_of(w.mounts, upoint, w.stale, _job_running(w, key, "mount")) if relevant else "unmounted"
    out = {"usb": {"point": upoint, "state": ust, "mine": bool(mine) and mine.get("device") == key}}
    k = dev["kdc"]
    wpoint = dev["_mount"] or (os.path.join(p.runtime_base, k["id"]) if k else "")
    wst = mounts.state_of(w.mounts, wpoint, w.stale, False) if wpoint else "unmounted"
    storage = dev.get("_storage") or ""
    out["wifi"] = {"point": wpoint, "state": wst, "mine": bool(wpoint) and wpoint in w.mine,
                   "open": storage if storage and wpoint and storage.startswith(wpoint.rstrip("/") + "/") else wpoint}
    out["usb"]["open"] = out["usb"]["point"]
    return out


def link_sig(dev):
    k = dev["kdc"] or {}
    a = dev["adb"] or {}
    return (bool(k.get("reachable")), tuple(k.get("links") or ()), (dev["usb"] or {}).get("serial"), a.get("serial"),
            a.get("state"), dev["link"])


def build(w):
    """-> the watch line (without `serial`), device records keeping their `_` internals for the caller."""
    m = merge.merge({"kdc": w.kdc, "adb": w.adb, "usb": w.usb, "ident": w.ident}, w.state, w.cfg, w.now)
    env = dict(env_of(w), usbMountDirOk=w.usb_mount_ok)
    devices = []
    for d in m["devices"]:
        d["mounts"] = _mounts_of(w, d)
        f = w.state.get("facts", {}).get(d["key"])
        d["facts"] = f if isinstance(f, dict) else None
        valid = {a: t for a, t in w.tries.get(d["key"], {}).items() if t.get("at", 0) >= w.changed_at.get(d["key"], 0)}
        d["can"] = caps.can_table(d, env, w.cfg, valid)
        devices.append(d)
    line = {"v": SCHEMA, "env": {"kdeconnect": w.kdc_state, "adbServer": "up" if w.adb_up else "down", "have": w.have},
            "current": merge.current_of(w.state, devices), "devices": devices, "pairing": m["pairing"],
            "jobs": [jobs.public(r) for r in w.jobs], "wifiPair": w.wifipair}
    return line, m


def public(line, serial):
    """The line as it is printed: `serial` after `v`, every `_` field gone."""
    out = {"v": line["v"], "serial": serial}
    for k, v in line.items():
        if k == "v":
            continue
        if k == "devices":
            v = [{a: b for a, b in d.items() if not a.startswith("_")} for d in v]
        out[k] = v
    return out


def without_figures(line):
    out = dict(line)
    out["jobs"] = [{k: v for k, v in j.items() if k not in FIGURES} for j in line["jobs"]]
    return out
