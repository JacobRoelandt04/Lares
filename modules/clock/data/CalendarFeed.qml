pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/system"
import "ical.js" as ICal
import "rrule.js" as RRule

// =============================================================================
// CalendarFeed.qml
//
// One network-backed calendar. Given a {id, name, color, url} entry from
// CalendarConfig, fetches the .ics, caches it to disk, parses it, expands
// recurring events, and publishes the result as `events`.
//
// Lifecycle:
//   - On construction: FileView auto-preloads the disk cache (if present) so
//     the UI paints with stale data instantly.
//   - refresh() fires curl via Process; on success the response is parsed AND
//     written back through the same FileView (atomic replace).
//   - A Timer drives periodic refresh — interval from entry.pollIntervalMs. It is a monotonic
//     Timer and stands still while the machine is suspended, so a RESUME (Sleep.watcher) asks
//     again a few seconds after (the network is not up the instant the machine is) and the poll
//     counts from there.
//
// Failures are contained: the `events` array holds whatever the last
// successful parse produced, `lastError` carries the reason.
// =============================================================================
Item {
    id: root

    // --- Inputs ---
    property var calendarEntry: null

    // Expansion window: how far out to materialise recurring occurrences.
    // Default: ~1 year back to ~1 year forward. Wide enough that everyday
    // navigation never falls off the edge; tighten later when we add dynamic
    // re-expansion on scroll to preserve memory.
    property date expandStart: {
        let n = new Date();
        return new Date(n.getFullYear() - 1, n.getMonth(), 1);
    }
    property date expandEnd: {
        let n = new Date();
        return new Date(n.getFullYear() + 1, n.getMonth() + 1, 0);
    }

    // --- Outputs ---
    property var events: []
    property bool loading: false
    property string lastError: ""
    property double lastFetchEpochMs: 0
    // How long after a resume from suspend the feed asks again.
    property int resumeFetchMs: 4000

    signal fetched()

    readonly property string _cacheDir:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
        + "/lares/calendars"
    readonly property string _cachePath:
        calendarEntry ? (_cacheDir + "/" + calendarEntry.id + ".ics") : ""

    // One-shot mkdir at component completion; cheap and idempotent.
    Component.onCompleted: {
        Quickshell.execDetached(["mkdir", "-p", _cacheDir]);
    }

    // --- Disk cache (read + write through same FileView) ---
    FileView {
        id: cacheView
        path: root._cachePath
        preload: true
        watchChanges: false   // we're the only writer
        atomicWrites: true
        printErrors: false

        // Initial (stale) render from disk. Real fetch will overwrite.
        onLoaded: if (root.events.length === 0) root._parseRaw(text())
        onTextChanged: if (root.events.length === 0) root._parseRaw(text())
    }

    // --- Network fetch ---
    Process {
        id: fetchProc
        running: false
        stdout: StdioCollector {
            id: fetchStdout
            onStreamFinished: {
                if (!text || text.length === 0) {
                    root.lastError = "empty response";
                    root.loading = false;
                    root.fetched();
                    return;
                }
                root._parseRaw(text);
                cacheView.setText(text);
                root.lastFetchEpochMs = Date.now();
                root.loading = false;
                root.lastError = "";
                root.fetched();
            }
        }
        onExited: (code, status) => {
            if (code !== 0) {
                root.lastError = "curl exit " + code;
                root.loading = false;
                root.fetched();
            }
        }
    }

    function refresh() {
        if (!calendarEntry || !calendarEntry.url) return;
        if (fetchProc.running) return;
        root.loading = true;
        // -L follows redirects. Google Apps Script web apps (and other
        // indirected ICS sources such as TimeEdit via a Scripts proxy)
        // respond with a 302 to a googleusercontent.com backing URL;
        // without -L, curl returns the HTML "Moved Temporarily" page,
        // which our ICS parser quietly rejects as empty.
        fetchProc.command = ["curl", "-sSfL", "--max-time", "20",
                             "--compressed", calendarEntry.url];
        fetchProc.running = true;
    }

    // Cached hash of the last text we parsed, to short-circuit redundant
    // parse work. Cache load + curl completion both feed the same ICS text
    // in most refreshes; parsing + RRULE-expanding a 20-90 KB feed takes
    // 30-80 ms on the main thread, and when a parse lands mid-animation
    // the whole slide-in stutters. Dedup wins frames.
    property string _lastParsedText: ""

    // --- Parse + expand helper ---
    function _parseRaw(txt) {
        if (!txt || txt.length === 0) return;
        if (txt === _lastParsedText) return;
        _lastParsedText = txt;
        try {
            let ical = ICal.parseIcs(txt);
            let rangeStart = root.expandStart;
            let rangeEnd = root.expandEnd;
            let out = [];
            for (let i = 0; i < ical.events.length; i++) {
                let ev = ical.events[i];
                ev.calendarId = calendarEntry ? calendarEntry.id : "";
                let occs = RRule.expandRRule(ev, rangeStart, rangeEnd);
                for (let j = 0; j < occs.length; j++) out.push(occs[j]);
            }
            root.events = out;
        } catch (e) {
            root.lastError = "parse error: " + e;
            console.warn("[CalendarFeed] parse error:", e);
        }
    }

    // --- Polling timer ---
    Timer {
        id: poller
        interval: root.calendarEntry && root.calendarEntry.pollIntervalMs
            ? root.calendarEntry.pollIntervalMs : 900000
        running: !!root.calendarEntry && !!root.calendarEntry.url
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Connections {
        target: Sleep.watcher
        ignoreUnknownSignals: true
        function onResumed() {
            resumeFetch.restart();
        }
    }
    Timer {
        id: resumeFetch
        interval: root.resumeFetchMs
        onTriggered: if (poller.running) poller.restart()
    }

    // Re-expand locally if window changes without refetching.
    onExpandStartChanged: if (cacheView.text()) _parseRaw(cacheView.text())
    onExpandEndChanged:   if (cacheView.text()) _parseRaw(cacheView.text())
}
