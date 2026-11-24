pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments

// =============================================================================
// WikiConfig.qml -- the user's wiki.jsonc, READ ONLY, hot-reloaded (the
// StocksConfig pattern).
//
// Path: $XDG_CONFIG_HOME/quickshell/config/wiki.jsonc (overridable: `configPath`).
// Template and schema: .examples/wiki.jsonc at the config root; `//` and
// `/* */` comments are allowed outside strings (JsonComments.js). Nothing in
// this shell writes the file (`blockWrites`). The file is gitignored.
//
// `config` is the file normalised over the defaults, every key present:
//   { askAt 5, batchSize 30, rolloverHour 4, seenMs 5000, dwellMs 15000,
//     quickNextMs 4000, ollamaUrl "http://localhost:11434", jev true,
//     notesRoot "~/Documents/Notes", notesFolder "Wiki",
//     show { calendar, notifications, lock, launcher } (all true),
//     families { <family id>: false } ({}: none is off), askAgainHours 24, jevCapUsd 0.04,
//     models { write "", judge "" } ("" = tools/wiki/data/models.json's),
//     sources { wikipedia, arch, archTips, gentoo, kernel, freedesktop } }
//
// Mistakes are a line in `lastError`, never a warning and never a crash: a bad
// value takes its default and is named. A file that does not PARSE keeps the
// last good config (a typo in the middle of an edit must not change the
// module's behaviour) and says so. A missing file is not an error: `present`
// is false and every default holds.
//
// `parseText(txt)` is the same normalisation as a pure call ({ config,
// errors, parsed }).
// =============================================================================
Item {
    id: root

    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/wiki.jsonc"

    readonly property var defaults: ({
        askAt: 5, batchSize: 30, rolloverHour: 4, seenMs: 5000, dwellMs: 15000, quickNextMs: 4000,
        ollamaUrl: "http://localhost:11434", jev: true,
        notesRoot: "~/Documents/Notes", notesFolder: "Wiki",
        show: { calendar: true, notifications: true, lock: true, launcher: true },
        families: {}, askAgainHours: 24, jevCapUsd: 0.04, models: { write: "", judge: "" },
        sources: { wikipedia: true, arch: true, archTips: true, gentoo: true, kernel: true, freedesktop: true }
    })
    // The subjects `families` may switch off (families.json: Discover, then Deepen; the guest is not one).
    readonly property var familyIds: ["history", "geography", "people", "visual-arts", "performing-arts", "literature", "philosophy", "society",
        "physical-sciences", "life-sciences", "earth", "technology", "everyday", "arch-installed", "arch-discovery", "wikipedia-cs", "arch-tips",
        "other-wikis"]

    property var config: root.parseText("").config
    property string lastError: ""
    property bool present: false
    // The file has been read (or found missing) at least once.
    property bool ready: false

    function reload() { fv.reload(); }

    // ---- The file --------------------------------------------------------------
    property string _raw: ""
    property bool _applied: false

    ConfigFile {
        id: fv
        path: root.configPath
        // Each read of the file in force, and the file appearing or going, arrive as one of these; _apply parses only when the
        // bytes changed.
        onLoaded: root._apply(fv.text(), true)
        onLoadFailed: root._apply("", false)
    }

    // Read once, by whichever comes first: the completion or the owner that needs
    // the config at ITS completion (a parent's onCompleted runs before its child's).
    property bool _read: false
    function ensureLoaded() {
        if (root._read) return;
        root._read = true;
        const t = fv.text();
        if (t) root._apply(t, true);
        else if (!root.ready) root._apply("", false);
    }
    Component.onCompleted: root.ensureLoaded()

    function _apply(txt, exists) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (root._applied && t === root._raw && root.present === (exists && t.length > 0)) return;
        root._applied = true;
        root._raw = t;
        root.present = exists && t.length > 0;
        const r = root.parseText(t);
        if (!r.parsed && root.ready && root.present) {
            // Keep the last good config; say why the edit was not taken.
            root.lastError = r.errors.join("; ");
            return;
        }
        root.config = r.config;
        root.lastError = r.errors.join("; ");
        root.ready = true;
    }

    // ---- Normalisation (pure) ----------------------------------------------------
    function parseText(txt) {
        const errors = [];
        let obj = null;
        let parsed = true;
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length > 0) {
            try {
                obj = JSON.parse(JsonComments.strip(t));
            } catch (e) {
                parsed = false;
                const at = JsonComments.locate(t);
                errors.push((at ? "wiki.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                : "wiki.jsonc: " + e.message)
                            + " -- the last good version is kept");
            }
            if (obj !== null && (typeof obj !== "object" || Array.isArray(obj))) {
                errors.push("wiki.jsonc: the top level is not an object");
                obj = null;
            }
        }
        const o = obj || {};
        const d = root.defaults;
        const cfg = {};
        cfg.askAt = root._int("askAt", o.askAt, d.askAt, 0, 1000, errors);
        cfg.batchSize = root._int("batchSize", o.batchSize, d.batchSize, 1, 200, errors);
        cfg.rolloverHour = root._int("rolloverHour", o.rolloverHour, d.rolloverHour, 0, 12, errors);
        cfg.seenMs = root._int("seenMs", o.seenMs, d.seenMs, 0, 600000, errors);
        cfg.dwellMs = root._int("dwellMs", o.dwellMs, d.dwellMs, 1000, 3600000, errors);
        cfg.quickNextMs = root._int("quickNextMs", o.quickNextMs, d.quickNextMs, 0, 600000, errors);
        cfg.ollamaUrl = d.ollamaUrl;
        if (o.ollamaUrl !== undefined) {
            if (typeof o.ollamaUrl === "string" && /^https?:\/\/[^\s]+$/.test(o.ollamaUrl.trim()))
                cfg.ollamaUrl = o.ollamaUrl.trim().replace(/\/+$/, "");
            else
                errors.push("ollamaUrl: not an http(s) URL, using " + d.ollamaUrl);
        }
        cfg.jev = d.jev;
        if (o.jev !== undefined) {
            if (typeof o.jev === "boolean") cfg.jev = o.jev;
            else errors.push("jev: not true or false, using " + d.jev);
        }
        cfg.notesRoot = d.notesRoot;
        if (o.notesRoot !== undefined) {
            if (typeof o.notesRoot === "string" && o.notesRoot.trim().length > 0) cfg.notesRoot = o.notesRoot.trim();
            else errors.push("notesRoot: not a path, using " + d.notesRoot);
        }
        cfg.notesFolder = d.notesFolder;
        if (o.notesFolder !== undefined) {
            // One plain folder name: it becomes a directory under notesRoot.
            if (typeof o.notesFolder === "string" && /^[^\/\\\0]+$/.test(o.notesFolder.trim())
                    && o.notesFolder.trim() !== "." && o.notesFolder.trim() !== "..")
                cfg.notesFolder = o.notesFolder.trim();
            else
                errors.push("notesFolder: not a single folder name, using " + d.notesFolder);
        }
        cfg.show = root._flags("show", o.show, d.show, errors);
        cfg.families = {};
        if (o.families !== undefined) {
            if (o.families && typeof o.families === "object" && !Array.isArray(o.families)) {
                for (const k in o.families) {
                    if (root.familyIds.indexOf(k) < 0) errors.push("families." + k + ": not a subject, ignored");
                    else if (typeof o.families[k] !== "boolean") errors.push("families." + k + ": not true or false");
                    else if (o.families[k] === false) cfg.families[k] = false;
                }
            } else {
                errors.push("families: not an object, none is off");
            }
        }
        cfg.askAgainHours = root._num("askAgainHours", o.askAgainHours, d.askAgainHours, 1, 720, errors);
        cfg.jevCapUsd = root._num("jevCapUsd", o.jevCapUsd, d.jevCapUsd, 0, 10, errors);
        cfg.models = Object.assign({}, d.models);
        if (o.models !== undefined) {
            if (o.models && typeof o.models === "object" && !Array.isArray(o.models)) {
                for (const k in o.models) {
                    if (d.models[k] === undefined) errors.push("models." + k + ": not a model's role, ignored");
                    else if (typeof o.models[k] !== "string") errors.push("models." + k + ": not a model name");
                    else cfg.models[k] = o.models[k].trim();
                }
            } else {
                errors.push("models: not an object, using models.json's");
            }
        }
        cfg.sources = Object.assign({}, d.sources);
        if (o.sources !== undefined) {
            if (o.sources && typeof o.sources === "object" && !Array.isArray(o.sources)) {
                for (const k in o.sources) {
                    if (d.sources[k] === undefined) errors.push("sources." + k + ": not a source, ignored");
                    else if (typeof o.sources[k] !== "boolean") errors.push("sources." + k + ": not true or false");
                    else cfg.sources[k] = o.sources[k];
                }
            } else {
                errors.push("sources: not an object, using the defaults");
            }
        }
        for (const k in o)
            if (d[k] === undefined) errors.push(k + ": not a setting, ignored");
        return { config: cfg, errors: errors, parsed: parsed };
    }

    function _num(key, v, dflt, lo, hi, errors) {
        if (v === undefined) return dflt;
        if (typeof v === "number" && isFinite(v) && v >= lo && v <= hi) return v;
        errors.push(key + ": not a number from " + lo + " to " + hi + ", using " + dflt);
        return dflt;
    }

    // An object of switches over `dflts`: each a boolean, an unknown one named.
    function _flags(key, v, dflts, errors) {
        const out = Object.assign({}, dflts);
        if (v === undefined) return out;
        if (!v || typeof v !== "object" || Array.isArray(v)) {
            errors.push(key + ": not an object, using the defaults");
            return out;
        }
        for (const k in v) {
            if (dflts[k] === undefined) errors.push(key + "." + k + ": not a setting, ignored");
            else if (typeof v[k] !== "boolean") errors.push(key + "." + k + ": not true or false");
            else out[k] = v[k];
        }
        return out;
    }

    function _int(key, v, dflt, lo, hi, errors) {
        if (v === undefined) return dflt;
        if (typeof v === "number" && isFinite(v) && Math.floor(v) === v && v >= lo && v <= hi) return v;
        errors.push(key + ": not a whole number from " + lo + " to " + hi + ", using " + dflt);
        return dflt;
    }
}
