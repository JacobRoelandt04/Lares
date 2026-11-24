"""Where the bridge keeps things, the config and the one state file.

  $XDG_STATE_HOME/lares/bridge/        0700, survives a log-out
      state.json      { links: {<kdc id>: <adb serial>}, prefs: {<key>: {...}}, lastSeen: {<key>: s}, current: <key>,
                        facts: {<key>: {...}}, pins: {<key>: "set" | "failed"} }
                      (facts: what `facts` read, for the watch line; pins: whether the login keyring keeps an unlock PIN for the phone
                      and whether the last unlock with it failed -- never the PIN: that lives in the keyring only, bridgelib/keyring.py)
      unlock.lock     the flock that makes one unlock at a time
  $XDG_RUNTIME_DIR/lares/bridge/       0700, this boot only
      jobs/<id>.json  one record per job             adb-started   {at: <s>}: present while the adb server is ours
      tries.json      { <key>: { <action>: {reason, hint, at} } }: why the last try of an action failed
      wifipair.json   { key, name, state: waiting | paired | failed | expired, reason, png, at }: a Wireless debugging pairing
      wifipair.png    its QR code (Android: Wireless debugging > Pair device with QR code)
      mine.json       { <mount point>: { device, at } }: the mounts this tool made
  $XDG_CACHE_HOME/lares/bridge/        0700, what happened, for whoever reads it after a test on the real phone (trace.py)
      trace.jsonl     one line per watch line, one-shot, command run and cable ident (rotated at 2 MB to trace.1.jsonl)
      jobs/<stamp>-<id>.log   the whole output of a job's program (the last 30 are kept)
  The cache holds the phone's serial and addresses: it is never copied into the repo.

Test overrides: LARES_BRIDGE_CONFIG (a config file), LARES_BRIDGE_STATE, LARES_BRIDGE_RUNTIME, LARES_BRIDGE_CACHE (dirs; with
LARES_BRIDGE_STATE set and no LARES_BRIDGE_CACHE the cache is <state>-cache beside it, so a test never writes the user's), LARES_BRIDGE_SYS (a fake
/sys root for USB), LARES_BRIDGE_MOUNTINFO (a file in /proc/self/mountinfo's format), LARES_BRIDGE_ENOTCONN (mount points that
read as stale). The files here are written whole through tools/lib/atomic.py and are never an address: no IP is ever stored.
"""
import copy
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import atomic  # noqa: E402
import jsonc  # noqa: E402

DEFAULTS = {
    "files": {"usbMount": "/mnt/android",
              "open": ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", "{path}"],
              "sendDir": "/sdcard/Download", "pickDir": "~"},
    "mirror": {"usb": {"maxSize": 0, "bitRate": "", "maxFps": 0},
               "wifi": {"maxSize": 1600, "bitRate": "6M", "maxFps": 60},
               "recordDir": "~/Videos", "extraArgs": []},
    "adb": {"start": "onDemand", "idleKillS": 300, "port": 5555},
    "shots": {"dir": "~/Pictures/Screenshots"},
    "flip": {"onOpen": True},
    # unlock, keys, sleepAtEnd, the files' pickDir and lookKey are the shell's (BridgeModel.parseConfig): here so the example is the defaults
    "cast": {"closeAfterS": 120, "reloadOnResize": True, "desktopScale": 1.0, "desktopMinDp": 320, "desktopMinPx": 640, "holdMin": 30,
             "unlock": "start+touch", "keys": {"back": "Left", "home": "Down", "recents": "Right"}, "sleepAtEnd": True},
    "relight": True,
    "lookKey": "alt",
    "devices": {},
}

# keepWireless is ON by default (the user's call 2026-11-19: "ready at all times to be connected to wirelessly, as little priming as
# possible"): every plug-in arms adb on the LAN until the phone restarts. wifiDebug: this computer is paired for Android's Wireless
# debugging (set by `_pairwait` when a QR pairing lands): a plug-in then also switches Wireless debugging on, so a restart costs the
# phone's quick tile and no cable.
PREF_DEFAULTS = {"keepWireless": True, "mode": "mirror", "screenOff": False, "record": False, "wifiDebug": False, "castAudio": False,
                "usbUnlockMtp": False}
MODES = ("mirror", "desktop", "camera", "audio")


class Paths:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        home = env.get("HOME") or os.path.expanduser("~")
        self.home = home
        self.state = env.get("LARES_BRIDGE_STATE") or os.path.join(
            env.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state"), "lares", "bridge")
        base = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
        self.runtime_base = base
        self.runtime = env.get("LARES_BRIDGE_RUNTIME") or os.path.join(base, "lares", "bridge")
        self.config = env.get("LARES_BRIDGE_CONFIG") or os.path.join(
            env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "quickshell", "config", "bridge.jsonc")
        self.cache = env.get("LARES_BRIDGE_CACHE") or (self.state.rstrip("/") + "-cache" if env.get("LARES_BRIDGE_STATE") else
                                                         os.path.join(env.get("XDG_CACHE_HOME") or os.path.join(home, ".cache"),
                                                                      "lares", "bridge"))
        self.sys_root = env.get("LARES_BRIDGE_SYS") or ""
        self.mountinfo = env.get("LARES_BRIDGE_MOUNTINFO") or "/proc/self/mountinfo"
        self.enotconn = [p for p in (env.get("LARES_BRIDGE_ENOTCONN") or "").split(",") if p]
        self.state_file = os.path.join(self.state, "state.json")
        self.jobs = os.path.join(self.runtime, "jobs")
        self.adb_started = os.path.join(self.runtime, "adb-started")
        self.tries = os.path.join(self.runtime, "tries.json")
        self.mine = os.path.join(self.runtime, "mine.json")
        self.wifipair = os.path.join(self.runtime, "wifipair.json")
        self.wifipair_png = os.path.join(self.runtime, "wifipair.png")
        self.seq = os.path.join(self.jobs, ".seq")
        self.idle_lock = os.path.join(self.runtime, "adb-idle.lock")

    def ensure(self):
        for d in (self.state, self.runtime, self.jobs):
            os.makedirs(d, mode=0o700, exist_ok=True)
        for d in (self.state, self.runtime, self.jobs):
            try:
                os.chmod(d, 0o700)
            except OSError:
                pass

    def expand(self, p):
        p = str(p)
        if p == "~":
            return self.home
        if p.startswith("~/"):
            return os.path.join(self.home, p[2:])
        return p


# ---- the config ---------------------------------------------------------------------------------------------------------
def _str(v, d):
    return v if isinstance(v, str) and v.strip() else d


def _int(v, d, lo, hi):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v:
        return d
    return int(min(hi, max(lo, v)))


def _real(v, d, lo, hi):
    if isinstance(v, bool) or not isinstance(v, (int, float)) or v != v or v in (float("inf"), float("-inf")):
        return d
    return float(min(hi, max(lo, v)))


def _strlist(v, d):
    if isinstance(v, list) and all(isinstance(x, str) for x in v):
        return list(v)
    return list(d)


def _bool(v, d):
    return v if isinstance(v, bool) else d


def clamp(user):
    """The user's parsed config laid over the defaults, every bad value back to its default; never raises."""
    u = user if isinstance(user, dict) else {}
    d = copy.deepcopy(DEFAULTS)
    f, m, a = u.get("files"), u.get("mirror"), u.get("adb")
    f = f if isinstance(f, dict) else {}
    m = m if isinstance(m, dict) else {}
    a = a if isinstance(a, dict) else {}
    out = d
    out["files"]["usbMount"] = _str(f.get("usbMount"), d["files"]["usbMount"])
    out["files"]["open"] = _strlist(f.get("open"), d["files"]["open"]) or list(d["files"]["open"])
    out["files"]["sendDir"] = _str(f.get("sendDir"), d["files"]["sendDir"])
    for t in ("usb", "wifi"):
        s = m.get(t) if isinstance(m.get(t), dict) else {}
        dd = DEFAULTS["mirror"][t]
        br = s.get("bitRate", dd["bitRate"])
        ok = isinstance(br, str) and (br == "" or (br[:-1].isdigit() and br[-1] in "KkMm") or br.isdigit())
        out["mirror"][t] = {"maxSize": _int(s.get("maxSize"), dd["maxSize"], 0, 16384),
                            "bitRate": br if ok else dd["bitRate"],
                            "maxFps": _int(s.get("maxFps"), dd["maxFps"], 0, 240)}
    out["mirror"]["recordDir"] = _str(m.get("recordDir"), d["mirror"]["recordDir"])
    out["mirror"]["extraArgs"] = _strlist(m.get("extraArgs"), [])
    st = a.get("start")
    out["adb"]["start"] = st if st in ("onDemand", "onPlug") else "onDemand"
    out["adb"]["idleKillS"] = _int(a.get("idleKillS"), 300, 5, 86400)
    out["adb"]["port"] = _int(a.get("port"), 5555, 1024, 65535)
    sh = u.get("shots") if isinstance(u.get("shots"), dict) else {}
    out["shots"]["dir"] = _str(sh.get("dir"), d["shots"]["dir"])
    fl = u.get("flip") if isinstance(u.get("flip"), dict) else {}
    out["flip"]["onOpen"] = _bool(fl.get("onOpen"), True)
    ca = u.get("cast") if isinstance(u.get("cast"), dict) else {}
    out["cast"]["closeAfterS"] = _int(ca.get("closeAfterS"), 120, 5, 86400)
    out["cast"]["reloadOnResize"] = _bool(ca.get("reloadOnResize"), True)
    out["cast"]["desktopScale"] = _real(ca.get("desktopScale"), 1.0, 0.5, 3.0)
    out["cast"]["desktopMinDp"] = _int(ca.get("desktopMinDp"), 320, 240, 1200)
    out["cast"]["desktopMinPx"] = _int(ca.get("desktopMinPx"), 640, 320, 2400)
    # how long a Mirror's hold keeps the screen on without a touch (the phone's screen_off_timeout while the cast runs), minutes
    out["cast"]["holdMin"] = _real(ca.get("holdMin"), 30, 1, 240)
    out["relight"] = _bool(u.get("relight"), True)
    devs = {}
    if isinstance(u.get("devices"), dict):
        for k, v in u["devices"].items():
            if isinstance(v, dict):
                e = {}
                if isinstance(v.get("skin"), str) and v["skin"]:
                    e["skin"] = v["skin"]
                if isinstance(v.get("hidden"), bool):
                    e["hidden"] = v["hidden"]
                devs[str(k)] = e
    out["devices"] = devs
    return out


def load_config(paths):
    """(config, error): the error is a sentence or ""; a missing file is the defaults and no error."""
    try:
        user = jsonc.load(paths.config)
    except OSError:
        return clamp({}), ""
    except ValueError as e:
        return clamp({}), "bridge.jsonc: %s" % e
    return clamp(user), ""


# ---- the state file -----------------------------------------------------------------------------------------------------
def read_json(path, default):
    v = atomic.read_json(path, default)
    return v if isinstance(v, type(default)) else default


def write_private(path, obj):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    atomic.write_json(path, obj)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def load_state(paths):
    s = read_json(paths.state_file, {})
    out = {"links": {}, "prefs": {}, "lastSeen": {}, "current": "", "facts": {}, "pins": {}}
    for k in ("links", "prefs", "lastSeen", "facts", "pins"):
        if isinstance(s.get(k), dict):
            out[k] = s[k]
    if isinstance(s.get("current"), str):
        out["current"] = s["current"]
    return out


def looks_like_address(serial):
    """host:port, the way adb names a TCP transport (an mDNS name `adb-<serial>-x._adb-tls-connect._tcp` counts too)."""
    s = str(serial)
    if "._adb-tls-" in s:
        return True
    head, _, port = s.rpartition(":")
    return bool(head) and port.isdigit()


def save_state(paths, state):
    """Writes the state; never an address (a link to a TCP serial is dropped here, whoever asked)."""
    paths.ensure()
    out = dict(state)
    out["links"] = {k: v for k, v in state.get("links", {}).items() if isinstance(v, str) and not looks_like_address(v)}
    write_private(paths.state_file, out)


def adopt(state, old, new):
    """A device that was known under `old` (a cable-only "adb:<serial>") turns out to be `new` (its KDE Connect id): what was kept
    under the old key moves over. The new key's own values win; lastSeen keeps the later one; `current` follows. -> changed"""
    changed = False
    for table in ("prefs", "facts", "pins"):
        t = state.get(table, {})
        if old in t:
            moved = t.pop(old)
            have = t.get(new)
            if isinstance(moved, dict) and isinstance(have, dict):
                if table == "facts":
                    t[new] = moved if moved.get("at", 0) > have.get("at", 0) else have
                else:
                    t[new] = dict(moved, **have)
            elif have is None:
                t[new] = moved
            changed = True
    ls = state.get("lastSeen", {})
    if old in ls:
        ls[new] = max(int(ls.pop(old) or 0), int(ls.get(new, 0) or 0))
        changed = True
    if state.get("current") == old:
        state["current"] = new
        changed = True
    return changed


def pin_of(state, key):
    """"none" | "set" | "failed": whether an unlock PIN is kept for the device and whether the last unlock with it failed."""
    v = state.get("pins", {}).get(key)
    return v if v in ("set", "failed") else "none"


def prefs_of(state, key):
    p = dict(PREF_DEFAULTS)
    stored = state.get("prefs", {}).get(key)
    if isinstance(stored, dict):
        for k, v in stored.items():
            if k in PREF_DEFAULTS and isinstance(v, type(PREF_DEFAULTS[k])):
                p[k] = v
    if p["mode"] not in MODES:
        p["mode"] = PREF_DEFAULTS["mode"]
    return p


def check_pref(name, value):
    """(ok, why) for `set <dev> <pref> <value>`."""
    if name not in PREF_DEFAULTS:
        return False, "unknown preference %s (%s)" % (name, ", ".join(PREF_DEFAULTS))
    if name == "mode":
        return (value in MODES), "mode is one of %s" % ", ".join(MODES)
    return isinstance(value, bool), "%s is true or false" % name


def dumps(obj):
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=False)
