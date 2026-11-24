.pragma library
.import "WeatherScales.js" as Scales

// =============================================================================
// WeatherModel.js -- the normaliser. Three raw responses in, ONE model out.
//
//     WM.normalise({ forecast, airQuality, kmi, config, nowMs, location }) -> model
//     WM.format(units)                          -> F, the formatter (F.temp(v) -> "18°" ...)
//     WM.conditionText(kind, intensity, night [, shower, code]) -> "Light rain"
//     WM.parseLocal("2026-09-16T19:00", 7200)   -> epoch ms
//     WM.parseWarnings(kmiWarningList)          -> [ { level, type, title, text, fromMs, toMs } ]
//
// The shapes are the model contract; every UI reads exactly those field names. Canonical units inside the model:
// °C, km/h, hPa, mm, m, %, µg/m³, grains/m³, s. Times are epoch ms. Anything
// that can be missing is null -- never NaN, never undefined.
//
// TIME. Open-Meteo answers with naive local ISO strings in the requested zone
// (Europe/Brussels) and labels ALL of them at the one `utc_offset_seconds` it
// reports, the offset at the request's instant (a winter request labels July at
// +1; measured). That offset, kept in the raw response, turns a label into an
// instant (`normalise`), so a 16-day window that crosses a DST change stays
// right on both sides and a cached response stays right when it is read again.
// Everything the model SHOWS is the Brussels rule (EU DST: last Sunday of March
// 01:00 UTC to last Sunday of October 01:00 UTC) applied to the instant: the
// date an hour belongs to, its clock hour, the weekday. The rule also parses
// the timestamps that carry no offset (KMI). Nothing here reads the machine's
// timezone: no `new Date(iso)` of a naive string, no getHours(). Only
// `Date.UTC` arithmetic. (tools/dev/dst_audit_cases.js holds this.)
//
// Pure JS: no Qt, no console. WeatherScales.js supplies every band.
// =============================================================================

// -----------------------------------------------------------------------------
// Code tables
// -----------------------------------------------------------------------------

// WMO weather_code -> { kind, intensity, shower }.
var WMO_KINDS = {
    0: { kind: "clear", intensity: 1, shower: false },
    1: { kind: "clear", intensity: 1, shower: false },
    2: { kind: "partly", intensity: 1, shower: false },
    3: { kind: "cloudy", intensity: 1, shower: false },
    45: { kind: "fog", intensity: 1, shower: false },
    48: { kind: "fog", intensity: 1, shower: false },
    51: { kind: "rain", intensity: 0, shower: false },
    53: { kind: "rain", intensity: 0, shower: false },
    55: { kind: "rain", intensity: 0, shower: false },
    56: { kind: "sleet", intensity: 0, shower: false },
    57: { kind: "sleet", intensity: 0, shower: false },
    61: { kind: "rain", intensity: 0, shower: false },
    63: { kind: "rain", intensity: 1, shower: false },
    65: { kind: "rain", intensity: 2, shower: false },
    66: { kind: "sleet", intensity: 1, shower: false },
    67: { kind: "sleet", intensity: 2, shower: false },
    71: { kind: "snow", intensity: 0, shower: false },
    73: { kind: "snow", intensity: 1, shower: false },
    75: { kind: "snow", intensity: 2, shower: false },
    77: { kind: "snow", intensity: 0, shower: false },
    80: { kind: "rain", intensity: 0, shower: true },
    81: { kind: "rain", intensity: 1, shower: true },
    82: { kind: "rain", intensity: 2, shower: true },
    85: { kind: "snow", intensity: 0, shower: true },
    86: { kind: "snow", intensity: 1, shower: true },
    95: { kind: "thunder", intensity: 1, shower: false },
    96: { kind: "hail", intensity: 1, shower: false },
    99: { kind: "hail", intensity: 2, shower: false }
};

// KMI `ww` icon code -> { kind, intensity } (irm-kmi's table).
var KMI_KINDS = {
    0: { kind: "clear", intensity: 1 },
    1: { kind: "clear", intensity: 1 },
    2: { kind: "thunder", intensity: 1 },
    3: { kind: "partly", intensity: 1 },
    4: { kind: "rain", intensity: 2 },
    5: { kind: "thunder", intensity: 1 },
    6: { kind: "rain", intensity: 2 },
    7: { kind: "thunder", intensity: 1 },
    8: { kind: "sleet", intensity: 1 },
    9: { kind: "sleet", intensity: 1 },
    10: { kind: "snow", intensity: 1 },
    11: { kind: "snow", intensity: 1 },
    12: { kind: "snow", intensity: 1 },
    13: { kind: "thunder", intensity: 1 },
    14: { kind: "cloudy", intensity: 1 },
    15: { kind: "cloudy", intensity: 1 },
    16: { kind: "rain", intensity: 2 },
    17: { kind: "thunder", intensity: 1 },
    18: { kind: "rain", intensity: 1 },
    19: { kind: "rain", intensity: 2 },
    20: { kind: "sleet", intensity: 1 },
    21: { kind: "rain", intensity: 1 },
    22: { kind: "snow", intensity: 1 },
    23: { kind: "snow", intensity: 1 },
    24: { kind: "fog", intensity: 1 },
    25: { kind: "fog", intensity: 1 },
    26: { kind: "fog", intensity: 1 },
    27: { kind: "fog", intensity: 1 }
};

// KMI warning type id -> slug (the irm-kmi integration's SLUG_MAP). The
// captured fixture carries no warning, so this is the integration's word,
// not a capture's; parseWarnings falls back to the English name when an id
// is not listed here.
var KMI_WARNING_TYPES = {
    0: "wind", 1: "rain", 2: "ice_or_snow", 3: "thunder", 7: "fog", 9: "cold",
    12: "thunder_wind_rain", 13: "thunderstorm_strong_gusts",
    14: "thunderstorm_large_rainfall", 15: "storm_surge", 17: "coldspell"
};

// The worst precipitation kind wins a night; skies are
// decided by frequency instead.
var PRECIP_RANK = { thunder: 6, hail: 5, snow: 4, sleet: 3, rain: 2, fog: 1 };
var SKY_KINDS = ["clear", "partly", "cloudy"];

var POLLEN_IDS = ["alder", "birch", "grass", "mugwort", "olive", "ragweed"];
var COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
               "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"];
var WEEKDAYS_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
var WEEKDAYS_LONG = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
var MONTHS_SHORT = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

var DASH = "–";     // the "no figure" glyph, an en dash
var HOUR_MS = 3600000;
var DAY_MS = 86400000;

// Default units (weather.jsonc's `units`), Belgian conventions.
var DEFAULT_UNITS = {
    temperature: "c", wind: "bft", speed: "kmh", pressure: "hpa", precipitation: "mm",
    distance: "km", airQuality: "ugm3", co: "mgm3", clock: "24h", date: "dd/MM"
};

// -----------------------------------------------------------------------------
// Small helpers
// -----------------------------------------------------------------------------

function num(v) {
    // A figure or null. Strings that are numbers (KMI sends "20" for a
    // percentage) count; "" and null do not.
    if (v === null || v === undefined || v === "")
        return null;
    const n = typeof v === "number" ? v : Number(v);
    return isFinite(n) ? n : null;
}

function pad2(n) {
    return (n < 10 ? "0" : "") + n;
}

function at(arr, i) {
    // arr[i] as a figure or null (missing array, short array, null cell).
    if (!arr || i < 0 || i >= arr.length)
        return null;
    return num(arr[i]);
}

function strAt(arr, i) {
    if (!arr || i < 0 || i >= arr.length)
        return null;
    const s = arr[i];
    return (typeof s === "string" && s.length > 0) ? s : null;
}

function langText(v) {
    // KMI sends { nl, fr, en, de }; take English, fall back to Dutch, accept a bare string.
    if (v === null || v === undefined)
        return null;
    if (typeof v === "string")
        return v.length > 0 ? v : null;
    if (typeof v === "object") {
        const s = v.en || v.nl || v.fr || v.de;
        return (typeof s === "string" && s.length > 0) ? s : null;
    }
    return null;
}

function mean(list) {
    let s = 0, n = 0;
    for (let i = 0; i < list.length; i++) {
        const v = list[i];
        if (v !== null) { s += v; n++; }
    }
    return n > 0 ? s / n : null;
}

function maxOf(list) {
    let m = null;
    for (let i = 0; i < list.length; i++) {
        const v = list[i];
        if (v !== null && (m === null || v > m))
            m = v;
    }
    return m;
}

function sumOf(list) {
    let s = null;
    for (let i = 0; i < list.length; i++) {
        const v = list[i];
        if (v !== null)
            s = (s === null ? 0 : s) + v;
    }
    return s;
}

function round1(v) {
    return Math.round(v * 10) / 10;
}

// -----------------------------------------------------------------------------
// Time: Europe/Brussels, by rule
// -----------------------------------------------------------------------------

function _lastSundayUtc(year, month0) {
    // 01:00 UTC on the last Sunday of the month, as epoch ms.
    const lastDay = new Date(Date.UTC(year, month0 + 1, 0));
    const day = lastDay.getUTCDate() - lastDay.getUTCDay();
    return Date.UTC(year, month0, day, 1, 0, 0);
}

// The Brussels UTC offset in SECONDS at a UTC instant: 7200 in summer time,
// 3600 otherwise (EU rule).
function brusselsOffset(utcMs) {
    const y = new Date(utcMs).getUTCFullYear();
    const start = _lastSundayUtc(y, 2);
    const end = _lastSundayUtc(y, 9);
    return (utcMs >= start && utcMs < end) ? 7200 : 3600;
}

// The Brussels offset for a naive LOCAL wall time: evaluate the rule at the
// instant assuming winter time; the transition hour itself is the only
// ambiguity and Open-Meteo skips or repeats it anyway.
function _brusselsOffsetForLocal(localAsUtcMs) {
    return brusselsOffset(localAsUtcMs - 3600000);
}

var ISO_RE = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?\s*(Z|[+-]\d{2}:?\d{2})?$/;

// Parse an ISO timestamp to epoch ms. An explicit offset in the string wins;
// else `utcOffsetSeconds` when it is a number; else the Brussels rule.
// Returns null for anything unparsable (a missing figure is null, not NaN).
function parseLocal(iso, utcOffsetSeconds) {
    if (typeof iso !== "string")
        return null;
    const m = ISO_RE.exec(iso.trim());
    if (!m)
        return null;
    const y = +m[1], mo = +m[2], d = +m[3];
    const h = m[4] !== undefined ? +m[4] : 0;
    const mi = m[5] !== undefined ? +m[5] : 0;
    const s = m[6] !== undefined ? +m[6] : 0;
    const wall = Date.UTC(y, mo - 1, d, h, mi, s);
    let off;
    if (m[7] !== undefined) {
        if (m[7] === "Z") {
            off = 0;
        } else {
            const sign = m[7][0] === "-" ? -1 : 1;
            const digits = m[7].slice(1).replace(":", "");
            off = sign * (Number(digits.slice(0, 2)) * 3600 + Number(digits.slice(2, 4)) * 60);
        }
    } else if (typeof utcOffsetSeconds === "number" && isFinite(utcOffsetSeconds)) {
        off = utcOffsetSeconds;
    } else {
        off = _brusselsOffsetForLocal(wall);
    }
    return wall - off * 1000;
}

// Local (Brussels) wall-clock parts of an epoch ms.
function localParts(ms) {
    const off = brusselsOffset(ms);
    const d = new Date(ms + off * 1000);
    return {
        year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate(),
        hour: d.getUTCHours(), minute: d.getUTCMinutes(), second: d.getUTCSeconds(),
        weekday: d.getUTCDay(), offsetS: off
    };
}

// "YYYY-MM-DD" of the local date an instant falls on.
function dateKey(ms) {
    if (typeof ms !== "number" || !isFinite(ms))
        return null;
    const p = localParts(ms);
    return p.year + "-" + pad2(p.month) + "-" + pad2(p.day);
}

// -----------------------------------------------------------------------------
// Kinds
// -----------------------------------------------------------------------------

function kindOfWmo(code) {
    const c = num(code);
    if (c === null)
        return { kind: null, intensity: null, shower: false, code: null };
    const k = WMO_KINDS[c];
    if (!k)
        return { kind: null, intensity: null, shower: false, code: c };
    return { kind: k.kind, intensity: k.intensity, shower: k.shower, code: c };
}

function kindOfKmi(ww) {
    const c = num(ww);
    if (c === null)
        return { kind: null, intensity: null, code: null };
    const k = KMI_KINDS[c];
    if (!k)
        return { kind: null, intensity: null, code: c };
    return { kind: k.kind, intensity: k.intensity, code: c };
}

// English condition text, sentence case. `shower` and `code` are optional:
// they tell drizzle (51-55) from light rain (61) and showers from steady rain.
function conditionText(kind, intensity, night, shower, code) {
    const c = num(code);
    switch (kind) {
    case "clear": return night ? "Clear night" : "Clear";
    case "partly": return "Partly cloudy";
    case "cloudy": return "Cloudy";
    case "fog": return "Fog";
    case "wind": return "Windy";
    case "rain":
        if (shower)
            return "Rain showers";
        if (c !== null && c >= 51 && c <= 55)
            return "Drizzle";
        return intensity === 0 ? "Light rain" : (intensity === 2 ? "Heavy rain" : "Rain");
    case "sleet":
        return intensity === 0 ? "Freezing drizzle" : "Sleet";
    case "snow":
        if (shower)
            return "Snow showers";
        return intensity === 0 ? "Light snow" : (intensity === 2 ? "Heavy snow" : "Snow");
    case "thunder": return "Thunderstorm";
    // WMO 96 / 99, "thunderstorm with slight / heavy hail". Named as a
    // hailstorm, with "Heavy" as rain and snow have it: the long form does not
    // fit the hero's condition line beside a full-height glyph in mini or
    // detailed (every label must fit).
    case "hail": return intensity === 2 ? "Heavy hailstorm" : "Hailstorm";
    default: return DASH;
    }
}

// Every text conditionText() can return, once each: what a slot that shows a
// condition must be measured against.
function conditionTexts() {
    const out = [];
    for (const k of ["clear", "partly", "cloudy", "fog", "wind", "rain", "sleet", "snow", "thunder", "hail"])
        for (const i of [0, 1, 2])
            for (const n of [false, true])
                for (const s of [false, true])
                    for (const c of [null, 53]) {
                        const t = conditionText(k, i, n, s, c);
                        if (out.indexOf(t) < 0)
                            out.push(t);
                    }
    return out;
}

// 16-point compass text of a meteorological direction (degrees FROM).
function compass(deg) {
    const d = num(deg);
    if (d === null)
        return null;
    return COMPASS[Math.round((((d % 360) + 360) % 360) / 22.5) % 16];
}

// KMI's `windDirection` is where the wind blows TO; meteorology says FROM.
function kmiWindFrom(deg) {
    const d = num(deg);
    return d === null ? null : (((d + 180) % 360) + 360) % 360;
}

function bftOf(kmh) {
    const b = Scales.beaufort(kmh);
    return b ? b.bft : null;
}

function makeWind(speed, dir, gust) {
    speed = num(speed); dir = num(dir); gust = num(gust);
    return {
        speed: speed, dir: dir, bft: bftOf(speed), gust: gust, gustBft: bftOf(gust), dirText: compass(dir)
    };
}

// -----------------------------------------------------------------------------
// Air quality and pollen
// -----------------------------------------------------------------------------

function makeAq(aqIndex, index, pm25, pm10, o3, no2, so2, co) {
    index = num(index);
    const b = Scales.bandOf(aqIndex, index);
    return {
        index: index, band: b ? b.band : null,
        pm25: num(pm25), pm10: num(pm10), o3: num(o3), no2: num(no2), so2: num(so2), co: num(co)
    };
}

// concs: { alder: n|null, ... }. null when every species is null; primary is
// the highest level (ties: highest concentration), null when nothing is active.
function makePollen(concs) {
    let any = false;
    const species = [];
    for (let i = 0; i < POLLEN_IDS.length; i++) {
        const id = POLLEN_IDS[i];
        const conc = num(concs[id]);
        const lv = Scales.pollenLevel(id, conc);
        if (conc !== null)
            any = true;
        species.push({
            id: id,
            name: lv ? lv.species : (Scales.SCALES.pollen.species[id].name),
            conc: conc,
            level: lv ? lv.level : null,
            levelName: lv ? lv.name : null,
            band: lv ? lv.band : null
        });
    }
    if (!any)
        return null;
    let best = null;
    for (let i = 0; i < species.length; i++) {
        const s = species[i];
        if (s.level === null || s.level < 1)
            continue;
        if (best === null || s.level > best.level || (s.level === best.level && s.conc > best.conc))
            best = s;
    }
    return {
        primary: best ? { species: best.id, name: best.name, conc: best.conc, level: best.level,
                          levelName: best.levelName, band: best.band } : null,
        species: species
    };
}

// -----------------------------------------------------------------------------
// KMI pieces
// -----------------------------------------------------------------------------

// KMI app warnings -> the model's list. Defensive: the captured fixture has
// none, so the shape (warningType { id, name{} }, warningLevel, fromTimestamp,
// toTimestamp, text{}) is the irm-kmi integration's reading of the API.
function parseWarnings(list) {
    const out = [];
    if (!Array.isArray(list))
        return out;
    for (let i = 0; i < list.length; i++) {
        const w = list[i];
        if (!w || typeof w !== "object")
            continue;
        const wt = (w.warningType && typeof w.warningType === "object") ? w.warningType : {};
        const id = num(wt.id !== undefined ? wt.id : w.warningTypeId);
        const name = langText(wt.name) || langText(w.warningType) || null;
        let type = (id !== null && KMI_WARNING_TYPES[id]) ? KMI_WARNING_TYPES[id] : null;
        if (type === null)
            type = name ? name.toLowerCase().replace(/[^a-z0-9]+/g, "_") : "unknown";
        const level = num(w.warningLevel !== undefined ? w.warningLevel : w.level);
        const title = name || (type.charAt(0).toUpperCase() + type.slice(1).replace(/_/g, " "));
        out.push({
            level: level === null ? 1 : Math.max(1, Math.min(3, Math.round(level))),
            type: type,
            title: title,
            text: langText(w.text) || "",
            fromMs: parseLocal(w.fromTimestamp || w.from || null, null),
            toMs: parseLocal(w.toTimestamp || w.to || null, null)
        });
    }
    return out;
}

// The radar sequence after `nowMs`: the next two hours in 10-minute steps.
function parseNowcast(animation, nowMs) {
    const out = [];
    const seq = animation && Array.isArray(animation.sequence) ? animation.sequence : null;
    if (!seq)
        return out;
    for (let i = 0; i < seq.length && out.length < 12; i++) {
        const e = seq[i];
        if (!e || typeof e !== "object")
            continue;
        const t = parseLocal(e.time, null);
        if (t === null || t <= nowMs)
            continue;
        const v = num(e.value);
        out.push({ timeMs: t, mm: v === null ? 0 : v });
    }
    return out;
}

function _decodeXml(s) {
    return s.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
            .replace(/&quot;/g, "\"").replace(/&#39;/g, "'").replace(/&apos;/g, "'");
}

// The pollen module SVG's note: the non-empty <tspan> texts after the one that
// reads "Active pollen", joined. null when that anchor is not there (fail
// closed: a layout this parser does not know is not a "no warning").
function parsePollenSvg(svgText) {
    if (typeof svgText !== "string" || svgText.length === 0)
        return null;
    const re = /<tspan\b[^>]*>([^<]*)<\/tspan>/g;
    const texts = [];
    let m;
    while ((m = re.exec(svgText)) !== null)
        texts.push(_decodeXml(m[1]).trim());
    let anchor = -1;
    for (let i = 0; i < texts.length; i++) {
        if (texts[i].toLowerCase() === "active pollen") { anchor = i; break; }
    }
    if (anchor < 0)
        return null;
    const rest = [];
    for (let i = anchor + 1; i < texts.length; i++) {
        if (texts[i].length > 0)
            rest.push(texts[i]);
    }
    return rest.length > 0 ? rest.join(", ") : null;
}

// KMI's daily list carries no dates: it opens with "Tonight"/"Today" and runs
// forward by weekday name. Map each entry to a "YYYY-MM-DD" from today's key;
// entries landing on the same date are joined. Anything unrecognised is
// skipped (null for that day rather than a guess).
function _kmiDailyTexts(kmiDaily, todayKey) {
    const out = {};
    if (!Array.isArray(kmiDaily) || !todayKey)
        return out;
    const base = parseLocal(todayKey + "T12:00", null);
    if (base === null)
        return out;
    let cursor = 0;           // days after today the list has reached
    for (let i = 0; i < kmiDaily.length; i++) {
        const e = kmiDaily[i];
        if (!e || typeof e !== "object")
            continue;
        const name = (langText(e.dayName) || "").toLowerCase();
        const text = langText(e.text);
        if (!text)
            continue;
        let offset = -1;
        if (name === "tonight" || name === "today" || name === "this evening" ||
            name === "this afternoon" || name === "this morning") {
            offset = 0;
        } else if (name === "tomorrow") {
            offset = 1;
        } else {
            let wd = -1;
            for (let k = 0; k < WEEKDAYS_LONG.length; k++) {
                if (WEEKDAYS_LONG[k].toLowerCase() === name) { wd = k; break; }
            }
            if (wd < 0)
                continue;
            for (let step = cursor; step < cursor + 7; step++) {
                if (localParts(base + step * DAY_MS).weekday === wd) { offset = step; break; }
            }
            if (offset < 0)
                continue;
        }
        if (offset < cursor)
            continue;            // the list never goes backwards
        cursor = offset;
        const key = dateKey(base + offset * DAY_MS);
        out[key] = out[key] ? out[key] + "\n\n" + text : text;
    }
    return out;
}

// -----------------------------------------------------------------------------
// normalise
// -----------------------------------------------------------------------------

function normalise(opts) {
    opts = opts || {};
    const forecast = opts.forecast || null;
    const airQuality = opts.airQuality || null;
    const kmi = opts.kmi || null;
    const config = opts.config || {};
    const units = Object.assign({}, DEFAULT_UNITS, config.units || {});
    const F = format(units);
    const aqIndex = (config.aqIndex || config.aqiIndex) === "belaqi" ? "belaqi" : "eaqi";
    const nowMs = (typeof opts.nowMs === "number" && isFinite(opts.nowMs)) ? opts.nowMs : Date.now();
    const loc = opts.location || {};

    // Naive local strings. Open-Meteo labels EVERY timestamp of a response at the ONE offset it reports
    // (`utc_offset_seconds`, the zone's offset at the REQUEST instant: measured against the live API, a request made
    // in winter labels July at +1), so that offset -- carried in the raw response, hence right for a cached one too --
    // is what turns a label into an instant; the Brussels rule would shift every hour past a change inside the window.
    // A response without the figure (a fixture, KMI) falls back to the rule. What the model SHOWS (day, hour, weekday)
    // is the Brussels rule on the instant, and an hour's day is the day of its instant, not of its label.
    const brussels = !(forecast && forecast.timezone && forecast.timezone !== "Europe/Brussels");
    const offsetOf = function (resp) { return resp ? num(resp.utc_offset_seconds) : null; };
    const tzOff = offsetOf(forecast);
    const P = function (iso) { return parseLocal(iso, tzOff); };
    const aqOff = offsetOf(airQuality) !== null ? offsetOf(airQuality) : tzOff;
    const PA = function (iso) { return parseLocal(iso, aqOff); };
    const midnight = function (key) { return brussels ? parseLocal(key + "T00:00", null) : P(key + "T00:00"); };

    const model = {
        location: {
            name: loc.name || (kmi && kmi.cityName) || "",
            lat: num(loc.lat !== undefined ? loc.lat : (forecast ? forecast.latitude : null)),
            lon: num(loc.lon !== undefined ? loc.lon : (forecast ? forecast.longitude : null)),
            elevation: num(loc.elevation !== undefined ? loc.elevation : (forecast ? forecast.elevation : null)),
            source: loc.source || "config",
            reason: loc.reason || ""
        },
        fetchedAtMs: (typeof opts.fetchedAtMs === "number" && isFinite(opts.fetchedAtMs)) ? opts.fetchedAtMs : nowMs,
        stale: false,
        offline: false,
        error: "",
        sources: {
            openMeteo: (config.sources && config.sources.openMeteo && config.sources.openMeteo.model) || "best_match",
            kmi: !!kmi
        },
        current: null,
        hourly: [],
        daily: [],
        warnings: kmi && kmi.for ? parseWarnings(kmi.for.warning) : [],
        nowcast: kmi ? parseNowcast(kmi.animation, nowMs) : [],
        pollenNote: kmi ? parsePollenSvg(kmi.pollenSvg) : null,
        aqIndex: aqIndex
    };

    if (!forecast || !forecast.hourly || !Array.isArray(forecast.hourly.time))
        return model;

    const H = forecast.hourly;
    const D = forecast.daily || {};
    const nH = H.time.length;
    const nD = Array.isArray(D.time) ? D.time.length : 0;

    // --- per-day sun windows -------------------------------------------------
    const dayKeys = [], sunrise = [], sunset = [];
    for (let d = 0; d < nD; d++) {
        dayKeys.push(strAt(D.time, d));
        sunrise.push(P(strAt(D.sunrise, d)));
        sunset.push(P(strAt(D.sunset, d)));
    }
    const nightEnd = function (d) {
        if (d + 1 < nD && sunrise[d + 1] !== null)
            return sunrise[d + 1];
        return sunrise[d] !== null ? sunrise[d] + DAY_MS : null;
    };

    // --- air quality lookups by hour -----------------------------------------
    const aqByMs = {};
    const AH = airQuality && airQuality.hourly && Array.isArray(airQuality.hourly.time) ? airQuality.hourly : null;
    if (AH) {
        for (let i = 0; i < AH.time.length; i++) {
            const t = PA(AH.time[i]);
            if (t !== null)
                aqByMs[t] = i;
        }
    }
    const belaqi = airQuality && airQuality.belaqi && typeof airQuality.belaqi === "object" ? airQuality.belaqi : null;
    const aqAt = function (ms, key) {
        if (!AH)
            return null;
        const i = aqByMs[ms];
        if (i === undefined)
            return null;
        const index = aqIndex === "belaqi" ? (belaqi ? num(belaqi[key]) : null) : at(AH.european_aqi, i);
        return makeAq(aqIndex, index, at(AH.pm2_5, i), at(AH.pm10, i), at(AH.ozone, i),
                      at(AH.nitrogen_dioxide, i), at(AH.sulphur_dioxide, i), at(AH.carbon_monoxide, i));
    };
    const pollenAt = function (ms) {
        if (!AH)
            return null;
        const i = aqByMs[ms];
        if (i === undefined)
            return null;
        const concs = {};
        for (let k = 0; k < POLLEN_IDS.length; k++)
            concs[POLLEN_IDS[k]] = at(AH[POLLEN_IDS[k] + "_pollen"], i);
        return makePollen(concs);
    };

    // --- every hour of the response (the daily halves read the past too) -----
    const times = [], keys = [], hours = [];
    for (let i = 0; i < nH; i++) {
        const iso = strAt(H.time, i);
        const ms = P(iso);
        const key = iso ? (brussels && ms !== null ? dateKey(ms) : iso.slice(0, 10)) : null;
        times.push(ms);
        keys.push(key);
        const k = kindOfWmo(at(H.weather_code, i));
        let isDay = at(H.is_day, i);
        let night;
        if (isDay !== null) {
            night = isDay === 0;
        } else {
            const d = dayKeys.indexOf(key);
            night = !(d >= 0 && sunrise[d] !== null && sunset[d] !== null && ms >= sunrise[d] && ms < sunset[d]);
        }
        const p = at(H.pressure_msl, i);
        const p3 = i >= 3 ? at(H.pressure_msl, i - 3) : null;
        hours.push({
            timeMs: ms,
            night: night,
            kind: k.kind, intensity: k.intensity, code: k.code, shower: k.shower,
            temp: at(H.temperature_2m, i),
            feelsLike: at(H.apparent_temperature, i),
            humidity: at(H.relative_humidity_2m, i),
            dewPoint: at(H.dew_point_2m, i),
            wind: makeWind(at(H.wind_speed_10m, i), at(H.wind_direction_10m, i), at(H.wind_gusts_10m, i)),
            precip: {
                mm: at(H.precipitation, i), prob: at(H.precipitation_probability, i),
                rain: at(H.rain, i), showers: at(H.showers, i), snowCm: at(H.snowfall, i)
            },
            pressure: p,
            pressureTrend: (p !== null && p3 !== null) ? Scales.pressureTrend(p - p3) : 0,
            cloudCover: at(H.cloud_cover, i),
            visibility: at(H.visibility, i),
            uv: at(H.uv_index, i),
            sunshineS: at(H.sunshine_duration, i),
            aq: ms !== null ? aqAt(ms, key) : null,
            pollen: ms !== null ? pollenAt(ms) : null
        });
    }

    // The hour containing now (floor); before the first hour it is the first.
    let i0 = 0;
    for (let i = 0; i < nH; i++) {
        if (times[i] !== null && times[i] <= nowMs)
            i0 = i;
    }
    model.hourly = hours.slice(i0);

    // --- current: the hour containing now, with the fresher `current` values --
    const cur = Object.assign({}, hours[i0] || {});
    cur.wind = Object.assign({}, cur.wind || makeWind(null, null, null));
    cur.precip = Object.assign({}, cur.precip || { mm: null, prob: null, rain: null, showers: null, snowCm: null });
    // The `current` block is a 15-minute value; it speaks for the hour it
    // was issued in and no other (a scrubbed or stale clock keeps the hour's).
    const C = forecast.current;
    const cMs = C && typeof C === "object" ? P(C.time) : null;
    const cFresh = cMs !== null && hours[i0] && hours[i0].timeMs !== null &&
                   cMs >= hours[i0].timeMs && cMs < hours[i0].timeMs + HOUR_MS;
    if (cFresh) {
        const ov = function (field, v) { const n = num(v); if (n !== null) cur[field] = n; };
        ov("temp", C.temperature_2m);
        ov("feelsLike", C.apparent_temperature);
        ov("humidity", C.relative_humidity_2m);
        ov("pressure", C.pressure_msl);
        ov("cloudCover", C.cloud_cover);
        if (num(C.wind_speed_10m) !== null) {
            cur.wind = makeWind(C.wind_speed_10m, C.wind_direction_10m !== undefined ? C.wind_direction_10m : cur.wind.dir,
                                C.wind_gusts_10m !== undefined ? C.wind_gusts_10m : cur.wind.gust);
        }
        // The condition now is the `current` block's too (a 15-minute value
        // against the hour's): the hero and its figures come from one place.
        if (num(C.weather_code) !== null) {
            const k = kindOfWmo(C.weather_code);
            cur.kind = k.kind; cur.intensity = k.intensity; cur.code = k.code; cur.shower = k.shower;
        }
        if (num(C.is_day) !== null)
            cur.night = num(C.is_day) === 0;
        if (num(C.precipitation) !== null) {
            cur.precip.mm = num(C.precipitation);
            if (num(C.rain) !== null) cur.precip.rain = num(C.rain);
            if (num(C.showers) !== null) cur.precip.showers = num(C.showers);
            if (num(C.snowfall) !== null) cur.precip.snowCm = num(C.snowfall);
        }
    }
    cur.obs = null;
    if (kmi && kmi.obs && typeof kmi.obs === "object") {
        const k = kindOfKmi(kmi.obs.ww);
        cur.obs = {
            temp: num(kmi.obs.temp),
            code: k.code,
            kind: k.kind,
            intensity: k.intensity,
            night: kmi.obs.dayNight === "n",
            timeMs: parseLocal(kmi.obs.timestamp, null)
        };
    }
    model.current = cur;

    // --- daily ------------------------------------------------------------------
    const todayKey = dateKey(nowMs);

    // TODAY'S EARLIER HOURS (feedback/weather.md "Data prior to last fetch should be kept"): the current day is
    // kept as a whole, not thrown out at the latest fetch. `hourly` starts at the current hour, so a
    // chart of today would have a handful of hours and gaps before them. The response's arrays begin at today's midnight; the hours
    // of THIS date before the current one are kept here for the detail's charts (WeatherSeries.hoursOfDay), and go when the
    // date changes (at midnight, not 4 am: charts are not aligned for that) -- the model is rebuilt every minute, so at 00:00 the new date's list starts empty again.
    model.hoursToday = [];
    for (let i = 0; i < i0; i++) {
        if (keys[i] === todayKey)
            model.hoursToday.push(hours[i]);
    }
    const kmiTexts = kmi && kmi.for ? _kmiDailyTexts(kmi.for.daily, todayKey) : {};

    const hoursIn = function (startMs, endMs) {
        const out = [];
        if (startMs === null || endMs === null)
            return out;
        for (let i = 0; i < nH; i++) {
            if (times[i] !== null && times[i] >= startMs && times[i] < endMs)
                out.push(i);
        }
        return out;
    };
    const windHalf = function (idx) {
        const speeds = [], gusts = [];
        let sx = 0, sy = 0, any = false;
        for (let j = 0; j < idx.length; j++) {
            const w = hours[idx[j]].wind;
            speeds.push(w.speed);
            gusts.push(w.gust);
            if (w.dir !== null && w.speed !== null) {
                const r = w.dir * Math.PI / 180;
                sx += w.speed * Math.sin(r);
                sy += w.speed * Math.cos(r);
                any = true;
            }
        }
        const sp = mean(speeds);
        let dir = null;
        if (any && (sx !== 0 || sy !== 0))
            dir = Math.round(((Math.atan2(sx, sy) * 180 / Math.PI) + 360) % 360);
        return makeWind(sp === null ? null : round1(sp), dir, maxOf(gusts));
    };
    const precipHalf = function (idx) {
        const mm = [];
        for (let j = 0; j < idx.length; j++)
            mm.push(hours[idx[j]].precip.mm);
        const s = sumOf(mm);
        return s === null ? null : round1(s);
    };
    const nightKind = function (idx, fallback) {
        // Worst precipitation kind wins; else the most frequent sky (ties go cloudier).
        let bestKind = null, bestRank = 0;
        const skyCount = { clear: 0, partly: 0, cloudy: 0 };
        for (let j = 0; j < idx.length; j++) {
            const h = hours[idx[j]];
            if (h.kind === null)
                continue;
            const r = PRECIP_RANK[h.kind];
            if (r !== undefined) {
                if (r > bestRank) { bestRank = r; bestKind = h.kind; }
            } else if (skyCount[h.kind] !== undefined) {
                skyCount[h.kind]++;
            }
        }
        if (bestKind === null) {
            let best = 0;
            for (let s = 0; s < SKY_KINDS.length; s++) {
                if (skyCount[SKY_KINDS[s]] >= best && skyCount[SKY_KINDS[s]] > 0) {
                    best = skyCount[SKY_KINDS[s]];
                    bestKind = SKY_KINDS[s];
                }
            }
        }
        if (bestKind === null)
            return { kind: fallback.kind, intensity: fallback.intensity, night: true, code: fallback.code, shower: fallback.shower };
        // Representative hour: the most frequent code of the winning kind, at its worst intensity.
        let intensity = 0, showerN = 0, n = 0;
        const codeCount = {};
        for (let j = 0; j < idx.length; j++) {
            const h = hours[idx[j]];
            if (h.kind !== bestKind)
                continue;
            n++;
            if (h.intensity !== null && h.intensity > intensity)
                intensity = h.intensity;
            if (h.shower)
                showerN++;
            codeCount[h.code] = (codeCount[h.code] || 0) + 1;
        }
        let code = null, cn = 0;
        for (const c in codeCount) {
            if (codeCount[c] > cn) { cn = codeCount[c]; code = Number(c); }
        }
        return { kind: bestKind, intensity: intensity, night: true, code: code, shower: showerN * 2 > n };
    };

    for (let d = 0; d < nD; d++) {
        const key = dayKeys[d];
        const dateMs = key ? midnight(key) : null;
        const dayIdx = hoursIn(sunrise[d], sunset[d]);
        const nightIdx = hoursIn(sunset[d], nightEnd(d));
        const dk = kindOfWmo(at(D.weather_code, d));
        const dayKind = { kind: dk.kind, intensity: dk.intensity, night: false, code: dk.code, shower: dk.shower };

        // The date's own hours (00:00..23:00 local) for the aggregates.
        const dateIdx = [];
        for (let i = 0; i < nH; i++) {
            if (keys[i] === key)
                dateIdx.push(i);
        }
        // Pressure trend across the date: last hour against first.
        let pTrend = 0;
        if (dateIdx.length >= 2) {
            const pa = hours[dateIdx[0]].pressure, pb = hours[dateIdx[dateIdx.length - 1]].pressure;
            if (pa !== null && pb !== null)
                pTrend = Scales.pressureTrend(pb - pa);
        }
        // Air quality: the worst hour of the date, per figure.
        let aq = null;
        const pollenMax = {};
        let pollenAny = false;
        for (let j = 0; j < dateIdx.length; j++) {
            const h = hours[dateIdx[j]];
            if (h.aq) {
                if (aq === null)
                    aq = { index: null, pm25: null, pm10: null, o3: null, no2: null, so2: null, co: null };
                for (const f in aq) {
                    if (h.aq[f] !== null && (aq[f] === null || h.aq[f] > aq[f]))
                        aq[f] = h.aq[f];
                }
            }
            if (h.pollen) {
                pollenAny = true;
                for (let s = 0; s < h.pollen.species.length; s++) {
                    const sp = h.pollen.species[s];
                    if (sp.conc !== null && (pollenMax[sp.id] === undefined || sp.conc > pollenMax[sp.id]))
                        pollenMax[sp.id] = sp.conc;
                }
            }
        }
        if (aq !== null)
            aq = makeAq(aqIndex, aq.index, aq.pm25, aq.pm10, aq.o3, aq.no2, aq.so2, aq.co);
        const pollen = pollenAny ? makePollen(pollenMax) : null;

        const moon = Scales.moonPhase(at(D.moon_phase, d));
        const kmiText = key && kmiTexts[key] ? kmiTexts[key] : null;

        // How much of the date the response really has: the forecast's last day is cut short (its hours exist, with null
        // figures, after the model's horizon -- 5 of 24 in the fixture). `complete` lets a list leave such a day out; a
        // secondary (the detail's day chips) may still show it.
        let dataHours = 0;
        for (let j = 0; j < dateIdx.length; j++) {
            if (hours[dateIdx[j]].temp !== null)
                dataHours++;
        }

        model.daily.push({
            dateMs: dateMs,
            hours: { total: dateIdx.length, data: dataHours },
            complete: dateIdx.length > 0 && dataHours >= dateIdx.length,
            weekday: F.weekday(dateMs),
            dateLabel: F.date(dateMs),
            isToday: key !== null && key === todayKey,
            day: dayKind,
            night: nightKind(nightIdx, dayKind),
            temp: { max: at(D.temperature_2m_max, d), min: at(D.temperature_2m_min, d) },
            feelsLike: { max: at(D.apparent_temperature_max, d), min: at(D.apparent_temperature_min, d) },
            humidity: at(D.relative_humidity_2m_mean, d),
            dewPoint: at(D.dew_point_2m_mean, d),
            wind: { day: windHalf(dayIdx), night: windHalf(nightIdx) },
            precip: {
                day: precipHalf(dayIdx), night: precipHalf(nightIdx),
                total: at(D.precipitation_sum, d),
                prob: at(D.precipitation_probability_max, d),
                hours: at(D.precipitation_hours, d)
            },
            sunshineS: at(D.sunshine_duration, d),
            daylightS: at(D.daylight_duration, d),
            uvMax: at(D.uv_index_max, d),
            pressure: at(D.pressure_msl_mean, d),
            pressureTrend: pTrend,
            cloud: { min: at(D.cloud_cover_min, d), max: at(D.cloud_cover_max, d), mean: at(D.cloud_cover_mean, d) },
            visibility: { min: at(D.visibility_min, d), max: at(D.visibility_max, d), mean: at(D.visibility_mean, d) },
            aq: aq,
            pollen: pollen,
            sunriseMs: sunrise[d],
            sunsetMs: sunset[d],
            moonriseMs: P(strAt(D.moonrise, d)),
            moonsetMs: P(strAt(D.moonset, d)),
            moonPhase: at(D.moon_phase, d),
            moonName: moon ? moon.name : null,
            moonIllumination: moon ? round1(moon.illumination * 100) / 100 : null,
            kmiText: d < 8 ? kmiText : null
        });
    }

    // How many of the days a LIST shows: the trailing days the model's horizon cut short are left out (feedback/weather.md
    // "No displaying incomplete days"), the first day always stays. The days themselves stay in
    // `daily`: a secondary (the detail's day chips) may show a partial day.
    let shown = model.daily.length;
    while (shown > 1 && model.daily[shown - 1].complete === false)
        shown--;
    model.dailyShown = shown;

    return model;
}

// -----------------------------------------------------------------------------
// The formatter
// -----------------------------------------------------------------------------

function _fixed(v, decimals) {
    // toFixed without a "-0", and without exponent surprises.
    let s = v.toFixed(decimals);
    if (/^-0(\.0*)?$/.test(s))
        s = s.slice(1);
    return s;
}

function _adaptive(v) {
    // 1 decimal below 10, none from 10 (precipitation, distance, concentration).
    return Math.abs(v) < 10 ? _fixed(v, 1) : _fixed(v, 0);
}

function _adaptiveSmall(v) {
    // 2 decimals below 1 (CO in mg/m³ reads 0.19), else _adaptive.
    return Math.abs(v) < 1 ? _fixed(v, 2) : _adaptive(v);
}

function format(units) {
    const u = Object.assign({}, DEFAULT_UNITS, units || {});
    const ok = function (v) { return typeof v === "number" && isFinite(v); };

    const temp = function (v) {
        if (!ok(v)) return DASH;
        const t = u.temperature === "f" ? v * 9 / 5 + 32 : v;
        return _fixed(t, 0) + "°";
    };
    const tempDelta = function (v) {
        if (!ok(v)) return DASH;
        const t = u.temperature === "f" ? v * 9 / 5 : v;
        const s = _fixed(t, 0);
        return (t > 0 && s !== "0" ? "+" : "") + s + "°";
    };
    const speedVal = function (v) {
        switch (u.speed) {
        case "ms": return v / 3.6;
        case "mph": return v / 1.609344;
        case "kn": return v / 1.852;
        default: return v;
        }
    };
    const speed = function (v) {
        if (!ok(v)) return DASH;
        const s = speedVal(v);
        return u.speed === "ms" ? _adaptive(s) : _fixed(s, 0);
    };
    const speedUnit = function () {
        switch (u.speed) {
        case "ms": return "m/s";
        case "mph": return "mph";
        case "kn": return "kn";
        default: return "km/h";
        }
    };
    const wind = function (w) {
        if (!w || typeof w !== "object") return DASH;
        if (u.wind === "speed")
            return ok(w.speed) ? speed(w.speed) + " " + speedUnit() : DASH;
        return ok(w.bft) ? _fixed(w.bft, 0) + " Bft" : DASH;
    };
    const pressure = function (v) {
        if (!ok(v)) return DASH;
        switch (u.pressure) {
        case "mmhg": return _fixed(v * 0.750061683, 0);
        case "inhg": return _fixed(v * 0.02952998, 2);
        default: return _fixed(v, 0);
        }
    };
    const pressureUnit = function () {
        switch (u.pressure) {
        case "mbar": return "mbar";
        case "mmhg": return "mmHg";
        case "inhg": return "inHg";
        default: return "hPa";
        }
    };
    const precip = function (v) {
        if (!ok(v)) return DASH;
        return u.precipitation === "in" ? _fixed(v / 25.4, 2) : _adaptive(v);
    };
    const precipUnit = function () { return u.precipitation === "in" ? "in" : "mm"; };
    const distance = function (m) {
        if (!ok(m)) return DASH;
        return _adaptive(u.distance === "mi" ? m / 1609.344 : m / 1000);
    };
    const distanceUnit = function () { return u.distance === "mi" ? "mi" : "km"; };
    // Carbon monoxide in mg/m3 when asked; every other pollutant is ug/m3 (units.airQuality has that one value).
    const concMg = function (id) { return id === "co" && u.co === "mgm3"; };
    const conc = function (v, id) {
        if (!ok(v)) return DASH;
        return concMg(id) ? _adaptiveSmall(v / 1000) : _adaptive(v);
    };
    const concUnit = function (id) { return concMg(id) ? "mg/m³" : "µg/m³"; };
    const percent = function (v) { return ok(v) ? _fixed(v, 0) : DASH; };

    const twelve = u.clock === "12h";
    const time = function (ms) {
        if (!ok(ms)) return DASH;
        const p = localParts(ms);
        if (!twelve)
            return pad2(p.hour) + ":" + pad2(p.minute);
        const h12 = p.hour % 12 === 0 ? 12 : p.hour % 12;
        const suffix = p.hour < 12 ? " am" : " pm";
        return h12 + (p.minute === 0 ? "" : ":" + pad2(p.minute)) + suffix;
    };
    const hour = function (ms) {
        if (!ok(ms)) return DASH;
        const p = localParts(ms);
        if (!twelve)
            return pad2(p.hour);
        const h12 = p.hour % 12 === 0 ? 12 : p.hour % 12;
        return h12 + (p.hour < 12 ? "am" : "pm");
    };
    const date = function (ms) {
        if (!ok(ms)) return DASH;
        const p = localParts(ms);
        switch (u.date) {
        case "MM/dd": return pad2(p.month) + "/" + pad2(p.day);
        case "d MMM": return p.day + " " + MONTHS_SHORT[p.month - 1];
        default: return pad2(p.day) + "/" + pad2(p.month);
        }
    };
    const weekday = function (ms) { return ok(ms) ? WEEKDAYS_SHORT[localParts(ms).weekday] : DASH; };
    const weekdayLong = function (ms) { return ok(ms) ? WEEKDAYS_LONG[localParts(ms).weekday] : DASH; };
    const duration = function (s) {
        if (!ok(s)) return DASH;
        const total = Math.round(s / 60);
        return Math.floor(total / 60) + "h" + pad2(total % 60);
    };

    return {
        units: u,
        temp: temp, tempUnit: function () { return u.temperature === "f" ? "°F" : "°C"; },
        tempDelta: tempDelta,
        speed: speed, speedUnit: speedUnit,
        wind: wind,
        pressure: pressure, pressureUnit: pressureUnit,
        precip: precip, precipUnit: precipUnit,
        distance: distance, distanceUnit: distanceUnit,
        conc: conc, concUnit: concUnit,
        percent: percent,
        time: time, hour: hour, date: date, weekday: weekday, weekdayLong: weekdayLong,
        duration: duration
    };
}
