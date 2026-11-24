.pragma library

// The spec of config/aerial.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/aerial.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    autoTunnel: ["bool", true],
    autoTunnelTo: ["text", "fastest", { re: "^(fastest|[A-Z]{2})$", like: "fastest or BE" }],
    autoTunnelOn: ["word", "any", ["any", "wifi"]],
    newNetworks: ["word", "public", ["public", "trusted"]],
    searchSeconds: ["int", 30, 5, 600],
    visibleSeconds: ["int", 180, 10, 3600],
    speedTest: { capMB: ["num", 200, 1, 5000] },
    portalCheckUrl: ["text", "http://ping.archlinux.org/nm-check.txt", { re: "^https?://", like: "http://..." }],
    usage: { enabled: ["bool", true] },
    bar: { traffic: ["bool", true], trafficFromMbps: ["num", 10, 1, 999] },
    btLow: ["list", [20, 10], ["int", undefined, 1, 50], { max: 4 }],
    sounds: ["bool", true],
    look: { secondarySide: ["word", "start", ["start", "end", "far"]] }
};
