#!/usr/bin/env bash
# A toast that leaves while another arrives (tools/dev/qml/toast_handover_probe.qml): the real engine's lane, the real toast
# stack and NotificationService, driven by frames. Sandbox, offscreen.
#
# Two passes: the HAND-OVER (the box moves once; frames and heights, no pictures) and THE ARRIVAL (an arriving card is never cut by
# its own reveal: every arrival filmed frame by frame and judged from the pixels, tools/dev/toast_entry_judge.py).
#
#   tools/dev/toast_handover_probe.sh [outdir]     ONLY=<scenario>[,..]   BEFORE=<rev> (the same harness on that revision's tree)
#   FILM=1 [FILM_EVERY=3] [FILM_N=15]   PNGs of the stage during each action into <outdir>/film (<scenario>_<frame>.png)
#   EDGE=bottom  the bar at the screen's bottom edge     SCALE=1.25  the frame magnified as the shell's is
#   PASS=hand|entry   run one pass only (both by default)
#   ARM=nohandover   an arrival opens at once whatever is leaving (the old stack): the hand-over scenarios must fail
#   ARM=noresync     a room already closing keeps its own clock when an arrival comes: `duringclose`'s rows and box part
#   ARM=oldclip      the slot's reveal clip put back (the card uncovered from the bar's side): the arrival check must fail
#   ARM=oldrows      the rows' clip at the stack's drawn extent (the arriving card cut by it): the arrival check must fail
#   ARM=topz         an arriving row paints over the rows next to it: the arrival check's order must fail
# Writes <outdir>/<scenario>.csv (frame, lane height, rows' drawn height) and <outdir>/entry/ (the arrival's frames).
# Last line: TOAST_HANDOVER RESULT PASS|FAIL.
set -u
cd "$(dirname "$0")/../.."
. tools/dev/result_lib.sh
OUT="$(realpath -m "${1:-${SCRATCH:-/tmp}/toast_handover}")"
if [ -e .git ]; then
    exec tools/dev/sandbox.sh QT_QPA_PLATFORM=offscreen tools/dev/toast_handover_probe.sh "$OUT"
fi
export QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND="${QT_QUICK_BACKEND:-rhi}" QSG_DISTANCEFIELD_ANTIALIASING=gray
HERE=$(pwd)
GITDIR="${MOCKUP_REPO:-$HERE}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/toasthand.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/cfg/theme" "$WORK/state" "$WORK/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$WORK/cfg/theme/state.json"
export NOTIF_CONFIG=""
if [ "${EDGE:-top}" = bottom ]; then
    printf '{ "spot": { "corner": "bottom-right" } }\n' > "$WORK/cfg/notifications.jsonc"
    export NOTIF_CONFIG="$WORK/cfg/notifications.jsonc"
fi
TREE="$HERE"
if [ -n "${BEFORE:-}" ]; then
    mkdir -p "$WORK/tree"
    git -C "$GITDIR" archive "$BEFORE" | tar -x -C "$WORK/tree" || { echo "TOAST_HANDOVER RESULT FAIL (no tree for $BEFORE)"; exit 1; }
    cp tools/dev/qml/toast_handover_probe.qml "$WORK/tree/tools/dev/qml/"
    TREE="$WORK/tree"
fi

arm_patch() {    # <py> : run a patch against $TREE
    (cd "$TREE" && python3 - "$@") || { echo "ARM ${ARM}: anchor is gone"; echo "TOAST_HANDOVER RESULT FAIL (ARM ${ARM}: anchor gone)"; exit 1; }
}
case "${ARM:-}" in
oldclip)
    arm_patch <<'PY'
p = "modules/notifications/toast/ToastSlot.qml"
s = open(p).read()
a = "    id: slot\n"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, a + "    clip: slot.extent < 1 && !slot.collapsing\n"))
PY
    ;;
oldrows)
    arm_patch <<'PY'
p = "modules/notifications/NotificationToast.qml"
s = open(p).read()
a = "                h += s.clipHeight;"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, "                h += s.height;"))
PY
    ;;
topz)
    arm_patch <<'PY'
p = "modules/notifications/toast/ToastSlot.qml"
s = open(p).read()
a = "    id: slot\n"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, a + "    z: slot.extent < 1 ? 1 : 0\n"))
PY
    ;;
nohandover)
    arm_patch <<'PY'
p = "modules/notifications/NotificationToast.qml"
s = open(p).read()
a = "        const heir = root._partnerFor(slot);"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, "        const heir = null;"))
PY
    ;;
noresync)
    arm_patch <<'PY'
p = "modules/notifications/toast/ToastSlot.qml"
s = open(p).read()
a = "    function resyncClose(): void {\n"
assert s.count(a) == 1
open(p, "w").write(s.replace(a, a + "        return;\n"))
PY
    ;;
"") ;;
*) echo "TOAST_HANDOVER RESULT FAIL (unknown ARM $ARM)"; exit 1 ;;
esac

passes="${PASS:-hand entry}"
[ "$passes" = hand ] || [ "$passes" = entry ] || [ "$passes" = "hand entry" ] || { echo "TOAST_HANDOVER RESULT FAIL (unknown PASS $passes)"; exit 1; }
rc=0
common_env() {    # the harness's environment for one pass
    env XDG_CONFIG_HOME="$WORK/cfg" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache" EDGE="${EDGE:-top}" SCALE="${SCALE:-1}" NOTIF_CONFIG="$NOTIF_CONFIG" "$@"
}

# ---- pass 1: the hand-over ----------------------------------------------------------------------------------------------
if [[ " $passes " == *" hand "* ]]; then
log="$OUT/run.log"
film=""
if [ -n "${FILM:-}" ]; then film="$OUT/film"; mkdir -p "$film"; fi
(cd "$TREE" && common_env ONLY="${ONLY:-}" FILM="$film" FILM_EVERY="${FILM_EVERY:-3}" FILM_N="${FILM_N:-15}" \
    timeout -k 5 240 quickshell -p tools/dev/qml/toast_handover_probe.qml > "$log" 2>&1)
rl_clean "$log" | grep -a "HANDOVER csv " | sed 's/^ *DEBUG qml: //' | python3 -c '
import sys, collections
out = sys.argv[1]
by = collections.OrderedDict()
for line in sys.stdin:
    parts = line.split()
    i = parts.index("csv")
    by.setdefault(parts[i + 1], []).append(parts[i + 2])
for name, rows in by.items():
    open("%s/%s.csv" % (out, name), "w").write("frame,lane,rows\n" + "\n".join(rows) + "\n")
' "$OUT"
rl_clean "$log" | grep -a "HANDOVER" | grep -v "RESULT\|HANDOVER csv \|HANDOVER card " | sed 's/^ *DEBUG qml: //'
if ! rl_has "$log" 'HANDOVER RESULT'; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($log)"
    cp "$log" "$OUT/noload.log" 2> /dev/null
    rl_noresult TOAST_HANDOVER "$log"; exit 1
fi
res=$(rl_result HANDOVER "$log"); rc1=$?
warn=$(rl_clean "$log" | grep -a -E "WARN|ERROR|Binding loop|Unable to assign|Cannot assign" | rl_platform_noise \
    | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks" | sort -u | head -5)
if [ -n "$warn" ]; then
    echo "$warn"
    echo "HANDOVER FAIL warnings in the log"
    rc1=1
fi
echo "${res:-no result}" | sed 's/^/HANDOVER: /'
[ $rc1 -eq 0 ] || rc=1
fi

# ---- pass 2: the arrival ------------------------------------------------------------------------------------------------
# Every arrival filmed frame by frame (a grab per frame moves the timing, so the shapes are not judged here), and judged from the
# pixels: the card stands at its place, nothing cuts it but the box and the row that covers it, it paints under that row.
if [[ " $passes " == *" entry "* ]]; then
elog="$OUT/entry.log"
edir="$OUT/entry"
rm -rf "$edir"; mkdir -p "$edir"
arrivals="${ENTRY_ONLY:-lone,replace,arrivefirst,duringfade,stack,overflow,arrive,arrive2}"
[ -n "${ONLY:-}" ] && arrivals="$ONLY"
(cd "$TREE" && common_env ONLY="$arrivals" FILM="$edir" FILM_EVERY=1 FILM_N="${ENTRY_FRAMES:-28}" ENTRY=1 \
    timeout -k 5 300 quickshell -p tools/dev/qml/toast_handover_probe.qml > "$elog" 2>&1)
if ! rl_has "$elog" 'HANDOVER RESULT'; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($elog)"
    cp "$elog" "$OUT/noload_entry.log" 2> /dev/null
    rl_noresult TOAST_HANDOVER "$elog"; exit 1
fi
rl_clean "$elog" | grep -a "HANDOVER card " | sed 's/^ *DEBUG qml: //' | python3 -c '
import sys, collections
out = sys.argv[1]
by = collections.OrderedDict()
for line in sys.stdin:
    parts = line.split()
    by.setdefault(parts[2], []).append(line.strip())
for name, rows in by.items():
    open("%s/%s.card" % (out, name), "w").write("\n".join(rows) + "\n")
' "$edir"
ewarn=$(rl_clean "$elog" | grep -a -E "WARN|ERROR|Binding loop|Unable to assign|Cannot assign" | rl_platform_noise \
    | grep -v "quickshell.tooling\|QT_QPA_PLATFORM\|--- WARNING ---\|WAYLAND_DISPLAY is present\|actually running wayland\|support setting window masks" | sort -u | head -5)
if [ -n "$ewarn" ]; then
    echo "$ewarn"
    echo "ENTRY FAIL warnings in the log"
    rc=1
fi
judge_args=""
[ "${EDGE:-top}" = bottom ] && judge_args="--no-place"
python3 tools/dev/toast_entry_judge.py "$edir" $judge_args || rc=1
fi

if [ $rc -eq 0 ]; then echo "TOAST_HANDOVER RESULT PASS"; else echo "TOAST_HANDOVER RESULT FAIL"; exit 1; fi
