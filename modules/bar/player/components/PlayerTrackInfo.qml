pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// PlayerTrackInfo.qml
//
// What is playing, and how far into it: title, artist, album, and the two time
// figures. Four facts in RESERVED slots, so that a track with no album tag
// does not lift the rail underneath it by a line, and a figure gaining a digit
// does not shove the one beside it.
//
// THE RESERVED-SLOT RULE, from the system update's `textBlock`. The block's
// height is fixed by how many companion lines it RESERVES -- two normally,
// one when `compact` folds the album onto the artist's line -- and not by how
// many of them have text. A blank slot fades its text out over 160 ms and
// keeps its height. Text itself swaps instantly: nothing here ever crossfades
// two strings through each other.
//
// When EVERY companion slot is blank -- a file with only a filename to its
// name -- a title pinned to the top would sit high over a band
// of nothing, so the title eases to the vertical middle of the block instead
// (260 ms OutCubic, the shell's resize easing) and slides back up when a line
// fills. The block's height never changes for it, so nothing below moves. The
// system update centres on ONE blank companion; here it is all of them, which
// is the same rule with two slots instead of one.
//
// THE FIGURES. Elapsed on the left, the track's TOTAL length on the right,
// each in a slot measured from a template of the widest digit at the current
// font -- FontMetrics, never a Text's own width read back into what sizes it.
// The template is what the CURRENT duration needs, not the worst case in the
// library: a four-minute track reserves `0:00`, a track past ten minutes
// `00:00`, one past an hour `0:00:00`. Elapsed can never out-digit the
// duration, so ONE template serves both ends and the two slots are the same
// width by construction.
//
// The right figure is the track's TOTAL length, not the time remaining. It is
// the fact that does not move while the track plays, which is what makes the
// pair readable at a glance: one figure counts up, the other is the length it
// is counting toward.
//
// WHY NOT DownloadStats, which is the shell's non-jittering figures line.
// Its slots are right for a download: the ETA's is a fixed "DD:DD", measured
// once for the shape a countdown has. A track's is not a shape, it is a
// length -- 4:05, 12:30, 1:10:05 -- and reserving the library's worst case
// would hang two empty digits off every three-minute song, while reserving
// "DD:DD" would let an hour-long one overflow. So the slot is measured from
// THIS track's duration, with DownloadStats' own machinery (FontMetrics
// templates of the widest digit, never a Text's width read back) rather than
// its component. Its `alignment` is also one per line, and this line pins one
// figure to each end.
//
// Elapsed is LEFT-aligned inside its slot and the total RIGHT-aligned, each
// flush with the edge it belongs to. Within a fixed slot only the figure's own
// far end can move (9:59 -> 10:00 on a long track, once); nothing beside it
// ever does, which is the whole point of the slot.
//
// WHERE THE FIGURES LINE SITS. Under the text block by `timesGap` when the
// block is exactly its implicit height, which is every host that lets it size
// itself. When a host gives it MORE height than that -- the mini view, where
// the record beside it is taller than the text -- `figuresAtBottom` pins the
// figures to the block's foot instead, and the slack opens up between the text
// and the figures. The figures belong with the viewfinder under them, not with
// the title above them, so in every view the pair reads as one instrument.
//
// `figuresBottomGap` is the room the block keeps BELOW the figures, inside its
// own implicit height, so the viewfinder that follows is not right up against
// them. It is part of this block's height rather than the host's spacing
// because it is the same distance in every view, and a distance that lives in
// two places drifts.
//
// Neither position is eased here. The height that moves them is the host's,
// and the host already eases it at 260 OutCubic; a Behavior on top of that is
// the second clock this shell keeps deleting.
//
// THE SKELETON. `empty` -- nothing playing at all, not paused: album done,
// queue empty -- swaps every string for a still silhouette of it: three bars in
// the text block, a bar at each end of the figures line, and the chip's own
// box (PlayerFidelityChip.skeleton). Static, with no pulse: the shell's
// skeletons pulse because something is LOADING, and here nothing is. The bars
// are measured from template strings at the real faces rather than taken as
// fractions of the block's width -- a silhouette is the perimeter the text
// would take, and a 600 px block does not imply a 370 px title.
//
// THE CHIP sits centred on the figures line. That line already has both of its
// ends pinned and a hole in the middle, the fidelity is a fact ABOUT the file
// being timed, and putting it there costs no new row -- the shell's rule
// against clutter is to use what is already on screen. `implicitWidth` is the
// narrowest width at which the three cannot collide, so a host that honours it
// never has to hide one.
//
// Sized through implicitWidth/implicitHeight; paints no background.
// =============================================================================
Item {
    id: root

    // ---- Content ----
    property string title: ""
    property string artist: ""
    property string album: ""
    property real position: 0            // seconds
    property real duration: 0            // seconds
    // The fidelity object. Null hides the chip; `empty` silhouettes it,
    // whatever is bound here (see PlayerFidelityChip).
    property var fidelity: null

    // ---- Mode ----
    // Nothing is playing -- not paused: stopped, queue empty, album done. Every
    // string is replaced by its silhouette and the block keeps every one of its
    // measurements, so the real text resolves in place when it arrives.
    property bool empty: false
    property bool compact: false         // album folds onto the artist's line
    // The artist's and the album's lines are links (the host opens their pages). In compact the one line carries both and it is the album's.
    signal artistClicked()
    signal albumClicked()
    // HOW FAR INTO COMPACT, 0..1, for the things that can travel: the figure
    // size and where the figures line sits. A host that eases a view switch
    // binds this to its own fraction and flips `compact` at the half-way
    // point, so the block is a pure function of one number and the switch
    // reads the same in both directions. A host that only sets the bool gets
    // the plain switch.
    property real compactF: root.compact ? 1 : 0
    // Pin the figures to the block's foot instead of to the text above them.
    // Only tells them apart when the host gives the block more height than its
    // implicit one; at implicit height the two positions are the same pixel.
    property bool figuresAtBottom: false
    // ...and how far toward the foot the figures are, the same way. In mini
    // they are pinned against the viewfinder; in the player they sit under
    // the text. Switched by the bool alone, they would leap a handful of pixels
    // on the first frame of a switch, before the box they sit in has moved.
    property real figuresAtBottomF: root.figuresAtBottom ? 1 : 0
    property real listScale: 1.0
    property string fontFamily: "Inter"

    // The chip is its own component with its own knobs. Handing it out is one
    // line; forwarding twelve properties through this file would be twelve
    // things to keep in step with it.
    readonly property alias chip: fidChip

    // ---- Type ----
    property real titleSize: 18
    property real lineSize: 12
    // Eased between the two views' sizes rather than swapped -- a swap reads
    // as the figures changing font in one frame while everything around them
    // is still moving. Two named sizes so a host can tune either.
    property real figureSizeNormal: 11
    property real figureSizeCompact: 10
    readonly property real figureSize: root.figureSizeNormal
        + (root.figureSizeCompact - root.figureSizeNormal) * Math.max(0, Math.min(1, root.compactF))

    // ---- Layout ----
    property real lineGap: 2             // between the reserved text lines
    property real timesGap: 6            // text block -> figures line
    // Figures -> whatever the host puts under the block (the viewfinder). 12,
    // the shell's padding: at 6 the figures and the rail read as one crowded
    // row rather than as a caption over an instrument.
    property real figuresBottomGap: 12
    property real figureGap: 8           // figures -> chip, at the minimum width
    property int resizeMs: 260
    property int fadeMs: 160

    // ---- The skeleton's shape ----
    // Measured, never drawn: the width of each bar is the width these strings
    // would have in the face that line uses, clamped to the block. A title's
    // silhouette that is longer than the artist's below it is what a track
    // block looks like from across the room.
    property string skeletonTitleTemplate: "The Track's Title"
    property string skeletonArtistTemplate: "An Artist Name"
    property string skeletonAlbumTemplate: "An Album"
    // How thick a bar is against the line it stands in. 0.55 is ListSkeleton's
    // relationship (a 12 px bar on a 20 px title line, 8 on 15).
    property real skeletonThickness: 0.55

    // ---- Palette (Theme defaults; a host may override every one) ----
    property color skeletonColor: Theme.headerBox  // a shade darker than the ground
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color surfaceColor: Theme.surface     // the fill the chip stands on
    property color chipColor: Theme.headerBox
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color accentColor: Theme.accent
    property color okColor: Theme.ok

    // ---- Derived -------------------------------------------------------------
    readonly property real _s: Math.max(0.2, root.listScale)

    FontMetrics { id: titleFm; font.family: root.fontFamily; font.pixelSize: root.titleSize * root._s; font.bold: true }
    FontMetrics { id: lineFm;  font.family: root.fontFamily; font.pixelSize: root.lineSize * root._s }
    FontMetrics { id: timeFm;  font.family: root.fontFamily; font.pixelSize: root.figureSize * root._s
                  font.features: ({ "tnum": 1 }) }

    readonly property real _titleH: titleFm.height
    readonly property real _lineH: lineFm.height
    readonly property real _timesH: timeFm.height
    readonly property real _gap: root.lineGap * root._s

    // The two companion strings as they are actually laid out. Compact folds
    // the album onto the artist's line with the shell's separator, so one slot
    // carries both facts instead of two slots carrying one each.
    readonly property string _artistLine: root.compact
        ? (root.artist.length > 0 && root.album.length > 0 ? root.artist + " · " + root.album
           : root.artist.length > 0 ? root.artist : root.album)
        : root.artist
    readonly property string _albumLine: root.compact ? "" : root.album

    // RESERVED, not filled -- the distinction this whole component exists for.
    readonly property int _companionSlots: root.compact ? 1 : 2
    readonly property int _companionsFilled:
        (root._artistLine.length > 0 ? 1 : 0)
        + (!root.compact && root._albumLine.length > 0 ? 1 : 0)
    // An EMPTY block is not a blank one. The centring rule exists so a lone
    // title does not sit high over a band of nothing; with the skeleton showing
    // there is no band of nothing, and the title's own silhouette is on the top
    // line. Centring the (invisible) title there would make it slide 16 px up
    // as it faded in -- the opposite of resolving in place.
    readonly property bool _allBlank: root._companionsFilled === 0 && !root.empty

    readonly property real _blockHeight: root._titleH + root._companionSlots * (root._gap + root._lineH)

    // ---- Figures -------------------------------------------------------------
    readonly property bool _hasTimes: root.duration > 0 && !root.empty
    function _fmt(sec) {
        const s = Math.max(0, Math.floor(sec));
        const h = Math.floor(s / 3600);
        const m = Math.floor((s % 3600) / 60);
        const r = s % 60;
        const two = n => (n < 10 ? "0" : "") + n;
        return h > 0 ? h + ":" + two(m) + ":" + two(r) : m + ":" + two(r);
    }
    readonly property string _elapsedText: root._hasTimes
        ? root._fmt(Math.max(0, Math.min(root.position, root.duration))) : ""
    readonly property string _totalText: root._hasTimes ? root._fmt(root.duration) : ""

    // The widest digit in this font, so a slot is measured for the worst case
    // the glyphs allow rather than for the digits that happen to be showing.
    // Each of the three bindings below reads `timeFm.font` first: advanceWidth
    // is a call, and a call alone leaves the binding with nothing to watch, so
    // without it a font or size change would never re-measure the slots
    // (DownloadStats uses the same idiom for the same reason).
    readonly property string _wideDigit: {
        const f = timeFm.font;
        let best = "0", bw = 0;
        for (const d of "0123456789") {
            const w = timeFm.advanceWidth(d);
            if (w > bw) { bw = w; best = d; }
        }
        return best;
    }
    // What THIS track's duration needs, and no more.
    readonly property string _timeTemplate: {
        const D = root._wideDigit;
        const d = Math.max(0, Math.floor(root.duration));
        if (d >= 3600)
            return D.repeat(String(Math.floor(d / 3600)).length) + ":" + D + D + ":" + D + D;
        return D.repeat(String(Math.floor(d / 60)).length) + ":" + D + D;
    }
    // One slot, both ends: the elapsed figure can never out-digit the duration
    // the template is measured from. An empty block reserves it too -- a
    // duration of 0 gives the same `D:DD` shape -- so the silhouette's bars are
    // the width the real figures will be.
    readonly property real _timeSlot: {
        const f = timeFm.font;
        return (root._hasTimes || root.empty) ? Math.ceil(timeFm.advanceWidth(root._timeTemplate)) : 0;
    }

    // ---- The skeleton's measurements ------------------------------------------
    // A bar is as thick as a fraction of the line it stands in, and as long as
    // its template would be in that line's own face -- clamped to the block, so
    // a narrow host gets a bar that fits rather than one that runs out of it.
    // Each width binding reads the FontMetrics' `font` first for the same
    // reason the time slots do: advanceWidth is a call, and a call alone leaves
    // the binding with nothing to watch when the face changes.
    function _barH(lineH) { return Math.max(2, Math.round(lineH * root.skeletonThickness)); }
    function _barW(fm, tpl) { return Math.min(root.width, Math.ceil(fm.advanceWidth(tpl))); }
    readonly property real _skelTitleW: {
        const f = titleFm.font;
        return root._barW(titleFm, root.skeletonTitleTemplate);
    }
    readonly property real _skelArtistW: {
        const f = lineFm.font;
        return root._barW(lineFm, root.compact
            ? root.skeletonArtistTemplate + " · " + root.skeletonAlbumTemplate
            : root.skeletonArtistTemplate);
    }
    readonly property real _skelAlbumW: {
        const f = lineFm.font;
        return root._barW(lineFm, root.skeletonAlbumTemplate);
    }

    // ---- Size ----------------------------------------------------------------
    // The narrowest width at which the two figures and the chip cannot touch.
    // The three text lines elide, so they ask for nothing.
    implicitWidth: root._timeSlot * 2
        + (fidChip.implicitWidth > 0 ? fidChip.implicitWidth + root.figureGap * root._s * 2 : 0)
    implicitHeight: root._blockHeight + root.timesGap * root._s + root._timesH
        + root.figuresBottomGap * root._s

    // A line of the block as a link: as wide as its ink, nothing announces it but the pointer (a short fade to the accent, the hand).
    component LineLink: MouseArea {
        id: link
        required property Text line
        property real hf: link.containsMouse ? 1 : 0
        Behavior on hf {
            NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }
        TextMetrics {
            id: ink
            font: link.line.font
            text: link.line.text
        }
        width: Math.min(Math.ceil(ink.advanceWidth), link.line.width)
        height: link.line.height
        enabled: link.line.text.length > 0 && !root.empty
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
    }

    // ---- The text block ------------------------------------------------------
    Item {
        id: textBlock
        objectName: "trackTextBlock"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: root._blockHeight

        Text {
            id: titleText
            objectName: "trackTitle"
            width: parent.width
            height: root._titleH
            y: root._allBlank ? (root._blockHeight - root._titleH) / 2 : 0
            Behavior on y { NumberAnimation { duration: root.resizeMs; easing.type: Easing.OutCubic } }
            verticalAlignment: Text.AlignVCenter
            // `empty` hides every string even if the host left one behind: the
            // silhouette says nothing is playing, and a stale title under it
            // would say two things at once.
            opacity: root.title.length > 0 && !root.empty ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.fadeMs } }
            text: root.title
            color: root.textColor
            font.family: root.fontFamily
            font.pixelSize: root.titleSize * root._s
            font.bold: true
            elide: Text.ElideRight
        }

        Text {
            id: artistText
            width: parent.width
            height: root._lineH
            y: root._titleH + root._gap
            verticalAlignment: Text.AlignVCenter
            opacity: root._artistLine.length > 0 && !root.empty ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.fadeMs } }
            text: root._artistLine
            color: Mix.c(root.mutedColor, root.accentColor, artistLink.hf)
            font.family: root.fontFamily
            font.pixelSize: root.lineSize * root._s
            elide: Text.ElideRight
            LineLink {
                id: artistLink
                objectName: "trackArtistLink"
                line: artistText
                onClicked: root.compact ? root.albumClicked() : root.artistClicked()
            }
        }

        Text {
            id: albumText
            visible: !root.compact
            width: parent.width
            height: root._lineH
            y: root._titleH + root._gap + (root._lineH + root._gap)
            verticalAlignment: Text.AlignVCenter
            // On the RAW album, not on `_albumLine`: that string is emptied
            // when compact folds the album onto the artist's line, and an
            // opacity that followed it would fade the line in on the way back
            // to the player while `visible` cuts it in one frame on the way
            // out -- the same swap, two different motions. The fold is
            // `visible`'s alone, instant both ways; the fade is for what it is
            // for, an album that has just been learned.
            opacity: root.album.length > 0 && !root.empty ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.fadeMs } }
            text: root._albumLine
            color: Mix.c(root.faintColor, root.accentColor, albumLink.hf)
            font.family: root.fontFamily
            font.pixelSize: root.lineSize * root._s
            elide: Text.ElideRight
            LineLink {
                id: albumLink
                objectName: "trackAlbumLink"
                line: albumText
                onClicked: root.albumClicked()
            }
        }

        // The silhouette of those three lines. Each bar is centred on the line
        // its text occupies -- laid out from the SAME numbers, so the bar and
        // the string it stands for share a centre and the text resolves in
        // place. The album's bar is not drawn compact, where there is no album
        // line to stand in for; the artist's template carries both facts there,
        // exactly as the real line does.
        InfoSkeletonBar {
            objectName: "trackSkelTitle"
            x: 0
            y: (root._titleH - height) / 2
            width: root._skelTitleW
            height: root._barH(root._titleH)
        }
        InfoSkeletonBar {
            objectName: "trackSkelArtist"
            x: 0
            y: root._titleH + root._gap + (root._lineH - height) / 2
            width: root._skelArtistW
            height: root._barH(root._lineH)
        }
        InfoSkeletonBar {
            objectName: "trackSkelAlbum"
            visible: !root.compact
            x: 0
            y: root._titleH + root._gap + (root._lineH + root._gap) + (root._lineH - height) / 2
            width: root._skelAlbumW
            height: root._barH(root._lineH)
        }
    }

    // Every silhouette in this block is the same still bar in a different box:
    // the host's word, no pulse, one colour pair. Declaring that once is what
    // keeps the five of them in step -- and what stops a sixth being added
    // with the pulse left on.
    component InfoSkeletonBar: SkeletonBar {
        showing: root.empty
        pulse: false
        barColor: root.skeletonColor
        groundColor: root.surfaceColor
        fadeMs: root.fadeMs
    }

    // ---- The figures line ----------------------------------------------------
    Item {
        id: timesRow
        objectName: "trackTimes"
        anchors.left: parent.left
        anchors.right: parent.right
        height: root._timesH
        // Not anchored: the two positions are two different rules and one of
        // them reads the item's OWN height, which the host owns. At implicit
        // height they are the same pixel; above it they are the point of the
        // property. No Behavior -- the height that moves this is already eased
        // by the host, and a second clock on top of it can only lag.
        y: {
            const under = root._blockHeight + root.timesGap * root._s;
            const foot = root.height - root.figuresBottomGap * root._s - timesRow.height;
            const f = Math.max(0, Math.min(1, root.figuresAtBottomF));
            return under + (foot - under) * f;
        }

        Text {
            id: elapsedText
            objectName: "trackElapsed"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: root._timeSlot
            horizontalAlignment: Text.AlignLeft
            opacity: root._hasTimes ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.fadeMs } }
            text: root._elapsedText
            color: root.mutedColor
            font: timeFm.font
        }

        PlayerFidelityChip {
            id: fidChip
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: fidChip.implicitWidth
            height: fidChip.implicitHeight
            fidelity: root.fidelity
            skeleton: root.empty
            skeletonColor: root.skeletonColor
            listScale: root._s
            fontFamily: root.fontFamily
            surfaceColor: root.surfaceColor
            chipColor: root.chipColor
            bevelColor: root.bevelColor
            shadowColor: root.borderColor
            accentColor: root.accentColor
            okColor: root.okColor
            mutedColor: root.mutedColor
            faintColor: root.faintColor
        }

        Text {
            id: totalText
            objectName: "trackTotal"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: root._timeSlot
            horizontalAlignment: Text.AlignRight
            opacity: root._hasTimes ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.fadeMs } }
            text: root._totalText
            color: root.mutedColor
            font: timeFm.font
        }

        // A bar at each end, the slot's own width: the figures' silhouette is
        // the slot, because the slot is what the figure is allowed to fill.
        InfoSkeletonBar {
            objectName: "trackSkelElapsed"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: root._timeSlot
            height: root._barH(root._timesH)
        }
        InfoSkeletonBar {
            objectName: "trackSkelTotal"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: root._timeSlot
            height: root._barH(root._timesH)
        }
    }
}
