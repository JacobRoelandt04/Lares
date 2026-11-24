.pragma library

// =============================================================================
// IdleAutoRules.js -- the idle auto layer's rules (IdleAuto), with no Qt in them.
//
// THINGS THAT NEED THE MACHINE AWAKE ASK FOR AN IDLE MODE, and the mode in force is the higher of the user's and theirs
// (off < soft < normal < hard). Content being watched asks for normal (no dim, no suspend: the point is to see it), and so does a
// screen that is being shared (others see it: no dimming under them); work the user waits on asks for soft (it may dim, it must
// never suspend: a timer would ring late, an answer, an update, a wiki batch, a download or someone else's package job would stall).
// A SHARE OUTRANKS EVERY SOFT CAUSE by its mode alone (normal > soft); between two causes of one mode the table's order names it.
// HOLDERS is that table, in the order that names the cause when two ask for the same mode. Each mode is a default: idle.jsonc `auto`
// (`modes`, { key: "off" | "soft" | "normal" | "hard" }) asks for another, and "off" is a holder that never counts.
//
// THE FLOOR. What a cause asks for is also the lowest the user's mode may be while it holds (IdleService.floorMode): a plain pick under it
// is refused, at or above it is the user's mode, and the layer never lowers or overwrites what the user picked. `higher` is the whole rule.
//
// AN OVERRIDE (a Ctrl+click or Ctrl+scroll on the idle reel) SETS ASIDE the holders that count at that moment: it stands while
// every holder that counts is one of them, and ends when one it did not set aside counts, or when none counts (`decide`, and
// IdleAuto's `_suppressed`).
// =============================================================================

var RANK = { off: 0, soft: 1, normal: 2, hard: 3 };

function rank(m) {
    return RANK[m] === undefined ? -1 : RANK[m];
}

// The higher of two modes ("" is below every mode).
function higher(a, b) {
    return rank(b) > rank(a) ? b : a;
}

// THE MODES ON OFFER (idle.jsonc `items`): the idle reel shows these and no other mode is ever in force. Always in the ladder's order
// (a list's order is not read: the ladder is what a floor and a refusal are measured on); an unknown id or a second copy is left out;
// "off" is always there (nothing held is always reachable); a list that names nothing is all four.
var LADDER = ["off", "soft", "normal", "hard"];
function offered(ids) {
    var out = [];
    var named = false;
    for (var i = 0; i < LADDER.length; i++) {
        var on = !!ids && ids.indexOf(LADDER[i]) >= 0;
        named = named || on;
        if (on || LADDER[i] === "off")
            out.push(LADDER[i]);
    }
    return named ? out : LADDER.slice();
}
// A mode the user's side asks for (a start, a saved mode) that is not on offer: the nearest offered mode BELOW it (never more held
// than was asked). "off" is always offered.
function down(m, offer) {
    var r = rank(m);
    var best = "off";
    for (var i = 0; i < offer.length; i++)
        if (rank(offer[i]) <= r && rank(offer[i]) > rank(best))
            best = offer[i];
    return r < 0 ? m : best;
}
// What a cause asks for, when it is not on offer: the nearest offered mode ABOVE it (a cause protects work: it never protects less),
// and with none above, the highest offered. "" (no cause) stays "".
function up(m, offer) {
    if (m === "" || rank(m) < 0 || offer.indexOf(m) >= 0)
        return m;
    for (var i = 0; i < offer.length; i++)
        if (rank(offer[i]) > rank(m))
            return offer[i];
    return offer[offer.length - 1];
}

var HOLDERS = [
    { key: "content", mode: "normal" },
    { key: "share", mode: "normal" },
    { key: "update", mode: "soft" },
    { key: "llm", mode: "soft" },
    { key: "timer", mode: "soft" },
    { key: "wiki", mode: "soft" },
    { key: "bridge", mode: "soft" },
    { key: "download", mode: "soft" },
    { key: "pkg", mode: "soft" },
    { key: "music", mode: "soft" }
];

// The mode a holder asks for: idle.jsonc's (`modes`), else the table's.
function modeOf(h, modes) {
    var m = modes && typeof modes === "object" ? modes[h.key] : undefined;
    return RANK[m] === undefined ? h.mode : m;
}

// The keys that count now, from { key: bool }, in HOLDERS' order; a holder the file switches off never counts.
function countedKeys(counted, modes) {
    var out = [];
    for (var i = 0; i < HOLDERS.length; i++)
        if (counted && counted[HOLDERS[i].key] === true && modeOf(HOLDERS[i], modes) !== "off")
            out.push(HOLDERS[i].key);
    return out;
}

// Does an override still stand: some holder counts, and every one that does was set aside by it?
function overrideStands(keys, suppressed) {
    if (!suppressed || suppressed.length === 0 || keys.length === 0)
        return false;
    for (var i = 0; i < keys.length; i++)
        if (suppressed.indexOf(keys[i]) < 0)
            return false;
    return true;
}

// The auto layer's answer: { mode ("" when nothing asks, or an override stands), key (the holder that names the cause), keys }.
function decide(counted, suppressed, modes) {
    var keys = countedKeys(counted, modes);
    if (overrideStands(keys, suppressed))
        return { mode: "", key: "", keys: keys };
    var mode = "", key = "";
    for (var i = 0; i < HOLDERS.length; i++) {
        var h = HOLDERS[i];
        var hm = modeOf(h, modes);
        if (keys.indexOf(h.key) >= 0 && rank(hm) > rank(mode)) {
            mode = hm;
            key = h.key;
        }
    }
    return { mode: mode, key: key, keys: keys };
}

// A file name short enough for a card: the start and the end (the extension) kept.
function shortName(s) {
    s = String(s || "");
    return s.length > 36 ? s.substring(0, 24) + "\u2026" + s.substring(s.length - 10) : s;
}

function _cap(s) {
    s = String(s || "");
    return s.length > 0 ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

// What the OSD card says the cause is. `facts`: { contentWho, timerWhat, downloadWhat, pkgWhat, bridgeWhat }.
function reason(key, facts) {
    var f = facts || {};
    switch (key) {
    case "content":
        return f.contentWho ? _cap(f.contentWho) + " is playing video" : "A video is playing";
    case "update":
        return "System update running";
    case "llm":
        return "The LLM is answering";
    case "timer":
        return _cap(f.timerWhat || "timer") + " running";
    case "music":
        return "Music playing";
    case "share":
        return "Screen is being shared";
    case "wiki":
        return "Wiki batch running";
    case "bridge":
        return "Sending files to " + (f.bridgeWhat ? f.bridgeWhat : "the phone");
    case "download":
        return f.downloadWhat ? "Downloading " + shortName(f.downloadWhat) : "Download running";
    case "pkg":
        // the words PackageJobRules made from the command line ("Building foo (yay)"); the shell's own update is `update`, never this
        return f.pkgWhat ? f.pkgWhat : "Package job running";
    }
    return "";
}
