.pragma library

// The spec of config/audio.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/audio.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var PAGES = ["playback", "recording", "sinks", "sources", "cards"];
var SPEC = {
    pill: { speakerOpens: ["word", "sinks", PAGES], micOpens: ["word", "sources", PAGES] },
    hide: ["list", [], ["text", undefined]]
};
