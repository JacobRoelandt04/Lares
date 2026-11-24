#!/usr/bin/env bash
# tools/dev/shell_joint_probe.sh -- does a tiled Hyprland window's corner nest in the bars' joint, by pixels? (HyprJoint.js THE OVERLAP;
# the user's feedback/general.md "Border radius around hyprland windows", round 8.)
#
#   tools/dev/shell_joint_probe.sh [<out>]      ends in SHELL_JOINT RESULT PASS|FAIL
#   CASES="1.25/1.25 1.25/1"                    <the shell's scale.global>/<Hyprland's scale of the output>; the default is the user's
#                                               laptop panel and his external screen
#   CORNERS="14/3"                              <decoration:rounding>/<general:border_size>, each reloaded into the running session
#   SWEEP=1                                     the compact sweep: Hyprland scale 1 1.25 1.5 2 x rounding 0 8 14 20 x border 1 2 3
#   ARM=oldoverlap                              the fault, in the run's own sandbox copy: THE OVERLAP is the old 2.5 px at every radius; the run must FAIL
#                                               on `border` (the ring over the window's border along the arc)
#   ARM=nooverlap                               THE OVERLAP is 0; the run must FAIL on `seam` (the wallpaper between the two arcs)
#   OVERLAP=<px>                                any other overlap, patched the same way (a measurement, never a verdict to keep)
#   SHELL_JOINT_KEEP=1                          keep the nested env's shots in <out> (they are kept on any failure)
#
# The REAL shell (shell.qml, mock services) in the nested Hyprland (tools/dev/lock_env.sh), with the shell's ring on, gaps_out 0, shadows
# off, and one tiled window (tools/dev/qml/joint_window.qml: green, Hyprland's border red). Every state is shot TWICE, over a black and
# over a white compositor background: the difference of the two is, pixel for pixel, the share of the wallpaper that shows (exact, whatever
# the colours), and the black one unmixes into the shell's surface, its ring, the border and the window. tools/dev/shell_joint_judge.py
# walks rays through each of the window's four corners and reads, per ray, the wallpaper between the shell and the border (`seam`) and how
# much of the border's thickness is left (`border`); the straights the same way.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
. tools/dev/result_lib.sh
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-sjn}"
OUT="${1:-${SCRATCH:-${XDG_CACHE_HOME:-$HOME/.cache}}/shell_joint_probe}"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
own_sb=0; [ -z "${SANDBOX:-}" ] && own_sb=1
SB="${SANDBOX:-/tmp/lares-sandbox-sjoint}"
CASES="${CASES:-1.25/1.25 1.25/1}"
CORNERS="${CORNERS:-14/3}"
if [ "${SWEEP:-0}" = 1 ]; then
    CASES="1.25/1 1.25/1.25 1.25/1.5 1.25/2"
    CORNERS="14/3 0/3 8/1 8/2 8/3 14/1 14/2 20/1 20/2 20/3"
fi
WAIT="${WAIT:-40}"

SPID=""; WPID=""; _cleaned=0; _ok=0
cleanup() {
    [ "$_cleaned" = 1 ] && return
    _cleaned=1
    [ -n "$WPID" ] && kill "$WPID" 2> /dev/null
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    [ "$own_sb" = 1 ] && rm -rf "$SB" "$SB.lrrt"
    [ "$_ok" = 1 ] && [ "${SHELL_JOINT_KEEP:-0}" != 1 ] && rm -f "$OUT"/joint_*.png
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

SANDBOX="$SB" tools/dev/sandbox.sh true > /dev/null || { echo "SHELL_JOINT RESULT FAIL (the sandbox did not sync)"; exit 1; }
[ -e "$SB/.git" ] && { echo "SHELL_JOINT RESULT FAIL (the sandbox is a work tree)"; exit 1; }
case "${ARM:-}" in oldoverlap) OVERLAP=2.5 ;; nooverlap) OVERLAP=0 ;; "") ;; *) echo "SHELL_JOINT RESULT FAIL (unknown ARM $ARM)"; exit 1 ;; esac
if [ -n "${OVERLAP:-}" ]; then
    python3 - "$SB/modules/shell/HyprJoint.js" "$OVERLAP" <<'PY' || { echo "SHELL_JOINT RESULT FAIL (ARM ${ARM:-overlap}: its anchor is gone in HyprJoint.js)"; exit 1; }
import sys
p, v = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
a = "    return b !== null && b >= 0 ? Math.min(v, OVERLAP_BORDER * b) : v;"
if s.count(a) != 1:
    raise SystemExit(1)
open(p, "w", encoding="utf-8").write(s.replace(a, "    return %s;" % float(v)))
PY
    echo "ARMED the copy: THE OVERLAP is $OVERLAP px at every radius"
fi

fails=0; checks=0
# Hyprland's own numbers go in the nested env's config FILE (a reload re-runs it: what a user does, and an evaluated monitor would not
# survive it)
hypr_cfg() {  # rounding border background
    cat >> "$("$E" dir)/hyprland.lua" <<LUA
hl.monitor({ output = "LOCK-1", mode = "2880x1620@60", position = "0x0", scale = $HS })
hl.config({
    general = { gaps_out = 0, gaps_in = 4, border_size = $2, col = { active_border = "rgba(ff0000ff)", inactive_border = "rgba(ff0000ff)" } },
    decoration = { rounding = $1, active_opacity = 1.0, inactive_opacity = 1.0, shadow = { enabled = false }, blur = { enabled = false } },
    misc = { background_color = "rgba($3ff)" },
})
hl.layer_rule({ name = "lares_bar_noanim_$RANDOM$RANDOM", match = { namespace = "^lares-bar\$" }, no_anim = true })
LUA
}
opt() { "$E" hyprctl -j getoption "$1" | python3 -c "
import json, sys
o = json.load(sys.stdin)
for k in ('int', 'float', 'css', 'custom'):
    if k in o: print(str(o[k]).split()[0]); break"; }
reload_to() {  # rounding border background
    hypr_cfg "$1" "$2" "$3"
    "$E" hyprctl reload > /dev/null 2>&1
    local _
    for _ in $(seq 1 100); do [ "$(opt decoration:rounding)" = "$1" ] && [ "$(opt general:border_size)" = "$2" ] && break; sleep 0.2; done
}
said_last() { rl_clean "$SLOG" | grep -a "HYPRJOINT " | tail -1 | sed 's/^.*HYPRJOINT //'; }

for C in $CASES; do
    K="${C%/*}"; HS="${C#*/}"
    while [ "$(cut -d. -f1 /proc/loadavg)" -ge 18 ]; do sleep 5; done
    "$E" down > /dev/null 2>&1
    OUTPUTS=1 "$E" up > /dev/null || { echo "SHELL_JOINT RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
    set -- $CORNERS
    R0="${1%/*}"; B0="${1#*/}"
    reload_to "$R0" "$B0" 000000
    for _ in $(seq 1 50); do [ "$("$E" hyprctl -j monitors | python3 -c "import json, sys; print('%g' % json.load(sys.stdin)[0]['scale'])")" = "$HS" ] && break; sleep 0.2; done
    mkdir -p "$("$E" dir)/state/lares-shell-mock/config"
    printf '{ "scale": { "global": %s }, "border": true }\n' "$K" > "$("$E" dir)/state/lares-shell-mock/config/shell.jsonc"
    TAG="k${K}_h${HS}"
    SLOG="$OUT/shell_$TAG.log"; WLOG="$OUT/window_$TAG.log"
    "$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 quickshell -n -p "$SB/shell.qml" > "$SLOG" 2>&1 &
    SPID=$!
    for _ in $(seq 1 400); do rl_has "$SLOG" "LARES settled" && break; kill -0 "$SPID" 2> /dev/null || break; sleep 0.3; done
    rl_has "$SLOG" "LARES ready" || { rl_noresult SHELL_JOINT "$SLOG"; exit 1; }
    "$E" run env QS_DISABLE_CRASH_HANDLER=1 quickshell -n -p "$SB/tools/dev/qml/joint_window.qml" > "$WLOG" 2>&1 &
    WPID=$!
    for _ in $(seq 1 60); do "$E" hyprctl -j clients 2> /dev/null | grep -q '"joint-window"' && break; sleep 0.3; done
    echo "  shell scale $K, Hyprland scale $HS:"
    for RB in $CORNERS; do
        R="${RB%/*}"; B="${RB#*/}"
        label="scale $K hypr $HS rounding $R border $B"
        want="rounding $R border $B -> outline $([ "$R" -gt 0 ] && echo $((R + B)) || echo 0) (compositor px)"
        reload_to "$R" "$B" 000000
        ok=0
        for _ in $(seq 1 $((WAIT * 5))); do [ "$(said_last)" = "$want" ] && { ok=1; break; }; sleep 0.2; done
        checks=$((checks + 1))
        if [ "$ok" != 1 ]; then echo "    $label FAIL (the shell did not say '$want' within ${WAIT}s; last: '$(said_last)')"; fails=$((fails + 1)); continue; fi
        sleep 1.5                                       # the frame that draws it
        pb="$OUT/joint_${TAG}_r${R}_b${B}_black.png"; pw="$OUT/joint_${TAG}_r${R}_b${B}_white.png"
        "$E" shot "$pb" > /dev/null 2>&1
        reload_to "$R" "$B" ffffff
        sleep 1.2
        "$E" shot "$pw" > /dev/null 2>&1
        box=$("$E" hyprctl -j clients | python3 -c "
import json, sys
c = [x for x in json.load(sys.stdin) if x['title'] == 'joint-window'][0]
print(c['at'][0], c['at'][1], c['size'][0], c['size'][1])")
        # a 1 px border caps THE OVERLAP at half a pixel (HyprJoint.js: a thin border is not spent on the seam): the seam it leaves is judged
        # against what no overlap leaves (0.22 .. 0.25), not against the full overlap's
        seam=0.15; [ "$B" -lt 2 ] && seam=0.21
        python3 -B tools/dev/shell_joint_judge.py "$pb" "$pw" --box "$box" --hs "$HS" --rounding "$R" --border "$B" --label "$label" --seam-arc "$seam" ${JUDGE_ARGS:-}
        [ $? = 0 ] || fails=$((fails + 1))
    done
    kill "$WPID" "$SPID" 2> /dev/null
    wait "$WPID" "$SPID" 2> /dev/null
    WPID=""; SPID=""
done

warns=$(for f in "$OUT"/shell_k*.log; do rl_clean "$f"; done | rl_platform_noise | grep -aE "Unable to assign|Binding loop|non-existent property|TypeError|ReferenceError")
if [ -n "$warns" ]; then echo "    FAIL the shell's log complains:"; printf '%s\n' "$warns" | head -5 | sed 's/^ */        /'; fails=$((fails + 1)); fi
if [ "$fails" = 0 ] && [ "$checks" -gt 0 ]; then
    echo "SHELL_JOINT RESULT PASS ($checks states: no wallpaper between the joint and the window's corner and the border whole, cases $CASES, corners $CORNERS)"
    _ok=1
    exit 0
fi
echo "SHELL_JOINT RESULT FAIL ($fails of $checks states; shots in $OUT)"
exit 1
