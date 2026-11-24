//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/osd"
import "modules/common/theme"

// =============================================================================
// dictation_probe_caption.qml -- the dictation's caption card (modules/osd/kinds/OsdCaption.qml, the OSD's kind "caption") in its
// states, each on the surface the engine draws under an OSD card, for tools/dev/dictation_probe_caption.sh's sheet. Offscreen only
// (the runner): one grab of the window to DICTCAP_GRAB, then quit.
//
// Cells: a window take waiting for sound; its live words (two written sentences, the sentence being spoken muted after them); a
// long transcript (older lines scrolled up under the top fade); a voice ask; the same long transcript in the fullscreen pill.
// Prints `DICTCAP size <cell> <w>x<h> (style <w>x<h>)` per cell and `DICTCAP RESULT PASS|FAIL`: every card at the style's extent.
// =============================================================================
ShellRoot {
    id: root

    readonly property string grabPath: Quickshell.env("DICTCAP_GRAB") || ""
    property int bad: 0

    OsdStyle {
        id: osdStyle
    }

    readonly property var long: ["The town was built on the old trade road, where the river bends twice before it reaches the sea.",
        "Its market drew people from three valleys away, and the bridge was for a long time the only way across.",
        "When the railway came, the road lost its traffic within a single summer,", "and the market moved to the station square."]
    readonly property var cells: [
        { label: "window take: waiting", o: "h", c: { mode: "source", head: "Waiting for sound from Zen", lines: [], live: "", hint: "No speech yet" } },
        { label: "window take: live words", o: "h", c: { mode: "source", head: "Transcribing Zen", lines: ["The town was built on the old trade road."],
                                                       live: "Its market drew people from three valleys", hint: "" } },
        { label: "window take: long (top fade)", o: "h", c: { mode: "source", head: "Transcribing Zen", lines: root.long, live: "and the old bridge", hint: "" } },
        { label: "voice ask", o: "h", c: { mode: "ask", head: "Ask the model", lines: ["What is the latest commit abbreviation in this repository?"],
                                         live: "", hint: "" } },
        { label: "fullscreen pill: long", o: "pill", c: { mode: "source", head: "Transcribing Zen", lines: root.long, live: "and the old bridge", hint: "" } }
    ]

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 600
        implicitHeight: col.implicitHeight + 24
        color: Theme.listBox

        Rectangle {
            id: sheet
            width: 600
            height: col.implicitHeight + 24
            color: Theme.listBox
            Column {
                id: col
                x: 12
                y: 12
                spacing: 10
                Repeater {
                    model: root.cells.length
                    delegate: Column {
                        id: cell
                        required property int index
                        readonly property var d: root.cells[cell.index]
                        spacing: 4
                        Text {
                            text: cell.d.label
                            color: Theme.textMuted
                            font.family: "Inter"
                            font.pixelSize: 11
                        }
                        Rectangle {
                            // the surface the engine (or the pill) draws under the card
                            width: content.implicitWidth
                            height: content.implicitHeight
                            radius: 14
                            color: Theme.surface
                            OsdContent {
                                id: content
                                anchors.fill: parent
                                kind: "caption"
                                orientation: cell.d.o
                                interactive: false
                                style: osdStyle
                                payload: ({ kind: "caption", key: "dictation", caption: cell.d.c })
                                Component.onCompleted: {
                                    const e = osdStyle.extentOf("caption", cell.d.o);
                                    const ok = content.implicitWidth === e.w && content.implicitHeight === e.h;
                                    if (!ok)
                                        root.bad += 1;
                                    console.log("DICTCAP size " + cell.d.label + " " + content.implicitWidth + "x" + content.implicitHeight
                                                + " (style " + e.w + "x" + e.h + ")" + (ok ? "" : " FAIL"));
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Timer {
        interval: 1200
        running: true
        onTriggered: {
            if (root.grabPath === "") {
                console.log("DICTCAP RESULT FAIL (no runner: DICTCAP_GRAB unset)");
                Qt.quit();
                return;
            }
            sheet.grabToImage(r => {
                r.saveToFile(root.grabPath);
                console.log("DICTCAP RESULT " + (root.bad === 0 ? "PASS" : "FAIL"));
                Qt.quit();
            });
        }
    }
}
