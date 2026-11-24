#!/usr/bin/env bash
# panorama_ui_probe.sh -- Panorama's canvas, popup and side popup on the mock service, driven by real pointer events (offscreen), and
# the geometry cases (node) it stands on.
#
#   tools/dev/panorama_ui_probe.sh                 PANORAMA_UI RESULT PASS | FAIL
#   ARM=<name> tools/dev/panorama_ui_probe.sh      patches ONE rule in the sandbox copy: the run must go red
#       overlap noconnect       PanoramaLayout.js: a drop may overlap a third tile / split the layout
#       topleft                 the drop is decided from the carried tile's top-left, not the pointer
#       nofollow                the carried card stays where it was (does not follow the hand)
#       noz                     the destination outline is drawn under the tiles
#       nocalm                  the float keeps swaying while a tile is carried
#       nogap                   no drawn gap between tiles
#       applyanim hintanim sideanim   an item that feeds implicitHeight eases it (the popup's apply bar, its hints, the detail's height)
#       noanchor                the side popup's anchor is only re-aimed when the selection changes
#       eager                   a slider commits on every move
#       orphan                  a lone half-width fact goes to the right column
#       singlebar               a fact with one option is still drawn as a selector
#       nobinding               a slider's ball never follows its host (a plain assignment kills the binding)
#   The cast chip, the TV's tile and its detail (tools/dev/qml/panorama_cast_ui_probe.qml) run as a second harness after the first, in the clean
#   run (its own result line PANORAMA_UI_CAST); these ARMs run that harness alone:
#       castanim        the parked row's height eases (an item that feeds implicitHeight animates)
#       unreserved      the parked row holds no room for the confirm step (the chip would have to push things)
#       nohonest        the confirm step does not say that pairing can fail and drop Wi-Fi
#       leavekeeps      leaving the chip does not cancel its confirm step
#       nomark          a casting tile carries no cast mark
#       applyearly      a changed quality restarts the stream at once (no "Apply to stream")
#       earlytile       the TV is a tile while it still connects
#       castdisplayrows the TV's detail shows a display's Resolution / Refresh / Rotation beside the stream's own
#       castoffleak     casting on whatever the config says (cast false still scans and shows chips: the census and the picture go red)
#       fignohold       the detail does not hold the figures (none are published)        figkeep    it never lets go of them
#       figrebuild      the figures are a list made at every beat (delegates rebuilt)      fighole    one with no source leaves a hole
#       figease         the figures' height eases                                          figstale   a lost link leaves the live figures
#       figtight        the columns are too narrow for a long figure beside its name       figbeat    one figure follows a beat late
#   ARM=all                                       every arm, each in its own copy (the clean run first); PANORAMA_UI ARMS PASS | FAIL
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
export SANDBOX="${SANDBOX:-/tmp/lares-sbx-pano-ui}"

if [ "${ARM:-}" = all ]; then
    bad=0
    out=$(ARM= "$0" 2>&1); echo "$out" | tail -1
    echo "$out" | tail -1 | grep -q "RESULT PASS" || bad=1
    for a in overlap noconnect topleft nofollow noz nocalm nogap applyanim hintanim sideanim noanchor eager nobinding orphan singlebar \
             castanim unreserved nohonest leavekeeps nomark applyearly earlytile castoffleak castdisplayrows \
             fignohold figkeep figrebuild fighole figease figstale figtight figbeat; do
        r=$(ARM=$a "$0" 2>&1)
        if rl_isnoresult "$r"; then echo "ARM $a: the armed copy did not load -- it proves nothing"; bad=1
        elif echo "$r" | grep -q "RESULT FAIL"; then echo "ARM $a: fails as it must ($(echo "$r" | grep -c 'PU FAIL') checks)"
        else echo "ARM $a: DID NOT FAIL"; bad=1; fi
    done
    [ $bad = 0 ] && echo "PANORAMA_UI ARMS PASS" || echo "PANORAMA_UI ARMS FAIL"
    exit $bad
fi

LOG=$(mktemp "${SCRATCH:-/tmp}/panoui.XXXXXX")
IMG=$(mktemp -d "${SCRATCH:-/tmp}/panoui-img.XXXXXX")
trap 'rm -f "$LOG"; rm -rf "$IMG"' EXIT
patch=""
HARNESS=panorama_canvas_probe.qml
C=modules/panorama/popup/ArrangeCanvas.qml
F=modules/panorama/secondary/CastFigures.qml
NEED=""
case "${ARM:-}" in
    "") ;;
    overlap)   patch='modules/panorama/data/PanoramaLayout.js@@if (!_fits(moving, p.x, p.y, others)) continue;@@' ;;
    noconnect) patch='modules/panorama/data/PanoramaLayout.js@@if (!connected(others.concat([{ name: moving.name, x: p.x, y: p.y, w: moving.w, h: moving.h }]))) continue;@@' ;;
    topleft)   patch="$C@@const p = root._logicalOf(px, py);@@const p = root._logicalOf(px - root._gx, py - root._gy);" ;;
    nofollow)  patch="$C@@        it.carry.follow(Math.max(0, Math.min(root.width - it.carry.tw, px - root._gx)), Math.max(0, Math.min(root.stageHeight - it.carry.th, py - root._gy)));@@        void 0;" ;;
    noz)       patch="$C@@        z: 10@@        z: 0" ;;
    nocalm)    patch="$C@@calm: root._dragged@@calm: false" ;;
    nogap)     patch="$C@@g = root.style.tileGap / 2;@@g = 0;" ;;
    applyanim) patch='modules/panorama/popup/PanoramaPopup.qml@@readonly property real _applyH: root.active && root.dirty ? Math.ceil(applyBar.implicitHeight) : 0@@property real _applyH: root.active && root.dirty ? Math.ceil(applyBar.implicitHeight) : 0
    Behavior on _applyH { NumberAnimation { duration: 260 } }' ;;
    hintanim)  patch='modules/panorama/popup/PanoramaPopup.qml@@readonly property real _hintsH: root.hints.length > 0 ? Math.ceil(hintRows.implicitHeight) : 0@@property real _hintsH: root.hints.length > 0 ? Math.ceil(hintRows.implicitHeight) : 0
    Behavior on _hintsH { NumberAnimation { duration: 260 } }' ;;
    sideanim)  patch='modules/panorama/secondary/DisplaySettings.qml@@readonly property real naturalHeight: Math.ceil(2 * root._pad + head.height + col.height)@@property real naturalHeight: Math.ceil(2 * root._pad + head.height + col.height)
    Behavior on naturalHeight { NumberAnimation { duration: 260 } }' ;;
    noanchor)  patch='modules/panorama/popup/PanoramaPopup.qml@@    on_SelectedRestChanged: root._publishSecondary()@@' ;;
    eager)     patch='modules/panorama/secondary/SideSlider.qml@@            settle.restart();@@            settle.restart();
            row.committed(v);' ;;
    orphan)    patch='modules/panorama/secondary/FactGrid.qml@@items.push({ item: c, x: 0, y: y, w: hw });@@items.push({ item: c, x: W - hw, y: y, w: hw });' ;;
    singlebar) patch='modules/panorama/secondary/ChoiceField.qml@@        visible: field.options.length > 1@@        visible: true' ;;
    nobinding) patch='modules/panorama/secondary/SideSlider.qml@@        when: !s.held@@        when: false' ;;
    castanim)   HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/popup/ArrangeCanvas.qml@@    readonly property real _rowH: root._castIds.length@@    Behavior on _rowH { NumberAnimation { duration: 260 } }
    property real _rowH: root._castIds.length' ;;
    unreserved) HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/popup/ArrangeCanvas.qml@@Math.max(root.style.parkedHeight, root.style.castRowHeight)@@root.style.parkedHeight' ;;
    nohonest)   HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/popup/CastChip.qml@@    readonly property string honest: "Pairing can fail and drop Wi-Fi for a few seconds."@@    readonly property string honest: ""' ;;
    castdisplayrows) HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/secondary/DisplaySettings.qml@@    readonly property bool displayRows: root.ok && !root.mirrored && !root.isCast@@    readonly property bool displayRows: root.ok && !root.mirrored' ;;
    leavekeeps) HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/popup/CastChip.qml@@        onHoveredChanged: if (!leave.hovered) chip.confirming = false@@' ;;
    nomark)     HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/popup/DisplayTile.qml@@                        visible: tile.cast && !tile.chip@@                        visible: false' ;;
    applyearly) HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/secondary/DisplaySettings.qml@@        q[k] = v;
        root.qDraft = q;@@        q[k] = v;
        root.qDraft = q;
        if (root.service) root.service.castApplyQuality(q);' ;;
    earlytile)  HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/popup/ArrangeCanvas.qml@@            if (o.cast && root._castHold)
                continue;@@            if (false)
                continue;' ;;
    castoffleak) HARNESS=panorama_cast_ui_probe.qml; patch='modules/panorama/data/PanoramaMock.qml@@    readonly property bool castEnabled: root.castConfig && root.cast !== null@@    readonly property bool castEnabled: root.cast !== null' ;;
    fignohold)  HARNESS=panorama_cast_ui_probe.qml; NEED='figures: the eight'; patch="$F@@            root._held.castHoldStats();@@            void 0;" ;;
    figkeep)    HARNESS=panorama_cast_ui_probe.qml; NEED='figures: released'; patch="$F@@            root._held.castReleaseStats();@@            void 0;" ;;
    figrebuild) HARNESS=panorama_cast_ui_probe.qml; NEED='figures: no delegate'; patch="$F@@        model: CP.FIGURES.length@@        model: root.stats !== null ? CP.FIGURES.map(x => ({ key: x.key, v: root.stats[x.key] })) : CP.FIGURES" ;;
    fighole)    HARNESS=panorama_cast_ui_probe.qml; NEED='figures: one with no source'; patch="$F@@ ? root.mask.slice(0, cell.index).split(\"1\").length - 1 : -1@@ ? cell.index : -1" ;;
    figease)    HARNESS=panorama_cast_ui_probe.qml; NEED='figures: those that come'; patch="$F@@    height: root.implicitHeight@@    height: root.implicitHeight
    Behavior on implicitHeight { NumberAnimation { duration: 260 } }" ;;
    figstale)   HARNESS=panorama_cast_ui_probe.qml; NEED='figures: a lost link'; patch='modules/panorama/data/CastParse.js@@            n[k] = all || FIGURES[i].live ? null : f[k];@@            n[k] = all ? null : f[k];' ;;
    figtight)   HARNESS=panorama_cast_ui_probe.qml; NEED='figures: the longest'; patch="$F@@    readonly property real columnWidth: Math.floor((root.width - root.columnGap) / 2)@@    readonly property real columnWidth: 130" ;;
    figbeat)    HARNESS=panorama_cast_ui_probe.qml; NEED='figures: all of one beat'; patch="$F@@                text: root.stats !== null ? CP.figureText(cell.key, root.stats[cell.key]) : \"\"@@                property string live: root.stats !== null ? CP.figureText(cell.key, root.stats[cell.key]) : \"\"
                text: cell.key === \"kbps\" ? late : live
                property string late: \"\"
                Timer { interval: 60; repeat: true; running: true; onTriggered: parent.late = parent.live }" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
armpy='import sys
f,a,b=sys.argv[1].split("@@",2); s=open(f).read()
if s.count(a)!=1: print("ARM anchor gone: "+a); sys.exit(1)
open(f,"w").write(s.replace(a,b))'
run='set -e; PRIV=$(mktemp -d /tmp/panoui-env.XXXXXX); mkdir -p $PRIV/config/theme $PRIV/state $PRIV/cache; printf "{\"theme\":\"eva\",\"mode\":\"light\"}\n" > $PRIV/config/theme/state.json; '
[ -n "$patch" ] && run="$run python3 -c '$armpy' $(printf '%q' "$patch"); "
run="$run"'env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1 PCU_TMP='"$IMG"' XDG_CONFIG_HOME=$PRIV/config XDG_STATE_HOME=$PRIV/state XDG_CACHE_HOME=$PRIV/cache tools/dev/notifications_bus.sh timeout 120 quickshell -p tools/dev/qml/'"$HARNESS"'; rm -rf $PRIV'
tools/dev/sandbox.sh bash -c "$run" > "$LOG" 2>&1
rl_clean "$LOG" | grep -a -E "PU (PASS|FAIL)" | sed "s/^.*PU /PU /"
# the cast harness writes the popup's picture with and without a cast service (the config says false): the same pixels
cast_pictures() {
    if [ -s "$IMG/off_a.png" ] && cmp -s "$IMG/off_a.png" "$IMG/off_b.png"; then echo "PU PASS cast off: the popup's picture is the same with and without a cast service"
    else echo "PU FAIL cast off: the popup's picture differs with a cast service (or the pictures are missing)"; fi
}
if [ -n "${ARM:-}" ]; then
    if rl_isnoresult "$(rl_result PANORAMA_UI "$LOG" 'PU RESULT .*')"; then echo "PANORAMA_UI RESULT FAIL (no result: armed copy)"; exit 1; fi
    [ "$HARNESS" = panorama_cast_ui_probe.qml ] && cast_pictures
    # an arm with a check of its own is judged by that check
    if [ -n "$NEED" ] && ! rl_clean "$LOG" | grep -a -q "PU FAIL $NEED"; then echo "PANORAMA_UI RESULT PASS (armed $ARM: not caught by \"$NEED\")"; exit 0; fi
    rl_clean "$LOG" | grep -a "PU RESULT" | sed 's/PU RESULT/PANORAMA_UI RESULT/'
    exit 0
fi
cp "$LOG" /tmp/panoui.last.log
res=$(rl_result PANORAMA_UI "$LOG" 'PU RESULT .*'); rc=$?
printf '%s\n' "$res" | sed 's/^PU RESULT/PANORAMA_UI RESULT/'
[ $rc = 0 ] || exit $rc
# the second harness: the cast chip, the TV's tile and its detail (its own result line)
LOG2=$(mktemp "${SCRATCH:-/tmp}/panoui2.XXXXXX")
run2='set -e; PRIV=$(mktemp -d /tmp/panoui-env.XXXXXX); mkdir -p $PRIV/config/theme $PRIV/state $PRIV/cache; printf "{\"theme\":\"eva\",\"mode\":\"light\"}\n" > $PRIV/config/theme/state.json; env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi QML_DISABLE_DISTANCEFIELD=1 PCU_TMP='"$IMG"' XDG_CONFIG_HOME=$PRIV/config XDG_STATE_HOME=$PRIV/state XDG_CACHE_HOME=$PRIV/cache tools/dev/notifications_bus.sh timeout 120 quickshell -p tools/dev/qml/panorama_cast_ui_probe.qml; rm -rf $PRIV'
tools/dev/sandbox.sh bash -c "$run2" > "$LOG2" 2>&1
rl_clean "$LOG2" | grep -a -E "PU (PASS|FAIL)" | sed "s/^.*PU /PU /"
pic=$(cast_pictures); echo "$pic"
res2=$(rl_result PANORAMA_UI_CAST "$LOG2" 'PU RESULT .*'); rc2=$?
rm -f "$LOG2"
printf '%s\n' "$res2" | sed 's/^PU RESULT/PANORAMA_UI_CAST RESULT/'
[ $rc2 = 0 ] || exit $rc2
case "$pic" in "PU PASS"*) exit 0 ;; *) echo "PANORAMA_UI_CAST RESULT FAIL (the picture)"; exit 1 ;; esac
