#!/usr/bin/env bash
# field_shape_qv4.sh -- the field-shape differential in QV4, the engine the shell runs GooeyGeometry.js in (node is V8: it gives an
# algorithm's share, never its cost -- CLAUDE.md). tools/dev/perf/field_shape_qv4.qml.in is copied (as field_shape_qv4.qml) into a scratch dir beside the two
# GooeyGeometry.js it compares (A.js, B.js) and field_shape_lib.js, and run in /usr/lib/qt6/bin/qml on the offscreen platform (no
# window anywhere, no quickshell, nothing of the desktop's touched).
#
#   tools/dev/perf/field_shape_qv4.sh <corpus.jsonl> <A> <B> identity|bench [passes] [class regex]
#       <A> / <B>   a GooeyGeometry.js file, or <rev>:<path> (git show)
#   QV4_GC_TIMELIMIT=2 as the shell runs (shell.qml's pragma); FS_ARM=const|order|state puts the replay's self-test fault into B
#   (field_shape_replay.js): identity must then FAIL.
# Ends in `FIELD_SHAPE_QV4 RESULT PASS|FAIL`.
set -u
HERE="$(cd "$(dirname "$0")/../../.." && pwd)"
[ $# -ge 4 ] || { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
CORPUS="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
A=$2 B=$3 MODE=$4 PASSES=${5:-5} CLS=${6:-}
W=$(mktemp -d "${TMPDIR:-/tmp}/fsqv4.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
src() {
    if [ -f "$1" ]; then cat "$1"; else git -C "$HERE" show "${1%%:*}:${1#*:}"; fi
}
src "$A" > "$W/A.js" || { echo "FIELD_SHAPE_QV4 RESULT FAIL (cannot read $A)"; exit 1; }
src "$B" > "$W/B.js" || { echo "FIELD_SHAPE_QV4 RESULT FAIL (cannot read $B)"; exit 1; }
if [ -n "${FS_ARM:-}" ]; then
    node -e '
        const fs = require("fs"), [f, name] = process.argv.slice(1);
        const swaps = { const: ["const BLEED = 1.5;", "const BLEED = 1.5000001;"],
                        order: ["fillets.push({ vx: vb, vy: va, ex: rb, ey: ra,", "fillets.push({ vy: va, vx: vb, ex: rb, ey: ra,"],
                        state: ["state: { rel: nextRel, void: nextVoid },", "state: { rel: nextRel, void: nextVoid, armed: 1 },"] };
        const s = swaps[name], t = fs.readFileSync(f, "utf8");
        if (!s || t.split(s[0]).length !== 2) { console.log("FIELD_SHAPE_QV4 RESULT FAIL (the arm " + name + "s anchor is gone)"); process.exit(1); }
        fs.writeFileSync(f, t.replace(s[0], s[1]));' "$W/B.js" "$FS_ARM" || exit 1
fi
cp "$HERE/tools/dev/perf/field_shape_lib.js" "$W/" && cp "$HERE/tools/dev/perf/field_shape_qv4.qml.in" "$W/field_shape_qv4.qml"
LOG="$W/log"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QML_XHR_ALLOW_FILE_READ=1 QT_FORCE_STDERR_LOGGING=1 \
    QV4_GC_TIMELIMIT="${QV4_GC_TIMELIMIT:-2}" XDG_CACHE_HOME="$W/cache" QML_DISABLE_DISK_CACHE=1 \
    /usr/lib/qt6/bin/qml "$W/field_shape_qv4.qml" -- "$CORPUS" "$MODE" "$PASSES" "$CLS" > "$LOG" 2>&1
sed -n 's/^.*\(FSQV4 \)/\1/p; s/^.*\(  [AB]: \)/\1/p; s/^.*\(FIELD_SHAPE_QV4 RESULT\)/\1/p' "$LOG"
if ! grep -q "FIELD_SHAPE_QV4 RESULT" "$LOG"; then
    head -20 "$LOG"
    echo "FIELD_SHAPE_QV4 RESULT FAIL (no result)"
    exit 1
fi
res=$(grep "FIELD_SHAPE_QV4 RESULT" "$LOG" | tail -1)
if [ -n "${FS_ARM:-}" ]; then
    case $res in *FAIL*differ*) echo "FIELD_SHAPE_QV4 ARM $FS_ARM caught"; exit 0 ;; *) echo "FIELD_SHAPE_QV4 ARM $FS_ARM NOT caught"; exit 1 ;; esac
fi
case $res in *PASS*) exit 0 ;; *) exit 1 ;; esac
