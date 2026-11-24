#!/usr/bin/env python3
"""The driver of tools/dev/session_env_probe.sh: runs INSIDE the nested Hyprland (a client of tools/dev/lock_env.sh).

Builds a session by hand, saves it with lares-session, closes everything, restores it, and compares the two pictures.
Every check prints `SRE ok <name>` or `SRE FAIL <name>: <what was seen>`; the last line is the verdict.
"""
import json
import os
import shlex
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "session"))
from sessionlib.hypr import Hypr, lua_str, lua_table  # noqa: E402  (Hypr: also the sampler's own connection)
from sessionlib.procs import Proc  # noqa: E402

W = os.environ["SRE_WORK"]
HOME = os.environ["HOME"]
QS = os.path.join(ROOT, "tools", "session", "lares-session")
HOOK = os.path.join(ROOT, "tools", "session", "session-hook.bash")
STUB = os.path.join(ROOT, "tools", "dev", "fixtures", "session", "stub_multi.py")
LAUNCH_ENV = {"HOME": HOME, "LARES_HOOK": HOOK}
PENDING = os.path.join(os.environ["XDG_RUNTIME_DIR"], "lares-session", "pending")

hy = Hypr()
proc = Proc()
fails = []


def check(name, ok, seen=""):
    if ok:
        print("SRE ok %s" % name, flush=True)
    else:
        print("SRE FAIL %s: %s" % (name, seen), flush=True)
        fails.append(name)


def clients():
    return [c for c in hy.json("clients") if c.get("mapped", True)]


def by_title(title, cs=None):
    for c in (cs or clients()):
        if c.get("title") == title:
            return c
    return None


def wait(cond, seconds=12.0, step=0.15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        v = cond()
        if v:
            return v
        time.sleep(step)
    return cond()


def kitty(title, ws, args=(), rule=None, pending=None, cwd=None):
    token = "sre" + title
    if pending:
        os.makedirs(PENDING, mode=0o700, exist_ok=True)
        with open(os.path.join(PENDING, token), "w") as f:
            f.write("run\n%s\n" % pending)
    cmd = ["env"] + ["%s=%s" % kv for kv in LAUNCH_ENV.items()] + ["LARES_SESSION_TOKEN=" + token, "kitty", "--title", title]
    if cwd:
        cmd += ["--directory", cwd]
    cmd += list(args)
    r = dict({"workspace": "%s silent" % ws, "no_initial_focus": True}, **(rule or {}))
    hy.dispatch("hl.dsp.exec_cmd(%s, %s)" % (lua_str(shlex.join(cmd)), lua_table(r)))
    c = wait(lambda: by_title(title))
    if not c:
        raise SystemExit("SRE FAIL scenario: %s did not open\nSESSION_ENV RESULT FAIL" % title)
    return c["address"]


def qs(*args, env=None, timeout=120):
    e = dict(os.environ, LARES_SESSION_LAUNCH_ENV=json.dumps(LAUNCH_ENV))
    e.update(env or {})
    p = subprocess.run([sys.executable, QS] + list(args), capture_output=True, text=True, env=e, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def job_of(title, cs=None):
    """The foreground job's argv of the kitty window titled `title`, or None at a prompt / no kitty."""
    c = by_title(title, cs)
    if not c:
        return "no window"
    from sessionlib.procs import terminal_windows
    proc.forget()
    wins = terminal_windows(proc, c["pid"], os.environ["XDG_RUNTIME_DIR"], HOME)
    if not wins:
        return "no terminal"
    w = wins[0]
    if not w["shell"]:
        return ["<noshell>"] + w["root"]["argv"]
    return [t["argv"] for t in w["job"]["tops"]] if w["job"] else None


def picture():
    """What must come back, keyed by title."""
    out = {}
    for c in clients():
        g = c.get("grouped") or []
        out[c["title"]] = {
            "class": c["class"], "ws": c["workspace"]["name"], "floating": c["floating"],
            "at": c["at"], "size": c["size"], "fullscreen": c["fullscreen"],
            "group": [x for x in g], "shown": c.get("visible"), "pinned": bool(c.get("pinned")),
        }
    addr_title = {c["address"]: c["title"] for c in clients()}
    for t, v in out.items():
        v["group"] = [addr_title.get(a, "?") for a in v["group"]]
    return out


def main():
    os.makedirs(os.path.join(W, "a"), exist_ok=True)
    log = os.path.join(W, "follow.log")
    open(log, "w").write("line\n")
    titles_file = os.path.join(W, "stub.titles")
    open(titles_file, "w").write("alpha document\nbeta document\n")
    cfgdir = os.path.join(os.environ["XDG_CONFIG_HOME"], "quickshell", "config")
    os.makedirs(cfgdir, exist_ok=True)
    stub_cmd = ["env", "GSK_RENDERER=cairo", "GTK_A11Y=none", sys.executable, STUB, titles_file]
    slow_titles = os.path.join(W, "slow.titles")
    open(slow_titles, "w").write("slow window\n")
    slow_cmd = ["env", "GSK_RENDERER=cairo", "GTK_A11Y=none", sys.executable, STUB, slow_titles, "slow.app"]
    held = os.path.join(W, "held.count")
    with open(os.path.join(cfgdir, "session.jsonc"), "w") as f:
        json.dump({"enabled": True, "apps": {"stub.multi": {"selfRestore": True, "launch": stub_cmd},
                                             "slow.app": {"slow": True, "launch": slow_cmd}},
                   "windowTimeoutMs": 15000, "appTimeoutMs": 20000}, f)

    # ---- the session, by hand -----------------------------------------------------------------------------------
    # tabA: `kitty --hold <program>` whose program is over (the user's `kitty --hold fastfetch`): a shell at its prompt
    # now, and the program must NOT run a second time at the restore.
    a_tabA = kitty("tabA", 1, cwd=os.path.join(W, "a"), args=["--hold", "sh", "-c", "echo x >> %s" % shlex.quote(held)])
    # tabB: a CHAIN, as the user types it -- `cd <dir>; tail -f <log>`. The cd is done when the picture is taken (the shell
    # stands in <dir>); only the tail runs, and only the tail may come back.
    chain_dir = os.path.join(W, "a")
    a_tabB = kitty("tabB", 1, pending="cd %s; tail -f %s" % (shlex.quote(chain_dir), shlex.quote(log)))
    a_tabC = kitty("tabC", 1, pending="sleep 1000")
    kitty("left", 2)
    kitty("right", 2)
    kitty("floaty", 3, rule={"float": True, "size": "800 500", "move": "100 120"})
    kitty("specialk", "special:default")
    kitty("noshell", 4, args=["less", log])
    kitty("risky", 4, args=["sh", "-c", "sleep 999"])
    a_maxi = kitty("maxi", 6)
    hy.dispatch("hl.dsp.window.fullscreen({ action = \"set\", mode = \"maximized\", window = %s })" % lua_str("address:" + a_maxi))
    hy.dispatch("hl.dsp.exec_cmd(%s, %s)" % (lua_str(shlex.join(slow_cmd)), lua_table({"workspace": "8 silent"})))
    wait(lambda: by_title("slow window"), 20)
    hy.dispatch("hl.dsp.exec_cmd(%s, %s)" % (lua_str(shlex.join(stub_cmd)), lua_table({"workspace": "5 silent"})))
    wait(lambda: by_title("alpha document") and by_title("beta document"), 20)
    beta = by_title("beta document")
    if not beta:
        raise SystemExit("SRE FAIL scenario: the stub app did not open\nSESSION_ENV RESULT FAIL")
    hy.dispatch("hl.dsp.window.move({ workspace = \"7\", follow = false, window = %s })" % lua_str("address:" + beta["address"]))
    # the group: tab order B, A, C; A on show
    hy.dispatch("hl.dsp.group.toggle({ window = %s })" % lua_str("address:" + a_tabB))
    for a in (a_tabA, a_tabC):
        hy.eval("local g = hl.get_window(%s).group; g:add(hl.get_window(%s))" % (lua_str("address:" + a_tabB), lua_str("address:" + a)))
    hy.dispatch("hl.dsp.group.active({ index = 2, window = %s })" % lua_str("address:" + a_tabB))
    hy.dispatch("hl.dsp.group.lock({ window = %s })" % lua_str("address:" + a_tabB))       # the group is LOCKED
    wait(lambda: job_of("tabB") and job_of("tabC"), 10)
    # The focus is NOT on the group: the tab on show must come back by the group's own record, not by the last focus.
    hy.dispatch("hl.dsp.focus({ workspace = 2 })")
    hy.dispatch("hl.dsp.focus({ window = %s })" % lua_str("address:" + by_title("right")["address"]))
    time.sleep(0.5)

    before = picture()
    check("scenario group", before["tabA"]["group"] == ["tabB", "tabA", "tabC"], before["tabA"]["group"])
    check("scenario tab on show", [before[t]["shown"] for t in ("tabB", "tabA", "tabC")] == [False, True, False],
          [before[t]["shown"] for t in ("tabB", "tabA", "tabC")])
    check("scenario jobs", job_of("tabB") == [["tail", "-f", log]] and job_of("tabC") == [["sleep", "1000"]],
          "%s %s" % (job_of("tabB"), job_of("tabC")))

    # ---- save ------------------------------------------------------------------------------------------------------
    rc, out, err = qs("save")
    check("scenario: the held program ran once", open(held).read().count("x") == 1, open(held).read())
    check("scenario: the group is locked", hy.group_locks(os.path.join(os.environ["XDG_RUNTIME_DIR"], "lares-session")).get(a_tabB) is True,
          hy.group_locks(os.path.join(os.environ["XDG_RUNTIME_DIR"], "lares-session")))
    check("save", rc == 0 and "13 windows" in out, (out + err).strip()[-200:])
    rc, out, err = qs("show", "--json")
    snap = json.loads(out) if rc == 0 else {"apps": [], "windows": []}
    apps = {a["id"]: a for a in snap["apps"]}
    wins = {w["title"]: w for w in snap["windows"]}

    def term(title):
        return (apps.get(wins.get(title, {}).get("app"), {}) or {}).get("terminal") or {}

    check("snapshot hook", snap.get("hook") is True, snap.get("hook"))
    check("snapshot tabA at its prompt", term("tabA").get("shell") is True and term("tabA").get("job") is None
          and term("tabA").get("cwd") == os.path.join(W, "a"), term("tabA"))
    jb = term("tabB").get("job") or {}
    check("snapshot tabB job", [t["argv"] for t in jb.get("tops", [])] == [["tail", "-f", log]]
          and (jb.get("typed") or {}).get("kind") == "builtin"
          and ((jb.get("typed") or {}).get("words") or {}).get("tail") == {"kind": "file", "alias": ""}
          and term("tabB").get("cwd") == chain_dir, jb)
    check("snapshot noshell", term("noshell").get("shell") is False and term("noshell").get("rootArgv", [None])[0] == "less",
          term("noshell"))
    check("snapshot group lock", (wins.get("tabB", {}).get("group") or {}).get("locked") is True, wins.get("tabB", {}).get("group"))
    check("snapshot group", (wins.get("tabA", {}).get("group") or {}).get("active") is True
          and (wins.get("tabB", {}).get("group") or {}).get("index") == 0
          and (wins.get("tabC", {}).get("group") or {}).get("index") == 2, [wins.get(t, {}).get("group") for t in ("tabB", "tabA", "tabC")])
    stub = [a for a in snap["apps"] if a["class"] == "stub.multi"]
    check("snapshot multi app", len(stub) == 1 and stub[0]["count"] == 2 and stub[0]["selfRestore"], stub)
    rc, out, err = qs("show")
    check("show: the chain is its running command", rc == 0 and "RUN   tail -f" in out and "RUN   cd " not in out
          and "type  cd " not in out and "type  sleep 1000" in out, (out + err)[-400:])
    print(out, flush=True)

    # ---- close everything ----------------------------------------------------------------------------------------
    pids = sorted({c["pid"] for c in clients()})
    for c in clients():
        hy.try_dispatch("hl.dsp.window.close({ window = %s })" % lua_str("address:" + c["address"]))
    if not wait(lambda: not clients(), 8):
        for p in pids:
            try:
                os.kill(p, 15)
            except OSError:
                pass
        wait(lambda: not clients(), 8)
    check("closed", not clients(), [c["title"] for c in clients()])
    hy.try_dispatch("hl.dsp.focus({ workspace = 9 })")
    # the app restores its windows in ANOTHER order than they were saved
    open(titles_file, "w").write("beta document\nalpha document\n")
    if os.environ.get("SRE_HALF"):
        # a restore into a session that already has part of it: one terminal and the app are open
        kitty("left", 2)
        hy.dispatch("hl.dsp.exec_cmd(%s)" % lua_str(shlex.join(stub_cmd)))
        wait(lambda: by_title("alpha document") and by_title("beta document"), 20)

    locker = None
    if os.environ.get("SRE_LOCKED"):
        # the boot lock's case: the whole restore runs under a session lock (lock_basic.qml: "u" unlocks)
        lockdir = os.path.join(W, "lock")
        os.makedirs(lockdir, exist_ok=True)
        import shutil
        shutil.copy(os.path.join(os.environ["SRE_LOCK_QML"]), os.path.join(lockdir, "shell.qml"))
        locker = subprocess.Popen(["quickshell", "-p", os.path.join(lockdir, "shell.qml")],
                                  stdout=open(os.path.join(W, "lock.log"), "w"), stderr=subprocess.STDOUT)
        check("locked", wait(lambda: hy.json("locked").get("locked") is True, 15), hy.json("locked"))

    # ---- restore ---------------------------------------------------------------------------------------------------
    rc, out, err = qs("restore", "--dry")
    print(out, flush=True)
    t0 = time.monotonic()
    # The restore, watched: its own progress lines, and what stands where, sampled all the way.
    import threading
    pre = {c["address"] for c in clients()}
    e = dict(os.environ, LARES_SESSION_LAUNCH_ENV=json.dumps(LAUNCH_ENV))
    p = subprocess.Popen([sys.executable, QS, "restore", "--json", "--progress"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, env=e)
    samples, events, reveal_at, stop = [], [], [None], threading.Event()

    def sampler():
        h2 = Hypr()
        while not stop.is_set():
            try:
                cs = [c for c in h2.json("clients") if c.get("mapped", True) and c["address"] not in pre]
            except Exception:
                cs = []
            samples.append((time.monotonic(), [(c["title"], c["workspace"]["name"], len(c.get("grouped") or [])) for c in cs]))
            time.sleep(0.03)

    th = threading.Thread(target=sampler, daemon=True)
    th.start()
    for line in p.stdout:
        try:
            d = json.loads(line)
        except ValueError:
            continue
        events.append(d)
        if d.get("event") == "reveal":
            reveal_at[0] = time.monotonic()
    err = p.stderr.read()
    rc = p.wait()
    stop.set()
    th.join(timeout=3)
    took = time.monotonic() - t0
    res = next((d for d in reversed(events) if d.get("event") == "result"), {})
    out = ""
    # NOTHING shows before the reveal: every new window waits on a staging workspace (the slow app alone opens in place)
    before_reveal = [s for t, s in samples if reveal_at[0] is not None and t < reveal_at[0]]
    seen = [x for s in before_reveal for x in s if x[0] != "slow window"]
    shown_early = sorted({(t, ws) for t, ws, _ in seen if not ws.startswith("special:lsr-")})
    check("staged until the reveal", reveal_at[0] is not None and not shown_early, shown_early[:4])
    check("the staging was watched (the check is not empty)", max((len(s) for s in before_reveal), default=0) >= 8,
          max((len(s) for s in before_reveal), default=0))
    # The user's complaint (2026-11-14): "it first created all windows ... 5 windows tiled and then all of a sudden they
    # group". A tab of the group is never in sight outside its group: in no sample at all.
    loose = sorted({(t, ws, g) for _, s in samples for t, ws, g in s
                    if t in ("tabA", "tabB", "tabC") and not ws.startswith("special:lsr-") and g < 3})
    check("a tab is never in sight outside its group", not loose, loose[:4])
    check("nothing is left staged", not [c for c in clients() if c["workspace"]["name"].startswith("special:lsr-")],
          [(c["title"], c["workspace"]["name"]) for c in clients() if c["workspace"]["name"].startswith("special:lsr-")])
    kinds = [d.get("event") for d in events]
    check("progress lines", kinds[:1] == ["start"] and "progress" in kinds and kinds[-2:] == ["reveal", "result"]
          and events[0].get("total") == (10 if os.environ.get("SRE_HALF") else 13), kinds[:3] + kinds[-3:])
    print("SRE restore rc=%s %.1fs %s %s" % (rc, took, json.dumps(res)[:600], err.strip()[-300:]), flush=True)
    if os.environ.get("SRE_HALF"):
        check("half: only the missing are started", res.get("restored") == 10 and len(res.get("skipped", [])) == 3, res)
        check("half: the open ones were not moved", by_title("alpha document")["workspace"]["name"] == "9", by_title("alpha document")["workspace"])
        return
    if locker:
        check("still locked after the restore", hy.json("locked").get("locked") is True, hy.json("locked"))
        check("locked: the focus is owed", res.get("refocus") is True, res.get("refocus"))
        subprocess.run(["wtype", "-p", "F24", "--", "u"], timeout=10)
        check("unlocked", wait(lambda: hy.json("locked").get("locked") is False, 10), hy.json("locked"))
        rc2, out2, err2 = qs("refocus")
        check("locked: the focus is given at the unlock", rc2 == 0 and out2.startswith("focused "), (out2 + err2).strip())
        try:
            locker.wait(timeout=5)
        except subprocess.TimeoutExpired:
            locker.kill()
    if not locker:
        check("not locked: no focus is owed", res.get("refocus") is False, res.get("refocus"))
    check("restore result", rc == 0 and res.get("restored") == 13 and not res.get("failed") and not res.get("later")
          and res.get("unclaimed") == 0, res)
    check("the held program did not run again", open(held).read().count("x") == 1, open(held).read())
    gl = hy.group_locks(os.path.join(os.environ["XDG_RUNTIME_DIR"], "lares-session"))
    tb = by_title("tabB")
    check("the group is locked again", bool(tb) and gl.get(tb["address"]) is True, gl)
    check("restore counts", res.get("ran") == 1 and res.get("typed") == 2, "ran=%s typed=%s" % (res.get("ran"), res.get("typed")))
    time.sleep(1.0)

    after = picture()
    check("all windows back", sorted(after) == sorted(before), sorted(set(before) ^ set(after)))
    for t, b in sorted(before.items()):
        a = after.get(t)
        if not a:
            continue
        check("%s workspace" % t, a["ws"] == b["ws"], "%s, was %s" % (a["ws"], b["ws"]))
        check("%s floating" % t, a["floating"] == b["floating"], a["floating"])
        check("%s fullscreen" % t, a["fullscreen"] == b["fullscreen"], a["fullscreen"])
        check("%s group" % t, a["group"] == b["group"], "%s, was %s" % (a["group"], b["group"]))
        if b["group"]:
            check("%s tab on show" % t, a["shown"] == b["shown"], "visible=%s, was %s" % (a["shown"], b["shown"]))
        near = all(abs(x - y) <= 3 for x, y in zip(a["at"] + a["size"], b["at"] + b["size"]))
        check("%s place" % t, near, "%s %s, was %s %s" % (a["at"], a["size"], b["at"], b["size"]))

    aw = hy.json("activeworkspace")
    check("active workspace back", aw.get("id") == 2, aw.get("id"))
    fw = hy.json("activewindow")
    check("focused window back", fw.get("title") == "right", fw.get("title"))
    check("tabA at its prompt", job_of("tabA") is None, job_of("tabA"))
    check("tabB runs again (run list)", wait(lambda: job_of("tabB") == [["tail", "-f", log]], 8), job_of("tabB"))
    cb = by_title("tabB")
    cwb = None
    if cb:
        from sessionlib.procs import terminal_windows as _tw
        twb = _tw(proc, cb["pid"])
        cwb = twb[0]["root"]["cwd"] if twb else None
    check("tabB stands where its cd put it", cwb == chain_dir, cwb)
    check("tabC is only typed", job_of("tabC") is None, job_of("tabC"))
    check("noshell runs as it did", (job_of("noshell") or [None, None])[:2] == ["<noshell>", "less"], job_of("noshell"))
    check("risky is a shell with the line typed", job_of("risky") is None, job_of("risky"))
    c = by_title("tabA")
    cw = None
    if c:
        from sessionlib.procs import terminal_windows
        tw = terminal_windows(proc, c["pid"])
        cw = tw[0]["root"]["cwd"] if tw else None
    check("tabA cwd", cw == os.path.join(W, "a"), cw)

    # the typed line is AT the prompt: one Enter runs it
    r = by_title("risky")
    if r:
        hy.try_dispatch("hl.dsp.focus({ workspace = 4 })")
        hy.try_dispatch("hl.dsp.focus({ window = %s })" % lua_str("address:" + r["address"]))
        time.sleep(0.6)
        subprocess.run(["wtype", "-k", "Return"], timeout=10)
        # `sh -c 'sleep 999'` execs: the job reads as sleep
        check("risky runs on Enter", wait(lambda: job_of("risky") == [["sleep", "999"]], 6), job_of("risky"))
    rc, out, err = qs("status", "--json")
    stt = json.loads(out) if rc == 0 else {}
    check("state: the restore is recorded done", ((stt.get("current") or {}).get("restoring") or {}).get("done") is not None,
          stt.get("current"))

    # ---- a window left on a staging workspace is never lost --------------------------------------------------------
    # (one that opens after its restore gave up: Hyprland's exec rule still sends it there)
    kitty("stray", "special:lsr-n9")
    rc, out, err = qs("show", "--json")       # the newest picture is the scenario's; a fresh one is taken below
    rc, out, err = qs("save")
    rc2, out2, _ = qs("show", "--json")
    strays = [w for w in (json.loads(out2).get("windows", []) if rc2 == 0 else []) if w["title"] == "stray"]
    check("a staged window is saved as its own workspace's", len(strays) == 1 and strays[0]["workspace"]["key"] == 9,
          [w["workspace"] for w in strays])
    rc, out, err = qs("reveal")
    st = by_title("stray")
    check("reveal shows what was left staged", rc == 0 and "revealed 1 window" in out and st and st["workspace"]["name"] == "9",
          (out + err).strip() + " " + str(st and st["workspace"]["name"]))
    hy.try_dispatch("hl.dsp.window.close({ window = %s })" % lua_str("address:" + st["address"]))
    wait(lambda: not by_title("stray"), 6)
    qs("forget")

    # ---- the watcher: the rolling picture follows the session ---------------------------------------------------
    rolling = os.path.join(os.environ["XDG_STATE_HOME"], "lares", "session", "rolling.json")
    wlog = open(os.path.join(W, "watch.log"), "w")
    watcher = subprocess.Popen([sys.executable, "-u", QS, "watch"], stdout=wlog, stderr=subprocess.STDOUT)

    def rolled():
        try:
            return len(json.load(open(rolling))["windows"])
        except (OSError, ValueError, KeyError):
            return -1

    check("watch: the first picture", wait(lambda: rolled() == 13, 10), rolled())
    f = by_title("floaty")
    hy.try_dispatch("hl.dsp.window.close({ window = %s })" % lua_str("address:" + f["address"]))
    check("watch: a closed window leaves the picture", wait(lambda: rolled() == 12, 10), rolled())
    # a job that starts in a terminal is seen without any window event: the title change, or the tick
    r = by_title("tabA")
    hy.try_dispatch("hl.dsp.focus({ workspace = 1 })")
    hy.try_dispatch("hl.dsp.focus({ window = %s })" % lua_str("address:" + r["address"]))
    time.sleep(0.6)
    subprocess.run(["wtype", "-p", "F24", "--", "sleep 444"], timeout=10)
    subprocess.run(["wtype", "-k", "Return"], timeout=10)

    def tabA_job():
        try:
            snap = json.load(open(rolling))
        except (OSError, ValueError):
            return None
        apps = {a["id"]: a for a in snap["apps"]}
        for w in snap["windows"]:
            if w["title"] in ("tabA",) or w["address"] == r["address"]:
                j = (apps[w["app"]].get("terminal") or {}).get("job")
                return [t["argv"] for t in j["tops"]] if j else None
        return None

    check("watch: a job that starts is in the picture", wait(lambda: tabA_job() == [["sleep", "444"]], 40, 0.5), tabA_job())
    watcher.terminate()
    try:
        watcher.wait(timeout=8)
    except subprocess.TimeoutExpired:
        watcher.kill()
    wlog.close()
    check("watch: it stops when told", "stopped (signal)" in open(os.path.join(W, "watch.log")).read(),
          open(os.path.join(W, "watch.log")).read()[-200:])

    # ---- the end: the reel's last step ----------------------------------------------------------------------------
    rc, out, err = qs("end", "logout")
    rc2, out2, _ = qs("status", "--json")
    stt = json.loads(out2) if rc2 == 0 else {}
    cur = stt.get("current") or {}
    check("end: the picture is frozen and the end recorded", rc == 0 and cur.get("ended") == "logout"
          and str(cur.get("endSnapshot", "")).endswith("-logout") and cur.get("endSnapshot") in stt.get("snapshots", []),
          (out + err).strip()[-200:] + " " + json.dumps(cur))
    rc, out, err = qs("begin")
    check("begin: a shell restart in this session decides nothing", rc == 0 and json.loads(out.strip().splitlines()[-1]).get("decision") == "none",
          (out + err)[-200:])


REFUSER = """import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gio, Gtk
def activate(app):
    w = Gtk.ApplicationWindow(application=app, title="refuser")
    w.set_default_size(400, 200)
    w.set_child(Gtk.Label(label="asks first"))
    w.connect("close-request", lambda *a: True)     # an unsaved-changes dialog: the close is refused
    w.present()
app = Gtk.Application(application_id="stub.refuse", flags=Gio.ApplicationFlags.NON_UNIQUE)
app.connect("activate", activate)
app.run([])
"""


def main_preset():
    """Presets: save a desktop, rearrange it, load it back with --add (what is open is reused and moved, the missing started,
    the extra left) and with --replace (the extra closed, a window that refuses to close kept and reported)."""
    import threading
    cfgdir = os.path.join(os.environ["XDG_CONFIG_HOME"], "quickshell", "config")
    os.makedirs(cfgdir, exist_ok=True)
    with open(os.path.join(cfgdir, "session.jsonc"), "w") as f:
        json.dump({"enabled": False, "closeTimeoutMs": 2500, "windowTimeoutMs": 15000}, f)        # presets work with it off
    refuser = os.path.join(W, "refuser.py")
    open(refuser, "w").write(REFUSER)
    dirs = {n: os.path.join(W, "d" + n) for n in ("alpha", "bravo", "charlie", "gA", "gB", "delta", "maxi", "extra", "pinny")}
    for d in dirs.values():
        os.makedirs(d, exist_ok=True)

    kitty("alpha", 1, cwd=dirs["alpha"])
    kitty("bravo", 1, cwd=dirs["bravo"])
    kitty("charlie", 2, rule={"float": True, "size": "800 500", "move": "100 120"}, cwd=dirs["charlie"])
    a_gA = kitty("gA", 3, cwd=dirs["gA"])
    kitty("gB", 3, cwd=dirs["gB"])
    kitty("delta", "special:default", cwd=dirs["delta"])
    a_maxi = kitty("maxi", 6, cwd=dirs["maxi"])
    a_pin = kitty("pinny", 2, rule={"float": True, "size": "400 300", "move": "1200 700"}, cwd=dirs["pinny"])
    hy.dispatch("hl.dsp.window.pin({ action = \"set\", window = %s })" % lua_str("address:" + a_pin))
    hy.dispatch("hl.dsp.window.fullscreen({ action = \"set\", mode = \"maximized\", window = %s })" % lua_str("address:" + a_maxi))
    hy.dispatch("hl.dsp.group.toggle({ window = %s })" % lua_str("address:" + a_gA))
    hy.eval("local g = hl.get_window(%s).group; g:add(hl.get_window(%s))" % (lua_str("address:" + a_gA), lua_str("address:" + by_title("gB")["address"])))
    hy.dispatch("hl.dsp.group.active({ index = 2, window = %s })" % lua_str("address:" + a_gA))
    hy.dispatch("hl.dsp.group.lock({ window = %s })" % lua_str("address:" + a_gA))
    time.sleep(0.8)
    saved = picture()
    check("scenario group", saved["gA"]["group"] == ["gA", "gB"] and saved["gB"]["shown"] is True and saved["gA"]["shown"] is False,
          (saved["gA"]["group"], saved["gA"]["shown"], saved["gB"]["shown"]))
    rtdir = os.path.join(os.environ["XDG_RUNTIME_DIR"], "lares-session")

    # ---- the verbs ---------------------------------------------------------------------------------------------------
    rc, out, err = qs("preset", "current", "--json")
    cur = json.loads(out) if rc == 0 else {}
    check("preset current", rc == 0 and cur.get("windows") == 8 and cur.get("workspaces") == 5
          and [w["key"] for w in cur["face"]["workspaces"]] == ["1", "2", "3", "6", "special:default"]
          and cur["face"]["monitors"] and all(m["w"] > 0 for m in cur["face"]["monitors"]), (out + err)[-300:])
    rc, out, err = qs("preset", "save", "dev", "--json")
    check("preset save", rc == 0 and json.loads(out) == {"ok": True, "name": "dev", "slug": "dev"}, (rc, out, err))
    rc, out, err = qs("preset", "save", "Dev", "--json")
    check("preset save: the name exists", rc == 4 and json.loads(out) == {"ok": False, "reason": "exists"}, (rc, out, err))
    rc, out, err = qs("preset", "list", "--json")
    lst = json.loads(out) if rc == 0 else {"presets": []}
    check("preset list", rc == 0 and [(p["name"], p["windows"], p["workspaces"]) for p in lst["presets"]] == [("dev", 8, 5)], (out + err)[-300:])
    pf = os.path.join(os.environ["XDG_DATA_HOME"], "lares", "session", "presets", "dev.json")
    check("preset file", oct(os.stat(pf).st_mode & 0o777) == "0o600", oct(os.stat(pf).st_mode & 0o777))

    # ---- rearrange: two gone, one moved and maximized, one unfloated, one moved off the special workspace, two extra ----
    for t in ("bravo", "gB"):
        hy.try_dispatch("hl.dsp.window.close({ window = %s })" % lua_str("address:" + by_title(t)["address"]))
        wait(lambda t=t: not by_title(t), 6)
    hy.dispatch("hl.dsp.window.move({ workspace = \"5\", follow = false, window = %s })" % lua_str("address:" + by_title("alpha")["address"]))
    hy.dispatch("hl.dsp.window.fullscreen({ action = \"set\", mode = \"maximized\", window = %s })" % lua_str("address:" + by_title("alpha")["address"]))
    hy.dispatch("hl.dsp.window.float({ action = \"unset\", window = %s })" % lua_str("address:" + by_title("charlie")["address"]))
    hy.dispatch("hl.dsp.window.move({ workspace = \"7\", follow = false, window = %s })" % lua_str("address:" + by_title("delta")["address"]))
    hy.dispatch("hl.dsp.window.move({ x = 50, y = 60, relative = false, window = %s })" % lua_str("address:" + by_title("pinny")["address"]))
    kitty("extra", 4, cwd=dirs["extra"])
    hy.dispatch("hl.dsp.exec_cmd(%s, %s)" % (lua_str(shlex.join(["env", "GSK_RENDERER=cairo", "GTK_A11Y=none", sys.executable, refuser])),
                                             lua_table({"workspace": "4 silent", "no_initial_focus": True})))
    wait(lambda: by_title("refuser"), 20)
    time.sleep(0.5)
    check("scenario rearranged", by_title("alpha")["workspace"]["name"] == "5" and by_title("extra") and by_title("refuser")
          and not by_title("bravo") and not by_title("gB"), [(c["title"], c["workspace"]["name"]) for c in clients()])

    # a login candidate is pending: a preset load must leave it unanswered
    stp = os.path.join(os.environ["XDG_STATE_HOME"], "lares", "session", "state.json")
    os.makedirs(os.path.dirname(stp), exist_ok=True)
    json.dump({"current": {"sig": hy.sig, "bootId": "b", "hyprPid": 1, "started": time.time(), "ended": None, "restoring": None},
               "candidate": {"snapshot": None, "decision": "ask", "cause": "x", "clean": True, "answered": False}}, open(stp, "w"))

    def sampled_load(*args):
        """A load, watched: its JSON lines, and every window's workspace sampled all the way."""
        pre = {c["address"] for c in clients()}
        e = dict(os.environ, LARES_SESSION_LAUNCH_ENV=json.dumps(LAUNCH_ENV))
        p = subprocess.Popen([sys.executable, QS, "preset", "load", "dev"] + list(args) + ["--json", "--progress"], stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, env=e)
        samples, events, reveal_at, stop = [], [], [None], threading.Event()

        def sampler():
            h2 = Hypr()
            while not stop.is_set():
                try:
                    cs = [c for c in h2.json("clients") if c.get("mapped", True)]
                except Exception:
                    cs = []
                samples.append((time.monotonic(), [(c["title"], c["workspace"]["name"], c["address"] in pre) for c in cs]))
                time.sleep(0.03)

        th = threading.Thread(target=sampler, daemon=True)
        th.start()
        for line in p.stdout:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            events.append(d)
            if d.get("event") == "reveal":
                reveal_at[0] = time.monotonic()
        err = p.stderr.read()
        rc = p.wait()
        stop.set()
        th.join(timeout=3)
        res = next((d for d in reversed(events) if d.get("event") == "result"), {})
        return rc, res, events, samples, reveal_at[0], err

    def in_place(tag, titles):
        time.sleep(1.0)
        after = picture()
        for t in titles:
            a, b = after.get(t), saved[t]
            if not a:
                check("%s %s is open" % (tag, t), False, "missing")
                continue
            check("%s %s workspace" % (tag, t), a["ws"] == b["ws"], "%s, was %s" % (a["ws"], b["ws"]))
            check("%s %s floating" % (tag, t), a["floating"] == b["floating"], a["floating"])
            check("%s %s pinned" % (tag, t), a["pinned"] == b["pinned"], "%s, was %s" % (a["pinned"], b["pinned"]))
            check("%s %s fullscreen" % (tag, t), a["fullscreen"] == b["fullscreen"], "%s, was %s" % (a["fullscreen"], b["fullscreen"]))
            check("%s %s group" % (tag, t), a["group"] == b["group"], "%s, was %s" % (a["group"], b["group"]))
            if b["group"]:
                check("%s %s tab on show" % (tag, t), a["shown"] == b["shown"], "%s, was %s" % (a["shown"], b["shown"]))
            check("%s %s place" % (tag, t), all(abs(x - y) <= 3 for x, y in zip(a["at"] + a["size"], b["at"] + b["size"])),
                  "%s %s, was %s %s" % (a["at"], a["size"], b["at"], b["size"]))
        return after

    def straight(tag, samples, reveal, titles):
        """A reused window goes from where it stood to the staging workspace and from there to its place: never anywhere else in sight."""
        final = {t: saved[t]["ws"] for t in titles}
        bad = sorted({(t, ws) for _, s in samples for t, ws, old in s if t in final and old
                      and not ws.startswith("special:lsr-") and ws != final[t] and ws != "%s" % rearr.get(t)})
        check("%s: a reused window is never in sight anywhere else" % tag, not bad, bad[:4])

    # ---- --add -----------------------------------------------------------------------------------------------------
    rc, out, err = qs("preset", "load", "dev", "--add", "--dry", "--json")
    dry = json.loads(out) if rc == 0 else {}
    check("dry add", rc == 0 and dry.get("close") == [] and sorted(c["title"] for c in dry.get("reuse", [])) == ["alpha", "charlie", "delta", "gA", "maxi", "pinny"]
          and sorted(l["name"] for l in dry.get("launch", [])) == ["kitty", "kitty"] and sorted(dry) == ["close", "launch", "reuse", "skipped"],
          (out + err)[-400:])
    check("dry add: a reused entry's shape", all(sorted(c) == ["address", "class", "title"] for c in dry.get("reuse", [])), dry.get("reuse"))
    rc, out, err = qs("preset", "load", "nope", "--add", "--json")
    check("load: a missing preset is refused", rc == 4 and json.loads(out) == {"ok": False, "reason": "missing"}, (rc, out, err))
    rearr = {"alpha": "5", "charlie": "2", "delta": "7", "gA": "3", "maxi": "6", "pinny": "2"}
    rc, res, events, samples, reveal, err = sampled_load("--add")
    print("SRE load add rc=%s %s %s" % (rc, json.dumps(res)[:500], err.strip()[-300:]), flush=True)
    kinds = [d.get("event") for d in events]
    check("add: progress lines", kinds[:1] == ["start"] and "progress" in kinds and kinds[-2:] == ["reveal", "result"] and events[0].get("total") == 8, kinds[:3] + kinds[-3:])
    check("add: the result", rc == 0 and res.get("restored") == 8 and res.get("reused") == 6 and res.get("closed") == 0 and res.get("kept") == []
          and res.get("preset") == "dev" and not res.get("failed"), res)
    after = in_place("add", sorted(saved))
    straight("add", samples, reveal, ["alpha", "charlie", "delta", "gA", "maxi"])      # (a pinned window follows the active workspace)
    new_early = sorted({(t, ws) for tt, s in samples if reveal is not None and tt < reveal for t, ws, old in s
                        if t in ("bravo", "gB") and not old and not ws.startswith("special:lsr-")})
    check("add: what was started waits out of sight until the reveal", reveal is not None and not new_early, new_early[:4])
    check("add: no window twice", sorted(c["title"] for c in clients()) == sorted(list(saved) + ["extra", "refuser"]), sorted(c["title"] for c in clients()))
    ex = by_title("extra")
    check("add leaves the extra window", bool(ex) and ex["workspace"]["name"] == "4", ex and ex["workspace"])
    gl = hy.group_locks(rtdir)
    ga = by_title("gA")
    check("add: the group is locked again", bool(ga) and gl.get(ga["address"]) is True, gl)
    stt = json.load(open(stp))
    check("add: the login candidate stays unanswered", (stt.get("candidate") or {}).get("answered") is False, stt.get("candidate"))
    r_ = (stt.get("current") or {}).get("restoring") or {}
    check("add: current.restoring names the preset and is done", r_.get("preset") == "dev" and r_.get("done") is not None and "snapshot" not in r_, r_)

    # ---- --replace ---------------------------------------------------------------------------------------------------
    hy.dispatch("hl.dsp.window.move({ workspace = \"4\", follow = false, window = %s })" % lua_str("address:" + by_title("charlie")["address"]))
    time.sleep(0.5)
    rearr = {"alpha": "1", "charlie": "4", "delta": "special:default", "gA": "3", "maxi": "6", "pinny": "2"}
    rc, out, err = qs("preset", "load", "dev", "--replace", "--dry", "--json")
    dry = json.loads(out) if rc == 0 else {}
    check("dry replace: exactly what would close", rc == 0 and sorted(c["title"] for c in dry.get("close", [])) == ["extra", "refuser"]
          and dry.get("launch") == [] and len(dry.get("reuse", [])) == 8, (out + err)[-400:])
    rc, res, events, samples, reveal, err = sampled_load("--replace")
    print("SRE load replace rc=%s %s %s" % (rc, json.dumps(res)[:500], err.strip()[-300:]), flush=True)
    check("replace: the result", rc == 0 and res.get("reused") == 8 and res.get("closed") == 1 and not res.get("failed")
          and res.get("kept") == [{"class": "stub.refuse", "title": "refuser"}] and res.get("restored") == 8, res)
    after = in_place("replace", sorted(saved))
    straight("replace", samples, reveal, [t for t in sorted(saved) if t != "pinny"])
    check("replace closed the extra window", by_title("extra") is None, by_title("extra"))
    check("replace left a window that refused to close", by_title("refuser") is not None, [c["title"] for c in clients()])
    check("replace: one reveal", [d.get("event") for d in events].count("reveal") == 1, [d.get("event") for d in events])
    check("replace: nothing is left staged", not [c for c in clients() if c["workspace"]["name"].startswith("special:lsr-")],
          [(c["title"], c["workspace"]["name"]) for c in clients() if c["workspace"]["name"].startswith("special:lsr-")])
    gl = hy.group_locks(rtdir)
    ga = by_title("gA")
    check("replace: the group is locked again", bool(ga) and gl.get(ga["address"]) is True, gl)


try:
    if os.environ.get("SRE_PRESET"):
        main_preset()
    else:
        main()
except SystemExit:
    raise
except Exception as e:  # a throwing step is a failed check, never a run without a verdict
    import traceback
    traceback.print_exc()
    check("driver", False, repr(e))
print("SESSION_ENV RESULT %s%s" % ("FAIL" if fails else "PASS", " (%d: %s)" % (len(fails), ", ".join(fails[:6])) if fails else ""))
sys.exit(1 if fails else 0)
