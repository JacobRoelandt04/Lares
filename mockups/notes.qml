pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

import "modules/common/mockup"
import "modules/common/system"
import "modules/common/theme"
import "modules/bar/gooey"
import "modules/notes"
import "modules/notes/browse"

// =============================================================================
// mockups/notes.qml -- the notes popup mockup, on the REAL bar engine.
//
// A slice of the screen at 1:1: a GooeyEngine with a top bar carrying the
// notes glyph, and thePopup the notes content opens in -- the drop-in as it
// will run, with the host contract for real: edge resizing followed live
// (liveResizeActive, alongShift, hostRoom), the note's colour poured over
// the popup and across the join (surfaceTint), the per-note sizes.
//
// THE NOTES ARE A SCRATCH COPY of mockups/fixtures/notes in
// $XDG_RUNTIME_DIR, made once and kept across reloads ("Reset notes" makes it
// again). Your own ~/Documents/Notes is used only after "Use my notes" is
// armed and confirmed on the Run page. The session file is the mockup's own.
//
// EDGE=left puts the popup where the shell does (docs/shell.md): out of a 6 px bar
// down the LEFT edge, under the 40 px top bar's left island (ISLAND=<px>, 900), opened by
// the button on the TOP bar through an anchor item near the left bar's top end -- the
// popup rests flush under the island (THE WALL). A 6 px bottom bar closes the corner as
// the shell's does. Everything the popup does is the same on either edge.
//
// Run it: quickshell -p mockups/notes.qml (in the sandbox when a shell is
// running here: tools/dev/sandbox.sh quickshell -p mockups/notes.qml).
// =============================================================================
MockupWindow {
    id: win

    moduleId: "notes"
    title: "Notes"
    stageLabel: leftMode ? "A section of the screen at 1:1 -- the top island, the 6 px left bar, the notes glyph, thePopup" : "A section of the screen at 1:1 -- a top bar, the notes glyph, thePopup"
    content: scene
    target: tun
    targets: ({
            floatSwayParams: notesFloat,
            floatLeanParams: notesFloat,
            floatDealParams: notesFloat
        })
    stageColor: "#1F2229"
    zoom: 1.0
    panelWidth: 460

    lists: ({
            gridParams: win.gridParams,
            editorParams: win.editorParams,
            resizeParams: win.resizeParams,
            motionParams: win.motionParams,
            floatSwayParams: win.floatSwayParams,
            floatLeanParams: win.floatLeanParams,
            floatDealParams: win.floatDealParams,
            noteColors: win.noteColors
        })
    themedLists: ["noteColors"]

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Grid",
            lists: ["gridParams"]
        },
        {
            name: "Editor",
            lists: ["editorParams"]
        },
        {
            name: "Resize",
            lists: ["resizeParams"]
        },
        {
            name: "Motion",
            lists: ["motionParams"]
        },
        {
            name: "Float",
            subs: [
                {
                    name: "Sway",
                    lists: ["floatSwayParams"]
                },
                {
                    name: "Lean",
                    lists: ["floatLeanParams"]
                },
                {
                    name: "Deal",
                    lists: ["floatDealParams"]
                }
            ]
        },
        {
            name: "Colours",
            lists: ["noteColors"]
        }
    ]

    // The shell's outlet (EDGE=left): the left bar, not the top one, carries the popup.
    readonly property bool leftMode: Quickshell.env("EDGE") === "left"
    readonly property real islandLen: Math.max(300, Number(Quickshell.env("ISLAND") || 900))

    // ---- Where the notes are -------------------------------------------------------------
    readonly property string scratchRoot: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lares-notes-mockup/notes"
    readonly property string fixtureRoot: RepoRoot.dir + "/mockups/fixtures/notes"
    readonly property string realRoot: (Quickshell.env("HOME") || "") + "/Documents/Notes"
    property string notesRoot: ""
    property bool useReal: false
    property bool armedReal: false

    Process {
        id: copyFixtures
        property bool force: false
        command: ["sh", "-c", 'if [ "$3" = 1 ] || [ ! -d "$1" ]; then rm -rf -- "$1" && mkdir -p -- "$(dirname -- "$1")" && cp -a -- "$2" "$1"; fi', "sh", win.scratchRoot, win.fixtureRoot, copyFixtures.force ? "1" : "0"]
    }
    Connections {
        target: copyFixtures
        function onExited(code) {
            win.notesRoot = win.useReal ? win.realRoot : win.scratchRoot;
        }
    }
    Component.onCompleted: copyFixtures.running = true

    function resetNotes() {
        if (win._owner)
            win._owner.close();
        win.useReal = false;
        win.notesRoot = "";
        copyFixtures.force = true;
        copyFixtures.running = true;
    }

    function useRealNotes() {
        if (win._owner)
            win._owner.close();
        win.useReal = true;
        win.armedReal = false;
        win.notesRoot = "";
        Qt.callLater(() => win.notesRoot = win.realRoot);
    }

    // ---- The tiles' float: the notes' own FloatStyle, handed to the owner (the Float tab's target) --------
    NotesFloatStyle {
        id: notesFloat
    }
    // SHEET_GRAB (the cleanup check's picture): the float has a clock of its own, so it does not start; the Run tab's switch too.
    property bool floatOn: win.sheetGrabPath === ""

    // ---- Tunables (the panel's target; the owner binds to them) ---------------------------
    QtObject {
        id: tun
        property bool dressAudiowide: true
        property real editorBodySize: 12
        property real editorTitleSize: 22
        property real minTile: 150
        property real maxTile: 210
        property real tileAspect: 0.7
        property real tileGap: 12
        property real browseWidth: 560
        property real browseHeight: 440
        property real noteWidth: 420
        property real noteHeight: 480
        property real minWidth: 300
        property real minHeight: 280
        property real iconAlong: 560
        property real morphMs: 320
        property real swipeBackUnits: 900
        property real swipeBackSign: 1
    }

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        implicitWidth: 1180
        implicitHeight: 800

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: gooeyEngine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: win.leftMode ? [topBar, leftBar, bottomBar] : [topBar]

            GooeyBar {
                id: topBar
                engine: gooeyEngine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                rawLen: win.leftMode ? Math.min(win.islandLen, gooeyEngine.w) : gooeyEngine.w

                NotesBarButton {
                    id: notesButton
                    x: Math.round(tun.iconAlong - width / 2)
                    y: Math.round((topBar.height - height) / 2)
                    owner: ownerLoader.item
                }
                Text {
                    x: topBar.width - width - 18
                    y: (topBar.height - height) / 2
                    text: "13:37"
                    color: Theme.textMuted
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            // The outlet bars (EDGE=left; in the top layout they are not in the engine's list and draw nothing).
            GooeyBar {
                id: leftBar
                engine: gooeyEngine
                barId: "left"
                edge: "left"
                rawPos: topBar.thickness
                rawLen: gooeyEngine.h - topBar.thickness - bottomBar.thickness
                thickness: 6
                reserve: 0
                inputMask: false
                // Where the popup hangs from: near the bar's top end (its x runs bottom to top).
                Item {
                    id: outlet
                    x: leftBar.rawLen - 24
                    y: 0
                    width: 1
                    height: 1
                }
            }
            GooeyBar {
                id: bottomBar
                engine: gooeyEngine
                barId: "bottom"
                edge: "bottom"
                rawPos: 0
                rawLen: gooeyEngine.w
                thickness: 6
                reserve: 0
                inputMask: false
            }
        }

        Loader {
            id: ownerLoader
            active: win.notesRoot !== ""
            sourceComponent: NotesBarOwner {
                engine: gooeyEngine
                bar: win.leftMode ? leftBar : topBar
                barId: win.leftMode ? "left" : "topBar"
                anchorItem: win.leftMode ? outlet : notesButton
                notesRoot: win.notesRoot
                statePath: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/lares/notes-mockup/" + (win.useReal ? "real" : "scratch") + "/session.json"
                fontFamily: tun.dressAudiowide ? "Audiowide" : "Inter"
                editorBodySize: tun.editorBodySize
                editorTitleSize: tun.editorTitleSize
                minTile: tun.minTile
                maxTile: tun.maxTile
                tileAspect: tun.tileAspect
                tileGap: tun.tileGap
                browseWidth: tun.browseWidth
                browseHeight: tun.browseHeight
                noteWidth: tun.noteWidth
                noteHeight: tun.noteHeight
                minWidth: tun.minWidth
                minHeight: tun.minHeight
                morphMs: tun.morphMs
                swipeBackUnits: tun.swipeBackUnits
                swipeBackSign: tun.swipeBackSign
                floatStyle: notesFloat
                shown: win.floatOn
            }
            // Open on start, like a click on the glyph.
            onLoaded: Qt.callLater(() => {
                if (win._owner && Quickshell.env("NOTES_NO_OPEN") !== "1")
                    win._owner.open();
                // NOTES_QUERY=<text>: start with that search typed (a grab of the "No match" state).
                if (win._owner && Quickshell.env("NOTES_QUERY"))
                    Qt.callLater(() => win._owner.activeStore.setQuery(Quickshell.env("NOTES_QUERY")));
            })
        }
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    readonly property NotesBarOwner _owner: ownerLoader.item as NotesBarOwner
    readonly property var _store: win._owner ? win._owner.activeStore : null
    // The popup's CONTENT (thePopup is the engine's body; its content item
    // is what carries the host contract).
    readonly property var _popup: gooeyEngine.thePopup && gooeyEngine.popupOwnerId === "notes" ? gooeyEngine.thePopup.contentItem : null

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "The popup"
                blurb: "Open and close it the way the bar does, and where its notes come from."
            }
            TipRow {
                tip: "The tiles' float (modules/common/float): off, the clock stops and every tile holds where it is, as when the popup is hidden. 'Deal again' replays the opening deal on the popup that is out."
                Layout.fillWidth: true
                spacing: 8
                CheckBox {
                    text: "Float"
                    checked: win.floatOn
                    onToggled: win.floatOn = checked
                }
                Button {
                    text: "Deal again"
                    onClicked: {
                        if (win._popup && win._popup.floatClock)
                            win._popup.floatClock.restartDeal();
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Open or close the popup, as a click on the notes glyph in the bar does. Dragging a file onto the glyph for half a second opens it too (spring-loading)."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win._owner && win._owner.popupMine ? "Close" : "Open"
                    onClicked: {
                        if (win._owner)
                            win._owner.toggle();
                    }
                }
                Button {
                    text: "Reset notes"
                    onClicked: win.resetNotes()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "The mockup works on a SCRATCH COPY of mockups/fixtures/notes. This switches it to your real ~/Documents/Notes: every edit, rename, group and delete there is real (deletes go to the trash). Arm, then confirm."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win.useReal ? "Using ~/Documents/Notes" : (win.armedReal ? "Confirm: use my notes" : "Use my notes...")
                    enabled: !win.useReal
                    onClicked: {
                        if (win.armedReal)
                            win.useRealNotes();
                        else
                            win.armedReal = true;
                    }
                }
                Button {
                    visible: win.armedReal
                    text: "Cancel"
                    onClicked: win.armedReal = false
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the popup and its store believe right now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: {
                    const s = win._store;
                    const p = win._popup;
                    if (!s)
                        return "notes: " + (win.notesRoot || "(copying)");
                    const lines = [];
                    lines.push("root: " + s.root.replace(Quickshell.env("HOME") || "~", "~"));
                    lines.push("view: " + s.view + (s.folder ? "   folder: " + s.folder : "") + (s.noteKey ? "   note: " + s.noteKey : "") + (s.newNote ? "   (new note)" : ""));
                    lines.push("entries: " + s.service.entries.count + "   sort: " + s.service.sortMode + (s.query ? "   search: " + s.query : ""));
                    if (p && p.implicitWidth !== undefined) {
                        lines.push("size: " + Math.round(p.implicitWidth) + " x " + Math.round(p.implicitHeight) + "   shift: " + Math.round(p.alongShift || 0) + (p.liveResizeActive ? "   RESIZING" : ""));
                        const r = p.hostRoom;
                        if (r)
                            lines.push("room: along " + Math.round(r.lo) + ".." + Math.round(r.hi) + "   out " + Math.round(r.out) + "   box " + Math.round(r.a0) + ".." + Math.round(r.a1));
                    }
                    lines.push("keyboard: " + gooeyEngine.popupKeyboard);
                    return lines.join("\n");
                }
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var gridParams: [
        {
            label: "min tile",
            prop: "minTile",
            group: "Tiles",
            blurb: "The browse grid: how big a tile may be and how they pack.",
            tip: "The narrowest a tile may get before a column is dropped. 150 puts three columns in the default 560 px popup (12 padding either side, 12 gaps) with room to spare, and a fourth only past 660.",
            val: 150,
            from: 90,
            to: 220,
            step: 1
        },
        {
            label: "max tile",
            prop: "maxTile",
            group: "Tiles",
            tip: "The widest a tile may grow before the grid centres itself with more margin rather than stretching the tile. 210 keeps a landscape tile a card, not a banner, when the popup is resized wide.",
            val: 210,
            from: 120,
            to: 320,
            step: 1
        },
        {
            label: "aspect",
            prop: "tileAspect",
            group: "Tiles",
            tip: "Tile height over width. 0.7: a landscape card (the user's choice, 'longer than they are high'), room for a title, about four lines of preview and the time.",
            val: 0.7,
            from: 0.6,
            to: 1.8,
            step: 0.01
        },
        {
            label: "gap",
            prop: "tileGap",
            group: "Tiles",
            tip: "Space between tiles. 12, the shell's one padding number, so the gutters match the popup's margins.",
            val: 12,
            from: 4,
            to: 28,
            step: 1
        },
        {
            label: "icon along bar",
            prop: "iconAlong",
            group: "Mockup",
            blurb: "The stage only: where the glyph sits, to try the popup against a screen edge.",
            tip: "Where the notes glyph sits along the bar in this mockup, in px from the left. Move it to an end to see the popup clamp at the screen edge and resize against it.",
            val: 560,
            from: 20,
            to: 1160,
            step: 1
        },
        {
            label: "Audiowide",
            prop: "dressAudiowide",
            group: "Mockup",
            tip: "Dress the popup's chrome (header, tiles) in Audiowide, as the other mockups are. The module's default is Inter; the editor always writes in Inter.",
            val: true
        }
    ]

    readonly property var editorParams: [
        {
            label: "body size",
            prop: "editorBodySize",
            group: "Text",
            blurb: "The live-markdown editor.",
            tip: "Body text size in the editor. 12, the shell's body size; headings scale from it (h1 1.5x, h2 1.3x).",
            val: 12,
            from: 9,
            to: 18,
            step: 1
        },
        {
            label: "title size",
            prop: "editorTitleSize",
            group: "Text",
            tip: "The inline title (the file name) above the note. 22: 'just bigger' than a heading, as a phone's notes app sets it.",
            val: 22,
            from: 14,
            to: 34,
            step: 1
        }
    ]

    readonly property var resizeParams: [
        {
            label: "browse width",
            prop: "browseWidth",
            group: "Default sizes",
            blurb: "The grid page has ONE size (round 3: it is not resized). A note is resized by dragging a free edge; each note remembers its own size, and 'reset size' goes back to the note default.",
            tip: "The grid page's width: three landscape tiles of about 171 px with the shell's padding and gaps (the user: three tiles wide, the popup wider than tall). Fixed: the grid cannot be dragged to another size.",
            val: 560,
            from: 300,
            to: 1100,
            step: 1
        },
        {
            label: "browse height",
            prop: "browseHeight",
            group: "Default sizes",
            tip: "The grid page's height: the header and two and a half rows of tiles, less than the width -- the fade at the foot says there is more. Fixed, like the width.",
            val: 440,
            from: 280,
            to: 760,
            step: 1
        },
        {
            label: "note width",
            prop: "noteWidth",
            group: "Default sizes",
            tip: "A note's default width, before it has been given its own. 420: a comfortable line of 12 px text.",
            val: 420,
            from: 300,
            to: 1100,
            step: 1
        },
        {
            label: "note height",
            prop: "noteHeight",
            group: "Default sizes",
            tip: "A note's default height.",
            val: 480,
            from: 280,
            to: 760,
            step: 1
        },
        {
            label: "min width",
            prop: "minWidth",
            group: "Limits",
            blurb: "How small a drag may make the popup (the room the bar reports is the most).",
            tip: "The narrowest a note may be dragged. 300: a line of 12 px text that still reads.",
            val: 300,
            from: 200,
            to: 500,
            step: 1
        },
        {
            label: "min height",
            prop: "minHeight",
            group: "Limits",
            tip: "The shortest a note may be dragged: the title and a few lines.",
            val: 280,
            from: 160,
            to: 500,
            step: 1
        }
    ]

    readonly property var motionParams: [
        {
            label: "morph ms",
            prop: "morphMs",
            group: "Open and back",
            blurb: "A tile grows into the popup when it opens and shrinks back into it, like a phone opening an app (the user's round-2 ask). One clock drives the card, the popup's size, the tint and the fades.",
            tip: "The whole morph, OutCubic. 320: a little longer than the shell's 260 ms resize, since the card travels further than an edge -- the page arrives at about two thirds of it.",
            val: 320,
            from: 120,
            to: 900,
            step: 10
        },
        {
            label: "swipe distance",
            prop: "swipeBackUnits",
            group: "Two-finger back",
            blurb: "Two fingers to the right go back, as in a browser: the page slides home under the fingers and completes past a third on the lift (or on a fling), springing back otherwise.",
            tip: "Wheel units (touchpad pixels x 2.5) for the whole way back. 900: about the view switcher's step threshold (gestures.md), so a comfortable swipe covers it and a third is a deliberate move.",
            val: 900,
            from: 300,
            to: 3000,
            step: 10
        },
        {
            label: "swipe sign",
            prop: "swipeBackSign",
            group: "Two-finger back",
            tip: "Which horizontal wheel direction is 'fingers to the right'. 1 was derived from natural scrolling (libinput inverts, Qt negates) but NOT measured on this machine: the desktop checklist asks for one real swipe; -1 flips it.",
            val: 1,
            from: -1,
            to: 1,
            step: 2
        }
    ]

    // ---- The float (modules/common/float): the notes' FloatStyle ---------------------------------------
    readonly property var floatSwayParams: [
        {
            label: "drift min",
            prop: "moveAmpMin",
            group: "Drift",
            blurb: "Every tile sways on three oscillators of its own (x, y, rotation), each rolling a new size and speed now and then. The phases are INTEGRATED: speed is speed at any age.",
            tip: "Least swing in px. The theme popup's tuned value; a card must stay well inside its 12 px of gap.",
            val: 1.2,
            from: 0,
            to: 6,
            step: 0.1
        },
        {
            label: "drift max",
            prop: "moveAmpMax",
            group: "Drift",
            tip: "Most swing in px. 3 leaves 9 px of the 12 px gap, and the lift still fits.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.1
        },
        {
            label: "drift speed min",
            prop: "moveFreqMin",
            group: "Drift",
            tip: "Slowest swing, rad/s: 0.5 is one sway in 12.5 s.",
            val: 0.5,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "drift speed max",
            prop: "moveFreqMax",
            group: "Drift",
            tip: "Fastest swing, rad/s: 0.9 is one sway in 7 s, 2.7 px/s at the most: the 20 Hz rest beat moves a card 0.14 px a tick.",
            val: 0.9,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "turn min",
            prop: "rotAmpMin",
            group: "Turn",
            blurb: "The sway's rotation, in the card's own plane.",
            tip: "Least turn in degrees.",
            val: 0.35,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "turn max",
            prop: "rotAmpMax",
            group: "Turn",
            tip: "Most turn in degrees: 0.8 moves the corners of a 200 px card by 1.4 px.",
            val: 0.8,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "turn speed min",
            prop: "rotFreqMin",
            group: "Turn",
            tip: "Slowest turn, rad/s.",
            val: 0.4,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "turn speed max",
            prop: "rotFreqMax",
            group: "Turn",
            tip: "Fastest turn, rad/s.",
            val: 1,
            from: 0.05,
            to: 3,
            step: 0.05
        },
        {
            label: "new targets after, min",
            prop: "retargetMin",
            group: "Rolls",
            blurb: "How often an oscillator picks a new size and speed.",
            tip: "Seconds: often enough that the sway never reads as a loop.",
            val: 6,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "new targets after, max",
            prop: "retargetMax",
            group: "Rolls",
            tip: "Seconds.",
            val: 7,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "calm",
            prop: "calmMs",
            group: "Calm",
            blurb: "While a drag, a reorder or a scroll runs, every tile eases to rest and the clock stops; it comes back after.",
            tip: "How fast the sway eases to rest when it must hold still, ms. 200 is gone before a dragged card has left its place.",
            val: 200,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "resume",
            prop: "resumeMs",
            group: "Calm",
            tip: "How slowly the sway comes back after it, ms: slower than it went, so the cards wake rather than jump.",
            val: 600,
            from: 0,
            to: 2000,
            step: 10
        }
    ]
    readonly property var floatLeanParams: [
        {
            label: "tilt",
            prop: "tiltMax",
            group: "Tilt",
            blurb: "The tile under the pointer leans towards it, on a spring.",
            tip: "Degrees at the card's edge. 9 reads as a card in the hand; text on it stays readable well past that.",
            val: 9,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "spring",
            prop: "tiltStiffness",
            group: "Tilt",
            tip: "How hard the spring pulls: 140 reaches the pointer in about 200 ms.",
            val: 140,
            from: 20,
            to: 400,
            step: 5
        },
        {
            label: "damping",
            prop: "tiltDamping",
            group: "Tilt",
            tip: "15 at this stiffness is a little under critical: one small overshoot, then still.",
            val: 15,
            from: 4,
            to: 40,
            step: 0.5
        },
        {
            label: "perspective",
            prop: "planeDistance",
            group: "Tilt",
            tip: "The eye's distance in px: smaller is a stronger perspective. 700 is a card held at reading distance.",
            val: 700,
            from: 200,
            to: 2000,
            step: 10
        },
        {
            label: "lift",
            prop: "liftScale",
            group: "Lift",
            blurb: "The pointer on a card: it rises to meet it.",
            tip: "Scale of the card the pointer is on. It must grow past the sway, or the pointer slips off a card's edge: 1.045 is 3-5 px each way.",
            val: 1.045,
            from: 1,
            to: 1.12,
            step: 0.005
        }
    ]
    readonly property var floatDealParams: [
        {
            label: "deal time",
            prop: "dealMs",
            group: "Deal",
            blurb: "The tiles land one after the other as the popup opens, like a hand being dealt; the + slot is dealt first and never sways.",
            tip: "How long one card takes, OutBack. 440 is about the popup's own opening; 0 turns the deal off.",
            val: 440,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "stagger",
            prop: "dealStaggerMs",
            group: "Deal",
            tip: "Between two cards, in reading order.",
            val: 45,
            from: 0,
            to: 150,
            step: 5
        },
        {
            label: "rise",
            prop: "dealRise",
            group: "Deal",
            tip: "How far below its place a card starts, px.",
            val: 16,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "turn",
            prop: "dealTurn",
            group: "Deal",
            tip: "How far turned a card starts, degrees, every other one the other way.",
            val: 3.5,
            from: 0,
            to: 12,
            step: 0.5
        }
    ]

    readonly property var noteColors: [
        {
            label: "red",
            prop: "noteRed",
            group: "Note tints",
            blurb: "A note's colour fills its tile and, while it is open, the whole popup. Each is its hue mixed into the surface (16 % in light, 14 % in dark) so text keeps its contrast.",
            tip: "Catppuccin Latte red over the surface.",
            val: "#E6C9D7"
        },
        {
            label: "orange",
            prop: "noteOrange",
            group: "Note tints",
            tip: "Latte peach over the surface.",
            val: "#EDD7D0"
        },
        {
            label: "yellow",
            prop: "noteYellow",
            group: "Note tints",
            tip: "Latte yellow over the surface.",
            val: "#E8DED2"
        },
        {
            label: "green",
            prop: "noteGreen",
            group: "Note tints",
            tip: "Latte green over the surface.",
            val: "#CFE1D5"
        },
        {
            label: "teal",
            prop: "noteTeal",
            group: "Note tints",
            tip: "Latte teal over the surface.",
            val: "#C8DEE6"
        },
        {
            label: "blue",
            prop: "noteBlue",
            group: "Note tints",
            tip: "Latte blue over the surface.",
            val: "#C9D7F5"
        },
        {
            label: "purple",
            prop: "notePurple",
            group: "Note tints",
            tip: "Latte mauve over the surface.",
            val: "#DAD0F4"
        },
        {
            label: "pink",
            prop: "notePink",
            group: "Note tints",
            tip: "Latte pink over the surface.",
            val: "#EADAEE"
        },
        {
            label: "highlight",
            prop: "mdMark",
            group: "Markdown",
            blurb: "Colours the editor draws a note's markup in.",
            tip: "The ==highlighter== fill. A light yellow that dark text reads on.",
            val: "#F2E2A6"
        }
    ]
}
