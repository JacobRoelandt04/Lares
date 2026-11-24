pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/StocksFormat.js" as F

// =============================================================================
// StocksList.qml -- the carved list under the tab row.
//
// A fixed number of rows tall (`rows` x `rowHeight` under the header), so a
// tab switch, a search or an empty watchlist never resizes the popup.
//
//   header   what is listed and how many, and the sort: the notes module's
//            SortControl -- the label is the mode and its direction ("Value
//            ↓"), a click opens the menu of modes and the direction
//            (service.setSort; the service remembers both). In search mode:
//            "Results" and nothing to sort.
//   rows     the service's ListModel for the mode, each row at its RANK
//            (index x rowHeight). The model is mirrored by position, so a new
//            order is new words in the same rows, swapped at once.
//   Closed   (holdings only) a collapsed ListSectionHeader with the fully sold
//            positions under it; the service remembers it open or shut.
//
// Loading: skeleton rows where the rows will be. Empty: one line saying why.
// The viewport scrolls through ScrollDressing (its own wheel reader, the fades).
// =============================================================================
Item {
    id: list

    property var service: null
    property var popup: null
    property Item overlayItem: null
    property var activeKey: null
    property bool searching: false
    property string fontFamily: "Inter"
    property real radius: 14
    property int rows: 6
    property real rowHeight: 44
    property real logoSize: 30
    property int bodySize: 12
    property int figureSize: 11
    property real headerHeight: 30
    property real inset: 6
    property real bevelWidth: 1
    property real shadowWidth: 3
    property real shadowFalloff: 1
    property real flashPeak: 0.22
    property real flashPad: 3

    readonly property string tab: list.service ? list.service.tab : "holdings"
    readonly property var mainModel: !list.service ? null
                                     : list.searching ? list.service.searchRows
                                     : list.tab === "watchlist" ? list.service.watchRows
                                     : list.service.holdingRows
    readonly property int mainCount: list.mainModel ? list.mainModel.count : 0
    readonly property int closedCount: !list.searching && list.tab === "holdings" && list.service && list.service.closedRows
                                       ? list.service.closedRows.count : 0
    readonly property bool closedExpanded: !!list.service && !!list.service.closedExpanded
    readonly property bool loading: !!list.service && list.service.loading
    readonly property bool busy: list.searching && !!list.service && list.service.searchBusy

    readonly property real viewHeight: list.rows * list.rowHeight
    implicitHeight: Math.round(list.headerHeight + list.viewHeight + list.inset)

    // ---- slot widths, measured once for every row -----------------------------------
    // A slot holds the largest magnitude the portfolio has in it (a +1,223 %
    // total gain is a real figure), never less than the template's default.
    readonly property var _max: {
        const p = list.service ? list.service.portfolio : null;
        let pct = 88.88, money = 88888.88;
        const all = p ? (p.holdings || []).concat(p.closed || []) : [];
        for (let i = 0; i < all.length; i++) {
            const h = all[i];
            for (const v of [h.totalPct, h.totalPctReal, h.dayPct, h.changePct])
                if (typeof v === "number" && isFinite(v))
                    pct = Math.max(pct, Math.abs(v));
            for (const v of [h.value, h.realised, h.realisedReal])
                if (typeof v === "number" && isFinite(v))
                    money = Math.max(money, Math.abs(v));
        }
        return { pct: pct, money: money };
    }
    TextMetrics {
        id: priceM
        font.family: list.fontFamily
        font.pixelSize: list.figureSize
        text: F.priceTemplate(88888.88, "EUR")
    }
    TextMetrics {
        id: moneyM
        font.family: list.fontFamily
        font.pixelSize: list.figureSize
        font.bold: true
        text: F.signedMoneyTemplate(list._max.money)
    }
    TextMetrics {
        id: pctM
        font.family: list.fontFamily
        font.pixelSize: list.figureSize
        font.bold: true
        text: F.pctTemplate(list._max.pct)
    }

    ShadowBox {
        anchors.fill: parent
        baseRadius: list.radius
        surfaceColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.listBox
        bevelWidth: list.bevelWidth
        shadowWidth: list.shadowWidth
        shadowFalloff: list.shadowFalloff
    }

    // ---- the header -------------------------------------------------------------------
    Text {
        id: countText
        x: list.inset + 8
        y: 0
        height: list.headerHeight
        verticalAlignment: Text.AlignVCenter
        text: {
            if (list.loading && list.mainCount === 0)
                return "";
            if (list.searching)
                return list.busy ? "Searching…" : (list.mainCount === 1 ? "1 result" : list.mainCount + " results");
            if (list.tab === "watchlist")
                return list.mainCount === 1 ? "1 watched" : list.mainCount + " watched";
            return list.mainCount === 1 ? "1 holding" : list.mainCount + " holdings";
        }
        color: Theme.textMuted
        font.family: list.fontFamily
        font.pixelSize: list.figureSize
    }
    SortControl {
        id: sortCtl
        objectName: "stocksSortHeader"
        visible: !list.searching
        x: list.width - list.inset - 8 - width
        y: 0
        width: implicitWidth
        height: list.headerHeight
        overlayItem: list.overlayItem
        fontFamily: list.fontFamily
        fontPixelSize: list.figureSize
        modes: [
            {
                id: "value",
                label: "Value",
                directional: true
            },
            {
                id: "day",
                label: "Day move",
                directional: true
            },
            {
                id: "total",
                label: "Total gain",
                directional: true
            },
            {
                id: "name",
                label: "Name",
                directional: true
            }
        ]
        mode: list.service ? list.service.sortKey : "value"
        ascending: !!list.service && list.service.sortAscending === true
        onSortRequested: (mode, ascending) => {
            if (list.service)
                list.service.setSort(mode, ascending);
        }
    }

    // ---- the rows -----------------------------------------------------------------------
    Flickable {
        id: flick
        x: 0
        y: list.headerHeight
        width: list.width
        height: list.viewHeight
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: content.height

        Item {
            id: content
            width: flick.width
            readonly property real closedY: list.mainCount * list.rowHeight
            readonly property real closedHeaderH: list.closedCount > 0 ? Math.ceil(closedHeader.height) + 8 : 0
            height: content.closedY + content.closedHeaderH + (list.closedExpanded ? list.closedCount * list.rowHeight : 0)

            Repeater {
                id: mainRows
                model: list.mainModel
                delegate: StockRow {
                    id: mainRow
                    required property int index
                    // The service mirrors its sorted array into the model BY
                    // POSITION (one record per rank, only `d` reassigned), so a
                    // row is its rank: a new order swaps what the rows say, at
                    // once (text swaps are instant), and nothing is rebuilt.
                    y: mainRow.index * list.rowHeight
                    width: content.width
                    height: list.rowHeight
                    service: list.service
                    popup: list.popup
                    activeKey: list.activeKey
                    fontFamily: list.fontFamily
                    bodySize: list.bodySize
                    figureSize: list.figureSize
                    logoSize: list.logoSize
                    priceW: Math.ceil(priceM.advanceWidth)
                    moneyW: Math.ceil(moneyM.advanceWidth)
                    pctW: Math.ceil(pctM.advanceWidth)
                    flashPeak: list.flashPeak
                    flashPad: list.flashPad
                }
            }

            ListSectionHeader {
                id: closedHeader
                visible: list.closedCount > 0
                x: list.inset
                y: content.closedY + 4
                width: content.width - 2 * list.inset
                title: "Closed"
                subtitle: list.closedCount === 1 ? "1 position" : list.closedCount + " positions"
                expandable: true
                expanded: list.closedExpanded
                fontFamily: list.fontFamily
                titleSize: list.bodySize
                subtitleSize: list.figureSize
                textColor: Theme.textPrimary
                mutedColor: Theme.textMuted
                faintColor: Theme.textFaint
                boxColor: Theme.headerBox
                boxSurfaceColor: Theme.listBox
                boxBevelColor: Theme.headerBoxBevel
                boxShadowColor: Theme.headerBoxShadow
                containerRadius: list.radius
                onToggled: {
                    if (list.service)
                        list.service.closedExpanded = !list.service.closedExpanded;
                }
            }

            Repeater {
                id: closedRows
                model: list.closedCount > 0 && list.closedExpanded ? list.service.closedRows : null
                delegate: StockRow {
                    id: closedRow
                    required property int index
                    y: content.closedY + content.closedHeaderH + closedRow.index * list.rowHeight
                    width: content.width
                    height: list.rowHeight
                    service: list.service
                    popup: list.popup
                    activeKey: list.activeKey
                    fontFamily: list.fontFamily
                    bodySize: list.bodySize
                    figureSize: list.figureSize
                    logoSize: list.logoSize
                    priceW: Math.ceil(priceM.advanceWidth)
                    moneyW: Math.ceil(moneyM.advanceWidth)
                    pctW: Math.ceil(pctM.advanceWidth)
                    flashPeak: list.flashPeak
                    flashPad: list.flashPad
                }
            }
        }
    }
    ScrollDressing {
        anchors.fill: flick
        flick: flick
        ground: Theme.listBox
        fadeHeight: 18
    }

    // ---- loading and empty ------------------------------------------------------------
    Item {
        id: skeleton
        x: 0
        y: flick.y
        width: list.width
        height: flick.height
        opacity: list.loading && list.mainCount === 0 ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 160
            }
        }
        Repeater {
            model: list.rows
            delegate: Item {
                id: sk
                required property int index
                x: list.inset + 8
                y: sk.index * list.rowHeight
                width: list.width - 2 * list.inset - 16
                height: list.rowHeight
                SkeletonBar {
                    x: 0
                    y: Math.round((sk.height - list.logoSize) / 2)
                    width: list.logoSize
                    height: list.logoSize
                    radius: 8
                    pulsePhaseMs: sk.index * 90
                }
                SkeletonBar {
                    x: list.logoSize + 10
                    y: Math.round(sk.height / 2 - 12)
                    width: 90
                    height: 10
                    pulsePhaseMs: sk.index * 90
                }
                SkeletonBar {
                    x: list.logoSize + 10
                    y: Math.round(sk.height / 2 + 3)
                    width: 150
                    height: 9
                    pulsePhaseMs: sk.index * 90
                }
                SkeletonBar {
                    x: sk.width - 60
                    y: Math.round(sk.height / 2 - 12)
                    width: 60
                    height: 10
                    pulsePhaseMs: sk.index * 90
                }
                SkeletonBar {
                    x: sk.width - 90
                    y: Math.round(sk.height / 2 + 3)
                    width: 90
                    height: 9
                    pulsePhaseMs: sk.index * 90
                }
            }
        }
    }
    Text {
        id: emptyText
        x: list.inset + 8
        y: flick.y
        width: list.width - 2 * (list.inset + 8)
        height: flick.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.Wrap
        opacity: !list.loading && !list.busy && list.mainCount === 0 && list.closedCount === 0 ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 160
            }
        }
        readonly property string cfgError: list.service && list.service.configError ? String(list.service.configError) : ""
        text: list.searching ? "Nothing on Yahoo matches that."
            : list.tab === "watchlist" ? "Nothing watched yet. The star on a stock's detail adds it here."
            : emptyText.cfgError ? "stocks.jsonc has an error: " + emptyText.cfgError.replace(/^stocks\.jsonc /, "")
            : "No holdings. Add them to stocks.jsonc (.examples/stocks.jsonc in the shell's folder shows how)."
        color: !list.searching && list.tab === "holdings" && emptyText.cfgError ? Theme.warn : Theme.textFaint
        font.family: list.fontFamily
        font.pixelSize: list.bodySize
    }

    // Scroll the Closed section's header to the top (as far as the list goes).
    function revealClosed() {
        if (list.closedCount === 0)
            return;
        Qt.callLater(() => flick.contentY = Math.max(0, Math.min(flick.contentHeight - flick.height, content.closedY)));
    }

    // ---- links ----------------------------------------------------------------------
    // The row a key is the link of, if it is drawn in the viewport.
    function rowItem(key) {
        if (!key)
            return null;
        const pick = (rep) => {
            for (let i = 0; i < rep.count; i++) {
                const it = rep.itemAt(i);
                if (it && it.symbol === key.symbol && it.kind === key.from)
                    return it;
            }
            return null;
        };
        return pick(mainRows) || pick(closedRows);
    }
}
