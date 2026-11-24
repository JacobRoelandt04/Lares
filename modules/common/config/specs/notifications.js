.pragma library

// The spec of config/notifications.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/notifications.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SOUNDS = d => ["list", d, ["path", undefined]];
// the keys a rule takes, for an app and for a source of the shell's own
var RULE = {
    mute: ["bool", undefined],
    urgency: ["word", undefined, ["low", "normal", "critical"]],
    group: ["word", undefined, ["critical", "system", "normal", "low"]],
    timeoutMs: ["int", undefined, -1, null],
    sound: ["path", undefined],
    drop: ["bool", undefined],
    breakDnd: ["bool", undefined],
    history: ["bool", undefined],
    focusSuppress: ["bool", undefined]
};
var SOURCE = o => Object.assign({ enabled: ["bool", true] }, RULE, o);
var PLAIN = () => ["obj", undefined, Object.assign({ enabled: ["bool", undefined] }, RULE)];
var SPEC = {
    spot: ["either", { corner: "top-right" },
        ["obj", undefined, { corner: ["word", undefined, ["top-right", "top-left", "bottom-right", "bottom-left"], { req: true }] }],
        ["obj", undefined, { bar: ["text", undefined, { req: true }], along: ["num", undefined, 0, 1] }]],
    screen: ["text", "focused"],
    timeouts: {
        low: ["int", 4000, -1, null], normal: ["int", 8000, -1, null], critical: ["int", -1, -1, null],
        clampMin: ["int", 3000, 0, null], clampMax: ["int", 60000, 0, null]
    },
    toasts: {
        max: ["int", 5, 1, null],
        floodCount: ["int", 3, 0, null],
        floodWindowMs: ["int", 10000, 0, null],
        hoverResumeMinMs: ["int", 2000, 0, null],
        swipe: { right: ["word", "file", ["file", "delete"]], left: ["word", "delete", ["file", "delete"]] }
    },
    manager: {
        openGroup: ["word", "latest", ["latest", "first", "none", "critical", "system", "normal", "low"]],
        swipe: { right: ["word", "pin", ["pin", "delete"]], left: ["word", "delete", ["pin", "delete"]] }
    },
    clickFocus: ["bool", true],
    bell: { ring: ["word", "always", ["always", "notDnd", "never"]] },
    retention: { count: ["int", 200, -1, null], days: ["num", 7, -1, null] },
    undoMs: ["int", 10000, 1, null],
    idleMs: ["int", 60000, 1, null],
    sounds: {
        low: SOUNDS([]),
        normal: SOUNDS(["~/.local/share/sounds/notification.mp3", "/usr/share/sounds/notification.mp3"]),
        critical: SOUNDS(["~/.local/share/sounds/notification-critical.mp3", "~/.local/share/sounds/notification.mp3", "/usr/share/sounds/notification.mp3"])
    },
    soundVolume: ["num", -1, -1, 1],
    dnd: {
        remember: ["bool", true],
        hours: ["list", [], ["text", undefined, { re: "^([01]\\d|2[0-3]):[0-5]\\d-([01]\\d|2[0-3]):[0-5]\\d$", like: "22:30-07:00" }]],
        summary: ["bool", true],
        holdApps: ["list", [], ["text", undefined]],
        breakthroughSources: ["list", ["clock", "auth"], ["text", undefined]],
        holdFullscreen: ["bool", true],
        holdScreencast: ["bool", true]
    },
    apps: ["map", {
        "kitty": { focusSuppress: false },
        "org.freedesktop.network-manager-applet": { drop: true },
        "NetworkManager Applet": { drop: true },
        "nm-applet": { drop: true },
        "blueman": { drop: true },
        "blueman-applet": { drop: true }
    }, RULE],
    sources: {
        update: SOURCE({
            nudge: {
                enabled: ["bool", true],
                afterBootMin: ["num", 15, 0, 1440],
                jitterMin: ["num", 4, 0, 240],
                minCount: ["num", 20, 1, 100000],
                minDays: ["num", 7, 1, 3650],
                rule: ["word", "either", ["either", "both", "count", "days"]],
                highlights: ["num", 3, 0, 8],
                timeoutMs: ["int", 30000, -1, 3600000]
            },
            started: ["bool", true],
            asks: ["bool", true],
            finished: ["bool", true],
            rebootPackages: ["list", ["linux", "linux-lts", "linux-zen", "linux-hardened", "linux-rt", "linux-rt-lts", "systemd", "mesa"], ["text", undefined]]
        }),
        battery: SOURCE({
            levels: ["list", [
                { pct: 8, urgency: "critical", hibernate: true, breakDnd: false, timeoutMs: 60000 },
                { pct: 3, urgency: "critical", hibernate: true, breakDnd: true, timeoutMs: -1 }
            ], {
                pct: ["int", undefined, 1, 99, { req: true }],
                urgency: ["word", undefined, ["low", "normal", "critical"]],
                hibernate: ["bool", undefined],
                breakDnd: ["bool", undefined],
                timeoutMs: ["int", undefined, -1, null],
                title: ["text", undefined]
            }],
            hibernate: ["word", "dud", ["dud", "systemctl"]],
            limitReached: ["bool", false],
            fastDrain: {
                enabled: ["bool", true], factor: ["num", 2, 1.2, 20], minW: ["num", 15, 1, 300], minutes: ["num", 5, 1, 120], tauMin: ["num", 30, 1, 600],
                warmupMin: ["num", 10, 0, 240]
            }
        }),
        stocks: SOURCE({ sudden: ["bool", true], scope: ["word", "portfolio", ["portfolio", "holdings", "all"]] }),
        screenshot: SOURCE({ toast: ["word", "auto", ["auto", "always", "never"]] }),
        usb: SOURCE({
            mount: ["bool", true],
            openAfterMount: ["bool", true],
            openCommand: ["argv", ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", "{path}"]],
            unsafeWarn: ["bool", true],
            safeSec: ["num", 10, 0, 3600],
            debounceMs: ["num", 600, 100, 10000]
        }),
        calendar: SOURCE({
            leadMin: ["either", 10, ["num", undefined, 1, 1440], ["list", undefined, ["num", undefined, 1, 1440], { min: 1, max: 6 }]],
            allDayAt: ["text", "", { re: "^(([01]\\d|2[0-3]):[0-5]\\d)?$", like: "09:00" }],
            calendars: ["list", [], ["text", undefined]],
            timeoutMs: ["int", 30000, -1, 3600000]
        }),
        disk: SOURCE({
            mounts: ["list", ["/", "/home"], ["text", undefined, { re: "^/", like: "/home" }]],
            minFreeGB: ["num", 5, 0.1, 100000],
            criticalGB: ["num", 1, 0.05, 100000],
            perMount: ["map", {}, ["num", undefined, 0, null]],
            pollMin: ["num", 5, 0.05, 1440],
            recover: ["num", 0.15, 0, 1]
        }),
        units: SOURCE({
            system: ["bool", true],
            user: ["bool", true],
            pollSec: ["num", 60, 5, 3600],
            ignore: ["list", ["geoclue.service"], ["text", undefined]],
            logLines: ["num", 8, 1, 40],
            copyLines: ["num", 2000, 1, 100000]
        }),
        thermal: SOURCE({
            pollSec: ["num", 15, 1, 300],
            minFraction: ["num", 0.25, 0.01, 1],
            sustainSec: ["num", 60, 5, 3600],
            cooldownMin: ["num", 15, 0, 1440],
            quietMin: ["num", 2, 0.5, 1440],
            root: ["path", "/sys/devices/system/cpu"]
        }),
        // the shell's other sources: the rule keys alone
        clock: PLAIN(), launcher: PLAIN(), llm: PLAIN(), auth: PLAIN(), notifications: PLAIN(), aerial: PLAIN(), panorama: PLAIN(), silicon: PLAIN(), wiki: PLAIN(),
        weather: PLAIN(), bridge: PLAIN(), dictation: PLAIN(), shell: PLAIN(), session: PLAIN(), theme: PLAIN(), osd: PLAIN(), config: PLAIN()
    }
};
