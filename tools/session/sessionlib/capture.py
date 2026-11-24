"""One snapshot of the session: every window, where it is, and how to start what is in it.

    {"version": 1, "time", "sig", "bootId", "hook": bool,
     "monitors": [{"name", "x", "y", "width", "height", "scale", "workspace", "special"}],
     "focus": address | null,
     "apps":    [{"id", "kind": "terminal" | "gui", "class", "name", "pid", "count", "argv", "cwd",
                  "launch": [argv] | null, "selfRestore", "skip", "why",
                  "terminal": {"opts", "program", "shell", "cwd", "job"} }],
     "windows": [{"id", "app", "address", "class", "initialClass", "title", "initialTitle",
                  "workspace": {"key", "name", "special"}, "monitor", "floating", "at", "size",
                  "fullscreen", "fullscreenClient", "pinned", "group": {"id", "index", "active"} | null,
                  "tags", "focus", "xwayland"}]}

`at` is relative to the window's monitor (a floating window goes back to the same place on a monitor that moved).
An app is one PROCESS: several windows of one pid are one app (`count`), started once.
"""
import os
import shlex
import shutil
import time

from . import plan as planlib
from . import procs
from . import vscode

# kitty's options that take a value (kitty --help, 0.50): everything else before the program is a flag.
KITTY_VALUE = {"-o", "--override", "-T", "--title", "--class", "--app-id", "--name", "--os-window-tag", "-c", "--config",
               "-d", "--directory", "--working-directory", "--session", "--listen-on", "--start-as", "--instance-group",
               "-w", "--watcher", "--position", "--wait-for-single-instance-window-close"}
KITTY_DIR = {"-d", "--directory", "--working-directory"}


def split_kitty(argv):
    """kitty's argv -> (options without any working directory, the program's argv)."""
    opts, i = [], 1
    while i < len(argv):
        a = argv[i]
        if a == "--":
            return opts, argv[i + 1:]
        if a.startswith("--") and "=" in a:
            if a.split("=", 1)[0] not in KITTY_DIR:
                opts.append(a)
        elif a in KITTY_VALUE:
            if a not in KITTY_DIR:
                opts.extend(argv[i:i + 2])
            i += 1
        elif a.startswith("-") and len(a) > 1:
            if not (len(a) > 2 and a[:2] == "-d" and not a.startswith("--")):
                opts.append(a)
        else:
            return opts, argv[i:]
        i += 1
    return opts, []


class Desktops:
    """The installed .desktop entries, enough to start an app the way its launcher does."""

    def __init__(self, env=None):
        env = os.environ if env is None else env
        home = env.get("HOME") or os.path.expanduser("~")
        data_home = env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
        dirs = [data_home] + (env.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":")
        self.entries = {}
        for d in dirs:
            appdir = os.path.join(d, "applications")
            try:
                names = sorted(os.listdir(appdir))
            except OSError:
                continue
            for n in names:
                if n.endswith(".desktop") and n not in self.entries:
                    e = self._parse(os.path.join(appdir, n))
                    if e:
                        self.entries[n] = e

    @staticmethod
    def _parse(path):
        e, section = {}, ""
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("["):
                        section = line
                    elif section == "[Desktop Entry]" and "=" in line:
                        k, v = line.split("=", 1)
                        if k in ("Name", "Exec", "StartupWMClass", "Terminal", "Type", "Hidden"):
                            e.setdefault(k, v)
        except OSError:
            return None
        if e.get("Type", "Application") != "Application" or "Exec" not in e or e.get("Hidden") == "true":
            return None
        return e

    def find(self, cls, initial_class, argv):
        want = {c.lower() for c in (cls, initial_class) if c}
        for n, e in self.entries.items():
            if e.get("StartupWMClass", "").lower() in want:
                return n, e
        for n, e in self.entries.items():
            if n[:-8].lower() in want:
                return n, e
        exe = os.path.basename(argv[0]) if argv else ""
        if exe:
            for n, e in self.entries.items():
                try:
                    words = shlex.split(e["Exec"])
                except ValueError:
                    continue
                words = [w for w in words if "=" not in w and w != "env"]
                if words and os.path.basename(words[0]) == exe:
                    return n, e
        return None, None

    @staticmethod
    def command(entry, docs):
        """Exec with its field codes filled: the documents for %f %F %u %U, the rest dropped."""
        try:
            words = shlex.split(entry["Exec"])
        except ValueError:
            return None
        out, used = [], False
        for w in words:
            if w in ("%f", "%u"):
                out.extend(docs[:1])
                used = True
            elif w in ("%F", "%U"):
                out.extend(docs)
                used = True
            elif w.startswith("%") and len(w) == 2:
                continue
            else:
                out.append(w.replace("%%", "%"))
        if docs and not used:
            out.extend(docs)
        return out or None


def _documents(argv, cwd):
    """The arguments that name something to open: existing paths (made absolute) and URLs."""
    docs = []
    for a in argv[1:]:
        if a.startswith("-"):
            continue
        if "://" in a:
            docs.append(a)
            continue
        p = a if os.path.isabs(a) else os.path.join(cwd or "/", a)
        if os.path.exists(p):
            docs.append(os.path.normpath(p))
    return docs


def _ws(c):
    w = c.get("workspace") or {}
    name = w.get("name") or ""
    staged = planlib.stage_target(name)
    if staged:
        return staged           # a window still on a restore's staging workspace belongs to the workspace that stands for
    wid = w.get("id")
    key = wid if isinstance(wid, int) and wid > 0 else name
    return {"key": key, "name": name, "special": name.startswith("special")}


def capture(hy, proc, paths, rules, desktops=None, env=None):
    env = os.environ if env is None else env
    clients = hy.json("clients")
    monitors = hy.json("monitors")
    proc.forget()
    desktops = desktops or Desktops(env)

    mons = {}
    out_mons = []
    for m in monitors:
        mons[m.get("id")] = m
        special = (m.get("specialWorkspace") or {}).get("name") or ""
        aw = m.get("activeWorkspace") or {}
        out_mons.append({"name": m.get("name"), "x": m.get("x", 0), "y": m.get("y", 0), "width": m.get("width", 0),
                         "height": m.get("height", 0), "scale": m.get("scale", 1),
                         "workspace": aw.get("id") if isinstance(aw.get("id"), int) and aw.get("id") > 0 else aw.get("name"),
                         "special": special, "focused": bool(m.get("focused"))})

    skip = set(rules.get("skipClasses", []))
    kept = [c for c in clients
            if c.get("mapped", True) and c.get("pid", 0) > 0 and c.get("class") not in skip
            and (c.get("class") or c.get("title"))]
    kept.sort(key=lambda c: c.get("address", ""))

    # Groups: every member reports the same ordered list. Whether a group is LOCKED is in no hyprctl answer: Lua knows.
    locks = hy.group_locks(paths.runtime)
    groups, gids = {}, {}
    for c in kept:
        g = c.get("grouped") or []
        if len(g) > 0:
            key = tuple(g)
            if key not in gids:
                gids[key] = "g%d" % (len(gids) + 1)
            groups[c["address"]] = (gids[key], g.index(c["address"]) if c["address"] in g else 0, key)
    active_of = {}
    by_addr = {c["address"]: c for c in kept}
    for key, gid in gids.items():
        members = [by_addr[a] for a in key if a in by_addr]
        # The tab on show is the one member Hyprland calls `visible` (also on a workspace that is not shown; measured on
        # 0.57.2 -- `hidden` is false for every tab). A fullscreen window over the group leaves none: then the member that
        # takes input, then the one focused last.
        shown = [m for m in members if m.get("visible")]
        if len(shown) != 1:
            shown = [m for m in members if m.get("acceptsInput")]
        if len(shown) != 1:
            shown = sorted(members, key=lambda m: m.get("focusHistoryID", 1 << 30))[:1]
        if shown:
            active_of[gid] = shown[0]["address"]

    # Apps: one per pid (and class: a pid can own windows of two classes).
    apps, app_of = [], {}
    term_cache = {}
    me = procs.ancestry(proc, os.getpid())      # the command taking this picture is no job of the session
    hook_seen = os.path.isdir(os.path.join(paths.runtime, "tty"))
    for c in kept:
        key = (c["pid"], c.get("class"))
        if key in app_of:
            apps[app_of[key]]["count"] += 1
            continue
        argv = proc.cmdline(c["pid"])
        cwd = proc.cwd(c["pid"])
        app = {"id": "a%d" % (len(apps) + 1), "kind": "gui", "class": c.get("class"), "name": c.get("class"),
               "pid": c["pid"], "count": 1, "argv": argv, "cwd": cwd, "launch": None, "selfRestore": False,
               "skip": False, "why": ""}
        rule = rules.get("apps", {}).get(c.get("class")) or rules.get("apps", {}).get(c.get("initialClass")) or {}
        # A kitty window keeps any class (`kitty --class x`): the PROCESS says it is a terminal.
        is_kitty = bool(argv) and os.path.basename(argv[0]) == "kitty" and "kitty" in rules.get("terminals", [])
        if is_kitty:
            app["kind"] = "terminal"
            app["name"] = "kitty"
            if c["pid"] not in term_cache:
                term_cache[c["pid"]] = procs.terminal_windows(proc, c["pid"], paths.runtime_base, paths.home, me)
            wins = term_cache[c["pid"]]
            opts, program = split_kitty(argv)
            term = {"opts": opts, "program": program, "shell": False, "cwd": cwd, "job": None, "rootArgv": []}
            if wins:
                w0 = wins[0]
                term["shell"] = w0["shell"]
                term["rootArgv"] = w0["root"]["argv"]
                term["cwd"] = w0["root"]["cwd"] or cwd
                if w0["job"]:
                    j = w0["job"]
                    term["job"] = {"tops": [{"argv": t["argv"]} for t in j["tops"]],
                                   "typed": j["typed"], "root": j["root"], "claude": j["claude"]}
                if len(wins) > 1:
                    app["why"] = "%d terminals in one kitty process: the first is restored" % len(wins)
            app["terminal"] = term
            app["launch"] = [argv[0]] + (["--directory", term["cwd"]] if term["cwd"] else []) + opts + program
        else:
            name, entry = desktops.find(c.get("class"), c.get("initialClass"), argv)
            if entry:
                app["name"] = entry.get("Name") or app["name"]
                app["desktop"] = name
            app["selfRestore"] = bool(rule.get("selfRestore"))
            docs = [] if app["selfRestore"] else _documents(argv, cwd)
            if rule.get("launch"):
                app["launch"] = list(rule["launch"])
            elif entry and entry.get("Terminal") != "true" and Desktops.command(entry, docs):
                app["launch"] = Desktops.command(entry, docs)
            elif argv and (os.path.isabs(argv[0]) and os.access(argv[0], os.X_OK) or shutil.which(argv[0])):
                app["launch"] = list(argv)
            else:
                app["why"] = "no way to start it is known"
        if rule.get("skip"):
            app["skip"] = True
            app["why"] = rule.get("why") or "set to skip"
        app_of[key] = len(apps)
        apps.append(app)

    windows = []
    for c in kept:
        m = mons.get(c.get("monitor"), {})
        at = c.get("at") or [0, 0]
        g = groups.get(c["address"])
        windows.append({
            "id": "w%d" % (len(windows) + 1), "app": apps[app_of[(c["pid"], c.get("class"))]]["id"],
            "address": c["address"], "class": c.get("class"), "initialClass": c.get("initialClass"),
            "title": c.get("title"), "initialTitle": c.get("initialTitle"),
            "workspace": _ws(c), "monitor": m.get("name"), "floating": bool(c.get("floating")),
            "at": [at[0] - m.get("x", 0), at[1] - m.get("y", 0)], "size": list(c.get("size") or [0, 0]),
            "fullscreen": c.get("fullscreen", 0), "fullscreenClient": c.get("fullscreenClient", 0),
            "pinned": bool(c.get("pinned")),
            "group": {"id": g[0], "index": g[1], "active": active_of.get(g[0]) == c["address"],
                      "locked": bool(locks.get(c["address"]))} if g else None,
            "tags": [t for t in (c.get("tags") or []) if not t.endswith("*")],
            "focus": c.get("focusHistoryID", -1), "xwayland": bool(c.get("xwayland")),
        })
    _vscode_folders(apps, windows, rules, paths)

    focus = None
    for w in sorted(windows, key=lambda w: w["focus"] if w["focus"] >= 0 else 1 << 30):
        focus = w["address"]
        break
    return {"version": 1, "time": time.time(), "sig": hy.sig, "bootId": None, "hook": hook_seen,
            "monitors": out_mons, "focus": focus, "apps": apps, "windows": windows}


def _vscode_folders(apps, windows, rules, paths):
    """A window of an app whose rule has `folders` (VS Code) gets the folder its title names: `window["folder"]`."""
    for app in apps:
        spec = (rules.get("apps", {}).get(app.get("class")) or {}).get("folders")
        if not spec:
            continue
        storage = os.path.join(paths.xdg_config, spec.get("config", "Code"), "User", "workspaceStorage")
        known = vscode.roots(storage)
        for w in windows:
            if w["app"] == app["id"]:
                folder = vscode.resolve(w.get("title"), spec.get("appName", "Visual Studio Code"), storage, known)
                if folder:
                    w["folder"] = folder


def fingerprint(snap):
    """What makes two snapshots the same picture: everything but the clock, the pids and the focus order."""
    def app(a):
        return (a["kind"], a["class"], a["count"], tuple(a.get("launch") or []), repr(a.get("terminal")))

    def win(w):
        return (w["app"], w["class"], w["title"], repr(w["workspace"]), w["monitor"], w["floating"],
                tuple(w["at"]) if w["floating"] else (), tuple(w["size"]) if w["floating"] else (),
                w["fullscreen"], w["pinned"], repr(w["group"]), tuple(w["tags"]))

    return repr(([app(a) for a in snap["apps"]], [win(w) for w in snap["windows"]],
                 [(m["name"], m["workspace"], m["special"]) for m in snap["monitors"]]))
