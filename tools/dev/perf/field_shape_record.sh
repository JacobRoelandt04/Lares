#!/usr/bin/env bash
# field_shape_record.sh -- the corpus of the field-shape differential: the EXACT inputs of every GooeyGeometry.fieldShape() call the
# real engine makes while the mock shell (shell.qml, mock services) runs a list of motions in tools/dev/lock_env.sh's nested Hyprland.
# The recorder is tools/dev/perf/field_shape_patch.py, applied to this run's own sandbox copy (never the tree); every call becomes one
# FSREC line of the shell's log, and tools/dev/perf/field_shape_extract.py turns those into <outdir>/corpus.jsonl, one call a line, each
# labelled with the scenario it fell in ("other" outside them: the start, the prewarm). tools/dev/perf/field_shape_replay.js (node) and
# field_shape_qv4.sh (QV4) replay it through two GooeyGeometry.js.
#
#   tools/dev/perf/field_shape_record.sh <outdir> [scenario ...]      (no scenario: the default list, field_shape_scenarios.txt)
#       open:<key>[:<s>]     an owner's popup (ShellFrame.owners' keys) opened, left <s> s (default 1), closed
#       quick:<key>          opened, toggled 150 ms later (a close in the middle of the open), again 150 ms later, then closed
#       travel:<a>:<b>       <a> opened, then <b> (the popup travels), then closed
#       sec:<name>           a popup with its secondary out and back: wiki (the clock's), weather, stocks, silicon
#       toast:<n>  osd:<n>  focus:<n>  title:<n>  rest:<s>      (as frame_split.sh: toasts 1.2 s apart, n volume keys 0.3 s apart,
#                            focus changes / title changes 0.6 s apart, nothing)
#   TOPMODE=continuous   the one continuous top bar (shell.jsonc topMode) instead of the three islands
#   SHELL_JSONC='{...}'  the mock shell's whole shell.jsonc instead (e.g. '{ "border": true }': the sky's outset, THE BORDER'S END)
#   SCALE=1 (LOCK-1's)   REFRESH=120   SETTLE_S=240   LOCK_ENV=pfe0 (12 characters at most)
#
# The corpus stays out of git (it is tens of MB): ~/.cache/claude-orch/perf/engine/ is where this stream kept its own. Ends in
# `FIELD_SHAPE_RECORD RESULT PASS|FAIL`: PASS says the scenarios ran and calls were recorded.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-}"; [ -n "$OUT" ] || { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sbx-perf-fsr}"
if [ -z "${FSR_INNER:-}" ]; then
    mkdir -p "$OUT" || exit 1
    OUT="$(cd "$OUT" && pwd)"
    SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi FSR_INNER=1 \
        REFRESH="${REFRESH:-120}" SCALE="${SCALE:-1}" TOPMODE="${TOPMODE:-}" SHELL_JSONC="${SHELL_JSONC:-}" SETTLE_S="${SETTLE_S:-240}" LOCK_ENV="${LOCK_ENV:-pfe0}" \
        bash tools/dev/perf/field_shape_record.sh "$OUT" "$@"
fi
cd "$HERE" || exit 1
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-pfe0}"
LOG="$OUT/shell.log"
MARKS="$OUT/marks.tsv"
QPID=""
: > "$MARKS"
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
mark() { printf '%s\t%s\n' "$(date +%s.%N)" "$1" >> "$MARKS"; }
fail() { echo "FIELD_SHAPE_RECORD RESULT FAIL ($*)"; exit 1; }

[ "$#" -gt 0 ] || set -- $(grep -v '^#' tools/dev/perf/field_shape_scenarios.txt)
python3 tools/dev/perf/frame_split_ablate.py "$HERE" hooktoggle || fail "the toggle hook's anchor is gone"
python3 tools/dev/perf/field_shape_patch.py "$HERE" || fail "an anchor of the recorder is gone"

"$E" down > /dev/null 2>&1
OUTPUTS=1 LOCK_REFRESH="${REFRESH:-120}" "$E" up > /dev/null || fail "the nested Hyprland did not come up"
"$E" hyprctl eval 'hl.config({ general = { gaps_out = 6 } })' > /dev/null
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
[ "${SCALE:-1}" = 1 ] || "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", scale = '"$SCALE"' })' > /dev/null
cfgdir="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
if [ -n "${SHELL_JSONC:-}" ]; then
    mkdir -p "$cfgdir" && printf '%s\n' "$SHELL_JSONC" > "$cfgdir/shell.jsonc"
elif [ -n "${TOPMODE:-}" ]; then
    mkdir -p "$cfgdir" && printf '{ "topMode": "%s" }\n' "$TOPMODE" > "$cfgdir/shell.jsonc"
fi
sleep 1
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 \
    quickshell -n -p "$HERE/shell.qml" > "$LOG" 2>&1 &
QPID=$!
deadline=$(( $(date +%s) + ${SETTLE_S:-240} ))
until grep -aq "LARES settled" "$LOG" 2> /dev/null; do
    kill -0 "$QPID" 2> /dev/null || { rl_noresult FIELD_SHAPE_RECORD "$LOG"; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || fail "never said settled within ${SETTLE_S:-240} s: $LOG"
    sleep 0.5
done
sleep 3
mark "settled"

hook() { "$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook "$@" 2> /dev/null; }
toggle() { r=$(hook toggle "$1"); [ "$r" = open ] || [ "$r" = shut ] || echo "FIELD_SHAPE_RECORD $1: the toggle answered '$r'"; }
fsjs() { r=$(hook fsjs "$1"); case $r in error*|none) echo "FIELD_SHAPE_RECORD fsjs '$1': $r" ;; esac; }
win_up() {
    "$E" run kitty --class "pf-$1" --title "$2" sh -c 'sleep 600' > /dev/null 2>&1 &
    sleep 1.5
}
ran=0
for sc in "$@"; do
    kind=${sc%%:*}; arg=""; [ "$kind" = "$sc" ] || arg=${sc#*:}
    mark "begin $sc"
    case $kind in
        open)
            key=${arg%%:*}; w=1; [ "$key" = "$arg" ] || w=${arg#*:}
            toggle "$key"; sleep 2.5; sleep "$w"; toggle "$key"; sleep 1.5 ;;
        quick)
            toggle "$arg"; sleep 0.15; toggle "$arg"; sleep 0.15; toggle "$arg"; sleep 2.5; toggle "$arg"; sleep 1.5 ;;
        travel)
            a=${arg%%:*}; b=${arg#*:}
            toggle "$a"; sleep 2.5; toggle "$b"; sleep 2.5; toggle "$b"; sleep 1.5 ;;
        sec)
            case $arg in
                wiki) toggle clock; sleep 2; fsjs 'clock|owner.openWiki("discover")'; sleep 2.5
                      fsjs 'clock|content.closeWiki()'; sleep 2; toggle clock; sleep 1.5 ;;
                weather) toggle weather; sleep 2.5
                         fsjs 'weather|const k = { metric: "conditions", dayIndex: 0, hourIndex: 0, from: "hero" }; content.openDetail(k, content.anchorFor(k))'
                         sleep 2.5; fsjs 'weather|content.stepBack()'; sleep 2; toggle weather; sleep 1.5 ;;
                stocks) toggle stocks; sleep 2.5
                        fsjs 'stocks|const w = owner.svc.watchlist[0]; owner.openSymbol(w && w.symbol ? w.symbol : w)'
                        sleep 2.5; fsjs 'stocks|content.closeDetail()'; sleep 2; toggle stocks; sleep 1.5 ;;
                silicon) toggle silicon; sleep 2.5; fsjs 'silicon|content.openSecondary("tuning")'; sleep 2.5
                         fsjs 'silicon|content.closeSecondary()'; sleep 2; toggle silicon; sleep 1.5 ;;
                *) echo "FIELD_SHAPE_RECORD unknown secondary: $arg" ;;
            esac ;;
        toast)
            for i in $(seq 1 "${arg:-3}"); do hook notify "field shape $i" > /dev/null; sleep 1.2; done
            sleep 7 ;;
        osd)
            for i in $(seq 1 "${arg:-4}"); do "$E" run quickshell ipc --path "$HERE/shell.qml" call osd volume up > /dev/null 2>&1; sleep 0.3; done
            sleep 3 ;;
        focus)
            [ -n "${FS_WIN:-}" ] || { win_up a "a short one"; win_up b "the second window carries a much longer title than the first"; FS_WIN=2; }
            for i in $(seq 1 "${arg:-6}"); do
                "$E" hyprctl dispatch 'hl.dsp.focus({ window = "class:pf-'"$([ $((i % 2)) = 0 ] && echo a || echo b)"'" })' > /dev/null 2>&1
                sleep 0.6
            done ;;
        title)
            n=${arg:-6}
            "$E" run kitty --class pf-title sh -c 'i=0; while [ $i -lt '"$n"' ]; do i=$((i+1)); printf "\033]2;title %s of a window, %s\007" $i "$(head -c $((i * 37 % 60)) /dev/zero | tr "\0" m)"; sleep 0.6; done; sleep 0.4' > /dev/null 2>&1 ;;
        rest)
            sleep "${arg:-5}" ;;
        *) echo "FIELD_SHAPE_RECORD unknown scenario: $sc"; mark "end $sc"; continue ;;
    esac
    mark "end $sc"
    ran=$((ran + 1))
done
sleep 0.5
kill "$QPID" 2> /dev/null; wait "$QPID" 2> /dev/null; QPID=""
[ "$ran" -gt 0 ] || fail "no scenario ran"
python3 tools/dev/perf/field_shape_extract.py "$LOG" "$MARKS" "$OUT/corpus.jsonl" || fail "no calls recorded: $LOG"
grep -av "FSREC " "$LOG" > "$OUT/shell.rest.log"; rm -f "$LOG"
echo "FIELD_SHAPE_RECORD RESULT PASS ($ran scenarios, $OUT/corpus.jsonl)"
