.pragma library
.import "WeatherScales.js" as Scales
.import "WeatherModel.js" as WM
.import "Astro.js" as Astro

// =============================================================================
// WeatherSeries.js -- one metric of one day as a chart spec for WeatherDetail.
//
//     WS.forDay(model, metric, dayIndex, F, opts) -> spec
//
// metric: ("temperature" | "feelsLike" | "precipitation" | "wind" |
// "airQuality" | "pollen" | "humidity" | "uv" | "visibility" | "pressure" |
// "cloudCover" | "sunMoon" | "conditions"); opts.pollutant for airQuality
// ("index" | "pm25" | "pm10" | "o3" | "no2" | "so2" | "co");
// opts.temperatureMinSpan / opts.pressureMinSpan override the AXIS table's
// minimum spans (a host's tunables; absent or <= 0 keeps the table's).
//
//     spec = {
//         metric, title, unit,
//         xLabels: [24 hour labels], nowIndex,            // nowIndex -1 unless the day holds "now"
//         series: [ { id, kind, values, color: ROLE, bandLow, width, dotted, gradient, range } ],
//         thresholds: [ { value, label, color: ROLE } ],
//         gradientStops: [ { value, color: ROLE } ],
//         yMin, yMax (NaN = auto), yMaxFloor (NaN = none), yMinSpan (0 = none),
//         yTicks, yNiceSteps, yFormat: v => string,       // AXIS POLICY below
//         hourly: bool,                                    // false: the daily figure as a flat line ("daily only")
//         empty: bool, emptyText,
//         summary: { valueAt(i), detailAt(i), bandAt(i), dayValue, dayLine, dayBand,
//                    valueTemplate },                   // a string, or a list: the widest sizes the slot
//         about: { title, unit, source, text } | null,
//         scale: [ { band, name, range, advice } ],
//         pollutants, pollutant,                           // airQuality
//         speciesRows,                                     // pollen
//         sunMoon: { sunrise, sunset, daylight, sunshine, moonrise, moonset, moonPhase, moonName, illumination },
//         glyphRow: [ { kind, intensity, night, shower, moonPhase } | null ], kmiText   // conditions
//     }
//
// COLOURS ARE ROLES, NOT VALUES. This is a library script with no Qt in it,
// and a theme token cannot live in a data array anyway (the Repeater rule):
// every `color` is a ROLE string -- "accent", "textMuted", "textFaint", "sun",
// "cloud", "rain", "snow", "storm", "fog", "night", "band:N" -- and
// WeatherDetail resolves it to a Theme token in QML when it hands the spec to
// the chart. Values are in the model's canonical units; `F` converts them
// wherever they are printed (yFormat, the summary, the scale table), so the
// chart's geometry never knows what unit the user chose.
//
// HOURS. The model's `hourly` starts at the current hour; the hours of today before it are
// the model's `hoursToday` (kept until the date changes), so today's chart is the whole day.
// A day past the hourly span has no hours at all and shows the daily figure as a flat line
// instead (`hourly: false`); the forecast's last day, cut short by the model's horizon, has
// null figures for its later hours (gaps).
// =============================================================================

var HOUR_MS = 3600000;
var DASH = "–";

var METRIC_TITLES = {
    temperature: "Temperature", feelsLike: "Feels like", precipitation: "Precipitation", wind: "Wind",
    airQuality: "Air quality", pollen: "Pollen", humidity: "Humidity", uv: "UV index",
    visibility: "Visibility", pressure: "Pressure", cloudCover: "Cloud cover", sunMoon: "Sun and moon",
    conditions: "Conditions"
};

var POLLUTANT_TABS = [
    { id: "index", label: "AQI" }, { id: "pm25", label: "PM2.5" }, { id: "pm10", label: "PM10" },
    { id: "o3", label: "O3" }, { id: "no2", label: "NO2" }, { id: "so2", label: "SO2" }, { id: "co", label: "CO" }
];

// Cold to warm, in degC: the temperature line's own gradient.
var TEMP_STOPS = [
    { value: -10, color: "storm" }, { value: 0, color: "rain" }, { value: 8, color: "band:0" },
    { value: 15, color: "band:1" }, { value: 22, color: "band:2" }, { value: 28, color: "band:3" },
    { value: 35, color: "band:4" }
];

// -----------------------------------------------------------------------------
// AXIS POLICY
//
// Left to its data an auto axis puts every day's worst hour at the top of the
// plot, so an EAQI of 26 ("Fair") would draw as high as a smog day. Each chart
// takes one of three policies, chosen from the axis every chart drew for
// every day of twelve mock scenarios (the live fixture's five AQ
// days, EAQI 18-32, put their worst hour at 42-53 % of the plot, against
// 80-100 % on an auto axis):
//
//   FLOOR     the axis top is at least the value where the scale says it
//             starts to matter; data under it draws against it, data above
//             extends the axis to nice ticks exactly as an auto axis does.
//   MIN SPAN  a range axis (no natural zero) is at least this wide about its
//             data's midpoint, so a 1 degree evening does not draw as a swing.
//   AS IS     the axis is already fixed by the quantity (a percentage, the
//             sky's altitude) and the data cannot distort it.
//
// Floors are READ FROM WeatherScales by band name (`floorAt`), never retyped,
// so a revised scale moves its chart with it.
//
// metric              | policy   | numbers                              | why
// --------------------+----------+--------------------------------------+-----------------------------------------
// temperature         | min span | 10 °C (ticks 1/2/5)                  | a Belgian summer day's own swing (KMI Uccle
// feelsLike           |          |                                      | normals, July: max ~23, min ~13): a full plot
//                     |          |                                      | means a full summer day; the fixture's
//                     |          |                                      | 3.9° evening spans 33 % of it (78 % on an auto axis)
// RELIEF (air quality only): a floor is for the common hour. When the data does not even reach
// `aqReliefShare` of it (SO2 at 3 µg/m³ against a 350 floor: a line 1 px off the foot of a
// 0-400 axis, which reads as dud data) the floor is dropped and the axis fits the data from 0,
// at least `aqMinSpan` µg/m³ (index points) tall so its ticks stay distinct. The bands that
// are then off the axis are simply not drawn (the chart draws a threshold only inside its axis).
// 5 %: below it the line sits within ~6 px of the foot of the 120 px plot (CO's usual 250 µg/m³ is 6 % of
// its 4000 floor and keeps it; SO2's 1.5 against 350 is 0.4 % and does not).
//
// precipitation       | floor    | 2.5 mm/h (WMO "Moderate")            | light rain (< 2.5) is the common hour and
//                     |          |                                      | reads as the lower part; 0.1 mm still
//                     |          |                                      | draws 5 px on the 120 px plot
// wind (+ gusts)      | floor    | 50 km/h (Beaufort 7, "Near gale";    | where the scale turns from moving things
//                     |          | ticks 1/2/5)                         | to impeding people; the fog scenario's
//                     |          |                                      | calm 11 km/h reaches 18 % (72 % on an auto axis)
// airQuality index    | floor    | EAQI 60 / BelAQI 5.5 ("Poor")        | EEA: the first band whose advice is for
//                     |          |                                      | everyone, not only sensitive people
// PM2.5 PM10 O3 NO2   | floor    | 25 / 50 / 130 / 120 / 350 µg/m³      | the same EEA "Poor" band per pollutant
// SO2                 |          | ("Poor")                             | (hourly index bands)
// CO                  | floor    | 4000 µg/m³ ("Above guideline")       | not in the EAQI; the WHO 2021 24-hour
//                     |          |                                      | guideline is the one official figure
// pollen (per species)| floor    | the species' "High" level            | Breezy's per-species thresholds (grass 25,
//                     |          | (grass 25, birch 50, ragweed 11)     | birch 50): where most allergic people react
// uv                  | floor    | 8 ("Very high")                      | WHO's own grouping of its advice: 0-2 none,
//                     |          |                                      | 3-7 protect, 8+ extra protection; an
//                     |          |                                      | evening's 0.8 fills 10 % (the plot on an auto axis)
// visibility          | floor    | 10 km (top of "Moderate")            | under 10 km something (haze, mist, fog) is
//                     |          |                                      | in the air; a 400 m fog evening draws 4 % of
//                     |          |                                      | the plot (400 m as its TOP on an auto axis)
// pressure            | min span | 20 hPa (ticks 1/2/5)                 | a front moves ~10 hPa in a day: a 0.6 hPa
//                     |          |                                      | evening fills 2 % of it (the plot on an auto axis)
// humidity            | as is    | 0-100 % (dew point on its -10..30)   | a percentage has its own full scale
// cloudCover          | as is    | 0-100 %                              | same
// precip. probability | as is    | 0-100 % (own range)                  | same
// sunMoon             | as is    | -75..75° (fixed, 25° ticks)          | symmetric about the horizon already
// conditions          | --       | no axis                              | a glyph strip
// -----------------------------------------------------------------------------
var AXIS = {
    temperatureMinSpan: 10,
    pressureMinSpan: 20,
    // Figures that print as whole numbers take no 2.5 step.
    wholeSteps: [1, 2, 5],
    floors: {
        precipitation: ["precipitation", "Moderate"],
        wind: ["beaufort", "Near gale"],
        uv: ["uv", "Very high"],
        visibility: ["visibility", "Good"],
        eaqi: ["eaqi", "Poor"], belaqi: ["belaqi", "Poor"],
        pm25: ["pm25", "Poor"], pm10: ["pm10", "Poor"], o3: ["o3", "Poor"], no2: ["no2", "Poor"], so2: ["so2", "Poor"],
        co: ["co", "Above guideline"]
    },
    pollenLevel: "High",
    aqReliefShare: 0.05,
    aqMinSpan: 1
};

// The lower bound of the band called `name` on scale `id` (the upper bound of
// the band before it); NaN when the scale has no such band or it is the first.
function bandStart(id, name) {
    const bs = Scales.bands(id);
    let lo = NaN;
    for (let i = 0; i < bs.length; i++) {
        if (bs[i].name === name)
            return lo;
        lo = bs[i].hi;
    }
    return NaN;
}

// A chart's axis-top floor from the policy table, by key.
function floorAt(key) {
    const f = AXIS.floors[key];
    return f ? bandStart(f[0], f[1]) : NaN;
}

// A pollen species' floor: the lower bound of its "High" level.
function pollenFloor(spInfo) {
    if (!spInfo)
        return NaN;
    const k = Scales.SCALES.pollen.levelNames.indexOf(AXIS.pollenLevel);
    return k >= 1 && isNum(spInfo.hi[k - 1]) ? spInfo.hi[k - 1] : NaN;
}

// About texts for the metrics that have no scale of their own in WeatherScales.
var OWN_ABOUT = {
    temperature: {
        title: "Temperature", unit: "°C", source: "Open-Meteo, best-match model, 2 m above ground",
        text: "The air temperature two metres above the ground, in the shade. The dotted line is what it feels like: the same air with the wind and the humidity taken into account."
    },
    feelsLike: {
        title: "Feels like", unit: "°C", source: "Open-Meteo apparent temperature (wind, humidity and solar radiation)",
        text: "What the air does to a person rather than to a thermometer: wind takes heat away, humidity keeps sweat from working, and sun adds warmth. The dotted line is the measured temperature."
    },
    sunMoon: {
        title: "Sun and moon", unit: "°", source: "Open-Meteo for rise and set; positions computed on the device (SunCalc, BSD-2)",
        text: "How high the sun and the moon stand above the horizon through the day. Sunrise and sunset are when the sun's upper edge meets the horizon, refraction included; the moon's phase is where it is in its 29.5-day cycle."
    },
    conditions: {
        title: "Conditions", unit: "", source: "Open-Meteo weather codes (WMO 4677); KMI forecast text for the first eight days",
        text: "The sky and any precipitation each hour, as one condition. A sun or moon peeking from behind a cloud means showers: rain that comes and goes rather than steady rain."
    }
};

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

function isNum(v) {
    return typeof v === "number" && isFinite(v);
}

// THE DAY GRID IS THE WALL CLOCK, 24 SLOTS: slot i is the hour that reads i:00 on the day's date. A day with 23 or 25
// hours (the changes) keeps 24 slots: the hour the spring change skips is an empty slot, and the hour the fall change
// repeats shows its later reading. A slot is never `dateMs + i h`, which on those two days is a slot of the next date
// (spring) or a label that repeats and an hour that is missing (fall). Dates and clock hours are the model's Brussels
// rule on the instant (tools/dev/dst_audit_cases.js W2).
function slotOf(day, ms) {
    if (!day || !isNum(day.dateMs) || !isNum(ms) || WM.dateKey(ms) !== WM.dateKey(day.dateMs))
        return -1;
    return WM.localParts(ms).hour;
}

// The instant of slot i of a day, null for the hour a spring change skips.
function slotMs(day, i) {
    if (!day || !isNum(day.dateMs))
        return null;
    const t = WM.parseLocal(WM.dateKey(day.dateMs) + "T" + (i < 10 ? "0" : "") + i + ":00", null);
    return t !== null && WM.localParts(t).hour === i ? t : null;
}

function hoursOfDay(model, day) {
    const out = [];
    for (let i = 0; i < 24; i++)
        out.push(null);
    if (!model || !day || !isNum(day.dateMs) || !Array.isArray(model.hourly))
        return out;
    const past = Array.isArray(model.hoursToday) ? model.hoursToday : [];
    for (let k = 0; k < past.length + model.hourly.length; k++) {
        const h = k < past.length ? past[k] : model.hourly[k - past.length];
        if (!h || !isNum(h.timeMs))
            continue;
        const i = slotOf(day, h.timeMs);
        if (i >= 0)
            out[i] = h;
    }
    return out;
}

function anyHour(hours) {
    for (let i = 0; i < hours.length; i++) {
        if (hours[i])
            return true;
    }
    return false;
}

function vals(hours, fn) {
    const out = [];
    for (let i = 0; i < hours.length; i++) {
        const h = hours[i];
        let v = null;
        if (h) {
            try { v = fn(h); } catch (e) { v = null; }
        }
        out.push(isNum(v) ? v : null);
    }
    return out;
}

function flat(v) {
    const out = [];
    for (let i = 0; i < 24; i++)
        out.push(isNum(v) ? v : null);
    return out;
}

function labelsOf(day, F) {
    // The wall-clock hours, whatever the day's length. F.hour reads only the Brussels clock hour of an instant, so a
    // January instant whose Brussels clock reads i:00 (UTC+1) names slot i on any day, the skipped hour's included.
    const out = [];
    for (let i = 0; i < 24; i++)
        out.push(F.hour(Date.UTC(2021, 0, 15, i - 1)));
    return out;
}

function nowIndexOf(model, day) {
    if (!model || !day || !isNum(day.dateMs))
        return -1;
    const t = model.current && isNum(model.current.timeMs) ? model.current.timeMs
            : (Array.isArray(model.hourly) && model.hourly[0] ? model.hourly[0].timeMs : null);
    if (!isNum(t))
        return -1;
    return slotOf(day, t);
}

function bandInfo(b) {
    return b ? { name: b.name, band: b.band } : null;
}

// "lo–hi unit", "< hi unit" or "≥ lo unit".
function rangeText(lo, hi, fmt, unit) {
    const u = unit ? " " + unit : "";
    if (!isFinite(lo) || lo === -Infinity)
        return "< " + fmt(hi) + u;
    if (!isFinite(hi))
        return "≥ " + fmt(lo) + u;
    return fmt(lo) + DASH + fmt(hi) + u;
}

function scaleRows(id, fmt, unit) {
    const bs = Scales.bands(id);
    const rows = [];
    let lo = -Infinity;
    for (let i = 0; i < bs.length; i++) {
        const b = bs[i];
        rows.push({ band: b.band, name: b.name, range: rangeText(lo, b.hi, fmt, unit), advice: b.advice || "" });
        lo = b.hi;
    }
    return rows;
}

// Thresholds at the upper bound of bands[from..to]: each labelled with the
// name of the band that STARTS there.
function bandThresholds(id, indices) {
    const bs = Scales.bands(id);
    const out = [];
    for (let k = 0; k < indices.length; k++) {
        const i = indices[k];
        if (i + 1 >= bs.length || !isFinite(bs[i].hi))
            continue;
        out.push({ value: bs[i].hi, label: bs[i + 1].name, color: "band:" + bs[i + 1].band });
    }
    return out;
}

// Gradient stops coloured by band: one at the start of every band.
function bandGradient(id) {
    const bs = Scales.bands(id);
    const out = [];
    let lo = 0;
    for (let i = 0; i < bs.length; i++) {
        out.push({ value: lo, color: "band:" + bs[i].band });
        if (!isFinite(bs[i].hi))
            break;
        lo = bs[i].hi;
    }
    return out;
}

function plain(v) {
    return isNum(v) ? (Math.abs(v - Math.round(v)) < 1e-9 ? String(Math.round(v)) : String(Math.round(v * 10) / 10)) : DASH;
}

function pct(F, v) {
    return isNum(v) ? F.percent(v) + " %" : DASH;
}

function emptySpec(metric, text) {
    return {
        metric: metric, title: METRIC_TITLES[metric] || metric, unit: "",
        xLabels: [], nowIndex: -1, series: [], thresholds: [], gradientStops: [],
        yMin: NaN, yMax: NaN, yMaxFloor: NaN, yMinSpan: 0, yTicks: 4, yNiceSteps: [1, 2, 2.5, 5],
        yFormat: null, hourly: false, empty: true, emptyText: text,
        summary: {
            valueAt: function () { return DASH; }, detailAt: function () { return ""; },
            bandAt: function () { return null; },
            dayValue: DASH, dayLine: text, dayBand: null, valueTemplate: "88"
        },
        about: OWN_ABOUT[metric] || null, scale: [],
        pollutants: [], pollutant: "index", speciesRows: [], sunMoon: null, glyphRow: [], kmiText: null
    };
}

// -----------------------------------------------------------------------------
// forDay
// -----------------------------------------------------------------------------

// Whether the chart of `to` morphs out of the chart of `from`: the chart matches series by id and kind, so two metrics do when they plot the same
// series (the same metric on another day, temperature and feels-like) and otherwise the old lines would only leave and the new ones arrive.
function morphsInto(from, to) {
    const fam = function (m) { return m === "feelsLike" ? "temperature" : m; };
    return !!from && !!to && fam(from) === fam(to);
}

function forDay(model, metric, dayIndex, F, opts) {
    opts = opts || {};
    const minSpan = function (name) {
        return isNum(opts[name]) && opts[name] > 0 ? opts[name] : AXIS[name];
    };
    if (!model || !Array.isArray(model.daily) || model.daily.length === 0)
        return emptySpec(metric, "No data");
    const d = Math.max(0, Math.min(model.daily.length - 1, isNum(dayIndex) ? dayIndex : 0));
    const day = model.daily[d];
    const hours = hoursOfDay(model, day);
    const hourly = anyHour(hours);
    const isNow = d === 0 && model.current;

    const spec = emptySpec(metric, "");
    spec.empty = false;
    spec.xLabels = labelsOf(day, F);
    spec.nowIndex = nowIndexOf(model, day);
    spec.hourly = hourly;
    spec.summary.dayLine = "";

    // The hourly value of `fn`, or the daily figure flat across the day.
    const hourlyOr = function (fn, dailyValue) {
        return hourly ? vals(hours, fn) : flat(dailyValue);
    };
    const at = function (i, fn) {
        if (!hourly)
            return null;
        const h = hours[i];
        if (!h)
            return null;
        try { const v = fn(h); return v === undefined ? null : v; } catch (e) { return null; }
    };
    const dailyOnly = hourly ? "" : " · daily only";

    switch (metric) {
    case "temperature":
    case "feelsLike": {
        const feels = metric === "feelsLike";
        const main = feels ? function (h) { return h.feelsLike; } : function (h) { return h.temp; };
        const other = feels ? function (h) { return h.temp; } : function (h) { return h.feelsLike; };
        const dMain = feels ? day.feelsLike : day.temp;
        const dOther = feels ? day.temp : day.feelsLike;
        spec.unit = F.tempUnit();
        spec.series = [
            { id: "main", kind: "line", values: hourlyOr(main, dMain ? dMain.max : null), color: "accent", width: 2, gradient: true },
            { id: "other", kind: "line", values: hourlyOr(other, dOther ? dOther.max : null), color: "textMuted", width: 1.5, dotted: true }
        ];
        spec.gradientStops = TEMP_STOPS;
        spec.thresholds = [{ value: 0, label: "Freezing", color: "snow" }];
        spec.yMinSpan = minSpan("temperatureMinSpan");
        spec.yNiceSteps = AXIS.wholeSteps;
        // Five intervals: the 10-degree span in 2-degree steps (four make
        // them 5 and the axis half as wide again as the span).
        spec.yTicks = 5;
        spec.yFormat = function (v) { return F.temp(v); };
        spec.summary.valueAt = function (i) { return F.temp(at(i, main)); };
        spec.summary.detailAt = function (i) {
            const o = at(i, other);
            return isNum(o) ? (feels ? "measured " : "feels ") + F.temp(o) : "";
        };
        spec.summary.dayValue = isNow && isNum(feels ? model.current.feelsLike : model.current.temp)
            ? F.temp(feels ? model.current.feelsLike : model.current.temp)
            : F.temp(dMain ? dMain.max : null);
        spec.summary.dayLine = "Max " + F.temp(dMain ? dMain.max : null) + " · Min " + F.temp(dMain ? dMain.min : null) + dailyOnly;
        spec.summary.valueTemplate = "−88°";
        spec.about = OWN_ABOUT[metric];
        break;
    }
    case "precipitation": {
        const unit = F.precipUnit();
        const mm = hourlyOr(function (h) { return h.precip.mm; }, day.precip ? day.precip.total : null);
        spec.unit = unit + "/h";
        spec.series = [
            { id: "mm", kind: "bars", values: mm, color: "rain" },
            { id: "prob", kind: "line", values: hourlyOr(function (h) { return h.precip.prob; }, day.precip ? day.precip.prob : null),
              color: "textFaint", width: 1.5, range: [0, 100] }
        ];
        spec.thresholds = bandThresholds("precipitation", [1, 2, 3]);
        spec.yMin = 0;
        spec.yMaxFloor = floorAt("precipitation");
        // Five intervals: the 2.5 mm floor then ticks in 0.5 steps, which the
        // one-decimal formatter prints exactly (four give 1 mm steps to 3).
        spec.yTicks = 5;
        spec.yFormat = function (v) { return F.precip(v); };
        spec.summary.valueAt = function (i) { const v = at(i, function (h) { return h.precip.mm; }); return isNum(v) ? F.precip(v) + " " + unit : DASH; };
        spec.summary.detailAt = function (i) { const p = at(i, function (h) { return h.precip.prob; }); return isNum(p) ? F.percent(p) + " % chance" : ""; };
        spec.summary.bandAt = function (i) { return bandInfo(Scales.bandOf("precipitation", at(i, function (h) { return h.precip.mm; }))); };
        spec.summary.dayValue = day.precip && isNum(day.precip.total) ? F.precip(day.precip.total) + " " + unit : DASH;
        spec.summary.dayLine = day.precip
            ? "Day " + F.precip(day.precip.day) + " · Night " + F.precip(day.precip.night) + " " + unit
              + (isNum(day.precip.prob) ? " · " + F.percent(day.precip.prob) + " %" : "")
              + (isNum(day.precip.hours) ? " · " + plain(day.precip.hours) + " h" : "") + dailyOnly
            : "";
        spec.summary.valueTemplate = "88.8 " + unit;
        spec.about = Scales.about("precipitation");
        spec.scale = scaleRows("precipitation", function (v) { return F.precip(v); }, unit + "/h");
        break;
    }
    case "wind": {
        const unit = F.speedUnit();
        spec.unit = unit;
        const spd = hourlyOr(function (h) { return h.wind.speed; }, day.wind && day.wind.day ? day.wind.day.speed : null);
        const gst = hourlyOr(function (h) { return h.wind.gust; }, day.wind && day.wind.day ? day.wind.day.gust : null);
        const dir = hourlyOr(function (h) { return isNum(h.wind.dir) ? (h.wind.dir + 180) % 360 : null; },
                             day.wind && day.wind.day && isNum(day.wind.day.dir) ? (day.wind.day.dir + 180) % 360 : null);
        spec.series = [
            { id: "gust", kind: "band", values: gst, bandLow: spd, color: "accent" },
            { id: "speed", kind: "line", values: spd, color: "accent", width: 2 },
            { id: "dir", kind: "arrows", values: dir, color: "textMuted" }
        ];
        spec.thresholds = bandThresholds("beaufort", [2, 4, 6, 8]).map(function (t, k) {
            return { value: t.value, label: [3, 5, 7, 9][k] + " Bft", color: t.color };
        });
        spec.yMin = 0;
        spec.yMaxFloor = floorAt("wind");
        spec.yNiceSteps = AXIS.wholeSteps;
        spec.yFormat = function (v) { return F.speed(v); };
        spec.summary.valueAt = function (i) { const w = at(i, function (h) { return h.wind; }); return w ? F.wind(w) : DASH; };
        spec.summary.detailAt = function (i) {
            const w = at(i, function (h) { return h.wind; });
            if (!w) return "";
            const parts = [];
            if (w.dirText) parts.push(w.dirText);
            if (isNum(w.gust)) parts.push("gusts " + F.wind({ speed: w.gust, bft: w.gustBft }));
            return parts.join(" · ");
        };
        spec.summary.bandAt = function (i) { const w = at(i, function (h) { return h.wind; }); return w ? bandInfo(Scales.beaufort(w.speed)) : null; };
        const dw = day.wind && day.wind.day ? day.wind.day : null;
        const nw = day.wind && day.wind.night ? day.wind.night : null;
        spec.summary.dayValue = dw ? F.wind(dw) : DASH;
        spec.summary.dayLine = (dw ? "Day " + F.wind(dw) + (dw.dirText ? " " + dw.dirText : "") : "")
            + (nw ? " · Night " + F.wind(nw) + (nw.dirText ? " " + nw.dirText : "") : "")
            + (dw && isNum(dw.gust) ? " · gusts " + F.wind({ speed: dw.gust, bft: dw.gustBft }) : "") + dailyOnly;
        spec.summary.dayBand = dw ? bandInfo(Scales.beaufort(dw.speed)) : null;
        spec.summary.valueTemplate = F.units && F.units.wind === "speed" ? "888 " + unit : "88 Bft";
        spec.about = Scales.about("beaufort");
        spec.scale = scaleRows("beaufort", function (v) { return F.speed(v); }, unit).map(function (r, i) {
            return { band: r.band, name: i + " · " + r.name, range: r.range, advice: r.advice };
        });
        break;
    }
    case "airQuality": {
        const p = opts.pollutant && opts.pollutant !== "index" ? opts.pollutant : "index";
        const aqId = model.aqIndex === "belaqi" ? "belaqi" : "eaqi";
        const id = p === "index" ? aqId : p;
        spec.pollutants = POLLUTANT_TABS.map(function (t) {
            return t.id === "index" ? { id: "index", label: aqId === "belaqi" ? "BelAQI" : "AQI" } : t;
        });
        spec.pollutant = p;
        const fmt = p === "index" ? function (v) { return plain(v); } : function (v) { return F.conc(v, p); };
        const unit = p === "index" ? "" : F.concUnit(p);
        const title = p === "index" ? METRIC_TITLES.airQuality : (Scales.about(p) ? Scales.about(p).title : p);
        const hasAq = !!(day.aq) || (hourly && hours.some(function (h) { return h && h.aq; }));
        if (!hasAq) {
            // A day past the air-quality forecast keeps what describes the
            // SCALE -- the title, the unit, the about text and its table -- so
            // swiping onto it changes the chart, not the detail's height.
            const e = emptySpec(metric, "No air quality data");
            e.pollutants = spec.pollutants; e.pollutant = p; e.xLabels = spec.xLabels; e.nowIndex = spec.nowIndex;
            e.title = title;
            e.unit = unit;
            e.about = Scales.about(id);
            e.scale = scaleRows(id, fmt, unit);
            return e;
        }
        const get = p === "index" ? function (h) { return h.aq ? h.aq.index : null; } : function (h) { return h.aq ? h.aq[p] : null; };
        const dailyV = day.aq ? (p === "index" ? day.aq.index : day.aq[p]) : null;
        spec.title = title;
        spec.unit = unit;
        spec.series = [{ id: "aq", kind: "line", values: hourlyOr(get, dailyV), color: "accent", width: 2, gradient: true }];
        spec.gradientStops = bandGradient(id);
        const bs = Scales.bands(id);
        const idx = [];
        for (let i = 0; i + 1 < bs.length; i++) idx.push(i);
        spec.thresholds = bandThresholds(id, idx);
        spec.yMin = 0;
        spec.yMaxFloor = floorAt(id);
        // The floor holds only while the data reaches a share of it (see RELIEF above).
        let aqTop = -Infinity;
        for (const v of spec.series[0].values)
            if (isNum(v) && v > aqTop) aqTop = v;
        if (isNum(spec.yMaxFloor) && isFinite(aqTop) && aqTop < AXIS.aqReliefShare * spec.yMaxFloor) {
            spec.yMaxFloor = NaN;
            spec.yMinSpan = AXIS.aqMinSpan;
        }
        spec.yFormat = fmt;
        spec.summary.valueAt = function (i) { const v = at(i, get); return isNum(v) ? fmt(v) + (unit ? " " + unit : "") : DASH; };
        spec.summary.detailAt = function () { return ""; };
        spec.summary.bandAt = function (i) { return bandInfo(Scales.bandOf(id, at(i, get))); };
        spec.summary.dayValue = isNum(dailyV) ? fmt(dailyV) + (unit ? " " + unit : "") : DASH;
        spec.summary.dayLine = (isNum(dailyV) ? "Worst hour of the day" : "") + dailyOnly;
        spec.summary.dayBand = bandInfo(Scales.bandOf(id, dailyV));
        spec.summary.valueTemplate = p === "index" ? "888" : "888.8 " + unit;
        spec.about = Scales.about(id);
        spec.scale = scaleRows(id, fmt, unit);
        break;
    }
    case "pollen": {
        const dp = day.pollen;
        if (!dp || !dp.primary) {
            const e = emptySpec(metric, dp ? "No active pollen" : "No pollen data");
            e.xLabels = spec.xLabels; e.nowIndex = spec.nowIndex;
            e.about = Scales.about("pollen");
            e.speciesRows = dp ? speciesRowsOf(dp, F) : [];
            e.summary.dayLine = model.pollenNote ? "KMI: " + model.pollenNote : e.summary.dayLine;
            return e;
        }
        const sp = opts.species || dp.primary.species || dp.primary.id;
        const spInfo = Scales.SCALES.pollen.species[sp];
        const spName = spInfo ? spInfo.name : sp;
        const get = function (h) {
            if (!h.pollen) return null;
            for (let k = 0; k < h.pollen.species.length; k++)
                if (h.pollen.species[k].id === sp) return h.pollen.species[k].conc;
            return null;
        };
        let dailyV = null;
        for (let k = 0; k < dp.species.length; k++)
            if (dp.species[k].id === sp) dailyV = dp.species[k].conc;
        spec.title = "Pollen · " + spName;
        spec.unit = "grains/m³";
        spec.series = [{ id: "pollen", kind: "bars", values: hourlyOr(get, dailyV), color: "band:1" }];
        const names = Scales.SCALES.pollen.levelNames, lb = Scales.SCALES.pollen.levelBands;
        spec.thresholds = spInfo ? [1, 2, 3].map(function (k) {
            return { value: spInfo.hi[k], label: names[k + 1], color: "band:" + lb[k + 1] };
        }) : [];
        spec.yMin = 0;
        spec.yMaxFloor = pollenFloor(spInfo);
        spec.yFormat = function (v) { return plain(v); };
        spec.summary.valueAt = function (i) { const v = at(i, get); return isNum(v) ? plain(v) : DASH; };
        spec.summary.detailAt = function () { return spName; };
        spec.summary.bandAt = function (i) { const l = Scales.pollenLevel(sp, at(i, get)); return l ? { name: l.name, band: l.band } : null; };
        spec.summary.dayValue = isNum(dailyV) ? plain(dailyV) : DASH;
        spec.summary.dayLine = "Primary " + (dp.primary.name || spName) + " · daily max" + dailyOnly
            + (model.pollenNote ? " · KMI: " + model.pollenNote : "");
        const dl = Scales.pollenLevel(sp, dailyV);
        spec.summary.dayBand = dl ? { name: dl.name, band: dl.band } : null;
        spec.summary.valueTemplate = "888";
        spec.about = Scales.about("pollen");
        spec.speciesRows = speciesRowsOf(dp, F);
        if (spInfo) {
            const rows = [];
            let lo = -Infinity;
            for (let k = 0; k < names.length; k++) {
                const hi = k < names.length - 1 ? spInfo.hi[k] : Infinity;
                rows.push({ band: lb[k], name: names[k], range: rangeText(lo, hi, plain, ""), advice: k === 0 ? spName + " thresholds" : "" });
                lo = hi;
            }
            spec.scale = rows;
        }
        break;
    }
    case "humidity": {
        spec.unit = "%";
        spec.series = [
            { id: "rh", kind: "line", values: hourlyOr(function (h) { return h.humidity; }, day.humidity), color: "rain", width: 2 },
            { id: "dew", kind: "line", values: hourlyOr(function (h) { return h.dewPoint; }, day.dewPoint), color: "textMuted", width: 1.5, dotted: true, range: [-10, 30] }
        ];
        spec.thresholds = bandThresholds("humidity", [0, 1, 2, 3]);
        spec.yMin = 0;
        spec.yMax = 100;
        spec.yFormat = function (v) { return F.percent(v); };
        spec.summary.valueAt = function (i) { return pct(F, at(i, function (h) { return h.humidity; })); };
        spec.summary.detailAt = function (i) { const t = at(i, function (h) { return h.dewPoint; }); return isNum(t) ? "dew point " + F.temp(t) : ""; };
        spec.summary.bandAt = function (i) { return bandInfo(Scales.bandOf("dewPoint", at(i, function (h) { return h.dewPoint; }))); };
        spec.summary.dayValue = pct(F, day.humidity);
        spec.summary.dayLine = "Mean · dew point " + F.temp(day.dewPoint) + dailyOnly;
        spec.summary.dayBand = bandInfo(Scales.bandOf("dewPoint", day.dewPoint));
        spec.summary.valueTemplate = "888 %";
        spec.about = Scales.about("humidity");
        spec.scale = scaleRows("dewPoint", function (v) { return F.temp(v); }, "dew point");
        break;
    }
    case "uv": {
        spec.unit = "";
        spec.series = [{ id: "uv", kind: "bars", values: hourlyOr(function (h) { return h.uv; }, day.uvMax), color: "sun" }];
        spec.thresholds = bandThresholds("uv", [0, 1, 2, 3]);
        spec.yMin = 0;
        spec.yMaxFloor = floorAt("uv");
        spec.yFormat = function (v) { return plain(v); };
        spec.summary.valueAt = function (i) { const v = at(i, function (h) { return h.uv; }); return isNum(v) ? plain(v) : DASH; };
        spec.summary.bandAt = function (i) { return bandInfo(Scales.bandOf("uv", at(i, function (h) { return h.uv; }))); };
        spec.summary.dayValue = isNum(day.uvMax) ? plain(day.uvMax) : DASH;
        spec.summary.dayLine = "Daily maximum" + dailyOnly;
        spec.summary.dayBand = bandInfo(Scales.bandOf("uv", day.uvMax));
        spec.summary.valueTemplate = "88.8";
        spec.about = Scales.about("uv");
        spec.scale = scaleRows("uv", plain, "");
        break;
    }
    case "visibility": {
        const unit = F.distanceUnit();
        spec.unit = unit;
        spec.series = [{ id: "vis", kind: "line", values: hourlyOr(function (h) { return h.visibility; }, day.visibility ? day.visibility.mean : null), color: "fog", width: 2 }];
        spec.thresholds = Scales.bands("visibility").slice(0, 4).map(function (b) { return { value: b.hi, label: b.name, color: "band:" + b.band }; });
        spec.yMin = 0;
        spec.yMaxFloor = floorAt("visibility");
        spec.yFormat = function (v) { return F.distance(v); };
        spec.summary.valueAt = function (i) { const v = at(i, function (h) { return h.visibility; }); return isNum(v) ? F.distance(v) + " " + unit : DASH; };
        spec.summary.bandAt = function (i) { return bandInfo(Scales.bandOf("visibility", at(i, function (h) { return h.visibility; }))); };
        const dv = day.visibility || null;
        spec.summary.dayValue = dv && isNum(dv.min) ? F.distance(dv.min) + DASH + F.distance(dv.max) + " " + unit : DASH;
        spec.summary.dayLine = dv ? "Mean " + F.distance(dv.mean) + " " + unit + dailyOnly : "";
        spec.summary.dayBand = dv ? bandInfo(Scales.bandOf("visibility", dv.min)) : null;
        spec.summary.valueTemplate = "88.8" + DASH + "88.8 " + unit;
        spec.about = Scales.about("visibility");
        spec.scale = scaleRows("visibility", function (v) { return F.distance(v); }, unit);
        break;
    }
    case "pressure": {
        const unit = F.pressureUnit();
        spec.unit = unit;
        spec.series = [
            { id: "p", kind: "line", values: hourlyOr(function (h) { return h.pressure; }, day.pressure), color: "accent", width: 2 },
            { id: "trend", kind: "arrows", values: hourlyOr(function (h) { return h.pressureTrend > 0 ? 0 : (h.pressureTrend < 0 ? 180 : null); },
                                                          day.pressureTrend > 0 ? 0 : (day.pressureTrend < 0 ? 180 : null)), color: "textMuted" }
        ];
        spec.thresholds = [{ value: 1013.25, label: "Standard", color: "textFaint" }];
        spec.yMinSpan = minSpan("pressureMinSpan");
        spec.yNiceSteps = AXIS.wholeSteps;
        spec.yFormat = function (v) { return F.pressure(v); };
        const trendWord = function (t) { return t > 0 ? "rising" : (t < 0 ? "falling" : "steady"); };
        spec.summary.valueAt = function (i) { const v = at(i, function (h) { return h.pressure; }); return isNum(v) ? F.pressure(v) + " " + unit : DASH; };
        spec.summary.detailAt = function (i) { const t = at(i, function (h) { return h.pressureTrend; }); return isNum(t) ? trendWord(t) : ""; };
        spec.summary.bandAt = function (i) { return bandInfo(Scales.bandOf("pressure", at(i, function (h) { return h.pressure; }))); };
        spec.summary.dayValue = isNum(day.pressure) ? F.pressure(day.pressure) + " " + unit : DASH;
        spec.summary.dayLine = "Mean · " + trendWord(day.pressureTrend) + dailyOnly;
        spec.summary.dayBand = bandInfo(Scales.bandOf("pressure", day.pressure));
        spec.summary.valueTemplate = "8888 " + unit;
        spec.about = Scales.about("pressure");
        spec.scale = scaleRows("pressure", function (v) { return F.pressure(v); }, unit);
        break;
    }
    case "cloudCover": {
        spec.unit = "%";
        spec.series = [{ id: "cc", kind: "bars", values: hourlyOr(function (h) { return h.cloudCover; }, day.cloud ? day.cloud.mean : null), color: "cloud" }];
        spec.thresholds = bandThresholds("cloudCover", [0, 1, 2, 3]);
        spec.yMin = 0;
        spec.yMax = 100;
        spec.yFormat = function (v) { return F.percent(v); };
        spec.summary.valueAt = function (i) { return pct(F, at(i, function (h) { return h.cloudCover; })); };
        spec.summary.detailAt = function (i) { const o = Scales.oktas(at(i, function (h) { return h.cloudCover; })); return o >= 0 ? o + " okta" : ""; };
        spec.summary.bandAt = function (i) { return bandInfo(Scales.bandOf("cloudCover", at(i, function (h) { return h.cloudCover; }))); };
        const dc = day.cloud || null;
        spec.summary.dayValue = dc ? pct(F, dc.mean) : DASH;
        spec.summary.dayLine = dc ? "Min " + pct(F, dc.min) + " · Max " + pct(F, dc.max) + dailyOnly : "";
        spec.summary.dayBand = dc ? bandInfo(Scales.bandOf("cloudCover", dc.mean)) : null;
        spec.summary.valueTemplate = "888 %";
        spec.about = Scales.about("cloudCover");
        spec.scale = scaleRows("cloudCover", function (v) { return F.percent(v); }, "%");
        break;
    }
    case "sunMoon": {
        const lat = model.location ? model.location.lat : null;
        const lon = model.location ? model.location.lon : null;
        const ok = isNum(lat) && isNum(lon) && isNum(day.dateMs);
        const sun = [], moon = [];
        for (let i = 0; i < 24; i++) {
            const t = ok ? slotMs(day, i) : null;
            sun.push(t !== null ? Math.round(Astro.sunAltitudeDeg(t, lat, lon) * 10) / 10 : null);
            moon.push(t !== null ? Math.round(Astro.moonAltitudeDeg(t, lat, lon) * 10) / 10 : null);
        }
        spec.unit = "";
        spec.hourly = true;
        spec.series = [
            { id: "sun", kind: "line", values: sun, color: "sun", width: 2 },
            { id: "moon", kind: "line", values: moon, color: "night", width: 1.5 }
        ];
        spec.thresholds = [{ value: 0, label: "Horizon", color: "textFaint" }];
        // A fixed, symmetric axis: the horizon is the centre line and the
        // sun's summer noon (62° here) and the winter night (-62°) both fit.
        // Left to the data, a night at -60 makes the nice step 50 and the
        // axis run to -100. Its ends are ticks (25° steps, six of them), so
        // the top figure's ink is the chart's margin as on every other chart
        // (-70..70 puts its top figure at 50°, 16 px down).
        spec.yMin = -75;
        spec.yMax = 75;
        spec.yTicks = 6;
        spec.yFormat = function (v) { return plain(v) + "°"; };
        spec.summary.valueAt = function (i) { return isNum(sun[i]) ? "Sun " + plain(Math.round(sun[i])) + "°" : DASH; };
        spec.summary.detailAt = function (i) { return isNum(moon[i]) ? "moon " + plain(Math.round(moon[i])) + "°" : ""; };
        spec.summary.dayValue = F.time(day.sunriseMs) + " " + DASH + " " + F.time(day.sunsetMs);
        spec.summary.dayLine = "Daylight " + F.duration(day.daylightS) + (day.moonName ? " · " + day.moonName : "");
        spec.summary.valueTemplate = "Sun 88°";
        const ill = isNum(day.moonIllumination) ? (day.moonIllumination > 1 ? day.moonIllumination : day.moonIllumination * 100) : null;
        spec.sunMoon = {
            sunrise: F.time(day.sunriseMs), sunset: F.time(day.sunsetMs),
            daylight: F.duration(day.daylightS), sunshine: F.duration(day.sunshineS),
            moonrise: F.time(day.moonriseMs), moonset: F.time(day.moonsetMs),
            moonPhase: isNum(day.moonPhase) ? day.moonPhase : 0.5,
            moonName: day.moonName || DASH,
            illumination: isNum(ill) ? F.percent(ill) + " %" : DASH
        };
        spec.about = OWN_ABOUT.sunMoon;
        break;
    }
    case "conditions": {
        const text = function (c) { return c && c.kind ? WM.conditionText(c.kind, c.intensity, c.night, c.shower, c.code) : DASH; };
        spec.unit = "";
        spec.series = [];
        spec.glyphRow = [];
        for (let i = 0; i < 24; i++) {
            const h = hours[i];
            spec.glyphRow.push(h && h.kind ? { kind: h.kind, intensity: isNum(h.intensity) ? h.intensity : 1, night: !!h.night, shower: !!h.shower, moonPhase: isNum(day.moonPhase) ? day.moonPhase : 0.5 } : null);
        }
        spec.summary.valueAt = function (i) { return hourly && hours[i] ? text(hours[i]) : DASH; };
        spec.summary.dayValue = text(day.day);
        spec.summary.dayLine = "Night: " + text(day.night) + dailyOnly;
        // Every label conditionText can print: the slot is the widest.
        spec.summary.valueTemplate = WM.conditionTexts();
        spec.kmiText = day.kmiText || null;
        spec.about = OWN_ABOUT.conditions;
        break;
    }
    default:
        return emptySpec(metric, "Unknown metric");
    }
    if (!hourly && spec.summary.dayLine.indexOf("daily only") < 0 && metric !== "sunMoon")
        spec.summary.dayLine += dailyOnly;
    return spec;
}

// The day strip's two figures for a chip: { a, b }. Temperature-ish metrics
// show max/min; the others their day's headline figure, b empty.
function chipText(model, metric, d, F) {
    const none = { a: "", b: "" };
    if (!model || !Array.isArray(model.daily) || !model.daily[d])
        return none;
    const day = model.daily[d];
    switch (metric) {
    case "temperature":
        return { a: F.temp(day.temp ? day.temp.max : null), b: F.temp(day.temp ? day.temp.min : null) };
    case "feelsLike":
        return { a: F.temp(day.feelsLike ? day.feelsLike.max : null), b: F.temp(day.feelsLike ? day.feelsLike.min : null) };
    case "precipitation":
        return { a: day.precip && isNum(day.precip.total) ? F.precip(day.precip.total) : DASH, b: "" };
    case "wind":
        return { a: day.wind && day.wind.day ? F.wind(day.wind.day) : DASH, b: "" };
    case "airQuality":
        return { a: day.aq && isNum(day.aq.index) ? plain(day.aq.index) : DASH, b: "" };
    case "pollen":
        return { a: day.pollen && day.pollen.primary ? (day.pollen.primary.levelName || "") : DASH, b: "" };
    case "humidity":
        return { a: isNum(day.humidity) ? F.percent(day.humidity) + " %" : DASH, b: "" };
    case "uv":
        return { a: isNum(day.uvMax) ? plain(day.uvMax) : DASH, b: "" };
    case "visibility":
        return { a: day.visibility && isNum(day.visibility.min) ? F.distance(day.visibility.min) : DASH, b: "" };
    case "pressure":
        return { a: isNum(day.pressure) ? F.pressure(day.pressure) : DASH, b: "" };
    case "cloudCover":
        return { a: day.cloud && isNum(day.cloud.mean) ? F.percent(day.cloud.mean) + " %" : DASH, b: "" };
    case "sunMoon":
        return { a: F.duration(day.daylightS), b: "" };
    default:
        return none;
    }
}

function speciesRowsOf(pollen, F) {
    const rows = [];
    if (!pollen || !Array.isArray(pollen.species))
        return rows;
    for (let k = 0; k < pollen.species.length; k++) {
        const s = pollen.species[k];
        rows.push({
            id: s.id, name: s.name,
            levelName: s.levelName || (isNum(s.conc) ? "" : DASH),
            band: isNum(s.band) ? s.band : -1,
            conc: isNum(s.conc) ? plain(s.conc) : DASH
        });
    }
    return rows;
}
