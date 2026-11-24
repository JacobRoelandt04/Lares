"""From a snapshot to what will be started (pure: no Hyprland, no /proc).

    build(snap, live, rules, cfg, clean, env) ->
      {"launches": [{"app", "name", "mode": "token" | "multi", "token", "cmd": [argv], "cwd",
                     "rule": {exec rule table}, "class", "windows": [window ids],
                     "pending": {"mode", "command", "reason"} | None, "timeoutMs"}],
       "skipped": [{"window", "title", "why"}],
       "windows": {id: window},  "groups": [{"id", "members": [ids in tab order], "active": id}]}

`token`  one window, started with an exec rule table (the STAGING workspace, float, size, move); the new client is
         known by LARES_SESSION_TOKEN in its process environment.
`multi`  an app that opens its windows itself (a browser, an editor that restores its own session) or hands the
         start to a running instance: started once under a temporary window rule, its windows matched by title.
`slow`   an app whose window may come minutes later (the Windows VM's viewer after a boot): a temporary window rule
         puts it on its own workspace whenever it opens; it is waited for like any app and, when it has not come,
         reported as "later", not as failed.

A saved window that an open client already stands for (same class and title) is skipped, and an app that is already
running is never started twice: a restore adds what is missing and moves nothing that is there.
"""
import os
import shlex

from . import classify

ELECTRONISH_MS = 30000


STAGE = "special:lsr-"


def stage_name(ws):
    """The hidden workspace a target workspace's windows are prepared on: `special:lsr-n<number>` for a numbered one,
    `special:lsr-s<hex of the name>` for a named or special one. The name alone says where its windows belong, so a
    window found on one is never lost (restore.reveal_stranded)."""
    key = ws.get("key")
    if isinstance(key, int):
        return "%sn%d" % (STAGE, key)
    return "%ss%s" % (STAGE, (ws.get("name") or str(key)).encode("utf-8").hex())


def stage_target(name):
    """The workspace record a staging workspace stands for, or None for any other name."""
    if not isinstance(name, str) or not name.startswith(STAGE):
        return None
    rest = name[len(STAGE):]
    try:
        if rest[:1] == "n":
            n = int(rest[1:])
            return {"key": n, "name": str(n), "special": False}
        if rest[:1] == "s":
            real = bytes.fromhex(rest[1:]).decode("utf-8")
            return {"key": real, "name": real, "special": real.startswith("special")}
    except ValueError:
        pass
    return None


def ws_rule(ws):
    """The exec rule's workspace word for a saved workspace."""
    key = ws.get("key")
    if isinstance(key, int):
        return "%d silent" % key
    name = ws.get("name") or str(key)
    if name.startswith("special"):
        return "%s silent" % name
    return "name:%s silent" % name


def ws_target(ws):
    """The same workspace for hl.dsp.window.move / hl.dsp.focus."""
    key = ws.get("key")
    if isinstance(key, int):
        return str(key)
    name = ws.get("name") or str(key)
    return name if name.startswith("special") else "name:" + name


def _order(w):
    key = w["workspace"]["key"]
    g = w.get("group")
    return (0 if isinstance(key, int) else 1, str(key).zfill(6), 1 if w["floating"] else 0,
            w["at"][0] if not g else -1, w["at"][1] if not g else -1, g["id"] if g else "", g["index"] if g else 0)


def _terminal_launch(app, clean, rules, cfg, why_unclean, claude="resume"):
    """(argv, pending) for a kitty window."""
    term = app["terminal"]
    kitty = (app.get("argv") or ["kitty"])[0]
    cwd = term.get("cwd") or ""
    base = [kitty] + (["--directory", cwd] if cwd and os.path.isdir(cwd) else [])
    opts, program = list(term.get("opts") or []), list(term.get("program") or [])
    if term.get("shell") and "--hold" in opts:
        # `kitty --hold <program>` whose program is over: it ran, and kitty put a shell in its place. A command that has
        # finished is never run again (the user's `kitty --hold fastfetch`: "not worth the hassle", 2026-11-14) -- the
        # terminal comes back as the plain shell it had become.
        opts = [o for o in opts if o != "--hold"]
        program = []
    if not term.get("shell"):
        # No shell in it: kitty ran a program directly (`kitty --title yazi sh -c yazi`, the launcher's `kitty -e app`).
        root = term.get("rootArgv") or program
        ok, why = classify.argv_rule(root, rules, cfg) if root else (True, "")
        if ok and not clean:
            ok, why = False, why_unclean
        if ok and claude == "type" and root and os.path.basename(root[0]) == "claude":
            ok, why = False, "session.jsonc types it"
        if ok or not program:
            return base + opts + program, None
        # The line typed is what RAN (`kitty --title yazi sh -c yazi`: sh exec'd yazi, so `yazi`), and the window keeps the
        # options it was started with (its title, its opacity: the user's window rules match on them).
        opts = [o for o in opts if o != "--hold"]
        return base + opts, {"mode": "type", "command": shlex.join(root or program), "reason": why}
    pending = None
    if term.get("job"):
        v = classify.classify(term["job"], rules, cfg, clean, why_unclean, claude)
        if v["mode"] in ("run", "type"):
            pending = v
    return base + opts + program, pending


def build(snap, live, rules, cfg, clean=True, why_unclean="the last session did not end cleanly", reuse=None,
          claude="resume"):
    """`reuse` (a preset load; `match_reuse`'s answer): {saved window id: the open window it is} -- those windows are
    not started, they are moved to their saved place (plan["reuse"]). With it the "already open" skip by class and title
    is off (the match decided what stands for what); `live` then names the windows that stay open, for "the app is
    already running"."""
    windows = {w["id"]: w for w in snap.get("windows", [])}
    apps = {a["id"]: a for a in snap.get("apps", [])}
    skipped, launches = [], []
    preset = reuse is not None          # a preset load: {} is "nothing reused", not "not a preset"
    reuse = reuse or {}

    live_left = [] if preset else [(c.get("class"), c.get("title")) for c in live]
    live_classes = {c.get("class") for c in live}

    by_app = {}
    for w in sorted(windows.values(), key=_order):
        by_app.setdefault(w["app"], []).append(w)

    n = 0
    for aid, wins in sorted(by_app.items(), key=lambda kv: _order(kv[1][0])):
        app = apps.get(aid) or {}
        wins = [w for w in wins if w["id"] not in reuse]         # an open window stands for it: moved, never started
        if not wins:
            continue
        # Today's rules judge (a picture taken under older rules carries their verdict; the picture's facts stand).
        rule = rules.get("apps", {}).get(app.get("class")) or {}
        app_rule = rule
        if rule.get("skip") or not app.get("launch"):
            for w in wins:
                skipped.append({"window": w["id"], "title": w["title"], "name": app.get("name"),
                                "why": (rule.get("why") or "set to skip") if rule.get("skip")
                                else "no way to start it is known"})
            continue
        multi = app.get("kind") == "gui" and (app.get("selfRestore") or rule.get("selfRestore") or len(wins) > 1)
        # An app whose window may come minutes later (a VM that has to boot first): never staged, never waited for long.
        slow = app.get("kind") == "gui" and bool(rule.get("slow")) and not multi
        todo = []
        for w in wins:
            pair = (w["class"], w["title"])
            if pair in live_left:
                live_left.remove(pair)
                skipped.append({"window": w["id"], "title": w["title"], "name": app.get("name"), "why": "already open"})
            elif multi and app.get("class") in live_classes:
                skipped.append({"window": w["id"], "title": w["title"], "name": app.get("name"),
                                "why": "the app is already running"})
            else:
                todo.append(w)
        if not todo:
            continue
        n += 1
        token = "lsr%d%s" % (n, os.urandom(4).hex())
        first = todo[0]
        if app.get("kind") == "terminal":
            cmd, pending = _terminal_launch(app, clean, rules, cfg, why_unclean, claude)
            cwd = None
        else:
            cmd, pending = list(app["launch"]), None
            cwd = app.get("cwd") if app.get("cwd") and os.path.isdir(app["cwd"]) else None
        # Everything is prepared on a hidden staging workspace and shown in one step (restore.py); a slow app opens
        # where it belongs, whenever it comes.
        rule = {"workspace": ws_rule(first["workspace"]) if slow else stage_name(first["workspace"]) + " silent",
                "no_initial_focus": True}
        if not multi and first["floating"]:
            rule["float"] = True
            rule["size"] = "%d %d" % (first["size"][0], first["size"][1])
            rule["move"] = "%d %d" % (first["at"][0], first["at"][1])
        launches.append({
            "app": aid, "name": app.get("name"), "mode": "slow" if slow else "multi" if multi else "token", "token": token,
            "target": ws_rule(first["workspace"]),
            "cmd": cmd, "cwd": cwd, "rule": rule, "class": app.get("class"),
            "windows": [w["id"] for w in (todo if multi else todo[:1])], "pending": pending,
            "timeoutMs": int(cfg.get("appTimeoutMs", ELECTRONISH_MS)) if multi or app.get("kind") == "gui"
            else int(cfg.get("windowTimeoutMs", 10000)),
        })
        folders = {w["id"]: w["folder"] for w in todo if multi and w.get("folder")}
        if folders and app_rule.get("folders"):
            launches[-1]["folders"] = folders                       # restore.py opens the ones VS Code did not bring back
            launches[-1]["folderApp"] = app_rule["folders"].get("appName", "Visual Studio Code")
        if not multi:
            for w in todo[1:]:
                skipped.append({"window": w["id"], "title": w["title"], "name": app.get("name"),
                                "why": app.get("why") or "a second window of one terminal process"})

    planned = {wid for l in launches for wid in l["windows"]} | set(reuse)
    groups, saved_size = {}, {}
    for w in windows.values():
        g = w.get("group")
        if g:
            saved_size[g["id"]] = saved_size.get(g["id"], 0) + 1
            if w["id"] in planned:
                groups.setdefault(g["id"], []).append(w)
    out_groups = []
    for gid, members in sorted(groups.items()):
        if len(members) < 2 and saved_size[gid] > 1:
            continue        # the rest of its group is already open: one tab of it is no group of its own
        members.sort(key=lambda w: w["group"]["index"])
        active = next((w["id"] for w in members if w["group"]["active"]), members[0]["id"])
        out_groups.append({"id": gid, "members": [w["id"] for w in members], "active": active,
                           "locked": any(w["group"].get("locked") for w in members)})
    return {"launches": launches, "skipped": skipped, "windows": windows, "groups": out_groups,
            "reuse": {wid: c["address"] for wid, c in reuse.items()}}


# -- a preset's windows and the open ones --------------------------------------------------------------------------------
def _prog(app):
    """What a terminal runs, for telling two apart: None at a prompt, else the basenames of the job's tops (a program that
    has no shell under it is told from the same program typed in one)."""
    t = app.get("terminal") or {}
    if not t.get("shell"):
        root = t.get("rootArgv") or t.get("program") or []
        return ("<noshell>", classify._base(root[0]) if root else "")
    job = t.get("job")
    tops = [x["argv"][0] for x in (job or {}).get("tops", []) if x.get("argv")]
    return tuple(classify._base(a) for a in tops) or None


def match_reuse(snap, live_snap, rules):
    """Which open window stands for which window of a preset (pure; `live_snap` is a capture of the desktop as it is).

    {preset window id: the open window}, every open window used once, the preset's windows taken in reading order:
      a terminal (kitty by its process)  the same directory AND the same running program (or both at a prompt) -- what a
                                         terminal runs cannot be changed from outside, so another one is not reused;
      a window with a `folder` (VS Code) the same class and the same folder;
      a self-restoring app (a browser)   the same class, paired by exact title first, then by order;
      any other window                   the same class -- and the same title where that class has several windows."""
    apps = {a["id"]: a for a in snap.get("apps", [])}
    lapps = {a["id"]: a for a in live_snap.get("apps", [])}
    lwins = list(live_snap.get("windows", []))
    pwins = sorted(snap.get("windows", []), key=_order)
    used, out = set(), {}

    def free(pred):
        return [c for c in lwins if c["address"] not in used and pred(c)]

    def take(w, c):
        used.add(c["address"])
        out[w["id"]] = c

    def title_first(w, cands):
        return next((c for c in cands if c.get("title") == w.get("title")), cands[0] if cands else None)

    rest = []
    for w in pwins:                                              # terminals, then folders
        app = apps.get(w["app"]) or {}
        if app.get("kind") == "terminal":
            cands = free(lambda c, w=w, app=app: (lapps.get(c["app"]) or {}).get("kind") == "terminal"
                         and ((lapps[c["app"]].get("terminal") or {}).get("cwd") or "") == ((app.get("terminal") or {}).get("cwd") or "")
                         and _prog(lapps[c["app"]]) == _prog(app))
            hit = title_first(w, cands)
            if hit:
                take(w, hit)
        elif w.get("folder"):
            hit = title_first(w, free(lambda c, w=w: c.get("class") == w.get("class") and c.get("folder") == w["folder"]))
            if hit:
                take(w, hit)
        else:
            rest.append(w)
    by_class = {}
    for w in rest:
        by_class.setdefault(w.get("class"), []).append(w)
    for cls, group in by_class.items():
        app0 = apps.get(group[0]["app"]) or {}
        self_restore = bool(app0.get("selfRestore") or (rules.get("apps", {}).get(cls) or {}).get("selfRestore"))
        open_n = len(free(lambda c, cls=cls: c.get("class") == cls))
        if self_restore:
            for w in group:                                      # exact titles first ...
                hit = next((c for c in free(lambda c, cls=cls: c.get("class") == cls) if c.get("title") == w.get("title")), None)
                if hit:
                    take(w, hit)
            for w in group:                                      # ... then by order
                if w["id"] in out:
                    continue
                cands = free(lambda c, cls=cls: c.get("class") == cls and (lapps.get(c["app"]) or {}).get("kind") != "terminal")
                if cands:
                    take(w, cands[0])
        else:
            several = len(group) > 1 or open_n > 1
            for w in group:
                cands = free(lambda c, cls=cls: c.get("class") == cls and (lapps.get(c["app"]) or {}).get("kind") != "terminal")
                if several:
                    cands = [c for c in cands if c.get("title") == w.get("title")]
                if cands:
                    take(w, cands[0])
    return out


def closable(live_snap, reuse, rules):
    """What `--replace` closes: every open window of the capture no preset window stands for. Never a class whose rule says
    `skip` (the Windows VM's viewer); the shell's own windows and the skipClasses are not in a capture at all."""
    keep = {c["address"] for c in reuse.values()}
    skip = {k for k, v in (rules.get("apps") or {}).items() if v.get("skip")}
    return [c for c in live_snap.get("windows", []) if c["address"] not in keep and c.get("class") not in skip]


def preset_plan(data, live_snap, clients, rules, cfg, replace):
    """(plan, reuse, closing) of a preset load (pure). `clients` = the open windows (hyprctl's list, mapped ones): with
    --replace the ones the preset has no place for are closing and no longer count as open; with --add `closing` is empty.
    The session counts CLEAN (a preset is chosen, not the end of one) and a Claude job comes back as session.jsonc's
    `presets.claude` says: a fresh `claude` by default."""
    reuse = match_reuse(data, live_snap, rules)
    closing = closable(live_snap, reuse, rules) if replace else []
    gone = {c["address"] for c in closing}
    stay = [c for c in clients if c["address"] not in gone]
    claude = (cfg.get("presets") or {}).get("claude", "fresh")
    return build(data, stay, rules, cfg, True, "", reuse=reuse, claude=claude), reuse, closing


def shell_command(launch, extra_env=None):
    """The one `sh -c` line hl.dsp.exec_cmd runs."""
    words = ["env"]
    if launch.get("cwd"):
        words += ["-C", launch["cwd"]]
    for k, v in (extra_env or {}).items():
        words.append("%s=%s" % (k, v))
    words.append("LARES_SESSION_TOKEN=%s" % launch["token"])
    return shlex.join(words + list(launch["cmd"]))
