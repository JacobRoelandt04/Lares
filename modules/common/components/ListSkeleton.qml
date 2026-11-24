pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ListSkeleton.qml
//
// A silhouette of the package list, shown while the update check is still
// running: faint header boxes with a few faint row bars under the first one,
// the way a video site sketches thumbnails and titles before it has them.
// It says "a list is coming" better than a line of text does, and it
// holds the list's space so nothing jumps when the real one arrives.
//
// The transition is the whole point. `resolve(realCount)` is called the
// moment the real categories are known:
//
//   - a silhouette that has a real header at the same slot fades out in
//     place, while the real list fades in underneath it -- the two boxes sit
//     at the same height, so the eye reads one becoming the other;
//   - a silhouette with NO real header under it (the guess was too long)
//     fades and collapses to nothing, so the tail of the list closes up as
//     the real one settles;
//   - if the guess was too short, the extra real headers simply fade in
//     with the rest; nothing had claimed their space, so nothing moves.
//
// When the check finds nothing at all, every silhouette collapses, and the
// empty container is what remains -- which is the truth.
//
// Geometry is taken from the same numbers the real list uses (header height
// and row height at the list's scale, the row inset, the container radius),
// so the silhouettes land where the real boxes will.
// =============================================================================
Item {
    id: skel

    // Layout, matched to the real list. The host hands over the real
    // header's and row's numbers -- paddings and the line heights of their
    // texts at the list's scale -- so the silhouettes land exactly where
    // the boxes and rows will, and the bars inside them sit where the
    // text will.
    property real headerHeight: 56          // the header's box, without headerGap
    property real headerGap: 6
    // Space the list keeps between one section and the next.
    property real sectionGap: 6
    property real headerPadV: 8
    property real titleLineH: 20
    property real subLineH: 15
    // The verbose view's narrow list lays its headers out compact: the
    // count sits on the title line, right-aligned, and there is no second
    // line at all while nothing is downloading (see ListSectionHeader's
    // compactLayout) -- so the host passes headerHeight = headerPadV * 2 +
    // titleLineH, the box a compact header measures, and the silhouette
    // draws the title bar plus a short bar at the line's right for the
    // count, and no subtitle bar. Rows are the same in both layouts.
    property bool compact: false
    // A row's full pitch (its own height plus the list's spacing), and
    // where the row proper begins inside it.
    property real rowHeight: 48
    property real rowInnerTop: 3
    property real rowVPad: 4
    property real nameLineH: 18
    property real versionLineH: 15
    property real rowInset: 6
    property real containerRadius: 14
    property real headerRadius: 10
    property real listScale: 1.0

    // Shape of the guess.
    property int  headerCount: 3
    property int  rowsUnderFirst: 2

    // Palette: a shade darker than the surface for the boxes, and the
    // surface itself for the bars carved out of them.
    property color boxColor: "#DCDFE6"
    property color barColor: "#E6E9F0"
    property color rowBarColor: "#D6D9E0"

    property int fadeMs: 160      // the shell's presence fade (CLAUDE.md, Motion rules)
    property int collapseMs: 260
    // The waiting pulse. Off for a still picture: a render to compare against
    // another render, or a probe that has to tell "this pixel is animating on
    // its own" from "this pixel is late" -- with the pulse running, a fifth of
    // the surface can be neither judged nor cleared.
    property bool pulse: true

    // Whether the silhouette is showing. Setting it false without resolve()
    // just fades everything out in place.
    property bool showing: true

    // How many real headers exist, once known; -1 while unknown.
    property int _realCount: -1

    function resolve(realCount) {
        skel._realCount = Math.max(0, realCount);
        skel.showing = false;
    }
    function reset() {
        skel._realCount = -1;
        skel.showing = true;
    }

    implicitHeight: col.implicitHeight

    Column {
        id: col
        width: parent.width
        spacing: 0

        Repeater {
            model: skel.headerCount

            Item {
                id: block
                required property int index
                width: col.width

                // A block that turned out to have a real header under it
                // keeps its height while fading (the real header takes the
                // slot); one that did not collapses as it fades.
                readonly property bool hasReal: skel._realCount < 0 || block.index < skel._realCount
                readonly property real fullHeight: skel.headerHeight + skel.headerGap
                    + (block.index === 0 ? skel.rowsUnderFirst * skel.rowHeight : 0)
                    + skel.sectionGap
                height: skel.showing || block.hasReal ? fullHeight : 0
                Behavior on height {
                    NumberAnimation { duration: skel.collapseMs; easing.type: Easing.InOutCubic }
                }
                opacity: skel.showing ? 1 : 0
                Behavior on opacity {
                    NumberAnimation { duration: skel.fadeMs; easing.type: Easing.OutCubic }
                }
                clip: true

                // The header silhouette: a box the header's size, with a title
                // bar and a shorter subtitle bar carved into it, and a soft
                // pulse so it reads as waiting rather than as a dead panel.
                Rectangle {
                    id: headerBox
                    x: 0
                    y: 0
                    width: block.width
                    height: skel.headerHeight
                    color: skel.boxColor
                    radius: block.index === 0 ? skel.containerRadius : skel.headerRadius
                    // The first box shares the container's top corners; its
                    // bottom corners are the ordinary header radius.
                    Rectangle {
                        visible: block.index === 0
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: parent.height / 2
                        color: parent.color
                        radius: skel.headerRadius
                    }

                    // Title and subtitle bars, centred on the lines the
                    // real texts will occupy. Laid out from the padding and
                    // the line heights, never from headerHeight: the host
                    // computes that from these same numbers, and a bar
                    // placed off the box's height would drift if the two
                    // ever disagreed.
                    Rectangle {
                        x: 11 * skel.listScale
                        y: skel.headerPadV + (skel.titleLineH - height) / 2
                        width: (70 + 30 * ((block.index * 7) % 3)) * skel.listScale
                        height: 12 * skel.listScale
                        radius: height / 2
                        color: skel.barColor
                    }
                    Rectangle {
                        visible: !skel.compact
                        x: 11 * skel.listScale
                        y: skel.headerPadV + skel.titleLineH - 1 + (skel.subLineH - height) / 2
                        width: 58 * skel.listScale
                        height: 8 * skel.listScale
                        radius: height / 2
                        color: skel.barColor
                    }
                    // Compact: the count, on the title line at its right.
                    // The real count ends a gap before the chevron, which
                    // is itself about 11px wide and the box padding in from
                    // the edge -- all at the list's scale. It shares the
                    // title's baseline in a smaller face, so its glyphs sit
                    // a little lower on the line than the title's do.
                    Rectangle {
                        visible: skel.compact
                        x: block.width - (11 + 11 + 8) * skel.listScale - width
                        y: skel.headerPadV + (skel.titleLineH - height) / 2 + 1 * skel.listScale
                        width: 46 * skel.listScale
                        height: 8 * skel.listScale
                        radius: height / 2
                        color: skel.barColor
                    }

                    SequentialAnimation on opacity {
                        running: skel.pulse && skel.showing && skel.visible
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.62; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0;  duration: 900; easing.type: Easing.InOutSine }
                    }
                }

                // Row silhouettes under the first header: a stripe, an icon
                // dot and a name bar, at the row's inset.
                Repeater {
                    model: block.index === 0 ? skel.rowsUnderFirst : 0
                    Item {
                        id: rowSil
                        required property int index
                        x: skel.rowInset
                        y: skel.headerHeight + skel.headerGap + rowSil.index * skel.rowHeight
                        width: block.width - skel.rowInset * 2
                        height: skel.rowHeight
                        opacity: 0.8

                        // The row proper: the stripe spans it minus the
                        // row's own vertical padding, the dot is centred on
                        // it, the bars sit on the name and version lines.
                        readonly property real innerTop: skel.rowInnerTop + skel.rowVPad
                        readonly property real innerH: skel.rowHeight - skel.rowInnerTop * 2 - skel.rowVPad * 2
                        Rectangle {
                            x: 2 * skel.listScale
                            y: rowSil.innerTop
                            width: 3 * skel.listScale
                            height: rowSil.innerH
                            radius: width / 2
                            color: skel.rowBarColor
                        }
                        Rectangle {
                            x: 16 * skel.listScale
                            y: rowSil.innerTop + (rowSil.innerH - height) / 2
                            width: 14 * skel.listScale
                            height: width
                            radius: width / 2
                            color: skel.rowBarColor
                        }
                        Rectangle {
                            x: 40 * skel.listScale
                            y: rowSil.innerTop + (skel.nameLineH - height) / 2
                            width: (110 + 40 * (rowSil.index % 2)) * skel.listScale
                            height: 11 * skel.listScale
                            radius: height / 2
                            color: skel.rowBarColor
                        }
                        Rectangle {
                            x: 40 * skel.listScale
                            y: rowSil.innerTop + skel.nameLineH + 1 + (skel.versionLineH - height) / 2
                            width: 50 * skel.listScale
                            height: 7 * skel.listScale
                            radius: height / 2
                            color: skel.rowBarColor
                        }
                    }
                }
            }
        }
    }
}
