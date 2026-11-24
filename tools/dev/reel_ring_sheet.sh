#!/usr/bin/env bash
# reel_ring_sheet.sh -- the reel slot's strips over a popup and over none, at rest and mid-merge, as PNGs
# (tools/dev/qml/reel_ring_sheet.qml: the shell's halo + ring on, a sky-blue popup; offscreen, a sandbox copy of the tree).
#
#   OUT=<dir> [TREE=<tree>] [MODE=light|dark] [THEME=eva] [CELLS=a,b] [BENCH=<n>] tools/dev/reel_ring_sheet.sh
#     BENCH  after each rest cell, timed grabs of the scene with and without the reel's layer over the popup (`SHEET bench`: the layer's
#            cost per frame; the harness's header)
#     TREE   the tree to render (default: this one); an old revision is `git archive <rev> | tar -x -C <dir>`: this tree's harness
#            is copied into it (it only uses API both revisions have)
#     OUT    where <cell>.png land (the window, 1:1: ZOOM 1)
#     RING_SHEET RESULT PASS | FAIL. Text is rendered without distance fields (QML_DISABLE_DISTANCEFIELD=1): it is not byte-reproducible across processes.
# Nothing touches the desktop: offscreen, a private copy of the tree, a private theme state and cache home (Qt writes its pipeline
# cache where XDG_CACHE_HOME says: left unset it rewrote ~/.cache/quickshell/qtpipelinecache-*/, the live shell's own).
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
TREE="${TREE:-$HERE}"
OUT="${OUT:?OUT=<dir> for the PNGs}"
mkdir -p "$OUT"
cd "$TREE" || exit 1
. "$HERE/tools/dev/result_lib.sh"
D="$(mktemp -d "${SCRATCH:-/tmp}/ringsheet.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"%s","mode":"%s"}\n' "${THEME:-eva}" "${MODE:-light}" > "$D/cfg/theme/state.json"
# this tree's harness in every tree rendered (an old revision's own knows fewer cells)
[ "$TREE" = "$HERE" ] || cp "$HERE/tools/dev/qml/reel_ring_sheet.qml" "$TREE/tools/dev/qml/"
run='env -u WAYLAND_DISPLAY XDG_CONFIG_HOME="'"$D/cfg"'" XDG_STATE_HOME="'"$D/state"'" XDG_CACHE_HOME="'"$D/cache"'" GRAB_DIR="'"$OUT"'" CELLS="'"${CELLS:-}"'" MERGE_T="'"${MERGE_T:-0.25}"'" BENCH="'"${BENCH:-}"'" BENCH_SCALE="'"${BENCH_SCALE:-}"'" QML_DISABLE_DISTANCEFIELD=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi timeout '"${RING_TIMEOUT:-600}"' quickshell -p tools/dev/qml/reel_ring_sheet.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-ringsheet}" "$TREE/tools/dev/sandbox.sh" bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'SHEET \(cell\|FAIL\|bench\)' | sed 's/^.*SHEET /SHEET /'
warn=$(rl_clean "$D/log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified|Failed to find shader|does not have a matching" | rl_platform_noise | head -5)
[ -n "$warn" ] && printf 'WARN %s\n' "$warn"
res=$(rl_result RING_SHEET "$D/log" 'SHEET RESULT .*'); rc=$?
fails=$(rl_clean "$D/log" | grep -ac 'SHEET FAIL ')
[ "$rc" = 0 ] && [ "$fails" -gt 0 ] && { res="RING_SHEET RESULT FAIL ($fails steps timed out: $D/log)"; rc=1; KEEP=1; }
rl_isnoresult "$res" && KEEP=1
printf '%s\n' "$res" | sed 's/^SHEET RESULT/RING_SHEET RESULT/'
exit "$rc"
