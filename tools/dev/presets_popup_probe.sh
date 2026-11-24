#!/usr/bin/env bash
# presets_popup_probe.sh -- the desktop presets' popup (modules/presets) on its mock service, clicked for real: the grid's size, the faces'
# geometry, Load's confirm (asks first, loads on the second click, at once with nothing to close, goes back by itself), Add, rename and its
# refusal, delete with Undo, the save card and its refusal, the Escape chain (tools/dev/qml/presets_popup_probe.qml).
#
#   tools/dev/presets_popup_probe.sh                 PRESETSPOPUP RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=noconfirm tools/dev/presets_popup_probe.sh   Load never asks (the plan's count is ignored): the confirm check goes red
#   ARM=groupsplit tools/dev/presets_popup_probe.sh  a tabbed group is drawn as a tile per member: the group check goes red
#   ARM=noundo tools/dev/presets_popup_probe.sh      a delete keeps no Undo window: the delete check goes red
#   ARM=alwaystwo tools/dev/presets_popup_probe.sh   the columns ignore how many cards there are: "no preset: one column" goes red
#   ARM=noedge tools/dev/presets_popup_probe.sh      the cards stand at their rest whatever the box's width: "the cards stand at the box's edges" red
#   ARM=hidden tools/dev/presets_popup_probe.sh      a change out of sight counts as under way: "a change out of sight" goes red
#   ARM=nostart tools/dev/presets_popup_probe.sh     a live service waits for an open to read the list: the start check goes red
#   ARM=nowatch tools/dev/presets_popup_probe.sh     a watched tab hears no desktop change: "live: a change while watched reaches the card" red
#   ARM=redraw tools/dev/presets_popup_probe.sh      every read replaces the picture: "live: the same desktop read again keeps the picture" red
#   ARM=noflip tools/dev/presets_popup_probe.sh      a tab flip (activewindowv2) is no desktop change: "live: a tab flip reaches the card" red
#   ARM=nolockface tools/dev/presets_popup_probe.sh  the face ignores a group's lock: "live: a group's lock reaches the card" red
#   ARM=nolockwatch tools/dev/presets_popup_probe.sh the watch never starts the lock watch: "live: the watch starts the lock watch" red
#   ARM=all                                          each of the above, one after the other
#
# Offscreen, in a sandbox copy, with a private config / state / cache home (the theme's state is seeded: nothing reaches the desktop's).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
if [ "${ARM:-}" = all ]; then
    rc=0
    for a in noconfirm groupsplit noundo alwaystwo noedge hidden nostart nowatch redraw noflip nolockface nolockwatch; do ARM=$a "$0" || rc=1; done
    exit $rc
fi
D="$(mktemp -d "${SCRATCH:-/tmp}/pp.XXXXXX")"
trap '[ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
mkdir -p "$D/cfg/theme" "$D/state" "$D/cache"
# the live service's tool: answers the list, does nothing else
cat > "$D/stub.py" <<'STUB_EOF'
import sys
print('{"presets": [{"name": "dev", "slug": "dev", "created": 1, "updated": 1, "windows": 1, "workspaces": 1, "face": null}]}' if sys.argv[1:3] == ["preset", "list"] else "{}")
STUB_EOF
printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    noconfirm) ARMCMD="sed -i 's|            if (n > 0) {|            if (false) {|' modules/presets/PresetCard.qml"; NEEDLE='PP FAIL confirm: the first Load click asks' ;;
    groupsplit) ARMCMD="sed -i 's|if (g \&\& g.id !== undefined \&\& g.id !== null \&\& groups\[g.id\] !== undefined) {|if (false) {|' modules/presets/PresetFaceLayout.js"; NEEDLE='PP FAIL face: the six-tab group is one tile' ;;
    noundo) ARMCMD="sed -i 's|        d\[row.slug\] = { until: Date.now() + root.undoMs, row: row };|        d[row.slug] = { until: 0, row: row };|' modules/presets/data/PresetsService.qml"; NEEDLE='PP FAIL delete: the card stays' ;;
    alwaystwo) ARMCMD="sed -i 's|        return Math.max(1, Math.min(columns, cells));|        return Math.max(1, columns);|' modules/presets/PresetsStyle.qml"; NEEDLE='PP FAIL columns: no preset: one column' ;;
    noedge) ARMCMD="sed -i 's/    readonly property real _box: root._from <= 0 ?/    readonly property real _box: true ?/' modules/presets/PresetsPopup.qml"; NEEDLE="PP FAIL columns: the cards stand at the box's edges" ;;
    hidden) ARMCMD="sed -i 's/    readonly property bool _onShow: root.visible .*/    readonly property bool _onShow: true/' modules/presets/PresetsPopup.qml"; NEEDLE='PP FAIL columns: a change out of sight' ;;
    nostart) ARMCMD="sed -i '/^    Component.onCompleted: {\$/,/^    }\$/d' modules/presets/data/PresetsService.qml"; NEEDLE='PP FAIL start: a live service reads' ;;
    nowatch) ARMCMD="sed -i 's|        if (root.watching)\$|        if (false)|' modules/presets/data/PresetsService.qml; grep -q '        if (false)\$' modules/presets/data/PresetsService.qml"; NEEDLE='PP FAIL live: a change while watched reaches the card' ;;
    redraw) ARMCMD="sed -i 's|        if (JSON.stringify(d) !== JSON.stringify(root._current))|        if (true)|' modules/presets/data/PresetsService.qml; grep -q '        if (true)\$' modules/presets/data/PresetsService.qml"; NEEDLE='PP FAIL live: the same desktop read again keeps the picture' ;;
    noflip) ARMCMD="sed -i 's|\"configreloaded\", \"activewindowv2\", |\"configreloaded\", |' modules/presets/data/PresetsService.qml; ! grep -q '\"activewindowv2\"' modules/presets/data/PresetsService.qml"; NEEDLE='PP FAIL live: a tab flip reaches the card' ;;
    nolockface) ARMCMD="sed -i 's|            locked: !!g \&\& g.locked === true,|            locked: false,|; s|            if (g.locked === true)\$|            if (false)|' modules/presets/PresetFaceLayout.js; grep -q '            locked: false,' modules/presets/PresetFaceLayout.js"; NEEDLE="PP FAIL live: a group's lock reaches the card" ;;
    nolockwatch) ARMCMD="sed -i 's|    onWatchingChanged: root._lockWatch(root.watching ? \"start\" : \"stop\")|    onWatchingChanged: {}|' modules/presets/data/PresetsService.qml; grep -q '    onWatchingChanged: {}' modules/presets/data/PresetsService.qml"; NEEDLE='PP FAIL live: the watch starts the lock watch' ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
run='set -e; '"${ARMCMD:+$ARMCMD; }"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi PRESETS_PROBE=1 PRESETS_STUB='"$D/stub.py"' XDG_CONFIG_HOME='"$D/cfg"' XDG_STATE_HOME='"$D/state"' XDG_CACHE_HOME='"$D/cache"' timeout -k 2 90 quickshell -p tools/dev/qml/presets_popup_probe.qml'
SANDBOX="${SANDBOX:-/tmp/lares-sandbox-presets-popup}" tools/dev/sandbox.sh bash -c "$run" > "$D/log" 2>&1
rl_clean "$D/log" | grep -a -o 'PP .*' | grep -a -v 'PP RESULT'
if [ -n "${ARM:-}" ]; then
    if rl_clean "$D/log" | grep -a -q "$NEEDLE"; then echo "ARM $ARM: failed as it must"; exit 0; fi
    if ! rl_has "$D/log" 'PP RESULT'; then echo "ARM $ARM: the armed copy did not load -- it proves nothing"; exit 1; fi
    echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it"; exit 1
fi
res=$(rl_result PRESETSPOPUP "$D/log" 'PP RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP=1; printf '%s\n' "$res"; exit 1; fi
# a clean run is clean: no warning of ours in the log
if rl_clean "$D/log" | grep -a -E 'presets/|presets_popup_probe' | grep -a -i -E 'warn|error|unable|cannot|binding loop' ; then
    echo "PRESETSPOPUP RESULT FAIL (warnings in the log: $D/log)"; KEEP=1; exit 1
fi
printf '%s\n' "$res" | sed 's/^PP RESULT/PRESETSPOPUP RESULT/'
exit $rc
