#!/usr/bin/env bash
# lockveil_render.sh -- the lock's veils at held clock times, offscreen, from a private copy of a tree
# (tools/dev/qml/lockveil_render.qml has the job format).
#
#   tools/dev/lockveil_render.sh JOBS.json OUTDIR [--tree DIR] [--mode light|dark]
#   tools/dev/lockveil_render.sh --sweep SWEEP.json OUTDIR [--tree DIR]
#
# --tree renders ANOTHER tree's veils (an old revision: `git archive <rev> | tar -x -C DIR`) with THIS tree's
# harness, so a before/after sheet is the same jobs on two trees. The copy holds the tree's modules, themes and
# the lock fixtures, and this tree's harness; it runs with a private runtime dir and a private config home whose
# theme state is seeded with --mode (the user's own theme is never read or written), and both go when it ends.
# Ends in LOCKVEIL_RENDER RESULT PASS|FAIL (the harness's own line; none is a FAIL).
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
. "$HERE/tools/dev/result_lib.sh"
JOBS="" SWEEP="" OUT="" TREE="$HERE" MODE=light
while [ $# -gt 0 ]; do
    case "$1" in
        --sweep) SWEEP="$(realpath "$2")"; shift 2 ;;
        --tree) TREE="$(realpath "$2")"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        *) if [ -z "$JOBS" ] && [ -z "$SWEEP" ]; then JOBS="$(realpath "$1")"; else OUT="$1"; fi; shift ;;
    esac
done
[ -n "$OUT" ] && { [ -n "$JOBS" ] || [ -n "$SWEEP" ]; } || { sed -n '2,10p' "$0"; exit 2; }
mkdir -p "$OUT"; OUT="$(realpath "$OUT")"
W=$(mktemp -d /tmp/lrlvr.XXXXXX) || exit 1
cleanup() { rm -rf "$W"; }
trap cleanup EXIT
mkdir -p "$W/t/tools/dev/qml" "$W/t/mockups" "$W/rt" "$W/cfg/theme" "$W/state" "$W/cache"
chmod 700 "$W/rt"
rsync -a --exclude '.qmlls.ini' "$TREE/modules" "$TREE/themes" "$W/t/" || { echo "LOCKVEIL_RENDER RESULT FAIL (copy)"; exit 1; }
rsync -a "$TREE/mockups/fixtures" "$W/t/mockups/" 2> /dev/null
# (the fixtures moved in the cleanup: an old tree keeps them under tests/)
[ -d "$W/t/mockups/fixtures/lockscreen" ] || { mkdir -p "$W/t/mockups/fixtures"; cp -r "$TREE/tests/fixtures/lockscreen" "$W/t/mockups/fixtures/" 2> /dev/null; }
cp "$HERE/tools/dev/qml/lockveil_render.qml" "$W/t/tools/dev/qml/"
ln -s ../../../modules "$W/t/tools/dev/qml/modules"
printf '{"theme":"eva","mode":"%s"}\n' "$MODE" > "$W/cfg/theme/state.json"
LOG="$OUT/render-$MODE.log"
env XDG_RUNTIME_DIR="$W/rt" XDG_CONFIG_HOME="$W/cfg" XDG_STATE_HOME="$W/state" XDG_CACHE_HOME="$W/cache" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QS_DISABLE_CRASH_HANDLER=1 \
    JOBS="$JOBS" SWEEP="$SWEEP" OUT="$OUT" \
    timeout -k 5 "${LVR_TMO:-600}" quickshell -n -p "$W/t/tools/dev/qml/lockveil_render.qml" > "$LOG" 2>&1
r=$(rl_clean "$LOG" | grep -ao "LOCKVEIL_RENDER RESULT.*" | tail -1)
[ -n "$r" ] || { rl_noresult LOCKVEIL_RENDER "$LOG"; exit 1; }
echo "$r"
case "$r" in *PASS*) exit 0 ;; *) exit 1 ;; esac
