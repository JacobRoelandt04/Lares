.pragma library

// The spec of config/osd.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/osd.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var KIND = (route, events) => Object.assign({ route: ["word", route, ["osd", "notification", "off"]], ms: ["int", 0, 0, 600000] },
    events ? { events: ["list", undefined, ["word", undefined, events]] } : {});
var SPEC = {
    spot: ["either", { bar: "right", along: 0.5 },
        ["obj", undefined, { bar: ["word", "right", ["right", "left", "bottom", "top"]], along: ["num", 0.5, 0, 1] }],
        ["obj", undefined, { corner: ["text", undefined, { req: true }] }]],
    screen: ["text", "focused"],
    fullscreen: ["word", "pill", ["pill", "keys", "suppress"]],
    dismissMs: ["int", 2000, 200, 600000],
    resumeMinMs: ["int", 800, 0, 600000],
    queueCap: ["int", 3, 1, 20],
    repeat: {
        delayMs: ["either", "auto", ["word", undefined, ["auto"]], ["int", undefined, 50, 5000]],
        rateHz: ["either", "auto", ["word", undefined, ["auto"]], ["int", undefined, 1, 200]]
    },
    volume: { step: ["num", 0.02, 0.001, 0.5], boostMax: ["num", 1.5, 1, 3] },
    mic: { step: ["num", 0.05, 0.001, 0.5] },
    brightness: {
        device: ["text", ""],
        step: ["num", 0.05, 0.001, 0.5],
        fineStep: ["num", 0.01, 0.001, 0.5],
        gamma: ["num", 2.0, 0.5, 4],
        floorRaw: ["int", 1, 0, 1000],
        target: ["word", "pointer", ["pointer", "focused", "panel"]]
    },
    media: { keys: ["word", "mpd", ["mpd", "auto"]] },
    capture: {
        dir: ["path", "~/Pictures/Screenshots"],
        name: ["text", "shot-%Y%m%d-%H%M%S.png", { re: "^[^/]+\\.png$", like: "shot-%Y%m%d-%H%M%S.png" }],
        copy: ["bool", true],
        openCommand: ["argv", ["xdg-open", "{path}"]],
        editCommand: ["list", [], ["text", undefined]],
        click: ["word", "edit", ["edit", "open", "none"]]
    },
    kbd: { device: ["text", "asus::kbd_backlight"] },
    lockkeys: { keys: ["list", ["caps", "num"], ["word", undefined, ["caps", "num"]], { min: 1, max: 2 }] },
    layout: { keyboard: ["text", "main"], codes: ["map", { "English (US)": "US", "Belgian": "BE" }, ["text", undefined]] },
    kinds: {
        volume: KIND("osd", ["key", "external", "device"]), mic: KIND("osd", ["key", "external", "device"]), brightness: KIND("osd"), kbd: KIND("osd"), lockkeys: KIND("osd"), layout: KIND("osd"), theme: KIND("osd"),
        track: KIND("osd", ["key", "change"]), bluetooth: KIND("osd", ["connected", "disconnected"]),
        network: KIND("osd", ["connected", "lost", "failed", "wired"]), vpn: KIND("osd", ["up", "down"]), autoTunnel: KIND("osd"), btLow: KIND("osd"),
        capture: KIND("osd", ["shot", "rec-start", "rec-stop", "copied"]), battery: KIND("osd", ["low", "full"]), power: KIND("osd"), caption: KIND("osd"), generic: KIND("off")
    }
};
