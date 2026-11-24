#!/usr/bin/env bash
# reel_film.sh -- the reels in the REAL shell (shell.qml, mock services) inside an isolated nested Hyprland (tools/dev/lock_env.sh), filmed:
#
#   tools/dev/reel_film.sh [outdir]          ends in REEL_FILM RESULT PASS|FAIL
#   WHAT="lock auto ctrl scroll"             which films (default all four)
#     lock   the `lares:lock` key as Super+L sends it (`hyprctl dispatch hl.dsp.global(...)`): the padlock's flourish while the REAL
#            lock comes up (SHELL_LOCK=live; its PAM stubbed by tools/dev/lock_a1_lib.sh, no face, no screentimed); frames of the bar's
#            power cell from the key on, and the lock's own word that it came up
#     auto   content being watched (a hook patched into THIS RUN's copy only: `hook video 1|0`, ContentHold.simulate): the idle reel opens by
#            itself, travels the long way, the REASON pops out beside the strip for its reading pause (ReelReason), both fold, the reel keeps
#            its colour; the frames take in the reason's place right of the strip
#     ctrl   while the auto layer holds the idle reel: a plain wheel under its floor does nothing; with Ctrl held (wtype) it picks one
#     scroll the power reel turned by the two-finger wheel, three steps a third of a second apart: each icon plays its flourish as it
#            arrives in the cell, the one turned out plays on in the strip; the reel landed three on and no command ran (the mock
#            runner's record), the frames of the cell and the strip from the first wheel on
# Frames: <outdir>/<what>/<ms>.png (crops, stamped ms after the act) and <outdir>/<what>.png (a strip, x2 nearest). Nothing shows on the
# user's screen and nothing of theirs is touched: the compositor, its bus, its runtime dir and the XDG homes are lock_env's, the shell
# and the lock run from a scratch copy of this tree, PATH has no ~/.local/bin (no screentimed, no hyprlock), only this run's pids are killed.
set -u
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
. tools/dev/lock_a1_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/reel_film}")"
WHAT="${WHAT:-lock auto ctrl scroll}"
a1_init a1reelfilm
SPID=""
cleanup() {
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    a1_down
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
mkdir -p "$OUT"
fails=0
say() { echo "REELFILM $1 $2${3:+  ($3)}"; [ "$1" = FAIL ] && fails=$((fails + 1)); return 0; }

# ---- the tree: a whole copy, the lock's PAM pointed at a stub, a hook to stand a video up -------------------------------------
a1_build_pam || { echo "REEL_FILM RESULT FAIL (the PAM stub did not build)"; exit 1; }
rm -rf "$T"; mkdir -p "$T"
rsync -a --exclude '.git' --exclude 'feedback' --exclude 'docs' "$ROOT/" "$T/" || exit 1
sed -i "s|property string pamDirectory: \"/etc/pam.d\"|property string pamDirectory: \"$W/pam.d\"|" "$T/modules/lockscreen/lock/AuthController.qml"
grep -q "$W/pam.d" "$T/modules/lockscreen/lock/AuthController.qml" || { echo "REEL_FILM RESULT FAIL (the PAM anchor moved)"; exit 1; }
printf '{}\n' > "$T/lockscreen.json"
a1_patch modules/shell/ShellMain.qml '            case "themeclick":' '            case "video":
                shellServices.idle.soft.content.simulate(arg === "1", "firefox");
                return arg;
            case "themeclick":' || { echo "REEL_FILM RESULT FAIL (the hook anchor moved)"; exit 1; }
# TRACE=1: the copy's reel logs every wheel and click it hears with its modifiers (REELTRACE lines in shell.log)
if [ "${TRACE:-0}" = 1 ]; then
    a1_patch modules/bar/reel/IconReelView.qml '            const ctrl = (wheel.modifiers & Qt.ControlModifier) !== 0;' '            const ctrl = (wheel.modifiers & Qt.ControlModifier) !== 0;
            console.log("REELTRACE wheel mods=" + wheel.modifiers + " held=" + view.reel.autoHeld + " angle=" + wheel.angleDelta.x + "," + wheel.angleDelta.y + " pixel=" + wheel.pixelDelta.x + "," + wheel.pixelDelta.y);' || exit 1
fi
CLEANPATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$HOME/.local/bin$" | paste -sd:)

# ---- the env, the snapshot link the reel's Lock runs, the shell ------------------------------------------------------------------
a1_up MODE=light || { echo "REEL_FILM RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
mkdir -p "$B/state/lares/lock" && ln -sfn "$T" "$B/state/lares/lock/current"
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
SLOG="$W/shell.log"
"$E" run env PATH="$CLEANPATH" SHELL_SERVICES=mock SHELL_LOCK=live LARES_LOCK_FACE=0 QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell -n -p "$T/shell.qml" > "$SLOG" 2>&1 &
SPID=$!
for _ in $(seq 1 400); do grep -aq "LARES settled" "$SLOG" 2> /dev/null && break; kill -0 "$SPID" 2> /dev/null || break; sleep 0.3; done
grep -aq "LARES settled" "$SLOG" || { rl_noresult REEL_FILM "$SLOG"; exit 1; }
sleep 1

ipc() { "$E" run quickshell ipc -p "$T/shell.qml" call shell "$@" 2> /dev/null; }
probe() { ipc probe; }
jget() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {'d': d}))" "$1"; }
SCREEN=$(probe | jget 'list(d["screens"].keys())[0]')
CELLS=$(probe | jget "d['screens']['$SCREEN']['reels']['cells']")
read -r PX PY PW PH IX IY IW IH < <(python3 -c "c=$CELLS; print(*c[0], *c[1])")
echo "cells: power $PX,$PY ${PW}x$PH  idle $IX,$IY ${IW}x$IH"
BBOX=$("$E" hyprctl -j monitors | python3 -c "import json,sys; m=json.load(sys.stdin); print(sum(x['width'] for x in m), max(x['height'] for x in m))")

# film <name> <x> <y> <w> <h> <secs> <act...>: four samplers grab the region (stamped ms after the act), the act runs at 0
film() {
    local name=$1 x=$2 y=$3 w=$4 h=$5 secs=$6; shift 6
    local d="$OUT/$name"; rm -rf "$d"; mkdir -p "$d"
    local t0; t0=$(date +%s%3N)
    local pids=() i
    for i in 1 2 3 4; do
        ( end=$((t0 + secs * 1000)); while [ "$(date +%s%3N)" -lt "$end" ]; do
              f="$d/tmp_${i}_$RANDOM.png"; s=$(date +%s%3N)
              "$E" run grim -g "$x,$y ${w}x$h" "$f" 2> /dev/null && mv "$f" "$d/$(printf '%06d' $((s - t0 + 100000))).png"
          done ) &
        pids+=($!)
        sleep 0.02
    done
    sleep 0.1
    "$@"
    for i in "${pids[@]}"; do wait "$i"; done
    # the stamps are ms after t0 + 100000 (no negatives); make them ms after the act (t0 + 100 ms)
    python3 - "$d" "$OUT/$name.png" <<'PY'
import os, sys
from PIL import Image, ImageDraw
d, out = sys.argv[1], sys.argv[2]
fs = sorted(f for f in os.listdir(d) if f.endswith(".png") and not f.startswith("tmp"))
cells = []
for f in fs:
    ms = int(f[:-4]) - 100000 - 100
    os.rename(os.path.join(d, f), os.path.join(d, "%+05d.png" % ms))
    cells.append(("%+05d.png" % ms, ms))
cells.sort(key=lambda c: c[1])
if cells:
    ims = [Image.open(os.path.join(d, c[0])).convert("RGB") for c in cells]
    w, h = ims[0].size
    Z = 2
    cols = min(len(ims), 12)
    rows = (len(ims) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (w * Z + 4), rows * (h * Z + 18)), "white")
    dr = ImageDraw.Draw(sheet)
    for i, (im, c) in enumerate(zip(ims, cells)):
        x, y = (i % cols) * (w * Z + 4), (i // cols) * (h * Z + 18)
        sheet.paste(im.resize((w * Z, h * Z), Image.NEAREST), (x, y))
        dr.text((x + 2, y + h * Z + 2), "%d ms" % c[1], fill="black")
    sheet.save(out)
print("frames %d" % len(cells))
PY
}

# ---- lock: the key, the flourish, the real lock ----------------------------------------------------------------------------------
if [[ " $WHAT " == *" lock "* ]]; then
    n=$(film lock 0 0 $((PX + PW + 150)) $((PH + 110)) 3 "$E" hyprctl dispatch 'hl.dsp.global("lares:lock")' | tail -1)
    echo "lock: $n"
    for _ in $(seq 1 50); do probe | jget "d['lock']['locked']" 2> /dev/null | grep -q True && break; sleep 0.2; done
    st=$(probe)
    locked=$(printf '%s' "$st" | jget "d['lock']['locked']" 2> /dev/null)
    shut=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['lock']['shut']" 2> /dev/null)
    [ "$locked" = True ] && say ok "the key started the REAL lock through the reel's path" || say FAIL "the key started the REAL lock through the reel's path" "locked=$locked"
    [ "$shut" = True ] && say ok "the padlock is shut while the session is locked" || say FAIL "the padlock is shut while the session is locked" "shut=$shut"
    "$E" shot "$OUT/lock_full.png" 2> /dev/null
    # unlock: the stub's password
    "$E" type hunter2 > /dev/null 2>&1; "$E" key Return > /dev/null 2>&1
    for _ in $(seq 1 50); do probe | jget "d['lock']['locked']" 2> /dev/null | grep -q False && break; sleep 0.2; done
    sleep 1.5
    st=$(probe)
    shut=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['lock']['shut']" 2> /dev/null)
    [ "$shut" = False ] && say ok "the padlock springs open when the lock lets go" || say FAIL "the padlock springs open when the lock lets go" "shut=$shut"
fi

# ---- auto: a video, the cinematic, the reason beside the strip, the fold ------------------------------------------------------------
if [[ " $WHAT " == *" auto "* ]]; then
    # the whole output while the reason is out (3 s of debounce, the strip's growth and the travel, then the reading pause)
    ( sleep 6.0; "$E" shot "$OUT/auto_reason.png" 2> /dev/null ) &
    # the strip and, right of it, where the reason comes out; long enough for the pause (4 s) and the fold with time to spare: the
    # cinematic starts after the auto layer's 3 s debounce, and under load a second later (a lateness is a time, not a share)
    n=$(film auto $((IX - 30)) 0 $((IW + 300)) 200 13 ipc hook video 1 | tail -1)
    echo "auto: $n"
    # the reason by its pixels: the band right of the strip changes while the pause runs and is back to the last frame's at the end
    rr=$(python3 - "$OUT/auto" "$((30 + IW + 6))" <<'PY'
import os, sys
from PIL import Image, ImageChops
d, x0 = sys.argv[1], int(sys.argv[2])
fs = sorted((int(f[:-4]), f) for f in os.listdir(d) if f.endswith(".png") and not f.startswith("tmp"))
if not fs:
    print("none 0 0"); sys.exit()
last = Image.open(os.path.join(d, fs[-1][1])).convert("RGB")
box = (x0, 30, last.width, 170)
ref = last.crop(box)
def moved(f):
    im = Image.open(os.path.join(d, f)).convert("RGB").crop(box)
    return sum(1 for p in ImageChops.difference(im, ref).getdata() if max(p) > 24)
during = max([moved(f) for ms, f in fs if 5500 <= ms <= fs[-1][0] - 1500] or [0])
after = max([moved(f) for ms, f in fs if ms >= fs[-1][0] - 600] or [0])
print("ok %d %d" % (during, after))
PY
)
    read -r _ during after <<< "$rr"
    echo "auto: the band right of the strip: $during px changed during the pause, $after px at the end"
    [ "${during:-0}" -gt 400 ] && [ "${after:-1}" -lt 40 ] && say ok "the reason came out beside the strip for the pause and folded with it" \
        || say FAIL "the reason came out beside the strip for the pause and folded with it" "during=$during after=$after"
    st=$(probe)
    printf '%s' "$st" | jget "(d['idle']['mode'], d['idle']['auto'], d['idle']['reason'])" 2> /dev/null
    held=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['idleHeld']")
    mode=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['idle']")
    [ "$held" = True ] && [ "$mode" = normal ] && say ok "a video put normal in force: the reel travelled there and is held" || say FAIL "a video put normal in force: the reel travelled there and is held" "held=$held reel=$mode"
    "$E" shot "$OUT/auto_full.png" 2> /dev/null
fi

# ---- ctrl: the cause's mode is a FLOOR (74fa2f61, the user's decision): a plain pick under it is refused, Ctrl+wheel goes under it ---
# (a plain pick at or above the floor is the user's mode -- reel_auto_probe / idle_floor_probe hold that side)
if [[ " $WHAT " == *" ctrl "* ]]; then
    [[ " $WHAT " == *" auto "* ]] || { ipc hook video 1 > /dev/null; sleep 6; }
    cx=$((IX + IW / 2)); cy=$((IY + IH / 2))
    read -r BW BH <<< "$BBOX"
    "$E" point "abs $((cx - 3)) $cy $BW $BH" "sleep 100" "abs $cx $cy $BW $BH"; sleep 1
    # the nested pointer's wheel is a two-finger kind (pixel 15 a unit): six of them cross the reel's swipe threshold, which turns an
    # unheld reel by at least one item; a negative wheel turns it toward soft, under the floor a video asks for (normal)
    "$E" point "wheel -15" "wheel -15" "wheel -15" "wheel -15" "wheel -15" "wheel -15" "wheel 0"; sleep 1.2
    st=$(probe)
    sel=$(printf '%s' "$st" | jget "d['idle']['selected']")
    shown=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['idle']")
    [ "$sel" = off ] && [ "$shown" = normal ] && say ok "a plain wheel under the floor on the held idle reel does nothing" || say FAIL "a plain wheel under the floor on the held idle reel does nothing" "selected=$sel reel=$shown"
    # Ctrl held by a virtual keyboard while the wheel turns (F24 first: wtype's first key is keycode 9, which the binds read as Escape)
    ( "$E" run wtype -P F24 -p F24 -M ctrl -s 1500 -m ctrl > /dev/null 2>&1 & )
    sleep 0.4
    "$E" point "wheel -15" "wheel -15" "wheel -15" "wheel -15" "wheel -15" "wheel -15" "wheel 0"; sleep 2.0
    st=$(probe)
    sel=$(printf '%s' "$st" | jget "d['idle']['selected']")
    auto=$(printf '%s' "$st" | jget "d['idle']['auto']")
    [ "$sel" = soft ] && [ "$auto" = False ] && say ok "Ctrl+wheel on the held idle reel picks a mode under the floor (the override)" "selected=$sel" || say FAIL "Ctrl+wheel on the held idle reel picks a mode under the floor (the override)" "selected=$sel auto=$auto"
    "$E" point "abs 1400 900 $BW $BH"; sleep 0.5
fi

# ---- scroll: the power reel turned by the wheel; each arriving icon plays, nothing fires ---------------------------------------------
if [[ " $WHAT " == *" scroll "* ]]; then
    read -r BW BH <<< "$BBOX"
    cx=$((PX + PW / 2)); cy=$((PY + PH / 2))
    # onto the cell as a hand comes (an entry, then a motion: the padlock's hover demo plays), and let it end
    "$E" point "abs $((cx - 3)) $cy $BW $BH" "sleep 100" "abs $cx $cy $BW $BH"; sleep 1.5
    st=$(probe)
    from=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['power']")
    calls0=$(printf '%s' "$st" | jget "len(d['calls'])")
    # six of the nested pointer's wheel units cross the swipe threshold: one step each, a third of a second apart, then the lift
    turn3() {
        "$E" point "wheel 15" "wheel 15" "wheel 15" "wheel 15" "wheel 15" "wheel 15"; sleep 0.33
        "$E" point "wheel 15" "wheel 15" "wheel 15" "wheel 15" "wheel 15" "wheel 15"; sleep 0.33
        "$E" point "wheel 15" "wheel 15" "wheel 15" "wheel 15" "wheel 15" "wheel 15" "wheel 0"
    }
    n=$(film scroll $((PX - 30)) 0 $((PW + 60)) 280 3 turn3 | tail -1)
    echo "scroll: $n"
    sleep 1.5
    st=$(probe)
    to=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['power']")
    calls1=$(printf '%s' "$st" | jget "len(d['calls'])")
    lock=$(printf '%s' "$st" | jget "d['screens']['$SCREEN']['reels']['lock']")
    echo "scroll: the reel went $from -> $to; commands $calls0 -> $calls1; padlock $lock"
    [ "$from" = lock ] && [ "$to" = reboot ] && say ok "three steps of the wheel turned the power reel from lock to reboot" || say FAIL "three steps of the wheel turned the power reel from lock to reboot" "$from -> $to"
    [ "$calls1" = "$calls0" ] && say ok "the scroll fired nothing (no command recorded)" || say FAIL "the scroll fired nothing (no command recorded)" "$calls0 -> $calls1"
    "$E" point "abs 1400 900 $BW $BH"; sleep 0.5
fi

warn=$(rl_clean "$SLOG" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function" | rl_platform_noise | sort -u | head -5)
[ -n "$warn" ] && say FAIL "the shell's log is clean" "$warn"
cp "$SLOG" "$OUT/shell.log"
[ "$fails" = 0 ] && echo "REEL_FILM RESULT PASS (films in $OUT)" && exit 0
echo "REEL_FILM RESULT FAIL ($fails; $OUT)"
exit 1
