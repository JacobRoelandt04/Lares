pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// StocksPopup.qml -- the stocks module's content for thePopup.
//
// ONE layout (no view modes), top to bottom, one padding apart:
//
//   summary card   total value, day gain, total gain (+ breakdown tip), the
//                  value-vs-invested chart with its range chips, the indices
//                  strip
//   tab row        Holdings | Watchlist (a two-finger sideways swipe over the
//                  selector switches it -- its own swipe), and the search
//                  field beside it (typing replaces the list; Esc clears)
//   list card      the sort (SortControl), the rows by rank, "Closed"
//
// The list is a fixed number of rows tall, so a tab switch, a search or an
// empty watchlist never resizes the popup.
//
// Everything reads ONE StocksService (`service`), which the bar-side owner
// keeps alive across closes. Nothing here fetches, sorts or computes money.
//
// ---- The engine's secondary contract (bar_structure.md) ----------------------
//
// Any row or index cell opens the stock's detail in the engine's secondary
// popup: `openDetail(key, anchor)` with key `{ symbol, from }`, from one of
// "holding" | "watch" | "closed" | "index" | "search". The same key again
// closes it. A tab switch or entering / leaving search closes it (the link it
// hung from is gone); a sort change RE-ANCHORS it on its row's new place.
// `linkItem(key)` is the item a key is the link of, `anchorFor(key)` its
// centre -- what a host clicks and a probe measures.
//
// WHERE THE DETAIL OPENS:
//   detailSide        "far" (away from the bar) | "start" | "end" (along it)
//   detailAnchor      "row"    centred on the link that was clicked
//                     "start"  its start flush with the popup's start
//                     "centre" centred on the popup
//                     "end"    its end flush with the popup's end
//                     -- along the side it hangs from: x below or above the
//                     popup, y beside it. Both coordinates are given; the
//                     engine takes the one its side runs along.
//   detailWidthScale  its width, in popup widths (0.6 .. 1.6)
//   detailOverhang    may hang past the popup's ends (clamped to the screen);
//                     always on when it is longer than the popup along that
//                     side, which the engine would otherwise centre on it
//   detailInset       how far it reaches under the popup (secondaryInset);
//                     the detail lays itself out around the cutout
//   detailMaxHeight   a ceiling (960): the detail is a static size, past this only a short screen scrolls its body
// =============================================================================
Item {
    id: root

    property var service: null
    property string fontFamily: "Inter"

    // ---- Layout knobs --------------------------------------------------------------
    property real popupWidth: 504
    property real padding: 12
    property real cardPadding: 12
    property real radius: 14
    property int listRows: 6
    property real rowHeight: 44
    property real logoSize: 30
    property real summaryChartHeight: 96
    property real tabRowHeight: 30
    property real searchWidth: 180
    property int titleSize: 16
    property int bodySize: 12
    property int figureSize: 11
    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    property real cardShadowFalloff: 1

    // ---- The indices strip ---------------------------------------------------------
    property int stripCycleMs: 4000
    property int stripRollMs: 420
    property int stripStaggerMs: 90
    property int stripHoverDwellMs: 400
    property int stripReleaseGraceMs: 250

    // ---- The real flip's flash (GainFlash) ---------------------------------------------
    property real flashPeak: 0.22
    property real flashPad: 3

    // ---- The detail (see the header: where it opens) -----------------------------------
    property string detailSide: "far"
    property string detailAnchor: "row"
    property real detailWidthScale: 1
    property bool detailOverhang: false
    property real detailInset: 0
    // A persistent detail comes back with the popup; `detailMemory` (a
    // SecondaryMemory the owner keeps) holds whether it was open, and on what.
    property bool detailPersistent: false
    property var detailMemory: null
    readonly property real detailWidth: Math.round(root.popupWidth * root.detailWidthScale)
    property real detailMaxHeight: 960
    property real detailChartHeight: 180
    property real detailLogoSize: 56

    // The search field wants the keyboard only when it is clicked.
    property string keyboardFocusRequest: "onDemand"

    implicitWidth: root.popupWidth
    implicitHeight: Math.round(root.padding + summary.implicitHeight + root.padding + root.tabRowHeight
                               + root.padding + list.implicitHeight + root.padding)

    // Laid out at the width the content ASKED for, not the host's easing box
    // (CLAUDE.md: a page laid out at the easing box re-lays out while it opens).
    readonly property real _innerW: root.popupWidth - 2 * root.padding

    readonly property bool searching: !!root.service && (root.service.searchQuery || "").length > 0
    readonly property string tab: root.service ? root.service.tab : "holdings"

    // ---- The engine's content contract (§5) --------------------------------------
    property Component secondaryComponent: Component {
        StockDetail {
            service: root.service
            fontFamily: root.fontFamily
            detailWidth: root.detailWidth
            maxHeight: root.detailMaxHeight
            chartHeight: root.detailChartHeight
            logoSize: root.detailLogoSize
            padding: root.padding
            cardPadding: root.cardPadding
            radius: root.radius
            titleSize: root.titleSize
            bodySize: root.bodySize
            figureSize: root.figureSize
            cardBevelWidth: root.cardBevelWidth
            cardShadowWidth: root.cardShadowWidth
            cardShadowFalloff: root.cardShadowFalloff
            flashPeak: root.flashPeak
            flashPad: root.flashPad
            // Its height places it on a side (the anchor's "start" / "end") and
            // decides the overhang: its NATURAL height, which the engine cannot
            // move (the live one includes the cutout the engine writes back).
            onNaturalHeightChanged: root._detailH = naturalHeight
            Component.onCompleted: root._detailH = naturalHeight
        }
    }
    property bool secondaryOpen: false
    readonly property point secondaryAnchor: root._anchorPoint(root.detailAnchor)
    readonly property string secondarySide: root.detailSide
    readonly property bool secondaryOverhang: root.detailOverhang || root._detailLonger
    readonly property real secondaryInset: root.detailInset
    property var secondaryKey: null
    readonly property bool secondaryPersistent: root.detailPersistent
    // Every open, close and re-key the user makes is remembered; the popup
    // closing is not one (the engine closes the child, `secondaryOpen` stays).
    onSecondaryOpenChanged: root._remember()
    onSecondaryKeyChanged: root._remember()
    function _remember() {
        if (root.detailPersistent && root.detailMemory)
            root.detailMemory.remember(root.secondaryOpen, root.secondaryOpen ? root.secondaryKey : null);
    }
    // The popup goes with the detail out: it was on screen until now (the decay counts from here).
    Component.onDestruction: {
        if (root.detailPersistent && root.detailMemory && root.secondaryOpen)
            root.detailMemory.seen();
    }
    // The remembered detail, as its link would open it (under its row when
    // the row is drawn, the popup's centre when it is not).
    function restoreDetail(key) {
        if (!key || typeof key.symbol !== "string" || key.symbol.length === 0)
            return;
        root._linkAnchor = root.anchorFor(key);
        root.secondaryKey = key;
        root.secondaryOpen = true;
    }

    // The clicked link's centre (the "row" anchor), and the detail's size
    // along each side: its width below / above the popup, its height beside it.
    property point _linkAnchor: Qt.point(0, 0)
    property real _detailH: root.detailMaxHeight
    readonly property bool _beside: root.detailSide === "start" || root.detailSide === "end"
    readonly property bool _detailLonger: root._beside ? root._detailH > root.implicitHeight + 0.5
                                                       : root.detailWidth > root.popupWidth + 0.5
    function _anchorPoint(mode) {
        const pw = root.implicitWidth, ph = root.implicitHeight;
        const cw = root.detailWidth, ch = root._detailH;
        switch (mode) {
        case "start":
            return Qt.point(cw / 2, ch / 2);
        case "centre":
            return Qt.point(pw / 2, ph / 2);
        case "end":
            return Qt.point(pw - cw / 2, ph - ch / 2);
        default:
            return root._linkAnchor;
        }
    }

    // The key the links highlight against: the open detail's, or nothing.
    readonly property var activeKey: root.secondaryOpen ? root.secondaryKey : null

    // Symbol, and the link it came from when both keys say.
    function sameKey(a, b) {
        if (!a || !b)
            return false;
        if (a.symbol !== b.symbol)
            return false;
        return !(a.from && b.from) || a.from === b.from;
    }
    // The links call this. `anchor` is the clicked item's centre in this
    // popup's coordinates.
    function openDetail(key, anchor) {
        if (root.secondaryOpen && root.sameKey(root.secondaryKey, key)) {
            root.secondaryOpen = false;
            return;
        }
        root._linkAnchor = anchor;
        root.secondaryKey = key;
        root.secondaryOpen = true;
    }
    function closeDetail() {
        root.secondaryOpen = false;
    }
    // Escape's step back (GooeyEngine.stepBack, asked only under shell.jsonc `"escape": "detail"`): the detail goes; true when one was open
    function stepBack(): bool {
        const was = root.secondaryOpen;
        root.closeDetail();
        return was;
    }
    function linkItem(key) {
        if (!key)
            return null;
        switch (key.from) {
        case "index":
            return summary.stripCell(key.symbol);
        case "holding":
        case "watch":
        case "closed":
        case "search":
            return list.rowItem(key);
        default:
            return null;
        }
    }
    function anchorFor(key) {
        const it = root.linkItem(key);
        return it ? it.mapToItem(root, it.width / 2, it.height / 2) : Qt.point(root.width / 2, root.height / 2);
    }

    // A new list is a new set of links: whatever the detail hung from may not
    // be drawn any more.
    onTabChanged: root.closeDetail()
    onSearchingChanged: root.closeDetail()
    // A new order moves the link: the detail follows it to the row's new rank
    // once the rows have been placed (they are placed, not animated, off screen).
    // A flip of the direction is a new order too.
    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onSortKeyChanged() {
            if (root.secondaryOpen)
                Qt.callLater(root.reanchor);
        }
        function onSortAscendingChanged() {
            if (root.secondaryOpen)
                Qt.callLater(root.reanchor);
        }
    }
    // Open the Closed section and bring it into view (holdings only).
    function showClosed() {
        if (!root.service)
            return;
        root.service.tab = "holdings";
        root.service.closedExpanded = true;
        list.revealClosed();
    }
    function reanchor() {
        if (!root.secondaryOpen)
            return;
        if (!root.linkItem(root.secondaryKey)) {
            root.closeDetail();
            return;
        }
        root._linkAnchor = root.anchorFor(root.secondaryKey);
    }

    // ---- The summary -------------------------------------------------------------------
    StocksSummaryCard {
        id: summary
        x: root.padding
        y: root.padding
        width: root._innerW
        height: implicitHeight
        popup: root
        service: root.service
        fontFamily: root.fontFamily
        cardPadding: root.cardPadding
        radius: root.radius
        chartHeight: root.summaryChartHeight
        titleSize: root.titleSize
        bodySize: root.bodySize
        figureSize: root.figureSize
        cycleMs: root.stripCycleMs
        rollMs: root.stripRollMs
        staggerMs: root.stripStaggerMs
        hoverDwellMs: root.stripHoverDwellMs
        releaseGraceMs: root.stripReleaseGraceMs
        flashPeak: root.flashPeak
        flashPad: root.flashPad
        bevelWidth: root.cardBevelWidth
        shadowWidth: root.cardShadowWidth
        shadowFalloff: root.cardShadowFalloff
        overlayItem: overlay
    }

    // ---- Holdings | Watchlist, and the search field --------------------------------------
    Item {
        id: tabRow
        x: root.padding
        y: summary.y + summary.height + root.padding
        width: root._innerW
        height: root.tabRowHeight

        TabSelector {
            id: tabs
            objectName: "stocksTabs"
            x: 0
            y: 0
            width: tabRow.width - root.searchWidth - root.padding
            height: tabRow.height
            // Its own swipe (the selector's default): a two-finger sideways
            // swipe over the selector steps the tab (its MouseArea; nothing
            // above it reads a wheel). A change goes through onTabChanged
            // like a click.
            fontFamily: root.fontFamily
            fontPixelSize: root.bodySize
            tabs: [
                { id: "holdings", label: "Holdings" },
                { id: "watchlist", label: "Watchlist" }
            ]
            onTabChanged: id => {
                if (root.service && root.service.tab !== id)
                    root.service.tab = id;
            }
        }
        // The selector writes its own currentTab on a click, which would cut
        // a plain binding for good (CLAUDE.md): the truth is a Binding element.
        Binding {
            target: tabs
            property: "currentTab"
            value: root.tab
        }

        CarvedSearchField {
            id: search
            objectName: "stocksSearch"
            x: tabRow.width - width
            y: 0
            width: root.searchWidth
            height: tabRow.height
            placeholder: "Search stocks"
            fontFamily: root.fontFamily
            pixelSize: root.bodySize
            surfaceColor: Theme.surface
            onEdited: t => {
                if (root.service)
                    root.service.setSearchQuery(t);
            }
            onEscaped: {
                if (root.service)
                    root.service.clearSearch();
            }
        }
        // The service's query is the truth (a probe or a replay may set it):
        // copied in when it differs, so the field's own typing is never cut.
        Component.onCompleted: search.text = root.service ? (root.service.searchQuery || "") : ""
        Connections {
            target: root.service
            ignoreUnknownSignals: true
            function onSearchQueryChanged() {
                const q = root.service.searchQuery || "";
                if (search.text !== q)
                    search.text = q;
            }
        }
    }

    // ---- The list ------------------------------------------------------------------------
    StocksList {
        id: list
        x: root.padding
        y: tabRow.y + tabRow.height + root.padding
        width: root._innerW
        height: implicitHeight
        popup: root
        service: root.service
        fontFamily: root.fontFamily
        radius: root.radius
        rows: root.listRows
        rowHeight: root.rowHeight
        logoSize: root.logoSize
        bodySize: root.bodySize
        figureSize: root.figureSize
        searching: root.searching
        bevelWidth: root.cardBevelWidth
        shadowWidth: root.cardShadowWidth
        shadowFalloff: root.cardShadowFalloff
        activeKey: root.activeKey
        overlayItem: overlay
        flashPeak: root.flashPeak
        flashPad: root.flashPad
    }

    // Floating things (tips) live here, above every card, inside the popup's
    // own bounds so the pointer reaches them.
    Item {
        id: overlay
        anchors.fill: parent
        z: 10
    }
}
