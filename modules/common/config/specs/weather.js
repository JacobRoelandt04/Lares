.pragma library

// The spec of config/weather.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/weather.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    locations: ["list", [{ name: "Brussels", lat: 50.85, lon: 4.35, elevation: 25 }], {
        name: ["text", undefined],
        lat: ["num", undefined, -90, 90],
        lon: ["num", undefined, -180, 180],
        elevation: ["num", undefined, -500, 9000],
        query: ["text", undefined],
        "default": ["bool", undefined],
        home: ["bool", undefined]
    }],
    currentLocation: {
        enabled: ["bool", true],
        maxAccuracyM: ["num", 3000, 1, null],
        nearSavedKm: ["num", 5, 0.001, null]
    },
    units: {
        temperature: ["word", "c", ["c", "f"]],
        wind: ["word", "bft", ["bft", "speed"]],
        speed: ["word", "kmh", ["kmh", "ms", "mph", "kn"]],
        pressure: ["word", "hpa", ["hpa", "mbar", "mmhg", "inhg"]],
        precipitation: ["word", "mm", ["mm", "in"]],
        distance: ["word", "km", ["km", "mi"]],
        airQuality: ["word", "ugm3", ["ugm3"]],
        co: ["word", "mgm3", ["mgm3", "ugm3"]],
        clock: ["word", "24h", ["24h", "12h"]],
        date: ["word", "dd/MM", ["dd/MM", "MM/dd", "d MMM"]]
    },
    view: { start: ["word", "mini", ["mini", "normal", "detailed"]], remember: ["word", "session", ["session", "never"]] },
    look: { secondarySide: ["word", "end", ["start", "end", "far"]] },
    glyphSet: ["word", "ink", ["ink", "carved"]],
    aqiIndex: ["word", "eaqi", ["eaqi", "belaqi"]],
    sources: {
        openMeteo: { model: ["text", "best_match", { re: "^[a-z0-9_]+$", like: "best_match" }] },
        kmi: { enabled: ["bool", true] }
    },
    refreshMinutes: {
        forecast: ["num", 15, 0.1, null],
        airQuality: ["num", 60, 0.1, null],
        kmi: ["num", 15, 0.1, null],
        nowcastWhileOpen: ["num", 5, 0.1, null]
    }
};
