pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "WeatherModel.js" as WM
import "PlaceMerge.js" as PM

// =============================================================================
// WeatherService.qml -- the one object the weather popup takes.
//
// Owns the config (WeatherConfig), the position (WeatherLocation), the two
// sources (OpenMeteoSource, KmiSource) and the per-location caches, and hands
// the popup ONE `model` built by WeatherModel.normalise. It lives OUTSIDE the
// popup: thePopup's host recreates its content, and a fetch cadence must not
// restart with it.
//
// Stale-first. Selecting a place opens its caches
// ($XDG_CACHE_HOME/lares/weather/<slug>-forecast.json, -aq.json; KMI keeps
// kmi-<lat>_<lon>.json/.svg itself), paints whatever they hold, and schedules
// each fetch for the moment the cache turns refreshMinutes old -- now when it
// is missing or already older, later when a restart finds it fresh. `stale`
// is "what is painted is older than refreshMinutes.forecast"; `offline` is
// "the last forecast fetch failed" (the cache stays up). refresh() fetches
// everything now.
//
// Clock. A 60 s tick rebuilds the model so `current` follows the wall clock
// (normalise is pure JS, a few ms), recomputes `stale`, and compares Date.now()
// with the tick it expected: a jump of more than five minutes (suspend, a
// corrected clock) refreshes, because every cadence timer slept through it.
// Europe/Brussels' date is computed here once per tick (EU DST rule; nothing
// reads the machine's zone) and handed to both sources as `todayKey`: KMI's
// key is md5'd over it, IRCEL's WMS is asked for it and the two days after.
//
// Locations. `locations` = "current location" first when
// config.currentLocation.enabled (its name is the fix's, "Current location"
// before one lands), then config.locations. While index 0 has no fix the
// HOMETOWN is fetched instead and model.location says so (source "home",
// reason from WeatherLocation): the saved location marked "home": true, else
// the town the shell learned (WeatherHome: the first accepted fix names it),
// else -- nobody has told it where home is yet -- the config's default
// location (source "config"). A fix that does not come ("no fix" is a normal
// answer: the geoclue agent asks per client) leaves the hometown up; a fix far
// from it is followed and never replaces it. `popupOpen` makes KMI
// refetch every refreshMinutes.nowcastWhileOpen (the radar sequence moves).
//
// FileViews: one per file, a static path, created for the place and destroyed
// on switch, never repointed (CLAUDE.md).
// =============================================================================
Item {
    id: root

    // ---- §2 interface --------------------------------------------------------
    property var model: null
    readonly property bool loading: openMeteo.loading || kmi.loading
    property bool offline: false
    property string lastError: ""
    property real fetchedAtMs: 0
    property var locations: []
    property int locationIndex: 0
    readonly property var config: cfg
    property bool popupOpen: false
    signal updated()

    function refresh() {
        if (root.place === null) return;
        openMeteo.refresh();
        kmi.refresh();
    }
    function selectLocation(i) {
        const n = root.locations.length;
        if (n === 0) return;
        root.locationIndex = Math.max(0, Math.min(n - 1, Math.floor(i)));
    }

    // Also written into model.stale: painted data older than refreshMinutes.forecast.
    property bool stale: false

    readonly property string cacheDir: cfg.cacheDir

    // ---- Beyond the interface: what a host can show to check the data -------
    // The exact requests (open one in a browser to see the raw answer the
    // model was built from), where the config was read and what it said.
    readonly property string forecastUrl: openMeteo.forecastUrl
    readonly property string airQualityUrl: openMeteo.airQualityUrl
    readonly property string configPath: cfg.configPath
    readonly property string configError: cfg.lastError
    readonly property string modelName: cfg.sources.openMeteo.model
    // geoclue's client for the current location ("" = the packaged
    // where-am-i); a probe points it at a stub.
    property string locationClient: ""
    // How long the client may run before it is asked again (a probe shortens it).
    property int locationFixTimeoutMs: 20000
    property int locationGraceMs: 5000
    // The ONE thing about the current location the user can act on (geoclue's client missing, or refusing again and again), said
    // once per session (WeatherLocation): `locationNotice(title, body)`, and posted through `notifier` (a DesktopNotifier the shell
    // hands in; none = nothing is posted). Every other failure of geoclue is quiet.
    property var notifier: null
    signal locationNotice(string title, string body)
    // The hometown now: the marked saved location, else the learned one, else null (the default location stands in).
    readonly property var homePlace: cfg.homeLocation || home.record

    // ---- Parts -------------------------------------------------------------
    WeatherConfig {
        id: cfg
        onConfigChanged: {
            root._rebuildLocations();
            root._rebuild();
        }
    }

    WeatherHome {
        id: home
        path: cfg.homePath
        onUpdated: {
            root._rebuildLocations();
            root._rebuild();
        }
    }

    WeatherLocation {
        id: geo
        config: cfg
        client: root.locationClient
        fixTimeoutMs: root.locationFixTimeoutMs
        graceMs: root.locationGraceMs
        extraPlaces: root.homePlace ? [root.homePlace] : []
        // KMI names the fix only when the fix is what is being fetched (`_nameFix` keeps that answer: the fix's municipality
        // is remembered by the fix's position). Not read off `place`: the place is built from this object's name, and a name
        // that reads the place is a binding loop (as soon as a fix is not near a saved
        // location) -- nor off `kmi` directly: a place MERGED into a saved one (below) is fetched at the saved place's
        // position, and the fix's name must not depend on which place is served.
        kmiCityName: cfg.currentLocation.enabled && geo.available ? root._cityOfFix(geo.lat, geo.lon) : ""
        onAvailableChanged: {
            root._rebuildLocations();
            // Deferred: learning writes the hometown, which `place` reads, and this runs inside the very change that
            // `place` is being rebuilt for -- written here it is a binding loop on `place`.
            Qt.callLater(root._learnHome);
        }
        onNameChanged: root._rebuildLocations()
        onReasonChanged: root._rebuild()
        onNoticeRaised: (title, body) => {
            root.locationNotice(title, body);
            if (root.notifier)
                root.notifier.notify("weather-location", { title: title, body: body, urgency: "low", timeoutMs: 15000 });
        }
    }

    // KMI's municipality for the fix, learned while the fix itself was the place served, kept by the fix's position: { lat, lon,
    // city } or null. A fix that moves on by more than 3 km forgets it (and is named again when it is served).
    property var _fixCity: null
    function _cityOfFix(lat, lon) {
        const f = root._fixCity;
        return f && typeof lat === "number" && typeof lon === "number" && geo.distanceKm(lat, lon, f.lat, f.lon) <= 3 ? f.city : "";
    }
    function _nameFix() {
        if (!geo.available || kmi.cityName === "")
            return;
        if (Math.abs(Number(kmi.lat) - geo.lat) > 1e-6 || Math.abs(Number(kmi.lon) - geo.lon) > 1e-6)
            return;
        const f = root._fixCity;
        if (!f || f.city !== kmi.cityName || f.lat !== geo.lat || f.lon !== geo.lon)
            root._fixCity = { lat: geo.lat, lon: geo.lon, city: kmi.cityName };
    }

    // ONE PLACE ONCE (feedback/weather.md, "Filter out duplicate locations"). The current-location slot (index 0) stands for the
    // fix or, without one, the hometown. When its name is the municipality of a SAVED location the slot is that saved entry:
    // the list the link cycles holds it once, at the head (where "current" always was), and "here" says a fix put it there.
    // The configured entry is the one kept -- its coordinates, its cache, its name -- never the live one.
    readonly property string _slotName: !cfg.currentLocation.enabled ? "" : (geo.available ? geo.name : (root.homePlace ? root.homePlace.name : ""))
    readonly property int _mergeIdx: PM.mergeIndex(root._slotName, cfg.locations)
    on_MergeIdxChanged: root._rebuildLocations()

    // THE FIRST ACCEPTED FIX NAMES THE HOMETOWN (unless the config marks one): stored once, named after a saved
    // location it is near, else "lat, lon" until KMI has answered for the fix (_nameHome). KMI is not read here: this
    // runs in the fix's change handler, before the place -- and so KMI's position -- has followed it.
    function _learnHome() {
        if (!geo.available || cfg.homeLocation !== null || home.record !== null || !home.settled)
            return;
        const near = geo.nearestSaved(geo.lat, geo.lon);
        home.learn(near ? near.name : geo.lat.toFixed(2) + ", " + geo.lon.toFixed(2),
                   geo.lat, geo.lon, geo.elevation, near ? "saved" : "coords");
    }
    // KMI's name for the town, once its answer is for the position the town was learned at.
    function _nameHome() {
        const r = home.record;
        const f = kmi.forecasts;
        const city = f && typeof f.cityName === "string" ? f.cityName : "";
        // Only KMI's answer for the position the town was learned at: the fix is being served (the service moves KMI's
        // latitude and longitude one after the other, so a half-moved position is no answer) and KMI stands on it.
        if (r === null || r.naming !== "coords" || !geo.available || city === ""
                || Math.abs(Number(kmi.lat) - r.lat) > 1e-6 || Math.abs(Number(kmi.lon) - r.lon) > 1e-6)
            return;
        home.rename(city);
    }

    OpenMeteoSource {
        id: openMeteo
        model: cfg.sources.openMeteo.model
        aqiIndex: cfg.aqiIndex
        todayKey: root.todayKey
        forecastEveryMs: cfg.refreshMinutes.forecast * 60000
        airQualityEveryMs: cfg.refreshMinutes.airQuality * 60000
        onFetched: kind => root._onFetched(kind)
        onFailed: (kind, error) => root._onFailed(kind, error)
    }

    KmiSource {
        id: kmi
        wanted: cfg.sources.kmi.enabled
        active: root._dirReady
        everyMs: cfg.refreshMinutes.kmi * 60000
        todayKey: root.todayKey
        onForecastsChanged: {
            root._dataSerial++;
            root._rebuild();
            Qt.callLater(root._nameHome);       // deferred for the same reason as _learnHome
            Qt.callLater(root._nameFix);
        }
        onPollenSvgChanged: root._rebuild()
        onFailed: error => { root.lastError = error; root._rebuild(); }
    }

    // ---- The place being served ----------------------------------------------
    // null until the config and the cache directory are ready; while the only
    // entries are queries still resolving, null too (no Brussels fetch that
    // the answer would replace seconds later).
    readonly property var place: {
        if (!cfg.ready || !root._dirReady || !home.settled || cfg.homePending) return null;
        const cur = cfg.currentLocation.enabled;
        const saved = cfg.locations;
        if (saved.length === 0 && cfg.resolving) return null;
        const dflt = saved[cfg.defaultIndex] || saved[0] || cfg.defaultLocation;
        // Where the current location stands in while it has no fix: the hometown, else the default.
        const away = root.homePlace || dflt;
        const merged = cur ? root._mergeIdx : -1;
        if (root.locationIndex === 0 && merged >= 0) {
            const m = saved[merged];
            return { name: m.name, lat: m.lat, lon: m.lon, elevation: m.elevation, here: geo.available,
                     source: geo.available || !root.homePlace ? "config" : "home", reason: geo.available ? "" : geo.reason,
                     slug: root.slugOf(m.name) };
        }
        if (root.locationIndex === 0 && cur) {
            if (geo.available)
                return { name: geo.name, lat: geo.lat, lon: geo.lon, elevation: geo.elevation,
                         source: "geoclue", reason: "", slug: root.slugAt("current", geo.lat, geo.lon) };
            return { name: away.name, lat: away.lat, lon: away.lon, elevation: away.elevation,
                     source: root.homePlace ? "home" : "config", reason: geo.reason,
                     slug: root.homePlace ? root.slugAt("home", away.lat, away.lon) : root.slugOf(away.name) };
        }
        const l = root._others(saved, merged)[root.locationIndex - (cur ? 1 : 0)] || (cfg.homeLocation || dflt);
        return { name: l.name, lat: l.lat, lon: l.lon, elevation: l.elevation,
                 source: "config", reason: "", slug: root.slugOf(l.name) };
    }
    readonly property string placeKey:
        root.place === null ? "" : root.place.slug + "@" + root.place.lat + "," + root.place.lon + "," + root.place.elevation
    // Deferred: activating resets KMI, whose city names the current location, which is what `place` is built from --
    // run inside the change that `place` is being rebuilt for, that is a binding loop on `place` (as soon as
    // a fix is not near a saved location). Coalesced: a burst of changes activates once.
    onPlaceKeyChanged: Qt.callLater(root._activate)

    // A cache slug for a place that has no fixed name (the fix, the hometown): its position to two decimals, so a
    // cache written at one place is never painted for another -- and a rename of the hometown does not refetch.
    function slugAt(kind, lat, lon) {
        return kind + "-" + Number(lat).toFixed(2) + "_" + Number(lon).toFixed(2);
    }
    function slugOf(name) {
        const s = String(name || "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
        return s === "" ? "place" : s;
    }

    // The saved places the link cycles after the slot: all of them, but the one the slot has taken in.
    function _others(saved, merged) {
        return merged < 0 ? saved : saved.filter((l, i) => i !== merged);
    }

    function _rebuildLocations() {
        const out = [];
        const saved = cfg.locations;
        const merged = cfg.currentLocation.enabled ? root._mergeIdx : -1;
        if (merged >= 0) {
            const m = saved[merged];
            out.push({ name: m.name, lat: m.lat, lon: m.lon, elevation: m.elevation, current: true, here: geo.available, saved: merged });
        } else if (cfg.currentLocation.enabled) {
            out.push({ name: geo.available || !root.homePlace ? geo.name : root.homePlace.name,
                       lat: geo.available ? geo.lat : (root.homePlace ? root.homePlace.lat : null),
                       lon: geo.available ? geo.lon : (root.homePlace ? root.homePlace.lon : null),
                       elevation: geo.available ? geo.elevation : (root.homePlace ? root.homePlace.elevation : null),
                       current: true, here: geo.available, saved: -1 });
        }
        for (let i = 0; i < saved.length; i++) {
            if (i !== merged)
                out.push({ name: saved[i].name, lat: saved[i].lat, lon: saved[i].lon, elevation: saved[i].elevation, current: false, here: false, saved: i });
        }
        // The selection stays on what it was on when the list changes shape (a place merged into the slot or let out of it):
        // a saved place by its place in the config, the slot as the slot.
        const prev = root.locations[root.locationIndex];
        root.locations = out;
        let idx = root.locationIndex;
        if (prev && !prev.current) {
            const f = out.findIndex(e => !e.current && e.saved === prev.saved);
            if (f >= 0) idx = f;
        }
        root.locationIndex = idx >= out.length ? 0 : idx;
    }

    // ---- Caches (forecast, air quality) --------------------------------------
    property int _gen: 0
    property bool _dirReady: false
    property var _forecast: null
    property var _aq: null
    property real _forecastSavedMs: 0
    property real _aqSavedMs: 0
    property var _fcView: null
    property var _aqView: null
    // Counts the arrivals of DATA (a cache read, a fetch, a KMI bundle) -- not the clock's rebuilds. The model carries it as
    // `dataSerial`, and the popup's cards morph from the picture on screen to the new data when it moves while the place stays
    // (otherwise the fetch that lands after a place's cache was shown would be a transition followed by a snap to the new data).
    property int _dataSerial: 0

    Component {
        id: cacheComp
        FileView {
            id: cv
            property int gen: 0
            property string kind: ""
            preload: true
            watchChanges: false
            atomicWrites: true
            printErrors: false
            onLoaded: root._cacheLoaded(cv, text())
            onLoadFailed: root._cacheMissing(cv)
        }
    }

    // Connections handler rather than inline onExited: qmllint cannot see
    // QProcess::ExitStatus and warns on every inline one (Theme.qml).
    Process {
        id: mkdirProc
        running: false
        command: ["mkdir", "-p", root.cacheDir]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
    Connections {
        target: mkdirProc
        function onExited() { root._dirReady = true; }
    }

    Component.onCompleted: {
        root.todayKey = root.brusselsDateKey(Date.now());
        root._expectedTickMs = Date.now() + tick.interval;
        mkdirProc.running = true;
    }

    // THE PICTURE OF THE PLACE BEING LEFT STAYS UP until the new place's cache has answered. Switching places clears the
    // forecast, and a model built from nothing is null: the popup takes that for "nothing to show" and draws a frame or two
    // of bare card (the hero's backdrop gone, its content fading out, the skeletons in) before the cache lands. The cache is a local read, a few milliseconds: hold the
    // old model for that long, and swap it for the new one in one step. A place with NO cache is a real wait (the fetch):
    // its missing cache ends the hold and the skeleton shows. `_holdMs` is the backstop for a cache that
    // answers neither way.
    property bool _switching: false
    property int _holdMs: 1000
    Timer {
        id: holdTimer
        interval: root._holdMs
        onTriggered: root._endSwitch()
    }
    function _endSwitch() {
        holdTimer.stop();
        if (!root._switching) return;
        root._switching = false;
        root._rebuild();
    }

    // The place `_activate` last set up: a change of the list's shape that leaves the place where it was (a saved place merged into
    // the slot, the selection following it) is no reason to clear the caches and fetch again.
    property string _activeKey: "<none>"
    function _activate() {
        if (root.placeKey === root._activeKey)
            return;
        root._activeKey = root.placeKey;
        // Before anything is cleared: only a picture that exists can be held.
        root._switching = root.place !== null && root.model !== null;
        if (root._switching) holdTimer.restart(); else holdTimer.stop();
        root._gen++;
        openMeteo.stop();
        if (root._fcView) { root._fcView.destroy(); root._fcView = null; }
        if (root._aqView) { root._aqView.destroy(); root._aqView = null; }
        root._forecast = null; root._aq = null;
        root._forecastSavedMs = 0; root._aqSavedMs = 0;
        root.fetchedAtMs = 0; root.stale = false; root.offline = false;
        const p = root.place;
        if (p === null) { root._rebuild(); return; }
        openMeteo.lat = p.lat; openMeteo.lon = p.lon; openMeteo.elevation = p.elevation;
        kmi.lat = p.lat; kmi.lon = p.lon;
        root._fcView = cacheComp.createObject(root, { path: root.cacheDir + "/" + p.slug + "-forecast.json", kind: "forecast", gen: root._gen });
        root._aqView = cacheComp.createObject(root, { path: root.cacheDir + "/" + p.slug + "-aq.json", kind: "aq", gen: root._gen });
        root._rebuild();
    }

    function _cacheLoaded(cv, txt) {
        if (cv.gen !== root._gen) return;
        let obj = null;
        try { obj = JSON.parse(txt); } catch (e) { obj = null; }
        if (!obj || typeof obj.savedAtMs !== "number" || !obj.data) { root._cacheMissing(cv); return; }
        const now = Date.now();
        if (cv.kind === "forecast") {
            root._forecast = obj.data;
            root._forecastSavedMs = obj.savedAtMs;
            root.fetchedAtMs = obj.savedAtMs;
            openMeteo.scheduleForecast(obj.savedAtMs + openMeteo.forecastEveryMs - now);
        } else {
            root._aq = obj.data;
            root._aqSavedMs = obj.savedAtMs;
            openMeteo.scheduleAirQuality(obj.savedAtMs + openMeteo.airQualityEveryMs - now);
        }
        if (cv.kind === "forecast") root._switching = false;
        root._dataSerial++;
        root._recomputeStale();
        root._rebuild();
    }

    function _cacheMissing(cv) {
        if (cv.gen !== root._gen) return;
        if (cv.kind === "forecast") {
            openMeteo.scheduleForecast(0);
            root._endSwitch();
        } else openMeteo.scheduleAirQuality(0);
    }

    function _onFetched(kind) {
        const now = Date.now();
        if (kind === "forecast") {
            root._forecast = openMeteo.forecast;
            root._forecastSavedMs = now;
            root.fetchedAtMs = now;
            root.offline = false;
            root.lastError = "";
            if (root._fcView) root._fcView.setText(JSON.stringify({ savedAtMs: now, data: root._forecast }) + "\n");
        } else {
            root._aq = openMeteo.airQuality;
            root._aqSavedMs = now;
            if (root._aqView) root._aqView.setText(JSON.stringify({ savedAtMs: now, data: root._aq }) + "\n");
        }
        root._dataSerial++;
        root._recomputeStale();
        root._rebuild();
    }

    function _onFailed(kind, error) {
        if (kind === "forecast") root.offline = true;
        root.lastError = error;
        root._rebuild();
    }

    function _recomputeStale() {
        root.stale = root._forecast !== null
            && (Date.now() - root._forecastSavedMs) > cfg.refreshMinutes.forecast * 60000;
    }

    // ---- The model -----------------------------------------------------------
    // Coalesced: a cache pair landing in one loop, or a fetch and its cache
    // write, build once.
    Timer { id: rebuildTimer; interval: 0; onTriggered: root._rebuildNow() }
    function _rebuild() { rebuildTimer.restart(); }

    function _rebuildNow() {
        const p = root.place;
        if (p === null || root._forecast === null) {
            if (p !== null && root._switching) return;      // the old place's picture stays up (_switching)
            if (root.model !== null) { root.model = null; root.updated(); }
            return;
        }
        const loc = { name: p.name, lat: p.lat, lon: p.lon, elevation: p.elevation, source: p.source, reason: p.reason, here: !!p.here };
        const kmiIn = kmi.forecasts ? Object.assign({}, kmi.forecasts, { pollenSvg: kmi.pollenSvg }) : null;
        let m = null;
        try {
            m = WM.normalise({
                forecast: root._forecast, airQuality: root._aq, kmi: kmiIn,
                config: cfg, nowMs: Date.now(), location: loc, fetchedAtMs: root.fetchedAtMs
            });
        } catch (e) {
            root.lastError = "model: " + e;
            console.warn("[WeatherService] normalise failed:", e);
            return;
        }
        if (!m) return;
        // The facts only the service knows.
        m.location = loc;
        m.fetchedAtMs = root.fetchedAtMs;
        m.stale = root.stale;
        m.offline = root.offline;
        m.error = root.lastError;
        m.dataSerial = root._dataSerial;
        root.model = m;
        root.updated();
    }

    // ---- Clock -----------------------------------------------------------------
    property string todayKey: ""
    property real _expectedTickMs: 0

    Timer {
        id: tick
        interval: 60000
        repeat: true
        running: true
        onTriggered: root._tick()
    }

    function _tick() {
        const now = Date.now();
        const jump = Math.abs(now - root._expectedTickMs);
        root._expectedTickMs = now + tick.interval;
        root.todayKey = root.brusselsDateKey(now);
        root._recomputeStale();
        if (jump > 5 * 60000) { root.refresh(); return; }
        root._rebuild();
    }

    // "YYYY-MM-DD" in Europe/Brussels: UTC+1, UTC+2 from the last Sunday of
    // March 01:00 UTC to the last Sunday of October 01:00 UTC (the EU rule).
    function brusselsDateKey(ms) {
        const y = new Date(ms).getUTCFullYear();
        const lastSundayAt1 = function (month) {
            const last = new Date(Date.UTC(y, month + 1, 0, 1, 0, 0));    // the month's last day, 01:00 UTC
            return last.getTime() - last.getUTCDay() * 86400000;
        };
        const dst = ms >= lastSundayAt1(2) && ms < lastSundayAt1(9);
        const local = new Date(ms + (dst ? 2 : 1) * 3600000);
        const two = n => (n < 10 ? "0" : "") + n;
        return local.getUTCFullYear() + "-" + two(local.getUTCMonth() + 1) + "-" + two(local.getUTCDate());
    }

    // ---- Nowcast while open ------------------------------------------------------
    Timer {
        id: nowcastTimer
        interval: cfg.refreshMinutes.nowcastWhileOpen * 60000
        repeat: true
        running: root.popupOpen && cfg.sources.kmi.enabled && root.place !== null
        onTriggered: kmi.refresh()
    }
    onPopupOpenChanged: {
        if (root.popupOpen && root.place !== null
                && Date.now() - kmi.fetchedAtMs > cfg.refreshMinutes.nowcastWhileOpen * 60000)
            kmi.refresh();
    }
}
