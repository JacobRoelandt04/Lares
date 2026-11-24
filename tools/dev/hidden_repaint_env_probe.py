#!/usr/bin/env python3
"""The driver of tools/dev/hidden_repaint_env_probe.sh: run INSIDE a lock_env that is up (two outputs).

It builds a session like the user's -- two monitors, shown and hidden workspaces, a special one, groups with hidden tabs,
kitty / Qt / GTK 4 windows that were all VISIBLE once (a window launched silently on a hidden workspace is never suspended
and proves nothing) --, changes every window's colour from white to black the way a theme switch does, runs
tools/theme/hidden_repaint.py, and then

  state     the session is exactly where it was: each monitor's workspace and special workspace, every group's tab, the
            focused window, the pointer, the animation switch
  film      every hidden workspace and tab is then shown in turn while each output is filmed: no frame may hold a white
            window (a stale picture)
  events    what Hyprland said on its event socket during the run (printed; the curtain must ignore exactly these)

ARM=norun skips the tool: the film must then show stale frames, or the film proves nothing.
Prints `HIDDEN_REPAINT RESULT PASS|FAIL ...` last.
"""
import glob
import json
import os
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIX = os.path.join(ROOT, "tools/dev/fixtures/hidden_repaint")
TOOL = os.environ.get("HR_TOOL") or os.path.join(ROOT, "tools/theme/hidden_repaint.py")
B = os.environ["LOCK_ENV_DIR"]
WORK = os.path.join(B, "hr")
ARM = os.environ.get("ARM", "")
FRAMES = os.environ.get("HR_FRAMES", "3")
checks = []


def check(name, ok, detail=""):
    checks.append((name, bool(ok), detail))
    print("  %s %s%s" % ("ok  " if ok else "FAIL", name, (": " + detail) if detail and not ok else ""), flush=True)


def hy(*args, timeout=30):
    return subprocess.run(["hyprctl", *args], capture_output=True, text=True, timeout=timeout).stdout


def D(expr):
    out = hy("dispatch", expr).strip()
    if out != "ok":
        print("  dispatch %s -> %s" % (expr, out[:200]))
    return out


def ev(lua):
    return hy("eval", lua).strip()


def clients():
    return json.loads(hy("-j", "clients"))


def ident(c):
    return c["class"] if c["class"].startswith("k") else c["title"]


def find(name):
    for c in clients():
        if ident(c) == name:
            return c
    return None


def wait_for(name, t=25):
    end = time.time() + t
    while time.time() < end:
        c = find(name)
        if c and c.get("mapped", True) and c["size"][0] > 10:
            return c
        time.sleep(0.2)
    raise SystemExit("HIDDEN_REPAINT RESULT FAIL (window %s never came)" % name)


def launch(kind, name):
    flag = os.path.join(WORK, "flag")
    if kind == "kitty":
        cmd = "kitty --class %s" % name
    elif kind == "qt":
        cmd = "env QT_QPA_PLATFORM=wayland QML_XHR_ALLOW_FILE_READ=1 /usr/lib/qt6/bin/qml %s/flagwin.qml -- %s %s" % (FIX, name, flag)
    else:
        cmd = "env GSK_RENDERER=ngl python3 %s/flagwin_gtk.py %s %s" % (FIX, name, flag)
    D("hl.dsp.exec_cmd('%s')" % cmd)
    return wait_for(name)


def lua_read(expr):
    """The value of a Lua expression, as text (an eval returns no value: it is written to a file)."""
    path = os.path.join(WORK, "val")
    if os.path.exists(path):
        os.unlink(path)
    ev('local f = io.open("%s", "w"); f:write(tostring(%s)); f:close()' % (path, expr))
    for _ in range(100):
        if os.path.exists(path):
            return open(path).read()
        time.sleep(0.02)
    return "?"


def snapshot():
    mons = json.loads(hy("-j", "monitors"))
    cls = clients()
    s = {
        "workspaces": {m["name"]: m["activeWorkspace"]["name"] for m in mons},
        "specials": {m["name"]: m["specialWorkspace"]["name"] for m in mons},
        "focusedMonitor": [m["name"] for m in mons if m["focused"]],
        "window": ident(json.loads(hy("-j", "activewindow")) or {"class": "", "title": ""}) if hy("-j", "activewindow").strip() not in ("", "{}") else "",
        "cursor": json.loads(hy("-j", "cursorpos")),
        "tabs": sorted(ident(c) for c in cls if c.get("grouped") and len(c["grouped"]) > 1 and c.get("visible")),
        "animations": lua_read('hl.get_config("animations:enabled")'),
        "no_warps": lua_read('hl.get_config("cursor:no_warps")'),
        "where": sorted((ident(c), c["workspace"]["name"]) for c in cls),
    }
    return s


def kitty_pids():
    out = []
    for p in glob.glob("/proc/[0-9]*"):
        try:
            if open(p + "/comm").read().strip() != "kitty":
                continue
            if ("LOCK_ENV_DIR=" + B).encode() in open(p + "/environ", "rb").read().split(b"\0"):
                out.append(int(p[6:]))
        except OSError:
            pass
    return out


def film(output, name, actions, gap=0.7):
    """Record one output while the actions run; returns the frames (downscaled 4x) as PIL images."""
    from PIL import Image
    mp4 = os.path.join(WORK, name + ".mp4")
    frames = os.path.join(WORK, "fr_" + name)
    subprocess.run(["rm", "-rf", mp4, frames])
    os.makedirs(frames)
    rec = subprocess.Popen(["wf-recorder", "-o", output, "-f", mp4, "-c", "libx264rgb", "-p", "crf=0"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    for a in actions:
        D(a)
        time.sleep(gap)
    time.sleep(0.6)
    rec.send_signal(signal.SIGINT)
    try:
        rec.wait(timeout=6)
    except subprocess.TimeoutExpired:
        rec.kill()
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", mp4, "-vf", "scale=iw/4:ih/4:flags=neighbor", "-fps_mode", "passthrough",
                    os.path.join(frames, "%06d.png")], stderr=subprocess.DEVNULL)
    return [Image.open(f).convert("L") for f in sorted(glob.glob(frames + "/*.png"))]


def stale(frames, points):
    """Per sample point, the frames' letters: W a white (stale) window, b anything else."""
    out = {}
    for name, (x, y) in points.items():
        out[name] = "".join("W" if f.getpixel((min(f.width - 1, x // 4), min(f.height - 1, y // 4))) > 200 else "b" for f in frames)
    return out


def build_session():
    """The session of the header; returns what the later steps need."""
    os.makedirs(WORK, exist_ok=True)
    kc = os.path.join(os.environ["XDG_CONFIG_HOME"], "kitty")
    os.makedirs(kc, exist_ok=True)
    open(kc + "/kitty.conf", "w").write("include current-theme.conf\nremember_window_size no\nconfirm_os_window_close 0\n")
    open(kc + "/current-theme.conf", "w").write("background #ffffff\nforeground #000000\n")
    mons = {m["name"]: m for m in json.loads(hy("-j", "monitors"))}
    if "LOCK-2" not in mons:
        raise SystemExit("HIDDEN_REPAINT RESULT FAIL (needs OUTPUTS=2)")
    ev('hl.workspace_rule({ workspace = "2", monitor = "LOCK-2" }); hl.workspace_rule({ workspace = "4", monitor = "LOCK-2" })')
    ev('hl.workspace_rule({ workspace = "1", monitor = "LOCK-1" }); hl.workspace_rule({ workspace = "3", monitor = "LOCK-1" })')
    # the user's own switches that matter here: windows and the special workspace animate, workspaces do not
    ev('hl.config({ animations = { enabled = true } }); hl.animation({ leaf = "workspaces", enabled = false })')

    print("building the session", flush=True)
    # LOCK-2: workspace 4 (hidden later): a Qt window and a kitty; workspace 2 (shown): a kitty
    D('hl.dsp.focus({ workspace = 4 })'); launch("qt", "q4"); launch("kitty", "k4")
    D('hl.dsp.focus({ workspace = 2 })'); launch("kitty", "k2")
    # LOCK-1: the special workspace: a kitty
    D('hl.dsp.focus({ workspace = 1 })')
    D('hl.dsp.workspace.toggle_special("default")'); launch("kitty", "ks"); D('hl.dsp.workspace.toggle_special("default")')
    # LOCK-1: workspace 3 (hidden later): a GTK window, and a group of two kittys
    D('hl.dsp.focus({ workspace = 3 })'); launch("gtk", "g3")
    a = launch("kitty", "k3a"); D("hl.dsp.group.toggle({ window = 'address:%s' })" % a["address"]); launch("kitty", "k3b")
    D("hl.dsp.group.active({ index = 1, window = 'address:%s' })" % a["address"])
    # LOCK-1: workspace 1 (shown): a group of kitty, Qt, kitty with the first on show
    D('hl.dsp.focus({ workspace = 1 })')
    a1 = launch("kitty", "k1a"); D("hl.dsp.group.toggle({ window = 'address:%s' })" % a1["address"])
    launch("qt", "q1"); launch("kitty", "k1b")
    D("hl.dsp.group.active({ index = 1, window = 'address:%s' })" % a1["address"])
    D("hl.dsp.focus({ window = 'address:%s' })" % a1["address"])
    D("hl.dsp.cursor.move({ x = 700, y = 600 })")
    time.sleep(1.0)
    geo = {ident(c): (c["at"], c["size"], c["workspace"]["name"], c["monitor"]) for c in clients()}
    return {"geo": geo, "mons": mons, "kc": kc, "a1": a1, "a": a}


def switch_colours(sess):
    """The theme switch as the apps see it: every window turns black."""
    open(sess["kc"] + "/current-theme.conf", "w").write("background #000000\nforeground #ffffff\n")
    for p in kitty_pids():
        os.kill(p, signal.SIGUSR1)
    open(os.path.join(WORK, "flag"), "w").write("1")


def interrupted(sess):
    """HR_MODE=interrupt: the user changes workspace while the run is under way. The run must STOP: the user's workspace stands
    (nothing is yanked back), the tabs and the two switches the run turned are put back, and the tool says so."""
    before = snapshot()
    switch_colours(sess)
    time.sleep(0.6)
    tool = subprocess.Popen(["python3", TOOL, "run", "--frames", "12"], stdout=subprocess.PIPE, text=True)   # 200 ms a step
    time.sleep(0.27)                                                        # in the second step: LOCK-1 shows workspace 1
    D('hl.dsp.focus({ workspace = 3 })')                                    # the user
    out = tool.communicate(timeout=30)[0].strip()
    line = (out.splitlines() or ["(no output)"])[-1]
    print("  %s" % line, flush=True)
    time.sleep(0.5)
    after = snapshot()
    check("the tool says it stopped", line.startswith("REPAINT stopped"), line)
    check("the user's workspace stands", after["workspaces"].get("LOCK-1") == "3", str(after["workspaces"]))
    for k in ("tabs", "animations", "no_warps", "specials", "where"):
        check("state: " + k, before[k] == after[k], "%s -> %s" % (before[k], after[k]))
    bad = [c for c in checks if not c[1]]
    print("HIDDEN_REPAINT RESULT %s %d checks (interrupt)%s" % ("FAIL" if bad else "PASS", len(checks),
                                                                (" failed: " + "; ".join(c[0] for c in bad)) if bad else ""))
    return 1 if bad else 0


def debug_run(sess):
    """HR_MODE=debug: the slowed run a person watches (`--debug-ms`): every step that long, the session put back as ever."""
    before = snapshot()
    t0 = time.time()
    r = subprocess.run(["python3", TOOL, "run", "--debug-ms", "400"], capture_output=True, text=True, timeout=60)
    line = (r.stdout.strip().splitlines() or ["(no output)"])[-1]
    took = (time.time() - t0) * 1000
    print("  %s   (wall %d ms)" % (line, took), flush=True)
    steps = int(line.split("steps=")[1].split()[0]) if "steps=" in line else 0
    check("the debug run says ok and that it was one", line.startswith("REPAINT ok") and " debug=400" in line, line)
    check("every step stayed the debug time", steps > 0 and took >= steps * 400, "%d steps, %d ms" % (steps, took))
    chunk = open(os.path.join(os.environ["XDG_RUNTIME_DIR"], "lares", "repaint.lua")).read()
    check("the steps are named for the notice, with their frames",
          "local DEBUG = true" in chunk and "workspace 3: " in chunk and "tab 2: " in chunk and ' 3 frames"' in chunk, "")
    time.sleep(0.4)
    after = snapshot()
    for k in before:
        check("state: " + k, before[k] == after[k], "%s -> %s" % (before[k], after[k]))
    bad = [c for c in checks if not c[1]]
    print("HIDDEN_REPAINT RESULT %s %d checks (debug)%s" % ("FAIL" if bad else "PASS", len(checks),
                                                            (" failed: " + "; ".join(c[0] for c in bad)) if bad else ""))
    return 1 if bad else 0


def vscode():
    """HR_MODE=vscode: a REAL VS Code (a private profile in the env) as a hidden tab of a group. It needs ~0.1 s on show to draw
    its new colours where kitty needs a frame, so its CLASS gets frames of its own (`--class <its class>=HR_VSCODE_FRAMES`, 16)
    while every other window gets one. The write comes 0.7 s before the run, as on the desktop (themectl writes VS Code's setting
    second of its ~0.6 s run; the curtain starts the repaint ~0.15 s after the run).
    HR_VSCODE_FRAMES= (empty: the arm `noclassframes`) gives VS Code the one frame of the rest: the tab must then come back stale."""
    import shutil
    if not shutil.which("code"):
        print("HIDDEN_REPAINT RESULT FAIL (no `code` on this machine: the VS Code check cannot run)")
        return 1
    os.makedirs(WORK, exist_ok=True)
    ud, ed, wd = B + "/vsc/ud", B + "/vsc/ext", B + "/vsc/work"
    for d in (ud + "/User", ed, wd):
        os.makedirs(d, exist_ok=True)
    now = ["Default Light Modern"]

    def theme(name):
        now[0] = name
        open(ud + "/User/settings.json", "w").write(json.dumps({
            "workbench.colorTheme": name, "workbench.startupEditor": "none", "security.workspace.trust.enabled": False,
            "telemetry.telemetryLevel": "off", "update.mode": "none", "window.restoreWindows": "none"}, indent=2))
    theme(now[0])
    kc = os.path.join(os.environ["XDG_CONFIG_HOME"], "kitty")
    os.makedirs(kc, exist_ok=True)
    open(kc + "/kitty.conf", "w").write("background #808080\nremember_window_size no\nconfirm_os_window_close 0\n")
    ev('hl.config({ animations = { enabled = false } })')
    a = launch("kitty", "ka")
    D("hl.dsp.group.toggle({ window = 'address:%s' })" % a["address"])
    D("hl.dsp.exec_cmd('code --user-data-dir %s --extensions-dir %s --ozone-platform=wayland --new-window %s')" % (ud, ed, wd))
    code = None
    for _ in range(200):
        cs = [c for c in clients() if "code" in c["class"].lower()]
        if cs and cs[0]["size"][0] > 10:
            code = cs[0]
            break
        time.sleep(0.2)
    if not code:
        print("HIDDEN_REPAINT RESULT FAIL (VS Code's window never came)")
        return 1
    time.sleep(8)                                              # its workbench's first paint
    D("hl.dsp.group.active({ index = 1, window = 'address:%s' })" % a["address"])
    time.sleep(1.0)
    vs_frames = os.environ.get("HR_VSCODE_FRAMES", "16")
    argv = ["python3", TOOL, "run", "--frames", "1"] + (["--class", "%s=%s" % (code["class"], vs_frames)] if vs_frames else [])
    rounds = []
    for rnd in range(3):
        want_dark = now[0].startswith("Default Light")
        theme("Default Dark Modern" if want_dark else "Default Light Modern")
        time.sleep(0.7)
        r = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        line = (r.stdout.strip().splitlines() or ["(no output)"])[-1]
        time.sleep(1.5)
        frames = film("LOCK-1", "vs%d" % rnd, ["hl.dsp.group.active({ index = 2, window = 'address:%s' })" % a["address"]], gap=1.5)
        seq = ""
        for f in frames:
            w, h = f.size
            c = f.crop((w // 2, h // 3, w // 2 + 10, h // 3 + 10))
            v = sum(c.getdata()) / 100.0
            seq += "W" if v > 200 else ("d" if v < 70 else ".")
        stale = seq.count("W" if want_dark else "d")
        rounds.append(stale)
        print("  round %d: %s   then shown: %s -> %d stale frames" % (rnd + 1, line, seq[:60], stale), flush=True)
        check("round %d: the tool says ok" % (rnd + 1), line.startswith("REPAINT ok"), line)
        if vs_frames:
            check("round %d: VS Code's tab was given its frames" % (rnd + 1), ("frames=%s " % vs_frames) in line, line)
        check("round %d: the film saw VS Code" % (rnd + 1), ("d" if want_dark else "W") in seq, seq[:80])
        D("hl.dsp.group.active({ index = 1, window = 'address:%s' })" % a["address"])
        time.sleep(1.0)
    check("VS Code comes back in the new colours, three rounds", sum(rounds) == 0, "stale frames per round: %s" % rounds)
    # VS Code's helper processes outlive the env's own sweep (they do not all keep its marker): end the ones of THIS profile
    for pdir in glob.glob("/proc/[0-9]*"):
        try:
            if ("--user-data-dir\0" + ud).encode() in open(pdir + "/cmdline", "rb").read() or ("--user-data-dir=" + ud).encode() in open(pdir + "/cmdline", "rb").read():
                os.kill(int(pdir[6:]), signal.SIGTERM)
        except (OSError, ValueError):
            pass
    bad = [c for c in checks if not c[1]]
    print("HIDDEN_REPAINT RESULT %s %d checks (vscode)%s" % ("FAIL" if bad else "PASS", len(checks),
                                                             (" failed: " + "; ".join(c[0] for c in bad)) if bad else ""))
    return 1 if bad else 0


def main():
    if os.environ.get("HR_MODE") == "vscode":
        return vscode()
    sess = build_session()
    if os.environ.get("HR_MODE") == "interrupt":
        return interrupted(sess)
    if os.environ.get("HR_MODE") == "debug":
        return debug_run(sess)
    before = snapshot()
    print("  session: %s" % json.dumps({k: before[k] for k in ("workspaces", "specials", "window", "tabs")}), flush=True)
    switch_colours(sess)
    time.sleep(0.6)

    # ---- the tool
    sock = subprocess.Popen(["sh", "-c",
                             "exec socat -u UNIX-CONNECT:$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -"],
                            stdout=open(os.path.join(WORK, "events"), "w"), stderr=subprocess.DEVNULL)
    time.sleep(0.4)
    line = "(not run)"
    if ARM != "norun":
        t0 = time.time()
        r = subprocess.run(["python3", TOOL, "run", "--frames", FRAMES], capture_output=True, text=True, timeout=60)
        line = (r.stdout.strip().splitlines() or ["(no output) " + r.stderr[-300:]])[-1]
        print("  %s   (wall %d ms, exit %d)" % (line, (time.time() - t0) * 1000, r.returncode), flush=True)
        check("the tool says ok", line.startswith("REPAINT ok"), line)
        check("the pointer never moved during the run", " warp=0 " in line, line)
    time.sleep(0.4)
    sock.terminate()
    names = {}
    for ln in open(os.path.join(WORK, "events")):
        names[ln.split(">>")[0]] = names.get(ln.split(">>")[0], 0) + 1
    print("  events during the run: %s" % json.dumps(names), flush=True)

    # ---- the session is where it was
    after = snapshot()
    for k in before:
        check("state: " + k, before[k] == after[k], "%s -> %s" % (before[k], after[k]))

    films(sess)
    bad = [c for c in checks if not c[1]]
    print("HIDDEN_REPAINT RESULT %s %d checks%s" % ("FAIL" if bad else "PASS", len(checks),
                                                    (" failed: " + "; ".join(c[0] for c in bad)) if bad else ""))
    return 1 if bad else 0


def films(sess):
    """Show every hidden thing while each output is filmed: no white frame anywhere."""
    geo, mons, a1, a = sess["geo"], sess["mons"], sess["a1"], sess["a"]
    ev('hl.config({ animations = { enabled = false } })')          # a slide would move the sample points
    def centre(name, origin):
        (x, y), (w, h), _, _ = geo[name]
        # a third in, not the middle: a focus dispatch warps the pointer to the window's middle, and its glyph is white
        return (x - origin[0] + w // 3, y - origin[1] + h // 3)
    o1, o2 = (mons["LOCK-1"]["x"], mons["LOCK-1"]["y"]), (mons["LOCK-2"]["x"], mons["LOCK-2"]["y"])
    f1 = film("LOCK-1", "l1", [
        "hl.dsp.group.active({ index = 2, window = 'address:%s' })" % a1["address"],
        "hl.dsp.group.active({ index = 3, window = 'address:%s' })" % a1["address"],
        "hl.dsp.workspace.toggle_special('default')",
        "hl.dsp.workspace.toggle_special('default')",
        "hl.dsp.focus({ workspace = 3 })",
        "hl.dsp.group.active({ index = 2, window = 'address:%s' })" % a["address"],
    ])
    s1 = stale(f1, {n: centre(n, o1) for n in ("k1a", "ks", "g3", "k3a")})
    f2 = film("LOCK-2", "l2", ["hl.dsp.focus({ workspace = 4 })"])
    s2 = stale(f2, {n: centre(n, o2) for n in ("q4", "k4")})
    print("  film LOCK-1 (%d frames): %s" % (len(f1), s1), flush=True)
    print("  film LOCK-2 (%d frames): %s" % (len(f2), s2), flush=True)
    check("the films hold frames", len(f1) >= 6 and len(f2) >= 2, "%d / %d" % (len(f1), len(f2)))
    labels = {"k1a": "the shown group's hidden tabs (kitty, Qt)", "ks": "the special workspace (kitty)",
              "g3": "a hidden workspace (GTK)", "k3a": "a hidden workspace's group and its hidden tab (kitty)",
              "q4": "the other monitor's hidden workspace (Qt)", "k4": "the other monitor's hidden workspace (kitty)"}
    for n, seq in list(s1.items()) + list(s2.items()):
        check("no stale frame: " + labels[n], "W" not in seq, seq)


if __name__ == "__main__":
    sys.exit(main())
