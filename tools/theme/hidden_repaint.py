#!/usr/bin/env python3
"""Make the windows nobody is looking at repaint after a theme switch.

Hyprland marks a hidden window (a hidden workspace, a group's hidden tab) `suspended`, and kitty and Qt draw nothing while
suspended: after a theme switch they show the old colours for a frame or two when they come back. Nothing but really showing
a window cures that (CLAUDE.md, "HYPRLAND MARKS A HIDDEN WINDOW suspended"). So, while the theme curtain's picture covers the
screen, this tool shows every hidden workspace and every hidden tab for a few frames and puts everything back.

    hidden_repaint.py run   [--frames N] [--class CLASS=N ...] [--debug-ms MS] [--timeout MS] [--dry]
                                                 do it (the shell's curtain calls this while it holds)
    hidden_repaint.py plan  [--frames N] [--class CLASS=N ...]
                                                 print the plan for the session as it is, change nothing

    --frames    the frames a window stays on show (3), unless its class says otherwise
    --class     the frames for one window class (Hyprland's `class`, exactly, any case): --class com.microsoft.VSCode=16
    --debug-ms  the run a person watches: every step that long, each named in a Hyprland notice

HOW. The session is read once (monitors, workspaces, windows, the focus, the pointer). `plan()` (pure, cases in
tools/dev/hidden_repaint_cases.py) turns that into STEPS; each step is a handful of dispatches for one moment, every monitor
working at the same time. A step stays the MOST frames that the windows it newly shows need (a window: its class's `--class`,
else `--frames`; on the user's 120 Hz panel kitty takes 2, VS Code about 16, zen about 24 -- their measurements), counted on
the slowest monitor. The steps are written as ONE Lua chunk that Hyprland runs by itself on its own timers (`hl.timer`): the
spacing is the compositor's, a step is one request, and the way back is in the compositor too -- it runs even when this
process is killed. Animations are off for the run and put back. The chunk writes its result to a file this tool waits for.

A STEP THAT FINDS THE SESSION ELSEWHERE THAN THE STEP BEFORE LEFT IT STOPS THE RUN (the user switched workspace under the
curtain): nothing is yanked back, only the tabs and the animation switch are restored.

What is never touched: a monitor whose shown workspace holds a fullscreen window (the shell's bar is frozen under it and a
workspace change there is a frame nobody answers), a hidden workspace that holds one (showing it would raise and drop the
shell's fullscreen state: its windows keep their old picture until shown), a workspace with no windows, a window that is not
mapped. The pointer does not move: warps are off for the run, and it is put where it was at the end.

Prints `REPAINT plan steps=<n> ms=<planned>` as the run starts, then one line, `REPAINT ok steps=<n> ms=<t> frames=<per step>
shown=<workspaces> tabs=<n>` or `REPAINT skip|stopped|FAIL <reason>`; exits 0 unless FAIL.
"""
import json
import os
import socket
import sys
import time

DEFAULT_FRAMES = 3


# --------------------------------------------------------------------------------------------------------------- the plan

def ws_key(ws):
    """A workspace's dispatch selector: its number when it has one, else `name:<name>` (a special one is toggled by name)."""
    if isinstance(ws.get("id"), int) and ws["id"] > 0:
        return ws["id"]
    return "name:" + ws.get("name", "")


def is_special(ws):
    return str(ws.get("name", "")).startswith("special:")


def _groups(clients, ws_name):
    """The groups on one workspace: a list of {"members": [address...], "shown": address}, members in tab order."""
    seen, out = set(), []
    for c in clients:
        if c["workspace"]["name"] != ws_name or not c.get("grouped") or len(c["grouped"]) < 2:
            continue
        key = tuple(c["grouped"])
        if key in seen:
            continue
        seen.add(key)
        by_addr = {x["address"]: x for x in clients}
        members = [a for a in c["grouped"] if a in by_addr]
        # the tab on show is the member Hyprland calls `visible` (0.57.2; `hidden` is false for every tab)
        shown = [a for a in members if by_addr[a].get("visible")]
        if len(shown) != 1:
            shown = [a for a in members if not by_addr[a].get("hidden")]
        if len(members) < 2 or len(shown) != 1:
            continue
        out.append({"members": members, "shown": shown[0]})
    return out


def frames_of(client, default, class_frames):
    """The frames a window needs on show: its class's entry in `class_frames` (the class exactly, in any case), else `default`."""
    if class_frames:
        key = str(client.get("class") or client.get("initialClass") or "").lower()
        if key in class_frames:
            return class_frames[key]
    return default


def _classes(wins):
    """The windows a moment newly shows, for a person: each class once, with a count."""
    names = [str(c.get("class") or c.get("initialClass") or "?") for c in wins]
    return ", ".join(n if names.count(n) == 1 else "%s x%d" % (n, names.count(n)) for n in dict.fromkeys(names))


def _tracks(monitors, workspaces, clients):
    """One track per monitor: (monitor, moments, way back); a moment is (actions, the windows it newly SHOWS, what it is).
    Also what was shown, the tab count and what was left alone."""
    by_ws = {}
    for c in clients:
        by_ws.setdefault(c["workspace"]["name"], []).append(c)
    ws_by_name = {w["name"]: w for w in workspaces}
    by_addr = {c["address"]: c for c in clients}
    tracks, shown, skipped = [], [], []
    count = {"tabs": 0}

    def tab_moments(ws_name):
        """A workspace on show: one moment per further tab of its deepest group (every group flips at once), and the actions that
        put the tabs back."""
        groups = _groups(clients, ws_name)
        lists = [[k for k, a in enumerate(g["members"]) if a != g["shown"]] for g in groups]
        moments = []
        for j in range(max((len(o) for o in lists), default=0)):
            acts, wins = [], []
            for g, others in zip(groups, lists):
                if j < len(others):
                    acts.append(("tab", g["shown"], others[j] + 1))
                    wins.append(by_addr[g["members"][others[j]]])
                    count["tabs"] += 1
            moments.append((acts, wins, "tab " + ", ".join(str(a[2]) for a in acts)))
        undo = [("tab", g["shown"], g["members"].index(g["shown"]) + 1) for g, o in zip(groups, lists) if o]
        return moments, undo

    def on_view(ws_name):
        """What showing a workspace shows: its windows but its groups' hidden tabs."""
        hidden_tabs = {a for g in _groups(clients, ws_name) for a in g["members"] if a != g["shown"]}
        return [c for c in by_ws.get(ws_name, []) if c["address"] not in hidden_tabs]

    for m in monitors:
        name = m["name"]
        active = m["activeWorkspace"]["name"]
        special_shown = (m.get("specialWorkspace") or {}).get("name") or ""
        if ws_by_name.get(active, {}).get("hasfullscreen"):
            skipped.append(name + ": fullscreen")
            continue
        track, pending = [], []          # the moments; what the next one (or the way back) does first, with no frame between

        def push(acts, wins, what):
            nonlocal pending
            track.append((pending + acts, wins, what))
            pending = []

        on_show = ([special_shown] if special_shown else []) + [active]
        for ws_name in on_show:          # what is on show: only its hidden tabs
            moments, undo = tab_moments(ws_name)
            for mo in moments:
                push(*mo)
            pending = pending + undo
        hidden = [w for w in workspaces if w.get("monitor") == name and w["name"] not in on_show and by_ws.get(w["name"])]
        for w in hidden:
            if w.get("hasfullscreen"):
                skipped.append(w["name"] + ": holds a fullscreen window")
        hidden = [w for w in hidden if not w.get("hasfullscreen")]
        hidden.sort(key=lambda w: (not is_special(w), w.get("id", 0), w["name"]))      # special ones first, over the home
        left_home = False
        for w in hidden:
            moments, undo = tab_moments(w["name"])
            if is_special(w):
                enter = [("special", name, w["name"][len("special:"):])]
                push(enter, on_view(w["name"]), "special workspace " + w["name"][len("special:"):])
            else:
                push([("ws", name, ws_key(w))], on_view(w["name"]), "workspace " + str(ws_key(w)).replace("name:", ""))
            for mo in moments:
                push(*mo)
            if is_special(w):
                pending = pending + undo + enter
                if special_shown:
                    pending.append(("special?", name, special_shown[len("special:"):]))
            else:
                left_home = True
                pending = pending + undo
            shown.append(w["name"])
        back = list(pending)
        if left_home:
            back.append(("ws", name, ws_key(ws_by_name.get(active, m["activeWorkspace"]))))
            if special_shown:
                back.append(("special?", name, special_shown[len("special:"):]))
        tracks.append((name, track, back))
    return tracks, shown, count["tabs"], skipped


def plan(monitors, workspaces, clients, active_window="", cursor=None, frames=DEFAULT_FRAMES, class_frames=None):
    """Steps for the session described. Returns a dict:

    steps    [[action, ...], ...]   one inner list per moment; an action is
             ("ws", monitor, key)          show this workspace on its monitor
             ("special", monitor, name)    toggle this special workspace on its monitor
             ("special?", monitor, name)   show it unless it is on show (the way back to one that was)
             ("tab", address, index)       make the index-th member (from 1) of this window's group the tab on show
    frames   [n, ...]   one per step: how many frames it stays -- the MOST that the windows it newly shows need: a window's
                        class in `class_frames` (exact, any case: kitty 2, VS Code 16, zen 24 on the user's panel), else `frames`
    labels   one line per step, for a person: what it shows and whose windows (the debug run's notices)
    restore  [action, ...]          the way back of the monitors that worked to the end, then the focus and the pointer;
                                    run as one moment right after the last step's frames
    shown / tabs / skipped          for the report

    Every monitor works at the same time: moment k of the run is every monitor's moment k, and a monitor that is done goes home
    in the moment after its last one while the others go on.
    """
    clients = [c for c in clients if c.get("mapped", True) and c.get("workspace", {}).get("name")]
    focused = next((m["name"] for m in monitors if m.get("focused")), monitors[0]["name"] if monitors else "")
    lower = {str(k).lower(): int(v) for k, v in (class_frames or {}).items()}
    tracks, shown, tabs, skipped = _tracks(monitors, workspaces, clients)
    depth = max((len(t[1]) for t in tracks), default=0)
    steps, need, labels, back_all = [], [], [], []
    for k in range(depth):
        acts, wins, words = [], [], []
        for name, track, back in tracks:
            if k < len(track):
                a, w, what = track[k]
                acts.extend(a)
                wins.extend(w)
                words.append(what + ": " + _classes(w))
            elif k == len(track):
                acts.extend(back)
        steps.append(_order(acts, focused))
        need.append(max([frames_of(c, frames, lower) for c in wins] or [frames]))
        labels.append("; ".join(words))
    for name, track, back in tracks:
        if len(track) == depth:
            back_all.extend(back)
    restore = _order(back_all, focused) if steps else []
    if steps:
        restore.append(("monitor", focused))
        if active_window:
            restore.append(("window", active_window))
        if cursor:
            restore.append(("cursor", int(cursor["x"]), int(cursor["y"])))
    return {"steps": steps, "frames": need, "labels": labels, "restore": restore, "shown": shown, "tabs": tabs,
            "skipped": skipped, "focused": focused}


def step_ms(p, hz):
    """Each step's time on the compositor's clock: its frames of a monitor refreshing at `hz` (the slowest one)."""
    return [max(1, int(round(f * 1000.0 / max(hz, 1.0)))) for f in p["frames"]]


def _order(acts, focused):
    """Within one moment the focused monitor's workspace comes last (a workspace dispatch focuses its monitor)."""
    return sorted(acts, key=lambda a: 1 if a[0] in ("ws", "special", "special?") and a[1] == focused else 0)


# ---------------------------------------------------------------------------------------------------------------- the Lua

def lua_str(s):
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def lua_action(a):
    kind = a[0]
    if kind == "ws":
        key = a[2]
        sel = str(key) if isinstance(key, int) else lua_str(key)
        return "ws(%s, %s)" % (lua_str(a[1]), sel)
    if kind == "special":
        return "special(%s, %s, false)" % (lua_str(a[1]), lua_str(a[2]))
    if kind == "special?":
        return "special(%s, %s, true)" % (lua_str(a[1]), lua_str(a[2]))
    if kind == "tab":
        return "tab(%s, %d)" % (lua_str(a[1]), a[2])
    if kind == "monitor":
        return "mon(%s)" % lua_str(a[1])
    if kind == "window":
        return "win(%s)" % lua_str(a[1])
    if kind == "cursor":
        return "cur(%d, %d)" % (a[1], a[2])
    raise ValueError(kind)


LUA = r'''-- generated by tools/theme/hidden_repaint.py: one run, then nothing of it is left but the result file
local R = { i = 0, n = %(n)d, t0 = os.clock(), errs = {}, here = {}, stopped = nil }
_G.__lares_repaint = R        -- the timers live while this does
local function try(f, ...) local ok, e = pcall(f, ...); if not ok then R.errs[#R.errs + 1] = tostring(e) end; return ok end
local function d(x) try(function() hl.dispatch(x) end) end
local function mon(name) d(hl.dsp.focus({ monitor = name })) end
local function shows(name) local m = hl.get_monitor(name); return m and m.active_workspace and m.active_workspace.name end
local function ws(monitor, key)
    d(hl.dsp.focus({ workspace = key })); R.here[monitor] = shows(monitor)
end
local function special_on(monitor)
    local m = hl.get_monitor(monitor); local s = m and m.active_special_workspace
    return s and s.name or ""
end
local function special(monitor, name, only_if_hidden)
    if only_if_hidden and special_on(monitor) == "special:" .. name then return end
    mon(monitor); d(hl.dsp.workspace.toggle_special(name))
end
local function tab(address, index) d(hl.dsp.group.active({ index = index, window = "address:" .. address })) end
local function win(address) d(hl.dsp.focus({ window = "address:" .. address })) end
local function cur(x, y) d(hl.dsp.cursor.move({ x = x, y = y })) end
local steps = {
%(steps)s
}
local function restore()
%(restore)s
end
local function tabs_back()
%(tabs_back)s
end
local anim = hl.get_config("animations:enabled")
local warps = hl.get_config("cursor:no_warps")
local function pointer()
    local ok, p = pcall(hl.get_cursor_pos)
    if ok and type(p) == "table" then return p.x or p[1] or 0, p.y or p[2] or 0 end
    return 0, 0
end
local px0, py0 = pointer()
R.warp = 0
local function strayed()
    local x, y = pointer()
    R.warp = math.max(R.warp, math.abs(x - px0), math.abs(y - py0))
end
local function finish(word)
    try(function() hl.config({ animations = { enabled = anim }, cursor = { no_warps = warps } }) end)
    local f = io.open(%(result)s .. ".tmp", "w")
    if f then
        f:write(word, " steps=", tostring(R.i), " warp=", tostring(math.floor(R.warp + 0.5)), " errs=", tostring(#R.errs), " ", table.concat(R.errs, " | "), "\n")
        f:close(); os.rename(%(result)s .. ".tmp", %(result)s)
    end
    _G.__lares_repaint = nil
end
local DEBUG = %(debug)s
local function notice(text, ms)
    -- Hyprland's own notification (the shell is the notification daemon: a notice about its run is not sent through it)
    d(hl.dsp.exec_cmd("hyprctl notify 1 " .. tostring(ms) .. " 0 '  repaint  " .. text .. "'"))
end
local function moved()
    -- somebody else changed a workspace since the last step: the user is acting under the curtain
    for monitor, name in pairs(R.here) do if shows(monitor) ~= name then return true end end
    return false
end
local function step()
    strayed()
    if moved() then tabs_back(); finish("stopped"); return end
    R.i = R.i + 1
    if R.i > R.n then restore(); if DEBUG then notice("back where it was", 1500) end; finish("ok"); return end
    try(steps[R.i][1])
    if DEBUG then notice(tostring(R.i) .. "/" .. tostring(R.n) .. "  " .. steps[R.i][3], steps[R.i][2]) end
    R.timer = hl.timer(step, { timeout = steps[R.i][2], type = "oneshot" })
end
for _, m in ipairs(hl.get_monitors()) do R.here[m.name] = m.active_workspace and m.active_workspace.name end
try(function() hl.config({ animations = { enabled = false }, cursor = { no_warps = true } }) end)
step()
'''


def lua_chunk(p, ms, result_path, debug_ms=0):
    """`ms` each step's time (`step_ms`); `debug_ms` > 0: every step that long instead, named in a Hyprland notice with the frames
    a real run gives it."""
    steps = []
    for k, moment in enumerate(p["steps"]):
        t = debug_ms if debug_ms > 0 else ms[k]
        text = ("%s  %d frames" % (p["labels"][k], p["frames"][k])).replace("'", "").replace('"', "")
        steps.append("    { function() " + "; ".join(lua_action(a) for a in moment) + " end, %d, %s }," % (t, lua_str(text)))
    restore = ["    " + lua_action(a) for a in p["restore"]] or ["    "]
    tabs_back = ["    " + lua_action(a) for a in p.get("tabs_back", [])] or ["    "]
    return LUA % {"n": len(p["steps"]), "steps": "\n".join(steps), "restore": "\n".join(restore),
                  "tabs_back": "\n".join(tabs_back), "result": lua_str(result_path), "debug": "true" if debug_ms > 0 else "false"}


# ----------------------------------------------------------------------------------------------------------- the session

def hypr_socket():
    sig = os.environ.get("HYPRLAND_INSTANCE_SIGNATURE", "")
    rt = os.environ.get("XDG_RUNTIME_DIR", "")
    if not sig or not rt:
        raise RuntimeError("no Hyprland session in the environment")
    return os.path.join(rt, "hypr", sig, ".socket.sock")


def ask(request, timeout=2.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(hypr_socket())
    s.sendall(request.encode())
    out = b""
    while True:
        b = s.recv(65536)
        if not b:
            break
        out += b
    s.close()
    return out.decode(errors="replace")


def read_session():
    mons = json.loads(ask("j/monitors"))
    wss = json.loads(ask("j/workspaces"))
    cls = json.loads(ask("j/clients"))
    try:
        aw = json.loads(ask("j/activewindow")).get("address", "")
    except ValueError:
        aw = ""
    try:
        cur = json.loads(ask("j/cursorpos"))
    except ValueError:
        cur = None
    return mons, wss, cls, aw, cur


def tabs_back_of(clients):
    """Every group's tab on show, as actions: what a stopped run still puts back."""
    out, seen = [], set()
    for c in clients:
        g = c.get("grouped") or []
        if len(g) < 2 or not c.get("visible", not c.get("hidden")) or tuple(g) in seen:
            continue
        seen.add(tuple(g))
        if c["address"] in g:
            out.append(("tab", c["address"], g.index(c["address"]) + 1))
    return out


def main(argv):
    if len(argv) < 2 or argv[1] not in ("run", "plan"):
        print(__doc__.strip().split("\n\n")[1])
        return 2
    frames, class_frames, timeout_ms, dry, debug_ms = DEFAULT_FRAMES, {}, 0, False, 0
    i = 2
    while i < len(argv):
        if argv[i] == "--frames":
            frames = max(1, int(argv[i + 1])); i += 2
        elif argv[i] == "--timeout":
            timeout_ms = int(argv[i + 1]); i += 2
        elif argv[i] == "--class":
            # CLASS=N; a class may hold a comma (CLAUDE.md), so one flag per class
            name, _, n = argv[i + 1].rpartition("=")
            if not name or not n.isdigit() or int(n) < 1:
                print("REPAINT FAIL --class wants CLASS=FRAMES, not " + argv[i + 1]); return 1
            class_frames[name.lower()] = int(n); i += 2
        elif argv[i] == "--debug-ms":
            debug_ms = max(0, int(argv[i + 1])); i += 2
        elif argv[i] == "--dry":
            dry = True; i += 1
        else:
            print("REPAINT FAIL unknown argument " + argv[i]); return 1
    t0 = time.monotonic()
    try:
        mons, wss, cls, aw, cur = read_session()
    except Exception as e:                                    # no session, a dead socket: nothing to do, say why
        print("REPAINT skip no session (%s)" % e)
        return 0
    p = plan(mons, wss, cls, aw, cur, frames, class_frames)
    p["tabs_back"] = tabs_back_of(cls)
    slowest = min([float(m.get("refreshRate") or 60.0) for m in mons] or [60.0])
    ms = step_ms(p, slowest)
    if argv[1] == "plan" or dry:
        for k, moment in enumerate(p["steps"]):
            print("step %d (%d frames, %d ms): %s    [%s]" % (k + 1, p["frames"][k], ms[k], p["labels"][k],
                                                            "  ".join(lua_action(a) for a in moment)))
        print("restore: " + "  ".join(lua_action(a) for a in p["restore"]))
        print("skipped: " + (", ".join(p["skipped"]) or "-"))
        return 0
    if not p["steps"]:
        print("REPAINT skip nothing hidden" + ((" (" + ", ".join(p["skipped"]) + ")") if p["skipped"] else ""))
        return 0
    rt = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "lares")
    os.makedirs(rt, exist_ok=True)
    chunk, result = os.path.join(rt, "repaint.lua"), os.path.join(rt, "repaint.result")
    for f in (result, result + ".tmp"):
        try:
            os.unlink(f)
        except FileNotFoundError:
            pass
    total = (len(p["steps"]) * debug_ms) if debug_ms > 0 else sum(ms)
    if timeout_ms <= 0:
        timeout_ms = total + 3000
    with open(chunk, "w") as f:
        f.write(lua_chunk(p, ms, result, debug_ms))
    # the run's planned length, first: the shell's watchdog is armed from it (a run is as long as its windows need)
    print("REPAINT plan steps=%d ms=%d" % (len(p["steps"]), total), flush=True)
    answer = ask("/eval dofile(%s)" % lua_str(chunk)).strip()
    if answer != "ok":
        print("REPAINT FAIL the compositor refused the chunk: " + answer[:300])
        return 1
    deadline = time.monotonic() + timeout_ms / 1000.0
    word = None
    while time.monotonic() < deadline:
        try:
            with open(result) as f:
                word = f.read().strip()
            break
        except FileNotFoundError:
            time.sleep(0.004)
    took = int((time.monotonic() - t0) * 1000)
    if word is None:
        print("REPAINT FAIL no result within %d ms (the compositor still finishes and restores by itself)" % timeout_ms)
        return 1
    head = word.split(" ", 1)[0]
    errs = word.split("errs=", 1)[1] if "errs=" in word else "0"
    warp = word.split("warp=", 1)[1].split(" ", 1)[0] if "warp=" in word else "?"
    if head == "ok" and errs.startswith("0"):
        print("REPAINT ok steps=%d ms=%d frames=%s warp=%s shown=%s tabs=%d%s%s" % (
            len(p["steps"]), took, ",".join(str(f) for f in p["frames"]), warp, ",".join(p["shown"]) or "-", p["tabs"],
            (" debug=%d" % debug_ms) if debug_ms > 0 else "",
            (" skipped=" + ";".join(p["skipped"])) if p["skipped"] else ""))
        return 0
    if head == "stopped":
        print("REPAINT stopped the session changed under the run (%s) ms=%d" % (word, took))
        return 0
    print("REPAINT FAIL %s ms=%d" % (word, took))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
