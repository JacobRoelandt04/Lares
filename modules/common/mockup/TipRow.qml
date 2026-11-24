pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// =============================================================================
// TipRow -- one row of a mockup control panel.
//
// Whatever controls are declared inside it sit in a RowLayout, and the row
// explains itself on hover: `tip` is shown under it after a short delay. A
// panel grows past forty parameters quickly and a six-word label cannot say
// what "orbit spring" actually does, so every parameter row goes through
// this and no control is left unexplained. Demo furniture only; nothing here
// ships with a module.
// =============================================================================
RowLayout {
    id: tipRow

    property string tip: ""
    // The longest line a tip is laid out at: about fifty characters of
    // Audiowide 14, which reads as a paragraph for the two or three sentences
    // a tip usually is. It is a cap, not a width -- a short tip still gets a
    // box that hugs its text -- and it is what stops a widened panel from
    // stretching a tip back into one long line.
    property real tipMaxWidth: 420

    Layout.fillWidth: true
    spacing: 8

    HoverHandler {
        id: tipHover
    }

    // The tip's width unwrapped. It has to be measured out here: reading the
    // Text's own implicitWidth back into what sizes it is a binding loop, and
    // the Popup overwrites the Text's width anyway (see contentWidth).
    TextMetrics {
        id: tipMetrics
        font.family: "Audiowide"
        font.pixelSize: 14
        text: tipRow.tip
    }

    FontMetrics {
        id: tipFont
        font: tipMetrics.font
    }

    ToolTip {
        id: tipPopup
        parent: tipRow
        visible: tipHover.hovered && tipRow.tip.length > 0
        delay: 350
        timeout: -1
        padding: 9
        // Proportional lineHeight hangs its extra leading under the last
        // line, so equal padding all round sits the paragraph high in its
        // box. Take that leading off the bottom to get the ink centred.
        bottomPadding: Math.max(0, tipPopup.padding - tipFont.height * (tipText.lineHeight - 1))
        // A Popup derives its implicitWidth from contentItem.implicitWidth --
        // for a Text that is the width it would need on ONE line, 1955 px for
        // a three-sentence tip -- and then writes contentItem.width itself,
        // which destroys any width binding on the Text. So the cap belongs
        // here, on the Popup's own contentWidth: a short tip still gets a box
        // that hugs its text, a long one wraps at the cap and grows downward.
        // The +1 is slack: the advance and the Text's own layout width can
        // differ by a fraction, and coming up short would drop the last word
        // onto a second line for no reason. The row is the third cap: a box
        // no wider than the row it explains cannot leave the panel, whatever
        // width the panel is dragged to, so it needs no edge nudging and sits
        // squarely under its own row.
        contentWidth: {
            const room = tipRow.width > 0
                ? tipRow.width - tipPopup.leftPadding - tipPopup.rightPadding
                : tipRow.tipMaxWidth;
            return Math.min(Math.ceil(tipMetrics.advanceWidth) + 1, tipRow.tipMaxWidth, room);
        }
        // A Popup is no child the RowLayout places: its x / y are relative to
        // its parent and nothing else writes them (qmllint reads it as a
        // layout-managed item).
        // qmllint disable Quick.layout-positioning
        x: 0
        y: tipRow.height + 4
        // qmllint enable Quick.layout-positioning

        contentItem: Text {
            id: tipText
            text: tipRow.tip
            color: "#EAEDF5"
            font: tipMetrics.font
            lineHeight: 1.3
            wrapMode: Text.Wrap
        }
        background: Rectangle {
            color: "#3A3D44"
            radius: 8
            border.color: "#5D5D5F"
            border.width: 1
        }
    }
}
