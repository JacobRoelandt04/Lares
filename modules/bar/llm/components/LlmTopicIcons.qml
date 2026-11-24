pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// LlmTopicIcons.qml
//
// Central icon registry for chat exchanges: "a linux icon for a linux
// question, a python logo for a python script". Same shape as
// PackageIcons.qml, and for the same reason -- the rules are data, so a host
// can extend or replace any layer without editing this file.
//
// Resolution order, first match wins:
//   1. patternIcons[]          first regex that hits the question or title,
//                              AMONG THE RULES THIS CATEGORY ALLOWS
//   2. categoryIcons[category] the exchange's category (code / system / ...)
//   3. defaultIcon             everything else
//
// There is no exact-name layer: free text has no exact names. The regexes do
// that job -- each names a topic a person would recognise at a glance, ordered
// specific before generic (arch before linux, python before generic shell) so
// the sharper icon wins.
//
// A GLYPH MAY NARROW A CATEGORY; IT MAY NEVER CONTRADICT ONE. Every rule
// carries `cats`, the categories it is true under, and a rule whose `cats`
// does not hold the exchange's category is SKIPPED. The reason: a turn filed
// `other` (the value the classifier's failure path writes -- not a judgement)
// would otherwise draw the python logo because the word "python" is in the
// question: two marks, one fact, disagreeing. With `cats` the python rule is
// not live under `other` at all, and the exchange draws the category's own
// glyph.
// `cats[0]` is the rule's PRIMARY category, and `categoryFromPatterns()`
// hands it back: when the classifier answers nothing, the words that chose
// the glyph are better evidence than the literal default "other", and they
// are the SAME evidence, so the two marks cannot disagree there either.
// A categoryKey of "" means "not decided" -- every rule is live -- which is
// what a conversation being retitled from its first question passes.
//
// `categoryIcons` ships EMPTY. The six category glyphs live once, on
// LlmService.categories; the service binds them in here at wiring time, so a
// reworded or re-glyphed category cannot drift against a second copy. Used
// standalone, an unmatched question simply falls through to `defaultIcon`.
//
// Glyphs are Nerd Font codepoints written as \u escapes rather than pasted
// private-use characters, so the source stays readable, greppable and
// diffable. Codepoints are from the Font Awesome 4 block plus the devicon
// block, both of which every Nerd Font ships.
//
// No memo, unlike PackageIcons: this is asked once per classification landing
// (the result is STORED on the message and the conversation row -- views
// render the stored `icon`, they do not re-derive it), and the haystack is a
// whole question, which would make a poor cache key anyway.
//
// Usage: `glyphFor(question, title, categoryKey)` returns a single-character
// string.
// =============================================================================
QtObject {
    id: registry

    // Fallback for anything unrecognised: FA4 question -- the same glyph
    // LlmService gives the `other` category, which is what an exchange that
    // matched nothing is.
    property string defaultIcon: "\uf128"

    // Per-category fallbacks, seeded by the host (see the header).
    property var categoryIcons: ({})

    // Regex rules, evaluated in order against the lowercased question + title.
    // Word-bounded so "software" never reads as war and "archive" never reads
    // as arch; ordered specific before generic.
    property var patternIcons: [
        // -- languages and tools ---------------------------------------------
        { re: /\bpython\b|\bpip\b|\bnumpy\b|\bpandas\b|\bdjango\b/, glyph: "\ue73c", cats: ["code"] },              // python logo
        { re: /\brust\b|\bcargo\b|\bborrow checker\b/, glyph: "\ue7a8", cats: ["code"] },                           // rust gear
        { re: /\bjavascript\b|\btypescript\b|\bnode\b|\breact\b|\bnpm\b/, glyph: "\ue74e", cats: ["code"] },        // javascript
        { re: /\bgit\b|\bgithub\b|\bcommit\b|\brebase\b|\bmerge conflict\b/, glyph: "\uf1d3", cats: ["code", "system"] },     // git
        { re: /\bdocker\b|\bcontainer\b|\bpodman\b|\bkubernetes\b/, glyph: "\uf21a", cats: ["system", "code"] },              // ship -- PackageIcons' docker
        { re: /\bbash\b|\bshell\b|\bzsh\b|\bterminal\b|\bscript\b/, glyph: "\uf120", cats: ["system", "code"] },              // terminal
        { re: /\bsql\b|\bdatabase\b|\bpostgres\b|\bsqlite\b|\bquery\b/, glyph: "\uf1c0", cats: ["code", "data"] },          // database drum
        // -- the machine ------------------------------------------------------
        { re: /\barch linux\b|\bpacman\b|\byay\b|\baur\b/, glyph: "\uf303", cats: ["system"] },                       // arch linux
        { re: /\blinux\b|\bkernel\b|\bsystemd\b|\bdebian\b|\bfedora\b/, glyph: "\uf17c", cats: ["system"] },          // tux
        { re: /\bqt\b|\bqml\b|\bquickshell\b|\bwayland\b|\bhyprland\b|\bcompositor\b/, glyph: "\uf108", cats: ["system", "code"] },  // desktop
        { re: /\bgpu\b|\bcpu\b|\bram\b|\bvram\b|\bfirmware\b|\bbios\b|\bdriver\b/, glyph: "\uf2db", cats: ["system"] },      // microchip
        { re: /\bwifi\b|\bnetwork\b|\bdns\b|\bvpn\b|\brouter\b|\bethernet\b/, glyph: "\uf1eb", cats: ["system"] },    // wifi fan
        { re: /\bpassword\b|\bencrypt|\bssh\b|\bgpg\b|\bcertificate\b/, glyph: "\uf023", cats: ["system", "code"] },          // lock
        { re: /\bhtml\b|\bcss\b|\bwebsite\b|\bbrowser\b|\bhttp\b/, glyph: "\uf0ac", cats: ["code", "system", "explain"] },               // globe -- the web
        // -- words and numbers ------------------------------------------------
        { re: /\btranslat|\bgrammar\b|\bdutch\b|\bgerman\b|\bfrench\b|\bspanish\b/, glyph: "\uf1ab", cats: ["write", "explain"] },     // language
        { re: /\bemail\b|\bletter\b|\bmemo\b/, glyph: "\uf0e0", cats: ["write"] },                                   // envelope
        { re: /\bequation\b|\bderivative\b|\bintegral\b|\bprobability\b|\bstandard deviation\b|\baverage\b|\bmedian\b/, glyph: "\uf1ec", cats: ["data", "explain"] },  // calculator
        { re: /\bchart\b|\bgraph\b|\bdataset\b|\bspreadsheet\b|\bcsv\b/, glyph: "\uf080", cats: ["data"] },         // bar chart
        // -- the world --------------------------------------------------------
        { re: /\bpipewire\b|\bpulseaudio\b|\bwireplumber\b|\bwpctl\b/, glyph: "\uf001", cats: ["system"] },        // music note -- the audio STACK
        { re: /\bmusic\b|\baudio\b|\bsong\b|\balbum\b/, glyph: "\uf001", cats: ["other", "write", "explain"] },        // music note
        { re: /\bphoto\b|\bimage\b|\bpicture\b|\bwallpaper\b|\bsvg\b|\bpng\b/, glyph: "\uf03e", cats: ["other", "explain", "code", "write"] },   // picture frame
        { re: /\bphysics\b|\bchemistry\b|\bmolecule\b|\bquantum\b|\beclipse\b|\borbit\b/, glyph: "\uf0c3", cats: ["explain", "data"] },  // flask -- science
        { re: /\bhistory\b|\bcentury\b|\bempire\b|\brevolution\b/, glyph: "\uf02d", cats: ["explain", "write"] },               // book
        { re: /\bcook|\brecipe\b|\bbake\b|\bdinner\b|\bingredient/, glyph: "\uf0f5", cats: ["other"] },              // cutlery
        { re: /\btravel\b|\bflight\b|\btrip\b|\bitinerary\b/, glyph: "\uf072", cats: ["other"] },                    // plane
        { re: /\bmoney\b|\bbudget\b|\binvest|\btax\b|\bsalary\b/, glyph: "\uf0d6", cats: ["other", "data"] },                // banknote
        { re: /\bgame\b|\bgaming\b|\bsteam\b/, glyph: "\uf11b", cats: ["other", "system"] }                                    // gamepad
    ]

    // The first rule that hits AND is true under `categoryKey`. A rule with
    // no `cats` at all (a host's own addition) is live under every category.
    function _matchRule(question, title, categoryKey) {
        const hay = ((question || "") + "\n" + (title || "")).toLowerCase();
        if (hay.length <= 1) return null;
        const key = categoryKey || "";
        for (let i = 0; i < registry.patternIcons.length; i++) {
            const rule = registry.patternIcons[i];
            if (!rule || !rule.re) continue;
            if (key !== "" && rule.cats && rule.cats.indexOf(key) < 0) continue;
            if (rule.re.test(hay)) return rule;
        }
        return null;
    }

    function glyphFor(question, title, categoryKey) {
        const rule = registry._matchRule(question, title, categoryKey);
        if (rule) return rule.glyph;
        const byCat = categoryKey ? registry.categoryIcons[categoryKey] : undefined;
        return byCat !== undefined ? byCat : registry.defaultIcon;
    }

    // The category the WORDS point at, "" when they point at none. Only for
    // the case where nothing else decided one: the caller then files the
    // exchange by the same evidence that will choose its glyph, so the two
    // marks say one thing.
    function categoryFromPatterns(question, title) {
        const rule = registry._matchRule(question, title, "");
        return (rule && rule.cats && rule.cats.length > 0) ? rule.cats[0] : "";
    }
}
