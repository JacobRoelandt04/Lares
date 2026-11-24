pragma ComponentBehavior: Bound

import QtQuick
import "../theme"

// =============================================================================
// ListSectionHeader.qml
//
// Header for a list section: title, amount/subtitle underneath, an optional
// carved box whose inset shadow carries its progress, and a chevron.
//
// The WHOLE header is one click target — title, subtitle, the empty space
// between them and the chevron, and the chevron itself: the chevron is the
// affordance users aim at, so it cannot sit outside the hit area.
//
//   ListSectionHeader {
//       title: "Extra"
//       subtitle: "181 packages"
//       accentColor: "#44C145"
//       expanded: section.open
//       onToggled: section.open = !section.open
//   }
//
// THE INSET REPORTS EITHER A FRACTION OR THE FACT THAT WORK IS HAPPENING.
// `progress` alone fills the inset from the left: a real fraction, arriving in
// steps, smoothed by `progressAnimMs` so the tint slides between readings.
// `progress` WITH `progressTail` makes it a travelling band instead -- the
// indeterminate bar, for a section whose worker cannot report progress at all
// (a language model writing a tool call: see LlmTurn and Sweep.js). The band's
// two edges arrive already shaped and MOVE EVERY FRAME, so the smoothing is
// switched off with it: a Behavior fed a new target every frame restarts
// before it has ticked once and never advances at all, so the LLM turn
// header's sweep would stand still where it is meant to be the thing saying
// "working".
// =============================================================================
Item {
    id: header

    // ---- Content ----
    property string title: ""
    property string subtitle: ""
    // How the title and subtitle are read. Text.AutoText, the default, suits
    // every host whose subtitle it wrote (a subtitle may carry a <b>); a host that shows
    // text it did not write -- a notification's summary as a group's preview
    // -- passes Text.PlainText, so a tag or an entity reads as the sender
    // wrote it, the way the card beside it draws the same words.
    property int textFormat: Text.AutoText
    // Keep the subtitle to ONE line: its line breaks (and runs of spaces) are
    // folded into single spaces and what does not fit is elided. Off by
    // default -- a host's own subtitle is one line by construction; a
    // preview of somebody else's text is not, and a summary with a newline
    // in it would grow the header by a line (58 -> 72 px).
    property bool subtitleOneLine: false
    // Download figures for this section, laid out by a DownloadStats block so
    // a changing number moves nothing beside it. Bytes are raw and formatted
    // there; rate and time arrive already in pacman's shape ("10.1 MiB/s",
    // "01:13"). Nothing shows while bytesTotal <= 0 and both texts are empty.
    property real   detailBytesDone: 0
    property real   detailBytesTotal: 0
    property string detailRateText: ""
    property string detailEtaText: ""
    // Two arrangements of the same three things:
    //
    //   normal   title                              (bold)
    //            subtitle              bytes · rate · eta
    //
    //   compact  title                        subtitle
    //            bytes · rate · eta
    //
    // Compact is for a narrow list (the verbose view's side panel): the
    // figures get a whole line to themselves, pinned left, and the count
    // moves up beside the title -- right-aligned, in its own muted style.
    property bool   compactLayout: false
    property bool   expandable: true
    property bool   expanded: false

    // ---- One plain figure, at the right of the subtitle line -------------
    //
    // For a section whose second line carries a single live number rather
    // than a download's four (the LLM turn's elapsed silence). It sits in a
    // slot measured with FontMetrics from `figureTemplate` -- never from the
    // text itself -- so the number can tick without moving the subtitle
    // beside it, and it aligns LEFT inside that slot, because the digit that
    // changes most often is the last one and it must stay where the eye is.
    //
    // Its PRESENCE fades, its text never does: setting `figureText` back to
    // "" fades the slot out still reading its last value, rather than
    // blanking to a wrong number for the length of the fade.
    property string figureText: ""
    // The widest value the slot must hold ("88:88"). Digits are re-measured
    // with the font's widest, DownloadStats' rule, so a template of zeroes is
    // as good as one of eights. Empty means the slot is the text's own width.
    property string figureTemplate: ""
    property int    figureFadeMs: 160
    // The figure is a MARK: a host may explain it on hover, and needs the
    // item to anchor a tip to and the hover state to show it by.
    readonly property alias figureHovered: figureHover.hovered
    readonly property Item  figureAnchor: figureLabel

    // ---- Styling ----
    property color textColor:   "#5D5D5F"
    property color mutedColor:  "#8A8A8C"
    property color faintColor:  "#B8BBC2"
    // The category's colour: the box's tint. It reaches nothing but the box's
    // inset, so a host is free to hand it a colour that is itself a MIX -- the
    // LLM turn fades its band out and back through this property, mixing to
    // the box's own shadow colour so a state swap underneath it is invisible.
    // Which is the reason there is no Behavior on it and must never be one:
    // the fraction is the host's clock, and a second one here would lag it and
    // chase the theme besides.
    property color accentColor: "transparent"
    property string fontFamily: "Inter"

    // ---- Optional icon slot ----
    //
    // A glyph at the LEFT of the header, spanning its box, the way
    // UpdatePackageRow places a package's icon: the text column shifts right
    // by the slot and nothing else changes. With no glyph there is no slot,
    // no item and no cost.
    property string iconGlyph: ""
    property string iconFontFamily: "Symbols Nerd Font"
    property int    iconSize: 15
    property color  iconColor: header.mutedColor
    property real   iconGap: 8
    readonly property real _iconSlot: header.iconGlyph.length > 0
        ? (header.iconSize + header.iconGap) * header._s : 0

    property int  titleSize: 15
    property int  subtitleSize: 11
    // The figures' size in the compact layout. Smaller than the subtitle so
    // "123.4 / 148.2 MiB · 2.4 MiB/s · 00:12" fits a narrow panel whole.
    property int  detailSizeCompact: 10
    property int  chevronSize: 15
    // Clearance between the box's edge and its text.
    //
    // Needs to clear the inset shadow, not just the border. The inset is
    // several pixels deep and reads as an edge in its own right, so text laid
    // at 2px would sit inside the shading and look like it is falling off
    // the box. The header's footprint therefore does not match a row's,
    // which is fine -- a header is not a row.
    property real boxPadding: 11
    property real boxPaddingV: 8

    readonly property real _s: Math.max(0.2, listScale)
    readonly property real _titleSize:    titleSize * _s
    readonly property real _subtitleSize: subtitleSize * _s
    readonly property real _chevronSize:  chevronSize * _s
    // Uniform scale for the whole header. Everything sized here multiplies by
    // it, so a host can tune list density per view without the layout or the
    // animation maths going out of step.
    property real listScale: 1.0

    property int animDuration: 200

    // ---- Carved surface -------------------------------------------------
    //
    // The header sits in its own ShadowBox, and its progress is carried by the
    // colour of that box's inset shadow rather than by a stripe beside the
    // text. There is no stripe: a coloured shadow already says which category
    // this is, so a second coloured mark would be saying it twice.
    property color boxColor: "#DCDFE6"          // darker than the surface
    property color boxSurfaceColor: "#EAEDF5"
    property color boxBevelColor: "#EEF0F7"
    property color boxShadowColor: "#AAADB4"
    property real  boxRadius: 10
    property real  boxBevelWidth: 1
    // Set by the list for its topmost section, so that box shares the
    // container's corner.
    property bool  firstInList: false
    property real  containerRadius: 10
    // The radius the box's TOP corners take, overriding the firstInList rule
    // when it is >= 0. A list whose topmost header is fixed (the system
    // update's sections) needs nothing but firstInList; a SCROLLING list where
    // any header can come to rest against the container's top edge has to say
    // which radius that header wants right now, because "shares the
    // container's corner" is a position there, not an index. In the header's
    // own units -- the box divides by the list scale, exactly as it does for
    // containerRadius.
    property real  topCornerRadius: -1
    // Clearance under the box. The box's own carved edge separates it from
    // the rows, so a divider rule would draw a second boundary a few pixels
    // from the first.
    property real  bottomGap: 6
    readonly property real _bottomGap: bottomGap * _s
    // Interpolated, so the tint slides rather than jumping between readings —
    // category progress arrives in steps as packages finish. The idle mark
    // is applied by the box itself, in px, so this is the bare fraction.
    property int   progressAnimMs: 320
    property real  _animProgress: header._showProgress ? Math.min(1, header.progress) : 0
    // Off while a band is running: its edges are already shaped and already
    // move every frame, and a Behavior on a per-frame target never advances.
    Behavior on _animProgress {
        enabled: header.progressTail < 0
        NumberAnimation { duration: header.progressAnimMs; easing.type: Easing.OutCubic }
    }

    // ---- Inset, idle and under way ---------------------------------------
    //
    // An idle category shows a constant-width sliver of its colour at the
    // left of the inset, and that width is
    // in px (times listScale), so it is the same mark in a wide list and a
    // narrow one. Progress then sweeps the colour rightward from there.
    //
    // THE DEFAULTS ARE SHADOWBOX'S OWN, which are the system update header's
    // tuned look (see ShadowBox's "Idle and active shapes"): a header that
    // sets none of these draws exactly what a ShadowBox that sets none of
    // them draws with the same idle mark. Parked: the colour gives way to the grey over a 12 px glow,
    // at 0.55 strength, lingering a little (falloff 0.9), 7.5 px deep -- a
    // hint. Under way: all of the strength, falloff 1, 7 px deep -- the news.
    // They are exposed as pairs so a host can decide otherwise, and blend on
    // progress rather than on a clock. A header with a mark and no progress
    // is parked (its category's colour at rest, as the update's are before a
    // run), so the carve does not move when a host switches progress on at
    // 0; a header with NOTHING in its inset draws the active shape without
    // the hue (see the box).
    property real  idleWidthPx: 12
    property real  boxIdleFeatherPx: 12
    property real  boxActiveFeatherPx: 12
    property real  boxShadowWidth: 7.5            // idle depth
    property real  boxProgressShadowWidth: 7      // depth under way
    property real  boxIdleEdgeAlpha: 0.55
    property real  boxActiveEdgeAlpha: 1.0
    property real  boxIdleFalloff: 0.9
    property real  boxActiveFalloff: 1.0
    // Progress at which the idle shape has fully given way to the active one.
    // The blend starts where the sweep leaves the idle mark.
    property real  progressBlendEnd: 0.32

    signal toggled()
    // A right click on the header, for a host that gives it a meaning (the update's group
    // headers: favourite the whole group). Off unless asked for: with it off the hit area
    // takes the left button only, and a right click goes on to whatever is
    // beneath.
    property bool rightClickEnabled: false
    signal rightClicked()

    // Progress carried by the box's inset, 0..1. Negative disables it.
    property real progress: -1
    // The band's TRAILING edge, 0..1, when the inset is reporting that work is
    // happening rather than how far it has got. Negative -- the default and
    // every determinate list in the shell -- leaves the inset a fill.
    property real progressTail: -1
    property bool progressFailed: false
    property color errorColor: Theme.error   // a failed header in the theme's own red (no host passes one)
    readonly property bool _showProgress: header.progress >= 0
    // The inset's colour: the category's, or the error's once a step has
    // failed.
    readonly property color _inkColor: header.progressFailed ? header.errorColor : header.accentColor
    // Whether the inset carries anything at all: progress, or a resting mark
    // that can be seen (a width and a colour). See the box's `shadowProgress`.
    readonly property bool _hasInset: header._showProgress
        || (header.idleWidthPx > 0 && header._inkColor.a > 0)

    // The subtitle as it is drawn: folded to one line when asked.
    readonly property string _subtitleShown: header.subtitleOneLine
        ? header.subtitle.replace(/\s+/g, " ").trim() : header.subtitle

    // Where the subtitle goes, and whether the figures line exists, decided
    // from the INPUTS. The line's visibility must never be read back off its
    // own children: a child's `visible` reports its effective visibility,
    // which is false for as long as the line is hidden -- so a line hidden
    // for want of figures could never notice them arriving.
    readonly property bool _subtitleOnTitle: compactLayout && header._subtitleShown.length > 0
    readonly property bool _subtitleOnLine:  !compactLayout && header._subtitleShown.length > 0
    readonly property bool _hasDetail: detailBytesTotal > 0
                                    || detailRateText.length > 0 || detailEtaText.length > 0

    // The figure's own presence clock and its latched text; see `figureText`.
    property string _figureShown: ""
    onFigureTextChanged: if (header.figureText.length > 0) header._figureShown = header.figureText
    property real _figureF: header.figureText.length > 0 ? 1 : 0
    Behavior on _figureF {
        NumberAnimation { duration: header.figureFadeMs; easing.type: Easing.OutCubic }
    }
    readonly property bool _figureOn: header._figureF > 0.001
    FontMetrics {
        id: figureFm
        font.family: header.fontFamily
        font.pixelSize: header._subtitleSize
        // Ask the font for tabular figures; harmless where it has none, which
        // is why the slot below is measured as well.
        font.features: ({ "tnum": 1 })
    }
    // Reads `figureFm.font` first: advanceWidth is a call, and a call alone
    // leaves the binding with nothing to watch when the face changes.
    readonly property real _figureW: {
        const f = figureFm.font;
        if (!header._figureOn)
            return 0;
        let wide = "0", bw = 0;
        for (const d of "0123456789") {
            const w = figureFm.advanceWidth(d);
            if (w > bw) { bw = w; wide = d; }
        }
        const tpl = header.figureTemplate.length > 0
            ? header.figureTemplate.replace(/[0-9]/g, wide) : "";
        return Math.ceil(Math.max(figureFm.advanceWidth(tpl),
                                  figureFm.advanceWidth(header._figureShown)));
    }

    // What the figure takes off the line, gap included, for everything else
    // on it. Zero when there is no figure, so a list without one is laid out
    // without it.
    readonly property real _figureGap: header._figureOn ? header._figureW + 12 * header._s : 0
    // Breathing room between the download figures and whatever ends the line
    // (the chevron): the text column already stops 8 px short of it, and the
    // figures must not sit hard against that.
    readonly property real _detailRightGap: 8 * header._s

    readonly property real _boxPad:  boxPadding * _s
    readonly property real _boxPadV: boxPaddingV * _s
    readonly property real _textLeft: _boxPad
    readonly property real _textRight: _boxPad
    readonly property real _textTop:   _boxPadV


    // The layout height switches immediately with the content; nothing
    // here animates its own size.
    implicitHeight: textCol.y + textCol.implicitHeight
        + header._boxPadV
        + header._bottomGap

    // Continuous 0→1 so the chevron and anything a caller binds to it move on
    // one clock rather than each carrying its own Behavior. NOT readonly: a
    // Behavior has to be able to write the property it is smoothing.
    property real _extent: expanded ? 1 : 0
    Behavior on _extent {
        NumberAnimation { duration: header.animDuration; easing.type: Easing.InOutCubic }
    }

    ShadowBox {
        id: headerBox
        z: -1
        // Fills the header exactly, and the header is laid out full width
        // inside its container -- so the box's edges ARE the container's
        // edges. The rows are the things inset from the sides, not the
        // headers.
        //
        // The box is not inset, and not overhung with negative margins
        // either: that pushes it under the scrolling clip and shears the
        // bevel off both sides. The clip is at the container's own bounds, so
        // the box can run right up to them and nothing is cut.
        anchors.fill: parent
        anchors.bottomMargin: header._bottomGap
        // The header that meets the container's own rounded corner takes that
        // radius exactly, so the two curves coincide -- otherwise a crescent
        // of the container's inset shadow shows outside the header's own and
        // the two gradients mash. Which header that is is `firstInList` in a
        // list whose top does not move, and `topCornerRadius` in one where it
        // does. ShadowBox multiplies every radius by sizeScale, which here is
        // the list scale, so both are handed over pre-divided -- otherwise a
        // 1.15 list scale would draw the shared corner 15% larger than the
        // corner it is meant to share.
        readonly property real _topRadius:
            header.topCornerRadius >= 0 ? header.topCornerRadius / header._s
            : (header.firstInList ? header.containerRadius / header._s : -1)
        topLeftRadius: headerBox._topRadius
        topRightRadius: headerBox._topRadius

        baseRadius: header.boxRadius
        surfaceColor: header.boxSurfaceColor
        bevelColor: header.boxBevelColor
        shadowColor: header.boxShadowColor
        backgroundColor: header.boxColor
        bevelWidth: header.boxBevelWidth
        sizeScale: header.listScale

        // A HEADER WITH NOTHING IN ITS INSET IS A PLAIN CARVED BOX AT FULL
        // STRENGTH. With no progress and no mark that can be seen (no idle
        // width, or no colour: the stocks list's "Closed", the LLM sidebar's
        // day groups) the box gets no progress at all (-1) and draws its own
        // carve, which is the under-way shape without the hue --
        // `boxProgressShadowWidth` deep at `boxActiveEdgeAlpha`, falling off
        // at `boxActiveFalloff` (7 px, 1, 1 at the defaults). Handed 0, every
        // such header would wear the PARKED shape carve-wide -- a hint
        // meant to go with a mark, on a box that shows none -- and its carve
        // would lose 40 % of its contrast (the first inset pixel
        // 186 -> 201 on a 223 fill). A header with progress, or with a mark,
        // is untouched: the box reads these three only without progress.
        shadowWidth: header.boxProgressShadowWidth
        shadowEdgeAlpha: header.boxActiveEdgeAlpha
        shadowFalloff: header.boxActiveFalloff

        // The category's own colour, eating into the shadow as the step
        // progresses; at rest, the mark. -1 while there is nothing in the
        // inset (above).
        shadowProgress: header._hasInset ? header._animProgress : -1
        shadowProgressTail: header._showProgress ? header.progressTail : -1
        shadowProgressColor: header._inkColor

        shadowProgressMinPx:     header.idleWidthPx
        progressIdleFeatherPx:   header.boxIdleFeatherPx
        progressActiveFeatherPx: header.boxActiveFeatherPx
        progressIdleWidth:       header.boxShadowWidth
        progressActiveWidth:     header.boxProgressShadowWidth
        progressIdleEdgeAlpha:   header.boxIdleEdgeAlpha
        progressActiveEdgeAlpha: header.boxActiveEdgeAlpha
        progressIdleFalloff:     header.boxIdleFalloff
        progressActiveFalloff:   header.boxActiveFalloff
        progressBlendEnd:        header.progressBlendEnd
    }

    Column {
        id: textCol
        x: header._textLeft + header._iconSlot
        y: header._textTop
        width: header.width - header._textLeft - header._iconSlot - header._textRight
             - chevron.width - 8 * header._s
        spacing: -1

        // Title line. Compact, the subtitle joins it at the right so the
        // line below is free for the figures.
        Item {
            width: parent.width
            height: titleText.implicitHeight
            Text {
                id: titleText
                text: header.title
                textFormat: header.textFormat
                color: header.textColor
                font.pixelSize: header._titleSize
                font.family: header.fontFamily
                font.bold: true
                width: parent.width
                     - (header._subtitleOnTitle ? titleSubtitle.implicitWidth + 8 * header._s : 0)
                elide: Text.ElideRight
            }
            Text {
                id: titleSubtitle
                visible: header._subtitleOnTitle
                text: header._subtitleShown
                textFormat: header.textFormat
                maximumLineCount: header.subtitleOneLine ? 1 : 2147483647
                color: header.mutedColor
                font.pixelSize: header._subtitleSize
                font.family: header.fontFamily
                anchors.right: parent.right
                anchors.baseline: titleText.baseline
            }
        }
        // Second line: subtitle with the figures at its right (normal), or
        // the figures alone at the left (compact).
        Item {
            visible: header._subtitleOnLine || header._hasDetail || header._figureOn
            width: parent.width
            height: Math.max(header._subtitleOnLine ? subtitleText.implicitHeight : 0,
                             header._hasDetail ? detailStats.implicitHeight : 0,
                             header._figureOn ? figureLabel.implicitHeight : 0)
            Text {
                id: subtitleText
                visible: header._subtitleOnLine
                text: header._subtitleShown
                textFormat: header.textFormat
                maximumLineCount: header.subtitleOneLine ? 1 : 2147483647
                color: header.mutedColor
                font.pixelSize: header._subtitleSize
                font.family: header.fontFamily
                // Whatever the figures leave. `width`, not `implicitWidth`:
                // what is actually on the line is what the subtitle has to
                // clear, and it never goes negative here because the figures
                // size themselves against the line.
                width: Math.max(0, parent.width - header._figureGap
                     - (header._hasDetail
                        ? detailStats.width + 12 * header._s + header._detailRightGap : 0))
                elide: Text.ElideRight
            }
            // The one figure, pinned to the line's right end and left-aligned
            // inside its slot. Outermost: the download block, when a list has
            // both, sizes against what this leaves.
            Text {
                id: figureLabel
                visible: header._figureOn
                opacity: header._figureF
                text: header._figureShown
                width: header._figureW
                horizontalAlignment: Text.AlignLeft
                color: header.mutedColor
                font.pixelSize: header._subtitleSize
                font.family: header.fontFamily
                font.features: ({ "tnum": 1 })
                x: parent.width - width
                // The subtitle's baseline, stated rather than anchored, so a
                // layout switch cannot leave a stale anchored y behind.
                y: subtitleText.baselineOffset - figureLabel.baselineOffset
                HoverHandler { id: figureHover }
            }
            DownloadStats {
                id: detailStats
                visible: header._hasDetail
                showPackages: false
                bytesDone: header.detailBytesDone
                bytesTotal: header.detailBytesTotal
                rateText: header.detailRateText
                etaText: header.detailEtaText
                color: header.mutedColor
                fontFamily: header.fontFamily
                pixelSize: header.compactLayout ? header.detailSizeCompact * header._s
                                                : header._subtitleSize
                separatorGap: 5 * header._s
                // Pinned to the edge the eye reads it from: the line's end
                // beside a subtitle, its start when it has the line alone.
                alignment: header.compactLayout ? Qt.AlignLeft : Qt.AlignRight
                // Inside whatever the figure leaves, which is the whole line
                // when there is no figure.
                x: header.compactLayout ? 0
                 : parent.width - header._figureGap - header._detailRightGap - width
                // Centred on the BOX, level with the chevron -- not on the
                // subtitle's baseline, where a figure beside a two-line
                // title/subtitle stack would sit low and read as belonging to
                // the subtitle rather than to the header. Its own line when
                // compact. Explicit rather than anchored, so switching layouts
                // cannot leave a stale anchored y behind; `parent.y` is where
                // the Column put this line, which no figure here feeds.
                y: header.compactLayout ? 0
                 : Math.round(headerBox.height / 2 - textCol.y - parent.y - height / 2)
                // The room it may take before the rate is dropped: THE LINE.
                //
                // The line minus the subtitle's own natural width would have
                // the priority backwards and then break on its own arithmetic.
                // `implicitWidth` is the subtitle's UNELIDED width, so a long
                // subtitle drives that NEGATIVE -- and a negative
                // `availableWidth` is DownloadStats' sentinel for "no
                // constraint given". Exactly when the line is tightest, the
                // figures would therefore switch the rate back ON and take the
                // most room, and the subtitle would be elided to pay for it
                // (truncated when it did not need to be).
                //
                // The figures are the priority, so they size against the line
                // alone and the subtitle takes what is left (below). The two
                // never read each other, which is also what stops one
                // settling against a stale width of the other.
                availableWidth: parent.width - header._figureGap
            }
        }
    }

    // The category's glyph, centred in its slot and on the BOX -- not on the
    // header, whose bottomGap is outside the box and would push the mark low.
    // A Loader, not a hidden Text: an empty header must carry nothing that
    // re-shapes a glyph every time the font size changes.
    Loader {
        id: iconSlot
        active: header.iconGlyph.length > 0
        x: header._textLeft
        y: Math.round((headerBox.height - height) / 2)
        width: header.iconSize * header._s
        height: header.iconSize * header._s
        sourceComponent: Text {
            anchors.centerIn: parent
            text: header.iconGlyph
            color: header.iconColor
            font.family: header.iconFontFamily
            font.pixelSize: header.iconSize * header._s
        }
    }

    // Two strokes meeting in a point, not a glyph: a "⌄" character would
    // rotate about its text box's centre and sweep up and down instead of
    // turning in place. The shell's one chevron (Chevron.qml, which carries
    // the pixel-grid reasoning), placed at a whole-pixel position.
    Chevron {
        id: chevron
        visible: header.expandable
        size: header._chevronSize
        thickness: 2 * header._s
        color: header.mutedColor
        x: Math.round(header.width - header._textRight - width)
        y: Math.round(textCol.y + (textCol.implicitHeight - height) / 2)
        rotation: header._extent * 180
    }

    // Full-width hit area, chevron included. Sits above the labels but is
    // kept a sibling of the box so it never covers list content below.
    MouseArea {
        id: hit
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: textCol.y + textCol.implicitHeight
              + header._boxPadV
        enabled: header.expandable
        cursorShape: header.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
        acceptedButtons: header.rightClickEnabled ? (Qt.LeftButton | Qt.RightButton) : Qt.LeftButton
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                header.rightClicked();
            else
                header.toggled();
        }
        z: 5
    }

    // No hover highlight: the pointing-hand cursor is the affordance.
}
