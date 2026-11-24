#!/usr/bin/env bash
# notes_editor_probe.sh -- the notes popup's keys and dictation contract on the real store + popup + editor (tools/dev/qml/notes_editor_probe.qml
# says what each check holds).
#
#   tools/dev/notes_editor_probe.sh                NOTESEDIT RESULT PASS | FAIL (<n>/<n> checks)
#   GRAB=<dir> tools/dev/notes_editor_probe.sh     also the editor's picture after the image and preedit checks (<dir>/*.png)
#   ARM=<name> tools/dev/notes_editor_probe.sh     one fault in the sandbox copy; the check it names must go red:
#     imgregex   the whole-line image pattern takes no <..> destination again: "renders as an image" goes red
#     escback    Escape goes back one step again (and answers nothing): "the open note stays open" goes red
#     shiftsplit Shift+Enter splits at the caret again: "a new empty line below" goes red
#     kbdown1    Down on the grid moves one tile, not a row: "keys: Down moves one row" goes red
#     kbright2   Right moves two tiles: "keys: Right moves one tile" goes red
#     kbend      End stops one short of the last tile: "keys: End reaches the last tile" goes red
#     kbenter    Enter ignores the highlight: "keys: Enter opens exactly the highlighted note" goes red
#     nosaveproblem  a failed write is not kept on the record: "words: a note whose folder refuses the write" goes red
#     noreadonly     the read-only note's problem line is gone: "words: a note that is not UTF-8" goes red
#     nonomatch      the empty-search words never show: "words: a search with no hit says 'No match'" goes red
#     backcloses     Escape in an open note closes whatever notes.jsonc says: "config: escape 'back'" goes red
#     arriveout      what the popup opens on is applied under a popup that is out: "config: openAt changes nothing" goes red
#     precommit  a preedit lives in the document (the edit goes through the model): "the document does not hold it" goes red
#
# Runs in a sandbox copy (tools/dev/sandbox.sh) with a private config / state and a fixture notes root built here (Probe.md, a symlinked
# Linked.md whose real folder is elsewhere, an attachment with a space in its name, Locked/Held.md in a read-only folder, a non-UTF-8 Zbin.md): never the user's notes.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/nep.XXXXXX")"
trap 'chmod -R u+w "$D" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ED=modules/notes/LiveMarkdownEditor.qml
POP=modules/notes/NotesPopup.qml
GRID=modules/notes/browse/NotesGrid.qml
MD=modules/common/components/Markdown.js
# An ARM is a patch script (exact-string anchors, FAIL when one is gone) run inside the sandbox copy.
ARMCMD="" NEEDLE=""
arm() {   # arm <file> <old> <new>
    printf '%s' "$2" > "$D/arm.old"; printf '%s' "$3" > "$D/arm.new"
    cat > "$D/arm.py" <<'P'
import sys
f, old, new = sys.argv[1], open(sys.argv[2]).read(), open(sys.argv[3]).read()
s = open(f).read()
if old not in s:
    print("FAIL anchor gone: " + old); sys.exit(1)
open(f, "w").write(s.replace(old, new, 1))
P
    ARMCMD="python3 $D/arm.py $1 $D/arm.old $D/arm.new"
}
case "${ARM:-}" in
    "") ;;
    imgregex) arm $MD '(<[^<>\n]*>|[^\s)<]+)' '([^\s)]+)'
              NEEDLE='NEP FAIL image: the pasted link renders as an image in a plain note' ;;
    escback)  arm $POP '        if (popup.store.query !== "")
            popup.store.setQuery("");
        return false;' '        if (popup.store.view === "editor") {
            popup.goBack();
            return;
        }
        return false;'
              NEEDLE='NEP FAIL escape: the open note stays open' ;;
    shiftsplit) arm $ED '        if (shift) {
            const end' '        if (false) {
            const end'
              NEEDLE='NEP FAIL shift+enter: a new empty line below' ;;
    precommit) arm $ED '        const tg = ed._dictationTarget();' '        ed.doc.replace(ed.doc.caret.line, ed.doc.caret.col, ed.doc.caret.line, ed.doc.caret.col, t);
        const tg = ed._dictationTarget();'
              NEEDLE='NEP FAIL dictation: the document does not hold it' ;;
    nosaveproblem) arm modules/notes/NotesStore.qml '            rec.problem = "Not saved: " + err;' '            rec.problem = "";'
              NEEDLE='NEP FAIL words: a note whose folder refuses the write' ;;
    noreadonly) arm modules/notes/NotesStore.qml '                rec.problem = "Read-only: not valid UTF-8 text";' '                rec.problem = "";'
              NEEDLE='NEP FAIL words: a note that is not UTF-8' ;;
    nonomatch) arm $GRID 'grid.searchKeys.length === 0 && grid.service' 'grid.searchKeys.length === 99 && grid.service'
              NEEDLE="NEP FAIL words: a search with no hit" ;;
    backcloses) arm $POP 'if (popup.escapeBack && ' 'if (false && '
              NEEDLE="NEP FAIL config: escape 'back'" ;;
    arriveout) arm modules/notes/NotesStore.qml '        if (where === "last" || store.holders > 0)' '        if (where === "last")'
              NEEDLE='NEP FAIL config: openAt changes nothing' ;;
    kbdown1)  arm $GRID '                i = cur + cols;' '                i = cur + 1;'
              NEEDLE='NEP FAIL keys: Down moves one row' ;;
    kbright2) arm $GRID '                i = cur + 1;
            else if (key === Qt.Key_Up)' '                i = cur + 2;
            else if (key === Qt.Key_Up)'
              NEEDLE='NEP FAIL keys: Right moves one tile' ;;
    kbend)    arm $GRID '            else if (key === Qt.Key_End)
                i = n - 1;' '            else if (key === Qt.Key_End)
                i = n - 2;'
              NEEDLE='NEP FAIL keys: End reaches the last tile' ;;
    kbenter)  arm $GRID '            if (grid.kbShown && grid.order.indexOf(grid.kbKey) >= 0)
                grid.openKey(grid.kbKey);' '            if (false)
                grid.openKey(grid.kbKey);'
              NEEDLE='NEP FAIL keys: Enter opens exactly the highlighted note' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache" "$D/ext"
printf '{"theme":"eva","mode":"%s"}\n' "${MODE:-light}" > "$D/cfg/theme/state.json"
[ -n "${GRAB:-}" ] && mkdir -p "$GRAB"
run='set -e; '"${ARMCMD:+$ARMCMD; }"'chmod -R u+w '"$D"'/notes 2>/dev/null || true; rm -rf '"$D"'/notes '"$D"'/ext; mkdir -p '"$D"'/ext; cp -a mockups/fixtures/notes '"$D"'/notes
printf "alpha beta\n- item one\ntail\n" > '"$D"'/notes/Probe.md
printf "# Linked\nabove\n" > '"$D"'/ext/Linked.md
ln -s '"$D"'/ext/Linked.md '"$D"'/notes/Linked.md
mkdir '"$D"'/notes/Locked; printf "held\n" > '"$D"'/notes/Locked/Held.md; chmod 555 '"$D"'/notes/Locked
printf "bin \377\376 bytes\n" > '"$D"'/notes/Zbin.md
python3 -c "
from PIL import Image, ImageDraw
im = Image.new(\"RGB\", (240, 150), (68, 128, 244)); d = ImageDraw.Draw(im); d.rectangle((20, 20, 220, 130), outline=(255, 255, 255), width=4)
im.save(\"'"$D"'/notes/.attachments/Pasted image 20261109-111327.png\")"
env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME='"$D"'/cfg XDG_STATE_HOME='"$D"'/state XDG_CACHE_HOME='"$D"'/cache NEP_NOTES='"$D"'/notes NEP_GRAB='"${GRAB:-}"' timeout -k 5 120 quickshell -p tools/dev/qml/notes_editor_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-notes-edit}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'NEP .*' | grep -a -v 'NEP RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'NEP RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; KEEP=1; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result NOTESEDIT "$D/log" 'NEP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
printf '%s\n' "$res" | sed 's/^NEP RESULT/NOTESEDIT RESULT/'
exit $rc
