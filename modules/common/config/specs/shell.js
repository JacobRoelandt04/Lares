.pragma library

// The spec of config/shell.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/shell.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var IDS = ["power", "idle", "theme", "notes", "llm", "windowtray", "weather", "clock", "stocks", "player", "volume", "aerial", "bridge", "panorama", "silicon", "update",
    "notifications", "network"];
var ZONE = d => ["list", d, ["word", undefined, IDS]];
var OUTLET = { bar: ["word", "left", ["left", "right", "bottom", "top"]], along: ["num", 0, 0, 1] };
var RATIO = ["num", undefined, 0.5, 2];
var POPUP_IDS = ["silicon", "weather", "clock", "stocks", "player", "audio", "aerial", "network", "bridge", "panorama", "update", "notifications", "notes", "llm",
    "clipboard", "launcher", "picker", "theme", "windowtray"];
var POPUPS = POPUP_IDS.concat(POPUP_IDS.map(id => id + ".detail"));
var COLOUR = ["text", null, { re: "^(#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?|[A-Za-z][A-Za-z0-9]*)$", like: "accent or #4480F4" }];
var PATHS = ["either", undefined, ["path", undefined], ["list", undefined, ["path", undefined]]];
var MODULES = {};
for (const id of ["power", "idle", "theme", "notes", "llm", "weather", "stocks", "player", "volume", "aerial", "bridge", "panorama", "silicon", "update", "clipboard",
    "picker", "wiki", "screentime"])
    MODULES[id] = ["bool", true, { start: true }];
// the words a bar button's click takes, beside "none", "popup" and a command
var CLICK = words => {
    const one = () => ["either", undefined, ["word", undefined, ["none", "popup"].concat(words)], ["argv", undefined]];
    return ["obj", undefined, { right: one(), middle: one() }];
};
var CLICKS = {
    theme: CLICK(["mode", "next"]), notes: CLICK(["new"]), llm: CLICK(["new"]), windowtray: CLICK([]), weather: CLICK(["refresh", "nextPlace"]),
    clock: CLICK(["timer", "timers", "wiki"]), stocks: CLICK(["refresh"]), player: CLICK(["toggle", "next", "prev", "stop"]), volume: CLICK(["mute"]),
    aerial: CLICK(["vpn", "airplane"]), bridge: CLICK(["mirror", "shot", "clip"]), panorama: CLICK(["displays", "presets"]), silicon: CLICK(["nextProfile"]),
    update: CLICK(["check"]), notifications: CLICK(["dnd", "clear"])
};
var SPEC = {
    topMode: ["word", "islands", ["islands", "continuous"]],
    font: ["text", "Audiowide"],
    centre: ["word", "centred", ["centred", "equal"]],
    zones: {
        left: ZONE(["power", "idle", "theme", "notes", "llm", "windowtray"]),
        centre: ZONE(["weather", "clock", "stocks"]),
        right: ZONE(["player", "volume", "aerial", "bridge", "panorama", "silicon", "update", "notifications"])
    },
    islands: ["map", {}, { left: ["num", undefined, 1, null], centre: ["num", undefined, 1, null], right: ["num", undefined, 1, null] }],
    outlets: { notes: OUTLET, llm: OUTLET },
    scale: {
        global: ["num", 1.0, 0.5, 4],
        bar: ["num", 1.0, 0.5, 2],
        popup: ["num", 1.0, 0.5, 2],
        popups: ["map", { silicon: 1.35, aerial: 1.35, llm: 1.1 }, RATIO, { keys: POPUPS }],
        pills: ["map", {}, RATIO, { keys: ["osd", "toast", "popup"] }],
        outputs: ["map", {}, {
            global: ["num", undefined, 0.5, 4], bar: RATIO, popup: RATIO,
            popups: ["map", undefined, RATIO, { keys: POPUPS }],
            pills: ["map", undefined, RATIO, { keys: ["osd", "toast", "popup"] }]
        }]
    },
    shadow: ["either", { mode: "off", color: null, aura: false, auraEvents: { llm: 60, update: true, timer: true, screencast: true } },
        ["obj", undefined, { mode: ["word", "off", ["off", "halo"]], color: COLOUR, aura: ["bool", false], auraEvents: {
            llm: ["either", 60, ["bool", undefined], ["num", undefined, 1, 3600]], update: ["bool", true], timer: ["bool", true], screencast: ["bool", true] } }],
        ["word", undefined, ["off", "halo"]],
        ["bool", undefined]],
    border: ["either", false,
        ["bool", undefined],
        ["num", undefined, 0, 12],
        ["word", undefined, ["on"]],
        ["obj", undefined, { width: ["num", 3, 0, 12], color: COLOUR }]],
    theme: {
        apply: ["word", "shell", ["shell", "themectl"]],
        targets: ["map", {}, ["bool", undefined], { keys: ["vscode", "wallpaper", "yazi", "hyprland", "kitty", "btop", "starship", "libadwaita", "gtk", "nwg-look",
            "gnome-accent", "evince", "gtk3-ini", "gtk4-ini", "fastfetch", "hyprlock", "windows-vm"] }],
        pairs: ["list", [], ["text", undefined]],
        curtain: ["bool", false],
        curtainRepaint: ["bool", true],
        curtainRepaintFrames: ["int", 3, 1, 60],
        curtainRepaintClassFrames: ["map", {}, ["int", undefined, 1, 60], { sample: true }],
        curtainRepaintDebug: ["bool", false],
        curtainRepaintDebugMs: ["int", 900, 200, 5000],
        curtainStyle: ["word", "radial", ["radial", "peel", "louvres", "cycle"]],
        curtainLive: ["bool", false],
        wallpapers: ["map", {}, { light: PATHS, dark: PATHS }],
        wallpaperFit: ["word", "cover", ["cover", "contain", "tile", "fill"]]
    },
    icons: { overrides: ["map", {}, ["path", undefined]], fallback: ["text", "application-x-executable"] },
    clicks: CLICKS,
    clickAway: ["list", [], ["word", undefined, ["theme", "notes", "llm", "weather", "clock", "stocks", "player", "audio", "aerial", "bridge", "panorama", "silicon",
        "update", "notifications"]]],
    bars: { outputs: ["either", "all", ["word", undefined, ["all", "internal"]], ["list", undefined, ["text", undefined]]] },
    flourishes: { hover: ["bool", true], key: ["bool", true] },
    terminal: ["argv", ["kitty", "-e"]],
    recorders: ["list", ["wf-recorder", "wl-screenrec", "wayvnc"], ["text", undefined]],
    geoclueAgent: ["bool", false, { start: true }],
    dictation: {
        enabled: ["bool", false],
        model: ["text", "auto"],
        device: ["word", "auto", ["auto", "cuda", "gpu", "cpu"]],
        tidy: ["bool", false],
        endSilenceMs: ["num", 700, 100, 10000],
        hopMs: ["num", 700, 100, 10000],
        thinkSilenceMs: ["num", 3000, 100, 60000],
        keepWarmMin: ["num", 10, 1, null],
        preload: ["bool", false],
        dgpuKeepMin: ["num", 2, 0.25, null],
        typeInto: ["list", [], ["text", undefined]],
        micVolume: ["num", -1, -1, 1.5],
        logTakes: ["bool", true],
        askEndMs: ["num", 2500, 0, null],
        key: ["word", "toggle", ["toggle", "hold"]],
        endAfterMin: ["num", 0, 0, 60],
        unmute: ["bool", true],
        aura: ["bool", true],
        copy: ["word", "fallback", ["fallback", "always"]],
        language: ["word", "auto", ["auto", "en", "nl"]],
        altLanguage: ["word", "nl", ["en", "nl"]],
        logKeep: ["int", 100, 1, 10000],
        text: {
            symbols: { fkeys: ["bool", true], signs: ["bool", true], leadingQuote: ["bool", true], codes: ["bool", true] },
            words: ["map", { "Hyperland": "Hyprland" }, ["text", undefined]],
            fillers: ["list", [], ["text", undefined]],
            repeats: ["bool", true],
            unfinished: ["bool", true]
        }
    },
    oled: {
        enabled: ["bool", true],
        shift: ["bool", true],
        shiftEveryS: ["num", 240, 30, 86400],
        flourishes: {
            idle: ["bool", true],
            active: ["bool", true],
            idleEveryS: ["either", [120, 240], ["list", undefined, ["num", undefined, 10, 86400], { min: 2, max: 2 }], ["num", undefined, 10, 86400]],
            activeEveryS: ["either", [600, 1200], ["list", undefined, ["num", undefined, 10, 86400], { min: 2, max: 2 }], ["num", undefined, 10, 86400]],
            glyphs: ["map", {}, ["bool", undefined]]
        }
    },
    escape: ["word", "all", ["all", "detail"]],
    hoverCursor: ["bool", false],
    modules: MODULES,
    input: {
        sideButtons: ["word", "both", ["both", "back", "forward", "off"]],
        sideClick: ["bool", true],
        sideGain: ["num", 1, 0.2, 5],
        sidePointer: ["word", "hold", ["hold", "free"]],
        notchPx: ["num", 120, 20, 600],
        notchMs: ["num", 140, 0, 600]
    },
    workarounds: { fileRoot: ["bool", true, { start: true }], gcAtScreenBuild: ["bool", true, { start: true }], visibleInk: ["bool", false], mpdResumeSeek: ["bool", true] },
    debug: { frameJournal: ["bool", true] }
};
