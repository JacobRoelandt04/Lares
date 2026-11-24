pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import ".."

// =============================================================================
// CastChip.qml -- a TV the scan found, parked beside the canvas (docs/contracts/panorama.md section 10). ONE chip per capable device not being cast.
//
//   at rest      the cast glyph and the TV's name; a click turns it into the confirm step IN PLACE
//   confirm      the chip takes the whole parked row (its height is RESERVED by the canvas: nothing under it moves): the TV's name, the honest line
//                about the pairing, and "Cast". Leaving the chip with the pointer (or Escape through the popup) puts it back
//   connecting   the cast's state in words ("Preparing…", "Connecting…", "Retrying…", "Negotiating…", "Stopping…"): instant swaps; a click
//                asks the cast to stop
//   failed       for 6 s the reason ("The TV did not answer", "Cancelled on the TV", "fluxcast failed: <detail>"), then the chip is back
//
// The canvas gives the geometry: `slot` (the chip at rest) and `row` (the whole parked row, the confirm step's room). Nothing here animates a
// size: the chip's rect steps, the words swap, only the hover tint eases.
// =============================================================================
Item {
    id: chip
    objectName: "castChip"

    property var service: null
    property PanoramaStyle style: PanoramaStyle {}
    property string fontFamily: "Inter"
    property color ground: Theme.listBox
    property string deviceId: ""
    property string deviceName: ""
    property rect slot: Qt.rect(0, 0, 0, 0)
    property rect row: Qt.rect(0, 0, 0, 0)

    property bool confirming: false

    readonly property string status: chip.service ? chip.service.castStatusText(chip.deviceId) : ""
    readonly property string notice: chip.service ? chip.service.castNoticeFor(chip.deviceId) : ""
    readonly property bool busy: chip.status !== ""
    readonly property bool _open: chip.confirming && !chip.busy && chip.notice === ""

    // the honest line, said before a first cast (CAST.md: the Wi-Fi card's firmware crashes in about 2 of 3 pairings and the normal link is down ~8 s)
    readonly property string honest: "Pairing can fail and drop Wi-Fi for a few seconds."

    x: chip._open ? chip.row.x : chip.slot.x
    y: chip._open ? chip.row.y : chip.slot.y
    width: chip._open ? chip.row.width : chip.slot.width
    height: chip._open ? chip.row.height : chip.slot.height

    onBusyChanged: if (chip.busy) chip.confirming = false
    function cancel(): void {
        chip.confirming = false;
    }

    property real _hover: area.containsMouse && !chip._open ? 1 : 0
    Behavior on _hover {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }

    ShadowBox {
        anchors.fill: parent
        baseRadius: chip.style.tileRadius
        bevelWidth: chip.style.tileBevel
        shadowWidth: chip.style.tileShadow
        surfaceColor: chip.ground
        backgroundColor: Mix.c(Theme.panelSunk, Theme.surface, chip._hover * 0.5 + (chip._open ? 0.5 : 0))
        bevelColor: Theme.bevel
        shadowColor: Theme.border
    }

    // the glyph (md-cast)
    Text {
        id: glyph
        x: chip.style.castChipPad
        y: chip._open ? chip.style.castChipPad : Math.round((chip.height - height) / 2)
        text: String.fromCodePoint(0xF0118)
        color: chip.notice !== "" ? Theme.error : (chip.busy ? Theme.accent : Theme.textMuted)
        font.family: "Symbols Nerd Font"
        font.pixelSize: chip.style.castMarkSize
    }

    // at rest, connecting and failed: one line
    Text {
        id: line
        visible: !chip._open
        x: glyph.x + glyph.width + 6
        y: Math.round((chip.height - height) / 2)
        width: chip.width - x - chip.style.castChipPad
        elide: Text.ElideRight
        text: chip.notice !== "" ? chip.notice : (chip.busy ? chip.status : chip.deviceName)
        color: chip.notice !== "" ? Theme.error : (chip.busy ? Theme.textPrimary : Theme.textPrimary)
        font.family: chip.fontFamily
        font.pixelSize: chip.style.tileLabelSize
        font.bold: !chip.busy && chip.notice === ""
    }

    // the confirm step
    Text {
        id: nameText
        visible: chip._open
        x: glyph.x + glyph.width + 6
        y: chip.style.castChipPad
        width: chip.width - x - chip.style.castChipPad
        elide: Text.ElideRight
        text: chip.deviceName
        color: Theme.textPrimary
        font.family: chip.fontFamily
        font.pixelSize: chip.style.tileLabelSize
        font.bold: true
    }
    Text {
        id: honestText
        visible: chip._open
        x: chip.style.castChipPad
        y: nameText.y + nameText.height + 4
        width: chip.width - 2 * chip.style.castChipPad - castButton.width - chip.style.castConfirmGap
        wrapMode: Text.WordWrap
        text: chip.honest
        color: Theme.textMuted
        font.family: chip.fontFamily
        font.pixelSize: chip.style.figureSize
    }
    PanoButton {
        id: castButton
        objectName: "castButton"
        visible: chip._open
        x: chip.width - chip.style.castChipPad - width
        y: chip.height - chip.style.castChipPad - height
        text: "Cast"
        accent: true
        ground: Theme.surface
        fontFamily: chip.fontFamily
        height: chip.style.buttonHeight
        onClicked: {
            chip.confirming = false;
            if (chip.service)
                chip.service.castStart(chip.deviceId);
        }
    }

    // a click: the confirm step; while it is connecting a click asks it to stop. The confirm step is left by leaving it.
    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: !chip._open
        cursorShape: Qt.PointingHandCursor
        onClicked: {
            if (!chip.service)
                return;
            if (chip.busy) {
                chip.service.castStop();
            } else {
                // a click on a notice is a click: the notice goes and the confirm step opens (it was ignored for the notice's 6 s)
                if (chip.notice !== "")
                    chip.service.castDismissNotice();
                chip.confirming = true;
            }
        }
    }
    HoverHandler {
        id: leave
        enabled: chip._open
        onHoveredChanged: if (!leave.hovered) chip.confirming = false
    }
}
