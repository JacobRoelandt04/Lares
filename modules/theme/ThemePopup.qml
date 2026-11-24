pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/float"

// =============================================================================
// ThemePopup.qml -- the theme picker's drop-in: one row per pair, its light card and its dark card joined by sine strands. A click on a card applies that pair in that mode;
// the popup only picks, and stays open on a pick: the switch runs under it.
//
//   control        ThemeControl: `pick(name, mode)` and `pairs` (ThemePairs). Colours and names all come from there, as data.
//   motionRunning  the owner's word that this popup is on screen; `parked` is the engine's. Either false: the clock stops and nothing is drawn but what is asked.
//   outlineRadius  the popup's corner on screen, in this item's px: the owner's (GooeyEngine.popupRadius), so the hole below stays inside the surface.
//
// ONE CLOCK. A FloatClock, here (modules/common/float: the card float this popup was first to have), steps every card and the strands' flow, every frame;
// nothing else in the popup moves on its own. It stops when the popup is parked or hidden: a closed popup costs nothing. Through a theme switch it keeps going
// (the popup is a theme island, below).
//
// THROUGH A THEME SWITCH NOTHING HOLDS: this is the popup most likely to be open when one runs. The whole popup is ONE ThemeIsland, not one per card (a host
// cuts four holes): a rounded box a little inside the surface, so the old shell's picture keeps only the popup's edge. Most of what is in the hole does not depend on the palette at
// all: the cards and the strands are a pair's own data, the same on both sides of the line, so they are not copied, faded or held. What IS themed is the ground and the little that
// lies on it: the old ground is an IslandGround under the rows (cut by the line), and a card's shadow and the pair's name carry FadeColors. Nothing of this exists at rest but the
// island's plain Item: the ground is a Loader's, built at the ask and gone when the fade ends.
//
// THE KEYS (the player's rule, HoverArm): the keyboard is the popup's once the pointer has MOVED onto it, and goes back when it leaves: it never takes the keys from the
// window being typed in because it opened. Arrows move the hand, which lifts a card as the pointer does; Enter applies it. Escape is the shell's (EscapeBind).
// =============================================================================
Item {
    id: root

    property var control: null
    property ThemeStyle style: ThemeStyle {}
    property string fontFamily: "Inter"
    property real renderScale: 1
    property bool motionRunning: true
    property real outlineRadius: 20
    // The engine's prewarm builds it parked (GooeyEngine): nothing moves, and the keys are nobody's.
    property bool parked: false
    // THE OVERSHOOT'S BIAS (GooeyEngine): the cards float on their own clock and carry the open's whole swell -- the user's liked
    // one, as it was -- so this popup asks for no cap: its open overshoots by the curve's share of its travel.
    readonly property real openOvershootCap: 0

    readonly property var pairs: root.control ? root.control.pairs : null
    readonly property var names: root.pairs ? root.pairs.names : []
    readonly property var entries: root.pairs ? root.pairs.entries : ({})
    readonly property int rows: root.names.length
    readonly property bool _scrolls: root.rows > root.style.maxRows
    readonly property real _rowsH: root.style.cardHeight * Math.min(Math.max(1, root.rows), root.style.maxRows) + root.style.rowGap * (Math.min(Math.max(1, root.rows), root.style.maxRows) - 1)

    implicitWidth: Math.ceil(2 * root.style.padding + 2 * root.style.cardWidth + root.style.strandGap)
    implicitHeight: Math.ceil(2 * root.style.padding + root._rowsH)

    // ---- the engine's contract --------------------------------------------------------------------------------------------------------------------
    HoverArm {
        id: arm
        target: root
        active: root.visible && !root.parked
    }
    readonly property bool keysArmed: arm.armed
    readonly property string keyboardFocusRequest: arm.armed ? "exclusive" : "none"
    onKeysArmedChanged: if (root.keysArmed) root.forceActiveFocus()

    // ---- the clock ---------------------------------------------------------------------------------------------------------------------------------
    readonly property bool clockOn: root.motionRunning && !root.parked && root.visible
    property real flow: 0
    readonly property alias floatClock: cardClock
    FloatClock {
        id: cardClock
        running: root.clockOn
        holdOnCrossfade: false
        style: root.style
        onTicked: dt => root.flow += dt
    }

    // ---- the marks ----------------------------------------------------------------------------------------------------------------------------------
    // "<name>:<mode>": the card the pointer or the keys are on.
    property string currentKey: ""
    // ... and the card in force, moved when the palette commits and not when `Theme.mode` does: a switch writes the mode first and asks for the crossfade's picture after
    // it, and in a picture of this popup (one that opened too late to be an island) the ring would stand on its new card in the old shell.
    property string activeKey: ""
    Connections {
        target: Theme
        function onSettled() {
            root.activeKey = Theme.themeName + ":" + Theme.mode;
        }
    }

    function _keys(): var {
        // [[ "eva:light", "eva:dark" ], ...]
        return root.names.map(n => root.entries[n].modes.map(m => n + ":" + m));
    }
    function _move(dx: int, dy: int): void {
        const grid = root._keys();
        if (grid.length === 0)
            return;
        let r = grid.findIndex(row => row.indexOf(root.currentKey) >= 0);
        if (r < 0) {
            const start = root.activeKey;
            r = Math.max(0, grid.findIndex(row => row.indexOf(start) >= 0));
            root.currentKey = grid[r].indexOf(start) >= 0 ? start : grid[r][0];
            return;
        }
        let c = grid[r].indexOf(root.currentKey);
        if (dy !== 0) {
            r = (r + dy + grid.length) % grid.length;
            c = Math.min(c, grid[r].length - 1);
        } else {
            c = (c + dx + grid[r].length) % grid[r].length;
        }
        root.currentKey = grid[r][c];
        const y = r * (root.style.cardHeight + root.style.rowGap) + root.style.padding;
        if (y < list.contentY)
            list.contentY = y - root.style.padding;
        else if (y + root.style.cardHeight > list.contentY + list.height)
            list.contentY = y + root.style.cardHeight + root.style.padding - list.height;
    }
    function pickKey(key: string): void {
        const at = key.lastIndexOf(":");
        if (at > 0 && root.control)
            root.control.pick(key.substring(0, at), key.substring(at + 1));
    }
    focus: true
    Keys.onPressed: e => {
        if (e.key === Qt.Key_Left)
            root._move(-1, 0);
        else if (e.key === Qt.Key_Right)
            root._move(1, 0);
        else if (e.key === Qt.Key_Up)
            root._move(0, -1);
        else if (e.key === Qt.Key_Down)
            root._move(0, 1);
        else if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Space) && root.currentKey !== "")
            root.pickKey(root.currentKey);
        else
            return;
        e.accepted = true;
    }

    // ---- the island: this popup through a theme switch (the header) ---------------------------------------------------------------------------------
    // 2 px inside the surface: its antialiased edge and the bar's join stay the picture's.
    readonly property real _holeInset: 2
    ThemeIsland {
        id: popupIsland
        x: root._holeInset
        y: root._holeInset
        width: Math.max(0, root.width - 2 * root._holeInset)
        height: Math.max(0, root.height - 2 * root._holeInset)
        radius: Math.max(0, root.outlineRadius - root._holeInset)
        snap: true
        live: root.clockOn
    }
    // (A probe reads this.)
    readonly property bool islandArmed: popupIsland.armed
    ThemeOld {
        id: oldPalette
        enabled: popupIsland.live
    }
    FadeColor {
        id: groundFade
        token: "surface"
        active: popupIsland.armed
        place: root
    }
    Loader {
        id: oldGround
        active: popupIsland.armed && oldPalette.map !== null
        x: popupIsland.snapRect.x
        y: popupIsland.snapRect.y
        width: popupIsland.snapRect.width
        height: popupIsland.snapRect.height
        sourceComponent: Component {
            IslandGround {
                island: popupIsland
                ground: oldPalette.map ? oldPalette.map.surface : "transparent"
            }
        }
    }

    // ---- the rows ---------------------------------------------------------------------------------------------------------------------------------
    Flickable {
        id: list
        anchors.fill: parent
        interactive: false
        clip: root._scrolls
        contentWidth: width
        contentHeight: rowsColumn.implicitHeight + 2 * root.style.padding
        Column {
            id: rowsColumn
            x: root.style.padding
            y: root.style.padding
            spacing: root.style.rowGap
            Repeater {
                id: rowRepeater
                model: root.names
                ThemePairRow {
                    required property string modelData
                    required property int index
                    style: root.style
                    entry: root.entries[modelData]
                    rowIndex: index
                    clock: cardClock
                    flow: root.flow
                    fontFamily: root.fontFamily
                    currentKey: root.currentKey
                    activeKey: root.activeKey
                    islandArmed: popupIsland.armed
                    onPicked: (name, mode) => root.pickKey(name + ":" + mode)
                    onHoverEntered: key => root.currentKey = key
                    onHoverLeft: key => {
                        if (root.currentKey === key)
                            root.currentKey = "";
                    }
                }
            }
        }
    }
    ScrollDressing {
        anchors.fill: parent
        flick: list
        visible: root._scrolls
        wheelEnabled: root._scrolls
        ground: groundFade.value
    }

    Component.onCompleted: {
        root.activeKey = Theme.themeName + ":" + Theme.mode;
        if (root.pairs)
            root.pairs.rescan();
    }
}
