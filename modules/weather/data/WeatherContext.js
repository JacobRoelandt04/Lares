.pragma library
.import "WeatherModel.js" as WM
.import "WeatherScales.js" as Scales

// =============================================================================
// WeatherContext.js -- the hero's context line: ONE sentence about what is
// worth knowing next, chosen from the model.
//
//     Ctx.line(model, F, nowMs [, thresholds]) -> { id, text, bars }
//
// `F` is WM.format(units); `nowMs` the instant the model was built for (the
// service's clock, the mock's `nowMs`). `bars` says the line is about the
// radar nowcast and the hero shows its twelve bars beside it. No model (or a
// model with no `current`) -> { id: "", text: "", bars: false }; with one,
// `text` is never empty: the last rules always hold.
//
// WHAT THE CARD ALREADY SAYS, and this line therefore never repeats: the
// temperature and condition NOW, today's high and low, feels-like now. A rule whose whole content is a warning's type is
// skipped while that warning is up (SUPPRESSED_BY below). The line is about
// what comes NEXT: when something starts or stops, how far a value goes.
//
// THE RULES, first that holds wins. Hours are `model.hourly` (hourly[0] is the
// hour containing now); "24 h" means hourly[0..24].
//
// | # | id            | condition                                             | text template                                  | bars |
// |---|---------------|-------------------------------------------------------|------------------------------------------------|------|
// | 1 | precip-now    | radar: nowcast[0].mm > 0; no radar: the current hour  | "Rain until 20:40" (radar's first dry step)     | radar|
// |   |               | has a precipitation kind and mm > 0                   | "Rain until tomorrow 08:00" (radar wet to its   |      |
// |   |               |                                                       | end: the hours carry on; the first dry hour)    |      |
// | 2 | precip-soon   | radar: a later step is wet (within 2 h)               | "Rain 19:40–20:30" / "Snow from 20:10"          | yes  |
// | 3 | gusts         | a gust >= 60 km/h in the next 24 h                     | "Gusts up to 88 km/h until 03:00" (now)         | no   |
// |   |               |                                                       | "Gusts up to 70 km/h tonight 23:00–05:00"       |      |
// | 4 | frost         | now above 0°, <= 0° within 18 h                        | "Frost tonight from 02:00, down to -3°"         | no   |
// |   |               |                                                       | (the depth dropped when the card shows it)      |      |
// | 5 | heat          | >= 30° later today (not now) / the coming night stays  | "30° or more 12:00–19:00" / "Hot 12:00–19:00"   | no   |
// |   |               | >= 20°                                                 | "Warm night, not below 22°" / "Warm night, 20°  |      |
// |   |               |                                                       | or more" / "Warm night" (see THE CARD'S FIGURES)|      |
// | 6 | fog           | fog now (kind fog or visibility < 1 km) / within 12 h  | "Fog until 08:00" / "Fog tonight from 03:00"    | no   |
// | 7 | precip-later  | an hour with probability >= 50 % in the next 24 h      | "Drizzle tomorrow 16:00–22:00"                  | no   |
// |   |               | (no probability: mm >= 0.2)                            | "Rain likely tonight from 23:00" (peak < 70 %)  |      |
// | 8 | uv            | UV >= 6 still ahead today                              | "UV very high 11:00–16:00, peak 9"              | no   |
// | 9 | tomorrow      | tomorrow wet (>= 60 %, >= 1 mm) after a dry today, or  | "Rain tomorrow, 6.1 mm"                         | no   |
// |   |               | tomorrow's high 5° or more from today's                | "7° colder tomorrow, high 13°" (a figure the    |      |
// |   |               |                                                       | card shows is dropped: "Colder tomorrow, ...")  |      |
// |10 | dry-spell     | the first wet day (>= 50 % or >= 1 mm) is 3+ days out, | "Dry until Saturday" / "Dry for the next 7 days"| no   |
// |   |               | or none in the week                                    |                                                 |      |
// |11 | sun           | always, with sun times                                 | "Sunset at 19:57" / "Sunrise at 07:23"          | no   |
// |12 | wind          | always (polar day/night: no sun times)                 | "Wind 3 Bft WNW"                                 | no   |
//
// WHY EACH IS INFORMATIVE, AND THE ORDER
//  1-2  Radar first: it is the freshest fact in the model and the only one
//       that answers "do I get wet on the way out". Rule 1 is the stop time
//       (the card already says it is raining; when it stops is new); rule 2
//       the start. The bars show how much.
//  3-5  Rarer and more consequential than a wet hour, so above rule 7: a gale
//       gust, the first frost, a hot afternoon or a tropical night happen a
//       few days a year in Belgium and change what one does. The high/low on
//       the card are today's calendar-day figures; the hours past 30° are
//       not on it, and tonight's low is not either unless it is also today's
//       (then the line says the threshold instead: THE CARD'S FIGURES).
//   6   Fog's clearing time: the card says "Fog", not until when.
//   7   The next wet spell, with its window (the strip scrolls; this says it
//       in one glance, in mini where there is no strip at all). The word is
//       the worst hour's (drizzle, rain, showers, snow, thunderstorms);
//       "likely" only when the best hour stays under 70 %.
//   8   Whether sunscreen still matters today (WHO "high" starts at 6).
//   9   A notable change tomorrow: wet after dry, or a 5° swing of the high.
//  10   A dry spell is news only when it is long (3+ days).
//  11   The always-true fallback: the next sunset or sunrise.
//  12   Only for a model without sun times.
//
// WHAT A RULE MUST NEVER REPEAT
//   THE CARD'S FIGURES, as a class. No line states a temperature the card
//   prints: now, feels-like now, today's high and low, the KMI observation
//   (`cardFigures`, compared as formatted text, so a 21.6 in the model is the
//   card's "22°"). A delta counts: "7° colder" beside a card's "7°" reads as
//   the same number. A rule that states a temperature offers its wordings
//   most informative first and ending in one with no figure, and `_say` takes
//   the first whose figures the card does not show:
//     frost     "Frost tonight from 02:00, down to -3°" -> "Frost tonight from 02:00"
//     heat      "30° or more 12:00–19:00" -> "Hot 12:00–19:00"
//               "Warm night, not below 22°" -> "Warm night, 20° or more" -> "Warm night"
//     tomorrow  "7° colder tomorrow, high 11°" -> "7° colder tomorrow"
//               -> "Colder tomorrow, high 11°" -> "Colder tomorrow"
//   A heatwave's "Warm night, not below 22°" beside the card's "L 22°"
//   repeats the card when the night's low is today's, which is why every
//   such rule ends in a wording with no figure.
//   precip-now/soon  the condition word as an adjective ("Heavy"): the card
//                    has it and the bars show the amount -- radar lines use
//                    the plain word
//   gusts            a wind warning (suppressed)
//   frost            a cold / ice / snow warning (suppressed)
//   heat             the peak (the line gives the hours, the card the high)
//   fog              a fog warning (suppressed)
//   precip-later     a rain / thunder warning (suppressed)
//   tomorrow/sun     nothing on the card is about tomorrow or the sun
//
// DAY WORDS. Within the next 3 hours a clock time needs no day ("Rain
// 19:40–20:40"). Past that, a time on today's date from 18:00, or on the next
// date before 06:00, is "tonight"; the next date from 06:00 is "tomorrow".
// "from" and range lines carry the word ("Drizzle tomorrow 16:00–22:00");
// "until" lines only say "tomorrow" (a stop within the night needs no day).
//
// Pure: no Qt, no console, no clock of its own. Thresholds are meteorological
// conventions, not styling, so they live here (`THRESHOLDS`) with the reason
// beside each; a caller may override any of them for a probe.
// =============================================================================

var HOUR_MS = 3600000;

var THRESHOLDS = {
    // Gust at which the line speaks up: just under Beaufort 8 ("gale",
    // 62-74 km/h), where gusts bring down twigs and make cycling hazardous.
    gustKmh: 60,
    // Air frost.
    frostC: 0,
    // A "tropical night" (ETCCDI's TR20: the minimum stays at or above 20 °C).
    warmNightC: 20,
    // A hot hour (a "tropical day" reaches 30 °C).
    hotC: 30,
    // WHO UV index "high".
    uvHigh: 6,
    // Hourly precipitation probability at which an hour counts as wet
    // (Open-Meteo: probability of >= 0.1 mm).
    wetProb: 50,
    // ...and below which the line hedges with "likely".
    sureProb: 70,
    // An hour without a probability counts as wet from this many mm.
    wetMm: 0.2,
    // A change of tomorrow's high worth a line.
    tomorrowDeltaC: 5,
    // Tomorrow counts as wet from this probability and total.
    wetDayProb: 60,
    wetDayMm: 1,
    // A day in the dry-spell scan counts as wet from EITHER of these: "dry"
    // is a promise, so a likely drizzle day (92 %, 0.5 mm) ends the spell.
    spellDayProb: 50,
    spellDayMm: 1,
    // A dry spell is news from this many days.
    spellDays: 3,
    // Look-ahead windows, hours.
    horizonH: 24,
    frostH: 18,
    fogLaterH: 12,
    heatH: 12
};

// Warning types (WM.KMI_WARNING_TYPES slugs) -> the rule each one
// already covers.
var SUPPRESSED_BY = {
    wind: ["gusts"],
    thunderstorm_strong_gusts: ["gusts", "precip-later"],
    thunder_wind_rain: ["gusts", "precip-later"],
    thunder: ["precip-later"],
    thunderstorm_large_rainfall: ["precip-later"],
    rain: ["precip-later"],
    fog: ["fog"],
    ice_or_snow: ["frost"],
    cold: ["frost"],
    coldspell: ["frost"]
};

var PRECIP_RANK = { thunder: 5, hail: 4, snow: 3, sleet: 2, rain: 1 };

var EMPTY = { id: "", text: "", bars: false };

function _num(v) {
    return typeof v === "number" && isFinite(v) ? v : null;
}

function _isDrizzle(code) {
    return code !== null && code !== undefined && code >= 51 && code <= 55;
}

// The full word for an hour of precipitation, or null for a dry kind.
function precipWord(h) {
    if (!h)
        return null;
    switch (h.kind) {
    case "thunder": return "Thunderstorms";
    case "hail": return "Hail";
    case "snow":
        if (h.shower) return "Snow showers";
        return h.intensity === 0 ? "Light snow" : (h.intensity === 2 ? "Heavy snow" : "Snow");
    case "sleet":
        return h.intensity === 0 ? "Freezing drizzle" : "Sleet";
    case "rain":
        if (h.shower) return "Showers";
        if (_isDrizzle(h.code)) return "Drizzle";
        return h.intensity === 0 ? "Light rain" : (h.intensity === 2 ? "Heavy rain" : "Rain");
    default: return null;
    }
}

// The plain word a radar line uses: no intensity (the bars show it), and a
// storm's radar echo is its rain.
function radarWord(h) {
    if (!h)
        return "Rain";
    switch (h.kind) {
    case "snow": return h.shower ? "Snow showers" : "Snow";
    case "sleet": return "Sleet";
    case "hail": return "Hail";
    case "rain":
        if (h.shower) return "Showers";
        return _isDrizzle(h.code) ? "Drizzle" : "Rain";
    default: return "Rain";
    }
}

function _rank(h) {
    const r = h ? PRECIP_RANK[h.kind] : undefined;
    return r === undefined ? 0 : r * 10 + (h.intensity | 0);
}

// "tonight" | "tomorrow" | "on Friday" | "" for a time relative to now (see
// DAY WORDS).
function dayWord(F, nowMs, ms) {
    if (ms - nowMs < 3 * HOUR_MS)
        return "";
    const a = WM.localParts(nowMs), b = WM.localParts(ms);
    const dayA = Date.UTC(a.year, a.month - 1, a.day), dayB = Date.UTC(b.year, b.month - 1, b.day);
    const d = Math.round((dayB - dayA) / 86400000);
    if (d === 0)
        return b.hour >= 18 ? "tonight" : "";
    if (d === 1)
        return b.hour < 6 ? "tonight" : "tomorrow";
    return d > 1 ? "on " + F.weekdayLong(ms) : "";
}

function _join(parts) {
    return parts.filter(function (p) { return p && p.length > 0; }).join(" ");
}

// "Drizzle tomorrow 16:00–22:00" / "Rain tonight from 23:00".
function _window(F, nowMs, word, startMs, endMs) {
    const dw = dayWord(F, nowMs, startMs);
    if (endMs === null)
        return _join([word, dw, "from " + F.time(startMs)]);
    return _join([word, dw, F.time(startMs) + "–" + F.time(endMs)]);
}

// "until 08:00" / "until tomorrow 08:00".
function _until(F, nowMs, ms) {
    return dayWord(F, nowMs, ms) === "tomorrow" ? "until tomorrow " + F.time(ms) : "until " + F.time(ms);
}

// The first index in [from, to] whose hour satisfies `pred`, or -1.
function _first(hours, from, to, pred) {
    for (let i = Math.max(0, from); i <= to && i < hours.length; i++) {
        if (pred(hours[i], i))
            return i;
    }
    return -1;
}

function _suppressed(model) {
    const out = {};
    const ws = model.warnings || [];
    for (let i = 0; i < ws.length; i++) {
        const ids = SUPPRESSED_BY[ws[i].type];
        if (ids)
            for (let j = 0; j < ids.length; j++)
                out[ids[j]] = true;
    }
    return out;
}

function _sameDate(a, b) {
    return WM.dateKey(a) === WM.dateKey(b);
}

// The temperatures the card prints (WeatherHero): now, feels-like now, today's
// high and low, the KMI observation -- formatted, as the card shows them.
function cardFigures(model, F) {
    if (!model || !model.current)
        return [];
    const cur = model.current;
    const d0 = model.daily && model.daily.length > 0 ? model.daily[0] : null;
    const vals = [cur.temp, cur.feelsLike, d0 && d0.temp ? d0.temp.max : null, d0 && d0.temp ? d0.temp.min : null,
                  cur.obs ? cur.obs.temp : null];
    const out = [];
    for (let i = 0; i < vals.length; i++) {
        if (_num(vals[i]) !== null)
            out.push(F.temp(vals[i]));
    }
    return out;
}

// The first wording none of whose temperature figures the card shows. The
// last wording carries no figure, so it always holds.
function _say(c, wordings) {
    for (let i = 0; i < wordings.length; i++) {
        const figs = wordings[i].match(/-?\d+(?:\.\d+)?°/g) || [];
        if (figs.every(function (f) { return c.shown.indexOf(f) < 0; }))
            return wordings[i];
    }
    return wordings[wordings.length - 1];
}

// =============================================================================
// The rules. Each takes a context object and returns a line or null.
// =============================================================================

function _wetHour(c, h) {
    const p = _num(h.precip ? h.precip.prob : null);
    const mm = _num(h.precip ? h.precip.mm : null);
    return p !== null ? p >= c.T.wetProb : (mm !== null && mm >= c.T.wetMm);
}

// The hour containing `ms`, or null.
function _hourAt(c, ms) {
    const hs = c.hours;
    for (let i = 0; i < hs.length; i++) {
        const t = hs[i].timeMs;
        if (t !== null && ms >= t && ms < t + HOUR_MS)
            return hs[i];
    }
    return null;
}

function rulePrecipNow(c) {
    const nc = c.nowcast;
    if (nc.length > 0) {
        if (!(nc[0].mm > 0))
            return null;
        const word = radarWord(_hourAt(c, nc[0].timeMs) || c.cur);
        for (let k = 1; k < nc.length; k++) {
            if (!(nc[k].mm > 0))
                return { id: "precip-now", text: word + " " + _until(c.F, c.now, nc[k].timeMs), bars: true };
        }
        // Wet to the radar's end: the hours say how long it goes on.
        const last = nc[nc.length - 1].timeMs;
        const end = _first(c.hours, 1, c.T.horizonH, function (h) {
            return h.timeMs !== null && h.timeMs >= last && !_wetHour(c, h);
        });
        return {
            id: "precip-now",
            text: word + " " + (end >= 0 ? _until(c.F, c.now, c.hours[end].timeMs) : "for the next " + c.T.horizonH + " h"),
            bars: true
        };
    }
    // No radar: the model's current hour.
    const cur = c.cur;
    const mm = _num(cur.precip ? cur.precip.mm : null);
    if (!precipWord(cur) || !(mm > 0))
        return null;
    const end = _first(c.hours, 1, c.T.horizonH, function (h) { return !_wetHour(c, h); });
    return {
        id: "precip-now",
        text: radarWord(cur) + " " + (end >= 0 ? _until(c.F, c.now, c.hours[end].timeMs) : "for the next " + c.T.horizonH + " h"),
        bars: false
    };
}

function rulePrecipSoon(c) {
    const nc = c.nowcast;
    let k0 = -1;
    for (let k = 0; k < nc.length; k++) {
        if (nc[k].mm > 0) { k0 = k; break; }
    }
    if (k0 < 1)
        return null;
    let k1 = -1;
    for (let k = k0 + 1; k < nc.length; k++) {
        if (!(nc[k].mm > 0)) { k1 = k; break; }
    }
    const word = radarWord(_hourAt(c, nc[k0].timeMs));
    return { id: "precip-soon", text: _window(c.F, c.now, word, nc[k0].timeMs, k1 >= 0 ? nc[k1].timeMs : null), bars: true };
}

function ruleGusts(c) {
    const T = c.T;
    const gustOf = function (h) { return _num(h.wind ? h.wind.gust : null); };
    const strong = function (h) { const g = gustOf(h); return g !== null && g >= T.gustKmh; };
    const i0 = _first(c.hours, 0, T.horizonH, strong);
    if (i0 < 0)
        return null;
    const i1 = _first(c.hours, i0 + 1, i0 + T.horizonH, function (h) { return !strong(h); });
    let max = 0;
    for (let i = i0; i < (i1 >= 0 ? i1 : Math.min(c.hours.length, i0 + T.horizonH + 1)); i++)
        max = Math.max(max, gustOf(c.hours[i]) || 0);
    const what = "Gusts up to " + c.F.speed(max) + " " + c.F.speedUnit();
    if (i0 === 0)
        return { id: "gusts", text: what + " " + (i1 >= 0 ? _until(c.F, c.now, c.hours[i1].timeMs) : "for the next " + T.horizonH + " h"), bars: false };
    return { id: "gusts", text: _window(c.F, c.now, what, c.hours[i0].timeMs, i1 >= 0 ? c.hours[i1].timeMs : null), bars: false };
}

function ruleFrost(c) {
    const T = c.T;
    const now = _num(c.cur.temp);
    if (now === null || now <= T.frostC)
        return null;
    const i0 = _first(c.hours, 1, T.frostH, function (h) { const t = _num(h.temp); return t !== null && t <= T.frostC; });
    if (i0 < 0)
        return null;
    let min = Infinity;
    for (let i = i0; i <= T.frostH && i < c.hours.length; i++) {
        const t = _num(c.hours[i].temp);
        if (t !== null && t < min)
            min = t;
    }
    const from = _window(c.F, c.now, "Frost", c.hours[i0].timeMs, null);
    return { id: "frost", text: _say(c, [from + ", down to " + c.F.temp(min), from]), bars: false };
}

function ruleHeat(c) {
    const T = c.T;
    const hs = c.hours;
    const hot = function (h) { const t = _num(h.temp); return t !== null && t >= T.hotC; };
    // Hot hours still ahead today, not now.
    const nowT = _num(c.cur.temp);
    if (hs.length > 0 && !hot(hs[0]) && !(nowT !== null && nowT >= T.hotC)) {
        const i0 = _first(hs, 1, T.heatH, function (h) { return hot(h) && _sameDate(h.timeMs, c.now); });
        if (i0 >= 0) {
            const i1 = _first(hs, i0 + 1, T.horizonH, function (h) { return !hot(h); });
            const span = function (word) { return _window(c.F, c.now, word, hs[i0].timeMs, i1 >= 0 ? hs[i1].timeMs : null); };
            return { id: "heat", text: _say(c, [span(c.F.temp(T.hotC) + " or more"), span("Hot")]), bars: false };
        }
    }
    // The coming night (or the rest of this one).
    const n0 = _first(hs, 0, T.heatH, function (h) { return h.night === true; });
    if (n0 < 0)
        return null;
    let min = Infinity, any = false;
    for (let i = n0; i < hs.length && hs[i].night === true; i++) {
        const t = _num(hs[i].temp);
        if (t !== null) { any = true; min = Math.min(min, t); }
    }
    if (!any || min < T.warmNightC)
        return null;
    return {
        id: "heat",
        text: _say(c, ["Warm night, not below " + c.F.temp(min), "Warm night, " + c.F.temp(T.warmNightC) + " or more", "Warm night"]),
        bars: false
    };
}

function ruleFog(c) {
    const T = c.T;
    const foggy = function (h) {
        const v = _num(h.visibility);
        return h.kind === "fog" || (v !== null && v < 1000);
    };
    if (foggy(c.cur)) {
        const end = _first(c.hours, 1, T.horizonH, function (h) { return !foggy(h); });
        return { id: "fog", text: "Fog " + (end >= 0 ? _until(c.F, c.now, c.hours[end].timeMs) : "for the next " + T.horizonH + " h"), bars: false };
    }
    const i0 = _first(c.hours, 1, T.fogLaterH, foggy);
    if (i0 < 0)
        return null;
    return { id: "fog", text: _window(c.F, c.now, "Fog", c.hours[i0].timeMs, null), bars: false };
}

function rulePrecipLater(c) {
    const T = c.T;
    const hs = c.hours;
    const i0 = _first(hs, 1, T.horizonH, function (h) { return _wetHour(c, h); });
    if (i0 < 0)
        return null;
    const i1 = _first(hs, i0 + 1, i0 + T.horizonH, function (h) { return !_wetHour(c, h); });
    const stop = i1 >= 0 ? i1 : Math.min(hs.length, i0 + T.horizonH + 1);
    let worst = null, peak = 0;
    for (let i = i0; i < stop; i++) {
        const h = hs[i];
        if (_rank(h) > _rank(worst))
            worst = h;
        const p = _num(h.precip ? h.precip.prob : null);
        peak = Math.max(peak, p === null ? 100 : p);
    }
    const word = (precipWord(worst) || "Rain") + (peak < T.sureProb ? " likely" : "");
    return { id: "precip-later", text: _window(c.F, c.now, word, hs[i0].timeMs, i1 >= 0 ? hs[i1].timeMs : null), bars: false };
}

function ruleUv(c) {
    const T = c.T;
    const hs = c.hours;
    const high = function (h) { const u = _num(h.uv); return u !== null && u >= T.uvHigh && _sameDate(h.timeMs, c.now); };
    const i0 = _first(hs, 0, T.horizonH, high);
    if (i0 < 0)
        return null;
    const i1 = _first(hs, i0 + 1, T.horizonH, function (h) { return !high(h); });
    let max = 0;
    for (let i = i0; i < (i1 >= 0 ? i1 : Math.min(hs.length, T.horizonH + 1)); i++)
        max = Math.max(max, _num(hs[i].uv) || 0);
    const band = Scales.bandOf("uv", max);
    const word = "UV " + (band ? band.name.toLowerCase() : "high");
    const peak = ", peak " + Math.round(max);
    if (i0 === 0)
        return { id: "uv", text: word + " " + (i1 >= 0 ? _until(c.F, c.now, hs[i1].timeMs) : "all day") + peak, bars: false };
    return { id: "uv", text: _window(c.F, c.now, word, hs[i0].timeMs, i1 >= 0 ? hs[i1].timeMs : null) + peak, bars: false };
}

function ruleTomorrow(c) {
    const T = c.T;
    const ds = c.days;
    if (ds.length < 2)
        return null;
    const d0 = ds[0], d1 = ds[1];
    const tot0 = _num(d0.precip ? d0.precip.total : null);
    const tot1 = _num(d1.precip ? d1.precip.total : null);
    const p1 = _num(d1.precip ? d1.precip.prob : null);
    if (tot1 !== null && p1 !== null && tot1 >= T.wetDayMm && p1 >= T.wetDayProb && (tot0 === null || tot0 < 0.5)) {
        const worst = _rank(d1.night) > _rank(d1.day) ? d1.night : d1.day;
        return { id: "tomorrow", text: (precipWord(worst) || "Rain") + " tomorrow, " + c.F.precip(tot1) + " " + c.F.precipUnit(), bars: false };
    }
    const hi0 = _num(d0.temp ? d0.temp.max : null), hi1 = _num(d1.temp ? d1.temp.max : null);
    if (hi0 === null || hi1 === null)
        return null;
    const delta = hi1 - hi0;
    if (Math.abs(delta) < T.tomorrowDeltaC)
        return null;
    const n = c.F.tempDelta(Math.abs(delta)).replace("+", "");
    const word = delta > 0 ? "warmer" : "colder";
    const Word = delta > 0 ? "Warmer" : "Colder";
    const high = ", high " + c.F.temp(hi1);
    return {
        id: "tomorrow",
        text: _say(c, [n + " " + word + " tomorrow" + high, n + " " + word + " tomorrow", Word + " tomorrow" + high, Word + " tomorrow"]),
        bars: false
    };
}

function ruleDrySpell(c) {
    const T = c.T;
    const ds = c.days;
    const last = Math.min(7, ds.length - 1);
    if (last < T.spellDays)
        return null;
    for (let d = 1; d <= last; d++) {
        const p = _num(ds[d].precip ? ds[d].precip.prob : null);
        const mm = _num(ds[d].precip ? ds[d].precip.total : null);
        if ((p !== null && p >= T.spellDayProb) || (mm !== null && mm >= T.spellDayMm)) {
            if (d < T.spellDays)
                return null;
            return { id: "dry-spell", text: "Dry until " + c.F.weekdayLong(ds[d].dateMs), bars: false };
        }
    }
    return { id: "dry-spell", text: "Dry for the next " + last + " days", bars: false };
}

function ruleSun(c) {
    const ds = c.days;
    if (ds.length === 0)
        return null;
    const d0 = ds[0];
    const rise0 = _num(d0.sunriseMs), set0 = _num(d0.sunsetMs);
    if (rise0 !== null && c.now < rise0)
        return { id: "sun", text: "Sunrise at " + c.F.time(rise0), bars: false };
    if (set0 !== null && c.now < set0)
        return { id: "sun", text: "Sunset at " + c.F.time(set0), bars: false };
    const rise1 = ds.length > 1 ? _num(ds[1].sunriseMs) : null;
    if (rise1 !== null)
        return { id: "sun", text: "Sunrise at " + c.F.time(rise1), bars: false };
    return null;
}

function ruleWind(c) {
    const w = c.cur.wind;
    return { id: "wind", text: _join(["Wind", c.F.wind(w), w && w.dirText ? w.dirText : ""]), bars: false };
}

// The order IS the priority (the header says why).
var RULES = [
    { id: "precip-now", fn: rulePrecipNow },
    { id: "precip-soon", fn: rulePrecipSoon },
    { id: "gusts", fn: ruleGusts },
    { id: "frost", fn: ruleFrost },
    { id: "heat", fn: ruleHeat },
    { id: "fog", fn: ruleFog },
    { id: "precip-later", fn: rulePrecipLater },
    { id: "uv", fn: ruleUv },
    { id: "tomorrow", fn: ruleTomorrow },
    { id: "dry-spell", fn: ruleDrySpell },
    { id: "sun", fn: ruleSun },
    { id: "wind", fn: ruleWind }
];

function ruleIds() {
    return RULES.map(function (r) { return r.id; });
}

// Every rule's answer, in priority order (null where it does not hold): what a
// probe reads to prove an order without crafting a model per pair.
function evaluate(model, F, nowMs, thresholds) {
    if (!model || !model.current)
        return [];
    const c = {
        model: model,
        F: F,
        now: nowMs,
        T: Object.assign({}, THRESHOLDS, thresholds || {}),
        cur: model.current,
        hours: model.hourly || [],
        days: model.daily || [],
        nowcast: model.nowcast || [],
        shown: cardFigures(model, F)
    };
    const off = _suppressed(model);
    return RULES.map(function (r) {
        if (off[r.id])
            return null;
        return r.fn(c);
    });
}

function line(model, F, nowMs, thresholds) {
    const all = evaluate(model, F, nowMs, thresholds);
    for (let i = 0; i < all.length; i++) {
        if (all[i] && all[i].text.length > 0)
            return all[i];
    }
    return EMPTY;
}
