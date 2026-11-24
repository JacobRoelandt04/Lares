pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "data/StocksFormat.js" as F

// =============================================================================
// StocksIndexStrip.qml -- the indices under the summary chart.
//
// Three cells rolling through the config's `indices` (RollingCells: one clock
// per cell, a fixed pool, a roll fades at the cell's edge). A pointer that
// RESTS on the strip for `hoverDwellMs` snaps the cells to the BIGGEST MOVERS
// of the moment and holds them there -- the order is taken once, at the snap,
// so the cells do not reshuffle under the pointer. A pointer that only flies
// over on its way somewhere does nothing. Leaving lets go
// after `releaseGraceMs`, and coming back within it keeps the snap, so a hand
// that slips off an edge does not start the cells rolling. A click opens the
// index's detail.
//
// ONE MouseArea over the strip does the hover and the click, and finds the
// cell by arithmetic: what a cell shows is the item RollingCells last handed
// it (`shownIndices`), so the delegates need no input of their own.
// `cellFor(sym)` is the link item of an index key: a plain Item on the cell.
// =============================================================================
Item {
    id: strip

    property var service: null
    property var popup: null
    property string fontFamily: "Inter"
    property int figureSize: 11
    property int count: 3
    property int cycleMs: 4000
    property int rollMs: 420
    property int staggerMs: 90
    // A rest this long snaps to the movers; a leave lets go this long after.
    property int hoverDwellMs: 400
    property int releaseGraceMs: 250

    readonly property var items: strip.service && strip.service.indices ? strip.service.indices : []
    readonly property real cellW: strip.width / strip.count
    readonly property real _lineH: Math.ceil(strip.figureSize * 1.4)
    TextMetrics {
        id: pctM
        font.family: strip.fontFamily
        font.pixelSize: strip.figureSize
        font.bold: true
        text: F.pctTemplate(8.88)
    }
    readonly property real _pctW: Math.ceil(pctM.advanceWidth)

    // What cell c shows now: the item RollingCells last pointed it at.
    function shownAt(c) {
        const idx = cells.shownIndices ? cells.shownIndices[c] : -1;
        return typeof idx === "number" && idx >= 0 ? strip.items[idx] || null : null;
    }

    // The movers, taken at the snap and held until the grace after a leave.
    property var _held: null
    readonly property bool hovered: area.containsMouse
    readonly property bool snapped: strip._held !== null
    onHoveredChanged: {
        if (strip.hovered) {
            releaseTimer.stop();
            if (strip._held === null)
                dwellTimer.restart();
        } else {
            dwellTimer.stop();
            if (strip._held !== null)
                releaseTimer.restart();
        }
    }
    Timer {
        id: dwellTimer
        interval: strip.hoverDwellMs
        onTriggered: {
            const m = strip.service && strip.service.moversOrder ? strip.service.moversOrder : [];
            if (strip.hovered && m.length > 0)
                strip._held = m.slice(0, strip.count);
        }
    }
    Timer {
        id: releaseTimer
        interval: strip.releaseGraceMs
        onTriggered: strip._held = null
    }

    RollingCells {
        id: cells
        anchors.fill: parent
        count: strip.count
        items: strip.items
        cycleMs: strip.cycleMs
        rollMs: strip.rollMs
        staggerMs: strip.staggerMs
        override: strip._held
        delegate: Component {
            Item {
                id: cellFace
                required property var item
                required property int cell
                readonly property var r: cellFace.item || null
                readonly property real pct: cellFace.r && isFinite(cellFace.r.changePct) ? cellFace.r.changePct : 0

                // Every child has a FIXED rect (slot widths, line heights): the
                // cells measure their delegates' childrenRect for the roll's
                // travel, and a width that followed another text's layout would make
                // that measure a binding loop.
                Text {
                    id: nameText
                    x: 8
                    y: Math.round((cellFace.height - 2 * strip._lineH - 1) / 2)
                    width: cellFace.width - 16 - strip._pctW - 6
                    height: strip._lineH
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: cellFace.r ? (cellFace.r.label || cellFace.r.symbol || "") : ""
                    color: Theme.textPrimary
                    font.family: strip.fontFamily
                    font.pixelSize: strip.figureSize
                    font.bold: true
                }
                Text {
                    x: cellFace.width - 8 - strip._pctW
                    y: nameText.y
                    width: strip._pctW
                    height: strip._lineH
                    horizontalAlignment: Text.AlignRight
                    verticalAlignment: Text.AlignVCenter
                    text: cellFace.r ? F.pct(cellFace.pct) : ""
                    color: cellFace.pct < 0 ? Theme.stockLoss : Theme.stockGain
                    font.family: strip.fontFamily
                    font.pixelSize: strip.figureSize
                    font.bold: true
                }
                Text {
                    x: 8
                    y: nameText.y + strip._lineH + 1
                    width: cellFace.width - 16
                    height: strip._lineH
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: cellFace.r && isFinite(cellFace.r.price) ? F.price(cellFace.r.price, cellFace.r.currency || "", cellFace.r.priceHint) : ""
                    color: Theme.textMuted
                    font.family: strip.fontFamily
                    font.pixelSize: strip.figureSize
                }
            }
        }
    }

    // Dividers between the cells, and a hover wash on the cell under the pointer.
    Repeater {
        model: Math.max(0, strip.count - 1)
        delegate: Rectangle {
            required property int index
            x: Math.round((index + 1) * strip.cellW)
            y: Math.round(strip.height * 0.2)
            width: 1
            height: Math.round(strip.height * 0.6)
            color: Theme.border
        }
    }
    Repeater {
        id: proxies
        model: strip.count
        delegate: Item {
            id: proxy
            required property int index
            x: Math.round(proxy.index * strip.cellW)
            y: 0
            width: Math.round((proxy.index + 1) * strip.cellW) - x
            height: strip.height
            property real hoverF: area.containsMouse && area.cellAt === proxy.index ? 1 : 0
            Behavior on hoverF {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                radius: 6
                color: Theme.panelSunk
                opacity: 0.6 * proxy.hoverF
            }
        }
    }

    function cellFor(sym) {
        for (let c = 0; c < strip.count; c++) {
            const it = strip.shownAt(c);
            if (it && it.symbol === sym)
                return proxies.itemAt(c);
        }
        return null;
    }

    MouseArea {
        id: area
        objectName: "indexStripArea"
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        readonly property int cellAt: area.containsMouse ? Math.max(0, Math.min(strip.count - 1, Math.floor(area.mouseX / strip.cellW))) : -1
        onClicked: mouse => {
            const c = Math.max(0, Math.min(strip.count - 1, Math.floor(mouse.x / strip.cellW)));
            const it = strip.shownAt(c);
            if (!it || !it.symbol || !strip.popup)
                return;
            const key = {
                symbol: it.symbol,
                from: "index"
            };
            const p = proxies.itemAt(c);
            strip.popup.openDetail(key, p.mapToItem(strip.popup, p.width / 2, p.height / 2));
        }
    }
}
