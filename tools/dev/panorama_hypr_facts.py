#!/usr/bin/env python3
"""tools/dev/panorama_hypr_facts.py -- the Hyprland facts Panorama is built on, re-proved in a nested Hyprland.

    tools/dev/panorama_hypr_facts.py            ends in PANORAMA_FACTS RESULT PASS|FAIL
    ONLY=F5,F7                                  run only these facts (setup still runs)
    PANORAMA_FACTS_KEEP=1                       keep the nested env up afterwards (LOCK_ENV=pnfx; `tools/dev/lock_env.sh down`)
    ARM=snapdown                                F5 expects ties DOWNWARD (1.1 -> 1.0): the run must FAIL on F5
    ARM=reservewiped                            F1 expects a full rule to WIPE the reserve: the run must FAIL on F1

Every fact prints `FACT <id> PASS|FAIL <what was read>`. A FAIL here is not a bug in Lares: it says Hyprland no longer behaves the
way the engine (tools/panorama/engine.lua) assumes, and the engine must be re-read against the new behaviour before anything else.
The facts (Hyprland 0.57.2, measured 2026-11-21; docs/agent_added_files_and_folders/panorama/FACTS.md has the consequences):

  F1   a full hl.monitor rule (mode/position/scale) keeps the reserved_area HyprReserve set; a partial rule merges with the newest
       rule of that output name (a scale-only rule keeps the mode an earlier eval set)
  F2   `hyprctl reload` starts a fresh Lua state: globals and hl.on handlers of the old one are gone
  F3   an hl.on("monitor.added") handler gets the HL.Monitor (userdata, .name); a rule sent inside it lands after the handler
  F5   an invalid fractional scale is snapped to k/120 with k dividing 120*W and 120*H, the nearest, ties upward
  F6   a persistent workspace rule's workspaces are already on the first monitor when monitor.removed runs, and come back to the
       rule's monitor by themselves when it is plugged again
  F7   moving a workspace that is not on show changes neither focus nor the pointer; moving the FOCUSED monitor's active workspace
       carries the focus and the pointer with it even under cursor:no_warps
  F8   io and os.getenv exist in Hyprland's Lua; hl.dispatch(hl.dsp.event("x,y")) arrives on socket2 as `custom>>x,y`
  F9   position "auto-center-up" stacks above the whole layout (the engine computes positions itself)
  F10  a mirroring output leaves `hyprctl -j monitors` (only `all` lists it) and its mirrorOf is the source's monitor ID
  F11  disabling an output fires monitor.removed for it; re-enabling the internal one from inside that handler works
  F14  hl.timer refuses timeout 0; set_enabled(false) cancels a pending oneshot
  F16  a 4 KB long-bracket string survives `hyprctl eval`
  F17  a rule sent for an output name holds for the next output of that name (a replug inherits it)
  NORULE  an output no rule matches comes up at its preferred mode ("No rule found ... trying to use the first")
  G1   a new output is born on a workspace of its own (the first free id) and STAYS on it when persistent rules bring 3 and 4 over
  G2   moving that birth workspace to another monitor (the new one not focused) puts the new output on its own workspace, destroys
       the empty one, and moves neither the focus nor the pointer
  G3   a partial rule after a `disabled = true` rule keeps the output disabled (the unplug's reset must say disabled = false)
  G4   an output that comes up under a standing `disabled` rule is listed, off, and fires NO monitor.added
  G5   `hyprctl output remove` of a disabled or a mirroring headless output answers "output not found" and removes nothing
  G6   the birth workspace of an output that is disabled or made a mirror is destroyed at once (no stray is left)
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENV = os.path.join(ROOT, "tools/dev/lock_env.sh")
NAME = "pnfx"
B = "/tmp/lrlk-" + NAME
os.environ["LOCK_ENV"] = NAME
ARM = os.environ.get("ARM", "")
if ARM not in ("", "snapdown", "reservewiped"):
    print("PANORAMA_FACTS RESULT FAIL (unknown ARM %s)" % ARM)
    sys.exit(1)
ONLY = set(x.strip() for x in os.environ.get("ONLY", "").split(",") if x.strip())
results = []


def sh(*args, timeout=30):
    p = subprocess.run([ENV, *args], capture_output=True, text=True, timeout=timeout)
    return p.stdout + p.stderr


def hc(*args):
    return sh("hyprctl", *args)


def ev(lua):
    out = hc("eval", lua)
    if "error" in out.lower():
        raise RuntimeError("eval: " + out.strip()[:300])
    return out


def lua_read(expr_lua):
    """Run Lua that sets `R` (a string) and read it back through a file (an eval returns no value)."""
    path = B + "/fact_read.txt"
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    ev("local R = ''; do " + expr_lua + " end; local f = io.open('" + path + "', 'w'); f:write(R); f:close()")
    with open(path) as f:
        return f.read()


def mons(all_=True):
    out = hc("-j", "monitors", "all") if all_ else hc("-j", "monitors")
    return {m["name"]: m for m in json.loads(out)}


def wsmap():
    return {w["id"]: w["monitor"] for w in json.loads(hc("-j", "workspaces"))}


def cursor():
    return lua_read("local p = hl.get_cursor_pos(); R = string.format('%d %d', math.floor(p.x + 0.5), math.floor(p.y + 0.5))")


def focused():
    return [m["name"] for m in json.loads(hc("-j", "monitors")) if m["focused"]]


def wait_for(fn, timeout=4.0, step=0.1):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = fn()
        if last:
            return last
        time.sleep(step)
    return last


def fact(fid, ok, detail):
    results.append((fid, ok))
    print("FACT %s %s %s" % (fid, "PASS" if ok else "FAIL", detail), flush=True)


class Socket2:
    def __init__(self):
        sig = sorted(os.listdir(B + "/rt/hypr"))[0]
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect("%s/rt/hypr/%s/.socket2.sock" % (B, sig))
        self.lines = []
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _run(self):
        buf = b""
        while True:
            try:
                d = self.s.recv(4096)
            except OSError:
                return
            if not d:
                return
            buf += d
            while b"\n" in buf:
                l, buf = buf.split(b"\n", 1)
                self.lines.append(l.decode("utf-8", "replace"))


def ensure3():
    """F5 F6 F9 F10 need LOCK-3; F3 makes it, ONLY= may skip F3."""
    if "LOCK-3" not in mons():
        hc("output", "create", "headless", "LOCK-3")
        wait_for(lambda: "LOCK-3" in mons(), 4)
        ev('hl.monitor({ output = "LOCK-3", mode = "preferred", position = "0x-1080", scale = 1 })')
        time.sleep(0.6)


GROUPS = {"G1": ("G1", "G2"), "G4": ("G3", "G4", "G5")}


def want(fid):
    return not ONLY or fid in ONLY or any(x in ONLY for x in GROUPS.get(fid, ()))


def main():
    sh("down")
    up = subprocess.run([ENV, "up"], capture_output=True, text=True, timeout=90, env=dict(os.environ, OUTPUTS="2"))
    if "LOCK_ENV UP" not in up.stdout:
        print(up.stdout + up.stderr)
        print("PANORAMA_FACTS RESULT FAIL (the nested Hyprland did not come up)")
        return 1
    s2 = Socket2()
    time.sleep(0.3)

    def run(fid, fn):
        if not want(fid):
            return
        try:
            fn()
        except Exception as e:  # a fact that throws is a failed fact, named
            fact(fid, False, "threw: %s" % e)

    def f1():
        ev('hl.monitor({ output = "LOCK-1", reserved_area = { top = 40, right = 0, bottom = 0, left = 0 } })')
        time.sleep(0.5)
        ev('hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = 1.25 })')
        time.sleep(0.8)
        m = mons()["LOCK-1"]
        kept = m["reserved"] == ([0, 0, 0, 0] if ARM == "reservewiped" else [0, 40, 0, 0]) and abs(m["scale"] - 1.25) < 1e-3
        ev('hl.monitor({ output = "LOCK-2", mode = "1920x1080@60", position = "2304x0", scale = 1 })')
        time.sleep(0.8)
        ev('hl.monitor({ output = "LOCK-2", scale = 1.5 })')
        time.sleep(0.8)
        m2 = mons()["LOCK-2"]
        merged = m2["width"] == 1920 and abs(m2["scale"] - 1.5) < 1e-3 and m2["x"] == 2304
        fact("F1", kept and merged, "reserve after full rule %s scale %s; partial merge: %sx%s s%s x%s" % (
            m["reserved"], m["scale"], m2["width"], m2["height"], m2["scale"], m2["x"]))
        ev('hl.monitor({ output = "LOCK-1", reserved_area = 0, scale = 1 })')

    def f8():
        r = lua_read("R = tostring(io ~= nil) .. ' ' .. tostring(os.getenv('HOME') ~= nil) .. ' ' .. _VERSION")
        n0 = len(s2.lines)
        ev('hl.dispatch(hl.dsp.event("lares-facts,42"))')
        got = wait_for(lambda: any(l == "custom>>lares-facts,42" for l in s2.lines[n0:]), 3)
        fact("F8", r.startswith("true true") and bool(got), "io/getenv/version: %r; custom event seen: %s" % (r, bool(got)))

    def f3():
        ev("""
pfx = pfx or {}
pfx.added = {}
if not pfx.hooked then
  pfx.hooked = true
  hl.on("monitor.added", function(m)
    pfx.added[#pfx.added + 1] = type(m) .. ":" .. tostring(m and m.name)
    if m and m.name == "LOCK-3" then
      hl.monitor({ output = "LOCK-3", mode = "preferred", position = "0x-1080", scale = 1 })
      local mm = hl.get_monitor("LOCK-3")
      pfx.sameturn = tostring(mm and mm.x) .. "," .. tostring(mm and mm.y)
    end
  end)
end""")
        hc("output", "create", "headless", "LOCK-3")
        got = wait_for(lambda: (mons().get("LOCK-3") or {}).get("y") == -1080, 4)
        info = lua_read("R = table.concat(pfx.added, ' ') .. ' sameturn=' .. tostring(pfx.sameturn)")
        ok = bool(got) and "userdata:LOCK-3" in info and "sameturn=0,-1080" not in info
        fact("F3", ok, "handler saw %s; rule landed after the handler: %s" % (info, bool(got)))

    def norule():
        hc("output", "create", "headless", "LOCK-4")
        m = wait_for(lambda: mons().get("LOCK-4"), 4) or {}
        log = open(sorted(__import__("glob").glob(B + "/rt/hypr/*/hyprland.log"))[0], errors="replace").read()
        ok = m.get("width") == 1920 and m.get("height") == 1080 and "No rule found for LOCK-4" in log
        fact("NORULE", ok, "LOCK-4 came up %sx%s s%s; log names the miss: %s" % (
            m.get("width"), m.get("height"), m.get("scale"), "No rule found for LOCK-4" in log))
        hc("output", "remove", "LOCK-4")
        time.sleep(0.6)

    def f5():
        ensure3()
        cases = [(1.1, 1.0 if ARM == "snapdown" else 1.2), (1.3, 4 / 3), (1.75, 5 / 3), (1.6, 1.6)]
        got = []
        ok = True
        for ask, exp in cases:
            ev('hl.monitor({ output = "LOCK-3", scale = %s })' % ask)
            time.sleep(0.6)
            s = mons()["LOCK-3"]["scale"]
            got.append("%s->%.4f" % (ask, s))
            ok = ok and abs(s - exp) < 1e-3
        fact("F5", ok, "1920x1080: " + " ".join(got))
        ev('hl.monitor({ output = "LOCK-3", scale = 1 })')
        time.sleep(0.5)

    def f6():
        ensure3()
        ev("""pfx = pfx or {}
pfx.r3 = hl.workspace_rule({ workspace = "3", monitor = "LOCK-3", persistent = true })
pfx.r4 = hl.workspace_rule({ workspace = "4", monitor = "LOCK-3", persistent = true })
pfx.atremove = ""
if not pfx.rmhooked then
  pfx.rmhooked = true
  hl.on("monitor.removed", function(m)
    local t = {}
    for _, w in ipairs(hl.get_workspaces()) do t[#t + 1] = tostring(w.id) .. "@" .. tostring(w.monitor and w.monitor.name) end
    table.sort(t)
    pfx.atremove = pfx.atremove .. "[" .. tostring(m.name) .. ": " .. table.concat(t, ",") .. "]"
  end)
end""")
        wait_for(lambda: wsmap().get(3) == "LOCK-3" and wsmap().get(4) == "LOCK-3", 3)
        hc("output", "remove", "LOCK-3")
        time.sleep(1.0)
        at = lua_read("R = pfx.atremove")
        moved = "3@LOCK-1" in at and "4@LOCK-1" in at
        hc("output", "create", "headless", "LOCK-3")
        back = wait_for(lambda: wsmap().get(3) == "LOCK-3" and wsmap().get(4) == "LOCK-3", 4)
        fact("F6", moved and bool(back), "at monitor.removed: %s; back on replug: %s" % (at, bool(back)))
        wait_for(lambda: (mons().get("LOCK-3") or {}).get("y") == -1080, 3)

    def f17():
        m = mons().get("LOCK-3") or {}
        fact("F17", m.get("y") == -1080 and abs(m.get("scale", 0) - 1) < 1e-3,
             "replugged LOCK-3 at %s,%s s%s (the rule of the old LOCK-3)" % (m.get("x"), m.get("y"), m.get("scale")))

    def f7():
        ev('hl.dispatch(hl.dsp.focus({ monitor = "LOCK-1" }))')
        time.sleep(0.4)
        c0, f0 = cursor(), focused()
        ev('hl.dispatch(hl.dsp.workspace.move({ workspace = 4, monitor = "LOCK-1" }))')
        time.sleep(0.5)
        c1, f1_ = cursor(), focused()
        quiet = (c0 == c1 and f0 == f1_ and wsmap().get(4) == "LOCK-1")
        ev('hl.dispatch(hl.dsp.workspace.move({ workspace = 4, monitor = "LOCK-3" }))')
        time.sleep(0.4)
        active = json.loads(hc("-j", "monitors"))
        act1 = [m["activeWorkspace"]["id"] for m in active if m["name"] == "LOCK-1"][0]
        ev('hl.config({ cursor = { no_warps = true } }); hl.dispatch(hl.dsp.workspace.move({ workspace = %d, monitor = "LOCK-3" })); hl.config({ cursor = { no_warps = false } })' % act1)
        time.sleep(0.6)
        c2, f2 = cursor(), focused()
        carried = f2 == ["LOCK-3"] and c2 != c0
        fact("F7", quiet and carried, "hidden ws move: cursor %s->%s focus %s->%s; focused active ws %d move under no_warps: focus %s cursor %s" % (
            c0, c1, f0, f1_, act1, f2, c2))
        ev('hl.dispatch(hl.dsp.workspace.move({ workspace = %d, monitor = "LOCK-1" }))' % act1)
        ev('hl.dispatch(hl.dsp.focus({ monitor = "LOCK-1" }))')
        time.sleep(0.5)

    def f9():
        ensure3()
        ev('hl.monitor({ output = "LOCK-3", position = "auto-center-up" })')
        time.sleep(0.6)
        a = mons()["LOCK-3"]
        ev('hl.monitor({ output = "LOCK-2", position = "auto-center-up" })')
        time.sleep(0.6)
        ms = mons()
        stacked = ms["LOCK-2"]["y"] < 0 and ms["LOCK-3"]["y"] < ms["LOCK-2"]["y"]
        fact("F9", a["y"] < 0 and stacked, "LOCK-3 alone %s,%s; with LOCK-2 also: LOCK-2 %s,%s LOCK-3 %s,%s" % (
            a["x"], a["y"], ms["LOCK-2"]["x"], ms["LOCK-2"]["y"], ms["LOCK-3"]["x"], ms["LOCK-3"]["y"]))
        ev('hl.monitor({ output = "LOCK-2", position = "2880x0" })')
        ev('hl.monitor({ output = "LOCK-3", position = "0x-1080" })')
        time.sleep(0.6)

    def f10():
        ensure3()
        ev('hl.monitor({ output = "LOCK-3", mirror = "LOCK-1" })')
        time.sleep(0.9)
        visible = "LOCK-3" in mons(all_=False)
        mo = mons()["LOCK-3"].get("mirrorOf")
        lid = str(mons()["LOCK-1"]["id"])
        fact("F10", (not visible) and mo == lid, "in monitors: %s; mirrorOf %r (LOCK-1 id %s)" % (visible, mo, lid))
        ev('hl.monitor({ output = "LOCK-3", mirror = "", position = "0x-1080", scale = 1 })')
        time.sleep(0.8)

    def f11():
        ev("""pfx = pfx or {}
pfx.safe = ""
if not pfx.safehooked then
  pfx.safehooked = true
  hl.on("monitor.removed", function(m)
    local live = 0
    for _, mm in ipairs(hl.get_monitors({ all = true })) do
      if mm.enabled and mm.name ~= m.name and mm.name:sub(1, 5) == "LOCK-" then live = live + 1 end
    end
    pfx.safe = pfx.safe .. "[" .. m.name .. ":" .. live .. "]"
    if live == 0 then hl.monitor({ output = "LOCK-1", disabled = false }) ; pfx.safe = pfx.safe .. "[reenable]" end
  end)
end""")
        ev('hl.monitor({ output = "LOCK-1", disabled = true })')
        time.sleep(0.7)
        off = mons()["LOCK-1"]["disabled"]
        hc("output", "remove", "LOCK-2")
        time.sleep(0.6)
        hc("output", "remove", "LOCK-3")
        back = wait_for(lambda: not mons()["LOCK-1"]["disabled"], 4)
        log = lua_read("R = pfx.safe")
        fact("F11", off and bool(back) and "[LOCK-1:" in log and "[reenable]" in log,
             "disable fired removed for LOCK-1: %s; handler log %s; LOCK-1 back: %s" % ("[LOCK-1:" in log, log, bool(back)))
        hc("output", "create", "headless", "LOCK-2")
        time.sleep(0.8)

    def f14():
        refused = False
        try:
            ev('pfx.t0 = hl.timer(function() end, { timeout = 0, type = "oneshot" })')
        except RuntimeError as e:
            refused = "timeout" in str(e)
        ev("""pfx.tlog = ""
pfx.tc = hl.timer(function() pfx.tlog = pfx.tlog .. "c" end, { timeout = 100, type = "oneshot" })
pfx.tc:set_enabled(false)
pfx.td = hl.timer(function() pfx.tlog = pfx.tlog .. "d" end, { timeout = 120, type = "oneshot" })""")
        time.sleep(0.6)
        # The nested compositor runs its timers on its own loop: a nudge wakes it
        hc("dispatch", 'hl.dsp.focus({ monitor = "LOCK-1" })')
        time.sleep(0.3)
        log = lua_read("R = pfx.tlog")
        fact("F14", refused and log == "d", "timeout 0 refused: %s; fired %r (c cancelled, d kept)" % (refused, log))

    def f16():
        payload = json.dumps({"k": "x" * 4000, "q": 'a"b]=c'})
        r = lua_read("local s = [==[" + payload + "]==]; R = tostring(#s)")
        fact("F16", r == str(len(payload)), "lua %s bytes, sent %d" % (r, len(payload)))

    def f2():
        ev("pfx = pfx or {}; pfx.marker = 'alive'")
        hc("reload")
        time.sleep(2.0)
        r = lua_read("R = tostring(pfx ~= nil)")
        fact("F2", r == "false", "global after reload present: %s" % r)

    def wsall():
        return sorted((w["id"], w["monitor"]) for w in json.loads(hc("-j", "workspaces")) if w["id"] > 0)

    def active():
        return {m["name"]: m["activeWorkspace"]["id"] for m in json.loads(hc("-j", "monitors"))}

    def gsetup():
        """One output (LOCK-1) with workspaces 1-4 persistent on it, and a log of the monitor events."""
        for n in ("LOCK-2", "LOCK-3", "LOCK-4", "LOCK-5"):
            if n in mons():
                ev('hl.monitor({ output = "%s", disabled = false, mirror = "", mode = "preferred", position = "auto", scale = 1 })' % n)
                time.sleep(0.5)
                hc("output", "remove", n)
        time.sleep(0.6)
        ev("""pfx = pfx or {}
pfx.g = pfx.g or {}
for i = 1, 4 do
  if pfx.g[i] then pfx.g[i]:set_enabled(false) end
  pfx.g[i] = hl.workspace_rule({ workspace = tostring(i), monitor = "LOCK-1", persistent = true })
end
pfx.gev = ""
if not pfx.ghooked then
  pfx.ghooked = true
  hl.on("monitor.added", function(m) pfx.gev = pfx.gev .. "[+" .. tostring(m.name) .. "]" end)
  hl.on("monitor.removed", function(m) pfx.gev = pfx.gev .. "[-" .. tostring(m.name) .. "]" end)
end""")
        ev('hl.dispatch(hl.dsp.focus({ monitor = "LOCK-1" }))')
        time.sleep(0.6)

    def g12():
        gsetup()
        hc("output", "create", "headless", "LOCK-5")
        wait_for(lambda: "LOCK-5" in mons(), 4)
        time.sleep(0.6)
        born = active().get("LOCK-5")
        ev('pfx.g[3]:set_enabled(false); pfx.g[4]:set_enabled(false); pfx.g[3] = hl.workspace_rule({ workspace = "3", monitor = "LOCK-5", persistent = true }); pfx.g[4] = hl.workspace_rule({ workspace = "4", monitor = "LOCK-5", persistent = true })')
        time.sleep(0.8)
        w, a = wsall(), active()
        stays = born not in (1, 2, 3, 4) and a.get("LOCK-5") == born and (3, "LOCK-5") in w and (4, "LOCK-5") in w and len(w) == 5
        fact("G1", stays, "born on %s; after the rules: %s, on show %s" % (born, w, a))
        c0, f0 = cursor(), focused()
        ev('hl.dispatch(hl.dsp.workspace.move({ workspace = %d, monitor = "LOCK-1" }))' % born)
        time.sleep(0.7)
        w, a = wsall(), active()
        fact("G2", [x[0] for x in w] == [1, 2, 3, 4] and a.get("LOCK-5") == 3 and cursor() == c0 and focused() == f0,
             "after moving %s away: %s, on show %s, focus %s -> %s, cursor %s -> %s" % (born, w, a, f0, focused(), c0, cursor()))

    def g345():
        gsetup()
        # G4: a standing disabled rule, then the output appears
        ev('hl.monitor({ output = "LOCK-5", disabled = true })')
        ev('pfx.gev = ""')
        hc("output", "create", "headless", "LOCK-5")
        wait_for(lambda: "LOCK-5" in mons(), 4)
        time.sleep(0.8)
        evs = lua_read("R = pfx.gev")
        fact("G4", mons()["LOCK-5"]["disabled"] and "+LOCK-5" not in evs, "disabled %s; events %r" % (mons()["LOCK-5"]["disabled"], evs))
        # G5: it cannot be removed while it is off, nor while it mirrors
        r1 = hc("output", "remove", "LOCK-5").strip()
        time.sleep(0.5)
        still1 = "LOCK-5" in mons()
        ev('hl.monitor({ output = "LOCK-5", disabled = false, mode = "preferred", position = "0x-1080", scale = 1 })')
        wait_for(lambda: not mons()["LOCK-5"]["disabled"], 4)
        ev('hl.monitor({ output = "LOCK-5", mirror = "LOCK-1" })')
        time.sleep(0.9)
        r2 = hc("output", "remove", "LOCK-5").strip()
        time.sleep(0.5)
        still2 = "LOCK-5" in mons()
        ev('hl.monitor({ output = "LOCK-5", mirror = "", position = "0x-1080", scale = 1 })')
        time.sleep(0.8)
        r3 = hc("output", "remove", "LOCK-5").strip()
        time.sleep(0.6)
        fact("G5", "not found" in r1 and still1 and "not found" in r2 and still2 and r3 == "ok" and "LOCK-5" not in mons(),
             "off: %r listed %s; mirroring: %r listed %s; on: %r" % (r1, still1, r2, still2, r3))
        # G3: disabled, then the old partial reset: still disabled at the next plug
        ev('hl.monitor({ output = "LOCK-5", disabled = true })')
        ev('hl.monitor({ output = "LOCK-5", mode = "preferred", position = "auto", scale = "auto" })')
        hc("output", "create", "headless", "LOCK-5")
        wait_for(lambda: "LOCK-5" in mons(), 4)
        time.sleep(0.8)
        kept = mons()["LOCK-5"]["disabled"]
        ev('hl.monitor({ output = "LOCK-5", disabled = false, mirror = "", mode = "preferred", position = "auto", scale = "auto" })')
        on = wait_for(lambda: not mons()["LOCK-5"]["disabled"], 4)
        fact("G3", kept and bool(on), "after a partial rule: disabled %s; after one that says disabled = false: on %s" % (kept, bool(on)))
        hc("output", "remove", "LOCK-5")
        time.sleep(0.6)

    def g6():
        gsetup()
        res = []
        ok = True
        for how in ('disabled = true', 'mirror = "LOCK-1"'):
            hc("output", "create", "headless", "LOCK-5")
            wait_for(lambda: "LOCK-5" in mons(), 4)
            time.sleep(0.6)
            born = active().get("LOCK-5")
            ev('hl.monitor({ output = "LOCK-5", %s })' % how)
            time.sleep(0.9)
            w = [x[0] for x in wsall()]
            ok = ok and born not in (1, 2, 3, 4) and w == [1, 2, 3, 4]
            res.append("%s: born on %s, then %s" % (how, born, w))
            ev('hl.monitor({ output = "LOCK-5", disabled = false, mirror = "", mode = "preferred", position = "0x-1080", scale = 1 })')
            time.sleep(0.8)
            hc("output", "remove", "LOCK-5")
            time.sleep(0.7)
        fact("G6", ok, "; ".join(res))

    for fid, fn in [("F1", f1), ("F8", f8), ("F3", f3), ("NORULE", norule), ("F5", f5), ("F6", f6), ("F17", f17), ("F7", f7),
                    ("F9", f9), ("F10", f10), ("F11", f11), ("F14", f14), ("F16", f16), ("G1", g12), ("G4", g345), ("G6", g6), ("F2", f2)]:
        run(fid, fn)

    if os.environ.get("PANORAMA_FACTS_KEEP") != "1":
        sh("down")
    failed = [f for f, ok in results if not ok]
    if not results:
        print("PANORAMA_FACTS RESULT FAIL (no fact ran)")
        return 1
    if failed:
        print("PANORAMA_FACTS RESULT FAIL (%s)" % ", ".join(failed))
        return 1
    print("PANORAMA_FACTS RESULT PASS (%d facts)" % len(results))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        if os.environ.get("PANORAMA_FACTS_KEEP") != "1":
            sh("down")
        print("PANORAMA_FACTS RESULT FAIL (runner threw: %s)" % e)
        sys.exit(1)
