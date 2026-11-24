pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/common/components"
import "modules/bridge/body"

// =============================================================================
// tools/dev/qml/bridge_body_sheet.qml -- the bridge's phone at a row of poses, one picture (tools/dev/bridge_body_sheet.sh
// runs it and looks at the PNG). Each cell is a real PhoneStage on the popup's surface, held at a pose by `pinTurn`
// (-1 = at rest, the cached layer; any other = that many turns, drawn live), with a text-heavy stand-in on the display so
// a face that does not sit on its glass shows (the back carries nothing, as in the popup).
//
//   POSES="-1 0.06 0.14 0.25 0.36 0.44 0.5"   SKIN=<skin>   SCALE=1|1.25|2 (a ScaleRoot: the shell's own magnifier)
//   OUT=<png>   CELLS_BACK=1 puts every free cell on its back face first   BUSY=1 lights what lights up
//   TILT=<degrees> tips every held pose about the stage's horizontal axis (90 shows the bottom wall, -90 the top one)
// Prints BBS lines.
// =============================================================================
Window {
    id: root

    readonly property var poses: (Quickshell.env("POSES") || "-1 0.06 0.14 0.25 0.36 0.44 0.5").trim().split(/\s+/).map(Number)
    readonly property string skin: Quickshell.env("SKIN") || "redmagic-10s-pro-moonlight"
    readonly property real factor: parseFloat(Quickshell.env("SCALE") || "1")
    readonly property string out: Quickshell.env("OUT") || "/tmp/bridge_body_sheet.png"
    readonly property bool backFirst: Quickshell.env("CELLS_BACK") === "1"
    readonly property bool busy: Quickshell.env("BUSY") === "1"
    readonly property real tilt: parseFloat(Quickshell.env("TILT") || "0")
    readonly property var n: ({ swaps: 0, waited: 0 })
    readonly property int cellW: 320
    readonly property int cellH: 664

    width: Math.ceil(root.poses.length * root.cellW * root.factor)
    height: Math.ceil(root.cellH * root.factor)
    visible: true
    color: Theme.surface

    Connections {
        target: root
        function onFrameSwapped() {
            root.n.swaps++;
        }
    }
    // offscreen stops rendering when nothing changes: one pixel keeps the frames coming while the probe waits
    Rectangle {
        width: 1
        height: 1
        color: Theme.surface
        RotationAnimation on rotation { from: 0; to: 360; duration: 400; loops: Animation.Infinite }
    }

    Item {
        id: sheet
        width: root.width
        height: root.height
        Rectangle {
            anchors.fill: parent
            color: Theme.surface
        }
        ScaleRoot {
            factor: root.factor
            hostWidth: sheet.width
            hostHeight: sheet.height
            Row {
                Repeater {
                    model: root.poses.length
                    PhoneStage {
                        id: cell
                        required property int index
                        width: root.cellW
                        height: root.cellH
                        skin: root.skin
                        pinTurn: root.poses[cell.index]
                        pinTilt: root.tilt
                        wired: true
                        busy: root.busy
                        partEnabled: ({ power: true, volup: true, voldown: true, cable: true })
                        front: [
                            Item {
                                anchors.fill: parent
                                Column {
                                    anchors.fill: parent
                                    anchors.margins: 12
                                    spacing: 8
                                    Text { text: "LTE   USB   81%"; color: Theme.textMuted; font.pixelSize: 11 }
                                    Text { text: "REDMAGIC 10S Pro"; color: Theme.textPrimary; font.pixelSize: 16; font.bold: true }
                                    Text { text: "On the cable"; color: Theme.textMuted; font.pixelSize: 12 }
                                    Grid {
                                        columns: 3
                                        spacing: 14
                                        Repeater {
                                            model: ["Mirror", "Files", "Send", "Clipboard", "Ring", "Shot"]
                                            Column {
                                                id: tile
                                                required property string modelData
                                                spacing: 4
                                                ShadowBox {
                                                    width: 68
                                                    height: 68
                                                    raised: true
                                                    baseRadius: 14
                                                    surfaceColor: Theme.listBox
                                                }
                                                Text { text: tile.modelData; color: Theme.textPrimary; font.pixelSize: 11; width: 68; horizontalAlignment: Text.AlignHCenter }
                                            }
                                        }
                                    }
                                    Text {
                                        width: parent.width
                                        wrapMode: Text.Wrap
                                        color: Theme.textFaint
                                        font.pixelSize: 10
                                        text: "The quick brown fox jumps over the lazy dog 0123456789. " + "Sphinx of black quartz, judge my vow. ".repeat(6)
                                    }
                                }
                                // the display's own edges, drawn to the pixel: the body's hole must show all four
                                Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Theme.accent; radius: 0 }
                            }
                        ]
                        Component.onCompleted: {
                            if (root.backFirst && cell.pinTurn < 0)
                                cell.flipTo("back");
                        }
                    }
                }
            }
        }
    }

    Timer {
        interval: 250
        repeat: true
        running: true
        onTriggered: {
            root.n.waited += 250;
            if (root.n.swaps >= 8 && root.n.waited >= 2500)
                root.shoot();
            else if (root.n.waited > 60000)
                root.fail("no frames: " + root.n.swaps);
        }
    }
    property bool shot: false
    function shoot() {
        if (root.shot)
            return;
        root.shot = true;
        sheet.grabToImage(function (r) {
            const ok = r.saveToFile(root.out);
            console.log("BBS grab " + (ok ? "saved" : "NOT-SAVED") + " " + root.out + " swaps=" + root.n.swaps + " poses=" + root.poses.join(","));
            Qt.quit();
        });
    }
    function fail(why: string) {
        console.log("BBS FAIL " + why);
        Qt.quit();
    }
}
