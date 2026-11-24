.pragma library

// =============================================================================
// WeatherScales.js -- every scale the weather module reads a value on.
//
// A scale is a list of BANDS over one metric in its CANONICAL unit (the unit
// the model stores: degC, km/h, hPa, mm, m, %, ug/m3, grains/m3, an index).
// Each band names the range, says in one official sentence what it implies,
// and carries a colour band INDEX 0..5 (good .. extreme) that a delegate
// resolves through `Theme.bands[i]` -- rows carry the index, never a colour,
// so a theme switch reaches every dot at once (CLAUDE.md, the Repeater rule).
//
//   Scales.bandOf("uv", 6.4)          -> { i: 2, name: "High", band: 3, advice, lo, hi }
//   Scales.bands("eaqi")              -> the band list (for the scale table)
//   Scales.about("visibility")        -> { title, unit, source, text }
//   Scales.beaufort(43)               -> { bft: 6, name: "Strong breeze", kmi: "krachtig", band: 3 }
//   Scales.moonPhase(0.175)           -> { name: "Waxing crescent", illumination: 0.27 }
//
// The sources are named on every scale and shown in the detail screen's
// "About" text; where a scale is a convention rather than a standard it says
// so. Pollen thresholds are the per-species ones Breezy Weather applies to CAMS
// concentrations (not an official Belgian scale: AirAllergy publishes levels,
// not thresholds) -- flagged in `source`.
// =============================================================================

var BAND_NAMES = ["good", "fair", "moderate", "poor", "very poor", "extreme"];

// Every band: { hi: exclusive upper bound (Infinity for the last), name, band, advice }.
var SCALES = {
    uv: {
        title: "UV index",
        unit: "",
        source: "WHO Global Solar UV Index (2002)",
        text: "How strong the sun's ultraviolet radiation is at the surface. 0 to 2 needs no protection; from 3 seek shade around midday, wear a shirt, sunscreen and a hat; from 8 avoid being outside in the middle of the day.",
        bands: [
            { hi: 3,  name: "Low",       band: 1, advice: "No protection needed. You can safely stay outside." },
            { hi: 6,  name: "Moderate",  band: 2, advice: "Seek shade during midday hours; wear a shirt, sunscreen and a hat." },
            { hi: 8,  name: "High",      band: 3, advice: "Seek shade during midday hours; a shirt, sunscreen and a hat are a must." },
            { hi: 11, name: "Very high", band: 4, advice: "Avoid being outside during midday hours; shirt, sunscreen and hat are essential." },
            { hi: Infinity, name: "Extreme", band: 5, advice: "Avoid being outside during midday hours; unprotected skin burns in minutes." }
        ]
    },
    eaqi: {
        title: "European air quality index",
        unit: "",
        source: "European Environment Agency, European Air Quality Index (bands revised 2024)",
        text: "The index is the worst of the pollutant bands measured at the hour (PM2.5, PM10, NO2, O3, SO2), so it reads as the pollutant that matters most right now.",
        bands: [
            { hi: 20,  name: "Good",           band: 0, advice: "The air quality is good. Enjoy your usual outdoor activities." },
            { hi: 40,  name: "Fair",           band: 1, advice: "Enjoy your usual outdoor activities." },
            { hi: 60,  name: "Moderate",       band: 2, advice: "Enjoy your usual outdoor activities. Sensitive people should consider reducing intense outdoor activity if they have symptoms." },
            { hi: 80,  name: "Poor",           band: 3, advice: "Consider reducing intense activities outdoors if you experience symptoms such as sore eyes, a cough or a sore throat." },
            { hi: 100, name: "Very poor",      band: 4, advice: "Consider reducing intense activities outdoors. Sensitive people should reduce physical activity, particularly outdoors." },
            { hi: Infinity, name: "Extremely poor", band: 5, advice: "Reduce physical activities outdoors. Sensitive people should avoid them." }
        ]
    },
    belaqi: {
        title: "BelAQI",
        unit: "",
        source: "IRCEL-CELINE, Belgian Air Quality Index (1 to 10)",
        text: "The Belgian interregional index combines the daily PM2.5, PM10, ozone and nitrogen dioxide levels into one figure from 1 (excellent) to 10 (horrible).",
        bands: [
            { hi: 1.5, name: "Excellent",   band: 0, advice: "No health effects expected." },
            { hi: 2.5, name: "Very good",   band: 0, advice: "No health effects expected." },
            { hi: 3.5, name: "Good",        band: 1, advice: "No health effects expected." },
            { hi: 4.5, name: "Fairly good", band: 1, advice: "Slight effects possible for sensitive people." },
            { hi: 5.5, name: "Moderate",    band: 2, advice: "Sensitive people may feel symptoms." },
            { hi: 6.5, name: "Poor",        band: 3, advice: "Sensitive people should limit strenuous outdoor activity." },
            { hi: 7.5, name: "Very poor",   band: 3, advice: "Sensitive people should avoid strenuous outdoor activity." },
            { hi: 8.5, name: "Bad",         band: 4, advice: "Everyone should limit strenuous outdoor activity." },
            { hi: 9.5, name: "Very bad",    band: 4, advice: "Everyone should avoid strenuous outdoor activity." },
            { hi: Infinity, name: "Horrible", band: 5, advice: "Stay indoors where possible." }
        ]
    },
    pm25: { title: "PM2.5", unit: "µg/m³", source: "EEA European Air Quality Index bands (hourly)",
        text: "Fine particles under 2.5 µm: combustion, traffic and wood smoke. They reach deep into the lungs; the WHO 2021 guideline is a 24-hour mean of 15 µg/m³.",
        bands: [ { hi: 10, name: "Good", band: 0 }, { hi: 20, name: "Fair", band: 1 }, { hi: 25, name: "Moderate", band: 2 },
                 { hi: 50, name: "Poor", band: 3 }, { hi: 75, name: "Very poor", band: 4 }, { hi: Infinity, name: "Extremely poor", band: 5 } ] },
    pm10: { title: "PM10", unit: "µg/m³", source: "EEA European Air Quality Index bands (hourly)",
        text: "Particles under 10 µm: road dust, pollen, sea salt and combustion. The WHO 2021 guideline is a 24-hour mean of 45 µg/m³.",
        bands: [ { hi: 20, name: "Good", band: 0 }, { hi: 40, name: "Fair", band: 1 }, { hi: 50, name: "Moderate", band: 2 },
                 { hi: 100, name: "Poor", band: 3 }, { hi: 150, name: "Very poor", band: 4 }, { hi: Infinity, name: "Extremely poor", band: 5 } ] },
    no2: { title: "Nitrogen dioxide", unit: "µg/m³", source: "EEA European Air Quality Index bands (hourly)",
        text: "Mostly from traffic and heating; irritates the airways. The WHO 2021 guideline is a 24-hour mean of 25 µg/m³.",
        bands: [ { hi: 40, name: "Good", band: 0 }, { hi: 90, name: "Fair", band: 1 }, { hi: 120, name: "Moderate", band: 2 },
                 { hi: 230, name: "Poor", band: 3 }, { hi: 340, name: "Very poor", band: 4 }, { hi: Infinity, name: "Extremely poor", band: 5 } ] },
    o3: { title: "Ozone", unit: "µg/m³", source: "EEA European Air Quality Index bands (hourly)",
        text: "Formed from traffic and industrial gases in sunlight, so it peaks on hot, still summer afternoons. The WHO 2021 guideline is an 8-hour mean of 100 µg/m³.",
        bands: [ { hi: 50, name: "Good", band: 0 }, { hi: 100, name: "Fair", band: 1 }, { hi: 130, name: "Moderate", band: 2 },
                 { hi: 240, name: "Poor", band: 3 }, { hi: 380, name: "Very poor", band: 4 }, { hi: Infinity, name: "Extremely poor", band: 5 } ] },
    so2: { title: "Sulphur dioxide", unit: "µg/m³", source: "EEA European Air Quality Index bands (hourly)",
        text: "From burning sulphur-rich fuels: industry and shipping. Low in Belgium since the 1990s. The WHO 2021 guideline is a 24-hour mean of 40 µg/m³.",
        bands: [ { hi: 100, name: "Good", band: 0 }, { hi: 200, name: "Fair", band: 1 }, { hi: 350, name: "Moderate", band: 2 },
                 { hi: 500, name: "Poor", band: 3 }, { hi: 750, name: "Very poor", band: 4 }, { hi: Infinity, name: "Extremely poor", band: 5 } ] },
    co: { title: "Carbon monoxide", unit: "µg/m³", source: "WHO 2021 air quality guideline (24-hour mean 4 mg/m³); the bands are this module's own steps around it, not an index",
        text: "From incomplete combustion: traffic, heating, wood fires. Not part of the European index; the WHO 24-hour guideline is 4 mg/m³ (4000 µg/m³).",
        bands: [ { hi: 2000, name: "Low", band: 0 }, { hi: 4000, name: "Within guideline", band: 1 }, { hi: 10000, name: "Above guideline", band: 2 },
                 { hi: 30000, name: "High", band: 3 }, { hi: 60000, name: "Very high", band: 4 }, { hi: Infinity, name: "Extreme", band: 5 } ] },
    beaufort: {
        title: "Wind force",
        unit: "km/h",
        source: "Beaufort scale as published by the KMI/IRM (10 m wind, km/h bands)",
        text: "The Beaufort scale reads wind by its effect: leaves rustle at 2, small branches move at 4, whole trees at 7, and twigs break off from 8. Gusts are the peak over the hour and are read on the same scale.",
        bands: [
            { hi: 1,   name: "Calm",            kmi: "windstil",          band: 0, advice: "Smoke rises vertically." },
            { hi: 6,   name: "Light air",       kmi: "zwakke wind",       band: 0, advice: "Smoke drifts; wind vanes still." },
            { hi: 12,  name: "Light breeze",    kmi: "zwakke wind",       band: 0, advice: "Wind felt on the face; leaves rustle." },
            { hi: 20,  name: "Gentle breeze",   kmi: "matige wind",       band: 1, advice: "Leaves and small twigs in constant motion." },
            { hi: 29,  name: "Moderate breeze", kmi: "matige wind",       band: 1, advice: "Raises dust and loose paper; small branches move." },
            { hi: 39,  name: "Fresh breeze",    kmi: "vrij krachtige wind", band: 2, advice: "Small trees in leaf begin to sway." },
            { hi: 50,  name: "Strong breeze",   kmi: "krachtige wind",    band: 3, advice: "Large branches in motion; umbrellas used with difficulty." },
            { hi: 62,  name: "Near gale",       kmi: "harde wind",        band: 3, advice: "Whole trees in motion; walking against the wind is an effort." },
            { hi: 75,  name: "Gale",            kmi: "stormachtige wind", band: 4, advice: "Twigs break off trees; progress on foot is impeded." },
            { hi: 89,  name: "Strong gale",     kmi: "storm",             band: 4, advice: "Slight structural damage: chimney pots and roof tiles." },
            { hi: 103, name: "Storm",           kmi: "zware storm",       band: 5, advice: "Trees uprooted; considerable structural damage." },
            { hi: 118, name: "Violent storm",   kmi: "zeer zware storm",  band: 5, advice: "Widespread damage." },
            { hi: Infinity, name: "Hurricane force", kmi: "orkaan",       band: 5, advice: "Devastation." }
        ]
    },
    pollen: {
        title: "Pollen",
        unit: "grains/m³",
        source: "Per-species thresholds as applied by Breezy Weather to CAMS forecasts; Belgian AirAllergy (Sciensano) publishes levels without a public threshold table",
        text: "Concentration of airborne pollen, forecast per species by CAMS. Sensitivity varies by person and species; the levels are a guide to how many allergic people react, not a health limit.",
        // Per species: the exclusive upper bound of none / low / moderate / high; anything above is very high.
        species: {
            alder:   { name: "Alder",   hi: [1, 5, 25, 50, 100] },
            birch:   { name: "Birch",   hi: [1, 10, 50, 100, 300] },
            grass:   { name: "Grass",   hi: [1, 5, 25, 50, 100] },
            mugwort: { name: "Mugwort", hi: [1, 5, 25, 50, 100] },
            olive:   { name: "Olive",   hi: [1, 5, 25, 50, 100] },
            ragweed: { name: "Ragweed", hi: [1, 5, 11, 23, 50] }
        },
        levelNames: ["None", "Low", "Moderate", "High", "Very high"],
        levelBands: [0, 1, 2, 3, 4]
    },
    visibility: {
        title: "Visibility",
        unit: "m",
        source: "WMO definitions of fog and mist; the upper labels are the KMI observation scale",
        text: "The greatest distance at which a dark object can be seen against the horizon. Under 1 km is fog by definition, 1 to 5 km is mist or haze.",
        bands: [
            { hi: 1000,  name: "Fog",       band: 4, advice: "Below 1 km: drive slowly with dipped headlights and fog lamps." },
            { hi: 5000,  name: "Mist",      band: 3, advice: "1 to 5 km: distant objects are hidden." },
            { hi: 10000, name: "Moderate",  band: 2, advice: "5 to 10 km: hazy horizon." },
            { hi: 20000, name: "Good",      band: 1, advice: "10 to 20 km." },
            { hi: 40000, name: "Very good", band: 0, advice: "20 to 40 km: clear air." },
            { hi: Infinity, name: "Excellent", band: 0, advice: "Over 40 km: exceptionally clear, often behind a cold front." }
        ]
    },
    dewPoint: {
        title: "Dew point",
        unit: "°C",
        source: "US National Weather Service comfort convention (the customary scale; there is no Belgian one)",
        text: "The temperature the air would have to cool to for its moisture to condense. It says how much water is in the air regardless of temperature, which is why it reads comfort better than relative humidity.",
        bands: [
            { hi: 10, name: "Dry",         band: 0, advice: "Comfortable, can feel dry." },
            { hi: 13, name: "Comfortable", band: 0, advice: "Pleasant." },
            { hi: 16, name: "Pleasant",    band: 1, advice: "Noticeable moisture, still comfortable for most." },
            { hi: 18, name: "Sticky",      band: 2, advice: "Getting humid." },
            { hi: 21, name: "Muggy",       band: 3, advice: "Uncomfortable for most." },
            { hi: 24, name: "Oppressive",  band: 4, advice: "Very uncomfortable; exertion is hard." },
            { hi: Infinity, name: "Miserable", band: 5, advice: "Extremely humid; rare in Belgium." }
        ]
    },
    humidity: {
        title: "Humidity",
        unit: "%",
        source: "Relative humidity; the 30 to 60 % comfort range is the usual indoor recommendation",
        text: "How much water vapour the air holds compared with the most it could hold at this temperature. Warm air holds more, so the same moisture reads as a lower percentage on a warm afternoon than on the cool night before.",
        bands: [
            { hi: 30, name: "Dry",         band: 2, advice: "Dry skin and airways." },
            { hi: 60, name: "Comfortable", band: 0, advice: "" },
            { hi: 75, name: "Humid",       band: 1, advice: "" },
            { hi: 90, name: "Very humid",  band: 2, advice: "Sweat evaporates slowly." },
            { hi: Infinity, name: "Saturated", band: 3, advice: "Mist, fog or rain likely." }
        ]
    },
    pressure: {
        title: "Pressure",
        unit: "hPa",
        source: "Air pressure reduced to sea level; 1013.25 hPa is the standard atmosphere",
        text: "Pressure at sea level. Belgian readings mostly sit between 985 and 1035 hPa. The trend over three hours says more than the value: falling pressure brings fronts and wind, rising pressure clears the sky.",
        bands: [
            { hi: 980,  name: "Very low",      band: 4, advice: "Deep depression: storm or heavy rain likely." },
            { hi: 1000, name: "Low",           band: 3, advice: "Unsettled, wet weather." },
            { hi: 1010, name: "Slightly low",  band: 2, advice: "Changeable." },
            { hi: 1020, name: "Normal",        band: 1, advice: "" },
            { hi: 1030, name: "High",          band: 0, advice: "Settled weather; fog possible in autumn and winter." },
            { hi: Infinity, name: "Very high", band: 0, advice: "Strong anticyclone: dry, calm, cold nights in winter." }
        ]
    },
    cloudCover: {
        title: "Cloud cover",
        unit: "%",
        source: "WMO oktas (eighths of the sky)",
        text: "The share of the sky covered by cloud, reported in oktas: 0 is a clear sky and 8 is overcast.",
        bands: [
            { hi: 6.25,  name: "Clear",     band: 0, advice: "0 oktas." },
            { hi: 31.25, name: "Few",       band: 0, advice: "1 to 2 oktas." },
            { hi: 56.25, name: "Scattered", band: 1, advice: "3 to 4 oktas." },
            { hi: 93.75, name: "Broken",    band: 2, advice: "5 to 7 oktas." },
            { hi: Infinity, name: "Overcast", band: 3, advice: "8 oktas." }
        ]
    },
    precipitation: {
        title: "Precipitation",
        unit: "mm/h",
        source: "WMO rainfall intensity classes",
        text: "Rain, drizzle, snow and hail as millimetres of water per hour. Snow is reported as its water equivalent; a centimetre of fresh snow is roughly a millimetre of water.",
        bands: [
            { hi: 0.1,  name: "Dry",      band: 0, advice: "" },
            { hi: 2.5,  name: "Light",    band: 1, advice: "Drizzle to light rain." },
            { hi: 10,   name: "Moderate", band: 2, advice: "Steady rain." },
            { hi: 50,   name: "Heavy",    band: 3, advice: "Puddles form quickly; poor visibility." },
            { hi: Infinity, name: "Violent", band: 4, advice: "Cloudburst; flash flooding possible." }
        ]
    },
    sunshine: {
        title: "Sunshine",
        unit: "s",
        source: "Hours of direct sun as a share of the day's length (WMO: direct irradiance above 120 W/m²)",
        text: "How long the sun shines unobstructed, out of the hours it is above the horizon.",
        bands: [
            { hi: 0.1, name: "None",   band: 2, advice: "" },
            { hi: 0.35, name: "Little", band: 1, advice: "" },
            { hi: 0.7, name: "Some",   band: 0, advice: "" },
            { hi: Infinity, name: "Sunny", band: 0, advice: "" }
        ]
    }
};

// Pollutant ids in the order the air-quality selector shows them.
var POLLUTANTS = ["pm25", "pm10", "o3", "no2", "so2", "co"];

function bands(id) {
    const s = SCALES[id];
    return s ? s.bands : [];
}

function about(id) {
    const s = SCALES[id];
    return s ? { title: s.title, unit: s.unit, source: s.source, text: s.text } : null;
}

// The band a value falls in: { i, name, band, advice, lo, hi }, or null when
// the value is not a number (a missing figure has no band).
function bandOf(id, v) {
    const s = SCALES[id];
    if (!s || !(typeof v === "number") || !isFinite(v))
        return null;
    let lo = -Infinity;
    for (let i = 0; i < s.bands.length; i++) {
        const b = s.bands[i];
        if (v < b.hi)
            return { i: i, name: b.name, band: b.band, advice: b.advice || "", lo: lo, hi: b.hi, kmi: b.kmi || "" };
        lo = b.hi;
    }
    const last = s.bands[s.bands.length - 1];
    return { i: s.bands.length - 1, name: last.name, band: last.band, advice: last.advice || "", lo: lo, hi: Infinity, kmi: last.kmi || "" };
}

// Beaufort from a 10 m wind speed in km/h: { bft, name, kmi, band }.
function beaufort(kmh) {
    const b = bandOf("beaufort", kmh);
    if (!b)
        return null;
    return { bft: b.i, name: b.name, kmi: b.kmi, band: b.band };
}

// A pollen concentration (grains/m3) for one species: { level 0..4, name, band }.
function pollenLevel(species, conc) {
    const sp = SCALES.pollen.species[species];
    if (!sp || !(typeof conc === "number") || !isFinite(conc))
        return null;
    let level = sp.hi.length;
    for (let i = 0; i < sp.hi.length; i++) {
        if (conc < sp.hi[i]) { level = i; break; }
    }
    level = Math.min(level, SCALES.pollen.levelNames.length - 1);
    return { level: level, name: SCALES.pollen.levelNames[level], band: SCALES.pollen.levelBands[level], species: sp.name };
}

// Open-Meteo's moon_phase is the cycle fraction: 0 new, 0.25 first quarter,
// 0.5 full, 0.75 last quarter. Illumination is the lit fraction of the disc.
function moonPhase(f) {
    if (!(typeof f === "number") || !isFinite(f))
        return null;
    f = ((f % 1) + 1) % 1;
    let name;
    if (f < 0.03 || f > 0.97) name = "New moon";
    else if (f < 0.22) name = "Waxing crescent";
    else if (f < 0.28) name = "First quarter";
    else if (f < 0.47) name = "Waxing gibbous";
    else if (f < 0.53) name = "Full moon";
    else if (f < 0.72) name = "Waning gibbous";
    else if (f < 0.78) name = "Last quarter";
    else name = "Waning crescent";
    return { name: name, illumination: 0.5 * (1 - Math.cos(2 * Math.PI * f)), waxing: f < 0.5 };
}

// Pressure tendency over three hours (WMO): rising above +1 hPa, falling
// below -1, steady between. Returns -1, 0, 1.
function pressureTrend(deltaHpa3h) {
    if (!(typeof deltaHpa3h === "number") || !isFinite(deltaHpa3h))
        return 0;
    return deltaHpa3h > 1 ? 1 : (deltaHpa3h < -1 ? -1 : 0);
}

// Okta count from a cloud cover percentage.
function oktas(pct) {
    if (!(typeof pct === "number") || !isFinite(pct))
        return -1;
    return Math.max(0, Math.min(8, Math.round(pct / 12.5)));
}
