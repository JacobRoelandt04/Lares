"""Where session restore keeps things, and the one state file.

  $XDG_STATE_HOME/lares/session/          0700, survives a log-out (the runtime dir does not: Linger=no)
      state.json        {"current": <session>, "candidate": <what the previous session left>}
      rolling.json      the live session's snapshot (the watcher rewrites it when the picture changes)
      snapshots/<id>.json   frozen snapshots, newest `keep` kept; <id> = <YYYYmmdd-HHMMSS>-<reason>
      lock              flock: one restore at a time, one writer of state.json at a time
  $XDG_DATA_HOME/lares/session/presets/   0700: <slug>.json (a version-1 snapshot + "preset"), .trash/ (presets.py)
  $XDG_RUNTIME_DIR/lares-session/                 0700, this boot only
      pending/<token>   a restored terminal's command (session-hook.bash claims it)
      tty/pts-<n>       the running line of each terminal (the hook's mark)

  session   = {"sig", "bootId", "hyprPid", "started", "ended": null | "logout" | "reboot" | "poweroff" | "system",
               "endedHow" (with "system": "reboot" | "poweroff" | "system", the shutdown's job), "endedAt", "endSnapshot",
               "restoring": null | {"snapshot", "since", "done"} | {"preset": slug, "since", "done"}}
  candidate = {"snapshot": id | null, "decision": "none" | "auto" | "ask" | "ask-critical", "cause", "answered": bool,
               "from": <the previous session>}
"""
import contextlib
import fcntl
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import jsonc  # noqa: E402

DEFAULTS = {
    "enabled": False,
    "afterLogout": "ask",       # ask | ask-critical | auto | off   (the user, 2026-11-14: a toast after a log-out too)
    "afterReboot": "ask",       # ask | ask-critical | auto | off
    "afterCrash": "ask",        # ask | off      (never auto)
    "maxAgeHours": 168,
    "run": [],
    "type": [],
    "apps": {},
    "terminals": None,          # None: rules.json's (kitty; capture.py knows no other)
    "skipClasses": None,
    "claude": "resume",         # a Claude Code terminal of a restore: resume | fresh | type
    "presets": {"claude": "fresh", "confirmReplace": True},     # ... of a preset load: fresh | resume; the shell's confirm
    "keep": 5,                  # frozen snapshots
    "resultToast": "always",    # always | needs | off (the shell's)
    "windowTimeoutMs": 10000,
    "appTimeoutMs": 30000,
    "closeTimeoutMs": 8000,     # a preset load with --replace: how long the windows it closed may take to go (an unsaved-changes
                                # dialog keeps one open: it is left and reported)
}


class Paths:
    def __init__(self, env=None):
        env = os.environ if env is None else env
        home = env.get("HOME") or os.path.expanduser("~")
        self.home = home
        self.xdg_config = env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config")
        self.state = os.path.join(env.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state"), "lares", "session")
        self.runtime_base = env.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
        self.runtime = os.path.join(self.runtime_base, "lares-session")
        self.config = os.path.join(env.get("XDG_CONFIG_HOME") or os.path.join(home, ".config"), "quickshell", "config",
                                   "session.jsonc")
        self.cache = env.get("XDG_CACHE_HOME") or os.path.join(home, ".cache")
        self.state_file = os.path.join(self.state, "state.json")
        self.rolling = os.path.join(self.state, "rolling.json")
        self.snapshots = os.path.join(self.state, "snapshots")
        self.lock = os.path.join(self.state, "lock")
        self.pending = os.path.join(self.runtime, "pending")
        # Presets live in the data dir, never under snapshots/ (`keep` rotates those): docs/contracts/session.md "Presets".
        self.data = os.path.join(env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share"), "lares", "session")
        self.presets = os.path.join(self.data, "presets")
        self.presets_trash = os.path.join(self.presets, ".trash")

    def ensure(self):
        for d in (self.state, self.snapshots):
            os.makedirs(d, mode=0o700, exist_ok=True)
        os.makedirs(self.pending, mode=0o700, exist_ok=True)
        for d in (self.state, self.snapshots, self.runtime, self.pending):
            try:
                os.chmod(d, 0o700)
            except OSError:
                pass


def load_config(paths):
    cfg = dict(DEFAULTS)
    try:
        user = jsonc.load(paths.config)
    except OSError:
        user = {}
    except ValueError as e:
        user = {}
        cfg["_error"] = "session.jsonc: %s" % e
    if isinstance(user, dict):
        for k, v in user.items():
            if k in DEFAULTS:
                cfg[k] = v
    if cfg["claude"] not in ("resume", "fresh", "type"):
        cfg["claude"] = DEFAULTS["claude"]
    own = cfg["presets"] if isinstance(cfg["presets"], dict) else {}
    cfg["presets"] = {"claude": "resume" if own.get("claude") == "resume" else "fresh", "confirmReplace": own.get("confirmReplace") is not False}
    if type(cfg["keep"]) is not int or not 1 <= cfg["keep"] <= 100:
        cfg["keep"] = DEFAULTS["keep"]
    return cfg


def load_rules():
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "rules.json"), encoding="utf-8") as f:
        return json.load(f)


def effective(rules, cfg):
    """rules.json with the user's lists laid over: terminals, skipClasses, apps."""
    out = dict(rules)
    if cfg.get("terminals"):
        out["terminals"] = list(cfg["terminals"])
    if cfg.get("skipClasses") is not None:
        out["skipClasses"] = list(rules.get("skipClasses", [])) + list(cfg["skipClasses"])
    apps = dict(rules.get("apps", {}))
    for k, v in (cfg.get("apps") or {}).items():
        if isinstance(v, dict):
            # a `launch` is a list of words; anything else (a string is letters to a list) leaves the built-in one
            launch = v.get("launch")
            if "launch" in v and not (isinstance(launch, list) and launch and all(isinstance(w, str) for w in launch)):
                v = {n: x for n, x in v.items() if n != "launch"}
            apps[k] = dict(apps.get(k, {}), **v)
    out["apps"] = apps
    return out


def atomic_write(path, text, mode=0o600):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, value):
    atomic_write(path, json.dumps(value, indent=1, ensure_ascii=False) + "\n")


@contextlib.contextmanager
def locked(paths, wait=True):
    """The state lock. `wait=False` raises BlockingIOError when someone holds it."""
    paths.ensure()
    fd = os.open(paths.lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        yield
    finally:
        with contextlib.suppress(OSError):
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def load_state(paths):
    st = read_json(paths.state_file, {})
    return st if isinstance(st, dict) else {}


def save_state(paths, st):
    write_json(paths.state_file, st)


def boot_id(proc_root="/proc"):
    try:
        with open(os.path.join(proc_root, "sys", "kernel", "random", "boot_id")) as f:
            return f.read().strip()
    except OSError:
        return ""


# -- snapshots ---------------------------------------------------------------------------------------------------------
def snapshot_id(when, reason):
    return time.strftime("%Y%m%d-%H%M%S", time.localtime(when)) + "-" + reason


def snapshot_path(paths, sid):
    return os.path.join(paths.snapshots, sid + ".json")


def list_snapshots(paths):
    """Newest first: [(id, path)]."""
    try:
        names = [n[:-5] for n in os.listdir(paths.snapshots) if n.endswith(".json")]
    except OSError:
        names = []
    names.sort(reverse=True)
    return [(n, snapshot_path(paths, n)) for n in names]


def freeze(paths, snap, reason, keep=DEFAULTS["keep"]):
    """Keep a snapshot under its own id; the oldest beyond `keep` go."""
    paths.ensure()
    sid = snapshot_id(snap.get("time", time.time()), reason)
    snap = dict(snap, id=sid, reason=reason)
    write_json(snapshot_path(paths, sid), snap)
    for old, path in list_snapshots(paths)[keep:]:
        with contextlib.suppress(OSError):
            os.unlink(path)
    return sid


def load_snapshot(paths, sid=None):
    """A snapshot by id, by index ("1" = newest), or the newest."""
    snaps = list_snapshots(paths)
    if sid is None:
        return read_json(snaps[0][1]) if snaps else None
    if sid.isdigit() and 1 <= int(sid) <= len(snaps):
        return read_json(snaps[int(sid) - 1][1])
    for n, path in snaps:
        if n == sid:
            return read_json(path)
    return None


def summary(snap):
    """"8 windows: kitty x5, VS Code x2, Zen Browser" -- the names a person knows."""
    wins = (snap or {}).get("windows", [])
    apps = {a["id"]: a for a in (snap or {}).get("apps", [])}
    counts = {}
    for w in wins:
        a = apps.get(w.get("app"), {})
        name = a.get("name") or w.get("class") or "?"
        counts[name] = counts.get(name, 0) + 1
    parts = ["%s x%d" % (n, c) if c > 1 else n for n, c in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0].lower()))]
    n = len(wins)
    return "%d window%s%s" % (n, "" if n == 1 else "s", ": " + ", ".join(parts) if parts else "")
