#!/usr/bin/env python3
"""The plan of tools/theme/hidden_repaint.py, case by case (pure: no compositor).

    tools/dev/hidden_repaint_cases.py          HIDDEN_REPAINT_CASES RESULT PASS|FAIL
    ARM=all tools/dev/hidden_repaint_cases.py  eight faults from tools/dev/hidden_repaint_arm.py, each in a copy of the tool:
                                               every one must fail a case here -> HIDDEN_REPAINT_CASES ARMS RESULT PASS|FAIL

A session is written as monitors / workspaces / windows the way `hyprctl -j` gives them, cut to what the plan reads.
The nested probes (hidden_repaint_env_probe.sh, curtain_repaint_env_probe.sh) prove the plan against the real compositor;
this holds its shape: what is shown, in which moment, what is left alone, the way back.
"""
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load(path):
    spec = importlib.util.spec_from_file_location("hidden_repaint_under_test", path)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def mon(name, ws, focused=False, special="", hz=120.0):
    return {"name": name, "focused": focused, "refreshRate": hz,
            "activeWorkspace": {"id": ws if isinstance(ws, int) else -1, "name": str(ws)}, "specialWorkspace": {"name": special}}


def ws(key, monitor, fullscreen=False):
    return {"id": key if isinstance(key, int) else -1, "name": str(key), "monitor": monitor, "hasfullscreen": fullscreen}


def win(addr, workspace, group=None, shown=True, mapped=True, cls="kitty"):
    return {"address": addr, "workspace": {"name": str(workspace)}, "grouped": group or [], "visible": shown, "hidden": False, "mapped": mapped,
            "class": cls}


def run(h):
    fails = []

    def check(name, got, want):
        if got != want:
            fails.append("%s\n      got  %r\n      want %r" % (name, got, want))

    A = [mon("A", 1, True)]
    # 1. nothing hidden: nothing to do, nothing to put back
    p = h.plan(A, [ws(1, "A")], [win("a", 1)], "a", {"x": 5, "y": 6})
    check("1 nothing hidden", (p["steps"], p["restore"]), ([], []))
    # 2. one hidden workspace: shown for one moment, then home, the focus and the pointer
    p = h.plan(A, [ws(1, "A"), ws(2, "A")], [win("a", 1), win("b", 2)], "a", {"x": 5, "y": 6})
    check("2 one hidden workspace", (p["steps"], p["restore"]),
          ([[("ws", "A", 2)]], [("ws", "A", 1), ("monitor", "A"), ("window", "a"), ("cursor", 5, 6)]))
    check("2 says what it showed", p["shown"], ["2"])
    # 3. a group of three on show: its two other tabs in turn, its own tab back with the way home
    g = ["a", "b", "c"]
    p = h.plan(A, [ws(1, "A")], [win("a", 1, g), win("b", 1, g, False), win("c", 1, g, False)], "a", None)
    check("3 a shown group's tabs", (p["steps"], p["restore"], p["tabs"]),
          ([[("tab", "a", 2)], [("tab", "a", 3)]], [("tab", "a", 1), ("monitor", "A"), ("window", "a")], 2))
    # 3b. the tab on show is the SECOND member: the others are 1 and 3, and 2 comes back
    p = h.plan(A, [ws(1, "A")], [win("a", 1, g, False), win("b", 1, g), win("c", 1, g, False)], "b", None)
    check("3b the shown tab is in the middle", (p["steps"], p["restore"][0]), ([[("tab", "b", 1)], [("tab", "b", 3)]], ("tab", "b", 2)))
    # 4. two groups on one hidden workspace flip TOGETHER; the tabs go back in the moment that leaves
    g2, g3 = ["d", "e"], ["f", "g", "h"]
    cl = [win("a", 1), win("d", 2, g2), win("e", 2, g2, False), win("f", 2, g3), win("g", 2, g3, False), win("h", 2, g3, False)]
    p = h.plan(A, [ws(1, "A"), ws(2, "A")], cl, "a", None)
    check("4 two groups flip together", p["steps"], [[("ws", "A", 2)], [("tab", "d", 2), ("tab", "f", 2)], [("tab", "f", 3)]])
    check("4 their tabs go back with the way home", p["restore"][:3], [("tab", "d", 1), ("tab", "f", 1), ("ws", "A", 1)])
    # 5. a hidden special workspace: toggled on, then off in the next moment; special ones before the others
    p = h.plan(A, [ws(1, "A"), ws(2, "A"), ws("special:default", "A")], [win("a", 1), win("b", 2), win("s", "special:default")], "a", None)
    check("5 a hidden special workspace", p["steps"], [[("special", "A", "default")], [("special", "A", "default"), ("ws", "A", 2)]])
    # 5b. a special workspace ON SHOW is not toggled; another one is shown and the first comes back
    p = h.plan([mon("A", 1, True, "special:default")], [ws(1, "A"), ws("special:default", "A"), ws("special:other", "A")],
               [win("a", 1), win("s", "special:default"), win("o", "special:other")], "s", None)
    check("5b a shown special workspace stays", (p["steps"], p["restore"][:2]),
          ([[("special", "A", "other")]], [("special", "A", "other"), ("special?", "A", "default")]))
    # 6. fullscreen: a monitor showing one is left alone, a hidden workspace holding one is left alone
    p = h.plan(A, [ws(1, "A", True), ws(2, "A")], [win("a", 1), win("b", 2)], "a", None)
    check("6 a fullscreen window on show", (p["steps"], p["skipped"]), ([], ["A: fullscreen"]))
    p = h.plan(A, [ws(1, "A"), ws(2, "A", True), ws(3, "A")], [win("a", 1), win("b", 2), win("c", 3)], "a", None)
    check("6b a hidden fullscreen workspace", (p["steps"], p["skipped"]), ([[("ws", "A", 3)]], ["2: holds a fullscreen window"]))
    # 7. two monitors work at the same time; within a moment the FOCUSED monitor's workspace comes last; the shorter one goes home early
    AB = [mon("A", 1, True), mon("B", 2)]
    wl = [ws(1, "A"), ws(2, "B"), ws(3, "A"), ws(4, "B"), ws(5, "A")]
    cl = [win("a", 1), win("b", 2), win("c", 3), win("d", 4), win("e", 5)]
    p = h.plan(AB, wl, cl, "a", None)
    check("7 two monitors", p["steps"], [[("ws", "B", 4), ("ws", "A", 3)], [("ws", "B", 2), ("ws", "A", 5)]])
    check("7 the way back", p["restore"], [("ws", "A", 1), ("monitor", "A"), ("window", "a")])
    # 8. a named workspace is asked for by name; an empty workspace and an unmapped window are nobody's
    p = h.plan(A, [ws(1, "A"), ws("mail", "A"), ws(7, "A"), ws(8, "A")], [win("a", 1), win("m", "mail"), win("u", 8, mapped=False)], "a", None)
    check("8 a named workspace, an empty one, an unmapped window", p["steps"], [[("ws", "A", "name:mail")]])
    # 9. the chunk Hyprland gets: one function per moment, the result path quoted, a Lua that parses
    p = h.plan(A, [ws(1, "A"), ws(2, "A")], [win("a", 1), win("b", 2)], "a", {"x": 5, "y": 6})
    p["tabs_back"] = h.tabs_back_of([win("a", 1, ["a", "z"]), win("z", 1, ["a", "z"], False)])
    chunk = h.lua_chunk(p, h.step_ms(p, 120.0), '/run/user/1/lares/re"paint.result')
    check("9 one function per moment", chunk.count("    { function() "), 1)
    check("9 the step, the way back and the stopped run's tabs are in it",
          ('ws("A", 2)' in chunk, 'ws("A", 1)' in chunk, 'cur(5, 6)' in chunk, 'tab("a", 1)' in chunk, 're\\"paint' in chunk), (True,) * 5)
    lua = shutil.which("luajit") or shutil.which("lua") or shutil.which("lua5.4")
    if lua:
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write("local hl = setmetatable({}, { __index = function() return function() end end })\nif false then\n" + chunk + "\nend\n")
        r = subprocess.run([lua, f.name], capture_output=True, text=True)
        os.unlink(f.name)
        check("9 the chunk parses", (r.returncode, r.stderr.strip()[:200]), (0, ""))
    # 11. A STEP STAYS THE MOST FRAMES OF THE WINDOWS IT NEWLY SHOWS: a window's class in the table, else the default
    wl = [ws(1, "A"), ws(2, "A"), ws(3, "A")]
    cl = [win("a", 1), win("b", 2), win("z", 2, cls="zen"), win("c", 3)]
    p = h.plan(A, wl, cl, "a", None, 2, {"zen": 24})
    check("11 a step stays the most frames of what it shows", (p["frames"], p["labels"]), ([24, 2], ["workspace 2: kitty, zen", "workspace 3: kitty"]))
    # 11b. the class is matched exactly, in any case: never a part of it
    cl = [win("a", 1), win("v", 2, cls="com.microsoft.VSCode"), win("c", 3, cls="codeium")]
    p = h.plan(A, wl, cl, "a", None, 2, {"COM.microsoft.vscode": 16, "code": 9})
    check("11b a class exactly, in any case, never a part", p["frames"], [16, 2])
    # 11c. a tab's moment counts the tab it shows; a workspace's counts what is on view there, never its hidden tabs
    g, g2 = ["a", "v", "c"], ["d", "e"]
    cl = [win("a", 1, g), win("v", 1, g, False, cls="com.microsoft.VSCode"), win("c", 1, g, False), win("d", 2, g2), win("e", 2, g2, False, cls="zen")]
    p = h.plan(A, [ws(1, "A"), ws(2, "A")], cl, "a", None, 2, {"com.microsoft.vscode": 16, "zen": 24})
    check("11c a tab counts the tab it shows", (p["frames"], p["labels"]),
          ([16, 2, 2, 24], ["tab 2: com.microsoft.VSCode", "tab 3: kitty", "workspace 2: kitty", "tab 2: zen"]))
    # 11d. two monitors in one moment: the most of both; a monitor going home in another's moment adds nothing (its home was on view)
    cl = [win("a", 1, cls="zen"), win("b", 2), win("c", 3), win("d", 4), win("e", 6)]
    p = h.plan(AB, [ws(1, "A"), ws(2, "B"), ws(3, "A"), ws(4, "B"), ws(6, "B")], cl, "a", None, 2, {"zen": 24})
    check("11d two monitors, and a monitor going home", (p["steps"], p["frames"]),
          ([[("ws", "B", 4), ("ws", "A", 3)], [("ws", "B", 6), ("ws", "A", 1)]], [2, 2]))
    cl = [win("a", 1), win("b", 2), win("c", 3), win("d", 4, cls="zen")]
    p = h.plan(AB, [ws(1, "A"), ws(2, "B"), ws(3, "A"), ws(4, "B")], cl, "a", None, 2, {"zen": 24})
    check("11d the most of both monitors", p["frames"], [24])
    # 11e. no table: every step the default
    p = h.plan(A, wl, [win("a", 1), win("b", 2, cls="zen"), win("c", 3)], "a", None)
    check("11e no table: the default everywhere", p["frames"], [h.DEFAULT_FRAMES, h.DEFAULT_FRAMES])
    # 12. a step's time is its frames of the slowest monitor; the chunk gives each step its own; a debug run gives every step the
    # debug time and names it with the frames a real run gives it
    p = h.plan(A, wl, [win("a", 1), win("v", 2, cls="Code"), win("c", 3)], "a", None, 2, {"code": 16})
    p["tabs_back"] = []
    check("12 a step's time", (h.step_ms(p, 120.0), h.step_ms(p, 60.0)), ([133, 17], [267, 33]))
    chunk = h.lua_chunk(p, h.step_ms(p, 120.0), "/x")
    check("12 each step its own time", (chunk.count("end, 133, "), chunk.count("end, 17, "), "local DEBUG = false" in chunk), (1, 1, True))
    chunk = h.lua_chunk(p, h.step_ms(p, 120.0), "/x", 800)
    check("12 a debug run", (chunk.count("end, 800, "), "local DEBUG = true" in chunk, '"workspace 2: Code  16 frames"' in chunk), (2, True, True))
    # 10. a step's time: frames of the SLOWEST monitor (the tool's own arithmetic, here by the same formula)
    check("10 the default frames", h.DEFAULT_FRAMES, 3)
    return fails


def main():
    tool = os.path.join(ROOT, "tools/theme/hidden_repaint.py")
    if os.environ.get("ARM") == "all":
        rc = 0
        for arm in ("notabs", "nospecial", "nohome", "notabsback", "noclass", "nomax", "substring", "hiddentabs"):
            d = tempfile.mkdtemp()
            copy = os.path.join(d, "hidden_repaint.py")
            shutil.copy(tool, copy)
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tools/dev/hidden_repaint_arm.py"), arm, copy], capture_output=True, text=True)
            if r.returncode != 0:
                print("ARM %s: NOT PROVEN (%s)" % (arm, r.stdout.strip())); rc = 1
            else:
                try:
                    fails = run(load(copy))
                except Exception as e:                       # a case that cannot even be read off the armed plan has failed
                    fails = ["a case threw: %r" % e]
                print("ARM %s: %s" % (arm, ("FAILED AS IT MUST (%s)" % fails[0].split("\n")[0]) if fails else "STAYED GREEN"))
                rc = rc or (0 if fails else 1)
            shutil.rmtree(d)
        print("HIDDEN_REPAINT_CASES ARMS RESULT " + ("PASS" if rc == 0 else "FAIL"))
        return rc
    fails = run(load(tool))
    for f in fails:
        print("  FAIL " + f)
    print("HIDDEN_REPAINT_CASES RESULT %s (%d failed)" % ("FAIL" if fails else "PASS", len(fails)))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
