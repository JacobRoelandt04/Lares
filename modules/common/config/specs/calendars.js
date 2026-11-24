.pragma library

// The spec of config/calendars.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/calendars.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    pollIntervalMs: ["int", 900000, 60000, null],
    weekStart: ["int", 1, 0, 6],
    calendars: ["list", [], {
        id: ["text", undefined],
        name: ["text", undefined],
        color: ["text", undefined, { re: "^#[0-9A-Fa-f]{6}$", like: "#89b4fa" }],
        url: ["text", undefined, { req: true, secret: true }],            // a shared link's access token is in it
        pollIntervalMs: ["int", undefined, 60000, null],
        remind: ["either", undefined, ["bool", undefined], ["num", undefined, 1, 1440]]
    }, { sample: true }]
};
