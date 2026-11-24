pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/StocksFormat.js" as F

// =============================================================================
// StockRow.qml -- one stock in the list, two lines.
//
//   [logo]  ASML       ~spark~     1,497.40 EUR    +0.84%
//           ASML Holding  12 sh    €17,968.80      +31.2%
//
// holding  label / spark / price in its OWN currency / day %
//          name / shares / value in EUR / total gain %
// watch    label / spark / price / day %;  name · exchange
// closed   label / realised EUR / total gain %;  name · "closed"
// search   symbol / price / day % when Yahoo gave them;  name · exchange · type
//
// EXTENDED HOURS. A holding or a watched stock in its pre- or post-market
// with a move (`d.ext`) shows it in line 2's last slot -- a small "pre" /
// "post" before its % -- in place of a holding's total gain,
// which comes back when the regular session opens.
//
// Every figure sits in a right-aligned slot as wide as its template, so the
// columns never move when a digit does (CLAUDE.md: figures never jitter).
//
// ONE MouseArea is the row's hover, its click and its gain hover: whether the
// pointer is over a GAIN figure is decided by arithmetic on the slots' own
// rects (CLAUDE.md: a hover handler stacked over a link steals its hover), and
// that asks the service for real figures (`realHover`), which flips every gain
// figure of the popup and the detail at once -- and a pale pill flashes behind
// each figure that flipped (GainFlash, on the service's `realFlash` clock): a
// holding's total gain %, a closed position's realised money and its %.
// =============================================================================
Item {
    id: row

    required property var rec                 // QtObject { property var d } -- d is a Row
    readonly property var d: row.rec ? row.rec.d : null
    property var service: null
    property var popup: null
    property var activeKey: null
    property string fontFamily: "Inter"
    property int bodySize: 12
    property int figureSize: 11
    property real logoSize: 30
    property real sparkWidth: 44
    property real sparkHeight: 14
    property real inset: 6
    property real pad: 8
    property real gap: 8
    // Slot widths, measured once by the list for every row.
    property real priceW: 90
    property real moneyW: 90
    property real pctW: 50
    // The real flip's flash (GainFlash).
    property real flashPeak: 0.22
    property real flashPad: 3

    readonly property string kind: row.d ? row.d.kind : ""
    readonly property string symbol: row.d ? row.d.symbol : ""
    readonly property var key: ({
            symbol: row.symbol,
            from: row.kind
        })
    readonly property bool selected: !!row.activeKey && row.activeKey.symbol === row.symbol && row.activeKey.from === row.kind
    readonly property bool real: !!row.service && row.service.showReal
    readonly property var ext: row.d && row.d.ext && (row.kind === "holding" || row.kind === "watch") ? row.d.ext : null
    readonly property real flash: row.service && typeof row.service.realFlash === "number" ? row.service.realFlash : 0

    function _num(v) {
        return typeof v === "number" && isFinite(v);
    }

    function _tone(v) {
        return v < 0 ? Theme.stockLoss : Theme.stockGain;
    }

    // ---- geometry: the columns, right to left -------------------------------------
    readonly property real _w: row.width - 2 * row.inset
    readonly property real _dX: row.inset + row._w - row.pad - row.pctW
    readonly property real _cW: Math.max(row.priceW, row.moneyW)
    readonly property real _cX: row._dX - row.gap - row._cW
    readonly property real _bX: row._cX - row.gap - row.sparkWidth
    readonly property real _aX: row.inset + row.pad + row.logoSize + 10
    readonly property real _lineH: Math.ceil(row.bodySize * 1.35)
    readonly property real _l1: Math.round(row.height / 2 - row._lineH - 1)
    readonly property real _l2: Math.round(row.height / 2 + 1)

    // ---- the grounds: hover wash, and the carved ground of the open detail's row -----
    property real hoverF: area.containsMouse ? 1 : 0
    Behavior on hoverF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    property real selF: row.selected ? 1 : 0
    Behavior on selF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    Rectangle {
        x: row.inset
        y: 2
        width: row._w
        height: row.height - 4
        radius: 8
        color: Theme.panelSunk
        opacity: 0.6 * row.hoverF * (1 - row.selF)
    }
    ShadowBox {
        x: row.inset
        y: 2
        width: row._w
        height: row.height - 4
        opacity: row.selF
        visible: opacity > 0
        baseRadius: 8
        surfaceColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.panelSunk
        bevelWidth: 1
        shadowWidth: 2.5
    }

    // ---- the logo ----------------------------------------------------------------
    LogoRelief {
        x: row.inset + row.pad
        y: Math.round((row.height - row.logoSize) / 2)
        logoSize: row.logoSize
        // At 30 px the baked wall is under 2 px: the carve reads through a
        // FLOOR a shade down (the sunk-panel shade toward the border), the
        // deep shadow and a slower falloff that holds it across the thin wall.
        // The dark palette's border is already far below its list box, so the
        // floor goes less of the way there.
        surfaceColor: Theme.listBox
        shadowColor: Theme.shadowDeep
        bodyColor: Mix.c(Theme.panelSunk, Theme.border, Theme.mode === "dark" ? 0.5 : 1.0)
        falloff: Theme.mode === "dark" ? 0.6 : 0.3
        ambient: Theme.mode === "dark" ? 0.6 : 1.0
        bevelWidth: 0.3
        source: {
            const s = row.service;
            if (!s || !row.symbol)
                return "";
            void s.logoSerial;
            return s.logoFor(row.symbol, row.logoSize) || "";
        }
    }
    Component.onCompleted: {
        if (row.service && row.symbol && row.service.wantLogo)
            row.service.wantLogo(row.symbol, 1);
    }
    onSymbolChanged: {
        if (row.service && row.symbol && row.service.wantLogo)
            row.service.wantLogo(row.symbol, 1);
    }

    // ---- line 1 --------------------------------------------------------------------
    Text {
        id: labelText
        x: row._aX
        y: row._l1
        width: (row.kind === "closed" || row.kind === "search" ? row._cX : row._bX) - row.gap - x
        height: row._lineH
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: row.d ? (row.d.label || row.d.symbol || "") : ""
        color: Theme.textPrimary
        font.family: row.fontFamily
        font.pixelSize: row.bodySize
        font.bold: true
    }
    Sparkline {
        visible: row.kind === "holding" || row.kind === "watch"
        x: row._bX
        y: Math.round(row._l1 + (row._lineH - height) / 2)
        width: row.sparkWidth
        height: row.sparkHeight
        values: row.d && row.d.spark && row.d.spark.v ? row.d.spark.v : []
        baselineValue: row.d && row.d.spark && row._num(row.d.spark.base) ? row.d.spark.base : NaN
        color: row._tone(row.d ? row.d.changePct : 0)
        baselineColor: Theme.textFaint
    }
    Text {
        id: line1C
        x: row._cX
        y: row._l1
        width: row._cW
        height: row._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: {
            const d = row.d;
            if (!d)
                return "";
            if (row.kind === "closed")
                return F.signedMoney(row.real ? d.realisedReal : d.realised);
            return row._num(d.price) ? F.price(d.price, d.currency || "", d.priceHint) : "";
        }
        color: row.kind === "closed" && row.d ? row._tone(row.real ? row.d.realisedReal : row.d.realised) : Theme.textPrimary
        font.family: row.fontFamily
        font.pixelSize: row.figureSize
        font.bold: row.kind === "closed"
        GainFlash {
            target: line1C
            strength: row.kind === "closed" ? row.flash : 0
            peak: row.flashPeak
            hPad: row.flashPad
        }
    }
    Text {
        id: line1D
        x: row._dX
        y: row._l1
        width: row.pctW
        height: row._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        readonly property var v: {
            const d = row.d;
            if (!d)
                return null;
            if (row.kind === "closed")
                return row.real ? d.totalPctReal : d.totalPct;
            return d.changePct;
        }
        text: row._num(line1D.v) ? F.pct(line1D.v) : ""
        color: row._tone(line1D.v)
        font.family: row.fontFamily
        font.pixelSize: row.figureSize
        font.bold: true
        GainFlash {
            target: line1D
            strength: row.kind === "closed" ? row.flash : 0
            peak: row.flashPeak
            hPad: row.flashPad
        }
    }

    // ---- line 2 --------------------------------------------------------------------
    Text {
        x: row._aX
        y: row._l2
        width: (row.kind === "holding" ? row._bX : row._cX) - row.gap - x
        height: row._lineH
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: {
            const d = row.d;
            if (!d)
                return "";
            const parts = [d.name || ""];
            if (row.kind === "watch" && d.exchDisp)
                parts.push(d.exchDisp);
            if (row.kind === "search") {
                if (d.exchDisp)
                    parts.push(d.exchDisp);
                if (d.typeDisp)
                    parts.push(d.typeDisp);
            }
            if (row.kind === "closed")
                parts.push("closed");
            return parts.filter(p => p.length > 0).join(" · ");
        }
        color: Theme.textMuted
        font.family: row.fontFamily
        font.pixelSize: row.figureSize
    }
    Text {
        visible: row.kind === "holding"
        x: row._bX
        y: row._l2
        width: row.sparkWidth
        height: row._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: row.d && row._num(row.d.shares) ? F.shares(row.d.shares) : ""
        color: Theme.textMuted
        font.family: row.fontFamily
        font.pixelSize: row.figureSize
    }
    Text {
        visible: row.kind === "holding"
        x: row._cX
        y: row._l2
        width: row._cW
        height: row._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: row.d && row._num(row.d.value) ? F.money(row.d.value) : ""
        color: Theme.textPrimary
        font.family: row.fontFamily
        font.pixelSize: row.figureSize
    }
    Text {
        id: line2D
        visible: row.kind === "holding" && !row.ext
        x: row._dX
        y: row._l2
        width: row.pctW
        height: row._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        readonly property var v: row.d ? (row.real ? row.d.totalPctReal : row.d.totalPct) : null
        text: row._num(line2D.v) ? F.pct(line2D.v) : ""
        color: row._tone(line2D.v)
        font.family: row.fontFamily
        font.pixelSize: row.figureSize
        font.bold: true
        GainFlash {
            objectName: "rowGainFlash"
            target: line2D
            strength: row.kind === "holding" ? row.flash : 0
            peak: row.flashPeak
            hPad: row.flashPad
        }
    }

    // The extended move: its % in the slot, the word just before its ink.
    Text {
        id: extPct
        objectName: "rowExtPct"
        visible: !!row.ext
        x: row._dX
        y: row._l2
        width: row.pctW
        height: row._lineH
        horizontalAlignment: Text.AlignRight
        verticalAlignment: Text.AlignVCenter
        text: row.ext && row._num(row.ext.changePct) ? F.pct(row.ext.changePct) : ""
        color: row.ext ? row._tone(row.ext.changePct) : Theme.textMuted
        font.family: row.fontFamily
        font.pixelSize: row.figureSize
        font.bold: true
    }
    Text {
        objectName: "rowExtWord"
        visible: !!row.ext
        x: Math.round(row._dX + row.pctW - Math.ceil(extPct.contentWidth) - 3 - width)
        y: row._l2
        width: Math.ceil(implicitWidth)
        height: row._lineH
        verticalAlignment: Text.AlignVCenter
        text: row.ext ? (row.ext.kind === "pre" ? "pre" : "post") : ""
        color: Theme.textFaint
        font.family: row.fontFamily
        font.pixelSize: row.figureSize - 2
    }

    // ---- the one pointer handler ------------------------------------------------------
    // The gain figure's rect: line 2's pct slot on a holding, line 1's money +
    // pct slots on a closed position.
    function overGain(px, py) {
        if (row.kind === "holding" && !row.ext)
            return px >= row._dX && px <= row._dX + row.pctW && py >= row._l2 && py <= row._l2 + row._lineH;
        if (row.kind === "closed")
            return px >= row._cX && px <= row._dX + row.pctW && py >= row._l1 && py <= row._l1 + row._lineH;
        return false;
    }
    property bool _gainHover: false
    on_GainHoverChanged: {
        if (row.service)
            row.service.realHover("row:" + row.kind + ":" + row.symbol, row._gainHover);
    }
    Component.onDestruction: {
        if (row._gainHover && row.service)
            row.service.realHover("row:" + row.kind + ":" + row.symbol, false);
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: mouse => row._gainHover = row.overGain(mouse.x, mouse.y)
        onContainsMouseChanged: {
            if (!area.containsMouse)
                row._gainHover = false;
        }
        onClicked: {
            if (!row.popup || !row.symbol)
                return;
            row.popup.openDetail(row.key, row.mapToItem(row.popup, row.width / 2, row.height / 2));
        }
    }
}
