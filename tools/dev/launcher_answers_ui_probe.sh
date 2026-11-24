#!/usr/bin/env bash
# launcher_answers_ui_probe.sh -- the launcher's quick answers, UI side (round 13): the lifecycle in LauncherService, the answer row in
# LauncherPopup, the keys, the copy, the history. tools/dev/qml/launcher_answers_probe.qml through the REAL service and popup, with the
# stand-in child tools/dev/fixtures/launcher_answers_stub.py and a copy command that appends to a file. Nothing of the machine is touched:
# private config / state / cache / data homes, offscreen, no clipboard, no daemon, no desktop window.
#
#   tools/dev/launcher_answers_ui_probe.sh             LAUNCHER_ANSWERS_UI RESULT PASS | FAIL
#   ARM=<name> tools/dev/launcher_answers_ui_probe.sh  the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     nostale     the reader keeps a reply whatever its id                                     -> "stale: a reply for an earlier query is dropped"
#     askempty    an empty query still asks the child                                          -> "empty: the empty query asked nothing"
#     noreplace   a second reply with the same id is ignored (pending stays)                   -> "pending: its landed reply replaced it"
#     entercopyless  Enter on the answer row launches / does nothing instead of copying        -> "enter: copies the main form"
#     enterstays  Enter does not close the launcher                                            -> "enter: closes the launcher"
#     shiftcloses Shift+Enter closes the launcher                                              -> "shift+enter: the launcher stays"
#     nocopied    the expr slot never says Copied                                              -> "shift+enter: the expr slot says Copied"
#     altmain     a click on an alt copies the main form                                       -> "alt: a click on an alt copies that alt"
#     nohistory   the history is never written to the state file                               -> "recall: Up on an empty query brings back"
#     recallnonempty  Up recalls even with a query typed                                       -> "none: Up on a non-empty query is not a recall"
#     noanswerkeys  an answerless Enter is swallowed by the answer path                        -> "none: Enter launches the app as before"
#     norestart   a dead child is never started again                                          -> "restart: a child that died"
#     eager       the child starts with the service, not the first query                       -> "lazy: no child before the first non-empty query"
#     noroom      the list does not give the answer row its slot                               -> "row: the popup did not resize"
#     copiedstuck the Copied line never goes                                                   -> "shift+enter: Copied goes after"
#     recalltyping typing does not leave the recall                                            -> "recall: typing leaves the recall"
#     downnewer   Down in a recall does nothing                                                -> "recall: Down walks back"
#     notmissing  a missing script is taken for a good one                                     -> "missing: no python or script"
#     nodefaultsel  the answer is not highlighted when it lands                                -> "row: highlighted by default"
#     nonomatch   the "No match" words never show                                                    -> "nomatch: a query nothing matches says 'No match'"
#     alwaysnomatch  the words show whatever the grid holds                                        -> "nomatch: a query with a match says nothing"
#     noanswerhide   the words show beside a quick answer                                          -> "nomatch: a quick answer stands in for the words"
#     nowaiting   the words flash while the answer child's reply is out                            -> "nomatch: no words while the quick answer's reply is still out"
#     keepslaunch a launch leaves its query to the next open                                   -> "file: keepQuerySec: a launch leaves none"
#     nooptions   the child is not told what launcher.jsonc says                               -> "file: the child is told what answers says"
#     nocodewords a script's failure reads "exit code N" again                                     -> "script: a failure with no output of its own says"
# The glyph table is checked against the installed Symbols Nerd Font (cmap) and the Nerd Fonts glyph list: every escape has the name it claims.
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-r13-answers-ui}"
D="$(mktemp -d "${SCRATCH:-/tmp}/lan.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
armadd() { ARMCMD="${ARMCMD:+$ARMCMD; }python3 -c 'import sys; p, o, n = sys.argv[1:4]; s = open(p).read(); sys.exit(\"ARM anchor gone: \" + o) if s.count(o) != 1 else open(p, \"w\").write(s.replace(o, n))' $(printf '%q ' "$@")"; }
A=modules/launcher/data/LauncherAnswers.qml
case "${ARM:-}" in
    "") ;;
    nostale)     NEEDLE="stale: a reply for an earlier query is dropped"
                 armadd $A '|| o.id !== a._id ||' '||'  ;;
    askempty)    NEEDLE="empty: the empty query asked nothing"
                 armadd $A 'if (t.length === 0 || !a.enabled || a._missing) {' 'if (t.length === 0 && false) {' ;;
    noreplace)   NEEDLE="pending: its landed reply replaced it"
                 armadd $A 'a._replied = true;
        a._set(out);' 'if (a._replied)
            return;
        a._replied = true;
        a._set(out);' ;;
    entercopyless) NEEDLE="enter: copies the main form"
                 armadd modules/launcher/browse/LauncherGrid.qml 'grid.answerActivated(shift);' 'grid.activateCurrent(shift);' ;;
    enterstays)  NEEDLE="enter: closes the launcher"
                 armadd modules/launcher/LauncherPopup.qml '        } else {
            popup.closeRequested();
        }
    }
    function freshen' '        }
    }
    function freshen' ;;
    shiftcloses) NEEDLE="shift+enter: the launcher stays"
                 armadd modules/launcher/LauncherPopup.qml 'if (keepOpen) {
            popup._copiedFlash = true;' 'if (false) {
            popup._copiedFlash = true;' ;;
    nocopied)    NEEDLE="shift+enter: the expr slot says Copied"
                 armadd modules/launcher/browse/AnswerRow.qml 'row.copied ? "Copied" : (row._a ? row._a.expr : "")' '(row._a ? row._a.expr : "")' ;;
    altmain)     NEEDLE="alt: a click on an alt copies that alt"
                 armadd modules/launcher/browse/AnswerRow.qml 'row.copyAlt(alt.d.copy,' 'row.copyAlt(row._a.copy,' ;;
    nohistory)   NEEDLE="recall: Up on an empty query brings back"
                 armadd modules/launcher/data/LauncherState.qml '        st._d.answerHistory = out;
        st._touch();' '        return;' ;;
    recallnonempty) NEEDLE="none: Up on a non-empty query is not a recall"
                 armadd modules/launcher/data/LauncherService.qml '(dir < 0 || h.length === 0 || svc.query !== "")' '(dir < 0 || h.length === 0)' ;;
    noanswerkeys) NEEDLE="none: Enter launches the app as before"
                 armadd modules/launcher/browse/LauncherGrid.qml 'readonly property bool answerSel: grid.primary && grid.answerOn && grid.answerSelRaw' 'readonly property bool answerSel: grid.primary && grid.answerSelRaw' ;;
    norestart)   NEEDLE="restart: a child that died"
                 armadd modules/common/components/SupervisedStream.qml '        if (!root.enabled)
            return;
        // A child that ran' '        return;
        // A child that ran' ;;
    eager)       NEEDLE="lazy: no child before the first non-empty query"
                 armadd $A 'property bool _wanted: false' 'property bool _wanted: true' ;;
    noroom)      NEEDLE="row: the popup did not resize"
                 armadd modules/launcher/LauncherPopup.qml 'readonly property real _answerRoom: !!popup.answer && !popup._m && !popup.service.hiddenView ? popup.rowH : 0' 'readonly property real _answerRoom: 0' ;;
    nodefaultsel) NEEDLE="row: highlighted by default"
                 armadd modules/launcher/LauncherPopup.qml '                grid.answerSelRaw = popup.answerTakesEnter;
            }
        }
        function onQueryChanged' '            }
        }
        function onQueryChanged' ;;
    keepslaunch) NEEDLE="file: keepQuerySec: a launch leaves none"
                 armadd modules/launcher/LauncherBarOwner.qml 'owner._left = owner._launched || ' 'owner._left = ' ;;
    nooptions)   NEEDLE="file: the child is told what answers says"
                 armadd $A '"--kinds", a.kinds.join(",")];' '"--kinds", ""];' ;;
    copiedstuck) NEEDLE="shift+enter: Copied goes after"
                 armadd modules/launcher/LauncherPopup.qml 'onTriggered: popup._copiedFlash = false' 'onTriggered: popup._copiedFlash = true' ;;
    recalltyping) NEEDLE="recall: typing leaves the recall"
                 armadd modules/launcher/data/LauncherService.qml '        if (!svc._recalling)
            svc._recallIdx = -1;
        svc._answerBox.ask' '        svc._answerBox.ask' ;;
    downnewer)   NEEDLE="recall: Down walks back"
                 armadd modules/launcher/browse/LauncherGrid.qml 'svc.recallStep(-1);' 'svc.recallStep(1);' ;;
    notmissing)  NEEDLE="missing: no python or script"
                 armadd $A 'a._ok = code === 0;' 'a._ok = true;' ;;
    nonomatch)   NEEDLE="nomatch: a query nothing matches says 'No match'"
                 armadd modules/launcher/LauncherPopup.qml 'popup.service.query.trim() !== "" && grid.order.length === 0' 'popup.service.query.trim() !== "" && grid.order.length === 99' ;;
    alwaysnomatch) NEEDLE="nomatch: a query with a match says nothing"
                 armadd modules/launcher/LauncherPopup.qml 'popup.service.query.trim() !== "" && grid.order.length === 0' 'popup.service.query.trim() !== ""' ;;
    noanswerhide) NEEDLE="nomatch: a quick answer stands in for the words"
                 armadd modules/launcher/LauncherPopup.qml '&& !popup.answer && !popup.service.answersWaiting' '&& !popup.service.answersWaiting' ;;
    nowaiting)   NEEDLE="nomatch: no words while the quick answer's reply is still out"
                 armadd modules/launcher/LauncherPopup.qml '&& !popup.answer && !popup.service.answersWaiting' '&& !popup.answer' ;;
    nocodewords) NEEDLE="script: a failure with no output of its own says"
                 armadd modules/launcher/data/LaunchRunner.qml '"It stopped with exit code " + code' '"exit code " + code' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac

# ---- the glyph table against the installed font and the Nerd Fonts names ------------------------------------------------------
glyph_check() {
    python3 - <<'PY'
import json, re, sys
from fontTools.ttLib import TTFont
src = open("modules/launcher/browse/AnswerKinds.js").read()
pairs = re.findall(r'(\w+): \{ name: "([\w-]+)", ch: "\\u([0-9A-Fa-f]{4})" \}', src)
font = TTFont("/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf")
cmap = font.getBestCmap()
names = json.load(open("tools/dev/fixtures/nerd_glyphnames.json")) if False else None
import glob
gl = glob.glob("tools/dev/fixtures/*glyphnames*")
names = json.load(open(gl[0])) if gl else {}
bad = []
for kind, name, code in pairs:
    cp = int(code, 16)
    if cp not in cmap:
        bad.append("%s: U+%04X is not in the installed Symbols Nerd Font" % (kind, cp))
    n = names.get(name)
    if n is None:
        bad.append("%s: no glyph named %s in the Nerd Fonts list" % (kind, name))
    elif int(n["code"], 16) != cp:
        bad.append("%s: %s is U+%s, not U+%04X" % (kind, name, n["code"].upper(), cp))
if len(pairs) < 11:
    bad.append("only %d kinds in the table" % len(pairs))
for b in bad:
    print("LAN FAIL glyph names: " + b)
print("LAN %s glyph names: %d kinds checked against the installed font" % ("FAIL" if bad else "ok  ", len(pairs)))
sys.exit(1 if bad else 0)
PY
}

mkdir -p "$D/scripts" "$D/state" "$D/m" "$D/home/.config/theme" "$D/cfg/theme" "$D/cache" "$D/data" "$D/rt"
printf '#!/bin/sh\n# name: zzprobe\n# description: a probe script\nexit 0\n' > "$D/scripts/zzprobe"; chmod +x "$D/scripts/zzprobe"
for t in "$HOME/.config/theme/state.json"; do [ -f "$t" ] && cp "$t" "$D/cfg/theme/state.json"; done
[ -f "$D/cfg/theme/state.json" ] || echo '{"mode":"light","theme":"eva"}' > "$D/cfg/theme/state.json"
: > "$D/copies.log"; : > "$D/asks.log"

run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1 QS_ICON_THEME=Papirus QT_QPA_PLATFORMTHEME=gtk3 HOME='"$D/home"' XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' XDG_CACHE_HOME='"$D/cache"' XDG_DATA_HOME='"$D/data"' LAN_DIR='"$D"' LAN_STUB="$PWD/tools/dev/fixtures/launcher_answers_stub.py" STUB_LOG='"$D/asks.log"' STUB_SLOW_MS=600 timeout 120 quickshell -p tools/dev/qml/launcher_answers_probe.qml'
tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'LAN \(ok\|FAIL\|RESULT\)' | sed 's/^.*LAN /LAN /' | tee "$D/verdict"
if [ -z "${ARM:-}" ]; then
    glyph_check | tee -a "$D/verdict" || true
fi
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'LAN RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load or never finished -- it proves nothing ($D)"; rl_noresult LAUNCHER_ANSWERS_UI "$D/log" | tail -3; exit 1; fi
    if grep -a 'LAN FAIL' "$D/verdict" | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D)"; exit 1
fi
if ! rl_has "$D/log" 'LAN RESULT'; then KEEP_D=1; rl_noresult LAUNCHER_ANSWERS_UI "$D/log"; exit 1; fi
if grep -aq 'LAN RESULT PASS' "$D/verdict" && ! grep -aq 'LAN FAIL' "$D/verdict"; then
    echo "LAUNCHER_ANSWERS_UI RESULT PASS"; exit 0
fi
KEEP_D=1; echo "LAUNCHER_ANSWERS_UI RESULT FAIL (log $D/log)"; exit 1
