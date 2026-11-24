#!/usr/bin/env python3
"""The offline cases of the bridge tool's logic: nothing is started, no bus, no phone, nothing of the user's read or written.

    python3 tools/dev/bridge_cases.py              BRIDGE_CASES RESULT PASS | FAIL
    ARM=<name> python3 tools/dev/bridge_cases.py   one fault in a COPY of tools/bridge; the group named must fail
    ARM=all ...                                    every arm in turn: BRIDGE_CASES ARMS RESULT PASS | FAIL

Groups: parse (every parser on tools/dev/fixtures/bridge/), merge, resolve (the transport ladder), argv, caps, config, state.

ARMs (group that must fail):
  storedip    (resolve)  the resolver also tries an address it remembered
  nousbfirst  (resolve)  a TCP transport already up is preferred to the cable
  weakmerge   (merge)    two phones with one name are merged
  noident     (merge)    the addresses the phone reports over the cable join nothing (the user's phone came up twice, 2026-11-18)
  computers   (merge)    a computer KDE Connect knows is offered as a phone
  nomdnsjoin  (merge)    Wireless debugging's own transport (named after the serialno) stays a stranger
  nopinneeded (caps)     unlock is offered with no PIN kept
  usbnone     (parse)    a phone's facts with no `screen_unlocked_functions=` line do not read "none"
  calmmtp     (argv)     `usbcalm off` still sends `mtp`
  nodpclamp   (config)   cast.desktopMinDp is not clamped from below
  nomtpask    (caps)     USB files are refused with adb on the cable and no MTP interface yet (the mount asks the phone for it)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIX = os.path.join(ROOT, "tools", "dev", "fixtures", "bridge")
ARMS = {
    "storedip": ("resolve", "bridgelib/resolve.py",
                 '    addrs = list(k.get("addresses") or [])',
                 '    addrs = list(k.get("addresses") or []) + list(dev.get("lastAddress") or [])'),
    "nousbfirst": ("resolve", "bridgelib/resolve.py", '    steps += ups + tcps', '    steps += tcps + ups'),
    "weakmerge": ("merge", "bridgelib/merge.py",
                  '        if len(cands) == 1 and len(same_kdc) == 1:', '        if cands:'),
    "noident": ("merge", "bridgelib/merge.py",
                '        if len(owners) == 1:\n            g.union("kdc:" + owners[0], _adb_node(t))\n    # 4.',
                '        if False:\n            g.union("kdc:" + owners[0], _adb_node(t))\n    # 4.'),
    "computers": ("merge", "bridgelib/merge.py", 'COMPUTERS = ("desktop", "laptop")', 'COMPUTERS = ()'),
    "nopinneeded": ("caps", "bridgelib/caps.py", '    elif pin == "none":', "    elif False:"),
    "usbnone": ("parse", "bridgelib/parse.py", '    return v if v and v != "none" else "none"', '    return v'),
    "calmmtp": ("argv", "bridgelib/argv.py", '*(["mtp"] if on else [])', '*["mtp"]'),
    "nodpclamp": ("config", "bridgelib/state.py", 'ca.get("desktopMinDp"), 320, 240, 1200', 'ca.get("desktopMinDp"), 320, 0, 1200'),
    "nomtpask": ("caps", "bridgelib/caps.py", '    elif not u.get("mtpIface") and not u.get("adbIface"):', '    elif not u.get("mtpIface"):'),
    "nomdnsjoin": ("merge", "bridgelib/merge.py", '        sn = parse.mdns_serial(t["serial"])\n', '        sn = ""\n'),
}


def arm_all():
    rc = 0
    for name, (group, _, _, _) in ARMS.items():
        p = subprocess.run([sys.executable, os.path.abspath(__file__)], env=dict(os.environ, ARM=name), capture_output=True, text=True)
        out = p.stdout + p.stderr
        if "anchor is gone" in out:
            print("ARM %s: NOT PROVEN (its anchor is gone)" % name)
            rc = 1
        elif "BC FAIL %s " % group in out and p.returncode != 0:
            line = next(l for l in out.splitlines() if l.startswith("BC FAIL %s " % group))
            print("ARM %s: FAILED AS IT MUST (%s)" % (name, line[:110]))
        elif p.returncode != 0:
            print("ARM %s: FAILED, BUT NOT IN ITS OWN GROUP (%s)" % (name, group))
            rc = 1
        else:
            print("ARM %s: STAYED GREEN" % name)
            rc = 1
    print("BRIDGE_CASES ARMS RESULT %s" % ("PASS" if rc == 0 else "FAIL"))
    sys.exit(rc)


if os.environ.get("ARM") == "all":
    arm_all()

WORK = tempfile.mkdtemp(prefix="bridge_cases.")
TOOLS = os.path.join(WORK, "tools")
shutil.copytree(os.path.join(ROOT, "tools", "bridge"), os.path.join(TOOLS, "bridge"), ignore=shutil.ignore_patterns("__pycache__"))
shutil.copytree(os.path.join(ROOT, "tools", "lib"), os.path.join(TOOLS, "lib"), ignore=shutil.ignore_patterns("__pycache__"))
if os.environ.get("ARM"):
    _, rel, a, b = ARMS[os.environ["ARM"]]
    path = os.path.join(TOOLS, "bridge", rel)
    src = open(path).read()
    if src.count(a) != 1:
        print("ARM %s: anchor is gone in %s" % (os.environ["ARM"], rel))
        print("BRIDGE_CASES RESULT FAIL (arm)")
        shutil.rmtree(WORK, ignore_errors=True)
        sys.exit(1)
    open(path, "w").write(src.replace(a, b))
sys.path.insert(0, os.path.join(TOOLS, "bridge"))
sys.path.insert(0, os.path.join(TOOLS, "lib"))
sys.dont_write_bytecode = True
from bridgelib import argv as A, caps, kdc as kdclib, merge, parse, resolve, state  # noqa: E402
import jsonc  # noqa: E402

fails = []
counts = {}


def check(group, name, ok, seen=""):
    counts[group] = counts.get(group, 0) + 1
    if not ok:
        fails.append("%s %s" % (group, name))
        print("BC FAIL %s %s: %s" % (group, name, seen))


def fx(name, mode="r"):
    with open(os.path.join(FIX, name), mode) as f:
        return f.read()


CFG = state.clamp({})


# ---- builders ---------------------------------------------------------------------------------------------------------
def kd(i, name="REDMAGIC 10S Pro", reachable=True, paired=True, addresses=("192.168.0.240",), plugins=("battery", "sftp", "share", "findmyphone", "clipboard"), **kw):
    d = {"id": i, "name": name, "type": "phone", "reachable": reachable, "paired": paired, "pairState": 3 if paired else 0,
         "addresses": list(addresses), "links": ["LAN"] if reachable else [], "plugins": list(plugins) if reachable else [],
         "verificationKey": "305BAF9E", "pairRequested": False, "pairRequestedByPeer": False, "battery": None, "cell": None,
         "mountPoint": ""}
    d.update(kw)
    return d


def ad(serial, state_="device", model="NX789J", **kw):
    t = {"serial": serial, "state": state_, "rawState": state_, "transport": parse.transport_of(serial), "address": parse.address_of(serial),
         "usbPath": "", "product": model, "model": model, "device": model, "transportId": "1"}
    t.update(kw)
    return t


def ub(serial, name="REDMAGIC 10S Pro", adb=True, mtp=True, **kw):
    u = {"serial": serial, "vendor": "19d2", "product": "1234", "name": name, "manufacturer": "Nubia", "adbIface": adb, "mtpIface": mtp,
         "bus": "1-4"}
    u.update(kw)
    return u


def do_merge(kdcs=(), adbs=(), usbs=(), st=None, cfg=None, now=1000, ident=None):
    facts = {"kdc": {d["id"]: d for d in kdcs}, "adb": list(adbs), "usb": list(usbs), "ident": ident or {}}
    s = {"links": {}, "prefs": {}, "lastSeen": {}, "current": "", "facts": {}}
    s.update(st or {})
    return merge.merge(facts, s, cfg or CFG, now)


def keys(m):
    return [d["key"] for d in m["devices"]]


ENV = {"kdeconnect": "running", "adbServer": "up",
       "have": {"adb": True, "scrcpy": "5.0.1", "aft": True, "sshfs": False, "fusermount": True}, "usbMountDirOk": True}


def dev_of(m, key=None):
    return m["devices"][0] if key is None else next(d for d in m["devices"] if d["key"] == key)


def with_mounts(d):
    d["mounts"] = {"usb": {"point": "/mnt/android", "state": "unmounted", "mine": False},
                   "wifi": {"point": "/run/user/1000/x", "state": "unmounted", "mine": False}}
    return d


# ---- parse ------------------------------------------------------------------------------------------------------------
def g_parse():
    devs = parse.parse_devices_l(fx("adb_devices_l.txt"))
    by = {d["serial"]: d for d in devs}
    check("parse", "devices count", len(devs) == 6, len(devs))
    u = by["RZ8N30ABCDE"]
    check("parse", "usb device", (u["state"], u["transport"], u["address"], u["usbPath"], u["model"], u["transportId"]) ==
          ("device", "usb", "", "1-4", "NX789J", "1"), u)
    t = by["192.168.0.240:5555"]
    check("parse", "tcp device", (t["transport"], t["address"], t["state"]) == ("tcp", "192.168.0.240:5555", "device"), t)
    m = by["adb-RZ8N30ABCDE-xYz1Qa._adb-tls-connect._tcp"]
    check("parse", "mdns serial is tcp with no address", (m["transport"], m["address"]) == ("tcp", ""), m)
    check("parse", "unauthorized", by["R58M12345XY"]["state"] == "unauthorized")
    check("parse", "offline", by["emulator-5554"]["state"] == "offline")
    check("parse", "no permissions maps to offline", (by["R9ZZ00000AA"]["state"], by["R9ZZ00000AA"]["rawState"]) == ("offline", "no permissions"))
    check("parse", "strange lines never raise", parse.parse_devices_l("\x00\xff junk\n\n  \nonlyserial\n* daemon started\n") == [])
    # the smart socket, fed one byte at a time
    wire = fx("adb_track_wire.bin", "rb")
    fp, frames = parse.FrameParser(), []
    for i in range(len(wire)):
        frames += fp.feed(wire[i:i + 1])
    check("parse", "frames byte by byte", len(frames) == 3 and frames[1] == "" and not fp.failed, frames)
    check("parse", "frame 3 has two transports", len(parse.parse_devices_l(frames[2])) == 2)
    fp = parse.FrameParser()
    fp.feed(b"FAIL0010unknown service")
    check("parse", "FAIL is reported", "unknown service" in fp.failed, fp.failed)
    check("parse", "bad length is no exception", parse.FrameParser().feed(b"OKAYzzzz") == [])
    mdns = parse.parse_mdns(fx("adb_mdns_services.txt"))
    check("parse", "mdns keeps only connect services", [(m["ip"], m["port"]) for m in mdns] == [("192.168.0.240", 41231), ("192.168.0.77", 37555)], mdns)
    check("parse", "mdns total", parse.parse_mdns("garbage\n\t\t\nx\ty\tz\n") == [])
    lines, rest = parse.split_redraws(fx("adb_push_progress.raw"))
    pcts = [parse.parse_push_line(l) for l in lines]
    check("parse", "push progress", [p["percent"] for p in pcts if p and "percent" in p] == [0, 12, 45, 100], pcts)
    summ = [p for p in pcts if p and "summary" in p]
    check("parse", "push summary", summ and summ[0]["summary"] == {"files": 1, "skipped": 0, "rate": 35200000, "bytes": 1048576, "seconds": 0.028}, summ)
    check("parse", "push garbage", parse.parse_push_line("adb: error: x") is None and parse.parse_push_line("[ 4x%] a") is None)
    b = parse.parse_dumpsys_battery(fx("dumpsys_battery.txt"))
    check("parse", "dumpsys battery", b == {"level": 81, "tempC": 28.7, "health": "good"}, b)
    check("parse", "df", parse.parse_df(fx("df_data.txt")) == {"total": 226455396 * 1024, "free": 128102476 * 1024})
    check("parse", "df garbage", parse.parse_df("x\ny z\n") == {})
    f = parse.parse_facts_blob(fx("facts_blob.txt"))
    check("parse", "facts blob", f == {"model": "NX789J", "android": "15", "batteryHealth": "good", "batteryTempC": 28.7,
                                       "storageTotal": 226455396 * 1024, "storageFree": 128102476 * 1024}, f)
    check("parse", "facts: no ==usb section asked, no usbUnlocked told", "usbUnlocked" not in f, f)
    fm, fn = parse.parse_facts_blob(fx("facts_blob_usb_mtp.txt")), parse.parse_facts_blob(fx("facts_blob_usb_none.txt"))
    check("parse", "usbUnlocked: the line `screen_unlocked_functions=MTP` reads mtp, lower case", fm.get("usbUnlocked") == "mtp" and fm["model"] == "NX789J", fm)
    check("parse", "usbUnlocked: no line reads none (usbUnlocked: no line reads none)", fn.get("usbUnlocked") == "none", fn)
    check("parse", "usbUnlocked: other functions and an empty value", (parse.parse_usb_unlocked("  screen_unlocked_functions=PTP"), parse.parse_usb_unlocked("screen_unlocked_functions="),
          parse.parse_usb_unlocked("screen_unlocked_functions=none")) == ("ptp", "none", "none"))
    check("parse", "the facts script asks dumpsys usb on the phone", "dumpsys usb | grep screen_unlocked_functions" in parse.FACTS_SCRIPT)
    i = parse.parse_ident(fx("ident_blob.txt"))
    check("parse", "ident: the phone's addresses (loopback out) and its device name",
          i == {"addresses": ["100.64.0.3", "10.0.140.20"], "name": "REDMAGIC 10 Pro"}, i)
    check("parse", "ident: an unset name reads null on Android", parse.parse_ident("==ip\n==name\nnull\n") == {"addresses": [], "name": ""})
    check("parse", "ident garbage", parse.parse_ident("\x00 junk") == {"addresses": [], "name": ""})
    pm = parse.parse_mdns_pairing(fx("adb_mdns_services.txt"))
    check("parse", "mdns pairing services only", pm == [{"instance": "adb-RZ8N30ABCDE", "ip": "192.168.0.240", "port": 38007}], pm)
    check("parse", "the serialno of a Wireless debugging transport", (parse.mdns_serial("adb-000000000042-Xy1._adb-tls-connect._tcp"),
          parse.mdns_serial("192.168.0.5:5555"), parse.mdns_serial("RZ8N30ABCDE")) == ("000000000042", "", ""))
    mi = parse.parse_mountinfo(fx("mountinfo.txt"))
    check("parse", "mountinfo", [(m["point"], m["fstype"]) for m in mi] == [("/run/user/1000/1d3a8f5c9b2e4a77", "fuse.sshfs"), ("/mnt/android", "fuse"), ("/mnt/with space", "ext4"), ("/", "ext4")], mi)
    check("parse", "scrcpy version", parse.parse_scrcpy_version(fx("scrcpy_version.txt")) == "5.0.1")
    check("parse", "scrcpy version garbage", parse.parse_scrcpy_version("nonsense") == "")
    check("parse", "last error line", parse.last_error_line(fx("scrcpy_noadb.txt")) == "Could not find any ADB device")
    check("parse", "last error line empty", parse.last_error_line("") == "")
    check("parse", "connect", parse.parse_connect("connected to 192.168.0.240:5555")[0] is True
          and parse.parse_connect("failed to connect to '1.2.3.4:5555': Connection refused")[0] is False
          and parse.parse_connect("")[0] is False)


def g_lock():
    L = {n: parse.parse_lockstate(fx("lockstate_%s.txt" % n)) for n in ("locked_dozing", "unlocked_awake", "locked_awake_app_on_top", "no_trust")}
    check("parse", "lockstate: locked and dozing, the lock screen in front (the phone's real line shapes)",
          L["locked_dozing"] == {"locked": True, "keyguard": True, "awake": False, "focus": "keyguard"}, L["locked_dozing"])
    check("parse", "lockstate: unlocked and awake, an app window in front",
          L["unlocked_awake"] == {"locked": False, "keyguard": False, "awake": True, "focus": "app"}, L["unlocked_awake"])
    check("parse", "lockstate: locked with an app window in front is not the keyguard's focus",
          L["locked_awake_app_on_top"] == {"locked": True, "keyguard": True, "awake": True, "focus": "app"}, L["locked_awake_app_on_top"])
    check("parse", "lockstate: with no deviceLocked the keyguard flags decide, no focus is none",
          L["no_trust"] == {"locked": True, "keyguard": False, "awake": True, "focus": ""}, L["no_trust"])
    check("parse", "lockstate: Keyguard and Bouncer windows count as the keyguard",
          [parse.parse_lockstate("mCurrentFocus=Window{1 u0 %s}" % w)["focus"] for w in ("Keyguard", "StatusBar", "Bouncer")] == ["keyguard", "app", "keyguard"])
    check("parse", "lockstate: garbage is unlocked, asleep-unknown reads awake", parse.parse_lockstate("") == {"locked": False, "keyguard": False, "awake": True, "focus": ""})
    two = ' User "Guest" (id=10, flags=0x4) : trustState=UNTRUSTED, deviceLocked=0\n User "Owner" (id=0) (current): deviceLocked=1\n'
    check("parse", "lockstate: the current user's deviceLocked wins", parse.parse_lockstate(two)["locked"] is True)
    check("parse", "lockstate script greps the four dumpsys sections on the phone",
          all(x in parse.LOCK_SCRIPT for x in ("dumpsys trust", "dumpsys window", "dumpsys power", "dumpsys deviceidle")))
    # the PIN: what is valid, and that the keyring module never takes it through an argv
    from bridgelib import keyring
    check("parse", "a PIN is 4 to 16 letters or digits", [keyring.valid(x) for x in ("1234", "Ab12cd34Ef56gh78", "123", "12345678901234567", "12 34", "12-34", "")] == [True, True, False, False, False, False, False])
    import inspect
    src = inspect.getsource(keyring)
    check("parse", "keyring: the PIN goes in on stdin only (store has no PIN in its argv)", 'stdin=pin' in src and '"device", device], stdin=pin' in src)


# ---- merge ------------------------------------------------------------------------------------------------------------
def g_merge():
    m = do_merge([kd("k1")], [ad("S1")], [ub("S1")], st={"links": {"k1": "S1"}})
    check("merge", "stored link joins kdc and cable", keys(m) == ["kdc:k1"] and dev_of(m)["link"] == "both" and dev_of(m)["usb"]["serial"] == "S1", keys(m))
    check("merge", "the device record carries pin: none by default, set / failed from the state",
          [dev_of(do_merge([kd("k1")], [], [], st=st_))["pin"] for st_ in ({}, {"pins": {"kdc:k1": "set"}}, {"pins": {"kdc:k1": "failed"}}, {"pins": {"kdc:k1": "junk"}})] == ["none", "set", "failed", "none"])
    m = do_merge([kd("k1", name="Phone One")], [ad("192.168.0.240:5555", model="X")], [])
    check("merge", "the Wi-Fi address joins kdc and an adb TCP transport", keys(m) == ["kdc:k1"] and dev_of(m)["adb"]["transport"] == "tcp", keys(m))
    check("merge", "...and writes no link (an address is never kept)", m["links"] == {}, m["links"])
    m = do_merge([kd("k1")], [ad("S9", model="NX789J")], [ub("S9")])
    check("merge", "a name both sides have once joins them", keys(m) == ["kdc:k1"] and m["links"] == {"k1": "S9"}, (keys(m), m["links"]))
    m = do_merge([kd("k1", name="Pixel 8"), kd("k2", name="Pixel 8", addresses=())], [], [ub("S3", name="Pixel 8")])
    check("merge", "two phones with one name are not merged", len(m["devices"]) == 3 and m["links"] == {}, keys(m))
    m = do_merge([kd("k1", name="Pixel 8")], [ad("A1", model="Pixel_8"), ad("A2", model="Pixel_8")], [])
    check("merge", "a name matching two adb devices joins none", len(m["devices"]) == 3, keys(m))
    m = do_merge([kd("kA", name="Phone", addresses=())], [ad("S1", model="Other"), ad("S2", model="Phone")], [ub("S1", name="Other"), ub("S2", name="Phone")],
                 st={"links": {"kA": "S1"}})
    d = dev_of(m, "kdc:kA")
    check("merge", "a stored link beats the name", d["usb"] and d["usb"]["serial"] == "S1" and "adb:S2" in keys(m), keys(m))
    m = do_merge([kd("k1")], [ad("S1")], [ub("S1")], st={"links": {"k1": "S1"}, "lastSeen": {}})
    check("merge", "one KDE Connect id and one USB serial per device", len(m["devices"]) == 1)
    m = do_merge([kd("k2", paired=True, reachable=False), kd("k3", name="Tablet", type="tablet", addresses=())],
                 [], [], st={"lastSeen": {"kdc:k2": 500}}, now=1000)
    check("merge", "present first by lastSeen: present (now) before absent",
          keys(m) == ["kdc:k3", "kdc:k2"], keys(m))
    m = do_merge([kd("a", reachable=False, name="Old", addresses=()), kd("b", reachable=False, name="Older", addresses=()),
                  kd("c", paired=False, reachable=True, name="Stranger", addresses=())], [], [],
                 st={"lastSeen": {"kdc:a": 900, "kdc:b": 100}}, now=2000)
    check("merge", "paired first, newest lastSeen first; the unpaired one is only in pairing",
          keys(m) == ["kdc:a", "kdc:b"] and [p["key"] for p in m["pairing"]] == ["kdc:c"], (keys(m), m["pairing"]))
    check("merge", "pairing entry shape", set(m["pairing"][0]) == {"key", "name", "type", "byPeer", "verificationKey"})
    cfg = state.clamp({"devices": {"REDMAGIC 10S Pro": {"hidden": True}, "kdc:z": {"skin": "generic"}}})
    m = do_merge([kd("k1"), kd("z", name="REDMAGIC 10S Pro Max", addresses=()), kd("y", name="Pixel", addresses=())], [], [], cfg=cfg)
    check("merge", "hidden by name is dropped; a key's skin wins over the name table",
          "kdc:k1" not in keys(m) and dev_of(m, "kdc:z")["skin"] == "generic" and dev_of(m, "kdc:y")["skin"] == "generic", [(d["key"], d["skin"]) for d in m["devices"]])
    m = do_merge([kd("k1")], [], [])
    check("merge", "skin by the name table", dev_of(m)["skin"] == "redmagic-10s-pro-moonlight", dev_of(m)["skin"])
    m = do_merge([], [ad("RZ1", model="Pixel_8")], [ub("RZ1", name="Pixel 8")])
    check("merge", "an adb-only device is keyed by its serial", keys(m) == ["adb:RZ1"] and dev_of(m)["name"] == "Pixel 8" and dev_of(m)["type"] == "phone", keys(m))
    m = do_merge([], [ad("RZ1"), ad("192.168.0.5:5555")], [ub("RZ1")])
    check("merge", "the same phone over the cable and over TCP is one device", keys(m) == ["adb:RZ1"] and dev_of(m)["link"] == "both", keys(m))
    m = do_merge([], [], [ub("RZ2", adb=False, mtp=True)])
    check("merge", "a cable with no adb is still a device", keys(m) == ["adb:RZ2"] and dev_of(m)["adb"] is None and dev_of(m)["link"] == "usb")
    m = do_merge([kd("k1", reachable=False, addresses=())], [], [])
    d = dev_of(m)
    check("merge", "an absent paired phone: present false, link none, lastSeen kept", (d["present"], d["link"], d["lastSeen"]) == (False, "none", 0), d)
    m = do_merge([kd("k1")], [], [], st={"prefs": {"kdc:k1": {"mode": "camera", "bogus": 1, "screenOff": "yes"}}})
    check("merge", "prefs: stored valid values over the defaults", dev_of(m)["prefs"] == {"keepWireless": True, "mode": "camera", "screenOff": False, "record": False, "wifiDebug": False, "castAudio": False, "usbUnlockMtp": False}, dev_of(m)["prefs"])
    check("merge", "present devices read lastSeen = now", dev_of(do_merge([kd("k1")], [], [], now=1234))["lastSeen"] == 1234)
    # the user's phone as captured on 2026-11-18 (serial and address made up): KDE Connect says "REDMAGIC 10 Pro" (the phone's own
    # name), adb "NX789J", the USB product "REDMAGIC 10S Pro"; nothing but the phone itself, asked over the cable, ties them
    real_k = kd("k1", name="REDMAGIC 10 Pro", addresses=("10.0.140.20",))
    real_a = ad("S1", model="NX789J", product="NX789J-EEA")
    real_u = ub("S1", name="REDMAGIC 10S Pro", manufacturer="nubia", product="0306")
    m = do_merge([real_k], [real_a], [real_u])
    check("merge", "unasked, the captured phone is two devices, the cable one named by its USB product (not NX789J, not 0306)",
          sorted(keys(m)) == ["adb:S1", "kdc:k1"] and dev_of(m, "adb:S1")["name"] == "REDMAGIC 10S Pro", [(d["key"], d["name"]) for d in m["devices"]])
    m = do_merge([real_k], [real_a], [real_u], ident={"S1": {"addresses": ["100.64.0.3", "10.0.140.20"], "name": ""}})
    check("merge", "the address the phone reports over the cable joins it to its KDE Connect self, and the link is kept",
          keys(m) == ["kdc:k1"] and dev_of(m)["link"] == "both" and dev_of(m)["name"] == "REDMAGIC 10 Pro" and m["links"] == {"k1": "S1"}, (keys(m), m["links"]))
    m = do_merge([real_k], [real_a], [real_u], ident={"S1": {"addresses": [], "name": "REDMAGIC 10 Pro"}})
    check("merge", "...and so does the device name it reports", keys(m) == ["kdc:k1"] and m["links"] == {"k1": "S1"}, keys(m))
    m = do_merge([real_k, kd("k2", name="Other", addresses=("10.0.140.20",))], [real_a], [real_u],
                 ident={"S1": {"addresses": ["10.0.140.20"], "name": ""}})
    check("merge", "an address two KDE Connect phones share joins neither", "adb:S1" in keys(m) and m["links"] == {}, keys(m))
    m = do_merge([real_k, kd("b", name="BEAST", type="desktop", reachable=False, addresses=()), kd("l", name="Work", type="laptop"),
                  kd("c", name="Lab PC", type="desktop", paired=False, reachable=True, addresses=())], [], [])
    check("merge", "computers are left out, from the devices and from pairing", keys(m) == ["kdc:k1"] and m["pairing"] == [],
          (keys(m), m["pairing"]))
    m = do_merge([], [], [ub("RZ2", adb=False, name="Pixel 8", product="4ee7")])
    check("merge", "a cable-only phone is named by its USB product string, never its product id", dev_of(m)["name"] == "Pixel 8", dev_of(m)["name"])
    # Wireless debugging: adb connects by itself to a paired phone it finds by mDNS, naming the transport after the serialno
    tls = ad("adb-S1-AbCdE1._adb-tls-connect._tcp", model="NX789J")
    m = do_merge([real_k], [tls], [], st={"links": {"k1": "S1"}})
    check("merge", "Wireless debugging's own transport joins the phone its stored link names", keys(m) == ["kdc:k1"] and dev_of(m)["adb"]["serial"].startswith("adb-S1-"), keys(m))
    m = do_merge([real_k], [tls], [])
    check("merge", "...and without a link it is its own device (no guess)", sorted(keys(m)) == ["adb:adb-S1-AbCdE1._adb-tls-connect._tcp", "kdc:k1"], keys(m))
    m = do_merge([real_k], [], [], st={"links": {"k1": "S1"}})
    steps = resolve.ladder(dev_of(m), 5555, [{"instance": "adb-S1-AbCdE1", "service": "_adb-tls-connect._tcp", "ip": "10.9.9.9", "port": 40123}])
    check("merge", "with no cable, the ladder finds Wireless debugging by the linked serialno (an address KDE Connect does not know)",
          steps and steps[0] == {"step": "mdns", "address": "10.9.9.9:40123"}, steps)
    table, ch = merge.seen_update({"lastSeen": {}}, ["a"], ["b"], 77)
    check("merge", "lastSeen on arrival and departure", ch and table == {"a": 77, "b": 77}, table)
    check("merge", "current falls back to the first device", merge.current_of({"current": "zz"}, [{"key": "a"}, {"key": "b"}]) == "a" and merge.current_of({"current": "b"}, [{"key": "a"}, {"key": "b"}]) == "b" and merge.current_of({"current": ""}, []) == "")


# ---- resolve ----------------------------------------------------------------------------------------------------------
def g_resolve():
    d = dev_of(do_merge([kd("k1")], [ad("S1"), ad("192.168.0.240:5555")], [ub("S1")], st={"links": {"k1": "S1"}}))
    steps = resolve.ladder(d, 5555)
    check("resolve", "the cable first, then a TCP transport that is up", [s["step"] for s in steps[:2]] == ["usb", "tcp"] and steps[0]["serial"] == "S1", steps)
    d = dev_of(do_merge([kd("k1", addresses=("192.168.0.240", "10.0.0.7"))], [], []))
    steps = resolve.ladder(d, 5556)
    check("resolve", "KDE Connect's addresses with the armed port", steps == [{"step": "connect", "address": "192.168.0.240:5556"}, {"step": "connect", "address": "10.0.0.7:5556"}], steps)
    d = dev_of(do_merge([kd("k1")], [ad("S1", "unauthorized")], [ub("S1")], st={"links": {"k1": "S1"}}))
    check("resolve", "a transport that is not in state device is no step", all(s["step"] == "connect" for s in resolve.ladder(d, 5555)))
    mdns = parse.parse_mdns(fx("adb_mdns_services.txt"))
    d = dev_of(do_merge([kd("k1", addresses=())], [ad("RZ8N30ABCDE", "offline")], [ub("RZ8N30ABCDE")], st={"links": {"k1": "RZ8N30ABCDE"}}))
    steps = resolve.ladder(d, 5555, mdns)
    check("resolve", "mDNS names the device by its serial", steps == [{"step": "mdns", "address": "192.168.0.240:41231"}], steps)
    d = dev_of(do_merge([kd("k1", addresses=("192.168.0.77",))], [], []))
    steps = resolve.ladder(d, 5555, mdns)
    check("resolve", "mDNS by KDE Connect's address, then the connect step", [(s["step"], s["address"]) for s in steps] == [("mdns", "192.168.0.77:37555"), ("connect", "192.168.0.77:5555")], steps)
    d = dev_of(do_merge([kd("k1", reachable=False, addresses=())], [], []))
    d["lastAddress"] = ["192.168.0.99"]
    check("resolve", "no remembered address is ever used", resolve.ladder(d, 5555) == [], resolve.ladder(d, 5555))
    d = dev_of(do_merge([kd("k1", addresses=())], [], []))
    d["lastAddress"] = ["192.168.0.99"]
    check("resolve", "...not for a reachable phone that reports no address", resolve.ladder(d, 5555) == [])
    d = dev_of(do_merge([kd("k1")], [ad("S1"), ad("192.168.0.240:5555")], [ub("S1")], st={"links": {"k1": "S1"}}))
    check("resolve", "USB is preferred to TCP", resolve.ladder(d, 5555)[0]["step"] == "usb")


# ---- argv -------------------------------------------------------------------------------------------------------------
def g_argv():
    c = CFG
    check("argv", "mirror over the cable: scrcpy's own sizes", A.scrcpy(c, "mirror", "S1", "usb", "Phone") == ["scrcpy", "-s", "S1", "--window-title", "Phone"],
          A.scrcpy(c, "mirror", "S1", "usb", "Phone"))
    check("argv", "mirror over Wi-Fi: the config's sizes", A.scrcpy(c, "mirror", "192.168.0.240:5555", "tcp", "Phone") ==
          ["scrcpy", "-s", "192.168.0.240:5555", "--window-title", "Phone", "--max-size=1600", "--video-bit-rate=6M", "--max-fps=60"])
    check("argv", "desktop", "--new-display" in A.scrcpy(c, "desktop", "S1", "usb"))
    check("argv", "camera", A.scrcpy(c, "camera", "S1", "usb")[3:] == ["--video-source=camera", "--no-control"], A.scrcpy(c, "camera", "S1", "usb"))
    check("argv", "audio is no video and no sizes", A.scrcpy(c, "audio", "S1", "tcp") == ["scrcpy", "-s", "S1", "--no-video", "--no-control"])
    check("argv", "screen off over the cable keeps the phone awake", A.scrcpy(c, "mirror", "S1", "usb", screen_off=True)[-2:] == ["--turn-screen-off", "--stay-awake"])
    check("argv", "screen off over Wi-Fi does not", "--stay-awake" not in A.scrcpy(c, "mirror", "S1", "tcp", screen_off=True))
    check("argv", "record and the extra arguments, last", A.scrcpy(state.clamp({"mirror": {"extraArgs": ["--window-borderless"]}}), "mirror", "S1", "usb", record_path="/v/p.mp4")[-2:] == ["--record=/v/p.mp4", "--window-borderless"])
    check("argv", "record names", (A.record_name("mirror", "20261116-120000"), A.record_name("audio", "x")) == ("phone-20261116-120000.mp4", "phone-x.mka"))
    check("argv", "always -s <serial>", all(A.scrcpy(c, m, "SER", v)[1:3] == ["-s", "SER"] for m in st_modes() for v in ("usb", "tcp")))
    check("argv", "the job's wrapper line", A.systemd_run("mirror", "m-18", "/t/lares-bridge", ["scrcpy", "-s", "S1"]) ==
          ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--expand-environment=no", "--unit=lares-bridge-mirror-m-18", "--", "setsid", "-f",
           "/t/lares-bridge", "_run", "m-18", "--", "scrcpy", "-s", "S1"])
    check("argv", "adb calls", (A.adb("devices", "-l"), A.adb_connect("1.2.3.4:5555"), A.adb_tcpip("S1", 5555), A.adb_keyevent("S1", "power"),
                                A.adb_screencap("S1"), A.adb_push("S1", ["/a b", "/c"], "/sdcard/Download")) ==
          (["adb", "devices", "-l"], ["adb", "connect", "1.2.3.4:5555"], ["adb", "-s", "S1", "tcpip", "5555"],
           ["adb", "-s", "S1", "shell", "input", "keyevent", "26"], ["adb", "-s", "S1", "exec-out", "screencap", "-p"],
           ["adb", "-s", "S1", "push", "/a b", "/c", "/sdcard/Download/"]))
    check("argv", "keycodes", (A.KEYCODES["volup"], A.KEYCODES["voldown"]) == (24, 25))
    check("argv", "the mount commands", (A.aft_mount("/mnt/android"), A.fusermount("/mnt/android"), A.fusermount("/mnt/android", True)) ==
          (["aft-mtp-mount", "/mnt/android"], ["fusermount3", "-u", "/mnt/android"], ["fusermount3", "-uz", "/mnt/android"]))
    check("argv", "the opener fills {path}", A.opener(c, "/mnt/android")[-1] == "/mnt/android" and A.opener(state.clamp({"files": {"open": ["xdg-open"]}}), "/p") == ["xdg-open", "/p"])
    check("argv", "share urls are file URLs", A.share_urls(["/a b/c.txt"]) == ["file:///a%20b/c.txt"])
    check("argv", "titles are clean", A.safe_title("REDMAGIC 10S Pro \"x\"\n") == "REDMAGIC 10S Pro x")
    # every flag we emit exists in this machine's scrcpy (read-only: `scrcpy --help`)
    if shutil.which("scrcpy"):
        h = subprocess.run(["scrcpy", "--help"], capture_output=True, text=True, timeout=10)
        text = h.stdout + h.stderr
        used = set()
        for m in st_modes():
            for v in ("usb", "tcp"):
                for so in (False, True):
                    used |= {a.split("=")[0] for a in A.scrcpy(state.clamp({"mirror": {"wifi": {"maxSize": 1, "bitRate": "1M", "maxFps": 1}, "usb": {"maxSize": 1, "bitRate": "1M", "maxFps": 1}}}), m, "S", v, "t", so, "/x.mp4") if a.startswith("-")}
        missing = [f for f in sorted(used) if f not in text]
        check("argv", "every scrcpy flag exists in `scrcpy --help`", not missing, missing)
    else:
        print("BC NOTE argv: scrcpy is not installed here, flags not checked against --help")


def st_modes():
    return state.MODES


# ---- caps -------------------------------------------------------------------------------------------------------------
def can(m, env=None, tries=None, cfg=None, mounts=None):
    d = with_mounts(dev_of(m) if isinstance(m, dict) else m)
    if mounts:
        d["mounts"].update(mounts)
    return caps.can_table(d, dict(ENV, **(env or {})), cfg or CFG, tries)


def g_argv_usb():
    check("argv", "usbcalm off: svc usb setScreenUnlockedFunctions with no function (usbcalm off sends no function)",
          A.adb_usb_calm("S1", False) == ["adb", "-s", "S1", "shell", "svc", "usb", "setScreenUnlockedFunctions"], A.adb_usb_calm("S1", False))
    check("argv", "usbcalm on: ...with mtp", A.adb_usb_calm("S1", True) == ["adb", "-s", "S1", "shell", "svc", "usb", "setScreenUnlockedFunctions", "mtp"])
    check("argv", "the usb function reads", (A.adb_usb_functions("S1")[-3:], A.adb_usb_set_functions("S1", "mtp")[-3:]) == (["svc", "usb", "getFunctions"], ["usb", "setFunctions", "mtp"]))


def g_caps():
    lan = do_merge([kd("k1")], [], [])
    c = can(lan)
    check("caps", "exactly the contract's actions", list(c) == list(caps.ACTIONS) == ["mirror", "mountUsb", "mountWifi", "send", "shot", "ring", "clip", "key", "pair", "unpair", "arm", "facts", "unlock"], list(c))
    check("caps", "every entry has ok / why / hint / via", all(set(v) == {"ok", "why", "hint", "via"} for v in c.values()))
    check("caps", "a phone on the LAN with adb: mirror is ok, via tcp", c["mirror"]["ok"] and c["mirror"]["via"] == "tcp", c["mirror"])
    check("caps", "sshfs missing says so", not c["mountWifi"]["ok"] and c["mountWifi"]["why"] == "sshfs is missing" and c["mountWifi"]["hint"] == "sudo pacman -S sshfs", c["mountWifi"])
    check("caps", "with sshfs it is ok", can(lan, {"have": dict(ENV["have"], sshfs=True)})["mountWifi"]["ok"])
    check("caps", "send over KDE Connect when adb is not up", c["send"]["ok"] and c["send"]["via"] == "kdeconnect", c["send"])
    check("caps", "ring / clip / unpair are ok, pair is not (already paired)", c["ring"]["ok"] and c["clip"]["ok"] and c["unpair"]["ok"] and not c["pair"]["ok"])
    check("caps", "arm needs the cable", not c["arm"]["ok"] and "cable" in c["arm"]["why"].lower(), c["arm"])
    check("caps", "no cable, so no usb files", not c["mountUsb"]["ok"] and "cable" in c["mountUsb"]["why"].lower(), c["mountUsb"])
    cab = do_merge([kd("k1")], [ad("S1")], [ub("S1")], st={"links": {"k1": "S1"}})
    c = can(cab)
    check("caps", "a cable with adb: mirror via usb, arm, send via adb, shot, key, facts, mountUsb",
          c["mirror"]["via"] == "usb" and c["arm"]["ok"] and c["send"]["via"] == "adb" and c["shot"]["ok"] and c["key"]["ok"] and c["facts"]["ok"] and c["mountUsb"]["ok"], c)
    c = can(do_merge([], [ad("S1", "unauthorized")], [ub("S1")]))
    check("caps", "unauthorized says to accept the prompt", not c["mirror"]["ok"] and "allowed" in c["mirror"]["why"] and "Accept" in c["mirror"]["hint"], c["mirror"])
    c = can(do_merge([], [], [ub("S1", adb=False)]))
    check("caps", "USB debugging off", not c["mirror"]["ok"] and "debugging" in c["mirror"]["why"], c["mirror"])
    check("caps", "usb files are offered with adb on the cable and no MTP yet (the mount asks the phone)", can(do_merge([], [], [ub("S1", adb=True, mtp=False)]))["mountUsb"]["ok"],
          can(do_merge([], [], [ub("S1", adb=True, mtp=False)]))["mountUsb"])
    check("caps", "...and no MTP mode says File transfer", can(do_merge([], [], [ub("S1", adb=False, mtp=False)]))["mountUsb"]["why"].count("File transfer") == 1)
    c = can(lan, {"have": dict(ENV["have"], adb=False)})
    check("caps", "no adb: mirror says so with the pacman hint", not c["mirror"]["ok"] and c["mirror"]["why"] == "adb is missing" and "android-tools" in c["mirror"]["hint"], c["mirror"])
    c = can(lan, {"have": dict(ENV["have"], scrcpy="")})
    check("caps", "no scrcpy", c["mirror"]["why"] == "scrcpy is missing", c["mirror"])
    c = can(do_merge([], [], []) if False else do_merge([kd("k1", reachable=False, addresses=())], [], []))
    check("caps", "absent device: adb is not connected, with the plug hint", c["mirror"]["why"] == "adb is not connected" and "Plug it in once" in c["mirror"]["hint"], c["mirror"])
    check("caps", "absent device: KDE Connect actions say unreachable", not c["ring"]["ok"] and c["ring"]["why"] == "Out of reach", c["ring"])
    c = can(lan, {"kdeconnect": "down"})
    check("caps", "the daemon down", not c["ring"]["ok"] and "not running" in c["ring"]["why"] and not c["pair"]["ok"], c["ring"])
    c = can(lan, {"kdeconnect": "missing"})
    check("caps", "KDE Connect missing", c["ring"]["why"] == "KDE Connect is missing", c["ring"])
    pc = {p: can(do_merge([kd("k1")], [], [], st={"pins": {"kdc:k1": p}} if p != "none" else {}))["unlock"] for p in ("none", "set", "failed")}
    check("caps", "unlock needs a kept PIN", pc["none"] == {"ok": False, "why": "No PIN kept", "hint": "Set it on the Details page", "via": ""}, pc["none"])
    check("caps", "unlock with a PIN set is ok, over the adb path", pc["set"] == {"ok": True, "why": "", "hint": "", "via": "tcp"}, pc["set"])
    check("caps", "a PIN that failed is not offered until it is set again", pc["failed"] == {"ok": False, "why": "The PIN failed last time", "hint": "Set it again on the Details page", "via": ""}, pc["failed"])
    nous = can(do_merge([kd("k1", reachable=False, addresses=())], [], [], st={"pins": {"kdc:k1": "set"}}))["unlock"]
    check("caps", "unlock needs an adb path like key does", not nous["ok"] and nous["why"] == "adb is not connected", nous)
    check("caps", "a failed try of unlock is told and stays pressable",
          can(do_merge([kd("k1")], [], [], st={"pins": {"kdc:k1": "set"}}), tries={"unlock": {"reason": "The keyring is locked", "hint": "x"}})["unlock"]["why"] == "The keyring is locked")
    c = can(lan, tries={"mirror": {"reason": "The phone does not accept adb over Wi-Fi yet", "hint": "Plug it in once"}})
    check("caps", "a failed try is told as why, and the action stays pressable (a failure is no lock)",
          c["mirror"]["ok"] and c["mirror"]["why"].startswith("The phone does not accept") and c["mirror"]["hint"] == "Plug it in once", c["mirror"])
    check("caps", "...and only for what can be tried", can(lan, tries={"ring": {"reason": "x"}})["ring"] == {"ok": True, "why": "", "hint": "", "via": ""})
    c = can(do_merge([kd("k1", paired=False)], [ad("S1")], [ub("S1")], st={"links": {"k1": "S1"}}))
    check("caps", "unpaired but reachable: pair is ok, unpair is not", c["pair"]["ok"] and not c["unpair"]["ok"], (c["pair"], c["unpair"]))
    c = can(do_merge([kd("k1", paired=False, pairRequested=True)], [ad("S1")], [ub("S1")], st={"links": {"k1": "S1"}}))
    check("caps", "a pair request in the air waits", not c["pair"]["ok"] and "Waiting" in c["pair"]["why"], c["pair"])
    c = can(cab, mounts={"usb": {"point": "/mnt/android", "state": "mounted", "mine": True}})
    check("caps", "a mounted phone stays ok (it unmounts)", c["mountUsb"]["ok"])
    c = can(cab, env={"usbMountDirOk": False})
    check("caps", "a missing mount folder names it", not c["mountUsb"]["ok"] and "/mnt/android" in c["mountUsb"]["why"] and "mkdir" in c["mountUsb"]["hint"], c["mountUsb"])
    c = can(cab, env={"have": dict(ENV["have"], aft=False)})
    check("caps", "no aft-mtp-mount", c["mountUsb"]["why"] == "aft-mtp-mount is missing" and "android-file-transfer" in c["mountUsb"]["hint"], c["mountUsb"])
    c = can(do_merge([kd("k1", plugins=("battery",))], [], []), {"have": dict(ENV["have"], sshfs=True)})
    check("caps", "a missing plugin is named", "File browsing" in c["mountWifi"]["why"] and not c["ring"]["ok"] and "Find my phone" in c["ring"]["why"], (c["mountWifi"], c["ring"]))


# ---- config and state -------------------------------------------------------------------------------------------------
def g_config():
    ex = jsonc.load(os.path.join(ROOT, ".examples", "bridge.jsonc"))
    check("config", ".examples/bridge.jsonc is the defaults, key for key", ex == state.DEFAULTS, ex)
    check("config", "...and clamps to itself", state.clamp(ex) == state.DEFAULTS)
    bad = state.clamp({"files": {"usbMount": 5, "open": [1], "sendDir": ""}, "mirror": {"usb": {"maxSize": -4, "bitRate": "fast", "maxFps": "x"},
                       "wifi": {"maxSize": 99999999, "bitRate": "8m", "maxFps": 500}, "extraArgs": "no"}, "adb": {"start": "now", "idleKillS": 1, "port": 22},
                       "flip": {"onOpen": "yes"}, "relight": 3, "devices": {"a": 5, "b": {"skin": 7, "hidden": "no"}, "c": {"hidden": True}}})
    d = state.DEFAULTS
    check("config", "every bad value falls back", bad["files"] == d["files"] and bad["mirror"]["usb"] == d["mirror"]["usb"] and bad["mirror"]["extraArgs"] == []
          and bad["adb"] == {"start": "onDemand", "idleKillS": 5, "port": 1024} and bad["flip"] == d["flip"] and bad["relight"] is True, bad)
    check("config", "wifi values clamp, a good bitRate stays", bad["mirror"]["wifi"] == {"maxSize": 16384, "bitRate": "8m", "maxFps": 240}, bad["mirror"]["wifi"])
    cs = state.clamp({"cast": {"desktopScale": 9, "desktopMinDp": 5, "desktopMinPx": 99999}})["cast"]
    check("config", "desktop keys clamp: scale to 3.0, dp to 240 (desktopMinDp clamps), px to 2400", (cs["desktopScale"], cs["desktopMinDp"], cs["desktopMinPx"]) == (3.0, 240, 2400), cs)
    cs = state.clamp({"cast": {"desktopScale": 0.1, "desktopMinDp": 5000, "desktopMinPx": 10}})["cast"]
    check("config", "...and from below: scale 0.5, dp 1200, px 320", (cs["desktopScale"], cs["desktopMinDp"], cs["desktopMinPx"]) == (0.5, 1200, 320), cs)
    cs = state.clamp({"cast": {"desktopScale": "big", "desktopMinDp": None, "desktopMinPx": True}})["cast"]
    check("config", "...a wrong type is the default", (cs["desktopScale"], cs["desktopMinDp"], cs["desktopMinPx"]) == (1.0, 320, 640), cs)
    check("config", "usbUnlockMtp is a boolean preference, off by default", state.PREF_DEFAULTS["usbUnlockMtp"] is False and state.check_pref("usbUnlockMtp", True)[0]
          and not state.check_pref("usbUnlockMtp", "yes")[0])
    check("config", "devices keep only what is typed right", bad["devices"] == {"b": {}, "c": {"hidden": True}}, bad["devices"])
    check("config", "clamp never raises on junk", state.clamp(None) == d and state.clamp([1]) == d and state.clamp({"files": 3, "adb": None}) == d)
    p = state.Paths({"HOME": "/h", "XDG_RUNTIME_DIR": "/r", "LARES_BRIDGE_STATE": "/s", "LARES_BRIDGE_SYS": "/fs"})
    check("config", "paths with the overrides", (p.state, p.runtime, p.sys_root, p.jobs) == ("/s", "/r/lares/bridge", "/fs", "/r/lares/bridge/jobs") and p.expand("~/Videos") == "/h/Videos", vars(p))
    check("config", "state prefs are checked", state.check_pref("mode", "desktop")[0] and not state.check_pref("mode", "x")[0] and not state.check_pref("record", "yes")[0]
          and not state.check_pref("bogus", 1)[0])


def g_state():
    tmp = tempfile.mkdtemp(prefix="bc.", dir=WORK)
    p = state.Paths({"HOME": tmp, "LARES_BRIDGE_STATE": tmp + "/st", "LARES_BRIDGE_RUNTIME": tmp + "/rt"})
    s = state.load_state(p)
    s["links"] = {"k1": "RZ1", "k2": "192.168.0.240:5555", "k3": "adb-RZ-1._adb-tls-connect._tcp"}
    s["lastSeen"] = {"kdc:k1": 5}
    state.save_state(p, s)
    raw = open(p.state_file).read()
    check("state", "a link to an address is never written", json.loads(raw)["links"] == {"k1": "RZ1"} and "192.168" not in raw and "_adb-tls" not in raw, raw)
    check("state", "the state file is 0600 in a 0700 dir", oct(os.stat(p.state_file).st_mode & 0o777) == "0o600" and oct(os.stat(p.state).st_mode & 0o777) == "0o700")
    st2 = {"pins": {"adb:S": "set"}, "prefs": {}, "facts": {}, "lastSeen": {}, "current": ""}
    state.adopt(st2, "adb:S", "kdc:k")
    check("state", "pins follow a device that turns out to be a KDE Connect one", st2["pins"] == {"kdc:k": "set"}, st2)
    check("state", "pin_of reads none / set / failed and nothing else", [state.pin_of({"pins": {"a": v}}, "a") for v in ("set", "failed", "x", None)] == ["set", "failed", "none", "none"])
    s2 = state.load_state(p)
    s2["pins"] = {"kdc:k1": "set"}
    state.save_state(p, s2)
    check("state", "pins are kept (a word, never a PIN)", json.loads(open(p.state_file).read())["pins"] == {"kdc:k1": "set"})
    check("state", "load reads it back", state.load_state(p)["links"] == {"k1": "RZ1"} and state.load_state(p)["lastSeen"] == {"kdc:k1": 5})
    open(p.state_file, "w").write("{not json")
    check("state", "a broken file is the defaults", state.load_state(p)["links"] == {})
    s = {"prefs": {"adb:S1": {"mode": "mirror", "keepWireless": True}, "kdc:k1": {"mode": "desktop"}},
         "facts": {"adb:S1": {"model": "NX789J", "at": 9}}, "lastSeen": {"adb:S1": 50, "kdc:k1": 40}, "current": "adb:S1", "links": {}}
    ch = state.adopt(s, "adb:S1", "kdc:k1")
    check("state", "adopt: the cable key's prefs, facts, lastSeen and current move to the KDE Connect key, its own values winning",
          ch and s["prefs"] == {"kdc:k1": {"mode": "desktop", "keepWireless": True}} and s["facts"] == {"kdc:k1": {"model": "NX789J", "at": 9}}
          and s["lastSeen"] == {"kdc:k1": 50} and s["current"] == "kdc:k1", s)
    check("state", "adopt of a key nobody has changes nothing", state.adopt(s, "adb:S9", "kdc:k1") is False)
    check("state", "a test's cache is its state dir's, never the user's", p.cache == tmp + "/st-cache", p.cache)
    check("state", "looks_like_address", state.looks_like_address("1.2.3.4:5555") and state.looks_like_address("host:1") and not state.looks_like_address("RZ8N30ABCDE"))
    from bridgelib import mounts, jobs
    mi = parse.parse_mountinfo(fx("mountinfo.txt"))
    check("state", "mount states", (mounts.state_of(mi, "/mnt/android", set(), False), mounts.state_of(mi, "/mnt/android", {"/mnt/android"}, False),
                                    mounts.state_of(mi, "/nope", set(), True), mounts.state_of(mi, "/nope", set(), False)) == ("mounted", "stale", "mounting", "unmounted"))
    check("state", "ENOTCONN is stale, a missing path is not", mounts.is_stale("/x", stat=lambda p: (_ for _ in ()).throw(OSError(107, "ENOTCONN")))
          and not mounts.is_stale("/x", stat=lambda p: (_ for _ in ()).throw(OSError(2, "ENOENT"))) and not mounts.is_stale("/x", stat=lambda p: None) and mounts.is_stale("/y", forced=("/y",)))
    rec = jobs.blank("mirror", "kdc:k1", "mirror", "usb", 10, id="m-1")
    check("state", "a job's public fields are the contract's", set(jobs.public(rec)) == {"id", "kind", "device", "mode", "via", "phase", "started", "ended", "code", "reason", "files", "file", "name", "done", "total", "rate"})
    check("state", "job ids rise", [jobs.next_id(p, "mirror"), jobs.next_id(p, "send"), jobs.next_id(p, "mount")] == ["m-1", "s-2", "f-3"])
    check("state", "KDE Connect is installed when its binary or its D-Bus service file is there",
          kdclib.installed(lambda n: "", exists=lambda p: p.endswith("org.kde.kdeconnect.service")) and kdclib.installed(lambda n: "/usr/bin/" + n, exists=lambda p: False)
          and not kdclib.installed(lambda n: "", exists=lambda p: False))
    from bridgelib import actions
    real_exec = actions._exec
    try:
        calls = []
        said = iter([(0, "List of discovered mdns services\n"),
                     (0, "List of discovered mdns services\nlares-abc123\t_adb-tls-pairing._tcp\t10.0.0.5:37001\n"),
                     (0, "Successfully paired to 10.0.0.5:37001 [guid=adb-S1-x]\n")])
        actions._exec = lambda argv, t=8: (calls.append(list(argv)), next(said))[1]
        state.write_private(p.wifipair, {"key": "kdc:k1", "name": "lares-abc123", "state": "waiting", "at": 1})
        rc = actions.pair_wait(p, CFG, "/bin/true", "kdc:k1", "lares-abc123", "0123456789", sleep=lambda s: None)
        rec = json.load(open(p.wifipair))
        check("state", "pairing: the service the QR code named is found, `adb pair` runs with its address and the password",
              rc == 0 and calls[-1] == ["adb", "pair", "10.0.0.5:37001", "0123456789"] and rec["state"] == "paired", (rc, calls, rec))
        check("state", "...and the phone is remembered as paired (wifiDebug), never the password", state.load_state(p)["prefs"]["kdc:k1"]["wifiDebug"] is True
              and "0123456789" not in open(p.wifipair).read() and "0123456789" not in open(p.state_file).read())
        calls.clear()
        state.write_private(p.wifipair, {"key": "kdc:k1", "name": "lares-newer", "state": "waiting", "at": 1})
        rc = actions.pair_wait(p, CFG, "/bin/true", "kdc:k1", "lares-abc123", "x", sleep=lambda s: None)
        check("state", "a pairing a newer QR code replaced ends at once and touches nothing", rc == 0 and calls == [] and json.load(open(p.wifipair))["name"] == "lares-newer", calls)
    finally:
        actions._exec = real_exec
    w, h = actions._reach_reason({"prefs": {"wifiDebug": True}}, "failed to connect to '1.2.3.4:5555': Connection refused", True)
    w2, h2 = actions._reach_reason({"prefs": {}}, "Connection refused", True)
    check("state", "refused over Wi-Fi: the one step that fixes it, by whether the phone is paired for Wireless debugging",
          w == "adb is off on the phone's Wi-Fi" and "Wireless debugging" in h and "plug" in h and "Plug it in once" in h2, (w, h, h2))
    check("state", "KDE Connect's plugin names lose their prefix (26.08 says kdeconnect_findmyphone; captured 2026-11-18)",
          [kdclib.plugin_name(x) for x in ("kdeconnect_findmyphone", "kdeconnect_share", "sftp")] == ["findmyphone", "share", "sftp"])
    check("state", "a device's id is read off an object path", (kdclib.id_of_path("/modules/kdeconnect/devices/abc/battery"), kdclib.id_of_path("/modules/kdeconnect")) == ("abc", ""))
    check("state", "the pid's start time is read", jobs.proc_start(os.getpid()) > 0 and jobs.proc_start(2 ** 22 + 99) == 0)


for g in (g_parse, g_lock, g_merge, g_resolve, g_argv, g_argv_usb, g_caps, g_config, g_state):
    try:
        g()
    except Exception as e:  # noqa: BLE001
        import traceback
        traceback.print_exc()
        fails.append("%s raised %s" % (g.__name__, e))
        print("BC FAIL %s raised: %s" % (g.__name__[2:], e))
shutil.rmtree(WORK, ignore_errors=True)
print("BRIDGE_CASES %s" % " ".join("%s=%d" % kv for kv in sorted(counts.items())))
print("BRIDGE_CASES RESULT %s" % ("PASS" if not fails else "FAIL (%d: %s)" % (len(fails), "; ".join(fails[:6]))))
sys.exit(0 if not fails else 1)
