//@ pragma Env QSG_DISTANCEFIELD_ANTIALIASING=gray
// qmllint disable unqualified
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/dictation"
import "modules/bar/audio/data"

// =============================================================================
// dictation_probe.qml -- DictationService on the REAL chain, in a nested Hyprland (tools/dev/dictation_probe.sh runs it in
// tools/dev/lock_env.sh): the real speech helper and model, the real input method (lares-ime) against the nested compositor, a real
// PipewireService on a PRIVATE PipeWire whose default source is a virtual mic playing FLEURS clips (tools/dev/stt_pw_fixture.sh),
// the stub field below (a Qt TextInput: text-input-v3, like the shell's own LLM input and notes editor), a stub wl-copy.
//
//   A  the field focused: fn+F10 (the lares:dictate global, dispatched through Hyprland to DictationShortcuts) -> live words in
//      the field's preedit -> a revision -> the final text in the field; the mic was muted,
//      is unmuted while listening, muted again after; the aura asked in and out
//   B  no field (the window hidden): the take's text goes to the clipboard
//   D  a secret field (the same field with ImhHiddenText | ImhSensitiveData: text-input hints hidden + sensitive): the take writes
//      nothing into it, nothing goes to the clipboard (a Qt echoMode-Password field enables no text input at all: it is no field)
//   E  the typing route's keyboard (`lares-ime --type-only`: apps with no text input) with a bare-Escape bind in the compositor:
//      the text arrives and the bind does not fire (its keycodes carry no symbol in the seat's keymap; wtype's keycode 9 would)
//   F  fillers (round 4), with the helper's stand-in decoder (tools/stt/sttlib/stubs.py: no recording of a real "uh" exists, so a
//      1 kHz tone on a burst of speech is its "uh," and a 2 kHz one its "MARK"; tools/dev/stt_filler_wav.py): speech, a filler, a 2 s
//      pause, MARK, speech. No hypothesis, final or field text shows the filler; the pause after it kept the sentence open (one
//      final holds the filler and MARK)
//   G  the tidy pass on, its model a stub that adds a word (LARES_STT_TIDY_MODEL=stub-add): the guard refuses every proposal and the
//      field gets the sentences as heard (A ran with the tidy pass off, the default: no final carried a tidy verdict)
//   H  the device per take, from a stubbed fact (LARES_STT_PCI_ROOT, a fake PCI tree): A ran with no NVIDIA card in it -> the iGPU; here
//      a card with the nvidia driver appears -> the take asks for CUDA, which this machine (Integrated) refuses -> the iGPU for the
//      take, which still writes its text
//   I  (round 5) THE FIRST TAKE LIVE: a window whose text input was made and ENABLED before the take's input method bound
//      (tools/dev/dictation_probe_ticlient.c: an app that makes its text input when its window is first focused). Hyprland enters
//      no field for that bind and sends no `activate`; lares-ime binds again (`rebound`) and the take's first route is the field:
//      its live words and finals reach the window
//   L  (round 5) A TAKE SHORTER THAN THE LOAD: the stand-in model loads for 4 s (LARES_STT_STUB_LOAD_FILE); the take is stopped before
//      `running`; its words are written once the model is up, and the take ends by itself (not on the stop's wait)
//   K  (round 5) CAPTURE FROM THE PRESS, the real model, a helper just started (light, as after a shell start): the capture rig
//      (tools/dev/dictation_probe_capture.sh) presses fn+F10 through Hyprland 100 ms before a clip's first word and links the
//      recorder as WirePlumber would; the clip's first word is the first word written. The aura: the island group at the press,
//      all of it at `running`, the way out at the end (the asks, in order)
//   S  (round 5) A WINDOW TAKE (lares:dictate-source, through Hyprland): a stub `hyprctl activewindow` names a window (a
//      process built here) whose CHILD starts playing a clip 3 s after the press, and another app's stream plays beside it. The
//      caption first says it waits for sound, the window's stream is linked when it comes and NOTHING else is (the fixture's own
//      `pw-link -l`), the caption shows live words, the transcript lands on the stub clipboard with "Transcript copied", the
//      caption is withdrawn, the mic and the aura untouched, the take log's route "source" with the stream it linked
//   Q  (round 5) A VOICE ASK (lares:dictate-ask): a terminal window (a shell on a pty in a directory made here), a clip in
//      the mic, and the take ENDS BY ITSELF after the question: a stub `voiceAsk` gets the words and the window's class, title and
//      the shell's directory, once; nothing typed, nothing copied, the mic and the aura as in A
//   C  the switch off: the global arrives and does nothing (no take, no helper, no input method)
//
// Every check prints `DICT ok|FAIL <check>: <detail>`; the last line is `DICT RESULT PASS|FAIL`.
// Env: DICT_FIXTURE (the fixture script), DICT_PW (its dir), DICT_CLIPS_A / DICT_CLIPS_B (space-separated wavs), DICT_REF_A (the
// clips' reference text, normalised), DICT_COPY (the stub wl-copy), DICT_STATE (the state dir), DICT_IME (a lares-ime to use: an arm's),
// DICT_FILLER (F's recording), DICT_PCI (the fake PCI tree the helper reads as LARES_STT_PCI_ROOT), DICT_TICLIENT (I's window),
// DICT_LOADFILE (L's slow load: the file LARES_STT_STUB_LOAD_FILE names), DICT_RIG / DICT_CAPWAV / DICT_CAPREF (K's rig, its recording
// and the recording's first reference word), DICT_CLIP_S / DICT_REF_S (S's window clip and its reference), DICT_CLIP_SB (the other
// app's clip), DICT_CLIP_Q / DICT_REF_Q (Q's question and its reference).
// =============================================================================
ShellRoot {
    id: root

    readonly property string fixture: Quickshell.env("DICT_FIXTURE") || ""
    readonly property string pwDir: Quickshell.env("DICT_PW") || ""
    readonly property string copyOut: (Quickshell.env("DICT_STATE") || "/tmp") + "/clipboard.txt"
    property int bad: 0
    property var auras: []
    property bool previewSeen: false
    property var fieldTexts: []

    function say(ok, what, detail) {
        if (!ok)
            root.bad += 1;
        console.log("DICT " + (ok ? "ok" : "FAIL") + " " + what + ": " + detail);
    }

    PipewireService {
        id: pw
    }

    DictationService {
        id: svc
        live: true
        rawConfig: ({ enabled: true, keepWarmMin: 1, logTakes: true })
        pipewire: pw
        stateDir: Quickshell.env("DICT_STATE") || ""
        imePath: Quickshell.env("DICT_IME") || (Quickshell.env("HOME") + "/.cache/lares-stt/bin/lares-ime")
        copyCommand: [Quickshell.env("DICT_COPY") || "true", root.copyOut]
        playAura: (palette, group, lifeMs) => {
            root.auras = root.auras.concat([palette + " " + group + " " + lifeMs]);
            return "playing on 1 screen(s)";
        }
        releaseAura: () => {
            root.auras = root.auras.concat(["release"]);
        }
        osd: osdStub
        llm: llmStub
        onToast: (title, body) => {
            root.toasts = root.toasts.concat([title + ": " + body]);
            console.log("DICT toast " + title + ": " + body);
        }
    }

    // ---- round 5's two other takes (S, Q): the caption's host and the LLM, stubbed; the window, the other app and the terminal ----
    property var toasts: []
    property var osdReqs: []
    property var asks: []
    QtObject {
        id: osdStub
        function show(req) {
            root.osdReqs = root.osdReqs.concat([JSON.parse(JSON.stringify(req))]);
            return true;
        }
        function withdraw(kind, key) {
            root.osdReqs = root.osdReqs.concat([{ withdraw: kind + ":" + key }]);
        }
    }
    QtObject {
        id: llmStub
        function voiceAsk(text, ctx) {
            root.asks = root.asks.concat([{ text: String(text), ctx: JSON.parse(JSON.stringify(ctx)) }]);
        }
    }
    readonly property string stateDir: Quickshell.env("DICT_STATE") || "/tmp"
    Process {
        id: fakeWin
        // the window: its pid is what the stub activewindow names; its CHILD plays 3 s later (a stream that comes after the press)
        command: ["setpriv", "--pdeathsig", "TERM", "--", "bash", "-c", "echo $$ > \"$1/winpid\"; sleep 3; pw-play --target 0 -P "
                  + "'{ node.name = app_a application.name = \"Fake player\" media.name = \"A video\" }' \"$2\"; exec sleep 600",
                  "sh", root.stateDir, Quickshell.env("DICT_CLIP_S") || ""]
    }
    Process {
        id: playerB
        command: ["setpriv", "--pdeathsig", "TERM", "--", "pw-play", "--target", "0", "-P", "{ node.name = app_b application.name = \"Other app\" }",
                  Quickshell.env("DICT_CLIP_SB") || ""]
    }
    Process {
        id: linkCheck
        command: ["pw-link", "-l"]
        stdout: StdioCollector {
            id: linkOut
        }
    }
    Process {
        id: fakeTerm
        // a terminal: a process whose child is a shell on a pty, in a directory of its own
        command: ["setpriv", "--pdeathsig", "TERM", "--", "python3", "-I", "-c",
                  "import os, pty, sys, time\nos.makedirs(sys.argv[1], exist_ok=True)\nos.chdir(sys.argv[1])\npid, fd = pty.fork()\n"
                  + "if pid == 0:\n    os.execvp('bash', ['bash', '--norc', '--noprofile', '-i'])\nopen(sys.argv[2], 'w').write(str(os.getpid()))\n"
                  + "time.sleep(600)\n", root.stateDir + "/askproj", root.stateDir + "/termpid"]
    }
    Process {
        id: pressMode
        property string what: "dictate-source"
        command: ["hyprctl", "dispatch", "hl.dsp.global(\"lares:" + pressMode.what + "\")"]
    }
    Process {
        id: readLog
        command: ["sh", "-c", "tail -n 1 \"$1/dictation/takes.jsonl\"", "sh", root.stateDir]
        stdout: StdioCollector {
            id: logOut
        }
    }
    function lastLog() {
        try {
            return JSON.parse(logOut.text.trim() || "{}");
        } catch (e) {
            return {};
        }
    }
    function refHits(text, ref) {
        const want = root.norm(ref).split(" ").filter(x => x !== "");
        const got = new Set(root.norm(text).split(" "));
        return { hit: want.filter(x => got.has(x)).length, of: want.length };
    }
    property var sFrom: null
    property var qFrom: null
    property bool sbStarted: false
    property string sLinks: ""
    property int sPresses: 0
    property string clipBefore: ""
    property string fieldBefore: ""

    // the keys as the shell registers them: A's start and C's press go through Hyprland's global shortcut (`hl.dsp.global`)
    DictationShortcuts {
        id: keys
        service: svc
    }
    Process {
        id: press
        command: ["hyprctl", "dispatch", "hl.dsp.global(\"lares:dictate\")"]
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 900
        implicitHeight: 120
        color: "#EAEDF5"
        TextInput {
            id: field
            anchors.fill: parent
            anchors.margins: 12
            focus: true
            wrapMode: TextInput.Wrap
            font.pixelSize: 16
            onPreeditTextChanged: if (field.preeditText !== "") root.previewSeen = true
            onTextChanged: root.fieldTexts = root.fieldTexts.concat([field.text])
        }
    }

    FloatingWindow {
        id: win2
        visible: false
        implicitWidth: 900
        implicitHeight: 120
        color: "#EAEDF5"
        TextInput {
            id: field2
            anchors.fill: parent
            anchors.margins: 12
            focus: true
            font.pixelSize: 16
            // a secret field for D (what a Qt app gives a passphrase it does not mask); E types into it with the hints gone
            inputMethodHints: Qt.ImhHiddenText | Qt.ImhSensitiveData
        }
    }

    // ---- the steps ------------------------------------------------------------------------------------------------------------------
    Process {
        id: player
        property string clips: ""
        command: ["bash", root.fixture, "play", root.pwDir, "2.0"].concat(player.clips.split(" ").filter(x => x !== ""))
    }
    Process {
        id: micState
        command: ["bash", root.fixture, "state", root.pwDir]
        stdout: StdioCollector {
            id: micOut
        }
    }
    Process {
        id: readCopy
        command: ["cat", root.copyOut]
        stdout: StdioCollector {
            id: copyText
        }
    }

    readonly property string marker: (Quickshell.env("DICT_STATE") || "/tmp") + "/escape-fired"
    Process {
        id: escapeBind
        command: ["hyprctl", "eval", "hl.bind(\"Escape\", hl.dsp.exec_cmd(\"touch " + root.marker + "\"))"]
        stdout: StdioCollector {
            id: bindOut
        }
    }
    Process {
        id: typer
        command: [svc.imePath, "--type-only"]
        stdinEnabled: true
        onStarted: {
            typer.write("type\thello world\n");
            typer.write("quit\n");
            typer.stdinEnabled = false;
        }
        stdout: StdioCollector {
            id: typerOut
        }
    }
    Process {
        id: markerCheck
        command: ["sh", "-c", "test -e \"$1\" && echo FIRED || echo quiet", "sh", root.marker]
        stdout: StdioCollector {
            id: markerOut
        }
    }
    property var dFrom: null
    property var fFrom: null
    property var gFrom: null
    property var hFrom: null
    readonly property string pciDir: Quickshell.env("DICT_PCI") || ""
    Process {
        id: fakeCard
        // a card on the bus with the nvidia driver, as sysfs shows one in Hybrid mode (vendor, class, the driver link)
        command: ["sh", "-c", "d=\"$1/0000:01:00.0\"; mkdir -p \"$d\" \"$1/drivers/nvidia\" && printf '0x10de\\n' > \"$d/vendor\" "
                  + "&& printf '0x030000\\n' > \"$d/class\" && ln -sfn \"$1/drivers/nvidia\" \"$d/driver\" && echo made", "sh", root.pciDir]
        stdout: StdioCollector {
            id: fakeCardOut
        }
    }
    // I: the window whose text input is made and enabled before the bind
    property var ticLines: []
    Process {
        id: tic
        command: [Quickshell.env("DICT_TICLIENT") || "true"]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => root.ticLines = root.ticLines.concat(String(data).split("\n").filter(x => x !== ""))
        }
    }
    // L: the stand-in model's load time, written to the file the helper reads (none: no delay)
    readonly property string loadFile: Quickshell.env("DICT_LOADFILE") || ""
    Process {
        id: loadSet
        property string ms: "0"
        command: ["sh", "-c", "printf '%s' \"$2\" > \"$1\"", "sh", root.loadFile, loadSet.ms]
    }
    // K: the capture rig
    property var rigLines: []
    Process {
        id: rig
        command: ["bash", Quickshell.env("DICT_RIG") || "/dev/null", root.pwDir, Quickshell.env("DICT_CAPWAV") || "", "1500", "100"]
        stdout: SplitParser {
            onRead: data => root.rigLines = root.rigLines.concat(String(data).split("\n").filter(x => x !== ""))
        }
    }
    function rigMs(what) {
        const l = root.rigLines.find(x => x.indexOf("CAPRIG " + what + " ") === 0);
        return l ? parseInt(l.split(" ")[2]) : NaN;
    }
    property var iFrom: null
    property var lFrom: null
    property var kFrom: null

    function fillerIn(t) {
        return /(^|\s)(uh|um|uhm|ehm|er)[,.]?(\s|$)/i.test(String(t));
    }

    property int step: 0
    property double stepAt: 0
    property string micBefore: ""
    property string micDuring: ""
    property string micAfter: ""
    property int takeA: 0
    property int pressesBefore: 0
    function go(n) {
        root.step = n;
        root.stepAt = Date.now();
    }
    // THE LOG IS CAPPED (the service keeps its last 200 notes), so a step marks the newest note it saw, never an index
    function mark() {
        return svc.log.length > 0 ? svc.log[svc.log.length - 1] : null;
    }
    function since(m) {
        const i = m === null ? -1 : svc.log.lastIndexOf(m);
        return svc.log.slice(i + 1);
    }
    function hyps(take) {
        return svc.log.filter(e => e.ev === "hyp");
    }
    function norm(t) {
        // case and punctuation off (a word that only gained a full stop is the same word)
        return String(t).toLowerCase().replace(/[.,!?;:"()\[\]\u2026-]+/g, " ").replace(/\s+/g, " ").trim();
    }

    Timer {
        interval: 100
        running: true
        repeat: true
        onTriggered: {
            const age = Date.now() - root.stepAt;
            switch (root.step) {
            case 0:
                root.go(1);
                win.visible = true;
                break;
            case 1:   // the checks done, the mic seen (muted, by the fixture)
                if (svc.log.some(e => e.ev === "checked") && pw.defaultSource && pw.defaultSource.audio && !micState.running) {
                    micState.running = true;
                    root.go(2);
                } else if (age > 20000) {
                    root.say(false, "setup", "no checked / no default source in 20 s (source " + (pw.defaultSource ? pw.defaultSource.name : "none") + ")");
                    root.go(99);
                }
                break;
            case 2:
                if (micState.running)
                    break;
                root.micBefore = micOut.text.trim();
                root.say(svc.log.some(e => e.ev === "checked" && e.helper && e.ime), "setup", "the helper and lares-ime are there; mic " + root.micBefore
                         + ", default source " + pw.defaultSource.name);
                if (Quickshell.env("DICT_FROM") === "I") {
                    // a developer's shortcut (DICTATION_FROM=I in the runner): round 5's steps alone -- never a verdict on the rest
                    svc.rawConfig = { enabled: true, keepWarmMin: 1, logTakes: true, model: "stub-speaker" };
                    root.ticLines = [];
                    tic.running = true;
                    root.go(70);
                    break;
                }
                press.running = true;      // fn+F10, through the compositor
                root.go(3);
                break;
            case 3:   // listening and the model loaded, then the clips (a cold load buffers what is said -- the first sentence would be
                      // heard whole at the load and A's live words would depend on how slow the load was on a busy machine)
                if (svc.state === "listening" && svc.log.some(e => e.ev === "route") && svc.log.some(e => e.ev === "loaded")) {
                    root.say(keys.presses.length === 1, "A the key", keys.presses.length + " press of lares:dictate arrived through Hyprland");
                    micState.running = true;
                    player.clips = Quickshell.env("DICT_CLIPS_A") || "";
                    player.running = true;
                    root.go(4);
                } else if (age > 60000) {
                    root.say(false, "A start", "not listening in 60 s (state " + svc.state + ")");
                    root.go(99);
                }
                break;
            case 4:   // the clips played, every sentence final: stop
                if (root.micDuring === "" && !micState.running)
                    root.micDuring = micOut.text.trim();
                if (!player.running && age > 3000 && svc.liveText === "") {
                    svc.toggle("");
                    root.go(5);
                } else if (age > 120000) {
                    root.say(false, "A play", "the clips never finished");
                    root.go(99);
                }
                break;
            case 5:
                if (svc.state === "idle") {
                    micState.running = true;
                    root.go(6);
                } else if (age > 15000) {
                    root.say(false, "A stop", "not idle 15 s after the stop");
                    root.go(99);
                }
                break;
            case 6: {
                if (micState.running)
                    break;
                root.micAfter = micOut.text.trim();
                const hs = svc.log.filter(e => e.ev === "hyp");
                const segs = svc.log.filter(e => e.ev === "seg" && e.text !== "");
                const firstSeg = svc.log.findIndex(e => e.ev === "seg");
                root.say(firstSeg > 0 && svc.log.slice(0, firstSeg).filter(e => e.ev === "hyp").length >= 2, "A live words",
                         hs.length + " hypotheses, " + svc.log.slice(0, Math.max(0, firstSeg)).filter(e => e.ev === "hyp").length + " before the first final");
                root.say(root.previewSeen, "A preedit in the field", root.previewSeen ? "the field showed provisional words" : "the field never showed a preedit");
                // a revision: a later hypothesis (or the final) changes a word an earlier one of the same sentence showed
                let revs = 0, ex = "";
                const last = {};
                for (const e of svc.log) {
                    if (e.ev !== "hyp" && e.ev !== "seg")
                        continue;
                    const w = root.norm(e.text).split(" ");
                    const o = last[e.seg];
                    if (o) {
                        const n = Math.min(o.length, w.length);
                        for (let i = 0; i < n; i++) {
                            if (o[i] !== w[i]) {
                                revs++;
                                if (ex === "")
                                    ex = "'" + o[i] + "' -> '" + w[i] + "' (" + e.ev + ")";
                                break;
                            }
                        }
                    }
                    last[e.seg] = w;
                }
                root.say(revs > 0, "A revision", revs + " hypotheses changed a word already shown" + (ex ? ", e.g. " + ex : ""));
                const committed = root.norm(segs.map(e => e.text).join(" "));
                const inField = root.norm(field.text);
                root.say(segs.length >= 2 && inField === committed && field.preeditText === "", "A final text in the field",
                         segs.length + " sentences; field \"" + field.text.substring(0, 160) + "\"" + (inField === committed ? "" : " != committed \"" + committed.substring(0, 160) + "\""));
                // a rough sanity of the words: most of the reference's words are in the field
                const ref = root.norm(Quickshell.env("DICT_REF_A") || "").split(" ").filter(x => x !== "");
                const got = new Set(inField.split(" "));
                const hit = ref.filter(x => got.has(x)).length;
                root.say(ref.length > 0 && hit / ref.length >= 0.7, "A words heard", hit + " of " + ref.length + " reference words are in the field");
                root.say(root.micBefore.indexOf("mute=true") === 0 && root.micDuring.indexOf("mute=false") === 0 && root.micAfter.indexOf("mute=true") === 0,
                         "A mic", "before " + root.micBefore + ", listening " + root.micDuring + ", after " + root.micAfter);
                // round 5: the island group at the press, all of it once words can appear, the way out at the end
                const runAt = svc.log.findIndex(e => e.ev === "running");
                const islandAt = svc.log.findIndex(e => e.ev === "aura" && e.group === "island");
                const allAt = svc.log.findIndex(e => e.ev === "aura" && e.group === "all");
                root.say(root.auras.length === 3 && root.auras[0] === "siri island 600000" && root.auras[1] === "siri all 600000"
                         && root.auras[2] === "release" && islandAt >= 0 && islandAt < runAt && runAt < allAt,
                         "A aura", root.auras.join(" | ") + " (island ask at log " + islandAt + ", running " + runAt + ", all " + allAt + ")");
                root.say(!svc.log.some(e => e.ev === "rebound"), "A no rebind", "a Qt field activates at the first bind: "
                         + svc.log.filter(e => e.ev === "rebound").length + " rebind(s)");
                root.say(svc.route === "ime", "A route", "the take went " + svc.route);
                // round 4: the device from the (stubbed) fact -- no card in the tree: the iGPU; and the tidy pass off by default
                const devA = svc.log.filter(e => e.ev === "device");
                root.say(devA.length === 1 && devA[0].cls === "igpu" && devA[0].dgpu === false, "A device",
                         devA.map(e => e.cls + " (" + e.why + ")").join(", ") || "no device event");
                const segsA = svc.log.filter(e => e.ev === "seg" && e.text !== "");
                root.say(segsA.length > 0 && segsA.every(e => !e.tidy) && !segsA.some(e => root.fillerIn(e.text)), "A tidy off",
                         segsA.length + " finals, " + segsA.filter(e => e.tidy).length + " with a tidy verdict");
                // B: no field (the window goes; a field that merely loses the focus keeps the text input enabled in Qt)
                win.visible = false;
                root.go(7);
                break;
            }
            case 7:
                if (age > 1500) {
                    svc.toggle("");
                    root.go(8);
                }
                break;
            case 8:
                if (svc.state === "listening" && svc.log.slice(-40).some(e => e.ev === "route")) {
                    player.clips = Quickshell.env("DICT_CLIPS_B") || "";
                    player.running = true;
                    root.go(9);
                } else if (age > 30000) {
                    root.say(false, "B start", "not listening in 30 s");
                    root.go(99);
                }
                break;
            case 9:
                if (!player.running && age > 3000 && svc.liveText === "") {
                    svc.toggle("");
                    root.go(10);
                } else if (age > 90000) {
                    root.say(false, "B play", "the clip never finished");
                    root.go(99);
                }
                break;
            case 10:
                if (svc.state === "idle" && age > 800) {
                    readCopy.running = true;
                    root.go(11);
                } else if (age > 15000) {
                    root.say(false, "B stop", "not idle 15 s after the stop");
                    root.go(99);
                }
                break;
            case 11: {
                if (readCopy.running)
                    break;
                const fin = svc.log.filter(e => e.ev === "finished").slice(-1)[0] || {};
                const clip = copyText.text.trim();
                const rb = svc.log.filter(e => e.ev === "rebound").slice(-1)[0];
                root.say(fin.route === "clipboard" && clip !== "" && root.norm(clip) === root.norm(fin.clip || ""), "B clipboard",
                         "route " + fin.route + "; wl-copy got \"" + clip.substring(0, 120) + "\"; with no field the rebind "
                         + (rb ? "cost " + rb.ms + " ms" : "did not run"));
                root.go(20);
                break;
            }
            case 20:   // D: a secret field, in a window of its own (a newly mapped window takes the keyboard)
                win2.visible = true;
                root.go(21);
                break;
            case 21:
                if (age > 1500) {
                    root.dFrom = root.mark();
                    svc.toggle("");
                    root.go(22);
                }
                break;
            case 22:
                if (svc.state === "listening" && root.since(root.dFrom).some(e => e.ev === "route")) {
                    player.clips = Quickshell.env("DICT_CLIPS_B") || "";
                    player.running = true;
                    root.go(23);
                } else if (age > 30000) {
                    root.say(false, "D start", "not listening in 30 s");
                    root.go(99);
                }
                break;
            case 23:
                if (!player.running && age > 3000 && svc.liveText === "") {
                    svc.toggle("");
                    root.go(24);
                } else if (age > 90000) {
                    root.say(false, "D play", "the clip never finished");
                    root.go(99);
                }
                break;
            case 24:
                if (svc.state === "idle" && age > 800) {
                    const d = root.since(root.dFrom);
                    const segs = d.filter(e => e.ev === "seg" && e.text !== "").length;
                    const fin = d.filter(e => e.ev === "finished").slice(-1)[0] || {};
                    root.say(segs > 0 && field2.text === "" && d.some(e => e.ev === "refused") && !d.some(e => e.ev === "commit")
                             && (fin.clip || "") === "", "D secret field",
                             segs + " sentences heard; the field holds " + field2.text.length + " characters; refused "
                             + d.filter(e => e.ev === "refused").length + " time(s), committed " + d.filter(e => e.ev === "commit").length
                             + ", clipboard \"" + (fin.clip || "") + "\"");
                    field2.inputMethodHints = Qt.ImhNone;
                    field2.text = "";
                    escapeBind.running = true;
                    root.go(30);
                } else if (age > 15000) {
                    root.say(false, "D stop", "not idle 15 s after the stop");
                    root.go(99);
                }
                break;
            case 30:   // E: typing, with a bare-Escape bind armed in the compositor
                if (!escapeBind.running && age > 1000) {
                    typer.stdinEnabled = true;
                    typer.running = true;
                    root.go(31);
                }
                break;
            case 31:
                if (!typer.running && age > 1500) {
                    markerCheck.running = true;
                    root.go(32);
                } else if (age > 15000) {
                    root.say(false, "E typing", "lares-ime did not end");
                    root.go(99);
                }
                break;
            case 32:
                if (!markerCheck.running) {
                    const fired = markerOut.text.trim() === "FIRED";
                    root.say(field2.text === "hello world" && !fired, "E typing",
                             "the field got \"" + field2.text + "\" (" + typerOut.text.trim().replace(/\n/g, " | ") + "); the Escape bind "
                             + (fired ? "FIRED" : "stayed quiet") + " (bind: " + (bindOut.text.trim() || "ok") + ")");
                    // F: fillers, on the stand-in decoder, in the field of the first window
                    win2.visible = false;
                    field.text = "";
                    win.visible = true;
                    svc.rawConfig = { enabled: true, keepWarmMin: 1, logTakes: true, model: "stub-speaker" };
                    root.go(40);
                }
                break;
            case 40:
                if (age > 1500) {
                    root.fFrom = root.mark();
                    svc.toggle("");
                    root.go(41);
                }
                break;
            case 41:
                if (svc.state === "listening" && root.since(root.fFrom).some(e => e.ev === "route")) {
                    player.clips = Quickshell.env("DICT_FILLER") || "";
                    player.running = true;
                    root.go(42);
                } else if (age > 30000) {
                    root.say(false, "F start", "not listening in 30 s");
                    root.go(99);
                }
                break;
            case 42:
                if (!player.running && age > 3000 && svc.liveText === "") {
                    svc.toggle("");
                    root.go(43);
                } else if (age > 90000) {
                    root.say(false, "F play", "the recording never finished");
                    root.go(99);
                }
                break;
            case 43:
                if (svc.state === "idle" && age > 800) {
                    const f = root.since(root.fFrom);
                    const segs = f.filter(e => e.ev === "seg");
                    const shown = f.filter(e => (e.ev === "hyp" || e.ev === "seg") && root.fillerIn(e.text));
                    const heard = segs.filter(e => root.fillerIn(e.raw));
                    root.say(heard.length > 0 && shown.length === 0 && !root.fillerIn(field.text), "F fillers",
                             heard.length + " final(s) heard \"uh\"; " + shown.length + " hypothesis / final showed it; field \""
                             + field.text.substring(0, 120) + "\"");
                    const joined = segs.filter(e => root.fillerIn(e.raw) && /MARK/.test(e.raw) && /MARK/.test(e.text));
                    const thinks = f.filter(e => e.ev === "think").length;
                    root.say(thinks > 0 && joined.length === 1 && field.text.indexOf("MARK") >= 0, "F think",
                             thinks + " thinking pause(s); " + segs.length + " finals: "
                             + segs.map(e => "[" + e.cut + "] " + e.raw.substring(0, 60)).join(" | "));
                    // G: the tidy pass on, its model the stub that adds a word
                    field.text = "";
                    svc.rawConfig = { enabled: true, keepWarmMin: 1, logTakes: true, model: "stub-speaker", tidy: true };
                    root.go(50);
                } else if (age > 15000) {
                    root.say(false, "F stop", "not idle 15 s after the stop");
                    root.go(99);
                }
                break;
            case 50:
                if (age > 1000) {
                    root.gFrom = root.mark();
                    svc.toggle("");
                    root.go(51);
                }
                break;
            case 51:
                if (svc.state === "listening" && root.since(root.gFrom).some(e => e.ev === "route")) {
                    player.clips = Quickshell.env("DICT_CLIPS_B") || "";
                    player.running = true;
                    root.go(52);
                } else if (age > 30000) {
                    root.say(false, "G start", "not listening in 30 s");
                    root.go(99);
                }
                break;
            case 52:
                if (!player.running && age > 3000 && svc.liveText === "") {
                    svc.toggle("");
                    root.go(53);
                } else if (age > 90000) {
                    root.say(false, "G play", "the clip never finished");
                    root.go(99);
                }
                break;
            case 53:
                if (svc.state === "idle" && age > 800) {
                    const g = root.since(root.gFrom);
                    const segs = g.filter(e => e.ev === "seg" && e.text !== "");
                    const refused = segs.filter(e => e.tidy && e.tidy.ok === false && String(e.tidy.why).indexOf("added") === 0);
                    root.say(segs.length > 0 && refused.length === segs.length && field.text !== "" && field.text.indexOf("banana") < 0,
                             "G tidy", segs.length + " finals, " + refused.length + " proposals refused ("
                             + (segs[0] && segs[0].tidy ? segs[0].tidy.why : "no verdict") + "); field \"" + field.text.substring(0, 100) + "\"");
                    // H: a card appears in the fake PCI tree
                    field.text = "";
                    svc.rawConfig = { enabled: true, keepWarmMin: 1, logTakes: true };
                    fakeCard.running = true;
                    root.go(60);
                } else if (age > 15000) {
                    root.say(false, "G stop", "not idle 15 s after the stop");
                    root.go(99);
                }
                break;
            case 60:
                if (!fakeCard.running && age > 1000) {
                    root.hFrom = root.mark();
                    svc.toggle("");
                    root.go(61);
                }
                break;
            case 61:
                if (svc.state === "listening" && root.since(root.hFrom).some(e => e.ev === "route")) {
                    player.clips = Quickshell.env("DICT_CLIPS_B") || "";
                    player.running = true;
                    root.go(62);
                } else if (age > 60000) {
                    root.say(false, "H start", "not listening in 60 s");
                    root.go(99);
                }
                break;
            case 62:
                if (!player.running && age > 3000 && svc.liveText === "") {
                    svc.toggle("");
                    root.go(63);
                } else if (age > 120000) {
                    root.say(false, "H play", "the clip never finished");
                    root.go(99);
                }
                break;
            case 63:
                if (svc.state === "idle" && age > 800) {
                    const h = root.since(root.hFrom);
                    const dev = h.filter(e => e.ev === "device");
                    const segs = h.filter(e => e.ev === "seg" && e.text !== "");
                    root.say(fakeCardOut.text.trim() === "made" && dev.length === 2 && dev[0].cls === "cuda" && dev[0].dgpu === true
                             && dev[1].cls === "igpu" && dev[1].fallback === true && segs.length > 0, "H device",
                             dev.map(e => e.cls + (e.fallback ? " (fallback: " : " (") + String(e.why).substring(0, 90) + ")").join(" -> ")
                             + "; " + segs.length + " finals written");
                    // I: the first take live, in a window whose field was enabled before the bind
                    svc.rawConfig = { enabled: true, keepWarmMin: 1, logTakes: true, model: "stub-speaker" };
                    root.ticLines = [];
                    tic.running = true;
                    root.go(70);
                } else if (age > 15000) {
                    root.say(false, "H stop", "not idle 15 s after the stop");
                    root.go(99);
                }
                break;
            case 70:   // I: the window mapped, focused, its text input made and entered (and enabled) with no input method
                if (root.ticLines.indexOf("ti-enter") >= 0 && age > 800) {
                    root.iFrom = root.mark();
                    svc.toggle("");
                    root.go(71);
                } else if (age > 15000) {
                    root.say(false, "I start", "the stand-in window never had its text input entered: " + root.ticLines.join(" "));
                    root.go(99);
                }
                break;
            case 71:
                if (svc.state === "listening" && root.since(root.iFrom).some(e => e.ev === "route")) {
                    player.clips = Quickshell.env("DICT_CLIPS_B") || "";
                    player.running = true;
                    root.go(72);
                } else if (age > 30000) {
                    root.say(false, "I start", "not listening in 30 s");
                    root.go(99);
                }
                break;
            case 72:
                if (!player.running && age > 3000 && svc.liveText === "") {
                    svc.toggle("");
                    root.go(73);
                } else if (age > 90000) {
                    root.say(false, "I play", "the clip never finished");
                    root.go(99);
                }
                break;
            case 73:
                if (svc.state === "idle" && age > 800) {
                    const it = root.since(root.iFrom);
                    const routes = it.filter(e => e.ev === "route").map(e => e.route);
                    const segs = it.filter(e => e.ev === "seg" && e.text !== "");
                    const pre = root.ticLines.filter(x => x.indexOf("preedit\t") === 0 && x.length > 8).length;
                    const got = root.norm(root.ticLines.filter(x => x.indexOf("commit\t") === 0).map(x => x.substring(7)).join(" "));
                    const want = root.norm(segs.map(e => e.text).join(" "));
                    const rb = it.filter(e => e.ev === "rebound");
                    root.say(routes.length > 0 && routes[0] === "ime" && routes.indexOf("clipboard") < 0 && pre > 0 && segs.length > 0
                             && got === want && rb.length === 1 && it.filter(e => e.ev === "activate").length === 1, "I first take live",
                             "routes " + routes.join(" -> ") + "; rebinds " + rb.length + (rb.length ? " (" + rb[0].ms + " ms)" : "") + "; activates "
                             + it.filter(e => e.ev === "activate").length + "; the window showed " + pre + " live preedit(s) and got \""
                             + got.substring(0, 100) + "\"" + (got === want ? "" : " != the finals \"" + want.substring(0, 100) + "\""));
                    tic.write("quit\n");
                    tic.stdinEnabled = false;
                    win.visible = false;      // mapped again below: a new window takes the keyboard back from the one that went
                    // L: a take shorter than the load (the helper started again, so the stand-in model loads afresh)
                    field.text = "";
                    loadSet.ms = "4000";
                    loadSet.running = true;
                    svc.rawConfig = { enabled: false };
                    root.go(80);
                } else if (age > 15000) {
                    root.say(false, "I stop", "not idle 15 s after the stop");
                    root.go(99);
                }
                break;
            case 80:
                if (!svc.helperRunning && !loadSet.running && age > 1000) {
                    win.visible = true;
                    svc.rawConfig = { enabled: true, keepWarmMin: 1, logTakes: true, model: "stub-speaker" };
                    root.go(81);
                }
                break;
            case 81:   // (the helper is back, light -- or, under ARM latecapture, started only by the press)
                if (age > 2000) {
                    root.lFrom = root.mark();
                    svc.toggle("");
                    root.go(82);
                }
                break;
            case 82:
                if (root.since(root.lFrom).some(e => e.ev === "capture")) {
                    player.clips = Quickshell.env("DICT_CLIPS_B") || "";
                    player.running = true;
                    root.go(83);
                } else if (age > 10000) {
                    root.say(false, "L start", "no capture in 10 s");
                    root.go(99);
                }
                break;
            case 83:   // stopped while the model still loads (4 s)
                if (age > 2500) {
                    svc.toggle("");
                    root.go(84);
                }
                break;
            case 84:
                if (svc.state === "idle" && age > 800) {
                    const lt = root.since(root.lFrom);
                    const stopAt = lt.findIndex(e => e.ev === "stop");
                    const runAt = lt.findIndex(e => e.ev === "running");
                    const segs = lt.filter(e => e.ev === "seg" && e.text !== "");
                    const fin = lt.filter(e => e.ev === "finished").slice(-1)[0] || {};
                    // written: into the field, or (no field) onto the clipboard
                    const said = root.norm(segs.map(e => e.text).join(" "));
                    const wrote = fin.route === "ime" ? root.norm(field.text) : root.norm(fin.clip || "");
                    root.say(stopAt >= 0 && lt[stopAt].running === false && runAt > stopAt && segs.length > 0 && fin.reason === "ended"
                             && wrote === said, "L stopped while loading",
                             "stop at log " + stopAt + " (running " + (stopAt >= 0 ? lt[stopAt].running : "?") + "), running at " + runAt + "; "
                             + segs.length + " final(s); the take ended by " + fin.reason + "; written (" + fin.route + ") \"" + wrote.substring(0, 80) + "\"");
                    loadSet.ms = "0";
                    loadSet.running = true;
                    // K: capture from the press, the real model, a helper just started
                    field.text = "";
                    root.auras = [];
                    svc.rawConfig = { enabled: false };
                    root.go(90);
                } else if (age > 30000) {
                    root.say(false, "L stop", "not idle 30 s after the stop");
                    root.go(99);
                }
                break;
            case 90:
                if (!svc.helperRunning && age > 1000) {
                    svc.rawConfig = { enabled: true, keepWarmMin: 1, logTakes: true };
                    root.go(91);
                }
                break;
            case 91:   // the helper back, light (as after a shell start); the rig presses
                if (age > 2500) {
                    root.kFrom = root.mark();
                    root.rigLines = [];
                    rig.running = true;
                    root.go(92);
                }
                break;
            case 92:
                if (!rig.running && age > 3000 && svc.state === "listening" && svc.liveText === "" && root.since(root.kFrom).some(e => e.ev === "running")) {
                    svc.toggle("");
                    root.go(93);
                } else if (age > 120000) {
                    root.say(false, "K play", "the rig never finished or the take never ran (state " + svc.state + "; " + root.rigLines.join(" | ") + ")");
                    root.go(99);
                }
                break;
            case 93:
                if (svc.state === "idle" && age > 800) {
                    const kt = root.since(root.kFrom);
                    const firstSeg = kt.find(e => e.ev === "seg" && e.text !== "") || {};
                    const first = root.norm(firstSeg.text || "").split(" ")[0] || "";
                    const want = Quickshell.env("DICT_CAPREF") || "?";
                    const lis = kt.find(e => e.ev === "listening") || {};
                    const run = kt.find(e => e.ev === "running") || {};
                    root.say(first === want, "K capture from the press",
                             "the speech began 100 ms after the press; the first word written \"" + first + "\" (the clip's \"" + want + "\"); rig: "
                             + root.rigLines.filter(x => x.indexOf(" end ") < 0).map(x => x.substring(7)).join(", ")
                             + " ms; helper: samples " + lis.ms + " ms after its start, running at " + run.ms + " ms; first sentence \""
                             + String(firstSeg.text || "").substring(0, 90) + "\"");
                    const runAt = kt.findIndex(e => e.ev === "running");
                    const islandAt = kt.findIndex(e => e.ev === "aura" && e.group === "island");
                    const allAt = kt.findIndex(e => e.ev === "aura" && e.group === "all");
                    root.say(root.auras.join(" | ") === "siri island 600000 | siri all 600000 | release" && islandAt >= 0 && islandAt < runAt
                             && runAt < allAt, "K aura", root.auras.join(" | ") + " (island at log " + islandAt + ", running " + runAt
                             + ", all " + allAt + ")");
                    // S: a window take
                    root.go(110);
                } else if (age > 20000) {
                    root.say(false, "K stop", "not idle 20 s after the stop");
                    root.go(99);
                }
                break;
            case 110:   // S: the window (its child plays 3 s after the press), the real model warm from K
                root.sFrom = root.mark();
                root.osdReqs = [];
                root.auras = [];
                root.toasts = [];
                root.sbStarted = false;
                root.sLinks = "";
                svc.activeWindowCommand = ["sh", "-c", "printf '{\"class\":\"fakeplayer\",\"title\":\"A video - Fake player\",\"pid\":%s}' \"$(cat \"$1/winpid\")\"",
                                           "sh", root.stateDir];
                fakeWin.running = true;
                micState.running = true;
                root.go(111);
                break;
            case 111:
                if (!micState.running && age > 800) {
                    root.micBefore = micOut.text.trim();
                    root.sPresses = keys.presses.length;
                    pressMode.what = "dictate-source";
                    pressMode.running = true;        // Ctrl+fn+F10, through the compositor
                    root.go(112);
                }
                break;
            case 112: {   // the other app starts beside the window's stream; the links are read while both play
                const st = root.since(root.sFrom).filter(e => e.ev === "sources");
                if (!root.sbStarted && age > 4000) {
                    playerB.running = true;
                    root.sbStarted = true;
                }
                if (root.sbStarted && root.sLinks === "" && age > 6500 && !linkCheck.running) {
                    root.sLinks = "reading";
                    linkCheck.running = true;
                }
                if (root.sLinks === "reading" && !linkCheck.running)
                    root.sLinks = linkOut.text;
                // the window's stream came and went (its clip played): the sentence it was in is written at the pause
                if (root.sLinks !== "" && root.sLinks !== "reading" && st.some(e => e.n > 0) && st[st.length - 1].n === 0 && svc.liveText === "") {
                    root.go(113);
                } else if (age > 60000) {
                    root.say(false, "S play", "the window's stream never came and went (" + st.map(e => e.n).join(",") + ")");
                    root.go(99);
                }
                break;
            }
            case 113:
                if (age > 2000) {
                    pressMode.what = "dictate-source";
                    pressMode.running = true;        // the key again: the stop
                    root.go(114);
                }
                break;
            case 114:
                if (svc.state === "idle" && age > 800) {
                    micState.running = true;
                    readCopy.running = true;
                    readLog.running = true;
                    root.go(115);
                } else if (age > 20000) {
                    root.say(false, "S stop", "not idle 20 s after the stop");
                    root.go(99);
                }
                break;
            case 115: {
                if (micState.running || readCopy.running || readLog.running)
                    break;
                const sl = root.since(root.sFrom);
                const pr = keys.presses.slice(root.sPresses);
                root.say(pr.length === 2 && pr[0] === "dictate-source" && pr[1] === "dictate-source", "S the key",
                         pr.join(", ") + " arrived through Hyprland");
                const caps = root.osdReqs.filter(r => r.kind === "caption");
                const firstLive = caps.findIndex(r => String(r.caption.live || "") !== "");
                const waitAt = caps.findIndex(r => String(r.caption.head).indexOf("Waiting for sound from") === 0);
                const st = sl.filter(e => e.ev === "sources");
                root.say(st.length >= 3 && st[0].n === 0 && st.some(e => e.n === 1) && waitAt >= 0 && (firstLive < 0 || waitAt < firstLive),
                         "S a stream after the press", "the linked streams over the take: " + st.map(e => e.n).join(" -> ") + "; the caption said \""
                         + (waitAt >= 0 ? caps[waitAt].caption.head : "?") + "\" first");
                // the fixture's own word: every link into the window capture comes from the window's stream (the other app played meanwhile)
                const into = [];
                let port = "";
                for (const l of root.sLinks.split("\n")) {
                    if (l.length > 0 && l[0] !== " ")
                        port = l.trim();
                    else if (l.indexOf("|<-") >= 0 && port.indexOf("lares-dictation-window:") === 0)
                        into.push(l.replace(/.*\|<-\s*/, "").trim());
                }
                const bPlayed = root.sLinks.indexOf("app_b:") >= 0;
                root.say(into.length > 0 && into.every(x => x.indexOf("app_a:") === 0) && bPlayed, "S only the window's streams",
                         "links into the capture from " + (into.join(", ") || "nothing") + "; the other app " + (bPlayed ? "was playing" : "was NOT playing"));
                const live = caps.filter(r => r.caption.mode === "source" && String(r.caption.live || "") !== "");
                const heads = [];
                for (const r of caps)
                    if (heads.indexOf(r.caption.head) < 0)
                        heads.push(r.caption.head);
                root.say(live.length > 0 && caps.length > 0 && caps.every(r => r.key === "dictation") && heads.some(h => h.indexOf("Transcribing Fake player") === 0),
                         "S live words", live.length + " caption(s) with live words (e.g. \"" + (live.length ? live[0].caption.live.substring(0, 60) : "") + "\"); heads " + heads.join(" | "));
                const said = sl.filter(e => e.ev === "seg" && e.text !== "").map(e => e.text).join(" ");
                const h = root.refHits(copyText.text, Quickshell.env("DICT_REF_S") || "");
                root.say(copyText.text.trim() === said.trim() && said !== "" && h.of > 0 && h.hit / h.of >= 0.7 && root.toasts.some(t => t.indexOf("Transcript copied: ") === 0),
                         "S transcript", h.hit + " of " + h.of + " reference words on the clipboard; \"" + copyText.text.trim().substring(0, 100) + "\"; toasts " + root.toasts.join(" | "));
                const lastShow = root.osdReqs.map(r => !!r.kind).lastIndexOf(true);
                const wd = root.osdReqs.findIndex(r => r.withdraw === "caption:dictation");
                root.say(wd > lastShow && lastShow >= 0, "S caption withdrawn", root.osdReqs.length + " requests, the withdraw at " + wd + ", the last show at " + lastShow);
                root.micAfter = micOut.text.trim();
                root.say(root.micBefore !== "" && root.micAfter === root.micBefore && !sl.some(e => e.ev === "mic" || e.ev === "micrestore") && root.auras.length === 0,
                         "S mic untouched", "before " + root.micBefore + ", after " + root.micAfter + "; mic notes "
                         + sl.filter(e => e.ev === "mic" || e.ev === "micrestore").length + "; aura asks " + root.auras.length);
                const lg = root.lastLog();
                root.say(lg.route === "source" && Array.isArray(lg.streams) && lg.streams.length === 1 && lg.streams[0].app === "Fake player",
                         "S take log", "route " + lg.route + ", streams " + JSON.stringify(lg.streams || null));
                fakeWin.running = false;
                // Q: a voice ask from a terminal window
                root.go(120);
                break;
            }
            case 120:
                root.qFrom = root.mark();
                root.osdReqs = [];
                root.auras = [];
                root.toasts = [];
                root.asks = [];
                root.micDuring = "";
                svc.activeWindowCommand = ["sh", "-c", "printf '{\"class\":\"kitty\",\"title\":\"bash\",\"pid\":%s}' \"$(cat \"$1/termpid\")\"", "sh", root.stateDir];
                fakeTerm.running = true;
                micState.running = true;
                readCopy.running = true;
                root.go(121);
                break;
            case 121:
                if (!micState.running && !readCopy.running && age > 1000) {
                    root.micBefore = micOut.text.trim();
                    root.clipBefore = copyText.text;
                    root.fieldBefore = field.text;
                    root.sPresses = keys.presses.length;
                    pressMode.what = "dictate-ask";
                    pressMode.running = true;        // Alt+fn+F10
                    root.go(122);
                }
                break;
            case 122:
                if (svc.state === "listening" && root.since(root.qFrom).some(e => e.ev === "running")) {
                    player.clips = Quickshell.env("DICT_CLIP_Q") || "";
                    player.running = true;
                    micState.running = true;
                    root.go(123);
                } else if (age > 60000) {
                    root.say(false, "Q start", "not listening in 60 s (state " + svc.state + ")");
                    root.go(99);
                }
                break;
            case 123:   // no stop: the ask ends by itself after the question
                if (root.micDuring === "" && !micState.running)
                    root.micDuring = micOut.text.trim();
                if (svc.state === "idle" && root.micDuring !== "") {
                    micState.running = true;
                    readCopy.running = true;
                    readLog.running = true;
                    root.go(124);
                } else if (age > 90000) {
                    root.say(false, "Q end", "the ask never ended by itself (state " + svc.state + ")");
                    root.go(99);
                }
                break;
            case 124: {
                if (micState.running || readCopy.running || readLog.running)
                    break;
                const ql = root.since(root.qFrom);
                const pr = keys.presses.slice(root.sPresses);
                const fin = ql.filter(e => e.ev === "finished").slice(-1)[0] || {};
                root.say(pr.length === 1 && pr[0] === "dictate-ask" && ql.some(e => e.ev === "askend") && fin.reason === "ended", "Q the key and the end",
                         pr.join(", ") + " arrived; the take ended by " + (ql.some(e => e.ev === "askend") ? "itself" : "the key") + " (" + fin.reason + ")");
                const a = root.asks[0] || { text: "", ctx: {} };
                const h = root.refHits(a.text, Quickshell.env("DICT_REF_Q") || "");
                const dir = root.stateDir + "/askproj";
                root.say(root.asks.length === 1 && h.of > 0 && h.hit / h.of >= 0.7 && a.ctx.windowClass === "kitty" && a.ctx.windowTitle === "bash" && a.ctx.cwd === dir,
                         "Q voice ask", root.asks.length + " ask(s); " + h.hit + " of " + h.of + " reference words; \"" + a.text.substring(0, 80) + "\"; context "
                         + JSON.stringify(a.ctx));
                root.say(field.text === root.fieldBefore && copyText.text === root.clipBefore && !ql.some(e => ["activate", "commit", "copied", "typed", "held"].indexOf(e.ev) >= 0),
                         "Q nothing typed or copied", "field " + (field.text === root.fieldBefore ? "unchanged" : "CHANGED") + ", clipboard "
                         + (copyText.text === root.clipBefore ? "unchanged" : "CHANGED") + ", input method / copy notes "
                         + ql.filter(e => ["activate", "commit", "copied", "typed", "held"].indexOf(e.ev) >= 0).length);
                root.micAfter = micOut.text.trim();
                root.say(root.micBefore.indexOf("mute=true") === 0 && root.micDuring.indexOf("mute=false") === 0 && root.micAfter.indexOf("mute=true") === 0
                         && root.auras.join(" | ") === "siri island 600000 | siri all 600000 | release", "Q mic and aura",
                         "mic " + root.micBefore + " / " + root.micDuring + " / " + root.micAfter + "; aura " + root.auras.join(" | "));
                const caps = root.osdReqs.filter(r => r.kind === "caption" && r.caption.mode === "ask");
                const lg = root.lastLog();
                root.say(caps.some(r => String(r.caption.live || "") !== "") && root.osdReqs.some(r => r.withdraw === "caption:dictation") && lg.route === "ask",
                         "Q caption and log", caps.length + " caption(s) of the ask; withdrawn " + root.osdReqs.some(r => r.withdraw === "caption:dictation")
                         + "; take log route " + lg.route);
                fakeTerm.running = false;
                // C: the switch off
                svc.activeWindowCommand = ["hyprctl", "-j", "activewindow"];
                svc.rawConfig = { enabled: false };
                root.go(12);
                break;
            }
            case 12:
                if (age > 1500) {
                    root.takeA = svc._take;
                    root.pressesBefore = keys.presses.length;
                    press.running = true;  // the global, with the switch off
                    root.go(13);
                }
                break;
            case 13:
                if (age > 2500) {
                    const pr = svc.log.filter(e => e.ev === "press").slice(-1)[0] || {};
                    root.say(keys.presses.length === root.pressesBefore + 1 && pr.enabled === false && svc._take === root.takeA
                             && svc.state === "idle" && !svc.helperRunning,
                             "C switch off", "the global arrived (" + (keys.presses.length - root.pressesBefore) + " press), logged with enabled "
                             + pr.enabled + "; take " + svc._take + " (was " + root.takeA + "), state " + svc.state + ", helper "
                             + (svc.helperRunning ? "RUNNING" : "stopped"));
                    root.go(99);
                }
                break;
            case 99:
                console.log("DICT log " + JSON.stringify(svc.log.filter(e => e.ev !== "hyp").slice(-60)).slice(-6000));
                console.log("DICT RESULT " + (root.bad === 0 ? "PASS" : "FAIL"));
                root.go(100);
                quitTimer.start();
                break;
            }
        }
    }
    Timer {
        id: quitTimer
        interval: 300
        onTriggered: Qt.quit()
    }
    // a harness smoked bare drives nothing (CLAUDE.md): with no fixture it says so and quits
    Timer {
        interval: 0
        running: root.fixture === ""
        onTriggered: {
            console.log("DICT RESULT FAIL (no runner: DICT_FIXTURE unset)");
            Qt.quit();
        }
    }
}
