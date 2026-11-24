pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/components"

// =============================================================================
// LauncherAnswers.qml -- the quick answers of the launcher's query (math, currency, bases, units, dates,
// colours, resolutions ...): the child process that parses them, and what the popup shows from it.
// Owned by LauncherService (it outlives the popup's content); `contract` is "the answers child" in
// docs/agent_added_files_and_folders/shell_progress/R13-PLAN.md, spoken by tools/launcher/answers.py.
//
// THE CHILD is started lazily, at the first non-empty query, through SupervisedStream
// (`setpriv --pdeathsig TERM -- python3 <script>`), kept for the shell's life and restarted with the
// stream's backoff when it dies. Python or the script missing: ONE log line and no answers, ever (the
// check is a `test -f` + `command -v python3` before the first start; a `command` handed in is trusted).
//
// ASKS. Every query change asks with a RISING id; only the reply carrying the LATEST id is kept (a reply
// is read against the state it belongs to), and an empty query clears the answers WITHOUT asking and
// bumps the id, so a reply still in the air for the last query lands on nothing. A `pending` answer is
// followed by a second reply with the same id: it replaces the first in place (the popup swaps the
// text, no fade). Until the first reply of a new query the previous answers stay (a reply takes
// a few milliseconds; clearing on every keystroke would blink the row), and a dead child clears them.
//
// COPY is `copyCommand` + the text (wl-copy, the way the shell copies text: ClipboardService, the
// screenshot's Copy path); detached, so it outlives the popup that asked.
// =============================================================================
QtObject {
    id: a

    property bool enabled: true
    // The child's argv; [] = the default (python3 on `script`). A probe points it at a stub.
    property var command: []
    property string script: RepoRoot.dir + "/tools/launcher/answers.py"
    // launcher.jsonc "answers", the child's options (a change of one restarts it).
    property var kinds: ["colour", "resolution", "percent", "currency", "base", "zone", "date", "timearith", "unit", "math"]
    property string homeCurrency: "EUR"
    property var currencies: ["USD", "EUR", "GBP", "JPY", "CHF"]
    property var copyCommand: ["wl-copy", "--"]

    // What the popup reads: the answers of the latest query ([] = none) and a serial that bumps on
    // every change of them (read it first in a binding that walks `items`).
    readonly property var items: a._items
    readonly property int serial: a._serial
    readonly property bool missing: a._missing
    readonly property bool running: a._stream.running
    readonly property int latestId: a._id
    // A query was sent and its reply has not landed: an empty `items` then is not yet "no answer".
    readonly property bool waiting: a._wanted && a._lastLine !== "" && !a._replied && !a._missing && a.enabled

    // A copy was made (the text copied).
    signal copied(string text)

    // The query changed (LauncherService calls this from onQueryChanged).
    function ask(q) {
        const t = String(q === undefined || q === null ? "" : q).trim();
        a._id += 1;
        a._replied = false;
        if (t.length === 0 || !a.enabled || a._missing) {
            a._lastLine = "";
            a._set([]);
            return;
        }
        a._lastLine = JSON.stringify({
            id: a._id,
            q: String(q)
        }) + "\n";
        a._wanted = true;
        if (a.command.length === 0 && !a._checked)
            a._check();
        a._flush();
    }

    function copy(text) {
        const t = String(text === undefined || text === null ? "" : text);
        if (t.length === 0)
            return;
        Quickshell.execDetached(a.copyCommand.concat([t]));
        a.copied(t);
    }

    // ---- internals -------------------------------------------------------------------------------------
    property var _items: []
    property int _serial: 0
    property int _id: 0
    property bool _replied: false
    property string _lastLine: ""
    property bool _wanted: false
    property bool _checked: false
    property bool _ok: false
    property bool _missing: false

    function _set(list) {
        if (list.length === 0 && a._items.length === 0)
            return;
        a._items = list;
        a._serial += 1;
    }

    function _check() {
        a._checked = true;
        chk.command = ["sh", "-c", 'test -f "$1" && command -v python3 >/dev/null 2>&1', "sh", a.script];
        chk.running = true;
    }

    function _flush() {
        if (a._lastLine !== "" && !a._replied && a._stream.running)
            a._stream.write(a._lastLine);
    }

    function _argv() {
        if (a.command.length > 0)
            return a.command;
        return ["setpriv", "--pdeathsig", "TERM", "--", "python3", a.script, "--home-currency", a.homeCurrency,
                "--currencies", a.currencies.join(","), "--kinds", a.kinds.join(",")];
    }

    function _onLine(text) {
        if (text.length === 0)
            return;
        let o = null;
        try {
            o = JSON.parse(text);
        } catch (e) {
            return;
        }
        if (!o || o.id !== a._id || !(o.answers instanceof Array))
            return;
        const out = [];
        for (let i = 0; i < o.answers.length && out.length < 3; i++) {
            const x = o.answers[i];
            if (!x || typeof x.value !== "string" || x.value.length === 0)
                continue;
            out.push({
                kind: String(x.kind || ""),
                value: x.value,
                copy: typeof x.copy === "string" && x.copy.length > 0 ? x.copy : x.value,
                expr: String(x.expr || ""),
                detail: String(x.detail || ""),
                alts: a._altsOf(x.alts),
                swatch: typeof x.swatch === "string" ? x.swatch : "",
                pending: x.pending === true
            });
        }
        a._replied = true;
        a._set(out);
    }

    function _altsOf(v) {
        const out = [];
        if (!(v instanceof Array))
            return out;
        for (let i = 0; i < v.length && out.length < 3; i++)
            if (v[i] && typeof v[i].value === "string" && v[i].value.length > 0)
                out.push({
                    label: String(v[i].label || ""),
                    value: v[i].value,
                    copy: typeof v[i].copy === "string" && v[i].copy.length > 0 ? v[i].copy : v[i].value
                });
        return out;
    }

    readonly property Process _chk: Process {
        id: chk
        running: false
        onExited: code => {
            a._ok = code === 0;
            if (!a._ok) {
                a._missing = true;
                console.log("LauncherAnswers: no answers (python3 or " + a.script + " is missing)");
                a._set([]);
            }
        }
    }

    readonly property SupervisedStream _stream: SupervisedStream {
        id: stream
        what: "LauncherAnswers: the answers child"
        stdinEnabled: true
        enabled: a.enabled && a._wanted && (a.command.length > 0 || a._ok)
        command: a._argv()
        onLine: text => a._onLine(text)
        // Stopped by us (other options, or switched off) it has the query to answer again when it is back.
        onExited: (code, expected) => {
            a._set([]);
            if (expected)
                a._replied = false;
        }
    }
    readonly property Connections _streamEvents: Connections {
        target: stream
        // A child that came (back) up is asked for the query it never answered.
        function onRunningChanged() {
            if (stream.running)
                a._flush();
        }
    }
}
