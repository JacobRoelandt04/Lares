import QtQuick

// =============================================================================
// Chevron.qml
//
// The shell's chevron: two round-capped strokes at 45 degrees meeting in one
// apex, pointing DOWN at rotation 0. Turn it with `rotation` (180 = up, 90 =
// left, -90 = right); an expand/collapse cue is `rotation: extent * 180`.
//
// The geometry is ListSectionHeader's:
//   - the arms' centres sit `_reach` apart, measured between their CAP
//     centres, so the two inner caps land on the same point and the mark
//     comes to one apex (measured from the full length, the apex would be a
//     cleft that reads as a corner cut off);
//   - the item is the mark's own footprint rounded out to whole pixels, so a
//     host that places it at a whole-pixel position gets both caps, the
//     tips and the apex on the same fraction of their outer pixel. Place it
//     with Math.round, never anchors.centerIn.
// =============================================================================
Item {
    id: chevron

    // Overall size of the mark, as ListSectionHeader's `chevronSize`: the arm
    // is 0.46 of it. 15 is the shell's list-header chevron.
    property real size: 15
    property real thickness: 2
    property color color: "#8A8A8C"

    readonly property real _arm: chevron.size * 0.46
    readonly property real _thick: Math.max(1.5, chevron.thickness)
    readonly property real _reach: Math.max(0, chevron._arm - chevron._thick) * 0.7071
    readonly property real _capReach: Math.max(0, chevron._arm - chevron._thick) / 2 * 0.7071 + chevron._thick / 2

    implicitWidth: Math.ceil(chevron._reach + chevron._capReach * 2)
    implicitHeight: Math.ceil(chevron._capReach * 2)
    transformOrigin: Item.Center

    Rectangle {
        width: chevron._arm
        height: chevron._thick
        radius: height / 2
        color: chevron.color
        x: chevron.width / 2 - chevron._reach / 2 - width / 2
        y: chevron.height / 2 - height / 2
        rotation: 45
    }
    Rectangle {
        width: chevron._arm
        height: chevron._thick
        radius: height / 2
        color: chevron.color
        x: chevron.width / 2 + chevron._reach / 2 - width / 2
        y: chevron.height / 2 - height / 2
        rotation: -45
    }
}
