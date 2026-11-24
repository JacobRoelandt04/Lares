pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/theme"
import "data/WikiCardModel.js" as Card
import "WikiGlyphs.js" as Glyphs

// =============================================================================
// WikiCompactCard.qml -- the wiki's article as a small carved card: the clock
// popup's tear-off, the notification manager's empty state and the lock
// screen's row. One drop-in; the host sets the WIDTH, the variant fixes the
// height (docs/contracts/wiki.md, "WikiCompactCard").
//
// Every variant spends ALL its room on the article's own words: the thumb sits
// top-left, a title row stands at the top edge, and the intro paragraph (plain,
// one paragraph, elided at the end of its lines) fills what is left.
//
//   tearoff   194 wide (the calendar panel's inner width). Title row: the
//             category glyph, then the title, beside the thumb. The intro runs
//             on under it beside the thumb (4 lines of 100 px) and then BELOW
//             the thumb at full width (1 line of 174 px): ONE Text whose
//             `onLineLaidOut` narrows the lines that stand beside the thumb.
//   wide      396 wide (the notification manager's inner width). Title left,
//             glyph at the right end of the row, 3 intro lines under it.
//   lock      440 x 92, thumb 72. As `wide` with 4 lines, and NOT interactive
//             (a public screen): no hover, no click, no tip, no why-text, no
//             installed badge. Discover only -- `tab` is ignored.
//
// The On-this-day line is not shown beside an intro (the intro takes its
// room). A card with NO intro text shows its On-this-day line in the body
// instead, and that body is its link (`onThisDayActivated`; Ctrl follows).
//
// HEIGHTS ARE FIXED PER VARIANT: tearoff = 2 padding + thumb 64 + 22 (106),
// wide = thumb 64 + 2 padding (84), lock = thumb 72 + 2 padding (92). Text is
// clamped to a line count and elided, never article-dependent; lines are a
// fixed 13 px (FixedHeight) so the count and the foot do not depend on the face.
//
// STATES. Loading is a skeleton at the SAME geometry (thumb block, the title
// row's bar, one bar per body line) that breathes only while `active`; empty
// is a quiet "No articles yet" at full size, or nothing at all with
// `collapseWhenEmpty` (implicitHeight 0 and the face hidden). A card on show is
// never blanked by a follow in progress: `loading` means the tab is loading AND
// there is nothing to show. A landing card fades its face in over 160 ms (one
// fraction, gated on `active`; the arrival at creation and a card replacing a
// card are instant -- a text swap is).
//
// NOTHING TICKS AT REST. No timer but the seen counter, which runs only while
// `attended` and the card is on screen (1 tick a second, changes nothing you
// can see); the skeleton stops when `active` is false; the fade is a one-shot.
// With no service the card creates nothing (a Loader with no face) and is 0 x 0.
//
// THE CARVE. The fill is the step from Theme.surface to Theme.listBox
// (Mix.sunk) applied to the ground the card stands on: on the popup surface it
// IS the notification card's own fill, on the calendar panel or the lock band
// it is the same step deeper. So `groundColor` is the only colour a host has
// to say: its band's fill (the ShadowBox's `surfaceColor`). The thumb's well,
// its floor and the skeleton bars derive from that fill; the category hue is a
// Theme token resolved here, in the view.
//
// TYPE. Title 12 bold (the notification card's summary: 16 bold is a popup's
// title), the body 11 muted. Whole-pixel positions throughout.
//
// SEEN. While `attended` and the card is showing, `service.shown(tab, id,
// cumulativeMs)` is called once a second (the count restarts with the card): a
// glance, which never makes an article seen -- only reading it in the wiki
// detail does (WikiService "SEEN").
// =============================================================================
Item {
    id: root

    property var service: null
    property string tab: "discover"
    // "tearoff" | "wide" | "lock"
    property string variant: "tearoff"
    // The fill of the band this stands on.
    property color groundColor: Theme.listBox
    property string fontFamily: "Inter"
    // Device px per px (a magnified stage): the thumb is decoded at it.
    property real renderScale: 1
    property real padding: 10
    property real radius: 12
    // Gates the only motion: the presence fade and the skeleton's breath.
    property bool active: true
    // Reports that it is on screen (the host: unlocked, awake, on screen).
    property bool attended: root.active
    property bool collapseWhenEmpty: false

    signal activated(var card)
    signal onThisDayActivated(bool follow)

    readonly property var card: root.service ? root.service.card(root._tab) : null
    readonly property bool loading: !!root.service && !root.card && root.service.loading(root._tab)
    readonly property bool empty: !!root.service && !root.card && !root.loading

    // ---- geometry ---------------------------------------------------------------
    readonly property string _v: root.variant
    readonly property bool _lock: root._v === "lock"
    readonly property bool _stacked: root._v === "tearoff"
    readonly property string _tab: root._lock ? "discover" : root.tab
    readonly property real _thumb: root._lock ? 72 : 64
    // Body lines of the variant: beside the thumb (+ below it, tear-off).
    readonly property int _lines: root._stacked ? 5 : (root._lock ? 4 : 3)
    readonly property real _lineH: 13
    readonly property bool _collapsed: root.collapseWhenEmpty && root.empty

    implicitWidth: !root.service ? 0 : (root._stacked ? 194 : (root._lock ? 440 : 396))
    implicitHeight: !root.service || root._collapsed ? 0
        : Math.round(root.padding) * 2 + root._thumb + (root._stacked ? 22 : 0)

    // ---- presence: ONE fraction, 0 = no card, 1 = the card ------------------------------
    readonly property bool _shown: !!root.card
    property bool _live: false
    property real _presence: root._shown ? 1 : 0
    Behavior on _presence {
        // A card that is there at creation is there at once; a card replacing
        // a card never changes `_shown`, so it is a text swap.
        enabled: root._live && root.active
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    // What stands behind a landing card and fades out under it.
    property bool _skelBehind: false
    onLoadingChanged: if (root.loading) root._skelBehind = true
    onEmptyChanged: if (root.empty) root._skelBehind = false
    Component.onCompleted: {
        root._skelBehind = root.loading;
        Qt.callLater(function () {
            root._live = true;
        });
    }

    // ---- what the line says ------------------------------------------------------------------
    readonly property string _otdText: root.service && root._tab === "discover" ? Card.otdLine(root.service.daily, 220) : ""
    readonly property bool _otdOn: root._otdText !== ""
    readonly property bool _interactive: !root._lock
    // The words of the body: the intro as one paragraph, or -- with none -- the
    // On-this-day line (which is then the body's link).
    readonly property string _introText: root.card ? String(root.card.intro || "").replace(/\s+/g, " ").trim().slice(0, 600) : ""
    readonly property bool _bodyIsOtd: root._introText === "" && root._otdOn
    readonly property string _bodyText: root._bodyIsOtd ? root._otdText : root._introText

    // ---- seen ----------------------------------------------------------------------------------------
    readonly property string _cardId: root.card ? root.card.id : ""
    property int _seenMs: 0
    on_CardIdChanged: root._seenMs = 0
    readonly property bool _counting: !!root.service && root.attended && root.visible && root._presence >= 1
        && root.width > 0 && root.opacity > 0.99 && !!root.card
    Timer {
        interval: 1000
        repeat: true
        running: root._counting
        onTriggered: {
            if (!root.card) return;
            root._seenMs += 1000;
            root.service.shown(root._tab, root.card.id, root._seenMs);
        }
    }

    Loader {
        anchors.fill: parent
        active: !!root.service
        visible: !root._collapsed
        sourceComponent: faceComp
    }

    Component {
        id: faceComp

        Item {
            id: face
            anchors.fill: parent

            // ---- colours: every one a Theme token, or a mix of two -----------------------
            readonly property color fill: Mix.sunk(Theme.surface, Theme.listBox, Theme.shadowDeep, root.groundColor)
            readonly property color fillLit: Mix.c(face.fill, Theme.bevel, 0.5)
            readonly property color well: Mix.sunk(Theme.surface, Theme.listBox, Theme.shadowDeep, face.fill)
            readonly property color wellFloor: Mix.c(face.well, Theme.shadowDeep, 0.25)
            readonly property color skel: Mix.c(face.fill, Theme.bevel, 0.6)
            readonly property color hue: {
                const k = root.card ? root.card.hueToken : "";
                return k && Theme[k] !== undefined ? Theme[k] : Theme.textMuted;
            }

            // ---- geometry -------------------------------------------------------------------------
            readonly property real w: root.width
            readonly property real h: root.height
            readonly property real p: Math.round(root.padding)
            readonly property real th: root._thumb
            readonly property real rowH: 16         // the title row
            readonly property real lineH: root._lineH
            readonly property real glyphBox: 14
            // The skeleton breathes only while the host says so, and holds still
            // under a theme crossfade (a still picture of the frame before, faded
            // out over the new palette: anything that keeps moving is a second copy).
            readonly property bool breathe: root.active && !Theme.crossfading
            readonly property real textX: face.p + face.th + face.p
            readonly property real textW: Math.max(0, face.w - face.textX - face.p)
            // Tear-off: glyph, then the title, at the thumb's top; the others: the
            // title from the text column's left, the glyph at the row's right end.
            readonly property real glyphX: root._stacked ? face.textX : face.w - face.p - face.glyphBox
            readonly property real glyphY: face.p + Math.round((face.rowH - face.glyphBox) / 2)
            readonly property real titleX: root._stacked ? face.textX + face.glyphBox + 6 : face.textX
            readonly property real titleW: Math.max(0, root._stacked ? face.w - face.p - face.titleX
                                                                     : face.textW - face.glyphBox - 12)
            // The body: from under the title row. The tear-off's Text spans the
            // card (its lines below the thumb run full width); the others stand
            // in the text column.
            readonly property real bodyY: face.p + face.rowH + 4
            readonly property real bodyX: root._stacked ? face.p : face.textX
            readonly property real bodyW: root._stacked ? face.w - 2 * face.p : face.textW
            // A line whose top is above this stands beside the thumb (tear-off).
            readonly property real besideH: root._stacked ? face.p + face.th - face.bodyY : 1e6
            readonly property real narrowX: face.textX - face.bodyX
            readonly property real narrowW: face.w - face.p - face.textX
            function lineBeside(i: int): bool {
                return i * face.lineH < face.besideH;
            }

            // Where a press is the body's link (an arithmetic hit-test: one
            // pointer area owns the card, nothing is stacked over the link).
            function inOtd(px: real, py: real): bool {
                if (!root._bodyIsOtd) return false;
                if (py < face.bodyY - 2 || py > face.bodyY + root._lines * face.lineH + 2) return false;
                return root._stacked || px >= face.textX;
            }

            // ---- hover: two eased fractions, the card's and the line's ---------------------------
            readonly property bool overOtd: hit.containsMouse && face.inOtd(hit.mouseX, hit.mouseY)
            property real hCard: hit.containsMouse && !face.overOtd ? 1 : 0
            property real hOtd: face.overOtd ? 1 : 0
            Behavior on hCard {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
            Behavior on hOtd {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }

            // ---- the carved card ---------------------------------------------------------------------
            ShadowBox {
                anchors.fill: parent
                baseRadius: root.radius
                surfaceColor: root.groundColor
                backgroundColor: Mix.c(face.fill, face.fillLit, face.hCard)
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                bevelWidth: 1
                shadowWidth: 3
            }

            // ---- the face -------------------------------------------------------------------------------
            Item {
                id: content
                anchors.fill: parent
                opacity: root._presence
                visible: root._presence > 0

                // The thumb: the photo, the subject's logo as a carved relief, or -- an
                // article with neither -- its veil, STILL (the picture at its start: a
                // thumbnail runs no clock), in the same carved square.
                Item {
                    id: thumb
                    x: face.p
                    y: face.p
                    width: face.th
                    height: face.th
                    readonly property var im: root.card && root.card.images.length > 0 ? root.card.images[0] : null
                    readonly property bool wantsPhoto: !!thumb.im && thumb.im.kind === "photo" && thumb.im.thumbUrl !== ""
                    readonly property bool photo: thumb.wantsPhoto && photoImage.status !== Image.Error
                    readonly property bool relief: !thumb.photo && !!thumb.im && thumb.im.kind === "relief" && thumb.im.thumbUrl !== ""
                    readonly property bool veiled: !thumb.photo && !thumb.relief
                    readonly property real decode: Math.round(Math.max(192, face.th * 2 * root.renderScale))

                    RoundedImage {
                        id: photoImage
                        anchors.fill: parent
                        visible: thumb.photo
                        radius: 8
                        source: thumb.wantsPhoto ? thumb.im.thumbUrl : ""
                        sourceSize: Qt.size(thumb.decode, thumb.decode)
                    }
                    Loader {
                        anchors.fill: parent
                        anchors.margins: 1
                        active: thumb.veiled && !!root.card
                        sourceComponent: WikiVeil {
                            id: thumbVeil
                            seedKey: root._cardId
                            hue: face.hue
                            groundColor: face.well
                            running: false
                            zoom: thumbVeil.style.thumbZoom
                            cornerRadius: 7
                        }
                    }
                    // The carve: a well with its own floor under a logo, the rim alone over a veil
                    // (a ShadowBox draws its inset under its children, so the veil lies under the box).
                    ShadowBox {
                        anchors.fill: parent
                        visible: !thumb.photo
                        baseRadius: 8
                        surfaceColor: thumb.veiled ? "transparent" : face.fill
                        backgroundColor: thumb.veiled ? "transparent" : face.well
                        bevelColor: Theme.bevel
                        shadowColor: Theme.border
                        bevelWidth: 1
                        shadowWidth: 3
                    }
                    LogoRelief {
                        visible: thumb.relief
                        source: thumb.relief ? thumb.im.thumbUrl : ""
                        logoSize: Math.round(face.th * 0.74)
                        x: Math.round((face.th - logoSize) / 2)
                        y: Math.round((face.th - logoSize) / 2)
                        surfaceColor: face.well
                        bodyColor: face.wellFloor
                    }
                }

                Text {
                    id: title
                    x: face.titleX
                    y: face.p
                    width: face.titleW
                    height: face.rowH
                    text: root.card ? root.card.title : ""
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: 12
                    font.bold: true
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }

                Text {
                    x: face.glyphX
                    y: face.glyphY
                    width: face.glyphBox
                    height: face.glyphBox
                    text: root.card ? root.card.glyph : ""
                    color: face.hue
                    font.family: Glyphs.FONT_FAMILY
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                // The body: one Text; the lines that stand beside the thumb are
                // narrowed and moved as they are laid out.
                Text {
                    id: body
                    x: face.bodyX
                    y: face.bodyY
                    width: face.bodyW
                    height: root._lines * face.lineH
                    text: root._bodyText
                    color: Mix.c(Theme.textMuted, Theme.accent, face.hOtd)
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    lineHeightMode: Text.FixedHeight
                    lineHeight: face.lineH
                    maximumLineCount: root._lines
                    elide: Text.ElideRight
                    onLineLaidOut: line => {
                        if (root._stacked && face.lineBeside(line.number)) {
                            line.x = face.narrowX;
                            line.width = face.narrowW;
                        }
                    }
                    readonly property real _geo: face.narrowX + face.narrowW + face.besideH
                    on_GeoChanged: body.forceLayout()
                }
            }

            // ---- the skeleton: the same geometry, breathing only while active ------------------------
            Item {
                id: skeleton
                anchors.fill: parent
                readonly property real f: root._skelBehind ? 1 - root._presence : 0
                opacity: skeleton.f
                visible: skeleton.f > 0

                SkeletonBar {
                    x: face.p
                    y: face.p
                    width: face.th
                    height: face.th
                    radius: 8
                    barColor: face.skel
                    groundColor: face.fill
                    pulse: face.breathe
                    pulseTravel: 2
                }
                SkeletonBar {
                    x: face.titleX
                    y: face.p + Math.round((face.rowH - height) / 2)
                    width: Math.round(face.titleW * 0.7)
                    height: 9
                    barColor: face.skel
                    groundColor: face.fill
                    pulse: face.breathe
                    pulseTravel: 3
                    pulsePhaseMs: 120
                }
                SkeletonBar {
                    x: face.glyphX
                    y: face.glyphY + Math.round((face.glyphBox - height) / 2)
                    width: face.glyphBox
                    height: 9
                    barColor: face.skel
                    groundColor: face.fill
                    pulse: face.breathe
                    pulseTravel: 2
                    pulsePhaseMs: 360
                }
                // One bar per body line, at the line's own x and width; the last is short.
                Repeater {
                    model: root._lines
                    SkeletonBar {
                        id: bar
                        required property int index
                        readonly property bool beside: !root._stacked || face.lineBeside(bar.index)
                        readonly property real full: bar.beside ? (root._stacked ? face.narrowW : face.bodyW) : face.bodyW
                        x: bar.beside ? face.textX : face.p
                        y: face.bodyY + bar.index * face.lineH + Math.round((face.lineH - height) / 2)
                        width: bar.index === root._lines - 1 ? Math.round(bar.full * 0.6) : bar.full
                        height: 8
                        barColor: face.skel
                        groundColor: face.fill
                        pulse: face.breathe
                        pulseTravel: 3
                        pulsePhaseMs: 240 + bar.index * 60
                    }
                }
            }

            // ---- nothing to show -------------------------------------------------------------------
            Text {
                readonly property real f: root._skelBehind ? 0 : 1 - root._presence
                anchors.fill: parent
                opacity: f
                visible: f > 0 && root.empty
                text: "No articles yet"   // the popup's own words (WikiPopup, WikiIntro)
                color: Theme.textFaint
                font.family: root.fontFamily
                font.pixelSize: 11
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }

            // ---- the pointer ---------------------------------------------------------------------------
            // One area owns the card; the line is told apart by arithmetic
            // (a hover area stacked over a link would take its hover and its
            // hand cursor -- CLAUDE.md). The lock row has none.
            MouseArea {
                id: hit
                anchors.fill: parent
                enabled: root._interactive && root._shown
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    if (!root.card) return;
                    if (face.inOtd(mouse.x, mouse.y))
                        root.onThisDayActivated((mouse.modifiers & Qt.ControlModifier) !== 0);
                    else
                        root.activated(root.card);
                }
            }
        }
    }
}
