pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/board"
import "modules/common/theme"
import "modules/common/components"
import "modules/common/board/IsoCore.js" as Core
import "modules/common/board/Figures.js" as Fig
import "modules/common/board/BoardLayout.js" as BL

// =============================================================================
// tools/dev/qml/board_toolkit_probe.qml -- do the board toolkit's own types load, run and answer on their own, with no scene behind them? One window, every
// QML type of modules/common/board built with its inputs bare, and the JS cores asked a few questions whose answers are written down. A type that
// imports a sibling directory (PopupStage, BoardInput, BoardIsland, ErrorTag) cannot be smoked as its own config root, so this is where it is loaded.
//   Prints one `BTK` line per check and ends in BOARD_TOOLKIT RESULT PASS|FAIL (the exit status follows).
// =============================================================================
Window {
    id: root

    width: 200
    height: 200
    visible: true

    property var fails: []
    function check(name, ok) {
        console.log("BTK " + (ok ? "ok   " : "FAIL ") + name);
        if (!ok)
            root.fails.push(name);
    }

    // the theme-switch island, on a window that is a crossfade host: armed at the ask, its ghost built for the fade, gone after it
    Item {
        id: body
        anchors.fill: parent
        opacity: 0.01
        Item {
            id: sceneStub
            property real renderScale: 1
            width: 120
            height: 120
        }
        BoardIsland {
            id: island
            scene: sceneStub
            live: true
            inset: 4
            ghostContent: Component {
                Rectangle {
                    color: "magenta"
                    Component.onCompleted: root.island_built++
                    Component.onDestruction: root.island_gone++
                }
            }
        }
    }
    ThemeCrossfade { target: body; anchors.fill: parent }
    property int island_built: 0
    property int island_gone: 0
    property string island_mode: ""
    property int island_stage: 0
    property bool island_armedSeen: false
    Timer {
        id: islandDriver
        interval: 40
        repeat: true
        running: false
        property int ticks: 0
        onTriggered: {
            ticks++;
            if (root.island_stage === 0) {
                root.island_mode = Theme.mode;
                Theme.setMode(Theme.mode === "light" ? "dark" : "light");
                root.island_stage = 1;
            } else if (root.island_stage === 1) {
                if (Theme.crossfading && island.armed)
                    root.island_armedSeen = true;
                if (root.island_armedSeen && root.island_built > 0)
                    root.island_stage = 2;
                else if (ticks > 100) {
                    root.check("island: armed with a ghost built during the fade (armed " + island.armed + ", crossfading " + Theme.crossfading + ", built " + root.island_built + ")", false);
                    root.island_stage = 9;
                }
            } else if (root.island_stage === 2) {
                if (!Theme.crossfading) {
                    root.check("island: armed during the fade, ghost built once", root.island_armedSeen && root.island_built === 1);
                    root.island_stage = 3;
                    ticks = 0;
                }
            } else if (root.island_stage === 3) {
                if (root.island_gone === root.island_built && !island.armed) {
                    root.check("island: ghost gone and not armed after the fade", true);
                    root.island_stage = 9;
                } else if (ticks > 50) {
                    root.check("island: ghost gone and not armed after the fade (gone " + root.island_gone + " of " + root.island_built + ")", false);
                    root.island_stage = 9;
                }
            }
            if (root.island_stage === 9) {
                islandDriver.stop();
                Theme.setMode(root.island_mode);
                root.finish();
            }
        }
    }

    PopupStage { id: stage; sizeScale: 1.5; designWidth: 100; designHeight: 50 }
    BoardInput { id: input; width: 100; height: 100 }
    ErrorTag { id: tag; text: "no" }
    ReadingBeat { id: beat; baseMs: 0 }
    IdleLadder { id: ladder }
    BoardClock { id: clock }
    BoardLayerBase { id: board; width: 10; height: 10 }
    GlowLayerBase { id: glow; width: 10; height: 10 }
    HoloLayerBase { id: holo; width: 10; height: 10 }

    Timer {
        interval: 0
        running: true
        onTriggered: {
            // the QML types
            root.check("PopupStage implicit size = design x sizeScale", stage.implicitWidth === 150 && stage.implicitHeight === 75);
            root.check("BoardInput with no scene picks nothing", input.partAt(5, 5) === "" && input.intentAt(5, 5) === "");
            root.check("BoardIsland is not armed before a switch", island.armed === false);
            root.check("ErrorTag shows its words", tag.implicitWidth > 0);
            ladder.open = true;
            root.check("IdleLadder is alive when opened", ladder.level === "alive");
            ladder.open = false;
            root.check("IdleLadder halts when closed", ladder.level === "halt");
            root.check("BoardClock is parked or idle with no scene", clock.running === false);
            root.check("BoardLayerBase frame uniform", board.frame.w === 0 && board.view.w === 0);
            holo.power = 0;
            root.check("HoloLayerBase hidden at power 0", holo.visible === false);
            // the JS cores
            const cam = { s: 2, ox: 100, oy: 100 };
            const p = Core.project([10, 5, 20], cam);
            const back = Core.onPlane(p.x, p.y, cam, 5);
            root.check("onPlane inverts project at the plane's height", Math.abs(back[0] - 10) < 1e-6 && Math.abs(back[2] - 20) < 1e-6);
            const fit = Core.fitPoints(Core.boxCorners({ x0: 0, x1: 100, y0: 0, y1: 2, z0: 0, z1: 60 }), 760, 560);
            root.check("fitPoints gives a whole-pixel origin", fit.ox === Math.round(fit.ox) && fit.s > 0);
            const hit = Core.pickBoxes([{ name: "a", min: [0, 0, 0], max: [10, 5, 10] }], { s: 3, ox: 0, oy: 0 }, Core.project([5, 5, 5], { s: 3, ox: 0, oy: 0 }).x, Core.project([5, 5, 5], { s: 3, ox: 0, oy: 0 }).y, null);
            root.check("pickBoxes finds the box under its top face", hit === "a");
            root.check("pickBoxes lets a frame hook leave a part out", Core.pickBoxes([{ name: "a", min: [0, 0, 0], max: [10, 5, 10] }], { s: 3, ox: 0, oy: 0 }, 0, 0, () => false) === "");
            root.check("Figures: right-aligned, a point takes no cell", Fig.pack("3.4", 3, false).join(",") === "11,19,4,11");
            root.check("Figures: too long is --", Fig.pack("12345", 3, false).join(",") === "11,10,10,11" || Fig.pack("12345", 3, false)[2] === 10);
            root.check("Figures: code4 round trip", Fig.uncode4(Fig.code4([1, 2, 3, 4])).join(",") === "1,2,3,4");
            root.check("BoardLayout: a point in a convex polygon", BL.inPoly([[0, 0], [10, 0], [10, 10], [0, 10]], 5, 5) && !BL.inPoly([[0, 0], [10, 0], [10, 10], [0, 10]], 15, 5));
            root.check("BoardLayout: zoneAt takes the first zone in order", BL.zoneAt({ a: [[[0, 0], [10, 0], [10, 10], [0, 10]]], b: [[[0, 0], [10, 0], [10, 10], [0, 10]]] }, 5, 5, ["a", "b"]) === "a");
            const hull = BL.convexHull([[0, 0], [4, 0], [4, 4], [0, 4], [2, 2]]);
            root.check("BoardLayout: hull drops the inside point", hull.length === 4);
            islandDriver.start();
        }
    }
    function finish() {
        console.log("BOARD_TOOLKIT RESULT " + (root.fails.length === 0 ? "PASS" : "FAIL (" + root.fails.join("; ") + ")"));
        Qt.quit();
    }
}
