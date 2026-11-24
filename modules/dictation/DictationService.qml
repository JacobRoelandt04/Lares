pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../common/components"
import "../common/system"
import "DictationText.js" as DT

// =============================================================================
// DictationService.qml -- dictation, ONE per shell (ShellServices `dictation`): a key toggles a take; the words appear live in the
// focused text field and fix themselves as you speak; a pause writes the sentence for good. A PROTOTYPE behind an off switch
// (shell.jsonc `"dictation": { "enabled": true }`; docs/dictation.md; the design is
// docs/agent_added_files_and_folders/stt/research.md section 8).
//
//   toggle(lang)        "" detects English / Dutch per take, "nl" / "en" force it (the keys: lares:dictate, dictate-nl)
//   holdPress(lang), holdRelease()   the same two keys when they take while they are held (HOLD)
//   toggleMode(m, lang) "type" (toggle's) | "source" (the focused window's sound) | "ask" (a question for the LLM)
//   state               idle | starting | listening | stopping        route   "" | shell | ime | type | clipboard | source | ask
//   liveText            the words of the sentence being spoken (the preedit)          language   the take's language
//   log                 the probe's record: one entry per thing done, oldest first (the last 200)
//
// THE TWO HELPERS. `lares-stt` (tools/stt/lares_stt.py, the private venv's Python): the microphone, the VAD, the model, the language,
// the revision policy -- a SupervisedStream that runs, LIGHT (the standard library only, ~50 ms to `ready`, no model), whenever the
// switch is on, so a press starts the capture at once (round 5: "nothing said after the press is lost"). The take's models load
// while it captures; the audio from the press is decoded once they are up (`running`). `keepWarmMin` after the last take the helper
// is started again, light (`preload`: never -- its models stay). `lares-ime` (tools/stt/ime, C, built into the cache): the input
// method, started per take and ended per take, so no app sees an input method unless you are dictating; when no `activate` came
// 200 ms after its `ready` it binds once more (`rebound`: a field enabled before the bind, lares-ime.c THE REBIND), and the route wait
// starts again.
//
// WHERE THE TEXT GOES (decided at the take's start, followed through it): (0) THE SHELL'S OWN FIELD (route `shell`, round 6): a
// popup content whose field has the caret takes the words itself, with no input method -- Hyprland never announces the shell's own
// layer-surface fields to a new input method, so a take into the notes editor went to the clipboard; (1) the focused field through
// the input method -- an app's: preedit for the live words, commit at each pause; (2) a window class listed in `typeInto` (no text
// input: Xwayland) gets the final text typed by lares-ime's virtual keyboard; (3) nothing takes text: the take's text goes to the
// clipboard at the stop (wl-copy, text/plain;charset=utf-8 and its aliases) with a toast. A password, pin, hidden or sensitive field
// takes nothing (DictationText.fieldRule); a terminal never gets a newline. The typing route types through a second lares-ime
// (`--type-only`): Hyprland ignores the keys of a virtual keyboard whose client holds the input method. A field lost mid-take keeps
// the live words for the next one; committed text stays where it was written, and what no field took goes to the clipboard.
//
// THE SHELL ROUTE'S CONTRACT (docs/dictation.md "The shell's own fields"). A popup content -- the engine's primary or secondary
// content item -- MAY declare
//     readonly property bool dictationActive        an editable field of this content has the caret now (it falls with the window's
//                                                   keyboard: a popup whose keys went to an app takes nothing)
//     function dictationPreedit(text: string): bool the live words underlined at the caret, replacing the previous ones; "" clears
//     function dictationCommit(text: string): bool  text inserted at the caret for good (the preedit goes). Both answer false when the
//                                                   field took nothing (round 8: the service then keeps the text for the clipboard, it
//                                                   is never counted delivered); a content that answers nothing (void) took it
//     function dictationBefore(): string            OPTIONAL: the text before the caret on its line (the spacing; without it the
//                                                   first piece of a take is written with no space before it)
// The host (ShellServices.dictationTarget) hands the service `shellTarget`: the focused screen's open popup's content -- the primary,
// then its secondary -- then any other screen's, whose `dictationActive` is true. At the press a target makes the route `shell` (the
// input method is not even started); a target that comes or goes mid-take is settled `shellSettleMs` later (a caret moving between
// two lines of one note is no change): a new target takes the rest of the take, a lost one hands it to the input method / clipboard
// rules (lares-ime is started then). The spacing is the input method route's (DictationText.joinPrefix); capitals are the helper's.
//
// A TAKE CAN NEVER GET STUCK (round 6: a helper went silent after `listening`, and its takes waited on it for ever). The helper must
// answer a `start` (`capture`) within `startAnswerMs`; one that does not, or that does not end a take `stopWait` after the stop
// (`timeout`), is STALLED: the take ends (reason `stalled` / `timeout`, the aura let go, the log written), the helper is asked for its
// threads (`trace`, answered from its stdin reader, not its main loop) and is started again -- with its last stderr lines and that
// trace in the shell log, so the next stall names itself. A press while the take is `stopping` ends it at once once `forceGraceMs`
// have passed since the stop (reason `forced`), and the helper is then pinged: no `pong` within `pingMs` is a stall too. Every line
// of a take is read only while that take runs (a late `running` plays no aura); a keep-warm restart takes no start meanwhile (it
// waits for the next helper's `ready`); a new take's input method waits for the last take's to go.
//
// A TAKE ENDS WITH ITS REASON, NEVER IN SILENCE (round 8: the iGPU raised inside a decode, the helper's loop died with the exception and
// the process went on, saying nothing -- the take ended on the stop's 6 s timer and its toast read as "the model unloaded"). The helper
// recovers a GPU decode on the CPU (`fallback`: a toast in words, the take goes on, nothing lost), ends a take its own loop raised in
// with `error` what `crash`, and beats once a second from a thread of its own (`beat`: how long ago its main loop turned). While a take is
// live this service listens: no beat for `beatMs` (`silent`), or a loop that has not turned for `loopStuckMs` (`loop`), is a stall --
// the take ends, a decode that hung on a GPU puts the next take on the CPU (`_avoidGpu`, until a rest restart), and the toast says
// which (`_stallWords`). A helper that exits mid-take says how in its toast (`_exitWords` and its last stderr line). The take log keeps
// all of it: `helperReason`, `exit`, `stall`, `fallbacks`, the take's `mode` and each sentence's `cut`.
//
// THE MIC. A muted default source (or one at 0 %; with `unmute` off a take on either does not start, and says so) is unmuted -- and raised to `micVolume` -- for the take, and put back after it on
// that same node, unless the user changed it meanwhile (their act wins). What was changed is written to dictation/state.json before
// the change and cleared after the restore, so a shell that dies mid-take restores the mic at its next start.
// THE AURA (dictation.aura). Dictation is the user's own act: not an AuraEvents event, DND does not silence it. `playAura("siri", "island", 600000)`
// AT THE PRESS -- the smaller aura: listening, the model still loading -- and `playAura("siri", "all", 600000)` at `running`, the
// moment words can appear (a play over a play carries on from its level: GooeyEngine.playAura); re-asked in its group before the
// 10 min run out, and `releaseAura()` at the end: the way out from the level it is at (no new seed, so the hues do not jump). A take
// that fails or is stopped while the models load lets it go the same way.
//
// THE TAKE LOG (takes.jsonl, the last `logKeep`; round 5): per take the focused window's class at the press, the device, the timings from
// the press (capture, listening, running, the first word, in ms), every route it took in order, and per sentence `raw` (what the
// model wrote), `text` (what was written) and `rules` (the text rules that changed it); `pieces` / `heard` as before. A take into a
// password, pin, hidden or sensitive field is not logged at all. `thinks`: each pause that kept a sentence open and why ("filler" |
// "unfinished"). The writer (round 6) ends the file with a newline before it appends (a file someone saved without its last one
// glued two records), queues a record while the last write runs, and trims through a tmp of its own.
//
// THE DEVICE AND THE PASSES (round 4). The helper picks the device per take from a cheap fact (the NVIDIA card on the bus: CUDA,
// else the Arc iGPU) and says so (`device`); a helper that ran a take on the card is let go `dgpuKeepMin` after the last take instead
// of `keepWarmMin` -- a CUDA context holds the card awake for as long as the process lives (with `preload`, it is restarted instead).
// Fillers ("uh", "um") never reach the field, and a pause right after one keeps the sentence open (`thinkSilenceMs`); `tidy` adds
// the guarded tidy pass. The take log keeps what was heard (`heard`) beside what was written (`pieces`) when they differ.
//
// THE TWO OTHER TAKES (round 5; `toggleMode`). Each writes into no field: its words show on a CAPTION card the OSD hosts (the kind
// "caption", modules/osd/kinds/OsdCaption.qml: it hangs from the bar beside the user's popups, renewed every second while the take
// runs, withdrawn at its end), and the input method is never started.
//   source  fn+Ctrl+F10 (lares:dictate-source): the sound of the window that had the focus at the press, never the mic. The
//           helper records a stereo capture nothing else links and links the window's output streams into it as they come and go
//           (tools/stt/sttlib/sources.py); no aura (it is not the user speaking), the mic untouched, the tidy pass off and no note
//           header (DictationText.sourceText); the language as an auto take's, the user's own prior left alone. At the stop the
//           transcript -- the finals in order -- goes to the clipboard with a toast "Transcript copied".
//   ask     Alt+fn+F10 (lares:dictate-ask): a normal take with the mic (its mute handling and its aura) whose finals collect
//           into ONE question; at the stop -- the key again, or by itself `askEndMs` after its last sentence (8 s with nothing said)
//           -- the question goes to the LLM: `llm.voiceAsk(text, { windowClass, windowTitle, cwd })`, the window as it was at the
//           press and the cwd of the shell under it when it is a terminal (the helper's `context`). Nothing to the clipboard, nothing
//           typed; an empty question asks nothing, and a take that ends any other way than cleanly asks nothing either.
// Any of the four keys stops whatever take runs.
//
// HOLD (shell.jsonc dictation.key "hold"). A press of the plain or the Shift key starts a take and its release stops it, as the toggle's
// second press does -- while it is still starting too (the helper finishes what it captured; a start that never reached it is dropped).
// The release ends only the take its press started: one that ended meanwhile, or that another key started, is left alone. A press while
// the last take is still finishing is kept, and starts the next one when it has -- if the key is still down.
// A take in which nothing was said for `endAfterMin` ends by itself, with a toast.
//
// SHELL-HOSTED: `live` false (the default) starts nothing, writes nothing and runs no program -- a press is only logged; the host
// injects pipewire (PipewireService or its mock), the aura hook, the power state, the state dir, the OSD (the caption's host) and
// the LLM service (the ask's).
// =============================================================================
Item {
    id: root
    visible: false

    // ---- injected ------------------------------------------------------------------------------------------------------------------
    property bool live: false
    // shell.jsonc's `dictation` block (ShellConfig.dictation)
    property var rawConfig: null
    readonly property var config: DT.config(root.rawConfig)
    readonly property bool enabled: root.config.enabled === true
    property var pipewire: null
    // function (palette, group, lifeMs) -> the hook's answer (ShellServices.playAura); null: no aura
    property var playAura: null
    // function () -> the aura's way out from its level (ShellServices.releaseAura); null: no aura
    property var releaseAura: null
    property bool onBattery: false
    // the OSD service (OsdService: show(req), withdraw(kind, key)): the caption's host; null: no caption
    property var osd: null
    // the LLM service (LlmService: voiceAsk(text, context)): where a voice ask goes; null: nowhere (said in a toast)
    property var llm: null
    // the shell's state dir ($XDG_STATE_HOME/lares): dictation/state.json, dictation/takes.jsonl
    property string stateDir: ""
    // THE SHELL ROUTE (header): the popup content whose field has the caret (ShellServices.dictationTarget); null: none
    property var shellTarget: null
    // the watchdog's numbers (header, A TAKE CAN NEVER GET STUCK): a probe shortens them
    property int startAnswerMs: 8000
    property int forceGraceMs: 2000
    property int pingMs: 5000
    property int shellSettleMs: 120
    // THE LISTENING WATCHDOG (round 8, header): the helper beats once a second while a take is live; none for `beatMs`, or a main
    // loop that has not turned for `loopStuckMs` (`loadStuckMs` while it loads a fallback model), ends the take
    property int beatMs: 5000
    property int loopStuckMs: 12000
    property int loadStuckMs: 45000
    // the programs (a probe points them at stubs)
    readonly property string _home: Quickshell.env("HOME") || ""
    readonly property string _sttHome: Quickshell.env("LARES_STT_HOME") || (root._home + "/.cache/lares-stt")
    property string pythonPath: root._home + "/.local/share/lares/stt/venv/bin/python"
    property string helperScript: RepoRoot.dir + "/tools/stt/lares_stt.py"
    property string imePath: root._sttHome + "/bin/lares-ime"
    // lares-ime's protocol as tools/stt/ime/lares-ime.c says it in `ready` (LARES_IME_VERSION): the binary in the cache is built by the user
    // (setup.sh / ime/build.sh), never by a deploy, so an older one is told once a session -- it still works, without the rebind
    readonly property int imeVersion: 2
    property bool _imeOld: false
    property var copyCommand: ["wl-copy"]
    property var activeWindowCommand: ["hyprctl", "-j", "activewindow"]

    // ---- read ------------------------------------------------------------------------------------------------------------------------
    readonly property string state: root._state
    readonly property bool active: root._state !== "idle"
    readonly property string mode: root._mode
    readonly property string route: root._route
    readonly property string liveText: root._preedit
    readonly property string language: root._lang
    readonly property var log: root._log
    readonly property bool helperRunning: helper.running
    // the take holds the aura (the island or the whole of it): an AuraEvents event does not play over it (ShellServices)
    readonly property bool holdsAura: root._auraOn

    signal toast(string title, string body)

    // ---- the take ------------------------------------------------------------------------------------------------------------------
    function toggle(lang: string): void {
        root.toggleMode("type", lang);
    }
    function toggleMode(mode: string, lang: string): void {
        if (root._state === "idle")
            root._start(mode === "source" || mode === "ask" ? mode : "type", lang);
        else if (root._state === "starting" || root._state === "listening")
            root._stop();
        else if (root._state === "stopping")
            root._pressStopping();
    }
    // HOLD: the take the held key started (0 none), and the language of a press that waits for the last take to finish (null none).
    property int _heldTake: 0
    property var _heldNext: null
    function holdPress(lang: string): void {
        root._heldNext = null;
        if (root._state === "idle") {
            root._start("type", lang);
            root._heldTake = root._state !== "idle" ? root._take : 0;
            return;
        }
        if (root._state === "stopping")
            root._heldNext = lang;
        root.toggleMode("type", lang);
    }
    function holdRelease(): void {
        root._heldNext = null;
        const mine = root._heldTake !== 0 && root._heldTake === root._take;
        root._heldTake = 0;
        if (mine && (root._state === "starting" || root._state === "listening"))
            root._stop();
    }
    on_StateChanged: {
        if (root._state !== "idle" || root._heldNext === null)
            return;
        Qt.callLater(() => {
            if (root._heldNext !== null && root._state === "idle")
                root.holdPress(root._heldNext);
        });
    }
    // A press while the take is stopping: inside the grace it is the same stop pressed twice; after it, the take ends at once (the
    // helper still finishing a load, or stalled: the ping tells them apart).
    function _pressStopping(): void {
        const since = Math.round(Date.now() - root._stopAt);
        if (since < root.forceGraceMs) {
            root._note({ ev: "pressstopping", take: root._take, since: since });
            return;
        }
        root._note({ ev: "forced", take: root._take, since: since, running: root._running });
        root._finish("forced");
        root._ping("forced");
    }

    property string _state: "idle"
    // the take's kind: "type" (into the focused field) | "source" (the window's sound) | "ask" (a question for the LLM)
    property string _mode: "type"
    property string _route: ""
    property string _preedit: ""
    property string _lang: ""
    property string _prior: "en"
    property var _log: []
    property int _take: 0
    property bool _warnedOff: false
    property bool _helperOk: false
    property bool _imeOk: false
    property bool _checked: false
    // the helper should run: always while the switch is on (THE TWO HELPERS); false for a moment to start it again, light
    property bool _warm: true
    property bool _helperReady: false
    property var _pendingStart: null
    // what goes to the helper after a start that waits for its `ready` (the take's `window`)
    property var _pendingOps: []
    // the field the input method serves: active, its content purpose, the text before the caret it reported
    property bool _imeActive: false
    // THE SHELL ROUTE: the content the take writes into now (route `shell`)
    property var _shell: null
    // when the stop was pressed (a press in `stopping` after the grace forces the end)
    property double _stopAt: 0
    property int _purpose: 0
    property int _hint: 0
    property bool _beforeKnown: false
    property string _before: ""
    property int _segsInField: 0
    // what no field took this take (the clipboard's), and every final piece in order (the take log's)
    property string _clip: ""
    property var _pieces: []
    property var _heard: []
    // the helper has run a take on the NVIDIA card (it holds the card awake until it exits)
    property bool _onCard: false
    // the take's models are up and its words can appear (the helper's `running`)
    property bool _running: false
    // the take's record (THE TAKE LOG): the press (ms since the epoch), the timings from it, the routes, the sentences, the window
    property double _pressAt: 0
    property var _times: ({})
    property var _routes: []
    property var _segs: []
    // the pauses that kept a sentence open, and why ("filler" | "unfinished": the helper's `think`)
    property var _thinks: []
    property string _device: ""
    // round 8 (THE TAKE LOG): a GPU that failed and the CPU that took over (the helper's `fallback`), why the take was stalled, how the
    // helper went, the helper's own `ended.reason`, the last beat (ms, wall) and the tick before it (a GUI stall is no silence)
    property var _fallbacks: []
    property var _stallInfo: null
    property var _exitInfo: null
    property string _helperEnded: ""
    property double _beatAt: 0
    property double _beatTick: 0
    // a decode that hung on a GPU: the next take runs on the CPU until the helper is restarted at rest (the GPU may need the time)
    property bool _avoidGpu: false
    // the helper said `error` what "crash": it is started again when the take is over
    property bool _restartAfterTake: false
    property string _windowClass: ""
    property string _windowTitle: ""
    property int _windowPid: 0
    property bool _windowKnown: false
    // a source or an ask take's finals in order (the transcript; the question), what the helper links (a source take: the streams
    // now, and every one this take, for the log), and the ask's cwd (the helper's `context`)
    property var _said: []
    property var _sources: []
    property var _streamsSeen: []
    property string _cwd: ""
    property bool _routePending: false
    // a password, pin, hidden or sensitive field was seen this take: nothing of it is logged
    property bool _secret: false
    property var _mic: null
    property real _lastMicVolume: 0

    function _note(o: var): void {
        root._log = root._log.concat([o]).slice(-200);
    }

    function _start(mode: string, lang: string): void {
        root._note({ ev: "press", lang: lang, mode: mode, enabled: root.enabled, live: root.live });
        if (!root.enabled) {
            if (!root._warnedOff) {
                root._warnedOff = true;
                root.toast("Dictation is off", "shell.jsonc: \"dictation\": { \"enabled\": true } turns it on");
            }
            return;
        }
        if (!root.live)
            return;
        if (!root._helperOk) {
            root.toast("Dictation is not set up", root._checked ? "No speech helper at " + root.pythonPath + " -- run tools/stt/setup.sh"
                                                              : "Still checking for the speech helper; press again in a moment");
            root._note({ ev: "nohelper" });
            return;
        }
        if (mode !== "source" && !root.config.unmute && root._micMuted()) {
            root.toast("The microphone is muted", "Unmute it to dictate");
            root._note({ ev: "muted" });
            return;
        }
        root._take += 1;
        root._pressAt = Date.now();
        root._mode = mode;
        root._state = "starting";
        root._running = false;
        root._times = {};
        root._routes = [];
        root._segs = [];
        root._thinks = [];
        root._device = "";
        root._fallbacks = [];
        root._stallInfo = null;
        root._exitInfo = null;
        root._helperEnded = "";
        root._beatAt = Date.now();
        root._beatTick = Date.now();
        root._windowClass = "";
        root._windowTitle = "";
        root._windowPid = 0;
        root._windowKnown = false;
        root._said = [];
        root._sources = [];
        root._streamsSeen = [];
        root._cwd = "";
        root._pendingOps = [];
        root._routePending = false;
        root._secret = false;
        root._route = "";
        root._preedit = "";
        root._lang = "";
        root._clip = "";
        root._pieces = [];
        root._heard = [];
        root._imeActive = false;
        root._shell = null;
        root._purpose = 0;
        root._hint = 0;
        root._beforeKnown = false;
        root._before = "";
        root._segsInField = 0;
        keepWarm.stop();
        const source = mode === "source";
        // a window take never touches the mic
        const node = source ? "" : root._micTake();
        // the capture first (the helper is running, light): the start goes out before anything else of the take
        root._warm = true;
        root._send({ op: "start", take: root._take, lang: !source && (lang === "nl" || lang === "en") ? lang : "auto", prior: root._prior,
                     node: node, source: source ? "window" : "mic", device: root._avoidGpu ? "cpu" : root.config.device, power: root.onBattery ? "battery" : "ac",
                     model: root.config.model, tidy: !source && root.config.tidy === true,
                     policy: { endSilenceMs: root.config.endSilenceMs, hopMs: root.config.hopMs, thinkSilenceMs: root.config.thinkSilenceMs },
                     text: source ? DT.sourceText(root.config.text) : root.config.text });
        stopWait.stop();
        // the helper answers a start at once (`capture`): one that does not is stalled (A TAKE CAN NEVER GET STUCK)
        startWait.interval = root.startAnswerMs;
        startWait.restart();
        if (!source)
            root._aura("island");
        if (mode === "type") {
            // the shell's own field first (THE SHELL ROUTE): with one, no input method is started at all
            if (!root._shellCheck()) {
                if (root._imeOk)
                    root._imeStart();
                routeWait.restart();
            }
        } else {
            root._setRoute(mode);
            root._caption();
            captionBeat.restart();
        }
        root._quietArm();
        if (!activeWindow.running)
            activeWindow.running = true;      // the window: the take log's class, the typing route's, a source take's, an ask's
    }

    // ms since the press (the take log's timings)
    function _sincePress(): int {
        return Math.round(Date.now() - root._pressAt);
    }

    function _stop(): void {
        if (root._pendingStart) {
            // the helper never got the take (it is still starting): nothing was heard, nothing to finish
            root._pendingStart = null;
            root._finish("cancel");
            return;
        }
        root._state = "stopping";
        root._stopAt = Date.now();
        root._note({ ev: "stop", take: root._take, running: root._running });
        root._send({ op: "stop", take: root._take });
        root._armStopWait();
    }

    // The take is over (the helper said `ended`, or it is gone, or it never answered, or the user forced it): the clipboard, the mic,
    // the aura, the log. From here on no line of this take is read (`_onHelperLine`: a late `running` plays no aura).
    function _finish(reason: string): void {
        if (root._state === "idle")
            return;
        stopWait.stop();
        startWait.stop();
        routeWait.stop();
        shellSettle.stop();
        auraRenew.stop();
        askQuiet.stop();
        quietEnd.stop();
        captionBeat.stop();
        root._pendingOps = [];
        if (root._pendingStart && root._pendingStart.take === root._take)
            root._pendingStart = null;
        if (reason === "timeout" || reason === "off" || reason === "forced" || reason === "stalled")
            root._send({ op: "cancel", take: root._take });
        if (root._preedit !== "" && reason !== "ended") {
            // the helper is gone mid-sentence: what was shown is written as it stands (nothing said is lost)
            if (root._mode === "type")
                root._deliver(root._preedit);
            else
                root._said = root._said.concat([root._preedit.trim()]);
        }
        root._preedit = "";
        root._running = false;
        if (root._route === "shell")
            root._shellWrite("preedit", "");
        root._shell = null;
        root._imeActive = false;
        root._imeQuit();
        const clip = root._clip.trim();
        // dictation.copy "always": the whole text, delivered or not -- never one of which a secret field saw a part
        const all = root.config.copy === "always" && root._mode === "type" && !root._secret ? root._pieces.join(" ").trim() : "";
        if (all !== "" || clip !== "")
            root._copy(all !== "" ? all : clip);
        if (clip !== "")
            root.toast("Dictation copied", DT.firstWords(clip, 8));
        if (root._mode !== "type") {
            root._captionGone();
            root._endSaid(reason);
        }
        root._micRestore();
        if (root._auraOn && typeof root.releaseAura === "function") {
            root.releaseAura();
            root._note({ ev: "aura", release: true });
        }
        root._auraOn = false;
        root._logTake(reason);
        root._note({ ev: "finished", take: root._take, reason: reason, route: root._route, clip: clip, mode: root._mode });
        root._state = "idle";
        if (!root.config.preload || root._onCard)
            keepWarm.restart();
    }

    // THE STOP'S WAIT: a helper that says nothing for 6 s after the stop (or after its last word) is not waited for -- 60 s while the
    // models still load, since a stop then is decoded only once they are up
    function _armStopWait(): void {
        stopWait.interval = root._running ? 6000 : 60000;
        stopWait.restart();
    }

    // ---- the window take and the voice ask (THE TWO OTHER TAKES) --------------------------------------------------------------------
    // The take is over: a window take's transcript to the clipboard, an ask's question to the LLM (only a take that ended cleanly).
    function _endSaid(reason: string): void {
        const said = root._said.join(" ").trim();
        if (root._mode === "source") {
            if (said !== "") {
                root._copy(said);
                root.toast("Transcript copied", DT.firstWords(said, 8));
            } else if (reason !== "cancel") {
                root.toast("Nothing heard", root._streamsSeen.length > 0 ? "No speech in the sound of " + root._sourceName()
                                                                          : "No sound came from " + root._sourceName());
            }
            return;
        }
        if (said === "") {
            if (reason !== "cancel")
                root.toast("Nothing heard", "Nothing was asked");
            return;
        }
        if (reason !== "ended") {
            root.toast("Dictation stopped", "The question was not asked: " + DT.firstWords(said, 8));
            return;
        }
        const ctx = { windowClass: root._windowClass, windowTitle: root._windowTitle, cwd: root._cwd };
        root._note({ ev: "ask", text: said, windowClass: ctx.windowClass, windowTitle: ctx.windowTitle, cwd: ctx.cwd });
        if (root.llm && typeof root.llm.voiceAsk === "function")
            root.llm.voiceAsk(said, ctx);
        else
            root.toast("Nothing to ask", "The LLM chat is not running");
    }

    // AN ASK ENDS BY ITSELF: `askEndMs` after its last written sentence while nobody speaks (`speech` holds it), 8 s from `running`
    // with nothing said yet. `had`: a sentence is written.
    function _askWait(had: bool): void {
        if (root.config.askEndMs <= 0 || root._state === "idle" || root._state === "stopping")
            return;
        askQuiet.interval = had ? Math.max(500, root.config.askEndMs) : 8000;
        askQuiet.restart();
    }
    Timer {
        id: askQuiet
        onTriggered: {
            if (root._mode !== "ask" || (root._state !== "starting" && root._state !== "listening"))
                return;
            if (root._preedit !== "") {
                askQuiet.restart();                 // a sentence is still being spoken
                return;
            }
            root._note({ ev: "askend", said: root._said.length });
            root._stop();
        }
    }

    // A TAKE NOBODY SPEAKS INTO (`endAfterMin`) ends by itself: armed at its start and again at every word heard.
    function _quietArm(): void {
        if (root.config.endAfterMin > 0 && (root._state === "starting" || root._state === "listening"))
            quietEnd.restart();
        else
            quietEnd.stop();
    }
    Timer {
        id: quietEnd
        interval: Math.max(0.01, Math.min(60, root.config.endAfterMin)) * 60000
        onTriggered: {
            if (root.config.endAfterMin <= 0 || (root._state !== "starting" && root._state !== "listening"))
                return;
            root._note({ ev: "quietend", take: root._take });
            root.toast("Dictation ended", "Nothing was said for " + root.config.endAfterMin + " min");
            root._stop();
        }
    }

    // THE CAPTION (the OSD's kind "caption"): what the take does now, the words, a hint while there are none.
    function _sourceName(): string {
        const app = root._sources.length > 0 ? root._sources[0].app : (root._streamsSeen.length > 0 ? root._streamsSeen[0].app : "");
        return app !== "" ? app : (root._windowClass !== "" ? root._windowClass : "the window");
    }
    function _captionPayload(): var {
        const ask = root._mode === "ask";
        const head = !root._windowKnown && !ask ? "Finding the window"
                   : !ask && root._sources.length === 0 ? "Waiting for sound from " + root._sourceName()
                   : !root._running ? "Loading the speech model"
                   : ask ? "Ask the model" : "Transcribing " + root._sourceName();
        return { kind: "caption", key: "dictation", source: "dictation", ms: 2500,
                 caption: { mode: root._mode, head: head, lines: root._said.slice(-8), live: root._preedit,
                            hint: ask ? "Say what you want" : "No speech yet" } };
    }
    function _caption(): void {
        if (root.osd && typeof root.osd.show === "function" && root._mode !== "type" && root._state !== "idle")
            root.osd.show(root._captionPayload());
    }
    function _captionGone(): void {
        if (root.osd && typeof root.osd.withdraw === "function")
            root.osd.withdraw("caption", "dictation");
    }
    Timer {
        id: captionBeat
        // renewed in place every second (2.5 s of life each time): after another card had the slot, the words come back; a shell
        // that stopped renewing them loses the card by itself
        interval: 1000
        repeat: true
        onTriggered: root._caption()
    }

    // ---- the speech helper ----------------------------------------------------------------------------------------------------------
    SupervisedStream {
        id: helper
        what: "DictationService: the speech helper"
        stdinEnabled: true
        enabled: root.live && root.enabled && root._helperOk && root._warm
        command: ["setpriv", "--pdeathsig", "TERM", "--", root.pythonPath, "-I", root.helperScript]
        onLine: text => root._onHelperLine(text)
        onExited: (code, expected) => root._onHelperExit(code, expected)
    }
    function _send(o: var): void {
        if (o.op === "start") {
            if (!root._helperReady) {
                root._pendingStart = o;
                return;
            }
        } else if (root._pendingStart && o.take === root._pendingStart.take) {
            root._pendingOps = root._pendingOps.concat([o]);     // after its start
            return;
        }
        if (!helper.running)
            return;
        helper.write(JSON.stringify(o) + "\n");
    }

    // ---- the watchdog (A TAKE CAN NEVER GET STUCK) ------------------------------------------------------------------------------
    // The helper's last stderr lines (SupervisedStream's `errorLine`), for the shell log when something goes wrong; and its answer to
    // `trace` (every thread's stack, from its stdin reader).
    property var _stderr: []
    property double _reportedAt: 0
    property int _pingN: 0
    property string _stallWhy: ""
    Connections {
        target: helper
        ignoreUnknownSignals: true
        function onErrorLine(text: string): void {
            root._stderr = root._stderr.concat([String(text)]).slice(-200);
        }
    }
    // The helper is alive when its main loop answers: `pong` within `pingMs`, or it is stalled.
    function _ping(why: string): void {
        if (!helper.running || !root._helperReady)
            return;
        root._pingN += 1;
        root._stallWhy = why;
        root._send({ op: "ping", n: root._pingN });
        pingWait.interval = root.pingMs;
        pingWait.restart();
    }
    // STALLED: the take (if one runs) ends now; the helper is asked for its threads, and started again once they came (or did not).
    // `info` (optional): what the helper's beat said (loopMs, phase), for the log and the toast.
    function _stall(why: string, info: var): void {
        const live = root._state !== "idle";
        root._stallInfo = Object.assign({ why: why }, info || {});
        root._note({ ev: "stall", why: why, take: root._take, state: root._state, info: info || null });
        // a decode that hung on a GPU: the GPU rests (the next take runs on the CPU) until the helper is restarted at rest
        if (why === "loop" && /GPU|CUDA/.test(root._device))
            root._avoidGpu = true;
        // WHY, in words (round 8, the user: "it did not state a reason"): the cause, what became of the take, what happens now
        root.toast(live ? "Dictation stopped" : "Dictation", root._stallWords(why, info, live));
        if (live)
            root._finish(why === "stop" ? "timeout" : "stalled");
        // what goes now takes no start: a press waits for the next helper's `ready`
        root._helperReady = false;
        if (!helper.running) {
            root._report(why, null);
            root._restartHelper("stall");
            return;
        }
        root._stallWhy = why;
        helper.write(JSON.stringify({ op: "trace", why: why }) + "\n");
        traceWait.restart();
    }
    function _stallWords(why: string, info: var, live: bool): string {
        const secs = info && info.loopMs ? Math.round(info.loopMs / 1000) : 0;
        const end = live ? "the take was ended; " : "";
        if (why === "loop")
            return "The speech helper stopped working (its decoder did not return for " + secs + " s); " + end + "it is starting again"
                    + (root._avoidGpu ? ", on the CPU for the next take" : "");
        if (why === "silent")
            return "The speech helper went silent (nothing from it for " + Math.round(root.beatMs / 1000) + " s); " + end + "it is starting again";
        if (why === "start")
            return "The speech helper did not answer the start; " + end + "it is starting again";
        if (why === "stop")
            return "The speech helper did not finish the take after you stopped it; " + end + "it is starting again";
        return "The speech helper did not answer when you pressed again; " + end + "it is starting again";
    }
    // An abnormal end, in the shell log: why, the take's last events, the helper's last stderr lines and (a stall) its threads.
    function _report(why: string, trace: var): void {
        const tail = root._log.slice(-12).map(o => JSON.stringify(o)).join("\n    ");
        const err = root._stderr.length > 0 ? root._stderr.join("\n    ") : "(none)";
        let threads = "";
        if (trace)
            threads = "\n  the helper's threads (" + (trace.loop || "") + "):\n    " + (Array.isArray(trace.threads) ? trace.threads.join("\n    ") : "");
        else if (why !== "exit")
            threads = "\n  the helper did not answer `trace`";
        console.warn("DictationService: the speech helper " + (why === "exit" ? "ended unasked" : "stalled (" + why + ")") + ", take "
                     + root._take + "\n  the last events:\n    " + tail + "\n  its last stderr lines:\n    " + err + threads);
    }
    // The helper is started again, light (its models go). `_helperReady` falls NOW: a start in the gap before the old one exits
    // waits for the new one's `ready` instead of going to the one that is going.
    function _restartHelper(why: string): void {
        if (why === "rest")
            root._avoidGpu = false;       // the GPU is tried again at the next helper start (a rest restart is the one nobody caused)
        root._helperReady = false;
        root._note({ ev: "restart", why: why });
        root._warm = false;
        Qt.callLater(() => root._warm = true);
    }
    Timer {
        id: startWait
        onTriggered: {
            if (root._state !== "idle" && root._times.capture === undefined)
                root._stall("start");
        }
    }
    Timer {
        id: pingWait
        onTriggered: root._stall(root._stallWhy !== "" ? root._stallWhy : "ping")
    }
    // THE LISTENING WATCHDOG (round 8): a live take whose helper has sent no beat for `beatMs` is stalled. A tick that came late (the
    // shell's own GUI thread was away: the beats queued meanwhile are read right after this tick) forgives that tick.
    Timer {
        id: beatWatch
        interval: 1000
        repeat: true
        running: root._state !== "idle" && root._times.capture !== undefined && helper.running
        onTriggered: {
            const now = Date.now();
            const late = now - root._beatTick > 2500;
            root._beatTick = now;
            if (late)
                return;
            if (now - root._beatAt > root.beatMs)
                root._stall("silent", { silentMs: now - root._beatAt });
        }
        onRunningChanged: if (running) root._beatTick = Date.now()
    }
    Timer {
        id: traceWait
        interval: 1500
        onTriggered: {
            root._report(root._stallWhy, null);
            root._restartHelper("stall");
        }
    }

    function _onHelperLine(text: string): void {
        const t = String(text).trim();
        if (t === "")
            return;
        let e = null;
        try {
            e = JSON.parse(t);
        } catch (err) {
            return;
        }
        if (e.ev === "pong") {
            if (e.n === root._pingN)
                pingWait.stop();
            return;
        }
        if (e.ev === "trace") {
            if (traceWait.running) {
                traceWait.stop();
                root._report(root._stallWhy, e);
                root._restartHelper("stall");
            }
            return;
        }
        if (e.ev === "ready") {
            root._helperReady = true;
            if (root._pendingStart) {
                const s = root._pendingStart;
                root._pendingStart = null;
                const ops = root._pendingOps;
                root._pendingOps = [];
                if (s.take === root._take && root._state !== "idle") {
                    root._send(s);
                    for (const o of ops)
                        root._send(o);
                }
            }
            return;
        }
        // a stale take, or this one's after its end (a `running` that comes after a timeout or a forced end plays no aura)
        if (e.take !== undefined && (e.take !== root._take || root._state === "idle"))
            return;
        if (e.ev === "beat") {
            // THE LISTENING WATCHDOG: the helper's own thread says how long ago its main loop last turned. A beat answers neither the
            // start nor the stop (it never re-arms their waits: a loop stuck in a native call beats on)
            root._beatAt = Date.now();
            const limit = e.phase === "load" ? root.loadStuckMs : root.loopStuckMs;
            if (Number(e.loopMs) > limit)
                root._stall("loop", { loopMs: Number(e.loopMs), phase: String(e.phase || "") });
            return;
        }
        if (e.take !== undefined)
            startWait.stop();                           // the helper answered the start
        if (root._state === "stopping" && e.ev !== "ended")
            root._armStopWait();                        // the helper is still at it
        switch (e.ev) {
        case "capture":
            root._beatAt = Date.now();
            root._mark("capture");
            root._note({ ev: "capture", take: e.take, ms: e.ms });
            break;
        case "listening":
            root._mark("listening");
            if (root._state === "starting")
                root._state = "listening";
            root._note({ ev: "listening", take: e.take, ms: e.ms });
            break;
        case "running":
            root._mark("running");
            root._running = true;
            root._device = String(e.device || "");          // the live model's
            root._note({ ev: "running", take: e.take, ms: e.ms, device: root._device });
            if (root._mode !== "source")
                root._aura("all");
            if (root._mode === "ask")
                root._askWait(false);
            root._caption();
            break;
        case "speech":
            // someone speaks: an ask does not end under them
            askQuiet.stop();
            root._quietArm();
            break;
        case "sources": {
            // a window take: the streams linked now (each change, the first picture too)
            const st = Array.isArray(e.streams) ? e.streams : [];     // JSON.parse's own array
            root._sources = st.map(x => ({ serial: x.serial, app: String(x.app || ""), media: String(x.media || ""), pid: x.pid }));
            const seen = root._streamsSeen.slice();
            for (const x of root._sources)
                if (!seen.some(y => y.serial === x.serial))
                    seen.push(x);
            root._streamsSeen = seen;
            root._note({ ev: "sources", n: root._sources.length, serials: root._sources.map(x => x.serial), capture: e.capture === true });
            root._caption();
            break;
        }
        case "context":
            root._cwd = String(e.cwd || "");
            root._note({ ev: "context", cwd: root._cwd, why: String(e.why || "") });
            break;
        case "loading":
        case "loaded":
            if (e.ev === "loaded" && String(e.device || "").indexOf("CUDA") === 0)
                root._onCard = true;
            root._note({ ev: e.ev, model: e.model, device: e.device, ms: e.ms });
            break;
        case "device":
            root._note({ ev: "device", cls: e["class"], why: e.why, fallback: e.fallback === true,
                         dgpu: e.dgpu ? !!e.dgpu.present : false });
            break;
        case "fallback": {
            // a GPU decode failed and the helper runs the take on the CPU from here (sttlib/devguard.py): said in words, the take goes on
            const f = { from: String(e.from || ""), to: String(e.to || ""), why: String(e.why || ""), detail: String(e.detail || ""),
                        model: String(e.model || ""), ms: root._sincePress() };
            root._fallbacks = root._fallbacks.concat([f]);
            if (root._device.indexOf(">") < 0)
                root._device = root._device + ">" + f.to;
            root._note({ ev: "fallback", from: f.from, to: f.to, why: f.why, detail: f.detail, model: f.model });
            root.toast("Dictation", f.why.charAt(0).toUpperCase() + f.why.slice(1) + "; switched to the " + f.to + ", the take goes on");
            break;
        }
        case "think":
            root._thinks = root._thinks.concat([{ seg: e.seg, why: String(e.why || "") }]);
            root._note({ ev: "think", seg: e.seg, waitMs: e.waitMs, why: String(e.why || "") });
            break;
        case "lang":
            root._lang = e.lang;
            // a window take hears someone else: the user's own language stays theirs
            if ((e.how === "detect" || e.how === "forced") && root._mode !== "source")
                root._prior = e.lang;
            root._saveState();
            root._note({ ev: "lang", lang: e.lang, how: e.how });
            break;
        case "hyp":
            root._preedit = String(e.text || "");
            if (root._preedit !== "") {
                root._mark("firstWord");
                root._quietArm();
            }
            if (root._mode === "type")
                root._showPreedit();
            else
                root._caption();
            root._note({ ev: "hyp", seg: e.seg, rev: e.rev, stable: e.stable, text: root._preedit });
            break;
        case "seg": {
            root._preedit = "";
            const rules = Array.isArray(e.rules) ? e.rules.map(String) : [];     // JSON.parse's own array
            root._note({ ev: "seg", seg: e.seg, text: String(e.text || ""), raw: String(e.raw || ""), cut: e.cut, tidy: e.tidy || null, rules: rules });
            if (String(e.raw || "").trim() !== "")
                root._heard = root._heard.concat([String(e.raw).trim()]);
            if (String(e.text || "").trim() !== "") {
                root._mark("firstWord");
                root._quietArm();
                root._segs = root._segs.concat([{ raw: String(e.raw || ""), text: String(e.text || ""), rules: rules,
                                                 cut: String(e.cut || ""), atMs: e.atMs, audioMs: e.audioMs, lang: String(e.lang || "") }]);
            }
            if (root._mode === "type") {
                root._deliver(String(e.text || ""));
            } else {
                if (String(e.text || "").trim() !== "")
                    root._said = root._said.concat([String(e.text).trim()]);
                root._caption();
                if (root._mode === "ask")
                    root._askWait(root._said.length > 0);
            }
            break;
        }
        case "error":
            root._note({ ev: "error", what: e.what, message: e.message, detail: e.detail });
            if (e.what === "crash") {
                // an exception in the helper's main loop (lares_stt.py `fail`): the helper ended the take itself, and is started again
                root.toast("Dictation stopped", "The speech helper crashed (" + String(e.message || "unknown") + "); the take was ended");
                root._restartAfterTake = true;
            } else {
                root.toast("Dictation", e.what === "audio" ? "No microphone signal" : String(e.message || e.what));
            }
            break;
        case "ended":
            root._helperEnded = String(e.reason || "");
            // a take the helper ended for an error is not a clean one (an ask asks nothing; the words shown are written as they stand)
            root._finish(root._helperEnded === "error" ? "error" : "ended");
            if (root._restartAfterTake) {
                root._restartAfterTake = false;
                root._restartHelper("crash");
            }
            break;
        }
    }

    function _onHelperExit(code: int, expected: bool): void {
        root._helperReady = false;
        root._onCard = false;
        pingWait.stop();
        const mid = root._state !== "idle";
        if (mid && !expected) {
            // WHY IT WENT (round 8: "it ended prematurely and did not state a reason"): the exit, the helper's last stderr line
            const last = root._lastStderr();
            root._exitInfo = { code: code, words: root._exitWords(code), stderr: last, stderrTail: root._stderr.slice(-3) };
            root._note({ ev: "helperdied", code: code, words: root._exitInfo.words, stderr: last });
            root.toast("Dictation stopped", "The speech helper stopped (" + root._exitInfo.words + (last !== "" ? ": " + last : "")
                       + "); the take was ended");
            root._finish("helper");
        }
        // an end nobody asked for, in the shell log with what the helper said last (once a minute at most: a helper that fails to
        // start is restarted with a back-off, and SupervisedStream already says so)
        if (!expected && (mid || root._stderr.length > 0) && Date.now() - root._reportedAt > 60000) {
            root._reportedAt = Date.now();
            root._report("exit", null);
        }
        // a helper that goes starts with an empty ring: what is in it now is the dead one's (reported above, or not wanted)
        root._stderr = [];
    }

    function _lastStderr(): string {
        for (let i = root._stderr.length - 1; i >= 0; i--) {
            const t = String(root._stderr[i]).trim();
            if (t !== "")
                return t.length > 110 ? t.substring(0, 109) + "…" : t;
        }
        return "";
    }
    // an exit code in words (a process killed by a signal reads 128 + n from a shell, -n from Qt)
    function _exitWords(code: int): string {
        const sig = code < 0 ? -code : (code > 128 && code < 160 ? code - 128 : 0);
        if (sig === 11)
            return "it crashed with a segmentation fault";
        if (sig === 6)
            return "it aborted";
        if (sig === 9)
            return "it was killed, probably for memory";
        if (sig === 7 || sig === 4 || sig === 8)
            return "it crashed (signal " + sig + ")";
        return "exit code " + code;
    }

    // the first time of a mark this take, in ms from the press (THE TAKE LOG)
    function _mark(what: string): void {
        if (root._times[what] !== undefined)
            return;
        const t = Object.assign({}, root._times);
        t[what] = root._sincePress();
        root._times = t;
    }

    // ---- the shell's own fields (THE SHELL ROUTE) ------------------------------------------------------------------------------
    function _shellValid(t: var): bool {
        return !!t && t.dictationActive === true && typeof t.dictationPreedit === "function" && typeof t.dictationCommit === "function";
    }
    // The route follows `shellTarget`: at the press (true: the take writes into the shell's field) and, settled, mid-take.
    function _shellCheck(): bool {
        shellSettle.stop();
        if (root._state === "idle" || root._mode !== "type")
            return false;
        const t = root._shellValid(root.shellTarget) ? root.shellTarget : null;
        if (t) {
            if (root._route === "shell" && root._shell === t)
                return true;
            root._leaveRoute();
            routeWait.stop();
            root._routePending = false;
            root._shell = t;
            root._segsInField = 0;
            root._note({ ev: "shelltarget", target: String(t.objectName || t) });
            root._setRoute("shell");
            return true;
        }
        if (root._route !== "shell")
            return false;
        // the shell's field is gone (its popup closed, the caret or the keyboard went elsewhere): the input method's rules
        root._leaveRoute();
        root._shell = null;
        root._segsInField = 0;
        root._note({ ev: "shelltarget", target: "" });
        if (root._imeActive) {
            root._setRoute("ime");
            return false;
        }
        root._setRoute("clipboard");          // until a field activates (the input method is started now) or `typeInto` says so
        if (root._imeOk) {
            root._imeStart();
            routeWait.restart();
        }
        return false;
    }
    // The route being left takes its preedit with it (the next one shows the words where they go now).
    function _leaveRoute(): void {
        if (root._route === "shell")
            root._shellWrite("preedit", "");
        else if (root._route === "ime" && root._imeActive)
            root._imeWrite("preedit\t");
    }
    // One call into the content; false when it is gone (a content destroyed with its popup throws) or when it says it took nothing
    // (round 8: a commit the editor dropped was counted delivered, and the words were lost -- a content answers `false` for "not in the
    // field", and one that answers nothing (void) took it).
    function _shellWrite(kind: string, text: string): bool {
        const t = root._shell;
        if (!t)
            return false;
        try {
            const r = kind === "commit" ? t.dictationCommit(text) : t.dictationPreedit(text);
            if (r === false) {
                root._note({ ev: "shelldropped", kind: kind, chars: text.length });
                return false;
            }
            return true;
        } catch (e) {
            root._note({ ev: "shellerror", kind: kind, message: String(e) });
            return false;
        }
    }
    function _shellPrefix(): string {
        const t = root._shell;
        let before = null;
        try {
            if (t && typeof t.dictationBefore === "function")
                before = String(t.dictationBefore());
        } catch (e) {
            before = null;
        }
        return DT.joinPrefix(before === null ? "" : before, before !== null, root._segsInField);
    }
    onShellTargetChanged: if (root._state !== "idle" && root._mode === "type") shellSettle.restart()
    Timer {
        id: shellSettle
        interval: root.shellSettleMs
        onTriggered: root._shellCheck()
    }

    // ---- delivery ------------------------------------------------------------------------------------------------------------------
    function _showPreedit(): void {
        if (root._route === "shell") {
            if (!root._shellWrite("preedit", root._preedit === "" ? "" : root._shellPrefix() + root._preedit))
                root._shellCheck();
            return;
        }
        const rule = DT.fieldRule(root._purpose, root._hint);
        if (root._route !== "ime" || !root._imeActive || rule === "refuse")
            return;
        const t = root._preedit === "" ? "" : DT.joinPrefix(root._before, root._beforeKnown, root._segsInField) + DT.shape(root._preedit, rule);
        root._imeWrite("preedit\t" + DT.esc(t));
    }

    function _deliver(text: string): void {
        const t = String(text).trim();
        if (t === "") {
            if (root._route === "shell")
                root._shellWrite("preedit", "");
            else if (root._route === "ime" && root._imeActive)
                root._imeWrite("preedit\t");
            return;
        }
        root._pieces = root._pieces.concat([t]);
        if (root._route === "shell") {
            const out = root._shellPrefix() + t;
            if (root._shellWrite("commit", out)) {
                root._segsInField += 1;
                root._note({ ev: "commit", route: "shell", text: out });
                return;
            }
            root._shellCheck();                    // the content is gone: the piece goes where the take goes now
        }
        if (root._route === "ime" && root._imeActive) {
            const rule = DT.fieldRule(root._purpose, root._hint);
            if (rule === "refuse") {
                root._secret = true;
                root._note({ ev: "refused", purpose: root._purpose, hint: root._hint });
                return;
            }
            const out = DT.joinPrefix(root._before, root._beforeKnown, root._segsInField) + DT.shape(t, rule);
            root._imeWrite("commit\t" + DT.esc(out));
            root._segsInField += 1;
            root._beforeKnown = false;            // until the field reports again
            root._note({ ev: "commit", text: out });
            return;
        }
        if (root._route === "type") {
            if (!typer.running) {
                typer.stdinEnabled = true;
                typer.running = true;
            }
            typer.write("type\t" + DT.esc((root._segsInField > 0 ? " " : "") + t) + "\n");
            root._segsInField += 1;
            root._note({ ev: "typed", text: t });
            return;
        }
        root._clip = root._clip === "" ? t : root._clip + " " + t;
        root._note({ ev: "held", text: t });
    }

    function _decideRoute(): void {
        root._routePending = false;
        if (root._route === "shell")
            return;                               // the shell's own field has the take (THE SHELL ROUTE)
        if (root._imeActive) {
            root._setRoute("ime");
            return;
        }
        const types = root.config.typeInto;
        if (root._imeOk && types && types.length > 0) {
            if (!root._windowKnown) {
                root._routePending = true;    // the class decides between typing and the clipboard: when it is read
                return;
            }
            root._setRoute(root._windowClass !== "" && types.indexOf(root._windowClass) >= 0 ? "type" : "clipboard");
            return;
        }
        root._setRoute("clipboard");
    }

    function _setRoute(r: string): void {
        if (root._route === r)
            return;
        root._route = r;
        root._routes = root._routes.concat([{ route: r, ms: root._sincePress() }]);
        root._note({ ev: "route", route: r });
        if (r === "ime" || r === "shell")
            root._showPreedit();
    }

    Timer {
        id: routeWait
        // Hyprland enters a new input method into the focused field at once; 300 ms is the most an `activate` takes to come back
        interval: 300
        onTriggered: root._decideRoute()
    }
    Process {
        id: activeWindow
        command: root.activeWindowCommand
        stdout: StdioCollector {
            id: activeOut
        }
        onExited: {
            let w = {};
            try {
                w = JSON.parse(activeOut.text || "{}") || {};
            } catch (e) {
                w = {};
            }
            root._windowClass = String(w.class || "");
            root._windowTitle = String(w.title || "");
            root._windowPid = Number(w.pid) > 0 ? Number(w.pid) : 0;
            root._windowKnown = true;
            root._note({ ev: "window", cls: root._windowClass, pid: root._windowPid });
            if (root._routePending && root._state !== "idle")
                root._decideRoute();
            if (root._state === "idle" || root._mode === "type")
                return;
            if (root._mode === "source" && root._windowPid <= 0) {
                root.toast("Nothing to listen to", "No window has the focus");
                root._stop();
                return;
            }
            // the helper: a window take links the window's streams; an ask learns the cwd under a terminal
            root._send({ op: "window", take: root._take, pid: root._windowPid, title: root._windowTitle,
                         watch: root._mode === "source", cwd: root._mode === "ask" });
            root._caption();
        }
    }

    // ---- the input method --------------------------------------------------------------------------------------------------------
    Process {
        id: ime
        command: ["setpriv", "--pdeathsig", "TERM", "--", root.imePath]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => {
                const parts = String(data).split("\n");
                for (let i = 0; i < parts.length; i++)
                    root._onImeLine(parts[i]);
            }
        }
        // the last take's input method has gone: the take that wanted one gets its own now
        onRunningChanged: {
            if (ime.running)
                return;
            root._imeQuitting = false;
            imeKill.stop();
            if (root._imeWanted) {
                root._imeWanted = false;
                if (root._state !== "idle" && root._mode === "type" && root._route !== "shell")
                    root._imeStart();
            }
        }
    }
    // the last take's lares-ime told to quit and not gone yet (a press right after a stop): the new take waits for it, never writes into it
    property bool _imeQuitting: false
    property bool _imeWanted: false

    function _imeStart(): void {
        if (ime.running) {
            if (root._imeQuitting && !root._imeWanted) {
                root._imeWanted = true;
                root._note({ ev: "imewait" });
                imeKill.restart();
            }
            return;
        }
        root._imeQuitting = false;
        ime.stdinEnabled = true;
        ime.running = true;
    }
    Timer {
        id: imeKill
        // a lares-ime that has not gone 1 s after its `quit` is ended (its exit starts the take's)
        interval: 1000
        onTriggered: if (ime.running) ime.signal(15)
    }

    function _imeWrite(line: string): void {
        if (ime.running)
            ime.write(line + "\n");
    }

    function _imeQuit(): void {
        root._imeWanted = false;
        if (ime.running)
            root._imeQuitting = true;
        for (const p of [ime, typer]) {
            if (!p.running)
                continue;
            p.write("quit\n");
            p.stdinEnabled = false;      // the EOF: lares-ime ends on either
        }
    }
    // THE TYPING: a second lares-ime with no input method (`--type-only`). Hyprland ignores the keys of a virtual keyboard whose client
    // holds the input method (its relay would loop them back), so the keyboard that types must be another client's.
    Process {
        id: typer
        command: ["setpriv", "--pdeathsig", "TERM", "--", root.imePath, "--type-only"]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => root._note({ ev: "typer", line: String(data) })
        }
    }

    function _onImeLine(line: string): void {
        if (line === "")
            return;
        const f = line.split("\t");
        switch (f[0]) {
        case "activate":
            root._imeActive = true;
            root._note({ ev: "activate" });
            // the shell's own field keeps the take while it has the caret (an app's field the input method found waits for its loss)
            if (root._state !== "idle" && root._route !== "shell") {
                root._segsInField = 0;
                routeWait.stop();
                root._setRoute("ime");
                root._showPreedit();
            }
            break;
        case "deactivate":
            root._imeActive = false;
            root._beforeKnown = false;
            root._note({ ev: "deactivate" });
            if (root._state !== "idle" && root._route === "ime")
                root._setRoute("clipboard");
            break;
        case "content":
            root._hint = parseInt(f[1]) || 0;
            root._purpose = parseInt(f[2]) || 0;
            break;
        case "surrounding": {
            const txt = DT.unesc(f[1] || "");
            const cur = parseInt(f[2]) || 0;
            // the cursor is a BYTE offset: cut the UTF-8 bytes, then decode
            root._before = root._utf8Prefix(txt, cur);
            root._beforeKnown = true;
            break;
        }
        case "ready":
            if ((parseInt(f[1]) || 1) < root.imeVersion && !root._imeOld) {
                root._imeOld = true;
                root._note({ ev: "imeold", version: parseInt(f[1]) || 1 });
                root.toast("Dictation: the input method is out of date", "Run tools/stt/ime/build.sh once (a field may not show the first take live until then)");
            }
            break;
        case "rebound":
            // no `activate` came: lares-ime bound again (a field enabled before the bind gets its enter now); the route waits again
            root._note({ ev: "rebound", ms: parseInt(f[1]) || 0 });
            if (root._state !== "idle" && !root._imeActive)
                routeWait.restart();
            break;
        case "unavailable":
            root._note({ ev: "unavailable" });
            root.toast("Dictation", "Another input method holds the keyboard: the text goes to the clipboard");
            break;
        case "error":
            root._note({ ev: "imeerror", message: f.slice(1).join(" ") });
            break;
        default:
            break;
        }
    }

    function _utf8Prefix(text: string, bytes: int): string {
        let n = 0, i = 0;
        for (; i < text.length && n < bytes; i++) {
            const c = text.charCodeAt(i);
            n += c < 0x80 ? 1 : c < 0x800 ? 2 : (c >= 0xD800 && c < 0xDC00) ? 4 : 3;
            if (c >= 0xD800 && c < 0xDC00)
                i++;
        }
        return text.substring(0, i);
    }

    // ---- the clipboard -----------------------------------------------------------------------------------------------------------
    Process {
        id: copier
        command: root.copyCommand
        property string pending: ""
        onStarted: {
            copier.write(copier.pending);
            copier.stdinEnabled = false;
        }
    }
    function _copy(text: string): void {
        copier.pending = text;
        copier.stdinEnabled = true;
        copier.running = true;
        root._note({ ev: "copied", text: text });
    }

    // ---- the mic ---------------------------------------------------------------------------------------------------------------
    readonly property var _source: root.pipewire ? root.pipewire.defaultSource : null
    readonly property real _sourceVolume: root._source && root._source.audio ? root._source.audio.volume : 0
    on_SourceVolumeChanged: if (root._sourceVolume > 0.001 && !root._mic) root._lastMicVolume = root._sourceVolume

    function _micMuted(): bool {
        const a = root._source ? root._source.audio : null;
        return !!a && (a.muted === true || (Number(a.volume) || 0) <= 0.001);
    }
    // The node to capture from (its node.name), unmuted and audible for the take.
    function _micTake(): string {
        root._mic = null;
        const n = root._source;
        if (!n || !n.audio)
            return "";
        const name = String(n.name || "");
        const wasMuted = n.audio.muted === true;
        const wasVolume = Number(n.audio.volume) || 0;
        const raise = wasVolume <= 0.001;
        if (!wasMuted && !raise) {
            root._note({ ev: "mic", node: name, changed: false });
            return name;
        }
        const want = root.config.micVolume >= 0 && root.config.micVolume <= 1.5 ? root.config.micVolume
                   : (root._lastMicVolume > 0.001 ? root._lastMicVolume : 0.6);
        // written down BEFORE the change: a shell that dies mid-take puts it back at its next start
        root._mic = { node: name, wasMuted: wasMuted, wasVolume: wasVolume, setVolume: raise ? want : -1 };
        root._saveState();
        if (wasMuted)
            root.pipewire.setMuted(n, false);
        if (raise)
            root.pipewire.setVolume(n, want);
        root._note({ ev: "mic", node: name, changed: true, wasMuted: wasMuted, wasVolume: wasVolume, setVolume: raise ? want : -1 });
        return name;
    }

    function _nodeNamed(name: string): var {
        const pw = root.pipewire;
        if (!pw || name === "")
            return null;
        if (pw.defaultSource && pw.defaultSource.name === name)
            return pw.defaultSource;
        const list = pw.hardwareSources || [];
        for (let i = 0; i < list.length; i++)
            if (list[i] && list[i].name === name)
                return list[i];
        return null;
    }

    // Put back what the take changed, on that node -- unless the user changed it meanwhile (their act wins).
    function _restoreMic(m: var): bool {
        const n = root._nodeNamed(m.node);
        if (!n || !n.audio)
            return false;
        let did = [];
        if (n.audio.muted === false) {
            if (m.setVolume >= 0 && Math.abs(Number(n.audio.volume) - m.setVolume) < 0.02) {
                root.pipewire.setVolume(n, m.wasVolume);
                did.push("volume");
            }
            if (m.wasMuted) {
                root.pipewire.setMuted(n, true);
                did.push("mute");
            }
        }
        root._note({ ev: "micrestore", node: m.node, did: did });
        return true;
    }

    function _micRestore(): void {
        const m = root._mic;
        root._mic = null;
        if (!m)
            return;
        root._restoreMic(m);
        root._saveState();
    }

    // ---- the aura -------------------------------------------------------------------------------------------------------------------
    property bool _auraOn: false
    property string _auraGroup: ""
    // THE AURA (top of the file): "island" at the press, "all" at `running`
    function _aura(group: string): void {
        if (typeof root.playAura !== "function" || !root.config.aura)
            return;
        root._auraOn = true;
        root._auraGroup = group;
        const a = root.playAura("siri", group, 600000);
        root._note({ ev: "aura", group: group, life: 600000, answer: String(a) });
        auraRenew.restart();
    }
    Timer {
        id: auraRenew
        interval: 540000
        onTriggered: if (root._state === "starting" || root._state === "listening") root._aura(root._auraGroup)
    }

    // ---- timers --------------------------------------------------------------------------------------------------------------------
    Timer {
        id: stopWait
        // the helper finishes the last sentence (one decode) and says `ended`; a helper that does not is not waited for
        interval: 6000
        onTriggered: {
            // a helper that does not end a take is broken: it is started again (A TAKE CAN NEVER GET STUCK)
            root._note({ ev: "stoptimeout" });
            root._stall("stop");
        }
    }
    Timer {
        id: keepWarm
        interval: Math.max(root._onCard ? 0.25 : 1, root._onCard ? root.config.dgpuKeepMin : root.config.keepWarmMin) * 60000
        // the helper is started again, light: its models go (and a card it held sleeps; the next take picks its device again)
        onTriggered: {
            if (root._state !== "idle")
                return;
            root._restartHelper("rest");
        }
    }

    // ---- state: the prior language and a mic to put back ------------------------------------------------------------------------
    readonly property string _statePath: root.stateDir !== "" ? root.stateDir + "/dictation/state.json" : ""
    FileView {
        id: stateFile
        path: root._statePath
        blockLoading: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }
    property bool _dirReady: false
    Process {
        id: mkdir
        command: ["mkdir", "-p", root.stateDir + "/dictation"]
        onExited: root._dirReady = true
    }
    function _saveState(): void {
        if (!root.live || !root._dirReady || root._statePath === "")
            return;
        stateFile.setText(JSON.stringify({ prior: root._prior, mic: root._mic }) + "\n");
    }
    property var _pendingRestore: null
    property int _restoreTries: 0
    Timer {
        id: restoreRetry
        interval: 1000
        repeat: true
        onTriggered: {
            root._restoreTries += 1;
            if (root._pendingRestore && root._restoreMic(root._pendingRestore)) {
                root._pendingRestore = null;
                root._saveState();
            }
            if (!root._pendingRestore || root._restoreTries >= 30)
                restoreRetry.stop();
        }
    }

    // ---- the take log ---------------------------------------------------------------------------------------------------------------
    // THE WRITER (round 6): a file that does not end in a newline gets one first (someone saved it without; the next record was
    // glued to the last), the records go on, the last `logKeep` stay -- trimmed through a tmp of this process's own. A record finished
    // while a write runs waits in `_logQueue` and goes with the next.
    property var _logQueue: []
    Process {
        id: logger
        property string pending: ""
        command: ["sh", "-c", "f=$1; if [ -s \"$f\" ] && [ -n \"$(tail -c 1 \"$f\")\" ]; then printf '\\n' >> \"$f\"; fi; "
                  + "cat >> \"$f\" && tail -n \"$2\" \"$f\" > \"$f.tmp.$$\" && mv \"$f.tmp.$$\" \"$f\"", "sh", root.stateDir + "/dictation/takes.jsonl",
                  String(Math.max(1, Math.min(10000, Math.round(root.config.logKeep))))]
        onStarted: {
            logger.write(logger.pending);
            logger.stdinEnabled = false;
        }
        onRunningChanged: if (!logger.running) root._logNext()
    }
    function _logNext(): void {
        if (logger.running || root._logQueue.length === 0)
            return;
        logger.pending = root._logQueue.join("");
        root._logQueue = [];
        logger.stdinEnabled = true;
        logger.running = true;
    }
    function _logTake(reason: string): void {
        if (!root.live || !root.config.logTakes || !root._dirReady || root._secret
                || DT.fieldRule(root._purpose, root._hint) === "refuse")
            return;
        // what was written: into a field (or the clipboard); a window take's transcript; an ask's question
        const pieces = root._mode === "type" ? root._pieces : root._said;
        const rec = { at: new Date().toISOString(), take: root._take, reason: reason, mode: root._mode, lang: root._lang, route: root._route,
                      routes: root._routes, window: root._windowClass, device: root._device, times: root._times,
                      segs: root._segs, thinks: root._thinks, pieces: pieces };
        // round 8: the helper's own word for how it ended, how it went when it did, why it was stalled, and a GPU that fell to the CPU
        if (root._helperEnded !== "")
            rec.helperReason = root._helperEnded;
        if (root._exitInfo)
            rec.exit = root._exitInfo;
        if (root._stallInfo)
            rec.stall = root._stallInfo;
        if (root._fallbacks.length > 0)
            rec.fallbacks = root._fallbacks;
        if (root._mode === "source")
            rec.streams = root._streamsSeen.map(x => ({ serial: x.serial, app: x.app }));     // the streams it linked
        if (root._heard.join(" ") !== pieces.join(" "))
            rec.heard = root._heard;          // what the model wrote, fillers and all (the filler rule and the tidy pass, judged)
        root._logQueue = root._logQueue.concat([JSON.stringify(rec) + "\n"]);
        root._logNext();
    }

    // ---- start-up: is everything there ---------------------------------------------------------------------------------------------
    Process {
        id: check
        command: ["sh", "-c", "test -x \"$1\" && test -f \"$2\" && echo helper; test -x \"$3\" && echo ime", "sh",
                  root.pythonPath, root.helperScript, root.imePath]
        stdout: StdioCollector {
            id: checkOut
        }
        onExited: {
            const t = checkOut.text || "";
            root._helperOk = t.indexOf("helper") >= 0;
            root._imeOk = t.indexOf("ime") >= 0;
            root._checked = true;
            root._note({ ev: "checked", helper: root._helperOk, ime: root._imeOk });
        }
    }
    function _boot(): void {
        if (!root.live || root._checked || check.running)
            return;
        check.running = true;
        if (root.stateDir !== "")
            mkdir.running = true;
        if (root._statePath !== "") {
            try {
                const o = JSON.parse(stateFile.text() || "{}");
                if (o.prior === "en" || o.prior === "nl")
                    root._prior = o.prior;
                if (o.mic && o.mic.node) {
                    root._pendingRestore = o.mic;
                    restoreRetry.start();
                }
            } catch (e) {
                // a state file that does not parse is no state
            }
        }
    }
    // Checked once the switch is on (a shell with it off runs nothing at all), and again when it is turned on hot.
    onEnabledChanged: {
        if (root.enabled)
            root._boot();
        else if (root._state !== "idle")
            root._finish("off");
    }
    Component.onCompleted: if (root.enabled) root._boot()
}
