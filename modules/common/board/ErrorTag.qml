pragma ComponentBehavior: Bound

import QtQuick

import "../components"

// =============================================================================
// ErrorTag.qml -- a part's error, as a small tag beside the part (silicon: the battery's, beside the charge-limit DIP switch).
//
// An error's words ("The charge limit is not available on this machine") belong where the thing that was
// refused is: next to the part. It is a STATUS, not a button, so it is CARVED (the language's rule: containers, fields and status cards are carved, buttons stand
// proud), in the error colour, and it takes no input of its own.
//
//   text       the error's words; "" is none. The tag is there for as long as the error stands (the view model
//              clears it on the next intent in the zone or after `errorMs`) -- nothing here times it out.
//   TEXT SWAPS ARE INSTANT; only PRESENCE fades (160 ms), and the words that were up stay up while it fades out.
//   Words that do not fit `maxWidth` wrap to `maxLines` lines and are elided after them; the whole text is a hover tip,
//   like the plates' tails.
//
// The tag floats over the board, a ground that is not fixed, so the carved box is drawn to ALPHA (`surfaceColor:
// transparent`, a translucent fill: CLAUDE.md, "a ShadowBox over a ground that is not fixed"), the way HoverTip's bubble is.
// Its size is whole pixels (text lands on the grid) and measured from TextMetrics, never read back from the Text.
// =============================================================================
Item {
    id: root

    // ---- in ----
    property string text: ""
    property Item overlayItem: null           // where the tip floats (the popup's overlay layer)
    property string fontFamily: "Inter"
    property int pixelSize: 11
    property real maxWidth: 170               // the widest the tag grows; longer words wrap, and are elided after `maxLines`
    property int maxLines: 2
    property real padH: 8
    property real padV: 5
    property real radius: 8
    property real fillOpacity: 0.88
    property int fadeMs: 160

    // ---- for the probes ----
    readonly property real presence: root._p
    readonly property bool truncated: label.truncated

    // the words are held while the presence fades out
    property string _held: ""
    function _sync() {
        // read the words, not `_p`: a change handler runs before the bindings that depend on the property
        if (root.text !== "")
            root._held = root.text;
    }
    onTextChanged: root._sync()
    Component.onCompleted: root._sync()

    property real _p: root.text !== "" ? 1 : 0
    Behavior on _p {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    visible: root._p > 0
    opacity: root._p

    TextMetrics {
        id: metrics
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize
        text: root._held
    }

    // The width comes from the words' advance (never from the Text); the height from the lines they take at that width.
    implicitWidth: Math.ceil(Math.min(root.maxWidth, metrics.advanceWidth + root.padH * 2))
    implicitHeight: Math.ceil(label.implicitHeight) + Math.round(root.padV * 2)
    width: root.implicitWidth
    height: root.implicitHeight

    // FadeColors: the tag is live inside the board's island hole and brings its own old colours to the new (SiliconIsland)
    property bool islandArmed: false
    FadeColor { id: bevelFade; token: "bevel"; active: root.islandArmed; place: root }
    FadeColor { id: borderFade; token: "border"; active: root.islandArmed; place: root }
    FadeColor { id: surfaceFade; token: "surface"; active: root.islandArmed; place: root }
    FadeColor { id: errorFade; token: "error"; active: root.islandArmed; place: root }
    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: "transparent"
        bevelColor: bevelFade.value
        shadowColor: borderFade.value
        backgroundColor: Qt.rgba(surfaceFade.value.r, surfaceFade.value.g, surfaceFade.value.b, root.fillOpacity)
        bevelWidth: 1
        shadowWidth: 3
    }
    Text {
        id: label
        x: root.padH
        y: Math.round(root.padV)
        width: root.width - root.padH * 2
        wrapMode: Text.Wrap
        maximumLineCount: root.maxLines
        elide: Text.ElideRight
        text: root._held
        color: errorFade.value
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize
    }
    // the whole line, when it does not fit
    MouseArea {
        id: hover
        anchors.fill: parent
        enabled: label.truncated && root.text !== ""
        acceptedButtons: Qt.NoButton
        cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
        hoverEnabled: true
    }
    HoverTip {
        id: tip
        show: hover.containsMouse && label.truncated && root.text !== ""
        anchorItem: root
        overlayItem: root.overlayItem
        text: root._held
        side: "below"
        fontFamily: root.fontFamily
    }
}
