pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/bar/player/components"

// =============================================================================
// mockups/audio_player.qml -- the audio player mockup.
//
//   quickshell -p mockups/audio_player.qml
//   tools/dev/mockup_grab.sh mockups/audio_player.qml --list
//   tools/dev/smoke.sh mockups/audio_player.qml
//
// Beyond MockupWindow's own environment (GRAB, PANEL_TAB, PANEL_TEST, ...):
//   VIEW=mini|player  BROWSE=1  PANEL=queue|library|data   the state to open in
//   AUDIO_LIVE=1      bind to the running daemon instead of the mock
//   MODE=light|dark   force the theme for a grab
//   PHASELOG=1        print every phase the record passes through
//   PLAY=1            put the mock on 8 s in, so a measuring run can hold the
//                     popup in its MOVING state with no hand on it
//   POSE_TEST=1       the pose recorder records what moves and nothing else
//                     (tools/dev/perf/pose_recorder_test.sh)
//
// The content is AudioPlayerPopup exactly as it will drop into thePopup. What
// drives it is a choice made on the Run page:
//
//   mock   PlayerMockRun -- a player-shaped object with a clock and a
//          synthetic queue, seeded from the REAL album directories so the
//          covers are the covers. The default, because a smoke run must not
//          put music on.
//   live   MpdService against the running daemon. Behind a button, and it
//          really does play.
//
// ONE TAB PER COMPONENT, and all of that component's values on it. What the
// record is MADE of is on Record and Sleeve, what it DOES is on Motion, and
// what it is played on is Turntable -- the platter's two marks, and the
// spindle it is dropped onto: a circle of turned metal, the shadow it lays on
// the mat and the shade the record lays back on it. The record's own SIZE is
// the exception to one-tab-per-component: it is VinylStage's `recordFrac` and
// is on Record -> Shape all the same, because the question it answers ("how
// big is the record") is a question about the record. The record is the
// module's centrepiece and the one thing the spec asks to be perfect, so it
// gets the most knobs by a distance, split by what a knob does rather than by
// kind. Data is the sidebar's third panel.
//
// Every row carries a tip that says what it does AND why its default is what
// it is, because a six-word label cannot, and an unexplained slider is one
// nobody dares move. Where a number was arrived at by measuring something --
// the moire in the grooves, the label's blacks at 100, the void along a
// flipping record's rim, the rail's one spark a second -- the tip says the
// measurement.
//
// Two of the lists are the THEME, not the module: the popup's palette, and the
// library's genre hues. Those rows edit themes/eva.json, carry no `*`, and
// stay out of the profiles. That is also why the browse panels have no colour
// lists of their own: every colour the queue, the library and the data panel
// wear is a Theme token the popup passes in, and a per-component row would
// either fight that binding or overwrite `Theme.<token>` with a literal and
// unhook the component from the theme for good.
// =============================================================================
MockupWindow {
    id: win

    moduleId: "audio_player"
    // The cleanup check's sheet: the record stops where the frame times of its spin took it, a different angle every run.
    onSheetAboutToGrab: popup.vinyl.spinDeg = 0
    title: "Audio player mockup"
    content: popup
    // The popup is anchored on the bar by its left edge, so opening the sidebar
    // pushes it OUT to the right rather than moving the record leftwards under
    // the pointer. The stage emulates that; there is room around it either way.
    anchorLeft: true
    stageColor: popup.surfaceColor
    zoom: 1.0
    // The browse view is 1040 wide; the default 440 panel leaves the stage too
    // narrow for it and the queue is cut off at the right in every grab.
    panelWidth: 400
    target: popup

    // Each list writes to the component it belongs to, never to the popup as a
    // proxy: a control that has to be forwarded is one that drifts.
    targets: ({
            stageGeom: popup.vinyl,
            discGeom: popup.vinylDisc,
            discMaterial: popup.vinylDisc,
            discLight: popup.vinylDisc,
            discWear: popup.vinylDisc,
            discColors: popup.vinylDisc,
            sleeveParams: popup.vinylSleeve,
            sleeveColors: popup.vinylSleeve,
            motionParams: popup.vinyl,
            turntableParams: popup.turntable,
            railParams: popup.rail,
            railSparks: popup.rail,
            tapParams: popup.levelTap,
            transportParams: popup.transport,
            infoParams: popup.trackInfo,
            chipParams: popup.trackInfo.chip,
            queueParams: popup.queuePanel,
            libraryParams: popup.libraryPanel,
            dataParams: popup.dataPanel,
        })

    lists: ({
            popupParams: win.popupParams,
            popupColors: win.popupColors,
            stageGeom: win.stageGeom,
            discGeom: win.discGeom,
            discMaterial: win.discMaterial,
            discLight: win.discLight,
            discWear: win.discWear,
            discColors: win.discColors,
            sleeveParams: win.sleeveParams,
            sleeveColors: win.sleeveColors,
            motionParams: win.motionParams,
            turntableParams: win.turntableParams,
            railParams: win.railParams,
            railSparks: win.railSparks,
            tapParams: win.tapParams,
            transportParams: win.transportParams,
            infoParams: win.infoParams,
            chipParams: win.chipParams,
            queueParams: win.queueParams,
            libraryParams: win.libraryParams,
            libraryHues: win.libraryHues,
            dataParams: win.dataParams,
        })

    // The popup's palette IS the theme, and so are the library's genre hues:
    // those rows edit themes/eva.json rather than the module, and are kept out
    // of the profiles for that reason. A genre's hue is a shared token -- the
    // same one the repo categories and the LLM module wear -- so a row here
    // moves it everywhere, which is what its tip says.
    themedLists: ["popupColors", "libraryHues"]

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        // Its own tab, and second, because it is a DRIVER rather than a
        // setting -- and because the first version buried it under the
        // stage's numbers, where it could not be found.
        {
            name: "Animation",
            page: motionPage
        },
        {
            name: "Popup",
            subs: [
                {
                    name: "Frame",
                    lists: ["popupParams"]
                },
                {
                    name: "Colours",
                    lists: ["popupColors"]
                }
            ]
        },
        // The record is the centrepiece and carries the most values by a
        // distance, so it is split by what a knob DOES rather than by kind:
        // one sub-tab per question you can ask about the material.
        {
            name: "Record",
            subs: [
                {
                    name: "Shape",
                    lists: ["stageGeom", "discGeom"]
                },
                {
                    name: "Grooves",
                    lists: ["discMaterial"],
                    groups: ["Grooves"]
                },
                {
                    name: "Sheen",
                    lists: ["discMaterial"],
                    groups: ["Sheen", "Tone", "The label"]
                },
                {
                    name: "Edge",
                    lists: ["discMaterial"],
                    groups: ["The edge"]
                },
                {
                    name: "Light",
                    lists: ["discLight"]
                },
                {
                    name: "Wear",
                    lists: ["discWear"]
                },
                {
                    name: "Colours",
                    lists: ["discColors"]
                }
            ]
        },
        {
            name: "Sleeve",
            lists: ["sleeveParams", "sleeveColors"]
        },
        // VinylStage: everything the record DOES. One sub-tab per set piece,
        // plus the platter it is all played on.
        {
            name: "Motion",
            subs: [
                {
                    name: "Platter",
                    lists: ["motionParams"],
                    groups: ["Speed", "The platter"]
                },
                {
                    name: "Arrival",
                    lists: ["motionParams"],
                    groups: ["The arrival"]
                },
                {
                    name: "Flip",
                    lists: ["motionParams"],
                    groups: ["The flip"]
                },
                {
                    name: "Sleeve",
                    lists: ["motionParams"],
                    groups: ["The sleeve"]
                }
            ]
        },
        // The platter is two marks; the spindle is a material, a shadow it
        // lays on the mat and a shade the record lays on it. Sub-tabs by what
        // a knob answers, like the record's own.
        {
            name: "Turntable",
            subs: [
                {
                    name: "Platter",
                    lists: ["turntableParams"],
                    groups: ["The platter"]
                },
                {
                    name: "Spindle",
                    lists: ["turntableParams"],
                    groups: ["The spindle", "Its light"]
                },
                {
                    name: "Shadows",
                    lists: ["turntableParams"],
                    groups: ["Its shadow on the mat", "The record's shade"]
                }
            ]
        },
        {
            name: "Rail",
            subs: [
                {
                    name: "Groove",
                    lists: ["railParams"],
                    groups: ["Groove"]
                },
                {
                    name: "Ball",
                    lists: ["railParams"],
                    groups: ["Ball"]
                },
                {
                    name: "Seeking",
                    lists: ["railParams"],
                    groups: ["Seeking"]
                },
                {
                    name: "Sparks",
                    lists: ["railSparks"],
                    groups: ["Rate", "Shape"]
                },
                {
                    name: "Bloom",
                    lists: ["railSparks"],
                    groups: ["Glow", "Bloom"]
                },
                {
                    name: "Music",
                    lists: ["railParams"],
                    groups: ["The music"]
                },
                {
                    name: "Level tap",
                    lists: ["tapParams"],
                    groups: ["Level tap"]
                }
            ]
        },
        {
            name: "Transport",
            lists: ["transportParams"]
        },
        {
            name: "Track",
            lists: ["infoParams"]
        },
        {
            name: "Fidelity",
            lists: ["chipParams"]
        },
        {
            name: "Queue",
            subs: [
                {
                    name: "Rows",
                    lists: ["queueParams"],
                    groups: ["Rows", "Header", "Type"]
                },
                {
                    name: "Motion",
                    lists: ["queueParams"],
                    groups: ["Motion"]
                },
                {
                    name: "Flight",
                    lists: ["queueParams"],
                    groups: ["Flight"]
                }
            ]
        },
        {
            name: "Library",
            subs: [
                {
                    name: "List",
                    lists: ["libraryParams"],
                    groups: ["List", "Header", "Type"]
                },
                {
                    name: "Motion",
                    lists: ["libraryParams"],
                    groups: ["Motion"]
                },
                {
                    name: "Genres",
                    lists: ["libraryHues"]
                }
            ]
        },
        // The sidebar's third panel. Its COLOURS are not here: all eleven are
        // Theme tokens, nine of them passed in by the popup (a row would fight
        // that binding) and the other two -- the header box's bevel and shadow
        // -- bound to `Theme.headerBoxBevel` / `Theme.headerBoxShadow`, which a
        // colour row would overwrite with a literal and so unhook from the
        // theme for good. Both are already on the Popup tab, as the theme rows
        // they are.
        {
            name: "Data",
            lists: ["dataParams"],
            page: dataPage
        },
        // NO "Tabs" TAB. It carried TabSelector's two natural-size knobs --
        // `slotPaddingAlong` and `slotPaddingAcross` -- which decide the size
        // the selector would ASK for. This popup STATES the selector's width
        // and height (`panelTabWidth`/`panelTabHeight`, Popup -> Size), so
        // neither knob could ever move a pixel here. They bound to real
        // properties, which is why the wiring check never flagged them; they
        // were simply shadowed. Round 10 took the tab out.
    ]

    // =====================================================================
    //  WHAT DRIVES IT
    // =====================================================================
    // AUDIO_LIVE=1 binds to the real daemon from the start. Anything else, including a smoke run, stays on the mock.
    property bool live: Quickshell.env("AUDIO_LIVE") === "1"

    PlayerMockRun {
        id: mockPlayer
    }

    // MpdService connects the moment it is constructed, which is right for the
    // shell and wrong for a mockup: a smoke run, a grab and the panel self-test
    // must not open a socket to the daemon, let alone start playback. So it is
    // not constructed until the Run page asks for it.
    Loader {
        id: liveLoader
        active: win.live
        sourceComponent: MpdService {}
    }

    readonly property var activePlayer: (win.live && liveLoader.item) ? liveLoader.item : mockPlayer

    // MODE=light|dark forces the theme for a grab. The panel's own toggle is
    // the way to switch it by hand; this is only so a render can be asked for
    // one mode without carrying the last session's choice into it.
    Component.onCompleted: {
        const m = Quickshell.env("MODE");
        if (m === "light" || m === "dark")
            Theme.setMode(m);
    }

    // =====================================================================
    //  THE DROP-IN
    // =====================================================================
    AudioPlayerPopup {
        id: popup
        player: win.activePlayer
        fontFamily: "Audiowide"
        // VIEW=mini|player picks the view a grab lands on; BROWSE=1 opens the
        // sidebar with it. The buttons at the foot of the popup are the way to
        // change either by hand.
        viewMode: Quickshell.env("VIEW") || "player"
        browseOpen: Quickshell.env("BROWSE") === "1"
        // PANEL=queue|library|data picks which of the three the sidebar opens on.
        browsePanel: Quickshell.env("PANEL") || "queue"
    }

    // PLAY=1 puts the mock on after the library has been scanned, so a
    // measuring run can hold the popup in its MOVING state without a hand on
    // it (tools/dev/perf/mockup_states.sh PLAY=1). Only the mock: the live daemon
    // is never started by an environment variable.
    Timer {
        running: Quickshell.env("PLAY") === "1" && !win.live
        interval: 8000
        onTriggered: mockPlayer.play()
    }

    // PHASELOG=1 prints every phase the record passes through, with the album
    // it is wearing. It is how a double arrival is caught against the LIVE
    // daemon, where the mock's own probe cannot go: three rounds running, the
    // user saw one and every test here was green.
    readonly property bool phaseLog: Quickshell.env("PHASELOG") === "1"
    Connections {
        target: win.phaseLog ? popup.vinyl : null
        function onPhaseChanged() {
            console.log("PHASE " + popup.vinyl.phase + "  album=[" + popup._onPlatter + "]  art=[" + popup.vinyl.albumArt + "]");
        }
    }

    // The animation transport's memory. A QML animation cannot be seeked or
    // reversed -- `paused` is the whole of its API -- so what the Motion tab
    // scrubs is a recording of the pose the animation produced, not a second
    // implementation of it.
    PoseRecorder {
        id: rec
        target: popup.vinyl
        props: ["spinDeg", "tiltX", "tiltY", "flipDeg", "flipAxisDeg", "discHeight", "discX", "discY", "discOpacity", "sleeveX", "sleeveY", "sleeveRot", "sleeveOpacity"]
        // Playback writes those properties, so whatever else writes them has
        // to let go first. Both writing the pose is the one way this can lie
        // about what it recorded.
        onBeforeScrub: popup.vinyl.freeze()
    }

    // POSE_TEST=1: the recorder records what MOVES and nothing else
    // (tools/dev/perf/pose_recorder_test.sh).
    //
    // The recorder's clock used to run from load to exit, and a running frame
    // clock keeps Qt Quick rendering whether or not a pixel changed: it was
    // 49 of the 72 frames a second this mockup drew while sitting there doing
    // nothing, and 7% of a cpu thread. It follows the pose now, so the thing
    // to prove is BOTH halves -- that it is quiet at rest, and that it still
    // catches a sequence when one starts. Nothing moves, then the mock plays,
    // then it stops; the frame count must hold, grow, and hold again.
    readonly property bool poseTest: Quickshell.env("POSE_TEST") === "1"
    property var _poseFails: []
    property int _poseMark: 0
    function _poseExpect(cond, what) {
        if (!cond)
            win._poseFails.push(what);
    }
    SequentialAnimation {
        running: win.poseTest
        // The launch is not idle: the album scan lands, the art resolves and
        // the record arrives for the first ten seconds or so, and all of that
        // is motion the recorder is right to record.
        PauseAnimation {
            duration: 14000
        }
        ScriptAction {
            script: {
                win._poseMark = rec.frameCount;
                console.log("POSE_TEST settled frames=" + rec.frameCount + " recording=" + rec.recording + " moving=" + rec._moving);
            }
        }
        PauseAnimation {
            duration: 2000
        }
        ScriptAction {
            script: {
                console.log("POSE_TEST idle frames=" + rec.frameCount);
                win._poseExpect(rec.frameCount === win._poseMark, "recorded " + (rec.frameCount - win._poseMark) + " frames while nothing moved");
                win._poseMark = rec.frameCount;
                mockPlayer.play();
            }
        }
        PauseAnimation {
            duration: 1500
        }
        ScriptAction {
            script: {
                console.log("POSE_TEST playing frames=" + rec.frameCount);
                win._poseExpect(rec.frameCount > win._poseMark + 20, "missed the motion: " + win._poseMark + " -> " + rec.frameCount);
                mockPlayer.pause();
            }
        }
        // The record is let go of rather than stopped, so the run-down is part
        // of the sequence and is recorded with it. Then the tail.
        PauseAnimation {
            duration: 5000
        }
        ScriptAction {
            script: win._poseMark = rec.frameCount
        }
        PauseAnimation {
            duration: 2000
        }
        ScriptAction {
            script: {
                console.log("POSE_TEST afterStop frames=" + rec.frameCount);
                win._poseExpect(rec.frameCount === win._poseMark, "kept recording " + (rec.frameCount - win._poseMark) + " frames after the motion ended");
                console.log("POSE_TEST RESULT " + (win._poseFails.length === 0 ? "PASS" : "FAIL: " + win._poseFails.join("; ")));
                Qt.quit();
            }
        }
    }

    // =====================================================================
    //  PAGES
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Source"
                blurb: "What the popup is bound to. The mock is the default so a smoke run, a grab and the panel self-test never touch the daemon."
            }

            TipRow {
                tip: "The mock is a player-shaped object with its own clock and a queue built from the real album directories -- the covers are the covers, the durations are invented. Live binds to MpdService and the running mpd: it really plays."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: win.live ? "using: LIVE mpd" : "using: mock"
                    onClicked: win.live = !win.live
                }
                Label {
                    text: win.activePlayer && win.activePlayer.connected ? "connected" : "offline"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Transport"
                blurb: "The same calls the popup's own buttons make."
            }

            TipRow {
                tip: "Play goes through the popup, not the player, so the hold-until-the-record-is-down rule is exercised: a play on a stopped player waits for the drop."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "play / pause"
                    onClicked: popup.requestPlayPause()
                }
                Button {
                    text: "prev"
                    onClicked: win.activePlayer.prev()
                }
                Button {
                    text: "next"
                    onClicked: win.activePlayer.next()
                }
                Button {
                    text: "seek 50%"
                    onClicked: win.activePlayer.seekFrac(0.5)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The queue"
                blurb: "What the record's arrival and departure are driven by: the ALBUM changing, never the track."
            }

            TipRow {
                tip: "Loads one album into the queue and seats its first song. The record sweeps in inside its sleeve, is revealed, swivels, spins up and is dropped."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "album 1"
                    enabled: !win.live
                    onClicked: mockPlayer.loadAlbumIntoQueue(0)
                }
                Button {
                    text: "album 2"
                    enabled: !win.live
                    onClicked: mockPlayer.loadAlbumIntoQueue(1)
                }
                Button {
                    text: "+ next album"
                    enabled: !win.live
                    onClicked: mockPlayer.appendAlbumIdx(2)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Jumps the mock straight to the last song of the current album, so the album boundary -- the one moment the record is taken off and another put on, with the two sleeves crossing -- can be watched without waiting out an album."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "jump to last song"
                    enabled: !win.live
                    onClicked: mockPlayer.playId(mockPlayer.queue.length > 0 ? mockPlayer.queue[mockPlayer.queue.length - 1].id : -1)
                }
                Button {
                    text: "run at 20x"
                    enabled: !win.live
                    onClicked: mockPlayer.speed = mockPlayer.speed > 1 ? 1 : 20
                }
                Button {
                    // The empty state: nothing playing, so the card shows the
                    // static skeleton and the turntable stands on its own.
                    text: "clear queue"
                    onClicked: win.activePlayer.clearQueue()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "The library"
                blurb: "The daemon's own view of ~/Music. A rescan re-reads every file rather than only the ones whose timestamps moved, which is what you want after editing tags."
            }

            TipRow {
                tip: "Asks MPD to rescan the library from disk and reloads it here when it comes back. On the mock it re-reads the album directories instead. It is here rather than in the module because a rescan is a thing you do while working on the library, not while listening to it."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "rescan library"
                    onClicked: win.activePlayer.rescanLibrary()
                }
                Label {
                    Layout.fillWidth: true
                    text: {
                        const p = win.activePlayer;
                        if (!p)
                            return "";
                        return (p.libraryLoading ? "scanning… " : "") + (p.albums ? p.albums.length + " albums" : "") + (p.playlists ? ", " + p.playlists.length + " lists" : "") + (p.recent ? ", " + p.recent.length + " recent" : "");
                    }
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }

            TipGroup {
                title: "Sound health"
                blurb: "The strip over the head of the card that says what is wrong with the sound. On the mock player each button stages one cause with MpdHealth.js's own words; the real service raises them from the daemon, the audio server and the kernel. A cause the button can cure shows one button; a device locked in the kernel shows none and says to unplug it."
            }

            TipRow {
                tip: "Stages a cause on the mock player: stall (the daemon's position is not moving), device-error (the sink is in error, the session manager can be restarted), device-hung (the session manager sits in D state: no button, re-plug the DAC), mpd-down, mpd-stuck, no-sink, output-error (mpd's own words). Real service: the buttons do nothing."
                Layout.fillWidth: true
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: ["stall", "device-error", "device-hung", "mpd-down", "mpd-stuck", "no-sink", "output-error", "clear"]
                        delegate: Button {
                            required property string modelData
                            text: modelData
                            enabled: !!win.activePlayer && win.activePlayer.mockProblem !== undefined
                            onClicked: win.activePlayer.mockProblem(modelData === "clear" ? "ok" : modelData)
                        }
                    }
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the content believes right now."
            }

            Label {
                id: stateReadout

                // The record's angle and the play position are each integrated
                // once per FRAME, so a text built straight off them re-shaped
                // this four-line QTextLayout 60 times a second on the GUI
                // thread. Ablating this one label was worth 0.18 ms/frame --
                // more than the mockup's whole flight recorder (0.12) and about
                // what the record's bloom costs (0.16) -- and every measurement
                // of this module paid it, because the Run tab is the tab the
                // panel opens on. So the two moving numbers are quantised to
                // the precision they are PRINTED at and the text is built from
                // the quantised holders: the string is rebuilt when the readout
                // changes, not when the value behind it does. Everything else
                // on these four lines (the view, the sizes, the phase, the lift,
                // the track, the album progress) moves on an event rather than
                // on a clock, and is read live.

                // The angle, to an eighth of a turn. Whole degrees changed 200
                // times a second at the platter's 200 deg/s -- oftener than the
                // screen refreshes, and far too fast for anyone to read, so
                // rounding to the degree alone would have bought nothing. An
                // eighth steps 4.4 times a second at full speed: still visibly
                // turning, still shows the run-up and the drag to a stop at
                // their own pace, and it parks on one of eight values you can
                // compare between runs. The double modulo is because a flipped
                // record turns the other way (VinylStage's `_faceSign`), so the
                // raw angle can be negative.
                readonly property int spinStep: 45
                readonly property int spinShown: ((Math.round(popup.vinyl.spinDeg / stateReadout.spinStep) * stateReadout.spinStep % 360) + 360) % 360

                // The position, in the tenths of a second it prints: 10 Hz, and
                // the fastest thing left in the readout. (The panel's x20 knob
                // puts it back to once a frame, but that button is for skipping
                // through a run, not for measuring one.)
                readonly property int elapsedTenths: win.activePlayer ? Math.round(win.activePlayer.elapsed * 10) : 0

                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    const p = win.activePlayer;
                    const c = p && p.current ? p.current : null;
                    return "view: " + popup.viewMode + (popup.browseOpen ? " + " + popup.browsePanel : "") + "   size: " + popup.implicitWidth.toFixed(0) + " x " + popup.implicitHeight.toFixed(0) + "\n" + "record: " + popup.vinyl.phase + "   spin " + stateReadout.spinShown + "°" + "   lift " + popup.vinyl.discHeight.toFixed(0) + "\n" + (c ? c.artist + " — " + c.title + "  [" + c.album + "]  " + (stateReadout.elapsedTenths / 10).toFixed(1) + " / " + p.duration.toFixed(1) + "s" : "nothing playing") + "\n" + "album progress: " + (p ? (p.albumProgress * 100).toFixed(0) : "0") + "%";
                }
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }
        },
        MockupPage {
            id: dataPage

            TipGroup {
                title: "The lyrics"
                blurb: "PlayerData reads the file itself with ffprobe -- MPD's own readcomments returns no lyrics of any kind, which was measured on a file that has them. Nothing is read while the tab is closed, so open the sidebar on data to see any of this."
            }

            TipRow {
                tip: "Whether the reading head drags the lyrics along with the music. Off leaves the block where it is and the head still moves down it, which is what you want while reading ahead; on is the default because following is the whole reason a timed lyric is worth having. It is a switch rather than a slider, so it lives here and not in the values above."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: popup.dataPanel.followPlayback ? "following playback" : "not following"
                    onClicked: popup.dataPanel.followPlayback = !popup.dataPanel.followPlayback
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Opens the sidebar on the data panel, which is also what arms the reader: the popup binds the panel's `active` to the tab being the one showing, so no ffprobe runs for a tab nobody is looking at."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "show the data panel"
                    onClicked: {
                        popup.browseOpen = true;
                        popup.browsePanel = "data";
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    const d = popup.dataPanel;
                    const r = d.reader;
                    const l = d.lyrics;
                    return "reader: " + (r.loading ? "reading…" : r.error ? "error: " + r.error : r.ready ? "ready" : "idle") + "   subject: " + (d.subject ? d.subject.title : "nothing") + (d.upNext ? "  (up next)" : "") + "\n" + "lyrics: " + (l.lines.length === 0 ? "none in the file" : (l.synced ? "timed, " : "untimed, ") + l.lines.length + " lines from " + l.source) + "\n" + "tags: " + Object.keys(d.tags).length + " read";
                }
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }

            TipGroup {
                title: "Not knobs"
                blurb: "`lyric size` is deliberately absent: PlayerData derives it from `compact` (13 in browse, 14 out of it), and a panel write would break that derivation for good -- the same reason the queue's and the library's figure sizes are not rows either. So is `active`, which the popup binds to the tab being open."
            }
        },
        MockupPage {
            id: motionPage

            TipGroup {
                title: "Play a sequence"
                blurb: "The record's three set pieces, on demand -- the same calls the popup makes when an album starts, reaches its half and ends. Each one arms the recorder below, so whatever you press can then be walked through frame by frame."
            }

            TipRow {
                tip: "arrive: the sleeve slides in from the left and comes to rest under friction -- no overshoot, because a sleeve on a table does not spring back -- pauses, then slides off to the right revealing the record; the record swivels to move its sheen about, the platter takes it, and it is lowered.  flip: the half-album turn, 1620 degrees about a wandering axis, with the slow motion at the top.  put away: run down, lift, and be fired back into the sleeve.  snap to playing: no animation at all, the record simply down and turning."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "arrive"
                    onClicked: {
                        rec.arm();
                        popup.vinyl.startSequence(popup.vinyl.albumArt);
                    }
                }
                Button {
                    text: "flip"
                    onClicked: {
                        rec.arm();
                        popup.vinyl.flipSequence();
                    }
                }
                Button {
                    text: "put away"
                    onClicked: {
                        rec.arm();
                        popup.vinyl.endSequence(popup.vinyl.albumArt);
                    }
                }
                Button {
                    text: "snap to playing"
                    onClicked: {
                        rec.arm();
                        popup.vinyl.snapToPlaying();
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "While it runs"
                blurb: "A QML animation can be paused and it can be slowed down, and that is all it can do -- there is no seek and no reverse in the engine. Those two live here; everything else is the recorder below."
            }

            TipRow {
                tip: "Holds whichever sequence is running exactly where it is: the pose stays put, the clock stops, and letting go carries on from the same frame rather than restarting."
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: popup.vinyl.sequencesPaused ? "resume" : "pause"
                    enabled: popup.vinyl.sequenceRunning || popup.vinyl.sequencesPaused
                    onClicked: popup.vinyl.sequencesPaused = !popup.vinyl.sequencesPaused
                }
                Label {
                    Layout.fillWidth: true
                    text: popup.vinyl.sequenceRunning ? (popup.vinyl.sequencesPaused ? "held at: " + popup.vinyl.phase : "running: " + popup.vinyl.phase) : "idle at: " + popup.vinyl.phase
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }

            TipRow {
                tip: "Multiplies every duration in every sequence at once, so the SHAPE of the choreography cannot change when its speed does. A duration is read when its segment starts, so a change lands on the next segment rather than on the one you are watching. The fine slider is `time scale` in the values above."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "speed"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Button {
                    text: "0.25"
                    // The five presets have to fit one row of a 400 px panel; a
                    // Controls Button is 100 px wide left to itself.
                    Layout.preferredWidth: 46
                    onClicked: popup.vinyl.timeScale = 0.25
                }
                Button {
                    text: "0.5"
                    // The five presets have to fit one row of a 400 px panel; a
                    // Controls Button is 100 px wide left to itself.
                    Layout.preferredWidth: 46
                    onClicked: popup.vinyl.timeScale = 0.5
                }
                Button {
                    text: "1"
                    // The five presets have to fit one row of a 400 px panel; a
                    // Controls Button is 100 px wide left to itself.
                    Layout.preferredWidth: 46
                    onClicked: popup.vinyl.timeScale = 1
                }
                Button {
                    text: "2"
                    // The five presets have to fit one row of a 400 px panel; a
                    // Controls Button is 100 px wide left to itself.
                    Layout.preferredWidth: 46
                    onClicked: popup.vinyl.timeScale = 2
                }
                Button {
                    text: "4"
                    // The five presets have to fit one row of a 400 px panel; a
                    // Controls Button is 100 px wide left to itself.
                    Layout.preferredWidth: 46
                    onClicked: popup.vinyl.timeScale = 4
                }
                Label {
                    Layout.fillWidth: true
                    text: popup.vinyl.timeScale.toFixed(2) + "x"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
            }

            TipGroup {
                title: "Walk through what it did"
                blurb: "The recorder keeps the last twenty seconds of the record's pose, one sample a frame. Playing it back writes those exact frames into the record -- so what you scrub through is what you saw, not a re-derivation of it. Recording stops the moment playback takes over, and the record is frozen while you are in there."
            }

            TipRow {
                tip: "start jumps to the first recorded frame; rewind plays the recording backwards; play runs it forwards from where the head is; end jumps to the last frame. Either direction stops when it reaches the end rather than looping, so a sweep can be watched into its own overshoot and left there."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: "|<"
                    enabled: rec.frameCount > 1
                    onClicked: rec.seek(0)
                }
                Button {
                    text: "<<"
                    enabled: rec.frameCount > 1
                    onClicked: rec.play(-1)
                }
                Button {
                    text: rec.playing ? "||" : ">"
                    enabled: rec.frameCount > 1
                    onClicked: rec.playing ? rec.pause() : rec.play(1)
                }
                Button {
                    text: ">|"
                    enabled: rec.frameCount > 1
                    onClicked: rec.seek(rec.spanMs)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "One recorded frame at a time -- about 16 ms of the choreography. This is the control the whole tool exists for: stopping on the frame where a sweep overshoots and walking back through it."
                Layout.fillWidth: true
                spacing: 6
                Button {
                    text: "-1 frame"
                    enabled: rec.frameCount > 1
                    onClicked: rec.step(-1)
                }
                Button {
                    text: "+1 frame"
                    enabled: rec.frameCount > 1
                    onClicked: rec.step(1)
                }
                Button {
                    text: "hand it back"
                    enabled: rec.scrubbing
                    onClicked: {
                        rec.release();
                        popup.vinyl.snapToPlaying();
                    }
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "The whole recording as one line. Dragging it writes the pose for that moment straight into the record, interpolated between the two frames either side, so a slow drag is smooth rather than a slideshow."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "scrub"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: Math.max(1, rec.spanMs)
                    value: rec.position
                    onMoved: rec.seek(value)
                }
            }

            TipRow {
                tip: "How fast playback runs, independently of the animation's own speed: the recording is already made, so this only changes how quickly you are walked through it."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "playback  " + rec.speed.toFixed(2) + "x"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0.05
                    to: 2
                    value: rec.speed
                    onMoved: rec.speed = value
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: {
                    const n = rec.frameCount;
                    if (n < 2)
                        return "nothing recorded yet -- press a sequence above";
                    return "frame " + (rec.frameIndex + 1) + " / " + n + "   " + rec.position.toFixed(0) + " / " + rec.spanMs.toFixed(0) + " ms" + (rec.scrubbing ? "   (scrubbing: the record is frozen)" : "   (recording)") + "\n" + "spin " + rec.valueAt("spinDeg").toFixed(0) + "°   lift " + rec.valueAt("discHeight").toFixed(1) + "   tilt " + rec.valueAt("tiltX").toFixed(1) + " / " + rec.valueAt("tiltY").toFixed(1) + "   flip " + rec.valueAt("flipDeg").toFixed(0) + "°" + "\n" + "record x " + rec.valueAt("discX").toFixed(1) + " a " + rec.valueAt("discOpacity").toFixed(2) + "   sleeve x " + rec.valueAt("sleeveX").toFixed(1) + " rot " + rec.valueAt("sleeveRot").toFixed(1) + " a " + rec.valueAt("sleeveOpacity").toFixed(2);
                }
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }

            TipGroup {
                title: "Pose by hand"
                blurb: "The record's own axes, for looking at the material rather than the choreography. Anything a sequence runs will overwrite these."
            }

            TipRow {
                tip: "Tilts the record about the view's x and y axes -- the swivel, held still. This is how the anisotropic sheen is judged: it should sweep, not slide."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "tilt"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Slider {
                    Layout.fillWidth: true
                    from: -80
                    to: 80
                    value: popup.vinyl.tiltY
                    onMoved: popup.vinyl.tiltY = value
                }
                Slider {
                    Layout.fillWidth: true
                    from: -80
                    to: 80
                    value: popup.vinyl.tiltX
                    onMoved: popup.vinyl.tiltX = value
                }
            }

            TipRow {
                tip: "Holds the record at a height above the platter, in pixels. The shadow's size, softness and offset all follow it -- that is the whole reading of 'floating' versus 'down'."
                Layout.fillWidth: true
                spacing: 8
                Label {
                    text: "lift"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 12
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: 1600
                    value: popup.vinyl.discHeight
                    onMoved: popup.vinyl.discHeight = value
                }
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    // ---- the popup itself ------------------------------------------------

    readonly property var popupParams: [
        {
            label: "padding",
            prop: "padding",
            group: "Layout",
            blurb: "The popup's own spacing. 12 everywhere in the shell, so the space above equals the space below.",
            tip: "Space between the popup's edge and its content, and between the pill row and the card. 12 is the shell's number; changing it here changes both at once, which is the point.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "card padding",
            prop: "cardPadding",
            group: "Layout",
            tip: "Space between the card's carved edge and the record, the text and the viewfinder inside it. Also 12: a card that breathes differently from the popup reads as a second material.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "text to rail gap",
            prop: "railGap",
            group: "Layout",
            tip: "Between the track's figures and the viewfinder under them. The shell's number for a text-to-rail gap is 6, and that was what this was; the user's word for it was 'a bit too close', so it is 12 and the record gives up the space rather than the popup.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "body gap",
            prop: "bodyGap",
            group: "Layout",
            tip: "Between the player column and the sidebar beside it in browse -- the queue, the library or the data panel. 10, matching the system update's terminal-to-list gap.",
            val: 10,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "card radius",
            prop: "cardRadius",
            group: "Layout",
            tip: "The card's corner. 14 is the shell's container radius; anything meeting that corner takes the same number so the two curves coincide.",
            val: 14,
            from: 0,
            to: 28,
            step: 1
        },
        {
            label: "radius (browse)",
            prop: "cardRadiusCompact",
            group: "Layout",
            tip: "The same corner in the denser browse view. 10, the shell's compact radius.",
            val: 10,
            from: 0,
            to: 28,
            step: 1
        },
        {
            label: "mini width",
            prop: "miniWidth",
            group: "Size",
            blurb: "What each view is. mini takes its HEIGHT from its own content, the way the shell's compact views do; the other two are minimums.",
            tip: "The popup's width in mini. Wide enough for the thumbnail record, a title and its artist, and the viewfinder beside them.",
            val: 480,
            from: 320,
            to: 720,
            step: 10
        },
        {
            label: "player width",
            prop: "playerWidth",
            group: "Size",
            tip: "The popup's width in player, and the width of the player column in browse. The record is sized from it, so this is the record's size in disguise.",
            val: 560,
            from: 380,
            to: 900,
            step: 10
        },
        {
            label: "player height",
            prop: "playerMinHeight",
            group: "Size",
            tip: "The popup's height in player, top to bottom. It lost the 44 px the pill row and its padding took when the row went; the record kept that space rather than the popup.",
            val: 720,
            from: 480,
            to: 1100,
            step: 10
        },
        {
            label: "sidebar width",
            prop: "browsePanelWidth",
            group: "Size",
            tip: "The sidebar beside the player: the queue, the library or the data panel. 470 fits a title, an artist and a duration without the title having to elide on most tracks, and gives a lyric line its own width.",
            val: 400,
            from: 280,
            to: 700,
            step: 10
        },
        {
            label: "selector width",
            prop: "panelTabWidth",
            group: "Size",
            tip: "The queue/library/data selector at the foot of the sidebar, level with the transport beside it. 260 splits into three pills of about 87, which is a word each with room around it rather than three words crammed against their pills.",
            val: 260,
            from: 100,
            to: 400,
            step: 5
        },
        {
            label: "selector height",
            prop: "panelTabHeight",
            group: "Size",
            tip: "Its height. It sits beside the transport's buttons, so it takes their size -- 38 -- and the two read as one row rather than a tall thing next to a short one.",
            val: 38,
            from: 18,
            to: 48,
            step: 1
        },
        {
            label: "mini record size",
            prop: "miniVinylSize",
            group: "Size",
            tip: "The record's size in mini. Small enough to be a thumbnail, large enough that the label's art and the groove lands still read.",
            val: 118,
            from: 60,
            to: 240,
            step: 2
        },
        {
            label: "transport height",
            prop: "transportHeight",
            group: "Size",
            tip: "The row of buttons under the card. 44 gives a 38 px button its shadow without crowding the card.",
            val: 44,
            from: 28,
            to: 72,
            step: 1
        }
    ]

    readonly property var popupColors: [
        {
            label: "surface",
            prop: "surface",
            group: "Ground",
            blurb: "The theme's own tokens: these rows edit themes/eva.json, not the module.",
            tip: "The ground the popup is drawn on, and the sky the record reflects -- which is why a record in dark mode reflects a dark room without anything switching on the mode.",
            val: "#EAEDF5"
        },
        {
            label: "sunk panel",
            prop: "panelSunk",
            group: "Ground",
            tip: "The fill of a carved container: the pill track, the viewfinder's groove. A shade under the surface, and DEEPER than a list box, because a groove is cut further in than a box is.",
            val: "#E1E4EB"
        },
        {
            label: "list box",
            prop: "listBox",
            group: "Ground",
            tip: "The card's fill, the queue's box and the ground the platter is carved into. A shade under the surface, so the box reads as cut into it.",
            val: "#E5E8EF"
        },
        {
            label: "header box",
            prop: "headerBox",
            group: "Ground",
            tip: "A group header inside a list -- a shade darker again than the box it sits in. The turntable's platter is this same fill: a platter is a well sunk into the card, which is what that token already means.",
            val: "#DCDFE6"
        },
        {
            label: "bevel",
            prop: "bevel",
            group: "Edges",
            blurb: "The two edges every carved thing has: a light rim outside, an inset shadow inside.",
            tip: "The light rim just outside a carved edge. One step LIGHTER than the surface, which is what makes an edge read as cut into the ground rather than drawn on it -- the shadow inside it does the other half.",
            val: "#EDF0F7"
        },
        {
            label: "border",
            prop: "border",
            group: "Edges",
            tip: "The inset shadow just inside a carved edge, every divider, and the platter's strobe dots and mat ring -- those are ENGRAVED marks, so they take the divider colour rather than an ink that would be darker in one mode and lighter in the other.",
            val: "#CED1D7"
        },
        {
            label: "header bevel",
            prop: "headerBoxBevel",
            group: "Edges",
            tip: "The rim outside a header box's edge, and outside the platter's. It is the only triple in the palette that reads as one well at both modes without inventing a colour.",
            val: "#EDF0F7"
        },
        {
            label: "header shadow",
            prop: "headerBoxShadow",
            group: "Edges",
            tip: "The inset inside that edge. Deeper than a list box's, which is why the platter reads as a well rather than as a smudge at its radius.",
            val: "#AAADB4"
        },
        {
            label: "deep shadow",
            prop: "shadowDeep",
            group: "Edges",
            tip: "The deepest inset, the drop shadows -- and the record's GROUND: the half of the room below the horizon that the lacquer reflects.",
            val: "#AAADB4"
        },
        {
            label: "ball shadow",
            prop: "ballShadow",
            group: "Edges",
            tip: "The contact shadow under the viewfinder's ball. Darker than the shell's own shadow, because it is cast into a groove rather than onto the surface.",
            val: "#2A2C31"
        },
        {
            label: "primary text",
            prop: "textPrimary",
            group: "Ink",
            blurb: "Three weights of ink, and the one accent everything active wears.",
            tip: "Titles, and the reading of every figure. Dark enough to clear 4.5:1 on the surface and no darker: a true black punches a hole in a pale panel.",
            val: "#5D5D5F"
        },
        {
            label: "muted text",
            prop: "textMuted",
            group: "Ink",
            tip: "The artist, the album, a glyph that is not on. At least 4.5:1 on the surface.",
            val: "#68686B"
        },
        {
            label: "faint text",
            prop: "textFaint",
            group: "Ink",
            tip: "Durations, counts, anything disabled -- and the hue an album with no genre tag wears in the library, which is the honest answer rather than a colour some genre may want later.",
            val: "#888888"
        },
        {
            label: "accent",
            prop: "accent",
            group: "Ink",
            tip: "Play, the played part of the rail, the ball, the sparks, the selected pill. One accent for everything active in the module, so no second colour is ever asked to mean a second fact.",
            val: "#4480F4"
        },
        {
            label: "accent hover",
            prop: "accentHover",
            group: "Ink",
            tip: "The same under the pointer. Nothing announces an affordance but this fade and the cursor.",
            val: "#4D91F8"
        },
        {
            label: "accent bevel",
            prop: "accentBevel",
            group: "Ink",
            tip: "The highlight inside an accent button's edge. A lightened accent rather than the white a plain button gets, so the play button's rim is still the accent and not a second colour.",
            val: "#88ADF5"
        },
        {
            label: "text on accent",
            prop: "textOnAccent",
            group: "Ink",
            tip: "The glyph on the play button. An alias of the surface, so it stays the ground's colour in both modes.",
            val: "@surface"
        },
        {
            label: "ok",
            prop: "ok",
            group: "Ink",
            tip: "The fidelity chip's lossless tiers -- the one place in this module a state is coloured rather than named.",
            val: "#44C145"
        },
        {
            label: "button plateau",
            prop: "buttonPlateau",
            group: "Buttons",
            blurb: "Buttons stand PROUD of the surface; everything else in the shell is carved into it. Same colours both ways, spreads tuned separately.",
            tip: "The face of a raised button. It IS the surface's own colour: a proud button is told from the ground by its bevel and its shadow, never by a different fill.",
            val: "#EAEDF5"
        },
        {
            label: "plateau hover",
            prop: "buttonPlateauHover",
            group: "Buttons",
            tip: "The same under the pointer, one step brighter. Nothing else in the shell announces that a button can be pressed -- that, and the hand cursor.",
            val: "#F1F4FB"
        },
        {
            label: "button bevel",
            prop: "buttonBevel",
            group: "Buttons",
            tip: "The highlight inside a raised button's edge -- and the lit side of the turntable's spindle, which is a turned cylinder under the same key light.",
            val: "#FFFFFF"
        },
        {
            label: "button shadow",
            prop: "buttonShadow",
            group: "Buttons",
            tip: "The drop shadow outside it, and the spindle's shaded side. The same deep grey every shadow in the shell is drawn in, so a proud button and a carved box are lit by one lamp.",
            val: "#AAADB4"
        }
    ]

    // ---- the record ------------------------------------------------------
    // How big the record is drawn in the box the popup gives the stage. It is
    // the STAGE'S number, not the disc's: the disc's item fills the stage so a
    // lifted record's shadow can leave the record's own square, and what the
    // disc is handed is whatever fraction makes it come out at this size.

    readonly property var stageGeom: [
        {
            label: "record size",
            prop: "recordFrac",
            group: "The stage",
            blurb: "The record is drawn in a square box the popup hands the stage, and the shader covers the WHOLE stage so a shadow is never cut off at that box's edge. This is how much of the box the record itself is.",
            tip: "How much of the record's box the record takes up IN THE NORMAL VIEW. Under 1 to leave the room it grows into as it lifts toward the camera, and the room its shadow needs. It lives on the stage rather than on the record because the record's own item is the stage now: the fraction VinylDisc is handed is derived from this and is not a number anybody can tune.",
            val: 0.78,
            from: 0.3,
            to: 1.0,
            step: 0.01
        },
        {
            label: "record size (mini)",
            prop: "miniRecordFrac",
            group: "The stage",
            tip: "The same fraction for the mini player, which is a separate number because the two views do not need the same headroom. Higher than the normal view's on purpose: in mini the record neither lifts as far toward the camera nor throws as much shadow, so it can stand nearer the edge of its box -- and it needs the help, because that is the view where it is drawn smallest.",
            val: 0.96,
            from: 0.3,
            to: 1.0,
            step: 0.01
        }
    ]

    // The record's own size is NOT here any more. VinylStage binds
    // `disc.radiusFrac` (the fraction that makes the disc's item -- which is
    // now the whole stage -- come out at `discSize`), so a panel write to it
    // destroys that binding and the record stops tracking the box it is given.
    // The tunable half of it is VinylStage.recordFrac, on `stageGeom` above.
    readonly property var discGeom: [
        {
            label: "hole",
            prop: "holeFrac",
            group: "Proportions",
            blurb: "A real LP is 302 mm across with a 100 mm label and a 7.2 mm spindle hole. Everything here is a fraction of the outer radius, so the record stays a record at any size.",
            tip: "The spindle hole, as a fraction of the outer radius. 0.024 is the real 7.24 mm on a 302 mm record. It is a real hole: at a tilt you see its inner wall, and the spindle comes up through it.",
            val: 0.024,
            from: 0,
            to: 0.15,
            step: 0.002
        },
        {
            label: "label",
            prop: "labelFrac",
            group: "Proportions",
            tip: "The paper label, as a fraction of the outer radius. 0.331 is the real 100 mm label.",
            val: 0.331,
            from: 0.1,
            to: 0.7,
            step: 0.005
        },
        {
            label: "grooves start",
            prop: "grooveInnerFrac",
            group: "Proportions",
            tip: "Where the modulated area begins. 0.365 leaves a sliver between it and the label's 0.331: that is the lead-out land, smooth, and the one part of the record that reflects like a mirror.",
            val: 0.365,
            from: 0.1,
            to: 0.9,
            step: 0.005
        },
        {
            label: "grooves end",
            prop: "grooveOuterFrac",
            group: "Proportions",
            tip: "Where the modulated area ends. 0.965 rather than 1: what is left outside it is the lead-in land at the rim, smooth again, and it is what catches the light when the record tips.",
            val: 0.965,
            from: 0.2,
            to: 1.0,
            step: 0.005
        },
        {
            label: "thickness",
            prop: "thicknessFrac",
            group: "Proportions",
            tip: "HALF the thickness, as a fraction of the radius, so the slab is twice this across. 0.013 draws a rim about twice a real LP's proportion, and deliberately: the record is about 400 px across here, where a true 1.9 mm on a 302 mm disc is two and a half pixels. It only shows when the record turns far enough to see its rim -- which the flip does, twice.",
            val: 0.013,
            from: 0,
            to: 0.08,
            step: 0.001
        },
        {
            label: "camera distance",
            prop: "camDistFrac",
            group: "Camera",
            blurb: "A pinhole camera in front of the record; the item's plane is drawn 1:1, so this only shows when the record tilts or lifts.",
            tip: "Eye distance in radii. Large is nearly orthographic and the record looks flat; small exaggerates the tilt and makes the lift read as coming toward you. The stage measures the sleeve against the record as drawn at its put-away height, so this changes how big a sleeve has to be.",
            val: 4.2,
            from: 1.6,
            to: 14,
            step: 0.1
        }
    ]

    readonly property var discMaterial: [
        {
            label: "groove count",
            prop: "grooveCount",
            group: "Grooves",
            blurb: "A real groove pitch is far under a pixel at any size this is drawn at, so the fine sine is not what the eye reads -- the smooth LANDS between tracks are.",
            tip: "How many fine grooves span the modulated band. They fade out on their own once the pixel footprint reaches half the pitch, which is Nyquist and not a guess: the old fade ran to 0.9 of the pitch, still drawing the sine at 1.8x its own sampling limit, and that is where the beating rings came from. Past visibility this costs nothing and changes nothing.",
            val: 150,
            from: 10,
            to: 400,
            step: 5
        },
        {
            label: "track lands",
            prop: "trackCount",
            group: "Grooves",
            tip: "The smooth bands between tracks -- what actually reads as 'grooves' at popup size, because a land has no groove in it and therefore reflects like a mirror next to the scattering modulated area. About one per song.",
            val: 9,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "land width",
            prop: "trackWidth",
            group: "Grooves",
            tip: "How wide a land is, as a fraction of the spacing between them. It is also what the rings dissolve INTO once a whole land-and-groove pair falls inside one pixel: that average is the right grey, and drawing rings there instead is the other half of the moire.",
            val: 0.62,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "groove depth",
            prop: "grooveDepth",
            group: "Grooves",
            tip: "How far the fine grooves bend the surface normal. Only visible while a ring is wider than a pixel; past that it is faded out and the roughness below takes over, which is why raising it does nothing on a small record.",
            val: 0.55,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "groove scatter",
            prop: "grooveRough",
            group: "Grooves",
            tip: "How much rougher the modulated area is than a land. This is what keeps the rings readable when the fine grooves are too small to draw -- and it lifts the albedo there a little, so they read even with no highlight crossing them.",
            val: 0.10,
            from: 0,
            to: 0.6,
            step: 0.005
        },
        {
            label: "along the groove",
            prop: "roughAlong",
            group: "Sheen",
            blurb: "The record's whole look: an anisotropic highlight whose tangent runs ALONG the grooves, so it stretches radially.",
            tip: "Roughness along the groove -- the axis the record is smooth on. Small is a sharp, tight sheen; large blurs it into a haze. 0.045 against 0.22 across it is a five-to-one anisotropy, and that ratio IS the record: equal on both axes and it is a black plate.",
            val: 0.045,
            from: 0.005,
            to: 0.4,
            step: 0.005
        },
        {
            label: "across the groove",
            prop: "roughAcross",
            group: "Sheen",
            tip: "Roughness across the groove -- the rough axis. Raising it smears the highlight further out along the radius, which is what makes the sheen a bar rather than a dot.",
            val: 0.22,
            from: 0.01,
            to: 0.8,
            step: 0.005
        },
        {
            label: "sheen strength",
            prop: "specStrength",
            group: "Sheen",
            tip: "How hard the three lamps strike the lacquer, before the ceiling beside it takes the top off. Under 1 deliberately: the sheen is added on top of a diffuse term that already puts a pale body just under 1 (Tone), so a strength that filled the range on its own would leave it nowhere to sit above.",
            val: 0.8,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "sheen ceiling",
            prop: "specKnee",
            group: "Sheen",
            tip: "A soft ceiling: the sheen can reach 1/this at most. There is an angle in the flip where every point of the record reflects the strip at once, and without a ceiling the whole disc goes white and loses its shape.",
            val: 1.0,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "reflection",
            prop: "reflectivity",
            group: "Sheen",
            tip: "How much of the room the lacquer shows. This is what makes the black read as glossy rather than as rubber.",
            val: 1.0,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "diffuse gain",
            prop: "diffuseGain",
            group: "Tone",
            blurb: "What the lighting does to a colour on its way back out. It is normalised now, so the vinyl colour set on the Colours tab is the colour that comes back.",
            tip: "How much of the diffuse light returns. With the ambient below it, a white albedo facing the key lands just under 1: measured on the default rig, 0.28 + 0.855 x 0.784 = 0.951. Just under, so a pale body still leaves the sheen somewhere to go -- the old 0.55 ceiling is why #FFFFFF in the album art came back #96979A.",
            val: 0.855,
            from: 0.2,
            to: 2,
            step: 0.005
        },
        {
            label: "ambient",
            prop: "ambientDiffuse",
            group: "Tone",
            tip: "The light that reaches a surface facing nothing. It is the floor of that same sum, so raising it flattens the record and leaves the key less to add.",
            val: 0.28,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "highlight knee",
            prop: "highlightKnee",
            group: "Tone",
            tip: "Where the output bends toward 1 instead of arriving at it. The near-black default never reaches it; a white record's whole face would otherwise sit at the ceiling with the arcs clipped flat out of it.",
            val: 0.88,
            from: 0.2,
            to: 2,
            step: 0.01
        },
        {
            label: "pale sheen",
            prop: "paleSheen",
            group: "Tone",
            tip: "How much a PALE body damps its own sheen. The ramp inside the shader starts at 0.30 luma and the default record's is 0.04, so this knob does not reach a black record at all -- the reflection stays exactly as it is. A white one loses enough of the arcs not to read as brushed metal.",
            val: 0.62,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "label roughness",
            prop: "labelRough",
            group: "The label",
            blurb: "The label is paper: matte, isotropic, and it has no grooves, so it takes none of the anisotropy.",
            tip: "How rough that paper is. It is the width of both the label's own lobes, the room's and the lamps'. 0.65 is paper: broad enough that neither can ever become a hard highlight, which is the difference between the label and the lacquer around it.",
            val: 0.65,
            from: 0.05,
            to: 1,
            step: 0.01
        },
        {
            label: "label room",
            prop: "labelReflect",
            group: "The label",
            tip: "The room in the paper: the environment through a roughness-capped fresnel, so it is nothing face-on and climbs as the label turns away. That is the angle the flip shows it at, and measured there (80 degrees) it is the whole of the effect -- 15 levels of 255.",
            val: 0.60,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "label lamp sheen",
            prop: "labelSpec",
            group: "The label",
            tip: "The direct lights' own lobe on the paper, and it has to stay small. A GGX lobe this broad is a flat veil rather than a highlight: at 6.0 it lifted the label's blacks from 36 to 100 and bleached the artwork the user asked to see, while adding 0.2 of a level at grazing -- brightest exactly where a sheen should be weakest.",
            val: 1.2,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "corner roll",
            prop: "edgeBevelFrac",
            group: "The edge",
            blurb: "The rim and the spindle hole's wall: the two places the record is not a flat face, and both of them sub-pixel at popup size.",
            tip: "How far the corners between the faces and the rim are rolled over, as a fraction of the HALF thickness. Traced sharp they meet at an exact right angle, and under this lighting that seam is black -- the void a flipping record showed. Rolling the normal is all the light needs to wrap them.",
            val: 0.75,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "edge ambient",
            prop: "edgeAmbient",
            group: "The edge",
            tip: "The light a cut edge gets when it faces nothing. It is matte and catches every bounce inside the hole, so it is never quite #000000.",
            val: 0.16,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "edge lift",
            prop: "edgeLift",
            group: "The edge",
            tip: "How far the cut edge sits from the body's own colour. A cut through vinyl is a shade lighter than its polished face.",
            val: 0.10,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "edge samples",
            prop: "edgeSamples",
            group: "The edge",
            tip: "Sub-samples spent on a pixel the silhouette, the rim band or the spindle hole passes through -- and only on those, so this is not a cost the whole record pays. The coverage used to come from the hit point's derivative, which at a silhouette is meaningless: measured, that put the rim's alpha at 255 in one pixel and 0 in the next, no antialiasing at all. 0 turns it off, which is the negative control the render harness arms.",
            val: 8,
            from: 0,
            to: 8,
            step: 1
        }
    ]

    readonly property var discLight: [
        {
            label: "key angle",
            prop: "keyAngleDeg",
            group: "Key light",
            blurb: "Lights are given as an angle and an elevation, because that is how a light is tuned: the angle sweeps it round the record, the elevation lifts it toward the camera.",
            tip: "Where the key light stands, in degrees: 0 is from the right, 90 from above. It also lights the sleeve and the spindle, so all three objects agree about where the room is.",
            val: 122,
            from: -180,
            to: 180,
            step: 1
        },
        {
            label: "key elevation",
            prop: "keyElevation",
            group: "Key light",
            tip: "How far the key light is lifted out of the record's plane toward the camera. At 1 it is straight down the lens and the sheen collapses to the centre.",
            val: 0.52,
            from: -1,
            to: 1,
            step: 0.01
        },
        {
            label: "key strength",
            prop: "lightIntensity0",
            group: "Key light",
            tip: "How bright the key is. The tone knobs are balanced against this one, so moving it moves where a white albedo lands.",
            val: 1.0,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "fill angle",
            prop: "fillAngleDeg",
            group: "Fill light",
            blurb: "A second, weaker light opposite the key, so the half of the record the key misses is not flat black.",
            tip: "Where the fill stands, on the same dial as the key. -29 against the key's 122 puts it across the record from it, which is the half of the record the key misses -- the whole job of a fill.",
            val: -29,
            from: -180,
            to: 180,
            step: 1
        },
        {
            label: "fill elevation",
            prop: "fillElevation",
            group: "Fill light",
            tip: "How far the fill is lifted out of the record's plane. 0.70, higher than the key's 0.52: a fill nearer the lens lifts the dark half without drawing a second sheen of its own across the grooves.",
            val: 0.70,
            from: -1,
            to: 1,
            step: 0.01
        },
        {
            label: "fill strength",
            prop: "lightIntensity1",
            group: "Fill light",
            tip: "How bright the fill is. Well under the key, or the record loses its direction.",
            val: 0.45,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "strip angle",
            prop: "stripAngleDeg",
            group: "Strip light",
            blurb: "The thing that makes a record look like a record. A point lamp on circular grooves gives a straight radial BAR of light; the curved sheens a record really shows need a source with LENGTH.",
            tip: "Where the middle of the strip stands, in degrees. 105 is close to the key's 122 on purpose: the arc the strip bends across the record and the key's own highlight then agree about where the room is, instead of reading as two lamps.",
            val: 105,
            from: -180,
            to: 180,
            step: 1
        },
        {
            label: "strip elevation",
            prop: "stripElevation",
            group: "Strip light",
            tip: "How far the strip is lifted toward the camera. 0.82 is the highest of the three, so its reflection crosses the record's FACE, where the grooves are, rather than skimming the rim.",
            val: 0.82,
            from: -1,
            to: 1,
            step: 0.01
        },
        {
            label: "strip tilt",
            prop: "stripTiltDeg",
            group: "Strip light",
            tip: "How the strip LIES across the view -- 0 is horizontal, 90 vertical. Turning it turns the arc the sheen is bent into.",
            val: 20,
            from: -90,
            to: 90,
            step: 1
        },
        {
            label: "strip length",
            prop: "stripHalfLength",
            group: "Strip light",
            tip: "Half the strip's length, in direction units. At 0 it is a point light and the sheen is a straight bar again; long makes the arc wide and soft.",
            val: 0.70,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "strip strength",
            prop: "stripIntensity",
            group: "Strip light",
            tip: "How bright the strip is. It is the brightest thing on the record and the first knob to reach for if the sheen is blowing out.",
            val: 0.9,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "horizon softness",
            prop: "envHorizon",
            group: "Room",
            blurb: "The room the record reflects: a bright half above the horizon and a dark half below, taken from the theme.",
            tip: "How soft the line between the room's two halves is. It decides whether the disc reads as lacquer or as rubber, because the record's blackness is entirely this gradient bent by the surface.",
            val: 0.45,
            from: 0.02,
            to: 2,
            step: 0.01
        },
        {
            label: "shadow strength",
            prop: "shadowStrength",
            group: "Shadow",
            blurb: "A real projection, not a blurred silhouette: from where the view ray meets the surface, walk back along the light and ask whether it crosses the record's plane.",
            tip: "How dark the shadow the record casts is. At 0 there is none and the record floats with nothing under it.",
            val: 0.42,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shadow softness",
            prop: "shadowSoftness",
            group: "Shadow",
            tip: "How fast the shadow blurs and drains as the record rises. This is what says 'lifted' rather than 'down' -- a record on the platter has a tight dark contact shadow.",
            val: 0.004,
            from: 0,
            to: 0.03,
            step: 0.0005
        },
        {
            label: "surface gap",
            prop: "shadowGapFrac",
            group: "Shadow",
            tip: "How far behind the record its resting surface is, in radii. Without a gap a record at rest casts its shadow in its own plane, which is no shadow at all.",
            val: 0.025,
            from: 0,
            to: 0.3,
            step: 0.005
        },
        {
            label: "softness at the tip",
            prop: "pinPenumbra",
            group: "Spindle shadow",
            blurb: "The spindle's shadow on the label. The record draws it, because the label is its own texture; the stage places it, because only the stage knows how far the record has risen up the pin. It is not one softness: the penumbra grows ALONG it, because what sets a penumbra is the distance between the point casting the shadow and the surface catching it -- zero where the pin comes through the label, the whole protrusion by the tip.",
            tip: "The penumbra at the shadow's TIP, in px per px of protrusion. What it is cast from is the length of pin standing PROUD of the label, so the shadow is longest with the record down and gone once the record has cleared the pin -- feeding the record's own height instead inverts it, which is measurably what happened first. A record still on its way down therefore has a SHORT HARD shadow and a settled one a long soft draining shadow, with nothing switching between them. Its strength and the pin's size are on Motion -> Platter.",
            val: 0.22,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "softness at the pin",
            prop: "pinPenumbraBase",
            group: "Spindle shadow",
            tip: "And how soft it is at the other end, where the pin comes through the hole, in px. A contact: 0.6 is one antialiased edge, which is what keeps the base of the shadow reading as something standing IN the label rather than hovering over it.",
            val: 0.6,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "drain to the tip",
            prop: "pinShadowFade",
            group: "Spindle shadow",
            tip: "How much darkness the shadow gives up on its way out. A penumbra that widens without draining reads as a smear rather than as a shadow ending; 0.45 loses it just under half its strength by the tip. The same number, for the same reason, as the pin's shadow on the mat.",
            val: 0.45,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var discWear: [
        {
            label: "dust",
            prop: "dust",
            group: "Wear",
            blurb: "A record that has been played. Every one of these is off at 0, which is a factory-fresh pressing.",
            tip: "Sparse specks on the lacquer, sized in the record's own space and softened by the pixel footprint, so they thin out as the record shrinks instead of turning into a field of hard squares. Never on the cut edge, where the radius barely changes so the cell index runs at the pixel rate and the field collapses into white noise -- that noise along the rim of a record mid-flip is what read as a void with static in it.",
            val: 0.3,
            from: 0,
            to: 2,
            step: 0.02
        },
        {
            label: "scuffing",
            prop: "scuff",
            group: "Wear",
            tip: "Fine circular scratches. They raise the ROUGHNESS along the groove rather than bending the normal -- a bent normal at this scale sparkles under the sheen, which reads as noise, not as wear.",
            val: 0.24,
            from: 0,
            to: 2,
            step: 0.02
        },
        {
            label: "label wear",
            prop: "labelWear",
            group: "Wear",
            tip: "Grain on the paper and a darker ring where it meets the lacquer. Lightly, because the label was kept in the sleeve.",
            val: 0.35,
            from: 0,
            to: 2,
            step: 0.02
        }
    ]

    readonly property var discColors: [
        {
            label: "vinyl",
            prop: "vinylColor",
            group: "The record",
            blurb: "The record's own material, which is physical rather than themed -- a coloured pressing is a coloured pressing in either mode.",
            tip: "The body's albedo, and it is literally that now: the lighting is normalised, so what is set here is what comes back. That is why this default reads darker than the old one -- #121216 through the old 0.55 ceiling rendered the same near-black this renders directly. A picture disc or a coloured pressing is this knob and nothing else.",
            val: "#0A0A0D"
        },
        {
            label: "label tint",
            prop: "labelTint",
            group: "The record",
            tip: "Multiplies the album art on the label. White is the default because the art is the album's identity; this is the knob for a deliberate cast, and the wear on the Wear tab is the knob for age.",
            val: "#FFFFFF"
        },
        {
            label: "key colour",
            prop: "lightColor0",
            group: "Lights",
            blurb: "The three lamps' own colours. Where they stand is on the Light tab; this is only what they are made of.",
            tip: "The key light's colour. White, because it is the reference the tone knobs were balanced against: tint it and the albedo set above stops being the colour that comes back.",
            val: "#FFFFFF"
        },
        {
            label: "fill colour",
            prop: "lightColor1",
            group: "Lights",
            tip: "The fill light's colour. A touch of blue reads as the cool half of a room.",
            val: "#C9D6FF"
        },
        {
            label: "strip colour",
            prop: "stripColor",
            group: "Lights",
            tip: "The strip light's colour -- and so the arcs' own, since the sheen is nearly all strip. White keeps the record's colour the only colour on the record.",
            val: "#FFFFFF"
        }
    ]

    // ---- the sleeve ------------------------------------------------------

    readonly property var sleeveParams: [
        {
            label: "print inset",
            prop: "coverInset",
            group: "Board",
            blurb: "The album cover as a piece of printed card that has been pulled in and out of a shelf for thirty years.",
            tip: "How much bare card shows around the print, in px -- about the white margin a printed sleeve really leaves. That rim is what the split below eats into, so a sleeve with no inset loses its art rather than its border.",
            val: 2,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "edge split",
            prop: "edgeWear",
            group: "Board",
            tip: "How far in from the cut the print has split and the board's core shows, in px. Patchy, not a uniform band: the split follows the board's own fibres. The stage adds a little of it to the sleeve's size, because that ragged edge is drawn inside the item's bounds and a record flush with them would show through it.",
            val: 9.5,
            from: 0,
            to: 30,
            step: 0.5
        },
        {
            label: "corner wear",
            prop: "cornerWear",
            group: "Board",
            tip: "How much of each corner has been chewed away, in px. This eats the SILHOUETTE, not just the colour -- a worn sleeve has round corners.",
            val: 12,
            from: 0,
            to: 50,
            step: 1
        },
        {
            label: "ring depth",
            prop: "ringWear",
            group: "The ring",
            blurb: "The record inside presses a circle into the front. It is drawn as a HEIGHT the light catches, not as a dark ring.",
            tip: "How deep that impression is. It is the one mark everybody recognises on a sleeve, which is exactly why it wants to sit at the edge of visibility -- read as a shape rather than as a stamp. The crease must also stay NARROW: a wide gentle slope has no normal for the light to catch and the ring simply disappears.",
            val: 0.25,
            from: 0,
            to: 6,
            step: 0.05
        },
        {
            label: "ring ink loss",
            prop: "ringInk",
            group: "The ring",
            tip: "How much ink the record's rim has taken off along the same circle. Kept as a second knob so the impression can be brought back either way: the depth is the height, this is the colour.",
            val: 0.025,
            from: 0,
            to: 1,
            step: 0.005
        },
        {
            label: "ring radius",
            prop: "ringRadius",
            group: "The ring",
            tip: "Where the impression sits, as a fraction of the sleeve's half-width. 0.86 is where a record's grooves end -- the same radius the turntable's mat ring uses, so the two objects agree about the record.",
            val: 0.96,
            from: 0.3,
            to: 1.0,
            step: 0.01
        },
        {
            label: "scuffs",
            prop: "scratches",
            group: "Surface",
            blurb: "Everything the print has been through since.",
            tip: "Long, nearly horizontal scuffs across the print. They both catch the light and take the ink off, from the same field -- a scuff that shines but keeps its colour reads as a smear on the screen, not on the card.",
            val: 0.9,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "paper grain",
            prop: "grain",
            group: "Surface",
            tip: "The board's own texture, under the print and under every other mark here. 0.32, well under the scuffs' 0.9: grain you can pick out individually is sandpaper, not card.",
            val: 0.16,
            from: 0,
            to: 2,
            step: 0.02
        },
        {
            label: "fade",
            prop: "fade",
            group: "Surface",
            tip: "How far the print has faded toward the card's own colour. Kept light at 0.14: a sleeve worn this hard would really be paler, but the cover is the album's identity and the same art is on the record's label a moment later.",
            val: 0.14,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "wear bias",
            prop: "wearBias",
            group: "Where the wear lives",
            blurb: "A sleeve is not weathered evenly: it is handled by its rim and pulled out of a shelf by a corner, so grain, scuffs and abrasion are all multiplied by a centre-to-edge mask.",
            tip: "How much of the front is spared. 0 is the old even weathering; 1 wears the rim and nothing else.",
            val: 0.82,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "wear shape",
            prop: "wearShape",
            group: "Where the wear lives",
            tip: "How abruptly that mask climbs on the way out. A linear ramp from the centre reads as a vignette, so this one is quiet across the middle and steep over the last of the way out -- and it lifts the two diagonals as well, so a corner wears like a piece of rim twice over.",
            val: 3.0,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "gloss",
            prop: "gloss",
            group: "Light",
            blurb: "The sleeve is lit by the record's own key light, so the two objects agree about where the room is.",
            tip: "How much the print still shines; bare board never does, whatever this says. 0.35 is a matte old cover catching a little of the key light, not a laminated reissue.",
            val: 0.35,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "key strength",
            prop: "lightIntensity",
            group: "Light",
            tip: "How hard the key light falls on the card. 0.85 against the record's 1.0 -- the same lamp in the same place, and card returns less of it than lacquer does.",
            val: 0.9,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "ambient",
            prop: "ambient",
            group: "Light",
            tip: "How much light reaches the card from everywhere at once. Lower makes the ring and the scuffs more dramatic and the cover harder to read.",
            val: 0.42,
            from: 0,
            to: 1.5,
            step: 0.01
        },
        {
            label: "wear seed",
            prop: "seed",
            group: "Light",
            tip: "Decorrelates two sleeves on screen at once -- at an album boundary the one leaving and the one arriving must not wear identically.",
            val: 0.37,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    readonly property var sleeveColors: [
        {
            label: "board core",
            prop: "cardColor",
            group: "The board",
            blurb: "The card itself, which is a physical colour rather than a themed one.",
            tip: "What shows where the print has gone: the board's own core. A warm grey, because that is the colour of the pulp under a printed sleeve -- and it is physical rather than themed, so it does not follow the mode.",
            val: "#D8D2C4"
        },
        {
            label: "cut edge",
            prop: "cardEdgeColor",
            group: "The board",
            tip: "The board's cut edge at the sleeve's mouth -- the one edge that is a lip rather than a fold, because the record has to come out toward the middle of the stage.",
            val: "#BDB6A6"
        },
        {
            label: "print tint",
            prop: "printTint",
            group: "The board",
            tip: "Multiplies the cover art. White by default because everything else on this tab already ages the print: this is the knob for a deliberate colour cast, not for wear.",
            val: "#FFFFFF"
        }
    ]

    // ---- what the record does --------------------------------------------

    readonly property var motionParams: [
        {
            label: "time scale",
            prop: "timeScale",
            group: "Speed",
            blurb: "One number scales every duration in every sequence, so the SHAPE of the choreography cannot change when its speed does.",
            tip: "Above 1 runs the arrival, the flip and the put-away in slow motion, which is how you tell whether a sweep overshoots too far; below 1 runs them fast, which is how a probe watches a whole arrival inside a test's patience. A duration is read when its segment starts, so a change lands on the next segment rather than on the one you are watching.",
            val: 1.0,
            from: 0.1,
            to: 4,
            step: 0.05
        },
        {
            label: "spin rate cap (Hz)",
            prop: "spinHz",
            group: "The platter",
            blurb: "How often the record's angle is advanced. The record is the only thing in the popup that animates continuously, so its clock is what makes the whole card redraw -- every other per-frame cost in here is paid at whatever rate this runs at.",
            tip: "0 is every frame, which is the default and what it has always done. Anything else caps it, and the saving is roughly proportional: this panel is 120 Hz, so 60 is about half the popup's per-second cost and 30 about a quarter. Judge it on the DUST AND THE SCUFFING at the outer edge, not on the label -- they are the highest-frequency detail on the disc and they are what sells the spin. At 33 1/3 rpm the record turns 3.3 degrees a step at 120 Hz and 13.3 at 30.",
            val: 0,
            from: 0,
            to: 120,
            step: 5
        },
        {
            label: "rpm",
            prop: "rpm",
            group: "The platter",
            tip: "The record's angle IS the playback position: the spin is integrated from one rate, and while the record is down that rate is the position's own derivative times this speed. 33 1/3 for an LP, which is 200 degrees a second. It is also what makes a scrub across a three-minute track look violent and one across a twenty-minute track look calm -- correctly, because it is.",
            val: 33.333,
            from: 5,
            to: 80,
            step: 0.333
        },
        {
            label: "scrub spin",
            prop: "scrubSpinScale",
            group: "The platter",
            tip: "How far a DRAGGED second of position turns the record, against the platter's own speed. At 1 -- the angle being the position exactly -- a drag across a three-minute track spun it a hundred times, which reads as a strobe rather than as a record wound by hand; at 0.2 a ten-second nudge is a little over one turn. Only a drag is scaled: playback still turns it at 33 1/3 rpm.",
            val: 0.2,
            from: 0.02,
            to: 1.0,
            step: 0.01
        },
        {
            label: "catch-up ceiling",
            prop: "positionCatchup",
            group: "The platter",
            tip: "The most position, in seconds per second of real time, the music may drag the record round. Playback advances it one second per second, so the headroom above 1 is for the service re-seating its clock forward; everything above this -- a track change's whole track, a click on the rail, a mock run at 20x -- is CARRIED rather than turned, which is what stops a skip snapping the record round.",
            val: 1.6,
            from: 1.0,
            to: 4.0,
            step: 0.1
        },
        {
            label: "run-up ms",
            prop: "spinRunupMs",
            group: "The platter",
            tip: "How long the wheel takes to take up when playback resumes. A pause is not a motor cut and neither is a resume: 620 ms is not what a direct drive does, it is what reads as a platter finding its speed.",
            val: 620,
            from: 0,
            to: 2000,
            step: 10
        },
        {
            label: "run-down ms",
            prop: "spinRundownMs",
            group: "The platter",
            tip: "And how long it takes to let go when playback pauses. The SAME number as the run-up, because that is what the user asked for -- and the easing is the run-up's read backwards, so the wheel sweeps the same 93 degrees letting go as it does taking up. Equal milliseconds with unequal easings are not the same by the only measure the eye has.",
            val: 620,
            from: 0,
            to: 2000,
            step: 10
        },
        {
            label: "rest height",
            prop: "restHeight",
            group: "The platter",
            tip: "How far above the platter the record sits while it is playing, in px. 0 is down on the mat, which is where its contact shadow is tightest and the spindle's shadow on the label is longest.",
            val: 0,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "platter size",
            prop: "platterFrac",
            group: "The platter",
            tip: "The platter's diameter, as a fraction of the record's own. Under 1 because a record overhangs its platter, and that overhang is what the contact shadow falls on.",
            val: 0.94,
            from: 0.5,
            to: 1.4,
            step: 0.01
        },
        {
            label: "pin length",
            prop: "pinLengthFrac",
            group: "The platter",
            tip: "How far the spindle stands above the platter, of the record's diameter. The record is drawn face-on, so a strictly correct spindle would be three pixels of nothing: a short standing pin is the stylisation that makes the drop read as a drop. 0.064 is 15% off the 0.075 it was drawn at while the pin was a rod seen from the side -- from above nothing draws its length, and what showed it instead, the shadow it lays across the mat, read as a rod at the old number. The pin's RADIUS is not a knob -- it is measured from the record's hole, so it fits through it by construction.",
            val: 0.064,
            from: 0,
            to: 0.3,
            step: 0.005
        },
        {
            label: "pin shadow",
            prop: "pinShadowStrength",
            group: "The platter",
            tip: "How dark the pin's shadow on the label is with the record down. It fades to nothing as the record rises off the pin, because at zero protrusion the shader draws the pin's own cross-section and a record held above it would keep a dark dot on its label. How soft that shadow is belongs to the record: Record -> Light.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "arrival ms",
            prop: "showMs",
            group: "The arrival",
            blurb: "The swivel, the rise toward the camera and the drop onto the platter are ONE 0..1 progress, not three animations in a row -- so the drop has no beginning of its own to give it away.",
            tip: "How long that whole arc takes, from the first of the swivel to the record landing. 3200, the flip's own duration. It is also most of what a first play waits through, since it is the drop that releases the audio.",
            val: 3200,
            from: 600,
            to: 8000,
            step: 50
        },
        {
            label: "swivel start",
            prop: "showStartFrac",
            group: "The arrival",
            tip: "How far into the sleeve's exit the swivel begins, as a fraction of it. The record is uncovered from its left edge as the sleeve slides off, so it can start showing itself well before the sleeve has left the stage.",
            val: 0.45,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "swivel turns",
            prop: "showTurns",
            group: "The arrival",
            tip: "How many times the swivel goes round. It is a cone, not two crossing rocks: the record's normal travels a circle inside an envelope that is nothing at both ends, so the record starts flat, is at its most turned where it is nearest the camera, and lands flat without being told to.",
            val: 1.5,
            from: 0.25,
            to: 5,
            step: 0.25
        },
        {
            label: "swivel amplitude",
            prop: "showTiltAmp",
            group: "The arrival",
            tip: "How far off the view plane the swivel leans at its widest, in degrees. This is the angle that moves the anisotropic sheen about, which is the whole reason the record is shown off before it is played.",
            val: 22,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "swivel ends at",
            prop: "showTiltEndFrac",
            group: "The arrival",
            tip: "Where in the arc the swivel is over. The last of the arc is the record already on its way down and no longer turning on its own axes: one continuous descent that BECOMES the drop.",
            val: 0.85,
            from: 0.2,
            to: 1,
            step: 0.01
        },
        {
            label: "peak height",
            prop: "showPeakFrac",
            group: "The arrival",
            tip: "How close to the camera the record comes at the top of the arc, as a fraction of its own size. Under the flip's 0.30: the arrival is a presentation and the flip is the bigger event, and the two must not compete.",
            val: 0.20,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "peak at",
            prop: "showApexFrac",
            group: "The arrival",
            tip: "Where in the arc that peak is. Past the middle, because the record should start going away again closer to the last quarter of the swivel. The rise is a smootherstep, so it leaves the platter without a jerk and arrives with no speed to reverse; the fall is gravity with a cushion, which is what a hand setting a record down does and what a free fall does not.",
            val: 0.62,
            from: 0.05,
            to: 0.95,
            step: 0.01
        },
        {
            label: "spin-up at",
            prop: "spinupStartFrac",
            group: "The arrival",
            tip: "Where in the arc the platter takes the record. On the way DOWN, so the spin is already at speed when it lands rather than starting there. 0.47 of a 3200 ms arrival is 350 ms earlier than the 0.58 it used to be: the record now begins to turn while the swivel is still going, which stops the spin reading as a separate event bolted to the end of it.",
            val: 0.42,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "flip ms",
            prop: "flipMs",
            group: "The flip",
            blurb: "The half-album flip: one 0..1 progress read through ONE time warp, so the rise, the turns, the fall and the slow motion at the top cannot drift apart. The warp is integrated into a lookup table when any of these change.",
            tip: "How long the whole flip takes. 3200, the arrival's own duration: they are the module's two long set pieces and a flip that outran the arrival would read as a different animation. It is also what the two millisecond numbers below are measured against.",
            val: 3200,
            from: 600,
            to: 9000,
            step: 50
        },
        {
            label: "turns",
            prop: "flipTurns",
            group: "The flip",
            tip: "How many turns it makes. 4.5 -- 1620 degrees -- so the record lands on its OTHER SIDE, which is the point of turning it over at the half of an album.",
            val: 2.5,
            from: 0.5,
            to: 8,
            step: 0.5
        },
        {
            label: "lift height",
            prop: "liftFrac",
            group: "The flip",
            tip: "How far the record rises at the apex, as a fraction of its own size. A fraction rather than pixels because the same choreography has to read at 118 px in mini and at 340 in player.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "axis variance",
            prop: "flipAxisVariance",
            group: "The flip",
            tip: "How far the flip's axis may wander off the x axis, in degrees. Both ends are drawn when the flip starts and interpolated across it, so the wander is as slow as it can be, never repeats, and never jumps.",
            val: 15,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "end ramps",
            prop: "flipEndEase",
            group: "The flip",
            tip: "How wide the ramp at each END of the flip is, as a fraction of it. The record is next to the platter there and must not snap into the turn or out of it: the speed is zero at both ends and these two smoothsteps widen that into a ramp you can watch.",
            val: 0.4,
            from: 0.02,
            to: 0.5,
            step: 0.01
        },
        {
            label: "slow motion at ms",
            prop: "flipSlowStartMs",
            group: "The flip",
            tip: "When the slow motion sets in, in ms from the start of the flip. In milliseconds rather than as a fraction because that is how it is judged ('it ends half a second too soon') -- and it then keeps its timing when the flip's duration changes.",
            val: 1080,
            from: 0,
            to: 6000,
            step: 10
        },
        {
            label: "slow motion ms",
            prop: "flipSlowMs",
            group: "The flip",
            tip: "How long it lasts. The record is highest inside this window rather than at the middle of the flip: the apex is read at the window's own centre, so the two are the same instant by construction.",
            val: 942,
            from: 0,
            to: 6000,
            step: 10
        },
        {
            label: "slow motion speed",
            prop: "flipSlowFactor",
            group: "The flip",
            tip: "How slowly the record turns inside that window, as a fraction of its normal speed. This is the moment the user is given to admire it, so it is the one number that decides whether the flip is playful or just fast.",
            val: 0.075,
            from: 0.02,
            to: 1,
            step: 0.005
        },
        {
            label: "slow edge in ms",
            prop: "flipSlowEdgeInMs",
            group: "The flip",
            tip: "How gradually the slow motion is ENTERED. Shorter than the way out: the record drops into slow motion and is then let go of, which is what makes the apex read as a held moment rather than one long ease.",
            val: 230,
            from: 5,
            to: 1500,
            step: 5
        },
        {
            label: "slow edge out ms",
            prop: "flipSlowEdgeOutMs",
            group: "The flip",
            tip: "How gradually it is LEFT. Wider than the way in, so the record picks its speed back up over the second half of the turn instead of snapping out of the well.",
            val: 420,
            from: 5,
            to: 1500,
            step: 5
        },
        {
            label: "apex on a face",
            prop: "flipApexOnFace",
            group: "The flip",
            tip: "Whether the slow-motion window is placed against the RECORD or by the clock. On, it slides to the nearest moment the record has turned a whole number of times since the flip began, so the record is held up FACE-ON -- the side it left the platter on -- with the edge-on crossings, where the apparent spin reverses, half a turn away in both directions; 1080 ms nominal is placed at 1025. Off is round 3's placement: the apex fell on a hairline edge-on sliver and the direction change was dragged into the slow motion with it.",
            val: true
        },
        {
            label: "slide ms",
            prop: "sleeveSlideMs",
            group: "The sleeve",
            blurb: "A sleeve pushed across a smooth table does not overshoot its mark and spring back: it decelerates to a stop under friction, so there is no OutBack anywhere near it. One clock, from which both the travel and the turn are read.",
            tip: "How long a slide takes, in or out. Slow enough to watch it come to rest.",
            val: 1050,
            from: 200,
            to: 3000,
            step: 10
        },
        {
            label: "friction",
            prop: "slideFriction",
            group: "The sleeve",
            tip: "The friction law. 2 is ideal Coulomb friction -- a velocity falling linearly to zero; above it the sleeve covers more of the distance early and creeps the last of the way, which is what card on wood does.",
            val: 2.4,
            from: 1.05,
            to: 6,
            step: 0.05
        },
        {
            label: "turn lag",
            prop: "slideRotGrip",
            group: "The sleeve",
            tip: "How far the sleeve's TURN lags its travel, 0..1: at 1 half the rotation is still to come when it has covered four fifths of its distance, so the last of it happens while the sleeve is barely moving. It is a shape and not the physical law, because the physical law is invisible -- with the turn proportional to the table's real grip, MEASURED over this slide, 3.4% of the rotation was left in the last 30% of the time. Half a degree. What reads is the lag.",
            val: 0.75,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "sleeve oversize",
            prop: "sleeveOversize",
            group: "The sleeve",
            tip: "How much bigger the sleeve is than the record it holds. A real 12 inch LP goes into a 12.375 inch sleeve, which is this to three figures -- and it has to be bigger, because the record is hidden GEOMETRICALLY until the sleeve moves rather than faded in.",
            val: 1.031,
            from: 1.0,
            to: 1.3,
            step: 0.001
        },
        {
            label: "put-away lift",
            prop: "putAwayLiftFrac",
            group: "The sleeve",
            tip: "How high the record is held while it is fired into the sleeve, of its own size. It is a knob and not a number because it decides the SLEEVE'S size: a lifted record is nearer the camera and is drawn bigger, and the sleeve is measured against the record AS FLUNG so it can swallow it without the record shrinking to fit.",
            val: 0.12,
            from: 0,
            to: 0.5,
            step: 0.005
        },
        {
            label: "settle angle",
            prop: "sleeveSettleRot",
            group: "The sleeve",
            tip: "The angle a sleeve keeps once it has stopped, in degrees. Nothing pushed across a table ends square with the world, and the put-away already stopped crooked; 3 gives the arrival the same courtesy. ONE number for both: each sleeve keeps this much of the tilt it arrived with, so the sign is the approach's -- the put-away comes in from the right turned clockwise and settles clockwise, the arrival from the left and settles anticlockwise.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "sleeve exit ms",
            prop: "sleeveExitMs",
            group: "The sleeve",
            tip: "How long the sleeve takes to LEAVE, once the record inside it is on its way off. It is its own motion now: the old sleeve used to be cut off mid-slide the instant the next album was called for, which the user read as the put-away being aborted.",
            val: 560,
            from: 120,
            to: 2000,
            step: 20
        },
        {
            label: "hand-over overlap",
            prop: "handoverOverlap",
            group: "The sleeve",
            tip: "How much of the leaving sleeve may still be on the stage when the next record is called for, as a fraction of the sleeve's own width. 0 is the rule the user asked for -- off the scene, then the next one; 1 is round 5's behaviour, the cut.",
            val: 0,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "album restart fall",
            prop: "albumRestartFall",
            group: "The flip",
            tip: "How far the album's progress must FALL to count as the album starting over, as a fraction of where it was. A restart turns the record back to side A, whatever caused it -- repeat all wrapping, a prev at the first song, a queue rebuilt in place -- so the flip is a fact about the progress rather than a case the host has to recognise. 0.5 is \"at most half of it\": the first song of a run of any length is, and a step back inside one never is.",
            val: 0.5,
            from: 0.05,
            to: 0.95,
            step: 0.05
        },
        {
            label: "mouth guard",
            prop: "mouthGuard",
            group: "The sleeve",
            tip: "Clearance between the record and the sleeve's two LONG edges, in px -- the bite the chewed rim takes out of its own edge. A rotated rectangle covers less of a circle than a square one does, so a sleeve that clears the record standing still can let it through while it is turning. Since round 4 that is answered with the approach's ANGLE rather than by dropping the sleeve, so it costs no travel at all any more: it comes off the tilt the sleeve is allowed instead. 2 px leaves 1.33 px of record inside the mouth at the tightest frame of the popup's put-away, 0.31 px of mini's. Do not raise it far -- mini's whole clearance is 1.64 px.",
            val: 2.0,
            from: 0,
            to: 8,
            step: 0.5
        },
        {
            label: "mouth tilt safety",
            prop: "mouthTiltSafety",
            group: "The sleeve",
            tip: "How much of the tilt its mouth can actually hold the sleeve is allowed to take at rest. A sleeve is a real 12.375 inch to a real 12 -- three per cent, six and a half pixels at the popup's own size -- and a sleeve lying off square carries the record that far off its centre line the moment its mouth is over it, so it cannot lie more than 1.7 degrees off square and still hold its record. That is the sleeve's own proportions talking, not a taste. This keeps a fifth of the margin back on top of it: the put-away settles at 1.40 degrees with 1.33 px of record still inside the mouth at its tightest frame. A crookeder settle wants a roomier sleeve, not this.",
            val: 0.8,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "mouth turn window",
            prop: "mouthTurnFrac",
            group: "The sleeve",
            tip: "Where the sleeve has finished turning, measured against the moment its mouth reaches the record's centre. The whole of round 4 is in this number: the sleeve has to be DONE turning before its mouth closes over the record, so it enters the stage at about ten degrees, straightens as it slides, and pushes the last third home square -- instead of being shoved 36 px downwards mid-slide to keep the record covered, which is the dive that read as a kink. Above 1 it is still turning while the mouth closes and the record shows: the kink. An arrival carries its record at its own centre, so it keeps the whole slide to turn in whatever this says.",
            val: 0.9,
            from: 0.3,
            to: 1.5,
            step: 0.05
        },
        {
            label: "mouth ride",
            prop: "mouthRideFrac",
            group: "The sleeve",
            tip: "The most the sleeve may ride off the record's own line, of the record's diameter, when the angle alone cannot cover it. A backstop for a geometry this was never measured at, not the mechanism: at the popup's 536x527 and at mini's 456x142 the fit spends exactly zero of it and the sleeve's path is a straight horizontal line. 0 takes the backstop away, which is one of the two ways the covering proof is armed.",
            val: 0.06,
            from: 0,
            to: 0.2,
            step: 0.005
        },
    ]

    // ---- the platter it is played on -------------------------------------

    readonly property var turntableParams: [
        {
            label: "mat ring",
            prop: "matRingFrac",
            group: "The platter",
            blurb: "The platter is a GUI element and does not pretend to be a 3D object: the shell's header box carved into the card, wearing the two marks that make a circle read as a turntable. Its size and its spindle are measured from the record, on Motion -> Platter.",
            tip: "The mat's ring, across, as a fraction of the platter. 0.86 is where a record's grooves end -- the same radius the sleeve carries the record's impression at, so the three objects agree about the record.",
            val: 0.86,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "strobe dots",
            prop: "strobeDots",
            group: "The platter",
            tip: "How many dots run round the rim. They are the one mark that says 'turntable' at a glance, and the only reason this is not just a sunk circle. Engraved, not printed: they take the divider colour in both modes.",
            val: 36,
            from: 0,
            to: 90,
            step: 1
        },
        {
            label: "strobe ring",
            prop: "strobeRingFrac",
            group: "The platter",
            tip: "How far out those dots sit, of the platter's radius. Just inside the edge, where a real strobe ring is printed.",
            val: 0.955,
            from: 0.5,
            to: 1,
            step: 0.005
        },
        {
            label: "cap dome",
            prop: "pinCapDome",
            group: "The spindle",
            blurb: "The camera looks straight down the record's axis, so the spindle is a CIRCLE -- the top of a turned rod -- and not a rod drawn in elevation. Its size is measured from the record's hole and is not a knob; everything it is MADE of is here.",
            tip: "The cap's height as a fraction of its radius: 0 a flat disc, 1 a hemisphere. This is what makes the circle read as the end of a rod rather than as a dot -- one bright side, one dark side, a rolled rim.",
            val: 0.22,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "brush along",
            prop: "pinBrushAlong",
            group: "The spindle",
            tip: "GGX roughness ALONG the turning marks, which run around the circle. It is the SHARP direction -- small keeps the highlight as two opposed arcs lying on the light's azimuth instead of one round blob. The same pair, and the same law, as the record's own grooves at a hundredth of the radius.",
            val: 0.14,
            from: 0.01,
            to: 1,
            step: 0.01
        },
        {
            label: "brush across",
            prop: "pinBrushAcross",
            group: "The spindle",
            tip: "And across them, radially: the SMEARED direction. The gap between the two is the whole of the anisotropy, and the anisotropy is what says machined -- measured, it is worth 23 levels of 255 on a 6 px cap, where the turning marks themselves were worth none at that size and are therefore not knobs.",
            val: 0.30,
            from: 0.01,
            to: 1,
            step: 0.01
        },
        {
            label: "cap tone",
            prop: "pinNeutral",
            group: "The spindle",
            tip: "Where the cap sits on the shell's raised ramp with no room and no lamp: 0.5 is exactly the button plateau, 1 the bevel above it, 0 the button shadow below. The cap is shaded on that ramp rather than as a metal reflecting a coloured room, because a real reflectance squares a near-black plateau in dark mode and the pin came back darker than the mat it stands on -- measured at 10-19 of 255 against a platter at 40, which reads as a hole punched in the platter.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "room swing",
            prop: "pinEnv",
            group: "The spindle",
            tip: "How far the room swings that tone, sky against ground. It is what gives the dome its light half and its dark half before any highlight lands.",
            val: 0.85,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "highlight",
            prop: "pinSpec",
            group: "The spindle",
            tip: "How far the specular arcs push the tone up. Chosen by rendering 0.55, 1.1 and 1.8 side by side and looking: 0.55 is too quiet to read as machined and 1.8 washes the dome out.",
            val: 1.1,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "light angle",
            prop: "lightAngleDeg",
            group: "Its light",
            blurb: "The key light, built exactly the way the record's is and defaulting to the same two numbers, so the pin and the record are lit by ONE lamp without anything having to wire them together.",
            tip: "The key's azimuth in degrees. The brushed arcs lie along it, so this is also which way round the cap's two highlights sit. 122 is the record's own key: move one and the other should move with it or the two objects stop agreeing about where the room is.",
            val: 122,
            from: 0,
            to: 360,
            step: 1
        },
        {
            label: "light elevation",
            prop: "lightElevation",
            group: "Its light",
            tip: "How high that key stands, 0 at the horizon and 1 straight overhead. It sets how long the pin's shadow across the mat is, as well as how the cap is lit. 0.52, the record's.",
            val: 0.52,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shadow strength",
            prop: "pinShadowStrength",
            group: "Its shadow on the mat",
            blurb: "The shadow the pin lays ACROSS THE MAT -- distinct from the one it lays on the record's label, which is the record's own texture and lives on Record -> Light. A penumbra is set by the distance between the point casting the shadow and the surface catching it, and along this shadow that distance runs from zero at the pin's foot to a whole pin length at its tip: so it is nearly sharp where it starts and soft where it ends, with nothing switching between the two.",
            tip: "How dark it is at its darkest. The record is wider than the platter and hides this shadow completely once it is down -- what it is for is the handful of frames at the end of the drop, where a shadow that shortens and hardens is the only thing that says there is a pin standing there at all.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "penumbra at foot",
            prop: "pinPenumbraBase",
            group: "Its shadow on the mat",
            tip: "How soft the shadow is where the pin meets the mat, in px. A contact, so nearly sharp: 0.6 is about one antialiased edge and no more.",
            val: 0.6,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "penumbra at tip",
            prop: "pinPenumbraGrow",
            group: "Its shadow on the mat",
            tip: "And how much softer it gets per px of pin height, by the time it reaches the tip. This is the knob that makes the softness a GRADIENT along the shadow rather than one blur over all of it.",
            val: 0.20,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "drain to the tip",
            prop: "pinShadowFade",
            group: "Its shadow on the mat",
            tip: "How much of its darkness the shadow also gives up on the way out. A penumbra that widens without draining reads as a smear; 0.45 loses it just under half its strength by the tip.",
            val: 0.45,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shade depth",
            prop: "pinDarkenStrength",
            group: "The record's shade",
            blurb: "A record hanging just above the spindle occludes almost the whole sky the cap can see, so the cap goes flat and dark before anything with an outline touches it. It is darkest at the instant the record's underside is level with the top of the pin, and dies within a few frames of the record descending past it -- which is the moment the pin comes back out through the hole and can see the room again. HOW LONG that takes is derived from the pin's own length and is deliberately not a knob: a panel write would break it away from the length the stage sets.",
            tip: "How far DOWN the material's ramp the record overhead pulls the cap. 0.5 is exactly the distance from the plateau to the button shadow, so at that one instant the cap wears the shell's deepest tone and nowhere else in the drop does it reach it.",
            val: 0.50,
            from: 0,
            to: 1,
            step: 0.01
        }
    ]

    // ---- the viewfinder --------------------------------------------------

    readonly property var railParams: [
        {
            label: "Music sparks",
            prop: "musicSparksEnabled",
            group: "The music",
            blurb: "Sparks the music itself throws: a baseline while it plays, more when loud, a burst on a beat.",
            tip: "The music's own budget: a sparse baseline while a track plays, more when it is loud, a burst on every beat. Off leaves only the per-pixel budget, which buys about one spark a second for a whole track -- the round-3 behaviour the user called flat.",
            val: true
        },
        {
            label: "Baseline / s",
            prop: "musicSparkPerSec",
            group: "The music",
            tip: "Sparks a second while a track plays, whatever the music is doing. The thing that never stops. 0.5 is about one spark every other second -- two in the air, since a spark lives 0.7-1.7 s.",
            val: 0.2,
            from: 0,
            to: 4,
            step: 0.1
        },
        {
            label: "Peak / s",
            prop: "musicPeakSparkPerSec",
            group: "The music",
            tip: "The rate at loudness 1. 1.4 rather than the 3.0 this started at: filmed against a real track, 3.0 put a cloud round the ball in every frame of the tile.",
            val: 2.2,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "Loudness curve",
            prop: "musicRateGamma",
            group: "The music",
            tip: "Bends the rate away from the middle, so a loud passage reads as an event rather than as the normal state. The tap's own distribution is already bottom-heavy (median 0.10, p75 0.83 on a real track), so this stays gentle.",
            val: 1.9,
            from: 0.5,
            to: 3,
            step: 0.1
        },
        {
            label: "Loud speed gain",
            prop: "musicSpeedGain",
            group: "The music",
            tip: "How much faster a spark leaves at full loudness, as a fraction of the scatter. 0.5 is half again.",
            val: 0.5,
            from: 0,
            to: 3,
            step: 0.1
        },
        {
            label: "Beat sparks",
            prop: "musicBeatSparks",
            group: "The music",
            tip: "The burst on an onset at full strength; a weak beat still throws a third of it, because a beat that shows nothing is not a beat.",
            val: 3,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "Beat speed gain",
            prop: "beatSpeedGain",
            group: "The music",
            tip: "How much faster a full beat's sparks leave than a baseline one. This is the user's 'maybe even faster particles'.",
            val: 1.0,
            from: 0,
            to: 3,
            step: 0.1
        },
        {
            label: "Ceiling in the air",
            prop: "musicMaxInAir",
            group: "The music",
            tip: "No music spark is emitted while this many are already alive. The rail is not the centrepiece -- the record is. Travel is not capped by it: a scrub is the user's own hand.",
            val: 10,
            from: 2,
            to: 40,
            step: 1
        },
        {
            label: "Music clock ms",
            prop: "musicSampleMs",
            group: "The music",
            tip: "How often the time budget is paid out. The remainder is carried, so a slower clock than the tap's 15.6 Hz costs nothing but wakeups; beats do not wait for it.",
            val: 100,
            from: 30,
            to: 300,
            step: 10
        },
        {
            label: "scale",
            prop: "sizeScale",
            group: "Groove",
            blurb: "The rail the spec asks for: the system update's, with two ball slots instead of a notch per step, and a ball you can drag.",
            tip: "Scales the whole rail -- groove, ball, edge padding and every spark with it. One number, so the rail cannot get out of proportion with itself.",
            val: 1.2,
            from: 0.4,
            to: 3,
            step: 0.05
        },
        {
            label: "groove thickness",
            prop: "lineThickness",
            group: "Groove",
            tip: "How thick the engraved channel is. 6 is the shell's rail.",
            val: 7,
            from: 1,
            to: 20,
            step: 0.5
        },
        {
            label: "slot size",
            prop: "dotSize",
            group: "Groove",
            tip: "The two ball slots, one at each end -- the start of the track and its end. 13 is a slot the 15 px ball settles into rather than sits on.",
            val: 11,
            from: 2,
            to: 30,
            step: 0.5
        },
        {
            label: "edge padding",
            prop: "edgePadding",
            group: "Groove",
            tip: "How far the groove stops short of the rail's own edge, so the end slot is not cut in half by the card. The track info block hands out its elapsed figure's slot width so the host can line the two up.",
            val: 20,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "groove bevel width",
            prop: "grooveBevelWidth",
            group: "Groove",
            tip: "The carve the ball runs in: a light bevel outside the edge and an inset shadow inside it, the same two marks every carved container in the shell wears. The lip of the surface OUTSIDE the groove's edge, in px before the list scale. 2 is the shell's carved-container bevel. The colour is a theme token and is tuned on the Popup tab -- a hex left here would look right in light mode and break the dark one.",
            val: 2,
            from: 0,
            to: 8,
            step: 0.5
        },
        {
            label: "groove inset shadow",
            prop: "grooveShadowWidth",
            group: "Groove",
            tip: "How deep the shadow reaches INSIDE the groove's edge, in px before the list scale. 3 is the shell's container inset; the buttons use 5. Wider reads as a deeper channel, and past about 5 the fill stops looking like it sits in the groove at all.",
            val: 3,
            from: 0,
            to: 10,
            step: 0.5
        },
        {
            label: "ball size",
            prop: "ballSize",
            group: "Ball",
            blurb: "The viewfinder itself: drag it to seek, and the record turns with it because the record's angle IS the position.",
            tip: "The ball's resting diameter, before the groove flattens it. 15 against the channel's 6: it has to read as a thing lying IN the groove, which needs it to be more than twice the channel deep.",
            val: 13,
            from: 4,
            to: 40,
            step: 0.5
        },
        {
            label: "flatten ceiling",
            prop: "ballFlatStretchMax",
            group: "Ball",
            tip: "How far the ball may spread along the rail from being squeezed into the channel alone, in diameters, before any scrub stretch. A ball pressed into a 7 px groove has to go somewhere, and area is conserved. 2.5 is PhaseRail's own ceiling, and it is a ceiling rather than a target: the flatten only reaches it where the channel is at its narrowest.",
            val: 1.1,
            from: 1,
            to: 4,
            step: 0.05
        },
        {
            label: "groove bleed",
            prop: "ballGrooveBleed",
            group: "Ball",
            tip: "How far the flattened ball overshoots the channel, in px. Matching the groove's thickness exactly leaves the groove's darker edge showing as a hairline above and below the ball, because both shapes are antialiased and each gives up part of its outermost pixel. PhaseRail's number, for PhaseRail's reason.",
            val: 1.0,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "stretch ceiling",
            prop: "ballStretchMax",
            group: "Ball",
            tip: "How much longer again a full-speed scrub makes it, in multiples of the length it already has. It only ever gets LONGER: across the rail the ball stays flush with the groove's edges whatever it is doing, so the stretch can never thin it into a smear.",
            val: 3,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "stretch speed",
            prop: "ballStretchSpeedRef",
            group: "Ball",
            tip: "The scrub speed, in px/ms, that reaches that ceiling. 2 px/ms crosses a 320 px rail in about a sixth of a second, so ordinary seeking never sits at the ceiling and a fling still gets there.",
            val: 0.8,
            from: 0.2,
            to: 8,
            step: 0.1
        },
        {
            label: "stretch settle ms",
            prop: "ballStretchMs",
            group: "Ball",
            tip: "The one clock the stretch moves on: how long it takes to reach and to leave its target. 130 ms is under a seventh of a second either way, so the ball answers a change of speed inside the gesture rather than after it.",
            val: 130,
            from: 20,
            to: 500,
            step: 5
        },
        {
            label: "shadow opacity",
            prop: "ballShadowOpacity",
            group: "Ball",
            tip: "The contact shadow under the ball, which is what makes it read as sitting in the groove rather than on it.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "shadow blur",
            prop: "ballShadowBlur",
            group: "Ball",
            tip: "How soft that shadow is. 12 px under a 15 px ball: wide enough to read as contact inside a channel, short of a second ball drawn underneath it.",
            val: 12,
            from: 0,
            to: 40,
            step: 0.5
        },
        {
            label: "fill darken",
            prop: "fillDarken",
            group: "Ball",
            tip: "How much darker the played part of the groove is than the accent. The colour of progress is one colour darkened, not a second token.",
            val: 1.4,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "fill shadow darken",
            prop: "fillShadowDarken",
            group: "Ball",
            tip: "And how much darker again its own inset shadow is. Both are FACTORS off the live tone rather than colours, so the pair keeps following the accent -- and therefore the theme -- instead of freezing at a hex.",
            val: 1.9,
            from: 1,
            to: 4,
            step: 0.05
        },
        {
            label: "ball lighten",
            prop: "ballLighten",
            group: "Ball",
            tip: "How much lighter the ball is than the fill it rides on. 1.12 is a hair, on purpose: the ball is the same accent as the fill and is told apart by its shape and its shadow, not by being a second colour.",
            val: 1.12,
            from: 1,
            to: 2,
            step: 0.01
        },
        {
            label: "hover fade ms",
            prop: "hoverFadeMs",
            group: "Ball",
            tip: "The short colour fade under the pointer. Nothing else announces that the rail can be grabbed -- that, and the hand cursor.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "ball show ms",
            prop: "ballShowMs",
            group: "Ball",
            tip: "How long the ball takes to scale away from its own centre when nothing is playing, and to come back when something does. 160 is the shell's presence fade; one fraction, one easing, no overshoot. WHETHER it is there is not a knob -- the popup binds it to the same flag it puts the track's skeleton up with, since a rail with no playhead to point at and the groove alone, already the skeleton's own shade, is the honest picture.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "travel ms",
            prop: "travelMs",
            group: "Seeking",
            blurb: "What happens when the ball is asked to go somewhere rather than dragged there.",
            tip: "How long the ball takes to reach a point that was clicked, or the far end when a new track starts.",
            val: 420,
            from: 60,
            to: 1200,
            step: 10
        },
        {
            label: "travel floor ms",
            prop: "travelMinMs",
            group: "Seeking",
            tip: "The shortest that travel may be, so a tiny correction is still a movement rather than a jump.",
            val: 140,
            from: 20,
            to: 600,
            step: 10
        },
        {
            label: "jump threshold s",
            prop: "travelSeekSec",
            group: "Seeking",
            tip: "How big a position change counts as a JUMP -- a seek, or a new track -- rather than playback creep. A jump makes the ball travel; anything under it and the ball simply is there. In SECONDS, so the same music reads the same way on a two-minute track and a ten-minute one.",
            val: 1.5,
            from: 0.1,
            to: 10,
            step: 0.1
        },
        {
            label: "drag deadzone",
            prop: "dragDeadzone",
            group: "Seeking",
            tip: "How far the pointer must move before a press becomes a drag rather than a click. Below it, letting go seeks to where you pressed.",
            val: 3,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "answer window ms",
            prop: "seekAnswerMs",
            group: "Seeking",
            tip: "How long the rail keeps showing the position it asked for rather than the one the daemon reports. MPD answers a seek in its own time, and without this the ball snaps back for one frame before the answer lands.",
            val: 2000,
            from: 200,
            to: 6000,
            step: 100
        },
        {
            label: "answer margin s",
            prop: "seekSettleSec",
            group: "Seeking",
            tip: "How close the reported position must come to the requested one before the rail believes the seek has landed. 1.5 s is the jump threshold above it: a source that lands inside the distance the rail would not have travelled for has answered.",
            val: 1.5,
            from: 0.1,
            to: 8,
            step: 0.1
        }
    ]

    // The measurement the music's sparks are read from: the tap turns MPD's
    // own output into one number, and these are what that number means.
    readonly property var tapParams: [
        {
            label: "Span dB",
            prop: "spanDb",
            group: "Level tap",
            blurb: "How the level tap turns the sound into a loudness and its beats.",
            tip: "How far above the running floor counts as full loudness. Music's dynamics inside a passage are 10-20 dB; at 14 a real track measures median 0.10 and p75 0.83 -- a signal that rests and rises rather than one that sits high.",
            val: 14,
            from: 4,
            to: 30,
            step: 1
        },
        {
            label: "Floor fall ms",
            prop: "floorFallMs",
            group: "Level tap",
            tip: "How fast a new quiet is believed. This is what makes the measure scale-free: a volume drop moves the floor with the signal, and the 12 dB drop from 100% to 20% is recovered in 0.1 s.",
            val: 1500,
            from: 200,
            to: 8000,
            step: 100
        },
        {
            label: "Floor rise ms",
            prop: "floorRiseMs",
            group: "Level tap",
            tip: "How slowly the floor is left once the music gets loud, so a whole loud passage does not normalise itself back to nothing.",
            val: 20000,
            from: 2000,
            to: 60000,
            step: 1000
        },
        {
            label: "Beat threshold",
            prop: "beatFluxRatio",
            group: "Level tap",
            tip: "How many times bigger than the normal jump a jump has to be to be a beat. At 2.5 a dense track fires 1.8 onsets a second, which with a burst on each is a shower; at 3.0 it is about 1.2 and they read as hits.",
            val: 3.0,
            from: 1.2,
            to: 8,
            step: 0.1
        },
        {
            label: "Beat gap ms",
            prop: "beatMinGapMs",
            group: "Level tap",
            tip: "Refractory: one hit is one beat. 600 ms holds a dense track to about 1.1 a second, which is where the bursts stop merging into a stream.",
            val: 600,
            from: 120,
            to: 1500,
            step: 20
        },
    ]

    readonly property var railSparks: [
        {
            label: "scrub per px",
            prop: "scrubSparkPerPx",
            group: "Rate",
            blurb: "Sparks are bought with DISTANCE, not speed. That is the whole of the spec's 'the same amount whatever the track's length': measured, a ten-minute track and a two-minute one threw 45 and 46 for the same drag.",
            tip: "Sparks per pixel the ball travels under a finger. The fraction left over is carried, so a slow drag pays out at the same rate as a fast one.",
            val: 0.35,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "playback per px",
            prop: "playSparkPerPx",
            group: "Rate",
            tip: "The rate while the music simply plays, at FULL loudness. Measured, not guessed: at 1.4 a 320 px rail throws about one spark a second at silence and two at a peak on a four-minute track -- one or two in the air at any moment, present rather than busy.",
            val: 1.4,
            from: 0,
            to: 4,
            step: 0.05
        },
        {
            label: "playback floor",
            prop: "playSparkFloor",
            group: "Rate",
            tip: "The share of that rate playback pays whatever the music is doing; loudness buys the rest. At 0 this is round 1's law -- the rate IS the loudness -- and a host with no level tap wired then plays a whole track without a spark, which is exactly what it did.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "new track scale",
            prop: "newTrackSparkScale",
            group: "Rate",
            tip: "The end-to-end sweep when a new track starts is quieter than a scrub of the same length: this multiplies the scrub rate above, so at 0.35 a sweep costs about a third of the drag it looks like. The user did not do it, so it should not sound as though they had.",
            val: 0.35,
            from: 0,
            to: 2,
            step: 0.01
        },
        {
            label: "burst ceiling",
            prop: "sparkMaxPerSample",
            group: "Rate",
            tip: "The most sparks one frame may emit. A fling across a long rail would otherwise empty the pool in a frame and starve the rest of the drag.",
            val: 12,
            from: 1,
            to: 60,
            step: 1
        },
        {
            label: "pool",
            prop: "maxParticles",
            group: "Rate",
            tip: "How many sparks can be alive at once. Read ONCE, when the pool is built, so moving it now changes nothing: save it into the mockup and reopen. A full-rail fling at the default rate is about 105 in the air at once, and emit silently DROPS past the ceiling, so it is sized for the worst gesture rather than the usual one.",
            val: 700,
            from: 40,
            to: 1000,
            step: 10
        },
        {
            label: "inherited speed",
            prop: "sparkBaseVelocity",
            group: "Shape",
            blurb: "What a spark looks like. Speed shapes it; distance decides how many there are.",
            tip: "How much of the ball's own velocity a spark is thrown backwards with. A tenth: enough that the spray trails the ball instead of travelling with it. PhaseRail's number, so a spark here is the shell's spark.",
            val: 0.1,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "scatter",
            prop: "sparkScatter",
            group: "Shape",
            tip: "Random velocity added on top, in px/s. This is what fans the shower out instead of firing one tight jet backwards; 100 spreads it without throwing sparks off the card. PhaseRail's number.",
            val: 110,
            from: 0,
            to: 500,
            step: 5
        },
        {
            label: "lifetime ms",
            prop: "sparkLifetimeBase",
            group: "Shape",
            tip: "How long a spark lives before it starts to die. There is always a further 250 ms of fade on top.",
            val: 700.0,
            from: 50,
            to: 2000,
            step: 10
        },
        {
            label: "lifetime variance",
            prop: "sparkLifetimeVariance",
            group: "Shape",
            tip: "How much that lifetime varies: up to 1000 ms on top of the 700 base, so a shower thins out over about a second rather than all going at the same instant.",
            val: 1000.0,
            from: 0,
            to: 2000,
            step: 10
        },
        {
            label: "trail length",
            prop: "sparkMaxHistory",
            group: "Shape",
            tip: "How many samples of trail a spark keeps. Counted in TICKS of about 16 ms, not in pixels: 8 is roughly 128 ms of streak.",
            val: 6,
            from: 1,
            to: 20,
            step: 1
        },
        {
            label: "size at birth",
            prop: "sparkSizeStart",
            group: "Shape",
            tip: "The stroke width a spark starts at. 3 px -- sparks are chunkier than a haze because they are debris. PhaseRail's number, so both rails in the shell throw the same spark.",
            val: 3.0,
            from: 0.5,
            to: 10,
            step: 0.1
        },
        {
            label: "size at death",
            prop: "sparkSizeEnd",
            group: "Shape",
            tip: "And what it tapers to: a third of its birth width, so a spark thins as it slows instead of only fading.",
            val: 1.0,
            from: 0,
            to: 10,
            step: 0.1
        },
        {
            label: "drag",
            prop: "sparkDrag",
            group: "Shape",
            tip: "Air resistance, per second. High and they slow quickly and drop by the rail; low and they fly far. 2 keeps the spray inside the overscan the card actually has.",
            val: 2.6,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "swirl strength",
            prop: "sparkSwirlStr",
            group: "Shape",
            tip: "The late-life curl that keeps a spark from dying in a straight line. The shell's own spark shape, shared with the workspaces and the volume slider.",
            val: 0.4,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "swirl chance",
            prop: "sparkSwirlProb",
            group: "Shape",
            tip: "What fraction of sparks get that curl. All of them reads as a pattern; none reads as a jet.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "spark size scale",
            prop: "particleSizeScale",
            group: "Shape",
            tip: "Scales every spark's stroke without changing how many there are or how far they go. It is separate from the rail's own scale so a big rail can keep fine sparks.",
            val: 1.0,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "glow speed",
            prop: "glowSpeedRef",
            group: "Glow",
            blurb: "A fast spark flares. This is what makes a fling look violent and a creep look calm without changing the count.",
            tip: "The speed, in px/s, at which a spark's glow is at full strength. 2600 is far above anything playback reaches -- creep samples about 2 px/s -- so only a scrub or a fling flares, which is the whole point of the glow.",
            val: 2600,
            from: 200,
            to: 6000,
            step: 50
        },
        {
            label: "glow max",
            prop: "glowMax",
            group: "Glow",
            tip: "How much brighter a spark at that speed is: 2.6x its normal opacity, clamped at fully opaque. 1 would be no brightening at all.",
            val: 2.6,
            from: 1,
            to: 6,
            step: 0.1
        },
        {
            label: "glow size gain",
            prop: "glowSizeGain",
            group: "Glow",
            tip: "And how much fatter: 0.7 is 70% wider at that speed, on top of the birth-to-death taper. These draw as trails, so it is the streak's own line width.",
            val: 0.7,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "bloom blur",
            prop: "bloomBlur",
            group: "Bloom",
            blurb: "A blurred copy drawn over the sparks, not instead of them -- that is what makes it a glow rather than a smudge.",
            tip: "The blur radius of that copy. Large is soft and hazy, small keeps the streaks crisp; 22 is the shell's, shared with the system update's rail so the two glow alike.",
            val: 6,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "bloom strength",
            prop: "bloomStrength",
            group: "Bloom",
            tip: "How much of the blurred copy is added. 0 switches the bloom off entirely; 0.32 reads as a glow around a spark rather than as a second spark drawn over it.",
            val: 0.32,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "bloom brightness",
            prop: "bloomBrightness",
            group: "Bloom",
            tip: "0.85 on the light surface. The dark mockups use 1.2, and copying that number into a light popup blows the sparks out.",
            val: 0.8,
            from: 0.2,
            to: 2,
            step: 0.05
        },
        {
            label: "overscan",
            prop: "particleMargin",
            group: "Bloom",
            tip: "How far outside the rail the particle canvas reaches. A Canvas clips to its own bounds and anything drawn past them is simply gone, so the canvas is grown and the overflow is FADED instead of cut. The host overrides each side of it with the room the card actually has.",
            val: 46,
            from: 0,
            to: 120,
            step: 2
        },
        {
            label: "edge fade",
            prop: "particleFadeWidth",
            group: "Bloom",
            tip: "How wide that fade is at the overscan's boundary: alpha is zero on the line and full 18 px inside it. Wide enough that the fade is not itself a visible edge, short enough that a spark is still bright where the eye is.",
            val: 18,
            from: 0,
            to: 60,
            step: 1
        }
    ]

    // ---- the chrome ------------------------------------------------------

    readonly property var transportParams: [
        {
            label: "button size",
            prop: "buttonSize",
            group: "Transport",
            blurb: "The classic row: shuffle, previous, play, next, repeat -- and the burger that opens the queue, with the expand/collapse that switches view beside it. Buttons stand PROUD of the surface; everything else in the shell is carved into it.",
            tip: "The diameter of a transport button. The play button is the same size as the others and only differs by being the accent one; the glyph and the corner are read from it, so this is the only size number the row has.",
            val: 38,
            from: 20,
            to: 72,
            step: 1
        },
        {
            label: "spacing",
            prop: "spacing",
            group: "Transport",
            tip: "Between two buttons. 10 against a 38 px button: the row is one control, and a gap as wide as a third of a button would break it into groups.",
            val: 10,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "shadow width",
            prop: "shadowWidth",
            group: "Transport",
            tip: "The drop shadow a raised button casts, in px. 5 for a button, against 3 for a carved container -- the two spreads are tuned separately on purpose.",
            val: 5,
            from: 0,
            to: 16,
            step: 0.5
        },
        {
            label: "shadow edge",
            prop: "shadowEdgeAlpha",
            group: "Transport",
            tip: "How dark that shadow is AT the button's own edge -- its depth, where the width above is its reach. A press scales this down, which is what makes a button go flat under the finger instead of sliding.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "bevel width",
            prop: "bevelWidth",
            group: "Transport",
            tip: "The highlight inside a raised button's edge. 1.5, against 1 on a container: a highlight is a thin line, a shadow spreads.",
            val: 1.5,
            from: 0,
            to: 8,
            step: 0.25
        },
        {
            label: "toggle ms",
            prop: "toggleMs",
            group: "Transport",
            tip: "How long shuffle, repeat, the burger and the view toggle take to come on. The fraction is eased and the colours are mixed from it -- never a Behavior on the colour, which would lag every theme switch.",
            val: 140,
            from: 20,
            to: 500,
            step: 10
        },
        {
            label: "tip delay ms",
            prop: "tipDelayMs",
            group: "Tips",
            blurb: "Every button says what it does on hover, in the popup's own overlay layer -- a tip that painted outside the row would never receive its own pointer.",
            tip: "How long the pointer must rest on a button before its tip appears. 350 ms: long enough that crossing the row does not light up five tips in turn, short enough that a pointer that stopped to ask gets an answer.",
            val: 450,
            from: 0,
            to: 1500,
            step: 25
        },
        {
            label: "tip fade ms",
            prop: "tipFadeMs",
            group: "Tips",
            tip: "How long that tip takes to appear and to go. Presence fades; the text itself never crossfades.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        }
    ]

    readonly property var infoParams: [
        {
            label: "scale",
            prop: "listScale",
            group: "Track",
            blurb: "What is playing, in reserved slots: a line that goes empty must not move the viewfinder under it.",
            tip: "Scales the whole block. The compact views use a smaller one rather than a second layout.",
            val: 1.0,
            from: 0.6,
            to: 2,
            step: 0.05
        },
        {
            label: "title size",
            prop: "titleSize",
            group: "Track",
            tip: "The track's title. 16 bold is the shell's title.",
            val: 18,
            from: 8,
            to: 32,
            step: 1
        },
        {
            label: "line size",
            prop: "lineSize",
            group: "Track",
            tip: "The artist and the album under it. 12 is the shell's body.",
            val: 12,
            from: 7,
            to: 24,
            step: 1
        },
        {
            label: "line gap",
            prop: "lineGap",
            group: "Track",
            tip: "Between the title and the line under it. 2: they are one block, not two.",
            val: 2,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "figures gap",
            prop: "timesGap",
            group: "Track",
            tip: "Between the text block and the figures line under it. 6 is the shell's text-to-figures gap; the gap BELOW the figures is the host's, because the viewfinder is the host's.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "figures to chip",
            prop: "figureGap",
            group: "Track",
            tip: "Between the elapsed/total figures and the fidelity chip beside them, at the width the block is measured at. The figures sit in anchored slots, so this is the one gap in the row that is not a slot.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "resize ms",
            prop: "resizeMs",
            group: "Track",
            tip: "How long the block takes to change height when a line appears or goes. 260 OutCubic, the shell's resize, so anything glued to its foot moves with it.",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "fade ms",
            prop: "fadeMs",
            group: "Track",
            tip: "How long a line takes to appear or go. Only PRESENCE fades -- the text itself swaps instantly, because crossfading two strings through each other is unreadable.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "skeleton thickness",
            prop: "skeletonThickness",
            group: "Skeleton",
            blurb: "With nothing playing the block shows the silhouette it will have: bars measured from three template strings in the very face each line uses, never drawn text.",
            tip: "How thick a bar is against the line it stands in. 0.55 is ListSkeleton's own relationship, a bar a little over half the line's height, so the silhouette carries the weight of the text it stands in and resolves into it in place.",
            val: 0.55,
            from: 0.1,
            to: 1,
            step: 0.05
        }
    ]

    readonly property var chipParams: [
        {
            label: "radius",
            prop: "chipRadius",
            group: "The chip",
            blurb: "The tier, as a category: Max, Lossless, High. The numbers behind it are one hover away, which is the whole point of a category.",
            tip: "The chip's corner. 8 -- a small carved box, not a container.",
            val: 6,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "padding h",
            prop: "padH",
            group: "The chip",
            tip: "Space either side of the tier's word. 8 against the 3 below it: a chip is wider than it is tall because a single word needs air at its ends and almost none over it.",
            val: 8,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "padding v",
            prop: "padV",
            group: "The chip",
            tip: "Space above and below it. 3 -- the box hugs one line of 10 px type, so the chip sits INSIDE the figures' row rather than standing above it.",
            val: 4,
            from: 0,
            to: 16,
            step: 0.5
        },
        {
            label: "text size",
            prop: "fontPixelSize",
            group: "The chip",
            tip: "The tier's word. 10 -- one under the figures beside it, because it is a label and they are the reading.",
            val: 10,
            from: 6,
            to: 20,
            step: 0.5
        },
        {
            label: "letter spacing",
            prop: "letterSpacing",
            group: "The chip",
            tip: "Tracking on that word. A small caps-ish label reads better opened up a little.",
            val: 0.8,
            from: 0,
            to: 4,
            step: 0.1
        },
        {
            label: "bevel width",
            prop: "bevelWidth",
            group: "The chip",
            tip: "The light rim outside the chip's carved edge. 1, a container's highlight: the chip is carved into the surface, and a raised button's 1.5 would lift it off.",
            val: 1,
            from: 0,
            to: 6,
            step: 0.25
        },
        {
            label: "shadow width",
            prop: "shadowWidth",
            group: "The chip",
            tip: "The inset shadow inside it. 3 -- a container's spread, because the chip is carved rather than raised.",
            val: 3,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "lobe padding h",
            prop: "lobePadH",
            group: "The bitrate lobe",
            blurb: "Hover the chip: a second, narrower lobe rises out of its top holding the bitrate, shrinkwrapped to the figure and joined to the chip by a smooth union (the chip is the gooey bar, the lobe the popup out of it).",
            tip: "Space either side of the bitrate figure inside the lobe. 7 -- a point under the chip's 8, so the lobe is the narrower of the two even for a lossy file whose chip is short.",
            val: 7,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "lobe padding v",
            prop: "lobePadV",
            group: "The bitrate lobe",
            tip: "Space above and below the figure in the lobe. 3 -- one under the chip's own, so the lobe is the lighter box of the two.",
            val: 3,
            from: 0,
            to: 16,
            step: 0.5
        },
        {
            label: "lobe radius",
            prop: "lobeRadius",
            group: "The bitrate lobe",
            tip: "The lobe's own top corners. 6, the chip's, so the two read as one material.",
            val: 6,
            from: 0,
            to: 20,
            step: 0.5
        },
        {
            label: "joint softness",
            prop: "lobeJoin",
            group: "The bitrate lobe",
            tip: "The smooth union's width: how wide the fillet is where the lobe's side meets the chip's top (about a quarter of this in px). 7 -- a small, definite fillet; 0.5 is a hard corner, 20 a bulb.",
            val: 7,
            from: 0.5,
            to: 24,
            step: 0.5
        },
        {
            label: "lobe ease ms",
            prop: "lobeMs",
            group: "The bitrate lobe",
            tip: "How long the lobe takes to rise and to go back. The hover starts it at once -- no delay, the user's word -- and the SHAPE eases on the shell's resize curve (260 ms OutCubic).",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "skeleton fade ms",
            prop: "fadeMs",
            group: "The numbers",
            blurb: "The silhouette the chip shows before a track is known, dissolving into the real badge.",
            tip: "How long the SKELETON takes to appear and go. It was called the tip's fade until round 3 took the tip away and round 10 found the name had outlived it -- the chip has no tip, and this is the only fade left in the chip itself (the bitrate lobe has its own ease, above). 160 is the shell's presence fade: presence fades, and the figures themselves never crossfade.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        }
    ]

    // ---- the three browse panels -----------------------------------------

    readonly property var queueParams: [
        {
            label: "last row air",
            prop: "rowFootAir",
            group: "Rows",
            blurb: "The queue beside the player in browse. Rows carry the inset, not the viewport, so the header can sit flush with the box's edge and share its corner.",
            tip: "Extra air under the LAST row's ink, on top of the half spacing its slot already carries. 6 is the header box's bottom gap, so the space under the last song equals the space over the first one -- above equals below.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "scale",
            prop: "listScale",
            group: "Rows",
            tip: "Scales the rows and their text together. The browse view uses a smaller one rather than a second layout.",
            val: 1.0,
            from: 0.6,
            to: 2,
            step: 0.05
        },
        {
            label: "row v padding",
            prop: "rowVPad",
            group: "Rows",
            tip: "Space above and below a row's text. The row's height follows its content rather than being set, so this is how tall a row is.",
            val: 4,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "row inset",
            prop: "rowInset",
            group: "Rows",
            tip: "How far a row is held off the box's edge. 6 everywhere in the shell.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "row line gap",
            prop: "rowLineGap",
            group: "Rows",
            tip: "Between a row's title and the artist under it. 1: they are one row, not two lines.",
            val: 1,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "row spacing",
            prop: "rowVirtualSpacing",
            group: "Rows",
            tip: "Between two rows, in the RESTING layout the animations are measured against. Half of it is reserved above a row's content and half below, which is what leaves the list flush with the box at both ends.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "block gap",
            prop: "rowGap",
            group: "Rows",
            tip: "Between a row's own blocks -- the number, the title, the duration, the remove slot. 8 against the 6 the row is held off the box by: a row's parts stand further apart than the row does from its edge, which is what makes them read as one row of parts.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "row side padding",
            prop: "rowSidePadding",
            group: "Rows",
            tip: "A hair of space inside the row's own left and right edge, so the stripe and the figures do not touch the hover fill's corner.",
            val: 2,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "stripe width",
            prop: "stripeWidth",
            group: "Rows",
            tip: "The mark on the playing row. 3 px is a mark rather than a bar, and it is the only one: one coloured mark for one fact, so there is no second tint, no coloured text and no glyph beside it.",
            val: 3,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "list fade",
            prop: "listFadeHeight",
            group: "Rows",
            tip: "The fade at each end of the scrolling box, keyed on the scroll position: the rows go under the carved edge rather than stopping at it.",
            val: 34,
            from: 0,
            to: 80,
            step: 2
        },
        {
            label: "header padding",
            prop: "headerBoxPadding",
            group: "Header",
            blurb: "The pinned header's own carve. Its two top corners meet the container's, so the two curves have to agree -- and so do the two edges.",
            tip: "Inside the header box, left and right. 11 x 8 is the shell's header box.",
            val: 11,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "header padding v",
            prop: "headerBoxPaddingV",
            group: "Header",
            tip: "And above and below. 11 x 8 is the shell's header box: wider than tall, because the box hugs one line of text.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "header bevel width",
            prop: "headerBevelWidth",
            group: "Header",
            tip: "The light lip OUTSIDE the header box's edge, in px before the list scale. 1 is the shell's container bevel. The header's COLOURS are theme tokens and are edited on the Popup tab, because a hex left on a component is how a dark theme breaks.",
            val: 1,
            from: 0,
            to: 6,
            step: 0.5
        },
        {
            label: "header inset shadow",
            prop: "headerShadowWidth",
            group: "Header",
            tip: "How deep the shadow reaches INSIDE the header box's edge, in px before the list scale. 3 here against the library's 7: the queue's header is a plain box and the library's carries a genre's hue in the same inset, which needs the room.",
            val: 3,
            from: 0,
            to: 16,
            step: 0.5
        },
        {
            label: "title size",
            prop: "titleSize",
            group: "Type",
            blurb: "Three sizes: the song, the artist under it, and the header over them.",
            tip: "A queued song's title. 13 in the browse column -- one step under the player's own 16, because a sidebar is a denser reading than the thing being played.",
            val: 13,
            from: 8,
            to: 24,
            step: 1
        },
        {
            label: "artist size",
            prop: "artistSize",
            group: "Type",
            tip: "The artist under it. 11 against the title's 13, the same one-step drop the player column makes from its title to its body.",
            val: 11,
            from: 7,
            to: 20,
            step: 1
        },
        {
            label: "header size",
            prop: "headerTitleSize",
            group: "Type",
            tip: "The queue's own header -- how many songs and how long they run. 15: between the popup's 16 title and the rows' 13, because it heads a column rather than the popup.",
            val: 15,
            from: 8,
            to: 28,
            step: 1
        },
        {
            label: "row anim ms",
            prop: "rowAnimDuration",
            group: "Motion",
            blurb: "Only what is on screen animates: a row that would land past the fold is PLACED, not staggered, or row forty spends two seconds arriving where nobody is looking.",
            tip: "How long a row takes to enter or leave. 240, the shell's row animation.",
            val: 240,
            from: 40,
            to: 800,
            step: 10
        },
        {
            label: "stagger ms",
            prop: "rowStaggerMs",
            group: "Motion",
            tip: "How far apart two neighbouring rows start that animation, so a batch arrives as a wave rather than as a block.",
            val: 55,
            from: 0,
            to: 300,
            step: 5
        },
        {
            label: "gap anim ms",
            prop: "gapAnimDuration",
            group: "Motion",
            tip: "How fast the gap under a dragged row opens and closes. Faster than a row entering the list: the pointer is already somewhere else by the time a 240 ms slide lands.",
            val: 160,
            from: 20,
            to: 600,
            step: 10
        },
        {
            label: "slot dead band",
            prop: "slotHysteresis",
            group: "Motion",
            tip: "How far past half way the dragged row must go before the gap gives up the slot it is in. A dead band, in fractions of a row. Without one the slot is a knife edge at every half row, re-read on every mouse move and every frame of an edge scroll, so a hand RESTING on a boundary flips the gap back and forth for as long as it sits there. It costs nothing in the direction of travel. Keep it well under 0.5: at 0.5 the gap could never reach the next slot at all.",
            val: 0.15,
            from: 0,
            to: 0.45,
            step: 0.01
        },
        {
            label: "scroll speed",
            prop: "scrollSpeed",
            group: "Motion",
            tip: "Multiplies a wheel notch. The list scrolls by its own handler, so this is the only place the rate is set.",
            val: 1.0,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "follow ms",
            prop: "followScrollMs",
            group: "Motion",
            tip: "How long the view takes to follow rows that arrived below the fold at the very bottom of the list. 260 OutCubic is the house's resize easing: the view moving to meet new content is the same kind of motion as a container growing.",
            val: 260,
            from: 0,
            to: 1200,
            step: 10
        },
        {
            label: "foot slack",
            prop: "followFootSlack",
            group: "Motion",
            tip: "How close to the end still counts as already scrolled to the end, in ROW PITCHES -- the queue only follows a list that was at its foot. Half a row: short enough that a list stopped in the middle never follows, long enough that one parked a pixel or two short of its end still does.",
            val: 0.5,
            from: 0,
            to: 3,
            step: 0.1
        },
        {
            label: "drag threshold",
            prop: "dragThreshold",
            group: "Flight",
            blurb: "Reordering: the row is lifted, flies to where it was dropped and lands there. The clone flies in the popup's overlay, because an item that paints outside its ancestor's bounds never receives input there.",
            tip: "How far the pointer must travel before a press on a row becomes a drag rather than a click that plays it.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "lift scale",
            prop: "flightLiftScale",
            group: "Flight",
            tip: "How much bigger the row is while it is in the hand. The lift itself is as short as an animation can be and the clone simply starts in the air, because lifting a second time at the drop reads as a hiccup.",
            val: 1.055,
            from: 1,
            to: 1.3,
            step: 0.005
        },
        {
            label: "travel ms",
            prop: "flightTravelMs",
            group: "Flight",
            tip: "How long the flight takes at full distance. Constant, so a long move does not read as a slower one.",
            val: 340,
            from: 60,
            to: 1200,
            step: 10
        },
        {
            label: "short distance",
            prop: "flightShortDistance",
            group: "Flight",
            tip: "Under this distance, in px, the travel time scales down with it -- so a two-row move is not padded out to the full duration.",
            val: 220,
            from: 20,
            to: 800,
            step: 10
        },
        {
            label: "travel floor ms",
            prop: "flightMinTravelMs",
            group: "Flight",
            tip: "And the shortest that scaling may make it. 130 ms, so even a one-row move is a movement you can follow rather than a jump.",
            val: 130,
            from: 20,
            to: 600,
            step: 10
        },
        {
            label: "land ms",
            prop: "flightLandMs",
            group: "Flight",
            tip: "The last leg: the clone dropping into the row's own place and handing back to it. 160 against the travel's 340, because the last few pixels are a landing rather than a journey.",
            val: 160,
            from: 20,
            to: 600,
            step: 10
        },
        {
            label: "min travel px",
            prop: "flightMinTravel",
            group: "Flight",
            tip: "Below this the row is not really moving, so there is nothing for a flight to convey and none is flown.",
            val: 4,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "blur distance",
            prop: "flightBlurRefDistance",
            group: "Flight",
            tip: "How far the LIST has to travel under the flight for its blur to peak. 700 px is well past a screenful of rows, so an ordinary reorder blurs in proportion to how far it went and only a throw to the far end saturates.",
            val: 700,
            from: 100,
            to: 2000,
            step: 50
        },
        {
            label: "blur max",
            prop: "flightBlurMax",
            group: "Flight",
            tip: "How blurred it gets at that distance. It is the list that blurs, never the row in the hand.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "settle ms",
            prop: "flightSettleMs",
            group: "Flight",
            tip: "How long the clone waits over the destination before it hands the row back. Long enough for the host's queued re-sync AND the relayout it causes to land, since the lift no longer runs first to cover them.",
            val: 90,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "pre-move ms",
            prop: "flightPreMoveDelayMs",
            group: "Flight",
            tip: "A beat before the clone starts travelling, so the eye registers the lift as a step of its own rather than as one continuous slide.",
            val: 100,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "pre-drop ms",
            prop: "flightPreDropDelayMs",
            group: "Flight",
            tip: "And the same beat before it drops into place. The same 100 ms, so the lift and the landing are symmetric -- a longer pause at one end reads as a hesitation.",
            val: 100,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "autoscroll zone",
            prop: "autoScrollDeadZone",
            group: "Flight",
            tip: "How close to the viewport's edge a dragged row must come before the list starts scrolling itself, in px. 12 is twice the row's inset: near enough to the edge to be deliberate, far enough that dropping a row at the end does not set the list moving under it.",
            val: 12,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "autoscroll ramp",
            prop: "autoScrollRamp",
            group: "Flight",
            tip: "Over how many further px that scroll reaches full speed, so it eases in rather than snapping on.",
            val: 140,
            from: 10,
            to: 400,
            step: 10
        },
        {
            label: "autoscroll max",
            prop: "autoScrollMaxSpeed",
            group: "Flight",
            tip: "And what full speed is, in px/s. 900 crosses the list's own viewport in well under a second, which is about as fast as a dragged row can still be followed.",
            val: 900,
            from: 100,
            to: 3000,
            step: 50
        },
    ]

    readonly property var libraryParams: [
        {
            label: "foot air",
            prop: "rowFootAir",
            group: "List",
            blurb: "Albums, artists, genres, recently played and playlists are five readings of the same shelf, so they are five tabs over ONE list: one box, one flick, one dressing, one row delegate. A switch is a re-fill, never a second list built beside this one -- that cost 64 to 100 ms of blocked frames when it was measured.",
            tip: "Under the last row when the list does NOT end on a header. A header ends in a box, and a box is meant to meet the container's edge; a song ends in bare text and would otherwise sit on the carved foot. 6 is the header box's bottom gap, and it is the queue's own number, so the two panels leave the same air.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "stripe width",
            prop: "stripeWidth",
            group: "List",
            tip: "The mark on the song that is playing, seen while browsing the library. 3 px is the queue's own: a mark, not a bar, and the only one -- one coloured mark for one fact.",
            val: 3,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "scale",
            prop: "listScale",
            group: "List",
            tip: "Scales the rows and their text together. The browse view uses a smaller one rather than a second layout.",
            val: 1.0,
            from: 0.6,
            to: 2,
            step: 0.05
        },
        {
            label: "selector gap",
            prop: "padding",
            group: "List",
            tip: "Between the grouping selector and the box under it. 12, the shell's padding.",
            val: 12,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "selector height",
            prop: "tabRowHeight",
            group: "List",
            tip: "How tall that selector is, AND the Clear / All button beside it -- one row, one height. 32 is a TabSelector's pill row: tall enough for a pill to take a pointer, short enough to leave the box the height it needs. The popup raises it so the row lines up with whatever stands beside it.",
            val: 32,
            from: 20,
            to: 56,
            step: 1
        },
        {
            label: "side button width",
            prop: "sideButtonWidth",
            group: "List",
            tip: "The button at the right end of the tab row: Clear on recently played, the artists' scope toggle on artists. 52 fits either label at the row's own type size. Its HEIGHT is the selector's above, and its corner is the container's, because it sits over the container's own top corner and the two curves must coincide.",
            val: 52,
            from: 24,
            to: 140,
            step: 2
        },
        {
            label: "row inset",
            prop: "rowInset",
            group: "List",
            tip: "How far a row is held off the box's edge. 6 everywhere in the shell.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "song inset",
            prop: "songInsetExtra",
            group: "List",
            tip: "How much further in a song sits under its album, per level. A genre is a list of albums and an album a list of songs, so a song under a genre is two of these in.",
            val: 0,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "row spacing",
            prop: "rowVirtualSpacing",
            group: "List",
            tip: "Between two rows in the RESTING layout every animation is measured against. Half of it is reserved above a row and half below, which is what leaves the list flush with the box at both ends.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "block gap",
            prop: "rowGap",
            group: "List",
            tip: "Between a row's own blocks -- the cover, the text, the count, the chevron. 8 against the 6 the row is held off the box by, and the queue's own number, so the two panels space their rows alike.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "song v padding",
            prop: "songVPad",
            group: "List",
            tip: "Space above and below a song row's text, which is what makes a song row shorter than a header.",
            val: 4,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "list fade",
            prop: "listFadeHeight",
            group: "List",
            tip: "The fade at each end of the scrolling box, keyed on the scroll position, with the container's corner re-cut over the rows that pass under it.",
            val: 34,
            from: 0,
            to: 80,
            step: 2
        },
        {
            label: "shelf line inset",
            prop: "shelfTextInset",
            group: "List",
            tip: "How far that line stands in from the selector's left edge. Its first glyph reads as flush with the selector's curve at 2.",
            val: 2,
            from: 0,
            to: 12,
            step: 1
        },
        {
            label: "header padding",
            prop: "headerBoxPadding",
            group: "Header",
            blurb: "A group header is ListSectionHeader in every respect but one: an album has to carry its cover, and that component's only icon slot is a font glyph. Same numbers, so the two read as one thing.",
            tip: "Inside the header box, left and right. 11 x 8 is the shell's header box.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "header padding v",
            prop: "headerBoxPaddingV",
            group: "Header",
            tip: "And above and below. 11 x 8 is the shell's header box: wider than tall, because the box hugs one line of text.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "bottom gap",
            prop: "headerBottomGap",
            group: "Header",
            tip: "Under a header, to whatever follows it. 6, ListSectionHeader's own -- and it is carried by the header itself, so the last one in the list can give it back and let the box end flush.",
            val: 4,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "cover size",
            prop: "coverSize",
            group: "Header",
            tip: "The album cover in a header. It IS the play button: nothing announces that but the pointer, because a glyph beside it would be a second mark for an action the picture already stands for.",
            val: 34,
            from: 16,
            to: 72,
            step: 1
        },
        {
            label: "cover radius",
            prop: "coverRadius",
            group: "Header",
            tip: "Its corner. Small: a cover is a picture, not a container.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "chevron size",
            prop: "chevronSize",
            group: "Header",
            tip: "The open/shut chevron at the right of a header. 15 against the title's 13, because a glyph reads smaller than type of the same size. It turns; it never swaps for a second glyph.",
            val: 14,
            from: 6,
            to: 28,
            step: 1
        },
        {
            label: "header bevel width",
            prop: "headerBevelWidth",
            group: "Header",
            tip: "The section header's carve, and the genre's hue glowing inside its inset. The system update exposes the same four knobs on its own headers; this is the audio player's half of that pair. The light lip OUTSIDE the header box's edge, in px before the list scale. 1 is the shell's container bevel. The COLOURS are theme tokens (Popup tab); the genre hue is the library's own and lives in the hue rows.",
            val: 1,
            from: 0,
            to: 6,
            step: 0.5
        },
        {
            label: "header inset shadow",
            prop: "headerShadowWidth",
            group: "Header",
            tip: "How deep the shadow reaches INSIDE the header box's edge, in px before the list scale. 7 rather than the queue's 3, because this inset also carries the genre's hue and the hue needs room to read as a sliver rather than a line.",
            val: 7,
            from: 0,
            to: 16,
            step: 0.5
        },
        {
            label: "header glow width",
            prop: "headerGlowWidth",
            group: "Header",
            tip: "How far the genre's hue reaches in from the left edge, in px. Unlike the system update's header, a genre has no PROGRESS -- so there is one width here where that one has an idle and an active pair, and the sliver is constant.",
            val: 12,
            from: 0,
            to: 48,
            step: 1
        },
        {
            label: "header glow feather",
            prop: "headerGlowFeather",
            group: "Header",
            tip: "How softly that hue gives way to the plain inset, in px. 1.5 is nearly a hard edge, which is what makes it read as a mark rather than as a gradient; the system update opens its own out to 12 while a category is under way.",
            val: 1.5,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "title size",
            prop: "titleSize",
            group: "Type",
            blurb: "Two sizes: the album, artist, genre or playlist, and the line under it.",
            tip: "A header's own name, and a song's title. 13, the queue's own, so the two panels that share this column read as one list rather than two.",
            val: 13,
            from: 8,
            to: 24,
            step: 1
        },
        {
            label: "shelf line size",
            prop: "shelfTextSize",
            group: "Type",
            tip: "The bold line between the selector and the list: how much is on the shelf, or the query while one is typed. Smaller than the notes' and the launcher's 16: this one is a sidebar's, not a popup's title.",
            val: 13,
            from: 10,
            to: 18,
            step: 1
        },
        {
            label: "subtitle size",
            prop: "subtitleSize",
            group: "Type",
            tip: "The artist under an album's name, and the counts beside it. 11, the queue's artist size, for the same reason.",
            val: 11,
            from: 7,
            to: 20,
            step: 1
        },
        {
            label: "row anim ms",
            prop: "rowAnimDuration",
            group: "Motion",
            blurb: "Every wave -- an expand, a collapse, a grouping swap -- is cut off at the fold: a row that would land off screen is PLACED, not staggered. The wave is reassessed while it runs, so scrolling along with it keeps the same cadence.",
            tip: "How long a row takes to enter or leave. 240, the shell's row animation.",
            val: 240,
            from: 40,
            to: 800,
            step: 10
        },
        {
            label: "stagger ms",
            prop: "rowStaggerMs",
            group: "Motion",
            tip: "How far apart two neighbouring rows start it, so a fill arrives as a wave rather than as a block.",
            val: 55,
            from: 0,
            to: 300,
            step: 5
        },
        {
            label: "swap gap ms",
            prop: "swapGapMs",
            group: "Motion",
            tip: "The pause between the old grouping's last row LANDING and the new grouping's first row starting -- a swap is a collapse followed by an expand, not two lists passing through each other. One stagger step is the doc's 'shortly after', read literally: the clock starts at the end of the exit wave, not at its last kick.",
            val: 55,
            from: 0,
            to: 600,
            step: 5
        },
        {
            label: "page morph ms",
            prop: "pageMorphMs",
            group: "Motion",
            tip: "How long a row takes to grow into its album or artist page, and the page to shrink back into the row. The notes' own 320: one clock moves the card, the list receding and the page arriving.",
            val: 320,
            from: 100,
            to: 1200,
            step: 10
        },
        {
            label: "swipe back units",
            prop: "swipeBackUnits",
            group: "Motion",
            tip: "How much two-finger travel is the whole of a swipe back from a page. A lift past a third of it, or a fling, goes back; less springs home. The notes' own 900.",
            val: 900,
            from: 200,
            to: 3000,
            step: 10
        },
        {
            label: "wave window ms",
            prop: "waveMaxMs",
            group: "Motion",
            tip: "How long a wave stays open to promotions. A list of 500 rows would otherwise keep its entrance running for half a minute, and past a few seconds a scroll is browsing rather than keeping up with the entrance.",
            val: 4000,
            from: 200,
            to: 12000,
            step: 100
        },
        {
            label: "scroll speed",
            prop: "scrollSpeed",
            group: "Motion",
            tip: "Multiplies a wheel notch. The list scrolls by its own handler rather than a Flickable's, so this is the only place its rate is set.",
            val: 1.0,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "follow if under",
            prop: "expandFollowMinRows",
            group: "Motion",
            tip: "How many song rows of an opened block must ALREADY be in view for the list not to scroll to it, when a block is opened at the very bottom. Under this the list follows what opened and stops at the header's own top, so the thing you asked for is on screen without the header you clicked leaving it.",
            val: 2,
            from: 0,
            to: 8,
            step: 1
        },
        {
            label: "follow ms",
            prop: "expandFollowMs",
            group: "Motion",
            tip: "How long that follow takes. 260 OutCubic is the shell's resize easing -- a scroll the panel makes for itself is a resize of what is on screen.",
            val: 260,
            from: 0,
            to: 1200,
            step: 10
        },
    ]

    readonly property var libraryHues: [
        {
            label: "rock",
            prop: "catCore",
            group: "Genres",
            blurb: "A group's colour is its GENRE'S, in the left edge of its header's inset, once: the same album wears the same hue in every view it appears in, and there is no second coloured mark anywhere -- no stripe, no tinted text, no coloured chevron. The six genres this library actually holds have hues of their own; anything else is hashed onto a fallback ring of five that are deliberately none of these, because a fallback that can be mistaken for a named hue is worse than no hue. These rows are theme tokens shared with the rest of the shell, so moving one moves it everywhere it is worn.",
            tip: "Rock. The repo-core orange -- a genre hue is always a token the shell already ships, never a colour invented here, so it follows a theme switch on the theme's own clock like every other mark.",
            val: "#FF6D12"
        },
        {
            label: "soundtrack",
            prop: "catExtra",
            group: "Genres",
            tip: "Soundtrack. The repo-extra green. Genre names are folded to lower case here, because the library holds both 'SoundTrack' and 'Soundtrack' and they are one genre.",
            val: "#44C145"
        },
        {
            label: "ambient",
            prop: "catMultilib",
            group: "Genres",
            tip: "Ambient. The multilib teal, the shell's third category colour and the only cyan in the six, so an ambient header cannot be taken for the electronic blue two rows under it.",
            val: "#00BEC4"
        },
        {
            label: "electronic",
            prop: "catAur",
            group: "Genres",
            tip: "Electronic -- and the hue the playlists grouping wears, since a playlist has nothing to take a genre from. It is the accent's own blue.",
            val: "#4480F4"
        },
        {
            label: "shoegaze",
            prop: "llmCode",
            group: "Genres",
            tip: "Shoegaze. Catppuccin Latte's mauve, from the LLM module's six -- borrowed rather than invented, for the same reason as the rest: nothing here can then drift from the palette.",
            val: "#8839EF"
        },
        {
            label: "dream pop",
            prop: "llmWrite",
            group: "Genres",
            tip: "Dream pop. Latte's pink, the LLM module's write hue. The last of the six named genres: everything past them is hashed onto the fallback ring the group's note describes.",
            val: "#EA76CB"
        }
    ]

    // ---- the file's own words --------------------------------------------
    // PlayerData. Everything the popup does NOT bind: its colours are the
    // theme's and are passed in, and `lyric size` is derived from `compact`.

    readonly property var dataParams: [
        {
            label: "scale",
            prop: "listScale",
            group: "The panel",
            blurb: "The tags attached to what is playing, and the lyrics that are the reason the tab is opened. Same carved box, same dressing, same row inset and radii as the queue and the library beside it.",
            tip: "Scales the panel's rows and its text together, like the queue's and the library's. The browse view uses a smaller one rather than a second layout.",
            val: 1.0,
            from: 0.6,
            to: 2,
            step: 0.05
        },
        {
            label: "follow the playback",
            prop: "followPlayback",
            group: "Following the music",
            blurb: "A timed lyric FOLLOWS the playback: the current line is held at one place in the viewport and the block moves under it. A hand on the wheel switches that off for a while, because a reader who has scrolled ahead is reading, not watching.",
            tip: "Whether the reading follows the song at all. Off, the lyrics are a page you scroll yourself and the head still marks the line being sung -- which is what a file with no timings gets anyway, since there is nothing to follow.",
            val: true
        },
        {
            label: "hold line at",
            prop: "followFraction",
            group: "Following the music",
            tip: "Where in the viewport the current line is held, 0 at the top and 1 at the foot. 0.38 is above the middle: enough of the song already sung stays visible to keep your place, and most of the room goes to what is coming.",
            val: 0.38,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "follow ms",
            prop: "followMs",
            group: "Following the music",
            tip: "How long the block takes to slide to the next line. Longer than the head's own move at 420, on purpose: the head arrives first and the words catch up, so the eye is told where to look before the page moves under it.",
            val: 420,
            from: 0,
            to: 2000,
            step: 10
        },
        {
            label: "resume after ms",
            prop: "followResumeMs",
            group: "Following the music",
            tip: "How long a hand on the wheel switches the follow off for. 5 s is long enough to read a verse ahead and short enough that a scroll you have forgotten about does not leave the panel stuck behind the music.",
            val: 5000,
            from: 0,
            to: 20000,
            step: 250
        },
        {
            label: "line gap",
            prop: "lyricLineGap",
            group: "The lyrics",
            blurb: "The words themselves. They get the room -- the tags under them are a quiet block that must not compete.",
            tip: "Between two sung lines, in px. 6 is the shell's own text-to-text gap; a lyric is a paragraph of one line each, not a list.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "gap line height",
            prop: "gapLineFactor",
            group: "The lyrics",
            tip: "A silent stretch between verses is drawn as a line of its own, this tall against a sung one. Short enough to read as a pause, tall enough for the reading head to be a mark in it rather than a dot.",
            val: 0.62,
            from: 0,
            to: 1.5,
            step: 0.01
        },
        {
            label: "sung dim",
            prop: "pastDim",
            group: "The lyrics",
            tip: "How far a line already sung is pushed back toward the box it sits in, 0 no dimmer than faint and 1 gone. 0.42 is dimmer than faint on purpose: the eye belongs at the line that is happening and the ones still coming.",
            val: 0.42,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "head width",
            prop: "stripeWidth",
            group: "The reading head",
            blurb: "Which line is being sung is said ONCE, by a mark in the margin that glides from line to line -- never by a second coloured thing saying the same fact.",
            tip: "The mark's width in px. 3 is the shell's row stripe: a mark, not a bar.",
            val: 3,
            from: 0,
            to: 12,
            step: 0.5
        },
        {
            label: "head track",
            prop: "stripeTrackAlpha",
            group: "The reading head",
            tip: "How much of the groove the head runs in shows through behind it, 0 none and 1 all. 0.8 keeps the track readable as the path the head is on, which is what stops the mark reading as an arbitrary dash beside one line.",
            val: 0.8,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "line lit ms",
            prop: "litMs",
            group: "The reading head",
            tip: "How long a line takes to light up and to go out again. 220 is a shade slower than a hover so the change reads as the song moving on rather than as a response to the pointer.",
            val: 220,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "head move ms",
            prop: "headMoveMs",
            group: "The reading head",
            tip: "How long the head takes to glide to the next line. 200, shorter than the block's own follow, so it arrives at the new line before the words move under it.",
            val: 200,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "head fade ms",
            prop: "fadeMs",
            group: "The reading head",
            tip: "How long the head takes to appear and to go. It goes when the WORDS end -- most files close their timed block early and play on -- so this is what that disappearance reads as. 160 is the house's presence fade: the same one the lyrics themselves arrive on, so the two never look like separate events.",
            val: 160,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "label column",
            prop: "tagLabelShare",
            group: "The tags",
            blurb: "Everything else the file carries. Date, bpm, key and release type sit in fixed slots so a figure never jitters when the track changes; the rest is a two-column block under them.",
            tip: "The label column of that block, as a share of its width. 0.34 leaves the values a flush left edge of their own -- the labels are the quiet half and are read down, not across.",
            val: 0.34,
            from: 0.1,
            to: 0.7,
            step: 0.01
        }
    ]


    // ---- the sidebar's own selector --------------------------------------

}
