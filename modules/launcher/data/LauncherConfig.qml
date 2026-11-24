pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components"
import "../../common/components/JsonComments.js" as JC
import "../../common/config/ConfigCheck.js" as Check
import "../../common/config/ConfigSpecs.js" as Specs
import "JsonEdit.js" as JE

// =============================================================================
// LauncherConfig.qml -- launcher.jsonc (or launcher.json), the launcher's hand-edited settings.
//
//   { "columns": 2,          // columns of the multi-column layout (1..8)
//     "rows": 9,             // rows shown before the list scrolls (1..40)
//     "scriptsRoot": "",     // "" = $XDG_CONFIG_HOME/quickshell/launcher;
//                            // "~/..." and absolute paths as written,
//                            // anything else relative to the config dir
//     "flourish": "",        // the confirm flourish's preset: honey (the default, ""), syrup,
//                            // dew, classic (modules/launcher/FlourishPresets.js), or off
//     "answers": { .. },     // the quick answers (LauncherAnswers): enabled, kinds, takesEnter, homeCurrency, currencies, history
//     "keysFree": [ .. ],    // the windows whose keys stay their own under the launcher
//     "clickOutsideCloses", "keepQuerySec",
//     "hidden": [] }         // desktop ids the launcher does not list
//
// The keys from `answers` to `keepQuerySec` are read through the file's spec (modules/common/config/specs/launcher.js: their types, ranges
// and defaults).
//
// Comments are allowed (JsonComments); a syntax error is reported with its
// line and column in `error`, and the defaults stand until it is fixed.
//
// THE LAUNCHER WRITES ONE MEMBER: `hidden` (Hide / Unhide). The file is not
// re-serialised -- JsonEdit replaces that one value in the text and every
// other byte, comments and formatting included, stays where the user put it.
// A file the launcher cannot read (a syntax error) is NEVER written:
// setHidden answers why and the file stays as it is. A missing file is
// normal (first run); the first Hide creates it with the defaults spelled
// out. Writes are atomic (FileView atomicWrites) after a mkdir -p of the
// folder; our own write's echo is recognised by its text and skipped.
//
// `path` is set once, at creation (a FileView is never repointed); ConfigFile reads the .jsonc beside a
// .json path first, and a first write creates the .jsonc.
// =============================================================================
Scope {
    id: cfg

    required property string path

    readonly property int columns: cfg._d.columns
    readonly property int rows: cfg._d.rows
    readonly property string scriptsRoot: cfg._d.scriptsRoot
    readonly property string flourish: cfg._d.flourish
    readonly property var answers: cfg._d.answers
    readonly property var keysFree: cfg._d.keysFree
    readonly property bool clickOutsideCloses: cfg._d.clickOutsideCloses
    readonly property real keepQuerySec: cfg._d.keepQuerySec
    readonly property var hidden: cfg._d.hidden
    readonly property string error: cfg._error
    readonly property bool exists: cfg._text.length > 0
    readonly property int serial: cfg._serial

    signal changed

    function isHidden(id) {
        return cfg._hiddenSet[id] === true;
    }

    // "" when written (or already so), else why not.
    function setHidden(id, on) {
        const want = !!on;
        if (typeof id !== "string" || id.length === 0)
            return "no desktop id";
        if (cfg.isHidden(id) === want)
            return "";
        if (cfg._error.length > 0)
            return cfg.path + " is not written: " + cfg._error;
        const next = cfg._d.hidden.filter(x => x !== id);
        if (want)
            next.push(id);
        const value = "[" + next.map(x => JSON.stringify(x)).join(", ") + "]";
        let txt;
        if (cfg._text.length === 0) {
            txt = cfg._fresh(value);
        } else {
            txt = JE.setTopLevel(cfg._text, "hidden", value);
            if (txt === null)
                return cfg.path + " is not written: its top level is not an object";
        }
        cfg._write(txt);
        return "";
    }

    // ---- internals ---------------------------------------------------------

    readonly property var defaults: ({
            columns: 2,
            rows: 9,
            scriptsRoot: "",
            flourish: "",
            hidden: []
        })
    property var _d: cfg._normalise({})
    property var _hiddenSet: ({})
    property string _text: ""
    property string _error: ""
    property int _serial: 0
    property var _recent: []
    property string _pending: ""
    property bool _dirReady: false
    readonly property string _dir: cfg.path.substring(0, cfg.path.lastIndexOf("/"))

    function _fresh(hiddenValue) {
        return [
            "// The application launcher (modules/launcher). Comments are allowed.",
            "// The launcher rewrites only \"hidden\" (Hide / Unhide in its menu).",
            "{",
            "    \"columns\": " + cfg.defaults.columns + ",",
            "    \"rows\": " + cfg.defaults.rows + ",",
            "    \"scriptsRoot\": \"\",",
            "    \"hidden\": " + hiddenValue,
            "}",
            ""
        ].join("\n");
    }

    function _int(v, lo, hi, dflt) {
        const n = Number(v);
        if (!isFinite(n) || Math.floor(n) !== n || n < lo || n > hi)
            return dflt;
        return n;
    }
    function _normalise(o) {
        const D = cfg.defaults;
        const S = Check.read(Specs.specOf("launcher"), o).settings;
        const hidden = [];
        if (Array.isArray(o.hidden))
            for (let i = 0; i < o.hidden.length; i++)
                if (typeof o.hidden[i] === "string" && o.hidden[i].length > 0 && hidden.indexOf(o.hidden[i]) < 0)
                    hidden.push(o.hidden[i]);
        return {
            columns: cfg._int(o.columns, 1, 8, D.columns),
            rows: cfg._int(o.rows, 1, 40, D.rows),
            scriptsRoot: typeof o.scriptsRoot === "string" ? o.scriptsRoot : D.scriptsRoot,
            flourish: typeof o.flourish === "string" ? o.flourish.trim().toLowerCase() : D.flourish,
            answers: S.answers,
            keysFree: S.keysFree,
            clickOutsideCloses: S.clickOutsideCloses,
            keepQuerySec: S.keepQuerySec,
            hidden: hidden
        };
    }

    function _ingest(txt) {
        const t = String(txt || "");
        if (t === cfg._text && cfg._serial > 0)
            return;
        cfg._text = t;
        let d = cfg._normalise({});
        let err = "";
        if (t.length > 0) {
            try {
                const o = JSON.parse(JC.strip(t));
                if (!o || typeof o !== "object" || Array.isArray(o))
                    err = "the top level is not an object";
                else
                    d = cfg._normalise(o);
            } catch (e) {
                const at = JC.locate(t);
                err = at ? "line " + at.line + ", column " + at.column + ": " + at.reason : String(e);
            }
        }
        if (err.length > 0 && err !== cfg._error)
            console.log("LauncherConfig: " + cfg.path + ": " + err + " -- the defaults stand and the file is not written until it is fixed");
        cfg._error = err;
        const set = {};
        for (let i = 0; i < d.hidden.length; i++)
            set[d.hidden[i]] = true;
        cfg._d = d;
        cfg._hiddenSet = set;
        cfg._serial += 1;
        cfg.changed();
    }

    function _write(txt) {
        const r = cfg._recent.slice(-3);
        r.push(txt);
        cfg._recent = r;
        // Memory follows at once: the next setHidden edits this text.
        cfg._ingest(txt);
        if (!cfg._dirReady) {
            cfg._pending = txt;
            mkdir.running = true;
            return;
        }
        file.setText(txt);
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", "--", cfg._dir]
        running: false
    }
    Connections {
        target: mkdir
        function onExited(exitCode) {
            cfg._dirReady = exitCode === 0;
            const t = cfg._pending;
            cfg._pending = "";
            if (cfg._dirReady && t.length > 0)
                file.setText(t);
            else if (!cfg._dirReady)
                console.log("LauncherConfig: could not create " + cfg._dir + "; " + cfg.path + " is not written");
        }
    }

    ConfigFile {
        id: file
        path: cfg.path
        atomicWrites: true
        onLoaded: {
            const t = file.text();
            // Our own write's echo (or a stale echo of an earlier one, which
            // reads the newer file: also ours) changes nothing.
            if (cfg._recent.indexOf(t) >= 0)
                return;
            cfg._dirReady = true;
            cfg._ingest(t);
        }
    }

    Component.onCompleted: {
        const t = file.text();
        cfg._dirReady = t.length > 0;
        cfg._ingest(t);
    }
    Component.onDestruction: file.waitForJob()
}
