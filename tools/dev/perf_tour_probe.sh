#!/usr/bin/env bash
# perf_tour_probe.sh -- the perf tour (tools/shell/lares-perf-tour) against the NESTED mock shell: every action ran, the marks file and the
# report exist, everything the tour opened is closed again, --list / --dry work, and without a tty it refuses.
#
#   tools/dev/perf_tour_probe.sh [<outdir>]          (SANDBOX=/tmp/lares-sbx-<stream> LOCK_ENV=<=12 chars>)
#   ARM=badtoggle   the toggle call names a function the shell lacks: the popups must NOT have opened (the check "popups opened" fails)
#   ARM=notty       the tour is given a tty-less stdin without TOUR_NO_TTY_OK and must refuse (it does: that is the check; the ARM
#                   instead sets TOUR_NO_TTY_OK=1 on the refusal check and so the "refuses without a tty" check fails)
#
# The mock shell has `hook toggle` only through frame_split_ablate.py's `hooktoggle` patch (applied here to the sandbox copy), so the
# tour is told TOUR_TOGGLE_FN=hook-toggle until the live `shell toggle` is the shell's own. Ends in `PERF_TOUR RESULT PASS|FAIL`.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-/tmp/perf-tour-probe}"
if [ -z "${PT_INNER:-}" ]; then
    mkdir -p "$OUT" || exit 1
    OUT="$(cd "$OUT" && pwd)"
    exec "$HERE/tools/dev/sandbox.sh" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PT_INNER=1 ARM="${ARM:-}" bash tools/dev/perf_tour_probe.sh "$OUT"
fi
cd "$HERE" || exit 1
T="$HERE"      # this half stands in a sandbox copy (the outer half re-executed through sandbox.sh): never the tree
[ ! -e "$T/.git" ] || { echo "PERF_TOUR RESULT FAIL (the inner half was started in a work tree, not in a sandbox copy)"; exit 1; }
. tools/dev/result_lib.sh
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-ptp}"
LOG="$OUT/shell.log"
QPID=""
FAILS=0
chk() { if [ "$2" = 1 ]; then echo "  ok   $1"; else echo "  FAIL $1"; FAILS=$((FAILS + 1)); fi; }
cleanup() { [ -n "$QPID" ] && kill "$QPID" 2> /dev/null; "$E" down > /dev/null 2>&1; wait 2> /dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP
python3 tools/dev/perf/frame_split_ablate.py "$HERE" hooktoggle livetitle || { echo "PERF_TOUR RESULT FAIL (a patch's anchor is gone)"; exit 1; }
"$E" down > /dev/null 2>&1
OUTPUTS=1 LOCK_REFRESH=120 "$E" up > /dev/null || { echo "PERF_TOUR RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
B="$("$E" dir)"
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 LARES_FRAME_JOURNAL=1 \
    quickshell -n -p "$T/shell.qml" > "$LOG" 2>&1 &
QPID=$!
deadline=$(( $(date +%s) + 240 ))
until grep -aq "LARES settled" "$LOG" 2> /dev/null; do
    kill -0 "$QPID" 2> /dev/null || { rl_noresult PERF_TOUR "$LOG"; exit 1; }
    [ "$(date +%s)" -lt "$deadline" ] || { echo "PERF_TOUR RESULT FAIL (never settled: $LOG)"; exit 1; }
    sleep 0.5
done
sleep 3
TOUR="$HERE/tools/shell/lares-perf-tour"
export TOUR_HYPRCTL="$E hyprctl" TOUR_QS="$E run quickshell" TOUR_QML="$HERE/shell.qml" TOUR_RUN="$E run" TOUR_NOTIFY=hook TOUR_THEME=hook \
    TOUR_TOGGLE_FN=hook-toggle TOUR_STATE="$B/state/lares" TOUR_JOURNAL="$B/state/lares/perf/frame-journal.jsonl" TOUR_SKIP_SYSTEM=1 \
    TOUR_REPORT="$HERE/tools/dev/perf/frame_journal_report.py"
[ "${ARM:-}" = badtoggle ] && export TOUR_TOGGLE_FN=nosuchfn
echo "== --list / --dry / refusal"
"$TOUR" --list > "$OUT/list.txt" 2>&1; chk "--list prints the script and runs nothing" "$(grep -q 'popup open clock' "$OUT/list.txt" && grep -q 'osd mic mute' "$OUT/list.txt" && echo 1 || echo 0)"
"$TOUR" --dry > "$OUT/dry.txt" 2>&1 < /dev/null; chk "--dry validates the environment (DRY OK)" "$(grep -q '^DRY OK' "$OUT/dry.txt" && echo 1 || echo 0)"
if [ "${ARM:-}" = notty ]; then TOUR_NO_TTY_OK=1 "$TOUR" > "$OUT/notty.txt" 2>&1 < /dev/null; else "$TOUR" > "$OUT/notty.txt" 2>&1 < /dev/null; fi
rc=$?
chk "without a tty it refuses (rc 3, 'no tty')" "$([ "$rc" = 3 ] && grep -q 'no tty' "$OUT/notty.txt" && echo 1 || echo 0)"
[ "${ARM:-}" = notty ] && { pkill -f "lares-tour" 2> /dev/null; }
[ "${ARM:-}" = notty ] && exit 1
echo "== the tour (nested)"
ws0=$("$E" hyprctl -j activeworkspace | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
TOUR_NO_TTY_OK=1 "$TOUR" run --label probe > "$OUT/tour.txt" 2>&1
trc=$?
chk "the tour ended" "$([ "$trc" = 0 ] && echo 1 || echo 0)"
J=$(ls -t "$B"/state/lares/perf/tours/*.json 2> /dev/null | grep -v report | head -1)
chk "the marks file exists" "$([ -n "$J" ] && [ -s "$J" ] && echo 1 || echo 0)"
python3 - "$J" "$OUT/tour_check.txt" <<'PYEOF'
import json, subprocess, sys
j = json.load(open(sys.argv[1]))
acts = j["actions"]
want = subprocess.run([sys.executable, "tools/shell/lares-perf-tour", "--list"], capture_output=True, text=True).stdout
n_want = sum(1 for l in want.splitlines() if l.startswith("  ") and " s  " in l)
ran = {a["name"]: a for a in acts}
res = {
    "every action ran (%d of %d)" % (len(acts), n_want): len(acts) == n_want,
    "the popups opened and shut": all(ran["popup open %s" % o]["ok"] and ran["popup close %s" % o]["ok"] for o in ("clock", "weather", "player", "silicon")),
    "an OSD step, a toast, the kitties": ran["osd volume up x3"]["ok"] and ran["toast 1"]["ok"] and ran["kitty a (titles, spinner)"]["ok"] and ran["focus lares-tour-a #2"]["ok"],
    "the theme hook ran twice": ran["theme switch 1"]["ok"] and ran["theme switch back"]["ok"],
    "the report ran on the span": bool(j.get("report")) and "windows" in j["report"],
    "the facts were recorded": "snapshot" in j["facts"] and "monitors" in j["facts"],
}
with open(sys.argv[2], "w") as f:
    for k, v in res.items():
        f.write("%s\t%d\n" % (k, 1 if v else 0))
    for a in acts:
        if not a["ok"]:
            f.write("# not ok: %s: %s\n" % (a["name"], a["note"]))
PYEOF
while IFS=$'\t' read -r k v; do case $k in "#"*) echo "  $k" ;; *) chk "$k" "$v" ;; esac; done < "$OUT/tour_check.txt"
chk "the report printed its groups" "$(grep -q 'STUTTERS BY WHAT WAS GOING ON\|WINDOWS' "$OUT/tour.txt" && echo 1 || echo 0)"
echo "== everything is put back"
sleep 1
open=$("$E" run quickshell ipc --path "$T/shell.qml" call shell probe 2> /dev/null | python3 -c 'import json,sys; j=json.loads(sys.stdin.read().splitlines()[-1]); print(sum(1 for s in j["screens"].values() if s["popup"]["open"]))' 2> /dev/null)
chk "no popup is open" "$([ "${open:-x}" = 0 ] && echo 1 || echo 0)"
kit=$("$E" hyprctl -j clients | python3 -c 'import json,sys; print(sum(1 for c in json.load(sys.stdin) if c.get("class","").startswith("lares-tour")))')
chk "no tour window is left" "$([ "$kit" = 0 ] && echo 1 || echo 0)"
ws1=$("$E" hyprctl -j activeworkspace | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
chk "the workspace is where it was ($ws0)" "$([ "$ws0" = "$ws1" ] && echo 1 || echo 0)"
sed -n 1,200p "$OUT/tour.txt" | grep -v '^$' | tail -45
if [ "$FAILS" = 0 ]; then echo "PERF_TOUR RESULT PASS"; exit 0; fi
echo "PERF_TOUR RESULT FAIL ($FAILS check(s); $OUT)"; exit 1
