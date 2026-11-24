pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/components"
import "SiliconModel.js" as Model
import "../../common/components/JsonComments.js" as JsonComments

// =============================================================================
// SiliconConfig.qml -- the user's silicon.jsonc, READ ONLY, hot-reloaded.
//
// Path: $XDG_CONFIG_HOME/quickshell/config/silicon.jsonc (overridable: `configPath`). Template and
// schema: .examples/silicon.jsonc at the config root. `//` and `/* */` comments are allowed outside
// strings (JsonComments.js). Nothing in this shell writes the file (`blockWrites`).
//
// `config` is the file normalised (SiliconModel.normalizeConfig), every key present at its
// seed's value unless the file says otherwise:
//   { defaultProfile: null | "quiet" | "balanced" | "performance",
//     profiles: { quiet|balanced|performance: { epp, turbo, governor, maxPerfPct, pl1W, pl2W } },
//     overhead: { wPerCpuSec, wPerGpuSec }, gpu: { ignoredHolders: [process names] }, look: { family, secondarySide } }
// (`defaultProfile`, default null: the profile the laptop comes up in. SiliconService stores that profile's row as the root helper's
// boot set, which silicon-boot.service applies early in every boot; the shell never applies it at its start. null stores nothing.)
// (An older file's `mux`, `idle` and `sounds` groups are not errors: each loads with one warning and is ignored -- the MUX's
// windows are the root helper's constants, SiliconModel.MUX_BOOT_WINDOW_S / MUX_PROMPT_WINDOW_S; the idle ladder's times and the
// sounds are the module's (IdleLadder, SiliconSounds), tuned in the silicon mockup.)
//
// A bad VALUE is ignored with ONE warning of its own (`warnings`, and one console.warn per
// warning each time the file's text changes -- never repeated for the same text), the other
// values stand. A file that does not PARSE keeps the last good config and says so in
// `lastError` (a typo in the middle of an edit must not reset the profiles). A missing file is
// not an error: `present` is false and every value is its seed.
//
// `ensureLoaded()` reads the file now, synchronously, if nothing has read it yet: a parent's
// Component.onCompleted runs before its children's, so the service calls it first.
// =============================================================================
Item {
    id: root

    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/silicon.jsonc"

    property var config: Model.defaultConfig()
    property var warnings: []
    property string lastError: ""
    property bool present: false
    // The file has been read (or found missing) at least once.
    property bool ready: false

    function reload() { fv.reload(); }

    function ensureLoaded() {
        if (root._applied)
            return;
        const t = fv.text();
        root._apply(t, t.length > 0);
    }

    // The same normalisation as a pure call: { config, warnings, parsed, error }.
    function parseText(txt) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0)
            return { config: Model.defaultConfig(), warnings: [], parsed: true, error: "" };
        let obj = null;
        try {
            obj = JSON.parse(JsonComments.strip(t));
        } catch (e) {
            const at = JsonComments.locate(t);
            return {
                config: null, warnings: [], parsed: false,
                error: (at ? "silicon.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                           : "silicon.jsonc: " + e.message) + " -- the last good version is kept"
            };
        }
        const r = Model.normalizeConfig(obj);
        return { config: r.config, warnings: r.warnings, parsed: true, error: "" };
    }

    // ---- The file ------------------------------------------------------------
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

    Component.onCompleted: root.ensureLoaded()

    function _apply(txt, exists) {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (root._applied && t === root._raw && root.present === (exists && t.length > 0))
            return;
        root._applied = true;
        root._raw = t;
        root.present = exists && t.length > 0;
        const r = root.parseText(t);
        if (!r.parsed) {
            root.lastError = r.error;
            console.warn("SiliconConfig: " + r.error);
            root.ready = true;
            return;
        }
        root.config = r.config;
        root.lastError = "";
        root.warnings = r.warnings;
        for (let i = 0; i < r.warnings.length; i++)
            console.warn("SiliconConfig: " + r.warnings[i]);
        root.ready = true;
    }
}
