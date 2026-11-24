import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// HowdyConfig.qml -- what howdy will do when a PAM stack reaches it.
//
//   mode       "off" | "native" | "input"   [core] workaround (howdy's
//                                           default when unset is "input")
//              "disabled"                   [core] disabled = true
//              "absent"                     no readable config
//   timeoutMs  [video] timeout, s -> ms (howdy's default 4 s)
//
// Under `off` howdy scans and THEN the next module prompts; under `native` the
// prompt is open at once and a failed face says nothing (measured).
// The auth toast's face line and the lock both depend on which.
// `path` is set once, at creation (a FileView repointed hands back the old
// file's bytes); `reload()` re-reads it.
// =============================================================================
Scope {
    id: root

    property string path: "/etc/howdy/config.ini"
    readonly property string mode: root._mode
    readonly property int timeoutMs: root._timeoutMs
    readonly property bool usable: root._mode !== "absent" && root._mode !== "disabled"

    property string _mode: "absent"
    property int _timeoutMs: 4000

    function reload() {
        file.reload();
        root._parse(file.text());
    }

    function _parse(text) {
        const t = String(text || "");
        if (t.length === 0) {
            root._mode = "absent";
            root._timeoutMs = 4000;
            return;
        }
        let section = "";
        const vals = {};
        const lines = t.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (line.length === 0 || line[0] === "#" || line[0] === ";")
                continue;
            const sec = /^\[(.+)\]$/.exec(line);
            if (sec) {
                section = sec[1].trim();
                continue;
            }
            const kv = /^([^=]+)=(.*)$/.exec(line);
            if (kv)
                vals[section + "." + kv[1].trim()] = kv[2].trim();
        }
        const secs = parseFloat(vals["video.timeout"]);
        root._timeoutMs = isFinite(secs) && secs > 0 ? Math.round(secs * 1000) : 4000;
        if (String(vals["core.disabled"] || "").toLowerCase() === "true")
            root._mode = "disabled";
        else
            root._mode = String(vals["core.workaround"] || "input").toLowerCase();
    }

    FileView {
        id: file
        path: root.path
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }

    Component.onCompleted: root._parse(file.text())
}
