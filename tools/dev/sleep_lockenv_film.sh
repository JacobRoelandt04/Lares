#!/usr/bin/env bash
# sleep_lockenv_film.sh -- a film of the REAL sleep fade over a REAL lock, SEVERAL SLEEPS IN ONE SHELL PROCESS, in the isolated Hyprland
# of tools/dev/lock_env.sh (env `slpfilm`, one 2880 x 1620 output): tools/dev/qml/sleep_lockenv_film.qml holds SleepFade, its SleepVeil
# windows and a LockOwner as the shell does, against a stand-in logind on the env's private bus and stub systemd-inhibit / brightnessctl
# over a fake sysfs (nothing of the machine is read or written). Each sleep is the user's: the inhibitor is held, PrepareForSleep(true),
# the lock starts at that moment (as hypridle's before_sleep_cmd starts it: the tree copy's supervisor + lock, PAM stub), its veil rises,
# the screen falls asleep, the release, 1.5 s "asleep", PrepareForSleep(false) over a panel the kernel relit, the climb back; then the
# runner unlocks (the stub's password) and the next sleep follows. grim films the output throughout (tools/dev/sleep_film_sample.py).
#
#   tools/dev/sleep_lockenv_film.sh <outdir>   ends in SLEEP_LOCKENV_FILM RESULT PASS|FAIL; <outdir>/lockenv_film.png (the strip)
#   CYCLES=<n>      sleeps in the one process (default 2: the second is the one a first fade can spoil -- the user's "black screen"
#                   came on every suspend after some first one, until the shell restarted)
#   MODE=dark       the env's theme
#   VEIL_HOUR=<h>   the lock veil's hour of day, pinned (default 12: the relief veil is lit by the real sky, and at night its rise
#                   is a lit disc on a dark field -- check L read that as a dark frame at 21:00)
#   ARM=emptypic    every capture the veil takes is EMPTY (the copy draws nothing: the ScreencopyView's frame never reaches the
#                   texture), the fault the user saw. With the picture check the veil goes on without a picture and P passes; with
#                   ARM=emptypic,nocheck (the check removed) the fall and the climb draw BLACK and P must FAIL.
#   ARM=nocheck     (with emptypic) the picture check removed: SleepVeil takes any copy as a picture, as it did
#   ARM=emptys0     the LOCK's S0 is empty (DesktopLayer copies nothing): with its check the veil rises over the live desktop and L
#                   passes, the lock log says `S0 empty`; ARM=emptys0,nos0check (the lock's check removed) shows black and L must FAIL
#   HOP=1           between two sleeps a headless output LARESLOCK-HOP is added and removed again, as the lock's keyboard hop does 3-4 s
#                   after every resume of the user's session (tools/lockscreen/lares-lock-hop): what the shell's veils see of it
#   LOGRULES=<rules> QT_LOGGING_RULES for the shell's part (quickshell.wayland.buffer*.debug=true: which buffer each capture gets)
#   ARM=slowxray    Hyprland applies the lock's prepareLock (xray on) 250 ms late: a lock that asks before it has been applied shows
#                   its clear first frames over NOTHING (black) until it lands -- L must stay green (the lock waits for it)
#   ARM=lates0      the lock's S0 reaches the screen 300 ms after the frames it counted (as a commit the compositor holds for its
#                   fence does): L must stay green (xray goes off once the veil is up, not on the count)
#   TRACE=1         the lock logs its desktop layer's steps and every compositor call (asked / applied) with wall-clock times
#   STILL=<p>       THE BEFORE/AFTER: one sleep, no lock, a picture taken anyway, the dither's seed fixed and the veil's progress held at
#                   <p> through the fall and the climb, over the env's still desktop: <outdir>/still_fall.png and still_rise.png are the
#                   output as drawn (full size), the same to the pixel from run to run. SLEEPFILM_MODULES=<tree> lays that tree's
#                   modules/ over the copy (the old revision's code: `git archive <rev> modules | tar -x -C <tree>`); compare the PNGs.
# Checks, per sleep <i>:
#   P<i>f  the fall's picture is not black: the middle of every frame at progress 0.25 .. 0.50 keeps at least 55 % of the brightness the
#          locked screen had just before the fall (a good picture keeps 80 % and more, a black one at most 44 % at 0.25 and ~0 % from 0.45;
#          a veil that went on without a picture shows the live lock there, which keeps it too)
#   P<i>w  the same for the climb (progress 0.50 .. 0.25, against the locked screen after the wake)
#   S<i>   the fade's sequence ran (released, rested) and the veil was BLACK over the lock while asleep
#   L<i>   the lock comes up without a black screen: from the sleep to the fall no frame is darker than 35 % of the desktop before it
# and E: with ARM=emptypic the veil logged `picture empty` (the check saw it) unless nocheck.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PNAME=SLEEP_LOCKENV_FILM
. "$ROOT/tools/dev/lock_a1_lib.sh"
OUT="${1:?usage: tools/dev/sleep_lockenv_film.sh <outdir>}"
CYCLES="${CYCLES:-2}"
a1_init slpfilm
rm -rf "$OUT"; mkdir -p "$OUT"
HP=""; REC=""
cleanup() {
    [ -n "$REC" ] && kill -INT "$REC" 2> /dev/null; [ -n "$HP" ] && kill "$HP" 2> /dev/null
    cp "$B/rt/lares-lock.log" "$OUT/lares-lock.log" 2> /dev/null; cp "$W/sup.out" "$OUT/sup.out" 2> /dev/null
    a1_down > /dev/null 2>&1
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
hlog() { cat "$OUT/harness.log" 2> /dev/null; }
wait_say() { local w=$1 s=${2:-20} i; for i in $(seq 1 $((s * 20))); do hlog | grep -aqE "SLEEPFILM $w" && return 0; sleep 0.05; done; return 1; }

a1_build_pam || { echo "$PNAME RESULT FAIL (pam stub)"; exit 1; }
a1_tree '{ "face": "off", "veil": "relief", "veils": ["relief"], "fallbackDelayMs": 600 }' || { echo "$PNAME RESULT FAIL (tree copy)"; exit 1; }
# (the old revision's modules first: an ARM patches the code that runs)
if [ -n "${SLEEPFILM_MODULES:-}" ]; then
    # (the copy's AuthController stays: a1_tree pointed its PAM directory at the stub, and an overlay that put the original back
    # would hand every password typed here to the machine's real PAM stack)
    rsync -a --delete --exclude 'lockscreen/lock/AuthController.qml' "$SLEEPFILM_MODULES/modules/" "$T/modules/" \
        || { echo "$PNAME RESULT FAIL (modules from $SLEEPFILM_MODULES)"; exit 1; }
fi
grep -q "property string pamDirectory: \"$W/pam.d\"" "$T/modules/lockscreen/lock/AuthController.qml" \
    || { echo "$PNAME RESULT FAIL (the copy's PAM directory is not the stub's: refusing to start a lock)"; exit 1; }
for arm in $(echo "${ARM:-}" | tr ',' ' '); do
    case "$arm" in
        # the copy holds nothing: the ShaderEffectSource is pointed at an empty item, so every texture the veil samples is transparent
        emptypic) a1_patch modules/idle/sleep/SleepCapture.qml 'sourceItem: cap' 'sourceItem: emptyArm' \
            && a1_patch modules/idle/sleep/SleepCapture.qml '    ScreencopyView {' '    Item {
        id: emptyArm
        anchors.fill: parent
    }
    ScreencopyView {' || { echo "$PNAME RESULT FAIL (ANCHOR: emptypic)"; exit 3; } ;;
        emptys0) a1_patch modules/lockscreen/lock/DesktopLayer.qml '            sourceItem: s0Loader' '            sourceItem: emptyS0Arm' \
            && a1_patch modules/lockscreen/lock/DesktopLayer.qml '        // does the copy hold anything (THE CHECK)' '        Item {
            id: emptyS0Arm
            anchors.fill: parent
        }
        // does the copy hold anything (THE CHECK)' || { echo "$PNAME RESULT FAIL (ANCHOR: emptys0)"; exit 3; } ;;
        nos0check) a1_patch modules/lockscreen/lock/DesktopLayer.qml '        s0probe.judge();' '        root._s0Judged("ink", -1, -1);' \
            || { echo "$PNAME RESULT FAIL (ANCHOR: nos0check)"; exit 3; } ;;
        # Hyprland answers the lock's prepareLock (xray on) 250 ms late, as a busy compositor or a slow hyprctl can
        slowxray) a1_patch modules/lockscreen/lock/HyprSettings.qml '        proc.command = ["hyprctl", "eval", job.lua];' \
            '        proc.command = job.name === "prepareLock" ? ["sh", "-c", "sleep 0.25; exec hyprctl eval \"$1\"", "sh", job.lua] : ["hyprctl", "eval", job.lua];' \
            || { echo "$PNAME RESULT FAIL (ANCHOR: slowxray)"; exit 3; } ;;
        # S0 reaches the screen 300 ms after the frames the lock counted (a commit the compositor holds): xray must not go off on
        # the count
        lates0) a1_patch modules/lockscreen/lock/DesktopLayer.qml '        } else {
            root._s0Alpha = 1;
        }
        root._blurActive = true;
        root._warm = false;
        root._stillOn = true;' '        } else {
            lateS0Arm.start();
        }
        root._blurActive = true;
        root._warm = false;' && a1_patch modules/lockscreen/lock/DesktopLayer.qml '    Timer {
        id: armCover' '    Timer {
        id: lateS0Arm
        interval: 300
        onTriggered: {
            root._s0Alpha = 1;
            root._stillOn = true;
        }
    }
    Timer {
        id: armCover' || { echo "$PNAME RESULT FAIL (ANCHOR: lates0)"; exit 3; } ;;
        nocheck) a1_patch modules/idle/sleep/SleepVeil.qml '        cap.check();' '        win._checked("ink", -1, -1);' \
            || { echo "$PNAME RESULT FAIL (ANCHOR: nocheck)"; exit 3; } ;;
        *) echo "$PNAME RESULT FAIL (no such ARM: $arm)"; exit 3 ;;
    esac
done
if [ -n "${STILL:-}" ]; then
    CYCLES=1
    a1_patch modules/idle/sleep/SleepFade.qml 'if (st !== null && st.phase === "locked") {' 'if (true) {' \
        && a1_patch modules/idle/sleep/SleepFade.qml 'root._p = root._from + (root._to - root._from) * t;' "root._p = $STILL;" \
        && sed -i 's/root\._seed = Math\.random();/root._seed = 0.25;/' "$T/modules/idle/sleep/SleepFade.qml" \
        && [ "$(grep -c 'root._seed = 0.25;' "$T/modules/idle/sleep/SleepFade.qml")" = 2 ] || { echo "$PNAME RESULT FAIL (ANCHOR: still)"; exit 3; }
fi
if [ -n "${TRACE:-}" ]; then
    # the lock's own times, for placing a frame of the film: the desktop layer's trace (ms since its epoch) and every
    # HyprSettings call asked / applied, on the wall clock the frames are named by
    a1_patch modules/lockscreen/lock/DesktopLayer.qml '    property bool trace: false' '    property bool trace: true' \
        && a1_patch modules/lockscreen/lock/HyprSettings.qml '        root._current = job.name;' '        root._current = job.name;
        console.log("LARESLOCK trace hypr " + job.name + " asked " + Date.now());' \
        && a1_patch modules/lockscreen/lock/HyprSettings.qml '            root.applied(root._current, reply);' '            console.log("LARESLOCK trace hypr " + root._current + " applied " + Date.now());
            root.applied(root._current, reply);' || { echo "$PNAME RESULT FAIL (ANCHOR: trace)"; exit 3; }
fi
D="$W/fade"
mkdir -p "$D/sys/intel_backlight" "$D/sys/nvidia_0"
echo 300 > "$D/sys/intel_backlight/brightness"; echo 400 > "$D/sys/intel_backlight/max_brightness"
echo 77 > "$D/sys/nvidia_0/brightness"; echo 100 > "$D/sys/nvidia_0/max_brightness"
# the panel's backlight is PanelBacklight's answer: this tree has both devices and no eDP card, so the rule (never the NVIDIA one while another
# exists) picks intel_backlight -- the Hybrid-with-a-stray-nvidia_0 case; the stub fails any call that names nvidia_0 or none
mkdir -p "$D/sysroot/class" && ln -sfn "$D/sys" "$D/sysroot/class/backlight"
: > "$D/calls"; : > "$D/inhibit.log"; echo 1000.000 > "$D/clock"
a1_up OUTPUTS=1 MODE="${MODE:-light}" || { echo "$PNAME RESULT FAIL (env)"; exit 1; }
a1_fake_stop
if [ -n "${STILL:-}" ]; then
    # the env's desktop again, with plain text: distance-field text is not the same picture from process to process (CLAUDE.md), and
    # the fixture's big "SECRET" moved ~100 px of every shot by a level between two runs of one tree
    for p in $("$E" status | grep 'desktop_fixture.qml' | awk '{print $1}'); do kill "$p" 2> /dev/null; done
    sleep 0.5
    "$E" run env QML_DISABLE_DISTANCEFIELD=1 quickshell -p "$FX/desktop_fixture.qml" > "$OUT/fixture.log" 2>&1 &
    sleep 2
fi
# the shell's part first, as it is in the session: its LockOwner is the lock's peer
"$E" run env SLEEPFILM_FX="$T/tools/dev/fixtures/sleep" SLEEPFILM_DIR="$D" SLEEP_FADE_DIR="$D" LARES_SYSFS_ROOT="$D/sysroot" SLEEP_FADE_PRIVATE_BUS=1 \
    SLEEPFILM_CYCLES="$CYCLES" SLEEPFILM_NOLOCK="${STILL:+1}" FAKE_LOGIND_CAP_US=5000000 ${LOGRULES:+QT_LOGGING_RULES="$LOGRULES"} quickshell -p "$T/tools/dev/qml/sleep_lockenv_film.qml" > "$OUT/harness.log" 2>&1 &
HP=$!
wait_say "held" 30 || { rl_noresult "$PNAME" "$OUT/harness.log"; exit 1; }
if [ -n "${STILL:-}" ]; then
    wait_say "fallclock 1 " 10 || { echo "$PNAME RESULT FAIL (no fall: $OUT/harness.log)"; exit 1; }
    sleep 0.6; "$E" shot "$OUT/still_fall.png" LOCK-1 || { echo "$PNAME RESULT FAIL (grim)"; exit 1; }
    wait_say "rise 1 " 10 || { echo "$PNAME RESULT FAIL (no climb: $OUT/harness.log)"; exit 1; }
    sleep 0.6; "$E" shot "$OUT/still_rise.png" LOCK-1 || { echo "$PNAME RESULT FAIL (grim)"; exit 1; }
    wait_say "RESULT" 10 || { rl_noresult "$PNAME" "$OUT/harness.log"; exit 1; }
    grep -a -o "LARESSLEEP .*" "$OUT/harness.log" | sed "s/^/$PNAME /"
    hlog | grep -aq "SLEEPFILM RESULT PASS" && { echo "$PNAME RESULT PASS (still at $STILL: $OUT/still_fall.png, $OUT/still_rise.png)"; exit 0; }
    echo "$PNAME RESULT FAIL (the fade did not run: $OUT/harness.log)"; exit 1
fi
"$E" run python3 "$ROOT/tools/dev/sleep_film_sample.py" LOCK-1 "$OUT/frames" > "$OUT/rec.log" 2>&1 &
REC=$!
for i in $(seq 1 "$CYCLES"); do
    wait_say "sleep $i " 10 || { echo "$PNAME RESULT FAIL (no sleep $i: $OUT/harness.log)"; exit 1; }
    A1_LOCK_ENV="LARES_LOCK_FACE=0 VEIL_HOUR=${VEIL_HOUR:-12}" a1_lock
    wait_say "rest $i " 30 || { echo "$PNAME RESULT FAIL (no rest after sleep $i: $OUT/harness.log)"; hlog | grep -a "SLEEPFILM\|LARESSLEEP" | tail -5; exit 1; }
    sleep 1
    "$E" type hunter2; "$E" key Return
    wait_say "unlocked $i " 15 || { echo "$PNAME RESULT FAIL (the lock did not go after sleep $i: $OUT/harness.log)"; exit 1; }
    # the next sleep once this lock's supervisor is gone (it holds the one-lock flock until it has put the compositor back)
    for _ in $(seq 1 100); do a1_sup_alive || break; sleep 0.1; done
    a1_sup_alive && { echo "$PNAME RESULT FAIL (the lock's supervisor did not end after sleep $i)"; exit 1; }
    cp "$B/rt/lares-lock.log" "$OUT/lock$i.log" 2> /dev/null
    if [ -n "${HOP:-}" ] && [ "$i" -lt "$CYCLES" ]; then
        # the shell's side of the lock's keyboard hop: an output comes and goes between two sleeps (here after the unlock: a bare
        # add/remove under a lock leaves this env's lock with no keyboard, which is the lock's affair, not the veil's)
        "$E" hyprctl output create headless LARESLOCK-HOP > "$OUT/hop$i.out" 2>&1
        sleep 1.5
        "$E" hyprctl output remove LARESLOCK-HOP >> "$OUT/hop$i.out" 2>&1
        sleep 1
    fi
    : > "$D/go$((i + 1))"
done
wait_say "RESULT" 10 || { rl_noresult "$PNAME" "$OUT/harness.log"; exit 1; }
sleep 0.5
kill -INT "$REC" 2> /dev/null; REC=""
sleep 1

CYCLES="$CYCLES" ARM="${ARM:-}" python3 - "$OUT" <<'PY'
import glob, os, re, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont
out = sys.argv[1]
cycles = int(os.environ["CYCLES"])
arms = [a for a in os.environ.get("ARM", "").split(",") if a]
log = open(out + "/harness.log", errors="replace").read()
ev = {}
for m in re.finditer(r"SLEEPFILM (held|sleep|fallclock|asleep|wake|rise|rest|unlocked) (\d+) (\d+)(?: (\d+))?", log):
    ev[(m.group(1), int(m.group(2)))] = (int(m.group(3)), int(m.group(4)) if m.group(4) else 0)
res = re.findall(r"SLEEPFILM RESULT (\S+)", log)
empties = [(int(m.group(1)), m.group(2)) for m in re.finditer(r"LARESSLEEP \S+ (\d+) picture empty \((\d+)\)", log)]
frames = sorted((int(os.path.basename(p)[:-4]), p) for p in glob.glob(out + "/frames/*.png"))
# the veil's clock as it ran (a climb that stalls is taken out of its own clock, so wall time is no progress)
prog = {}
for m in re.finditer(r"SLEEPFILM p (\d+) (\d+) ([0-9.]+)", log):
    prog.setdefault(int(m.group(1)), []).append((int(m.group(2)), float(m.group(3))))


def progress_at(i, t, lo, hi):
    """the clock's value at wall time t within [lo, hi] (the last value set at or before t), None outside it"""
    if not (lo <= t <= hi):
        return None
    v = None
    for ms, p in prog.get(i, []):
        if lo <= ms <= t:
            v = p
    return v


def mid(p):
    a = np.asarray(Image.open(p).convert("L"), np.float64)
    h, w = a.shape
    return float(a[int(h * 0.35):int(h * 0.65), int(w * 0.35):int(w * 0.65)].mean())


def full(p):
    return float(np.asarray(Image.open(p).convert("L"), np.float64).mean())


ok = True
lines = []
pick = []
for i in range(1, cycles + 1):
    fc = ev.get(("fallclock", i))
    asl = ev.get(("asleep", i))
    wk = ev.get(("wake", i))
    ri = ev.get(("rise", i))
    rs = ev.get(("rest", i))
    if not (fc and asl and wk and ri and rs):
        lines.append("S%d FAIL: the sleep's events are missing (%s)" % (i, sorted(k for k in ev if k[1] == i)))
        ok = False
        continue
    t_fall, fall_ms = fc
    t_rise, climb_ms = ri
    before = [p for t, p in frames if t_fall - 1500 <= t <= t_fall - 30]
    band_f = [(t, p) for t, p in frames if 0.25 <= (progress_at(i, t, t_fall, asl[0]) or -1) <= 0.50]
    after = [p for t, p in frames if rs[0] + 400 <= t <= rs[0] + 1000]
    band_w = [(t, p) for t, p in frames if 0.25 <= (progress_at(i, t, t_rise, rs[0]) or -1) <= 0.50]
    asleep = [p for t, p in frames if asl[0] + 150 <= t <= wk[0] - 50]
    m0 = mid(before[-1]) if before else -1
    t_sleep = ev[("sleep", i)][0] if ("sleep", i) in ev else t_fall
    desk = [p for t, p in frames if t_sleep - 600 <= t <= t_sleep - 20]
    rising = [p for t, p in frames if t_sleep <= t <= t_fall - 50]
    md = full(desk[-1]) if desk else -1
    lo = min([full(p) for p in rising] or [-1])
    lk = md > 20 and len(rising) > 0 and lo >= 0.35 * md
    lines.append("L%d %s: the lock came up over %d frames, the darkest %.0f %% of the desktop before it (%.1f of %.1f; black is ~0 %%)"
                 % (i, "PASS" if lk else "FAIL", len(rising), 100 * lo / md if md > 0 else -1, lo, md))
    ok = ok and lk
    m1 = mid(after[-1]) if after else -1
    mf = min([mid(p) for _, p in band_f] or [-1])
    mw = min([mid(p) for _, p in band_w] or [-1])
    darkest = max([full(p) for p in asleep] or [999])
    pf = m0 > 20 and len(band_f) > 0 and mf >= 0.55 * m0
    pw = m1 > 20 and len(band_w) > 0 and mw >= 0.55 * m1
    s = darkest < 3
    # a band no frame landed in measured nothing: it fails, and says so (a sampler starved by a loaded machine), never as a brightness
    if not band_f:
        lines.append("P%df FAIL: no frame landed in the fall's band 0.25..0.50 (the sampler was starved: run it again on a quiet machine)" % i)
    else:
        lines.append("P%df %s: the fall at progress 0.25..0.50 (%d frames) keeps %.0f %% of the locked screen's middle (%.1f of %.1f; black is <= 44 %%)"
                     % (i, "PASS" if pf else "FAIL", len(band_f), 100 * mf / m0 if m0 > 0 else -1, mf, m0))
    if not band_w:
        lines.append("P%dw FAIL: no frame landed in the climb's band 0.50..0.25 (the sampler was starved: run it again on a quiet machine)" % i)
    else:
        lines.append("P%dw %s: the climb at progress 0.50..0.25 (%d frames) keeps %.0f %% of the locked screen's middle (%.1f of %.1f)"
                     % (i, "PASS" if pw else "FAIL", len(band_w), 100 * mw / m1 if m1 > 0 else -1, mw, m1))
    lines.append("S%d %s: asleep, the veil is black over the lock (%d frames, brightest mean %.1f; black is < 3)" % (i, "PASS" if s else "FAIL", len(asleep), darkest))
    ok = ok and pf and pw and s
    pick += [(t, p, "sleep %d fall %.2f" % (i, progress_at(i, t, t_fall, asl[0]))) for t, p in band_f[:2]]
    pick += [(t, p, "sleep %d climb %.2f" % (i, progress_at(i, t, t_rise, rs[0]))) for t, p in band_w[:2]]
l0 = bool(res) and res[-1] == "PASS"
lines.append("R %s: the harness says %s" % ("PASS" if l0 else "FAIL", res[-1] if res else "nothing"))
ok = ok and l0
lockdir = out
s0e = 0
for k in range(1, cycles + 1):
    try:
        s0e += len(re.findall(r"LARESLOCK fact desktop \S+: S0 empty \(\d+\)", open("%s/lock%d.log" % (lockdir, k), errors="replace").read()))
    except OSError:
        pass
if "emptys0" in arms and "nos0check" not in arms:
    e = s0e > 0
    lines.append("E0 %s: the lock said its S0 was empty %d time(s)" % ("PASS" if e else "FAIL", s0e))
    ok = ok and e
elif not arms:
    e = s0e == 0
    lines.append("E0 %s: no S0 was empty (%d)" % ("PASS" if e else "FAIL", s0e))
    ok = ok and e
if "emptypic" in arms and "nocheck" not in arms:
    e = len(empties) > 0
    lines.append("E %s: the veil said its picture was empty %d time(s)" % ("PASS" if e else "FAIL", len(empties)))
    ok = ok and e
elif not arms:
    e = len(empties) == 0
    lines.append("E %s: no picture was empty (%d)" % ("PASS" if e else "FAIL", len(empties)))
    ok = ok and e
try:
    font = ImageFont.truetype("/usr/share/fonts/inter/InterVariable.ttf", 18)
except OSError:
    font = ImageFont.load_default()
tw, th = 480, 270
cols = 4
rows = max(1, (len(pick) + cols - 1) // cols)
sheet = Image.new("RGB", (cols * (tw + 6) + 6, 10 + rows * (th + 32)), (24, 24, 28))
dr = ImageDraw.Draw(sheet)
for k, (t, p, label) in enumerate(pick):
    r, c = divmod(k, cols)
    x, y = 6 + c * (tw + 6), 10 + r * (th + 32)
    dr.text((x, y), label, fill=(220, 220, 225), font=font)
    sheet.paste(Image.open(p).convert("RGB").resize((tw, th)), (x, y + 26))
sheet.save(out + "/lockenv_film.png")
for l in lines:
    print("SLEEP_LOCKENV_FILM " + l)
print("SLEEP_LOCKENV_FILM RESULT %s" % ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
PY
