pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/AudioModel.js" as Model

// =============================================================================
// AudioList.qml -- one tab's rows in a carved box. The rows are mirrored into a ListModel of keys (a Repeater on a derived array rebuilds every delegate on every
// change: a slider under the hand would be destroyed by a stream starting elsewhere), diffed by key, so a refresh touches nothing.
//
// A device tab has the default's rail down its left side (SlotRail: a slot at each device, the ball in one of them) and the well that glides under the default row, on the
// rail's clock, as the launcher's highlight does. A click on a row, or on the rail beside it, makes it the default.
//
// ONE CLOCK PER MOTION: NOTHING HERE ANIMATES A POSITION. The column has no `move` transition: that restarted on every frame of a row's growth and left every row below,
// and everything read from them, a resize behind. A row's height is its own (AudioReveal); a row that comes or goes is an AnimatedListRow, its slide and its height on one
// clock; and the rows below, the rail, the well and the patch lines all read the same numbers in the same frame. The hosts of the patch lines read `plugY(key)` and `rowRight`.
//
// A TAB'S ENTRANCE IS THE NETWORK POPUP'S: the rows on screen fly in from the left on a stagger, and what is past the fold is placed (`enter()`,
// docs/contracts/list_animation.md). Their places hold while they fly, so the rail and the lines have nothing to chase.
// =============================================================================
Item {
    id: list

    property string section: ""
    property var keys: []
    property var service: null
    property var parity: null
    property var popup: null
    property AudioStyle style: AudioStyle {}
    property string fontFamily: "Inter"
    property bool shown: false
    property bool metersOn: true
    property real renderScale: 1
    property string emptyText: ""
    // The slider the wheel is armed on: { key, channel } or null (AudioPopup).
    property var armed: null
    readonly property alias flick: flicker
    readonly property bool scrolling: dressing.moving
    readonly property bool canScroll: flicker.contentHeight > flicker.height + 0.5
    signal scrolled
    readonly property bool hasRail: list.section === "sinks" || list.section === "sources"
    readonly property real _rowX: list.style.rowGap + (list.hasRail ? list.style.railWidth + list.style.rowGap : 0)
    // Where a row ends, in this item's frame: a patch line's start.
    readonly property real rowRight: flicker.x + rowsClip.x + rowsColumn.x + rowsColumn.width
    // How many rows have something to read or something still falling: nobody beats for a silent tab.
    property int meterCount: 0
    // The row under the pointer: the patch bay lifts its line.
    property string hoveredKey: ""

    function feedWheel(px, ad, phase) {
        dressing.wheel({ pixelDelta: Qt.point(0, px), angleDelta: Qt.point(0, ad), phase: phase });
    }

    // ---- the mirror ------------------------------------------------------------------------------------------------------------
    ListModel {
        id: keyModel
    }
    function _have(): var {
        const a = [];
        for (let i = 0; i < keyModel.count; i++)
            if (!keyModel.get(i).leaving)
                a.push(keyModel.get(i).rowKey);
        return a;
    }
    // Every row standing, those that are closing too: a line stays with its row.
    property var standingKeys: []
    function _stand(): void {
        const a = [];
        for (let i = 0; i < keyModel.count; i++)
            a.push(keyModel.get(i).rowKey);
        list.standingKeys = a;
    }
    // A row that arrives after the list has filled opens; the first fill is simply there.
    property bool _settled: false
    function _sync(): void {
        const want = list.keys;
        // Every read of the service hands a new array: most say what the list already shows, and those must cost no frame.
        if (want.length === keyModel.count && want.every((k, i) => keyModel.get(i).rowKey === k && !keyModel.get(i).leaving))
            return;
        // A row that came back in time stays.
        for (let i = 0; i < keyModel.count; i++)
            if (keyModel.get(i).leaving && want.indexOf(keyModel.get(i).rowKey) >= 0)
                keyModel.setProperty(i, "leaving", false);
        const have = list._have();
        // What leaves closes first: its slot is taken away with `sweep`.
        for (let i = 0; i < keyModel.count; i++)
            if (!keyModel.get(i).leaving && want.indexOf(keyModel.get(i).rowKey) < 0) {
                keyModel.setProperty(i, "leaving", true);
                sweep.restart();
            }
        const stay = have.filter(k => want.indexOf(k) >= 0);
        const ops = Model.diffKeys(stay, want);
        // the indices of `ops` are among the rows that stay: translate them past the leaving ones
        const realIndex = i => {
            let seen = 0;
            for (let j = 0; j < keyModel.count; j++) {
                if (keyModel.get(j).leaving)
                    continue;
                if (seen === i)
                    return j;
                seen++;
            }
            return keyModel.count;
        };
        for (const op of ops) {
            if (op.op === "insert")
                keyModel.insert(realIndex(op.at), { rowKey: op.key, leaving: false });
            else if (op.op === "move")
                keyModel.move(realIndex(op.from), realIndex(op.to), 1);
        }
        if (want.length > 0)
            Qt.callLater(() => list._settled = true);
        list._stand();
        list.geometrySerial++;
    }
    onKeysChanged: list._sync()
    Component.onCompleted: list._sync()
    Timer {
        id: sweep
        interval: list.style.resizeMs + 30
        onTriggered: {
            for (let i = keyModel.count - 1; i >= 0; i--)
                if (keyModel.get(i).leaving)
                    keyModel.remove(i);
            list._stand();
            list.geometrySerial++;
        }
    }

    // ---- where rows are ------------------------------------------------------------------------------------------------------------
    property var _rows: ({})
    // Bumped when anything moved a row; the rail, the well and the patch bay read it.
    property int geometrySerial: 0
    onWidthChanged: list.geometrySerial++
    function rowItem(key: string): var {
        return list._rows[key] || null;
    }
    // The rows that are on screen fly in; what is past the fold is placed.
    function enter(): void {
        let rank = 0;
        for (let i = 0; i < rows.count; i++) {
            const r = rows.itemAt(i) as AnimatedListRow;
            if (r && r.y < flicker.contentY + flicker.height && r.y + r.height > flicker.contentY)
                r.enter(rank++);
        }
    }
    // The y of a row's middle in this item's frame, scrolled: where its patch line starts.
    function plugY(key: string): real {
        const r = list._rows[key];
        return r ? flicker.y + rowsColumn.y + r.rowTop + r.rowHeight / 2 - flicker.contentY : -1;
    }
    // The slider under a point of this item, or null: { row, key, channel }.
    function sliderAt(x: real, y: real): var {
        const c = rowsColumn.mapFromItem(list, x, y);
        if (y < 0 || y > list.height)
            return null;
        for (const k in list._rows) {
            const r = list._rows[k];
            if (c.y < r.y || c.y > r.y + r.height)
                continue;
            const ch = r.channelAt(c.x - r.x, c.y - r.y);
            if (ch > -2)
                return { row: r, key: k, channel: ch };
        }
        return null;
    }

    ShadowBox {
        id: boxFill
        anchors.fill: parent
        baseRadius: list.style.listRadius
        surfaceColor: Theme.surface
        backgroundColor: Theme.listBox
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: 1
        shadowWidth: 3
    }

    Flickable {
        id: flicker
        anchors.fill: parent
        anchors.margins: 1
        interactive: false
        clip: true
        contentWidth: width
        contentHeight: rowsColumn.height + list.style.rowGap
        onContentHeightChanged: list.geometrySerial++
        onContentYChanged: {
            list.geometrySerial++;
            list.scrolled();
        }

        // The selected row's ground: one carved well, gliding under the rows on the rail's clock.
        ShadowBox {
            id: well
            objectName: "selectedWell"
            visible: list.hasRail && rail.seated
            x: rowsClip.x + rowsColumn.x
            y: rowsColumn.y + rail.wellTop
            width: rowsColumn.width
            height: rail.wellHeight
            baseRadius: list.style.rowRadius
            surfaceColor: Theme.listBox
            backgroundColor: Theme.panelSunk
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            bevelWidth: 1
            shadowWidth: 3
        }

        Item {
            id: railHost
            x: list.style.rowGap
            y: rowsColumn.y
            visible: list.hasRail && !list.empty
            width: list.style.railWidth
            height: rowsColumn.height
            SlotRail {
                id: rail
                objectName: "defaultRail"
                width: list.style.railWidth
                lineThickness: list.style.railLine
                slotSize: list.style.railDot
                ballSize: list.style.railBall
                travelMs: list.style.travelMs
                settle: list.style.railSettle
                ground: Theme.listBox
                stops: {
                    void list.geometrySerial;
                    void list.service.rowsSerial;
                    if (!list.hasRail)
                        return [];
                    const out = [];
                    for (const k of list.keys) {
                        const r = list._rows[k];
                        if (r && r.row && !r.row.isMonitor)
                            out.push({ key: k, y: r.rowTop + r.rowHeight / 2, top: r.rowTop, height: r.rowHeight });
                    }
                    return out;
                }
                // What the hand asked for, then the graph's own default: the rows catch up a read later, and a click must answer at once.
                currentKey: {
                    if (!list.hasRail)
                        return "";
                    const k = list.section === "sinks" ? "d:sink:" + list.service.railSink : "d:source:" + list.service.railSource;
                    return list.keys.indexOf(k) >= 0 ? k : "";
                }
            }
            MouseArea {
                anchors.fill: parent
                anchors.margins: -3
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    const y = mouse.y + anchors.margins;
                    for (const k in list._rows) {
                        const r = list._rows[k];
                        if (y >= r.y && y <= r.y + r.height && r.row && !r.row.isMonitor)
                            list.service.setDefault(r.row);
                    }
                }
            }
        }

        // The rows fly in under this edge, not over the rail. It stands off them by the bevel a glowing row draws outside its rect.
        Item {
            id: rowsClip
            x: list._rowX - 2
            y: 0
            width: flicker.width - x - list.style.rowGap + 2
            height: flicker.contentHeight
            clip: true
            Column {
                id: rowsColumn
                objectName: "rows"
                x: 2
                y: list.style.rowGap / 2
                width: rowsClip.width - 4
                onHeightChanged: list.geometrySerial++
                Repeater {
                    id: rows
                    model: keyModel
                    delegate: AnimatedListRow {
                        id: slot
                        required property string rowKey
                        required property bool leaving
                        required property int index
                        width: rowsColumn.width
                        virtualSpacing: list.style.rowGap
                        animDuration: list.style.resizeMs
                        staggerMs: list.style.enterStaggerMs
                        contentHeight: inner.item ? inner.item.implicitHeight : 0
                        // A row that arrives once the list has filled opens; a row that goes closes, the slide and the height on one clock.
                        Component.onCompleted: {
                            if (list._settled)
                                slot.rowState = "entering";
                            const m = Object.assign({}, list._rows);
                            m[slot.rowKey] = slot;
                            list._rows = m;
                            list.geometrySerial++;
                        }
                        onLeavingChanged: {
                            slot.animateHeight = true;
                            slot.rowState = slot.leaving ? "leaving" : "rest";
                        }
                        // The tab's entrance: a place kept, a flight on a stagger.
                        function enter(rank: int): void {
                            slot.animateHeight = false;
                            slot.staggerIdx = rank;
                            slot.rowState = "rest";
                            slot.rowState = "entering";
                        }
                        readonly property real rowHeight: Math.max(0, slot.height - list.style.rowGap)
                        readonly property real rowTop: slot.y + list.style.rowGap / 2
                        // How much of the row is here: its line goes with it.
                        readonly property real present: Math.min(1, slot._extent * 2.5) * (1 - Math.min(1, Math.abs(slot.x) / Math.max(1, slot.width)))
                        onPresentChanged: list.geometrySerial++
                        onYChanged: list.geometrySerial++
                        onHeightChanged: list.geometrySerial++
                        readonly property var content: inner.item
                        readonly property var row: inner.item ? inner.item.row : null
                        readonly property bool hovered: !!inner.item && inner.item.hovered === true
                        onHoveredChanged: {
                            if (slot.hovered)
                                list.hoveredKey = slot.rowKey;
                            else if (list.hoveredKey === slot.rowKey)
                                list.hoveredKey = "";
                        }
                        function channelAt(x: real, y: real): int {
                            return inner.item && inner.item.channelAt ? inner.item.channelAt(x, y - list.style.rowGap / 2) : -2;
                        }
                        function wheelStep(s: int, ch: int): void {
                            inner.item.wheelStep(s, ch);
                        }
                        function gestureEnded(): void {
                            inner.item.gestureEnded();
                        }
                        function beat(): void {
                            if (inner.item && inner.item.beat)
                                inner.item.beat();
                        }
                        function openDeviceChoice(from: Item): void {
                            inner.item.openDeviceChoice(from);
                        }
                        readonly property real level: inner.item && inner.item.level !== undefined ? inner.item.level : 0
                        readonly property real flow: inner.item && inner.item.flow !== undefined ? inner.item.flow : 0
                        readonly property bool metering: !!inner.item && (inner.item.meterWanted === true || slot.level > 0 || slot.flow > 0)
                        onMeteringChanged: list.meterCount += slot.metering ? 1 : -1
                        Component.onDestruction: {
                            if (slot.metering)
                                list.meterCount--;
                            const m = Object.assign({}, list._rows);
                            if (m[slot.rowKey] === slot)
                                delete m[slot.rowKey];
                            list._rows = m;
                        }
                        Loader {
                            id: inner
                            anchors.left: parent.left
                            anchors.right: parent.right
                            sourceComponent: list.section === "cards" ? cardRow : streamRow
                        }
                        Component {
                            id: streamRow
                            AudioRow {
                                rowKey: slot.rowKey
                                service: list.service
                                parity: list.parity
                                popup: list.popup
                                style: list.style
                                fontFamily: list.fontFamily
                                shown: list.shown
                                metersOn: list.metersOn
                                renderScale: list.renderScale
                                selected: rail.currentKey === slot.rowKey
                                armedChannel: list.armed && list.armed.key === slot.rowKey ? list.armed.channel : -2
                            }
                        }
                        Component {
                            id: cardRow
                            AudioCardRow {
                                rowKey: slot.rowKey
                                service: list.service
                                popup: list.popup
                                style: list.style
                                fontFamily: list.fontFamily
                            }
                        }
                    }
                }
            }
        }
    }

    readonly property bool empty: list.keys.length === 0
    Text {
        anchors.centerIn: parent
        visible: list.empty
        text: list.emptyText
        font.family: list.fontFamily
        font.pixelSize: list.style.titleSize
        color: Theme.textFaint
    }

    ScrollDressing {
        id: dressing
        anchors.fill: flicker
        flick: flicker
        ground: Theme.listBox
        wheelEnabled: false
    }

    // The popup's one beat reaches the rows through here.
    function beat(): real {
        let top = 0;
        for (const k in list._rows) {
            list._rows[k].beat();
            top = Math.max(top, list._rows[k].level);
        }
        return top;
    }
}
