pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// PlayerHealthBanner.qml -- the player saying what is wrong with the sound.
//
// A carved strip laid over the head of the card (the record keeps its place; an error is the one
// thing worth covering it for). It reads the service's `health` snapshot and shows, in plain words:
//
//   title    the broken layer ("ACME AUDIO DAC PRO stopped answering", "mpd is not running")
//   words    what that means, in one sentence; for mpd's own errors mpd's words
//   hint     what to do when no button can ("Unplug it and plug it in again")
//   button   ONE, only for a cause a button can cure (MpdHealth.js decides which)
//   "Check again" / "Hide"   small text links; nothing is ever restarted by looking
//
// While an action runs it shows `busyWords` instead and no button; after it, `outcomeWords` for a few
// seconds ("Playing again." or why it did not help). The category's colour is in the inset shadow only,
// the way a header carries its category's: warn for "nothing is moving", error for a broken layer, ok
// for a recovery -- never a second mark for the same fact.
//
// PRESENCE IS ONE FRACTION (`_f`, 260 ms OutCubic): it drives the slide, the fade and the visibility, and
// the whole item costs nothing while it is 0 (not visible, no layout run).
//
// The host sizes it: `width`. Its `implicitHeight` is its content's, so the host places it from that.
// =============================================================================
Item {
    id: root

    // The service's snapshot: { kind, severity, title, words, hint, action:{id,label}|null, device,
    // busy, busyWords, outcome, outcomeWords, shown }.
    property var health: null
    property string fontFamily: "Inter"

    // The ground it is carved into (the card's fill) and the box's own fill.
    property color surfaceColor: Theme.listBox
    property color boxColor: Theme.panelSunk
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color accentColor: Theme.accent
    property color okColor: Theme.ok
    property color warnColor: Theme.warn
    property color errorColor: Theme.error
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow

    property real radius: 10
    property real padding: 10
    property real slide: 10

    signal actionRequested(string id)
    signal checkRequested()
    signal dismissRequested()

    // ---- what is shown ----
    readonly property bool _shown: !!root.health && root.health.shown === true
    readonly property bool _busy: !!root.health && root.health.busy === true
    readonly property string _outcome: root.health ? (root.health.outcome || "") : ""
    // The last content, held while the banner fades out, so it does not empty before it is gone.
    property var _held: null
    on_ShownChanged: if (root._shown) root._held = root.health
    onHealthChanged: if (root._shown) root._held = root.health
    readonly property var _h: root._shown ? root.health : root._held

    readonly property string _title: {
        const h = root._h;
        if (!h) return "";
        if (h.busy) return h.busyWords || "";
        if (h.outcome === "ok") return h.outcomeWords || "Back on track.";
        return h.title || "";
    }
    readonly property string _words: {
        const h = root._h;
        if (!h || h.busy) return "";
        if (h.outcome === "failed") return h.outcomeWords || "";
        return h.outcome === "ok" ? "" : (h.words || "");
    }
    readonly property string _hint: {
        const h = root._h;
        if (!h || h.busy || h.outcome === "ok") return "";
        // After a failed attempt the hint is the next step, which the title below now names.
        return h.hint || "";
    }
    readonly property var _action: {
        const h = root._h;
        return h && !h.busy && h.outcome !== "ok" ? h.action : null;
    }
    // The strip's colour, in its inset shadow only.
    readonly property color _tint: {
        const h = root._h;
        const base = root.borderColor;
        if (!h) return base;
        if (h.outcome === "ok") return Mix.c(base, root.okColor, 0.6);
        if (h.busy) return base;
        return Mix.c(base, h.severity === "warn" ? root.warnColor : root.errorColor, 0.6);
    }

    property real _f: root._shown ? 1 : 0
    Behavior on _f {
        NumberAnimation {
            duration: 260
            easing.type: Easing.OutCubic
        }
    }

    visible: root._f > 0.001
    opacity: Math.min(1, root._f * 2)
    implicitHeight: Math.ceil(box.implicitHeight)
    height: implicitHeight
    transform: Translate { y: -root.slide * (1 - root._f) }

    ShadowBox {
        id: box
        anchors.left: parent.left
        anchors.right: parent.right
        implicitHeight: Math.ceil(col.implicitHeight + root.padding * 2)
        height: implicitHeight
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        bevelColor: root.bevelColor
        shadowColor: root._tint
        backgroundColor: root.boxColor
        bevelWidth: 1
        shadowWidth: 3

        Item {
            id: inner
            x: root.padding
            y: root.padding
            width: box.width - root.padding * 2
            height: col.implicitHeight

            Column {
                id: col
                width: inner.width - (btn.visible ? btn.width + 10 : 0)
                spacing: 2

                Text {
                    width: parent.width
                    text: root._title
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: 12
                    font.bold: true
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    visible: text.length > 0
                    text: root._words
                    color: root.mutedColor
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width
                    visible: text.length > 0
                    text: root._hint
                    color: root.textColor
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                }
                // small, muted, no button chrome: only the pointer announces them
                Row {
                    id: links
                    spacing: 12
                    visible: !!root._h && !root._busy && root._outcome !== "ok"
                    topPadding: 2
                    Text {
                        id: checkLink
                        text: "Check again"
                        color: checkArea.containsMouse ? root.accentColor : root.faintColor
                        font.family: root.fontFamily
                        font.pixelSize: 11
                        MouseArea {
                            id: checkArea
                            anchors.fill: parent
                            anchors.margins: -3
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.checkRequested()
                        }
                    }
                    Text {
                        text: "Hide"
                        color: hideArea.containsMouse ? root.accentColor : root.faintColor
                        font.family: root.fontFamily
                        font.pixelSize: 11
                        MouseArea {
                            id: hideArea
                            anchors.fill: parent
                            anchors.margins: -3
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.dismissRequested()
                        }
                    }
                }
            }

            RaisedButton {
                id: btn
                visible: !!root._action
                text: root._action ? root._action.label : ""
                accent: true
                fontFamily: root.fontFamily
                fontPixelSize: 11
                horizontalPadding: 12
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                surfaceColor: root.boxColor
                plateauColor: root.buttonPlateauColor
                plateauHoverColor: root.buttonPlateauHoverColor
                bevelColor: root.buttonBevelColor
                shadowColor: root.buttonShadowColor
                accentColor: root.accentColor
                onClicked: if (root._action) root.actionRequested(root._action.id)
            }
        }
    }
}
