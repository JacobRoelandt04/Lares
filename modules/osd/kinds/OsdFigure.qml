pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// OsdFigure.qml -- a level's figure in a slot that never changes width.
//
// DigitCells puts every digit in a cell as wide as the font's widest digit, and
// the slot is sized for `ruler` ("150": the widest a volume gets), the figure
// right-aligned in it, so "7" -> "62" -> "150" moves nothing but its own left
// edge. A small "%" stands after the slot.
// =============================================================================
Item {
    id: f

    property string text: "0"
    property string ruler: "150"
    property real px: 16
    property string family: "Audiowide"
    property color color: Theme.textPrimary
    property color percentColor: Theme.textMuted
    property bool percent: true

    DigitCells {
        id: rule
        visible: false
        text: f.ruler
        fontFamily: f.family
        pixelSize: f.px
    }
    DigitCells {
        id: cells
        x: rule.implicitWidth - cells.implicitWidth
        text: f.text
        fontFamily: f.family
        pixelSize: f.px
        color: f.color
    }
    Text {
        id: pct
        visible: f.percent
        x: rule.implicitWidth + 2
        y: cells.y + cells.implicitHeight - pct.implicitHeight - Math.round(f.px * 0.08)
        text: "%"
        color: f.percentColor
        font.family: f.family
        font.pixelSize: Math.round(f.px * 0.62)
        font.bold: true
    }

    // How far the digits' ink stops above the foot of the item (the line's
    // descent, which a figure has no use for): a layout that stands the ink a
    // given distance from an edge subtracts it.
    readonly property real inkBottom: {
        const f = fm.font;
        const r = fm.tightBoundingRect("0123456789");
        return Math.max(0, rule.implicitHeight - (fm.ascent + r.y + r.height));
    }

    FontMetrics {
        id: fm
        font.family: f.family
        font.pixelSize: f.px
        font.bold: true
    }

    implicitWidth: rule.implicitWidth + (f.percent ? 2 + Math.ceil(pct.implicitWidth) : 0)
    implicitHeight: rule.implicitHeight
}
