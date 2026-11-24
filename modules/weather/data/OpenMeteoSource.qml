pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// OpenMeteoSource.qml -- the forecast and the air quality, by curl.
//
// Two fetches on separate cadences, each a `curl -sSfL --max-time 20
// --compressed` Process (CalendarFeed's transport; no XMLHttpRequest, whose
// abort() never closes its socket). The parameter lists are FIXED -- the
// fixtures under modules/weather/data/fixtures/ were captured with exactly these, so a stub serving by URL
// matches them verbatim:
//
//   forecast     current + hourly (16 d) + daily incl. moonrise/moonset/moon_phase,
//                sunshine, visibility and cloud-cover ranges; timezone=Europe/Brussels;
//                elevation passed when known (Open-Meteo corrects T and p to it),
//                models=<config's model>
//   air quality  CAMS: current + hourly pollutants, EAQI per pollutant, six
//                pollen species, uv; 5 days
//   belaqi       when aqiIndex is "belaqi": IRCEL's forecast WMS, a
//                GetFeatureInfo point value for today, +1 and +2, handed on as
//                airQuality.belaqi = { "YYYY-MM-DD": index }. Auxiliary: a
//                failed day is simply absent.
//
// The source has no cache of its own (WeatherService keeps one per location)
// and no clock of its own: the service calls scheduleForecast(delayMs) /
// scheduleAirQuality(delayMs) with what the cache's age leaves, and from then
// on each fetch reschedules itself at its cadence (retryMs after a failure).
// stop() bumps a generation so a result that lands after a location switch is
// dropped rather than painted over the new place.
// =============================================================================
Item {
    id: root

    // ---- Inputs ------------------------------------------------------------
    property var lat: null
    property var lon: null
    property var elevation: null           // metres, or null to let Open-Meteo use its own DEM
    property string model: "best_match"
    property string aqiIndex: "eaqi"
    property string todayKey: Qt.formatDate(new Date(), "yyyy-MM-dd")   // the service hands in Europe/Brussels' date
    property int forecastEveryMs: 15 * 60000
    property int airQualityEveryMs: 60 * 60000
    property int retryMs: 2 * 60000

    // ---- Outputs -----------------------------------------------------------
    property var forecast: null            // the parsed forecast response, or null
    property var airQuality: null          // the parsed air-quality response (+ belaqi), or null
    readonly property bool loading: forecastProc.running || aqProc.running || belaqiProc.running
    property string lastError: ""
    signal fetched(string kind)            // "forecast" | "airQuality"
    signal failed(string kind, string error)

    readonly property bool hasPlace: root.lat !== null && root.lon !== null

    readonly property string forecastCurrent:
        "temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,rain,showers,snowfall,weather_code,cloud_cover,pressure_msl,surface_pressure,wind_speed_10m,wind_direction_10m,wind_gusts_10m"
    readonly property string forecastHourly:
        "temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,precipitation,precipitation_probability,rain,showers,snowfall,weather_code,pressure_msl,surface_pressure,cloud_cover,visibility,wind_speed_10m,wind_direction_10m,wind_gusts_10m,uv_index,is_day,sunshine_duration"
    readonly property string forecastDaily:
        "weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,sunrise,sunset,daylight_duration,sunshine_duration,uv_index_max,precipitation_sum,rain_sum,showers_sum,snowfall_sum,precipitation_hours,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,moonrise,moonset,moon_phase,cloud_cover_min,cloud_cover_max,cloud_cover_mean,visibility_min,visibility_max,visibility_mean,dew_point_2m_mean,relative_humidity_2m_mean,pressure_msl_mean"
    readonly property string airQualityCurrent:
        "european_aqi,pm10,pm2_5,carbon_monoxide,nitrogen_dioxide,sulphur_dioxide,ozone,uv_index"
    readonly property string airQualityHourly:
        "pm10,pm2_5,carbon_monoxide,nitrogen_dioxide,sulphur_dioxide,ozone,european_aqi,european_aqi_pm2_5,european_aqi_pm10,european_aqi_nitrogen_dioxide,european_aqi_ozone,european_aqi_sulphur_dioxide,alder_pollen,birch_pollen,grass_pollen,mugwort_pollen,olive_pollen,ragweed_pollen,uv_index"

    readonly property string forecastUrl: !root.hasPlace ? "" :
        "https://api.open-meteo.com/v1/forecast?latitude=" + root.lat + "&longitude=" + root.lon
        + (root.elevation !== null ? "&elevation=" + root.elevation : "")
        + "&current=" + root.forecastCurrent + "&hourly=" + root.forecastHourly + "&daily=" + root.forecastDaily
        + "&timezone=Europe%2FBrussels&forecast_days=16&models=" + root.model
    readonly property string airQualityUrl: !root.hasPlace ? "" :
        "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=" + root.lat + "&longitude=" + root.lon
        + "&current=" + root.airQualityCurrent + "&hourly=" + root.airQualityHourly
        + "&timezone=Europe%2FBrussels&forecast_days=5"

    function belaqiUrl(dateKey) {
        const f = x => String(Number(x.toFixed(4)));
        return "https://geo.irceline.be/forecast/wms?SERVICE=WMS&VERSION=1.3.0&REQUEST=GetFeatureInfo"
            + "&LAYERS=belaqi_forecast&QUERY_LAYERS=belaqi_forecast&CRS=EPSG:4326"
            + "&BBOX=" + f(root.lat - 0.01) + "," + f(root.lon - 0.01) + "," + f(root.lat + 0.01) + "," + f(root.lon + 0.01)
            + "&WIDTH=3&HEIGHT=3&I=1&J=1&INFO_FORMAT=application/json&TIME=" + dateKey + "T00:00:00Z";
    }

    // "YYYY-MM-DD" + k days, on the calendar (no timezone in the arithmetic).
    function dateKeyPlus(key, k) {
        const p = key.split("-");
        const d = new Date(Date.UTC(Number(p[0]), Number(p[1]) - 1, Number(p[2]) + k));
        const two = n => (n < 10 ? "0" : "") + n;
        return d.getUTCFullYear() + "-" + two(d.getUTCMonth() + 1) + "-" + two(d.getUTCDate());
    }

    // ---- Scheduling --------------------------------------------------------
    property int _gen: 0
    property var _belaqiDates: []
    property var _belaqi: ({})
    property var _aqPending: null

    function scheduleForecast(delayMs) {
        if (!root.hasPlace) return;
        forecastTimer.interval = Math.max(0, Math.floor(delayMs));
        forecastTimer.restart();
    }
    function scheduleAirQuality(delayMs) {
        if (!root.hasPlace) return;
        aqTimer.interval = Math.max(0, Math.floor(delayMs));
        aqTimer.restart();
    }
    function refresh() { root.scheduleForecast(0); root.scheduleAirQuality(0); }
    function stop() {
        root._gen++;
        forecastTimer.stop(); aqTimer.stop();
        forecastProc.running = false; aqProc.running = false; belaqiProc.running = false;
        root._belaqiDates = []; root._aqPending = null;
    }

    // A changed model or index after something was fetched: fetch again.
    onModelChanged: if (root.forecast !== null) root.scheduleForecast(0)
    onAqiIndexChanged: if (root.airQuality !== null) root.scheduleAirQuality(0)

    Timer { id: forecastTimer; onTriggered: root.fetchForecast() }
    Timer { id: aqTimer; onTriggered: root.fetchAirQuality() }

    function fetchForecast() {
        if (!root.hasPlace || forecastProc.running) return;
        forecastProc.gen = root._gen;
        forecastProc.command = ["curl", "-sSfL", "--max-time", "20", "--compressed", root.forecastUrl];
        forecastProc.running = true;
    }
    function fetchAirQuality() {
        if (!root.hasPlace || aqProc.running) return;
        aqProc.gen = root._gen;
        aqProc.command = ["curl", "-sSfL", "--max-time", "20", "--compressed", root.airQualityUrl];
        aqProc.running = true;
    }

    // ---- Transport ---------------------------------------------------------
    // Connections handlers rather than inline onExited: qmllint cannot see
    // QProcess::ExitStatus and warns on every inline one (Theme.qml).
    Process {
        id: forecastProc
        property int gen: 0
        running: false
        stdout: StdioCollector { id: fcOut }
        stderr: StdioCollector { id: fcErr }
    }
    Connections {
        target: forecastProc
        function onExited(code) { root._forecastDone(forecastProc.gen, code, fcOut.text, fcErr.text); }
    }
    Process {
        id: aqProc
        property int gen: 0
        running: false
        stdout: StdioCollector { id: aqOut }
        stderr: StdioCollector { id: aqErr }
    }
    Connections {
        target: aqProc
        function onExited(code) { root._airQualityDone(aqProc.gen, code, aqOut.text, aqErr.text); }
    }
    Process {
        id: belaqiProc
        property int gen: 0
        property string dateKey: ""
        running: false
        stdout: StdioCollector { id: belaqiOut }
        stderr: StdioCollector { id: belaqiErr }
    }
    Connections {
        target: belaqiProc
        function onExited(code) { root._belaqiDone(belaqiProc.gen, belaqiProc.dateKey, code, belaqiOut.text, belaqiErr.text); }
    }

    // A curl failure, a non-JSON body or Open-Meteo's own {error:true} -> the reason.
    function _parseBody(code, out, err) {
        if (code !== 0) {
            const line = err ? err.trim().split("\n")[0] : "";
            return { error: "curl exit " + code + (line ? ": " + line : "") };
        }
        let obj;
        try { obj = JSON.parse(out); } catch (e) { return { error: "bad JSON: " + e.message }; }
        if (!obj || typeof obj !== "object") return { error: "not an object" };
        if (obj.error) return { error: typeof obj.reason === "string" ? obj.reason : "API error" };
        return { obj: obj };
    }

    function _forecastDone(gen, code, out, err) {
        if (gen !== root._gen) return;
        const r = root._parseBody(code, out, err);
        if (!r.error && (!r.obj.hourly || !r.obj.daily)) r.error = "no hourly/daily in the response";
        if (r.error) {
            root.lastError = "forecast: " + r.error;
            root.failed("forecast", root.lastError);
            root.scheduleForecast(root.retryMs);
            return;
        }
        root.forecast = r.obj;
        root.lastError = "";
        root.fetched("forecast");
        root.scheduleForecast(root.forecastEveryMs);
    }

    function _airQualityDone(gen, code, out, err) {
        if (gen !== root._gen) return;
        const r = root._parseBody(code, out, err);
        if (!r.error && !r.obj.hourly) r.error = "no hourly in the response";
        if (r.error) {
            root.lastError = "air quality: " + r.error;
            root.failed("airQuality", root.lastError);
            root.scheduleAirQuality(root.retryMs);
            return;
        }
        if (root.aqiIndex === "belaqi") {
            // Hold the publish until the three WMS answers are in (or failed).
            root._aqPending = r.obj;
            root._belaqi = {};
            root._belaqiDates = [root.todayKey, root.dateKeyPlus(root.todayKey, 1), root.dateKeyPlus(root.todayKey, 2)];
            root._nextBelaqi();
            return;
        }
        root._publishAirQuality(r.obj);
    }

    function _publishAirQuality(obj) {
        root.airQuality = obj;
        root.lastError = "";
        root.fetched("airQuality");
        root.scheduleAirQuality(root.airQualityEveryMs);
    }

    function _nextBelaqi() {
        if (root._belaqiDates.length === 0) {
            const obj = root._aqPending;
            root._aqPending = null;
            if (!obj) return;
            obj.belaqi = root._belaqi;
            root._publishAirQuality(obj);
            return;
        }
        const key = root._belaqiDates[0];
        root._belaqiDates = root._belaqiDates.slice(1);
        belaqiProc.gen = root._gen;
        belaqiProc.dateKey = key;
        belaqiProc.command = ["curl", "-sSfL", "--max-time", "20", "--compressed", root.belaqiUrl(key)];
        belaqiProc.running = true;
    }

    function _belaqiDone(gen, dateKey, code, out, err) {
        if (gen !== root._gen) return;
        const r = root._parseBody(code, out, err);
        if (r.error) {
            root.lastError = "belaqi " + dateKey + ": " + r.error;
        } else {
            const f = Array.isArray(r.obj.features) ? r.obj.features[0] : null;
            const v = f && f.properties ? f.properties.GRAY_INDEX : undefined;
            if (typeof v === "number" && isFinite(v) && v >= 1 && v <= 10) root._belaqi[dateKey] = v;
        }
        root._nextBelaqi();
    }
}
