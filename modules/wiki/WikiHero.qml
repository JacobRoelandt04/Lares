pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "WikiGlyphs.js" as Glyphs

// =============================================================================
// WikiHero.qml -- the picture well at the head of the card.
//
// A CARVED well (16:9 of the card's inner width, on whole pixels) holding the
// carousel. What is drawn, bottom to top:
//
//   floor      the well's fill (Theme.listBox)
//   carousel   the pictures (WikiCarousel), clipped to the well's rectangle: a
//              photograph, or the article's VEIL when it has none (WikiVeil: a
//              slow pattern on the floor, the subject's logo carved on it when
//              there is one)
//   (nothing is laid over the picture's foot: the buttons' own drop shadows
//   carry their contrast on any picture)
//   corners    four pieces of the GROUND between the well's rounded corners
//              and its square clip: a picture slides out through straight
//              edges, and a rectangle cannot round
//   rim        the well's carve, drawn OVER the picture: a translucent
//              ShadowBox (transparent fill and ground), so the inset shadow
//              sinks a photograph into the surface the way it sinks a logo
//   controls   the band's buttons -- [more][less][knew] left, [save][next]
//              right, RAISED, each with a tip -- the carousel dots between them
//              (faint at rest behind a small pill, clickable), and the back
//              chip (WikiTrail) at the top-left while there is a trail
//
// THE POINTER. One HoverHandler on this item, an ANCESTOR of everything that
// takes hover: it is hovered alongside a button's own MouseArea (a hover-only
// MouseArea on an overlay would take the hover of what lies under it). A click
// on the picture steps the carousel; the buttons and the dots sit above the
// click area and take theirs. The picture's credit is a tip that comes after
// `creditDelayMs`, near the pointer, and gives way to the buttons' own tips.
//
// A click on more / less / knew is a CHOICE the service keeps for the card (it counts at the
// next daily turnover, until then it is reversible): the pressed button stands in the accent (the
// shell's selected look, eased), pressing it again undoes it, more and less switch each other.
// The look reads the service's `choiceOf`, so it is the same after the card is closed and
// opened again. Save holds the accent once the note has been written, and its tip then names the
// note (or the failure).
// =============================================================================
Item {
    id: root

    objectName: "wikiHero"
    property var service: null
    property string tab: "discover"
    property var card: null
    property WikiStyle style: WikiStyle {}
    property Item overlayItem: null
    property real radius: 14
    property string fontFamily: "Inter"
    property int autoAdvanceMs: 7000
    property int slideMs: 260
    // The host holds the auto-advance (the secondary is moving, the popup is
    // hidden, the theme is crossfading); the hover holds it as well.
    property bool holdCarousel: false
    // The card's pictures, buttons and chip take part only when there is a card
    // and it is not being replaced.
    property bool live: true
    // A veil may move: the host says false while nobody is there to see it (the shell idle or locked).
    property bool veilRunning: true
    // The presence of the pictures and controls (the host eases it 0 -> 1).
    property real shownF: 1
    // The back chip.
    property bool canBack: false
    property string parentTitle: ""

    readonly property bool hovered: hover.hovered && root.live
    readonly property alias carousel: carouselView
    readonly property bool _hasCard: root.card !== null && root.card !== undefined
    readonly property string _id: root._hasCard ? root.card.id : ""
    readonly property bool _photo: carouselView.current !== null && carouselView.current.kind === "photo"
    // The family's hue, for the veil's deepest shade (a token the card names; resolved here, never carried in a model).
    readonly property color _hue: {
        const k = root._hasCard ? root.card.hueToken : "";
        const c = k ? Theme[k] : undefined;
        return c !== undefined ? c : Theme.shadowDeep;
    }

    // ---- what the reader has chosen for the card on show (the service keeps it) -----------------
    readonly property var _choice: root._readChoice(root.service, root.tab, root._id)
    function _readChoice(service, tab, id) {
        if (service && service.choiceOf && id.length > 0)
            return service.choiceOf(tab, id);
        return { more: false, less: false, knew: false };
    }
    property string _saveState: ""
    property string _saveNote: ""
    on_IdChanged: {
        root._saveState = "";
        root._saveNote = "";
    }
    function _tell(kind) {
        if (!root.service || !root._hasCard)
            return;
        if (kind === "more")
            root.service.more(root.tab, root._id);
        else if (kind === "less")
            root.service.less(root.tab, root._id);
        else
            root.service.knew(root.tab, root._id);
    }
    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onNoteSaved(tab, id, ok, keyOrError) {
            if (tab !== root.tab || id !== root._id)
                return;
            root._saveState = ok ? "saved" : "failed";
            root._saveNote = keyOrError || "";
        }
    }

    // ---- the well ----------------------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        anchors.margins: 1
        radius: Math.max(0, root.radius - 1)
        color: Theme.listBox
    }

    WikiCarousel {
        id: carouselView
        anchors.fill: parent
        opacity: root.shownF
        images: root._hasCard ? root.card.images : []
        style: root.style
        autoAdvanceMs: root.autoAdvanceMs
        slideMs: root.slideMs
        paused: root.holdCarousel || root.hovered
        veilKey: root._id
        veilHue: root._hue
        veilRunning: root.veilRunning && root.live
    }

    MouseArea {
        id: stepArea
        objectName: "wikiStepArea"
        anchors.fill: parent
        enabled: root.live && carouselView.count > 1
        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: carouselView.step(1)
    }

    // ---- the button band's presence (ONE fraction: buttons, dots) ---------------------------------
    property real bandF: root.hovered ? 1 : 0
    Behavior on bandF {
        NumberAnimation {
            duration: root.style.bandFadeMs
            easing.type: Easing.OutCubic
        }
    }
    // ---- the corners ---------------------------------------------------------------------------
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        // The four corner pieces reach one pixel outside the well so no seam is
        // left where the arc meets the straight edge.
        readonly property real r: root.radius
        readonly property real e: 1

        ShapePath {
            fillColor: Theme.surface
            strokeColor: "transparent"
            strokeWidth: -1
            startX: -1
            startY: -1
            PathLine { x: root.radius; y: -1 }
            PathLine { x: root.radius; y: 0 }
            PathArc { x: 0; y: root.radius; radiusX: root.radius; radiusY: root.radius; direction: PathArc.Counterclockwise }
            PathLine { x: -1; y: root.radius }
            PathLine { x: -1; y: -1 }
        }
        ShapePath {
            fillColor: Theme.surface
            strokeColor: "transparent"
            strokeWidth: -1
            startX: root.width + 1
            startY: -1
            PathLine { x: root.width + 1; y: root.radius }
            PathLine { x: root.width; y: root.radius }
            PathArc { x: root.width - root.radius; y: 0; radiusX: root.radius; radiusY: root.radius; direction: PathArc.Counterclockwise }
            PathLine { x: root.width - root.radius; y: -1 }
            PathLine { x: root.width + 1; y: -1 }
        }
        ShapePath {
            fillColor: Theme.surface
            strokeColor: "transparent"
            strokeWidth: -1
            startX: root.width + 1
            startY: root.height + 1
            PathLine { x: root.width - root.radius; y: root.height + 1 }
            PathLine { x: root.width - root.radius; y: root.height }
            PathArc { x: root.width; y: root.height - root.radius; radiusX: root.radius; radiusY: root.radius; direction: PathArc.Counterclockwise }
            PathLine { x: root.width + 1; y: root.height - root.radius }
            PathLine { x: root.width + 1; y: root.height + 1 }
        }
        ShapePath {
            fillColor: Theme.surface
            strokeColor: "transparent"
            strokeWidth: -1
            startX: -1
            startY: root.height + 1
            PathLine { x: -1; y: root.height - root.radius }
            PathLine { x: 0; y: root.height - root.radius }
            PathArc { x: root.radius; y: root.height; radiusX: root.radius; radiusY: root.radius; direction: PathArc.Counterclockwise }
            PathLine { x: root.radius; y: root.height + 1 }
            PathLine { x: -1; y: root.height + 1 }
        }
    }

    // ---- the rim: the carve, over the picture -----------------------------------------------------
    ShadowBox {
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: "transparent"
        backgroundColor: "transparent"
        bevelColor: Theme.bevel
        // Over a picture the carve needs a real shade; over the bare floor it is
        // the container's own (a light shadow on a light photograph is invisible).
        shadowColor: root._photo ? Theme.shadowDeep : Theme.border
        bevelWidth: root.style.wellBevel
        shadowWidth: root.style.wellShadow
        shadowFalloff: root.style.wellFalloff
        shadowEdgeAlpha: root.style.wellEdgeAlpha
    }

    // ---- the buttons ---------------------------------------------------------------------------------
    component BandButton: RaisedButton {
        id: vb

        required property WikiStyle st
        property string glyph: ""
        property string tip: ""
        property string tipFont: "Inter"
        property Item overlay: null
        // The choice this button carries is made for the card on show.
        property bool latched: false
        readonly property bool hovered: buttonHover.hovered

        property real latchF: vb.latched ? 1 : 0
        Behavior on latchF {
            NumberAnimation {
                duration: vb.st.latchMs
                easing.type: Easing.OutCubic
            }
        }

        width: vb.st.buttonWidth
        implicitHeight: vb.st.buttonHeight
        minWidth: 0
        horizontalPadding: 0
        text: vb.glyph
        fontFamily: Glyphs.FONT_FAMILY
        fontPixelSize: vb.st.buttonGlyphSize
        bold: false
        radius: vb.st.buttonRadius
        shadowWidth: vb.st.buttonShadow
        bevelWidth: vb.st.buttonBevel
        shadowToAlpha: true
        surfaceColor: Theme.listBox
        shadowColor: Theme.buttonShadow
        // The chosen look is the shell's selected one (accent plateau, light text), eased on its own fraction.
        plateauColor: Mix.c(Theme.buttonPlateau, Theme.accent, vb.latchF)
        plateauHoverColor: Mix.c(Theme.buttonPlateauHover, Theme.accentHover, vb.latchF)
        bevelColor: Mix.c(Theme.buttonBevel, Theme.accentBevel, vb.latchF)
        textColor: Mix.c(Theme.textPrimary, Theme.textOnAccent, vb.latchF)

        HoverHandler {
            id: buttonHover
        }
        HoverTip {
            anchorItem: vb
            overlayItem: vb.overlay
            show: vb.hovered
            delayMs: vb.st.tipDelayMs
            fillOpacity: vb.st.pictureTipOpacity
            fontFamily: vb.tipFont
            text: vb.st.wrapTip(vb.tip)
        }
    }

    Item {
        id: controls
        anchors.fill: parent
        visible: root.bandF > 0
        opacity: root.bandF * root.shownF

        Row {
            id: leftRow
            x: root.style.buttonMargin
            y: root.height - root.style.buttonMargin - root.style.buttonHeight
            spacing: root.style.buttonGap

            BandButton {
                objectName: "wikiBtnMore"
                st: root.style
                overlay: root.overlayItem
                tipFont: root.fontFamily
                glyph: Glyphs.markChar("more")
                tip: "More like this"
                latched: root._choice.more
                onClicked: root._tell("more")
            }
            BandButton {
                objectName: "wikiBtnLess"
                st: root.style
                overlay: root.overlayItem
                tipFont: root.fontFamily
                glyph: Glyphs.markChar("less")
                tip: "Less like this"
                latched: root._choice.less
                onClicked: root._tell("less")
            }
            BandButton {
                objectName: "wikiBtnKnew"
                st: root.style
                overlay: root.overlayItem
                tipFont: root.fontFamily
                glyph: Glyphs.markChar("knew")
                tip: "I already know this — no penalty"
                latched: root._choice.knew
                onClicked: root._tell("knew")
            }
        }
        Row {
            id: rightRow
            x: root.width - root.style.buttonMargin - width
            y: leftRow.y
            spacing: root.style.buttonGap

            BandButton {
                objectName: "wikiBtnSave"
                st: root.style
                overlay: root.overlayItem
                tipFont: root.fontFamily
                glyph: Glyphs.markChar("save")
                tip: root._saveState === "saved" ? "Saved: " + root._saveNote
                     : root._saveState === "failed" ? "Could not save: " + root._saveNote : "Save to a note"
                latched: root._saveState === "saved"
                onClicked: {
                    if (root.service && root._hasCard)
                        root.service.saveToNote(root.tab, root._id);
                }
            }
            BandButton {
                objectName: "wikiBtnNext"
                st: root.style
                overlay: root.overlayItem
                tipFont: root.fontFamily
                glyph: Glyphs.markChar("next")
                tip: "Next article"
                onClicked: {
                    if (root.service)
                        root.service.next(root.tab);
                }
            }
        }
    }

    // ---- the dots ---------------------------------------------------------------------------------------
    Item {
        id: dots
        readonly property int n: carouselView.count
        readonly property real span: dots.n > 1 ? (dots.n - 1) * root.style.dotPitch + root.style.dotSize : 0
        visible: dots.n > 1 && root.live
        opacity: root.shownF * (root.style.dotRestOpacity + (1 - root.style.dotRestOpacity) * root.bandF)
        width: dots.span
        height: root.style.dotSize
        x: Math.round((root.width - width) / 2)
        y: root.height - root.style.buttonMargin - Math.round((root.style.buttonHeight + root.style.dotSize) / 2)

        // The faint pill that lets them read on any picture; the band's hover takes over.
        Rectangle {
            x: -root.style.dotPillPad
            y: -root.style.dotPillPad + (root.style.dotSize / 2 - root.style.dotSize / 2)
            width: dots.span + 2 * root.style.dotPillPad
            height: root.style.dotSize + 2 * root.style.dotPillPad
            radius: height / 2
            opacity: (1 - root.bandF)
            color: Qt.rgba(Theme.surface.r, Theme.surface.g, Theme.surface.b, root.style.dotPillAlpha)
        }
        Repeater {
            model: dots.n

            Item {
                id: dot

                required property int index

                readonly property bool active: dot.index === carouselView.currentIndex
                property real activeF: dot.active ? 1 : 0
                Behavior on activeF {
                    NumberAnimation {
                        duration: root.style.latchMs
                        easing.type: Easing.OutCubic
                    }
                }
                x: dot.index * root.style.dotPitch
                width: root.style.dotSize
                height: root.style.dotSize

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Mix.c(Theme.textMuted, Theme.accent, dot.activeF)
                }
                MouseArea {
                    objectName: "wikiDot" + dot.index
                    x: -(root.style.dotPitch - root.style.dotSize) / 2
                    y: -(root.style.dotHit - root.style.dotSize) / 2
                    width: root.style.dotPitch
                    height: root.style.dotHit
                    cursorShape: Qt.PointingHandCursor
                    onClicked: carouselView.goTo(dot.index, dot.index > carouselView.currentIndex ? 1 : -1)
                }
            }
        }
    }

    // ---- the way back --------------------------------------------------------------------------------------
    WikiTrail {
        id: trail
        objectName: "wikiTrail"
        x: root.style.chipMargin
        y: root.style.chipMargin
        service: root.service
        tab: root.tab
        style: root.style
        fontFamily: root.fontFamily
        parentTitle: root.parentTitle
        wanted: root.canBack
        overlayItem: root.overlayItem
    }

    // ---- the pointer and the credit ---------------------------------------------------------------------------
    HoverHandler {
        id: hover
        enabled: root.live
    }
    // A FIXED SPOT (a tip above the cursor would stand at no defined position): the credit's tip opens centred above the top of the button band, on the picture's foot, wherever
    // the pointer is on the picture. The anchor is the band's top edge, full width; the tip centres on it and stands its
    // gap above it.
    Item {
        id: creditAnchor
        x: 0
        y: root.height - root.style.bandHeight
        width: root.width
        height: 1
    }
    // While the pointer is on the button band, or on the chip, the credit stays
    // away: the band's buttons have tips of their own. (The band is arithmetic
    // on the pointer: a hover handler of its own, stacked over the buttons,
    // would take THEIR hover.)
    readonly property bool _onBand: root.bandF > 0 && hover.point.position.y >= root.height - root.style.bandHeight
    HoverTip {
        anchorItem: creditAnchor
        overlayItem: root.overlayItem
        show: root.hovered && !root._onBand && !trail.hovered && carouselView.credit !== ""
        delayMs: root.style.creditDelayMs
        fillOpacity: root.style.pictureTipOpacity
        fontFamily: root.fontFamily
        text: root.style.wrapTip(carouselView.credit)
    }
}
