pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "AirplayRules.js" as Rules

// =============================================================================
// AirplayWatch.qml -- is sound going to an AirPlay (RAOP) speaker, how late does it arrive, and keeping the Wi-Fi radio awake
// while it does. ONE per shell (ShellServices; AirplayWatchMock is its twin). Contract: docs/audio.md "Airplay".
//
// THE FACTS (event-driven, nothing polls)
//   sending      a PipeWire link group into a RAOP sink (`raop_sink.<host>.<ip>.<port>`, raop-discover's) is ACTIVE: sound flows
//                (a paused stream's link is Paused). Read from Quickshell's `Pipewire.linkGroups`, whose model and every group's
//                `state` say when it changes (an Instantiator over the model carries each group's own signal).
//   sinkName     the sink it flows into
//   latencyMs    that sink's `raop.latency.ms` + `sess.latency.msec`, from its module's arguments (`pw-dump Module`, ONE read when a
//                RAOP sink first appears, matched by ip and port in the name; `raop.ifindex` names the Wi-Fi interface)
//   mpdInto      mpd's own stream (node `mpd.PipeWire`) is linked into it, Active or Paused (the delay holds across a pause)
//   delayMs      what the player's displays wait to arrive with the sound: latencyMs while mpdInto (config.delay "auto"), a number
//                from the config instead, + delayExtraMs, never below 0; 0 when mpd is not playing into a RAOP sink.
//                AirplayDelay.delayMs is this, written by ShellServices (the OSD's track card, the bar glyph's flourish and the
//                lyrics' active line read that singleton).
//
// THE RADIO. The speaker's stream drops out while the radio sleeps between beacons. NetworkManager cannot change power save on
// an active connection (it applies `wifi.powersave` at activation only), so it is `iw dev <iface> set power_save` as root: the
// silicon helper's `wifi-powersave` verb behind the user's passwordless polkit rule (lares setup R3 / R4). A `pkcheck` first says
// whether polkit would ASK; if it would (no rule) nothing is run, so no password dialog ever opens from here.
//
//   sending for `startHoldMs`   power save is read (`iw dev <iface> get power_save`, no root); `on` -> the helper turns it off and
//                               the record says WE did (`ours`, kept in `stateFile`: $XDG_RUNTIME_DIR/lares/airplay-powersave.json).
//                               `off` already -> the user's own setting: never touched, never restored.
//   while sending               every `recheckMs` (one single-shot re-armed when a check ends) it is read again, and put back off when
//                               it is on (NetworkManager turns it on at its next activation of the connection: a roam, a reconnect).
//   `graceSec` after sending ended   if it is ours, the helper turns it on again (a track change or a pause is not the end).
//   at start                    a record that says ours with nothing sending (the shell died with it off) puts it back at once.
// A missing verb / helper / rule is said once per kind and not retried until the next sending session starts. `config/airplay.jsonc`
// (`powersave: false` switches all of it off and puts a power save of ours back).
//
// `live: false` has no PipeWire, no process and no file; a probe writes `sending`, `latencyMs`, `mpdInto` and calls `applyConfig`.
// =============================================================================
Item {
    id: root

    property bool live: false
    property string configPath: ""
    // The record of what we changed ("" = none kept). $XDG_RUNTIME_DIR/lares/airplay-powersave.json
    property string stateFile: ""
    property string helperPath: "/usr/local/libexec/silicon-helper"
    // Where the interfaces' `ifindex` files are (the probe's fixture overrides it).
    property string netSysfs: "/sys/class/net"
    property int startHoldMs: 2000
    property int recheckMs: 30000
    property int reconcileMs: 3000
    property int jobLimitMs: 20000

    property var config: Rules.parseConfig({})

    // ---- the facts ----
    property bool sending: false
    property bool mpdInto: false
    property string sinkName: ""
    property int latencyMs: 0
    readonly property int delayMs: Rules.delayMs(root.config, root.latencyMs, root.mpdInto)

    // ---- the radio ----
    property string iface: ""
    property string powerSave: ""            // as last read or set: "on" | "off" | ""
    property bool ours: false                // we turned it off and have not put it back
    property string helperState: "unknown"   // "unknown" | "ok" | "missing" | "unauthorised" | "failed"
    property int reasserts: 0                // times a power save found on again while ours was put back off (a probe reads it)
    property var jobLog: []                  // [{ kind, then, rc }] oldest first, a probe reads it

    // ======================================================================================================================
    // CONFIG
    // ======================================================================================================================
    function applyConfig(obj: var): void {
        root.config = Rules.parseConfig(obj);
        if (root.ours && !root.config.powersave)
            root._restore(true);
    }
    function _applyText(text: string): void {
        let o = {};
        try {
            o = JSON.parse(JsonComments.strip(text));
        } catch (e) {
            o = {};
        }
        root.applyConfig(o);
    }
    ConfigFile {
        id: cfgFile
        path: root.configPath
        watchChanges: root.live
        onLoaded: if (root.live) root._applyText(cfgFile.text())
        onLoadFailed: if (root.live) root._applyText("")
    }

    // ======================================================================================================================
    // THE GRAPH
    // ======================================================================================================================
    property var _infos: ({})       // sink name -> { latencyMs, iface }
    property var _asked: ({})       // sink name -> true once its module has been read for
    property var _raopNames: []     // the RAOP sinks the graph holds now

    function _scan(): void {
        if (!root.live || !Pipewire.ready)
            return;
        // the sinks that exist
        const ns = Pipewire.nodes ? Pipewire.nodes.values : [];
        const names = [];
        for (let i = 0; i < ns.length; i++)
            if (ns[i] && Rules.isRaop(ns[i].name))
                names.push(ns[i].name);
        let askNew = false;
        for (const n of names)
            if (!root._asked[n])
                askNew = true;
        if (names.join("|") !== root._raopNames.join("|")) {
            const keepI = {}, keepA = {};
            for (const n of names) {
                if (root._infos[n])
                    keepI[n] = root._infos[n];
                if (root._asked[n])
                    keepA[n] = true;
            }
            root._infos = keepI;
            root._asked = keepA;
            root._raopNames = names;
        }
        if (askNew)
            root._askModules();
        // the links into them
        const gs = Pipewire.linkGroups ? Pipewire.linkGroups.values : [];
        let sink = "", into = false, any = false, mpdSink = "";
        for (let i = 0; i < gs.length; i++) {
            const g = gs[i];
            const t = g ? g.target : null;
            if (!t || !Rules.isRaop(t.name))
                continue;
            const active = g.state === PwLinkState.Active;
            const isMpd = /^mpd/i.test(String(g.source ? g.source.name : ""));
            // mpd's own link counts while PAUSED too: the delay holds across a pause, or the lyrics' line would jump by the
            // delay at the pause and back at the resume. Sound flowing (`sending`, the power save's fact) stays Active only.
            if (isMpd && (active || g.state === PwLinkState.Paused) && mpdSink === "") {
                mpdSink = t.name;
                into = true;
            }
            if (!active)
                continue;
            any = true;
            if (sink === "")
                sink = t.name;
        }
        if (mpdSink !== "")
            sink = mpdSink;
        if (root.mpdInto !== into)
            root.mpdInto = into;
        if (root.sinkName !== sink)
            root.sinkName = sink;
        if (root.sending !== any)
            root.sending = any;
        root._facts();
    }
    // latencyMs and iface follow the sink in use
    function _facts(): void {
        const i = root._infos[root.sinkName];
        const lat = i ? i.latencyMs : 0;
        if (root.latencyMs !== lat)
            root.latencyMs = lat;
        const f = i ? i.iface : "";
        if (f !== "" && root.iface !== f)
            root.iface = f;
        if (root._wantEngage && root.iface !== "")
            root._engage();
    }

    LazyLoader {
        active: root.live
        component: Scope {
            id: graph
            readonly property var groups: Pipewire.linkGroups
            readonly property var nodes: Pipewire.nodes
            Connections {
                target: graph.groups
                function onValuesChanged(): void { root._scan(); }
            }
            Connections {
                target: graph.nodes
                function onValuesChanged(): void { root._scan(); }
            }
            Connections {
                target: Pipewire
                function onReadyChanged(): void { root._scan(); }
            }
            // each group's own state (a link going Active / Paused says nothing to the model)
            Instantiator {
                model: graph.groups
                delegate: QtObject {
                    id: row
                    required property var modelData
                    readonly property int st: row.modelData ? row.modelData.state : 0
                    onStChanged: root._scan()
                }
            }
            PwObjectTracker {
                objects: graph.groups ? graph.groups.values : []
            }
            Component.onCompleted: root._scan()
        }
    }

    // ONE read of the RAOP modules' arguments, and of the interface indexes, when a RAOP sink first appears.
    Process {
        id: modRead
        command: ["sh", "-c",
            'command -v pw-dump > /dev/null 2>&1 || exit 127; pw-dump Module || exit 1; printf "\\n@@IF\\n"; ' +
            'for d in "$1"/*; do [ -r "$d/ifindex" ] && { read -r i < "$d/ifindex"; printf "%s %s\\n" "${d##*/}" "$i"; }; done; exit 0',
            "sh", root.netSysfs]
        stdout: StdioCollector {
            onStreamFinished: root._modulesRead(this.text)
        }
    }
    function _askModules(): void {
        if (modRead.running)
            return;
        const a = Object.assign({}, root._asked);
        for (const n of root._raopNames)
            a[n] = true;
        root._asked = a;
        modRead.running = true;
    }
    function _modulesRead(text: string): void {
        const cut = text.indexOf("\n@@IF\n");
        const dump = cut >= 0 ? text.substring(0, cut) : text;
        const listing = cut >= 0 ? text.substring(cut + 6) : "";
        const mods = Rules.parseModules(dump);
        const infos = Object.assign({}, root._infos);
        for (const n of root._raopNames) {
            const m = Rules.moduleFor(mods, n);
            if (!m)
                console.warn("LARES airplay: no raop-sink module found for " + n + " (its latency is read as 0)");
            infos[n] = { latencyMs: m ? m.latencyMs : 0, iface: m ? Rules.ifaceOf(listing, m.ifindex) : "" };
            console.log("LARES airplay: " + n + " latency " + infos[n].latencyMs + " ms, interface " + (infos[n].iface || "?"));
        }
        root._infos = infos;
        root._scan();
    }

    // ======================================================================================================================
    // THE RADIO
    // ======================================================================================================================
    property bool _stable: false        // sending has lasted startHoldMs
    property bool _wantEngage: false
    property var _told: ({})
    property var _queue: []
    property var _cur: null

    function _tell(key: string, text: string): void {
        if (root._told[key])
            return;
        const t = Object.assign({}, root._told);
        t[key] = true;
        root._told = t;
        console.log("LARES airplay: " + text);
    }

    onSendingChanged: {
        if (root.sending) {
            graceTimer.stop();
            reconcileTimer.stop();
            root.helperState = root.helperState === "ok" ? "ok" : "unknown";   // a new session tries a missing helper once again
            root._told = ({});
            if (!root._stable)
                startTimer.restart();
        } else {
            startTimer.stop();
            recheckTimer.stop();
            root._stable = false;
            root._wantEngage = false;
            if (root.ours)
                graceTimer.restart();
        }
    }
    Timer {
        id: startTimer
        interval: root.startHoldMs
        onTriggered: {
            root._stable = true;
            root._engage();
        }
    }
    Timer {
        id: recheckTimer
        interval: root.recheckMs
        onTriggered: root._enqueue({ kind: "get", then: "recheck" })
    }
    Timer {
        id: graceTimer
        interval: root.config.graceSec * 1000
        onTriggered: root._restore(false)
    }
    Timer {
        id: reconcileTimer
        interval: root.reconcileMs
        onTriggered: if (!root.sending) root._restore(true)
    }

    function _engage(): void {
        if (!root.live || !root.config.powersave || !root._stable || root.helperState === "missing" || root.helperState === "unauthorised")
            return;
        if (root.iface === "") {
            root._wantEngage = true;
            return;
        }
        root._wantEngage = false;
        root._enqueue({ kind: "get", then: "engage" });
    }
    // put it back: `force` goes on while something is sending (the config switched the feature off)
    function _restore(force: bool): void {
        if (!root.ours || (root.sending && !force) || root.iface === "")
            return;
        root._enqueue({ kind: "get", then: "restore" });
    }

    function _enqueue(job: var): void {
        root._queue = root._queue.concat([job]);
        root._pump();
    }
    function _pump(): void {
        if (job.running || root._queue.length === 0 || !root.live)
            return;
        const j = root._queue[0];
        root._queue = root._queue.slice(1);
        root._cur = j;
        if (j.kind === "get") {
            job.command = ["sh", "-c",
                'command -v iw > /dev/null 2>&1 || { echo "@@RC 127"; exit 0; }; iw dev "$1" get power_save 2> /dev/null; echo "@@RC $?"',
                "sh", root.iface];
        } else {
            job.command = ["sh", "-c",
                'command -v pkcheck > /dev/null 2>&1 && { pkcheck --action-id org.lares.silicon.helper --process $$ > /dev/null 2>&1 || { echo "@@RC 125"; exit 0; }; }; ' +
                '[ -x "$1" ] || { echo "@@RC 127"; exit 0; }; pkexec "$@" 2> /dev/null; echo "@@RC $?"',
                "sh", root.helperPath, "wifi-powersave", root.iface, j.kind];
        }
        watchdog.restart();
        job.running = true;
    }
    Process {
        id: job
        stdout: StdioCollector {
            onStreamFinished: root._jobDone(this.text)
        }
    }
    Timer {
        id: watchdog
        interval: root.jobLimitMs
        onTriggered: if (job.running) job.running = false
    }

    function _jobDone(text: string): void {
        watchdog.stop();
        const j = root._cur;
        root._cur = null;
        const cut = text.lastIndexOf("@@RC");
        const body = cut >= 0 ? text.substring(0, cut) : text;
        const rc = cut >= 0 ? parseInt(text.substring(cut + 4)) : -1;
        if (j) {
            const l = root.jobLog.slice(-40);
            l.push({ kind: j.kind, then: j.then, rc: rc });
            root.jobLog = l;
            if (j.kind === "get")
                root._gotRead(j, rc, body);
            else
                root._gotWrite(j, rc, body);
        }
        // while sound goes and the radio is ours, the next look
        if (root.sending && root.ours && root._stable && root.config.powersave && !recheckTimer.running && root._queue.length === 0)
            recheckTimer.restart();
        root._pump();
    }

    function _gotRead(j: var, rc: int, body: string): void {
        const ps = rc === 0 ? Rules.parsePowerSave(body) : "";
        if (ps === "") {
            root._tell("noread", "cannot read the power save of " + root.iface + " (iw: " + (rc === 127 ? "not installed" : "exit " + rc) + "); leaving it alone");
            return;
        }
        root.powerSave = ps;
        if (j.then === "restore") {
            if (ps === "off" && root.ours)
                root._enqueue({ kind: "on", then: "restore" });
            else
                root._setOurs(false);
            return;
        }
        // engage / recheck
        if (!root.config.powersave)
            return;
        if (ps === "on") {
            if (root.ours)
                root.reasserts++;
            if (j.then === "recheck" && !root.ours)
                return;   // not ours: a recheck never takes a setting we did not find off
            root._enqueue({ kind: "off", then: j.then });
        } else if (!root.ours) {
            root._tell("userOff", "power save of " + root.iface + " was already off: left as it is");
        }
    }

    function _gotWrite(j: var, rc: int, body: string): void {
        if (rc === 125) {
            root.helperState = "unauthorised";
            root._tell("unauthorised", "polkit would ask for a password to run the silicon helper: power save left alone (lares setup R3)");
            return;
        }
        if (rc === 127) {
            root.helperState = "missing";
            root._tell("nohelper", root.helperPath + " is not installed: power save left alone");
            return;
        }
        const a = Rules.parseHelperAnswer(body);
        if (a.missing) {
            root.helperState = "missing";
            root._tell("noverb", "the installed silicon helper has no wifi-powersave verb: power save left alone (lares setup R4)");
            return;
        }
        if (!a.ok) {
            root.helperState = "failed";
            root._tell("failed:" + a.why, "wifi-powersave " + j.kind + " failed: " + a.why);
            return;
        }
        root.helperState = "ok";
        root.powerSave = a.powerSave;
        root._setOurs(j.kind === "off" && a.powerSave === "off");
    }

    function _setOurs(v: bool): void {
        if (root.ours !== v)
            root.ours = v;
        const text = JSON.stringify({ ours: v, iface: root.iface });
        if (root.stateFile !== "")
            rec.setText(text);
        if (v && root.sending && root._stable && root.config.powersave && !recheckTimer.running)
            recheckTimer.restart();
        if (!v)
            recheckTimer.stop();
    }

    // the record: what we changed survives the shell (a shell that died with power save off puts it back)
    FileView {
        id: rec
        path: root.stateFile
        blockLoading: true
        printErrors: false
    }
    Process {
        id: mkdir
        command: ["mkdir", "-p", "--", root.stateFile.substring(0, Math.max(0, root.stateFile.lastIndexOf("/")))]
    }
    Component.onCompleted: {
        if (!root.live || root.stateFile === "")
            return;
        mkdir.running = true;
        let r = null;
        try {
            r = JSON.parse(rec.text());
        } catch (e) {
            r = null;
        }
        if (r && r.ours === true && typeof r.iface === "string" && r.iface !== "") {
            root.ours = true;
            root.iface = r.iface;
            reconcileTimer.restart();
        }
    }
}
