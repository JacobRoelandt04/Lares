#!/usr/bin/env python3
"""The offline cases of session restore: no compositor, no window, nothing of the user's read or written.

    python3 tools/dev/session_cases.py            SESSION_CASES RESULT PASS | FAIL
    ARM=<name> python3 tools/dev/session_cases.py  one fault in a COPY of tools/session; the group named must fail
    ARM=all ...                                    every arm in turn: SESSION_CASES ARMS RESULT PASS | FAIL

Groups:
  classify   tools/dev/session_classify_cases.tsv: run or type, the command handed to the shell
  proc       a fake /proc tree: a shell at its prompt, a job, a pipeline, a root job, a kitty with no shell, the mark
  kitty      kitty's argv split into options and program
  policy     policy.decide: what a session's start does
  begin      `lares-session begin` against a fake Hyprland directory and state: the rotation, the restart, safe mode
  plan       plan.build on a fixture: token / multi, what is skipped, what is already open
  match      a multi-window app's windows paired by title
  vscode     one process, two windows: a folder each, the missing one opened with code -n
  end        how the watcher reads a machine going down (systemd's state, logind, the shutdown's job)
  preset     presets: save / --over / names and slugs / rename / delete / undelete / list and the face; the snapshots'
             rotation never touches one
  reuse      a preset load: which open window stands for which saved one, what --replace closes and --add never does,
             a Claude job back as a fresh `claude`

ARMs (group that must fail):
  unknownruns (classify)  a program on no list runs      aliasblind (classify)  the typed line is not looked at
  crashruns (classify)    an unclean end still runs      crashauto (policy)     an unclean end restores by itself
  suspectauto (policy)    a restore cut short is trusted restartrestores (begin) a shell restart decides again
  safemode (begin)        safe mode is not seen          nomark (proc)          the hook's mark is not read
  chainwhole (classify)   a chain is not taken apart     chaintail (classify)   what follows the running command is run too
  selfjob (proc)          the command taking the picture is captured as a terminal's job
  heldrerun (plan)        a held program that is over is run again   nostage (plan)   windows open on their own workspace
  nofolders (vscode)      the folders of a multi-window app are not planned   nojournal (begin)       the previous boot's journal is not asked   nostopping (end)        a reboot nobody delayed (no logind delay inhibitor) reads as no shutdown
  typedruns (classify)    claude "type" runs it                               letters (plan)        a launch that is a string is taken as a list
  noreuse (reuse)         no open window stands for a saved one              closeadd (reuse)       --add closes too
  presetcrash (begin)     a crash during a preset load is "the last restore ended in a crash"
  facenolock (preset)     the face drops a group's lock (the presets' card cannot show it)
  resumeclaude (reuse)    a Claude job comes back resumed                    rotatepresets (preset) the snapshots' rotation takes the presets
"""
import json
import os
import shlex
import shutil
import subprocess
import re
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ARMS = {
    "unknownruns": ("classify", "sessionlib/classify.py",
                    '        return False, rules.get("type", {}).get(name) or "not on the run list"',
                    '        return True, ""'),
    "aliasblind": ("classify", "sessionlib/classify.py",
                   '            ok, why = _typed_ok(typed, argv)', '            ok, why = True, ""'),
    "crashruns": ("classify", "sessionlib/classify.py",
                  '    if verdict is None and not clean:', '    if False:'),
    "crashauto": ("policy", "sessionlib/policy.py",
                  '        return {"decision": "ask-critical", "cause": cause, "clean": False}',
                  '        return {"decision": "auto", "cause": cause, "clean": True}'),
    "suspectauto": ("policy", "sessionlib/policy.py",
                    '    if restoring and not clean_end:', '    if False:'),
    "restartrestores": ("begin", "lares-session",
                        '        if cur and cur.get("sig") == ctx.hy.sig:', '        if False:'),
    "safemode": ("begin", "sessionlib/hypr.py",
                 '                return b"--safe-mode" in f.read().split(b"\\0")', '                return False'),
    "chainwhole": ("classify", "sessionlib/classify.py",
                   '    if not segs or len(segs) < 2:\n        return None', '    if True:\n        return None'),
    "chaintail": ("classify", "sessionlib/classify.py",
                  '    if rest:\n        out["why"] = "more commands follow it on the line"', '    if False:\n        pass'),
    "heldrerun": ("plan", "sessionlib/plan.py",
                  '    if term.get("shell") and "--hold" in opts:', '    if False:'),
    "nostage": ("plan", "sessionlib/plan.py",
                '        rule = {"workspace": ws_rule(first["workspace"]) if slow else stage_name(first["workspace"]) + " silent",',
                '        rule = {"workspace": ws_rule(first["workspace"]),'),
    "selfjob": ("proc", "sessionlib/procs.py",
                '            if members and not ids.intersection(ignore):', '            if members:'),
    "nomark": ("proc", "sessionlib/procs.py",
               '    if not runtime_dir or not is_pts(tty_nr):', '    if True:'),
    "nofolders": ("vscode", "sessionlib/plan.py",
                  '        if folders and app_rule.get("folders"):', '        if False:'),
    "nojournal": ("begin", "lares-session",
                  '        if prev and not prev.get("ended"):\n            found', '        if False:\n            found'),
    "noreuse": ("reuse", "sessionlib/plan.py",
                '    return out\n\n\ndef closable(', '    return {}\n\n\ndef closable('),
    "closeadd": ("reuse", "sessionlib/plan.py",
                 '    closing = closable(live_snap, reuse, rules) if replace else []',
                 '    closing = closable(live_snap, reuse, rules)'),
    "resumeclaude": ("reuse", "sessionlib/classify.py",
                     '    fresh = bool(claude == "fresh" and', '    fresh = bool(False and'),
    "rotatepresets": ("preset", "sessionlib/state.py",
                      '    for old, path in list_snapshots(paths)[keep:]:',
                      '    for _p in __import__("glob").glob(os.path.join(paths.presets, "*.json")):\n        os.unlink(_p)\n'
                      '    for old, path in list_snapshots(paths)[keep:]:'),
    "typedruns": ("classify", "sessionlib/classify.py",
                  '    if verdict is None and is_claude and claude == "type":', '    if False:'),
    "letters": ("plan", "sessionlib/state.py",
                '                v = {n: x for n, x in v.items() if n != "launch"}', '                pass'),
    "presetcrash": ("begin", "lares-session",
                    '            if restoring and restoring.get("preset"):', '            if False:'),
    "facenolock": ("preset", "sessionlib/presets.py",
                   '                      "locked": bool(g.get("locked"))} if g else None,', '                      } if g else None,'),
    "nostopping": ("end", "lares-session",
                   '    stopping = run(["systemctl", "is-system-running"]).strip() == "stopping"', '    stopping = False'),
}


def arm_all():
    rc = 0
    for name, (group, _, _, _) in ARMS.items():
        p = subprocess.run([sys.executable, os.path.abspath(__file__)], env=dict(os.environ, ARM=name),
                           capture_output=True, text=True)
        out = p.stdout + p.stderr
        if "anchor is gone" in out:
            print("ARM %s: NOT PROVEN (its anchor is gone)" % name)
            rc = 1
        elif "SC FAIL %s " % group in out and "SESSION_CASES RESULT FAIL" in out:
            line = next(l for l in out.splitlines() if l.startswith("SC FAIL %s " % group))
            print("ARM %s: FAILED AS IT MUST (%s)" % (name, line[:110]))
        elif "SESSION_CASES RESULT FAIL" in out:
            print("ARM %s: FAILED, BUT NOT IN ITS OWN GROUP (%s)" % (name, group))
            rc = 1
        else:
            print("ARM %s: STAYED GREEN" % name)
            rc = 1
    print("SESSION_CASES ARMS RESULT %s" % ("PASS" if rc == 0 else "FAIL"))
    sys.exit(rc)


if os.environ.get("ARM") == "all":
    arm_all()

WORK = tempfile.mkdtemp(prefix="session_cases.")
TOOLS = os.path.join(WORK, "tools")
shutil.copytree(os.path.join(ROOT, "tools", "session"), os.path.join(TOOLS, "session"))
shutil.copytree(os.path.join(ROOT, "tools", "lib"), os.path.join(TOOLS, "lib"))
if os.environ.get("ARM"):
    _, rel, a, b = ARMS[os.environ["ARM"]]
    path = os.path.join(TOOLS, "session", rel)
    src = open(path).read()
    if src.count(a) != 1:
        print("ARM %s: anchor is gone in %s" % (os.environ["ARM"], rel))
        print("SESSION_CASES RESULT FAIL (arm)")
        shutil.rmtree(WORK, ignore_errors=True)
        sys.exit(1)
    open(path, "w").write(src.replace(a, b))
sys.path.insert(0, os.path.join(TOOLS, "session"))
from sessionlib import capture, classify, plan, policy, procs, restore, state  # noqa: E402

QS = os.path.join(TOOLS, "session", "lares-session")
fails = []
counts = {}


def check(group, name, ok, seen=""):
    counts[group] = counts.get(group, 0) + 1
    if not ok:
        fails.append("%s %s" % (group, name))
        print("SC FAIL %s %s: %s" % (group, name, seen))


# ---- classify ----------------------------------------------------------------------------------------------------------
def g_classify():
    rules = state.load_rules()
    cfg = dict(state.DEFAULTS)
    n = 0
    for ln, line in enumerate(open(os.path.join(ROOT, "tools", "dev", "session_classify_cases.tsv"), encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        f = line.split("\t")
        if len(f) != 6:
            check("classify", "line %d" % ln, False, "expected 6 columns, got %d" % len(f))
            continue
        expect, flags, kind, alias, typed, argvs = f
        want_cmd = None
        if "=" in expect:
            expect, want_cmd = expect.split("=", 1)
        flags = [] if flags == "-" else flags.split(",")
        tops = [{"argv": shlex.split(a)} for a in argvs.split(" ||| ")]
        job = {"tops": tops, "root": "root" in flags, "claude": None,
               "typed": None if typed == "-" else {"kind": "" if kind == "-" else kind, "alias": "" if alias == "-" else alias,
                                                  "text": typed, "words": {}}}
        for fl in flags:
            if fl.startswith("claude="):
                job["claude"] = fl.split("=", 1)[1]
            elif fl.startswith("w=") and job["typed"] is not None:
                w, k, a = fl[2:].split(":", 2)
                job["typed"]["words"][w] = {"kind": k, "alias": a}
        v = classify.classify(job, rules, cfg, "unclean" not in flags,
                              claude="fresh" if "fresh" in flags else "type" if "typed" in flags else "resume")
        ok = v["mode"] == expect and (want_cmd is None or v["command"] == want_cmd)
        check("classify", "line %d (%s)" % (ln, typed if typed != "-" else argvs), ok,
              "%s %r (%s), wanted %s%s" % (v["mode"], v["command"], v["reason"], expect, " " + want_cmd if want_cmd else ""))
        n += 1
    check("classify", "the table has cases", n >= 70, n)
    segs = classify.split_chain("a; b && c || d\ne 'x;y' \"q;z\"; ")
    check("classify", "a line is cut at its top-level separators only",
          [(s["text"], s["sep"]) for s in segs] == [("a", ";"), ("b", "&&"), ("c", "||"), ("d", ";"), ("e 'x;y' \"q;z\"", "")], segs)
    check("classify", "open quotes are no chain", classify.split_chain("cd 'x; lg") is None, "")
    check("classify", "a pipe, a redirection, an expansion make a part compound",
          [s["complex"] for s in classify.split_chain("a | b; c > d; e $(f); g \"$h\"; i '$j'; k")] == [True, True, True, True, False, False], "")
    # the user's lists win
    cfg2 = dict(cfg, run=["frobnicate"], type=["lazygit"])
    j = {"tops": [{"argv": ["frobnicate"]}], "typed": None, "root": False, "claude": None}
    check("classify", "config run", classify.classify(j, rules, cfg2)["mode"] == "run")
    j = {"tops": [{"argv": ["lazygit"]}], "typed": None, "root": False, "claude": None}
    check("classify", "config type", classify.classify(j, rules, cfg2)["mode"] == "type")


# ---- a fake /proc -------------------------------------------------------------------------------------------------------
class FakeProc:
    def __init__(self, root):
        self.root = root
        os.makedirs(os.path.join(root, "sys", "kernel", "random"), exist_ok=True)
        open(os.path.join(root, "sys", "kernel", "random", "boot_id"), "w").write("boot-1\n")

    def add(self, pid, ppid, argv, pgrp=None, tpgid=-1, tty=0, cwd="/", comm=None, uid=1000):
        d = os.path.join(self.root, str(pid))
        os.makedirs(os.path.join(d, "task", str(pid)), exist_ok=True)
        comm = comm or os.path.basename(argv[0])[:15]
        open(os.path.join(d, "stat"), "w").write("%d (%s) S %d %d %d %d %d 0 0\n" % (pid, comm, ppid, pgrp or pid, pgrp or pid, tty, tpgid))
        open(os.path.join(d, "cmdline"), "wb").write(b"\0".join(a.encode() for a in argv) + b"\0")
        open(os.path.join(d, "status"), "w").write("Name:\t%s\nUid:\t%d\t%d\t%d\t%d\n" % (comm, uid, uid, uid, uid))
        open(os.path.join(d, "environ"), "wb").write(b"A=1\0")
        if os.path.lexists(os.path.join(d, "cwd")):
            os.unlink(os.path.join(d, "cwd"))
        os.symlink(cwd, os.path.join(d, "cwd"))
        open(os.path.join(d, "task", str(pid), "children"), "w").write("")
        pd = os.path.join(self.root, str(ppid), "task", str(ppid), "children")
        if os.path.exists(pd):
            open(pd, "a").write("%d " % pid)


PTS = lambda n: (136 << 8) | n  # noqa: E731


def g_proc():
    root = os.path.join(WORK, "proc")
    rt = os.path.join(WORK, "rt")
    home = os.path.join(WORK, "home")
    os.makedirs(os.path.join(rt, "lares-session", "tty"))
    os.makedirs(os.path.join(home, ".claude", "sessions"))
    fp = FakeProc(root)
    # kitty 100: helper without a tty, a shell at its prompt
    fp.add(100, 1, ["kitty", "--hold", "fastfetch"])
    fp.add(101, 100, ["/usr/bin/kitten", "__atexit__"])
    fp.add(102, 100, ["/bin/bash", "--posix"], pgrp=102, tpgid=102, tty=PTS(3), cwd="/home/u/proj")
    # kitty 200: a shell with one job (lazygit, typed as the alias lg), and the job's own child
    fp.add(200, 1, ["kitty"])
    fp.add(202, 200, ["/bin/bash", "--posix"], pgrp=202, tpgid=210, tty=PTS(4), cwd="/home/u/repo")
    fp.add(210, 202, ["lazygit"], pgrp=210, tpgid=210, tty=PTS(4), cwd="/home/u/repo")
    fp.add(211, 210, ["git", "status"], pgrp=210, tpgid=210, tty=PTS(4), cwd="/home/u/repo")
    open(os.path.join(rt, "lares-session", "tty", "pts-4"), "w").write("alias\tlg\talias\tlazygit\nlazygit\nlg\n")
    # kitty 300: a pipeline
    fp.add(300, 1, ["kitty"])
    fp.add(302, 300, ["bash"], pgrp=302, tpgid=310, tty=PTS(5), cwd="/tmp")
    fp.add(310, 302, ["journalctl", "-f"], pgrp=310, tpgid=310, tty=PTS(5))
    fp.add(311, 302, ["grep", "x"], pgrp=310, tpgid=310, tty=PTS(5))
    open(os.path.join(rt, "lares-session", "tty", "pts-5"), "w").write("file\n\njournalctl -f | grep x\n")
    # kitty 400: a root job
    fp.add(400, 1, ["kitty"])
    fp.add(402, 400, ["bash"], pgrp=402, tpgid=410, tty=PTS(6), cwd="/etc")
    fp.add(410, 402, ["sudo", "nvim", "fstab"], pgrp=410, tpgid=410, tty=PTS(6), uid=0)
    # kitty 500: no shell (kitty --title yazi sh -c yazi: sh exec'd yazi)
    fp.add(500, 1, ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "sh", "-c", "yazi"])
    fp.add(502, 500, ["yazi"], pgrp=502, tpgid=502, tty=PTS(7), cwd="/home/u/.config")
    # kitty 600: `sh -c` that did not exec: a wrapper, not a prompt
    fp.add(600, 1, ["kitty", "sh", "-c", "a; b"])
    fp.add(602, 600, ["sh", "-c", "a; b"], pgrp=602, tpgid=602, tty=PTS(8), cwd="/")
    fp.add(603, 602, ["a"], pgrp=602, tpgid=602, tty=PTS(8))
    # kitty 700: claude with a session file; an empty mark (the prompt hook ran)
    fp.add(700, 1, ["kitty", "--hold", "fastfetch"])
    fp.add(702, 700, ["/bin/bash", "--posix"], pgrp=702, tpgid=710, tty=PTS(9), cwd="/home/u/repo")
    fp.add(710, 702, ["claude"], pgrp=710, tpgid=710, tty=PTS(9), cwd="/home/u/repo")
    open(os.path.join(home, ".claude", "sessions", "710.json"), "w").write(json.dumps({"sessionId": "e14529b2-aaaa", "pid": 710}))
    open(os.path.join(rt, "lares-session", "tty", "pts-9"), "w").write("")

    p = procs.Proc(root)
    w = procs.terminal_windows(p, 100, rt, home)
    check("proc", "prompt", len(w) == 1 and w[0]["shell"] and w[0]["job"] is None and w[0]["root"]["cwd"] == "/home/u/proj", w)
    w = procs.terminal_windows(p, 200, rt, home)
    j = w[0]["job"] or {}
    check("proc", "job", [t["argv"] for t in j.get("tops", [])] == [["lazygit"]] and len(j.get("members", [])) == 2, j)
    check("proc", "mark", j.get("typed") == {"kind": "alias", "alias": "lazygit", "text": "lg",
                                             "words": {"lg": {"kind": "alias", "alias": "lazygit"}}}, j.get("typed"))
    # the command that takes the picture, typed in a terminal, is no job of the session
    w = procs.terminal_windows(p, 200, rt, home, procs.ancestry(p, 211))
    check("proc", "the asking command is not a job", w[0]["shell"] and w[0]["job"] is None, w[0]["job"])
    check("proc", "ancestry", procs.ancestry(p, 211) == {211, 210, 202, 200}, procs.ancestry(p, 211))
    w = procs.terminal_windows(p, 300, rt, home)
    j = w[0]["job"] or {}
    check("proc", "pipeline", [t["argv"][0] for t in j.get("tops", [])] == ["journalctl", "grep"]
          and (j.get("typed") or {}).get("text") == "journalctl -f | grep x"
          and (j.get("typed") or {}).get("words") == {}, j)     # a mark from a hook older than the triples
    w = procs.terminal_windows(p, 400, rt, home)
    check("proc", "root job", (w[0]["job"] or {}).get("root") is True, w[0]["job"])
    w = procs.terminal_windows(p, 500, rt, home)
    check("proc", "no shell", w[0]["shell"] is False and w[0]["root"]["argv"] == ["yazi"] and w[0]["job"] is None, w[0])
    w = procs.terminal_windows(p, 600, rt, home)
    check("proc", "sh -c is no prompt", w[0]["shell"] is False, w[0])
    w = procs.terminal_windows(p, 700, rt, home)
    j = w[0]["job"] or {}
    check("proc", "claude session", j.get("claude") == "e14529b2-aaaa" and j.get("typed") is None, j)
    return fp, root, rt, home


def g_kitty():
    for argv, opts, prog in [
        (["kitty"], [], []),
        (["kitty", "--hold", "fastfetch"], ["--hold"], ["fastfetch"]),
        (["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "sh", "-c", "yazi"],
         ["-o", "background_opacity=0.75", "--title", "yazi"], ["sh", "-c", "yazi"]),
        (["kitty", "--directory", "/x", "--hold", "fastfetch"], ["--hold"], ["fastfetch"]),
        (["kitty", "-d", "/x", "--title=a b", "-e", "btop"], ["--title=a b", "-e"], ["btop"]),
        (["kitty", "--directory=/x", "--class", "c", "--", "-odd"], ["--class", "c"], ["-odd"]),
    ]:
        check("kitty", " ".join(argv), capture.split_kitty(argv) == (opts, prog), capture.split_kitty(argv))


# ---- policy ------------------------------------------------------------------------------------------------------------
def g_policy():
    cfg = dict(state.DEFAULTS)
    t = 1_800_000_000.0
    snap = {"time": t - 60, "windows": 5}
    now = {"bootId": "b1", "time": t, "safeMode": False, "crashReport": None}
    cases = [
        ("no previous session", None, now, snap, cfg, "none", True),
        ("logout, same boot", {"ended": "logout", "bootId": "b1", "endedAt": t - 60}, now, snap, cfg, "ask", True),
        ("afterLogout auto", {"ended": "logout", "bootId": "b1"}, now, snap, dict(cfg, afterLogout="auto"), "auto", True),
        ("afterLogout ask-critical", {"ended": "logout", "bootId": "b1"}, now, snap, dict(cfg, afterLogout="ask-critical"),
         "ask-critical", True),
        ("afterReboot ask-critical", {"ended": "reboot", "bootId": "b0"}, now, snap, dict(cfg, afterReboot="ask-critical"),
         "ask-critical", True),
        ("afterReboot auto", {"ended": "poweroff", "bootId": "b0"}, now, snap, dict(cfg, afterReboot="auto"), "auto", True),
        ("logout, another boot", {"ended": "logout", "bootId": "b0"}, now, snap, cfg, "ask", True),
        ("reboot", {"ended": "reboot", "bootId": "b0"}, now, snap, cfg, "ask", True),
        ("poweroff", {"ended": "poweroff", "bootId": "b0"}, now, snap, cfg, "ask", True),
        ("system shutdown", {"ended": "system", "bootId": "b0"}, now, snap, cfg, "ask", True),
        ("crash", {"ended": None, "bootId": "b1"}, now, snap, cfg, "ask-critical", False),
        ("crash, another boot", {"ended": None, "bootId": "b0"}, now, snap, cfg, "ask-critical", False),
        ("crash with a report", {"ended": None, "bootId": "b1"}, dict(now, crashReport=t - 30), snap, cfg, "ask-critical", False),
        ("a restore cut short", {"ended": None, "bootId": "b1", "restoring": {"snapshot": "x", "since": t - 90, "done": None}},
         now, snap, cfg, "ask-critical", False),
        ("a restore that finished, then a crash at once", {"ended": None, "bootId": "b1",
                                                           "restoring": {"snapshot": "x", "since": t - 90, "done": t - 80}},
         now, snap, cfg, "ask-critical", False),
        ("a restore, then a clean logout", {"ended": "logout", "bootId": "b1", "restoring": {"snapshot": "x", "done": t - 80}},
         now, snap, cfg, "ask", True),
        ("safe mode", {"ended": "logout", "bootId": "b1"}, dict(now, safeMode=True), snap, cfg, "none", True),
        ("nothing saved", {"ended": "logout", "bootId": "b1"}, now, None, cfg, "none", True),
        ("no windows", {"ended": "logout", "bootId": "b1"}, now, {"time": t, "windows": 0}, cfg, "none", True),
        ("too old", {"ended": "logout", "bootId": "b1"}, now, {"time": t - 200 * 3600, "windows": 5}, cfg, "none", True),
        ("afterLogout off", {"ended": "logout", "bootId": "b1"}, now, snap, dict(cfg, afterLogout="off"), "none", True),
        ("afterLogout ask", {"ended": "logout", "bootId": "b1"}, now, snap, dict(cfg, afterLogout="ask"), "ask", True),
        ("afterReboot off", {"ended": "reboot", "bootId": "b0"}, now, snap, dict(cfg, afterReboot="off"), "none", True),
        ("afterCrash off", {"ended": None, "bootId": "b1"}, now, snap, dict(cfg, afterCrash="off"), "none", True),
        ("afterCrash is never auto", {"ended": None, "bootId": "b1"}, now, snap, dict(cfg, afterCrash="auto"), "ask-critical", False),
    ]
    for name, prev, nw, sn, cf, want, clean in cases:
        d = policy.decide(prev, nw, sn, cf)
        check("policy", name, d["decision"] == want and (want == "none" or d["clean"] == clean), d)
    d = policy.decide({"ended": None, "bootId": "b1"}, dict(now, crashReport=t - 30), snap, cfg)
    check("policy", "the report is named", d["cause"].startswith("Hyprland crashed at "), d["cause"])
    # The cause names the day when the end was not today (local calendar days, `now` pinned: Sat 2026-11-21 09:00).
    def L(d, h, m):
        return time.mktime((2026, 11, d, h, m, 0, 0, 0, -1))
    pn = dict(now, time=L(21, 9, 0))
    for name, prev, want in [
        ("cause today", {"ended": "logout", "bootId": "b1", "endedAt": L(21, 1, 5)}, "Logged out at 01:05"),
        ("cause yesterday", {"ended": "logout", "bootId": "b1", "endedAt": L(20, 18, 42)}, "Logged out yesterday at 18:42"),
        ("cause a weekday", {"ended": "poweroff", "bootId": "b0", "endedAt": L(18, 23, 10)}, "Powered off Wed at 23:10"),
        ("cause older", {"ended": "reboot", "bootId": "b0", "endedAt": L(12, 18, 42)}, "Restarted 12 Nov at 18:42"),
    ]:
        d = policy.decide(prev, pn, {"time": L(21, 8, 59), "windows": 5}, cfg)
        check("policy", name, d["cause"] == want, d["cause"])
    d = policy.decide({"ended": None, "bootId": "b1"}, dict(pn, crashReport=L(20, 14, 2)), {"time": L(21, 8, 59), "windows": 5}, cfg)
    check("policy", "crash report names the day", d["cause"] == "Hyprland crashed yesterday at 14:02", d["cause"])
    d = policy.decide({"ended": None, "bootId": "b1", "restoring": {"snapshot": "x", "done": None}}, now, snap, cfg)
    check("policy", "the cut restore is named", "last restore" in d["cause"], d["cause"])


# ---- begin: the CLI against a fake Hyprland and state ---------------------------------------------------------------------
def g_begin(fp, proc_root):
    base = os.path.join(WORK, "begin")

    def setup(name, sig, safe=False):
        d = os.path.join(base, name)
        rt = os.path.join(d, "rt")
        hd = os.path.join(rt, "hypr", sig)
        os.makedirs(hd, exist_ok=True)
        open(os.path.join(hd, ".socket.sock"), "w").close()
        pid = 9000 + (abs(hash(sig)) % 500)
        open(os.path.join(hd, "hyprland.lock"), "w").write("%d\nwayland-1\n" % pid)
        fp.add(pid, 1, ["Hyprland", "--watchdog-fd", "4"] + (["--safe-mode"] if safe else []))
        env = dict(os.environ, HOME=os.path.join(d, "home"), XDG_STATE_HOME=os.path.join(d, "state"),
                   XDG_RUNTIME_DIR=rt, XDG_CONFIG_HOME=os.path.join(d, "cfg"), XDG_CACHE_HOME=os.path.join(d, "cache"),
                   HYPRLAND_INSTANCE_SIGNATURE=sig, LARES_SESSION_PROC=proc_root)
        return d, env, pid

    def begin(env):
        p = subprocess.run([sys.executable, QS, "begin"], env=env, capture_output=True, text=True)
        try:
            return json.loads(p.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return {"decision": "ERROR", "out": p.stdout + p.stderr}

    def paths_of(d):
        return state.Paths({"HOME": os.path.join(d, "home"), "XDG_STATE_HOME": os.path.join(d, "state"),
                            "XDG_RUNTIME_DIR": os.path.join(d, "rt"), "XDG_CONFIG_HOME": os.path.join(d, "cfg"),
                            "XDG_CACHE_HOME": os.path.join(d, "cache")})

    snap = {"version": 1, "time": time.time() - 30, "sig": "sigA", "apps": [{"id": "a1", "name": "kitty"}],
            "windows": [{"id": "w1", "app": "a1", "class": "kitty"}, {"id": "w2", "app": "a1", "class": "kitty"}]}

    # 1. the very first session
    d, env, _ = setup("first", "sigA")
    r = begin(env)
    check("begin", "first session", r.get("decision") == "none", r)
    st1 = state.load_state(paths_of(d))
    check("begin", "the session is recorded", (st1.get("current") or {}).get("sig") == "sigA"
          and (st1["current"] or {}).get("bootId") == "boot-1", st1.get("current"))

    # 2. logout -> the next session restores by itself; a shell restart in it decides nothing
    d, env, _ = setup("logout", "sigA")
    p = paths_of(d)
    p.ensure()
    sid = state.freeze(p, snap, "logout")
    state.save_state(p, {"current": {"sig": "sigA", "bootId": "boot-1", "hyprPid": 1, "started": time.time() - 500,
                                     "ended": "logout", "endedAt": time.time() - 30, "endSnapshot": sid}})
    _, env2, _ = setup("logout", "sigB")
    r = begin(env2)
    check("begin", "after a logout: an ask that may run commands", r.get("decision") == "ask" and r.get("clean") is True
          and r.get("snapshot") == sid and "2 windows" in r.get("summary", ""), r)
    r = begin(env2)
    check("begin", "the ask is repeated to a restarted shell", r.get("decision") == "ask" and r.get("repeat") is True, r)

    # 2b. the same with "afterLogout": "auto" in the user's config: restored by itself, and a shell restart decides nothing
    d, env, _ = setup("auto", "sigA")
    p = paths_of(d)
    p.ensure()
    sid = state.freeze(p, snap, "logout")
    state.save_state(p, {"current": {"sig": "sigA", "bootId": "boot-1", "hyprPid": 1, "started": time.time() - 500,
                                     "ended": "logout", "endedAt": time.time() - 30, "endSnapshot": sid}})
    os.makedirs(os.path.join(d, "cfg", "quickshell", "config"))
    open(os.path.join(d, "cfg", "quickshell", "config", "session.jsonc"), "w").write('{ "afterLogout": "auto" } // the user\'s\n')
    _, env2, _ = setup("auto", "sigB")
    r = begin(env2)
    check("begin", "afterLogout auto", r.get("decision") == "auto" and r.get("snapshot") == sid, r)
    r = begin(env2)
    check("begin", "a shell restart decides nothing", r.get("decision") == "none", r)

    # 3. a crash: the rolling picture becomes the candidate, the ask is critical, and it is repeated to a restarted shell
    d, env, pid = setup("crash", "sigA")
    p = paths_of(d)
    p.ensure()
    state.write_json(p.rolling, snap)
    state.save_state(p, {"current": {"sig": "sigA", "bootId": "boot-1", "hyprPid": pid, "started": time.time() - 500, "ended": None}})
    os.makedirs(os.path.join(d, "cache", "hyprland"))
    open(os.path.join(d, "cache", "hyprland", "hyprlandCrashReport%d.txt" % pid), "w").write("x")
    _, env2, _ = setup("crash", "sigB")
    r = begin(env2)
    check("begin", "after a crash", r.get("decision") == "ask-critical" and r.get("clean") is False
          and (r.get("snapshot") or "").endswith("-unclean") and r.get("cause", "").startswith("Hyprland crashed"), r)
    check("begin", "the rolling picture is frozen and gone", not os.path.exists(p.rolling) and len(state.list_snapshots(p)) == 1,
          os.listdir(p.state))
    r = begin(env2)
    check("begin", "an unanswered ask is repeated", r.get("decision") == "ask-critical" and r.get("repeat") is True, r)
    subprocess.run([sys.executable, QS, "answer", "discard"], env=env2, capture_output=True)
    r = begin(env2)
    check("begin", "an answered ask is not", r.get("decision") == "none", r)

    # 4. safe mode: nothing decided, nothing touched
    d, env, _ = setup("safe", "sigA")
    p = paths_of(d)
    p.ensure()
    sid = state.freeze(p, snap, "logout")
    before = {"current": {"sig": "sigA", "bootId": "boot-1", "hyprPid": 1, "started": 1, "ended": "logout", "endSnapshot": sid}}
    state.save_state(p, before)
    _, env2, _ = setup("safe", "sigSAFE", safe=True)
    r = begin(env2)
    check("begin", "safe mode decides nothing", r.get("decision") == "none" and r.get("cause") == "safe mode", r)
    check("begin", "safe mode touches nothing", state.load_state(p) == before, state.load_state(p))
    _, env3, _ = setup("safe", "sigC")
    r = begin(env3)
    check("begin", "after safe mode the session is still offered", r.get("decision") == "ask", r)

    # 4b. a session that never ended, in ANOTHER boot: the previous boot's journal says whether logind shut it down
    # (the watcher's own mark races the shutdown and loses). A stub journalctl answers; none/empty = a crash.
    def stub_journal(d, text):
        bd = os.path.join(d, "bin")
        os.makedirs(bd, exist_ok=True)
        open(os.path.join(bd, "args"), "w").write("")
        open(os.path.join(bd, "journalctl"), "w").write('#!/bin/sh\necho "$@" > "%s/args"\nprintf %%s "%s"\n' % (bd, text))
        os.chmod(os.path.join(bd, "journalctl"), 0o755)
        return bd

    jline = "%d.123456 laptop systemd-logind[751]: System is rebooting.\\n" % int(time.time() - 3600)
    for name, text, want, clean in (("journal", jline, "ask", True), ("emptyjournal", "", "ask-critical", False)):
        d, env, pid = setup(name, "sigA")
        p = paths_of(d)
        p.ensure()
        state.write_json(p.rolling, snap)
        state.save_state(p, {"current": {"sig": "sigA", "bootId": "boot-0", "hyprPid": pid, "started": time.time() - 5000, "ended": None}})
        _, env2, _ = setup(name, "sigB")
        bd = stub_journal(d, text)
        env2["PATH"] = bd + os.pathsep + env2["PATH"]
        r = begin(env2)
        check("begin", "another boot, %s: %s" % (name, "restarted, a clean ask" if clean else "still a crash"),
              r.get("decision") == want and r.get("clean") is clean
              and (re.match(r"Restarted (yesterday |[A-Z][a-z]{2} |\d+ [A-Z][a-z]{2} )?at \d", r.get("cause", "")) is not None if clean else True), r)
    # (the journal line is an hour old on the real clock: past midnight the cause names the day, "Restarted yesterday at 23:43")
    check("begin", "the previous boot's id (dashes out) is what is asked",
          "-b boot0" in open(os.path.join(bd, "args")).read(), open(os.path.join(bd, "args")).read())
    # the same boot (the compositor crashed in a running system) never asks the journal
    d, env, pid = setup("sameboot", "sigA")
    p = paths_of(d)
    p.ensure()
    state.write_json(p.rolling, snap)
    state.save_state(p, {"current": {"sig": "sigA", "bootId": "boot-1", "hyprPid": pid, "started": time.time() - 500, "ended": None}})
    _, env2, _ = setup("sameboot", "sigB")
    bd = stub_journal(d, jline)
    env2["PATH"] = bd + os.pathsep + env2["PATH"]
    r = begin(env2)
    check("begin", "same boot, compositor crashed: still a crash", r.get("decision") == "ask-critical" and r.get("clean") is False, r)

    # 4c. a crash during a PRESET load is an ordinary crash: the rolling picture, no lookup of the preset, no "last restore" cause
    d, env, pid = setup("presetcrash", "sigA")
    p = paths_of(d)
    p.ensure()
    state.write_json(p.rolling, snap)
    state.save_state(p, {"current": {"sig": "sigA", "bootId": "boot-1", "hyprPid": pid, "started": time.time() - 100, "ended": None,
                                     "restoring": {"preset": "dev", "since": time.time() - 90, "done": None}}})
    _, env2, _ = setup("presetcrash", "sigB")
    r = begin(env2)
    check("begin", "a crash during a preset load is an ordinary crash", r.get("decision") == "ask-critical"
          and (r.get("snapshot") or "").endswith("-unclean") and "last restore" not in r.get("cause", ""), r)

    # 5. a restore cut short: its own snapshot is the candidate, never the half-built rolling picture
    d, env, pid = setup("cut", "sigA")
    p = paths_of(d)
    p.ensure()
    sid = state.freeze(p, snap, "logout")
    state.write_json(p.rolling, dict(snap, windows=snap["windows"][:1]))
    state.save_state(p, {"current": {"sig": "sigA", "bootId": "boot-1", "hyprPid": pid, "started": time.time() - 100, "ended": None,
                                     "restoring": {"snapshot": sid, "since": time.time() - 90, "done": None}}})
    _, env2, _ = setup("cut", "sigB")
    r = begin(env2)
    check("begin", "a restore cut short", r.get("decision") == "ask-critical" and r.get("snapshot") == sid
          and "last restore" in r.get("cause", ""), r)


# ---- plan ----------------------------------------------------------------------------------------------------------------
def g_plan():
    cfg = dict(state.DEFAULTS, apps={"skipme": {"skip": True, "why": "the user's"}})
    rules = state.effective(state.load_rules(), cfg)
    odd = state.effective({"apps": {"code": {"launch": ["code", "-n"]}}}, {"apps": {"code": {"launch": "code --new-window", "slow": True}, "x": {"launch": ["x"]}}})
    check("plan", "a launch that is a string leaves the built-in one (a list of letters is no command), a list is taken",
          odd["apps"]["code"] == {"launch": ["code", "-n"], "slow": True} and odd["apps"]["x"]["launch"] == ["x"], odd["apps"])
    # the staging workspace's name says where its windows belong, both ways
    for ws in ({"key": 3, "name": "3", "special": False}, {"key": "special:default", "name": "special:default", "special": True},
               {"key": "work", "name": "work", "special": False}):
        check("plan", "staging name of %s" % ws["key"], plan.stage_target(plan.stage_name(ws)) == ws
              and plan.stage_name(ws).startswith("special:lsr-"), plan.stage_name(ws))
    check("plan", "no other name is a staging name", plan.stage_target("special:default") is None and plan.stage_target("3") is None
          and plan.stage_target("special:lsr-zz") is None and plan.stage_target("special:lsr-sXY") is None, "")

    def win(i, app, title, ws, **kw):
        w = {"id": "w%d" % i, "app": app, "address": "0x%d" % i, "class": kw.pop("cls", "kitty"), "title": title,
             "workspace": {"key": ws, "name": str(ws), "special": str(ws).startswith("special")}, "monitor": "eDP-1",
             "floating": False, "at": [0, 0], "size": [100, 100], "fullscreen": 0, "pinned": False, "group": None, "tags": []}
        w.update(kw)
        return w

    job = {"tops": [{"argv": ["lazygit"]}], "typed": {"kind": "alias", "alias": "lazygit", "text": "lg"}, "root": False, "claude": None}
    yay = {"tops": [{"argv": ["yay", "-Syu"]}], "typed": None, "root": False, "claude": None}
    snap = {"apps": [
        {"id": "a1", "kind": "terminal", "class": "kitty", "name": "kitty", "argv": ["kitty", "--hold", "fastfetch"],
         "launch": ["kitty"], "terminal": {"opts": ["--hold"], "program": ["fastfetch"], "shell": True, "cwd": "/tmp", "job": job}},
        {"id": "a2", "kind": "terminal", "class": "kitty", "name": "kitty", "argv": ["kitty"], "launch": ["kitty"],
         "terminal": {"opts": [], "program": [], "shell": True, "cwd": "/nonexistent-dir", "job": yay}},
        {"id": "a3", "kind": "terminal", "class": "kitty", "name": "kitty", "argv": ["kitty", "--title", "yazi", "sh", "-c", "yazi"],
         "launch": ["kitty"], "terminal": {"opts": ["--title", "yazi"], "program": ["sh", "-c", "yazi"], "shell": False,
                                           "cwd": "/tmp", "job": None, "rootArgv": ["yazi"]}},
        {"id": "a4", "kind": "terminal", "class": "kitty", "name": "kitty", "argv": ["kitty", "-e", "yay", "-Syu"],
         "launch": ["kitty"], "terminal": {"opts": ["-e"], "program": ["yay", "-Syu"], "shell": False, "cwd": "/tmp", "job": None,
                                           "rootArgv": ["yay", "-Syu"]}},
        {"id": "a5", "kind": "gui", "class": "zen", "name": "Zen Browser", "launch": ["zen-browser"], "selfRestore": True, "cwd": "/"},
        {"id": "a6", "kind": "gui", "class": "org.gnome.Loupe", "name": "Image Viewer", "launch": ["loupe", "/x.png"], "cwd": "/tmp"},
        {"id": "a7", "kind": "gui", "class": "com.freerdp.client.sdl3", "name": "Windows", "launch": ["windows-vm"], "skip": True,
         "why": "a verdict of older rules, kept in the picture"},
        {"id": "a9", "kind": "gui", "class": "skipme", "name": "Skipped", "launch": ["x"]},
        {"id": "a8", "kind": "gui", "class": "mystery", "name": "mystery", "launch": None, "why": "no way to start it is known"},
    ], "windows": [
        win(1, "a1", "lg", 1, group={"id": "g1", "index": 1, "active": True, "locked": True}),
        win(2, "a2", "yay", 1, group={"id": "g1", "index": 0, "active": False, "locked": True}),
        win(3, "a3", "yazi", 4, floating=True, at=[1604, 1054], size=[691, 233]),
        win(4, "a4", "upd", 2),
        win(5, "a5", "Mail — Zen Browser", 2, cls="zen"),
        win(6, "a5", "Docs — Zen Browser", "special:default", cls="zen"),
        win(7, "a6", "x.png", 3, cls="org.gnome.Loupe"),
        win(8, "a7", "Windows", 5, cls="com.freerdp.client.sdl3"),
        win(9, "a8", "?", 5, cls="mystery"),
        win(10, "a9", "skipped", 5, cls="skipme"),
    ]}
    pl = plan.build(snap, [], rules, cfg, True)
    by = {l["app"]: l for l in pl["launches"]}
    check("plan", "the run-listed job runs", by["a1"]["pending"]["mode"] == "run" and by["a1"]["pending"]["command"] == "lg", by["a1"])
    check("plan", "a held program that is over is not run again (kitty --hold fastfetch: a plain shell)",
          by["a1"]["cmd"] == ["kitty", "--directory", "/tmp"], by["a1"]["cmd"])
    check("plan", "every window is opened on its staging workspace", by["a1"]["rule"]["workspace"] == "special:lsr-n1 silent"
          and by["a1"]["target"] == "1 silent" and by["a3"]["rule"]["workspace"] == "special:lsr-n4 silent"
          and by["a5"]["rule"]["workspace"] == "special:lsr-n2 silent", (by["a1"]["rule"], by["a3"]["rule"], by["a5"]["rule"]))
    check("plan", "the risky job is typed; a directory that is gone is not passed",
          by["a2"]["pending"]["mode"] == "type" and by["a2"]["cmd"] == ["kitty"], by["a2"])
    check("plan", "a kitty with no shell runs as it did", by["a3"]["pending"] is None
          and by["a3"]["cmd"] == ["kitty", "--directory", "/tmp", "--title", "yazi", "sh", "-c", "yazi"]
          and by["a3"]["rule"].get("float") is True and by["a3"]["rule"].get("move") == "1604 1054"
          and by["a3"]["rule"].get("size") == "691 233", by["a3"])
    check("plan", "a kitty that ran a risky program becomes a shell with the line typed",
          by["a4"]["pending"] == {"mode": "type", "command": "yay -Syu", "reason": by["a4"]["pending"]["reason"]}
          and by["a4"]["cmd"] == ["kitty", "--directory", "/tmp", "-e"], by["a4"])
    check("plan", "a self-restoring app is started once for its windows", by["a5"]["mode"] == "multi"
          and by["a5"]["windows"] == ["w5", "w6"] and "float" not in by["a5"]["rule"], by["a5"])
    check("plan", "a plain app is one token launch in its directory", by["a6"]["mode"] == "token" and by["a6"]["cwd"] == "/tmp"
          and by["a6"]["target"] == "3 silent", by["a6"])
    check("plan", "a slow app (the Windows VM) opens on its own workspace, under today's rules whatever the picture said",
          by.get("a7", {}).get("mode") == "slow" and by["a7"]["rule"]["workspace"] == "5 silent" and by["a7"]["cmd"] == ["windows-vm"],
          by.get("a7"))
    check("plan", "the special workspace's rule", plan.ws_rule({"key": "special:default", "name": "special:default"}) == "special:default silent"
          and plan.ws_rule({"key": "work", "name": "work"}) == "name:work silent", "")
    why = {s["window"]: s["why"] for s in pl["skipped"]}
    check("plan", "skip and unknown are reported, not started", why.get("w10") == "the user's" and "no way" in why.get("w9", "")
          and "a9" not in by and "a8" not in by, why)
    check("plan", "the group in tab order, with its lock",
          pl["groups"] == [{"id": "g1", "members": ["w2", "w1"], "active": "w1", "locked": True}], pl["groups"])
    order = [l["app"] for l in pl["launches"]]
    check("plan", "the launch order follows the workspaces", order.index("a2") < order.index("a1") < order.index("a4")
          and order.index("a4") < order.index("a6") < order.index("a3"), order)
    cmd = plan.shell_command(by["a6"], {"X": "1"})
    check("plan", "the launch line", cmd.startswith("env -C /tmp X=1 LARES_SESSION_TOKEN=lsr") and cmd.endswith(" loupe /x.png"), cmd)
    # unclean: nothing runs
    pl2 = plan.build(snap, [], rules, cfg, False)
    by2 = {l["app"]: l for l in pl2["launches"]}
    check("plan", "after an unclean end every job is typed", by2["a1"]["pending"]["mode"] == "type"
          and by2["a3"]["pending"] == {"mode": "type", "command": "yazi", "reason": by2["a3"]["pending"]["reason"]}, (by2["a1"], by2["a3"]))
    check("plan", "... and a kitty that ran a program keeps its own options (the user's rules match its title)",
          by2["a3"]["cmd"] == ["kitty", "--directory", "/tmp", "--title", "yazi"], by2["a3"]["cmd"])
    # what is open is not started again
    live = [{"class": "kitty", "title": "lg"}, {"class": "zen", "title": "whatever"}]
    pl3 = plan.build(snap, live, rules, cfg, True)
    by3 = {l["app"]: l for l in pl3["launches"]}
    why3 = {s["window"]: s["why"] for s in pl3["skipped"]}
    check("plan", "an open window and a running app are skipped", "a1" not in by3 and "a5" not in by3
          and why3.get("w1") == "already open" and why3.get("w5") == "the app is already running", why3)
    check("plan", "one tab of a group whose rest is open is no group of its own", pl3["groups"] == [], pl3["groups"])


def g_match():
    saved = [{"id": "w1", "title": "keybinds.lua - hypr - Visual Studio Code"},
             {"id": "w2", "title": "● general.md - quickshell - Visual Studio Code"}]
    live = [{"address": "A", "title": "general.md - quickshell - Visual Studio Code"},
            {"address": "B", "title": "Welcome - hypr - Visual Studio Code"}]
    pairs = {s["id"]: c["address"] for s, c in restore.assign_by_title(saved, live)}
    check("match", "by folder when the file differs", pairs == {"w1": "B", "w2": "A"}, pairs)
    pairs = {s["id"]: c["address"] for s, c in restore.assign_by_title(saved, live[:1])}
    check("match", "fewer windows than saved", pairs == {"w2": "A"}, pairs)
    check("match", "the unsaved dot is ignored", restore.title_score("● a.md - x", "a.md - x") == 2.0, "")


# ---- vscode: one process, two windows, a folder each ----------------------------------------------------------------------
def g_vscode():
    from sessionlib import vscode
    d = os.path.join(WORK, "vscode")
    store = os.path.join(d, "Code", "User", "workspaceStorage")
    for i, (name, kind) in enumerate((("quickshell", "folder"), ("hypr", "folder"), ("quickshell", "folder"), ("team", "workspace"))):
        os.makedirs(os.path.join(store, "h%d" % i))
        target = os.path.join(d, "dir%d" % i, name + (".code-workspace" if kind == "workspace" else ""))
        os.makedirs(os.path.dirname(target))
        if kind == "workspace":
            open(target, "w").write("{}")
        else:
            os.makedirs(target)
        uri = "file://" + target.replace(" ", "%20")
        wj = os.path.join(store, "h%d" % i, "workspace.json")
        open(wj, "w").write(json.dumps({kind: uri}))
        os.utime(wj, (1000 + i, 1000 + i))
    app = "Visual Studio Code"
    q = vscode.resolve("bridge.md - quickshell - " + app, app, store)
    check("vscode", "the root name ends the title; the newest of two folders of one name", q == os.path.join(d, "dir2", "quickshell"), q)
    check("vscode", "no editor open: the title is the root", vscode.resolve("hypr - " + app, app, store) == os.path.join(d, "dir1", "hypr"), "")
    check("vscode", "a multi-root workspace", vscode.resolve("a.md - team (Workspace) - " + app, app, store) == os.path.join(d, "dir3", "team.code-workspace"), "")
    check("vscode", "nothing matches: no guess", vscode.resolve("x.md - nowhere - " + app, app, store) is None
          and vscode.resolve("quickshell", app, store) is None, "")

    cfg = dict(state.DEFAULTS)
    rules = state.effective(state.load_rules(), cfg)
    cls = "com.microsoft.VSCode"
    from sessionlib import capture
    wins = [{"app": "a1", "title": "bridge.md - quickshell - " + app}, {"app": "a1", "title": "x - nowhere - " + app}]
    capture._vscode_folders([{"id": "a1", "class": cls}], wins, rules, type("P", (), {"xdg_config": d})())
    check("vscode", "capture records a folder per window, none where nothing resolves",
          wins[0].get("folder") == os.path.join(d, "dir2", "quickshell") and "folder" not in wins[1], wins)

    def win(i, title, folder):
        w = {"id": "w%d" % i, "app": "a1", "address": "0x%d" % i, "class": cls, "title": title,
             "workspace": {"key": 1, "name": "1", "special": False}, "monitor": "eDP-1", "floating": False, "at": [0, 0],
             "size": [100, 100], "fullscreen": 0, "pinned": False, "group": None, "tags": []}
        if folder:
            w["folder"] = folder
        return w

    def snap(folders):
        return {"apps": [{"id": "a1", "kind": "gui", "class": cls, "name": "Code", "launch": ["code"], "selfRestore": True, "cwd": "/"}],
                "windows": [win(1, "bridge.md - quickshell - " + app, "/p/quickshell" if folders else None),
                            win(2, "general.md - hypr - " + app, "/p/hypr" if folders else None)]}

    pl = plan.build(snap(True), [], rules, cfg, True)
    l = pl["launches"][0]
    check("vscode", "one start for the process, the folders ride on it", len(pl["launches"]) == 1 and l["mode"] == "multi"
          and l["cmd"] == ["code"] and l.get("folders") == {"w1": "/p/quickshell", "w2": "/p/hypr"}, l)
    check("vscode", "no folder recorded: today's launch, nothing extra", not plan.build(snap(False), [], rules, cfg, True)["launches"][0].get("folders"), "")

    class Hy:
        def __init__(self):
            self.sent = []

        def dispatch(self, lua):
            self.sent.append(lua)

    hy = Hy()
    r = restore.Restore(hy, None, None, pl, extra_env={})
    r._open_missing(l, ["w1", "w2"], [{"title": "x.md - quickshell - " + app}])
    check("vscode", "VS Code brought one folder back: the other is opened with code -n",
          len(hy.sent) == 1 and "-n /p/hypr" in hy.sent[0] and "/p/quickshell" not in hy.sent[0], hy.sent)
    # through _match: not before VS Code's own restore has settled (nothing new for FOLDER_SETTLE_S), then once
    hy2 = Hy()
    r2 = restore.Restore(hy2, None, None, pl, extra_env={})
    r2.before = set()
    r2.clients = lambda: [{"address": "0xa", "class": cls, "title": "x.md - quickshell - " + app}]
    l2 = {k: v for k, v in l.items() if k != "_spawned"}
    r2._match([l2])
    check("vscode", "_match waits while VS Code's restore may still be bringing windows", not hy2.sent and not l2.get("_spawned"), hy2.sent)
    l2["_cn_at"] -= restore.FOLDER_SETTLE_S + 1
    r2._match([l2])
    r2._match([l2])
    check("vscode", "_match opens the missing folder once, after it settled", len(hy2.sent) == 1 and l2.get("_spawned"), hy2.sent)
    hy.sent.clear()
    r._open_missing(l, ["w1", "w2"], [{"title": "x.md - quickshell - " + app}, {"title": "y - hypr - " + app}])
    check("vscode", "both back by themselves: nothing is opened", not hy.sent, hy.sent)


# ---- end: how the watcher tells a machine going down ---------------------------------------------------------------------
def g_end():
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("lares_session_cases", QS)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    tool = importlib.util.module_from_spec(spec)
    loader.exec_module(tool)

    def fake(running, preparing, jobs):
        def run(argv):
            if argv[:2] == ["systemctl", "is-system-running"]:
                return running + "\n"
            if argv[:1] == ["busctl"]:
                return ("b true" if preparing else "b false") + "\n"
            if argv[:2] == ["systemctl", "list-jobs"]:
                return "".join("%d %s start waiting\n" % (i + 1, u) for i, u in enumerate(jobs))
            return ""
        return run

    # what this machine answered while a `systemctl reboot` tore the session down (no delay inhibitor left: logind false)
    cases = [
        ("a reboot nobody delayed", fake("stopping", False, ["systemd-reboot.service", "reboot.target", "shutdown.target"]), "reboot"),
        ("a power-off", fake("stopping", False, ["poweroff.target", "shutdown.target"]), "poweroff"),
        ("a halt", fake("stopping", False, ["halt.target"]), "poweroff"),
        ("a shutdown whose job is not listed", fake("stopping", False, []), "system"),
        ("held back by a delay inhibitor (logind says so first)", fake("running", True, ["reboot.target"]), "reboot"),
        ("a running machine", fake("running", False, []), None),
        ("a degraded machine is not going down", fake("degraded", False, []), None),
        ("the compositor crashed: nothing is going down", fake("running", False, ["foo.service"]), None),
    ]
    for name, run, want in cases:
        got = tool.system_end_kind(run)
        check("end", name, got == want, got)
    d = policy.decide({"ended": "system", "endedHow": "reboot", "bootId": "b0", "endedAt": 1_800_000_000.0},
                      {"bootId": "b1", "time": 1_800_000_100.0, "safeMode": False, "crashReport": None},
                      {"time": 1_800_000_000.0, "windows": 3}, dict(state.DEFAULTS))
    check("end", "a reboot seen this way asks as after a reboot, and says so", d["decision"] == "ask" and d["clean"] is True
          and d["cause"].startswith("Restarted at "), d)


# ---- preset: the store, its names, the face ---------------------------------------------------------------------------------
def g_preset():
    from sessionlib import presets
    base = os.path.join(WORK, "preset")
    env_d = {"HOME": os.path.join(base, "home"), "XDG_STATE_HOME": os.path.join(base, "state"), "XDG_DATA_HOME": os.path.join(base, "data"),
             "XDG_RUNTIME_DIR": os.path.join(base, "rt"), "XDG_CONFIG_HOME": os.path.join(base, "cfg"), "XDG_CACHE_HOME": os.path.join(base, "cache")}
    paths = state.Paths(env_d)

    def win(i, ws, cls="kitty", title="t", **kw):
        w = {"id": "w%d" % i, "app": "a1", "address": "0x%d" % i, "class": cls, "title": title,
             "workspace": {"key": ws, "name": str(ws), "special": str(ws).startswith("special")}, "monitor": "eDP-1",
             "floating": False, "at": [0, 0], "size": [100, 100], "fullscreen": 0, "pinned": False, "group": None, "tags": []}
        w.update(kw)
        return w

    snap = {"version": 1, "time": 1.0, "sig": "s", "bootId": "b", "apps": [{"id": "a1", "kind": "gui", "class": "kitty"}],
            "monitors": [{"name": "eDP-1", "x": 0, "y": 0, "width": 2880, "height": 1800, "scale": 1.5}],
            "windows": [win(1, "special:default", title="sp"), win(2, "work", title="named"), win(3, 10, title="ten"),
                        win(4, 2, title="two-a", group={"id": "g1", "index": 1, "active": False, "locked": True}),
                        win(5, 2, title="two-b", group={"id": "g1", "index": 0, "active": True, "locked": True}, floating=True,
                            at=[10, 20], size=[300, 200], pinned=True, fullscreen=0)]}
    err = lambda f: (lambda: f())  # noqa: E731

    def reason(fn):
        try:
            fn()
        except presets.PresetError as e:
            return e.reason
        return None

    check("preset", "save keeps a name under its slug", presets.save(paths, "  Dev Setup! ", snap, now=100.0) == "dev-setup", "")
    f = os.path.join(paths.presets, "dev-setup.json")
    check("preset", "the file is 0600 in a 0700 dir, outside snapshots/",
          oct(os.stat(f).st_mode & 0o777) == "0o600" and oct(os.stat(paths.presets).st_mode & 0o777) == "0o700"
          and not os.path.commonpath([paths.presets, paths.snapshots]) == paths.snapshots and paths.presets.startswith(paths.data), "")
    got = presets.load(paths, "dev setup")
    check("preset", "a snapshot plus its name and times", got["preset"] == {"name": "Dev Setup!", "created": 100.0, "updated": 100.0}
          and got["version"] == 1 and len(got["windows"]) == 5, got.get("preset"))
    check("preset", "a name that exists is refused; one with the same slug too",
          reason(lambda: presets.save(paths, "Dev Setup!", snap)) == "exists" and reason(lambda: presets.save(paths, "dev-setup", snap)) == "exists", "")
    presets.save(paths, "DEV setup", snap, over=True, now=200.0)
    check("preset", "--over keeps `created`, moves `updated`, takes the new spelling",
          presets.load(paths, "dev-setup")["preset"] == {"name": "DEV setup", "created": 100.0, "updated": 200.0}, presets.load(paths, "dev-setup")["preset"])
    check("preset", "bad names: empty, only symbols, 41 characters", reason(lambda: presets.save(paths, "   ", snap)) == "name"
          and reason(lambda: presets.save(paths, "!!!", snap)) == "name" and reason(lambda: presets.save(paths, "x" * 41, snap)) == "name"
          and reason(lambda: presets.save(paths, "x" * 40, snap)) is None, "")
    presets.save(paths, "alpha", snap, now=300.0)
    ls = presets.listing(paths)
    check("preset", "the list is by name, case-insensitive", [p["name"] for p in ls] == ["alpha", "DEV setup", "x" * 40], [p["name"] for p in ls])
    p0 = ls[0]
    check("preset", "a list entry's shape", sorted(p0) == ["created", "face", "name", "slug", "updated", "windows", "workspaces"]
          and p0["windows"] == 5 and p0["workspaces"] == 4 and p0["slug"] == "alpha", sorted(p0))
    face = p0["face"]
    check("preset", "the face: logical monitors", face["monitors"] == [{"name": "eDP-1", "w": 1920, "h": 1200}], face["monitors"])
    check("preset", "the face: numbered ascending, named, special last",
          [w["key"] for w in face["workspaces"]] == ["2", "10", "work", "special:default"] and face["workspaces"][-1]["special"] is True
          and sorted(face["workspaces"][0]) == ["key", "monitor", "name", "special", "windows"], [w["key"] for w in face["workspaces"]])
    wins2 = {w["title"]: w for w in face["workspaces"][0]["windows"]}
    check("preset", "the face: a window's fields, its group's size and lock",
          sorted(wins2["two-b"]) == ["at", "class", "floating", "fullscreen", "group", "pinned", "size", "title"]
          and wins2["two-b"]["group"] == {"id": "g1", "index": 0, "active": True, "size": 2, "locked": True}
          and wins2["two-b"]["pinned"] is True and wins2["two-b"]["floating"] is True and wins2["two-b"]["at"] == [10, 20]
          and face["workspaces"][1]["windows"][0]["group"] is None, wins2)
    # rotation: the snapshots keep five, a preset is not one of them
    paths.ensure()
    for i in range(8):
        state.freeze(paths, dict(snap, time=1000.0 + i), "manual")
    check("preset", "the snapshots' rotation never touches a preset", len(state.list_snapshots(paths)) == 5
          and presets.load(paths, "alpha") is not None and presets.load(paths, "dev-setup") is not None,
          (len(state.list_snapshots(paths)), os.listdir(paths.presets)))

    # the CLI: rename / delete / undelete / list (none of them needs a compositor)
    def cli(*a):
        p = subprocess.run([sys.executable, QS, "preset"] + list(a), env=dict(os.environ, **env_d), capture_output=True, text=True)
        try:
            return p.returncode, json.loads(p.stdout.strip().splitlines()[-1])
        except (ValueError, IndexError):
            return p.returncode, {"raw": p.stdout + p.stderr}

    rc, j = cli("rename", "alpha", "Omega", "--json")
    check("preset", "rename", rc == 0 and j == {"ok": True, "name": "Omega", "slug": "omega"}, (rc, j))
    check("preset", "rename: the old one is gone, `created` kept", presets.load(paths, "alpha") is None
          and presets.load(paths, "omega")["preset"]["created"] == 300.0 and presets.load(paths, "omega")["preset"]["name"] == "Omega", "")
    check("preset", "rename: missing / exists / a bad name", cli("rename", "nope", "q", "--json") == (4, {"ok": False, "reason": "missing"})
          and cli("rename", "omega", "dev setup", "--json") == (4, {"ok": False, "reason": "exists"})
          and cli("rename", "omega", "???", "--json") == (2, {"ok": False, "reason": "name"}), "")
    check("preset", "a name's case may change under its own slug", cli("rename", "omega", "OMEGA", "--json")[0] == 0
          and presets.load(paths, "omega")["preset"]["name"] == "OMEGA", "")
    rc, j = cli("delete", "omega", "--json")
    check("preset", "delete moves it to .trash", rc == 0 and j["slug"] == "omega" and presets.load(paths, "omega") is None
          and os.path.exists(os.path.join(paths.presets_trash, "omega.json")), (rc, j))
    check("preset", "delete: missing", cli("delete", "omega", "--json") == (4, {"ok": False, "reason": "missing"}), "")
    rc, j = cli("list", "--json")
    check("preset", "list --json", rc == 0 and [p["name"] for p in j["presets"]] == ["DEV setup", "x" * 40], (rc, j.get("raw", j)))
    presets.save(paths, "omega", snap)
    check("preset", "a successful save sweeps the trash", not os.listdir(paths.presets_trash), os.listdir(paths.presets_trash))
    shutil.copy(os.path.join(paths.presets, "omega.json"), os.path.join(paths.presets_trash, "omega.json"))
    check("preset", "undelete is refused over a live one", cli("undelete", "omega", "--json") == (4, {"ok": False, "reason": "exists"}), "")
    cli("delete", "omega", "--json")
    rc, j = cli("undelete", "omega", "--json")
    check("preset", "undelete brings it back", rc == 0 and presets.load(paths, "omega") is not None
          and cli("undelete", "omega", "--json") == (4, {"ok": False, "reason": "missing"})
          and cli("undelete", "never", "--json") == (4, {"ok": False, "reason": "missing"}), (rc, j))
    rc, out = cli("rename")
    check("preset", "usage is exit 2", rc == 2, (rc, out))


# ---- reuse: which open window stands for which saved one ------------------------------------------------------------------
def g_reuse():
    cfg = dict(state.DEFAULTS, apps={"skipme": {"skip": True}})
    rules = state.effective(state.load_rules(), cfg)

    def term(i, cwd, job=None, shell=True, root=None):
        return {"id": i, "kind": "terminal", "class": "kitty", "name": "kitty", "launch": ["kitty"],
                "terminal": {"opts": [], "program": [], "shell": shell, "cwd": cwd, "job": job, "rootArgv": root or []}}

    def jb(*argv, claude=None):
        return {"tops": [{"argv": list(argv)}], "typed": None, "root": False, "claude": claude}

    def gui(i, cls, **kw):
        return dict({"id": i, "kind": "gui", "class": cls, "name": cls, "launch": [cls], "selfRestore": False, "cwd": "/"}, **kw)

    def win(i, app, cls, title, ws=1, **kw):
        w = {"id": "w%d" % i, "app": app, "address": "0x%x" % (0xa0 + i), "class": cls, "title": title,
             "workspace": {"key": ws, "name": str(ws), "special": False}, "monitor": "eDP-1", "floating": False,
             "at": [i, 0], "size": [100, 100], "fullscreen": 0, "pinned": False, "group": None, "tags": []}
        w.update(kw)
        return w

    code = "com.microsoft.VSCode"
    preset = {"apps": [term("p1", "/w"), term("p2", "/w", jb("tail", "-f", "x")), term("p3", "/x", jb("claude", "--resume", "abc", claude="abc")),
                       gui("p4", "zen", selfRestore=True), gui("p5", code, selfRestore=True), gui("p6", "loupe"),
                       gui("p7", "foo"), gui("p8", "bar"), term("p9", "/w", jb("btop")), term("p10", "/y", shell=False, root=["less", "f"])],
              "windows": [win(1, "p1", "kitty", "idle", 1), win(2, "p2", "kitty", "follow", 1), win(3, "p3", "kitty", "claude", 2),
                          win(4, "p4", "zen", "Mail", 3), win(5, "p4", "zen", "Docs", 3), win(6, "p5", code, "a - F1 - Code", 4, folder="/F1"),
                          win(7, "p5", code, "b - F2 - Code", 4, folder="/F2"), win(8, "p6", "loupe", "a.png", 5),
                          win(9, "p7", "foo", "t1", 5), win(10, "p7", "foo", "t2", 5), win(11, "p8", "bar", "b1", 5),
                          win(12, "p9", "kitty", "btop", 6), win(13, "p10", "kitty", "less", 6)]}
    live = {"apps": [term("l1", "/w"), term("l2", "/w", jb("vim")), term("l3", "/w", jb("tail", "-f", "y")), term("l4", "/x", jb("claude")),
                     gui("l5", "zen", selfRestore=True), gui("l6", code, selfRestore=True), gui("l7", "loupe"), gui("l8", "foo"),
                     gui("l9", "bar"), gui("l10", "skipme"), term("l11", "/y", jb("less", "f")), term("l12", "/y", shell=False, root=["less", "f"])],
            "windows": [win(21, "l1", "kitty", "other idle", 7), win(22, "l2", "kitty", "vim", 7), win(23, "l3", "kitty", "follow", 7),
                        win(24, "l4", "kitty", "cl", 7), win(25, "l5", "zen", "Docs", 8), win(26, "l5", "zen", "Other", 8),
                        win(27, "l5", "zen", "Third", 8), win(28, "l6", code, "x - F2 - Code", 9, folder="/F2"),
                        win(29, "l6", code, "y - F3 - Code", 9, folder="/F3"), win(30, "l7", "loupe", "other.png", 9),
                        win(31, "l8", "foo", "t2", 9), win(32, "l9", "bar", "b9", 9), win(33, "l9", "bar", "b8", 9),
                        win(34, "l10", "skipme", "vm", 9), win(35, "l11", "kitty", "less in a shell", 9),
                        win(36, "l12", "kitty", "less", 9)]}
    live_by_title = {w["title"]: w["address"] for w in live["windows"]}
    got = plan.match_reuse(preset, live, rules)
    by = {preset["windows"][int(k[1:]) - 1]["title"]: v["title"] for k, v in got.items()}
    check("reuse", "a terminal: same directory and program, or both at a prompt", by.get("idle") == "other idle" and by.get("follow") == "follow"
          and "btop" not in by and by.get("claude") == "cl", by)
    check("reuse", "a terminal running something else is not reused", "vim" not in by.values() and "btop" not in by, by)
    check("reuse", "a kitty with no shell is not a shell running the program", by.get("less") == "less" and "less in a shell" not in by.values(), by)
    check("reuse", "a self-restoring app: by exact title, then by order", by.get("Docs") == "Docs" and by.get("Mail") == "Other", by)
    check("reuse", "VS Code: by folder only", by.get("b - F2 - Code") == "x - F2 - Code" and "a - F1 - Code" not in by, by)
    check("reuse", "another GUI app: the same class", by.get("a.png") == "other.png", by)
    check("reuse", "a class with several windows: the same title too", by.get("t2") == "t2" and "t1" not in by and "b1" not in by, by)
    check("reuse", "every open window is used once", len({v["address"] for v in got.values()}) == len(got), got)
    check("reuse", "the open ones are the open ones", all(v["address"] == live_by_title[v["title"]] for v in got.values()), got)

    closing = plan.closable(live, got, rules)
    names = sorted(c["title"] for c in closing)
    check("reuse", "--replace closes what no saved window stands for, never a skip-rule class",
          "vim" in names and "Third" in names and "vm" not in names and "follow" not in names and "Docs" not in names, names)
    pl_r, reuse_r, closing_r = plan.preset_plan(preset, live, live["windows"], rules, cfg, True)
    pl_a, reuse_a, closing_a = plan.preset_plan(preset, live, live["windows"], rules, cfg, False)
    check("reuse", "--replace has a close list, --add never does", len(closing_r) > 0 and closing_a == [] and reuse_r == reuse_a, (len(closing_r), closing_a))
    started = sorted(plan_w for l in pl_a["launches"] for plan_w in l["windows"])
    check("reuse", "what is reused is not started, the rest is",
          not (set(started) & set(pl_a["reuse"])) and set(pl_a["reuse"]) == set(reuse_a) and "w12" in started, (started, pl_a["reuse"]))
    check("reuse", "the plan carries the reused open windows' addresses", pl_a["reuse"]["w1"] == live_by_title["other idle"], pl_a["reuse"])
    why = {s["window"]: s["why"] for s in pl_a["skipped"]}
    check("reuse", "no 'already open' skip by class and title in a preset load", "already open" not in why.values(), why)
    # fresh claude: the id stays out; a preset terminal that is not reused starts a bare claude
    p2 = dict(preset, windows=[win(3, "p3", "kitty", "claude", 2)], apps=[term("p3", "/x", jb("claude", "--resume", "abc", claude="abc"))])
    pl_c, _, _ = plan.preset_plan(p2, {"apps": [], "windows": []}, [], rules, cfg, False)
    pend = pl_c["launches"][0]["pending"]
    check("reuse", "a Claude job comes back as a fresh claude", pend["mode"] == "run" and pend["command"] == "claude", pend)
    pl_n = plan.build(p2, [], rules, cfg, True)
    check("reuse", "a restore (not a preset) still resumes it", pl_n["launches"][0]["pending"]["command"] == "claude --resume abc",
          pl_n["launches"][0]["pending"])
    pl_q, _, _ = plan.preset_plan(p2, {"apps": [], "windows": []}, [], rules, dict(cfg, presets={"claude": "resume"}), False)
    check("reuse", "session.jsonc presets.claude \"resume\" resumes it", pl_q["launches"][0]["pending"]["command"] == "claude --resume abc",
          pl_q["launches"][0]["pending"])
    rs = restore.Restore(None, None, None, pl_a)
    check("reuse", "the restore starts with the reused windows in its matched set", rs.addr == pl_a["reuse"] and rs._total() == len(pl_a["reuse"]) + len(started),
          (rs.addr, rs._total()))


try:
    g_classify()
    fp, proc_root, rt, home = g_proc()
    g_kitty()
    g_policy()
    g_begin(fp, proc_root)
    g_plan()
    g_match()
    g_vscode()
    g_end()
    g_preset()
    g_reuse()
except Exception as e:  # a throwing group is a failed check, never a run without a verdict
    import traceback
    traceback.print_exc()
    check("driver", "threw", False, repr(e))
finally:
    shutil.rmtree(WORK, ignore_errors=True)

print("SC " + ", ".join("%s %d" % kv for kv in counts.items()))
print("SESSION_CASES RESULT %s%s" % ("FAIL" if fails else "PASS", " (%d: %s)" % (len(fails), "; ".join(fails[:5])) if fails else ""))
sys.exit(1 if fails else 0)
