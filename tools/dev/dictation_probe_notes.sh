#!/usr/bin/env bash
# dictation_probe_notes.sh -- the notes editor's side of a dictation take (round 8: the user saw more text while speaking than he had
# said): the REAL notes popup and editor on a fixture note, offscreen, in seconds. tools/dev/qml/dictation_probe_notes.qml has the checks
# (P1 each partial's words once, P2 markup characters, P3 a commit and its answer, P4 the title).
#
#   tools/dev/dictation_probe_notes.sh               DICTNOTES RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/dictation_probe_notes.sh    one fault in the sandbox copy; the check it names must go red:
#     richinsert   the preedit goes in as it did (a rich-text `insert`, a leading space it may drop)          -> "DNP FAIL P1"
#     nocommitanswer  dictationCommit answers true for a commit it dropped (counted delivered, the words lost)   -> "DNP FAIL P3 a commit nothing can take"
#     titlecommit  a preedit in the title is not guarded: titleCommitted sees it                              -> "DNP FAIL P4"
#
# Runs in a sandbox copy (tools/dev/sandbox.sh) with a private config / state and a fixture notes root built here: never the user's notes.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/dnp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ED=modules/notes/LiveMarkdownEditor.qml
ARMCMD="" NEEDLE=""
arm() {   # arm <file> <old> <new>
    printf '%s' "$2" > "$D/arm.old"; printf '%s' "$3" > "$D/arm.new"
    cat > "$D/arm.py" <<'P'
import sys
f, old, new = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(f).read()
if s.count(old) != 1:
    print("DNP ARMLOST anchor found %d times: %s" % (s.count(old), old)); sys.exit(1)
open(f, "w").write(s.replace(old, new, 1))
P
    ARMCMD="python3 $D/arm.py $1 $D/arm.old $D/arm.new"
}
case "${ARM:-}" in
    "") ;;
    richinsert)
        arm $ED '        te.insert(col, te.textFormat === TextEdit.RichText ? ed._preeditHtml(t) : t);' '        te.insert(col, t);'
        NEEDLE='DNP FAIL P1' ;;
    nocommitanswer)
        arm $ED '        if (t === "" || !ed.dictationActive)
            return false;
        if (titleEdit.activeFocus) {' '        if (t === "" || !ed.dictationActive)
            return true;
        if (titleEdit.activeFocus) {'
        NEEDLE='DNP FAIL P3 a commit nothing can take' ;;
    titlecommit)
        arm $ED '                    ed._clearPreedit();
                    ed.titleCommitted(titleEdit.text);' '                    ed.titleCommitted(titleEdit.text);'
        NEEDLE='DNP FAIL P4' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'rm -rf '"$D"'/notes; cp -a mockups/fixtures/notes '"$D"'/notes
printf "alpha beta\nsecond\n" > '"$D"'/notes/Probe.md
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache DNP_NOTES='"$D"'/notes timeout -k 5 120 quickshell -p tools/dev/qml/dictation_probe_notes.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-dictnotes}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'DNP .*' | grep -a -v 'DNP RESULT' | cut -c1-500
oor=$(rl_clean "$D/log" | grep -a -c "setPosition: Position .* out of range")
warn=$(rl_clean "$D/log" | grep -a -E 'Unable to assign|Binding loop|non-existent|TypeError|ReferenceError' | head -3)
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q -F "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if rl_has "$D/log" 'DNP ARMLOST'; then echo "ARM $ARM: its anchor is gone -- it proves nothing"; exit 1; fi
    if ! rl_has "$D/log" 'DNP RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; KEEP=1; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result DICTNOTES "$D/log" 'DNP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
[ "$oor" -eq 0 ] || { echo "DNP FAIL P5 the editor warned $oor time(s): QTextCursor::setPosition out of range"; rc=1; }
[ -z "$warn" ] || { echo "DNP FAIL warnings: $warn"; rc=1; }
res=$(printf '%s\n' "$res" | sed 's/^DNP RESULT/DICTNOTES RESULT/')
[ "$rc" -eq 0 ] || { KEEP=1; res="${res%%)*})"; res="DICTNOTES RESULT FAIL ($D/log)"; }
printf '%s\n' "$res"
exit $rc
