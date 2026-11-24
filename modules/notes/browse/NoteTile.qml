pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../../common/components/LiveMarkdown.js" as LM
import "../../common/components/RelTime.js" as RelTime

// =============================================================================
// NoteTile.qml -- one note in the notes grid.
//
// A tile stands proud (it is clicked): the raised ShadowBox of RaisedButton,
// tinted by the note's colour. Title (the file name, `.md` hidden), the first
// lines of the note as a tile would show them (LiveMarkdown.thumbHtml: images,
// code, tables and frontmatter skipped), fading out at the tile's foot rather
// than cut, and a faint relative modified time. A foreign note -- a symlink
// to a file elsewhere -- carries a small link glyph whose tooltip is the real
// path; a link whose file is gone says so.
//
// `entry` is a plain facts object (NotesService.entry()); the tile resolves
// its colours itself, so nothing themed ever sits in a model.
// =============================================================================
Item {
    id: tile

    property var entry: null
    property Item overlayItem: null
    property string fontFamily: "Inter"
    property real padding: 12
    property real radius: 12
    property bool lifted: false        // carried by a drag
    // How far it has risen (the carried tile eases up; 0..1).
    property real liftF: tile.lifted ? 1 : 0
    property bool target: false        // a group would form here
    property bool hoverEnabled: true
    // The keyboard highlight (NotesGrid): the look the pointer gives.
    property bool kbFocus: false
    // The face alone, no box: drawn on the popup's morph card (MorphCard),
    // whose ground is `bareGround`.
    property bool bare: false
    property color bareGround: "transparent"
    // The face (title, glyph, lines, time) held as one texture: the grid's float moves it as a quad (FloatClock.layers). The box is drawn
    // directly; the texture is twice the device's pixels and mipmapped, so a turned or leaning tile stays sharp.
    property bool faceLayered: false
    // The modified time in words ("now", "4 min", "Thu", "24 Sep"; RelTime
    // with `time: false`). `clock` is the grid's one BoundaryClock: the tile
    // reads its `now` and asks it for the instant its own words change, so
    // the label turns on its boundary -- never on a minute where nothing
    // turns, and never because a scan happened to touch its row. A tile
    // handed only `now` (the popup's morph card draws a bare copy of a grid
    // tile, and the grid's own tile asks) reads it and asks for nothing.
    property var clock: null
    property real now: tile.clock ? tile.clock.now : 0
    // A TILE NEVER READS A CLOCK OLDER THAN THE WALL. `now` moves only on a
    // boundary somebody asked for, and tiles are built only on screen
    // (scrolled in, the grid shown again), so a new tile would read the last
    // boundary's instant -- and a boundary of its own already behind the
    // wall is one no timer will ever wake it for: its words would freeze. So
    // the reading is the later of `now` and the wall; `now` is what re-reads
    // it on every boundary (and a pinned `now`, a probe's, is read when later).
    readonly property var _rel: tile.entry && !tile.entry.broken && tile.entry.mtimeMs
        ? RelTime.format(tile.entry.mtimeMs, Math.max(tile.now, Date.now()), { time: false }) : null
    on_RelChanged: tile._ask()
    Component.onCompleted: tile._ask()
    // -1 is final: nothing to ask for. A boundary that passed while the tile
    // was being built wakes the clock at once instead of never.
    function _ask() {
        if (tile.clock && tile._rel && tile._rel.nextMs > 0)
            tile.clock.request(Math.max(tile._rel.nextMs, Date.now() + 1));
    }
    readonly property alias hovered: hover.hovered

    readonly property string colorKey: tile.entry ? (tile.entry.colorKey || "") : ""
    readonly property color plateau: tile.colorKey ? tile.tintOf(tile.colorKey) : Theme.buttonPlateau

    function tintOf(key) {
        const k = "note" + key.charAt(0).toUpperCase() + key.substring(1);
        return Theme[k] !== undefined ? Theme[k] : Theme.buttonPlateau;
    }

    property real hoverF: (hover.hovered && tile.hoverEnabled) || tile.kbFocus ? 1 : 0
    Behavior on hoverF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    property real targetF: tile.target ? 1 : 0
    Behavior on targetF {
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }

    scale: 1 + 0.04 * tile.targetF
    transformOrigin: Item.Center

    ShadowBox {
        visible: !tile.bare
        anchors.fill: parent
        baseWidth: tile.width
        baseHeight: tile.height
        baseRadius: tile.radius
        raised: true
        // The drop shadow falls to TRANSPARENT, not to the surface colour: the
        // carried tile passes over other tiles, and a shadow easing into an
        // opaque surface-coloured apron draws a hard pale ring there.
        shadowToAlpha: true
        surfaceColor: Theme.surface
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        backgroundColor: Mix.c(Mix.c(tile.plateau, Theme.buttonPlateauHover, tile.hoverF * (tile.colorKey ? 0.35 : 1)), Theme.accent, 0.14 * tile.targetF)
        bevelWidth: 1.5
        shadowWidth: 5 + 4 * tile.liftF
    }

    readonly property color _ground: tile.bare ? tile.bareGround : Mix.c(Mix.c(tile.plateau, Theme.buttonPlateauHover, tile.hoverF * (tile.colorKey ? 0.35 : 1)), Theme.accent, 0.14 * tile.targetF)
    readonly property var thumbPalette: ({
            faint: String(Theme.textFaint),
            muted: String(Theme.textMuted),
            link: String(Theme.accent),
            codeBg: String(Theme.mdCode),
            mark: String(Theme.mdMark),
            named: {
                red: String(Theme.mdRed),
                orange: String(Theme.mdOrange),
                yellow: String(Theme.mdYellow),
                green: String(Theme.mdGreen),
                teal: String(Theme.mdTeal),
                blue: String(Theme.mdBlue),
                purple: String(Theme.mdPurple),
                pink: String(Theme.mdPink),
                gray: String(Theme.mdGray)
            }
        })

    DeviceScale {
        id: dev
    }
    Item {
        id: face
        anchors.fill: parent
        layer.enabled: tile.faceLayered
        layer.smooth: true
        layer.mipmap: true
        layer.textureSize: Qt.size(Math.ceil(face.width * dev.value * 2), Math.ceil(face.height * dev.value * 2))

        Text {
            id: titleText
            x: tile.padding
            y: tile.padding - 2
            width: tile.width - 2 * tile.padding - (linkGlyph.visible ? 14 : 0)
            text: tile.entry ? tile.entry.title : ""
            font.family: tile.fontFamily
            font.pixelSize: 12
            font.bold: true
            color: tile.entry && tile.entry.broken ? Theme.textFaint : Theme.textPrimary
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        Text {
            id: linkGlyph
            visible: !!(tile.entry && tile.entry.isLink)
            x: tile.width - tile.padding - width
            y: titleText.y + 1
            text: "\uF0C1"
            font.family: "Symbols Nerd Font"
            font.pixelSize: 10
            color: Mix.c(Theme.textFaint, Theme.accent, linkHover.hovered ? 1 : 0)
            // A click here opens where the file really is (NotesGrid hit-tests
            // it); the pointer says so.
            HoverHandler {
                id: linkHover
                cursorShape: Qt.PointingHandCursor
            }
            HoverTip {
                overlayItem: tile.overlayItem
                anchorItem: linkGlyph
                show: linkHover.hovered
                text: tile.entry ? (tile.entry.broken ? "Missing: " : "") + String(tile.entry.linkTarget || tile.entry.realPath || "").replace(/^\/home\/[^\/]+/, "~") : ""
            }
        }

        // The note's first lines, faded out at the foot.
        Item {
            id: thumbBox
            x: tile.padding
            y: titleText.y + titleText.height + 6
            width: tile.width - 2 * tile.padding
            height: Math.max(0, footText.y - 4 - y)
            clip: true
            Text {
                width: parent.width
                // StyledText, not RichText: it re-lays out on every resize step
                // (LiveMarkdown.thumbHtml has the numbers).
                textFormat: Text.StyledText
                wrapMode: Text.Wrap
                text: tile.entry && !tile.entry.broken && tile.entry.head ? LM.thumbHtml(tile.entry.head, tile.entry.title, tile.thumbPalette, {
                        maxLines: 10,
                        kind: tile.entry.kind === "text" ? "text" : "markdown"
                    }) : ""
                font.family: tile.entry && tile.entry.kind === "text" ? "Consolas" : tile.fontFamily
                font.pixelSize: 10
                color: Theme.textMuted
                lineHeight: 1.1
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: Math.min(18, parent.height)
                gradient: Gradient {
                    GradientStop {
                        position: 0
                        color: Qt.rgba(tile._ground.r, tile._ground.g, tile._ground.b, 0)
                    }
                    GradientStop {
                        position: 1
                        color: tile._ground
                    }
                }
            }
        }
        Text {
            id: footText
            x: tile.padding
            y: tile.height - tile.padding - height + 2
            width: tile.width - 2 * tile.padding
            text: tile.entry ? (tile.entry.broken ? "missing" : (tile._rel ? tile._rel.text : "")) : ""
            font.family: tile.fontFamily
            font.pixelSize: 10
            color: Theme.textFaint
            elide: Text.ElideRight
        }
    }
}
