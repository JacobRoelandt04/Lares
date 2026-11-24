pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import ".."
import "../../common/components/RelTime.js" as RelTime
import "NotifyGlyphs.js" as G

// =============================================================================
// NotificationCard.qml -- ONE notification, the same face in a toast and in
// the manager (the host wraps it in a SwipeVerbCard with its own verbs).
//
//   [icon]  Summary ..........................  App · 3 min  (pin)
//           Body, three lines at most, links clickable
//           [===== progress rail =====]
//           <a source's rich body, when a shell source hands one>
//           [ Reply ] [ Action ] [ Action ] [ ... ]
//           [ reply field, while it is open ]
//   [ picture band, the full width, for a large image: its own aspect ratio, the height between the style's
//     the style's pictureMinHeight and pictureMaxHeight, a picture outside them cropped at its middle ]
//
// (When the summary and "App · 3 min" do not fit one line, the summary keeps the
// whole line and "App · 3 min" goes on a line of its own under it.)
//
// THE CARD IS CARVED (a container), and its group's colour lives in its inset
// shadow: at rest a sliver at the left of the inset -- the stripe's job,
// ListSectionHeader's idiom -- and on a toast that is counting down the
// colour FILLS the inset and drains AWAY as the time runs out (`countdown`
// 1 -> 0): the sliver is the resting state's, so it is withdrawn while the
// clock runs and the drain reaches nothing at the deadline (with the
// sliver kept, the colour would stop at it for the last ~6 % of the time and the
// toast leave while its mark stood still). One coloured mark carries both
// facts, never two. The shade's look is ShadowBox's own defaults (the system
// update header's); the card only states its colour and whether it rests.
//
// A CARD WITH NO COUNTDOWN CAN BE SHADED ACROSS (`shadeAll`, 0 -> 1): a sticky
// critical toast has no clock to carry its colour, so the host takes the
// resting sliver out to the whole carve -- the countdown's own full-width
// shade, held -- instead of leaving the one mark a sticky note has (a critical
// has no decay timer, so it can be fully shaded red instead of only the left
// side). It is the same tint on the same sweep, so
// there is no second mark: the card only forwards the fraction, and the host
// eases it (ONE clock, no Behavior here).
//
// THE SUMMARY IS THE LINE'S FIRST CLAIM (the title must not be truncated by the
// source text: the network "Connection Established" notification from
// NetworkManager is the example). The
// summary and "App · 3 min" size themselves from each other -- the summary
// takes the line minus the source, the source is as wide as its text -- so one
// of them has to come first, and it is the summary. It is measured at its
// natural width (a TextMetrics, never the Text read back into its own width);
// if that plus the gap plus the source's own width fits the line, they share it
// (the common card is untouched). If not, the source steps
// down to a line of its own under the summary -- "stacked", left-aligned like a
// byline, the pin and the time's tip going with it -- and the summary has the
// whole line, wrapping to a second line before it is ever elided. Whether it is
// stacked is a pure function of three measures (the summary's, the source's, the
// column's), so there is nothing for it to loop on.
//
// THE ICON COLUMN is EntryIcon's, and only when there is something to show:
// with no image, no icon and no glyph the text starts at the left padding.
//
// THE LOOK is the module's one NotificationStyle (`style`): every size, gap
// and carve below is read from it, and each default is the value drawn when no
// style is given. The first block of look properties can be set one by one; a
// host that hands `style` needs nothing else.
//
// THE MANAGER'S CHEVRON sits at the lower right, in the padding under the text
// column. A progress rail on the column's last line would run under it (a
// bundle's chevron over the end of KDE Connect's "Receiving file" rail), so that
// rail stops `metaGap` short of it -- as the summary stops
// short of its "App · 3 min".
//
// Everything the card shows is the record `d` (NotificationStore's plain
// object, CONTRACT "Record"); what only lives at runtime -- a shell source's
// rich body -- comes from `service.richBodyOf(uid)`. Buttons, links and the
// picture act through the service (invoke / reply / activate), so the card
// never touches a live Notification. A stale record (loaded after a restart)
// or one its app closed while it was pinned shows its actions disabled.
// =============================================================================
Item {
    id: card

    // ---- data --------------------------------------------------------------
    property var d: null
    property var service: null
    property var clock: null                  // BoundaryClock: `now` + request()
    property Item overlayItem: null           // menus and tips float here

    // ---- look ------------------------------------------------------------------
    property NotificationStyle style: null
    property real cardWidth: 360
    property color groupColor: Theme.accent
    property string fontFamily: card.style ? card.style.fontFamily : "Inter"
    property real padding: card.style ? card.style.cardPadding : 12
    property real radius: card.style ? card.style.cardRadius : 14
    property int iconSize: card.style ? card.style.iconSize : 40
    property real iconGap: card.style ? card.style.iconGap : 10
    // the app's icon on an avatar's corner
    property int badgeSize: card.style ? card.style.badgeSize : 18
    // a shell glyph's size, share of iconSize
    property real glyphScale: card.style ? card.style.glyphScale : 1.0
    // device px per px: icons are rendered at it
    property real renderScale: card.style ? card.style.renderScale : 1
    // 0 = no limit
    property int maxLines: card.style ? card.style.maxLines : 3
    property bool expanded: false             // the manager's chevron
    property real countdown: -1               // 0..1 time left, -1 none
    // 0..1: the resting mark taken out across the carve while there is no
    // countdown (see the header); ignored while counting.
    property real shadeAll: 0
    // the resting sliver; 0 while counting
    property real idleMarkPx: card.style ? card.style.idleMarkPx : 12
    // the tallest a picture band may be (the style's pictureMaxHeight)
    property real pictureMaxHeight: card.style ? card.style.pictureMaxHeight : 160
    property string footnote: ""              // e.g. a flood's "+4 more from Signal"
    property bool expandable: false           // the manager: a chevron when clipped
    property bool chevronAlways: false        // a bundle's head: the chevron opens the bundle

    signal replyToggled(bool open)
    signal expandToggled()

    readonly property bool truncated: body.truncated
    // The shade's floor as drawn: the idle mark at rest, nothing while counting.
    readonly property real markPx: card.countdown >= 0 ? 0 : card.idleMarkPx
    // Where the text column starts: after the icon, or at the padding.
    readonly property real textX: card.padding + (icon.shown ? card.iconSize + card.iconGap : 0)
    readonly property real _iconH: icon.shown ? card.iconSize : 0
    readonly property bool replyOpen: card._replyOpen
    property bool _replyOpen: false

    readonly property bool _live: !!card.d && !card.d.stale && !card.d.closed
    readonly property var _img: card.d && card.d.image ? card.d.image : null
    readonly property bool _picture: !!card._img && card._img.kind === "picture"
        && (card._img.file !== "" || !card.d.stale)
    readonly property var _rich: card.service && card.d && card.service.richBodyOf
        ? card.service.richBodyOf(card.d.uid) : null

    // A rich body's props are written into the loaded item at load and again when the service's record hands new ones
    // (`update(uid, { bodyProps })`, which moves the rich record's `rev`: the 1-minute sharpening of a stock card), the item itself
    // never rebuilt. A change of any other field of the record writes nothing: the props are the body's, not the record's.
    function _feedRich() {
        const it = richLoader.item;
        if (!it || !card._rich || richLoader.fedRev === card._rich.rev)
            return;
        richLoader.fedRev = card._rich.rev;
        const p = card._rich.props || {};
        for (const k in p)
            if (k in it)
                it[k] = p[k];
        // A body that declares `hostCard` is handed the card it sits
        // in: the auth card arms its keyboard from the WHOLE toast
        // ("hovering the notification toast area"), not its own rows.
        if ("hostCard" in it && it.hostCard !== card)
            it.hostCard = card;
    }
    on_RichChanged: card._feedRich()

    // The style's sizes and gaps (see THE LOOK).
    readonly property NotificationStyle _st: card.style
    readonly property int _summarySize: card._st ? card._st.summarySize : 12
    readonly property int _bodySize: card._st ? card._st.bodySize : 12
    readonly property int _metaSize: card._st ? card._st.metaSize : 11
    readonly property int _footSize: card._st ? card._st.footSize : 11
    readonly property real _lineGap: card._st ? card._st.lineGap : 4
    readonly property real _metaGap: card._st ? card._st.metaGap : 8
    readonly property real _metaItemGap: card._st ? card._st.metaItemGap : 4
    readonly property real _appNameMax: card._st ? card._st.appNameMaxWidth : 110
    readonly property real _progressH: card._st ? card._st.progressHeight : 6
    readonly property real _actionGap: card._st ? card._st.actionGap : 6
    readonly property real _actionRowPadY: card._st ? card._st.actionRowPadY : 2
    readonly property int _maxActions: card._st ? card._st.maxInlineActions : 3
    readonly property real _replyH: card._st ? card._st.replyFieldHeight : 28
    readonly property real _pictureRadius: card._st ? card._st.pictureRadius : 8
    readonly property real _pictureMinHeight: card._st ? card._st.pictureMinHeight : 72
    readonly property real _chevronSize: card._st ? card._st.expandChevronSize : 11
    readonly property real _chevronStroke: card._st ? card._st.expandChevronStroke : 1.5

    implicitWidth: card.cardWidth
    implicitHeight: Math.ceil(card.padding * 2 + Math.max(card._iconH, textCol.implicitHeight)
        + (card._picture && picture.status === Image.Ready ? card.iconGap + picture.height : 0))

    // ---- the carved card ---------------------------------------------------------
    ShadowBox {
        objectName: "notificationCardBox"
        anchors.fill: parent
        baseRadius: card.radius
        backgroundColor: Theme.listBox
        // Transparent ground: the card slides over the swipe well, so its rim
        // must ease to alpha rather than paint the surface colour round it.
        surfaceColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        bevelWidth: card._st ? card._st.cardBevelWidth : 1
        shadowWidth: card._st ? card._st.cardShadowWidth : 3
        shadowProgress: card.countdown >= 0 ? card.countdown : card.shadeAll
        shadowProgressMinPx: card.markPx
        shadowProgressColor: card.groupColor
        // The group colour's shade (NotificationStyle "the group colour in the
        // carve"); never shallower than the card's own carve. Without a style
        // they stay ShadowBox's own defaults, which these defaults are.
        progressIdleWidth: card._st ? Math.max(shadowWidth, card._st.shadeIdleWidth) : Math.max(shadowWidth, 7.5)
        progressActiveWidth: card._st ? Math.max(shadowWidth, card._st.shadeActiveWidth) : Math.max(shadowWidth, 7)
        progressIdleFeatherPx: card._st ? card._st.shadeFeatherPx : 12
        progressActiveFeatherPx: card._st ? card._st.shadeFeatherPx : 12
        progressIdleEdgeAlpha: card._st ? card._st.shadeIdleEdgeAlpha : 0.55
        progressActiveEdgeAlpha: card._st ? card._st.shadeActiveEdgeAlpha : 1.0
        progressIdleFalloff: card._st ? card._st.shadeIdleFalloff : 0.9
        progressActiveFalloff: card._st ? card._st.shadeActiveFalloff : 1.0
        progressBlendEnd: card._st ? card._st.shadeBlendEnd : 0.32
    }

    EntryIcon {
        id: icon
        x: card.padding
        y: card.padding
        size: card.iconSize
        badgeSize: card.badgeSize
        glyphScale: card.glyphScale
        renderScale: card.renderScale
        d: card.d
        service: card.service
    }

    // ---- the text column -------------------------------------------------------
    Column {
        id: textCol
        x: card.textX
        y: card.padding
        width: card.cardWidth - x - card.padding
        spacing: card._lineGap

        // Summary on the left, "App · 3 min" and the pin on the right -- or, when
        // they do not fit one line (THE SUMMARY IS THE LINE'S FIRST CLAIM), the
        // summary on the whole line and "App · 3 min" under it. The time sits
        // in a slot as wide as its widest reading, so a minute ticking over
        // never moves the summary's elision or the choice.
        Item {
            id: head
            objectName: "notificationHead"
            width: textCol.width
            // "App · 3 min" as the line's second claim, from its pieces and never from the row they
            // sit in: the row's width depends on the choice (a source on a line of its own may be as
            // long as the line, one that shares may not), and the choice must not read it. The facts,
            // not `visible` (false under any hidden ancestor); the widths from TextMetrics, never from
            // the Texts that are drawn (a binding that reads a Text's implicit width lays that Text out
            // early -- the pin's, hidden until the record is pinned -- and the pin of a flying clone
            // came up in grey antialiasing against the card it lands as, ARM `readtexts`).
            readonly property bool hasApp: meta._app !== ""
            readonly property bool hasPin: !!card.d && card.d.pinned
            readonly property real fixedW: (head.hasApp ? dotFit.advanceWidth : 0) + Math.ceil(timeSlot.advanceWidth) + (head.hasPin ? pinFit.advanceWidth : 0)
            readonly property real gapsW: card._metaItemGap * ((head.hasApp ? 2 : 0) + (head.hasPin ? 1 : 0))
            // ... as it stands on a SHARED line: the source capped at appNameMaxWidth.
            readonly property real sharedW: (head.hasApp ? Math.min(appFit.advanceWidth, card._appNameMax) : 0) + head.fixedW + head.gapsW
            // The summary at its natural width (2 px of slack for the layout's rounding), the gap and
            // the source's shared width, against the line.
            readonly property bool stacked: Math.ceil(summaryFit.advanceWidth) + 2 + card._metaGap + head.sharedW > head.width
            readonly property real bylineGap: Math.round(card._lineGap / 2)
            height: head.stacked ? summary.implicitHeight + head.bylineGap + metaRow.implicitHeight
                                 : Math.max(summary.implicitHeight, meta.implicitHeight)

            Text {
                id: summary
                objectName: "notificationSummary"
                width: head.stacked ? head.width : head.width - metaRow.width - card._metaGap
                text: card.d ? card.d.summary : ""
                elide: Text.ElideRight
                wrapMode: Text.Wrap
                maximumLineCount: 2
                textFormat: Text.PlainText
                color: Theme.textPrimary
                font.family: card.fontFamily
                font.pixelSize: card._summarySize
                font.bold: true
            }
            Row {
                id: metaRow
                // Placed by x / y, never by flipping anchors (two opposing anchors set in turn
                // leave an item anchored on both sides for an instant, which destroys its width).
                // Shared, it is where `anchors.verticalCenter: summary.verticalCenter` puts it:
                // Qt rounds that anchor's two halves separately (the summary's centre, then the
                // row's half height), so the row stands on a WHOLE pixel. The plain difference over two is a
                // half pixel for an odd one, and the Text then rasters at y.5 -- soft, and not where it stands on
                // any card of the shell. The same rounding, by hand.
                x: head.stacked ? 0 : head.width - metaRow.width
                y: head.stacked ? summary.height + head.bylineGap
                                : Math.round(summary.y + summary.height / 2) - Math.round(metaRow.height / 2)
                spacing: card._metaItemGap

                Text {
                    id: meta
                    objectName: "notificationApp"
                    readonly property string _app: card.d ? String(card.d.appName || "") : ""
                    // Capped on a shared line; on a line of its own it may take what the time and
                    // the pin leave.
                    width: head.stacked ? Math.max(0, Math.min(appFit.advanceWidth, head.width - head.fixedW - head.gapsW))
                                        : Math.min(implicitWidth, card._appNameMax)
                    elide: Text.ElideRight
                    text: meta._app
                    visible: meta._app !== ""
                    textFormat: Text.PlainText
                    color: Theme.textFaint
                    font.family: card.fontFamily
                    font.pixelSize: card._metaSize
                }
                Text {
                    id: dotMark
                    text: "·"
                    visible: meta.visible
                    color: Theme.textFaint
                    font.family: card.fontFamily
                    font.pixelSize: card._metaSize
                }
                // Left-aligned in its slot: the text stays beside its dot and
                // the slot's fixed width keeps the summary's elision still.
                Text {
                    id: when
                    objectName: "notificationWhen"
                    width: Math.ceil(timeSlot.advanceWidth)
                    horizontalAlignment: Text.AlignLeft
                    // The clock's `now` is the trigger, the wall the floor: a
                    // card built after the clock's last publish (a manager
                    // opened long after it, a row scrolled in) reads the truth
                    // on its first read, and never asks for an instant already
                    // past (the reader pattern). nextMs -1 is final.
                    readonly property var _rt: card.d
                        ? RelTime.format(card.d.updatedMs || card.d.arrivedMs,
                                         card.clock ? Math.max(card.clock.now, Date.now()) : Date.now())
                        : null
                    text: when._rt ? when._rt.text : ""
                    on_RtChanged: when._arm()
                    Component.onCompleted: when._arm()
                    function _arm() {
                        if (when._rt && when._rt.nextMs > 0 && card.clock)
                            card.clock.request(Math.max(when._rt.nextMs, Date.now() + 1));
                    }
                    color: Theme.textFaint
                    font.family: card.fontFamily
                    font.pixelSize: card._metaSize

                    HoverHandler {
                        id: whenHover
                    }
                    HoverTip {
                        anchorItem: when
                        overlayItem: card.overlayItem
                        show: whenHover.hovered
                        text: card.d ? RelTime.absolute(card.d.updatedMs || card.d.arrivedMs) : ""
                        fontFamily: card.fontFamily
                    }
                }
                Text {
                    id: pinMark
                    objectName: "notificationPin"
                    visible: !!card.d && card.d.pinned
                    text: G.pin
                    font.family: G.family
                    font.pixelSize: card._metaSize
                    color: Theme.textFaint
                    anchors.verticalCenter: parent.verticalCenter

                    HoverHandler {
                        id: pinHover
                    }
                    HoverTip {
                        anchorItem: pinMark
                        overlayItem: card.overlayItem
                        show: pinHover.hovered
                        text: "pinned — swipe right to unpin"
                        fontFamily: card.fontFamily
                    }
                }
            }
            // THE TIME'S SLOT is as wide as the widest reading of the form it is in. "now", "4 min" and "23 h" share one
            // slot sized for "59 min", so a minute ticking over never moves the summary's elision or the choice.
            // "Wed 11:57", "9 Sep 09:12" and "30 Dec 2025" are wider than that (with a
            // weekday in front the hour text goes out of bounds -- the Text draws past its 40 px slot, over the
            // card's padding), so each is measured as it stands with every digit as wide as the font's widest: the
            // slot holds any time of that date for good, and changes only when the form does (once a day at most,
            // when the text itself changes). Measured by TextMetrics, never by the drawn Text.
            readonly property string slotSample: head._slotSample(when._rt ? when._rt.text : "")
            function _slotSample(t: string): string {
                if (t === "" || /^(now|\d+ (min|h))$/.test(t))
                    return "59 min";
                return t.replace(/\d/g, head._widestDigit());
            }
            // Reads the metrics' own `font` first: that read is the dependency, and the guarantee that the measure comes after
            // the font changed (an `advanceWidth()` call alone captures nothing).
            function _widestDigit(): string {
                const f = digitFm.font;
                let best = "0", bw = -1;
                for (let i = 0; i < 10; i++) {
                    const w = digitFm.advanceWidth(String(i));
                    if (w > bw && f) {
                        bw = w;
                        best = String(i);
                    }
                }
                return best;
            }
            FontMetrics {
                id: digitFm
                font.family: card.fontFamily
                font.pixelSize: card._metaSize
            }
            TextMetrics {
                id: timeSlot
                font.family: card.fontFamily
                font.pixelSize: card._metaSize
                text: head.slotSample
            }
            // The summary as one line, in the summary's own face: what it claims.
            TextMetrics {
                id: summaryFit
                font.family: card.fontFamily
                font.pixelSize: card._summarySize
                font.bold: true
                text: card.d ? card.d.summary : ""
            }
            // The pieces of "App · 3 min" and the pin, as drawn, measured where nothing is drawn.
            TextMetrics {
                id: appFit
                font.family: card.fontFamily
                font.pixelSize: card._metaSize
                text: meta._app
            }
            TextMetrics {
                id: dotFit
                font.family: card.fontFamily
                font.pixelSize: card._metaSize
                text: "·"
            }
            TextMetrics {
                id: pinFit
                font.family: G.family
                font.pixelSize: card._metaSize
                text: G.pin
            }
        }

        Text {
            id: body
            width: textCol.width
            visible: text !== ""
            text: card.d ? card.d.body : ""
            textFormat: Text.StyledText
            wrapMode: Text.Wrap
            maximumLineCount: card.expanded || card.maxLines <= 0 ? 100000 : card.maxLines
            elide: Text.ElideRight
            color: Theme.textMuted
            linkColor: Theme.accent
            font.family: card.fontFamily
            font.pixelSize: card._bodySize
            onLinkActivated: link => Qt.openUrlExternally(link)

            HoverHandler {
                cursorShape: body.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
            }
        }

        Text {
            width: textCol.width
            visible: card.footnote !== ""
            text: card.footnote
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Theme.textFaint
            font.family: card.fontFamily
            font.pixelSize: card._footSize
        }

        Meter {
            id: rail
            // The chevron's room when the rail is the column's last line (THE
            // MANAGER'S CHEVRON).
            width: textCol.width - (card._chevronShown && card._railLast ? expandChevron.width + card._metaGap : 0)
            height: card._progressH
            visible: card._hasRail
            from: 0
            to: 100
            value: card.d && card.d.progress >= 0 ? card.d.progress : 0
            trackColor: Theme.panelSunk
            trackBorderColor: Theme.border
            fillTopColor: card.groupColor
            fillBottomColor: card.groupColor
            fillShadowColor: Theme.shadowDeep
        }

        Loader {
            id: richLoader
            width: textCol.width
            active: card._rich !== null
            visible: active
            sourceComponent: card._rich ? card._rich.component : null
            // the rich record's `rev` last written into the item (see _feedRich)
            property int fedRev: -1
            onLoaded: {
                richLoader.fedRev = -1;
                card._feedRich();
            }
        }

        // Reply first, then the sender's actions: three buttons at most, the
        // rest behind "...".
        Row {
            id: actionRow
            spacing: card._actionGap
            visible: card._hasActions
            topPadding: card._actionRowPadY
            bottomPadding: card._actionRowPadY

            // The words-buttons (three at most, the rest behind "..."), and the sender's ICON actions (`icon`: a glyph,
            // an icon-only button after the others -- the screenshot's trash): they take no room of the three.
            readonly property var _all: card.d && card.d.actions ? card.d.actions : []
            readonly property var _list: actionRow._all.filter(a => !a.icon)
            readonly property var _icons: actionRow._all.filter(a => !!a.icon)
            readonly property int _room: card._maxActions - (card._hasReply ? 1 : 0)
            readonly property int _shown: actionRow._list.length <= actionRow._room
                ? actionRow._list.length : actionRow._room - 1

            CardButton {
                visible: card._hasReply
                enabled: card._live
                text: "Reply"
                style: card.style
                fontFamily: card.fontFamily
                onClicked: card.setReplyOpen(!card._replyOpen)
            }
            Repeater {
                model: actionRow._shown
                CardButton {
                    id: actBtn
                    required property int index
                    readonly property var _a: actionRow._list[actBtn.index]
                    enabled: card._live
                    text: actBtn._a ? actBtn._a.label : ""
                    style: card.style
                    fontFamily: card.fontFamily
                    onClicked: if (card.service && actBtn._a) card.service.invoke(card.d.uid, actBtn._a.id)
                }
            }
            Repeater {
                model: actionRow._icons
                CardButton {
                    id: iconBtn
                    required property var modelData
                    enabled: card._live
                    text: iconBtn.modelData.icon
                    style: card.style
                    fontFamily: G.family
                    fontPixelSize: 15
                    minWidth: card.style ? card.style.actionHeight : 30
                    horizontalPadding: 0
                    onClicked: if (card.service) card.service.invoke(card.d.uid, iconBtn.modelData.id)

                    HoverTip {
                        anchorItem: iconBtn
                        overlayItem: card.overlayItem
                        show: iconBtn._hovered   // the button's own hover: a HoverHandler under its MouseArea hears none
                        text: iconBtn.modelData.label || ""
                        fontFamily: card.fontFamily
                    }
                }
            }
            CardButton {
                id: moreBtn
                visible: actionRow._list.length > actionRow._shown
                enabled: card._live
                text: G.more
                style: card.style
                fontFamily: G.family
                onClicked: {
                    const p = moreBtn.mapToItem(card.overlayItem ?? card, 0, moreBtn.height + 4);
                    menu.openAt(p.x, p.y);
                }

                HoverTip {
                    anchorItem: moreBtn
                    overlayItem: card.overlayItem
                    show: moreBtn._hovered && !menu.visible
                    text: "More actions"
                    fontFamily: card.fontFamily
                }
            }
        }

        CarvedSearchField {
            id: replyField
            width: textCol.width
            height: card._replyH
            visible: card._replyOpen
            glyph: G.reply
            placeholder: card.d && card.d.reply ? (card.d.reply.placeholder || "Reply") : "Reply"
            surfaceColor: Theme.listBox
            fontFamily: card.fontFamily
            onEscaped: card.setReplyOpen(false)
            Keys.onReturnPressed: card._sendReply()
            Keys.onEnterPressed: card._sendReply()
        }
    }

    readonly property bool _hasReply: !!card.d && !!card.d.reply
    // What the column's last lines are, from the facts (an item's `visible`
    // is false under any hidden ancestor, CLAUDE.md): the rail is the last
    // line when nothing is drawn under it.
    readonly property bool _hasRail: !!card.d && card.d.progress >= 0
    readonly property bool _hasActions: !!card.d && !!card.d.actions && card.d.actions.length > 0 || card._hasReply
    readonly property bool _railLast: card._hasRail && card._rich === null && !card._hasActions && !card._replyOpen
    readonly property bool _chevronShown: card.expandable && (card.chevronAlways || card.truncated || card.expanded)

    PictureBand {
        id: picture
        x: card.padding
        y: card.padding + Math.max(card._iconH, textCol.implicitHeight) + card.iconGap
        width: card.cardWidth - card.padding * 2
        minHeight: card._pictureMinHeight
        maxHeight: card.pictureMaxHeight
        visible: card._picture
        source: !card._picture ? "" : (card._img.file ? "file://" + card._img.file : (card._img.url || ""))
        // a decode cap (constant under layout), as large again as the glass magnifies
        sourceSize: Qt.size(Math.round(1024 * Math.max(1, card.renderScale)), Math.round(1024 * Math.max(1, card.renderScale)))
        radius: card._pictureRadius
        asynchronous: true
        onStatusChanged: card._maybeGrabPicture()
        // No click of its own: a click on the picture is a click on the notification, and that is the SENDER'S
        // default action over D-Bus (Signal raises its window; a shell source's own onDefault opens its file).
        // Opening the image's file instead would, for an image-data picture, open the PNG this card
        // grabbed of it: a click on a Signal toast would open GIMP on an empty transparent square.
    }

    // The manager's chevron: shown when the body was clipped (or is open), at
    // the card's lower right, in the padding under the text column. Turning
    // it opens the body in place; the body click stays "act".
    Chevron {
        id: expandChevron
        visible: card._chevronShown
        size: card._chevronSize
        thickness: card._chevronStroke
        color: Theme.textFaint
        x: Math.round(card.cardWidth - card.padding - width)
        y: Math.round(card.implicitHeight - card.padding / 2 - height - 2)
        rotation: card.expanded ? 180 : 0

        MouseArea {
            anchors.fill: parent
            anchors.margins: -6
            cursorShape: Qt.PointingHandCursor
            onClicked: card.expandToggled()
        }
    }

    FloatingMenu {
        id: menu
        overlayItem: card.overlayItem
        fontFamily: card.fontFamily
        rows: {
            const out = [];
            const l = actionRow._list;
            for (let i = actionRow._shown; i < l.length; i++)
                out.push({ id: l[i].id, label: l[i].label });
            return out;
        }
        onTriggered: id => { if (card.service) card.service.invoke(card.d.uid, id); }
    }

    function setReplyOpen(open) {
        if (card._replyOpen === open)
            return;
        card._replyOpen = open;
        if (open)
            Qt.callLater(() => replyField.forceFocus());
        card.replyToggled(open);
    }
    function _sendReply() {
        const t = replyField.text.trim();
        if (t === "" || !card.service)
            return;
        card.service.reply(card.d.uid, t);
        card.setReplyOpen(false);
    }
    function _maybeGrabPicture() {
        if (!card._picture || picture.status !== Image.Ready || !card.service || card._img.file)
            return;
        if (String(card._img.url || "").indexOf("image://qsimage/") !== 0)
            return;
        const svc = card.service;
        const dir = svc.imagesDir || (String(svc.historyPath || "").replace(/[^/]*$/, "") + "images");
        const uid = card.d.uid;
        const file = dir + "/" + uid + ".png";
        const w = Math.min(1024, picture.image.implicitWidth);
        const h = Math.round(w * picture.image.implicitHeight / Math.max(1, picture.image.implicitWidth));
        // The Image itself, not the band: the band shows a centred part of a picture that is taller or wider than its
        // bounds, and what is kept in the file is the picture.
        picture.image.grabToImage(r => {
            if (r.saveToFile(file))
                svc.imageGrabbed(uid, file);
        }, Qt.size(w, h));
    }
}
