pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/scroll"
import "modules/common/theme"
import "modules/bar/gooey"
import "modules/launcher"
import "modules/clipboard"
import "modules/clipboard/data"

// =============================================================================
// mockups/clipboard.qml -- the clipboard shelf mockup, on the REAL bar clipEngine.
//
// A slice of the screen at 1:1: a GooeyEngine with a 40 px top bar and the
// launcher's slim 6 px bottom bar across the whole edge (LauncherBar), and
// thePopup the shelf rises into -- the drop-in as it will run. There is no bar
// button: Alt+V (a Shortcut of this window; the desktop's is a Hyprland
// `global` bind, ClipboardBarOwner's header) or the Run tab opens it.
//
// THE SERVICE IS THE MOCK (ClipboardMock): fixtures of every kind, a scripted
// feed, nothing touches a clipboard, a store or a window. A paste is recorded
// (the Run tab shows it) and the popup closes as it will. Sealed copies live
// for the mock's ttl; a lock drops them, a screencast hides them.
//
// Keys, in the popup (ClipboardPopup's header has the full list): type to
// search, arrows / Home / End / PgUp / PgDn, Tab for the chips, Enter pastes,
// Shift+Enter copies, Alt+1..9 pastes the nth, Ctrl+Space marks, Ctrl+E edits,
// Ctrl+T / Menu / right-click the menu, Ctrl+P pins, Delete removes (Undo in
// the header), hold Ctrl+R to peek at a sealed card, Esc.
//
// Run it: quickshell -p mockups/clipboard.qml (in the sandbox when a shell is
// running here: tools/dev/sandbox.sh quickshell -p mockups/clipboard.qml).
// Env: CLIPBOARD_NO_OPEN=1 (start closed).
// =============================================================================
MockupWindow {
    id: win

    moduleId: "clipboard"
    title: "Clipboard"
    stageLabel: "A section of the screen at 1:1 -- a top bar, the slim bottom bar, thePopup"
    content: scene
    target: sty
    targets: ({
            styleParams: sty,
            popupParams: owner,
            secretParams: mock,
            scrollParams: ScrollFeel
        })
    stageColor: "#1F2229"
    zoom: 1.0
    panelWidth: 460
    // The popup spans the bar: the window opens wide enough to show all of it.
    fitContent: true

    lists: ({
            styleParams: win.styleParams,
            popupParams: win.popupParams,
            secretParams: win.secretParams,
            scrollParams: win.scrollParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Popup",
            lists: ["popupParams"]
        },
        {
            name: "Style",
            subs: [
                {
                    name: "Shelf",
                    lists: ["styleParams"],
                    groups: ["Shelf", "Focus mark"]
                },
                {
                    name: "Cards",
                    lists: ["styleParams"],
                    groups: ["Card", "Faces", "Badges"]
                },
                {
                    name: "Secrets",
                    lists: ["styleParams", "secretParams"],
                    groups: ["Sealed card", "Sealed copies"]
                },
                {
                    name: "Motion",
                    lists: ["styleParams"],
                    groups: ["Motion"]
                }
            ]
        },
        {
            name: "Scrolling",
            lists: ["scrollParams"]
        }
    ]

    property bool dressAudiowide: true

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    ClipStyle {
        id: sty
    }

    ClipboardMock {
        id: mock
    }

    // The Run tab's "Real clipboard": the REAL service on a mockup-private store
    // (never the shell's own), copy-only (no origin: it never sends a paste key).
    property bool useReal: Quickshell.env("CLIPBOARD_REAL") === "1"
    onUseRealChanged: owner.close()
    readonly property ClipboardService realSvc: realService.item as ClipboardService
    LazyLoader {
        id: realService
        active: win.useReal
        component: ClipboardService {
            stateOverride: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/clipboard-mockup"
            origin: null
            // Copy-only means it writes nothing to the desktop's clipboard of its own accord either.
            restoreOnStart: false
        }
    }

    Item {
        id: scene
        implicitWidth: 1180
        implicitHeight: 800

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: clipEngine
            anchors.fill: parent
            renderScale: win.stage.zoom
            surfaceColor: Theme.surface
            barsList: [topBar, clipBar]

            GooeyBar {
                id: topBar
                engine: clipEngine
                barId: "topBar"
                edge: "top"
                rawPos: 0
                rawLen: clipEngine.w
                Text {
                    x: topBar.width - width - 18
                    y: (topBar.height - height) / 2
                    text: "13:37"
                    color: Theme.textMuted
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }

            LauncherBar {
                id: clipBar
                engine: clipEngine
                barId: "clipBar"
                rawPos: 0
                rawLen: clipEngine.w
            }
        }

        ClipboardBarOwner {
            id: owner
            engine: clipEngine
            bar: clipBar
            barId: "clipBar"
            service: win.useReal && win.realSvc ? win.realSvc : mock
            // The linter sees this type twice -- once through the mockup's `modules` link, once at its real path -- and calls the two
            // incompatible; the engine follows the link and sees one (mockups/modules: RepoRoot.qml).
            // qmllint disable incompatible-type
            style: sty
            // qmllint enable incompatible-type
            fontFamily: win.dressAudiowide ? "Audiowide" : "Inter"
            // A mockup never registers the desktop's shortcut, and has no
            // compositor to ask which window the paste is for.
            shortcutEnabled: false
            liveWindow: false
        }
    }

    // Alt+V, as the desktop's bind: the same toggle.
    Shortcut {
        sequence: "Alt+V"
        context: Qt.WindowShortcut
        onActivated: owner.toggle()
    }

    Timer {
        interval: 80
        running: Quickshell.env("CLIPBOARD_NO_OPEN") !== "1"
        onTriggered: owner.open()
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    readonly property string pasteText: {
        const p = mock.lastPaste;
        if (!p)
            return "nothing pasted yet";
        return p.mode + " " + p.keys.length + " key(s)  via " + p.via + (p.text !== "" ? "  with text (" + p.text.length + " chars)" : "") + (p.keys.length > 1 ? "  joined (" + p.joined.length + " chars)" : "") + "\nshortcut " + p.pasteKey;
    }

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "The popup"
                blurb: "Open and close it as the Alt+V bind does."
            }
            TipRow {
                tip: "Open or close the shelf as Alt+V does: the keyboard is the shelf's at once. Escape clears the search, then the marks, then closes -- copying the card you picked on the way out; a paste closes it too. In the editor, Escape saves the edit as a card and Ctrl+Escape throws it away."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: owner.popupMine ? "Close" : "Open (Alt+V)"
                    onClicked: owner.toggle()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Dress the popup's header, menu and editor in Audiowide, as the other mockups are. The module's own face is Inter (the cards' faces are the shelf's, Inter always)."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    text: "Audiowide"
                    checked: win.dressAudiowide
                    onToggled: win.dressAudiowide = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Show your REAL clipboard instead of the fixtures: the real service watches it (wl-paste --watch) and keeps its history in ~/.local/state/lares/clipboard-mockup, never the shell's own store. Copy something anywhere and it lands on the shelf; passwords are sealed in memory as they will be. Copy-only here: Enter puts the item on the clipboard but sends no paste key (the mockup has no window to paste into). The buttons below drive the fixtures, not this."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    text: "Real clipboard"
                    checked: win.useReal
                    onToggled: win.useReal = checked
                }
                Label {
                    visible: win.useReal
                    text: win.realSvc ? (win.realSvc.error !== "" ? win.realSvc.error
                                         : (win.realSvc.ready ? win.realSvc.entries.count + " in the mockup store" : "starting")) : ""
                    color: Theme.textMuted
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "A new copy"
                blurb: "What the watcher would report, one kind at a time. The popup, open or not, shows it at once."
            }
            TipRow {
                tip: "A plain text copy, a code snippet, a link with tracking parameters, a colour. Each lands on the left of the shelf: while the popup is open the cards slide one slot."
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: ["text", "code", "link", "colour"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        onClicked: mock.feed(modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "An image (no thumbnail file in the mock: the card shows its dimensions) and a file list."
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: ["image", "files"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        onClicked: mock.feed(modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "A sealed copy. secret: the password manager's own hint or app (no Keep). heuristic: nothing said so, the detector did (the card offers Keep, 'not a secret'). Neither is stored: they live in memory for the ttl on the Secrets tab."
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: ["secret", "heuristic"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        onClicked: mock.feed(modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The clipboard changes state"
                blurb: "What wl-paste --watch reports besides a copy."
            }
            TipRow {
                tip: "nil: the source went away (or cleared); every sealed copy goes, and the top entry is re-offered once (counted below). clear: an explicit clear; the sealed copies go, nothing is re-offered. empty: data of zero bytes, a password manager 'clearing'; same as clear."
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    model: ["nil", "clear", "empty"]
                    delegate: Button {
                        required property string modelData
                        text: modelData
                        onClicked: mock.fire(modelData)
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }
            TipRow {
                tip: "Lock: the session locked, every sealed copy is dropped. Screencast: the screen is shared; sealed cards are left out of the shelf entirely and a peek is cancelled."
                Layout.fillWidth: true
                spacing: 8
                Switch {
                    text: "locked"
                    checked: mock.locked
                    onToggled: mock.setLocked(checked)
                }
                Switch {
                    text: "screencast"
                    checked: mock.screencast
                    onToggled: mock.setScreencast(checked)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "What the mock was told"
                blurb: "A paste touches no clipboard; this is the call the real service would have made."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
                text: win.pasteText + "\nre-offers " + mock.reoffers + "   last state " + (mock.lastState || "-") + "   entries " + mock.entries.count + "   sealed " + mock.secrets.length
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    readonly property var styleParams: [
        {
            label: "cards wide",
            prop: "shelfCards",
            group: "Shelf",
            blurb: "How wide the popup is.",
            tip: "The popup is this many cards wide (plus its 12 px padding), whatever the display: the header's search field takes what the chips and the right-hand text leave. On a bar with less room the popup takes the room the bar leaves. 4 is the default: four cards fit a header with the chips, 'N picked', Undo and the count without dead space.",
            val: 4,
            from: 2,
            to: 8,
            step: 1
        },
        {
            label: "card gap",
            prop: "cardGap",
            group: "Shelf",
            tip: "Space between two cards. Wide enough for a raised card's drop shadow not to touch its neighbour.",
            val: 10,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "focus mark",
            prop: "focusStyle",
            group: "Focus mark",
            blurb: "How the focused card shows.",
            tip: "lift: the focused card stands proud, a raised box. well: the launcher's carved well glides under it. Type one of the two words.",
            val: "lift",
            kind: "text"
        },
        {
            label: "lift px",
            prop: "liftPx",
            group: "Focus mark",
            tip: "How far the lift raises the focused card. Only the lift style reads it.",
            val: 4,
            from: 0,
            to: 10,
            step: 1
        },
        {
            label: "card width",
            prop: "cardWidth",
            group: "Card",
            blurb: "One card.",
            tip: "Width of one card. 184 shows a link's domain and two lines of its path without cutting a word in the middle.",
            val: 184,
            from: 120,
            to: 320,
            step: 2
        },
        {
            label: "card height",
            prop: "cardHeight",
            group: "Card",
            tip: "Height of one card. The popup's height follows it (and the editor takes the same height).",
            val: 148,
            from: 100,
            to: 260,
            step: 2
        },
        {
            label: "card radius",
            prop: "cardRadius",
            group: "Card",
            tip: "Corner radius of a card. 10, the radius of a carved box inside a container (14 normal, 10 compact).",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "card padding",
            prop: "cardPadding",
            group: "Card",
            tip: "Space inside a card between its edge and its first ink. 12 everywhere in the shell.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "text lines",
            prop: "textLines",
            group: "Faces",
            blurb: "How much of a copy a card shows.",
            tip: "Lines a text card shows before it fades out.",
            val: 5,
            from: 1,
            to: 10,
            step: 1
        },
        {
            label: "code lines",
            prop: "codeLines",
            group: "Faces",
            tip: "Lines a code card shows. Consolas Bold is taller than the text face, so a card holds one more.",
            val: 6,
            from: 1,
            to: 12,
            step: 1
        },
        {
            label: "image fit",
            prop: "thumbFit",
            group: "Faces",
            tip: "crop: the thumbnail fills the card and is cut at its edges. fit: all of it shows, with bars. Type one of the two words.",
            val: "crop",
            kind: "text"
        },
        {
            label: "badge size",
            prop: "badgeSize",
            group: "Badges",
            blurb: "The digit and pick-order badges.",
            tip: "Diameter of the badge that shows 1..9 while Alt is held and the pick order of the marked cards.",
            val: 18,
            from: 12,
            to: 30,
            step: 1
        },
        {
            label: "ring size",
            prop: "ringSize",
            group: "Sealed card",
            blurb: "A sealed card.",
            tip: "Diameter of the countdown ring on a sealed card: it drains over the copy's life.",
            val: 22,
            from: 14,
            to: 40,
            step: 1
        },
        {
            label: "focus ms",
            prop: "focusMs",
            group: "Motion",
            blurb: "Every motion has its own clock.",
            tip: "The focus mark's glide (or lift) from one card to the next.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "insert ms",
            prop: "insertMs",
            group: "Motion",
            tip: "A new copy's slide in while the popup is open: the on-screen cards make one slot of room.",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "presence ms",
            prop: "presenceMs",
            group: "Motion",
            tip: "Fades of things that appear or go: badges, the empty note, the editor, the header's marks and Undo. 160, the shell's presence fade.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        }
    ]

    readonly property var secretParams: [
        {
            label: "ttl s",
            prop: "ttlS",
            group: "Sealed copies",
            blurb: "How long a sealed copy lives.",
            tip: "Seconds a sealed copy is kept in memory before it is forgotten (clipboard.jsonc's secrets.ttlS, 120). Read when a copy arrives: a copy already on the shelf keeps the deadline it was given.",
            val: 120,
            from: 5,
            to: 600,
            step: 5
        }
    ]

    // THE WHOLE SHELL'S SCROLL FEEL (modules/common/scroll/ScrollFeel.qml). These rows write the singleton,
    // so a change moves every scroller of this mockup at once -- and, once the values are copied into
    // ScrollFeel.qml, every scroller of the shell. "Save to mockup" keeps them in this file's val: entries,
    // which are only the panel's defaults; the shell reads ScrollFeel.qml.
    readonly property var scrollParams: [
        {
            label: "speed",
            prop: "speed",
            group: "Distance",
            blurb: "How far things move per wheel or finger movement. The shell's, not the shelf's.",
            tip: "Multiplier on every VERTICAL scroller in the shell (lists, the transcript, the terminal): 1 is one notch = notch px, the fingers 1:1. This is the WHOLE SHELL's feel, one number for all of them. 1.0 so that a box that was tuned before this singleton existed feels as it did.",
            val: 1.0,
            from: 0.2,
            to: 4.0,
            step: 0.05
        },
        {
            label: "horizontal speed",
            prop: "hSpeed",
            group: "Distance",
            tip: "The same multiplier for HORIZONTAL scrollers (the clipboard shelf, weather's strips, code blocks, the terminal's sideways scroll). Higher than the vertical one by the user's call: a card is 194 px wide and a notch of 120 px barely moved the shelf. 1.6 makes a notch about one card. The WHOLE SHELL's horizontal feel.",
            val: 1.6,
            from: 0.2,
            to: 6.0,
            step: 0.05
        },
        {
            label: "notch px",
            prop: "notchPx",
            group: "Distance",
            tip: "How far ONE mouse-wheel notch goes at speed 1, in px. 120 is the notch's own angle delta, so a notch is as many px as the wheel says it is. Scaled by speed / horizontal speed. The WHOLE SHELL's notch.",
            val: 120,
            from: 40,
            to: 400,
            step: 10
        },
        {
            label: "notch glide ms",
            prop: "notchMs",
            group: "Mouse wheel",
            blurb: "A notch glides; notches add up and none is swallowed.",
            tip: "How long a mouse notch glides to where it is going, OutCubic. A notch arriving mid-glide adds to the target and the glide restarts from where the content is. 0 lands at once (round 16's behaviour). 140 is quick enough to feel direct and long enough to read as a glide. The WHOLE SHELL's wheel.",
            val: 140,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "coast tau ms",
            prop: "momentumTau",
            group: "Touchpad coast",
            blurb: "What the fingers leave behind when they lift while moving.",
            tip: "The time constant of a fling: its velocity decays as exp(-t / tau), so it coasts v0 x tau and eases to a stop, the way a browser's does. Longer is slipperier. The user disliked the old 'infinite friction' (a stop the moment the fingers lift). 380 is a web-like feel. The WHOLE SHELL's coast.",
            val: 380,
            from: 50,
            to: 1500,
            step: 10
        },
        {
            label: "fling threshold px/ms",
            prop: "flingMin",
            group: "Touchpad coast",
            tip: "A lift slower than this just stops: slowly dragging a card into place must not drift on. 0.3 px/ms is about 300 px/s.",
            val: 0.3,
            from: 0.0,
            to: 2.0,
            step: 0.05
        },
        {
            label: "velocity window ms",
            prop: "velocityWindowMs",
            group: "Touchpad coast",
            tip: "The fingers' velocity is measured over the last this-many ms before the lift. Shorter reads the very end of the stroke (a flick that decelerated barely coasts); longer averages a whole stroke. 90 follows the end of the stroke without reading noise.",
            val: 90,
            from: 20,
            to: 300,
            step: 10
        },
        {
            label: "max fling px/ms",
            prop: "maxFling",
            group: "Touchpad coast",
            tip: "A fling's velocity is clamped to this, so a hard flick cannot cross a hundred cards. 8 px/ms with a 380 ms tau coasts at most about 3000 px.",
            val: 8,
            from: 1,
            to: 20,
            step: 0.5
        }
    ]

    readonly property var popupParams: [
        {
            label: "over fullscreen",
            prop: "openOverFullscreen",
            group: "Popup",
            blurb: "The popup around the shelf.",
            tip: "Open the shelf while the active window is fullscreen (clipboard.jsonc's openOverFullscreen). The launcher's rule is no; a mockup has no compositor to ask, so this changes nothing here.",
            val: false
        }
    ]
}
