"""Carry a plan out: start what is missing, find each new window, prepare it out of sight, show everything at once.

THE STAGING WORKSPACES. Every window is opened on a hidden special workspace that stands for its own (plan.stage_name:
`special:lsr-n3` for workspace 3) -- no key reaches one, and Hyprland lays a special workspace out at the monitor's full
size, so a window there is sized as it will be. There the groups are built, in tab order, with their tab on show and
their lock; then ONE Lua chunk moves everything to where it belongs, pins and maximizes, between two frames: what the
user sees is the session appearing, never five tiles that fold into a group. A group moves as one tile (moving any
member takes the group, its order and its tab along).
Nothing may stay on a staging workspace: the reveal runs whatever happened before it, `reveal_stranded` sweeps what
is left by the workspace's own name, the CLI lingers for the window that opens after its launch gave up (Hyprland's
exec rule lives 60 s), and the watcher sweeps again.

Every step addresses a window BY ADDRESS (measured on Hyprland 0.57.2, also under a session lock: exec rules,
`window.move`, `group.toggle`, the Lua `Group:add`, `group.active`, `group.lock`, `window.swap` -- none needs the focus).

What is not reproduced: a dwindle tree. Tiled windows arrive in reading order and are then swapped onto the saved place
nearest to them; split ratios are Hyprland's.
"""
import difflib
import os
import re
import time

from . import plan as planlib
from . import vscode
from .hypr import HyprError, lua_str, lua_table, split_event

SETTLE_S = 1.2          # titles of a multi-window app after its last window opened
FOLDER_SETTLE_S = 4.0  # an app that restores its own windows (VS Code): no new one this long -> open the missing folders
SPLASH_S = 3.0          # a matched window that closes this soon was a splash screen
SLOW_RULE_MS = 600000   # how long a slow app's window rule waits for its window
EXEC_RULE_S = 60        # Hyprland keeps an exec rule this long: a window that late still lands on its staging workspace


def _norm_title(t):
    return re.sub(r"^[●*•\s]+", "", t or "").strip().lower()


def title_score(a, b):
    a, b = _norm_title(a), _norm_title(b)
    if a == b:
        return 2.0
    return difflib.SequenceMatcher(None, a, b).ratio()


def assign_by_title(saved, live):
    """Greedy best pairs: [(saved window, live client)] -- every saved window at most once, every client at most once."""
    scores = sorted(((title_score(s["title"], c.get("title")), si, ci)
                     for si, s in enumerate(saved) for ci, c in enumerate(live)), reverse=True)
    used_s, used_c, pairs = set(), set(), []
    for _, si, ci in scores:
        if si in used_s or ci in used_c:
            continue
        used_s.add(si)
        used_c.add(ci)
        pairs.append((saved[si], live[ci]))
    return pairs


def _move_line(address, target):
    return ("pcall(function() hl.dispatch(hl.dsp.window.move({ workspace = %s, follow = false, window = %s })) end)"
            % (lua_str(target), lua_str("address:" + address)))


def reveal_stranded(hy):
    """Every window still on a staging workspace goes to the workspace that one stands for (its NAME says which).
    Returns how many were moved. Safe at any time: with nothing staged it reads the clients and does nothing."""
    moved, groups = 0, set()
    for c in hy.json("clients"):
        target = planlib.stage_target((c.get("workspace") or {}).get("name"))
        if not target:
            continue
        g = tuple(c.get("grouped") or [])
        if g:
            if g in groups:
                continue                        # the group went with its first member
            groups.add(g)
        if hy.try_dispatch("hl.dsp.window.move({ workspace = %s, follow = false, window = %s })"
                           % (lua_str(planlib.ws_target(target)), lua_str("address:" + c["address"]))) is None:
            moved += 1
    return moved


CLOSE_SETTLE_S = 0.3    # the layout after the windows of a --replace went, before anything starts


def close_windows(hy, paths, targets, timeout_s):
    """Close open windows politely: ONE Lua chunk of `hl.dsp.window.close` by address (the app is asked, never killed), then
    wait up to `timeout_s` for each to go. Returns (closed, kept): the targets that are gone, and the ones still open -- a
    window that asks first (unsaved changes) is left as it is. `targets` = [{"address", "class", "title"}]."""
    if not targets:
        return [], []
    lines = ["pcall(function() hl.dispatch(hl.dsp.window.close({ window = %s })) end)" % lua_str("address:" + t["address"])
             for t in targets]
    hy.run_lua("\n".join(lines) + "\n", paths.runtime)
    want = {t["address"] for t in targets}
    end = time.monotonic() + timeout_s
    while True:
        open_now = {c["address"] for c in hy.json("clients")} & want
        if not open_now or time.monotonic() >= end:
            break
        time.sleep(0.15)
    if len(open_now) < len(want):
        time.sleep(CLOSE_SETTLE_S)
    return [t for t in targets if t["address"] not in open_now], [t for t in targets if t["address"] in open_now]


class Restore:
    def __init__(self, hy, proc, paths, plan, log=None, extra_env=None, progress=None):
        self.hy, self.proc, self.paths, self.plan = hy, proc, paths, plan
        self.log = log or (lambda *a: None)
        self.progress = progress or (lambda d: None)
        self.extra_env = extra_env or {}
        # saved window id -> live address. A preset load starts with the windows it REUSES in it (plan["reuse"]): they are
        # moved to their place like the ones just started, and revealed in the same chunk.
        self.reused = dict(plan.get("reuse") or {})
        self.addr = dict(self.reused)
        self.opened_at = {}     # address -> when it was matched
        self.failed = []
        self.later = []         # slow apps whose window has not come yet
        self.direct = set()     # windows of slow apps: opened on their own workspace, never staged
        self.focused = None     # the live address of the window that had the focus, once it was asked for
        self.before = set()
        self.rules_made = []
        self.rules_kept = set()
        self.started = time.monotonic()
        self._told = None

    # -- helpers -----------------------------------------------------------------------------------------------------
    def clients(self):
        return [c for c in self.hy.json("clients") if c.get("mapped", True)]

    def _do(self, lua, what):
        err = self.hy.try_dispatch(lua)
        if err:
            self.log("warn", "%s: %s" % (what, err))
        return err is None

    def _write_pending(self, launch):
        p = launch.get("pending")
        if not p:
            return
        path = os.path.join(self.paths.pending, launch["token"])
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("%s\n%s\n" % (p["mode"], p["command"]))

    def _total(self):
        return sum(len(l["windows"]) for l in self.plan["launches"]) + len(self.reused)

    def _tell(self, waiting):
        """Progress, once per change: how many windows are there, and what is still awaited."""
        names = []
        for l in waiting:
            if l["name"] not in names:
                names.append(l["name"])
        state = (len(self.addr), tuple(names))
        if state != self._told:
            self._told = state
            self.progress({"event": "progress", "done": len(self.addr),
                           "total": self._total(), "waiting": names})

    # -- starting ------------------------------------------------------------------------------------------------------
    def _rule(self, launch, ttl_ms=None):
        """A temporary window rule for an app's class, kept by name in a Lua global so that it can be ended."""
        name = "lares-session-" + launch["app"]
        lua = ("LARES_SESSION_RULES = LARES_SESSION_RULES or {}; LARES_SESSION_RULES[%s] = hl.window_rule({ name = %s, "
               "match = { class = %s }, workspace = %s, no_initial_focus = true })"
               % (lua_str(name), lua_str(name), lua_str("^(%s)$" % re.escape(launch["class"] or "")),
                  lua_str(launch["rule"]["workspace"])))
        if ttl_ms:
            lua += ("; hl.timer(function() if LARES_SESSION_RULES[%s] then LARES_SESSION_RULES[%s]:set_enabled(false); "
                    "LARES_SESSION_RULES[%s] = nil end end, { timeout = %d, type = \"oneshot\" })"
                    % (lua_str(name), lua_str(name), lua_str(name), ttl_ms))
        try:
            self.hy.eval(lua)
            self.rules_made.append(name)
        except HyprError as e:
            self.log("warn", "window rule for %s: %s" % (launch["name"], e))
        return name

    def _start(self, launch):
        self._write_pending(launch)
        cmd = planlib.shell_command(launch, self.extra_env)
        launch["_started"] = time.monotonic()
        if launch["mode"] == "multi":
            self._rule(launch)
            self.hy.dispatch("hl.dsp.exec_cmd(%s)" % lua_str(cmd))
        elif launch["mode"] == "slow":
            # Its window opens on its own workspace whenever it comes, in ten minutes at most: the rule ends itself.
            launch["_rule"] = self._rule(launch, SLOW_RULE_MS)
            self.direct.update(launch["windows"])
            self.hy.dispatch("hl.dsp.exec_cmd(%s)" % lua_str(cmd))
        else:
            self.hy.dispatch("hl.dsp.exec_cmd(%s, %s)" % (lua_str(cmd), lua_table(launch["rule"])))

    def _drop_rules(self):
        for name in self.rules_made:
            if name in self.rules_kept:
                continue
            try:
                self.hy.eval("if LARES_SESSION_RULES and LARES_SESSION_RULES[%s] then LARES_SESSION_RULES[%s]:set_enabled(false); "
                             "LARES_SESSION_RULES[%s] = nil end" % (lua_str(name), lua_str(name), lua_str(name)))
            except HyprError as e:
                self.log("warn", "window rule %s: %s" % (name, e))
        self.rules_made = []

    # -- finding the new windows -------------------------------------------------------------------------------------
    def _match(self, launches, final=False):
        """Assign new clients to the windows of the launches still waiting. Returns the launches now complete."""
        live = [c for c in self.clients() if c["address"] not in self.before]
        taken = set(self.addr.values())
        alive = {c["address"] for c in live}
        # A matched window that is gone again so soon was a splash: wait for the real one.
        for wid, a in list(self.addr.items()):
            if wid not in self.reused and a not in alive and time.monotonic() - self.opened_at.get(a, 0) < SPLASH_S:
                del self.addr[wid]
        done = []
        for l in launches:
            want = [w for w in l["windows"] if w not in self.addr]
            if not want:
                done.append(l)
                continue
            free = [c for c in live if c["address"] not in taken]
            if l["mode"] == "token":
                hit = None
                for c in free:
                    if self.proc.environ(c["pid"]).get("LARES_SESSION_TOKEN") == l["token"]:
                        hit = c
                        break
                if hit is None and final:
                    same = [c for c in free if c.get("class") == l["class"]]
                    hit = same[0] if same else None
                if hit is not None:
                    self.addr[want[0]] = hit["address"]
                    self.opened_at[hit["address"]] = time.monotonic()
                    taken.add(hit["address"])
                    done.append(l)
                continue
            # multi: wait for as many windows as were saved, let the titles settle, then pair by title.
            cands = [c for c in free if c.get("class") == l["class"] or c.get("initialClass") == l["class"]]
            if l.get("folders") and not l.get("_spawned") and not final:
                now = time.monotonic()
                if l.get("_cn") != len(cands):
                    l["_cn"], l["_cn_at"] = len(cands), now
                # settled: its windows stopped coming (none at all: only after a longer wait for the first)
                if now - l["_cn_at"] >= FOLDER_SETTLE_S and (cands or now - l.get("_started", now) >= 3 * FOLDER_SETTLE_S):
                    self._open_missing(l, want, cands)
            if not cands:
                continue
            if len(cands) >= len(want):
                since = l.setdefault("_full_at", time.monotonic())
                if not final and time.monotonic() - since < SETTLE_S:
                    continue
            elif not final:
                l.pop("_full_at", None)
                continue
            saved = [self.plan["windows"][w] for w in want]
            for s, c in assign_by_title(saved, cands):
                self.addr[s["id"]] = c["address"]
                self.opened_at[c["address"]] = time.monotonic()
                taken.add(c["address"])
            if all(w in self.addr for w in l["windows"]) or final:
                done.append(l)
        return done

    def _open_missing(self, launch, want, cands):
        """VS Code reopened some windows by itself; its own restore has settled. A saved window whose folder is in none
        of the open ones' titles is opened with `code -n <folder>`: a second `code` hands off to the running instance and
        exits, so the window belongs to the first pid and the launch's class rule (staging) and title pairing take it."""
        launch["_spawned"] = True
        open_titles = [c.get("title") for c in cands]
        for wid in want:
            folder = (launch.get("folders") or {}).get(wid)
            if not folder:
                continue
            name = os.path.basename(folder.rstrip("/"))
            if folder.endswith(".code-workspace"):
                name = os.path.splitext(name)[0] + " (Workspace)"
            hit = next((t for t in open_titles if vscode.title_has_root(t, name, launch.get("folderApp", ""))), None)
            if hit is not None:
                open_titles.remove(hit)
                continue
            extra = dict(launch, cmd=list(launch["cmd"][:1]) + ["-n", folder])
            self.hy.dispatch("hl.dsp.exec_cmd(%s)" % lua_str(planlib.shell_command(extra, self.extra_env)))
            self.log("start", "%s: %s" % (launch["name"], " ".join(extra["cmd"])))

    def run(self):
        launches = list(self.plan["launches"])
        self.before = {c["address"] for c in self.clients()}
        self.progress({"event": "start", "total": self._total()})
        ev = self.hy.events()
        try:
            try:
                waiting = []
                for l in launches:
                    try:
                        self._start(l)
                        l["_deadline"] = time.monotonic() + l["timeoutMs"] / 1000.0
                        waiting.append(l)
                        self.log("start", "%s: %s" % (l["name"], " ".join(l["cmd"])))
                    except HyprError as e:
                        self.failed.append({"name": l["name"], "why": "could not be started: %s" % e})
                    # Let each window land before the next opens: the opening order is the tiling order.
                    self._pump(ev, [l], 1.5 if l["mode"] == "token" else 0.3)
                    done = self._match(waiting)
                    waiting = [x for x in waiting if x not in done]
                    self._tell(waiting)
                while waiting:
                    now = time.monotonic()
                    late = [l for l in waiting if now >= l["_deadline"]]
                    if late:
                        self._match(late, final=True)
                        for l in late:
                            missing = [w for w in l["windows"] if w not in self.addr]
                            if not missing:
                                continue
                            if l["mode"] == "slow":
                                # not a failure: it is still starting, and its rule waits for it
                                self.rules_kept.add(l["_rule"])
                                self.later.append({"name": l["name"], "workspace": l["target"].split()[0]})
                            else:
                                self.failed.append({"name": l["name"], "why": "%d of %d windows did not open in %d s" % (
                                    len(missing), len(l["windows"]), l["timeoutMs"] // 1000)})
                        waiting = [l for l in waiting if l not in late]
                        self._tell(waiting)
                        continue
                    self._pump(ev, waiting, min(0.5, max(0.05, min(l["_deadline"] for l in waiting) - now)))
                    done = self._match(waiting)
                    waiting = [x for x in waiting if x not in done]
                    self._tell(waiting)
                self._prepare()
            finally:
                # whatever happened above: the temporary rules end, and nothing stays out of sight
                self._drop_rules()
                self.progress({"event": "reveal"})
                self._reveal()
        finally:
            ev.close()
        self._settle()
        return self._result()

    def _pump(self, ev, launches, seconds):
        """Wait up to `seconds`, returning early when a window of ours may have opened."""
        end = time.monotonic() + seconds
        while True:
            left = end - time.monotonic()
            if left <= 0:
                return
            lines = ev.wait(left)
            if lines is None:
                raise HyprError("the compositor went away")
            if any(split_event(x)[0] in ("openwindow", "windowtitlev2", "closewindow") for x in lines):
                if self._match(launches) and all(all(w in self.addr for w in l["windows"]) for l in launches):
                    return

    # -- out of sight: every window on its staging workspace, the groups built ---------------------------------------
    def _float_fix(self, wid, c, mons):
        """A floating window's saved size and place (relative to its monitor), where the live one differs."""
        w = self.plan["windows"][wid]
        sel = lua_str("address:" + c["address"])
        if w["floating"] != bool(c.get("floating")):
            self._do("hl.dsp.window.float({ action = %s, window = %s })"
                     % (lua_str("set" if w["floating"] else "unset"), sel), "float %s" % w["title"])
        if not w["floating"]:
            return
        m = mons.get(w["monitor"]) or next(iter(mons.values()), {})
        x, y = w["at"][0] + m.get("x", 0), w["at"][1] + m.get("y", 0)
        at, size = c.get("at") or [0, 0], c.get("size") or [0, 0]
        changed = w["floating"] != bool(c.get("floating"))
        if changed or abs(size[0] - w["size"][0]) > 2 or abs(size[1] - w["size"][1]) > 2:
            self._do("hl.dsp.window.resize({ x = %d, y = %d, relative = false, window = %s })"
                     % (w["size"][0], w["size"][1], sel), "resize %s" % w["title"])
        if changed or abs(at[0] - x) > 2 or abs(at[1] - y) > 2:
            self._do("hl.dsp.window.move({ x = %d, y = %d, relative = false, window = %s })" % (x, y, sel),
                     "place %s" % w["title"])

    def _release(self, live):
        for wid, a in self.reused.items():
            c = live.get(a)
            if not c:
                continue
            sel = lua_str("address:" + a)
            if c.get("grouped"):
                # a locked group takes no member out: ask it first (group.lock TOGGLES, so only when it is locked)
                try:
                    self.hy.eval("local w = hl.get_window(%s); if w and w.group and w.group.locked then "
                                 "hl.dispatch(hl.dsp.group.lock({ window = %s })) end" % (sel, sel))
                except HyprError as e:
                    self.log("warn", "group unlock: %s" % e)
                self._do("hl.dsp.window.move({ out_of_group = true, window = %s })" % sel, "leave group")
            if c.get("pinned"):
                self._do("hl.dsp.window.pin({ action = \"unset\", window = %s })" % sel, "unpin")
            if c.get("fullscreen"):
                # `unset` needs the mode it undoes (measured, 0.57.2: without one the window stays as it was)
                self._do("hl.dsp.window.fullscreen({ action = \"unset\", mode = %s, window = %s })"
                         % (lua_str("fullscreen" if c["fullscreen"] == 2 else "maximized"), sel), "unfullscreen")

    def _prepare(self):
        wins = self.plan["windows"]
        live = {c["address"]: c for c in self.clients()}
        mons = {m["name"]: m for m in self.hy.json("monitors")}
        self.addr = {wid: a for wid, a in self.addr.items() if a in live}

        # 0. a window that was open already (a preset load) leaves what it was in: a group (moving one member moves the whole
        # group), a pin and a fullscreen are undone first, and set again from the saved state at the reveal
        if self.reused:
            self._release(live)
            live = {c["address"]: c for c in self.clients()}
            self.addr = {wid: a for wid, a in self.addr.items() if a in live}

        # 1. where it waits (an app that opens its own windows put them all on one staging workspace), and a float's box
        for wid, a in self.addr.items():
            w, c = wins[wid], live[a]
            if wid in self.direct:
                want = planlib.ws_target(w["workspace"])
                here = (c.get("workspace") or {}).get("name") == w["workspace"]["name"]
            else:
                want = planlib.stage_name(w["workspace"])
                here = (c.get("workspace") or {}).get("name") == want
            if not here:
                self._do("hl.dsp.window.move({ workspace = %s, follow = false, window = %s })"
                         % (lua_str(want), lua_str("address:" + a)), "stage %s" % w["title"])
            self._float_fix(wid, c, mons)

        # 2. the groups, in tab order, the saved tab on show, locked when they were
        for g in self.plan["groups"]:
            members = [wid for wid in g["members"] if wid in self.addr]
            if len(members) < 1:
                continue
            first = self.addr[members[0]]
            sel = lua_str("address:" + first)
            now = {c["address"]: c for c in self.clients()}
            if not (now.get(first, {}).get("grouped")):
                self._do("hl.dsp.group.toggle({ window = %s })" % sel, "group")
            for wid in members[1:]:
                try:
                    self.hy.eval("local g = hl.get_window(%s).group; if g then g:add(hl.get_window(%s)) end"
                                 % (sel, lua_str("address:" + self.addr[wid])))
                except HyprError as e:
                    self.log("warn", "group %s: %s" % (wins[wid]["title"], e))
            active = g["active"] if g["active"] in members else members[0]
            self._do("hl.dsp.group.active({ index = %d, window = %s })" % (members.index(active) + 1, sel), "group tab")
            if g.get("locked"):
                # group.lock TOGGLES whatever `action` says (0.57.2): ask the group first. Last: a locked group takes no member.
                try:
                    self.hy.eval("local w = hl.get_window(%s); if w and w.group and not w.group.locked then "
                                 "hl.dispatch(hl.dsp.group.lock({ window = %s })) end" % (sel, sel))
                except HyprError as e:
                    self.log("warn", "group lock: %s" % e)

        # 3. tags
        for wid, a in self.addr.items():
            for t in wins[wid].get("tags") or []:
                self._do("hl.dsp.window.tag({ tag = %s, window = %s })" % (lua_str("+" + t), lua_str("address:" + a)), "tag")

    # -- into sight: one chunk ----------------------------------------------------------------------------------------
    def _reveal(self):
        wins = self.plan["windows"]
        live = {c["address"]: c for c in self.clients()}
        lines, groups = [], set()
        for wid in sorted((w for w in self.addr if self.addr[w] in live), key=lambda i: planlib._order(wins[i])):
            if wid in self.direct:
                continue
            c = live[self.addr[wid]]
            # ONE rule says where a staged window belongs: the name of the staging workspace it stands on (_prepare put
            # it there; reveal_stranded reads the same name).
            target = planlib.stage_target((c.get("workspace") or {}).get("name"))
            if not target:
                continue
            g = tuple(c.get("grouped") or [])
            if g:
                if g in groups:
                    continue                    # a group is one tile: it went with its first member
                groups.add(g)
            lines.append(_move_line(c["address"], planlib.ws_target(target)))
        for wid, a in self.addr.items():
            if a not in live:
                continue
            w, sel = wins[wid], lua_str("address:" + a)
            if w.get("pinned") and w["floating"]:
                lines.append("pcall(function() hl.dispatch(hl.dsp.window.pin({ action = \"set\", window = %s })) end)" % sel)
            if w.get("fullscreen"):
                mode = "fullscreen" if w["fullscreen"] == 2 else "maximized"
                lines.append("pcall(function() hl.dispatch(hl.dsp.window.fullscreen({ action = \"set\", mode = %s, "
                             "window = %s })) end)" % (lua_str(mode), sel))
        if lines:
            try:
                self.hy.run_lua("\n".join(lines) + "\n", self.paths.runtime)
            except HyprError as e:
                self.log("warn", "reveal: %s" % e)
        # whatever the chunk left behind (a member that never joined its group, a failed line)
        reveal_stranded(self.hy)

    def _settle(self):
        """In sight: the tiled order, and a float that another monitor's layout moved."""
        self._tile_order()
        live = {c["address"]: c for c in self.clients()}
        mons = {m["name"]: m for m in self.hy.json("monitors")}
        for wid, a in self.addr.items():
            if a in live and self.plan["windows"][wid]["floating"]:
                self._float_fix(wid, live[a], mons)

    def linger(self, seconds):
        """A window that opens after its launch gave up still lands on its staging workspace while Hyprland's exec rule
        lives: stay that long and show each as it comes."""
        end = time.monotonic() + seconds
        try:
            ev = self.hy.events()
        except HyprError:
            return
        try:
            while time.monotonic() < end:
                lines = ev.wait(min(2.0, max(0.05, end - time.monotonic())))
                if lines is None:
                    return
                if any(split_event(x)[0] == "openwindow" for x in lines):
                    time.sleep(0.2)
                    reveal_stranded(self.hy)
        except HyprError:
            return
        finally:
            ev.close()

    def late_possible(self):
        """Seconds for which a window of a failed launch could still open on a staging workspace (0: none can)."""
        left = 0.0
        for l in self.plan["launches"]:
            if l["mode"] == "token" and "_started" in l and not all(w in self.addr for w in l["windows"]):
                left = max(left, l["_started"] + EXEC_RULE_S + 5 - time.monotonic())
        return max(0.0, left)

    def _tile_order(self):
        wins = self.plan["windows"]
        live = {c["address"]: c for c in self.clients()}
        mons = {m.get("id"): m for m in self.hy.json("monitors")}
        by_ws = {}
        for wid, a in self.addr.items():
            w = wins[wid]
            if w["floating"] or a not in live:
                continue
            g = w.get("group")
            if g and g["index"] != min(wins[x]["group"]["index"] for x in self.addr
                                       if wins[x].get("group") and wins[x]["group"]["id"] == g["id"]):
                continue                                   # a group is one tile: its first restored member stands for it
            by_ws.setdefault(str(w["workspace"]["key"]), []).append(wid)
        for ws, ids in by_ws.items():
            if len(ids) < 2:
                continue
            for wid in sorted(ids, key=lambda i: (wins[i]["at"][0], wins[i]["at"][1])):
                live = {c["address"]: c for c in self.clients()}

                def rel(a):
                    c = live[a]
                    m = mons.get(c.get("monitor"), {})
                    return (c["at"][0] - m.get("x", 0), c["at"][1] - m.get("y", 0))

                want = wins[wid]["at"]
                here = [self.addr[i] for i in ids if self.addr[i] in live]
                if self.addr[wid] not in here:
                    continue
                best = min(here, key=lambda a: abs(rel(a)[0] - want[0]) + abs(rel(a)[1] - want[1]))
                mine = self.addr[wid]
                if best != mine and (abs(rel(best)[0] - rel(mine)[0]) + abs(rel(best)[1] - rel(mine)[1])) > 4:
                    self._do("hl.dsp.window.swap({ window = %s, target = %s })"
                             % (lua_str("address:" + mine), lua_str("address:" + best)), "swap")

    def focus(self, snap):
        """The active workspace of each monitor, then the window that had the focus."""
        mons = {m["name"]: m for m in self.hy.json("monitors")}
        for m in sorted(snap.get("monitors", []), key=lambda m: m.get("focused", False)):
            if m["name"] in mons and m.get("workspace") not in (None, ""):
                cur = mons[m["name"]].get("activeWorkspace") or {}
                key = m["workspace"]
                if cur.get("id") != key and cur.get("name") != key:
                    self._do("hl.dsp.focus({ workspace = %s })" % (repr(key) if isinstance(key, int) else lua_str(
                        key if str(key).startswith("special") else "name:%s" % key)), "workspace")
        by_addr = {w["address"]: w["id"] for w in snap.get("windows", [])}
        wid = by_addr.get(snap.get("focus"))
        if wid in self.addr:
            self.focused = self.addr[wid]
            # focusing a window WARPS the pointer: put it back where it was, in the same Lua chunk (KeyRelease.qml's way)
            try:
                self.hy.focus_window(self.addr[wid])
            except HyprError as e:
                self.log("warn", "focus: %s" % e)

    def _result(self):
        typed = ran = 0
        waiting = []
        for l in self.plan["launches"]:
            p = l.get("pending")
            if p and any(w in self.addr for w in l["windows"]):
                if p["mode"] == "run":
                    ran += 1
                else:
                    typed += 1
                    waiting.append({"command": p["command"], "why": p.get("reason", "")})
        return {"restored": len(self.addr), "planned": self._total(),
                "skipped": self.plan["skipped"], "failed": self.failed, "later": self.later, "ran": ran, "typed": typed,
                "waiting": waiting}

    def unclaimed(self, wait_s=4.0):
        """Pending commands no shell claimed (the bash hook is not sourced, or the shell has not reached its prompt)."""
        tokens = [l["token"] for l in self.plan["launches"] if l.get("pending") and any(w in self.addr for w in l["windows"])]
        end = time.monotonic() + wait_s
        left = tokens
        while left and time.monotonic() < end:
            left = [t for t in tokens if os.path.exists(os.path.join(self.paths.pending, t))]
            if left:
                time.sleep(0.2)
        for l in self.plan["launches"]:
            if l.get("pending"):
                try:
                    os.unlink(os.path.join(self.paths.pending, l["token"]))
                except OSError:
                    pass
        return len(left)
