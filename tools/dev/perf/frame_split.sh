#!/usr/bin/env bash
# frame_split.sh -- what one frame of the real shell costs, split by Qt itself: the mock shell (shell.qml, mock services) in
# tools/dev/lock_env.sh's nested Hyprland, started with QSG_RENDER_TIMING=1 and --log-times, driven through a scenario, and every
# frame's polish / sync / render / swap read back from its log (tools/dev/perf/frame_split.py). The frame journal says THAT the user's
# shell missed frames and in which context; this says WHERE in the frame the time went, so a cause can be ablated.
#
#   tools/dev/perf/frame_split.sh <outdir> [scenario ...]
#       minute        rest until the next minute boundary, then 3 s (the bar clock's roll; the break fill's beat)
#       rest:<s>      nothing for <s> seconds (what draws by itself)
#       title:<n>     <n> changes of the focused window's title, 600 ms apart (the islands follow the title)
#       focus:<n>     <n> focus changes between two windows, 600 ms apart (the islands and the title)
#       toast:<n>     <n> notifications 1.2 s apart (the lane opens, moves, closes)
#       popup:<key>[:<s>]  an owner's popup (the keys of ShellFrame.owners: clock, weather, player, ...) opened, left open <s> seconds
#                     (default 4) and closed: three spans, "open", "rest" and "close"
#       hook:<name>:<arg>[:<wait s>]   one of the mock shell's probe hooks (shell.qml `hook`: notify, critical, idle, themeclick, toggle; and
#                     wikiopen:discover = the clock popup with its wiki secondary), then the wait (default 3 s)
#       ipc:<target>.<fn>[:<wait s>]   one `quickshell ipc call` into the shell (a popup's toggle), then the wait (default 2 s)
#   REFRESH=120 (LOCK-1's refresh rate)   SCALE=1 (Hyprland's scale of LOCK-1)   WIDTH=2880 HEIGHT=1620
#   ABL="<name> ..." ablations from tools/dev/perf/frame_split_ablate.py applied to the run's own copy before the start
#   PROFILE=1 also records Qt's QML profiler (quickshell --debug + /usr/lib/qt6/bin/qmlprofiler) around every scenario, one
#       <outdir>/<scenario>.qtd each, and prints tools/dev/perf/qml_profile.py's table for it: the JS functions, bindings and signal
#       handlers by SELF time. The profiler slows call-heavy code, so read the shares, and time without it.
#   KEEP_ENV=1 leaves the nested session up (LOCK_ENV=pf0).   SETTLE_S=240 at most for `LARES settled`.
#
# Every scenario prints one line per stretch of continuous drawing: frames, the frame gap's median and worst, and the median / worst of
# polish, sync, render, swap and "gui" (the GUI thread's own time per frame: animations + polish + the wait for the sync). The raw
# per-frame table is <outdir>/<scenario>.frames.tsv. Ends in `FRAME_SPLIT RESULT PASS|FAIL`: PASS says the scenarios ran and frames
# were read, not that anything is fast.
#
# A TIMING: the absolute numbers need a quiet machine; a split that is 15 ms of polish against 1 ms does not.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${1:-}"; [ -n "$OUT" ] || { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
SCRATCH="${SCRATCH:-/tmp}"
SANDBOX="${SANDBOX:-$SCRATCH/lares-sbx-perf-fs}"
if [ -z "${FS_INNER:-}" ]; then
    mkdir -p "$OUT" || exit 1
    OUT="$(cd "$OUT" && pwd)"
    SANDBOX="$SANDBOX" SCRATCH="$SCRATCH" exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi FS_INNER=1 \
        REFRESH="${REFRESH:-120}" SCALE="${SCALE:-1}" ABL="${ABL:-}" KEEP_ENV="${KEEP_ENV:-}" SETTLE_S="${SETTLE_S:-240}" PROFILE="${PROFILE:-}" \
        SHELL_JSONC_FILE="${SHELL_JSONC_FILE:-}" HYPR_EXTRA="${HYPR_EXTRA:-}" WINDOWS="${WINDOWS:-}" QT_RULES="${QT_RULES:-}" FS_ENV="${FS_ENV:-}" WV_OPEN_S="${WV_OPEN_S:-}" WV_MINI_S="${WV_MINI_S:-}" \
        bash tools/dev/perf/frame_split.sh "$OUT" "$@"
fi
cd "$HERE" || exit 1
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-pf0}"
LOG="$OUT/shell.log"
MARKS="$OUT/marks.tsv"
QPID=""
PPID_PROF=""
GTPID=""
: > "$MARKS"
cleanup() {
    [ -n "$PPID_PROF" ] && kill "$PPID_PROF" 2> /dev/null
    [ -n "$GTPID" ] && kill "$GTPID" 2> /dev/null
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    [ -n "${KEEP_ENV:-}" ] || "$E" down > /dev/null 2>&1
    wait 2> /dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
mark() { printf '%s\t%s\n' "$(date +%s.%N)" "$1" >> "$MARKS"; }

# shellcheck disable=SC2086
python3 tools/dev/perf/frame_split_ablate.py "$HERE" hooktoggle livetitle ${ABL:-} || { echo "FRAME_SPLIT RESULT FAIL (a patch's anchor is gone)"; exit 1; }

PORT=$(( 37000 + $$ % 2000 ))
"$E" down > /dev/null 2>&1
OUTPUTS=1 LOCK_REFRESH="${REFRESH:-120}" "$E" up > /dev/null || { echo "FRAME_SPLIT RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.config({ general = { gaps_out = 6 } })' > /dev/null
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
[ "${SCALE:-1}" = 1 ] || "$E" hyprctl eval 'hl.monitor({ output = "LOCK-1", scale = '"$SCALE"' })' > /dev/null
if [ -n "${SHELL_JSONC_FILE:-}" ]; then      # the shell's own config (scale.global, shadow, border ...): a copy of the named file
    cfgdir="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
    mkdir -p "$cfgdir" && cp "$SHELL_JSONC_FILE" "$cfgdir/shell.jsonc" || { echo "FRAME_SPLIT RESULT FAIL (SHELL_JSONC_FILE: $SHELL_JSONC_FILE)"; exit 1; }
fi
# HYPR_EXTRA: a Lua file evaluated in the nested Hyprland before the shell starts (a replica of a real decoration config)
# (one line, comments out: hyprctl takes the chunk as ONE argument and a leading "--" reads as a flag)
[ -z "${HYPR_EXTRA:-}" ] || "$E" hyprctl eval "$(grep -v '^[[:space:]]*--' "$HYPR_EXTRA" | tr '\n' ' ')" > "$OUT/hypr_extra.log" 2>&1
[ -z "${HYPR_EXTRA:-}" ] || grep -qx ok "$OUT/hypr_extra.log" || { echo "FRAME_SPLIT RESULT FAIL (HYPR_EXTRA was refused: $(head -c 200 "$OUT/hypr_extra.log"))"; exit 1; }
# WINDOWS=<n>: n tiled kitty windows under the shell (what the compositor draws under every shell frame)
for i in $(seq 1 "${WINDOWS:-0}"); do
    "$E" run kitty --class "pf-bg$i" --title "background $i" sh -c 'sleep 100000' > /dev/null 2>&1 &
    sleep 0.6
done
sleep 1
# the GPU beside the frames: the iGPU's frequency and its rc6 residency (the whole GPU: the user's session is in it too), 10 Hz
GT=""; for c in /sys/class/drm/card[0-9]; do [ -r "$c/gt_act_freq_mhz" ] && GT=$c && break; done
if [ -n "$GT" ]; then
    ( while :; do printf '%s\t%s\t%s\n' "$EPOCHREALTIME" "$(cat "$GT/gt_act_freq_mhz")" "$(cat "$GT/gt/gt0/rc6_residency_ms" 2> /dev/null)"; sleep 0.1; done ) > "$OUT/gt.tsv" 2> /dev/null &
    GTPID=$!
fi
# shellcheck disable=SC2086
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 QSG_RENDER_TIMING=1 \
    LARES_FRAME_JOURNAL=1 ${FS_ENV:-} quickshell --log-times --log-rules "qt.scenegraph.time.renderloop.debug=true${QT_RULES:+;$QT_RULES}" ${PROFILE:+--debug "$PORT"} -n -p "$HERE/shell.qml" > "$LOG" 2>&1 &
QPID=$!
mark "launch"
deadline=$(( $(date +%s) + ${SETTLE_S:-240} ))
until grep -aq "LARES settled" "$LOG" 2> /dev/null; do
    kill -0 "$QPID" 2> /dev/null || { rl_noresult FRAME_SPLIT "$LOG"; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "FRAME_SPLIT RESULT FAIL (never said settled within ${SETTLE_S:-240} s: $LOG)"; exit 1; }
    sleep 0.5
done
sleep 3
mark "settled"
if [ -n "${PROFILE:-}" ]; then
    FIFO="$OUT/prof.fifo"; rm -f "$FIFO"; mkfifo "$FIFO"
    /usr/lib/qt6/bin/qmlprofiler -a 127.0.0.1 -p "$PORT" --interactive --record off \
        --include javascript,binding,handlingsignal,creating,compiling < "$FIFO" > "$OUT/prof.log" 2>&1 &
    PPID_PROF=$!
    exec 7> "$FIFO"
    sleep 2
    kill -0 "$PPID_PROF" 2> /dev/null || { echo "FRAME_SPLIT RESULT FAIL (qmlprofiler did not attach: $OUT/prof.log)"; exit 1; }
fi
prof_on() { [ -z "${PROFILE:-}" ] || { echo record >&7; sleep 0.3; }; }
prof_off() {    # prof_off <scenario>: stop, save, clear
    [ -n "${PROFILE:-}" ] || return 0
    echo record >&7; sleep 0.5
    echo "output $OUT/$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_').qtd" >&7; sleep 1.5
    echo clear >&7; sleep 0.2
}

win_up() {      # a client window to give the islands a title
    "$E" run kitty --class "pf-$1" --title "$2" sh -c 'sleep 600' > /dev/null 2>&1 &
    sleep 1.5
}
ran=0
for sc in "$@"; do
    kind=${sc%%:*}; arg=""; [ "$kind" = "$sc" ] || arg=${sc#*:}
    prof_on
    case $kind in
        minute)
            now=$(date +%s); wait_s=$(( 60 - now % 60 ))
            [ "$wait_s" -ge 4 ] || { sleep "$wait_s"; wait_s=60; }
            sleep $(( wait_s - 2 ))
            mark "begin $sc"; sleep 5; mark "end $sc" ;;
        rest)
            mark "begin $sc"; sleep "${arg:-10}"; mark "end $sc" ;;
        title)
            mark "begin $sc"
            n=${arg:-6}
            "$E" run kitty --class pf-title sh -c 'i=0; while [ $i -lt '"$n"' ]; do i=$((i+1)); printf "\033]2;title %s of a window, %s\007" $i "$(head -c $((i * 37 % 60)) /dev/zero | tr "\0" m)"; sleep 0.6; done; sleep 0.4' > "$OUT/kitty.log" 2>&1
            mark "end $sc" ;;
        focus)
            [ -n "${FS_WIN:-}" ] || { win_up a "a short one"; win_up b "the second window carries a much longer title than the first"; FS_WIN=2; }
            mark "begin $sc"
            for i in $(seq 1 "${arg:-6}"); do
                "$E" hyprctl dispatch 'hl.dsp.focus({ window = "class:pf-'"$([ $((i % 2)) = 0 ] && echo a || echo b)"'" })' > /dev/null 2>&1
                sleep 0.6
            done
            mark "end $sc" ;;
        toast)
            mark "begin $sc"
            for i in $(seq 1 "${arg:-3}"); do
                "$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook notify "frame split $i" > /dev/null 2>&1
                sleep 1.2
            done
            sleep 7; mark "end $sc" ;;
        popup)
            key=${arg%%:*}; w=4; [ "$key" = "$arg" ] || w=${arg#*:}
            mark "begin open $key"
            r=$("$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook toggle "$key" 2> /dev/null)
            [ "$r" = open ] || echo "FRAME_SPLIT popup $key: the toggle answered '$r'"
            sleep 2.5; mark "end open $key"
            mark "begin rest $key"; sleep "$w"; mark "end rest $key"
            mark "begin close $key"
            "$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook toggle "$key" > /dev/null 2>&1
            sleep 1.5; mark "end close $key" ;;
        hook)   # hook:<name>:<arg>[:<wait s>]
            hn=${arg%%:*}; rest=${arg#*:}; ha=${rest%%:*}; w=3; [ "$ha" = "$rest" ] || w=${rest#*:}
            mark "begin $sc"
            "$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook "$hn" "$ha" > /dev/null 2>&1
            sleep "$w"; mark "end $sc" ;;
        osd)    # osd:<n>: n volume steps 0.3 s apart (the OSD opens, its level moves), then its close
            mark "begin $sc"
            for i in $(seq 1 "${arg:-4}"); do "$E" run quickshell ipc --path "$HERE/shell.qml" call osd volume up > /dev/null 2>&1; sleep 0.3; done
            sleep 3.5; mark "end $sc" ;;
        wview)  # wview[:<rounds>]: the weather popup opened, then its view switched mini > normal > detailed > normal > mini, 1.2 s each
            mark "begin wopen"
            "$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook toggle weather > /dev/null 2>&1
            sleep "${WV_OPEN_S:-3}"; mark "end wopen"        # WV_OPEN_S / WV_MINI_S short: the first switch lands in the cards' background build
            "$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook wview mini > /dev/null 2>&1
            sleep "${WV_MINI_S:-1.5}"; prof_off "wview-open"; WV_N=0
            for i in $(seq 1 "${arg:-2}"); do
                for v in normal detailed back mini; do
                    WV_N=$((WV_N + 1)); prof_on
                    mark "begin to-$v $i"; [ "$v" != back ] || v=normal
                    r=$("$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook wview "$v" 2> /dev/null)
                    [ "$r" = "$v" ] || echo "FRAME_SPLIT wview $v: the hook answered '$r'"
                    sleep 1.2; mark "end to-$([ $((WV_N % 4)) = 3 ] && echo back || echo "$v") $i"; prof_off "to-$v-$WV_N"
                done
            done
            prof_on
            "$E" run quickshell ipc --path "$HERE/shell.qml" call shell hook toggle weather > /dev/null 2>&1
            sleep 1.5 ;;
        spinner) # spinner:<n>: n title changes of ONE width (a terminal's spinner: the morph with no island move), 120 ms apart
            mark "begin $sc"
            "$E" run kitty --class pf-spin sh -c 'i=0; while [ $i -lt '"${arg:-20}"' ]; do i=$((i+1)); case $((i % 4)) in 0) c=a ;; 1) c=b ;; 2) c=c ;; *) c=d ;; esac; printf "\033]2;spin %s work\007" "$c"; sleep 0.12; done; sleep 0.4' > /dev/null 2>&1
            mark "end $sc" ;;
        ipc)
            call=${arg%%:*}; w=2; [ "$call" = "$arg" ] || w=${arg#*:}
            mark "begin $sc"
            "$E" run quickshell ipc --path "$HERE/shell.qml" call "${call%%.*}" "${call#*.}" > /dev/null 2>&1
            sleep "$w"; mark "end $sc" ;;
        *) echo "FRAME_SPLIT unknown scenario: $sc"; prof_off "$sc"; continue ;;
    esac
    prof_off "$sc"
    ran=$((ran + 1))
done
if [ -n "${PROFILE:-}" ]; then
    echo quit >&7; exec 7>&-
    sleep 0.5; kill "$PPID_PROF" 2> /dev/null; PPID_PROF=""
fi
sleep 0.5
kill "$QPID" 2> /dev/null; wait "$QPID" 2> /dev/null; QPID=""
[ -n "$GTPID" ] && { kill "$GTPID" 2> /dev/null; GTPID=""; }
python3 tools/dev/perf/frame_split.py "$LOG" "$MARKS" "$OUT"
rc=$?
# the env's own frame journal: the misses per 1000 frames of this run, by what was going on
J="/tmp/lrlk-$LOCK_ENV/state/lares/perf/frame-journal.jsonl"
[ -s "$J" ] || J=$(find "/tmp/lrlk-$LOCK_ENV/state" -name 'frame-journal.jsonl' 2> /dev/null | head -1)
if [ -n "$J" ] && [ -s "$J" ]; then
    cp "$J" "$OUT/frame-journal.jsonl"
    python3 tools/dev/perf/frame_journal_report.py "$OUT/frame-journal.jsonl" --top 6 > "$OUT/journal.txt" 2>&1
    grep -aE "^  bar|all windows|^ +[0-9]+ x " "$OUT/journal.txt" | head -40
fi
if [ -n "${PROFILE:-}" ]; then
    for q in "$OUT"/*.qtd; do
        [ -s "$q" ] && python3 tools/dev/perf/qml_profile.py "$q" --top "${PROFILE_TOP:-25}" --strip "$HERE/"
    done
fi
[ "$ran" -gt 0 ] || rc=1
exit "$rc"
