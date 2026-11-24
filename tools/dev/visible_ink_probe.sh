#!/usr/bin/env bash
# visible_ink_probe.sh -- THE INK gate (shell.jsonc `workarounds.visibleInk`; modules/bar/gooey/GooeyInk.qml): with the switch ON, no
# pixel the bar window draws may lie outside the visible region it tells Hyprland, in any frame of a tour of the shell's motions -- ink
# outside it is CUT by the compositor (hyprland_surface_v1 set_visible_region is the clip of that surface's draw).
#
#   tools/dev/visible_ink_probe.sh [outdir]
#
# The mock shell (shell.qml) in tools/dev/lock_env.sh's nested Hyprland (a real 0.57: it honours the region), the user-shaped config
# (halo shadow, aura, ring, scale.global 1.25 at Hyprland scale 1.25; SHELL_JSONC_FILE=<file> takes another, its `visibleInk` forced on),
# started with LARES_INK_PROBE: modules/shell/perf/InkProbe.qml numbers every frame INTO the frame, logs the region each frame goes out
# with and grabs the whole window as fast as it can. The tour: rest, title changes and focus changes (the islands), popups opened with
# their overshoot and closed, a travel between two owners, a secondary (the clock's wiki), toasts, the OSD, the two reels and the tray,
# every glyph flourish at once, a theme switch and back. tools/dev/visible_ink_judge.py holds every picture to its frame's region (while
# the tour runs, deleting what it judged) and prints a table per step and the verdict.
#
#   ARM=shrink   every rect of the region shrunk by the reach it was grown by (halo + ring + tile margin + joint): the halo under the bars is cut, so
#                the gate must FAIL and name the step.
#   SCALE=1.25 (Hyprland's scale of LOCK-1)   LOCK_ENV=ikvi   KEEP=1 keeps the pictures that failed (always: <outdir>/grabs/bad, 6 at most)
# Ends in `VISIBLE_INK RESULT PASS|FAIL`.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-${SCRATCH:-/tmp}/visible-ink}"
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sbx-ink}"
if [ -z "${VI_INNER:-}" ]; then
    mkdir -p "$OUT" || exit 1
    OUT="$(cd "$OUT" && pwd)"
    SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi VI_INNER=1 \
        SCALE="${SCALE:-1.25}" ARM="${ARM:-}" LOCK_ENV="${LOCK_ENV:-ikvi}" SHELL_JSONC_FILE="${SHELL_JSONC_FILE:-}" \
        bash tools/dev/visible_ink_probe.sh "$OUT"
fi
cd "$HERE" || exit 1
T="$HERE"      # this half stands in a sandbox copy (the outer half re-executed through sandbox.sh): never the tree
[ ! -e "$T/.git" ] || { echo "VISIBLE_INK RESULT FAIL (the inner half was started in a work tree, not in a sandbox copy)"; exit 1; }
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-ikvi}"
LOG="$OUT/shell.log"
G="$OUT/grabs"
rm -rf "$G"; mkdir -p "$G"
QPID=""; JPID=""
cleanup() {
    [ -n "$JPID" ] && kill "$JPID" 2> /dev/null
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

[ -e .git ] && { echo "VISIBLE_INK RESULT FAIL (not in a sandbox copy)"; exit 1; }
python3 tools/dev/perf/frame_split_ablate.py "$HERE" hooktoggle livetitle || { echo "VISIBLE_INK RESULT FAIL (a hook patch's anchor is gone)"; exit 1; }
case "${ARM:-}" in
    "") ;;
    shrink)
        python3 - "$HERE/modules/bar/gooey/GooeyInk.qml" <<'PY' || { echo "VISIBLE_INK RESULT FAIL (ARM shrink: the anchor is gone)"; exit 1; }
import sys
p = sys.argv[1]; s = open(p).read()
a = "        const p = root.padPx, R = [];\n"
if s.count(a) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, "        const p = root.padPx - reach * Math.min(sx, sy), R = [];\n"))
print("VISIBLE_INK ARM shrink applied")
PY
        ;;
    *) echo "VISIBLE_INK RESULT FAIL (unknown ARM ${ARM})"; exit 1 ;;
esac

"$E" down > /dev/null 2>&1
OUTPUTS=1 LOCK_REFRESH=60 "$E" up > /dev/null || { echo "VISIBLE_INK RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.config({ general = { gaps_out = 6 } })' > /dev/null
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
[ "${SCALE:-1}" = 1 ] || "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", scale = '"$SCALE"' })' > /dev/null
cfgdir="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
mkdir -p "$cfgdir"
python3 - "$cfgdir/shell.jsonc" "${SHELL_JSONC_FILE:-}" <<'PY' || { echo "VISIBLE_INK RESULT FAIL (the config)"; exit 1; }
import json, re, sys
dst, src = sys.argv[1], sys.argv[2]
cfg = {"scale": {"global": 1.25}, "shadow": {"mode": "halo", "aura": True}, "border": True}
if src:
    sys.path.insert(0, "tools/lib")
    import jsonc
    cfg = jsonc.loads(open(src).read()) if hasattr(jsonc, "loads") else json.loads(re.sub(r"(?m)^\s*//.*$", "", open(src).read()))
cfg.setdefault("workarounds", {})["visibleInk"] = True
json.dump(cfg, open(dst, "w"), indent=1)
PY
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 LARES_INK_PROBE="$G" \
    quickshell -n -p "$T/shell.qml" > "$LOG" 2>&1 &
QPID=$!
deadline=$(( $(date +%s) + 240 ))
until grep -aq "LARES settled" "$LOG" 2> /dev/null; do
    kill -0 "$QPID" 2> /dev/null || { rl_noresult VISIBLE_INK "$LOG"; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "VISIBLE_INK RESULT FAIL (never said settled: $LOG)"; exit 1; }
    sleep 0.5
done
sleep 2
# the judge eats the pictures while the tour runs
( while kill -0 "$QPID" 2> /dev/null; do python3 tools/dev/visible_ink_judge.py "$LOG" "$G" "$SCALE" --consume; sleep 1; done ) &
JPID=$!

ipc() { "$E" run quickshell ipc --path "$T/shell.qml" call "$@" 2> /dev/null; }
mark() { ipc inkprobe mark "$1" > /dev/null; }
toggle() { ipc shell hook toggle "$1"; }
win_up() {
    "$E" run kitty --class "vi-$1" --title "$2" sh -c 'sleep 600' > /dev/null 2>&1 &
    sleep 1.5
}

mark rest; sleep 3
mark title
"$E" run kitty --class vi-title sh -c 'i=0; while [ $i -lt 6 ]; do i=$((i+1)); printf "\033]2;title %s of a window, %s\007" $i "$(head -c $((i * 37 % 60)) /dev/zero | tr "\0" m)"; sleep 0.6; done; sleep 0.4' > /dev/null 2>&1
win_up a "a short one"; win_up b "the second window carries a much longer title than the first"
mark focus
for i in 1 2 3 4; do "$E" hyprctl dispatch 'hl.dsp.focus({ window = "class:vi-'"$([ $((i % 2)) = 0 ] && echo a || echo b)"'" })' > /dev/null 2>&1; sleep 0.6; done
for key in clock weather player stocks silicon; do
    mark "open-$key"; r=$(toggle "$key"); [ "$r" = open ] || echo "VISIBLE_INK note: $key answered '$r'"
    sleep 2
    mark "close-$key"; toggle "$key" > /dev/null; sleep 1.5
done
mark travel
toggle clock > /dev/null; sleep 1.5; toggle weather > /dev/null; sleep 1.5; toggle stocks > /dev/null; sleep 1.5
mark travel-close; toggle stocks > /dev/null; sleep 1.5
mark secondary
ipc shell hook wikiopen discover > /dev/null; sleep 3
mark secondary-close; toggle clock > /dev/null; sleep 1.5
mark toasts
for i in 1 2 3; do ipc shell hook notify "ink probe $i" > /dev/null; sleep 1.2; done
sleep 6
mark osd
for i in 1 2 3 4; do ipc osd volume up > /dev/null; sleep 0.3; done
sleep 3.5
for key in power idle; do
    mark "reel-$key"; r=$(ipc inkprobe reel "$key" 1); [ "$r" = open ] || echo "VISIBLE_INK note: reel $key answered '$r'"
    sleep 2
    mark "reel-$key-close"; ipc inkprobe reel "$key" 0 > /dev/null; sleep 1.5
done
mark tray; r=$(toggle windowtray); [ "$r" = open ] || echo "VISIBLE_INK note: windowtray answered '$r'"
sleep 2
mark tray-close; [ "$r" = open ] && toggle windowtray > /dev/null; sleep 1.5
mark flourish
echo "VISIBLE_INK note: $(ipc inkprobe flourish) flourishes played"; sleep 3
mark theme
ipc shell hook themeclick > /dev/null; sleep 5
mark theme-back
ipc shell hook themeclick > /dev/null; sleep 5
mark rest-end; sleep 2

kill "$QPID" 2> /dev/null; wait "$QPID" 2> /dev/null; QPID=""
wait "$JPID" 2> /dev/null; JPID=""
python3 tools/dev/visible_ink_judge.py "$LOG" "$G" "$SCALE"
rl_clean "$LOG" | grep -a -E "^\s*(ERROR|WARN).*(GooeyInk|InkProbe|InkWhole|binding loop)" | head -5
python3 tools/dev/visible_ink_judge.py "$G" --summary
