// tools/dev/weather_aq_axis_probe.js -- the air-quality chart's axis rule (WeatherSeries.js, RELIEF): the "Poor" floor holds only while
// the data reaches a share of it; below that the axis fits the data (from 0, at least aqMinSpan tall) and the floor is dropped.
// Run by tools/dev/weather_aq_axis_probe.sh:  node weather_aq_axis_probe.js <WeatherSeries.js dir>
// Prints "WAQ ok|FAIL <name>" lines and "WAQ RESULT PASS|FAIL (n/n checks)". No Qt: the library scripts are plain JS.
const fs = require("fs"), path = require("path");
const dir = process.argv[2];
// Every top-level function / var of a library script, as one object (a `.pragma library` file with its `.import`s as arguments).
function load(name, deps) {
    const src = fs.readFileSync(path.join(dir, name), "utf8").replace(/^\.pragma.*$/mg, "").replace(/^\.import.*$/mg, "");
    const names = [...src.matchAll(/^(?:function|var|const)\s+(\w+)/mg)].map(m => m[1]);
    const keys = Object.keys(deps || {});
    return new Function(...keys, src + "\n;return {" + names.join(",") + "};")(...keys.map(k => deps[k]));
}
const Scales = load("WeatherScales.js");
const Astro = load("Astro.js");
const WM = load("WeatherModel.js", { Scales });
const WS = load("WeatherSeries.js", { Scales, WM, Astro });

const F = { hour: ms => String(new Date(ms).getUTCHours()), conc: (v, p) => String(v), concUnit: p => "ug/m3", percent: v => String(v), units: {} };
const DAY0 = Date.UTC(2026, 8, 16);
// a day of 24 hours; `fn(i)` the pollutant's value at hour i
function model(fn) {
    const hourly = [];
    for (let i = 0; i < 24; i++)
        hourly.push({ timeMs: DAY0 + i * 3600000, aq: WM.makeAq("eaqi", 30, fn("pm25", i), fn("pm10", i), fn("o3", i), fn("no2", i), fn("so2", i), fn("co", i)) });
    return { daily: [{ dateMs: DAY0, aq: hourly[0].aq }], hourly: hourly, hoursToday: [], current: { timeMs: DAY0 }, aqIndex: "eaqi" };
}
let checks = 0, fails = 0;
function check(name, ok, detail) {
    checks++;
    if (!ok) fails++;
    console.log("WAQ " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
}
const spec = (m, p) => WS.forDay(m, "airQuality", 0, F, { pollutant: p });
const j = s => "floor=" + s.yMaxFloor + " span=" + s.yMinSpan + " yMin=" + s.yMin;

// SO2: 0.2 .. 1.5 ug/m3 against a floor of 350 (0.4 %): the floor goes, the axis fits, a minimum span is asked
let s = spec(model((p, i) => p === "so2" ? 0.2 + 1.3 * (i % 5) / 4 : 10), "so2");
check("SO2 trace: no floor", !isFinite(s.yMaxFloor), j(s));
check("SO2 trace: minimum span, from zero", s.yMinSpan >= 1 && s.yMin === 0, j(s));
// SO2 at 0: all zeros still asks the span (a flat line only because the data is flat)
s = spec(model((p, i) => p === "so2" ? 0 : 10), "so2");
check("SO2 zero: no floor, span", !isFinite(s.yMaxFloor) && s.yMinSpan >= 1, j(s));
// SO2 at 40 (11 %): the floor holds, as before
s = spec(model((p, i) => p === "so2" ? 40 : 10), "so2");
check("SO2 at 11 % of the floor keeps it", s.yMaxFloor === 350 && s.yMinSpan === 0, j(s));
// just under / over the share: 5 % of 350 = 17.5
s = spec(model((p, i) => p === "so2" ? 17 : 10), "so2");
check("SO2 just under 5 % drops it", !isFinite(s.yMaxFloor), j(s));
s = spec(model((p, i) => p === "so2" ? 18 : 10), "so2");
check("SO2 just over 5 % keeps it", s.yMaxFloor === 350, j(s));
// the usual pollutants are untouched: PM2.5 12 (floor 25), CO 250 (floor 4000, 6 %)
s = spec(model((p, i) => p === "pm25" ? 12 : 10), "pm25");
check("PM2.5 12 keeps its floor", s.yMaxFloor === 25 && s.yMinSpan === 0, j(s));
s = spec(model((p, i) => p === "co" ? 250 : 10), "co");
check("CO 250 keeps its floor", s.yMaxFloor === 4000 && s.yMinSpan === 0, j(s));
// a spike inside an otherwise tiny day: the data reaches the share, the floor holds
s = spec(model((p, i) => p === "so2" ? (i === 12 ? 60 : 0.5) : 10), "so2");
check("one real hour keeps the floor", s.yMaxFloor === 350, j(s));
// no data at all: nothing to fit, the floor is left alone
s = spec(model((p, i) => null), "so2");
check("no values: floor untouched", s.yMaxFloor === 350, j(s));
console.log("WAQ RESULT " + (fails === 0 ? "PASS" : "FAIL") + " (" + (checks - fails) + "/" + checks + " checks)");
process.exit(fails ? 1 : 0);
