pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// KmiSource.qml -- the KMI app's forecast bundle for one place, and its
// pollen SVG, by curl, cached per place, stale-first.
//
//   https://app.meteo.be/services/appv4/?s=getForecasts&k=<key>&lat=<lat>&long=<lon>
//   key = md5("r9EnW374jkJ9acc;getForecasts;dd/MM/yyyy") with TODAY's date in
//   Europe/Brussels (the service hands `todayKey` in; verified live: this exact
//   formula returns the fixture). User-Agent "lares-weather/0.1
//   (+https://github.com/JacobRoelandt04/Lares)" -- an unofficial client says who it is.
//
// The bundle carries obs, for.hourly (49), for.daily (8), for.warning, module[]
// and animation (the radar sequence). The module[] entry of type "svg" whose
// data.url.en contains "e=pollen" is fetched as text and exposed as
// `pollenSvg` ("" when the module is absent: the pollen note fails closed).
//
// Cache: $XDG_CACHE_HOME/lares/weather/kmi-<lat>_<lon>.json ({ savedAtMs,
// forecasts }) and .svg, one FileView per file with a static path, created for
// the place and destroyed when the place changes (a FileView is never
// repointed -- CLAUDE.md). The cache paints first; the fetch is scheduled for
// when the cache turns everyMs old (now, when it is missing), then every
// everyMs, retryMs after a failure. refresh() fetches now (the popup's
// nowcast cadence). Not wanted (`wanted` false): no request, `forecasts` null.
// =============================================================================
Item {
    id: root

    // ---- Inputs ------------------------------------------------------------
    property var lat: null
    property var lon: null
    property bool wanted: true             // config.sources.kmi.enabled
    property bool active: false            // the service: the cache directory exists
    property int everyMs: 15 * 60000
    property int retryMs: 2 * 60000
    property string todayKey: Qt.formatDate(new Date(), "yyyy-MM-dd")
    readonly property string userAgent: "lares-weather/0.1 (+https://github.com/JacobRoelandt04/Lares)"
    readonly property string cacheDir:
        (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
        + "/lares/weather"

    // ---- Outputs -----------------------------------------------------------
    property var forecasts: null           // the parsed getForecasts bundle, or null
    property string pollenSvg: ""
    readonly property string cityName:
        root.forecasts && typeof root.forecasts.cityName === "string" ? root.forecasts.cityName : ""
    readonly property bool loading: proc.running || svgProc.running
    property string lastError: ""
    property real fetchedAtMs: 0           // savedAtMs of what `forecasts` holds (cache or live)
    property bool fromCache: false
    signal fetched()
    signal failed(string error)

    readonly property string key:
        Qt.md5("r9EnW374jkJ9acc;getForecasts;" + root.ddmmyyyy(root.todayKey))
    readonly property string url: root.place === "" ? "" :
        "https://app.meteo.be/services/appv4/?s=getForecasts&k=" + root.key
        + "&lat=" + root.lat + "&long=" + root.lon
    // The place being served: "" when disabled, inactive or without coordinates.
    readonly property string place:
        (root.wanted && root.active && root.lat !== null && root.lon !== null)
            ? root.lat + "_" + root.lon : ""

    function ddmmyyyy(isoKey) {
        const p = isoKey.split("-");
        return p[2] + "/" + p[1] + "/" + p[0];
    }

    // ---- Per-place caches ----------------------------------------------------
    property int _gen: 0
    property var _jsonView: null
    property var _svgView: null

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

    onPlaceChanged: root._activate()
    Component.onCompleted: root._activate()

    function _activate() {
        root._gen++;
        fetchTimer.stop();
        proc.running = false; svgProc.running = false;
        if (root._jsonView) { root._jsonView.destroy(); root._jsonView = null; }
        if (root._svgView) { root._svgView.destroy(); root._svgView = null; }
        root.forecasts = null; root.pollenSvg = ""; root.fetchedAtMs = 0; root.fromCache = false;
        if (root.place === "") return;
        const base = root.cacheDir + "/kmi-" + root.place;
        root._jsonView = cacheComp.createObject(root, { path: base + ".json", kind: "json", gen: root._gen });
        root._svgView = cacheComp.createObject(root, { path: base + ".svg", kind: "svg", gen: root._gen });
    }

    function _cacheLoaded(cv, txt) {
        if (cv.gen !== root._gen) return;
        if (cv.kind === "svg") {
            if (root.fetchedAtMs === 0 || root.fromCache) root.pollenSvg = txt || "";
            return;
        }
        let obj = null;
        try { obj = JSON.parse(txt); } catch (e) { obj = null; }
        if (!obj || typeof obj.savedAtMs !== "number" || !obj.forecasts) { root._cacheMissing(cv); return; }
        if (root.fetchedAtMs === 0) {          // nothing live yet: paint the cache
            root.fromCache = true;
            root.fetchedAtMs = obj.savedAtMs;
            root.forecasts = obj.forecasts;
        }
        root.schedule(obj.savedAtMs + root.everyMs - Date.now());
    }

    function _cacheMissing(cv) {
        if (cv.gen !== root._gen || cv.kind !== "json") return;
        root.schedule(0);
    }

    // ---- Scheduling --------------------------------------------------------
    Timer { id: fetchTimer; onTriggered: root.fetch() }

    function schedule(delayMs) {
        if (root.place === "") return;
        fetchTimer.interval = Math.max(0, Math.floor(delayMs));
        fetchTimer.restart();
    }
    function refresh() { root.schedule(0); }

    function fetch() {
        if (root.place === "" || proc.running) return;
        proc.gen = root._gen;
        proc.command = ["curl", "-sSfL", "--max-time", "20", "--compressed", "-A", root.userAgent, root.url];
        proc.running = true;
    }

    // ---- Transport ---------------------------------------------------------
    // Connections handlers rather than inline onExited: qmllint cannot see
    // QProcess::ExitStatus and warns on every inline one (Theme.qml).
    Process {
        id: proc
        property int gen: 0
        running: false
        stdout: StdioCollector { id: out }
        stderr: StdioCollector { id: err }
    }
    Connections {
        target: proc
        function onExited(code) { root._done(proc.gen, code, out.text, err.text); }
    }
    Process {
        id: svgProc
        property int gen: 0
        running: false
        stdout: StdioCollector { id: svgOut }
        stderr: StdioCollector { id: svgErr }
    }
    Connections {
        target: svgProc
        function onExited(code) { root._svgDone(svgProc.gen, code, svgOut.text, svgErr.text); }
    }

    function _done(gen, code, body, errText) {
        if (gen !== root._gen) return;
        let error = "";
        let obj = null;
        if (code !== 0) {
            const line = errText ? errText.trim().split("\n")[0] : "";
            error = "curl exit " + code + (line ? ": " + line : "");
        } else {
            try { obj = JSON.parse(body); } catch (e) { error = "bad JSON: " + e.message; }
            if (!error && (!obj || typeof obj !== "object" || !obj["for"])) error = "no forecast in the response";
        }
        if (error) {
            root.lastError = "kmi: " + error;
            root.failed(root.lastError);
            root.schedule(root.retryMs);
            return;
        }
        const now = Date.now();
        root.fromCache = false;
        root.fetchedAtMs = now;
        root.forecasts = obj;
        root.lastError = "";
        if (root._jsonView) root._jsonView.setText(JSON.stringify({ savedAtMs: now, forecasts: obj }) + "\n");
        root.fetched();
        root.schedule(root.everyMs);
        const svgUrl = root.pollenUrl(obj);
        if (svgUrl === "") { root.pollenSvg = ""; return; }
        svgProc.gen = root._gen;
        svgProc.command = ["curl", "-sSfL", "--max-time", "20", "--compressed", "-A", root.userAgent, svgUrl];
        svgProc.running = true;
    }

    function _svgDone(gen, code, body, errText) {
        if (gen !== root._gen) return;
        if (code !== 0 || !body || body.indexOf("<svg") < 0) {
            const line = errText ? errText.trim().split("\n")[0] : "";
            root.lastError = "kmi pollen: " + (code !== 0 ? "curl exit " + code + (line ? ": " + line : "") : "not an SVG");
            root.pollenSvg = "";
            return;
        }
        root.pollenSvg = body;
        if (root._svgView) root._svgView.setText(body);
    }

    // The English pollen module URL in a bundle, or "".
    function pollenUrl(bundle) {
        const mods = bundle && Array.isArray(bundle.module) ? bundle.module : [];
        for (let i = 0; i < mods.length; i++) {
            const m = mods[i];
            if (!m || m.type !== "svg" || !m.data || !m.data.url) continue;
            const u = m.data.url.en;
            if (typeof u === "string" && u.indexOf("e=pollen") >= 0) return u;
        }
        return "";
    }
}
