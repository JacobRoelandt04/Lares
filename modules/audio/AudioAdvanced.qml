pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// AudioAdvanced.qml -- pavucontrol's Advanced expander: the active port's latency offset (-2000..5000 ms in steps of 10, its range and step), and, on a digital
// output, the formats the receiver takes through (PCM is always there). Each is a write the service reads back.
// =============================================================================
Column {
    id: adv

    property var row: null
    property var service: null
    property AudioStyle style: AudioStyle {}
    property string fontFamily: "Inter"
    property Item overlayItem: null
    property color ground: Theme.listBox         // what it is carved into: the row's
    spacing: 6
    topPadding: 4

    readonly property var _formats: [
        { id: "pcm", label: "PCM" }, { id: "ac3-iec61937", label: "AC-3" }, { id: "eac3-iec61937", label: "E-AC-3" }, { id: "dts-iec61937", label: "DTS" },
        { id: "mpeg-iec61937", label: "MPEG" }, { id: "aac-iec61937", label: "AAC" }, { id: "truehd-iec61937", label: "TrueHD" }, { id: "dtshd-iec61937", label: "DTS-HD" }
    ]

    // The offset, as it stands or as the hand has taken it.
    property real _draft: adv.row ? adv.row.activeOffsetMs : 0
    Timer {
        id: commit
        interval: 300
        onTriggered: adv.service.setOffset(adv.row, adv._draft)
    }
    function _step(d: real): void {
        adv._draft = Math.max(-2000, Math.min(5000, adv._draft + d));
        commit.restart();
    }

    Row {
        visible: !!adv.row && adv.row.activePort !== ""
        height: visible ? 24 : 0
        spacing: 6
        Text {
            height: 24
            verticalAlignment: Text.AlignVCenter
            text: "Latency offset"
            font.family: adv.fontFamily
            font.pixelSize: adv.style.subtitleSize
            color: Theme.textMuted
        }
        AudioGlyphButton {
            objectName: "offsetDown"
            glyph: "\u{F0374}"
            size: 13
            overlayItem: adv.overlayItem
            fontFamily: adv.fontFamily
            onClicked: adv._step(-adv.style.offsetStepMs)
        }
        Text {
            width: 66
            height: 24
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            text: adv._draft.toFixed(2) + " ms"
            font.family: adv.fontFamily
            font.pixelSize: adv.style.figureSize
            color: Theme.textPrimary
        }
        AudioGlyphButton {
            objectName: "offsetUp"
            glyph: "\u{F0415}"
            size: 13
            overlayItem: adv.overlayItem
            fontFamily: adv.fontFamily
            onClicked: adv._step(adv.style.offsetStepMs)
        }
    }

    Flow {
        visible: !!adv.row && adv.row.digital
        width: adv.width
        height: visible ? implicitHeight : 0
        spacing: 8
        Repeater {
            model: adv._formats
            delegate: Item {
                id: fmt
                required property var modelData
                width: Math.ceil(fmtLabel.implicitWidth) + 34
                height: 22
                readonly property bool on: !!adv.row && adv.row.formats.indexOf(fmt.modelData.id) >= 0
                GrooveToggle {
                    anchors.verticalCenter: parent.verticalCenter
                    trackWidth: 26
                    checked: fmt.on
                    surfaceColor: adv.ground
                    onToggled: c => {
                        const next = adv.row.formats.filter(f => f !== fmt.modelData.id);
                        if (c)
                            next.push(fmt.modelData.id);
                        adv.service.setFormats(adv.row, next);
                    }
                }
                Text {
                    id: fmtLabel
                    x: 32
                    height: 22
                    verticalAlignment: Text.AlignVCenter
                    text: fmt.modelData.label
                    font.family: adv.fontFamily
                    font.pixelSize: adv.style.subtitleSize
                    color: Theme.textMuted
                }
            }
        }
    }
}
