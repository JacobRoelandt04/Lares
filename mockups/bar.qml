pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/components"
import "modules/common/components/Mix.js" as Mix
import "modules/common/mockup"
import "modules/common/theme"
import "modules/bar/gooey"

// =============================================================================
// mockups/bar.qml -- the gooey bar engine on a section of the screen.
//
// Every bar and popup is one surface (GooeyField): popups grow out of their
// bars, travel along them, ride around a screen corner onto the next bar, jump
// when there is no bar to ride on, and -- new -- a SECONDARY popup grows out of
// an open one, centred on what was clicked in it. And THE LANE: the
// notifications' toast stack, a popup of its own in the top-right corner that
// stays out while thePopup comes and goes, sliding aside and melting with it.
//
// The scene is built to have every case in it at once: a top bar split by a
// void, a right bar meeting the top bar's end corner ON corner, a left bar
// starting under the top bar (a perpendicular corner), a second right bar
// behind a void, and a bottom bar floating between two voids. Checkboxes take
// bars away (take both side bars away and top and bottom have no path).
//
//   quickshell -p mockups/bar.qml
//   OPEN=<owner> CHILD=<tile> GRAB=<png> ... for renders (see onCompleted)
//   SEQ="tiles@300;tile:3@900"  clicks tile 3 of the tiles popup (its own path)
//   LANE=<n>                    opens the lane with n toasts at launch
// =============================================================================
MockupWindow {
    id: win

    moduleId: "bar"
    title: "Gooey bar engine"
    stageLabel: "A section of the screen at 1:1 — six bars, thePopup and its secondary"
    content: scene
    target: engine
    stageColor: "#1F2229"
    zoom: 0.8
    panelWidth: 480
    // WINW / WINH: a window big enough for the whole scene at 1:1, for renders.
    width: Number(Quickshell.env("WINW") || 1480)
    height: Number(Quickshell.env("WINH") || 960)

    lists: ({
            engineShape: win.engineShape,
            engineLane: win.engineLane,
            bottomBarShape: win.bottomBarShape,
            leftBarShape: win.leftBarShape,
            engineMotion: win.engineMotion,
            engineChild: win.engineChild,
            engineDebug: win.engineDebug,
            barColors: win.barColors
        })
    themedLists: ["barColors"]
    // One bar's own numbers write to that bar (GooeyBar: thickness, radius).
    targets: ({
            bottomBarShape: bottomBar,
            leftBarShape: leftBar
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Engine",
            subs: [
                {
                    name: "Shape",
                    lists: ["engineShape"]
                },
                {
                    name: "Bars",
                    lists: ["bottomBarShape", "leftBarShape"]
                },
                {
                    name: "Motion",
                    lists: ["engineMotion"]
                },
                {
                    name: "Secondary",
                    lists: ["engineChild"]
                },
                {
                    name: "Lane",
                    lists: ["engineLane"]
                },
                {
                    name: "Debug",
                    lists: ["engineDebug"]
                },
                {
                    name: "Colours",
                    lists: ["barColors"]
                }
            ]
        }
    ]

    // =====================================================================
    //  THE WALLPAPER (as mockups/power.qml: the real one, following the theme)
    // =====================================================================
    MockupWallpaper {
        id: stageWall
    }
    readonly property string wallpaper: stageWall.source

    // =====================================================================
    //  WHAT THE RUN PAGE DRIVES
    // =====================================================================
    property bool withTopRight: true
    property bool withRightTop: true
    property bool withRightBottom: true
    property bool withBottom: true
    property bool withLeft: true

    // The secondary popup's demo settings, read by the tiles content.
    property string childSide: "far"
    property bool childOverhang: false
    property real childWidth: 300
    // What each tile of the tiles popup asks for, so clicking through them shows
    // every placement a secondary can take -- including the two the engine grew
    // for this round: wider than its parent on BOTH sides, and the same inset
    // into it. The parent is 460 wide at x 70..530, so 500 hangs 20 px past each
    // of its sides without reaching the left bar.
    readonly property var tileSpecs: [
        { label: "flush left", width: 300, overhang: false, inset: 0 },
        { label: "centred", width: 300, overhang: false, inset: 0 },
        { label: "flush right", width: 300, overhang: false, inset: 0 },
        { label: "wide, both sides", width: 500, overhang: false, inset: 0 },
        { label: "wide, inset 40", width: 500, overhang: false, inset: 40 },
        { label: "overhang", width: 300, overhang: true, inset: 0 }
    ]
    property real childHeight: 200
    // The live contract's surfaceTint, on the content-sized popup (Run page).
    property bool tintSized: false
    // THE LANE's placeholder: how many toasts it shows, and whether its content
    // says a swipe is under the fingers (a close then waits for the lift).
    property int laneToasts: 2
    property bool laneGesture: false

    // =====================================================================
    //  PLACEHOLDER CONTENT -- themed, so the surface is the only thing judged
    // =====================================================================
    component DemoCard: Item {
        id: card
        property string title: ""
        property string body: ""
        Text {
            x: 16
            y: 14
            text: card.title
            color: Theme.textPrimary
            font.family: "Audiowide"
            font.pixelSize: 16
            font.bold: true
        }
        Text {
            x: 16
            y: 42
            width: card.width - 32
            text: card.body
            color: Theme.textMuted
            font.family: "Audiowide"
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
    }

    Component {
        id: compCalendar
        DemoCard {
            title: "Calendar"
            body: "400 × 300, from the middle of the right half of the top bar."
        }
    }
    Component {
        id: compMusic
        DemoCard {
            title: "Music"
            body: "320 × 150."
        }
    }
    Component {
        id: compSettings
        DemoCard {
            title: "Settings"
            body: "2D: grows out of the corner where two bars cross."
        }
    }
    Component {
        id: compVolume
        DemoCard {
            title: "Volume"
            body: "250 × 200 on a vertical bar."
        }
    }
    Component {
        id: compNotifications
        DemoCard {
            title: "Notifications"
            body: "The popup's size along its bar, and out of it, swap on a side bar."
        }
    }

    // Sized by its content: w/h are null, the engine follows implicitWidth /
    // implicitHeight on its resize clock. Click to grow.
    Component {
        id: compSized
        Item {
            id: sized
            property bool expanded: false
            // Transparent is no tint: the surface is drawn as if the member
            // were not declared.
            property color surfaceTint: win.tintSized ? Mix.c(Theme.surface, Theme.catFlatpak, 0.35) : "transparent"
            implicitWidth: sized.expanded ? 420 : 280
            implicitHeight: sized.expanded ? 260 : 140
            DemoCard {
                anchors.fill: parent
                title: "Content-sized"
                body: sized.expanded ? "420 × 260. Click to shrink." : "280 × 140. Click to grow: the popup follows its content's implicit size."
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: sized.expanded = !sized.expanded
            }
        }
    }

    // THE LANE's content: a toast stack sized by its content, speaking the
    // swipe-hold contract (a close waits while `swipeGestureActive`).
    Component {
        id: compLane
        Item {
            id: laneContent
            implicitWidth: 340
            implicitHeight: 12 + win.laneToasts * 72
            property bool swipeGestureActive: win.laneGesture
            readonly property real gestureHoldWidth: 520
            readonly property real gestureHoldHeight: 420
            function gestureWheel(ev) {
                return laneContent.swipeGestureActive;
            }
            Column {
                x: 12
                y: 12
                spacing: 12
                Repeater {
                    model: win.laneToasts
                    ShadowBox {
                        id: toast
                        required property int index
                        width: 316
                        height: 60
                        baseRadius: 14
                        surfaceColor: Theme.surface
                        bevelColor: Theme.bevel
                        shadowColor: Theme.border
                        backgroundColor: Theme.listBox
                        bevelWidth: 1
                        shadowWidth: 3
                        Text {
                            x: 14
                            y: 10
                            text: "Toast " + (toast.index + 1)
                            color: Theme.textPrimary
                            font.family: "Audiowide"
                            font.pixelSize: 12
                        }
                        Text {
                            x: 14
                            y: 32
                            text: "The lane: out beside thePopup, never over it."
                            color: Theme.textMuted
                            font.family: "Inter"
                            font.pixelSize: 11
                        }
                    }
                }
            }
        }
    }
    function openLane() {
        engine.openLane("toasts", "topR", topR.width, null, null, true, compLane, 0.5);
    }

    // THE CONTENT CONTRACT: tiles that open a secondary popup centred on the
    // tile that was clicked. Nothing here knows about the engine.
    Component {
        id: compTiles
        Item {
            id: tiles
            implicitWidth: 460
            implicitHeight: 280

            property Component secondaryComponent: compDetail
            property bool secondaryOpen: false
            property point secondaryAnchor: Qt.point(0, 0)
            property string secondarySide: win.childSide
            property bool secondaryOverhang: win.childOverhang
            property real secondaryInset: win.childInset
            property var secondaryKey: -1

            // What a click on tile `i` does: its own placement, then the
            // detail centred on it. The Run page and the tiles-click probe call
            // this, so they go through exactly the path a click takes.
            function openTile(i) {
                if (tiles.secondaryOpen && tiles.secondaryKey === i) {
                    tiles.secondaryOpen = false;
                    return;
                }
                const spec = win.tileSpecs[i];
                win.childWidth = spec.width;
                win.childOverhang = spec.overhang;
                win.childInset = spec.inset;
                const t = tileGrid.itemAt(i);
                tiles.secondaryAnchor = t ? t.mapToItem(tiles, t.width / 2, t.height / 2)
                                          : Qt.point(tiles.width / 2, tiles.height / 2);
                tiles.secondaryKey = i;
                tiles.secondaryOpen = true;
            }

            // For the Run page: open the detail at a point of this content.
            function openAt(x, key) {
                tiles.secondaryAnchor = Qt.point(x, tiles.height / 2);
                tiles.secondaryKey = key;
                tiles.secondaryOpen = true;
            }
            function closeDetail() {
                tiles.secondaryOpen = false;
            }

            Text {
                x: 16
                y: 12
                text: "Click a tile"
                color: Theme.textPrimary
                font.family: "Audiowide"
                font.pixelSize: 16
                font.bold: true
            }

            Grid {
                x: 12
                y: 44
                columns: 3
                spacing: 12
                Repeater {
                    id: tileGrid
                    model: 6
                    ShadowBox {
                        id: tile
                        required property int index
                        width: 136
                        height: 106
                        baseRadius: 14
                        surfaceColor: Theme.surface
                        bevelColor: Theme.bevel
                        shadowColor: Theme.border
                        backgroundColor: tile.index === tiles.secondaryKey && tiles.secondaryOpen ? Theme.headerBox : Theme.listBox
                        bevelWidth: 1
                        shadowWidth: 3
                        Column {
                            anchors.centerIn: parent
                            spacing: 2
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "tile " + tile.index
                                color: Theme.textMuted
                                font.family: "Audiowide"
                                font.pixelSize: 13
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: win.tileSpecs[tile.index].label
                                color: Theme.textFaint
                                font.family: "Inter"
                                font.pixelSize: 10
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: tiles.openTile(tile.index)
                        }
                    }
                }
            }
        }
    }

    Component {
        id: compDetail
        Item {
            id: detail
            property var secondaryKey: -1
            // Where the parent covers this detail (an inset one): the text
            // starts below it.
            property rect secondaryCutout: Qt.rect(0, 0, 0, 0)
            implicitWidth: win.childWidth
            implicitHeight: win.childHeight + win.childInset
            DemoCard {
                x: 0
                y: detail.secondaryCutout.height > 0 ? detail.secondaryCutout.y + detail.secondaryCutout.height : 0
                width: detail.width
                height: detail.height - y
                title: typeof detail.secondaryKey === "number" && detail.secondaryKey >= 0 && detail.secondaryKey < win.tileSpecs.length
                       ? "Tile " + detail.secondaryKey + ": " + win.tileSpecs[detail.secondaryKey].label
                       : "Detail of tile " + detail.secondaryKey
                body: "The secondary popup, grown out of the one above, centred on the tile. Another tile slides it along and swaps this text while it is hidden."
            }
        }
    }

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    component BarChip: Rectangle {
        id: chip
        property string text: ""
        signal clicked
        width: 132
        height: 26
        radius: 13
        color: chipArea.containsMouse ? Theme.panelSunk : Theme.listBox
        border.width: 1
        border.color: Theme.border
        anchors.verticalCenter: parent ? parent.verticalCenter : undefined
        Text {
            anchors.centerIn: parent
            text: chip.text
            color: Theme.textPrimary
            font.family: "Audiowide"
            font.pixelSize: 11
        }
        MouseArea {
            id: chipArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    Item {
        id: scene
        clip: true
        implicitWidth: 1280
        implicitHeight: 800

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }
        Image {
            anchors.fill: parent
            source: win.wallpaper
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
        }

        // ---- The engine -----------------------------------------------
        GooeyEngine {
            id: engine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: [topL, topR, rightT, rightB, bottomBar, leftBar].filter(b => b.visible)

            GooeyBar {
                id: topL
                engine: engine
                barId: "topL"
                edge: "top"
                rawPos: 0
                rawLen: 560
                // Centred 320: the popup rests 50 px off the left bar, clear of
                // the wall (GooeyEngine: THE WALL), so a detail wider than it
                // can still hang past both of its sides.
                BarChip {
                    x: 254
                    text: "TILES"
                    onClicked: engine.toggle("tiles", "topL", 320, 460, 280, false, compTiles, 0.5)
                }
                BarChip {
                    x: 20
                    text: "MUSIC"
                    onClicked: engine.toggle("music-top", "topL", 86, 320, 150, false, compMusic)
                }
            }
            GooeyBar {
                id: topR
                engine: engine
                visible: win.withTopRight
                barId: "topR"
                edge: "top"
                rawPos: 700
                rawLen: engine.w - 700
                BarChip {
                    x: 60
                    text: "CALENDAR"
                    onClicked: engine.toggle("calendar", "topR", 126, 400, 300, false, compCalendar)
                }
                BarChip {
                    x: topR.width - 150
                    text: "SETTINGS 2D"
                    onClicked: engine.toggle("settings", "topR", topR.width - 84, 250, 200, true, compSettings)
                }
            }
            GooeyBar {
                id: rightT
                engine: engine
                visible: win.withRightTop
                barId: "rightT"
                edge: "right"
                rawPos: 0
                rawLen: 360
                BarChip {
                    x: 90
                    text: "VOLUME"
                    onClicked: engine.toggle("volume", "rightT", 156, 250, 200, false, compVolume)
                }
            }
            GooeyBar {
                id: rightB
                engine: engine
                visible: win.withRightBottom
                barId: "rightB"
                edge: "right"
                rawPos: 460
                rawLen: engine.h - 460
                BarChip {
                    x: 60
                    text: "NOTIFS"
                    onClicked: engine.toggle("notifs-right", "rightB", 126, 250, 200, false, compNotifications)
                }
            }
            GooeyBar {
                id: bottomBar
                engine: engine
                visible: win.withBottom
                barId: "bottom"
                edge: "bottom"
                rawPos: 240
                rawLen: 800
                BarChip {
                    x: 60
                    rotation: 180
                    text: "SIZED"
                    onClicked: engine.toggle("sized", "bottom", 126, null, null, false, compSized, 1)
                }
                BarChip {
                    x: 334
                    rotation: 180
                    text: "CALENDAR"
                    onClicked: engine.toggle("calendar-bottom", "bottom", 400, 600, 300, false, compCalendar)
                }
                BarChip {
                    x: 610
                    rotation: 180
                    text: "MUSIC"
                    onClicked: engine.toggle("music-bottom", "bottom", 676, 250, 200, false, compMusic)
                }
            }
            GooeyBar {
                id: leftBar
                engine: engine
                visible: win.withLeft
                barId: "left"
                edge: "left"
                // Under the top bar: its own thickness.
                rawPos: topL.thickness
                rawLen: 560
                BarChip {
                    x: 40
                    text: "NOTIFS 2D"
                    onClicked: engine.toggle("notifs-left", "left", 106, 250, 300, true, compNotifications)
                }
                BarChip {
                    x: 360
                    text: "VOLUME"
                    onClicked: engine.toggle("volume-left", "left", 426, 250, 300, false, compVolume)
                }
            }
        }
    }

    // =====================================================================
    //  DRIVING IT
    // =====================================================================
    // The same actions the chips run, by owner, for the Run page and for
    // OPEN=<owner> at launch.
    readonly property var actions: ({
            "tiles": ["topL", 320, 460, 280, false, compTiles, 0.5],
            "music-top": ["topL", 86, 320, 150, false, compMusic, 0.5],
            "calendar": ["topR", 126, 400, 300, false, compCalendar, 0.5],
            "settings": ["topR", 496, 250, 200, true, compSettings, 0.5],
            "volume": ["rightT", 156, 250, 200, false, compVolume, 0.5],
            "notifs-right": ["rightB", 126, 250, 200, false, compNotifications, 0.5],
            "sized": ["bottom", 126, null, null, false, compSized, 1],
            "calendar-bottom": ["bottom", 400, 600, 300, false, compCalendar, 0.5],
            "music-bottom": ["bottom", 676, 250, 200, false, compMusic, 0.5],
            "notifs-left": ["left", 106, 250, 300, true, compNotifications, 0.5],
            "volume-left": ["left", 426, 250, 300, false, compVolume, 0.5]
        })

    function openOwner(owner) {
        const a = win.actions[owner];
        if (!a)
            return;
        if (engine.popupOpen && engine.popupOwnerId === owner)
            return;
        engine.toggle(owner, a[0], a[1], a[2], a[3], a[4], a[5], a[6]);
    }

    function tilesContent() {
        const p = engine.thePopup;
        return engine.popupOpen && engine.popupOwnerId === "tiles" && p.contentItem ? p.contentItem : null;
    }

    // Opens the tiles popup if it is not out, then the detail at `x` of it.
    function childAt(x, key, width, overhang, inset) {
        win.childWidth = width;
        win.childOverhang = overhang;
        win.childInset = inset || 0;
        if (!win.tilesContent()) {
            win.openOwner("tiles");
            pendingChild.args = [x, key];
            pendingChild.restart();
            return;
        }
        win.tilesContent().openAt(x, key);
    }

    Timer {
        id: pendingChild
        property var args: []
        interval: 450
        onTriggered: {
            const t = win.tilesContent();
            if (t)
                t.openAt(pendingChild.args[0], pendingChild.args[1]);
        }
    }

    Timer {
        id: slideLater
        interval: 700
        onTriggered: win.childAt(390, 5, win.childWidth, win.childOverhang)
    }

    // CYCLE=1: the same journey over and over, for tools/dev/perf/gooey_perf.sh --
    // open, slide along the bar, around a corner, down the side, across to
    // the bottom, close.
    readonly property var cycleSteps: ["music-top", "tiles", "calendar", "volume", "notifs-right", "calendar-bottom", ""]
    property int cycleIndex: 0
    Timer {
        running: Quickshell.env("CYCLE") === "1"
        repeat: true
        interval: 700
        onTriggered: {
            const owner = win.cycleSteps[win.cycleIndex % win.cycleSteps.length];
            win.cycleIndex++;
            if (owner === "")
                engine.close();
            else
                win.openOwner(owner);
        }
    }

    // ---- Scripted states for renders ---------------------------------------
    // SLOW=<ms> sets every engine clock to that duration, so a grab GRAB_MS
    // after launch lands at a known fraction of an animation, in both engines.
    // SEQ="<action>@<ms>;..." runs actions at those times after launch:
    //   <owner>                 opens that popup (see `actions`)
    //   close                   closes the popup
    //   child:<x>:<w>:<o>[:<i>] the tiles' detail at x, width w, overhang 0|1,
    //                           inset i px into the parent
    // NOBARS=left,rightT,...    starts with those bars removed.
    property var seqEvents: []
    property real seqStart: 0
    Timer {
        id: seqTimer
        interval: 5
        repeat: true
        onTriggered: {
            const now = Date.now() - win.seqStart;
            while (win.seqEvents.length > 0 && win.seqEvents[0].at <= now) {
                const ev = win.seqEvents.shift();
                win.runSeqAction(ev.action);
            }
            if (win.seqEvents.length === 0)
                seqTimer.stop();
        }
    }
    // ---- POSED states -------------------------------------------------------
    // A grab GRAB_MS after launch lands wherever the wall clock had got to,
    // and four runs of one state landed up to 80 ms apart -- fine for a sheet
    // to look at, useless for a gate that compares two runs pixel by pixel.
    // A POSE runs the actions, then STOPS every clock and writes the numbers:
    // the same pose is the same picture in every run.
    //
    //   POSE=open:<owner>:<t>[:<fade>]
    //   POSE=rest:<owner>                   open and FINISHED: phase "open", the
    //                                       clip layer as the engine leaves it at
    //                                       rest (an open: pose at t 1 is still
    //                                       "opening", so its layer is on)
    //   POSE=close:<owner>:<t>[:<fade>]
    //   POSE=child:<x>:<w>:<overhang>:<inset>:<t>[:<fade>]
    //   POSE=migrate:<from>:<to>:<t>[:<fade>]
    //
    // Grab well after settleMs: a join that has let go relaxes on its own
    // clock, and only once it has stopped is the shape a function of t alone.
    function freezeSlot(S, t, fade) {
        S.stop();
        S.slideT = 1;
        S.contentOpacity = fade;
        S.t = t;
        engine.layout();
    }
    function applyPose(spec) {
        const p = spec.split(":");
        const kind = p[0];
        if (kind === "open") {
            win.openOwner(p[1]);
            win.freezeSlot(engine.thePopup, Number(p[2]), p[3] !== undefined ? Number(p[3]) : 1);
            return;
        }
        if (kind === "rest") {
            win.openOwner(p[1]);
            win.freezeSlot(engine.thePopup, 1, 1);
            engine.thePopup.finished();
            return;
        }
        if (kind === "close") {
            win.openOwner(p[1]);
            win.freezeSlot(engine.thePopup, 1, 1);
            engine.thePopup.finished();
            engine.close();
            win.freezeSlot(engine.thePopup, Number(p[2]), p[3] !== undefined ? Number(p[3]) : 1);
            return;
        }
        if (kind === "migrate") {
            win.openOwner(p[1]);
            win.freezeSlot(engine.thePopup, 1, 1);
            engine.thePopup.finished();
            win.openOwner(p[2]);
            win.freezeSlot(engine.thePopup, Number(p[3]), p[4] !== undefined ? Number(p[4]) : 1);
            return;
        }
        if (kind === "child") {
            win.openOwner("tiles");
            win.freezeSlot(engine.thePopup, 1, 1);
            engine.thePopup.finished();
            win.childWidth = Number(p[2]);
            win.childOverhang = p[3] === "1";
            win.childInset = Number(p[4] || 0);
            const c = win.tilesContent();
            if (c)
                c.openAt(Number(p[1]), 0);
            win.freezeSlot(engine.childPopup, Number(p[5]), p[6] !== undefined ? Number(p[6]) : 1);
        }
    }

    function runSeqAction(action) {
        const parts = action.split(":");
        if (parts[0] === "close") {
            engine.close();
        } else if (parts[0] === "tile") {
            const t = win.tilesContent();
            if (t)
                t.openTile(Number(parts[1]));
        } else if (parts[0] === "child") {
            win.childAt(Number(parts[1]), 0, Number(parts[2] || 300), parts[3] === "1", Number(parts[4] || 0));
        } else {
            win.openOwner(parts[0]);
        }
    }
    property real childInset: 0

    Component.onCompleted: {
        // OPEN=<owner> opens a popup at launch; CHILD=<x>[:width[:overhang]]
        // then opens the tiles' detail at that x; TILES=1 tints the field's
        // tiles and BOXES=1 outlines the bodies.
        // The content-clip gate's two levers: the surface with no content in
        // it, and the cut forced on at rest.
        if (Quickshell.env("HIDECONTENT") === "1")
            engine.hideContent = true;
        if (Quickshell.env("FORCECLIP") === "1")
            engine.forceContentClip = true;
        const slow = Number(Quickshell.env("SLOW") || 0);
        if (slow > 0) {
            engine.openMs = slow;
            engine.migrateMs = slow;
            engine.resizeMs = slow;
            engine.childMs = slow;
            engine.childSlideMs = slow;
        }
        const nobars = (Quickshell.env("NOBARS") || "").split(",");
        if (nobars.indexOf("topR") >= 0) win.withTopRight = false;
        if (nobars.indexOf("rightT") >= 0) win.withRightTop = false;
        if (nobars.indexOf("rightB") >= 0) win.withRightBottom = false;
        if (nobars.indexOf("bottom") >= 0) win.withBottom = false;
        if (nobars.indexOf("left") >= 0) win.withLeft = false;
        const seq = Quickshell.env("SEQ") || "";
        if (seq !== "") {
            win.seqEvents = seq.split(";").filter(x => x !== "").map(x => {
                const at = x.lastIndexOf("@");
                return { action: x.slice(0, at), at: Number(x.slice(at + 1)) };
            }).sort((a, b) => a.at - b.at);
            win.seqStart = Date.now();
            seqTimer.start();
        }
        if ((Quickshell.env("TILES") || "") === "1")
            engine.showTiles = true;
        if ((Quickshell.env("BOXES") || "") === "1")
            engine.showBoxes = true;
        const pose = Quickshell.env("POSE") || "";
        if (pose !== "")
            win.applyPose(pose);
        const open = Quickshell.env("OPEN") || "";
        if (open !== "")
            win.openOwner(open);
        const child = Quickshell.env("CHILD") || "";
        if (child !== "") {
            const parts = child.split(":");
            win.childAt(Number(parts[0]), 0, Number(parts[1] || 300), parts[2] === "1");
        }
        const lane = Quickshell.env("LANE") || "";
        if (lane !== "") {
            win.laneToasts = Math.max(1, Number(lane) || 2);
            win.openLane();
        }
    }

    // THE STATE READOUT. Not a binding on the boxes: that rebuilt and re-laid
    // out this text on every frame of every animation, and measured it cost
    // more than the engine did (0.8 ms of CPU and 8 ms/s of GPU per second of
    // motion). It is refreshed at 4 Hz while anything moves, and once when it
    // stops, so a still scene still renders no frames.
    property string readout: ""
    readonly property bool anyMoving: {
        const moving = ph => ph !== "open" && ph !== "closed";
        return moving(engine.thePopup.phase) || moving(engine.childPopup.phase) || moving(engine.theLane.phase);
    }
    onAnyMovingChanged: win.refreshReadout()
    Timer {
        running: win.anyMoving
        repeat: true
        interval: 250
        onTriggered: win.refreshReadout()
    }
    function refreshReadout() {
        const p = engine.thePopup;
        if (!p)
            return;
        win.readout = "thePopup:  " + (engine.popupOpen ? engine.popupOwnerId : "closed")
            + "   " + p.popX.toFixed(1) + ", " + p.popY.toFixed(1)
            + "   " + p.popW.toFixed(1) + " × " + p.popH.toFixed(1)
            + "\nradius:  " + engine.popupRadius.toFixed(2)
            + "   corners " + engine.popupCornerRadii.map(v => v.toFixed(1)).join(" / ")
            + "\nchild:  " + (engine.childOpen ? engine.childOwnerId : "closed")
            + "   " + engine.childX.toFixed(1) + ", " + engine.childY.toFixed(1)
            + "   " + engine.childW.toFixed(1) + " × " + engine.childH.toFixed(1)
            + "\nlane:  " + (engine.laneOpen ? engine.laneOwnerId : engine.laneBlocked ? "blocked" : "closed")
            + "   " + engine.theLane.popX.toFixed(1) + ", " + engine.theLane.popY.toFixed(1)
            + "   " + engine.theLane.popW.toFixed(1) + " × " + engine.theLane.popH.toFixed(1)
            + "\ntiles:  " + engine.tileCount + " / 48";
    }

    // Where thePopup and its child actually are IN THE WINDOW, printed just
    // before a grab (as mockups/power.qml's POPBOX).
    Timer {
        running: win.grabPath !== ""
        interval: Math.max(200, win.grabMs - 250)
        onTriggered: {
            const p = engine.thePopup;
            const a0 = engine.mapToItem(null, p.popX, p.popY);
            const a1 = engine.mapToItem(null, p.popX + p.popW, p.popY + p.popH);
            console.log("POPBOX " + a0.x.toFixed(2) + " " + a0.y.toFixed(2)
                + " " + (a1.x - a0.x).toFixed(2) + " " + (a1.y - a0.y).toFixed(2));
            // Whether the clip is a layer on this frame (the clip-switch gate
            // proves its plain render really dropped it).
            console.log("CLIPSTATE popup=" + p.contentLayered + " child=" + engine.childPopup.contentLayered);
            if (engine.childOpen) {
                const c0 = engine.mapToItem(null, engine.childX, engine.childY);
                const c1 = engine.mapToItem(null, engine.childX + engine.childW, engine.childY + engine.childH);
                console.log("CHILDBOX " + c0.x.toFixed(2) + " " + c0.y.toFixed(2)
                    + " " + (c1.x - c0.x).toFixed(2) + " " + (c1.y - c0.y).toFixed(2));
            }
            // The bodies the field was handed on this frame, in scene
            // coordinates, so a probe can redraw exactly this state alone
            // (test_gooey_field_probe.qml BODIES=).
            for (let i = 0; i < engine.children.length; i++) {
                const c = engine.children[i];
                if (c.cornerRadii !== undefined && c.bodies !== undefined)
                    console.log("BODIES " + JSON.stringify(c.bodies));
            }
        }
    }

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Bars"
                blurb: "Take bars away to make the voids, corners and paths the popup has to deal with."
            }
            TipRow {
                tip: "The top bar's right half. Without it the left half ends in a long void, and the settings popup has nowhere to be."
                CheckBox {
                    text: "top right"
                    checked: win.withTopRight
                    onToggled: win.withTopRight = checked
                }
                CheckBox {
                    text: "right top"
                    checked: win.withRightTop
                    onToggled: win.withRightTop = checked
                }
                CheckBox {
                    text: "right bottom"
                    checked: win.withRightBottom
                    onToggled: win.withRightBottom = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Take BOTH side bars away (and keep top and bottom) and there is no chain of bars between the top and the bottom: opening one from the other then closes the old popup in place and opens a fresh one, instead of travelling."
                CheckBox {
                    text: "bottom"
                    checked: win.withBottom
                    onToggled: win.withBottom = checked
                }
                CheckBox {
                    text: "left"
                    checked: win.withLeft
                    onToggled: win.withLeft = checked
                }
                Button {
                    text: "Pathless setup"
                    onClicked: {
                        win.withLeft = false;
                        win.withRightTop = false;
                        win.withRightBottom = false;
                        win.withBottom = true;
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Open"
                blurb: "The same as clicking the chip on the bar. Opening another while one is out migrates it."
            }
            TipRow {
                tip: "Popups on the top bar. TILES is the one with a secondary popup; SETTINGS opens and closes in 2D, out of the corner where the top bar meets the right one."
                Button { text: "tiles"; onClicked: win.openOwner("tiles") }
                Button { text: "music"; onClicked: win.openOwner("music-top") }
                Button { text: "calendar"; onClicked: win.openOwner("calendar") }
                Button { text: "settings 2D"; onClicked: win.openOwner("settings") }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Popups on the side and bottom bars: from the top, these travel around a corner (or two)."
                Button { text: "volume R"; onClicked: win.openOwner("volume") }
                Button { text: "notifs R"; onClicked: win.openOwner("notifs-right") }
                Button { text: "notifs L 2D"; onClicked: win.openOwner("notifs-left") }
                Button { text: "volume L"; onClicked: win.openOwner("volume-left") }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The bottom bar. SIZED has no size of its own: the popup follows its content's implicit size (click it to grow)."
                Button { text: "sized"; onClicked: win.openOwner("sized") }
                Button { text: "calendar B"; onClicked: win.openOwner("calendar-bottom") }
                Button { text: "music B"; onClicked: win.openOwner("music-bottom") }
                Button { text: "close"; onClicked: engine.close() }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The live contract's surfaceTint: SIZED's content hands the engine a colour for its whole surface (a third of the way from the surface to the flatpak magenta, re-mixed from the theme, so it follows a light/dark switch). It is poured across the join into the bar, which keeps the surface colour -- how far is `tint blend` on Engine > Shape."
                CheckBox {
                    text: "tint SIZED"
                    checked: win.tintSized
                    onToggled: win.tintSized = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Secondary popup"
                blurb: "Grows out of the tiles popup, centred on a point of it. Kept inside the parent's width unless it is wider than the parent (then it hangs past both sides) or overhang is on. CLICKING A TILE sets the width, overhang and inset itself, from that tile's own case (tile 3 is wide, tile 4 wide and inset, tile 5 overhanging), so it overrides these controls until the next click."
            }
            TipRow {
                tip: "Which side of the tiles popup it grows from. far = away from the bar (below, for a top bar); start / end = along the bar (left / right)."
                ComboBox {
                    model: ["far", "start", "end"]
                    currentIndex: model.indexOf(win.childSide)
                    onActivated: win.childSide = currentText
                }
                CheckBox {
                    text: "overhang"
                    checked: win.childOverhang
                    onToggled: win.childOverhang = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Centred under the left, middle and right tile. At the left and right it is pushed back inside the parent, so one of its sides runs flush with the parent's."
                Button { text: "left"; onClicked: win.childAt(80, 0, 300, false) }
                Button { text: "centre"; onClicked: win.childAt(230, 1, 300, false) }
                Button { text: "right"; onClicked: win.childAt(380, 2, 300, false) }
                Button { text: "close it"; onClicked: { const t = win.tilesContent(); if (t) t.closeDetail(); } }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The three ways its side can meet the parent's: exactly flush (one straight edge), 5 px inside (a short S where the parent's corner rounds out and the child's rounds in), and hanging 40 px past it (the S the other way round)."
                Button { text: "flush"; onClicked: win.childAt(460 - 150, 3, 300, false) }
                Button { text: "inside 5"; onClicked: win.childAt(460 - 155, 4, 300, false) }
                Button { text: "overhang 40"; onClicked: win.childAt(460 - 150 + 40, 5, 300, true) }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Wider than the tiles popup: it hangs past BOTH of its sides, the S-curves on either side rounding the other way. Inset 40: the same detail reaches 40 px up into the tiles popup; that overlap belongs to the tiles popup and the detail's text starts below it."
                Button { text: "wide both"; onClicked: win.childAt(230, 6, 560, false) }
                Button { text: "wide inset 40"; onClicked: win.childAt(230, 7, 560, false, 40) }
                Button { text: "narrow inset 40"; onClicked: win.childAt(230, 8, 300, false, 40) }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Slide: open under the left tile, then another tile 0.7 s later -- the detail slides along the parent's edge and swaps its text while it is hidden. Then take the parent away with the child still out, or move the parent to another module."
                Button {
                    text: "slide A→B"
                    onClicked: {
                        win.childAt(80, 0, 300, false);
                        slideLater.restart();
                    }
                }
                Button { text: "close parent"; onClicked: engine.close() }
                Button { text: "migrate parent"; onClicked: win.openOwner("music-top") }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The lane"
                blurb: "theNotification: the notifications' toast stack, a popup of its own out of the top-right corner (2D, as a point). It stays out while thePopup comes and goes: where thePopup will be, it slides aside along the bar and melts with it, and glides back when it goes."
            }
            TipRow {
                tip: "Open or close the lane. Open a popup near the right of the top bar (settings 2D, calendar) to watch it make room -- and the popup come out behind it."
                Button { text: "open lane"; onClicked: win.openLane() }
                Button { text: "close lane"; onClicked: engine.closeLane() }
                Button { text: "+ toast"; onClicked: win.laneToasts = Math.min(6, win.laneToasts + 1) }
                Button { text: "− toast"; onClicked: win.laneToasts = Math.max(1, win.laneToasts - 1) }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The swipe-hold contract: while the content says a swipe is under the fingers, close lane WAITS -- the last toast swiped away must not take the surface from under them. Untick to lift the fingers."
                CheckBox {
                    text: "gesture held"
                    checked: win.laneGesture
                    onToggled: win.laneGesture = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
            }
            Label {
                Layout.fillWidth: true
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                wrapMode: Text.Wrap
                text: win.readout
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    // Two bars' own numbers (GooeyBar: every bar carries its own thickness and
    // radius; the engine's are only their defaults). Everything placed against
    // a bar follows ITS thickness -- the face its popups hang from, how far a
    // popup on the perpendicular bar keeps off it, the wall a migration rides
    // past it -- so any value here is one property, not a special case.
    readonly property var bottomBarShape: [
        {
            label: "thickness",
            prop: "thickness",
            group: "Bottom bar",
            blurb: "The floating bottom bar: the sized, calendar and music popups hang from it.",
            tip: "This bar's own thickness, 40 like the others by default. Its popups' face follows it (a 6 px bar is the launcher's slim bar); the fillets stay circles of the fillet radius in the air on the popup's side, whatever the bar's thickness.",
            val: 40,
            from: 2,
            to: 72,
            step: 1
        },
        {
            label: "corner radius",
            prop: "radius",
            group: "Bottom bar",
            tip: "This bar's own corner radius at its free ends, 20 by default. A corner on the screen's edge is always square (the user); a free corner beside one rounds across the bar's whole thickness (a 6 px bar of radius 20 ends in one 20 x 6 curve from its face to the screen's edge).",
            val: 20,
            from: 0,
            to: 40,
            step: 1
        }
    ]
    readonly property var leftBarShape: [
        {
            label: "thickness",
            prop: "thickness",
            group: "Left bar",
            blurb: "The side bar under the top bar's left half: the 2D notifications popup and the volume popup hang from it.",
            tip: "This bar's own thickness, 40 by default. The tiles and music popups on the top bar keep off it by this much, and the 2D popup opens out of the corner it makes with the top bar.",
            val: 40,
            from: 2,
            to: 72,
            step: 1
        }
    ]

    readonly property var engineShape: [
        {
            label: "bar thickness",
            prop: "thickness",
            group: "Bars",
            blurb: "The bars themselves. Every popup is placed from these.",
            tip: "How thick the bars are -- the default of every bar that has no thickness of its own (the bottom and left bars have theirs on the Bars tab). Popups hang from their bar's inner face, so this also moves every popup on those bars.",
            val: 40,
            from: 24,
            to: 72,
            step: 1
        },
        {
            label: "corner radius",
            prop: "maxR",
            group: "Bars",
            tip: "The corner radius of a popup at rest, and the default of every bar's own (the bottom bar has its own on the Bars tab). A popup that is still small is rounder (surface tension) and eases down to this as it inflates.",
            val: 20,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "fillet radius",
            prop: "blendRadius",
            group: "Where bodies meet",
            blurb: "The one surface: how a popup melts into its bar and a child into its popup.",
            tip: "How far a join's concave curve runs along the face it joins, at most. Where a popup meets its bar far from any end it is a quarter circle of this radius; near an end the S-curve there tightens to fit. Equal to the corner radius, inside and outside curves match, which is the old engine's look.",
            val: 20,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "attach distance",
            prop: "attachDistance",
            group: "Where bodies meet",
            tip: "A popup face this close to a bar face is drawn fully against it (the popup's content stays where it is). It is what closes the hole a popup a few pixels under a perpendicular bar used to leave. The old engine had no full-attach zone and let go over the whole snap distance.",
            val: 12,
            from: 0,
            to: 50,
            step: 1
        },
        {
            label: "snap distance",
            prop: "snapDistance",
            group: "Where bodies meet",
            tip: "Beyond the attach distance a face lets go gradually, completely at this distance; a popup this far past a bar's end still pulls a flare out of it. 50 is the old engine's.",
            val: 50,
            from: 1,
            to: 150,
            step: 1
        },
        {
            label: "settle ms",
            prop: "settleMs",
            group: "Where bodies meet",
            tip: "How long a join takes to let go once its popup has left -- the bar's corner turning back from bent outward to rounded inward after a popup crosses away from it. 0 lets go at once.",
            val: 160,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "tint blend",
            prop: "tintBlend",
            group: "Where bodies meet",
            tip: "How far a content's surfaceTint runs past its popup's join into the bar, and as far again into the popup, in px: the colour is poured across the join along the field's own distances, exactly the tint beyond it and exactly the surface on the bar's far side. 20 is the fillet's own size, so the colour turns where the surface does; up to the bar's thickness it still leaves the bar's outer half untouched. Tint SIZED on the Run page to see it.",
            val: 20,
            from: 1,
            to: 60,
            step: 1
        },
        {
            label: "flush snap",
            prop: "flushSnap",
            group: "Where bodies meet",
            tip: "A child whose side comes within this of its parent's side is snapped flush with it, and a popup's end within this of its bar's end is drawn flush (letting go by twice this), so nothing placed a pixel or two off draws a ledge or a sub-pixel S.",
            val: 3,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "stickiness",
            prop: "stickiness",
            group: "Resistance",
            blurb: "How the joins deform while a popup opens and closes.",
            tip: "0: a join moves rigidly with its popup's side. 1: its tip on the bar stays where it will be when the popup is open and the join stretches instead, which is what makes an opening popup look pressurised. Scaled by how much of the popup is out, so a sliver pulls nothing. 0.75 is the old engine's factor.",
            val: 0.75,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "stretch max",
            prop: "stretchMax",
            group: "Resistance",
            tip: "The longest a join stretches beyond its normal size, so a popup closing from very wide does not drag a join across half the bar.",
            val: 60,
            from: 0,
            to: 200,
            step: 1
        },
        {
            label: "side stretch",
            prop: "sideStretch",
            group: "Resistance",
            tip: "How much of the stretch also runs down the popup's side: the join getting taller as well as longer, the drop-shaped neck the old engine had. 0 stretches along the bar only.",
            val: 1,
            from: 0,
            to: 2,
            step: 0.05
        }
    ]

    readonly property var engineMotion: [
        {
            label: "open ms",
            prop: "openMs",
            group: "Open and close",
            blurb: "A popup coming out of its bar, and going back in. One clock for its whole box.",
            tip: "How long a popup takes to open and to close, in both engines (the A/B follows this group). 400 is the old engine's. Up to 10 s, to watch the shape change slowly.",
            val: 400,
            from: 100,
            to: 10000,
            step: 10
        },
        {
            label: "open easing",
            prop: "openEasingIndex",
            group: "Open and close",
            tip: "0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo. OutBack (3) overshoots and settles: the metaball bounce. Applies to both engines.",
            val: 3,
            from: 0,
            to: 5,
            step: 1
        },
        {
            label: "overshoot",
            prop: "openOvershoot",
            group: "Open and close",
            tip: "How far OutBack overshoots, in Qt's own units (its default is 1.70158), for a SHORT open: it swells past its rest by 5.3 % of its travel at 1.2. A tall open leans to the cap below (THE OVERSHOOT'S BIAS). 1.2 is the old engine's. Applies to both engines.",
            val: 1.2,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "overshoot cap",
            prop: "openOvershootCap",
            group: "Open and close",
            tip: "THE OVERSHOOT'S BIAS: the swell (px, times the popup ratio) a tall NARROW popup's open leans to. A short open swells by the curve's own share of its travel; as the travel grows the swell bends into this, or into the area budget below where the popup is wide -- still one OutBack per open, its overshoot chosen for its travel and width, so the motion stays continuous. 30 leaves every popup the shell has today to the area budget (the narrow ones, the reels and tray menus, are too short to reach it) and holds a tall narrow one near 25 px. 0: proportional all the way, the area budget off too (the old engine). A content may ask for its own `openOvershootCap` (the theme popup asks for 0: its floating cards carry the full swell).",
            val: 30,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "overshoot area",
            prop: "openOvershootArea",
            group: "Open and close",
            tip: "THE OVERSHOOT'S BIAS, across the motion: what reads as how much moved is the swell times the popup's extent ACROSS its open (its width out of a top bar, its height out of a side bar, the shorter side of a menu out of a point), so a wide popup's swell leans to this area (px², times the popup ratio squared) over its width. A reel 40 px across swells 9 px (360 px²) and looks calm; the clipboard 790 across swelled 11 (8900). 9000 keeps the reels and every tray menu level within 3 % of the old swell, brings the launcher (420 across) from 22 px to 18 and the clipboard from 11 to 9, and the widest popups most (silicon, 1026 across: 23 -> 9). 0: the cap alone (the previous rule).",
            val: 9000,
            from: 0,
            to: 40000,
            step: 250
        },
        {
            label: "overshoot bend",
            prop: "openOvershootBend",
            group: "Open and close",
            tip: "How sharply a growing open turns from the proportional swell into the cap and the area budget (a soft minimum of the three: where two of them meet and the third is far, the swell is that value / 2^(1/bend)). Larger keeps more of the proportional range and caps harder. 3: the reels and tray menus keep their swell, the launcher lands near 18 px, the clipboard comes down to 9.",
            val: 3,
            from: 0.5,
            to: 10,
            step: 0.5
        },
        {
            label: "migrate ms",
            prop: "migrateMs",
            group: "Travel",
            blurb: "A popup moving to another module: along the bar, or around the corners.",
            tip: "How long the journey takes, whatever its length.",
            val: 400,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "migrate easing",
            prop: "migrateEasingIndex",
            group: "Travel",
            tip: "0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo. OutQuint (2) leaves at once and arrives gently.",
            val: 2,
            from: 0,
            to: 5,
            step: 1
        },
        {
            label: "resize ms",
            prop: "resizeMs",
            group: "Resize",
            blurb: "A popup following its content's size, or the same module asking for a new one.",
            tip: "The shell's resize: 260 ms OutCubic, the same as every module's view change.",
            val: 260,
            from: 60,
            to: 1000,
            step: 10
        },
        {
            label: "resize easing",
            prop: "resizeEasingIndex",
            group: "Resize",
            tip: "0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo.",
            val: 1,
            from: 0,
            to: 5,
            step: 1
        },
        {
            label: "content fade ms",
            prop: "contentFadeMs",
            group: "Content",
            blurb: "What is inside the popup appearing, disappearing, and being swapped for another module's.",
            tip: "How long content takes to appear when a popup opens and to go when it closes. The shell's presence fade.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "swap out",
            prop: "swapOutFrac",
            group: "Content",
            tip: "When the popup travels to another module, the old content fades out over this share of the journey before the new one is put in.",
            val: 0.2,
            from: 0.05,
            to: 1,
            step: 0.05
        },
        {
            label: "swap in",
            prop: "swapInFrac",
            group: "Content",
            tip: "And the new content fades in over this share. Out then in, never both at once.",
            val: 0.3,
            from: 0.05,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var engineChild: [
        {
            label: "open ms",
            prop: "childMs",
            group: "The secondary popup",
            blurb: "Growing out of its parent, and back in.",
            tip: "How long the secondary popup takes to open (and to close, from fully open).",
            val: 400,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "easing",
            prop: "childEasingIndex",
            group: "The secondary popup",
            tip: "0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo. OutBack gives it the same bounce as the popup out of its bar.",
            val: 3,
            from: 0,
            to: 5,
            step: 1
        },
        {
            label: "slide ms",
            prop: "childSlideMs",
            group: "The secondary popup",
            tip: "How long it takes to slide along its parent's side to another anchor.",
            val: 400,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "width from",
            prop: "childWidthFrom",
            group: "The secondary popup",
            tip: "The share of its width it starts at: 0.5 inflates sideways as it comes out, as the popup out of the bar does; 1 slides straight out.",
            val: 0.5,
            from: 0.05,
            to: 1,
            step: 0.05
        },
        {
            label: "close lead",
            prop: "closeChildLead",
            group: "The secondary popup",
            tip: "Closing a popup whose secondary is out: how far the secondary is back in (share of its size) before the popup itself starts to close. Until then the popup holds its box and its content. 0 closes both at once; 1 waits for the secondary to be all the way in. 0.9 starts the popup on the secondary's last tenth, so a popup never drags an open secondary into the bar.",
            val: 0.9,
            from: 0,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var engineLane: [
        {
            label: "glide ms",
            prop: "laneGlideMs",
            group: "The lane",
            blurb: "The notifications' toast stack beside thePopup.",
            tip: "How long the lane takes to slide aside when thePopup's target comes where it is, and back when it goes. One clock per placement; it is never re-placed per frame. A resize of thePopup moves it on thePopup's own resize clock instead, so the two faces move as one.",
            val: 400,
            from: 100,
            to: 1500,
            step: 10
        },
        {
            label: "glide easing",
            prop: "laneGlideEasingIndex",
            group: "The lane",
            tip: "0 Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo. OutCubic (1) clears the way at once, so a popup opening where the lane sat comes out behind it without waiting, and comes to rest against thePopup gently.",
            val: 1,
            from: 0,
            to: 5,
            step: 1
        },
        {
            label: "melt",
            prop: "laneMelt",
            group: "The lane",
            tip: "On: the lane sits flush beside thePopup and the two melt -- a fillet at the free end, one surface. Off: it keeps the fillet radius away, two blobs with a channel between them.",
            val: true
        }
    ]

    readonly property var engineDebug: [
        {
            label: "show tiles",
            prop: "showTiles",
            group: "Debug",
            blurb: "What the field is doing underneath.",
            tip: "Tints each tile the field is drawn in. The tiles cover only where the surface can be, and meet edge to edge so no pixel is drawn twice.",
            val: false
        },
        {
            label: "single tile",
            prop: "forceSingleTile",
            group: "Debug",
            tip: "Draws the whole field as one tile covering everything. It must look identical to the tiled version -- that is the tiling's proof.",
            val: false
        },
        {
            label: "show boxes",
            prop: "showBoxes",
            group: "Debug",
            tip: "Outlines each popup's box (red) and the secondary's (cyan): the rectangles the surface is grown around.",
            val: false
        },
        {
            label: "always cut content",
            prop: "forceContentClip",
            group: "The cut",
            blurb: "The content is cut to the outline the field drew, not to the rectangle the popup clips to.",
            tip: "Keeps the cut on at rest too. It is normally dropped the moment the outline is the resting rounded rectangle again, because the cut is a layer and a layer at rest is an FBO nobody needs. Turn it on and nothing should change: content whose ink reaches into a corner of radius maxR is content that breaks its own radius rule.",
            val: false
        },
        {
            label: "hide content",
            prop: "hideContent",
            group: "The cut",
            tip: "Draws the surface with nothing in it: grabbed beside the normal frame, it shows exactly which pixels the content put outside the surface.",
            val: false
        }
    ]

    readonly property var barColors: [
        {
            label: "surface",
            prop: "surface",
            group: "The surface",
            blurb: "The bars and every popup are one surface in one colour.",
            tip: "The bars', the popups' and the secondary popup's surface.",
            val: "#EAEDF5"
        }
    ]
}
