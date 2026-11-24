// bridge_seam.js -- the seam between the bridge's two halves, held from both sides (tools/dev/bridge_tool_probe.sh runs it
// inside its fake world): the service's own reader (modules/bridge/data/BridgeModel.js) on the REAL tool's lines, and
// the argv the service builds for each action, to be handed to the REAL tool.
//
//   node bridge_seam.js <BridgeModel.js> line            a watch line on stdin -> "ok <n devices>" or what is wrong with it
//   node bridge_seam.js <BridgeModel.js> argv <key>      one JSON line per action: { name, argv } (the probe runs each)
//   node bridge_seam.js <BridgeModel.js> answer <keys>   a one-shot's JSON on stdin: "ok" when it is one object with a
//                                                        boolean `ok` and, when given, every key of the comma list
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma.*$/m, "");
const M = new Function(src + "; return { parseLine, normalise, argvOf };")();
const mode = process.argv[3];
if (mode === "line") {
    const text = fs.readFileSync(0, "utf8").trim().split("\n").pop();
    const r = M.parseLine(text);
    if (!r.ok) {
        console.log("the service's parser refuses the tool's line: " + (r.error || "?"));
        process.exit(1);
    }
    const l = r.line;
    const bad = [];
    for (const d of l.devices) {
        for (const k of ["key", "name", "type", "skin", "present", "link", "prefs", "mounts", "can"])
            if (d[k] === undefined)
                bad.push("device." + k);
        for (const a of ["mirror", "mountUsb", "mountWifi", "send", "shot", "ring", "clip", "key", "pair", "unpair", "arm", "facts", "unlock"])
            if (!d.can || !d.can[a] || typeof d.can[a].ok !== "boolean")
                bad.push("can." + a);
    }
    if (bad.length) {
        console.log("after normalise: " + bad.join(" "));
        process.exit(1);
    }
    console.log("ok " + l.devices.length);
} else if (mode === "argv") {
    const key = process.argv[4];
    const asks = [
        ["mirror", { mode: "mirror", screenOff: true, record: false }], ["mirror-desktop", { mode: "desktop" }], ["mirror-camera", { mode: "camera" }],
        ["mirror-audio", { mode: "audio", record: true }],
        ["mount", { which: "usb" }], ["unmount", { which: "usb" }], ["mount-wifi", { which: "wifi" }], ["unmount-wifi", { which: "wifi" }],
        ["send", { paths: ["/tmp/does-not-matter.bin"] }], ["send-via", { paths: ["/tmp/does-not-matter.bin"], via: "kdeconnect" }],
        ["shot", {}], ["ring", {}], ["clip", {}], ["key", { name: "power" }], ["key-volup", { name: "volup" }], ["key-voldown", { name: "voldown" }],
        ["pair", {}], ["accept", {}], ["reject", {}], ["arm", {}], ["disarm", {}], ["facts", {}], ["wifipair", {}], ["wifipair", { cancel: true }], ["castprep", {}], ["castprep-record", { unlock: false, hold: true, record: true }], ["select", {}], ["refresh", {}],
        ["set", { name: "keepWireless", value: true }], ["set-mode", { name: "mode", value: "desktop" }], ["set-off", { name: "keepWireless", value: false }],
        ["stop", { id: "m-999" }], ["ack", { id: "m-999" }],
        // (`pin set` reads the PIN on stdin: the tool probe and the service probe hold that path; here only what needs none)
        ["unlock", {}], ["unlock-auto", { auto: true }], ["pin-forget", { op: "forget" }]
    ];
    for (const [name, args] of asks) {
        const action = name.split("-")[0];
        const v = M.argvOf(action, key, args);
        console.log(JSON.stringify({ name: name, argv: v }));
    }
} else if (mode === "answer") {
    let j;
    try {
        const lines = fs.readFileSync(0, "utf8").trim().split("\n");
        if (lines.length !== 1)
            throw new Error(lines.length + " lines on stdout");
        j = JSON.parse(lines[0]);
    } catch (e) {
        console.log("not one JSON line: " + e.message);
        process.exit(1);
    }
    const need = (process.argv[4] || "").split(",").filter(Boolean);
    const missing = need.filter(k => j[k] === undefined);
    if (typeof j.ok !== "boolean" || missing.length) {
        console.log("ok is " + typeof j.ok + (missing.length ? "; missing " + missing.join(",") : ""));
        process.exit(1);
    }
    console.log("ok");
} else {
    process.exit(2);
}
