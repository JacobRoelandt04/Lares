pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/AudioModel.js" as Model

// =============================================================================
// AudioSockets.qml -- the Playback and Recording tabs' devices: a carved box beside the list, in the list's material and on the list's rhythm, so socket N stands beside
// row N and a line from the one to the other lies flat. A click makes a device the default (the rail and the well, as on Outputs); a line lands on a socket's left end.
//
// The column's width is the room a device's name needs and never gives any of it to the waves: what they need, the list gives (AudioPopup, `gap`).
// =============================================================================
Item {
    id: column

    property string section: "playback"
    property var service: null
    property AudioStyle style: AudioStyle {}
    property string fontFamily: "Inter"
    property var glyphs: null
    // The socket a dragged line hangs over, by device name.
    property string dropName: ""
    // The socket under the pointer, by device name: the bay lifts its lines.
    property string hoveredName: ""

    readonly property var devices: {
        void column.service.rowsSerial;
        const r = column.service.rows;
        // a monitor is a socket only while something records it: then it is where a line has to land
        return column.section === "playback" ? r.sinks : r.sources.filter(s => !s.isMonitor || s.streams > 0);
    }
    readonly property real _top: 1 + column.style.rowGap
    // Where a socket starts, in this item's frame: a patch line's end.
    readonly property real cellLeft: 1 + column.style.rowGap
    readonly property real pitch: column.devices.length === 0 ? 0 : Math.min(column.style.socketPitch, (column.height - 2 * column._top + column.style.rowGap) / column.devices.length)
    readonly property real cellHeight: Math.max(0, column.pitch - column.style.rowGap)

    ListModel {
        id: socketModel
    }
    function _sync(): void {
        const want = column.devices.map(d => d.key);
        const have = [];
        for (let i = 0; i < socketModel.count; i++)
            have.push(socketModel.get(i).rowKey);
        for (const op of Model.diffKeys(have, want)) {
            if (op.op === "remove")
                socketModel.remove(op.at);
            else if (op.op === "insert")
                socketModel.insert(op.at, { rowKey: op.key });
            else
                socketModel.move(op.from, op.to, 1);
        }
    }
    onDevicesChanged: column._sync()
    Component.onCompleted: column._sync()

    function socketIndex(name: string): int {
        for (let i = 0; i < column.devices.length; i++)
            if (column.devices[i].name === name)
                return i;
        return -1;
    }
    function socketCentre(index: int): real {
        return column._top + index * column.pitch + column.cellHeight / 2;
    }
    function socketNameAt(y: real): string {
        for (let i = 0; i < column.devices.length; i++)
            if (Math.abs(y - column.socketCentre(i)) <= column.pitch / 2)
                return column.devices[i].name;
        return "";
    }

    ShadowBox {
        anchors.fill: parent
        baseRadius: column.style.listRadius
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    // The default's ground and marker: the same well and rail as Outputs, one clock.
    readonly property var _stops: {
        const out = [];
        for (let i = 0; i < column.devices.length; i++) {
            if (column.devices[i].isMonitor)
                continue;
            const c = column.socketCentre(i);
            out.push({ key: column.devices[i].key, y: c, top: c - column.cellHeight / 2, height: column.cellHeight });
        }
        return out;
    }
    // What the hand asked for, then the graph's own default: the rows catch up a read later, and a click must answer at once.
    readonly property string _defaultKey: {
        const k = column.section === "playback" ? "d:sink:" + column.service.railSink : "d:source:" + column.service.railSource;
        return column.devices.some(x => x.key === k) ? k : "";
    }
    readonly property real _cellRight: rail.x - column.style.rowGap
    ShadowBox {
        objectName: "socketWell"
        visible: rail.seated
        x: column.cellLeft
        y: rail.wellTop
        width: column._cellRight - x
        height: rail.wellHeight
        baseRadius: column.style.rowRadius
        surfaceColor: Theme.listBox
        backgroundColor: Theme.panelSunk
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }
    SlotRail {
        id: rail
        objectName: "socketRail"
        x: column.width - width - column.style.rowGap - 1
        width: column.style.railWidth
        lineThickness: column.style.railLine
        slotSize: column.style.railDot
        ballSize: column.style.railBall
        travelMs: column.style.travelMs
        settle: column.style.railSettle
        ground: Theme.listBox
        stops: column._stops
        currentKey: column._defaultKey
    }

    Repeater {
        model: socketModel
        delegate: Item {
            id: socket
            required property string rowKey
            required property int index
            objectName: "socket:" + socket.rowKey
            x: column.cellLeft
            y: column._top + socket.index * column.pitch
            width: column._cellRight - x
            height: column.cellHeight
            readonly property var dev: {
                void column.service.rowsSerial;
                return column.service.rowOf(socket.rowKey);
            }
            readonly property bool isDefault: column._defaultKey === socket.rowKey
            readonly property bool hovered: hit.containsMouse
            onHoveredChanged: {
                const n = socket.dev ? socket.dev.name : "";
                if (socket.hovered)
                    column.hoveredName = n;
                else if (column.hoveredName === n)
                    column.hoveredName = "";
            }
            property real _hover: socket.hovered && !socket.isDefault ? 1 : 0
            Behavior on _hover {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
            // A line hangs over it: this is where it would land.
            property real _target: !!socket.dev && column.dropName === socket.dev.name ? 1 : 0
            Behavior on _target {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
            Rectangle {
                anchors.fill: parent
                radius: column.style.rowRadius
                visible: socket._hover + socket._target > 0.001
                color: Mix.c(Mix.c(Theme.listBox, Theme.panelSunk, socket._hover), Theme.accent, 0.14 * socket._target)
            }
            Text {
                x: 10
                height: parent.height
                width: 18
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                font.family: "Symbols Nerd Font"
                font.pixelSize: column.style.glyphSize
                color: Theme.textMuted
                text: !socket.dev || !column.glyphs ? "" : socket.dev.kind === "sink" ? column.glyphs.outputGlyph(socket.dev.type, 1, false) : column.glyphs.inputGlyph(false)
            }
            Text {
                objectName: "socketName"
                x: 34
                width: parent.width - x - 6
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                lineHeight: 0.95
                text: socket.dev ? socket.dev.shortName : ""
                font.family: column.fontFamily
                font.pixelSize: column.style.subtitleSize
                font.bold: socket.isDefault
                color: Theme.textPrimary
            }
            // Its slot on the rail is part of it.
            MouseArea {
                id: hit
                anchors.fill: parent
                anchors.rightMargin: -(column.width - column._cellRight - x)
                hoverEnabled: true
                cursorShape: socket.isDefault ? Qt.ArrowCursor : Qt.PointingHandCursor
                onClicked: {
                    if (socket.dev)
                        column.service.setDefault(socket.dev);
                }
            }
        }
    }
}
