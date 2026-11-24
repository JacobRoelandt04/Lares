pragma ComponentBehavior: Bound
// qmllint disable incompatible-type

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "modules/common/theme"
import "modules/launcher"
import "modules/launcher/browse"

// tools/dev/qml/launcher_answers_sheet.qml -- every kind of quick answer as its row, at rest and highlighted, on the list's ground (the
// popup's surface), for the report: tools/dev/launcher_answers_sheet.sh renders it light and dark at 1x and 1.25. LAS_DATA is a JSON array of
// { label, answer, copied } (made from the stand-in child's canned replies), LAS_OUT the PNG.
Window {
    id: win
    visible: true
    color: "#808080"
    width: stage.width
    height: stage.height

    property var entries: []
    FileView {
        id: file
        path: Quickshell.env("LAS_DATA") || ""
        blockLoading: true
        printErrors: false
    }
    Component.onCompleted: {
        try {
            win.entries = JSON.parse(file.text());
        } catch (e) {
            console.log("LAS FAIL data: " + e);
        }
    }

    LauncherTune {
        id: sheetTune
        fontFamily: Quickshell.env("LAS_FONT") || "Inter"
    }
    readonly property real rowH: sheetTune.iconSize + 2 * sheetTune.rowInset
    readonly property real cellW: sheetTune.listWidth
    readonly property real labelW: 96

    Rectangle {
        id: stage
        width: win.labelW + 2 * win.cellW
        height: win.entries.length * (win.rowH + 6) + 6
        color: Theme.surface
        Column {
            x: 0
            y: 3
            spacing: 6
            Repeater {
                model: win.entries
                delegate: Item {
                    id: line
                    required property var modelData
                    width: stage.width
                    height: win.rowH
                    Text {
                        x: 12
                        y: Math.round((parent.height - height) / 2)
                        text: line.modelData.label
                        color: Theme.textFaint
                        font.family: "Inter"
                        font.pixelSize: 10
                    }
                    AnswerRow {
                        x: win.labelW + 12
                        width: win.cellW - 24
                        height: win.rowH
                        tune: sheetTune
                        answer: line.modelData.answer
                        copied: line.modelData.copied === true
                        selected: false
                    }
                    AnswerRow {
                        x: win.labelW + win.cellW + 12
                        width: win.cellW - 24
                        height: win.rowH
                        tune: sheetTune
                        answer: line.modelData.answer
                        copied: line.modelData.copied === true
                        selected: true
                    }
                }
            }
        }
    }

    Timer {
        interval: 700
        running: win.entries.length > 0
        onTriggered: stage.grabToImage(r => {
            r.saveToFile(Quickshell.env("LAS_OUT") || "/tmp/las.png");
            console.log("LAS saved " + r.image.width + "x" + r.image.height);
            Qt.quit();
        })
    }
    Timer {
        interval: 15000
        running: true
        onTriggered: {
            console.log("LAS FAIL timeout");
            Qt.quit();
        }
    }
}
