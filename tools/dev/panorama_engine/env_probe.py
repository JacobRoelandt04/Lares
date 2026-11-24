#!/usr/bin/env python3
"""tools/dev/panorama_engine/env_probe.py -- Panorama's engine (tools/panorama/engine.lua) inside a REAL nested Hyprland.
Run through tools/dev/panorama_engine_env_probe.sh (ARM, LOCK_ENV, result line). Prints `  ok|FAIL <check>` lines, then
`PANORAMA_ENGINE_ENV RESULT PASS|FAIL`. No quickshell is started. The engine runs on LOCK-1 as the internal panel
(`panorama.internal_override`: the nested env has no eDP and its Hyprland environment cannot carry a variable).
"""
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
ENV = os.path.join(ROOT, "tools/dev/lock_env.sh")
# the engine's own version, read where it is written: a literal here is red after every change of it
ENGINE = int(re.search(r"^local ENGINE_VERSION = (\d+)", open(os.path.join(ROOT, "tools/panorama/engine.lua")).read(), re.M).group(1))
NAME = os.environ.get("LOCK_ENV", "pe1")
B = "/tmp/lrlk-" + NAME
os.environ["LOCK_ENV"] = NAME
ARM = os.environ.get("ARM", "")
ARMS = {
    # (noverifyremove lives in panorama_cases.lua: here the start's own sweep also takes the output, so the arm cannot bite)
    "nohandover": ("  if handOver(plan, outs) then waiting = true end", "", "four workspaces, the new display shows its own"),
    # name: (anchor, replacement, the check that must go red)
    "noguard": ('arm("guard", guardMs or 45000, function()', '(function(...) end)("guard", guardMs or 45000, function()', "trial: no shell, guard reverts"),
    "nodedup": ('  if out.x ~= spec.position[1] or out.y ~= spec.position[2] then return "position" end',
                '  if true then return "position" end', "replug: no rule"),
    "nodefer": ("if wrong and act and act.id == id then", "if false then", "deferred: focused active workspace waits"),
    "nosafety": ("if not anyOn and internal then", "if false then", "safety: internal re-enabled by the handler"),
    "nohooked": ("if not P.hooked then", "if true then", "exactly one rule for it"),
    # a workspace is moved onto an output that is still a mirror: Hyprland answers "Monitor not found"
    "mirrormove": ("    if target and mirroring[target] then", "    if false then", "mirror revert: no warning"),
    # a deferred workspace the compositor already satisfied is cleared without its persistent rule
    "norulerun": ("      P.deferred[w] = nil; any = true\n      setRule(w, target)\n    elseif id ~= actId then",
                  "      P.deferred[w] = nil; any = true\n    elseif id ~= actId then", "deferred: satisfied by the user"),
    # ---- cast displays ----
    "nostraysweep": ("    if M.isCast(m.name) and not P.cast.keep[m.name] then", "    if false then", "cast: keep([]) sweeps"),
    "castkeepdrop": ("  for _, n in ipairs(d.keep or {}) do if M.isCast(n) then P.cast.keep[n] = true end end", "", "cast: a reload keeps a live cast"),
    "castmirroron": ("  if M.isCast(name) then return \"\" end\n  local mir = spec.mirror", "  local mir = spec.mirror", "leaves the output on and no mirror"),
    "castnoext": ("    if o ~= internal then externals[#externals + 1] = o end", "    if o ~= internal and not M.isCast(o.name) then externals[#externals + 1] = o end",
                       "cast: workspaces 3 and 4 are the cast's"),
    "castopendup": ("  for _, n in ipairs(keysOf(P.cast.map)) do if P.cast.map[n] == id then name = n; break end end", "", "cast: the same identity reuses its output"),
}
if ARM and ARM not in ARMS:
    print("PANORAMA_ENGINE_ENV RESULT FAIL (unknown ARM %s)" % ARM)
    sys.exit(1)
results = []


def sh(*args, timeout=40):
    p = subprocess.run([ENV, *args], capture_output=True, text=True, timeout=timeout)
    return p.stdout + p.stderr


def hc(*args):
    return sh("hyprctl", *args)


def ev(lua):
    out = hc("eval", lua)
    if "error" in out.lower():
        raise RuntimeError("eval: " + out.strip()[:300])
    return out


def lua_read(body):
    path = B + "/pe_read.txt"
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    ev("local R = ''; do " + body + " end; local f = io.open('" + path + "', 'w'); f:write(R); f:close()")
    return open(path).read()


def mons():
    return {m["name"]: m for m in json.loads(hc("-j", "monitors", "all"))}


def wsmap():
    return {w["id"]: w["monitor"] for w in json.loads(hc("-j", "workspaces"))}


def focused():
    return [m["name"] for m in json.loads(hc("-j", "monitors")) if m["focused"]]


def cursor():
    return lua_read("local p = hl.get_cursor_pos(); R = string.format('%d %d', math.floor(p.x + 0.5), math.floor(p.y + 0.5))")


def wait_for(fn, timeout=6.0, step=0.15):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            last = fn()
        except Exception:
            last = None
        if last:
            return last
        time.sleep(step)
    return last


def state():
    try:
        return json.load(open(B + "/rt/lares/panorama.json"))
    except Exception:
        return None


def counts():
    return json.loads(lua_read("R = panorama.json.encode(panorama.rules_sent)") or "{}")


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print("  %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  [" + str(detail)[:300] + "]"), flush=True)


class Socket2:
    def __init__(self):
        sig = sorted(os.listdir(B + "/rt/hypr"))[0]
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect("%s/rt/hypr/%s/.socket2.sock" % (B, sig))
        self.lines = []
        threading.Thread(target=self._run, daemon=True).start()

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


def spec(mode, pos, scale=1, enabled=True):
    s = {"enabled": enabled, "mode": mode, "position": pos, "scale": scale, "transform": 0, "mirror": False, "vrr": 0,
         "bitdepth": 8, "cm": "srgb", "sdrbrightness": 1, "sdrsaturation": 1}
    return s


L1, L2, L3 = "headless:LOCK-1", "headless:LOCK-2", "headless:LOCK-3"


def disp(i, internal, port):
    return {"label": port, "custom": False, "internal": internal, "port": port, "placeholder": False}


def data(lock3=False, lock2y=-200, split1=None, lock1_on=True, only12=False):
    d = {"v": 1, "displays": {L1: disp(1, True, "LOCK-1"), L2: disp(2, False, "LOCK-2")}, "setups": {},
         "split": {"3": L3, "4": L3}}
    if split1:
        d["split"]["1"] = split1
    s12 = {L1: spec("2880x1620@60", [0, 0], 1, lock1_on), L2: spec("3440x1440@60", [2880, lock2y])}
    d["setups"][L1 + " + " + L2] = {"name": "Desk", "custom": True, "used": 5, "outputs": s12}
    if lock3:
        d["displays"][L3] = disp(3, False, "LOCK-3")
        s123 = dict(s12)
        s123[L3] = spec("1920x1080@60", [480, -1080], "auto")
        d["setups"][L1 + " + " + L2 + " + " + L3] = {"name": "Three", "custom": True, "used": 6, "outputs": s123}
    return d


def lit(text):
    n = 0
    while "]" + "=" * n + "]" in text:
        n += 1
    return "[" + "=" * n + "[" + text + "]" + "=" * n + "]"


def main():
    sh("down")
    up = subprocess.run([ENV, "up"], capture_output=True, text=True, timeout=120, env=dict(os.environ, OUTPUTS="2"))
    if "LOCK_ENV UP" not in up.stdout:
        print(up.stdout + up.stderr)
        print("PANORAMA_ENGINE_ENV RESULT FAIL (the nested Hyprland did not come up)")
        return 1
    try:
        return run()
    finally:
        if not os.environ.get("PANORAMA_ENGINE_ENV_KEEP"):
            sh("down")


def run():
    s2 = Socket2()
    # the engine under test: a COPY, armed when asked
    eng = open(os.path.join(ROOT, "tools/panorama/engine.lua")).read()
    if ARM:
        a, b, _ = ARMS[ARM]
        if eng.count(a) != 1:
            print("ARM %s: its anchor is gone in engine.lua" % ARM)
            print("PANORAMA_ENGINE_ENV RESULT FAIL (ARM anchor gone)")
            return 1
        eng = eng.replace(a, b)
    open(B + "/engine.lua", "w").write(eng)
    os.makedirs(B + "/cfg_hypr/config", exist_ok=True)
    GEN = os.path.join(ROOT, "tools/panorama/generate.py")

    def generate(d):
        open(B + "/setups.json", "w").write(json.dumps(d))
        subprocess.run([sys.executable, GEN, B + "/setups.json", B + "/engine.lua", B + "/cfg_hypr/config/panorama.lua"], check=True)

    generate(data())
    LUA = B + "/cfg_hypr/config/panorama.lua"
    ev('hl.monitor({ output = "LOCK-1", reserved_area = { top = 40, right = 0, bottom = 0, left = 0 } })')
    time.sleep(0.4)

    # ---- load by eval (twice: a second dofile registers nothing) ----
    ev('panorama = { internal_override = "LOCK-1" }')
    ev('dofile("%s")' % LUA)
    ev('dofile("%s")' % LUA)
    st = wait_for(lambda: (state() or {}).get("serial") and state(), 5)
    sig = sorted(os.listdir(B + "/rt/hypr"))[0]
    check("load: the state file names this session and the engine version", st and st["session"] == sig and st["engine"] == ENGINE, st and (st["session"], sig))
    check("load: the data is applied (LOCK-2 moved to y -200)", wait_for(lambda: mons()["LOCK-2"]["y"] == -200, 5), mons()["LOCK-2"]["y"])
    check("load: the set and its setup", st and st["set"] == L1 + " + " + L2 and st["name"] == "Desk" and st["kind"] == "setup", st and (st["set"], st["name"]))
    check("load: the persistent split puts workspaces 3-4 on LOCK-2", wait_for(lambda: wsmap().get(3) == "LOCK-2" and wsmap().get(4) == "LOCK-2", 4), wsmap())

    # ---- a never-seen plug ----
    n0 = len(s2.lines)
    cur0, foc0 = cursor(), focused()
    hc("output", "create", "headless", "LOCK-3")
    ok3 = wait_for(lambda: mons().get("LOCK-3", {}).get("y", 0) < 0, 8)
    time.sleep(2.0)      # the rule lands after the handler, headless takes scale 2 from "auto", and the engine applies once more
    m3, m1 = mons().get("LOCK-3", {}), mons()["LOCK-1"]
    w3, h3 = m3.get("width", 0) / m3.get("scale", 1), m3.get("height", 0) / m3.get("scale", 1)
    w1 = m1["width"] / m1["scale"]
    check("never-seen LOCK-3: placed above LOCK-1 and centred", ok3 and m3["y"] + h3 == m1["y"] and m3["x"] + w3 / 2 == m1["x"] + w1 / 2,
          (m3.get("x"), m3.get("y"), w3, h3))
    st = state()
    check("never-seen LOCK-3: listed in unknown", L3 in (st or {}).get("unknown", []), st and st.get("unknown"))
    check("never-seen LOCK-3: takes workspaces 3-4", wait_for(lambda: wsmap().get(3) == "LOCK-3" and wsmap().get(4) == "LOCK-3", 6), wsmap())
    check("never-seen LOCK-3: the custom nudge on socket2", any(l.startswith("custom>>lares-panorama,") for l in s2.lines[n0:]), s2.lines[n0:][-5:])
    c = counts()
    check("never-seen LOCK-3: exactly one rule for it, none for the eDP stand-in", c.get("LOCK-3") == 1 and "LOCK-1" not in c, c)
    check("split move: no focus change, no pointer warp", focused() == foc0 and cursor() == cur0, (foc0, focused(), cur0, cursor()))
    check("HyprReserve's partial reserved_area is intact after a plug", mons()["LOCK-1"]["reserved"] == [0, 40, 0, 0], mons()["LOCK-1"]["reserved"])

    # ---- the shell's reload_data makes LOCK-3 known; an unplug and a replug is silent ----
    ev("panorama.reload_data(%s)" % lit(json.dumps(data(lock3=True))))
    time.sleep(0.8)
    before = counts()
    hc("output", "remove", "LOCK-3")
    time.sleep(1.0)
    n1 = len(s2.lines)
    hc("output", "create", "headless", "LOCK-3")
    wait_for(lambda: mons().get("LOCK-3", {}).get("y") == -1080, 8)
    time.sleep(0.8)
    after = counts()
    check("replug of a known display: LOCK-3 is back in place", mons().get("LOCK-3", {}).get("y") == -1080, mons().get("LOCK-3"))
    check("replug: no rule for the internal panel or LOCK-2", after.get("LOCK-1") is None and after.get("LOCK-2") == before.get("LOCK-2"), (before, after))

    # ---- the hop output is ignored ----
    ser = state()["serial"]
    hc("output", "create", "headless", "LARESLOCK-HOP")
    time.sleep(1.0)
    hc("output", "remove", "LARESLOCK-HOP")
    time.sleep(1.0)
    check("hop output: nothing written, nothing sent", state()["serial"] == ser and counts() == after, (ser, state()["serial"], counts()))

    # ---- the deferred move of the focused monitor's active workspace ----
    ev("panorama.reload_data(%s)" % lit(json.dumps(data(lock3=True, split1=L2))))
    time.sleep(1.0)
    w = wsmap()
    st = state()
    check("deferred: focused active workspace waits (stays, listed in deferred)", w.get(1) == "LOCK-1" and st["deferred"] == ["1"], (w.get(1), st["deferred"]))
    check("deferred: no focus change", focused() == ["LOCK-1"] or focused() == foc0, focused())
    cur_d = cursor()
    ev("hl.dispatch(hl.dsp.focus({ workspace = 2 }))")
    check("deferred: runs on workspace.active, after the user left it", wait_for(lambda: wsmap().get(1) == "LOCK-2", 5) and (state()["deferred"] == []), (wsmap().get(1), state()["deferred"]))
    ev("hl.dispatch(hl.dsp.focus({ workspace = 1 }))")
    time.sleep(0.3)
    # (a) workspace 1 is wanted on LOCK-2 again and is on show on LOCK-1 (deferred); the USER moves it there himself and leaves it: the
    # engine clears the entry and the persistent rule must follow (it named LOCK-1 before)
    ev("panorama.reload_data(%s)" % lit(json.dumps(data(lock3=True))))
    time.sleep(0.6)
    ev("hl.dispatch(hl.dsp.workspace.move({ workspace = 1, monitor = \"LOCK-1\" }))")
    ev("hl.dispatch(hl.dsp.focus({ monitor = \"LOCK-1\" }))")
    ev("hl.dispatch(hl.dsp.focus({ workspace = 1 }))")
    time.sleep(0.5)
    ev("panorama.reload_data(%s)" % lit(json.dumps(data(lock3=True, split1=L2))))
    time.sleep(0.8)
    rule_of = lambda: lua_read("local r = panorama.wsrules['1']; R = r and r.monitor or 'none'")
    check("deferred (again): workspace 1 on show on LOCK-1 waits", wsmap().get(1) == "LOCK-1" and state()["deferred"] == ["1"], (wsmap().get(1), state()["deferred"]))
    # the rule of a deferred workspace is the OLD one (a new rule would pull the workspace): make that the state, whatever the run left
    ev("local r = panorama.wsrules['1']; if r and r.rule then r.rule:set_enabled(false) end; panorama.wsrules['1'] = { monitor = 'LOCK-1' }")
    ev("hl.dispatch(hl.dsp.workspace.move({ workspace = 1, monitor = \"LOCK-2\" }))")
    ev("hl.dispatch(hl.dsp.focus({ workspace = 7 }))")      # a workspace of nobody's split: a sure `workspace.active`
    wait_for(lambda: state()["deferred"] == [], 5)
    check("deferred: satisfied by the user: its persistent rule names the new monitor", state()["deferred"] == [] and rule_of() == "LOCK-2", (rule_of(), state()["deferred"]))
    ev("panorama.reload_data(%s)" % lit(json.dumps(data(lock3=True))))
    time.sleep(0.8)
    ev("hl.dispatch(hl.dsp.focus({ workspace = 1 }))")
    time.sleep(0.3)
    ev("hl.dispatch(hl.dsp.focus({ monitor = \"LOCK-1\" }))")

    # ---- reload: a fresh Lua state, the config's own line, applied again, handlers once ----
    ev('hl.monitor({ output = "LOCK-2", position = "2880x500" })')
    time.sleep(0.6)
    generate(data())
    with open(B + "/hyprland.lua", "a") as f:
        f.write('\npanorama = { internal_override = "LOCK-1" }\npackage.path = "%s/cfg_hypr/?.lua;" .. package.path\npcall(require, "config/panorama")\n' % B)
    hc("reload")
    time.sleep(2.0)
    check("reload: the engine applied the data again", wait_for(lambda: mons()["LOCK-2"]["y"] == -200, 8), mons()["LOCK-2"]["y"])
    check("reload: a fresh Lua state (the serial restarted)", (state() or {}).get("serial", 99) < 8, (state() or {}).get("serial"))
    hc("output", "create", "headless", "LOCK-4")
    wait_for(lambda: "LOCK-4" in mons(), 5)
    time.sleep(1.5)
    c = counts()
    check("handlers once (rules for a new plug): one rule for LOCK-4", c.get("LOCK-4") == 1, c)

    # ---- trials with no shell ----
    cand = data()
    cand["setups"][L1 + " + " + L2]["outputs"][L2]["position"] = [2880, -300]
    # LOCK-3 and LOCK-4 are present: the set is bigger than the data knows; the trial is judged on LOCK-2
    ev('panorama.try(%s, "t1", 3000, 1500)' % lit(json.dumps(cand)))
    check("trial: the candidate is applied", wait_for(lambda: mons()["LOCK-2"]["y"] == -300, 5), mons()["LOCK-2"]["y"])
    ok = wait_for(lambda: (state() or {}).get("trial", {}).get("phase") == "reverted", 14)
    check("trial: no shell, guard reverts", ok and wait_for(lambda: mons()["LOCK-2"]["y"] == -200, 5), (state() or {}).get("trial"))
    ev('panorama.try(%s, "t2", 3000, 1500)' % lit(json.dumps(cand)))
    wait_for(lambda: (state() or {}).get("trial", {}).get("phase") == "trying" and mons()["LOCK-2"]["y"] == -300, 5)
    time.sleep(1.8)
    ev('panorama.keep("t2")')
    time.sleep(4.0)
    st = state()
    check("trial: keep cancels the guard (stays kept, LOCK-2 stays)", st["trial"]["phase"] == "kept" and mons()["LOCK-2"]["y"] == -300, (st["trial"], mons()["LOCK-2"]["y"]))
    ev('panorama.try(%s, "t3", 30000, 1500)' % lit(json.dumps(data())))
    time.sleep(0.8)
    hc("output", "remove", "LOCK-4")
    ok = wait_for(lambda: (state() or {}).get("trial", {}).get("phase") == "reverted", 6)
    check("trial: an output pulled mid-trial reverts at once", ok, (state() or {}).get("trial"))

    # ---- a mirror trial and its revert (the real compositor): the un-mirror rule and the workspaces' move land in different turns ----
    hc("output", "remove", "LOCK-3")
    time.sleep(1.2)
    ev("panorama.reload_data(%s)" % lit(json.dumps(data())))
    time.sleep(0.8)
    mcand = data()
    mcand["setups"][L1 + " + " + L2]["outputs"][L2]["mirror"] = True
    ev('panorama.try(%s, "m1", 30000, 1500)' % lit(json.dumps(mcand)))
    check("mirror trial: LOCK-2 mirrors the internal panel", wait_for(lambda: mons()["LOCK-2"]["mirrorOf"] != "none", 6), mons()["LOCK-2"]["mirrorOf"])
    time.sleep(1.8)
    check("mirror trial: it verifies (the trial is not failed)", (state() or {}).get("trial", {}).get("phase") == "trying", (state() or {}).get("trial"))
    out = ev('panorama.revert("m1")')
    check("mirror revert: no warning from the compositor (no workspace moved onto an output that is still a mirror)", "warning" not in out.lower(), out.strip()[:200])
    check("mirror revert: LOCK-2 mirrors no more", wait_for(lambda: mons()["LOCK-2"]["mirrorOf"] == "none", 6), mons()["LOCK-2"]["mirrorOf"])
    check("mirror revert: workspace 3 is back on LOCK-2 (the split looked again after the rule landed)", wait_for(lambda: wsmap().get(3) == "LOCK-2", 6), wsmap())

    # ---- the safety rule ----
    ev("panorama.reload_data(%s)" % lit(json.dumps(data(lock1_on=False))))
    check("safety setup: the internal is switched off by the data", wait_for(lambda: mons()["LOCK-1"]["disabled"], 5), mons()["LOCK-1"]["disabled"])
    hc("output", "remove", "LOCK-2")
    back = wait_for(lambda: not mons()["LOCK-1"]["disabled"], 6)
    lg = " | ".join((state() or {}).get("log", []))
    check("safety: internal re-enabled by the handler", back and "safety: LOCK-1 re-enabled" in lg, lg[-300:])
    run_cast(generate)
    return finish()


CID = "cast:wfd:02:AE:00:00:0A:01"
LAPID = L1


def cast_data(mirror=False):
    d = data()
    d["displays"].pop(L2)
    d["setups"] = {}
    d["displays"][CID] = {"label": "LG TV", "custom": False, "internal": False, "port": "LARES-CAST-1", "placeholder": False}
    d["setups"][L1 + " + " + CID] = {"name": "TV", "custom": False, "used": 9, "outputs": {
        L1: spec("2880x1620@60", [0, 0], 1), CID: dict(spec("1920x1080@60", [480, -1080], 1), mirror=mirror)}}
    d["setups"][L1] = {"name": "Laptop", "custom": False, "used": 8, "outputs": {L1: spec("2880x1620@60", [0, 0], 1)}}
    d["split"] = {}
    return d


def cast_names():
    return sorted(n for n in mons() if n.startswith("LARES-CAST-"))


def run_cast(generate):
    ev("panorama.reload_data(%s)" % lit(json.dumps(cast_data())))
    ev('hl.dispatch(hl.dsp.focus({ workspace = 1 }))')
    ev('hl.dispatch(hl.dsp.focus({ workspace = 2 }))')
    ev('hl.dispatch(hl.dsp.focus({ workspace = 1 }))')
    time.sleep(0.8)
    check("cast setup: the laptop alone, no cast output", cast_names() == [], cast_names())
    ws0 = {k: v for k, v in wsmap().items() if k in (1, 2)}
    trial0 = (state() or {}).get("trial")
    foc0, cur0 = focused(), cursor()
    ev("panorama.cast_open(%s)" % lit(json.dumps(CID)))
    ok = wait_for(lambda: "LARES-CAST-1" in mons(), 8)
    check("cast: cast_open creates LARES-CAST-1", ok, cast_names())
    st = wait_for(lambda: (state() or {}).get("cast", {}).get("outputs", {}).get("LARES-CAST-1") == CID and state(), 4)
    check("cast: the state file names the output and its identity", st, (state() or {}).get("cast"))
    time.sleep(2.2)
    m, m1 = mons().get("LARES-CAST-1", {}), mons()["LOCK-1"]
    w1 = m1["width"] / m1["scale"]
    check("cast: 1920x1080 at 60 Hz, scale 1", m.get("width") == 1920 and m.get("height") == 1080 and abs(m.get("refreshRate", 0) - 60) < 1 and m.get("scale") == 1,
          (m.get("width"), m.get("height"), m.get("refreshRate"), m.get("scale")))
    check("cast: above the laptop (bottom edge on its top edge), centred", m.get("y", 0) + 1080 == m1["y"] and m.get("x", 0) + 960 == m1["x"] + w1 / 2,
          (m.get("x"), m.get("y"), m1["x"], m1["y"], w1))
    ev("panorama.cast_open(%s)" % lit(json.dumps(CID)))
    time.sleep(1.2)
    check("cast: the same identity reuses its output", cast_names() == ["LARES-CAST-1"] and list(state()["cast"]["outputs"]) == ["LARES-CAST-1"], (cast_names(), state()["cast"]))
    check("cast: a plug is no trial and no keep prompt", (state() or {}).get("trial") == trial0, ((state() or {}).get("trial"), trial0))
    w = wsmap()
    check("cast: workspaces 1-2 stay on the laptop", all(w.get(k) == v for k, v in ws0.items()), (ws0, w))
    check("cast: workspaces 3 and 4 are the cast's", wait_for(lambda: wsmap().get(3) == "LARES-CAST-1" and wsmap().get(4) == "LARES-CAST-1", 5), wsmap())
    check("cast: no focus change, no pointer warp", focused() == foc0 and cursor() == cur0, (foc0, focused(), cur0, cursor()))
    # THE HAND-OVER (FACTS G1, G2): the new output shows its own workspace and the one it was born on is gone -- four workspaces
    w = json.loads(hc("-j", "workspaces"))
    act = {m["name"]: m["activeWorkspace"]["id"] for m in json.loads(hc("-j", "monitors"))}
    check("cast: four workspaces, the new display shows its own (the birth workspace is gone)",
          sorted(x["id"] for x in w if x["id"] > 0) == [1, 2, 3, 4] and act.get("LARES-CAST-1") == 3, (sorted(x["id"] for x in w), act))
    # A CAST OUTPUT IS NEVER OFF AND NEVER A MIRROR while it exists (FACT G5: it could not be removed again). A setup that says mirror
    # (the shell stores it and makes NO output for such a cast) leaves an output that still exists as it is, removable.
    cur1 = cursor()
    ev("panorama.reload_data(%s)" % lit(json.dumps(cast_data(mirror=True))))
    time.sleep(1.5)
    m = mons()["LARES-CAST-1"]
    check("cast: a setup that says mirror leaves the output on and no mirror", not m["disabled"] and m.get("mirrorOf") in ("none", "", None) and m["width"] == 1920, m)
    w = wsmap()
    check("cast: ... and moves nothing of the user's", all(w.get(k) == v for k, v in ws0.items()) and focused() == foc0 and cursor() == cur1, (wsmap(), focused(), cursor()))
    check("cast: still no keep prompt", (state() or {}).get("trial") == trial0, (state() or {}).get("trial"))
    ev("panorama.cast_close('LARES-CAST-1')")
    check("cast: ... and it is removed like any other", wait_for(lambda: cast_names() == [], 6), cast_names())
    # one that IS off (an older engine's, a hand's) is switched on and then removed: the removal is looked at again
    ev("panorama.reload_data(%s)" % lit(json.dumps(cast_data(mirror=False))))
    ev("panorama.cast_open(%s)" % lit(json.dumps(CID)))
    wait_for(lambda: "LARES-CAST-1" in mons(), 8)
    time.sleep(1.5)
    ev('hl.monitor({ output = "LARES-CAST-1", disabled = true })')
    wait_for(lambda: mons()["LARES-CAST-1"]["disabled"], 5)
    ev("panorama.cast_close('LARES-CAST-1')")
    check("cast: an output that was off is removed all the same", wait_for(lambda: cast_names() == [], 8), cast_names())
    ev("panorama.cast_open(%s)" % lit(json.dumps(CID)))
    ok = wait_for(lambda: "LARES-CAST-1" in mons() and not mons()["LARES-CAST-1"]["disabled"] and mons()["LARES-CAST-1"]["y"] == -1080, 8)
    time.sleep(1.0)
    check("cast: the next cast's output comes up on and in place (the name's rule was reset)", ok, mons().get("LARES-CAST-1"))
    # a foreign headless output is none of the cast's
    hc("output", "create", "headless", "LOCK-9")
    wait_for(lambda: "LOCK-9" in mons(), 5)
    time.sleep(1.5)
    st = state()
    check("cast: another headless output stays a plain unknown display", "headless:LOCK-9" in st["unknown"] and "LOCK-9" not in st["cast"]["outputs"], (st["unknown"], st["cast"]))
    hc("output", "remove", "LOCK-9")
    time.sleep(0.8)
    # a reload (a fresh Lua state) keeps the live cast's output: its names come back from the file
    generate(cast_data())
    hc("reload")
    time.sleep(1.5)
    check("cast: after a reload the table is back", wait_for(lambda: lua_read("R = tostring(panorama.cast.map['LARES-CAST-1'])") == CID, 8), lua_read("R = tostring(panorama.cast.map['LARES-CAST-1'])"))
    time.sleep(7.0)
    check("cast: a reload keeps a live cast's output (past the start's grace)", "LARES-CAST-1" in mons(), cast_names())
    # the shell says nothing is live: swept after the grace, not before
    ev("panorama.cast_keep('[]')")
    time.sleep(2.0)
    check("cast: not swept inside the grace", "LARES-CAST-1" in mons(), cast_names())
    gone = wait_for(lambda: cast_names() == [], 8)
    check("cast: keep([]) sweeps the output no live cast keeps", gone, cast_names())
    check("cast: the sweep left no table entry", (state() or {}).get("cast", {}).get("outputs") == {}, (state() or {}).get("cast"))
    # a stray one nobody made
    hc("output", "create", "headless", "LARES-CAST-7")
    wait_for(lambda: "LARES-CAST-7" in mons(), 5)
    ev("panorama.cast_keep('[]')")
    check("cast: keep([]) sweeps a stray LARES-CAST-7 too", wait_for(lambda: cast_names() == [], 9), cast_names())
    # close: gone, nothing left
    ev("panorama.cast_open(%s)" % lit(json.dumps(CID)))
    wait_for(lambda: "LARES-CAST-1" in mons(), 6)
    time.sleep(1.5)
    ev("panorama.cast_close('LARES-CAST-1')")
    check("cast: cast_close removes the output", wait_for(lambda: cast_names() == [], 5), cast_names())
    time.sleep(1.2)
    st = state()
    leftovers = [n for n in mons() if n.startswith("LARES-CAST-")]
    check("cast: nothing is left (monitors all, the table, the keep list, the workspaces)",
          leftovers == [] and st["cast"]["outputs"] == {} and st["cast"]["keep"] == [] and "LARES-CAST-1" not in wsmap().values(), (leftovers, st["cast"], wsmap()))
    check("cast: the laptop is where it was", mons()["LOCK-1"]["x"] == 0 and mons()["LOCK-1"]["y"] == 0 and not mons()["LOCK-1"]["disabled"], mons()["LOCK-1"])


def finish():
    failed = [n for n, ok in results if not ok]
    if ARM:
        needle = ARMS[ARM][2]
        if any(needle in n for n in failed):
            print("ARM %s: failed at its check (%s)" % (ARM, needle))
            print("PANORAMA_ENGINE_ENV RESULT FAIL (ARM %s, as it must)" % ARM)
            return 1
        print("ARM %s: its check (%s) stayed green; failed: %s" % (ARM, needle, failed))
        print("PANORAMA_ENGINE_ENV RESULT FAIL (ARM %s not caught)" % ARM)
        return 1
    if failed:
        print("PANORAMA_ENGINE_ENV RESULT FAIL (%s)" % "; ".join(failed))
        return 1
    print("PANORAMA_ENGINE_ENV RESULT PASS (%d checks)" % len(results))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        sh("down")
        print("PANORAMA_ENGINE_ENV RESULT FAIL (runner threw: %r)" % (e,))
        sys.exit(1)
