.pragma library

// The spec of config/bridge.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/bridge.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var MIRROR = (size, rate, fps) => ({ maxSize: ["int", size, 0, 16384], bitRate: ["text", rate], maxFps: ["int", fps, 0, 480] });
var SPEC = {
    files: {
        usbMount: ["path", "/mnt/android"],
        open: ["argv", ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", "{path}"]],
        sendDir: ["path", "/sdcard/Download"],
        pickDir: ["path", "~"]
    },
    mirror: {
        usb: MIRROR(0, "", 0),
        wifi: MIRROR(1600, "6M", 60),
        recordDir: ["path", "~/Videos"],
        extraArgs: ["list", [], ["text", undefined]]
    },
    adb: {
        start: ["word", "onDemand", ["onDemand", "onPlug"]],
        idleKillS: ["int", 300, 5, 86400],
        port: ["int", 5555, 1024, 65535]
    },
    shots: { dir: ["path", "~/Pictures/Screenshots"] },
    flip: { onOpen: ["bool", true] },
    cast: {
        closeAfterS: ["int", 120, 5, 86400],
        reloadOnResize: ["bool", true],
        desktopScale: ["num", 1.0, 0.5, 3],
        desktopMinDp: ["int", 320, 240, 1200],
        desktopMinPx: ["int", 640, 320, 2400],
        unlock: ["word", "start+touch", ["start+touch", "start", "touch", "never"]],
        keys: { back: ["text", "Left"], home: ["text", "Down"], recents: ["text", "Right"] },
        sleepAtEnd: ["bool", true],
        holdMin: ["num", 30, 1, 240]
    },
    relight: ["bool", true],
    lookKey: ["word", "alt", ["alt", "ctrl", "shift", "off"]],
    devices: ["map", {}, { skin: ["text", undefined], hidden: ["bool", undefined] }]
};
