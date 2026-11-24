pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix

// =============================================================================
// LogoLink.qml -- an engraved logo that IS the link.
//
// The pointer is the only thing that announces it (CLAUDE.md, "Clutter"): the
// carve is a `LogoRelief`, its lit wall brightens on hover (ONE eased fraction,
// 120 ms OutCubic -- never a colour Behavior) and the hand cursor shows. The
// idiom is StockDetailHeader's logo, lifted out: same reading (a little
// shallower than LogoRelief's default at this size), same hover gain.
//
//     LogoLink {
//         source: Qt.resolvedUrl("../../assets/logos/archlinux.png")
//         logoSize: 28
//         surfaceColor: Theme.surface           // the ground it is cut into
//         onClicked: service.openSource(tab, id)
//     }
//
// `logoSize` is the MARK's width (LogoRelief's convention), and the relief is
// weak below ~24 px at 1x: the Wikipedia, Linux and Commons marks are thin.
// `source` empty or unloadable -> zero size, nothing drawn, no cursor.
//
// `surfaceColor` is the GROUND the logo is cut into (CLAUDE.md): the card's fill
// on a card, `Theme.surface` on the bare popup. The other colours follow
// StockDetailHeader's reading, so the two look alike wherever they sit.
// =============================================================================
Item {
    id: root

    // ---- Contract ----
    property url source
    property real logoSize: 56
    // The fraction of the baked texture the mark occupies (LogoRelief's own).
    property real markFraction: 0.82
    signal clicked

    // ---- Palette (the ground it sits on, and the carve's reading of it) ----
    property color surfaceColor: Theme.listBox
    property color shadowColor: Theme.shadowDeep
    property color bodyColor: Mix.c(Theme.panelSunk, Theme.border, Theme.mode === "dark" ? 0.35 : 0.85)
    property real falloff: Theme.mode === "dark" ? 0.8 : 0.4
    property real ambient: Theme.mode === "dark" ? 0.5 : 1.0
    property real bevelWidth: 0.2
    // The lit wall's strength at rest, and what a hover adds to it.
    property real highlightGain: 0.85
    property real hoverGain: 0.35
    property int hoverMs: 120

    readonly property bool hovered: area.containsMouse && root.enabled
    readonly property bool ready: relief.ready

    implicitWidth: relief.implicitWidth
    implicitHeight: relief.implicitHeight

    property real hoverF: root.hovered ? 1 : 0
    Behavior on hoverF {
        NumberAnimation {
            duration: root.hoverMs
            easing.type: Easing.OutCubic
        }
    }

    LogoRelief {
        id: relief
        x: 0
        y: 0
        logoSize: root.logoSize
        markFraction: root.markFraction
        surfaceColor: root.surfaceColor
        shadowColor: root.shadowColor
        bodyColor: root.bodyColor
        falloff: root.falloff
        ambient: root.ambient
        bevelWidth: root.bevelWidth
        highlightGain: root.highlightGain + root.hoverGain * root.hoverF
        source: root.source
    }
    MouseArea {
        id: area
        width: relief.width
        height: relief.height
        enabled: root.enabled && relief.ready
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
