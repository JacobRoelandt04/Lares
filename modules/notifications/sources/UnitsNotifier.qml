pragma ComponentBehavior: Bound

import QtQuick

import "SourceGlyphs.js" as G
import "FailedUnits.js" as Units

// =============================================================================
// UnitsNotifier.qml -- a systemd unit failed (source "units"; SOURCES.md, "Later sources").
//
// Every `pollSec` seconds `systemctl --failed` is read for the system manager and for the user's (each can be
// switched off; `ignore` names units, or `*` globs, the user does not want to hear about). A unit that is failed and was
// not told yet this BOOT is a card -- "foo failed", its description, "(user)" for the user manager's -- and one that
// recovers takes its card away and will be told again if it fails again. Units already failed when the shell starts are
// told once, then remembered with the boot's id in sources.json: restarting the shell does not say them again.
//
// "Show log": the action runs `journalctl [--user] -u <unit> -n N -o cat` and the SAME card takes the tail in a box of its
// own below the words (LogTailBody: a carved box, the terminal's face, the newest line at the foot -- a card clamps its body
// text from the top, and the line that says why is the last). The card is resident: the button does not dismiss it. While
// the log is shown the button reads "Hide log" and hides it (the card says what it first said), and "Copy log" stands
// beside it: it copies the WHOLE journal -- the last `copyLines` lines of the unit's, not the few the card has room for --
// to the clipboard (journalctl piped into wl-copy, so the text never passes through an argument) and says "Copied" for a
// moment. The journal is read only when a button is pressed.
// =============================================================================
SourceBase {
    id: src

    sourceId: "units"
    appName: "Systemd"
    glyph: G.units
    keys: ["unit"]

    property int pollMs: src.settings.pollSec * 1000

    Timer {
        interval: Math.max(50, src.pollMs)
        running: src.active
        repeat: true
        triggeredOnStart: true
        onTriggered: src._poll()
    }

    function _poll() {
        if (!src.active)
            return;
        // a list that is switched off reads as an empty one that could be read: what it told is taken back
        const ok = { system: !src.settings.system, user: !src.settings.user };
        const scopes = ["system", "user"].filter(sc => src.settings[sc]);
        if (scopes.length === 0) {
            src._apply([], ok);
            return;
        }
        const found = [];
        let pending = scopes.length;
        for (const scope of scopes) {
            const argv = ["systemctl"].concat(scope === "user" ? ["--user"] : []).concat(["--failed", "--no-legend", "--plain", "--no-pager"]);
            src.host.exec.run(argv, (code, out) => {
                // a list that could not be read (no user manager, no bus) says nothing: it recovers no unit
                ok[scope] = code === 0;
                if (code === 0)
                    for (const u of Units.parse(out, scope))
                        if (!Units.ignored(u.unit, src.settings.ignore))
                            found.push(u);
                if (--pending === 0 && src.active)
                    src._apply(found, ok);
            });
        }
    }

    function _keyOf(u) {
        return "unit:" + u.scope + ":" + u.unit.replace(/[^A-Za-z0-9._@:+-]/g, "_");
    }

    function _apply(found, ok) {
        const r = Units.fresh(found, Units.memory(src.host.state.get("units"), src.host.bootId), ok);
        for (const u of r.added)
            src._say(u);
        for (const k of r.removed) {
            const ck = "unit:" + k.replace(/[^A-Za-z0-9._@:+-]/g, "_");
            delete src._logs[ck];
            delete src._units[ck];
            src.withdraw(ck);
        }
        src.host.state.put("units", { boot: src.host.bootId, announced: r.announced });
    }

    // Switched off: what it told is taken back, and the memory goes with it (switched on again, it tells what is failing).
    onDeactivated: {
        src._logs = ({});
        src._units = ({});
        src._copied = "";
        src.host.state.put("units", { boot: src.host.bootId, announced: {} });
    }

    Component {
        id: logBody
        LogTailBody {}
    }

    // What each card shows, by its key: `_logs[key]` is the tail's lines while "Show log" is on (absent: the card as it first
    // said it; [] a unit with no journal), `_units[key]` the unit it is for, `_copied` the key whose Copy just worked.
    property var _logs: ({})
    property var _units: ({})
    property string _copied: ""

    // The card of `u` as it stands: the first words, or with the tail's box (a unit with no journal says so, in words).
    function _say(u) {
        const key = src._keyOf(u);
        const log = src._logs[key];
        const shown = log !== undefined;
        src._units[key] = u;
        const actions = [{ id: "log", label: shown ? "Hide log" : "Show log", run: () => shown ? src._hideLog(u) : src._showLog(u) }];
        const spec = { title: Units.title(u), body: Units.body(u), urgency: "normal", resident: true, actions: actions };
        if (shown && log.length > 0) {
            actions.push({ id: "copy", label: src._copied === key ? "Copied" : "Copy log", run: () => src._copyLog(u) });
            spec.bodyComponent = logBody;
            spec.bodyProps = { lines: log };
        } else if (shown) {
            spec.body = Units.body(u) + "\nNo journal lines for this unit";
        }
        src.post(key, spec);
    }

    function _showLog(u) {
        src.host.exec.run(Units.tailCommand(u.unit, u.scope, src.settings.logLines), (code, out) => {
            if (!src.active)
                return;
            src._logs[src._keyOf(u)] = Units.tail(out, src.settings.logLines);
            src._say(u);
        });
    }

    function _hideLog(u) {
        delete src._logs[src._keyOf(u)];
        src._say(u);
    }

    // The whole journal (the last `copyLines` lines), to the clipboard; the card says "Copied" for a moment.
    function _copyLog(u) {
        src.host.exec.run(Units.copyCommand(u.unit, u.scope, src.settings.copyLines), code => {
            if (!src.active || code !== 0)
                return;
            src._copied = src._keyOf(u);
            src._say(u);
            copiedTimer.restart();
        });
    }
    Timer {
        id: copiedTimer
        interval: 2500
        onTriggered: {
            const key = src._copied;
            src._copied = "";
            if (src._units[key] && src._logs[key] !== undefined)
                src._say(src._units[key]);
        }
    }
}
