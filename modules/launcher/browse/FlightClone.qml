pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import ".."

// =============================================================================
// FlightClone.qml -- the favourite flight's clone of a launcher row
// (LauncherGrid's RowFlight): the row as it lifts off, pixel for pixel. The
// highlighted row is the well's carved plate, opaque, with the row's face
// over it, so it lands in the well that travels under it without a seam; a
// row the well is not on (a star clicked under a still pointer after the
// keyboard moved the highlight) is its face on a plate of the ground it sat
// on -- opaque, so the rows making room under it never show through, and
// with no second well in the list.
//
// `flightData` is RowFlight's contract: { facts, hovered, starHovered,
// highlighted }, the row as it was at the gesture. `flipped` turns the clone
// into the row it is becoming (the favourite flipped): the host sets it as
// the travel starts, so the star appears or goes in mid-air -- at once, the
// star has no fade anywhere. A star the pointer lit (a click on
// it) stays lit on its way to being a favourite, and lets the pointer's
// light go as it lands (`landing`); one flying off being a favourite drops
// the pointer's look at once, and its star is gone in the same frame.
//
// PUT DOWN. A flight cut short by a re-cut list (LauncherGrid._cutFlight)
// ends at once, but its clone is not dropped with it: the grid hands it a
// `landHost`, and the body -- plate and face -- is drawn there while the
// grid's landing eases it down into its row. RowFlight drops `flightData` as
// the flight ends, so a clone put down shows `landData` instead, and shows
// it as the row it now is: the toggle is committed, so its facts are the
// row's own (no flip), the pointer's light goes as in any landing, and it
// wears the well's plate exactly while the grid's highlight well rides
// under it (`landHighlighted`: the highlight is on the row it lands in), so
// there is never a second well beside it. The body goes back when
// `landHost` is cleared.
// =============================================================================
Item {
    id: clone

    property var flightData: null
    property bool flipped: false
    // The travel is over and the clone is dropping into its cell.
    property bool landing: false
    property LauncherTune tune: null
    property bool searching: false
    // The list's ground: the plate of a row the well is not on.
    property color ground: Theme.surface
    // Put down (above): where the body is drawn, what it shows, and whether
    // the highlight well rides under it.
    property Item landHost: null
    property var landData: null
    property bool landHighlighted: false
    readonly property bool _down: !!clone.landHost
    readonly property var _data: clone._down ? clone.landData : clone.flightData
    // Put down, its facts are already the row's: nothing left to flip.
    readonly property bool _flipped: clone.flipped && !clone._down
    readonly property bool _landing: clone.landing || clone._down
    readonly property bool _highlighted: clone._down ? clone.landHighlighted : !!clone.flightData && !!clone.flightData.highlighted

    implicitHeight: clone.tune ? clone.tune.iconSize + 2 * clone.tune.rowInset : 52

    // The pointer's look is kept unless the row is flying OFF being a
    // favourite: dropped by the flip, it made a lit star fall faint while it
    // rose as the favourite's (the star dimmed and greyed in mid-air). Put
    // down it has turned, flipped or not.
    readonly property bool _keepsHover: !!clone._data && (!(clone._flipped || clone._down) || (!!clone._facts && !!clone._facts.favorite))

    readonly property var _facts: !clone._data || !clone._data.facts ? null : clone._flipped ? Object.assign({}, clone._data.facts, {
            favorite: !clone._data.facts.favorite
        }) : clone._data.facts

    // Every fraction of the face takes the new row's value at once.
    function snap() {
        face.snap();
    }

    // The body: in the clone, or in `landHost` while put down.
    Item {
        id: body
        objectName: "flightBody"
        parent: clone.landHost ? clone.landHost : clone
        anchors.fill: parent

        Rectangle {
            objectName: "cloneGround"
            visible: !clone._highlighted
            anchors.fill: parent
            radius: clone.tune ? clone.tune.wellRadius : 10
            color: clone.ground
        }
        ShadowBox {
            objectName: "cloneWell"
            visible: clone._highlighted
            anchors.fill: parent
            baseWidth: body.width
            baseHeight: body.height
            baseRadius: clone.tune ? clone.tune.wellRadius : 10
            surfaceColor: "transparent"
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: Theme.panelSunk
            bevelWidth: 1
            shadowWidth: 3
        }
        AppRow {
            id: face
            objectName: "flightClone"
            anchors.fill: parent
            facts: clone._facts
            hovered: clone._keepsHover && clone._data.hovered
            starHovered: clone._keepsHover && clone._data.starHovered && !clone._landing
            tune: clone.tune
            matchIndices: clone.searching && clone._facts ? (clone._facts.matchIndices || []) : []
            showFolder: clone.searching
        }
    }
}
