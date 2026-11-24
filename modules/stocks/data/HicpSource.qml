pragma ComponentBehavior: Bound

import QtQuick
import "Markets.js" as Markets

// =============================================================================
// HicpSource.qml -- Eurostat's monthly HICP index (prc_hicp_minr, 2015 = 100)
// for one country, one lane. cb(error, { "YYYY-MM": value }).
// =============================================================================
Item {
    id: root

    property string curl: "curl"
    readonly property bool busy: lane.busy

    function hicp(geo, cb) {
        const url = Markets.hicpUrl(geo);
        lane.get("hicp|" + geo, url, function (e, text) {
            const m = e ? {} : Markets.parseHicp(text);
            cb(e || (Object.keys(m).length === 0 ? "no HICP series for " + geo : ""), m);
        }, false);
    }
    function cancel() { lane.cancel(); }

    StocksFetch { id: lane; curl: root.curl }
}
