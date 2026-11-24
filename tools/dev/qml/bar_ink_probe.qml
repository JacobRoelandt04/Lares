pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/bar/reel"
import "modules/clock"
import "modules/shell"
import "modules/silicon"
import "modules/shell/ReelItems.js" as ReelItems

// =============================================================================
// bar_ink_probe.qml -- the shade a bar glyph and bar text rest in (round 5, text made permanent in round 6). Cells drawn at SCALE (default 4, so a thick stroke has
// fully covered pixels), saved as PNGs; tools/dev/bar_ink_probe.sh reads each cell's most inked pixel (furthest from the surface) and
// judges it against the token printed by `BARINK expect <cell> <token> <hex>`:
//   ref_glyph   a plain Nerd Font glyph in Theme.textMuted: the ink every other bar glyph rests in
//   reel_rest   the power reel's bar cell at rest (selected item): must be that same ink (it was Theme.textPrimary)
//   clock       the clock's text: the same ink (BarText.ink, Theme.textMuted)
//   silicon     the battery's charge digits (SiliconBarFace, objectName "siliconFigure"): the same ink -- grabbed on the figure alone
//               (the fill and the card around it are other colours)
//
//   OUT_DIR  where the cells go (required)     SCALE  default 4
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 700
        implicitHeight: 240
        visible: true
        color: Theme.surface

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property real zoom: Math.max(1, Number(Quickshell.env("SCALE") || 4))
        property int at: -1
        property int fails: 0
        property var plan: []
        // through a var: the harness's import path and the view's own name one type twice to qmllint
        property var ring: powerRing

        IconReel {
            id: powerRing
            items: ReelItems.POWER
        }

        Row {
            spacing: 10
            x: 10
            y: 10
            Rectangle {
                id: refFrame
                width: 40 * win.zoom
                height: 41 * win.zoom
                color: Theme.surface
                Text {
                    anchors.centerIn: parent
                    text: "\u{F0904}"
                    font.family: "Symbols Nerd Font"
                    font.pixelSize: 17 * win.zoom
                    color: Theme.textMuted
                }
            }
            Rectangle {
                id: reelFrame
                width: 40 * win.zoom
                height: 41 * win.zoom
                color: Theme.surface
                Item {
                    width: 40
                    height: 41
                    scale: win.zoom
                    transformOrigin: Item.TopLeft
                    IconReelView {
                        anchors.fill: parent
                        reel: win.ring
                        edge: "top"
                        aFrom: 0
                    }
                }
            }
            Rectangle {
                id: clockFrame
                width: 64 * win.zoom
                height: 41 * win.zoom
                color: Theme.surface
                Item {
                    width: 64
                    height: 41
                    scale: win.zoom
                    transformOrigin: Item.TopLeft
                    ClockBarButton {
                        id: clk
                        anchors.centerIn: parent
                        horizontalPixelSize: 15
                        overrideDate: new Date(2026, 10, 8, 18, 18, 18)
                        secondsEnabled: false
                    }
                }
            }
            Rectangle {
                id: siliconFrame
                width: 90 * win.zoom
                height: 41 * win.zoom
                color: Theme.surface
                Item {
                    id: siliconScene
                    width: 90
                    height: 41
                    scale: win.zoom
                    transformOrigin: Item.TopLeft
                    SiliconBarButton {
                        id: sil
                        anchors.centerIn: parent
                        percent: 88
                        liveMotion: false
                        flourishEnabled: false
                    }
                }
            }
        }

        Component.onCompleted: {
            powerRing.snapTo(ReelItems.indexOf(ReelItems.POWER, "lock"));
            console.log("BARINK expect ref_glyph textMuted " + Theme.textMuted);
            console.log("BARINK expect reel_rest textMuted " + Theme.textMuted);
            console.log("BARINK expect clock textMuted " + Theme.textMuted);
            console.log("BARINK expect silicon textMuted " + Theme.textMuted);
            console.log("BARINK surface " + Theme.surface);
            win.plan = [
                { name: "ref_glyph", frame: refFrame },
                { name: "reel_rest", frame: reelFrame },
                { name: "clock", frame: clockFrame },
                { name: "silicon", frame: siliconFrame, crop: true }
            ];
            stepTimer.start();
        }

        function figureOf(item: Item): Item {
            for (let i = 0; i < item.children.length; i++) {
                if (item.children[i].objectName === "siliconFigure")
                    return item.children[i];
            }
            return item;
        }

        Timer {
            id: stepTimer
            interval: 150
            onTriggered: {
                win.at += 1;
                if (win.at >= win.plan.length) {
                    console.log("BARINK RESULT " + (win.fails === 0 && win.outDir !== "" ? "PASS" : "FAIL") + " (" + win.plan.length + " cells, " + win.fails + " failed)");
                    quitTimer.start();
                    return;
                }
                const step = win.plan[win.at];
                grabTimer.start();
            }
        }
        Timer {
            id: grabTimer
            interval: 150
            onTriggered: {
                const step = win.plan[win.at];
                if (step.crop) {
                    // the digits alone: the pill, the fill and the card around them are other colours
                    const fig = win.figureOf(sil.face);
                    const r = fig.mapToItem(step.frame, 0, 0, fig.width, fig.height);
                    console.log("BARINK crop " + step.name + " " + Math.floor(r.x) + " " + Math.floor(r.y) + " "
                                + Math.ceil(r.width) + " " + Math.ceil(r.height));
                }
                const ok = step.frame.grabToImage(r => {
                    if (!r.saveToFile(win.outDir + "/" + step.name + ".png"))
                        win.fails += 1;
                    console.log("BARINK cell " + step.name);
                    stepTimer.start();
                });
                if (!ok) {
                    win.fails += 1;
                    stepTimer.start();
                }
            }
        }
        Timer {
            id: quitTimer
            interval: 50
            onTriggered: Qt.quit()
        }
    }
}
