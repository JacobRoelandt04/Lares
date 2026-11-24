pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments

// =============================================================================
// WeatherConfig.qml -- the user's weather.jsonc, hot-reloaded, every key
// defaulted, every `query` location resolved once and remembered.
//
// Path: $XDG_CONFIG_HOME/quickshell/config/weather.jsonc (falls back to
// $HOME/.config/quickshell/config/weather.jsonc). Start from .examples/weather.jsonc.
//
// Schema -- every key is optional; the values shown are the defaults except the locations, an example (the
// default is one location, Brussels):
//
//   {
//     "locations": [
//       { "name": "Antwerp", "lat": 51.22, "lon": 4.40, "elevation": 7, "default": true },
//       { "name": "Leuven", "query": "Leuven, BE" }
//     ],
//       name        what the popup shows; a query entry without one takes the
//                   place name the geocoder answers with
//       lat, lon    decimal degrees, WGS84
//       elevation   metres above sea level. Open-Meteo corrects temperature and
//                   pressure to it. Left out, it is looked up ONCE through
//                   https://api.open-meteo.com/v1/elevation and remembered.
//       query       a place name, optionally ", CC" with an ISO country code
//                   ("Leuven, BE"), resolved ONCE through Open-Meteo's geocoder
//                   (https://geocoding-api.open-meteo.com/v1/search, first hit
//                   wins, English names). The geocoder searches NAMES only: the
//                   country goes in its own `countryCode` parameter, and
//                   "Leuven, BE" sent as a name finds nothing (a stub
//                   that answers any URL does not show it). The answer, elevation
//                   included, is written to
//                   $XDG_CACHE_HOME/lares/weather/locations.json keyed by
//                   the query text, so a restart never asks again; change the
//                   text to resolve anew. A query with no hit is dropped from
//                   `locations` and named in `lastError`.
//       default     the location the current location shows while geoclue has no
//                   fix and there is no hometown; the first entry when none is
//                   marked (with the current location off the popup starts on
//                   the first entry)
//       home        the user's hometown: what the current location shows while
//                   geoclue has no fix (a fix that is not accepted yet, an agent
//                   whose question is unanswered, a shell that has just started).
//                   Marks ONE saved location ("home": true); the first marked
//                   wins. With none marked, the hometown is the one the shell
//                   learned itself: the FIRST ACCEPTED geoclue fix names it, and
//                   it is kept in $XDG_STATE_HOME/lares/weather/home.json
//                   (delete that file to learn it again). A flag here always
//                   beats the learned one; with neither, the `default` location
//                   is the fallback.
//
//     "currentLocation": { "enabled": true, "maxAccuracyM": 3000, "nearSavedKm": 5 },
//       enabled       ask geoclue (its where-am-i client) for the machine's position and
//                     put "current location" first in the list
//       maxAccuracyM  a fix coarser than this is refused (an IP-only fix is
//                     tens of km; a WiFi fix a few hundred m)
//       nearSavedKm   a fix within this distance of a saved location takes
//                     that location's name
//
//     "units": { "temperature": "c", "wind": "bft", "speed": "kmh", "pressure": "hpa",
//                "precipitation": "mm", "distance": "km", "airQuality": "ugm3",
//                "co": "mgm3", "clock": "24h", "date": "dd/MM" },
//       temperature    c | f
//       wind           bft (Beaufort) | speed (a figure in the `speed` unit)
//       speed          kmh | ms | mph | kn
//       pressure       hpa | mbar | mmhg | inhg
//       precipitation  mm | in
//       distance       km | mi                (visibility)
//       airQuality     ugm3                   (pollutant concentrations)
//       co             mgm3 | ugm3            (carbon monoxide is usually mg/m3)
//       clock          24h | 12h
//       date           dd/MM | MM/dd | d MMM
//
//     "glyphSet": "ink",
//       ink     the drawn icon set (WeatherGlyphInk)
//       carved  the legacy carved set
//       TEMPORARY: it goes with the carved set once the ink set is approved (WeatherGlyphSet).
//
//     "view": { "start": "mini", "remember": "session" },
//       start     the view a session's first open is on: mini | normal | detailed
//       remember  session: the popup comes back as it was left | never: every open is `start`
//
//     "look": { "secondarySide": "end" },   where a day's detail opens: end | start | far
//
//     "aqiIndex": "eaqi",
//       eaqi    the European air quality index (Open-Meteo / CAMS)
//       belaqi  IRCEL-CELINE's Belgian index, 1..10 (forecast WMS point query)
//
//     "sources": { "openMeteo": { "model": "best_match" }, "kmi": { "enabled": true } },
//       openMeteo.model  an Open-Meteo model id: best_match (KNMI HARMONIE here,
//                        ECMWF beyond), knmi_harmonie_arome_netherlands, icon_d2,
//                        meteofrance_arome_france_hd, ecmwf_ifs025, ...
//       kmi.enabled      the KMI app API: observation, warnings, pollen note,
//                        radar nowcast, KMI's own daily text
//
//     "refreshMinutes": { "forecast": 15, "airQuality": 60, "kmi": 15, "nowcastWhileOpen": 5 }
//       how old each source may be before it is fetched again; nowcastWhileOpen
//       is KMI's cadence while the popup is open (the radar sequence moves)
//   }
//
// A missing or unparseable file gives the defaults with ONE location, Brussels
// (50.85, 4.35, 25 m), and `lastError` says why. An unknown unit or index value
// falls back to its default and is named in `lastError` too.
//
// The FileView rule (CLAUDE.md): one FileView per file, a static path, refreshed
// with reload(); the config's watcher reloads on change, the cache is ours alone.
// =============================================================================
Item {
    id: root

    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/weather.jsonc"
    readonly property string cacheDir:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
        + "/lares/weather"
    readonly property string locationsCachePath: root.cacheDir + "/locations.json"
    // The hometown the shell learned (WeatherHome): state, not cache -- a wiped cache must not forget where the user lives.
    readonly property string stateDir:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/weather"
    readonly property string homePath: root.stateDir + "/home.json"

    // ---- Defaults --------------------------------------------------------
    readonly property var defaultLocation: ({ name: "Brussels", lat: 50.85, lon: 4.35, elevation: 25 })
    readonly property var defaultUnits: ({
        temperature: "c", wind: "bft", speed: "kmh", pressure: "hpa", precipitation: "mm",
        distance: "km", airQuality: "ugm3", co: "mgm3", clock: "24h", date: "dd/MM"
    })
    readonly property var unitChoices: ({
        temperature: ["c", "f"], wind: ["bft", "speed"], speed: ["kmh", "ms", "mph", "kn"],
        pressure: ["hpa", "mbar", "mmhg", "inhg"], precipitation: ["mm", "in"], distance: ["km", "mi"],
        airQuality: ["ugm3"], co: ["mgm3", "ugm3"], clock: ["24h", "12h"],
        date: ["dd/MM", "MM/dd", "d MMM"]
    })
    readonly property var defaultRefresh: ({ forecast: 15, airQuality: 60, kmi: 15, nowcastWhileOpen: 5 })
    readonly property var defaultCurrent: ({ enabled: true, maxAccuracyM: 3000, nearSavedKm: 5 })

    // ---- Public state ----------------------------------------------------
    property var units: root.defaultUnits
    property string aqiIndex: "eaqi"
    // TEMPORARY (see the header): which icon set WeatherGlyph draws.
    property string glyphSet: "ink"
    property var view: ({ start: "mini", remember: "session" })
    property var look: ({ secondarySide: "end" })
    property var sources: ({ openMeteo: { model: "best_match" }, kmi: { enabled: true } })
    property var refreshMinutes: root.defaultRefresh
    property var currentLocation: root.defaultCurrent
    // Resolved: [{ name, lat, lon, elevation }]. Empty ONLY while every entry
    // is a query still being resolved; a config with no usable entry (or no
    // file) holds the Brussels default.
    property var locations: [root.defaultLocation]
    property int defaultIndex: 0
    // The location marked "home": true, resolved (a copy of its entry in `locations`), or null. `homePending` is a
    // marked entry whose query is still being resolved: the service waits for it instead of showing the default first.
    property var homeLocation: null
    property bool homePending: false
    property string lastError: ""
    // The file and the cache have both been read (or found missing).
    readonly property bool ready: root._settled && root._cacheSettled && root._dirReady
    // A geocoding / elevation lookup is in flight or queued.
    readonly property bool resolving: root._job !== null

    signal configChanged()

    // ---- Private ---------------------------------------------------------
    property var _raw: []               // [{ name, lat, lon, elevation, query, isDefault }]
    property var _cache: ({})           // locations.json: { "<query>" | "@lat,lon": { ... } }
    property var _job: null             // { kind, key, url } in flight
    property var _failed: []            // keys whose lookup failed this round (retried later)
    property var _parseErrors: []
    property string _lookupError: ""
    property string _lastText: ""
    property bool _settled: false
    property bool _cacheSettled: false
    property bool _dirReady: false

    // ---- The config file -------------------------------------------------
    ConfigFile {
        id: configView
        path: root.configPath
        onLoaded: root._parse(configView.text(), "")
        onLoadFailed: root._parse("", "weather.jsonc not found at " + root.configPath + ": using the defaults (Brussels)")
    }

    // ---- The resolved-locations cache (ours alone) -------------------------
    FileView {
        id: cacheView
        path: root.locationsCachePath
        preload: true
        watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root._cacheLoaded(text())
        onLoadFailed: root._cacheLoaded("")
    }

    // Connections handlers rather than inline onExited: qmllint cannot see
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
        function onExited() { root._dirReady = true; root._resolvePending(); }
    }

    // One lookup at a time; the collectors are read at exit (the pattern of
    // every Process in this shell).
    Process {
        id: geoProc
        running: false
        stdout: StdioCollector { id: geoOut }
        stderr: StdioCollector { id: geoErr }
    }
    Connections {
        target: geoProc
        function onExited(code) { root._lookupDone(code, geoOut.text, geoErr.text); }
    }

    // A transport failure is retried after a while; a "no hit" answer is
    // cached and never retried (the user changes the text instead).
    Timer {
        id: retryTimer
        interval: 5 * 60000
        onTriggered: { root._failed = []; root._resolvePending(); }
    }

    Component.onCompleted: {
        mkdirProc.running = true;
        const t = configView.text();
        if (t) root._parse(t, "");
    }

    function reload() { configView.reload(); }

    function geocodeUrl(query) {
        const m = /^(.*\S)\s*,\s*([A-Za-z]{2})\s*$/.exec(String(query));
        const name = m ? m[1] : String(query).trim();
        return "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(name)
            + (m ? "&countryCode=" + m[2].toUpperCase() : "")
            + "&count=1&language=en&format=json";
    }
    function elevationUrl(lat, lon) {
        return "https://api.open-meteo.com/v1/elevation?latitude=" + lat + "&longitude=" + lon;
    }

    // ---- Parsing ---------------------------------------------------------
    function _parse(txt, why) {
        if (why === "" && txt === root._lastText && root._settled) return;   // the watcher echoing the same bytes
        root._lastText = txt;
        const errors = [];
        let obj = null;
        if (why !== "") {
            errors.push(why);
        } else if (!txt || txt.trim().length === 0) {
            errors.push("weather.jsonc is empty: using the defaults (Brussels)");
        } else {
            try { obj = JSON.parse(JsonComments.strip(txt)); }
            catch (e) { errors.push("weather.jsonc: " + e.message + ": using the defaults (Brussels)"); }
            if (obj !== null && (typeof obj !== "object" || Array.isArray(obj))) {
                errors.push("weather.jsonc: top level is not an object: using the defaults (Brussels)");
                obj = null;
            }
        }
        const o = obj || {};
        root.units = root._mergeUnits(o.units, errors);
        root.aqiIndex = root._pick("aqiIndex", o.aqiIndex, ["eaqi", "belaqi"], "eaqi", errors);
        root.glyphSet = root._pick("glyphSet", o.glyphSet, ["ink", "carved"], "ink", errors);
        const view = o.view && typeof o.view === "object" ? o.view : {}, look = o.look && typeof o.look === "object" ? o.look : {};
        root.view = { start: root._pick("view.start", view.start, ["mini", "normal", "detailed"], "mini", errors),
                      remember: root._pick("view.remember", view.remember, ["session", "never"], "session", errors) };
        root.look = { secondarySide: root._pick("look.secondarySide", look.secondarySide, ["start", "end", "far"], "end", errors) };
        root.sources = root._mergeSources(o.sources, errors);
        root.refreshMinutes = root._mergeNumbers("refreshMinutes", o.refreshMinutes, root.defaultRefresh, errors);
        root.currentLocation = root._mergeCurrent(o.currentLocation, errors);
        root._raw = root._parseLocations(o.locations, errors);
        root._parseErrors = errors;
        root._settled = true;
        root._rebuildLocations();
        root._resolvePending();
    }

    function _pick(key, v, choices, dflt, errors) {
        if (v === undefined) return dflt;
        if (typeof v === "string" && choices.indexOf(v) >= 0) return v;
        errors.push(key + ": unknown value " + JSON.stringify(v) + ", using \"" + dflt + "\"");
        return dflt;
    }

    function _mergeUnits(u, errors) {
        const out = {};
        const src = (u && typeof u === "object") ? u : {};
        if (u !== undefined && (typeof u !== "object" || u === null)) errors.push("units: not an object, using the defaults");
        for (const k in root.defaultUnits)
            out[k] = root._pick("units." + k, src[k], root.unitChoices[k], root.defaultUnits[k], errors);
        return out;
    }

    function _mergeNumbers(key, v, dflts, errors) {
        const out = {};
        const src = (v && typeof v === "object") ? v : {};
        for (const k in dflts) {
            const x = src[k];
            if (x === undefined) { out[k] = dflts[k]; continue; }
            if (typeof x === "number" && isFinite(x) && x > 0) { out[k] = x; continue; }
            errors.push(key + "." + k + ": not a positive number, using " + dflts[k]);
            out[k] = dflts[k];
        }
        return out;
    }

    function _mergeSources(s, errors) {
        const src = (s && typeof s === "object") ? s : {};
        const om = (src.openMeteo && typeof src.openMeteo === "object") ? src.openMeteo : {};
        const kmi = (src.kmi && typeof src.kmi === "object") ? src.kmi : {};
        let model = "best_match";
        if (om.model !== undefined) {
            if (typeof om.model === "string" && /^[a-z0-9_]+$/.test(om.model)) model = om.model;
            else errors.push("sources.openMeteo.model: not a model id, using \"best_match\"");
        }
        let enabled = true;
        if (kmi.enabled !== undefined) {
            if (typeof kmi.enabled === "boolean") enabled = kmi.enabled;
            else errors.push("sources.kmi.enabled: not a boolean, using true");
        }
        return { openMeteo: { model: model }, kmi: { enabled: enabled } };
    }

    function _mergeCurrent(c, errors) {
        const src = (c && typeof c === "object") ? c : {};
        const nums = root._mergeNumbers("currentLocation", src,
            { maxAccuracyM: root.defaultCurrent.maxAccuracyM, nearSavedKm: root.defaultCurrent.nearSavedKm }, errors);
        let enabled = root.defaultCurrent.enabled;
        if (src.enabled !== undefined) {
            if (typeof src.enabled === "boolean") enabled = src.enabled;
            else errors.push("currentLocation.enabled: not a boolean, using true");
        }
        return { enabled: enabled, maxAccuracyM: nums.maxAccuracyM, nearSavedKm: nums.nearSavedKm };
    }

    function _parseLocations(list, errors) {
        if (list === undefined) return [];
        if (!Array.isArray(list)) { errors.push("locations: not a list"); return []; }
        const out = [];
        for (let i = 0; i < list.length; i++) {
            const e = list[i];
            if (!e || typeof e !== "object") { errors.push("locations[" + i + "]: not an object"); continue; }
            const name = typeof e.name === "string" ? e.name.trim() : "";
            const query = typeof e.query === "string" && e.query.trim() ? e.query.trim() : null;
            const hasLat = typeof e.lat === "number" && isFinite(e.lat) && Math.abs(e.lat) <= 90;
            const hasLon = typeof e.lon === "number" && isFinite(e.lon) && Math.abs(e.lon) <= 180;
            let elevation = null;
            if (e.elevation !== undefined) {
                if (typeof e.elevation === "number" && isFinite(e.elevation)) elevation = e.elevation;
                else errors.push("locations[" + i + "]: elevation is not a number, will be looked up");
            }
            if (query === null && !(hasLat && hasLon)) {
                errors.push("locations[" + i + "]" + (name ? " (" + name + ")" : "") + ": needs lat and lon, or a query");
                continue;
            }
            out.push({
                name: name, query: query,
                lat: hasLat ? e.lat : null, lon: hasLon ? e.lon : null,
                elevation: elevation, isDefault: e["default"] === true, isHome: e["home"] === true
            });
        }
        return out;
    }

    // ---- Resolution ------------------------------------------------------
    function _cacheLoaded(txt) {
        let obj = {};
        if (txt && txt.trim().length > 0) {
            try { obj = JSON.parse(JsonComments.strip(txt)); } catch (e) { obj = {}; }
            if (!obj || typeof obj !== "object" || Array.isArray(obj)) obj = {};
        }
        root._cache = obj;
        root._cacheSettled = true;
        root._rebuildLocations();
        root._resolvePending();
    }

    // The resolved view of `_raw` through the cache. Emits configChanged.
    function _rebuildLocations() {
        if (!root._settled || !root._cacheSettled) return;
        const out = [];
        const notes = [];
        let def = -1;
        let home = -1;
        let homePending = false;
        let pending = 0;
        for (let i = 0; i < root._raw.length; i++) {
            const e = root._raw[i];
            let name = e.name, lat = e.lat, lon = e.lon, elev = e.elevation;
            if (e.query !== null) {
                const c = root._cache[e.query];
                if (!c) { pending++; if (e.isHome && home < 0) homePending = true; continue; }
                if (c.error) { notes.push("\"" + e.query + "\": " + c.error); continue; }
                lat = c.lat; lon = c.lon;
                if (elev === null && typeof c.elevation === "number") elev = c.elevation;
                if (!name) name = c.name;
            }
            if (elev === null) {
                const c = root._cache["@" + lat + "," + lon];
                if (c && typeof c.elevation === "number") elev = c.elevation;
            }
            if (e.isDefault && def < 0) def = out.length;
            if (e.isHome && home < 0) home = out.length;
            out.push({ name: name || (lat.toFixed(2) + ", " + lon.toFixed(2)), lat: lat, lon: lon, elevation: elev });
        }
        if (out.length === 0 && pending === 0) out.push(Object.assign({}, root.defaultLocation));
        const errs = root._parseErrors.concat(notes);
        if (root._lookupError) errs.push(root._lookupError);
        root.defaultIndex = def < 0 ? 0 : def;
        root.locations = out;
        root.homeLocation = home < 0 ? null : Object.assign({}, out[home]);
        root.homePending = homePending && home < 0;
        root.lastError = errs.join("; ");
        root.configChanged();
    }

    function _resolvePending() {
        if (!root._settled || !root._cacheSettled || !root._dirReady) return;
        if (root._job !== null) return;
        for (let i = 0; i < root._raw.length; i++) {
            const e = root._raw[i];
            if (e.query !== null && !(e.query in root._cache) && root._failed.indexOf(e.query) < 0) {
                root._lookup({ kind: "geocode", key: e.query, url: root.geocodeUrl(e.query) });
                return;
            }
        }
        for (let i = 0; i < root._raw.length; i++) {
            const e = root._raw[i];
            let lat = e.lat, lon = e.lon, elev = e.elevation;
            if (e.query !== null) {
                const c = root._cache[e.query];
                if (!c || c.error) continue;
                lat = c.lat; lon = c.lon;
                if (elev === null && typeof c.elevation === "number") elev = c.elevation;
            }
            if (elev !== null) continue;
            const key = "@" + lat + "," + lon;
            if (key in root._cache || root._failed.indexOf(key) >= 0) continue;
            root._lookup({ kind: "elevation", key: key, url: root.elevationUrl(lat, lon) });
            return;
        }
    }

    function _lookup(job) {
        root._job = job;
        geoProc.command = ["curl", "-sSfL", "--max-time", "20", "--compressed", job.url];
        geoProc.running = true;
    }

    function _lookupDone(code, out, err) {
        const job = root._job;
        root._job = null;
        if (!job) return;
        let entry = null;
        let fail = "";
        if (code !== 0) {
            fail = "curl exit " + code + (err ? ": " + err.trim().split("\n")[0] : "");
        } else {
            try {
                const obj = JSON.parse(out);
                if (job.kind === "geocode") {
                    const r = Array.isArray(obj.results) ? obj.results[0] : null;
                    entry = r ? {
                        name: typeof r.name === "string" ? r.name : job.key,
                        lat: r.latitude, lon: r.longitude,
                        elevation: typeof r.elevation === "number" ? r.elevation : null,
                        country: typeof r.country_code === "string" ? r.country_code : ""
                    } : { error: "no hit" };
                } else {
                    const v = Array.isArray(obj.elevation) ? obj.elevation[0] : undefined;
                    entry = typeof v === "number" ? { elevation: v } : { error: "no elevation" };
                }
            } catch (e) {
                fail = "bad JSON: " + e.message;
            }
        }
        if (fail) {
            root._failed = root._failed.concat([job.key]);
            root._lookupError = (job.kind === "geocode" ? "geocoding \"" : "elevation for \"")
                + job.key + "\" failed: " + fail;
            retryTimer.restart();
        } else {
            entry.resolvedAtMs = Date.now();
            root._cache[job.key] = entry;
            root._lookupError = "";
            cacheView.setText(JSON.stringify(root._cache, null, 1) + "\n");
        }
        root._rebuildLocations();
        root._resolvePending();
    }
}
