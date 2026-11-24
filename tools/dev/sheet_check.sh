#!/usr/bin/env bash
# sheet_check.sh -- the regression check: a change the user must not notice is judged by it (the reference sheet, the logs, the names, the
# kept gates). The cleanup's steps were judged by it, and so is any change since.
#
#   tools/dev/sheet_check.sh <outdir> --baseline                  take the baseline: <outdir>/sheet (PNGs, logs), <outdir>/gates.txt
#   tools/dev/sheet_check.sh <outdir> [--step cN] [--map <json>] [--expect <file>]     judge the tree against the baseline
#   SHEET_BASELINE=<dir>/sheet ...                              the baseline to judge against (a --baseline run's <outdir>/sheet): required
#   --no-gates / --no-sheet                                     one half only (the verdict line says so)
#   ARM=token|padding|delete tools/dev/sheet_check.sh <outdir>    one fault in the sandbox copy: the check must FAIL and name the right states
#   ARM=all tools/dev/sheet_check.sh <outdir>                     the three; ends in SHEET_CHECK ARMS RESULT PASS|FAIL
#   SHEET_ENV_PREFIX=<p> ...                                    the prefix of its nested sessions' LOCK_ENV names (default shk)
#
# Ends in one SHEET_CHECK RESULT PASS|FAIL (...) line, and the exit status follows it. Run it from a work tree with no live config (the
# worktree of a step): a tree that holds one is refused, the sheet must not depend on the user's files.
#
# WHAT IT JUDGES
#   The sheet     every state of tools/dev/sheet_states.txt (tools/dev/sheet_render.py: how a state is held still) against the baseline's PNGs,
#                 composited on black, a pixel moved when any channel moved (tools/dev/sheet_compare.py). A state that moved is rendered once
#                 more: moved twice is a finding, a state that came back to 0 is printed as FLAKE, because a picture that does not repeat is
#                 a fault of the sheet and has to be fixed there. --expect <file> names what a step changes on purpose (see the compare).
#   The logs      of those runs and of the real shell.qml in shell_probe's nested Hyprland: no new warning line, numbers and addresses
#                 normalised; `Unable to assign`, `is not a type`, `Binding loop`, missing-file lines fail wherever they stand.
#   The names     --map: no reference left to a moved or deleted name in modules shell.qml tools helpers lock mockups themes assets (comments
#                 are listed until C7, the step that rewrites them, and fail from --step c7 on).
#   The gates     each through its own runner, read by its own RESULT line, an absent one being a FAIL: smoke of shell.qml and every mockup,
#                 shell_probe (all groups, and p13 with SHP_WATCH=1), config_loaders_probe, shell_hosted_m{1,2,3}_probe, theme_sync_probe,
#                 mockup_panel_test (every framework mockup), mockup_promote_probe, lock_supervisor_probe, lares_tool_probe, shader_compile_probe.
#
# THE WORLD. A gate runs as tools/dev/shell_gates.sh runs it: `box` in a tools/dev/sandbox.sh copy, `tree` from the tree on a stand-in runtime dir,
# `env` with tools/dev/lock_env.sh, each in a transient user scope with a private config (theme seeded), state and cache, no Wayland display
# and no Hyprland signature, and a deadline that stops the scope. One tree copy at a time: SANDBOX (default $SCRATCH/lares-sandbox-sheet) is
# shared and gone at the end; the nested sessions are LOCK_ENV names starting with SHEET_ENV_PREFIX.
set -u
{   # ONE BRACE GROUP: bash parses the whole script before running a line of it, so an edit under a live run changes nothing
cd "$(dirname "$0")/../.." || exit 2
ROOT=$(pwd)
. tools/dev/result_lib.sh
NAME=SHEET_CHECK
SCRATCH="${SCRATCH:-/tmp/lares-sheet}"
SB="${SANDBOX:-$SCRATCH/lares-sandbox-sheet}"
BASE="${SHEET_BASELINE:-}"
ENVP="${SHEET_ENV_PREFIX:-shk}"
smoke_env() {       # runs inside `gate ... env`: shell.qml and the files that hold a PanelWindow, as clients of a nested Hyprland, on the mock services
    local E="$ROOT/tools/dev/lock_env.sh" rc files
    export LOCK_ENV="${ENVP}smk"
    files="$1"
    tools/dev/sandbox.sh > /dev/null || { echo "smoke: the sandbox did not sync"; return 1; }
    "$E" down > /dev/null 2>&1
    OUTPUTS=2 "$E" up > /dev/null || { echo "smoke: the nested Hyprland did not come up"; "$E" down > /dev/null 2>&1; return 1; }
    # shellcheck disable=SC2086
    "$E" run env SHELL_SERVICES=mock bash -c 'cd "$1" && shift && SECS=25 exec bash tools/dev/smoke.sh "$@"' _ "$SANDBOX" $files 2>&1
    rc=${PIPESTATUS[0]}
    "$E" down > /dev/null 2>&1
    return "$rc"
}

if [ "${1:-}" = "--smoke-env" ]; then smoke_env "$2"; exit $?; fi
OUT=""; MAKE_BASE=0; STEP=""; MAP=""; EXPECT=""; DO_GATES=1; DO_SHEET=1
while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) MAKE_BASE=1; shift ;;
        --step) STEP="$2"; shift 2 ;;
        --map) MAP="$2"; shift 2 ;;
        --expect) EXPECT="$2"; shift 2 ;;
        --no-gates) DO_GATES=0; shift ;;
        --no-sheet) DO_SHEET=0; shift ;;
        --*) echo "unknown option $1"; exit 2 ;;
        *) if [ -z "$OUT" ]; then OUT="$1"; shift; else echo "one outdir"; exit 2; fi ;;
    esac
done
[ -n "$OUT" ] || { sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 2; }
[ "$MAKE_BASE" = 1 ] || [ -n "$BASE" ] || { echo "$NAME RESULT FAIL (no baseline: SHEET_BASELINE=<a --baseline run's outdir>/sheet)"; exit 2; }
mkdir -p "$OUT" "$SCRATCH"; OUT="$(cd "$OUT" && pwd)"
ARM="${ARM:-}"
START=$SECONDS
FINDINGS=()
finding() { FINDINGS+=("$1"); echo "FINDING: $1"; }

# ---- ARM=all: each fault in its own run, and each must fail on what it broke -------------------------------------------------------------------
if [ "$ARM" = all ]; then
    rc=0
    declare -A WANT=( [token]='^MOVED mockup\.[a-z_]*\.dark|^MOVED shell\.[a-z-]*\.dark' [padding]='^MOVED shell\.open-weather' [delete]='StocksIndexStrip.*is not a type|is not a type.*StocksIndexStrip' )
    declare -A NOT=( [token]='^MOVED .*\.light' [padding]='^MOVED (shell\.(open-(notes|clock|llm)|rest)|mockup\.(clock|notes))' [delete]='^MOVED (shell\.(open-weather|open-clock)\.|mockup\.(clock|weather_popup))' )
    # what a fault may move besides its own: the theme popup draws BOTH halves of every pair from the theme files, so a dark token
    # moves its light states too, and must
    declare -A EXEMPT=( [token]='^MOVED (mockup\.theme|shell\.open-theme)\.' [padding]='^$' [delete]='^$' )
    for a in token padding delete; do
        log="$OUT/arm-$a.log"
        ARM="$a" bash "$ROOT/tools/dev/sheet_check.sh" "$OUT/arm-$a" > "$log" 2>&1; arc=$?
        last=$(grep -a "^$NAME RESULT" "$log" | tail -1)
        states=$(grep -a -E '^(MOVED|GONE) ' "$log" | sed 's/:.*//' | sort -u)
        n=$(printf '%s\n' "$states" | grep -c .)
        if [ "$arc" = 0 ]; then
            echo "$NAME ARM $a: STAYED GREEN ($last)"; rc=1
        elif ! grep -a -q -E "${WANT[$a]}" "$log"; then
            echo "$NAME ARM $a: FAILED, BUT NOT ON ITS STATES ($last)"; rc=1
        elif grep -a -E "${NOT[$a]}" "$log" | grep -a -q -v -E "${EXEMPT[$a]}"; then
            echo "$NAME ARM $a: A STATE IT DOES NOT TOUCH MOVED: $(grep -a -E "${NOT[$a]}" "$log" | grep -a -v -E "${EXEMPT[$a]}" | head -2 | tr '\n' ' ')"; rc=1
        else
            echo "$NAME ARM $a: FAILED AS IT MUST ($n states; first: $(printf '%s\n' "$states" | head -3 | sed 's/^[A-Z]* //' | tr '\n' ' '))"
        fi
    done
    [ "$rc" = 0 ] && echo "$NAME ARMS RESULT PASS" || echo "$NAME ARMS RESULT FAIL"
    exit "$rc"
fi
if [ -n "$ARM" ]; then
    [ "$MAKE_BASE" = 0 ] || { echo "$NAME RESULT FAIL (an ARM is never a baseline)"; exit 2; }
    DO_GATES=0                       # a fault in the copy is the sheet's and the log's to find; the gates run on the tree
fi

# ---- the tree must hold no live config: the sheet must not depend on the user's files --------------------------------------------------------
for n in shell notifications osd silicon launcher clipboard stocks weather windowtray calendars idle llm player bridge panorama; do
    for e in jsonc json; do
        [ -e "$n.$e" ] && { echo "$NAME RESULT FAIL (the tree holds a live config: $n.$e; run from a worktree)"; exit 2; }
    done
done
[ -e .env ] && { echo "$NAME RESULT FAIL (the tree holds a .env; run from a worktree)"; exit 2; }

export SCRATCH
export SANDBOX="$SB"
cleanup_all() {
    [ -n "${CUR_UNITS:-}" ] && for u in $CUR_UNITS; do systemctl --user stop "$u.scope" > /dev/null 2>&1; done
    rm -rf "$SB" "$SB.lrrt" "$SB-out"         # $SB-out: shell_hosted_m3's own output beside the copy
}
trap cleanup_all EXIT
trap 'cleanup_all; exit 130' INT TERM HUP

# ---- the sheet ------------------------------------------------------------------------------------------------------------------------------
SHEET_LINE="sheet not run"
FLAKES=""
sheet_part() {
    python3 -B tools/dev/sheet_render.py "$OUT/sheet" 2>&1 | tail -12
    if [ "$MAKE_BASE" = 1 ]; then
        SHEET_LINE="sheet $(find "$OUT/sheet/png" -name '*.png' | wc -l) states taken"
        [ -z "$(python3 -B tools/dev/sheet_render.py --list | while read -r s; do [ -f "$OUT/sheet/png/$s.png" ] || echo "$s"; done)" ] || finding "the baseline has no picture for every state"
        return
    fi
    [ -d "$BASE/png" ] || { finding "no baseline at $BASE"; SHEET_LINE="no baseline"; return; }
    local args=(sheet "$BASE" "$OUT/sheet"); [ -n "$EXPECT" ] && args+=(--expect "$EXPECT")
    python3 -B tools/dev/sheet_compare.py "${args[@]}" > "$OUT/sheet_compare.txt" 2>&1
    cat "$OUT/sheet_compare.txt"
    if [ -s "$OUT/sheet/moved.txt" ] && [ "${NO_RETRY:-0}" != 1 ] && [ -z "$ARM" ]; then
        # once more, those alone: a real change moves them again, a picture that does not repeat comes back to 0
        local re; re="^($(sed 's/\./\\./g' "$OUT/sheet/moved.txt" | paste -sd'|'))$"
        ONLY="$re" python3 -B tools/dev/sheet_render.py "$OUT/retry" > "$OUT/retry.log" 2>&1
        ONLY="$re" python3 -B tools/dev/sheet_compare.py sheet "$BASE" "$OUT/retry" > "$OUT/retry_compare.txt" 2>&1
        # A FLAKE is a state the second render DREW and the second compare JUDGED still. A compare that never printed its SHEET line judged
        # nothing, and a state with no picture the second time is still gone: C3's two deleted battery states read as "flaky" and PASS
        # through exactly that (the compare crashed on a render that made no png dir).
        if ! grep -a -q '^SHEET ' "$OUT/retry_compare.txt"; then
            finding "the second render of the moved states was not judged ($OUT/retry_compare.txt)"
        else
            while read -r s; do
                grep -a -q -E "^(MOVED|GONE) $(printf '%s' "$s" | sed 's/\./\\./g'):" "$OUT/retry_compare.txt" && continue
                [ -f "$OUT/retry/png/$s.png" ] || continue
                FLAKES="$FLAKES $s"; echo "FLAKE $s: moved once, 0 px when rendered again"
            done < "$OUT/sheet/moved.txt"
        fi
        grep -a -E '^(MOVED|GONE|NEW) ' "$OUT/retry_compare.txt" | sed 's/^/again: /'
        if grep -a -q -E '^(MOVED|GONE) ' "$OUT/retry_compare.txt" || grep -a -q '^NEW ' "$OUT/sheet_compare.txt"; then
            finding "the sheet moved"
        fi
    elif grep -a -q -E '^(MOVED|GONE|NEW) ' "$OUT/sheet_compare.txt"; then
        finding "the sheet moved"
    fi
    SHEET_LINE="$(grep -a '^SHEET ' "$OUT/sheet_compare.txt" | tail -1 | sed 's/^SHEET //')"
    [ -n "$FLAKES" ] && SHEET_LINE="$SHEET_LINE, flaky:$FLAKES"
}
[ "$DO_SHEET" = 1 ] && sheet_part

# ---- the gates ------------------------------------------------------------------------------------------------------------------------------
GATE_N=0; GATE_RED=0
CUR_UNITS=""
: > "$OUT/gates.txt"
# gate <name> <kind> <seconds> <ERE of the verdict, or smoke:<n>> <words...>
gate() {
    local key=$1 kind=$2 tmo=$3 re=$4; shift 4
    local d="$OUT/gates/$key" log sc unit start rt="" rc=0
    log="$d/run.log"
    rm -rf "$d"; mkdir -p "$d/cfg/theme" "$d/state" "$d/cache"
    printf '{"theme":"eva","mode":"light"}\n' > "$d/cfg/theme/state.json"
    sc="$SCRATCH/g-${key:0:24}"; rm -rf "$sc"; mkdir -p "$sc"
    local base_u=(-u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u ARM -u ONLY -u ONLY_ARMS -u MODE -u SMOKE -u PHASES -u TIMEOUT -u RETRY -u KEEP -u BEFORE -u SECS -u TRIAL -u SANDBOX)
    local base_s=("XDG_CONFIG_HOME=$d/cfg" "XDG_STATE_HOME=$d/state" "XDG_CACHE_HOME=$d/cache" "SCRATCH=$sc" "QT_QPA_PLATFORMTHEME=")
    local cmd=()
    case "$kind" in
        box) cmd=("$ROOT/tools/dev/sandbox.sh" "${base_u[@]}" "${base_s[@]}" QT_QPA_PLATFORM=offscreen "$@") ;;
        tree|env)
            rt=$(mktemp -d /tmp/lrrt-shk.XXXXXX); chmod 700 "$rt"
            ( shopt -s dotglob nullglob
              for e in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/*; do b=${e##*/}; [ "$b" = quickshell ] || ln -s "$e" "$rt/$b"; done )
            if [ "$kind" = tree ]; then
                cmd=(env "${base_u[@]}" "${base_s[@]}" "XDG_RUNTIME_DIR=$rt" QT_QPA_PLATFORM=offscreen "SANDBOX=$SB" "$@")
            else
                cmd=(env "${base_u[@]}" "${base_s[@]}" "SANDBOX=$SB" "$@")
            fi ;;
        *) echo "bad kind $kind"; return ;;
    esac
    unit="sheetcheck-$key-$$"
    CUR_UNITS="$CUR_UNITS $unit"
    start=$SECONDS
    (
        [ "$kind" = box ] && export SANDBOX="$SB"
        systemd-run --user --scope --quiet --collect -u "$unit" --expand-environment=no -- "${cmd[@]}" < /dev/null > "$log" 2>&1
        echo "$?" > "$d/rc"
    ) &
    local pid=$!
    while kill -0 "$pid" 2> /dev/null && [ $((SECONDS - start)) -lt "$tmo" ]; do sleep 1; done
    if kill -0 "$pid" 2> /dev/null; then
        systemctl --user stop "$unit.scope" 2> /dev/null
        echo "TIMEOUT after ${tmo}s (the gate's scope was stopped)" >> "$log"
        echo 124 > "$d/rc"
    fi
    wait "$pid" 2> /dev/null
    systemctl --user stop "$unit.scope" > /dev/null 2>&1
    [ -n "$rt" ] && rm -rf "$rt"
    # the real shell's log, kept for the log judge (SHP_KEEP keeps it past a PASS)
    [ "$key" = shell_probe ] && cp "$sc"/shellprobe-*/shell.log "$d/shell.log" 2> /dev/null
    rm -rf "$sc"
    rc=$(cat "$d/rc" 2> /dev/null || echo "?")
    local res green=0
    case "$re" in
        smoke:*)
            local want=${re#smoke:} clean
            clean=$(rl_clean "$log" | grep -a -c -E '\.qml +clean$')
            if [ "$rc" = 0 ] && [ "$clean" = "$want" ]; then res="SMOKE RESULT PASS ($clean files clean)"; green=1
            else res="SMOKE RESULT FAIL ($clean of $want files clean, rc $rc: $log)"; fi ;;
        themesync)      # this runner's two verdicts have no RESULT word: the pixels', then the static one
            if [ "$rc" = 0 ] && rl_has "$log" '^THEME_SYNC PASS' && rl_has "$log" '^THEME_SYNC static PASS'; then
                res="THEME_SYNC RESULT PASS ($(rl_clean "$log" | grep -a '^THEME_SYNC PASS' | tail -1 | cut -c1-110))"; green=1
            else res="THEME_SYNC RESULT FAIL (rc $rc: $log)"; fi ;;
        *)
            res=$(rl_clean "$log" | grep -a -o -E "$re.*" | tail -1)
            if [ -z "$res" ]; then res="$key RESULT FAIL (no result: $log)"
            elif [ "$rc" = 0 ] && printf '%s' "$res" | grep -q "RESULT PASS"; then green=1
            elif [ "$rc" != 0 ] && printf '%s' "$res" | grep -q "RESULT PASS"; then res="$res  (but rc $rc: $log)"; fi ;;
    esac
    local line
    line=$(printf '%-24s %s %5ss  %s' "$key" "$([ "$green" = 1 ] && echo GREEN || echo RED)  " "$((SECONDS - start))" "$(printf '%s' "$res" | cut -c1-150)")
    echo "$line" | tee -a "$OUT/gates.txt"
    [ "$green" = 1 ] || echo "$key" >> "$OUT/gates_red.txt"
}

mockups() { grep -l 'MockupWindow' mockups/*.qml; }
OLD_MOCKUPS="mockups/groove_slider.qml mockups/shadowbox.qml mockups/terminal.qml mockups/workspaces.qml mockups/audio_button.qml"

gates_part() {
    rm -f "$OUT/gates_red.txt"
    tools/dev/sandbox.sh > /dev/null || { finding "the sandbox did not sync"; return; }
    local all m pw off n
    all="$(mockups) $(for m in $OLD_MOCKUPS; do [ -f "$m" ] && echo "$m"; done)"
    pw=""; off=""
    for m in $all; do
        if grep -q 'PanelWindow' "$m"; then pw="$pw $m"; else off="$off $m"; fi
    done
    # shellcheck disable=SC2086
    gate smoke_offscreen box 900 "smoke:$(echo $off | wc -w)" QT_QUICK_BACKEND=rhi SECS=5 bash tools/dev/smoke.sh $off
    # shellcheck disable=SC2086
    gate smoke_nested env 900 "smoke:$(echo shell.qml $pw | wc -w)" bash "$ROOT/tools/dev/sheet_check.sh" --smoke-env "shell.qml $pw"
    gate shell_probe env 1500 'SHELL_PROBE RESULT' LOCK_ENV="${ENVP}shp" SHP_KEEP=1 bash tools/dev/shell_probe.sh
    gate shell_probe_hot env 900 'SHELL_PROBE RESULT' LOCK_ENV="${ENVP}shh" SHP_WATCH=1 ONLY=p13 bash tools/dev/shell_probe.sh
    gate config_loaders box 300 'CONFIG_LOADERS RESULT' bash tools/dev/config_loaders_probe.sh
    gate shell_hosted_m1 box 600 'SHELL_HOSTED_M1 RESULT' bash tools/dev/shell_hosted_m1_probe.sh
    gate shell_hosted_m2 box 600 'SHELL_HOSTED_M2 RESULT' bash tools/dev/shell_hosted_m2_probe.sh
    gate shell_hosted_m3 box 600 'SHELL-HOSTED-M3 RESULT' bash tools/dev/shell_hosted_m3_probe.sh
    gate theme_sync box 300 themesync bash tools/dev/theme_sync_probe.sh
    gate mockup_promote_probe tree 1800 'MOCKUP_PROMOTE_PROBE RESULT' bash tools/dev/mockup_promote_probe.sh
    gate lock_supervisor env 900 'LOCK_SUPERVISOR RESULT' A1_ENV_PREFIX="$ENVP" bash tools/dev/lock_supervisor_probe.sh
    gate lares_tool box 1500 'LARES_TOOL RESULT' bash tools/dev/lares_tool_probe.sh
    gate shader_compile tree 300 'SHADER_COMPILE RESULT' bash tools/dev/shader_compile_probe.sh
    n=0
    for m in $(mockups); do
        gate "panel_$(basename "$m" .qml)" box 240 'PANEL_TEST RESULT' bash tools/dev/mockup_panel_test.sh "$m" &
        n=$((n + 1))
        if [ "$n" -ge 4 ]; then wait -n; n=$((n - 1)); fi
    done
    wait
    # A gate that was red at the baseline as well is still a finding (nothing here is excused), but it is named as such: the cure is the
    # gate's, not this step's.
    local was="$(dirname "$BASE")/gates_red.txt" g said=""
    if [ -f "$OUT/gates_red.txt" ]; then
        for g in $(cat "$OUT/gates_red.txt"); do
            if [ "$MAKE_BASE" = 0 ] && [ -f "$was" ] && grep -q -x "$g" "$was"; then said="$said $g(red at the baseline too)"; else said="$said $g"; fi
        done
        finding "red gates:$said"
    fi
}
GATE_LINE="gates not run"
if [ "$DO_GATES" = 1 ]; then
    gates_part
    GATE_LINE="gates $(grep -c ' GREEN ' "$OUT/gates.txt") green, $(grep -c ' RED ' "$OUT/gates.txt") red"
fi

# ---- the logs -------------------------------------------------------------------------------------------------------------------------------
LOG_LINE="logs not judged"
if [ "$DO_SHEET" = 1 ]; then
    if [ -f "$OUT/gates/shell_probe/shell.log" ]; then cp "$OUT/gates/shell_probe/shell.log" "$OUT/sheet/logs/realshell.log"; fi
    if [ "$MAKE_BASE" = 1 ]; then
        python3 -B tools/dev/sheet_compare.py logs "$OUT/sheet" "$OUT/sheet" > "$OUT/logs_compare.txt" 2>&1
    else
        python3 -B tools/dev/sheet_compare.py logs "$BASE" "$OUT/sheet" > "$OUT/logs_compare.txt" 2>&1
    fi
    [ $? = 0 ] || finding "the logs: $(grep -a -c '^LOG ' "$OUT/logs_compare.txt") lines"
    grep -a '^LOG ' "$OUT/logs_compare.txt" | head -20
    LOG_LINE="$(grep -a '^LOGS ' "$OUT/logs_compare.txt" | sed 's/^LOGS //')"
fi

# ---- the names ------------------------------------------------------------------------------------------------------------------------------
MAP_LINE="no map"
if [ -n "$MAP" ]; then
    args=(map "$MAP" --out "$OUT"); [ -n "$STEP" ] && args+=(--step "$STEP")
    python3 -B tools/dev/sheet_compare.py "${args[@]}" > "$OUT/map_compare.txt" 2>&1 || finding "dangling names"
    grep -a '^MAP ' "$OUT/map_compare.txt" | head -20
    MAP_LINE="$(grep -a '^MAP ' "$OUT/map_compare.txt" | tail -1 | sed 's/^MAP //')"
fi

# ---- the verdict ----------------------------------------------------------------------------------------------------------------------------
secs=$((SECONDS - START))
what="${STEP:+$STEP: }$SHEET_LINE; logs $LOG_LINE; map $MAP_LINE; $GATE_LINE; ${secs}s"
if [ ${#FINDINGS[@]} -eq 0 ]; then
    echo "$NAME RESULT PASS ($what)"
    exit 0
fi
echo "$NAME RESULT FAIL (${#FINDINGS[@]} findings; $what)"
exit 1
}
