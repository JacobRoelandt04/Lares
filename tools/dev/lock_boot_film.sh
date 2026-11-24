#!/usr/bin/env bash
# lock_boot_film.sh -- the lock AT BOOT, filmed frame by frame in tools/dev/lock_env.sh's nested Hyprland: the real
# supervisor and lock (Hyprland's --locked-cmd, as SDDM starts it), the user's own wallpaper under hyprpaper (started
# with the session, as autostart.lua does), and the REAL shell.qml (mock services, SHELL_LOCK=live: the lock's socket)
# started when the scenario says. wf-recorder takes every frame the compositor makes of LOCK-1 (it records on damage:
# a frame that changes nothing is not a frame), and each frame is classified by its pixels.
#
# A REAL BOOT'S COMPOSITOR IS BUSY (BUSY=1, the default): hyprpaper maps and fades the wallpaper in, themectl sets it again,
# the cursor theme is set, all while the lock starts, so Hyprland draws frame after frame -- including in the span from the
# lock's request to its first commit, in which it draws the session's WORKSPACE. tools/dev/lock_env/probes/busy_layer.qml
# (a transparent full-screen layer that commits every frame) stands in for that; without it no frame lands in the span and
# the wallpaper the user filmed at every boot cannot be seen here (last round's film passed for that reason). Hyprland's
# animations are on (ANIMATIONS=true, as the user's are: layers fade in).
#
#   tools/dev/lock_boot_film.sh [scenario ...]        default: floor ontime late never fail
#   TREE=<dir> tools/dev/lock_boot_film.sh ...        another tree's lock and shell (an old revision's copy), same film
#   VEIL=gooey (default) | paper | ...               DEADLINE=<ms> the boot card's wait where a scenario does not set it
#   VEILS="relief gooey ..." (default: all seven)     the veils `floor` films, one run each
#   SLOWFENCE=<n>                                     the cover's first frame made GPU-heavy (n full-screen blended rects)
#   OUT=<dir> (default $SCRATCH/lockboot)             KEEP_FRAMES=1 keeps the PNGs; BUSY=0 the idle compositor of old
#   LBF_PREFIX=<word>                                 the lock_env name's prefix (a stream's own env beside the gate's)
#
# Scenarios (the shell's start is counted from the lock's start, `go`):
#   floor   per veil of VEILS, no shell (the first seconds of every boot): the password typed blind at +4 s and Return with
#           nothing shown at +5 s unlock it (no card ever)
#   ontime  the shell at +3 s (a real boot's is ~4 s): no card ever; the popup comes once, out of its bar
#   late    the card's wait cut to 5 s, the shell at +9 s: the card, then THE HAND-OVER -- never a frame with both
#   latewarm  the same with the shell's shaders already in the env's cache (one run of it before the lock), as a real
#           session's are: the hand-over's gap as the desktop would see it
#   never   no shell; the password typed blind at +2 s, Return only once the card is up (8 s wait): it unlocks
#   fail    no shell, the default 30 s wait: a wrong password at +2 s brings the card at once; the right one unlocks
# In the TEST COPY only, the card is filled magenta and the shell's lock popup carries a green strip at its top centre,
# so a frame says which of the two it shows. Every scenario also judges THE FIRST FRAMES -- the user's own model of a
# boot: the tty's black until the veil's floor is on screen, whole:
#   - no frame of the wallpaper while locked: the frame IS the wallpaper (fitted as hyprpaper fits it), or a darkened copy
#     of it (its luminance follows the wallpaper's: a cover still fading in); the unlock's fade, after the veil, is not one
#   - no frame of Hyprland's lockdead screen (the lock took longer than lockdead_screen_delay to draw)
#   - the floor at once: no frame of the lock is part veil and part black (a pour, a front laying a bed, a cutter laying
#     sand over the black)
# Per scenario a timeline of runs of frames (state, first and last time, count), the share of wallpaper before the veil
# and the first veil frame's black, the lock's log lines, and LOCK_BOOT_FILM <scen> PASS|FAIL (why); last line
# LOCK_BOOT_FILM RESULT PASS|FAIL.
#
# THE COVER'S ORDER, read from the two logs (boot scenarios): Hyprland mapped the cover BEFORE it locked the session (its
# log: "LayerSurface <cover> mapped" before "Session got locked"), and the lock let the cover go only once secure ("LARESLOCK
# fact cover: gone" after "LARESLOCK secure"). A broken order is a FAIL whether or not a frame landed in the span: the bare
# first frame keeps the span about one frame long, and a film at ~15 fps sees such a frame only sometimes.
#
# ARM=<arm> patches ONE fault into the test copy; the scenario must then FAIL on its needle:
#   nocover     no cover (BootCover) while the lock asks                          floor: "locked the session before ... mapped"
#   swaponly    the lock asks on the cover's first swapped frame, not once the compositor has MAPPED it (lists it); with
#               SLOWFENCE the cover's buffer is not ready when the request lands     floor: "locked the session before ... mapped"
#   earlycover  the cover goes as the lock asks, not at secure                       floor: "the cover went before the lock was secure"
#   coveranim   the supervisor sets no no_anim rule for the cover (it fades in)      floor: "the wallpaper is on screen" -- the
#               film's word only (hyprctl reports a layer's fade goal, not where it stands): it bites when a frame lands in
#               the cover's first moments, not every run
#   nobare      the boot veil built into the surface's first frame again             floor: "lockdead" (cold cache: > 1 s)
#   growbed     (VEILS=paper) the bed laid by a front out of the shell at boot       floor: "the floor came in parts"
#   pour        (VEILS=gooey) the pour's front at boot                              floor: "the floor came in parts"
#   cutter      (VEILS=dials) the sand laid behind the cutter at boot                floor: "the floor came in parts"
#   lateveil    the veil built 1.5 s after secure: the black must HOLD               floor: PASS (an arm that must not fail)
#   nohandover  the card waits for the shell's `shown`, not its bar (the old rule)   late: "card and popup together"
#   nodeadline  the boot card waits only fallbackDelayMs (2 s), as before            ontime: "a card showed"
#   nofail      a failed attempt does not bring the card                             fail: "no-early-card"
# (`noblack`, the surface clear from its first frame, is gone: under the cover and the bare first frame the workspace is
# never drawn while it is clear -- black whether the surface is or not -- so no film can see it; the surface's black stays
# as a second line)
#
# PAM is the scripted stub (password "hunter2"); the real password and camera are never involved. Nothing reaches the
# user's desktop: the compositor, the bus, the runtime dir and the XDG homes are lock_env's, the tree is a copy.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/dev/lock_a1_lib.sh"
TREE="${TREE:-$ROOT}"
VEIL="${VEIL:-gooey}"
SCENS="${*:-floor ontime late never fail}"
OUT="${OUT:-${SCRATCH:-/tmp}/lockboot}"
# The wallpaper is the judge's reference ("is this frame the wallpaper?"), so it is a FIXTURE no lock frame can resemble,
# made here: warm saturated hues (red to amber, blue 0) over a texture, never grey (the veils' surfaces), black (the
# floor), magenta (the card's marker), green (the popup's) or teal (lockdead). The user's own picture was the reference
# until round 4 and failed twice: its file moved, and the next one's pale ground is within 24 levels of the light
# veils' surface, so every veil frame read as wallpaper ("no frame of the lock at all"). WALL=<picture> films another.
if [ -z "${WALL:-}" ]; then
    mkdir -p "$OUT"
    WALL="$OUT/wall_fixture.png"
    python3 - "$WALL" <<'PYW' || { echo "LOCK_BOOT_FILM RESULT FAIL (could not make the wallpaper fixture)"; exit 1; }
import sys
import numpy as np
from PIL import Image
W, H = 2880, 1620
y, x = np.mgrid[0:H, 0:W].astype(np.float32)
hue = 50.0 * (x / W * 0.6 + y / H * 0.4)                                          # 0 (red) .. 50 deg (amber)
val = 0.62 + 0.18 * (y / H) + 0.2 * (0.5 + 0.5 * np.sin(x / 37.0) * np.sin(y / 53.0))  # 0.62 .. 1.0, textured
r = val
g = val * hue / 60.0
rgb = np.stack([r, g, np.zeros_like(r)], axis=2)
Image.fromarray(np.clip(rgb * 255.0 + 0.5, 0, 255).astype(np.uint8), "RGB").save(sys.argv[1])
PYW
fi
BUSY="${BUSY:-1}"
VEILS="${VEILS:-relief gooey dimples paper louvres keycaps dials}"
fails=0
A1_ENV_PREFIX="${LBF_PREFIX:-}" a1_init pdlkboot
REC=""; SHPID=""; BUSYPID=""
cleanup() {
    [ -n "$REC" ] && kill -INT "$REC" 2> /dev/null
    [ -n "$SHPID" ] && kill "$SHPID" 2> /dev/null
    [ -n "$BUSYPID" ] && kill "$BUSYPID" 2> /dev/null
    a1_down > /dev/null 2>&1
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
[ -f "$WALL" ] || { echo "LOCK_BOOT_FILM RESULT FAIL (no wallpaper at '$WALL')"; exit 1; }

# the veils' boot floors, as they were (each arm puts one back)
ARM_PAPER_OLD='    readonly property real _bedFront: root._opaque ? 1e6 : Math.min(1, root._rise * 2) * root._reach'
ARM_PAPER_NEW='    readonly property real _bedFront: Math.min(1, root._rise * 2) * root._reach'
ARM_GOOEY_OLD='    if (presence < 0.9999 && opaqueMode < 0.5) {'
ARM_GOOEY_NEW='    if (presence < 0.9999) {'
ARM_DIALS_OLD='    float groundCov = entering && opaqueMode < 0.5 ? smoothstep(0.0, front.y * u, behind) : 1.0;'
ARM_DIALS_NEW='    float groundCov = entering ? smoothstep(0.0, front.y * u, behind) : 1.0;'
rebake() {  # a shader of the COPY, baked again after an arm patched it
    (cd "$T" && bash tools/dev/bake_shaders.sh "${1%.frag}" 2>&1 | grep -q 'PASS') || { echo "prep: the bake of $1 failed"; return 1; }
}

prep() {  # deadline_ms [veil]
    a1_build_pam > /dev/null || return 1
    rm -rf "$T"; mkdir -p "$T"
    rsync -a --exclude '.git' --exclude '.qmlls.ini' --exclude '.claude' --exclude 'screenshots' "$TREE/" "$T/" || return 1
    local f="$T/modules/lockscreen/lock/AuthController.qml"
    [ "$(grep -c 'property string pamDirectory: "/etc/pam.d"' "$f")" = 1 ] || { echo "prep: pamDirectory anchor missing"; return 1; }
    sed -i "s|property string pamDirectory: \"/etc/pam.d\"|property string pamDirectory: \"$W/pam.d\"|" "$f"
    printf '{ "veil": "%s", "bootFallbackDelayMs": %s, "face": "off" }\n' "${2:-$VEIL}" "$1" > "$T/lockscreen.json"
    rm -f "$T/lockscreen.jsonc"
    # the markers (THIS COPY ONLY): the card magenta, a green strip at the top of the shell's lock popup
    a1_patch modules/lockscreen/lock/LockSurface.qml '            surfaceColor: Theme.surface
            backgroundColor: Theme.surface' '            surfaceColor: "#ff00ff"
            backgroundColor: "#ff00ff"' || return 1
    a1_patch modules/lockscreen/LockOwner.qml '                    renderScale: t.engine && t.engine.renderScale > 0 ? t.engine.renderScale : 1
                }' '                    renderScale: t.engine && t.engine.renderScale > 0 ? t.engine.renderScale : 1
                    Rectangle { x: (parent.width - 120) / 2; y: 0; width: 120; height: 10; color: "#00ff00"; z: 1000 }
                }' || return 1
    case "${ARM:-}" in
        "") ;;
        nocover) a1_patch modules/lockscreen/lock/LockRoot.qml '        active: root.boot && !root._coverDone' '        active: false' || return 1 ;;
        swaponly) a1_patch modules/lockscreen/lock/BootCover.qml '            root._swappedAt = Date.now();
            layers.running = true;' '            root._swappedAt = Date.now();
            root._mappedAt = Date.now();
            root._mapped = true;' || return 1 ;;
        earlycover) a1_patch modules/lockscreen/lock/LockRoot.qml '        root._asked = true;
        coverWait.stop();' '        root._asked = true;
        Qt.callLater(() => { root._coverDone = true; });
        coverWait.stop();' || return 1 ;;
        coveranim) a1_patch tools/lockscreen/lares-lock '    [ "${BOOT:-}" = 1 ] && cover_rule' '    :' || return 1 ;;
        nobare) a1_patch modules/lockscreen/lock/LockSurface.qml '            if (root._lockedNow)
                root._build();' '            if (root._boot || root._lockedNow)
                root._build();' || return 1 ;;
        growbed) a1_patch modules/lockscreen/veil/VeilPaper.qml "$ARM_PAPER_OLD" "$ARM_PAPER_NEW" || return 1 ;;
        pour) a1_patch modules/lockscreen/shaders/veil_gooey.frag "$ARM_GOOEY_OLD" "$ARM_GOOEY_NEW" || return 1
              rebake veil_gooey.frag || return 1 ;;
        cutter) a1_patch modules/lockscreen/shaders/veil_dials.frag "$ARM_DIALS_OLD" "$ARM_DIALS_NEW" || return 1
                rebake veil_dials.frag || return 1 ;;
        lateveil) a1_patch modules/lockscreen/lock/LockSurface.qml '            id: veilLoader
            anchors.fill: parent' '            id: veilLoader
            anchors.fill: parent
            active: !root._armHold' || return 1
                  a1_patch modules/lockscreen/lock/LockSurface.qml '    property bool _built: false' '    property bool _built: false
    property bool _armHold: root._boot
    Timer { interval: 1500; running: root._built; onTriggered: root._armHold = false }' || return 1 ;;
        nohandover) a1_patch modules/lockscreen/lock/LockSurface.qml '        return !!n && !!n.bar;' '        return false;' || return 1 ;;
        nodeadline) a1_patch modules/lockscreen/lock/LockSurface.qml '(root.ctx.lockState.boot && !root.ctx.relaunch ? root.ctx.config.bootFallbackDelayMs : root.ctx.config.fallbackDelayMs)' 'root.ctx.config.fallbackDelayMs' || return 1 ;;
        nofail) a1_patch modules/lockscreen/lock/LockSurface.qml '            if (root.ctx.lockState.auth === "failed" && !root._reported && !root._due) {' '            if (false) {' || return 1 ;;
        *) echo "unknown ARM=$ARM"; return 1 ;;
    esac
    [ -n "${ARM:-}" ] && echo "  ARMED $ARM"
    # SLOWFENCE=<n>: the cover's first frame made heavy for the GPU (n full-screen rectangles, blended), so its buffer's
    # fence comes long after its swap: Hyprland applies a dmabuf commit only once the fence is readable, and a lock that
    # asked on the swap (ARM swaponly) is heard before the cover is there. Not a fault: the lock must wait for the map.
    if [ -n "${SLOWFENCE:-}" ]; then
        a1_patch modules/lockscreen/lock/BootCover.qml '            Item {
                id: body
                anchors.fill: parent
            }' "            Item {
                id: body
                anchors.fill: parent
                Repeater {
                    model: $SLOWFENCE
                    Rectangle {
                        required property int index
                        width: cover.width
                        height: cover.height
                        color: Qt.rgba(0, 0, 0, 0.02 + 0.0001 * index)
                    }
                }
            }" || return 1
        echo "  SLOWFENCE $SLOWFENCE"
    fi
    printf '#!/bin/sh\nwhile [ ! -e %s/go ]; do sleep 0.02; done\nexec bash %s/tools/lockscreen/lares-lock --boot\n' "$W" "$T" > "$W/bootlock.sh"
    chmod +x "$W/bootlock.sh"
    printf 'splash = false\nipc = false\nwallpaper {\n    monitor =\n    path = %s\n    fit_mode = cover\n}\n' "$WALL" > "$W/hyprpaper.conf"
    rm -f "$W/go"
}

up() {
    "$E" down > /dev/null 2>&1
    env MODE=light ANIMATIONS="${ANIMATIONS:-true}" LOCKED_CMD="$W/bootlock.sh" AUTOSTART="hyprpaper -c $W/hyprpaper.conf" "$E" up > /dev/null \
        || { echo "LOCK_BOOT_FILM env up failed"; return 1; }
    "$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
    if [ "$BUSY" = 1 ]; then
        # A REAL BOOT'S BUSY COMPOSITOR (busy_layer.qml): every vsync a whole-output frame, as hyprpaper's fade-in, themectl
        # and the cursor theme make at a real boot. Without it the nested compositor draws nothing between the lock's
        # request and its first commit, and the wallpaper the user films in that span cannot be seen here.
        mkdir -p "$W/busy"; cp "$ROOT/tools/dev/lock_env/probes/busy_layer.qml" "$W/busy/shell.qml"
        "$E" run env QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 quickshell -n -p "$W/busy/shell.qml" > "$W/busy.log" 2>&1 &
        BUSYPID=$!
    fi
    sleep 2
}
record() {  # dir
    "$E" run wf-recorder -o LOCK-1 -c ffv1 -x bgr0 -f "$1/film.mkv" > "$1/rec.log" 2>&1 &
    REC=$!
    sleep 1.5
}
stop_record() {
    [ -n "$REC" ] && kill -INT "$REC" 2> /dev/null
    for _ in $(seq 1 100); do kill -0 "$REC" 2> /dev/null || break; sleep 0.1; done
    REC=""
}
shell_start() {  # dir
    "$E" run env SHELL_SERVICES=mock SHELL_LOCK=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
        quickshell -n -p "$T/shell.qml" > "$1/shell.log" 2>&1 &
    SHPID=$!
}
go() { touch "$W/go"; GO_MS=$(date +%s%3N); }
at() { local want=$(( GO_MS + $1 )) now; now=$(date +%s%3N); [ "$want" -gt "$now" ] && sleep "$(python3 -c "print(($want - $now) / 1000)")"; }
lockline() { a1_lock_log | grep -a "$1" | head -1; }

judge() {  # scen dir expect...
    local scen=$1 d=$2; shift 2
    python3 - "$d" "$WALL" "$@" <<'PY'
import os, re, subprocess, sys
import numpy as np
from PIL import Image
d, wall, expects = sys.argv[1], sys.argv[2], sys.argv[3:]
fr = os.path.join(d, "frames"); os.makedirs(fr, exist_ok=True)
p = subprocess.run(["ffmpeg", "-v", "info", "-i", os.path.join(d, "film.mkv"), "-vf", "scale=720:-2,showinfo",
                    "-fps_mode", "passthrough", os.path.join(fr, "%06d.png")], capture_output=True, text=True)
pts = [float(m.group(1)) for m in re.finditer(r"pts_time:([0-9.]+)", p.stderr)]
files = sorted(f for f in os.listdir(fr) if f.endswith(".png"))
if not files:
    print("JUDGE FAIL no frames (ffmpeg: %s)" % p.stderr[-300:]); sys.exit(1)
# the wallpaper as hyprpaper fits it (cover), at the frame's size
W, H = Image.open(os.path.join(fr, files[0])).size
im = Image.open(wall).convert("RGB")
s = max(2880 / im.width, 1620 / im.height)
im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
x0, y0 = (im.width - 2880) // 2, (im.height - 1620) // 2
wp = np.asarray(im.crop((x0, y0, x0 + 2880, y0 + 1620)).resize((W, H), Image.LANCZOS)).astype(np.int16)
wpl = wp.mean(axis=2).ravel()
states = []
walls = []      # each frame's share of wallpaper pixels
blacks = []     # each frame's share of black pixels (the ground no veil covers yet)
for f in files:
    a = np.asarray(Image.open(os.path.join(fr, f)).convert("RGB")).astype(np.int16)
    mean = a.mean()
    wall_px = (np.abs(a - wp).max(axis=2) < 24).mean()          # share of pixels that ARE the wallpaper
    walls.append(wall_px)
    blacks.append((a.max(axis=2) < 14).mean())
    # the wallpaper behind something partly transparent (a cover still fading in): the frame is the wallpaper scaled, so its
    # luminance follows the wallpaper's closely however dark it is
    lum = a.mean(axis=2).ravel()
    ghost = lum.std() > 3 and float(np.corrcoef(lum, wpl)[0, 1]) > 0.85
    # Hyprland's lockdead screen: dark grey (#0b0b0b) with its teal logo and white text
    teal = ((a[..., 1] > 150) & (a[..., 2] > 150) & (a[..., 0] < 80)).mean()
    mag = ((a[..., 0] > 200) & (a[..., 1] < 60) & (a[..., 2] > 200)).sum()
    grn = ((a[..., 0] < 60) & (a[..., 1] > 200) & (a[..., 2] < 60)).sum()
    if wall_px > 0.05:
        st = "WALLPAPER(%.0f%%)" % (100 * wall_px)
    elif ghost:
        st = "WALLPAPER(ghost, mean %.0f)" % mean
    elif mean < 6:
        st = "black"
    elif teal > 0.0005 and blacks[-1] > 0.5:
        st = "LOCKDEAD"
    else:
        st = "veil"
    if mag > 20:
        st += "+card"
    if grn > 20:
        st += "+popup"
    states.append(st)
t = (pts + [pts[-1] if pts else 0] * len(files))[:len(files)]
runs = []
for i, st in enumerate(states):
    key = re.sub(r"\(.*?\)", "", st)
    if runs and runs[-1][0] == key:
        runs[-1][2] = t[i]; runs[-1][3] += 1
    else:
        runs.append([key, t[i], t[i], 1, st])
for k, a_, b_, n, ex in runs:
    print("  %-22s %7.3f .. %7.3f s  %4d frame(s)%s" % (k, a_, b_, n, ("  e.g. " + ex) if ex != k else ""))
seq = [r[0] for r in runs]
bad = []
# THE FIRST FRAMES: a boot session is locked from Hyprland's first frame, so until the lock lets go the compositor shows
# black or the lock -- never the wallpaper. Wallpaper frames after the lock's last frame are the unlocked desktop.
locked = [i for i, s in enumerate(seq) if s != "black" and not s.startswith("WALLPAPER") and s != "LOCKDEAD"]
if locked:
    # (a faded wallpaper after the veil's first frame is the unlock's fade to the desktop, never a flash: a flash is exact)
    inside = [r for k, r in enumerate(runs[:locked[-1] + 1]) if r[0].startswith("WALLPAPER") and (k < locked[0] or "ghost" not in r[4])]
    if inside:
        bad.append("the wallpaper is on screen in %d frame(s) while locked (first at %.3f s)" % (sum(r[3] for r in inside), inside[0][1]))
    dead = [r for r in runs[:locked[-1] + 1] if r[0] == "LOCKDEAD"]
    if dead:
        bad.append("Hyprland's lockdead screen in %d frame(s) (first at %.3f s): the lock took longer than lockdead_screen_delay to draw"
                   % (sum(r[3] for r in dead), dead[0][1]))
    # the lock's frames up to its first veil frame: the most wallpaper any of them shows (a share under the 5 % of a
    # WALLPAPER frame is still printed: it says how close the run came)
    first = locked[0]
    fi = sum(r[3] for r in runs[:first])
    # (`first` indexes runs; fi is that run's first frame)
    print("  most wallpaper in a frame before the lock's veil: %.2f %%; the first veil frame (#%d at %.3f s): %.2f %% black, %.2f %% wallpaper"
          % (100 * max(walls[:fi + 1]), fi, t[fi], 100 * blacks[fi], 100 * walls[fi]))
    # THE FLOOR AT ONCE: a boot veil is opaque and comes whole -- its bottom layer covers the screen in its first frame, so
    # no frame of the lock is part veil and part black (a pour, a front laying a bed, a cutter laying sand: the black ahead)
    lf = sum(r[3] for r in runs[:locked[-1] + 1])
    parts = [i for i in range(fi, lf) if states[i].startswith("veil") and blacks[i] > 0.005]
    if parts:
        bad.append("the floor came in parts: %d veil frame(s) with black left in them (first at %.3f s, %.1f %% black)"
                   % (len(parts), t[parts[0]], 100 * blacks[parts[0]]))
else:
    bad.append("no frame of the lock at all")
if any("+card" in s and "+popup" in s for s in seq):
    bad.append("card and popup together in %d frame(s)" % sum(r[3] for r in runs if "+card" in r[0] and "+popup" in r[0]))
for e in expects:
    if e == "nocard" and any("+card" in s for s in seq):
        bad.append("a card showed")
    if e == "card" and not any("+card" in s for s in seq):
        bad.append("no card ever showed")
    if e == "popup" and not any("+popup" in s for s in seq):
        bad.append("the shell's popup never showed")
    if e == "card_then_popup":
        c = [i for i, s in enumerate(seq) if "+card" in s]; pp = [i for i, s in enumerate(seq) if "+popup" in s]
        if c and pp:
            gap = runs[pp[0]][1] - runs[c[-1]][2]
            print("  hand-over: the card's last frame at %.3f s, the popup's first at %.3f s (%.0f ms between)" % (runs[c[-1]][2], runs[pp[0]][1], 1000 * gap))
            if pp[0] < c[-1]:
                bad.append("the card came back after the popup")
print("JUDGE " + ("PASS" if not bad else "FAIL " + "; ".join(bad)) + " (%d frames)" % len(files))
PY
}

film() {  # scen [veil]
    local scen=$1 veil="${2:-$VEIL}" deadline="${DEADLINE:-30000}" expect=() ok=1 why="" name=$1
    [ "$scen" = floor ] && name="floor-$veil"
    local d="$OUT/$name"
    rm -rf "$d"; mkdir -p "$d"
    case "$scen" in late|latewarm|never) deadline=5000 ;; esac
    [ "$scen" = never ] && deadline=8000
    prep "$deadline" "$veil" || { echo "LOCK_BOOT_FILM $name FAIL (prep)"; fails=$((fails + 1)); return; }
    up || { fails=$((fails + 1)); return; }
    if [ "$scen" = latewarm ]; then
        # the shell once before the lock, so its shaders are in the env's cache as they are in a real session's
        shell_start "$d"
        for _ in $(seq 1 150); do grep -aq 'LARES settled' "$d/shell.log" 2> /dev/null && break; sleep 0.2; done
        sleep 3; kill "$SHPID" 2> /dev/null; wait "$SHPID" 2> /dev/null; SHPID=""
        mv "$d/shell.log" "$d/shell-warm.log"
    fi
    record "$d"
    go
    case "$scen" in
        floor)
            # no shell: the veil alone, as the first seconds of every boot; the password typed blind and Return with nothing
            # shown unlock it (keys are never lost, nothing waits for a card)
            at 4000; "$E" type hunter2
            at 5000; "$E" key Return
            expect=(nocard) ;;
        ontime)
            at 3000; shell_start "$d"
            # (the nested env's shader cache is cold at every start: the shell's popup takes 5-10 s here, ~1 s on a warm one)
            a1_wait_log 'LARESLOCK shell on' 40; sleep 2.5
            "$E" type hunter2; sleep 0.3; "$E" key Return
            expect=(nocard popup) ;;
        late|latewarm)
            at 9000; shell_start "$d"
            a1_wait_log 'LARESLOCK shell on' 40; sleep 2.5
            "$E" type hunter2; sleep 0.3; "$E" key Return
            expect=(card popup card_then_popup) ;;
        never)
            at 2000; "$E" type hunter2
            at 10000; "$E" key Return
            expect=(card) ;;
        fail)
            at 2000; "$E" type wrong; sleep 0.3; "$E" key Return
            at 7000; "$E" type hunter2; sleep 0.3; "$E" key Return
            expect=(card) ;;
    esac
    a1_wait_log 'LARESLOCK unlocked' 8 || { ok=0; why="$why no-unlock"; }
    sleep 1.5
    stop_record
    cp "$B/rt/lares-lock.log" "$d/lock.log" 2> /dev/null
    # THE COVER'S ORDER (the header): Hyprland's word -- the cover mapped, then the session locked (its log, kept beside the
    # film) -- and the lock's -- the cover gone only once secure
    local hl addr hord lord
    hl=$(ls "$B"/rt/hypr/*/hyprland.log 2> /dev/null | head -1)
    if [ -n "$hl" ]; then
        cp "$hl" "$d/hyprland.log"
        addr=$(grep -ao 'LayerSurface [0-9a-f]* (namespace lares-lock-cover' "$hl" | head -1 | awk '{print $2}')
        grep -aE "Session got locked|LayerSurface ${addr:-NONE} (mapped|destroyed)" "$hl" | sed 's/^.*\] /  hypr  /' | head -4
        hord=$(grep -aoE "Session got locked|LayerSurface ${addr:-NONE} mapped" "$hl" | head -2 | sed 's/Session got locked/locked/; s/LayerSurface .* mapped/mapped/' | tr '\n' ' ')
        [ "$hord" = "mapped locked " ] || { ok=0; why="$why Hyprland locked the session before it mapped the cover (${hord:-nothing});"; }
    fi
    lord=$(a1_lock_log | grep -aoE "LARESLOCK secure|LARESLOCK fact cover: gone" | head -2 | tr '\n' '|')
    case "$lord" in
        "LARESLOCK secure|LARESLOCK fact cover: gone|") ;;
        *) ok=0; why="$why the cover went before the lock was secure (${lord:-no line});" ;;
    esac
    a1_lock_log | grep -aE "LARESLOCK (secure|veil up|fallback|shell|unlocked|release)" | sed 's/^/  log  /' | cut -c1-120
    if [ "$scen" = fail ]; then
        # the card at once on the failed attempt, long before the 30 s wait
        local shown; shown=$(a1_lock_log | grep -ao 'fallback LOCK-1 shown at [0-9]*' | head -1 | awk '{print $NF}')
        if [ -n "$shown" ] && [ $(( shown - GO_MS )) -lt 9000 ]; then echo "  the card came $(( shown - GO_MS )) ms after the lock started (the failed attempt)"
        else ok=0; why="$why no-early-card"; fi
    fi
    j=$(judge "$scen" "$d" "${expect[@]}")
    printf '%s\n' "$j" | grep -v '^JUDGE'
    printf '%s\n' "$j" | grep -q '^JUDGE PASS' || { ok=0; why="$why $(printf '%s\n' "$j" | grep '^JUDGE' | sed 's/^JUDGE FAIL //')"; }
    [ -n "$SHPID" ] && { kill "$SHPID" 2> /dev/null; SHPID=""; }
    [ -n "$BUSYPID" ] && { kill "$BUSYPID" 2> /dev/null; BUSYPID=""; }
    [ "${KEEP_FRAMES:-0}" = 1 ] || rm -rf "$d/frames"
    rm -f "$d/film.mkv"
    "$E" down > /dev/null 2>&1
    if [ "$ok" = 1 ]; then echo "LOCK_BOOT_FILM $name PASS"; else echo "LOCK_BOOT_FILM $name FAIL ($why )"; fails=$((fails + 1)); fi
}

mkdir -p "$OUT"
for s in $SCENS; do
    case "$s" in
        floor) for v in $VEILS; do film floor "$v"; done ;;
        ontime|late|latewarm|never|fail) film "$s" ;;
        *) echo "unknown scenario $s"; fails=$((fails + 1)) ;;
    esac
done
[ "$fails" -eq 0 ] && echo "LOCK_BOOT_FILM RESULT PASS" || { echo "LOCK_BOOT_FILM RESULT FAIL ($fails)"; exit 1; }
