"""The snapshot rules the root tool and the user's CLI share (contract: docs/contracts/snapshots.md).

Pure functions, stdlib only. The root tool installs a copy of this file beside itself, and SnapshotRules.js is its twin for the
rule (`wants`, `notable`, `title`): both are held to ONE table, tools/dev/snapshot_rule_cases.json.

    wants(names, settings)        -> {"want", "count", "critical"}   section 4
    notable(critical)             -> at most 4 names, list order
    title(record)                 -> the line the rescue menu and the popup show (ASCII, at most 60 characters)
    settings_from(raw, defaults)  -> (settings, problems)            section 8, every clamp
    read_config(candidates, uid)  -> (raw or None, problems)         the file as DATA: no links, owned by you, small
    run_id(pid, proc)             -> "<pid>:<starttime>" of the run the process belongs to, or None
    installed(root)              -> {name: version} from pacman's local database
    changed(before, now)         -> [{"name", "from", "to"}]
"""
import datetime
import json
import os
import re
import stat
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
if os.geteuid() != 0 and not os.path.exists(os.path.join(HERE, "jsonc.py")):
    # in the repo jsonc.py lives in tools/lib; an installed copy has it beside this file, and root never reaches into a tree
    sys.path.insert(0, os.path.join(HERE, "..", "..", "lib"))
import jsonc  # noqa: E402

RUN_PROGRAMS = ("yay", "paru", "pikaur", "aura", "pamac", "pacman")
MAX_CONFIG_BYTES = 64 * 1024
CLAMPS = {"keep": (1, 50), "minFreeGB": (1, 500), "maxAddedGB": (1, 500), "maxMinutes": (1, 120)}
EXCLUDE_ROOTS = ("/var/lib", "/opt", "/srv", "/root", "/usr/local")
SETTING_KEYS = ("enabled", "rule", "keep", "minFreeGB", "maxAddedGB", "maxMinutes", "prime", "exclude", "onFail", "offsite")
NOTABLE_MAX = 4
TITLE_MAX = 60


def load_defaults(path=None):
    with open(path or os.path.join(HERE, "defaults.json"), encoding="utf-8") as f:
        return json.load(f)


# ---- the rule -------------------------------------------------------------------------------------------------------------------

def glob_match(pattern, name):
    """`*` is the only wildcard and the whole name must match, case sensitive."""
    parts = pattern.split("*")
    if len(parts) == 1:
        return pattern == name
    first, last = parts[0], parts[-1]
    if not name.startswith(first) or len(name) - len(last) < len(first) or not name.endswith(last):
        return False
    pos, end = len(first), len(name) - len(last)
    for mid in parts[1:-1]:
        i = name.find(mid, pos)
        if i < 0 or i + len(mid) > end:
            return False
        pos = i + len(mid)
    return True


def critical_globs(settings):
    rule = settings.get("rule") or {}
    seen, out = set(), []
    for g in list(rule.get("critical") or []) + list(rule.get("criticalAlso") or []):
        if g not in seen:
            seen.add(g)
            out.append(g)
    return out


def wants(names, settings):
    """The packages the transaction upgrades or installs. A package that matches several globs is listed once, at the first."""
    uniq = sorted(set(n for n in names if n))
    crit, seen = [], set()
    for g in critical_globs(settings):
        for n in uniq:
            if n not in seen and glob_match(g, n):
                seen.add(n)
                crit.append(n)
    minp = (settings.get("rule") or {}).get("minPackages", 40)
    return {"want": len(uniq) >= minp or bool(crit), "count": len(uniq), "critical": crit}


def notable(critical):
    return list(critical)[:NOTABLE_MAX]


def title(record):
    reason = record.get("reason")
    if reason == "manual":
        return "Manual"
    if reason == "undo":
        if not record.get("undoneTime"):
            return "Before an undo"
        return "Before undoing the update of " + datetime.datetime.fromtimestamp(record["undoneTime"]).strftime("%Y-%m-%d")
    if reason == "rescue":
        return "Before the restore of " + datetime.datetime.fromtimestamp(record.get("time") or 0).strftime("%Y-%m-%d")
    head = "Before %d packages" % record.get("count", 0)
    shown = notable(record.get("critical") or [])
    while shown:
        t = head + ": " + ", ".join(shown)
        if len(t) <= TITLE_MAX:
            return t
        shown = shown[:-1]
    return head


# ---- the settings ---------------------------------------------------------------------------------------------------------------

def _clean_globs(v, what, problems):
    ok = isinstance(v, list) and len(v) <= 200 and all(isinstance(g, str) and 0 < len(g) <= 100 and " " not in g for g in v)
    if not ok:
        problems.append("%s must be a list of package names or patterns; the default is used" % what)
    return v if ok else None


def exclude_problem(p):
    """Why a user's exclude is refused, or None. Absolute, normalised, below a root the user may thin, never pacman's own state."""
    if not isinstance(p, str) or not p or len(p) > 1000 or "\0" in p or "\n" in p:
        return "is not a path"
    if not p.startswith("/") or os.path.normpath(p) != p:
        return "must be an absolute, normalised path"
    if re.search(r"[*?\[\]\\]", p):
        return "may not hold wildcards (a pattern could reach pacman's own files)"
    if p == "/var/lib/pacman" or p.startswith("/var/lib/pacman/"):
        return "is pacman's own database, which a snapshot always keeps"
    if not any(p.startswith(r + "/") for r in EXCLUDE_ROOTS):
        return "must be below /var/lib, /opt, /srv, /root or /usr/local"
    return None


def settings_from(raw, defaults):
    """Every key, the file's value where it is the right type (clamped), else the default and a line in `problems`."""
    problems = []
    s = json.loads(json.dumps({k: defaults[k] for k in SETTING_KEYS}))   # a private copy of what the user can set
    if raw is None:
        return s, problems
    if not isinstance(raw, dict):
        return s, ["snapshots.jsonc must hold one object; the defaults are used"]
    for key in ("enabled", "prime"):
        if key in raw:
            if isinstance(raw[key], bool):
                s[key] = raw[key]
            else:
                problems.append("%s must be true or false; the default is used" % key)
    r = raw.get("rule")
    if r is not None and not isinstance(r, dict):
        problems.append("rule must be an object; the default is used")
        r = {}
    r = r or {}
    if "minPackages" in r:
        v = r["minPackages"]
        if isinstance(v, int) and not isinstance(v, bool):
            s["rule"]["minPackages"] = max(1, min(9999, v))
            if s["rule"]["minPackages"] != v:
                problems.append("rule.minPackages %d was set to %d (the range is 1 to 9999)" % (v, s["rule"]["minPackages"]))
        else:
            problems.append("rule.minPackages must be a whole number; the default is used")
    for key in ("critical", "criticalAlso"):
        if key in r:
            v = _clean_globs(r[key], "rule." + key, problems)
            if v is not None:
                s["rule"][key] = v
    for key, (lo, hi) in CLAMPS.items():
        if key in raw:
            v = raw[key]
            if isinstance(v, int) and not isinstance(v, bool):
                s[key] = max(lo, min(hi, v))
                if s[key] != v:
                    problems.append("%s %d was set to %d (the range is %d to %d)" % (key, v, s[key], lo, hi))
            else:
                problems.append("%s must be a whole number; the default is used" % key)
    if "exclude" in raw:
        v = raw["exclude"]
        if isinstance(v, list) and len(v) <= 100:
            good = []
            for p in v:
                why = exclude_problem(p)
                if why:
                    problems.append("exclude %s %s; it is ignored" % (json.dumps(p)[:80], why))
                else:
                    good.append(p)
            s["exclude"] = good
        else:
            problems.append("exclude must be a list of paths; the default is used")
    if "onFail" in raw:
        if raw["onFail"] in ("stop", "continue"):
            s["onFail"] = raw["onFail"]
        else:
            problems.append('onFail must be "stop" or "continue"; the default is used')
    o = raw.get("offsite")
    if o is not None and not isinstance(o, dict):
        problems.append("offsite must be an object; the default is used")
        o = {}
    for key, kind in (("enabled", bool), ("onBattery", bool), ("metered", bool), ("folder", str)):
        if o and key in o:
            v = o[key]
            if isinstance(v, kind) and (kind is bool or (v and len(v) <= 300 and "\0" not in v)):
                s["offsite"][key] = v
            else:
                problems.append("offsite.%s has the wrong type; the default is used" % key)
    machine = (o or {}).get("machine", "")
    if machine != "" and not (isinstance(machine, str) and re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$", machine)):
        problems.append("offsite.machine is no folder name (letters, digits, dot, dash, underscore); the host's name is used")
    return s, problems


def read_config(candidates, uid):
    """The first candidate that exists, read as data. A link, a file that is not yours, a big or a broken file means the defaults."""
    for path in candidates:
        if not os.path.lexists(path):
            continue
        name = os.path.basename(path)
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        except OSError:
            return None, ["%s cannot be opened (a link is never followed); the defaults are used" % name]
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode):
                return None, ["%s is not a regular file; the defaults are used" % name]
            if st.st_uid != uid:
                return None, ["%s is not owned by you; the defaults are used" % name]
            if st.st_size > MAX_CONFIG_BYTES:
                return None, ["%s is larger than 64 KB; the defaults are used" % name]
            with os.fdopen(fd, "rb", closefd=False) as f:
                data = f.read(MAX_CONFIG_BYTES + 1)
        finally:
            os.close(fd)
        try:
            return jsonc.loads(data.decode("utf-8")), []
        except ValueError as e:
            return None, ["%s does not parse (%s); the defaults are used" % (name, str(e)[:60])]
    return None, []


# ---- the run, the packages ------------------------------------------------------------------------------------------------------

def _stat_fields(proc, pid):
    """(comm, ppid, starttime) from /proc/<pid>/stat; the name may hold spaces and brackets, so split at the LAST ')'."""
    with open("%s/%d/stat" % (proc, pid), encoding="utf-8", errors="replace") as f:
        raw = f.read()
    left, right = raw.index("("), raw.rindex(")")
    rest = right + 2
    fields = raw[rest:].split()
    return raw[left + 1:right], int(fields[1]), fields[19]


def run_id(pid, proc="/proc"):
    """The TOP-MOST ancestor of `pid` whose name is a package manager, as `<pid>:<starttime>`; None when no ancestor is one."""
    found, seen = None, set()
    while pid > 1 and pid not in seen and len(seen) < 64:
        seen.add(pid)
        try:
            comm, ppid, start = _stat_fields(proc, pid)
        except (OSError, ValueError, IndexError):
            break
        if comm in RUN_PROGRAMS:
            found = "%d:%s" % (pid, start)
        pid = ppid
    return found


def _cmdline(proc, pid):
    try:
        with open("%s/%d/cmdline" % (proc, pid), "rb") as f:
            return f.read().decode("utf-8", "replace").split("\0")
    except OSError:
        return []


def undo_run(pid, proc="/proc"):
    """None, or the short id being undone ("" when not known) when an ancestor of `pid` is `lares-snapshot undo <short>` or
    `update-run.sh --kind undo`. The nearest ancestor speaks first: the CLI names the snapshot, the run script does not."""
    seen = set()
    while pid > 1 and pid not in seen and len(seen) < 64:
        seen.add(pid)
        argv = _cmdline(proc, pid)
        for i, a in enumerate(argv):
            base = os.path.basename(a)
            if base == "lares-snapshot" and argv[i + 1:i + 2] == ["undo"]:
                short = argv[i + 2] if len(argv) > i + 2 else ""
                return "" if short.startswith("-") else short
            if base == "update-run.sh" and "--kind" in argv and argv[argv.index("--kind") + 1:argv.index("--kind") + 2] == ["undo"]:
                return ""
        try:
            pid = _stat_fields(proc, pid)[1]
        except (OSError, ValueError, IndexError):
            break
    return None


def installed(root=""):
    """name -> version of every installed package, from the names of pacman's local database directories (`name-version-release`)."""
    out = {}
    base = root + "/var/lib/pacman/local"
    try:
        entries = os.listdir(base)
    except OSError:
        return out
    for d in entries:
        parts = d.rsplit("-", 2)
        if len(parts) == 3 and os.path.isfile(os.path.join(base, d, "desc")):
            out[parts[0]] = "%s-%s" % (parts[1], parts[2])
    return out


def changed(before, now):
    out = []
    for name in sorted(set(before) | set(now)):
        a, b = before.get(name), now.get(name)
        if a != b:
            out.append({"name": name, "from": a, "to": b})
    return out
