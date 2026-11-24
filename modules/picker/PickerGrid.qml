pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/PickerModel.js" as Model

// =============================================================================
// PickerGrid.qml -- the picker's grid: a carved box with section headers and tiles, scrolled by the shell's one scroll feel.
//
// WHAT IT SHOWS is a layout (PickerModel.layout): rows of two kinds, a header (a section's label) and tiles (`cols` of one
// profile). It builds NOTHING past the viewport: a RING of row slots (`poolRows`, a few more than the box shows) lives in the
// Flickable's content, each slot standing at its row's y. Slot `s` always shows the row r with r = s (mod pool) inside the window
// [firstRow, firstRow + pool), so crossing a row boundary rebinds ONE slot, not every one (a window that shifted the slots would
// re-lay out a hundred colour-emoji Texts per boundary).
//
// ONE HIGHLIGHT, a carved well that GLIDES between cells on one clock (`style.glideMs`); it lives in the scrolling content, so
// a scroll carries it, and it snaps (no glide) where the layout is replaced. The pointer moves it by MOTION only (a resting
// pointer's hover is re-delivered every frame); a wheel that moves the list under a still pointer hands it the cell that comes
// under it. The keyboard's `ensureVisible` scrolls with a short ease, never through the wheel's engine.
//
// SCROLL: ScrollDressing (the shell's KineticScroll + ScrollFeel, and the two end fades cut to the box's rounded outline).
//
// THE TILES: an emoji is a colour glyph (Noto Color Emoji at `profile.glyph` logical px: the font's bitmaps are 136 px, so the
// glyph stays sharp up to ~100 logical px at any shell scale); a symbol is plain text; an alt code carries its code(s) under it;
// a kaomoji is one elided line. A tile the tray holds carries an accent badge with its count.
//
// THE CLEAR CONTROL (`clearSec`): one UndoDrainButton at the right end of a section's header (the Recent one, or -- while an Undo is on offer
// and the Recent section is gone -- the header that took its place, at the same y). Headers are pooled rows, so the button is not one of them:
// it stands over the box in a clipping layer of its own, between the pointer's area and the dressing, at the header's y less the scroll, so it
// goes with its header and is cut at the box's edge like the rows. `clearClicked()` asks the host to clear; the button turns into Undo
// (`armUndo()`) and drains for `undoMs`; `undoClicked()` / `undoExpired()` say how it ended. The host owns what is cleared.
//
// The host reads `current` / `hovered()` / `picked()` / `contextRequested()`; it owns the keys.
// =============================================================================
Item {
    id: grid

    property var layoutObj: null
    property int current: -1
    property PickerStyle style: null
    property string fontFamily: "Inter"
    // The installed Nerd Font's family (the Nerd tab's tiles are drawn in it).
    property string nerdFamily: "Symbols Nerd Font"
    property int tone: 0
    property var tones: []
    // { "<char>": count } of what the tray holds.
    property var trayCounts: ({})
    property color boxColor: Theme.listBox
    property color surfaceColor: Theme.surface

    signal hovered(int i)
    signal picked(int i, bool shift, bool ctrl)
    signal contextRequested(int i)
    signal clearClicked
    signal undoClicked
    signal undoExpired

    // The section whose header carries the Clear control ("" = none), and how long its Undo stays on offer.
    property string clearSec: ""
    property int undoMs: 10000
    readonly property bool undoing: clearBtn.undoing
    function armUndo(leftMs) {
        clearBtn.arm(leftMs);
    }
    function disarmUndo() {
        clearBtn.disarm();
    }

    readonly property real contentY: view.contentY
    readonly property bool scrolling: dressing.moving || scrollAnim.running
    // The section whose rows are at the top of the box (the category bar follows it).
    readonly property string topSection: grid.layoutObj ? Model.sectionAt(grid.layoutObj, view.contentY + 1) : ""
    readonly property int poolRows: grid.layoutObj ? Math.ceil(view.height / grid.layoutObj.minRowH) + 2 : 0
    readonly property int firstRow: grid.layoutObj && grid.layoutObj.rows.length > 0 ? Model.rowAt(grid.layoutObj, view.contentY) : 0
    readonly property real _radius: grid.style ? grid.style.boxRadius : 14
    // The carve's rim: the inset shadow's width, and how far the VIEWPORT stands inside the box at its top and foot.
    readonly property real _rim: 3

    // ---- scrolling to a place ------------------------------------------------------------
    function _clampY(y) {
        return Math.max(0, Math.min(Math.max(0, view.contentHeight - view.height), y));
    }
    function scrollTo(y, animated) {
        dressing.stopMotion();
        scrollAnim.stop();
        const to = grid._clampY(y);
        if (!animated || Math.abs(to - view.contentY) < 1 || !grid.style || grid.style.scrollMs <= 0) {
            view.contentY = to;
            return;
        }
        scrollAnim.from = view.contentY;
        scrollAnim.to = to;
        scrollAnim.duration = grid.style.scrollMs;
        scrollAnim.restart();
    }
    // Where a section starts (its header's y).
    function scrollToSection(id, animated) {
        const L = grid.layoutObj;
        if (L && L.secY[id] !== undefined)
            grid.scrollTo(L.secY[id], animated);
    }
    // Brings cell `i` into the box, with a header above it when it is the first row of its section.
    function ensureVisible(i, animated) {
        const L = grid.layoutObj;
        if (!L || i < 0 || i >= L.flat.length)
            return;
        const r = Model.cellRect(L, i);
        const ri = L.rowOf[i];
        let top = r.y;
        if (ri > 0 && L.rows[ri - 1].kind === "head")
            top = L.rows[ri - 1].y;
        const margin = 6;
        const viewTop = view.contentY;
        const viewBottom = view.contentY + view.height;
        if (top < viewTop + margin)
            grid.scrollTo(top - margin, animated);
        else if (r.y + r.h > viewBottom - margin)
            grid.scrollTo(r.y + r.h - view.height + margin, animated);
    }
    // A cell's rect in `target`'s coordinates (the tone popover stands by it).
    function cellRectIn(i, target) {
        const L = grid.layoutObj;
        if (!L || i < 0 || i >= L.flat.length)
            return null;
        const r = Model.cellRect(L, i);
        const p = view.contentItem.mapToItem(target, r.x, r.y);
        return { x: p.x, y: p.y, w: r.w, h: r.h };
    }
    // The well goes where the layout puts it, with no glide (a new query is a new page).
    function snapWell() {
        well.glide = false;
        glideBack.restart();
    }
    onLayoutObjChanged: {
        grid.snapWell();
        // A shorter page leaves the old scroll position past its end.
        view.contentY = grid._clampY(view.contentY);
    }

    NumberAnimation {
        id: scrollAnim
        target: view
        property: "contentY"
        easing.type: Easing.OutCubic
    }
    Timer {
        id: glideBack
        interval: 0
        onTriggered: well.glide = true
    }

    // ---- the box ----------------------------------------------------------------------------
    ShadowBox {
        id: box
        anchors.fill: parent
        baseWidth: width
        baseHeight: height
        baseRadius: grid._radius
        surfaceColor: grid.surfaceColor
        backgroundColor: grid.boxColor
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: grid._rim
    }

    // THE VIEWPORT: the box less the carve's rim at its top and foot. The cut band (fade_band.frag) feathers inward from the
    // outline it is given and one pixel further in, so an outline that IS the clip leaves the clip's first two rows bare: a slit
    // under the box's border where the glyphs showed through (feedback/picker.md). The dressing's rule is an outline that is "the
    // host's drawn shape when it is rounder than its clip", so the clip is cut in by the rim (the shadow's width: the part of the
    // box the glyphs have no business in) and the outline stays the box. `view` keeps the box's size and place, so every row, the
    // pointer and the clear control stand exactly where they did; only what shows is cut in, and the rim shows the box's own carve.
    // (tools/dev/fade_edges_probe.sh, site `picker`, ARM flush.)
    Item {
        id: viewport
        objectName: "pickerViewport"
        anchors.fill: parent
        anchors.topMargin: grid._rim
        anchors.bottomMargin: grid._rim
        clip: true

        Flickable {
            id: view
            objectName: "pickerFlick"
            x: 0
            y: -grid._rim
            width: grid.width
            height: grid.height
            contentWidth: width
            contentHeight: grid.layoutObj ? grid.layoutObj.height : 0
            clip: false
            interactive: false
            boundsBehavior: Flickable.StopAtBounds

            // The highlight: carved, one, gliding.
            ShadowBox {
                id: well
                objectName: "pickerWell"
                property bool glide: true
                readonly property var rect: grid.layoutObj && grid.current >= 0 && grid.current < grid.layoutObj.flat.length ? Model.cellRect(grid.layoutObj, grid.current) : null
                readonly property real inset: grid.style ? grid.style.wellInset : 2
                visible: well.rect !== null
                x: well.rect ? well.rect.x + well.inset : 0
                y: well.rect ? well.rect.y + well.inset : 0
                width: well.rect ? well.rect.w - 2 * well.inset : 0
                height: well.rect ? well.rect.h - 2 * well.inset : 0
                baseWidth: width
                baseHeight: height
                baseRadius: grid.style ? grid.style.wellRadius : 10
                surfaceColor: "transparent"
                backgroundColor: Theme.panelSunk
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                bevelWidth: 1
                shadowWidth: 3
                Behavior on x {
                    enabled: well.glide
                    NumberAnimation {
                        duration: grid.style ? grid.style.glideMs : 140
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on y {
                    enabled: well.glide
                    NumberAnimation {
                        duration: grid.style ? grid.style.glideMs : 140
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on width {
                    enabled: well.glide
                    NumberAnimation {
                        duration: grid.style ? grid.style.glideMs : 140
                        easing.type: Easing.OutCubic
                    }
                }
            }

            Repeater {
                model: grid.poolRows
                delegate: Item {
                    id: slot
                    required property int index
                    // The ring: the row in [firstRow, firstRow + pool) that is congruent to this slot.
                    readonly property int ri: grid.firstRow + ((slot.index - grid.firstRow) % grid.poolRows + grid.poolRows) % grid.poolRows
                    readonly property var row: grid.layoutObj && slot.ri < grid.layoutObj.rows.length ? grid.layoutObj.rows[slot.ri] : null
                    readonly property bool isHead: slot.row !== null && slot.row.kind === "head"
                    readonly property bool isTiles: slot.row !== null && slot.row.kind === "tiles"
                    y: slot.row ? slot.row.y : 0
                    width: view.contentWidth
                    height: slot.row ? slot.row.h : 0
                    visible: slot.row !== null

                    Text {
                        visible: slot.isHead
                        x: grid.layoutObj ? grid.layoutObj.pad + 6 : 0
                        y: slot.row ? slot.row.h - implicitHeight - 4 : 0
                        text: slot.isHead ? slot.row.label : ""
                        font.family: grid.fontFamily
                        font.pixelSize: 11
                        font.bold: true
                        color: Theme.textMuted
                    }

                    Repeater {
                        model: slot.isTiles ? grid.layoutObj.maxCols : 0
                        delegate: Item {
                            id: tile
                            required property int index
                            readonly property var it: slot.isTiles && tile.index < slot.row.n ? grid.layoutObj.flat[slot.row.start + tile.index] : null
                            readonly property string profile: slot.isTiles ? slot.row.profile : ""
                            readonly property real x0: slot.isTiles ? Math.round(grid.layoutObj.pad + tile.index * grid.layoutObj.inner / slot.row.cols) : 0
                            readonly property real x1: slot.isTiles ? Math.round(grid.layoutObj.pad + (tile.index + 1) * grid.layoutObj.inner / slot.row.cols) : 0
                            readonly property int count: tile.it ? (grid.trayCounts[tile.it.ch] || 0) : 0
                            x: tile.x0
                            width: tile.x1 - tile.x0
                            height: slot.height
                            visible: tile.it !== null

                            readonly property bool emoji: tile.profile === "emoji"
                            readonly property bool alt: tile.profile === "alt"
                            readonly property bool wide: tile.profile === "wide"
                            readonly property bool nerd: tile.profile === "nerd"
                            readonly property real glyphPx: !grid.style ? 22 : tile.emoji ? grid.style.emojiGlyph : tile.alt ? grid.style.altGlyph : tile.wide ? grid.style.wideGlyph
                                : tile.nerd ? grid.style.nerdGlyph : grid.style.symbolGlyph

                            Text {
                                id: glyph
                                // An alt tile keeps its glyph above the caption; the others centre theirs.
                                x: tile.wide ? 10 : 0
                                width: tile.wide ? tile.width - 20 : tile.width
                                height: tile.alt ? tile.height - 16 : tile.height
                                horizontalAlignment: tile.wide ? Text.AlignLeft : Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                elide: tile.wide ? Text.ElideRight : Text.ElideNone
                                text: tile.it ? (tile.it.tonable ? Model.toned(tile.it.ch, grid.tone, grid.tones) : tile.it.ch) : ""
                                font.family: tile.emoji ? "Noto Color Emoji" : tile.nerd ? grid.nerdFamily : grid.fontFamily
                                font.pixelSize: tile.glyphPx
                                color: Theme.textPrimary
                            }
                            Text {
                                visible: tile.alt
                                x: 0
                                y: tile.height - 18
                                width: tile.width
                                horizontalAlignment: Text.AlignHCenter
                                text: tile.it ? Model.codesCaption(tile.it) : ""
                                font.family: "Inter"
                                font.pixelSize: grid.style ? grid.style.altCaption : 10
                                color: Theme.textFaint
                            }
                            // The tray's badge: how many times this one is in the pick.
                            Rectangle {
                                visible: tile.count > 0
                                readonly property real s: grid.style ? grid.style.badgeSize : 14
                                x: tile.width - s - 3
                                y: 3
                                width: s
                                height: s
                                radius: s / 2
                                color: Theme.accent
                                Text {
                                    anchors.centerIn: parent
                                    text: tile.count
                                    font.family: "Inter"
                                    font.pixelSize: 9
                                    font.bold: true
                                    color: Theme.textOnAccent
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- the pointer ------------------------------------------------------------------------
    // One area over the box and arithmetic for the cell (the tiles are pooled: no per-tile area to move or to leak).
    property var _lastPos: ({ x: -1, y: -1 })
    function _cellAtViewport(vx, vy) {
        return grid.layoutObj ? Model.indexAt(grid.layoutObj, vx, vy + view.contentY) : -1;
    }
    function _followPointer() {
        if (!mouse.containsMouse)
            return;
        const i = grid._cellAtViewport(mouse.mouseX, mouse.mouseY);
        if (i >= 0 && i !== grid.current)
            grid.hovered(i);
    }
    MouseArea {
        id: mouse
        objectName: "pickerMouse"
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: grid._cellAtViewport(mouse.mouseX, mouse.mouseY) >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
        onPositionChanged: m => {
            // A resting pointer's hover is delivered again every frame: only a pointer that MOVED counts.
            if (m.x === grid._lastPos.x && m.y === grid._lastPos.y)
                return;
            grid._lastPos = { x: m.x, y: m.y };
            const i = grid._cellAtViewport(m.x, m.y);
            if (i >= 0 && i !== grid.current)
                grid.hovered(i);
        }
        onClicked: m => {
            const i = grid._cellAtViewport(m.x, m.y);
            if (i < 0)
                return;
            if (m.button === Qt.RightButton) {
                grid.hovered(i);
                grid.contextRequested(i);
            } else {
                grid.picked(i, (m.modifiers & Qt.ShiftModifier) !== 0, (m.modifiers & Qt.ControlModifier) !== 0);
            }
        }
    }

    // ---- the Clear control ----------------------------------------------------------------------
    FontMetrics {
        id: headFm
        font.family: grid.fontFamily
        font.pixelSize: 11
        font.bold: true
    }
    Item {
        id: clearLayer
        objectName: "pickerClearLayer"
        anchors.fill: viewport
        clip: true
        UndoDrainButton {
            id: clearBtn
            objectName: "pickerClear"
            // The header row's y (-1 = no such header), and the label's middle in it: the label sits on the row's foot, so the plate is
            // centred on the label's line, not on the row.
            readonly property real headY: grid.layoutObj && grid.clearSec !== "" && grid.layoutObj.secY[grid.clearSec] !== undefined ? grid.layoutObj.secY[grid.clearSec] : -1
            readonly property real headH: grid.style ? grid.style.headH : 26
            visible: clearBtn.headY >= 0
            x: grid.layoutObj ? view.width - grid.layoutObj.pad - 6 - width : 0
            y: Math.round(clearBtn.headY - view.contentY - grid._rim + clearBtn.headH - 4 - Math.ceil(headFm.height) / 2 - height / 2)
            width: implicitWidth
            height: grid.style ? grid.style.clearHeight : 20
            text: "Clear"
            undoText: "Undo"
            drainMs: grid.undoMs
            surfaceColor: grid.boxColor
            shadowToAlpha: true
            fontFamily: grid.fontFamily
            fontPixelSize: 11
            drainWidth: 5
            onClicked: grid.clearClicked()
            onUndoClicked: grid.undoClicked()
            onExpired: grid.undoExpired()
        }
    }

    ScrollDressing {
        id: dressing
        objectName: "pickerScrollDressing"
        anchors.fill: viewport
        flick: view
        fadeHeight: grid.style ? grid.style.fadeHeight : 24
        ground: grid.boxColor
        outline: ({ x: 0, y: -grid._rim, w: view.width, h: view.height, radii: [grid._radius, grid._radius, grid._radius, grid._radius] })
        onWheeled: {
            scrollAnim.stop();
            grid._followPointer();
        }
    }
    Connections {
        target: view
        function onContentYChanged() {
            if (dressing.moving)
                grid._followPointer();
        }
    }
}
