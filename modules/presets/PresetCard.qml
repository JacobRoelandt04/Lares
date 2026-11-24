pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/float"

// =============================================================================
// PresetCard.qml -- one saved desktop: its name and size over its face (PresetFace: the workspaces as tiled mini screens), and two buttons.
//
//   Load   REPLACES: whatever is open and not in the preset closes. The first click asks the tool what would close (`plan`); with anything
//          to close the button turns into "Close N windows?" in the error tone and a second click within `confirmMs` loads (the user's
//          rule, 2026-11-21: confirm first). The pointer leaving the card, or the time running out, puts it back. Nothing to close: it
//          loads at once.
//   Add    keeps everything open and adds what the preset has that is missing. Never asks.
//   Right click  the popup's menu (Save over, Rename, Delete): `menuAsked(x, y)` in this card's frame.
//   A deleted card (`row.deleted`, its Undo window) fades its face and offers one Undo button, draining (UndoDrainButton).
//
// A FloatCard on the popup's one FloatClock (the theme popup's float: dealt in, sways, lifts and leans under the hand). The face and the
// title are ONE held texture (a mipmapped layer at `faceScale` x the glass): small tiles under a slow rotation shimmer, a texture does not.
// The buttons are live (their hover and press move); the input is the card's own, inside the FloatCard, so it lands where it is drawn.
// =============================================================================
Item {
    id: card

    required property PresetsStyle style
    required property var row
    property FloatClock clock: null
    property int seed: 1
    property int order: 0
    property bool current: false
    property var appLookup: null
    property string fontFamily: "Inter"
    property var service: null

    signal loadAsked(string mode)
    signal menuAsked(real x, real y)
    signal hoverEntered()
    signal hoverLeft()

    readonly property bool deleted: !!card.row && card.row.deleted === true
    readonly property string name: card.row ? String(card.row.name) : ""
    // the title's rect in this card's frame (the popup lays its rename field over it)
    readonly property rect titleRect: Qt.rect(card.style.cardPadding, card.style.cardPadding, card.width - 2 * card.style.cardPadding, card.style.titleSize + 6)

    width: card.style.cardWidth
    height: Math.ceil(2 * card.style.cardPadding + card.style.titleSize + 6 + card.style.titleGap + card.style.faceHeight + card.style.footGap + card.style.buttonHeight)

    // ---- Load's confirm ------------------------------------------------------------------------------------
    property bool confirming: false
    property int closeCount: 0
    property bool planning: false
    function askLoad(): void {
        if (card.deleted || card.planning)
            return;
        if (card.confirming) {
            card.confirming = false;
            confirmTimer.stop();
            card.loadAsked("replace");
            return;
        }
        if (!card.service || !card.service.confirmReplace) {
            card.loadAsked("replace");
            return;
        }
        card.planning = true;
        card.service.plan(card.name, "replace", d => {
            card.planning = false;
            const n = d && d.close ? d.close.length : 0;
            if (n > 0) {
                card.closeCount = n;
                card.confirming = true;
                confirmTimer.restart();
            } else if (d && d.failed !== true) {
                card.loadAsked("replace");
            }
        });
    }
    function cancelConfirm(): void {
        card.confirming = false;
        confirmTimer.stop();
    }
    Timer {
        id: confirmTimer
        interval: card.style.confirmMs
        onTriggered: card.confirming = false
    }

    // ---- the pointer: hover, lean, the right click ------------------------------------------------------------
    property real _px: 0
    property real _py: 0
    HoverHandler {
        id: hover
        onPointChanged: {
            card._px = Math.max(-1, Math.min(1, hover.point.position.x / Math.max(1, card.width) * 2 - 1));
            card._py = Math.max(-1, Math.min(1, hover.point.position.y / Math.max(1, card.height) * 2 - 1));
        }
        onHoveredChanged: {
            if (hover.hovered) {
                card.hoverEntered();
            } else {
                card.hoverLeft();
                card.cancelConfirm();
            }
        }
    }
    TapHandler {
        acceptedButtons: Qt.RightButton
        enabled: !card.deleted
        onTapped: (ev, button) => {
            body.kick(card.style.clickKick);
            card.menuAsked(ev.position.x, ev.position.y);
        }
    }

    FloatCard {
        id: body
        anchors.fill: parent
        clock: card.clock
        style: card.style
        seed: card.seed
        order: card.order
        lifted: card.current && !card.deleted
        tilting: hover.hovered && card.current && !card.deleted
        pointerX: card._px
        pointerY: card._py

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
        // ONE texture: the title, the size and the face, with a margin the carve's bevel can land in.
        Item {
            id: held
            readonly property real m: 2
            x: card.style.cardPadding - held.m
            y: card.style.cardPadding - held.m
            width: card.width - 2 * card.style.cardPadding + 2 * held.m
            height: card.style.titleSize + 6 + card.style.titleGap + card.style.faceHeight + 2 * held.m
            opacity: card.deleted ? 0.35 : 1
            layer.enabled: true
            layer.smooth: true
            layer.mipmap: true
            layer.textureSize: Qt.size(Math.ceil(held.width * dev.value * card.style.faceScale), Math.ceil(held.height * dev.value * card.style.faceScale))

            Text {
                id: title
                x: held.m
                y: held.m
                width: held.width - 2 * held.m - meta.implicitWidth - 8
                height: card.style.titleSize + 6
                verticalAlignment: Text.AlignVCenter
                text: card.name
                color: Theme.textPrimary
                font.family: card.fontFamily
                font.pixelSize: card.style.titleSize
                font.bold: true
                elide: Text.ElideRight
            }
            Text {
                id: meta
                x: held.width - held.m - Math.ceil(meta.implicitWidth)
                y: held.m
                height: card.style.titleSize + 6
                verticalAlignment: Text.AlignVCenter
                text: card.row ? (card.row.windows + (card.row.windows === 1 ? " window" : " windows")) : ""
                color: Theme.textMuted
                font.family: card.fontFamily
                font.pixelSize: card.style.metaSize
            }
            PresetFace {
                x: held.m
                y: held.m + card.style.titleSize + 6 + card.style.titleGap
                width: held.width - 2 * held.m
                height: card.style.faceHeight
                face: card.row ? card.row.face : null
                style: card.style
                appLookup: card.appLookup
                ground: Theme.surface
            }
        }

        // ---- the foot: Load and Add, or the deleted card's Undo ----------------------------------------------
        Item {
            id: foot
            x: card.style.cardPadding
            y: card.height - card.style.cardPadding - card.style.buttonHeight
            width: card.width - 2 * card.style.cardPadding
            height: card.style.buttonHeight
            readonly property real half: Math.floor((foot.width - card.style.buttonGap) / 2)

            PresetButton {
                id: loadBtn
                objectName: "presetLoad"
                visible: !card.deleted
                width: foot.half
                height: foot.height
                fontFamily: card.fontFamily
                text: card.confirming ? ("Close " + card.closeCount + (card.closeCount === 1 ? " window?" : " windows?")) : "Load"
                accent: card.confirming
                danger: card.confirming
                onClicked: {
                    body.kick(card.style.clickKick);
                    card.askLoad();
                }
            }
            PresetButton {
                id: addBtn
                objectName: "presetAdd"
                visible: !card.deleted
                x: foot.width - foot.half
                width: foot.half
                height: foot.height
                fontFamily: card.fontFamily
                text: "Add"
                onClicked: {
                    body.kick(card.style.clickKick);
                    card.cancelConfirm();
                    card.loadAsked("add");
                }
            }
            UndoDrainButton {
                id: undoBtn
                objectName: "presetUndo"
                visible: card.deleted
                anchors.fill: parent
                text: "Deleted"
                undoText: "Undo"
                drainMs: card.service ? card.service.undoMs : 5000
                fontFamily: card.fontFamily
                surfaceColor: Theme.surface
                shadowToAlpha: true
                onUndoClicked: {
                    if (card.service)
                        card.service.undo(card.name);
                }
            }
        }
    }

    function _armUndo(): void {
        if (card.deleted && card.service) {
            const left = card.service.undoLeft(card.name);
            if (left > 0)
                undoBtn.arm(left);
        } else {
            undoBtn.disarm();
        }
    }
    onDeletedChanged: card._armUndo()
    Component.onCompleted: card._armUndo()
}
