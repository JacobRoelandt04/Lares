#!/usr/bin/env python3
"""The driver of tools/dev/curtain_repaint_env_probe.sh: run INSIDE the lock_env, with the real shell.qml (mock services) up.

argv: <sandbox> (the tree the shell runs from)

The session is hidden_repaint_env_probe's (two outputs, hidden workspaces, a special one, groups, kitty / Qt / GTK 4). Every
window's colour changes as a theme switch changes it, the theme button is right-clicked with the virtual pointer, and the shell's
own curtain does the rest. Checked: one curtain run, no drop, NO FAST-FORWARD (the repaint's own workspace changes are not
triggers), the tool ran once and said ok, the focus the bars read was published NOT ONCE during the run, the session is where it
was, and a film of every hidden thing shown afterwards holds no stale frame.
Prints `CURTAIN_REPAINT RESULT PASS|FAIL ...` last.
"""
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hidden_repaint_env_probe as H  # noqa: E402

SB = sys.argv[1]
SHELL_QML = os.path.join(SB, "shell.qml")
B = os.environ["LOCK_ENV_DIR"]


def probe():
    t = ""
    for _ in range(8):
        t = subprocess.run(["quickshell", "ipc", "-p", SHELL_QML, "call", "shell", "probe"], capture_output=True, text=True, timeout=20).stdout
        try:
            return json.loads(t)
        except ValueError:
            time.sleep(0.3)
    raise SystemExit("CURTAIN_REPAINT RESULT FAIL (no probe answer: %s)" % t[:200])


def point(*lines):
    with open(os.path.join(B, "vpointer.fifo"), "w") as f:
        f.write("\n".join(lines) + "\n")


def debug_switch(sess, before, st0, point, w, h):
    """CR_MODE=debug (shell.jsonc "curtainRepaintDebug": true): the click switches the theme with NO curtain, then the repaint runs
    slowed and named; the bar is not held; the session ends where it was."""
    H.switch_colours(sess)
    time.sleep(0.3)
    point("rclick")
    t0, st1, held = time.time(), st0, False
    while time.time() - t0 < 40:
        st1 = probe()
        held = held or st1["curtain"]["repaintHeld"]
        if st1["curtain"]["repaintRuns"] > st0["curtain"]["repaintRuns"] and st1["curtain"]["repaintLast"] != "":
            break
        time.sleep(0.1)
    time.sleep(0.8)
    st1 = probe()
    c0, c1 = st0["curtain"], st1["curtain"]
    print("  after: curtain %s, mode %s" % (json.dumps(c1), st1["themeMode"]), flush=True)
    H.check("the theme switched", st1["themeMode"] != st0["themeMode"], st1["themeMode"])
    H.check("no curtain ran", c1["runs"] == c0["runs"], str(c1["runs"]))
    H.check("the repaint ran once, as a debug run", c1["repaintRuns"] == c0["repaintRuns"] + 1 and c1["repaintLast"].startswith("REPAINT ok")
            and " debug=300" in c1["repaintLast"], c1["repaintLast"])
    H.check("the bar was not held (it shows where the run is)", not held and st1["focusPublished"] > st0["focusPublished"],
            "held %s, published %d -> %d" % (held, st0["focusPublished"], st1["focusPublished"]))
    after = H.snapshot()
    for k in before:
        H.check("state: " + k, before[k] == after[k], "%s -> %s" % (before[k], after[k]))
    bad = [c for c in H.checks if not c[1]]
    print("CURTAIN_REPAINT RESULT %s %d checks (debug: %s)%s" % ("FAIL" if bad else "PASS", len(H.checks), c1["repaintLast"],
                                                                 (" failed: " + "; ".join(c[0] for c in bad)) if bad else ""))
    return 1 if bad else 0


def main():
    sess = H.build_session()
    time.sleep(1.5)
    st = probe()
    mons = json.loads(H.hy("-j", "monitors"))
    x0, y0 = min(m["x"] for m in mons), min(m["y"] for m in mons)
    w = max(m["x"] + m["width"] for m in mons) - x0
    h = max(m["y"] + m["height"] for m in mons) - y0
    s = st["screens"]["LOCK-1"]
    bar = ([b for b in s["bars"] if b["id"] == "topL"] or [b for b in s["bars"] if b["id"] == "top"])[0]
    p = s["placed"]["theme"]
    bx, by = round(bar["rawPos"] + p["x"] + p["width"] / 2), 20
    m1 = [m for m in mons if m["name"] == "LOCK-1"][0]
    ax, ay = m1["x"] - x0 + bx, m1["y"] - y0 + by
    # the pointer rests on the theme button BEFORE the state is read: where it stands is part of the state
    point("abs %d %d %d %d" % (ax - 3, ay, w, h), "sleep 80", "abs %d %d %d %d" % (ax, ay, w, h))
    time.sleep(0.8)
    before = H.snapshot()
    st0 = probe()
    print("  before: curtain %s, mode %s, focus published %d" % (json.dumps(st0["curtain"]), st0["themeMode"], st0["focusPublished"]), flush=True)
    if os.environ.get("CR_MODE") == "debug":
        return debug_switch(sess, before, st0, point, w, h)
    H.switch_colours(sess)
    time.sleep(0.3)
    # LOCK-2 is filmed through the run: workspace 2 is one kitty over the whole output, workspace 4 two windows with the wallpaper
    # in the gap between them, so the wallpaper's blue in the middle column is workspace 4 SEEN -- a hop showing through the curtain
    mp4, frames = os.path.join(H.WORK, "run.mp4"), os.path.join(H.WORK, "fr_run")
    subprocess.run(["rm", "-rf", mp4, frames]); os.makedirs(frames)
    rec = subprocess.Popen(["wf-recorder", "-o", "LOCK-2", "-f", mp4, "-c", "libx264rgb", "-p", "crf=0"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)
    point("rclick")
    phases, t0, st1 = [], time.time(), st0
    while time.time() - t0 < 30:
        st1 = probe()
        ph = st1["curtain"]["phase"] + ("+held" if st1["curtain"]["repaintHeld"] else "")
        if not phases or phases[-1] != ph:
            phases.append(ph)
        if st1["curtain"]["runs"] > st0["curtain"]["runs"] and st1["curtain"]["phase"] == "idle":
            break
        time.sleep(0.05)
    time.sleep(0.6)
    rec.send_signal(2)
    try:
        rec.wait(timeout=6)
    except subprocess.TimeoutExpired:
        rec.kill()
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", mp4, "-vf", "scale=iw/4:ih/4:flags=neighbor", "-fps_mode", "passthrough",
                    os.path.join(frames, "%06d.png")], stderr=subprocess.DEVNULL)
    from PIL import Image
    import glob
    m2 = [m for m in mons if m["name"] == "LOCK-2"][0]
    seen = ""
    for fr in sorted(glob.glob(frames + "/*.png")):
        r, g, b = Image.open(fr).convert("RGB").getpixel((m2["width"] // 8, m2["height"] // 8))
        seen += "L" if (b > r + 50 and b > 120) else ("W" if min(r, g, b) > 200 else ("b" if max(r, g, b) < 60 else "."))
    print("  LOCK-2's middle through the run (b the window, L the hidden workspace seen): %s" % seen, flush=True)
    st1 = probe()
    c0, c1 = st0["curtain"], st1["curtain"]
    print("  phases seen: %s" % " > ".join(phases), flush=True)
    print("  after: curtain %s, mode %s, focus published %d" % (json.dumps(c1), st1["themeMode"], st1["focusPublished"]), flush=True)
    H.check("the click ran one curtain", c1["runs"] == c0["runs"] + 1 and c1["phase"] == "idle", json.dumps(c1))
    H.check("the theme switched", st1["themeMode"] != st0["themeMode"], st1["themeMode"])
    H.check("the curtain was not dropped", c1["drops"] == c0["drops"], str(c1["drops"]))
    H.check("no fast-forward: the repaint's workspace changes are not triggers", c1["fastForwards"] == c0["fastForwards"], str(c1["fastForwards"]))
    H.check("the repaint ran once", c1["repaintRuns"] == c0["repaintRuns"] + 1, str(c1["repaintRuns"]))
    H.check("the tool said ok", c1["repaintLast"].startswith("REPAINT ok"), c1["repaintLast"])
    fl = [int(x) for x in c1["repaintLast"].split(" frames=")[1].split()[0].split(",")] if " frames=" in c1["repaintLast"] else []
    if os.environ.get("CR_MODE") == "long":
        H.check("every step had the 60 frames asked (a run past the old fixed 4 s)", fl != [] and all(f == 60 for f in fl), str(fl))
    else:
        # the runner's shell.jsonc: { "K3B": 30 } -- the step that shows that kitty 30 frames, every other the default 3
        H.check("the class table reached the tool: K3B's step 30 frames, the others 3", fl.count(30) == 1 and all(f == 3 for f in fl if f != 30),
                str(fl))
    # (the probe's windows turn black BEFORE the click, so the curtain's picture is black there too: no W is expected)
    H.check("the run was filmed", len(seen) >= 8 and "b" in seen, seen)
    H.check("nothing shows through the curtain", "L" not in seen, seen)
    H.check("the bars' focus held still", st1["focusPublished"] == st0["focusPublished"],
            "%d -> %d" % (st0["focusPublished"], st1["focusPublished"]))
    after = H.snapshot()
    for k in before:
        H.check("state: " + k, before[k] == after[k], "%s -> %s" % (before[k], after[k]))
    point("abs %d %d %d %d" % (700, 900, w, h))        # off the bar: the film's dispatches warp it anyway
    H.films(sess)
    bad = [c for c in H.checks if not c[1]]
    print("CURTAIN_REPAINT RESULT %s %d checks, the run took %d ms (%s)%s" % (
        "FAIL" if bad else "PASS", len(H.checks), c1["lastMs"], c1["repaintLast"],
        (" failed: " + "; ".join(c[0] for c in bad)) if bad else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
