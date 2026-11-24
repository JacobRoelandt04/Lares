pragma ComponentBehavior: Bound

import QtQuick
import "Markets.js" as Markets

// =============================================================================
// CnbcSource.qml -- the detail's market cap / P/E / EPS / yield / beta /
// average volume from CNBC's restQuote, one lane. cb(error, { cnbcSym: row })
// in CNBC's own strings (Markets.parseCnbc); a symbol CNBC does not know is a
// row of nulls.
// =============================================================================
Item {
    id: root

    property string curl: "curl"
    readonly property bool busy: lane.busy
    signal rateLimited()

    function quote(cnbcSymbols, cb) {
        const url = Markets.cnbcUrl(cnbcSymbols);
        lane.get("cnbc|" + url, url, function (e, text) {
            cb(e, e ? {} : Markets.parseCnbc(text));
        }, false);
    }
    function cancel() { lane.cancel(); }

    StocksFetch { id: lane; curl: root.curl; onRateLimited: root.rateLimited() }
}
