#!/usr/bin/env bash
# aerial_keys_env_probe.sh -- the aerial popup's panels take typed text when another app holds the keyboard (round 3: "I tried to search
# in the memory detail popup when my active window was vscode, but it just typed into vscode"). The REAL shell.qml on its mock services in
# the nested Hyprland of tools/dev/lock_env.sh (nothing of the user's is touched), a stand-in app (tools/dev/qml/aerial_keys_app.qml)
# that holds the keyboard, the virtual pointer and `wtype -p F24` (the shell's Escape bind is up while a popup is: never a bare first key).
#
#   tools/dev/aerial_keys_env_probe.sh            AERIAL_KEYS_ENV RESULT PASS | FAIL
#   ARM=oldrequest | nopointer | nostrongkeys | oldreclaim   one fault each (K2 / K2 / K1 / K3): no request at all, a request nothing
#                                                 arms, an optional field that asks at once, the keys reclaimed only in thePopup's rect
#   ARM=all                                       each ARM must fail its own phase: AERIAL_KEYS_ENV ARMS RESULT PASS | FAIL
#   AKE_KEEP=1                                    keep the work dir
# The copy gets a test hook (an IpcHandler `aerialkeys` in AerialPopup: where the memory chip and the panel's field are, and the
# field's state); the run's sandbox copy only, never the tree.
set -u
{
cd "$(dirname "$0")/../.." || exit 1
ROOT="$PWD"
. "$ROOT/tools/dev/result_lib.sh"
if [ "${ARM:-}" = all ]; then
    rc=0
    declare -A NEED=([oldrequest]=K2 [nopointer]=K2 [nostrongkeys]=K1 [oldreclaim]=K3)
    for a in ${ONLY_ARMS:-oldrequest nopointer nostrongkeys oldreclaim}; do
        out=$(ARM="$a" LOCK_ENV="ak${a:0:6}" SANDBOX="${SANDBOX:-/tmp/lares-sbx-r3k}-$a" bash "$0" 2>&1)
        if rl_isnoresult "$out" || printf '%s\n' "$out" | grep -aq "anchor"; then
            echo "ARM $a: NOT PROVEN ($(printf '%s\n' "$out" | grep -a 'anchor\|no result' | head -1 | cut -c1-100))"; rc=1
        elif printf '%s\n' "$out" | grep -aq "^AERIAL_KEYS_ENV RESULT FAIL" && printf '%s\n' "$out" | grep -aqE "^ *AKE ${NEED[$a]}[^ ]* FAIL"; then
            echo "ARM $a: FAILED AS IT MUST ($(printf '%s\n' "$out" | grep -aE "^ *AKE ${NEED[$a]}[^ ]* FAIL" | head -1 | cut -c1-120))"
        else
            echo "ARM $a: DID NOT FAIL ITS PHASE ${NEED[$a]}: $(printf '%s\n' "$out" | grep -a 'AKE .* FAIL\|RESULT' | head -2 | tr '\n' ' ' | cut -c1-150)"; rc=1
        fi
    done
    [ "$rc" = 0 ] && echo "AERIAL_KEYS_ENV ARMS RESULT PASS" || echo "AERIAL_KEYS_ENV ARMS RESULT FAIL"
    exit "$rc"
fi
E="$ROOT/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-aerkeys}"
SANDBOX="${SANDBOX:-/tmp/lares-sbx-r3k}"
D="$(mktemp -d "${SCRATCH:-/tmp}/aerkeys.XXXXXX")"
SPID="" APID="" _cleaned=0 _ok=0
cleanup() {
    [ "$_cleaned" = 1 ] && return
    _cleaned=1
    [ -n "$SPID" ] && kill "$SPID" 2> /dev/null
    [ -n "$APID" ] && kill "$APID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    rm -rf "$SANDBOX" "$SANDBOX.lrrt"
    [ "$_ok" = 1 ] && [ -z "${AKE_KEEP:-}" ] && rm -rf "$D"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

SANDBOX="$SANDBOX" tools/dev/sandbox.sh > /dev/null || { echo "AERIAL_KEYS_ENV RESULT FAIL (the sandbox did not sync)"; exit 1; }
SB="$SANDBOX"
python3 tools/dev/shell_tripwires.py "$SB" > /dev/null || { echo "AERIAL_KEYS_ENV RESULT FAIL (the tripwires did not go in)"; exit 1; }
python3 - "$SB" "${ARM:-}" <<'PY' || { echo "AERIAL_KEYS_ENV RESULT FAIL (the copy's patch did not go in: anchor)"; exit 1; }
import sys
sb, arm = sys.argv[1:3]
def patch(path, pairs):
    p = sb + "/" + path
    s = open(p, encoding="utf-8").read()
    for a, b in pairs:
        if s.count(a) != 1:
            print("anchor in %s found %d times: %s" % (path, s.count(a), a.splitlines()[0][:90])); sys.exit(1)
        s = s.replace(a, b)
    open(p, "w", encoding="utf-8").write(s)
HOOK = '''    readonly property bool secondaryWantsKeys: root._secKeys
    function _findField(it: var): var {
        if (!it)
            return null;
        if (it.objectName === "fieldInput")
            return it;
        for (let i = 0; i < it.children.length; i++) {
            const r = root._findField(it.children[i]);
            if (r)
                return r;
        }
        return null;
    }
    IpcHandler {
        target: "aerialkeys"
        function memAt(): string {
            const p = Layout.anchorPoint(boardScene.geo, "mem", boardScene.pickState());
            const q = Cam.project(p, boardScene.cam);
            const s = boardScene.mapToItem(null, q.x, q.y);
            return Math.round(s.x) + " " + Math.round(s.y);
        }
        function info(): string {
            const sec = root._liveSecondary();
            const f = sec ? root._findField(sec.panel) : null;
            let at = "";
            if (f) {
                const s = f.mapToItem(null, f.width / 2, f.height / 2);
                at = Math.round(s.x) + " " + Math.round(s.y);
            }
            return JSON.stringify({ sec: !!sec, page: sec && sec.panel ? String(sec.panel.page) : "", field: at, focus: f ? f.activeFocus : false,
                text: f ? f.text : "", req: root.keyboardFocusRequest, wants: root._secKeys });
        }
    }
'''
patch("modules/aerial/popup/AerialPopup.qml", [("    readonly property bool secondaryWantsKeys: root._secKeys\n", HOOK)])
P = "modules/aerial/popup/AerialPopup.qml"
if arm == "oldrequest":
    # no request for the saved list's optional search (the fault as the user had it: nothing ever asks the compositor)
    patch(P, [("    readonly property string keyboardFocusRequest: root._secKeys && root.secondaryOpen ? \"onDemand\" : \"none\"\n",
               "    readonly property string keyboardFocusRequest: \"none\"\n")])
elif arm == "nopointer":
    patch(P, [("readonly property bool wantsNow: sec.keyboardWanted && (!sec.optionalKeys || root._byKey || sec._moved)",
               "readonly property bool wantsNow: false")])
elif arm == "nostrongkeys":
    patch(P, [("readonly property bool wantsNow: sec.keyboardWanted && (!sec.optionalKeys || root._byKey || sec._moved)",
               "readonly property bool wantsNow: sec.keyboardWanted")])
elif arm == "oldreclaim":
    patch("modules/shell/ShellFrame.qml", [("if (b && (b === gooeyEngine.thePopup || b.live) && p.x", "if (b && b === gooeyEngine.thePopup && p.x")])
elif arm:
    print("unknown ARM=" + arm); sys.exit(2)
PY
sed -i '0,/^import QtQuick$/s//import QtQuick\nimport Quickshell.Io/' "$SB/modules/aerial/popup/AerialPopup.qml"

"$E" down > /dev/null 2>&1
OUTPUTS=1 "$E" up > "$D/up.log" 2>&1 || { tail -5 "$D/up.log"; echo "AERIAL_KEYS_ENV RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
"$E" hyprctl eval 'hl.layer_rule({ name = "lares_bar_noanim", match = { namespace = "^lares-bar$" }, no_anim = true })' > /dev/null
ALOG="$D/app.log" SLOG="$D/shell.log"
SHELL_PLAT_PATH="$SB/shell.qml"
"$E" run env AKA_MODE=win QS_DISABLE_CRASH_HANDLER=1 quickshell -n -p "$SB/tools/dev/qml/aerial_keys_app.qml" > "$ALOG" 2>&1 &
APID=$!
for _ in $(seq 1 100); do grep -aq "AKA ready" "$ALOG" 2> /dev/null && break; sleep 0.2; done
grep -aq "AKA ready" "$ALOG" || { rl_noresult AERIAL_KEYS_ENV "$ALOG"; exit 1; }
"$E" run env SHELL_SERVICES=mock SHELL_FOCUS=live QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 quickshell -n -p "$SB/shell.qml" > "$SLOG" 2>&1 &
SPID=$!
for _ in $(seq 1 400); do
    grep -aq "LARES settled" "$SLOG" 2> /dev/null && break
    kill -0 "$SPID" 2> /dev/null || break
    sleep 0.3
done
if ! grep -aq "LARES settled" "$SLOG"; then
    [ -n "${ARM:-}" ] && echo "ARM $ARM: the armed copy did not load -- it proves nothing ($SLOG)"
    AKE_KEEP=1; rl_noresult AERIAL_KEYS_ENV "$SLOG"; exit 1
fi
python3 tools/dev/aerial_keys_env_probe.py "$ROOT" "$SB" "$LOCK_ENV" "$ALOG" "$SLOG" 2>&1 | tee "$D/checks.log" | grep -a "^ *AKE "
rc=${PIPESTATUS[0]}
if [ "$rc" = 0 ]; then
    echo "AERIAL_KEYS_ENV RESULT PASS"; _ok=1; exit 0
fi
AKE_KEEP=1
echo "AERIAL_KEYS_ENV RESULT FAIL (logs: $D)"
exit 1
}
