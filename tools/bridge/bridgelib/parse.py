"""Every parser of a program's output, pure and total: a strange line is skipped, never an exception.

The formats are adb's, scrcpy's and the kernel's as documented; tools/dev/fixtures/bridge/ holds a sample of each (SYNTHETIC
until a real capture replaces them, see the README there).
"""
import re

_UNQUOTE = re.compile(r"\\([0-7]{3})")


def _unescape(s):
    return _UNQUOTE.sub(lambda m: chr(int(m.group(1), 8)), s)


ADB_STATES = ("device", "unauthorized", "offline", "no permissions", "bootloader", "recovery", "sideload", "rescue", "host",
              "authorizing", "connecting", "detached")


def transport_of(serial):
    """"tcp" for a serial that is an address (host:port) or an mDNS name, else "usb"."""
    s = str(serial)
    if "._adb-tls-" in s:
        return "tcp"
    head, _, port = s.rpartition(":")
    return "tcp" if head and port.isdigit() else "usb"


def address_of(serial):
    s = str(serial)
    return s if transport_of(s) == "tcp" and "._adb-tls-" not in s else ""


def parse_devices_l(text):
    """`adb devices -l` (or the track-devices-l payload): [{serial, state, transport, address, usbPath, product, model, device,
    transportId, rawState}]. state is device | unauthorized | offline (anything else adb says maps to offline)."""
    out = []
    for line in str(text).splitlines():
        line = line.strip()
        if not line or line.startswith("List of devices") or line.startswith("*"):
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        serial, rest = parts
        words = rest.split()
        raw = words[0] if words else ""
        if raw == "no" and len(words) > 1 and words[1] == "permissions":
            raw = "no permissions"
        kv = {}
        for w in words:
            k, sep, v = w.partition(":")
            if sep and k in ("usb", "product", "model", "device", "transport_id"):
                kv[k] = v
        if raw not in ADB_STATES:
            continue
        state = raw if raw in ("device", "unauthorized", "offline") else "offline"
        out.append({"serial": serial, "state": state, "rawState": raw, "transport": transport_of(serial),
                    "address": address_of(serial), "usbPath": kv.get("usb", ""), "product": kv.get("product", ""),
                    "model": kv.get("model", ""), "device": kv.get("device", ""), "transportId": kv.get("transport_id", "")})
    return out


class FrameParser:
    """adb's smart socket answer: `OKAY`, then frames of 4 hex digits of length + payload. feed(bytes) -> [payload str]."""

    def __init__(self):
        self.buf = b""
        self.ok = False
        self.failed = ""

    def feed(self, data):
        self.buf += data
        out = []
        if not self.ok and not self.failed:
            if len(self.buf) < 4:
                return out
            head, self.buf = self.buf[:4], self.buf[4:]
            if head == b"OKAY":
                self.ok = True
            else:
                self.failed = "adb said " + head.decode("ascii", "replace")
                self.buf = self._fail_text(self.buf)
                return out
        while self.ok and len(self.buf) >= 4:
            try:
                n = int(self.buf[:4], 16)
            except ValueError:
                self.buf = b""
                self.ok = False
                self.failed = "adb sent a bad frame length"
                break
            if len(self.buf) < 4 + n:
                break
            out.append(self.buf[4:4 + n].decode("utf-8", "replace"))
            self.buf = self.buf[4 + n:]
        return out

    def _fail_text(self, buf):
        try:
            n = int(buf[:4], 16)
            self.failed = buf[4:4 + n].decode("utf-8", "replace") or self.failed
        except ValueError:
            pass
        return b""


def frame(payload):
    b = payload.encode("utf-8") if isinstance(payload, str) else payload
    return b"%04x" % len(b) + b


def parse_mdns(text):
    """`adb mdns services`: [{instance, service, ip, port}] for the connect services (`_adb-tls-connect._tcp`)."""
    out = []
    for line in str(text).splitlines():
        f = [x.strip() for x in line.split("\t")]
        if len(f) < 3 or "_adb-tls-connect" not in f[1]:
            continue
        ip, _, port = f[2].rpartition(":")
        if not ip or not port.isdigit():
            continue
        out.append({"instance": f[0], "service": f[1], "ip": ip, "port": int(port)})
    return out


def parse_mdns_pairing(text):
    """`adb mdns services`: [{instance, ip, port}] for the pairing services (`_adb-tls-pairing._tcp`), which a phone shows while
    its "Pair device with QR code" waits (the instance is the name the QR code carried)."""
    out = []
    for line in str(text).splitlines():
        f = [x.strip() for x in line.split("\t")]
        if len(f) < 3 or "_adb-tls-pairing" not in f[1]:
            continue
        ip, _, port = f[2].rpartition(":")
        if ip and port.isdigit():
            out.append({"instance": f[0], "ip": ip, "port": int(port)})
    return out


def mdns_serial(serial):
    """An adb transport named by mDNS (`adb-<serialno>-<random>._adb-tls-connect._tcp`) -> the phone's serialno, else ""."""
    m = re.match(r"^adb-([^-]+)-[^.]*\._adb-tls-connect\.", str(serial))
    return m.group(1) if m else ""


_PUSH_PCT = re.compile(r"^\[\s*(\d{1,3})%\]\s+(.+?)\s*$")
_PUSH_SUM = re.compile(r"^(?:(.+?):\s+)?(\d+) files? pushed,?\s+(\d+) skipped\.?\s*(?:([\d.]+) ([KMG]?B)/s)?\s*(?:\((\d+) bytes in ([\d.]+)s\))?")
_UNITS = {"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9}


def parse_push_line(line):
    """One line of `adb push` (a \\r redraw is split by the caller): {"percent", "name"} | {"summary": {...}} | None."""
    line = str(line).strip()
    m = _PUSH_PCT.match(line)
    if m:
        return {"percent": min(100, int(m.group(1))), "name": m.group(2)}
    m = _PUSH_SUM.match(line)
    if m:
        rate = float(m.group(4)) * _UNITS.get(m.group(5), 1) if m.group(4) else 0
        return {"summary": {"files": int(m.group(2)), "skipped": int(m.group(3)), "rate": int(rate),
                            "bytes": int(m.group(6) or 0), "seconds": float(m.group(7) or 0)}}
    return None


def split_redraws(buf):
    """(complete lines, rest) of a stream that redraws with \\r as well as \\n."""
    parts = re.split(r"[\r\n]+", buf)
    return [p for p in parts[:-1] if p], parts[-1]


def parse_dumpsys_battery(text):
    """level, temperature (tenths of a degree C) and health of `dumpsys battery` -> {level, tempC, health}."""
    out = {}
    names = {1: "unknown", 2: "good", 3: "overheat", 4: "dead", 5: "over voltage", 6: "failure", 7: "cold"}
    for line in str(text).splitlines():
        k, sep, v = line.strip().partition(":")
        v = v.strip()
        if not sep or not v.lstrip("-").isdigit():
            continue
        if k == "level":
            out["level"] = int(v)
        elif k == "temperature":
            out["tempC"] = int(v) / 10.0
        elif k == "health":
            out["health"] = names.get(int(v), "unknown")
    return out


def parse_df(text):
    """`df -k <path>` on the phone (toybox or busybox): {total, free} in bytes of the last data row, or {}."""
    rows = [l.split() for l in str(text).splitlines() if l.strip()]
    for r in reversed(rows):
        if len(r) >= 4 and r[1].isdigit() and r[3].isdigit():
            return {"total": int(r[1]) * 1024, "free": int(r[3]) * 1024}
    return {}


def parse_scrcpy_version(text):
    m = re.search(r"scrcpy\s+v?(\d+(?:\.\d+)*)", str(text))
    return m.group(1) if m else ""


def _mi_unescape(s):
    return _unescape(s)


def parse_mountinfo(text):
    """/proc/self/mountinfo: [{point, fstype, source}]. The mount point and source are octal-unescaped (a space is \\040)."""
    out = []
    for line in str(text).splitlines():
        a, sep, b = line.partition(" - ")
        f = a.split()
        g = b.split()
        if not sep or len(f) < 5 or len(g) < 2:
            continue
        out.append({"point": _mi_unescape(f[4]), "fstype": g[0], "source": _mi_unescape(g[1])})
    return out


def last_error_line(text):
    """The last stderr line that says why: the last one with ERROR / error / failed / cannot in it, else the last non-empty."""
    lines = [l.strip() for l in str(text).splitlines() if l.strip()]
    for l in reversed(lines):
        if re.search(r"ERROR|error|failed|cannot|can't|unable|no devices|not found|refused", l):
            return re.sub(r"^(ERROR|error):\s*", "", l)[:200]
    return lines[-1][:200] if lines else ""


def parse_connect(text):
    """`adb connect` -> (ok, text): ok for "connected to" / "already connected to"."""
    t = str(text).strip()
    return ("connected to" in t and "cannot" not in t and "failed" not in t), t.splitlines()[-1] if t else ""


IDENT_SCRIPT = "echo ==ip; ip -o -4 addr show; echo ==name; settings get global device_name"


def parse_ident(text):
    """The answer of IDENT_SCRIPT -> {addresses: [the phone's IPv4 addresses, loopback left out], name: its device name or ""}.

    Read over the cable to tell which KDE Connect device it is: KDE Connect reports the addresses it reaches the phone on, and the
    name the phone gives itself (Settings, About phone, Device name), which is neither adb's model nor the USB product string."""
    sec, cur = {"ip": [], "name": []}, None
    for line in str(text).splitlines():
        if line.startswith("==") and line[2:].strip() in sec:
            cur = line[2:].strip()
        elif cur:
            sec[cur].append(line)
    addrs = []
    for line in sec["ip"]:
        m = re.search(r"\binet\s+(\d+\.\d+\.\d+\.\d+)/", line)
        if m and not m.group(1).startswith("127.") and m.group(1) not in addrs:
            addrs.append(m.group(1))
    name = next((l.strip() for l in sec["name"] if l.strip()), "")
    return {"addresses": addrs, "name": "" if name == "null" else name}


FACTS_SCRIPT = ("echo ==model; getprop ro.product.model; echo ==android; getprop ro.build.version.release; "
                "echo ==battery; dumpsys battery; echo ==df; df -k /data; "
                "echo ==usb; dumpsys usb | grep screen_unlocked_functions; true")


def parse_facts_blob(text):
    """The answer of FACTS_SCRIPT -> {model, android, storageTotal, storageFree, batteryHealth, batteryTempC, usbUnlocked} (keys it could not read are left out;
    usbUnlocked is "none" or the function the phone switches USB to at every unlock, see parse_usb_unlocked)."""
    sec, cur = {}, None
    for line in str(text).splitlines():
        if line.startswith("==") and line[2:].strip() in ("model", "android", "battery", "df", "usb"):
            cur = line[2:].strip()
            sec[cur] = []
        elif cur:
            sec[cur].append(line)
    out = {}
    one = lambda n: next((l.strip() for l in sec.get(n, []) if l.strip()), "")
    if one("model"):
        out["model"] = one("model")
    if one("android"):
        out["android"] = one("android")
    b = parse_dumpsys_battery("\n".join(sec.get("battery", [])))
    if "health" in b:
        out["batteryHealth"] = b["health"]
    if "tempC" in b:
        out["batteryTempC"] = b["tempC"]
    d = parse_df("\n".join(sec.get("df", [])))
    if d:
        out["storageTotal"], out["storageFree"] = d["total"], d["free"]
    if "usb" in sec:
        out["usbUnlocked"] = parse_usb_unlocked("\n".join(sec["usb"]))
    return out


def parse_usb_unlocked(text):
    """`dumpsys usb`'s `screen_unlocked_functions=MTP` -> "mtp" (lower case: "ptp", "midi", ...); "none" when the line is not there or says
    nothing (what Android switches to at every unlock: with a value it restarts adbd at each lock and unlock, and every adb link drops)."""
    m = re.search(r"screen_unlocked_functions=(\S*)", str(text))
    v = m.group(1).strip().lower() if m else ""
    return v if v and v != "none" else "none"


# What the phone says about its lock, from ONE `adb shell` (Android 16, captured on the real phone 2026-11-19; fixtures lockstate_*.txt):
# `dumpsys trust` (deviceLocked), `dumpsys window` (the focused window, isKeyguardShowing, mDreamingLockscreen), `dumpsys power`
# (mWakefulness) and `dumpsys deviceidle` (mScreenOn, mScreenLocked), each cut down on the phone by grep.
LOCK_SCRIPT = ("echo ==trust; dumpsys trust | grep deviceLocked; "
               "echo ==window; dumpsys window | grep -E 'mCurrentFocus|isKeyguardShowing|mDreamingLockscreen'; "
               "echo ==power; dumpsys power | grep mWakefulness=; "
               "echo ==idle; dumpsys deviceidle | grep -E 'mScreenOn|mScreenLocked'")
KEYGUARD_WINDOWS = re.compile(r"NotificationShade|Keyguard|Bouncer", re.I)


def _flag(text, name):
    m = re.search(r"\b%s=(true|false)\b" % name, text)
    return None if not m else m.group(1) == "true"


def parse_lockstate(text):
    """The answer of LOCK_SCRIPT -> {locked, keyguard, awake, focus}: locked is `deviceLocked=1` of the current user (the first user when none
    says current), and when trust says nothing any of isKeyguardShowing / mDreamingLockscreen / mScreenLocked being true; `focus` is
    "keyguard" when the focused window is NotificationShade, Keyguard or Bouncer, "app" for any other window, "" for none."""
    text = str(text)
    users = [l for l in text.splitlines() if "deviceLocked=" in l]
    cur = next((l for l in users if "(current)" in l), users[0] if users else "")
    m = re.search(r"deviceLocked=(\d)", cur)
    showing = _flag(text, "isKeyguardShowing")
    others = [x for x in (showing, _flag(text, "mDreamingLockscreen"), _flag(text, "mScreenLocked")) if x is not None]
    locked = (m.group(1) == "1") if m else any(others)
    fm = re.search(r"mCurrentFocus=Window\{\S+ u\d+ ([^}]*)\}", text)
    name = fm.group(1).strip() if fm else ""
    focus = "" if not name or name == "null" else "keyguard" if KEYGUARD_WINDOWS.search(name) else "app"
    wm_ = re.search(r"mWakefulness=(\w+)", text)
    on = _flag(text, "mScreenOn")
    awake = (wm_.group(1) == "Awake") if wm_ else (True if on is None else on)
    return {"locked": locked, "keyguard": focus == "keyguard" if showing is None else showing, "awake": awake, "focus": focus}
