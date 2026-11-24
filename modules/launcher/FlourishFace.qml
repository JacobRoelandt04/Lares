pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/icons"
import "../common/components/Mix.js" as Mix
import "browse/RowText.js" as RT
import "browse/RowGeometry.js" as RG

// =============================================================================
// FlourishFace.qml -- the confirm flourish's content: the launched row as the
// engine's flourish slot carries it (ConfirmFlourish opens it; the engine
// lays it out at the slot's box).
//
// The row's own icon (the same AppIcon) and its title (the same StyledText, marks and all, elided at the row's own
// name slot, so it never re-elides on the way), drawn where the flourish's
// pose puts them (FlourishPose.js): ONE morph fraction, the lift's, takes the
// icon from the row's left to the card's centre-top and the title from beside
// it to below it, centred; the icon grows with the rise. The row's highlight
// well and its marks (the star, a link's chain glyph) are there on the first
// frame -- the row it replaces is hidden in the same one, so the detach is
// the row itself -- and go as a 160 ms presence fade.
//
// The card is SURFACE, not a window onto the launcher: the engine draws the
// flourish's body in the field, under every popup's content, and this layer
// above it -- so without a ground of its own the card's icon and title were
// drawn over the fading rows it lifts through, two layouts legible through
// each other (the verifier's lift series, 80-128 ms). The backing is the
// field's own colour, cut by the slot's outline half a pixel inside it,
// where the field is solid: nothing changes at rest or on the wallpaper.
// And the row as the list DREW it: under the list's edge fade (a row at the
// foot of a list with more below, or at its head once scrolled) the same
// bands are drawn over the face on the detach frame, released with the
// well; the part of a row outside the list's clip is outside the body
// (FlourishPose.rowBox), so the first frame is the row itself either way.
//
// Every position is the pose's, in the engine's coordinates, less where the
// engine laid the slot out this frame: the content is where the pose says
// whatever the box does. Nothing here animates on a clock of its own and no
// colour has a Behavior (Theme is one clock).
// =============================================================================
Item {
    id: face

    property var flourish: null
    property var tune: null

    readonly property var p: face.flourish ? face.flourish.pose : null
    readonly property var f: face.flourish ? face.flourish.face : null
    readonly property var facts: face.f ? face.f.facts : null
    // Where the slot is this frame (the engine's box: the item's origin).
    readonly property var body: face.flourish && face.flourish.engine ? face.flourish.engine.theFlourish : null
    readonly property real ox: face.body ? face.body.popX : 0
    readonly property real oy: face.body ? face.body.popY : 0
    // The flourish opens at the row grown by a carved well's bevel slack, so
    // the well's rim is inside the body's clip (CLAUDE.md: a clip on a carved
    // box's edge shears its bevel).
    readonly property real slack: 3
    readonly property real inset: face.tune ? face.tune.rowInset : 6
    // The row's box whole while it lifts (the body may be cut to the list's
    // viewport), in this item's coordinates: the well and the marks sit on it.
    readonly property var wb: face.p ? (face.p.wellBox || face.p.box) : null
    readonly property real wx: face.wb ? face.wb.x0 - face.ox : 0
    readonly property real wy: face.wb ? face.wb.y0 - face.oy : 0
    readonly property real ww: face.wb ? face.wb.x1 - face.wb.x0 : face.width
    readonly property real wh: face.wb ? face.wb.y1 - face.wb.y0 : face.height

    // The card's ground: the field's colour, under everything it carries.
    Rectangle {
        objectName: "flourishBacking"
        anchors.fill: parent
        color: face.flourish && face.flourish.engine ? face.flourish.engine.surfaceColor : Theme.surface
    }

    // The row's highlight well, fading.
    ShadowBox {
        id: well
        objectName: "flourishWell"
        readonly property real a: face.p ? face.p.wellA : 0
        visible: !!face.f && face.f.well && well.a > 0.001
        opacity: well.a
        x: face.wx + face.slack
        y: face.wy + face.slack
        width: Math.max(0, face.ww - 2 * face.slack)
        height: Math.max(0, face.wh - 2 * face.slack)
        baseWidth: well.width
        baseHeight: well.height
        baseRadius: face.tune ? face.tune.wellRadius : 10
        surfaceColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.panelSunk
        bevelWidth: 1
        shadowWidth: 3
    }

    AppIcon {
        id: mark
        objectName: "flourishIcon"
        readonly property real ip: face.p ? face.p.ip : 40
        // An int: its centre is kept where the pose puts it.
        size: Math.max(1, Math.round(mark.ip))
        x: face.p ? face.p.icon.x + (mark.ip - mark.size) / 2 - face.ox : 0
        y: face.p ? face.p.icon.y + (mark.ip - mark.size) / 2 - face.oy : 0
        icon: face.facts ? face.facts.icon : ""
        kind: face.facts ? face.facts.kind : ""
        appId: face.facts ? face.facts.desktopId : ""
    }

    Text {
        id: title
        objectName: "flourishTitle"
        visible: title.opacity > 0.001
        opacity: face.p ? face.p.titleA : 1
        x: face.p ? face.p.title.x - face.ox : 0
        y: face.p ? face.p.title.y - face.oy : 0
        width: face.f ? face.f.nameW : 0
        textFormat: Text.StyledText
        text: RT.styled(face.facts ? face.facts.name : "", face.f ? face.f.matchIndices : [], Theme.accent.toString(), face.f && face.f.showFolder && face.facts ? (face.facts.folderName || "") : "", Theme.textMuted.toString())
        elide: Text.ElideRight
        font.family: face.tune ? face.tune.fontFamily : "Inter"
        font.pixelSize: face.tune ? face.tune.nameSize : 12
        color: Theme.textPrimary
    }

    // The row's marks at its right end, as AppRow draws them, fading.
    Text {
        id: link
        objectName: "flourishLink"
        visible: !!face.f && face.f.link && link.opacity > 0.001
        opacity: face.p ? face.p.marksA : 0
        x: Math.round(face.wx + face.slack + RG.linkX(face.ww - 2 * face.slack, face.tune) + (RG.LINK_SLOT - link.width) / 2)
        y: Math.round(face.wy + (face.wh - link.height) / 2)
        text: "\uF0C1"
        font.family: "Symbols Nerd Font"
        font.pixelSize: 10
        color: Mix.c(Theme.textFaint, Theme.accent, face.f && face.f.linkHovered ? 1 : 0)
    }
    Text {
        id: star
        objectName: "flourishStar"
        readonly property var s: face.f ? face.f.star : null
        readonly property real presence: star.s ? star.s.favF + (1 - star.s.favF) * star.s.hoverStarF : 0
        visible: star.opacity > 0.01
        opacity: star.presence * (face.p ? face.p.marksA : 0)
        x: Math.round(face.wx + face.ww - face.slack - face.inset - star.width)
        y: Math.round(face.wy + (face.wh - star.height) / 2)
        text: "\uF005"
        font.family: "Symbols Nerd Font"
        font.pixelSize: face.tune ? face.tune.starSize : 12
        color: Mix.c(Mix.c(Theme.textFaint, Theme.accent, star.s ? star.s.starHoverF : 0), Mix.c(Theme.accent, Theme.accentHover, star.s ? star.s.starHoverF : 0), star.s ? star.s.favF : 0)
    }

    // The list's edge fades as the list drew them over the row (ScrollDressing:
    // the ground from the edge to transparent over a fade-height, weighted by
    // how far the content runs past that end), fixed where the list was and
    // released with the well.
    readonly property var fd: face.f ? face.f.fade : null
    readonly property real bandA: face.p && face.p.bandA !== undefined ? face.p.bandA : 0
    Rectangle {
        objectName: "flourishFadeHead"
        visible: !!face.fd && face.fd.head * face.bandA > 0.001
        opacity: face.fd ? face.fd.head * face.bandA : 0
        x: face.fd ? face.fd.x0 - face.ox : 0
        y: face.fd ? face.fd.y0 - face.oy : 0
        width: face.fd ? face.fd.x1 - face.fd.x0 : 0
        height: face.fd ? face.fd.h : 0
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Theme.surface
            }
            GradientStop {
                position: 1.0
                color: "transparent"
            }
        }
    }
    Rectangle {
        objectName: "flourishFadeFoot"
        visible: !!face.fd && face.fd.foot * face.bandA > 0.001
        opacity: face.fd ? face.fd.foot * face.bandA : 0
        x: face.fd ? face.fd.x0 - face.ox : 0
        y: face.fd ? face.fd.y1 - face.fd.h - face.oy : 0
        width: face.fd ? face.fd.x1 - face.fd.x0 : 0
        height: face.fd ? face.fd.h : 0
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: "transparent"
            }
            GradientStop {
                position: 1.0
                color: Theme.surface
            }
        }
    }
}
