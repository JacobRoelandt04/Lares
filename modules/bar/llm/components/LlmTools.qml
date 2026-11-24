pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "LlmToolPolicy.js" as Pol
import "LlmVoicePolicy.js" as Voice
import "../../../common/auth"
import "../../../auth/data"
import "../../../common/components"
import "../../../common/system"

// =============================================================================
// LlmTools.qml
//
// The tool registry, the permission policy, the grants and the runner -- ONE
// file of code over MANY files of data. The host creates it
// beside LlmService and hands it to `service.tools`; the service never sees a
// process, and this file never sees a conversation.
//
// THE DATA. `files[]` names JSON files under `dir` (the shell's own
// `llm_tools/`); an Instantiator puts a watched FileView on each, and
// `policy.json` is always loaded beside them. Every entry is compiled by
// LlmToolPolicy.compileFile against the templating law AT LOAD TIME:
// a placeholder never sits inside code, so `sed -n '{from},{to}p'` cannot be
// loaded at all, a `sh -c` script may carry one only as a positional argument
// after the script, an embedded placeholder (text around it, as in the
// Hyprland Lua dispatch) needs a constrained type. A bad entry is dropped and
// named with its exact path in `errors`; a bad ACTION of a family is dropped
// alone and the rest of the family loads (one typo must not silence all of
// Hyprland). An edit hot-reloads: `wireTools` is rebuilt on load, never per
// request; an empty mid-save read is ignored, the Theme idiom.
//
// THE MECHANISM BEHIND THE LAW. Nothing acts on the machine unless the
// user has seen the exact bytes that will act, and the bytes that run are the
// bytes that were shown. That is not a convention here: `freeze()` builds the
// call object ONCE at policy time -- the rendered argv, the stdin, the cwd,
// the timeout, the detail text the confirmation shows -- and `run()` executes
// THAT object. The runner never reads `args` or `norm`; a caller that mutates
// the model's arguments after the box opened changes nothing that runs.
// `run()` refuses a frozen object that has not been decided (`free` for a
// read, `granted`/`yes`/`always` for an act), refuses one that already ran,
// and refuses a second job while one is running -- all three as throws a
// test can see.
//
// THE RUNNER. One tool child at a time, ever. argv is `timeout -k <grace> <s>
// ...` with `timeout` as the Process's OWN pid, because that is what signals
// the whole pipeline: TERM to `timeout -k 2 30 bash -c 'sleep 20 | cat'`
// takes the bash and the sleep with it inside 0.7 s (measured), where a
// bash wrapper around timeout dies alone and orphans the tool. A process
// GROUP is not a fence, though: `set -m` puts every later job in its own
// group and `sleep 997 &` outlives a bash that exits at once, and both were
// reproduced surviving the timeout, the cancel and the trailer that said the
// job had ended. So every job runs in its own transient
// systemd SCOPE -- `systemd-run --user --scope -u llm-tool-<id>`, which execs
// `timeout` in place (21 ms, measured) -- and a scope is a cgroup: when the
// job ends, however it ends, `cgroup.procs` says what is still alive in it,
// a `1` written to `cgroup.kill` ends all of it, and the trailer counts what
// was killed. The grace KILL after a cancel and the belt go to the whole
// cgroup, never to `timeout` alone (which raced timeout's own -k and could
// orphan a TERM-immune child). The scope also carries RuntimeMaxSec, so the
// kernel ends the job at timeout + grace + 1 s even if this process is gone.
// Without a user manager (`/proc/self/cgroup` has no user@N.service, or
// `systemd-run` fails its one-time probe) the runner falls back to the bare
// timeout wrapper and says so once.
//
// THE COMMAND REACHES BASH AS IT WAS SHOWN. `systemd-run` expands
// `${NAME}` inside a word and turns `$$` into `$` before it execs anything --
// its unit-file rules, applied to a --scope's argv by default (systemd 261,
// measured: `for f in a b; do printf "[%s]" "${f}"; done` printed `[][]`).
// Every scope is started with `--expand-environment=no`, so the bytes bash
// runs are the bytes the confirmation showed; the one-time probe carries the
// flag too, so a systemd without it falls back to the bare timeout wrapper
// rather than to a mangled command.
//
// SUDO AUTHENTICATES EVERY TIME. Two things make that need care, both measured:
//   * a job run INSIDE the terminal quickshell was started from shares its
//     session and controlling tty (tty_nr 34823 in the job's bash), so sudo's
//     per-terminal credential cache is shared by every call the model makes AND
//     with whatever the user has sudo'd in that terminal: the second
//     `sudo pacman -Qe` of a conversation ran in 154 ms with no face scan.
//     So every job starts under `setsid -w`: a new session with no terminal
//     (tty_nr 0), which leaves sudo nothing to cache against but the job's own
//     shell. `setsid` execs in place (the Process is not a group leader), so
//     the Process's pid is still `timeout`'s and every signal path is the
//     same.
//   * within one call, `sudo a; sudo b` share that shell. So `sudo` on a job's
//     PATH is `llm_tools/bin/sudo`, which runs `/usr/bin/sudo -k -A`: `-k`
//     ignores any cached credential AND writes none, `-A` takes a password
//     from `SUDO_ASKPASS` instead of a terminal. Howdy is the first link of
//     sudo's PAM stack either way, so every call looks at the camera first.
//     A command that names `/usr/bin/sudo` itself skips the shim; within that
//     ONE call it can then reuse its first authentication, never across
//     calls, and the confirmation showed the path it used.
//
// THE PASSWORD. When Howdy gives up, sudo runs the askpass helper
// (`llm_tools/askpass.py`), which connects to `_askSock` -- a socket
// `AskpassServer` serves only while a job runs, and whose requests it verifies
// against this job's own process (see its header for the security reasoning)
// -- and waits for one line. A command may say `2>/dev/null`,
// which is why the request does not travel on stderr. `authRequest` is the
// server's verified request decorated with the job's fields; `answerAuth(id,
// secret)` hands the secret on and keeps nothing. An empty answer is a cancel
// (the helper exits 1 and sudo reports "no password was provided"). The
// confirmation shows every command verbatim first.
//
// WHO ASKS THE USER. The popup draws no password field:
// the server's requests go to the shell's AuthBroker (`AuthBus.broker`) through
// an `AskpassSource`, and the user answers in the authentication toast -- face
// or password, the face winning is read from the processes (AskpassServer's
// settle watch), not from the helper. `answerAuth` / `cancelAuth` stay for
// tests and go through the broker like the toast does. With no broker (an LLM
// mockup alone) the request is answered "" at once and `authNote` says why.
//
// A child that never STARTS (a cwd that does not exist, fork failure) gets no
// `exited` from Quickshell -- only `running` falling back to false with no
// `started` before it -- and would wedge the runner for the life of the
// process; that transition settles the job as `failed` with the reason.
//
// Output is counted in BYTES from the collector's own byte array on every
// arrival -- never from its decoded text, whose U+FFFD for an undecodable or
// half-arrived byte would count as three and flag a 64 KiB text file as
// binary. The head buffer stops at 75 % of the cap on a character boundary, a
// tail ring keeps the last 25 % (the error is at the end), and past
// `toolFloodKillBytes` the child is killed and the entry says `flood` with
// the exact figures. Binary means a NUL or an invalid sequence; a character
// the child itself cut in half at its end is dropped, not binary. Nothing is
// cut in silence: the trailer line the model reads and the block draws
// carries the byte counts.
//
// THE GRANTS. `remember()` writes a rule to `<store>.tools.json` immediately,
// atomically, watched, so a hand edit applies live and a revoke from any of
// the three surfaces in the popup lands here. The verb rule lives in
// LlmToolPolicy.grantKeyOf; the never-lists live in policy.json and are
// applied by `decide()`, which is the ONE function that says whether a call
// runs free, runs under a rule, asks, or is refused. A `dir` key is the
// REAL parent directory: an entry with a `preflight` (write_file's
// `write.py --preflight`) has it run BEFORE the decision, and its resolved
// path is what the key, the confirmation and the frozen argv carry -- a
// symlinked parent is shown resolved, never followed after the click.
//
// A SPOKEN TURN (LlmService.voiceAsk) IS DECIDED BY ITS OWN TABLE. The service
// hands `decide()` and `freeze()` facts with `handsFree` set, and the decision
// is LlmVoicePolicy's: a run_command passes only as ONE plain command from its
// short list, judged on the paths as written and as `voicepaths.py` (the voice
// preflight, run before the decision) resolved them, and it runs as the argv
// that was judged -- `timeout ... git --no-pager ... log ...`, never through
// bash, with its stdin closed; the reading tools stop at a secret store, the
// clipboard and the screen; a web search stops once the turn has read the
// machine; no remembered rule applies and nothing grantable is offered. A
// conversation that began spoken runs its tools in the directory it was asked
// from (`facts.cwd`, resolved by the same preflight), spoken turn or typed.
// =============================================================================
Item {
    id: root

    // ---- Wiring ------------------------------------------------------------
    property string dir: RepoRoot.dir + "/llm_tools"
    property var    files: ["tools.json", "hyprctl.json", "system.json"]
    property var    store: null
    readonly property string home: Quickshell.env("HOME") || ""

    // The popup's numbers; an entry's own `timeoutMs`/`outputCap` of 0 means
    // these. The host binds them from its panel entries.
    property int toolTimeoutMs: 20000
    property int toolOutputCap: 32768
    property int toolFloodKillBytes: 1048576
    property int toolKillGraceMs: 2000
    property int preflightMs: 2000
    // Run every job in its own systemd scope (see the header). Off, the bare
    // `timeout` wrapper is the whole fence.
    property bool scoped: true
    // Every job in a new session with no terminal (see the header). Off, the
    // job inherits the terminal.
    property bool detachTty: true
    // How long a call that may run sudo is given ON TOP of its own limit for
    // the face scan and the password -- and how long the helper waits for an
    // answer before sudo is told there is none.
    property int  sudoAuthWindowMs: 120000
    // A password request is shown only when the requester's parent is sudo
    // running as root. Off serves a stub sudo that is not setuid (a harness
    // sets it).
    property bool requireSudoParent: true
    // Where sudo's requests are asked: the shell's AuthBroker. A harness hands in
    // its own; null cancels every request at once (see `authNote`).
    property var broker: AuthBus.broker
    // howdy's mode and timeout for the toast's face line, bound by the host
    // from the shared HowdyConfig ("absent": no face line).
    property string howdyMode: "absent"
    property int    howdyTimeoutMs: 4000
    // The sudo shim's directory (first on every job's PATH), the helper sudo
    // runs for a password, and the binary the shim executes -- a harness
    // points the last at a stub through the job environment instead.
    readonly property string shimDir: root.dir + "/bin"
    readonly property string askpassPath: root.dir + "/askpass.py"

    // ---- Read-only state (frozen API) -------------------------------
    readonly property bool   ready: root._ready
    readonly property var    entries: root._entries
    readonly property var    errors: root._errors
    readonly property var    wireTools: root._wire
    readonly property var    grants: root._grants
    readonly property var    disabled: root._disabled
    readonly property var    policy: root._policy
    readonly property bool   running: root._job !== null
    readonly property string runningId: root._job ? (root._job.frozen.callId || "") : ""
    // The cgroup of this process's user manager (`/user.slice/user-N.slice/
    // user@N.service`), under which every job's scope lives; "" outside a
    // user session. `scopeState`: "unknown" until the one-time probe answers,
    // then "on" | "off".
    readonly property string cgroupRoot: root._cgroupRoot
    readonly property string scopeState: root._scopeState
    // sudo asking for a password inside the running job, verified (see the
    // header), or null: { id, callId, name, glyph, prompt, attempt, howdy,
    // detail, detailLang, detailLines, cwd, timeoutS, authS }. A new object
    // per request; `answerAuth` / `cancelAuth` take its id.
    readonly property var    authRequest: root._authPublic
    // One line for the reader while a request is being refused for want of
    // somewhere to ask (""), set when it happens and cleared with the next job.
    readonly property string authNote: root._authNote
    // Extra environment for every job, set by a harness (e.g.
    // LLM_SUDO_BIN). Never read from a tool entry.
    property var extraEnv: ({})
    // What llm.jsonc says: tools that are never offered, tools that ask first whatever the policy would let run (stricter only, see
    // LlmToolPolicy.stricter), whether a spoken command that only reads runs unasked, one tool's own environment and the value of an
    // argument the model left out ({ tool: { name: value } }).
    property var  offNames: []
    property var  askNames: []
    property bool voiceAutoRun: true
    property var  toolEnv: ({})
    property var  argDefaults: ({})
    onOffNamesChanged: root._rebuildWire()

    // `grantsChanged` (frozen API) is the `grants` property's own change signal.
    signal loaded()

    // ---- Internal ----------------------------------------------------------
    property bool _ready: false
    property var  _entries: []
    property var  _byName: ({})
    property var  _errors: []
    property var  _wire: []
    property var  _grants: []
    property var  _disabled: []
    // Tools the user switched ON although their file says `enabled:false`:
    // the Tools tab's checkbox is a lever in both directions.
    property var  _enabled: []
    property var  _probes: ({})
    property var  _texts: ({})          // file -> last non-empty text
    property var  _policy: root._defaultPolicy
    property bool _compileQueued: false
    property var  _job: null            // { frozen, cb, preflight, startAt, ... }
    property string _cgroupRoot: ""
    property string _scopeState: "unknown"
    property var  _authPublic: null
    property string _authNote: ""
    property string _askSock: ""
    readonly property string _jobPath: root.shimDir + ":" + (Quickshell.env("PATH") || "/usr/local/bin:/usr/bin:/bin")

    // The shipped policy, the fallback when policy.json is missing or broken
    // (a broken policy must make things ASK, never run free).
    readonly property var _defaultPolicy: ({
        format: "llm-tool-policy/1",
        alwaysAsk: [
            "(^|[;&|(])\\s*(sudo|doas|pkexec|su)\\b",
            "(^|[;&|(])\\s*(rm|rmdir|shred|wipefs|mkfs(\\.[a-z0-9]+)?|dd|chattr|chmod|chown|mount|umount)\\b",
            "(^|[;&|(])\\s*(reboot|shutdown|poweroff|halt|kexec)\\b",
            "(^|[;&|(])\\s*systemctl(\\s+-[A-Za-z-]+(=\\S+)?)*\\s+(stop|disable|mask|poweroff|reboot|halt|suspend|hibernate|kexec|kill)\\b",
            "(^|[;&|(])\\s*(kill|pkill|killall)\\b",
            "(^|[;&|(])\\s*git(\\s+-[A-Za-z-]+(=\\S+)?|\\s+-[cC]\\s+\\S+)*\\s+(push|reset|clean|rebase)\\b",
            "(^|[;&|(])\\s*(pacman|yay|paru)(\\s+\\S+)*?\\s+(-[A-Za-z]*[SRU]|--(sync|remove|upgrade|sysupgrade|refresh|noconfirm))",
            "(^|[;&|(])\\s*(sh|bash|zsh|dash|fish|ksh|python[0-9.]*|perl|node|ruby|lua|php|eval|exec|source|xargs|nohup|setsid|nice|ionice|timeout|watch|env|command|builtin|time|chrt|taskset|stdbuf|unbuffer|script|systemd-run|busybox)\\b",
            "(^|[;&|(])\\s*(curl|wget|ssh|scp|rsync|nc|ncat|socat)\\b",
            "(^|[;&|(])\\s*find\\b(?=.*\\s-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)\\b)",
            "(^|[;&|(])\\s*sed\\b(?=.*\\s-i)"],
        neverRun: [":\\(\\)\\s*\\{", "\\bmkfs(\\.[a-z0-9]+)?\\s+(-\\S+\\s+)*/dev/"],
        neverGrantWrite: ["~/.ssh", "~/.gnupg", "~/.password-store", "~/.config/quickshell/llm_tools", "~/.local/state/lares"],
        grantWriteRoots: ["~", "/tmp"],
        neverGrantHosts: ["localhost", "0.0.0.0/8", "127.0.0.0/8", "::1", "10.0.0.0/8", "100.64.0.0/10", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fe80::/10", "fc00::/7"],
        cwd: "~"
    })

    // =========================================================================
    //  Files
    // =========================================================================

    Instantiator {
        model: root.files
        delegate: FileView {
            required property string modelData
            path: root.dir + "/" + modelData
            watchChanges: true
            printErrors: false
            onFileChanged: reload()
            onLoaded: root._fileText(modelData, text())
            onTextChanged: root._fileText(modelData, text())
        }
    }

    FileView {
        id: _policyFile
        path: root.dir + "/policy.json"
        watchChanges: true
        printErrors: false
        onFileChanged: _policyFile.reload()
        onLoaded: root._policyText(_policyFile.text())
        onTextChanged: root._policyText(_policyFile.text())
    }

    onDirChanged: root._queueCompile()
    onFilesChanged: root._queueCompile()

    function _fileText(file, txt) {
        // A mid-save read is empty or truncated; the last good text stands.
        if (!txt || txt.length === 0) return;
        if (root._texts[file] === txt) return;
        const next = ({});
        for (const k in root._texts) next[k] = root._texts[k];
        next[file] = txt;
        root._texts = next;
        root._queueCompile();
    }

    function _policyText(txt) {
        if (!txt || txt.length === 0) return;
        let d = null;
        try { d = JSON.parse(txt); } catch (e) { d = null; }
        if (!d || typeof d !== "object") {
            console.warn("[llm tools] policy.json is not valid JSON; the shipped policy applies");
            root._policy = root._defaultPolicy;
            return;
        }
        const p = ({});
        for (const k in root._defaultPolicy) p[k] = root._defaultPolicy[k];
        for (const k2 in d) p[k2] = d[k2];
        root._policy = p;
    }

    function _queueCompile() {
        if (root._compileQueued) return;
        root._compileQueued = true;
        Qt.callLater(root._compile);
    }

    // Every file in `files` order; a name seen twice keeps its first entry
    // and names the second as a fault.
    function _compile() {
        root._compileQueued = false;
        const entries = [];
        const byName = ({});
        let errors = [];
        for (let i = 0; i < root.files.length; i++) {
            const f = root.files[i];
            const txt = root._texts[f];
            if (txt === undefined) continue;
            const r = Pol.compileFile(txt, f);
            errors = errors.concat(r.errors);
            for (let j = 0; j < r.entries.length; j++) {
                const e = r.entries[j];
                if (byName[e.name]) {
                    errors.push({ file: f, name: e.name, action: "",
                                  reason: f + ": " + e.name + " is already defined in " + byName[e.name].file });
                    continue;
                }
                byName[e.name] = e;
                entries.push(e);
            }
        }
        root._entries = entries;
        root._byName = byName;
        root._errors = errors;
        root._rebuildWire();
        if (errors.length > 0 && !root._ready)
            console.log("[llm tools] " + errors.length + " tool entr" + (errors.length === 1 ? "y" : "ies")
                        + " rejected: " + errors.map(function (x) { return x.reason; }).join(" | "));
        root._ready = true;
        root.loaded();
    }

    function _rebuildWire() {
        const w = [];
        for (let i = 0; i < root._entries.length; i++) {
            const e = root._entries[i];
            if (!root._offered(e)) continue;
            w.push(e.wire);
        }
        root._wire = w;
    }

    // =========================================================================
    //  Grants, disabled, probes -- the store sibling
    // =========================================================================

    Connections {
        target: root.store
        ignoreUnknownSignals: true
        function onToolStateChanged() { root._readStore(); }
    }

    onStoreChanged: root._readStore()

    function _readStore() {
        if (!root.store || !root.store.toolState) return;
        const st = root.store.toolState;
        root._grants = (st.grants || []).slice();
        root._disabled = (st.disabled || []).slice();
        root._enabled = (st.enabled || []).slice();
        root._probes = st.probes || ({});
        root._rebuildWire();
    }

    function _writeStore() {
        const obj = { version: 1, grants: root._grants, disabled: root._disabled, enabled: root._enabled, probes: root._probes };
        if (root.store && root.store.setToolState) root.store.setToolState(obj);
        else root._rebuildWire();
    }

    function _hasGrant(tool, key) {
        for (let i = 0; i < root._grants.length; i++)
            if (root._grants[i].tool === tool && root._grants[i].key === key) return true;
        return false;
    }

    // One record per key; a multi-segment command writes one per segment,
    // each labelled as its own rule (`wc -l …`).
    function remember(tool, keys, label) {
        const ks = keys || [];
        if (ks.length === 0) return;
        const next = root._grants.slice();
        let added = false;
        for (let i = 0; i < ks.length; i++) {
            if (root._hasGrant(tool, ks[i])) continue;
            const lab = (ks.length === 1) ? String(label || ks[i]) : (ks[i] + " …");
            next.push({ tool: tool, key: ks[i], label: lab, at: Date.now(), uses: 0 });
            added = true;
        }
        if (!added) return;
        root._grants = next;
        root._writeStore();
    }

    function forget(tool, key) {
        const next = [];
        for (let i = 0; i < root._grants.length; i++)
            if (!(root._grants[i].tool === tool && root._grants[i].key === key)) next.push(root._grants[i]);
        if (next.length === root._grants.length) return;
        root._grants = next;
        root._writeStore();
    }

    function forgetAll() {
        if (root._grants.length === 0) return;
        root._grants = [];
        root._writeStore();
    }

    function _countUse(tool, keys) {
        const next = root._grants.slice();
        let touched = false;
        for (let i = 0; i < next.length; i++) {
            if (next[i].tool !== tool || (keys || []).indexOf(next[i].key) < 0) continue;
            const g = ({});
            for (const k in next[i]) g[k] = next[i][k];
            g.uses = (g.uses || 0) + 1;
            next[i] = g;
            touched = true;
        }
        if (!touched) return;
        root._grants = next;
        root._writeStore();
    }

    // setEnabled(name, on): the Tools tab's lever, in both directions. A tool
    // whose file says `enabled:false` is switched on through `enabled[]` in
    // the store; any other is switched off through `disabled[]` (writing a
    // file-disabled tool into `disabled[]` would change nothing).
    function setEnabled(name, on) {
        const e = root.lookup(name);
        if (!e) return;
        if (root.isOffered(name) === !!on) return;
        if (!e.enabled) {
            const next = root._enabled.slice();
            const i = next.indexOf(name);
            if (on && i < 0) next.push(name);
            if (!on && i >= 0) next.splice(i, 1);
            root._enabled = next;
        } else {
            const next2 = root._disabled.slice();
            const j = next2.indexOf(name);
            if (on && j >= 0) next2.splice(j, 1);
            if (!on && j < 0) next2.push(name);
            root._disabled = next2;
        }
        root._writeStore();
    }

    // Whether a tool would ride on the wire: its file's `enabled` with the
    // store's overrides applied.
    function isOffered(name) {
        return root._offered(root.lookup(name));
    }

    function probeStateOf(digest) {
        const r = root._probes[digest];
        return r ? r : null;
    }

    function recordProbe(digest, record) {
        if (!digest) return;
        const next = ({});
        for (const k in root._probes) next[k] = root._probes[k];
        next[digest] = record;
        root._probes = next;
        root._writeStore();
    }

    // =========================================================================
    //  Lookup, validation, summary
    // =========================================================================

    function lookup(name) {
        const e = root._byName[name];
        return e ? e : null;
    }

    function _offered(e) {
        if (!e) return false;
        if (root.offNames.indexOf(e.name) >= 0) return false;
        if (root._disabled.indexOf(e.name) >= 0) return false;
        return e.enabled || root._enabled.indexOf(e.name) >= 0;
    }

    // validate(name, args) -> { ok, error, norm, action, ignored }
    function validate(name, args) {
        const e = root.lookup(name);
        if (!e || !root._offered(e))
            return { ok: false, error: "unknown tool " + name, norm: null, action: "", ignored: [] };
        if (args === null || typeof args !== "object" || Array.isArray(args))
            return { ok: false, error: "arguments are not an object", norm: null, action: "", ignored: [] };
        const spec = Pol.resolveAction(e, args);
        if (!spec) {
            const keys = e.actions ? Object.keys(e.actions) : [];
            return { ok: false, error: "unknown action " + JSON.stringify(args.action === undefined ? "" : args.action)
                                     + " (one of " + keys.join(", ") + ")", norm: null, action: "", ignored: [] };
        }
        const a = Object.assign({}, root.argDefaults[name]);
        for (const k in args) if (k !== "action" || !e.actions) a[k] = args[k];
        const v = Pol.validateArgs(spec.spec, a);
        if (!v.ok) return { ok: false, error: v.error, norm: null, action: spec.key, ignored: v.ignored };
        return { ok: true, error: "", norm: v.norm, action: spec.key, ignored: v.ignored };
    }

    function _specOf(name, norm, action) {
        const e = root.lookup(name);
        if (!e) return null;
        const args = ({});
        for (const k in (norm || {})) args[k] = norm[k];
        if (e.actions) args.action = action || "";
        return Pol.resolveAction(e, args);
    }

    function summarise(name, norm, action) {
        const spec = root._specOf(name, norm, action);
        if (!spec) return name;
        let s = Pol.fillTemplate(spec.summary, norm, root.home);
        if (s.length > 80) s = s.substring(0, 79) + "…";
        return s;
    }

    function _renderCtx(spec, e) {
        const timeoutMs = spec.timeoutMs > 0 ? spec.timeoutMs : root.toolTimeoutMs;
        const outputCap = spec.outputCap > 0 ? spec.outputCap : root.toolOutputCap;
        return { home: root.home, dir: root.dir, outputCap: outputCap,
                 timeoutS: Math.max(1, Math.ceil(timeoutMs / 1000)), timeoutMs: timeoutMs,
                 cwd: root._cwdOf(e), types: root._typesOf(spec) };
    }

    function _typesOf(spec) {
        const t = ({});
        const props = spec.spec.properties || {};
        for (const k in props) t[k] = props[k].type;
        return t;
    }

    function _cwdOf(e) {
        const c = (e && e.cwd) ? e.cwd : (root._policy.cwd || "~");
        return Pol.expandTilde(c, root.home);
    }

    // The path a write resolves to LEXICALLY: `~` expanded, `.`/`..`
    // collapsed. The real path (symlinks followed) comes from the entry's
    // preflight and rides in `facts.resolvedPath`; this is the fallback for
    // an entry without one, and the "what was typed" half of the reason line
    // when the two differ.
    function _lexicalPath(norm, base) {
        if (!norm || norm.path === undefined) return "";
        let p = Pol.expandTilde(String(norm.path), root.home);
        if (p.charAt(0) !== "/") p = (base || root.home) + "/" + p;
        return Pol.normalizePath(p);
    }

    // The facts a decision and a freeze share: the resolved path when the
    // preflight measured one, else the lexical path -- unless the entry
    // DECLARES a preflight and it gave no path, in which case the resolved
    // path is "" and a `dir` key cannot be made (asks every time). Hand the
    // same object to decide() and freeze() so the key, the confirmation and
    // the argv agree byte for byte. `base` is the directory a relative path is
    // taken against: the home directory, or where a spoken conversation was asked.
    function factsFor(name, norm, preflight, base) {
        const e = root.lookup(name);
        const lex = root._lexicalPath(norm, base);
        const f = { lexicalPath: lex, resolvedPath: lex, size: -1, isNew: true, preflight: false };
        if (e && e.preflight) {
            f.preflight = true;
            f.resolvedPath = (preflight && preflight.resolvedPath) ? String(preflight.resolvedPath) : "";
            if (preflight) { f.size = preflight.size; f.isNew = preflight.isNew; }
        }
        return f;
    }

    // The argument object the argv is rendered from: `path` replaced by the
    // resolved path when the preflight found one, so write.py is handed the
    // real directory and the confirmation shows the bytes that run.
    function _effectiveNorm(norm, facts) {
        if (!facts || !facts.resolvedPath || !norm || norm.path === undefined) return norm;
        const n = ({});
        for (const k in norm) n[k] = norm[k];
        n.path = facts.resolvedPath;
        return n;
    }

    // =========================================================================
    //  The policy decision
    // =========================================================================

    // decide(name, norm, action, facts) ->
    //   { mode: "free"|"auto"|"granted"|"ask"|"refused", grantable, grantKeys, grantLabel, reason, parts }
    // "auto" is a command line every part of which is read-only (LlmShell.js);
    // `parts` (shell lines only) lists each simple command with its own state.
    function decide(name, norm, action, facts) {
        return Pol.stricter(root._decide(name, norm, action, facts), root.askNames, name);
    }
    function _decide(name, norm, action, facts) {
        const e = root.lookup(name);
        const spec = root._specOf(name, norm, action);
        const out = { mode: "ask", grantable: false, grantKeys: [], grantLabel: "", reason: "", parts: [] };
        if (!e || !spec) { out.mode = "refused"; out.reason = "unknown tool"; return out; }
        const pol = root._policy;
        if (facts && facts.handsFree) return root._decideHandsFree(name, e, spec, norm, facts, out);
        if (e.shell) {
            // The line is read the way bash reads it, command by command
            // (LlmShell.js): a read-only command and a command under a rule
            // pass, anything else asks, and the answer says which part.
            const g = Pol.analyzeShell(String(norm.command || ""), pol, { hasGrant: function (k) { return root._hasGrant(name, k); } });
            out.parts = g.parts;
            if (g.mode === "refused") { out.mode = "refused"; out.reason = "refused by policy"; return out; }
            out.reason = g.reason;
            out.grantKeys = g.keys;
            out.grantLabel = g.label;
            out.grantable = g.grantable;
            out.mode = g.mode;
            return out;
        }
        const f = facts || root.factsFor(name, norm, null);
        const r = Pol.renderArgv(spec.argv, root._effectiveNorm(norm, f), root._renderCtx(spec, e));
        const argv = r.argv || [];
        const line = Pol.policyLineOf(argv, root.dir);
        if (Pol.matchPolicy(line, pol.neverRun)) { out.mode = "refused"; out.reason = "refused by policy"; return out; }
        if (spec.kind === "read") { out.mode = "free"; return out; }
        const ask = Pol.matchPolicy(line, pol.alwaysAsk);
        if (ask) { out.mode = "ask"; out.reason = Pol.hitWords(ask.match) + " — always asks"; return out; }
        if (spec.allow === "never" || spec.grantable === false) { out.mode = "ask"; out.reason = "asks every time"; return out; }
        // A path that resolved somewhere other than what was typed is said
        // on the reason line, whatever else the decision is.
        const linked = (f.resolvedPath && f.lexicalPath && f.resolvedPath !== f.lexicalPath)
            ? (root._shortHome(f.lexicalPath) + " is a link — the real path is shown") : "";
        if (spec.allow === "dir" && f.preflight && !f.resolvedPath) {
            out.mode = "ask"; out.reason = "the path could not be resolved — asks every time"; return out;
        }
        const k = Pol.keysFor(spec.allow, e, spec.key, norm, argv, f, pol, root.home);
        if (k.keys === null) { out.mode = "ask"; out.reason = linked ? linked + " · " + k.reason : k.reason; return out; }
        out.grantKeys = k.keys;
        out.grantLabel = k.label;
        out.grantable = true;
        if (spec.allow === "host") out.reason = "a URL can carry data off this machine — asks once per host";
        if (linked) out.reason = linked;
        let have = true;
        for (let j = 0; j < k.keys.length; j++) if (!root._hasGrant(name, k.keys[j])) have = false;
        out.mode = have ? "granted" : "ask";
        return out;
    }

    // THE SPOKEN TURN'S DECISION (see the header): free, auto with the argv that runs, ask -- never granted, never grantable.
    function _decideHandsFree(name, e, spec, norm, f, out) {
        const pol = root._policy;
        if (e.shell) {
            const line = String(norm.command || "");
            if (Pol.matchPolicy(line, pol.neverRun)) { out.mode = "refused"; out.reason = "refused by policy"; return out; }
            const v = root._voiceCheck(line, f);
            if (v.ok && v.argv.length > 0 && root.voiceAutoRun) { out.mode = "auto"; return out; }
            out.reason = v.ok && v.argv.length > 0 ? "spoken request: every command asks"
                : "spoken request: only a plain read runs without your OK — " + (v.why || "its paths could not be checked");
            return out;
        }
        const r = Pol.renderArgv(spec.argv, root._effectiveNorm(norm, f), root._renderCtx(spec, e));
        if (Pol.matchPolicy(Pol.policyLineOf(r.argv || [], root.dir), pol.neverRun)) { out.mode = "refused"; out.reason = "refused by policy"; return out; }
        const t = Voice.toolVerdict(name, spec.kind, norm, { home: root.home, cwd: f.cwd || root.home, resolved: f.resolved || null, tainted: !!f.tainted });
        out.mode = t.mode;
        out.reason = t.reason;
        return out;
    }

    // The spoken run_command at its final stage: the paths as the voice preflight resolved them. Pure, so decide() and freeze()
    // reach the same answer from the same facts.
    function _voiceCheck(line, f) {
        if (!f || !f.resolved) return { ok: false, why: "its paths were not checked", argv: [] };
        return Voice.check(line, { home: root.home, cwd: f.lexCwd || f.cwd || root.home, realCwd: f.cwd || root.home,
                                   resolved: f.resolved, filters: f.filters || [] });
    }

    // THE VOICE PREFLIGHT: the conversation's directory and the words a spoken call names, resolved on disk (and, for git, the
    // repository's own filter drivers). `cwd` "" means the user's home.
    function voicePreflightArgv(cwd, words, git) {
        return ["python3", "-I", root.dir + "/voicepaths.py"].concat(git ? ["--git"] : [])
               .concat(["--cwd", String(cwd || ""), "--"]).concat(words || []);
    }
    // Its answer, or null (no JSON, an error): a decision that needs it then asks.
    function parseVoicePreflight(out, code) {
        if (code !== 0) return null;
        let d = null;
        try { d = JSON.parse(String(out || "").trim()); } catch (err) { return null; }
        if (!d || typeof d !== "object" || typeof d.cwd !== "string" || d.cwd.charAt(0) !== "/" || typeof d.paths !== "object")
            return null;
        return { cwd: d.cwd, given: !!d.given, paths: d.paths || ({}), filters: Array.isArray(d.filters) ? d.filters.map(String) : [] };
    }

    function _shortHome(p) {
        const s = String(p || "");
        if (root.home.length > 0 && s === root.home) return "~";
        if (root.home.length > 0 && s.indexOf(root.home + "/") === 0) return "~" + s.substring(root.home.length);
        return s;
    }

    // =========================================================================
    //  The frozen call
    // =========================================================================

    // The entry's preflight argv for a call, rendered, or null when it has
    // none. The service runs it BEFORE the decision (`preflight()`), and
    // hands what it said to decide() and freeze() as `facts`.
    function preflightArgvOf(name, norm, action) {
        const e = root.lookup(name);
        const spec = root._specOf(name, norm, action);
        if (!e || !spec || !e.preflight) return null;
        const pr = Pol.renderArgv(e.preflight, norm, root._renderCtx(spec, e));
        return pr.error ? null : pr.argv;
    }

    // freeze(callId, name, norm, action, facts) -> the object the
    // confirmation renders and the runner executes. Built once; `decision`
    // is "" until the service records what was decided, and run() refuses it
    // until then.
    function freeze(callId, name, norm, action, facts) {
        const e = root.lookup(name);
        const spec = root._specOf(name, norm, action);
        if (!e || !spec) throw new Error("freeze: unknown tool " + name);
        const ctx = root._renderCtx(spec, e);
        const f = facts || root.factsFor(name, norm, null);
        // A conversation that began spoken runs where it was asked (the voice preflight's resolved directory).
        if (f.cwd) ctx.cwd = f.cwd;
        const normEff = root._effectiveNorm(norm, f);
        const r = Pol.renderArgv(spec.argv, normEff, ctx);
        if (r.error) throw new Error("freeze: " + r.error);
        let argv = r.argv;
        let stdin = null;
        if (e.stdin) {
            const ph = Pol.placeholdersOf(e.stdin)[0];
            const v = norm[ph.name];
            stdin = (v === undefined || v === null) ? "" : String(v);
        }
        let det = Pol.detailFor(spec.detail, normEff, argv, f, stdin);
        // A SPOKEN run_command that passed runs as the argv that was judged, not through bash, with its stdin closed at once;
        // the detail shows exactly that argv. A spoken search never opens a secret by its name.
        let direct = false;
        if (f.handsFree && e.shell) {
            const vc = root._voiceCheck(String(norm.command || ""), f);
            if (vc.ok && vc.argv.length > 0) {
                argv = vc.argv;
                stdin = "";
                direct = true;
                det = { text: Voice.quoteArgv(argv), lang: "sh" };
            }
        } else if (f.handsFree && name === "search_files") {
            const t = Voice.toolVerdict(name, spec.kind, norm, { home: root.home, cwd: f.cwd || root.home, resolved: f.resolved || null, tainted: !!f.tainted });
            const at = argv.indexOf("-e");
            if (t.mode === "free" && at > 0) {
                const globs = [];
                for (let g = 0; g < t.extraGlobs.length; g++) globs.push("-g", t.extraGlobs[g]);
                argv = argv.slice(0, at).concat(globs).concat(argv.slice(at));
                det = Pol.detailFor(spec.detail, normEff, argv, f, stdin);
            }
        }
        // A shell call that may run sudo gets the authentication window on
        // top of its own limit (see Pol.mayElevate); `commandTimeoutS` is
        // the limit the call itself asked for, for the confirmation's words.
        const authS = (e.shell && !direct && Pol.mayElevate(argv[argv.length - 1]))
            ? Math.ceil(root.sudoAuthWindowMs / 1000) : 0;
        return {
            callId: String(callId), name: name, action: spec.key, kind: spec.kind,
            argv: ["timeout", "-k", String(root.toolKillGraceMs / 1000), String(ctx.timeoutS + authS)].concat(argv),
            toolArgv: argv,
            stdin: stdin, cwd: ctx.cwd, timeoutMs: ctx.timeoutMs + authS * 1000, timeoutS: ctx.timeoutS + authS,
            commandTimeoutS: ctx.timeoutS, authS: authS,
            outputCap: ctx.outputCap, result: spec.result,
            // Carried on the frozen call because that is the object the
            // runner still has when the child is killed; the entry it came
            // from is not in scope there.
            retryHint: e.retryHint || "",
            detail: det.text, detailLang: det.lang, shownDetail: Pol.visibleControls(det.text),
            detailLines: det.text.split("\n").length,
            argsText: Pol.argsTextFor(spec.detail, normEff, argv, f, stdin),
            summary: root.summarise(name, normEff, action),
            progress: Pol.fillTemplate(spec.progress, norm, root.home),
            glyph: e.glyph || "",
            resolvedPath: f.resolvedPath,
            lexicalPath: f.lexicalPath,
            fileSize: f.size, fileIsNew: f.isNew,
            stdinBytes: stdin === null ? 0 : Pol.utf8Length(stdin),
            grantKeys: [],
            decision: "",
            ran: false
        };
    }

    // =========================================================================
    //  The runner
    // =========================================================================

    // The user manager's cgroup, read once at a static path (a FileView
    // reads only its FIRST path): every job's scope lives under
    // `<root>/app.slice/`.
    FileView {
        id: _selfCgroup
        path: "/proc/self/cgroup"
        blockLoading: true
        printErrors: false
    }
    // The reaper: what is still alive in a job's scope, killed, counted --
    // a bash child rather than FileViews over cgroupfs, because a scope with
    // nothing left in it is being collected by systemd at that very moment
    // and a read of its files then fails in a way Quickshell reports
    // unconditionally (measured: two WARNs in thirty jobs). One at a time;
    // callers queue.
    readonly property string _reapScript:
        'd=$1; n=0\n'
        + 'if [ -e "$d/cgroup.procs" ]; then n=$(wc -l < "$d/cgroup.procs" 2>/dev/null || echo 0); fi\n'
        + 'n=${n:-0}\n'
        + 'if [ "$n" -gt 0 ]; then echo 1 > "$d/cgroup.kill" 2>/dev/null; fi\n'
        + 'echo "$n"'
    property var _reapQueue: []          // [{ dir, cb }]
    property var _reapCurrent: null
    Process {
        id: _reapProc
        running: false
        stdout: StdioCollector { id: _reapOut; waitForEnd: true }
    }
    Connections {
        target: _reapProc
        function onExited(exitCode, exitStatus) { root._reapDone(parseInt(String(_reapOut.text).trim(), 10) || 0); }
        function onRunningChanged() { if (!_reapProc.running && root._reapCurrent && !root._reapCurrent.started) root._reapDone(0); }
        function onStarted() { if (root._reapCurrent) root._reapCurrent.started = true; }
    }
    function _reapDone(n) {
        const cur = root._reapCurrent;
        if (!cur) return;
        root._reapCurrent = null;
        root._reapPump();
        try { cur.cb(n); } catch (e) { console.warn("[llm tools] reap callback threw: " + e); }
    }
    function _reapPump() {
        if (root._reapCurrent || root._reapQueue.length === 0) return;
        const next = root._reapQueue.shift();
        root._reapCurrent = { cb: next.cb, started: false };
        _reapProc.command = ["bash", "-c", root._reapScript, "reap", next.dir];
        _reapProc.running = true;
    }
    // The one-time probe: can this session make a scope at all? Its own
    // failed start (no systemd-run) is answered like a non-zero exit.
    Process {
        id: _scopeProbe
        running: false
        command: ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--slice=app.slice", "--expand-environment=no", "true"]
        onStarted: root._scopeProbeStarted = true
    }
    property bool _scopeProbeStarted: false
    Connections {
        target: _scopeProbe
        function onExited(exitCode, exitStatus) { root._scopeAnswer(exitCode === 0 && exitStatus === 0); }
        function onRunningChanged() { if (!_scopeProbe.running && !root._scopeProbeStarted) root._scopeAnswer(false); }
    }
    function _scopeAnswer(ok) {
        if (root._scopeState !== "unknown") return;
        root._scopeState = ok ? "on" : "off";
        if (!ok) console.log("[llm tools] no user systemd scope for tool jobs; the timeout wrapper is the only fence");
    }
    // This process's pid, for a socket path no other quickshell shares (the
    // user's own shell and a mockup run side by side).
    FileView {
        id: _selfStat
        path: "/proc/self/stat"
        blockLoading: true
        printErrors: false
    }
    Component.onCompleted: {
        const pid = parseInt(String(_selfStat.text() || "").split(" ")[0], 10) || 0;
        root._askSock = (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/lares-llm-askpass-" + pid + ".sock";
        root._readStore();
        const m = /^0::(\/user\.slice\/user-\d+\.slice\/user@\d+\.service)/m.exec(_selfCgroup.text() || "");
        root._cgroupRoot = m ? m[1] : "";
        if (root._cgroupRoot.length > 0) _scopeProbe.running = true;
        else root._scopeAnswer(false);
    }

    Process {
        id: _proc
        running: false
        stdout: StdioCollector {
            id: _outC
            waitForEnd: false
            onDataChanged: root._onOut()
        }
        stderr: StdioCollector {
            id: _errC
            waitForEnd: false
            onDataChanged: root._onErr()
        }
        onStarted: root._onProcStarted()
    }
    Connections {
        target: _proc
        // A Connections handler rather than an inline onExited: qmllint cannot
        // see QProcess::ExitStatus and warns on every inline one (Theme.qml).
        function onExited(exitCode, exitStatus) { root._onProcExited(exitCode, exitStatus); }
        // A child that never started: `running` falls with no `started`
        // before it and no `exited` after it (Quickshell drops the QProcess
        // on FailedToStart). Settled as `failed`, deferred so the callback
        // never runs inside the `running = true` assignment.
        function onRunningChanged() { if (!_proc.running) root._onProcStopped(); }
    }

    // Belt under timeout's braces: if the job is somehow still here past
    // timeout + grace + 1 s, its whole cgroup dies; a job whose process never
    // ran is settled.
    Timer {
        id: _belt
        repeat: false
        onTriggered: {
            const j = root._job;
            if (!j || j.exited) return;
            j.belted = true;
            if (!_proc.running && !j.started) { root._onProcStopped(); return; }
            root._reap(j, function () {});
            _proc.signal(9);
        }
    }
    // kill() and the flood kill: TERM now, then the whole cgroup after the
    // grace (never `timeout` alone: that raced timeout's own -k and could
    // orphan a TERM-immune child).
    Timer {
        id: _killGrace
        repeat: false
        onTriggered: { if (root._job && !root._job.exited) { root._reap(root._job, function () {}); _proc.signal(9); } }
    }

    function _guard(frozen) {
        if (root._job) throw new Error("run: a tool is already running (" + root.runningId + ")");
        if (!frozen || typeof frozen !== "object" || !Array.isArray(frozen.argv))
            throw new Error("run: not a frozen call");
        if (frozen.ran) throw new Error("run: call " + frozen.callId + " already ran");
        const d = String(frozen.decision || "");
        // A read runs free, or on the user's yes where a spoken turn asked for it (LlmVoicePolicy.toolVerdict).
        const ok = (frozen.kind === "read") ? (d === "free" || d === "yes")
                 : (d === "granted" || d === "auto" || d === "yes" || d === "always");
        if (!ok) throw new Error("run: call " + frozen.callId + " is not decided (" + JSON.stringify(d) + ")");
    }

    // run(frozen, cb): cb(outcome) once, on exit. Throws on a bypass attempt.
    function run(frozen, cb) {
        root._guard(frozen);
        frozen.ran = true;
        if (frozen.decision === "granted" && frozen.grantKeys && frozen.grantKeys.length > 0)
            root._countUse(frozen.name, frozen.grantKeys);
        root._start(frozen, cb, false);
    }

    // preflight(name, argv, cwd, cb): an entry's own read argv (write_file's
    // `write.py --preflight`), run before the decision, 2 s, free;
    // cb(stdoutText, exitCode). Not a tool call: no guard, no trailer, but
    // the same one-child rule and the same fence.
    function preflight(name, argv, cwd, cb, outputCap) {
        if (root._job) throw new Error("preflight: a tool is already running");
        if (!Array.isArray(argv) || argv.length === 0) { cb("", 1); return; }
        const s = Math.max(1, Math.ceil(root.preflightMs / 1000));
        const pf = {
            callId: String(name) + "_pre", name: name, kind: "read",
            argv: ["timeout", "-k", "1", String(s)].concat(argv),
            stdin: null, cwd: cwd || root.home, timeoutMs: root.preflightMs, timeoutS: s,
            outputCap: outputCap > 0 ? outputCap : 4096, result: "text"
        };
        root._start(pf, cb, true);
    }

    function _scopePrefix(callId, timeoutS) {
        if (!root.scoped || root._scopeState !== "on" || root._cgroupRoot.length === 0) return null;
        const graceS = Math.max(1, Math.ceil(root.toolKillGraceMs / 1000));
        const unit = "llm-tool-" + String(callId).replace(/[^A-Za-z0-9_.:-]/g, "-") + "-" + Date.now();
        return { unit: unit,
                 argv: ["systemd-run", "--user", "--scope", "--quiet", "--collect", "--slice=app.slice",
                        "--expand-environment=no", "-u", unit,
                        "-p", "RuntimeMaxSec=" + (timeoutS + graceS + 1), "-p", "TimeoutStopSec=" + graceS] };
    }

    function _start(frozen, cb, isPreflight) {
        root._authNote = "";
        const isImage = frozen.result === "image";
        const cap = frozen.outputCap;
        const sc = root._scopePrefix(frozen.callId, frozen.timeoutS);
        root._job = {
            frozen: frozen, cb: cb, preflight: isPreflight,
            unit: sc ? sc.unit : "",
            startAt: Date.now(), outLen: 0, errLen: 0,
            headCap: isImage ? cap : Math.floor(cap * 0.75),
            tailCap: isImage ? 0 : (cap - Math.floor(cap * 0.75)),
            headParts: [], headBytes: 0, tailParts: [], tailBytes: 0,
            bytes: 0, lines: 0, lastNl: true, nul: false, dec: Pol.utf8Decoder(),
            err: "", errBytes: 0, flood: false, killed: false, belted: false,
            started: false, failedStart: false, exited: false,
            floodAt: Math.max(root.toolFloodKillBytes, cap)
        };
        const detach = root.detachTty ? ["setsid", "-w"] : [];
        _proc.command = (sc ? sc.argv : []).concat(detach).concat(frozen.argv);
        _proc.workingDirectory = frozen.cwd || root.home;
        const env = ({ LLM_TOOL: "1", PATH: root._jobPath, SUDO_ASKPASS: root.askpassPath,
                       LLM_ASKPASS_SOCKET: root._askSock,
                       LLM_ASKPASS_TIMEOUT: String(Math.ceil(root.sudoAuthWindowMs / 1000)) });
        for (const k in root.extraEnv) env[k] = String(root.extraEnv[k]);
        const own = root.toolEnv[frozen.name] || ({});
        for (const k in own) env[k] = String(own[k]);
        _proc.environment = env;
        _proc.clearEnvironment = false;
        _proc.stdinEnabled = frozen.stdin !== null && frozen.stdin !== undefined;
        _belt.interval = frozen.timeoutMs + root.toolKillGraceMs + 1000;
        _belt.restart();
        _proc.running = true;
    }

    function _onProcStarted() {
        const j = root._job;
        if (!j) return;
        j.started = true;
        const s = j.frozen.stdin;
        if (s !== null && s !== undefined) {
            _proc.write(s);
            // Closing the write channel is what lets `wl-copy`, `write.py`
            // and every other stdin reader see EOF.
            _proc.stdinEnabled = false;
        }
    }

    function _onProcStopped() {
        const j = root._job;
        if (!j || j.exited || j.started || j.failedStart) return;
        j.failedStart = true;
        Qt.callLater(function () { if (root._job === j && !j.exited) root._onProcExited(-1, 1); });
    }

    // Every arrival: the NEW bytes of the collector's byte array, never its
    // decoded text.
    function _onOut() {
        const j = root._job;
        const d = _outC.data;
        if (!j || !d || d.byteLength <= j.outLen) return;
        const u8 = new Uint8Array(d, j.outLen);
        j.outLen = d.byteLength;
        root._take(j, u8);
    }

    function _onErr() {
        const j = root._job;
        const d = _errC.data;
        if (!j || !d || d.byteLength <= j.errLen) return;
        j.errBytes += d.byteLength - j.errLen;
        j.errLen = d.byteLength;
        // stderr rides under the result, capped at 4 KB (the tail: the last
        // line of a traceback is the one that says why).
        j.err = Pol.utf8Suffix(_errC.text, 4096);
        if (j.errBytes + j.bytes > j.floodAt && !j.flood) root._floodKill(j);
    }

    function _take(j, u8) {
        const n = u8.length;
        j.bytes += n;
        for (let i = 0; i < n; i++) {
            const b = u8[i];
            if (b === 10) j.lines++;
            else if (b === 0) j.nul = true;
        }
        j.lastNl = u8[n - 1] === 10;
        j.dec.push(u8, false);
        let rest = u8;
        if (j.headBytes < j.headCap) {
            const take = Math.min(j.headCap - j.headBytes, n);
            j.headParts.push(u8.slice(0, take));
            j.headBytes += take;
            rest = take < n ? u8.subarray(take) : null;
        }
        if (rest && rest.length > 0 && j.tailCap > 0) {
            if (rest.length >= j.tailCap) {
                j.tailParts = [rest.slice(rest.length - j.tailCap)];
                j.tailBytes = j.tailCap;
            } else {
                j.tailParts.push(rest.slice());
                j.tailBytes += rest.length;
                while (j.tailBytes > j.tailCap) {
                    const first = j.tailParts[0];
                    const over = j.tailBytes - j.tailCap;
                    if (first.length <= over) { j.tailParts.shift(); j.tailBytes -= first.length; }
                    else { j.tailParts[0] = first.subarray(over); j.tailBytes -= over; }
                }
            }
        }
        if (j.bytes > j.floodAt && !j.flood) root._floodKill(j);
    }

    // TERM to `timeout`, which forwards it to the child's process group;
    // the whole cgroup after the grace if anything is left.
    function _floodKill(j) {
        j.flood = true;
        _proc.signal(15);
        _killGrace.interval = root.toolKillGraceMs;
        _killGrace.restart();
    }

    function kill() {
        const j = root._job;
        if (!j) return;
        j.killed = true;
        // A password request standing is answered "no" FIRST, on our side of
        // the socket: a helper killed with the job would close it from its
        // end, and Quickshell logs every such close as a socket error.
        _askpass.cancel("");
        _proc.signal(15);
        _killGrace.interval = root.toolKillGraceMs;
        _killGrace.restart();
    }

    // _reap(j, cb): what is still alive in the job's scope is killed and
    // counted; cb(count). cb(0) at once without a scope. A scope already
    // gone (`--collect` removes an empty one) counts 0.
    function _reap(j, cb) {
        if (!j || !j.unit || root._cgroupRoot.length === 0) { cb(0); return; }
        const dir = "/sys/fs/cgroup" + root._cgroupRoot + "/app.slice/" + j.unit + ".scope";
        root._reapQueue.push({ dir: dir, cb: cb });
        root._reapPump();
    }

    function _onProcExited(code, status) {
        const j = root._job;
        if (!j || j.exited) return;
        j.exited = true;
        _belt.stop();
        _killGrace.stop();
        const ms = Date.now() - j.startAt;
        // Whatever the call left behind dies with its cgroup, counted; the
        // job stays `running` until that has happened, so nothing else can
        // start in the gap.
        root._reap(j, function (survivors) { root._finishJob(j, code, status, ms, survivors); });
    }

    function _finishJob(j, code, status, ms, survivors) {
        if (root._job === j) root._job = null;
        const f = j.frozen;
        // The head, cut on a character; the tail from its first whole
        // character; a character the child cut in half at its very end is
        // counted in `bytes` and shown nowhere.
        const hd = Pol.utf8Decoder();
        const head = hd.push(Pol.concatBytes(j.headParts, j.headBytes), true);
        const keptHead = j.headBytes - hd.pending;
        const tailAll = Pol.concatBytes(j.tailParts, j.tailBytes);
        const skip = Pol.firstCharStart(tailAll);
        const td = Pol.utf8Decoder();
        const tail = td.push(tailAll.subarray(skip), true);
        const keptTail = Math.max(0, tailAll.length - skip - td.pending);
        if (j.preflight) {
            try { j.cb(head, code); } catch (e) { console.warn("[llm tools] preflight callback threw: " + e); }
            return;
        }
        const lines = j.lines + ((j.bytes > 0 && !j.lastNl) ? 1 : 0);
        const cut = j.tailCap > 0 && j.bytes > j.headBytes;
        let st;
        if (j.killed) st = "cancelled";
        else if (j.flood) st = "flood";
        else if (j.failedStart) st = "failed";
        else if (code === 124 || ((code === 137 || code === 9 || status !== 0) && (j.belted || ms >= f.timeoutMs - 20))) st = "timedOut";
        else st = (code === 0 && status === 0) ? "done" : "failed";
        let stderr = j.err;
        if (j.failedStart && stderr.length === 0)
            stderr = "could not start: the working directory " + (f.cwd || root.home) + " may not exist, or " + String(f.argv[0]) + " was not found";
        const out = {
            status: st, exitCode: code, ms: ms, bytes: j.bytes, lines: lines,
            truncated: cut || j.flood, keptHead: cut ? keptHead : 0,
            keptTail: cut ? keptTail : 0, survivors: survivors,
            stderr: stderr, image: "", imageW: 0, imageH: 0, thumbB64: "", result: "", trailer: ""
        };
        let imageNote = "";
        if (f.result === "image" && st === "done") {
            let d = null;
            try { d = JSON.parse(head.trim()); } catch (e) { d = null; }
            if (!d || typeof d.b64 !== "string" || d.b64.length === 0) {
                out.status = "failed";
                if (out.stderr.length === 0) out.stderr = "the screenshot helper printed no picture";
            } else {
                out.image = d.b64;
                out.imageW = d.w || 0;
                out.imageH = d.h || 0;
                out.thumbB64 = d.thumbB64 || "";
                const now = new Date();
                const hh = function (n) { return (n < 10 ? "0" : "") + n; };
                const scaled = (d.fullW && d.fullW !== d.w) ? (d.fullW + "×" + d.fullH + " scaled to " + d.w + "×" + d.h) : (d.w + "×" + d.h);
                imageNote = "Screenshot of " + (f.action === "region" || (f.toolArgv && f.toolArgv.indexOf("region") >= 0) ? "a selected region" : "the whole screen")
                          + ", " + scaled + ", taken " + hh(now.getHours()) + ":" + hh(now.getMinutes()) + ":" + hh(now.getSeconds())
                          + ". The picture follows.";
                out.bytes = 0; out.lines = 1; out.truncated = false; out.keptHead = 0; out.keptTail = 0;
            }
        }
        const c = Pol.composeResult(f.name, {
            status: out.status, exitCode: code, ms: ms, bytes: out.bytes, lines: out.lines,
            head: head, tail: cut ? tail : "", cut: cut,
            keptHead: out.keptHead, keptTail: out.keptTail, stderr: out.stderr,
            binary: (j.nul || j.dec.invalid) && !out.image, ignored: f.ignored || [], timeoutS: f.timeoutS,
            retryHint: f.retryHint || "",
            imageNote: imageNote, survivors: survivors
        });
        out.result = c.result;
        out.trailer = c.trailer;
        try { j.cb(out); } catch (e) { console.warn("[llm tools] run callback threw: " + e); }
    }

    // =========================================================================
    //  sudo's password -- see the header
    // =========================================================================

    // Listening only while a job runs; a preflight job has no sudo in it, so
    // it has no root process to descend from and every request is refused.
    AskpassServer {
        id: _askpass
        path: root._askSock
        active: root._job !== null
        rootPid: (root._job && !root._job.preflight && _proc.processId) ? Number(_proc.processId) : 0
        requireSudoParent: root.requireSudoParent
        answerWindowMs: root.sudoAuthWindowMs
        onRequested: function (req) { root._onAsk(req); }
    }
    Connections {
        target: _askpass
        function onRequestChanged() { if (!_askpass.request) root._authPublic = null; }
    }

    // The broker's face: sudo's request as the job asked it. The command is
    // shown as the confirmation showed it.
    AskpassSource {
        id: _askSource
        broker: root.broker
        server: _askpass
        title: "Administrator password"
        howdyMode: root.howdyMode
        faceTimeoutMs: root.howdyTimeoutMs
        describe: function (req) {
            const j = root._job;
            const f = j ? j.frozen : null;
            return {
                body: f ? "The assistant's " + f.name + " call runs sudo" : "A tool call runs sudo",
                detail: f ? String(f.detail || "") : ""
            };
        }
        onDeclined: function (req, why) {
            root._authNote = "sudo was not asked: " + why;
        }
    }

    function _onAsk(req) {
        const j = root._job;
        // No broker: the source answers "" and says why; nothing is published.
        if (!j) { _askpass.cancel(req.id); return; }
        if (!root.broker) return;
        const f = j.frozen;
        j.authAttempts = (j.authAttempts || 0) + 1;
        root._authPublic = {
            id: "auth:" + f.callId + ":" + req.id, callId: f.callId, kind: "password",
            name: f.name, glyph: f.glyph || "", prompt: req.prompt, attempt: j.authAttempts,
            // Howdy says why it gave up on its own line, which sudo prints on
            // the job's stderr -- unless the command sent that to /dev/null.
            howdy: /Failure, (timeout reached|image too dark|not possible to open camera)/.test(j.err),
            detail: f.detail, detailLang: f.detailLang, detailLines: f.detailLines,
            cwd: f.cwd, timeoutS: f.commandTimeoutS || f.timeoutS, authS: f.authS || 0
        };
    }

    // answerAuth(id, secret): what the toast does -- through the broker, so
    // its record follows (checking, failed, ok). "" is a cancel. Nothing keeps
    // the secret: it is handed over and this function returns.
    function answerAuth(id, secret) {
        const p = root._authPublic;
        const r = _askpass.request;
        if (!p || !r || String(id) !== p.id) return;
        const rid = _askSource.recordFor(r.id);
        if (rid.length === 0) { _askpass.answer(r.id, secret); return; }
        if (String(secret || "") === "") root.broker.cancel(rid);
        else root.broker.submit(rid, secret);
    }
    function cancelAuth(id) { root.answerAuth(id, ""); }
}
