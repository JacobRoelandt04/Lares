pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/audio/airplay"
import "modules/audio/data"
import "modules/bar/player"
import "modules/bar/player/components"
import "modules/osd/data/sources"
import "modules/common/theme"

// =============================================================================
// airplay_probe.qml -- AirplayWatch and its three consumers on a PRIVATE PipeWire (tools/dev/airplay_probe.sh). A null sink carries a
// RAOP sink's name, an `mpd.PipeWire` stream is linked into it and out of it by `pw-link`; `iw`, `pkcheck`, `pkexec` and `pw-dump` are
// stubs first on PATH (the pkexec stub plays the helper: it keeps the radio's state in a file and logs its argv). Scenarios (AP_SCENARIO):
//
//   main        the watcher end to end: sending, latency from the module, power save off after the hold, re-asserted after a reset, put
//               back after the grace, a user's own `off` never touched; AirplayDelay reaches the OSD source (a key's card at once, a
//               natural change late, a newer one replaces, a stop drops), the bar glyph's flourish and the lyrics' active line, and
//               every one of them live again with nothing sending
//   reconcile   a record that says ours with nothing sending (the shell died with it off) puts power save back at start
//   noverb      a helper that predates the verb: said once, never retried
//
// One line per check (`AP ok|FAIL <name>`), `AP RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: root

    readonly property string dir: Quickshell.env("AP_DIR")
    readonly property string scenario: Quickshell.env("AP_SCENARIO") || "main"
    readonly property string sink: "raop_sink.Speaker-0B01.local.192.168.0.103.7000"

    // ---- the thing under test (the real watcher; the singleton bound as ShellServices binds it) ----
    AirplayWatch {
        id: watch
        live: true
        configPath: root.dir + "/config/airplay.jsonc"
        stateFile: root.dir + "/rt/lares/airplay-powersave.json"
        helperPath: root.dir + "/stubs/silicon-helper"
        netSysfs: root.dir + "/net"
        startHoldMs: 500
        recheckMs: 1500
        reconcileMs: 800
    }
    Binding {
        target: AirplayDelay
        property: "delayMs"
        value: watch.delayMs
    }

    // ---- the consumers ----
    property var osdLog: []
    MpdSource {
        id: osd
        live: false
        onRequest: req => root.osdLog = root.osdLog.concat([{ tick: root.tick, title: req.track.title, source: req.source }])
    }
    QtObject {
        id: playerStub
        property bool connected: true
        property string playState: "play"
        property int songId: 1
    }
    Item {
        id: stage
        width: 400
        height: 400
        PlayerBarButton {
            id: btn
            player: playerStub
            family: "Audiowide"
            glyphSize: 15
            pad: 4
        }
        PlayerData {
            id: pd
            y: 40
            width: 320
            height: 320
            active: false
            song: ({ file: "/probe/x.flac", title: "x", duration: 200 })
            playing: true
        }
    }
    FloatingWindow {
        visible: true
        implicitWidth: 420
        implicitHeight: 420
        color: Theme.surface
        data: [stage]
    }

    // ---- a clock the probe measures in (the QML clock: the consumers' own timers run on it) ----
    property int tick: 0
    Timer {
        interval: 10
        running: true
        repeat: true
        onTriggered: root.tick++
    }

    // ---- the world's files, read every 100 ms (a probe may fork) ----
    property var snap: ({ calls: [], iw: "", rec: "" })
    Process {
        id: snapProc
        command: ["sh", "-c", 'cat "$1/calls.log" 2> /dev/null; echo "@@IW"; cat "$1/iw_state" 2> /dev/null; echo "@@REC"; cat "$1/rt/lares/airplay-powersave.json" 2> /dev/null', "sh", root.dir]
        stdout: StdioCollector {
            onStreamFinished: {
                const a = this.text.split("@@IW\n");
                const b = (a[1] || "").split("@@REC\n");
                root.snap = { calls: a[0].split("\n").filter(l => l !== ""), iw: b[0].trim(), rec: (b[1] || "").trim() };
            }
        }
    }
    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: if (!snapProc.running) snapProc.running = true
    }
    // pw-link and the radio's resets, one at a time
    Process { id: act }
    function doAct(name: string): void {
        const L = '"mpd.PipeWire:output_FL" "' + root.sink + ':send_FL"';
        const R = '"mpd.PipeWire:output_FR" "' + root.sink + ':send_FR"';
        const cmd = {
            link: "pw-link " + L + "; pw-link " + R,
            unlink: "pw-link -d " + L + "; pw-link -d " + R,
            nmreset: 'echo on > "$1/iw_state"',
            userOff: 'echo off > "$1/iw_state"',
            userOn: 'echo on > "$1/iw_state"'
        }[name];
        act.command = ["sh", "-c", cmd, "sh", root.dir];
        act.running = true;
    }

    // ---- the checks ----
    property int bad: 0
    function ck(name: string, ok: bool, detail: string): void {
        console.log("AP " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : " -- " + detail));
        if (!ok)
            root.bad++;
    }
    function pk(kind: string): int {   // pkexec calls of a kind so far
        return root.snap.calls.filter(l => l.indexOf("wifi-powersave wlp47s0 " + kind) >= 0).length;
    }
    function finish(): void {
        console.log("AP RESULT " + (root.bad === 0 ? "PASS" : "FAIL") + " (" + root.scenario + ")");
        Qt.quit();
    }

    // ---- the sequencer: a step runs `go`, then waits for `until` (polled each 50 ms) up to `limit` ticks (10 ms of the QML clock) ----
    property var steps: []
    property int stepAt: 0
    property int stepStart: 0
    property bool _entered: false
    Timer {
        interval: 50
        running: root.steps.length > 0
        repeat: true
        onTriggered: {
            if (root.stepAt >= root.steps.length)
                return;
            const s = root.steps[root.stepAt];
            if (!root._entered) {
                root._entered = true;
                root.stepStart = root.tick;
                if (s.go)
                    s.go();
            }
            const waited = root.tick - root.stepStart;
            const met = s.until ? s.until() : true;
            if (met || waited > (s.limit || 800)) {
                if (!met)
                    root.ck(s.name + " (timed out)", false, "after " + waited + " ticks");
                if (s.done)
                    s.done(met, waited);
                root.stepAt++;
                root._entered = false;
                if (root.stepAt >= root.steps.length)
                    root.finish();
            }
        }
    }

    function startMain(): void {
        const lines = [{ t: 1, text: "one" }, { t: 10, text: "two" }, { t: 20, text: "three" }, { t: 30, text: "four" }];
        const song = n => ({ id: n, title: "S" + n, artist: "", album: "", file: "f" + n, coverUrl: "" });
        let t0 = 0, n0 = 0;
        root.steps = [
            { name: "the sink is seen and its module read", until: () => watch.iface === "wlp47s0" || watch._infos[root.sink] !== undefined, limit: 600,
              done: (m) => {
                root.ck("nothing sends before a link exists", !watch.sending && watch.delayMs === 0 && AirplayDelay.delayMs === 0, "sending " + watch.sending + " delay " + watch.delayMs);
                root.ck("the helper has not been asked", root.snap.calls.length === 0, root.snap.calls.join(","));
              } },
            { name: "sound goes into the sink", go: () => root.doAct("link"), until: () => watch.sending && watch.latencyMs > 0, limit: 800,
              done: () => {
                root.ck("sending, into the RAOP sink, by mpd", watch.sending && watch.mpdInto && watch.sinkName === root.sink, watch.sinkName + " mpd " + watch.mpdInto);
                root.ck("the latency is the module's raop.latency.ms + sess.latency.msec", watch.latencyMs === 3479, "latency " + watch.latencyMs);
                root.ck("the interface is raop.ifindex's", watch.iface === "wlp47s0", "iface '" + watch.iface + "'");
                root.ck("the config's number replaces the sink's own (delay 700) and reaches AirplayDelay", watch.delayMs === 700 && AirplayDelay.delayMs === 700, watch.delayMs + " / " + AirplayDelay.delayMs);
              } },
            { name: "power save goes off after the hold", until: () => watch.ours && root.snap.iw === "off", limit: 800,
              done: () => {
                root.ck("the helper was asked once, for off, through pkexec", root.pk("off") === 1 && root.snap.calls.length === 1, root.snap.calls.join(" | "));
                root.ck("the record says ours", root.snap.rec.indexOf('"ours":true') >= 0, root.snap.rec);
              } },
            // ---- the consumers, with a delay of 700 ms ----
            { name: "osd: a key's card shows at once", go: () => { osd.simulateReady("play", 1); osd.media("next"); n0 = root.osdLog.length; osd.simulateSong(song(2), "play"); },
              until: () => true,
              done: () => root.ck("osd: key card immediate", root.osdLog.length === n0 + 1 && root.osdLog[n0].source === "key" && root.osdLog[n0].tick === root.tick, JSON.stringify(root.osdLog)) },
            { name: "osd: the key's claim ends", until: () => osd._action === "", limit: 300 },
            { name: "osd: a natural change waits", go: () => { n0 = root.osdLog.length; t0 = root.tick; osd.simulateSong(song(3), "play"); },
              until: () => root.osdLog.length > n0, limit: 300,
              done: () => {
                const e = root.tick - t0;
                root.ck("osd: not shown at once", e >= 40, "after " + e + " ticks");
                root.ck("osd: shown about 700 ms later, as the external card", e <= 110 && root.osdLog[n0].source === "external" && root.osdLog[n0].title === "S3", e + " " + JSON.stringify(root.osdLog.slice(n0)));
              } },
            { name: "osd: a newer change replaces the pending one", go: () => { n0 = root.osdLog.length; t0 = root.tick; osd.simulateSong(song(4), "play"); },
              until: () => root.tick - t0 >= 30,
              done: () => { osd.simulateSong(song(5), "play"); t0 = root.tick; } },
            { name: "osd: ... and only the newer shows", until: () => root.tick - t0 >= 150,
              done: () => root.ck("osd: one card, the newer, late", root.osdLog.length === n0 + 1 && root.osdLog[n0].title === "S5" && root.osdLog[n0].tick - t0 >= 40, JSON.stringify(root.osdLog.slice(n0))) },
            { name: "osd: a stop drops it", go: () => { n0 = root.osdLog.length; t0 = root.tick; osd.simulateSong(song(6), "play"); osd.simulateState("stop"); },
              until: () => root.tick - t0 >= 150,
              done: () => root.ck("osd: nothing shown after a stop", root.osdLog.length === n0, JSON.stringify(root.osdLog.slice(n0))) },
            { name: "flourish: a new song waits", go: () => { playerStub.songId = 11; t0 = root.tick; }, until: () => true,
              done: () => root.ck("flourish: not at once", !btn.flourishing, "playing at once") },
            { name: "flourish: ... then plays", until: () => btn.flourishing, limit: 300,
              done: () => root.ck("flourish: plays about 700 ms later", root.tick - t0 >= 40 && root.tick - t0 <= 120 && btn.flourishing, (root.tick - t0) + " ticks") },
            { name: "flourish: let it end", until: () => !btn.flourishing, limit: 600 },
            { name: "flourish: a pause drops a pending one", go: () => { playerStub.songId = 12; playerStub.playState = "pause"; t0 = root.tick; }, until: () => root.tick - t0 >= 150,
              done: () => { root.ck("flourish: nothing after a pause", !btn.flourishing, "playing"); playerStub.playState = "play"; } },
            { name: "lyrics: the line follows position - delay", go: () => {
                pd.reader._cache = ({ "/probe/x.flac": { tags: {}, lyrics: { synced: true, lines: lines, source: "lyrics" }, error: "" } });
                pd.active = true;
                pd.position = 20.5;
              }, until: () => pd._activeIdx >= 0 && pd._lines.length === 4, limit: 300,
              done: () => {
                root.ck("lyrics: 20.5 s with 700 ms of delay is still line 2 (live would say 3)", pd._activeIdx === 1, "idx " + pd._activeIdx);
                pd.position = 1.2;
              } },
            { name: "lyrics: clamped at the start", until: () => pd._activeIdx === -1, limit: 200,
              done: (m) => root.ck("lyrics: 1.2 s with 700 ms of delay is before the first line", m && pd._activeIdx === -1, "idx " + pd._activeIdx) },
            { name: "lyrics: the playhead stays live", until: () => true,
              done: () => root.ck("lyrics: the popup's position is untouched", pd.position === 1.2, "position " + pd.position) },
            // ---- the radio again ----
            { name: "an NM reset is re-asserted", go: () => root.doAct("nmreset"), until: () => root.pk("off") >= 2 && root.snap.iw === "off", limit: 1500,
              done: (m) => root.ck("re-asserted after a reset: the helper asked for off again", m && watch.reasserts >= 1 && root.pk("off") === 2, "off calls " + root.pk("off") + " reasserts " + watch.reasserts) },
            { name: "sending ends", go: () => { root.doAct("unlink"); t0 = root.tick; }, until: () => !watch.sending, limit: 500,
              done: () => root.ck("nothing sends, the delay is 0 again", !watch.sending && watch.delayMs === 0 && AirplayDelay.delayMs === 0, "delay " + watch.delayMs + "/" + AirplayDelay.delayMs) },
            { name: "the grace holds it off", until: () => root.tick - t0 >= 30,
              done: () => root.ck("power save is not put back before the grace", root.pk("on") === 0 && watch.ours, "on calls " + root.pk("on")) },
            { name: "after the grace it is put back", until: () => root.pk("on") === 1 && !watch.ours, limit: 1500,
              done: (m) => root.ck("put back on after graceSec, once", m && root.snap.iw === "on" && root.snap.rec.indexOf('"ours":false') >= 0, "iw " + root.snap.iw + " rec " + root.snap.rec) },
            // ---- everything live with nothing sending ----
            { name: "live: osd", go: () => { n0 = root.osdLog.length; osd.simulateSong(song(7), "play"); }, until: () => true,
              done: () => root.ck("live: a natural change shows at once with nothing sending", root.osdLog.length === n0 + 1 && root.osdLog[n0].tick === root.tick, JSON.stringify(root.osdLog.slice(n0))) },
            { name: "live: flourish", go: () => { playerStub.songId = 13; }, until: () => btn.flourishing, limit: 100,
              done: (m) => root.ck("live: the flourish plays at once", m, "not playing") },
            { name: "live: lyrics", go: () => { pd.position = 20.5; }, until: () => pd._activeIdx === 2, limit: 200,
              done: (m) => root.ck("live: the line follows the position", m && pd._activeIdx === 2, "idx " + pd._activeIdx) },
            // ---- the user had power save off themselves ----
            { name: "the user's own off", go: () => { root.doAct("userOff"); }, until: () => root.snap.iw === "off", limit: 300 },
            { name: "sending again", go: () => { root.doAct("link"); n0 = root.snap.calls.length; }, until: () => watch.sending && watch._stable && watch.jobLog.length > 0 && watch.jobLog[watch.jobLog.length - 1].then === "engage", limit: 800 },
            { name: "...and nothing is asked of the helper", until: () => root.tick - stepStartHold() >= 150,
              done: () => root.ck("untouched when the user had it off", root.snap.calls.length === n0 && !watch.ours && root.snap.iw === "off", root.snap.calls.slice(n0).join(" | ") + " ours " + watch.ours) },
            { name: "sending ends again", go: () => { root.doAct("unlink"); t0 = root.tick; }, until: () => !watch.sending && root.tick - t0 >= 250, limit: 1000,
              done: () => root.ck("a setting that was the user's is never restored", root.snap.calls.length === n0 && root.snap.iw === "off", root.snap.calls.slice(n0).join(" | ")) }
        ];
    }
    function stepStartHold(): int { return root.stepStart; }

    function startReconcile(): void {
        root.steps = [
            { name: "the record is put back", until: () => root.pk("on") >= 1 && !watch.ours, limit: 1200,
              done: (m) => root.ck("reconcile: a record that says ours, with nothing sending, puts power save back on", m && root.snap.iw === "on" && root.snap.rec.indexOf('"ours":false') >= 0, "calls " + root.snap.calls.join(" | ") + " iw " + root.snap.iw) }
        ];
    }

    function startNoverb(): void {
        let n = 0;
        root.steps = [
            { name: "sound goes", go: () => root.doAct("link"), until: () => watch.sending && watch.latencyMs > 0, limit: 800 },
            { name: "the missing verb is found", until: () => watch.helperState === "missing", limit: 1000,
              done: (m) => root.ck("noverb: the helper without the verb is noticed", m && !watch.ours && root.snap.iw === "on", "state " + watch.helperState) },
            { name: "and not asked again", go: () => { n = root.snap.calls.length; }, until: () => root.tick - root.stepStart >= 600,
              done: () => root.ck("noverb: no retry storm while sending", root.snap.calls.length === n && n === 1, "calls " + root.snap.calls.length) }
        ];
    }

    Component.onCompleted: {
        if (root.scenario === "main")
            root.startMain();
        else if (root.scenario === "reconcile")
            root.startReconcile();
        else
            root.startNoverb();
    }
}
