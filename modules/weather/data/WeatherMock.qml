pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../common/system"
import "WeatherModel.js" as WM

// =============================================================================
// WeatherMock.qml -- the weather service without a network.
//
// The identical interface to WeatherService: the popup takes
// ONE `service` object and reads `model`, `loading`, `offline`, `lastError`,
// `fetchedAtMs`, `locations`, `locationIndex`, `config`, `popupOpen`, calls
// `refresh()` / `selectLocation(i)` and listens to `updated()`. A mockup swaps
// this in for the real one and nothing above it changes.
//
// WHERE THE DATA COMES FROM. The three captured responses under
// modules/weather/data/fixtures/ (Antwerp, 2026-09-16 19:02) plus the KMI pollen SVG,
// normalised by WeatherModel.js exactly as the real service does it, then
// edited by one function per `scenario`. An edit touches current, the
// hours and the days together so every figure stays plausible: a "snow"
// scenario has sub-zero temperatures, a dew point below them, snow in
// centimetres with its water equivalent in millimetres, a KMI observation
// that says snow, and a radar nowcast that is not dry. A scenario that could
// not happen on the captured day is still the captured day underneath -- the
// sun still sets at 19:57 -- so the timeline stays coherent.
//
// `timeOfDay` scrubs which hour is "now" (0..24 on the fixture's day; -1 is
// the capture's own 19:00). A scenario that is about an hour sets its own
// (`_defaultHour`: the night scenarios 23:00, uv-high 11:00) unless the panel
// has set one. `scenarios` lists every name for a panel's selector.
//
// The scenarios after `heatwave` each put the hero's context line
// (WeatherContext.js) on one rule, named after the situation: rain-soon
// (radar), gusty, frost-tonight, uv-high, colder-tomorrow, dry-spell and
// settled-evening (nothing ahead: the sunset). heatwave shows the warm night,
// fog the clearing time, rain the stop time, the capture itself the next wet
// spell (drizzle tomorrow afternoon).
//
// One FileView per fixture, static path, never repointed (CLAUDE.md: a
// FileView loads on its FIRST path only). `blockLoading` makes text() a
// synchronous read, so the model exists before the first frame.
// =============================================================================
Item {
    id: root

    // --- WeatherService interface -------------------------------------------
    property var model: null
    property bool loading: false
    property bool offline: false
    property string lastError: ""
    property real fetchedAtMs: 0
    property var locations: [
        { name: "Antwerp (fixture)", lat: 51.22, lon: 4.40, elevation: 7, current: false },
        { name: "Leuven (mock)", lat: 50.88, lon: 4.70, elevation: 30, current: false }
    ]
    property int locationIndex: 0
    property var config: ({
        units: {
            temperature: "c", wind: "bft", speed: "kmh", pressure: "hpa", precipitation: "mm",
            distance: "km", airQuality: "ugm3", co: "mgm3", clock: "24h", date: "dd/MM"
        },
        aqIndex: "eaqi",
        glyphSet: "ink",
        view: { start: "mini", remember: "session" },
        look: { secondarySide: "end" },
        refreshMinutes: { forecast: 15, airQuality: 60, kmi: 15, nowcastWhileOpen: 5 }
    })
    property bool popupOpen: false
    signal updated()

    function refresh() {
        root._rebuild();
    }
    // A fetch landing for the place on screen: its scenario becomes `scenario` (the data the cache did not have) and the model
    // carries a new `dataSerial`, which is what the real service does and what makes the popup's cards MOVE to it.
    function landFetch(scenarioName) {
        const l = root.locationScenarios.slice();
        while (l.length <= root.locationIndex)
            l.push("");
        l[root.locationIndex] = scenarioName;
        root.locationScenarios = l;
        root.dataSerial++;
        root._rebuild();
    }
    property int dataSerial: 0
    // False: the model carries no `dataSerial` (a host that predates it): a fetch then SNAPs.
    property bool stampData: true

    function selectLocation(i) {
        if (i < 0 || i >= root.locations.length)
            return;
        root.locationIndex = i;
        root._rebuild();
    }

    // --- the mock's own knobs -------------------------------------------------
    property string scenario: "live-fixture"
    // A scenario of its own per saved place, by index ("" = the scenario above): two places that look different, so a switch
    // between them moves something (for the place morph). Empty: every place shows `scenario`.
    property var locationScenarios: []
    property real timeOfDay: -1
    readonly property var scenarios: [
        "live-fixture", "clear-day", "clear-night", "partly-day", "partly-night", "cloudy", "fog",
        "drizzle", "rain", "heavy-rain", "showers", "sleet", "snow", "hail", "thunder", "windy",
        "heatwave", "rain-soon", "gusty", "frost-tonight", "uv-high", "colder-tomorrow", "dry-spell",
        "settled-evening", "warning", "no-aq", "offline", "loading"
    ]
    // The capture's own "now": 2026-09-16 19:00 Europe/Brussels.
    readonly property real fixtureNowMs: WM.parseLocal("2026-09-16T19:00", 7200)
    // The instant the model was last built for (what `timeOfDay` resolved to).
    readonly property real nowMs: root._nowMs
    property real _nowMs: 0

    // No rebuild before the mock is complete. Its knobs are first assigned
    // while the scene is still being created, and a consumer's binding that
    // reads `config` for the first time FLUSHES that assignment inside its own
    // evaluation: a rebuild there writes `model` under the binding that is
    // reading it (a hero's contextLine reported a binding loop exactly so).
    property bool _complete: false
    onScenarioChanged: if (root._complete) root._rebuild()
    onTimeOfDayChanged: if (root._complete) root._rebuild()
    onConfigChanged: if (root._complete) root._rebuild()
    Component.onCompleted: {
        root._complete = true;
        root._rebuild();
    }

    FileView {
        id: fvForecast
        path: RepoRoot.dir + "/modules/weather/data/fixtures/openmeteo_forecast.json"
        blockLoading: true
        printErrors: false
    }
    FileView {
        id: fvAirQuality
        path: RepoRoot.dir + "/modules/weather/data/fixtures/openmeteo_airquality.json"
        blockLoading: true
        printErrors: false
    }
    FileView {
        id: fvKmi
        path: RepoRoot.dir + "/modules/weather/data/fixtures/kmi_forecasts.json"
        blockLoading: true
        printErrors: false
    }
    FileView {
        id: fvPollenSvg
        path: RepoRoot.dir + "/modules/weather/data/fixtures/kmi_pollen.svg"
        blockLoading: true
        printErrors: false
    }

    // -------------------------------------------------------------------------
    // Build
    // -------------------------------------------------------------------------

    readonly property var _defaultHour: ({ "clear-night": 23, "partly-night": 23, "uv-high": 11 })

    function _effectiveNowMs(sc) {
        let t = root.timeOfDay;
        if (!(t >= 0 && t <= 24))
            t = root._defaultHour[sc] !== undefined ? root._defaultHour[sc] : -1;
        if (t < 0)
            return root.fixtureNowMs;
        const h = Math.min(23, Math.floor(t));
        const m = Math.min(59, Math.round((t - h) * 60));
        return WM.parseLocal("2026-09-16T" + (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m, 7200);
    }

    // The captured radar sequence covers 18:00..22:40 on the fixture's day, so
    // a scrubbed "now" would have no nowcast at all. Slide the sequence by the
    // scrub so the next two hours always exist; the values stay the capture's.
    // The KMI observation slides with it: it is the latest one, "at 19:00" only
    // when now is 19:00.
    function _rebaseKmi(kmi) {
        const delta = root._nowMs - root.fixtureNowMs;
        if (delta === 0)
            return;
        const shift = function (iso) {
            const t = WM.parseLocal(iso, null);
            if (t === null)
                return iso;
            const p = WM.localParts(t + delta);
            const pad = function (n) { return (n < 10 ? "0" : "") + n; };
            return p.year + "-" + pad(p.month) + "-" + pad(p.day) + "T" + pad(p.hour) + ":" + pad(p.minute) + ":00+0"
                + (p.offsetS / 3600) + ":00";
        };
        if (kmi.animation && Array.isArray(kmi.animation.sequence)) {
            const seq = kmi.animation.sequence;
            for (let i = 0; i < seq.length; i++)
                seq[i].time = shift(seq[i].time);
        }
        if (kmi.obs && kmi.obs.timestamp)
            kmi.obs.timestamp = shift(kmi.obs.timestamp);
    }

    function _rebuild() {
        const own = root.locationScenarios[root.locationIndex];
        const sc = typeof own === "string" && own !== "" ? own : root.scenario;
        root._nowMs = root._effectiveNowMs(sc);
        if (sc === "loading") {
            root.loading = true;
            root.offline = false;
            root.lastError = "";
            root.model = null;
            root.updated();
            return;
        }
        root.loading = false;
        let forecast = null, airQuality = null, kmi = null;
        try {
            forecast = JSON.parse(fvForecast.text());
            airQuality = JSON.parse(fvAirQuality.text());
            kmi = JSON.parse(fvKmi.text());
        } catch (e) {
            root.offline = true;
            root.lastError = "fixture unreadable: " + e;
            root.model = null;
            root.updated();
            return;
        }
        kmi.pollenSvg = fvPollenSvg.text();
        root._rebaseKmi(kmi);
        const loc = root.locations[root.locationIndex] || root.locations[0];
        const m = WM.normalise({
            forecast: forecast, airQuality: airQuality, kmi: kmi, config: root.config, nowMs: root._nowMs,
            location: { name: loc.name, lat: loc.lat, lon: loc.lon, elevation: loc.elevation, source: "config", reason: "" }
        });
        const edit = root._scenarioEdits[sc];
        if (edit)
            edit(m);
        root.offline = sc === "offline";
        root.lastError = sc === "offline" ? "Network is unreachable" : "";
        if (root.offline) {
            m.offline = true;
            m.stale = true;
            m.error = root.lastError;
            m.fetchedAtMs = root._nowMs - 47 * 60000;
        }
        root.fetchedAtMs = m.fetchedAtMs;
        if (root.stampData)
            m.dataSerial = root.dataSerial;
        root.model = m;
        root.updated();
    }

    // -------------------------------------------------------------------------
    // Scenario edits. Each takes the normalised model and changes it in place.
    // -------------------------------------------------------------------------

    // Deterministic variation over an index: lo..hi, smooth.
    function _wave(i, lo, hi, phase) {
        return lo + (hi - lo) * (0.5 + 0.5 * Math.sin(i * 1.7 + (phase || 0)));
    }

    function _r1(v) {
        return Math.round(v * 10) / 10;
    }

    // A day's curve: coldest at 05:00, warmest at 17:00.
    function _diurnal(ms, lo, hi) {
        const h = WM.localParts(ms).hour;
        const f = 0.5 - 0.5 * Math.cos((h - 5) / 24 * 2 * Math.PI);
        return root._r1(lo + (hi - lo) * f);
    }

    function _setCondition(h, kind, intensity, code, shower) {
        h.kind = kind;
        h.intensity = intensity;
        h.code = code;
        h.shower = !!shower;
    }

    // The hours a scenario paints: current plus hourly[0..n-1]. `fn(h, i)`
    // sees current as i = -1 (it is a copy of hourly[0], so paint both).
    function _paint(m, n, fn) {
        fn(m.current, -1);
        const count = Math.min(n, m.hourly.length);
        for (let i = 0; i < count; i++)
            fn(m.hourly[i], i);
    }

    // Re-derive the day halves the painted hours fall in -- today's day
    // (sunrise..sunset), tonight (sunset..next sunrise), tomorrow's day -- so
    // the list agrees with the strip whatever hour "now" is: the kind of each
    // touched half becomes the scenario's, its precipitation the painted sum.
    // A half no painted hour reaches keeps the capture's figures.
    function _settleDays(m, spec, n) {
        if (m.daily.length === 0)
            return;
        const d0 = m.daily[0];
        const d1 = m.daily.length > 1 ? m.daily[1] : null;
        const halves = {
            day0: { touched: false, mm: 0, prob: 0, hours: 0 },
            night0: { touched: false, mm: 0, prob: 0, hours: 0 },
            day1: { touched: false, mm: 0, prob: 0, hours: 0 }
        };
        const count = Math.min(n, m.hourly.length);
        for (let i = 0; i < count; i++) {
            const h = m.hourly[i];
            let key = null;
            if (d0.sunriseMs !== null && d0.sunsetMs !== null && h.timeMs >= d0.sunriseMs && h.timeMs < d0.sunsetMs)
                key = "day0";
            else if (d0.sunsetMs !== null && d1 && d1.sunriseMs !== null && h.timeMs >= d0.sunsetMs && h.timeMs < d1.sunriseMs)
                key = "night0";
            else if (d1 && d1.sunriseMs !== null && d1.sunsetMs !== null && h.timeMs >= d1.sunriseMs && h.timeMs < d1.sunsetMs)
                key = "day1";
            if (!key)
                continue;
            const half = halves[key];
            half.touched = true;
            if (h.precip.mm !== null) { half.mm += h.precip.mm; if (h.precip.mm > 0) half.hours++; }
            if (h.precip.prob !== null && h.precip.prob > half.prob) half.prob = h.precip.prob;
        }
        const kindOf = function (night) {
            return { kind: spec.kind, intensity: spec.intensity, night: night, code: spec.code, shower: !!spec.shower };
        };
        if (halves.day0.touched) {
            d0.day = kindOf(false);
            d0.precip.day = root._r1(halves.day0.mm);
        }
        if (halves.night0.touched) {
            d0.night = kindOf(true);
            d0.precip.night = root._r1(halves.night0.mm);
        }
        if (halves.day0.touched || halves.night0.touched) {
            d0.precip.total = root._r1((d0.precip.day || 0) + (d0.precip.night || 0));
            d0.precip.prob = Math.max(halves.day0.prob, halves.night0.prob);
            d0.precip.hours = halves.day0.hours + halves.night0.hours;
        }
        if (d1 && halves.day1.touched) {
            d1.day = kindOf(false);
            d1.precip.day = root._r1(halves.day1.mm);
            d1.precip.total = root._r1(halves.day1.mm + (d1.precip.night || 0));
            d1.precip.prob = Math.max(d1.precip.prob || 0, halves.day1.prob);
        }
        if (m.current.obs) {
            m.current.obs.kind = spec.kind;
            m.current.obs.intensity = spec.intensity;
            m.current.obs.temp = m.current.temp !== null ? Math.round(m.current.temp) : null;
        }
    }

    // The generic condition edit: `spec` = { kind, intensity, code, shower,
    // hours, cloud: [lo,hi], precip: [lo,hi], prob: [lo,hi], sunshine: bool,
    // visibility?, humidity?, temps?: [lo,hi], feels?: delta, dew?: delta,
    // snow?: [lo,hi] cm, night?: bool }.
    function _condition(m, spec) {
        const n = spec.hours || 13;
        root._paint(m, n, function (h, i) {
            const k = i < 0 ? 0 : i;
            root._setCondition(h, spec.kind, spec.intensity, spec.code, spec.shower);
            if (spec.cloud)
                h.cloudCover = Math.round(root._wave(k, spec.cloud[0], spec.cloud[1]));
            if (spec.precip) {
                const mm = root._r1(root._wave(k, spec.precip[0], spec.precip[1], 0.9));
                h.precip.mm = mm;
                h.precip.rain = spec.snow ? 0 : mm;
                h.precip.showers = spec.shower ? mm : 0;
                h.precip.snowCm = 0;
            } else {
                h.precip.mm = 0; h.precip.rain = 0; h.precip.showers = 0; h.precip.snowCm = 0;
            }
            if (spec.snow) {
                const cm = root._r1(root._wave(k, spec.snow[0], spec.snow[1], 0.4));
                h.precip.snowCm = cm;
                if (spec.kind === "snow") {
                    h.precip.mm = root._r1(cm / 7);
                    h.precip.rain = 0;
                }
            }
            if (spec.prob)
                h.precip.prob = Math.round(root._wave(k, spec.prob[0], spec.prob[1], 2.1));
            else
                h.precip.prob = Math.round(root._wave(k, 0, 6));
            if (h.sunshineS !== null)
                h.sunshineS = spec.sunshine && !h.night ? 3600 : 0;
            if (spec.visibility !== undefined)
                h.visibility = spec.visibility;
            if (spec.humidity !== undefined)
                h.humidity = spec.humidity;
            if (spec.temps)
                h.temp = root._diurnal(h.timeMs, spec.temps[0], spec.temps[1]);
            if (h.temp !== null) {
                if (spec.feels !== undefined)
                    h.feelsLike = root._r1(h.temp + spec.feels);
                if (spec.dew !== undefined)
                    h.dewPoint = root._r1(h.temp + spec.dew);
            }
            if (spec.uvMax !== undefined) {
                const hr = WM.localParts(h.timeMs).hour;
                h.uv = (hr > 6 && hr < 20) ? root._r1(spec.uvMax * Math.sin(Math.PI * (hr - 6) / 14)) : 0;
            }
            if (spec.night !== undefined && i < 0)
                h.night = spec.night;
        });
        if (spec.temps && m.daily.length > 0) {
            for (let d = 0; d < Math.min(3, m.daily.length); d++) {
                const D = m.daily[d];
                D.temp = { max: spec.temps[1], min: spec.temps[0] };
                D.feelsLike = {
                    max: root._r1(spec.temps[1] + (spec.feels || 0)),
                    min: root._r1(spec.temps[0] + (spec.feels || 0))
                };
                if (spec.dew !== undefined)
                    D.dewPoint = root._r1((spec.temps[0] + spec.temps[1]) / 2 + spec.dew);
                if (spec.uvMax !== undefined)
                    D.uvMax = spec.uvMax;
                if (spec.humidity !== undefined)
                    D.humidity = spec.humidity;
            }
        }
        if (m.current.obs && spec.night !== undefined)
            m.current.obs.night = spec.night;
        root._settleDays(m, spec, n);
        root._nowcast(m, spec.nowcast || null);
    }

    // Radar nowcast: null keeps the capture (dry); [lo, hi] paints mm per 10 min.
    function _nowcast(m, range) {
        if (!range)
            return;
        for (let i = 0; i < m.nowcast.length; i++)
            m.nowcast[i].mm = root._r1(root._wave(i, range[0], range[1], 1.3));
    }

    // Radar nowcast step by step: `steps[i]` mm for the i-th 10 minutes, 0 past the list.
    function _nowcastSteps(m, steps) {
        for (let i = 0; i < m.nowcast.length; i++)
            m.nowcast[i].mm = i < steps.length ? steps[i] : 0;
    }

    // Dry, settled hours from now for `n` hours: no precipitation, a low
    // probability, the sky given.
    function _dryHours(m, n, kind, code) {
        root._paint(m, n, function (h, i) {
            const k = i < 0 ? 0 : i;
            root._setCondition(h, kind, 1, code, false);
            h.precip.mm = 0; h.precip.rain = 0; h.precip.showers = 0; h.precip.snowCm = 0;
            h.precip.prob = Math.round(root._wave(k, 0, 12));
        });
    }

    // Light rain over the daytime hours of daily[d]'s date, 10:00-16:00:
    // `mmPerHour` each, so a hand-set day total has hours that add up to it.
    function _wetDaytime(m, d, mmPerHour) {
        if (d >= m.daily.length)
            return;
        const key = WM.dateKey(m.daily[d].dateMs);
        for (let i = 0; i < m.hourly.length; i++) {
            const h = m.hourly[i];
            const hr = WM.localParts(h.timeMs).hour;
            if (WM.dateKey(h.timeMs) !== key || hr < 10 || hr > 16)
                continue;
            root._setCondition(h, "rain", 0, 61, false);
            h.precip.mm = mmPerHour; h.precip.rain = mmPerHour; h.precip.showers = 0;
            h.precip.prob = 75;
            h.cloudCover = 95;
        }
    }

    // A day half's sky, for the days a scenario settles by hand.
    function _halves(D, dayKind, dayCode, nightKind, nightCode) {
        D.day = { kind: dayKind, intensity: 1, night: false, code: dayCode, shower: false };
        D.night = { kind: nightKind, intensity: 1, night: true, code: nightCode, shower: false };
    }

    // Wind on every hour and both halves of the first two days.
    function _wind(m, speedLo, speedHi, gustLo, gustHi, dir) {
        root._paint(m, 48, function (h, i) {
            const k = i < 0 ? 0 : i;
            h.wind = root._makeWind(root._r1(root._wave(k, speedLo, speedHi)), dir,
                                    root._r1(root._wave(k, gustLo, gustHi, 0.7)));
        });
        for (let d = 0; d < Math.min(2, m.daily.length); d++) {
            const D = m.daily[d];
            D.wind.day = root._makeWind(root._r1((speedLo + speedHi) / 2), dir, gustHi);
            D.wind.night = root._makeWind(root._r1((speedLo + speedHi) / 2), dir, gustHi);
        }
    }

    function _makeWind(speed, dir, gust) {
        const bft = function (v) { return v === null ? null : WM.bftOf(v); };
        return { speed: speed, dir: dir, bft: bft(speed), gust: gust, gustBft: bft(gust), dirText: WM.compass(dir) };
    }

    // Air quality on every hour that has one, and the first days.
    function _aq(m, index, pm25, pm10, o3, no2, so2, co) {
        const set = function (h) {
            if (h.aq)
                h.aq = WM.makeAq(m.aqIndex, index, pm25, pm10, o3, no2, so2, co);
        };
        root._paint(m, 48, function (h) { set(h); });
        for (let d = 0; d < Math.min(3, m.daily.length); d++)
            set(m.daily[d]);
    }

    function _pollen(m, concs) {
        const set = function (h) {
            if (h.pollen)
                h.pollen = WM.makePollen(concs);
        };
        root._paint(m, 48, function (h) { set(h); });
        for (let d = 0; d < Math.min(3, m.daily.length); d++)
            set(m.daily[d]);
    }

    function _warn(m, list) {
        m.warnings = WM.parseWarnings(list);
    }

    // The KMI app's warning shape (irm-kmi's reading of it; the capture has none).
    function _kmiWarning(id, name, level, hoursFrom, hoursTo, text) {
        const iso = function (ms) {
            const p = WM.localParts(ms);
            const pad = function (n) { return (n < 10 ? "0" : "") + n; };
            return p.year + "-" + pad(p.month) + "-" + pad(p.day) + "T" + pad(p.hour) + ":" + pad(p.minute) + ":00+0"
                + (p.offsetS / 3600) + ":00";
        };
        return {
            warningType: { id: id, name: { nl: name, fr: name, en: name, de: name } },
            warningLevel: level,
            fromTimestamp: iso(root._nowMs + hoursFrom * 3600000),
            toTimestamp: iso(root._nowMs + hoursTo * 3600000),
            text: { nl: text, fr: text, en: text, de: text }
        };
    }

    readonly property var _scenarioEdits: ({
        "clear-day": function (m) {
            root._condition(m, { kind: "clear", intensity: 1, code: 0, cloud: [0, 8], sunshine: true, night: false });
        },
        "clear-night": function (m) {
            root._condition(m, { kind: "clear", intensity: 1, code: 0, cloud: [0, 8], sunshine: true, night: true });
        },
        "partly-day": function (m) {
            root._condition(m, { kind: "partly", intensity: 1, code: 2, cloud: [35, 60], sunshine: true, night: false });
        },
        "partly-night": function (m) {
            root._condition(m, { kind: "partly", intensity: 1, code: 2, cloud: [35, 60], sunshine: true, night: true });
        },
        "cloudy": function (m) {
            root._condition(m, { kind: "cloudy", intensity: 1, code: 3, cloud: [92, 100], sunshine: false, prob: [5, 15] });
        },
        "fog": function (m) {
            root._condition(m, { kind: "fog", intensity: 1, code: 45, cloud: [95, 100], sunshine: false,
                                 visibility: 400, humidity: 97, dew: -0.3, feels: -1 });
            root._wind(m, 3, 6, 6, 11, 140);
        },
        "drizzle": function (m) {
            root._condition(m, { kind: "rain", intensity: 0, code: 53, cloud: [96, 100], precip: [0.1, 0.4],
                                 prob: [60, 80], sunshine: false, humidity: 93, dew: -1, nowcast: [0, 0.1] });
        },
        "rain": function (m) {
            root._condition(m, { kind: "rain", intensity: 1, code: 63, cloud: [90, 100], precip: [1, 4],
                                 prob: [70, 95], sunshine: false, humidity: 90, dew: -1.5, nowcast: [0.2, 0.7] });
        },
        "heavy-rain": function (m) {
            root._condition(m, { kind: "rain", intensity: 2, code: 65, cloud: [100, 100], precip: [6, 12],
                                 prob: [95, 100], sunshine: false, humidity: 95, dew: -0.8, visibility: 2000,
                                 nowcast: [1.0, 2.2] });
        },
        "showers": function (m) {
            root._condition(m, { kind: "rain", intensity: 1, code: 81, shower: true, cloud: [55, 80],
                                 precip: [0.5, 3], prob: [50, 70], sunshine: true, nowcast: [0, 0.9] });
            // Showers come and go: every third hour clears to a break in the cloud.
            root._paint(m, 13, function (h, i) {
                if (i > 0 && i % 3 === 0) {
                    root._setCondition(h, "partly", 1, 2, false);
                    h.precip.mm = 0; h.precip.rain = 0; h.precip.showers = 0;
                    h.precip.prob = 25;
                }
            });
        },
        "sleet": function (m) {
            root._condition(m, { kind: "sleet", intensity: 1, code: 66, cloud: [95, 100], precip: [0.8, 2.0],
                                 prob: [75, 90], sunshine: false, temps: [0, 2], feels: -4, dew: -1,
                                 humidity: 92, snow: [0.2, 0.5], nowcast: [0.1, 0.4] });
        },
        "snow": function (m) {
            root._condition(m, { kind: "snow", intensity: 1, code: 73, cloud: [95, 100], prob: [80, 95],
                                 sunshine: false, temps: [-3, 1], feels: -4, dew: -1, humidity: 90,
                                 snow: [0.5, 2.0], visibility: 1500, nowcast: [0.1, 0.3] });
        },
        "hail": function (m) {
            root._condition(m, { kind: "hail", intensity: 1, code: 96, cloud: [95, 100], precip: [4, 8],
                                 prob: [85, 95], sunshine: false, humidity: 88, nowcast: [0.5, 2.5] });
            root._paint(m, 13, function (h, i) {
                if (i >= 3 && i < 6) {
                    root._setCondition(h, "rain", 1, 63, false);
                    h.precip.mm = root._r1(root._wave(i, 1.5, 3)); h.precip.rain = h.precip.mm;
                } else if (i >= 6) {
                    root._setCondition(h, "partly", 1, 2, false);
                    h.precip.mm = 0; h.precip.rain = 0; h.precip.prob = 15;
                    h.cloudCover = 50;
                }
            });
        },
        "thunder": function (m) {
            root._condition(m, { kind: "thunder", intensity: 1, code: 95, cloud: [95, 100], precip: [4, 8],
                                 prob: [85, 95], sunshine: false, humidity: 88, nowcast: [0.4, 1.8] });
            root._paint(m, 13, function (h, i) {
                if (i >= 5 && i < 9) {
                    root._setCondition(h, "rain", 1, 63, false);
                    h.precip.mm = root._r1(root._wave(i, 1, 3)); h.precip.rain = h.precip.mm;
                } else if (i >= 9) {
                    root._setCondition(h, "partly", 1, 2, false);
                    h.precip.mm = 0; h.precip.rain = 0; h.precip.prob = 20;
                    h.cloudCover = 45;
                }
            });
            root._warn(m, [root._kmiWarning(3, "Thunderstorm", 1, -1, 6,
                "Thunderstorms with local downpours of 10 to 20 mm in an hour and gusts up to 70 km/h.")]);
        },
        "windy": function (m) {
            root._condition(m, { kind: "partly", intensity: 1, code: 2, cloud: [40, 70], sunshine: true, prob: [5, 20] });
            root._wind(m, 52, 60, 76, 88, 250);
        },
        "heatwave": function (m) {
            root._condition(m, { kind: "clear", intensity: 1, code: 0, cloud: [0, 5], sunshine: true, hours: 48,
                                 temps: [22, 34], feels: 3, dew: -9, humidity: 55, uvMax: 9 });
            // dew: -9 off a 22..34 curve lands the afternoon at ~20 (muggy), as asked.
            root._paint(m, 48, function (h) { if (h.temp !== null) h.dewPoint = root._r1(Math.min(20, h.temp - 9)); });
            root._wind(m, 6, 12, 14, 22, 90);
            root._aq(m, 65, 12, 25, 200, 20, 1.5, 250);
            root._pollen(m, { alder: 0, birch: 0, grass: 30, mugwort: 8, olive: 0, ragweed: 0.5 });
            m.pollenNote = "Grass";
        },
        // Dry now; the radar shows a shower passing 19:40-20:40 (the hour
        // after says light rain, so strip and line agree).
        "rain-soon": function (m) {
            root._condition(m, { kind: "partly", intensity: 1, code: 2, cloud: [45, 70], sunshine: true, prob: [5, 20] });
            if (m.hourly.length > 1) {
                const h = m.hourly[1];
                root._setCondition(h, "rain", 0, 61, false);
                h.precip.mm = 0.8; h.precip.rain = 0.8; h.precip.prob = 70;
                h.cloudCover = 90;
            }
            root._nowcastSteps(m, [0, 0, 0, 0.2, 0.6, 1.2, 0.9, 0.4, 0.1, 0, 0, 0]);
        },
        // Calm evening, gusts building overnight: 30 km/h now, 60 km/h and more
        // from 01:00 to 06:00 (72 at the peak). Dry, so nothing outranks them.
        "gusty": function (m) {
            root._condition(m, { kind: "partly", intensity: 1, code: 2, cloud: [50, 80], sunshine: true, prob: [5, 25], hours: 26 });
            const gustAt = function (i) {
                if (i < 4) return 30 + i * 2;
                if (i < 6) return 30 + (i - 3) * 14;
                if (i < 10) return 66 + Math.min(6, (i - 5) * 3);
                return Math.max(28, 72 - (i - 9) * 11);
            };
            root._paint(m, 26, function (h, i) {
                const k = i < 0 ? 0 : i;
                const g = gustAt(k);
                h.wind = root._makeWind(root._r1(g * 0.55), 240, g);
            });
            const D = m.daily[0];
            D.wind.night = root._makeWind(28, 240, 72);
        },
        // A clear, cold evening: 8° now, -2° before dawn. Today's own low was
        // this morning's 5°, so the line keeps its depth ("down to -2°"); had
        // the card's L been -2° the rule would have dropped it
        // (WeatherContext.js, THE CARD'S FIGURES).
        "frost-tonight": function (m) {
            root._condition(m, { kind: "clear", intensity: 1, code: 0, cloud: [0, 8], sunshine: true, hours: 48,
                                 temps: [-2, 9], feels: -2, dew: -3, humidity: 80 });
            if (m.daily.length > 1) {
                m.daily[0].temp = { max: 9, min: 5 };
                m.daily[0].feelsLike = { max: 7, min: 3 };
                m.daily[1].temp = { max: 9, min: -2 };
                m.daily[1].feelsLike = { max: 7, min: -4 };
            }
        },
        // A clear late morning in high summer: UV 8 at its peak, above 6
        // until 17:00. Dry until tomorrow noon.
        "uv-high": function (m) {
            root._condition(m, { kind: "clear", intensity: 1, code: 0, cloud: [0, 10], sunshine: true, hours: 13,
                                 uvMax: 8.4, temps: [15, 26], feels: 1, dew: -10, humidity: 50 });
        },
        // A warm day, a cold front overnight: tomorrow 8° colder. Dry for the
        // next day, so the swing is the news.
        "colder-tomorrow": function (m) {
            root._dryHours(m, 30, "partly", 2);
            const today = WM.dateKey(root._nowMs);
            root._paint(m, 30, function (h) {
                const onToday = WM.dateKey(h.timeMs) === today;
                h.temp = onToday ? root._diurnal(h.timeMs, 14, 24) : root._diurnal(h.timeMs, 9, 16);
                h.feelsLike = root._r1(h.temp - 1);
                h.dewPoint = root._r1(h.temp - 6);
            });
            if (m.daily.length > 2) {
                m.daily[0].temp = { max: 24, min: 14 };
                m.daily[0].feelsLike = { max: 23, min: 13 };
                m.daily[0].precip = { day: 0, night: 0, total: 0, prob: 5, hours: 0 };
                root._halves(m.daily[0], "clear", 0, "partly", 2);
                m.daily[1].temp = { max: 16, min: 9 };
                m.daily[1].feelsLike = { max: 15, min: 7 };
                m.daily[1].precip = { day: 0, night: 0, total: 0, prob: 15, hours: 0 };
                root._halves(m.daily[1], "cloudy", 3, "partly", 2);
            }
        },
        // High pressure: dry until Monday, when rain returns.
        "dry-spell": function (m) {
            root._dryHours(m, 24 * 7, "clear", 0);
            for (let d = 0; d < Math.min(6, m.daily.length); d++) {
                const D = m.daily[d];
                D.precip = { day: 0, night: 0, total: 0, prob: 5 + d * 2, hours: 0 };
                root._halves(D, d % 2 ? "partly" : "clear", d % 2 ? 2 : 0, "clear", 0);
            }
            if (m.daily.length > 5) {
                const D = m.daily[5];
                D.precip = { day: 4.2, night: 0, total: 4.2, prob: 75, hours: 7 };
                root._halves(D, "rain", 61, "partly", 2);
                root._wetDaytime(m, 5, 0.6);
            }
        },
        // Nothing ahead worth a line: dry and calm for a day, rain only on
        // Friday. The line falls back to the sunset.
        "settled-evening": function (m) {
            root._dryHours(m, 30, "partly", 2);
            if (m.daily.length > 2) {
                m.daily[0].precip = { day: 0, night: 0, total: 0, prob: 5, hours: 0 };
                root._halves(m.daily[0], "partly", 2, "partly", 2);
                m.daily[1].precip = { day: 0, night: 0, total: 0, prob: 20, hours: 0 };
                root._halves(m.daily[1], "partly", 2, "cloudy", 3);
                m.daily[2].precip = { day: 3.5, night: 0, total: 3.5, prob: 70, hours: 7 };
                root._halves(m.daily[2], "rain", 61, "partly", 2);
                root._wetDaytime(m, 2, 0.5);
            }
        },
        "warning": function (m) {
            root._scenarioEdits["thunder"](m);
            root._wind(m, 52, 60, 80, 95, 240);
            root._warn(m, [
                root._kmiWarning(0, "Wind", 2, -2, 10, "Gusts of 90 to 100 km/h are expected, locally more along the coast."),
                root._kmiWarning(3, "Thunderstorm", 1, -1, 6, "Thunderstorms with local downpours and hail.")
            ]);
        },
        "no-aq": function (m) {
            root._paint(m, m.hourly.length, function (h) { h.aq = null; h.pollen = null; });
            for (let d = 0; d < m.daily.length; d++) {
                m.daily[d].aq = null;
                m.daily[d].pollen = null;
            }
            m.pollenNote = null;
        },
        "offline": function () {
            // The flags are set by _rebuild; the data is the capture as it was.
        }
    })
}
