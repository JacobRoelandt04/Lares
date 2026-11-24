pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../data/SiliconFormat.js" as Fmt

// =============================================================================
// ZoneReadouts.qml -- the GPU zone's live figures: one row, every figure in a slot of fixed width (FigureSlot), centred on the plate
// (ZoneBlock's figures row).
//
//   72 %  ·  58 °C  ·  45.2 W  ·  6.1 / 8.0 GiB      load, temperature, watts, memory -- ONLY WHILE THE CARD IS AWAKE: asleep (D3cold) there is
//                                                    nothing to read and nothing is asked (nvidia-smi runs only for a card that is already up, and
//                                                    the data layer says so by leaving the figures null). The row fades in and out as one (160 ms);
//                                                    the slots never move inside it.
//
// The CPU's three figures are not here: its clock, usage and temperature are seven-segment displays on the board
// (SceneGeometry.SEG7, `SiliconScene.figures`), like the battery's. The CPU plate keeps only its name and its tail.
//
// An unknown figure is the module's dash, never a gap and never "NaN". Who is using the card is the caption's tail ("in use by steam,
// proton"); the whole list is the tip on it (the block's `tip`). `live` says whether the row is there (the plate opens its row's slot for it).
// =============================================================================
Item {
    id: root

    // The board is a theme island and this is live inside its hole: the colours carry their own old values to the new (FadeColor)
    property bool islandArmed: false

    property var vm: null
    property string fontFamily: "Inter"
    property int figureSize: 11
    property real gap: 16                       // the room a separator takes
    property int fadeMs: 160

    readonly property var _gpu: root.vm ? root.vm.gpu : null

    // the row exists while the card is awake and has something to say
    readonly property bool live: root._gpu !== null && root._gpu.awake === true && root._gpu.util !== null
    property real _p: root.live ? 1 : 0
    Behavior on _p {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property real presence: root._p

    // memory: GiB when the card has more than a GiB (it has 8), else MiB; both figures in one unit
    function vramText(used, total) {
        if (typeof used !== "number" || typeof total !== "number" || !isFinite(used) || !isFinite(total) || total <= 0)
            return Fmt.DASH;
        if (total >= 1024)
            return (used / 1024).toFixed(1) + " / " + (total / 1024).toFixed(1) + " GiB";
        return Math.round(used) + " / " + Math.round(total) + " MiB";
    }

    visible: root._p > 0
    opacity: root._p
    implicitWidth: row.width
    implicitHeight: row.height

    component Sep: Item {
        implicitWidth: root.gap
        implicitHeight: dot.implicitHeight
        FadeColor { id: dotFade; token: "textFaint"; active: root.islandArmed; place: root }
        Text {
            id: dot
            x: Math.round((parent.width - width) / 2)
            y: 0
            text: "·"
            color: dotFade.value
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
    }
    component Fig: FigureSlot {
        islandArmed: root.islandArmed
        fontFamily: root.fontFamily
        pixelSize: root.figureSize
    }

    Row {
        id: row
        Fig {
            id: gUtil
            text: Fmt.percent(root._gpu ? root._gpu.util : null)
            template: "000 %"
        }
        Sep {}
        Fig {
            id: gTemp
            text: Fmt.temp(root._gpu ? root._gpu.tempC : null)
            template: "000 °C"
        }
        Sep {}
        Fig {
            id: gWatts
            text: Fmt.watts(root._gpu ? root._gpu.watts : null)
            template: "000.0 W"
        }
        Sep {}
        Fig {
            id: gVram
            text: root.vramText(root._gpu ? root._gpu.vramUsedMB : null, root._gpu ? root._gpu.vramTotalMB : null)
            template: "0.0 / 0.0 GiB"
        }
    }

    // for the probes: where each figure's slot is, as [x, width] in this item's coordinates (the probe holds
    // them against the values: a slot that moves with its value is a jitter)
    function slotGeometry() {
        return [gUtil, gTemp, gWatts, gVram].map(s => [Math.round(s.mapToItem(root, 0, 0).x * 100) / 100, s.width]);
    }
}
