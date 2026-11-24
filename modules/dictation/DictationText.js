.pragma library

// =============================================================================
// DictationText.js -- the pure half of DictationService: the config's defaults, how a piece of text joins the text before the
// caret, what a field's content type allows, and the escaping of the input method's line protocol (tools/stt/ime/lares-ime.c).
//
//   config(raw)                          shell.jsonc's `dictation` block over the defaults (never null; `text` is an object or null)
//   joinPrefix(before, known, segs)      " " when the text must be spaced from what is before the caret, else ""
//   fieldRule(purpose, hint)             "refuse" (password, pin, or a hidden / sensitive field) | "terminal" (no newline) | "text"
//   shape(text, rule)                    the text as that field may take it
//   esc(text) / unesc(text)              the line protocol's escapes: \\ \n \t
//   firstWords(text, n)                  the toast's preview
//   sourceText(text)                     the text rules a WINDOW take writes with (round 5): the user's own, less the note header
// =============================================================================

var DEFAULTS = {
    enabled: false,
    model: "auto",          // the bench's pick per device (tools/stt/lares_stt.py PICK), or `<id>` / `<live id>+<final id>` (sttlib/decoders.py)
    device: "auto",         // auto: the NVIDIA card when it is on the bus (Hybrid / Smart), else the Arc iGPU | cuda | gpu (the iGPU) | cpu
    tidy: false,            // the tidy pass: a sentence's false starts, repeats and stutters removed (a small model, a guard; sttlib/tidy.py)
    endSilenceMs: 700,      // the pause that ends a sentence (it is then written for good)
    thinkSilenceMs: 3000,   // ... unless the last word before it was a filler ("uh", "um"): thinking, the sentence waits this long
    hopMs: 700,             // how often the sentence being spoken is decoded again
    keepWarmMin: 10,        // the helper's models (~1-2 GB) stay loaded this long after the last take; then it runs light again
    dgpuKeepMin: 2,         // ... this long when the take ran on the NVIDIA card (the helper holds the card awake while it lives)
    preload: false,         // the helper's models stay loaded after the first take (never let go after keepWarmMin; a take on the NVIDIA card still is)
    typeInto: [],           // window classes with no text input (Xwayland apps) that get the final text typed
    micVolume: -1,          // the volume a muted mic at 0 % is raised to; exactly -1: the last non-zero volume seen, else 0.6
    logTakes: true,         // ~/.local/state/lares/dictation/takes.jsonl: the events and the text, never audio, the last `logKeep`
    key: "toggle",          // the plain and the Shift key: a press starts, the next ends it | "hold": the take lasts while the key is down
    endAfterMin: 0,         // a take in which nothing was said for this many minutes ends by itself; 0: never
    unmute: true,           // a muted mic is unmuted for the take; false: a take on one does not start
    aura: true,             // the aura comes with a take
    copy: "fallback",       // the text on the clipboard: what no field took | "always" all of it
    language: "auto",       // the plain key's: "auto" (detected) | "en" | "nl"
    altLanguage: "nl",      // the Shift key's: "en" | "nl"
    logKeep: 100,           // how many takes the log keeps
    askEndMs: 2500,         // a voice ask (Alt+fn+F10) ends by itself this long after its last sentence was written; 0: only the key ends it
    text: null              // the rules for the final text (sttlib/policy.py, docs/dictation.md): handed to the helper verbatim
};

var WORDS = { key: ["toggle", "hold"], copy: ["fallback", "always"], language: ["auto", "en", "nl"], altLanguage: ["en", "nl"] };

function config(raw) {
    var out = {};
    for (var k in DEFAULTS)
        out[k] = DEFAULTS[k];
    if (raw && typeof raw === "object" && !Array.isArray(raw)) {
        for (var key in raw) {
            if (!(key in DEFAULTS))
                continue;
            var v = raw[key], d = DEFAULTS[key];
            if (typeof d === "boolean" && typeof v === "boolean")
                out[key] = v;
            else if (typeof d === "number" && typeof v === "number" && isFinite(v))
                out[key] = v;
            else if (typeof d === "string" && typeof v === "string" && (!(key in WORDS) || WORDS[key].indexOf(v) >= 0))
                out[key] = v;
            else if (Array.isArray(d) && v && typeof v.length === "number")
                out[key] = Array.prototype.slice.call(v).map(String);
            else if (key === "text" && v && typeof v === "object" && typeof v.length !== "number")
                out[key] = JSON.parse(JSON.stringify(v));      // an object, verbatim (a copy: the config's own stays the config's)
        }
    }
    return out;
}

// zwp_text_input_v3 content purposes and hints (text-input-unstable-v3.xml): purpose 8 password, 10 pin, 13 terminal; hint 0x40
// hidden_text, 0x80 sensitive_data. A Qt field with ImhHiddenText / ImhSensitiveData reports the hints, not the purpose; a Qt
// password field (echoMode Password) enables no text input at all, so it never activates the input method (the take then has no
// field: the clipboard).
var PURPOSE_PASSWORD = 8, PURPOSE_PIN = 10, PURPOSE_TERMINAL = 13;
var HINT_HIDDEN = 0x40, HINT_SENSITIVE = 0x80;

function fieldRule(purpose, hint) {
    if (purpose === PURPOSE_PASSWORD || purpose === PURPOSE_PIN || ((hint | 0) & (HINT_HIDDEN | HINT_SENSITIVE)) !== 0)
        return "refuse";
    if (purpose === PURPOSE_TERMINAL)
        return "terminal";
    return "text";
}

function shape(text, rule) {
    var t = String(text || "");
    if (rule === "terminal")
        return t.replace(/\s*\n\s*/g, " ");
    return t;
}

// `before`: the text before the caret as the field reported it; `known`: whether it reported any; `segs`: what this take already
// wrote into this field. A field that tells us nothing gets a space before every piece but the first.
function joinPrefix(before, known, segs) {
    if (known)
        return before.length > 0 && !/\s$/.test(before) ? " " : "";
    return segs > 0 ? " " : "";
}

function esc(text) {
    return String(text || "").replace(/\\/g, "\\\\").replace(/\n/g, "\\n").replace(/\t/g, "\\t");
}

function unesc(text) {
    return String(text || "").replace(/\\(.)/g, function (m, c) {
        return c === "n" ? "\n" : c === "t" ? "\t" : c;
    });
}

// A window take (fn+Ctrl+F10) transcribes someone else's speech: the user's own text rules hold (F-keys, signs, spellings, repeats,
// the unfinished sentence), but a take that begins "greater than" is not one of the user's note headers.
function sourceText(text) {
    var t = text && typeof text === "object" ? JSON.parse(JSON.stringify(text)) : {};
    var sym = t.symbols && typeof t.symbols === "object" ? t.symbols : {};
    sym.leadingQuote = false;
    t.symbols = sym;
    return t;
}

function firstWords(text, n) {
    var w = String(text || "").split(/\s+/).filter(function (x) { return x.length > 0; });
    return w.slice(0, n).join(" ") + (w.length > n ? " …" : "");
}
