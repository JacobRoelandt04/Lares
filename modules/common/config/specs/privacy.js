.pragma library

// The spec of config/privacy.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/privacy.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.
// Read by tools only (tools/publish/privacy_check.py, lares publish, tools/aerial/make_fixtures.py), never by the shell's QML. Every
// value is a private one: secret, so no message, schema or `lares config` line ever shows it.

var SPEC = {
    replace: ["map", {}, ["text", undefined], { secret: true }],
    forbid: ["list", [], ["text", undefined], { secret: true }],
    publish: {
        name: ["text", "", { secret: true }],
        email: ["text", "", { re: "^$|^[^@\\s]+@[^@\\s]+$", like: "12345678+name@users.noreply.github.com", secret: true }]
    }
};
