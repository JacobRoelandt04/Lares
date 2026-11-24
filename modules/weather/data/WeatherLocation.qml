pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../common/system"

// =============================================================================
// WeatherLocation.qml -- the machine's position through geoclue.
//
// Asked through geoclue's own command-line client, `where-am-i` (the geoclue
// package ships it beside the demo agent), in a Process whose output this file
// reads and whose errors it keeps: QtPositioning's geoclue2 plugin prints its
// D-Bus failures to the console itself --
// "qt.positioning.geoclue2: Unable to obtain the client: NoReply ..." whenever
// geoclue is slow to answer or tears down under a request -- where no QML can
// catch them, and the console stays free of warnings.
//
// While config.currentLocation.enabled, `where-am-i -t <fixTimeout> -a 8` runs
// and reports each location it gets as a block of lines (Latitude, Longitude,
// Accuracy, Altitude when known, ... Timestamp). A fix is ACCEPTED when its
// accuracy is within maxAccuracyM (an IP-only fix is tens of km and is
// refused); then the client is stopped and asked again every refixMinutes, so a
// laptop that moves is followed. With no agent (or no fix) the client simply
// runs out its timeout with nothing to say -- measured here, exit 0, no output
// -- and is asked again after retryMinutes. An accepted fix is NAMED after a
// saved location within nearSavedKm (haversine), else after KMI's cityName for
// it (the service sets `kmiCityName`), else "lat, lon" to two decimals.
//
// "NO FIX" IS A NORMAL ANSWER. geoclue answers nothing until an agent has registered for
// the user, and the demo agent (the shell's trial tool starts it; the deployment's exec-once
// will) ASKS -- "Allow 'where-am-i' to access your location information?" -- at every start,
// for a client its conf.d does not name: until that question is answered the client runs out
// its timeout in silence. So a silent client, a refused one and one that never exits are each
// a reason the popup shows (below), never an error: the place falls back to the hometown
// (WeatherService.place) and the client is asked again after retryMinutes. A client that does
// not exit by itself (a geoclue that hangs; a stub that ignores -t) is killed after
// fixTimeoutMs + graceMs by a watchdog -- without it the retry would wait for ever.
//
// FAILURE IS QUIET: a notification about geoclue failing is one nobody can act on. The shell's failed-units card
// tells "geoclue.service failed" -- geoclue is D-Bus activated by every where-am-i, and 202 of 860 starts in a week hung past
// systemd's 90 s start timeout (a Failed unit until the next start succeeded, then told again when it failed again) -- and an
// ask every five minutes for ever ends 455 times in the client's silence (no acceptable fix). So:
//   - a failure that is not the user's to fix is NOT SAID: the last fix stays (or the hometown stands in) and the popup's name tip
//     says why; the next ask comes after a BACKOFF -- retryMinutes, doubled per failure in a row up to maxRetryMinutes -- and a good
//     fix is refreshed every refixMinutes. Geoclue is woken ~10 times a day when nothing works, not ~120.
//   - a RESUME from suspend asks again once the network has had resumeDelayMs to come back (Sleep.watcher), quietly, from a fresh
//     backoff: a laptop that moved is wherever it is now, and an ask made in the first seconds finds no network.
//   - a failure the user CAN act on is said ONCE per session, never again (`noticeRaised`, `notice`): where-am-i is not installed
//     (said at once), or geoclue keeps refusing -- no agent, or its configuration -- `refusalsToNotice` times in a row. The service
//     hands it to the shell's notifier; this file posts nothing itself.
//
// `reason` says why `available` is false, in the words the popup shows:
//   "disabled in weather.jsonc"
//   "geoclue: where-am-i not found (<path>)"
//   "geoclue: waiting for a fix"
//   "geoclue: no fix (no agent, or its question is unanswered)"
//   "geoclue: no answer within N s"
//   "geoclue: refused (<the client's error line>)"
//   "geoclue: fix too coarse (N m > M m)"
//   "geoclue: <the client's own error line>"
// The agent is not started here: `lares start` starts it at login when shell.jsonc asks ("geoclueAgent": true).
// =============================================================================
Item {
    id: root

    property var config: null            // the WeatherConfig
    property string kmiCityName: ""
    property int fixTimeoutMs: 20000
    // geoclue's command-line client ("" = the one the geoclue package ships),
    // and how often it is asked again.
    property string client: ""
    readonly property string _client: root.client !== "" ? root.client : "/usr/lib/geoclue-2.0/demos/where-am-i"
    // The wait after a failed ask, doubled for each failure in a row (so the first retry is retryMinutes) up to maxRetryMinutes; the
    // wait after a good fix. A resume asks again after resumeDelayMs (the network is not up the moment the lid opens).
    property real retryMinutes: 5
    property real maxRetryMinutes: 120
    property real refixMinutes: 30
    property int resumeDelayMs: 12000
    // The suspend watcher a resume is heard from (the shell's one, a probe's own).
    property var sleepWatcher: Sleep.watcher
    // Refusals in a row before the user is told (a login races the agent's start: the first ones are not news).
    property int refusalsToNotice: 3
    // How long past -t a client may run before it is killed (see the header).
    property int graceMs: 5000
    // Named places besides the config's saved locations that a fix may take the name of (the hometown): [{ name, lat, lon }].
    property var extraPlaces: []

    readonly property bool active:
        !!(root.config && root.config.currentLocation && root.config.currentLocation.enabled)
    readonly property real maxAccuracyM:
        root.config && root.config.currentLocation ? root.config.currentLocation.maxAccuracyM : 3000
    readonly property real nearSavedKm:
        root.config && root.config.currentLocation ? root.config.currentLocation.nearSavedKm : 5

    property bool available: false
    property var lat: null
    property var lon: null
    property var elevation: null          // geoclue's altitude when it has one, else null
    property real accuracyM: 0
    property real fixAtMs: 0
    property string reason: "disabled in weather.jsonc"
    // The one thing the user can do something about, in words, said once per session: "" until then. `noticeRaised` carries it
    // (title, body) to whoever posts notifications.
    property string notice: ""
    signal noticeRaised(string title, string body)
    // Asks in a row that ended without an acceptable fix, and refusals among them (reset by a fix).
    property int failures: 0
    property int refusals: 0

    readonly property string name: {
        if (!root.available) return "Current location";
        const near = root.nearestSaved(root.lat, root.lon);
        if (near) return near.name;
        if (root.kmiCityName) return root.kmiCityName;
        return root.lat.toFixed(2) + ", " + root.lon.toFixed(2);
    }

    // The client. Started with a shell guard so a missing binary is an exit
    // code (127) rather than Quickshell's own "failed to start" line.
    Process {
        id: proc
        running: false
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => root._line(line)
        }
        stderr: StdioCollector { id: procErr }
    }
    Connections {
        target: proc
        function onExited(code) { root._exited(code, procErr.text); }
    }
    Timer {
        id: again
        onTriggered: root._ask()
    }
    // The client's own -t should end it; this is for the one that does not.
    property bool _timedOut: false
    Timer {
        id: watchdog
        interval: root.fixTimeoutMs + root.graceMs
        onTriggered: {
            if (proc.running) {
                root._timedOut = true;
                proc.running = false;
            }
        }
    }

    onActiveChanged: root._reset()
    Component.onCompleted: root._reset()

    Connections {
        target: root.sleepWatcher
        ignoreUnknownSignals: true
        function onResumed() { root._resumed(); }
    }
    // The machine woke: ask again once the network had a moment, from the base wait -- unless a fix is fresh or an ask runs.
    function _resumed() {
        if (!root.active || proc.running)
            return;
        if (root.available && Date.now() - root.fixAtMs < root.refixMinutes * 60000)
            return;
        root.failures = 0;
        again.interval = Math.max(1, root.resumeDelayMs);
        again.restart();
    }

    function _reset() {
        again.stop();
        watchdog.stop();
        root._timedOut = false;
        root.failures = 0;
        root.refusals = 0;
        proc.running = false;
        root.available = false;
        root.lat = null; root.lon = null; root.elevation = null;
        root.accuracyM = 0; root.fixAtMs = 0;
        if (!root.active) { root.reason = "disabled in weather.jsonc"; return; }
        root._ask();
    }

    property var _fix: ({})
    property bool _gotFix: false
    function _ask() {
        if (!root.active)
            return;
        again.stop();
        root._fix = ({});
        root._timedOut = false;
        root._gotFix = false;
        if (!root.available)
            root.reason = "geoclue: waiting for a fix";
        proc.command = ["sh", "-c", "[ -x \"$0\" ] || exit 127; exec \"$0\" -t \"$1\" -a 8",
                        root._client, String(Math.max(1, Math.round(root.fixTimeoutMs / 1000)))];
        proc.running = true;
        watchdog.restart();
    }

    // One line of where-am-i's report: "Latitude:    51.050000°" and so on; a
    // block ends with its Timestamp line.
    function _line(line) {
        const m = /^\s*(Latitude|Longitude|Accuracy|Altitude|Timestamp):\s*(-?[0-9.]+)?/.exec(line);
        if (!m)
            return;
        if (m[1] !== "Timestamp") {
            const v = parseFloat(m[2]);
            if (isFinite(v))
                root._fix[m[1]] = v;
            return;
        }
        root._take(root._fix);
        root._fix = ({});
    }

    function _take(f) {
        if (!root.active || typeof f.Latitude !== "number" || typeof f.Longitude !== "number")
            return;
        if (typeof f.Accuracy !== "number") {
            if (!root.available) root.reason = "geoclue: fix without an accuracy, refused";
            return;
        }
        if (f.Accuracy > root.maxAccuracyM) {
            if (!root.available)
                root.reason = "geoclue: fix too coarse (" + Math.round(f.Accuracy) + " m > " + Math.round(root.maxAccuracyM) + " m)";
            return;
        }
        root.lat = f.Latitude;
        root.lon = f.Longitude;
        root.elevation = typeof f.Altitude === "number" ? f.Altitude : null;
        root.accuracyM = f.Accuracy;
        root.fixAtMs = Date.now();
        root.reason = "";
        root._gotFix = true;
        root.available = true;
        // Got it: stop listening, ask again later.
        watchdog.stop();
        proc.running = false;
    }

    function _exited(code, err) {
        // A stop's exit can land after the next run has started (a reset).
        if (!root.active || proc.running)
            return;
        watchdog.stop();
        const first = err ? err.trim().split("\n")[0] : "";
        const secs = Math.max(1, Math.round(root.fixTimeoutMs / 1000));
        let refused = false, noAgent = false, missing = false;
        if (!root._gotFix) {
            if (root._timedOut) {
                if (!root.available) root.reason = "geoclue: no answer within " + secs + " s";
            } else if (code === 127) {
                missing = true;
                if (!root.available) root.reason = "geoclue: where-am-i not found (" + root._client + ")";
            } else if (first && /denied|disallow|not allowed|refus|no agent for/i.test(err)) {
                refused = true;
                noAgent = /no agent/i.test(err);
                if (!root.available) root.reason = "geoclue: refused (" + first + ")";
            } else if (first) {
                if (!root.available) root.reason = "geoclue: " + first;
            } else if (!root.available && root.reason.indexOf("geoclue: fix") !== 0) {
                // (a fix that came and was too coarse already said so)
                root.reason = "geoclue: no fix (no agent, or its question is unanswered)";
            }
        }
        root._timedOut = false;
        if (root._gotFix) {
            root.failures = 0;
            root.refusals = 0;
        } else {
            root.failures++;
            root.refusals = refused ? root.refusals + 1 : 0;
            if (missing)
                root._say("Weather: no current location",
                          "geoclue's where-am-i is not installed (" + root._client + "), so the weather stays at your hometown. Install the geoclue package, or switch currentLocation off in weather.jsonc.");
            else if (refused && root.refusals >= root.refusalsToNotice)
                root._say("Weather: geoclue keeps refusing",
                          noAgent ? "No geoclue agent is running for your session, so the weather cannot learn where you are and stays at your hometown. Start geoclue's agent (shell.jsonc: geoclueAgent), or switch currentLocation off in weather.jsonc."
                                  : "geoclue refuses the weather's location request (see /etc/geoclue/conf.d), so it stays at your hometown. Allow where-am-i there, or switch currentLocation off in weather.jsonc.");
        }
        again.interval = root.nextAskMs(root._gotFix, root.failures);
        again.restart();
    }

    // The wait before the next ask: after a fix, refixMinutes; after failures in a row, retryMinutes doubled per failure up to
    // maxRetryMinutes.
    function nextAskMs(gotFix, failures) {
        if (gotFix)
            return Math.max(1000, root.refixMinutes * 60000);
        const n = Math.max(1, failures);
        return Math.max(1000, Math.min(root.maxRetryMinutes, root.retryMinutes * Math.pow(2, n - 1)) * 60000);
    }

    // At most once per session, and only for what the user can act on.
    function _say(title, body) {
        if (root.notice !== "")
            return;
        root.notice = body;
        root.noticeRaised(title, body);
    }

    // Great-circle distance in km.
    function distanceKm(lat1, lon1, lat2, lon2) {
        const r = Math.PI / 180;
        const dLat = (lat2 - lat1) * r, dLon = (lon2 - lon1) * r;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
            + Math.cos(lat1 * r) * Math.cos(lat2 * r) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        return 2 * 6371.0088 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
    }

    // The saved location (or extra place: the hometown) nearest to (lat, lon) within nearSavedKm, or null.
    function nearestSaved(lat, lon) {
        const saved = root.config && Array.isArray(root.config.locations) ? root.config.locations : [];
        const list = saved.concat(Array.isArray(root.extraPlaces) ? root.extraPlaces : []);
        let best = null, bestKm = root.nearSavedKm;
        for (let i = 0; i < list.length; i++) {
            const l = list[i];
            if (typeof l.lat !== "number" || typeof l.lon !== "number") continue;
            const km = root.distanceKm(lat, lon, l.lat, l.lon);
            if (km <= bestKm) { best = l; bestKm = km; }
        }
        return best;
    }
}
