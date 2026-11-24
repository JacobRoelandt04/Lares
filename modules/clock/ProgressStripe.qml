pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"

// =============================================================================
// ProgressStripe.qml -- a row's coloured left stripe that is also a gauge.
//
//   ProgressStripe {
//       color: category.color        // the stripe at full strength
//       fill: 0.4                    // 0..1 of its length that is still coloured
//       fromBottom: true             // the coloured part is the BOTTOM 40 %
//   }
//
// The system update's rows fill their stripe from its drained resting colour to the
// category colour as a package is downloaded (UpdatePackageRow: the fill grows from
// the top); the calendar's event rows do the opposite -- an event in progress ERASES
// its stripe from the top as the time runs out, so the colour that is left is the time
// remaining (`fromBottom`). The same two layers either way: a faint base the whole
// length of the stripe, and over it a rounded fill of `fill` of that length.
//
// THE FRACTION EASES, NOT THE HEIGHT. A row that changes size (an event row opening
// to show its details) lengthens the stripe, and the fill is sized from the fraction,
// so the boundary between the two parts moves WITH the stripe instead of lagging
// behind it; a change of `fill` itself (a minute of the event going by) glides over
// `easeMs`. The first value is taken as it is: a row built part-way through its event
// does not erase itself from full.
//
// DRAINED, NOT A SECOND COLOUR. The faint base is the stripe's own hue at
// `mutedSaturation`, at a lightness a fixed share of the way from the ground the row
// lies on towards mid-grey (UpdatePackageRow's rule: it drains the same on a light list
// and on a dark one, and because the ground is a themed colour it follows the theme).
// No Behavior on a colour anywhere -- the two colours are live tokens and only `fill`
// moves.
// =============================================================================
Item {
    id: root

    // The stripe at full strength.
    property color color: Theme.accent
    // The ground the row lies on: the drained colour is made relative to it.
    property color ground: Theme.panelSunk
    property real mutedSaturation: 0.22
    property real mutedLightnessMix: 0.4732
    // The drained (burned-out) stripe. Bindable: a host that wants another look sets it.
    property color faintColor: Qt.hsla(root.color.hslHue, root.mutedSaturation,
                                       root.ground.hslLightness + (0.5 - root.ground.hslLightness) * root.mutedLightnessMix, 1.0)

    // The coloured share of the stripe's length, 0..1, and which end it is anchored to.
    property real fill: 1
    property bool fromBottom: false
    property int easeMs: 280

    implicitWidth: 3
    implicitHeight: 24

    // The eased fraction the fill is drawn from. A Behavior skips the first value, so a
    // stripe built at 0.4 starts there.
    property real shownFill: root.fill
    Behavior on shownFill {
        NumberAnimation {
            duration: root.easeMs
            easing.type: Easing.OutCubic
        }
    }

    Rectangle {
        id: base
        anchors.fill: parent
        radius: root.width / 2
        color: root.faintColor
        // A whole stripe is the colour alone: the drained layer under its antialiased rim would show as a faint edge.
        visible: root.shownFill < 0.999
    }
    Rectangle {
        id: coloured
        x: 0
        width: parent.width
        height: Math.min(parent.height, root.shownFill * parent.height)
        y: root.fromBottom ? parent.height - coloured.height : 0
        radius: root.width / 2
        color: root.color
        visible: coloured.height > 0.01
    }
}
