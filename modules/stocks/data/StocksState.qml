pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// StocksState.qml -- what the shell remembers between runs (never stocks.jsonc).
//
// $XDG_STATE_HOME/lares/stocks/state.json (overridable: `statePath`):
//   { version: 1, watchlist: [sym], sort, sortAscending, tab, summaryRange,
//     detailRange, closedExpanded, alertLatches: { key: latch } }
//
// A file without `sortAscending` takes the key's own direction (name A-Z,
// the figures largest first).
//
// Read once, synchronously, at completion (TimerService: blockLoading, no
// waiting for onLoaded). Every change is written 300 ms after the last one,
// atomically, into a directory made first; a write equal to the last one we
// made is skipped (the self-write guard). `persist: false` keeps it in memory.
// =============================================================================
Item {
    id: root

    property bool persist: true
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/stocks/state.json"

    readonly property var sortKeys: ["value", "day", "total", "name"]
    readonly property var tabs: ["holdings", "watchlist"]
    readonly property var summaryRanges: ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "ALL"]
    readonly property var detailRanges: ["1D", "5D", "1M", "6M", "YTD", "1Y", "5Y", "MAX"]

    property var watchlist: []
    property string sortKey: "value"
    property bool sortAscending: false
    property string tab: "holdings"
    property string summaryRange: "1M"
    property string detailRange: "1D"
    property bool closedExpanded: false
    property var alertLatches: ({})

    // True once the file has been read (or found missing).
    readonly property bool loaded: root._loaded

    onWatchlistChanged: root._save()
    onSortKeyChanged: root._save()
    onSortAscendingChanged: root._save()
    onTabChanged: root._save()
    onSummaryRangeChanged: root._save()
    onDetailRangeChanged: root._save()
    onClosedExpandedChanged: root._save()
    onAlertLatchesChanged: root._save()

    function flush() {
        if (!root.persist || !root._loaded) return;
        if (!root._dirReady) { writeTimer.restart(); return; }
        writeTimer.stop();
        const txt = root._serialize();
        if (txt === root._selfWrite) return;
        root._selfWrite = txt;
        file.setText(txt);
    }

    // ---- Private -------------------------------------------------------------
    property bool _loaded: false
    property bool _ingesting: false
    property bool _dirReady: false
    property string _selfWrite: ""

    function _save() {
        if (!root.persist || root._ingesting || !root._loaded) return;
        writeTimer.restart();
    }

    function _serialize() {
        return JSON.stringify({
            version: 1,
            watchlist: root.watchlist,
            sort: root.sortKey,
            sortAscending: root.sortAscending,
            tab: root.tab,
            summaryRange: root.summaryRange,
            detailRange: root.detailRange,
            closedExpanded: root.closedExpanded,
            alertLatches: root.alertLatches
        }, null, 1) + "\n";
    }

    function _ingest(txt) {
        if (!txt || txt.trim().length === 0) return;
        let o = null;
        try { o = JSON.parse(txt); } catch (e) { return; }
        if (!o || typeof o !== "object" || Array.isArray(o)) return;
        root._ingesting = true;
        if (Array.isArray(o.watchlist))
            root.watchlist = o.watchlist.filter(function (s) { return typeof s === "string" && s.length > 0; });
        if (root.sortKeys.indexOf(o.sort) >= 0) root.sortKey = o.sort;
        root.sortAscending = typeof o.sortAscending === "boolean" ? o.sortAscending : root.sortKey === "name";
        if (root.tabs.indexOf(o.tab) >= 0) root.tab = o.tab;
        if (root.summaryRanges.indexOf(o.summaryRange) >= 0) root.summaryRange = o.summaryRange;
        if (root.detailRanges.indexOf(o.detailRange) >= 0) root.detailRange = o.detailRange;
        if (typeof o.closedExpanded === "boolean") root.closedExpanded = o.closedExpanded;
        if (o.alertLatches && typeof o.alertLatches === "object" && !Array.isArray(o.alertLatches))
            root.alertLatches = o.alertLatches;
        root._ingesting = false;
        root._selfWrite = root._serialize();
    }

    Timer {
        id: writeTimer
        interval: 300
        onTriggered: root.flush()
    }

    FileView {
        id: file
        path: root.persist ? root.statePath : ""
        blockLoading: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", root.statePath.substring(0, root.statePath.lastIndexOf("/"))]
        running: false
    }
    Connections {
        target: mkdir
        function onExited() { root._dirReady = true; }
    }

    Component.onCompleted: {
        if (root.persist) root._ingest(file.text());
        root._loaded = true;
        if (root.persist) mkdir.running = true;
        else root._dirReady = true;
    }
}
