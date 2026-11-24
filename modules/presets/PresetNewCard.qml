pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/float"

// =============================================================================
// PresetNewCard.qml -- the last card: the desktop as it is NOW (PresetFace of the live capture), a name field and Save. Enter or Save makes
// a preset of it. A name that is empty or taken is refused with the shell's wiggle (Shake) and the field keeps its text, selected; the tip
// line under the title says why ("dev exists: right-click it to save over").
//
// The same float, size and layer as a PresetCard, so the grid is one material.
// =============================================================================
Item {
    id: card

    required property PresetsStyle style
    property FloatClock clock: null
    property int seed: 7
    property int order: 0
    property bool current: false
    property var appLookup: null
    property string fontFamily: "Inter"
    property var service: null

    signal saved(string name)
    signal hoverEntered()
    signal hoverLeft()

    readonly property alias field: nameField
    property string problem: ""

    width: card.style.cardWidth
    height: Math.ceil(2 * card.style.cardPadding + card.style.titleSize + 6 + card.style.titleGap + card.style.faceHeight + card.style.footGap + card.style.buttonHeight)

    function submit(): void {
        if (!card.service)
            return;
        const n = nameField.text.trim();
        card.service.save(n, false, (ok, reason) => {
            if (ok) {
                card.problem = "";
                nameField.text = "";
                card.saved(n);
                return;
            }
            card.problem = reason === "exists" ? n + " exists: right-click it to save over"
                : reason === "name" ? "A name, up to 40 characters"
                : "Could not save";
            shake.play();
            nameField.forceFocus();
        });
    }

    property real _px: 0
    property real _py: 0
    HoverHandler {
        id: hover
        onPointChanged: {
            card._px = Math.max(-1, Math.min(1, hover.point.position.x / Math.max(1, card.width) * 2 - 1));
            card._py = Math.max(-1, Math.min(1, hover.point.position.y / Math.max(1, card.height) * 2 - 1));
        }
        onHoveredChanged: hover.hovered ? card.hoverEntered() : card.hoverLeft()
    }

    Shake {
        id: shake
        amplitude: card.style.shakePx
    }

    FloatCard {
        id: body
        anchors.fill: parent
        clock: card.clock
        style: card.style
        seed: card.seed
        order: card.order
        lifted: card.current
        tilting: false

        ShadowBox {
            anchors.fill: parent
            baseRadius: card.style.cardRadius
            raised: true
            shadowToAlpha: true
            surfaceColor: Theme.surface
            backgroundColor: Theme.surface
            bevelColor: Theme.bevel
            shadowColor: Theme.shadowDeep
            bevelWidth: 1
            shadowWidth: card.style.shadowWidth
        }

        DeviceScale {
            id: dev
        }
        Item {
            id: held
            readonly property real m: 2
            x: card.style.cardPadding - held.m
            y: card.style.cardPadding - held.m
            width: card.width - 2 * card.style.cardPadding + 2 * held.m
            height: card.style.titleSize + 6 + card.style.titleGap + card.style.faceHeight + 2 * held.m
            layer.enabled: true
            layer.smooth: true
            layer.mipmap: true
            layer.textureSize: Qt.size(Math.ceil(held.width * dev.value * card.style.faceScale), Math.ceil(held.height * dev.value * card.style.faceScale))

            Text {
                x: held.m
                y: held.m
                width: held.width - 2 * held.m
                height: card.style.titleSize + 6
                verticalAlignment: Text.AlignVCenter
                text: card.problem !== "" ? card.problem : "Save this desktop"
                color: card.problem !== "" ? Theme.error : Theme.textMuted
                font.family: card.fontFamily
                font.pixelSize: card.problem !== "" ? card.style.metaSize : card.style.titleSize
                font.bold: card.problem === ""
                elide: Text.ElideRight
            }
            PresetFace {
                objectName: "presetNewFace"
                x: held.m
                y: held.m + card.style.titleSize + 6 + card.style.titleGap
                width: held.width - 2 * held.m
                height: card.style.faceHeight
                face: card.service && card.service.current ? card.service.current.face : null
                style: card.style
                appLookup: card.appLookup
                ground: Theme.surface
            }
        }

        Item {
            id: foot
            x: card.style.cardPadding
            y: card.height - card.style.cardPadding - card.style.buttonHeight
            width: card.width - 2 * card.style.cardPadding
            height: card.style.buttonHeight
            readonly property real half: Math.floor((foot.width - card.style.buttonGap) / 2)

            CarvedSearchField {
                id: nameField
                objectName: "presetName"
                width: foot.width - saveBtn.width - card.style.buttonGap
                height: foot.height
                placeholder: "Name, e.g. dev"
                glyph: ""
                escapeClears: false
                fontFamily: card.fontFamily
                surfaceColor: Theme.surface
                transform: Translate {
                    x: shake.offset
                }
                onEdited: card.problem = ""
                Keys.onReturnPressed: card.submit()
                Keys.onEnterPressed: card.submit()
            }
            PresetButton {
                id: saveBtn
                objectName: "presetSave"
                x: foot.width - width
                width: Math.ceil(Math.max(64, implicitWidth))
                height: foot.height
                fontFamily: card.fontFamily
                text: "Save"
                accent: nameField.text.trim() !== ""
                onClicked: card.submit()
            }
        }
    }
}
