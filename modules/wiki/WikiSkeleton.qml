pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// WikiSkeleton.qml -- the card while an entry is on its way (a rabbit hole's page
// being fetched, a first batch not yet in): a block in the hero well, two bars
// where the title goes with the two round marks at their end, and the
// paragraph's lines, on the SAME rectangles the real parts take, so the entry
// resolves in place.
//
// The bars are SkeletonBar: they breathe on GEOMETRY (a distance each end
// travels), never on a colour, on one shared clock, and hold still while the
// theme crossfades. `showing: false` fades them out (SkeletonBar.fadeMs) while
// the real parts fade in underneath; a still frame (`pulse` off) is the same
// picture every time.
//
// It takes rectangles, not a layout of its own: the popup knows where its hero,
// title slot and intro slot are, and hands them over.
// =============================================================================
Item {
    id: root

    property WikiStyle style: WikiStyle {}
    property bool showing: true
    // In this item's own coordinates.
    property rect heroRect: Qt.rect(0, 0, 0, 0)
    property rect titleRect: Qt.rect(0, 0, 0, 0)
    property rect introRect: Qt.rect(0, 0, 0, 0)

    readonly property bool _pulse: root.style.skeletonPulse && !Theme.crossfading
    readonly property int _lines: Math.max(1, Math.floor(root.introRect.height / root.style.bodyLineH))

    // The hero: one block a little inside the well's carve.
    SkeletonBar {
        x: root.heroRect.x + root.style.skeletonHeroInset
        y: root.heroRect.y + root.style.skeletonHeroInset
        width: Math.max(0, root.heroRect.width - 2 * root.style.skeletonHeroInset)
        height: Math.max(0, root.heroRect.height - 2 * root.style.skeletonHeroInset)
        radius: root.style.skeletonHeroRadius
        barColor: Theme.headerBox
        groundColor: Theme.listBox
        showing: root.showing
        fadeMs: root.style.presenceMs
        pulse: root._pulse
        pulseTravel: 3
    }

    // The title: two bars, centred in the row's slot, and the marks at its end.
    readonly property real _barH: root.style.skeletonTitleBarHeight
    readonly property real _titleBlockH: 2 * root._barH + root.style.skeletonBarGap
    readonly property real _titleTop: root.titleRect.y + Math.round((root.titleRect.height - root._titleBlockH) / 2)
    readonly property real _marksW: root.style.glyphBox + root.style.iconGap + root.style.logoSize + root.style.logoGap
    readonly property real _titleW: Math.max(0, root.titleRect.width - root._marksW)
    SkeletonBar {
        x: root.titleRect.x
        y: root._titleTop
        width: Math.round(root._titleW * 0.78)
        height: root._barH
        barColor: Theme.headerBox
        groundColor: Theme.surface
        showing: root.showing
        fadeMs: root.style.presenceMs
        pulse: root._pulse
        pulseTravel: 3
    }
    SkeletonBar {
        x: root.titleRect.x
        y: root._titleTop + root._barH + root.style.skeletonBarGap
        width: Math.round(root._titleW * 0.46)
        height: root._barH
        barColor: Theme.headerBox
        groundColor: Theme.surface
        showing: root.showing
        fadeMs: root.style.presenceMs
        pulse: root._pulse
        pulseTravel: 3
        pulsePhaseMs: 150
    }
    SkeletonBar {
        x: root.titleRect.x + root.titleRect.width - root.style.logoSize - root.style.iconGap - root.style.glyphBox
        y: root.titleRect.y + Math.round((root.titleRect.height - root.style.glyphBox) / 2)
        width: root.style.glyphBox
        height: root.style.glyphBox
        radius: root.style.glyphBox / 2
        barColor: Theme.headerBox
        groundColor: Theme.surface
        showing: root.showing
        fadeMs: root.style.presenceMs
        pulse: root._pulse
        pulseTravel: 2
    }
    SkeletonBar {
        x: root.titleRect.x + root.titleRect.width - root.style.logoSize
        y: root.titleRect.y + Math.round((root.titleRect.height - root.style.logoSize) / 2)
        width: root.style.logoSize
        height: root.style.logoSize
        radius: root.style.logoSize / 2
        barColor: Theme.headerBox
        groundColor: Theme.surface
        showing: root.showing
        fadeMs: root.style.presenceMs
        pulse: root._pulse
        pulseTravel: 2
    }

    // The paragraph: one bar per line, the last one short.
    Repeater {
        model: root._lines

        SkeletonBar {
            id: line

            required property int index

            x: root.introRect.x
            y: root.introRect.y + line.index * root.style.bodyLineH + Math.round((root.style.bodyLineH - height) / 2)
            width: line.index === root._lines - 1 ? Math.round(root.introRect.width * 0.55) : root.introRect.width
            height: root.style.skeletonBarHeight
            barColor: Theme.headerBox
            groundColor: Theme.surface
            showing: root.showing
            fadeMs: root.style.presenceMs
            pulse: root._pulse
            pulseTravel: 3
            pulsePhaseMs: 60 * line.index
        }
    }
}
