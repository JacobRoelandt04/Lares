pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/common/notify"
import "modules/common/power"
import "modules/bar/gooey"
import "modules/bar/llm"
import "modules/bar/llm/components"

// =============================================================================
// tools/dev/qml/llm_voice_probe.qml -- a SPOKEN ask, end to end, against a stub ollama (tools/dev/llm_voice_probe.sh).
//
// The real LlmBackend (curl to tools/dev/llm_voice_stub.py), LlmStore (a private file), LlmTools (the shipped llm_tools/,
// unscoped: systemd-run is a stub that says no), LlmService, LlmAttention and LlmMachine (no GPU: only its CPU floor, a note in
// PowerBus here); the real LlmBarOwner on a real GooeyEngine and bar, the attention's `openConversation` routed to it as
// ShellServices routes it, and the real LlmBarButton on the same service. The bus is a recorder whose toasts can be "clicked".
// A SPOKEN ask runs in the BACKGROUND (round 8: the user wanted it silent): nothing in it opens a popup or moves the open chat.
// Each step speaks one ask through `voiceAsk(text, { windowClass, windowTitle, cwd })` with the stub repository as the directory:
//   v1 silent       the conversation is made but is NOT the active one, the glyph is working from the moment it was heard (it waits
//                   in the queue for the model list), the service lists the models ITSELF, tools ride with the wrench off, the
//                   system note names the directory, `git log -1 --format=%h` runs at once (no card) in the stub repository AS AN
//                   ARGV, the one-block answer is copied (wl-copy stub), and ONE toast says "Copied" with the hash and an "Open
//                   chat"; no popup opened, the glyph is not latched as an unseen answer
//   v1r released    with no popup open the model is let go after the answer: the server is told, and LlmMachine's floor goes
//                   within ~10 s (its 5 s linger)
//   v2 chat open    the chat is open on its own conversation: the spoken ask leaves it on that conversation, the popup stays
//                   where it was, nothing is released under it; prose is not copied: ONE toast holds the answer; its "Open chat"
//                   opens THAT conversation
//   v3 asks         `touch notes.txt` waits for the click (the chat open on another conversation shows no Run for it): a toast with
//                   the exact command, the folder and Run / Deny / Open chat; nothing ran by itself; Deny settles it; the old
//                   toast's Run then does nothing and says so
//   v3c run         the same ask again: Run (through the toast) runs the command, the toast is gone, the model is kept until then
//   v3d dropped     an ask nobody answers is dropped after `voiceConfirmDropMs` with its one toast, and the model goes
//   v4 taint        a free read_file of the repository's README, then web_search ASKS (the turn read the machine)
//   v5 secret       `cat ~/.ssh/id_ed25519` asks (answered in the panel's road: the toast is withdrawn)
//   v6 stricter     `git log --oneline | head -1` asks, where a typed chat's policy runs it unasked
//   v8 search       search_files in "." runs free (no secret store below the repository) and never opens its .env
//   v9 failed       a spoken ask the server refuses says why in its one toast
//   v7 typed        a typed ask in the same service with the wrench off carries no tools and copies nothing; its answer with no
//                   chat open is still the generic "answer" notice and latches the glyph (typed chats are unchanged)
//
// SAFETY: nothing runs unless LLMV=1 and the runner's stub directory leads PATH (wl-copy, notify-send and systemd-run are
// stubs; the commands that run are git on the stub repository and python3 on llm_tools/). Without the gate this file loads,
// says SKIP and quits, so a smoke sweep is inert.
// =============================================================================
Window {
    id: w
    width: 1400
    height: 900
    visible: true
    color: "#3B4453"

    readonly property bool armed: Quickshell.env("LLMV") === "1"
    readonly property string stubDir: Quickshell.env("LLMV_STUB_DIR") || ""
    readonly property bool stubbed: w.armed && w.stubDir.length > 0
        && String(Quickshell.env("PATH") || "").indexOf(w.stubDir + ":") === 0

    Loader {
        anchors.fill: parent
        active: w.stubbed
        sourceComponent: rigComp
    }

    Timer {
        interval: 0
        running: !w.stubbed
        onTriggered: {
            console.log("LLMV not armed -- LLMV=1 and the stub first on PATH (tools/dev/llm_voice_probe.sh does both)");
            console.log("LLM-VOICE RESULT SKIP");
            Qt.quit();
        }
    }

    Component {
        id: rigComp

        Item {
            id: rig

            readonly property string repo: Quickshell.env("LLMV_REPO") || ""
            readonly property string hash: Quickshell.env("LLMV_HASH") || ""
            readonly property var ctx: ({ windowClass: "kitty", windowTitle: "proj", cwd: rig.repo })

            // ---- the ledger ----------------------------------------------------------------------------------------------
            property var fails: []
            property int checks: 0
            function sub(id, name, ok, saw) {
                rig.checks++;
                if (!ok)
                    rig.fails.push(id + "." + name);
                console.log("  " + (ok ? "ok  " : "FAIL") + " " + id + "." + name + "   " + saw);
            }

            // ---- what the services did, recorded -----------------------------------------------------------------------
            QtObject {
                id: bus
                property var posts: []
                property var withdrawn: []
                function post(spec) { bus.posts = bus.posts.concat([spec]); return "rec" + bus.posts.length; }
                function withdraw(source, key) { bus.withdrawn = bus.withdrawn.concat([source + "/" + key]); }
                // A click on a toast's action, as the notification service does it: the callback runs.
                function click(spec, id) {
                    if (typeof spec.onAction === "function")
                        spec.onAction(id);
                }
            }
            property int confirms: 0
            property var argvs: []
            FileView {
                id: reqLog
                path: Quickshell.env("LLMV_REQ_LOG") || ""
                blockLoading: true
                blockAllReads: true
                printErrors: false
            }
            FileView {
                id: copyLog
                path: Quickshell.env("LLMV_COPY_LOG") || ""
                blockLoading: true
                blockAllReads: true
                printErrors: false
            }
            function reqs() {
                reqLog.reload();
                return String(reqLog.text() || "").split("\n").filter(l => l.length > 0).map(l => JSON.parse(l));
            }
            function copies() {
                copyLog.reload();
                return String(copyLog.text() || "").split("\u001e").filter(l => l.length > 0);
            }

            // ---- the chat's services, as LlmServices arranges them (no LlmMachine: it would ask the GPU and the CPU profile) ----
            LlmBackend {
                id: stubBackend
                baseUrl: Quickshell.env("LLMV_URL") || "http://127.0.0.1:9"
            }
            LlmStore {
                id: convStore
                path: (Quickshell.env("XDG_STATE_HOME") || "/tmp") + "/llmv/conversations.json"
            }
            LlmTools {
                id: toolReg
                store: convStore
                broker: null
                scoped: false
                onRunningChanged: {
                    if (toolReg.running && toolReg._job && toolReg._job.frozen)
                        rig.argvs = rig.argvs.concat([toolReg._job.frozen.argv.slice()]);
                }
            }
            LlmService {
                id: svc
                backend: stubBackend
                store: convStore
                tools: toolReg
                model: "stub:voice"
                toolsEnabled: false
                toolProbeEnabled: false
                probeGpuAtStart: false
                onConfirmRequested: rig.confirms++
            }
            LlmAttention {
                id: attention
                service: svc
                attended: owner.popupMine
            }
            LlmMachine {
                id: machine
                service: svc
                gpu: null
            }
            LlmResidency {
                id: residency
                service: svc
                attended: owner.popupMine
            }
            LlmBarButton {
                id: glyph
                llm: bundle
                x: 700
                y: 10
            }
            QtObject {
                id: bundle
                readonly property var service: svc
                readonly property bool attended: owner.popupMine
            }
            Connections {
                target: attention
                function onOpenConversation(convId) {
                    owner.openConversation(convId);
                }
            }

            // ---- one screen: an engine, a top bar, the chat's owner --------------------------------------------------
            GooeyEngine {
                id: eng
                anchors.fill: parent
                surfaceColor: Theme.surface
                barsList: [topBar]

                GooeyBar {
                    id: topBar
                    engine: eng
                    barId: "top"
                    edge: "top"
                    rawPos: 0
                    rawLen: eng.w

                    Item {
                        id: anchorMark
                        x: 200
                        width: 30
                        height: topBar.height
                    }
                }
            }
            LlmBarOwner {
                id: owner
                engine: eng
                bar: topBar
                barId: "top"
                ownerId: "llm"
                anchorItem: anchorMark
                llm: bundle
            }

            // ---- the sequencer: each step starts, waits for its fact (or its deadline), then judges ---------------------
            property var steps: []
            property int at: -1
            property real stepAt: 0
            property bool started: false
            property var mem: ({})
            Timer {
                id: tick
                interval: 50
                repeat: true
                running: true
                onTriggered: rig.pump()
            }
            function pump() {
                if (svc.generating && machine.holdingFloor)
                    rig.mem.sawFloor = true;
                if (rig.at < 0) {
                    if (!toolReg.ready || !convStore.loaded)
                        return;
                    NotificationBus.service = bus;
                    rig.at = 0;
                    rig.started = false;
                }
                if (rig.at >= rig.steps.length) {
                    tick.stop();
                    console.log("checks " + rig.checks + ", " + rig.fails.length + " failed" + (rig.fails.length ? ": " + rig.fails.join(" ") : ""));
                    console.log("LLM-VOICE RESULT " + (rig.fails.length === 0 && rig.checks > 0 ? "PASS" : "FAIL"));
                    NotificationBus.service = null;
                    Qt.quit();
                    return;
                }
                const s = rig.steps[rig.at];
                try {
                    if (!rig.started) {
                        rig.started = true;
                        rig.stepAt = Date.now();
                        console.log("STEP " + s.name);
                        s.start();
                        return;
                    }
                    if (!s.until() && Date.now() - rig.stepAt < (s.ms || 15000))
                        return;
                    if (!s.until())
                        rig.sub(s.name, "deadline", false, "its fact did not come within " + (s.ms || 15000) + " ms");
                    else
                        s.check();
                } catch (err) {
                    rig.sub(s.name, "threw", false, String(err));
                }
                rig.at++;
                rig.started = false;
            }

            // `touch notes.txt` ran since argv log line `from`: a confirmed command goes through bash -c, so its words are one element.
            function touched(from, count) {
                const n = rig.argvs.slice(from).filter(a => a.join(" ").indexOf("touch notes.txt") >= 0).length;
                return count ? n : n > 0;
            }
            function msgs(cid) { return convStore.messagesOf(cid); }
            function answer(cid) {
                const a = rig.msgs(cid);
                for (let i = a.length - 1; i >= 0; i--)
                    if (a[i].role === "assistant") return a[i];
                return null;
            }
            // A card stands, or the turn ended without one (then the step's own check says what ran).
            function carded() {
                return svc.pendingConfirm !== null || (rig.done(rig.mem.cid) && !svc.generating);
            }
            function card() {
                return svc.pendingConfirm || ({ id: "", tool: "(no card: the call ran)", detail: "", reason: "", cwd: "", grantable: null, parts: [] });
            }
            function deny(r) {
                if (r.id !== "")
                    svc.answerConfirm(r.id, "no");
            }
            function done(cid) {
                const m = rig.answer(cid);
                return !!m && !m.pending && !svc.generating;
            }
            function chatsSince(n) {
                return rig.reqs().slice(n).filter(r => r.path === "/api/chat" && r.body && r.body.stream !== false
                                                    && (r.body.messages || []).length > 0);
            }
            function speak(text) {
                rig.mem.reqs0 = rig.reqs().length;
                rig.mem.copies0 = rig.copies().length;
                rig.mem.posts0 = bus.posts.length;
                rig.mem.confirms0 = rig.confirms;
                rig.mem.argvs0 = rig.argvs.length;
                rig.mem.doneAt = 0;
                const before = svc.activeId;
                const had = svc.queue.map(e => e.convId);
                svc.voiceAsk(text, rig.ctx);
                // the ask's own conversation: the one the queue gained (the active one did not move)
                const fresh = svc.queue.filter(e => had.indexOf(e.convId) < 0 && e.voice);
                rig.mem.cid = fresh.length > 0 ? fresh[0].convId : "";
                rig.mem.newConv = rig.mem.cid !== "" && rig.mem.cid !== before && svc.activeId === before;
            }
            // The ask's toasts since `speak`, by the notice kinds the shell has: its one voice toast, the old "copied" / "answer" ones.
            function toastsOf(cid) {
                return bus.posts.slice(rig.mem.posts0).filter(x => x.source === "llm" && x.key === "voice-" + cid);
            }
            function strays() {
                return bus.posts.slice(rig.mem.posts0).filter(x => x.key === "copied" || x.key === "answer");
            }
            // The compositor's view of "a model was let go": a load request with keep_alive 0 after `n` log lines.
            function unloadsSince(n) {
                return rig.reqs().slice(n).filter(r => r.path === "/api/chat" && r.body && r.body.keep_alive === 0 && (r.body.messages || []).length === 0);
            }

            Component.onCompleted: {
                rig.steps = [
                    {
                        name: "v1", ms: 20000,
                        start: function () {
                            rig.mem.sawFloor = false;
                            rig.mem.unloads0 = rig.reqs().length;
                            rig.speak("What is the latest commit abbreviation?");
                            const q = svc.queue;
                            rig.sub("v1", "new-conversation", rig.mem.newConv && convStore.exists(rig.mem.cid) && svc.activeId === "",
                                    "ask's conversation " + rig.mem.cid + ", active " + JSON.stringify(svc.activeId));
                            rig.sub("v1", "titled-from-the-words", (convStore.meta(rig.mem.cid) || {}).title !== "",
                                    JSON.stringify((convStore.meta(rig.mem.cid) || {}).title));
                            rig.sub("v1", "queued-spoken", q.length === 1 && !!q[0].voice && q[0].voice.cwd === rig.repo,
                                    JSON.stringify(q.map(e => ({ conv: e.convId, voice: e.voice }))));
                            rig.sub("v1", "lists-the-models-itself", stubBackend.modelsLoading === true && stubBackend.models.length === 0,
                                    "modelsLoading " + stubBackend.modelsLoading + ", models " + stubBackend.models.length);
                            rig.sub("v1", "no-popup", !owner.popupMine && !eng.popupOpen, "popupOpen " + eng.popupOpen);
                            rig.sub("v1", "glyph-working-while-queued", svc.voiceQueued === true && svc.generating === false && glyph.generating === true,
                                    "voiceQueued " + svc.voiceQueued + ", generating " + svc.generating + ", glyph " + glyph.generating);
                        },
                        // The copy lands after the answer (wl-copy has to exit first): wait for its toast, or 4 s past the answer.
                        until: function () {
                            if (!rig.done(rig.mem.cid)) return false;
                            if (!rig.mem.doneAt) rig.mem.doneAt = Date.now();
                            return rig.toastsOf(rig.mem.cid).length > 0 || Date.now() - rig.mem.doneAt > 4000;
                        },
                        check: function () {
                            const rs = rig.reqs().slice(rig.mem.reqs0);
                            const tagsAt = rs.findIndex(r => r.path === "/api/tags");
                            const chatAt = rs.findIndex(r => r.path === "/api/chat" && r.body && r.body.stream !== false && (r.body.messages || []).length > 0);
                            rig.sub("v1", "tags-before-the-turn", tagsAt >= 0 && chatAt > tagsAt, "tags at " + tagsAt + ", chat at " + chatAt);
                            const first = chatAt >= 0 ? rs[chatAt].body : null;
                            const nTools = first && first.tools ? first.tools.length : 0;
                            rig.sub("v1", "tools-offered-wrench-off", nTools > 0 && svc.toolsEnabled === false,
                                    nTools + " tool definitions, toolsEnabled " + svc.toolsEnabled);
                            const sys = first && first.messages[0].role === "system" ? String(first.messages[0].content) : "";
                            rig.sub("v1", "system-note", sys.indexOf("Commands run in " + rig.repo + ".") >= 0 && sys.indexOf("spoken aloud") >= 0
                                    && sys.indexOf("kitty titled \"proj\"") >= 0, JSON.stringify(sys.substring(sys.indexOf("This request"), sys.indexOf("This request") + 60)));
                            const a = rig.answer(rig.mem.cid);
                            const tc = (a && a.toolCalls) ? a.toolCalls : [];
                            const c0 = tc[0] || {};
                            rig.sub("v1", "ran-without-a-card", tc.length === 1 && c0.decision === "auto" && c0.status === "done"
                                    && rig.confirms === rig.mem.confirms0,
                                    tc.length + " call(s): " + c0.name + " " + c0.decision + " " + c0.status + ", cards " + (rig.confirms - rig.mem.confirms0));
                            rig.sub("v1", "in-the-repository", rig.hash.length >= 7 && String(c0.result || "").indexOf(rig.hash) >= 0,
                                    "result " + JSON.stringify(String(c0.result || "").substring(0, 60)) + ", want " + rig.hash);
                            const av = rig.argvs.slice(rig.mem.argvs0);
                            const run = av.length > 0 ? av[av.length - 1] : [];
                            const gi = run.indexOf("git");
                            rig.sub("v1", "as-an-argv", gi > 0 && run.indexOf("bash") < 0 && run.indexOf("--no-pager") === gi + 1
                                    && run.indexOf("core.fsmonitor=false") > gi && run.indexOf("--no-ext-diff") > run.indexOf("log"),
                                    JSON.stringify(run));
                            const cp = rig.copies().slice(rig.mem.copies0);
                            rig.sub("v1", "copied", cp.length === 1 && cp[0] === rig.hash && a.copiedToClipboard === true,
                                    JSON.stringify(cp) + ", copiedToClipboard " + a.copiedToClipboard);
                            const p = rig.toastsOf(rig.mem.cid);
                            rig.sub("v1", "one-toast-copied", p.length === 1 && p[0].title === "Copied" && p[0].body === rig.hash
                                    && (p[0].actions || []).length === 1 && p[0].actions[0].id === "open" && p[0].actions[0].label === "Open chat"
                                    && p[0].timeoutMs === undefined,
                                    JSON.stringify(p.map(x => [x.title, x.body, (x.actions || []).map(y => y.id), x.timeoutMs])));
                            rig.sub("v1", "no-second-notice", rig.strays().length === 0,
                                    rig.strays().length + " old-style \"copied\" / \"answer\" notice(s) beside the toast");
                            rig.sub("v1", "still-no-popup", !eng.popupOpen && svc.activeId === "", "popupOpen " + eng.popupOpen + ", active " + JSON.stringify(svc.activeId));
                            rig.sub("v1", "floor-held-while-working", rig.mem.sawFloor === true, "LlmMachine floor seen during the turn: " + rig.mem.sawFloor);
                            rig.sub("v1", "glyph-quiet-after", glyph._unseenAnswer === false && glyph.needsYou === false,
                                    "unseenAnswer " + glyph._unseenAnswer + " (the toast is a spoken ask's notice)");
                        }
                    },
                    {
                        // NO POPUP IS OPEN, so the model goes: the server is told, and the machine lets go after its linger (5 s).
                        name: "v1r", ms: 12000,
                        start: function () { },
                        until: function () { return rig.unloadsSince(rig.mem.unloads0).length > 0 && !machine.holdingFloor && PowerBus.heldBy !== "llm"; },
                        check: function () {
                            rig.sub("v1r", "model-released", rig.unloadsSince(rig.mem.unloads0).length >= 1,
                                    rig.unloadsSince(rig.mem.unloads0).length + " unload request(s) (keep_alive 0)");
                            rig.sub("v1r", "floor-released", !machine.holdingFloor && PowerBus.heldBy !== "llm",
                                    "holdingFloor " + machine.holdingFloor + ", PowerBus held by " + JSON.stringify(PowerBus.heldBy));
                        }
                    },
                    {
                        name: "v2", ms: 15000,
                        start: function () {
                            owner.open();
                            svc.newChat();
                            rig.mem.chatId = svc.activeId;
                            rig.mem.unloads0 = rig.reqs().length;
                            rig.sub("v2", "chat-open", owner.popupMine && eng.popupOwnerId === "llm" && rig.mem.chatId !== "",
                                    "popupMine " + owner.popupMine + ", owner " + eng.popupOwnerId + ", chat " + rig.mem.chatId);
                            rig.speak("Explain what a commit is");
                        },
                        until: function () {
                            if (!rig.done(rig.mem.cid)) return false;
                            if (!rig.mem.doneAt) rig.mem.doneAt = Date.now();
                            return rig.toastsOf(rig.mem.cid).length > 0 || Date.now() - rig.mem.doneAt > 4000;
                        },
                        check: function () {
                            rig.sub("v2", "chat-keeps-its-conversation", svc.activeId === rig.mem.chatId && convStore.exists(rig.mem.chatId)
                                    && owner.popupMine && eng.popupOwnerId === "llm",
                                    "active " + (svc.activeId === rig.mem.chatId ? "the chat's own" : svc.activeId) + ", popupMine " + owner.popupMine);
                            const a = rig.answer(rig.mem.cid);
                            rig.sub("v2", "prose-not-copied", rig.copies().length === rig.mem.copies0 && !a.copiedToClipboard,
                                    "copies " + (rig.copies().length - rig.mem.copies0) + ", answer " + JSON.stringify(String(a.content).substring(0, 40)));
                            const p = rig.toastsOf(rig.mem.cid);
                            rig.sub("v2", "one-toast-with-the-answer", p.length === 1 && p[0].title !== "Copied" && p[0].body === String(a.content)
                                    && (p[0].actions || []).some(x => x.id === "open") && rig.strays().length === 0,
                                    JSON.stringify(p.map(x => [x.title, x.body.substring(0, 50)])) + ", strays " + rig.strays().length);
                            rig.sub("v2", "model-kept-while-the-chat-is-open", rig.unloadsSince(rig.mem.unloads0).length === 0,
                                    rig.unloadsSince(rig.mem.unloads0).length + " unload(s) with a popup up");
                            // "Open chat" opens THAT conversation
                            bus.click(p[0], "open");
                            rig.sub("v2", "open-chat-opens-that-conversation", svc.activeId === rig.mem.cid && owner.popupMine,
                                    "active " + (svc.activeId === rig.mem.cid ? "the ask's" : svc.activeId) + ", popupMine " + owner.popupMine);
                            rig.mem.chatId = "";
                        }
                    },
                    {
                        // the chat is put away: with nothing open the model goes
                        name: "v2b", ms: 15000,
                        start: function () {
                            owner.close();
                            rig.mem.unloads0 = rig.reqs().length;
                        },
                        until: function () { return rig.unloadsSince(rig.mem.unloads0).length > 0; },
                        check: function () { rig.sub("v2b", "released-when-the-chat-closed", true, "an unload followed the close"); }
                    },
                    {
                        name: "v3", ms: 15000,
                        start: function () {
                            // the chat is open on a conversation of its own while the ask is spoken
                            owner.open();
                            svc.newChat();
                            rig.mem.chatId = svc.activeId;
                            rig.mem.unloads0 = rig.reqs().length;
                            rig.speak("touch a notes file");
                        },
                        until: function () { return rig.carded() && bus.posts.slice(rig.mem.posts0).some(x => x.key === "confirm"); },
                        check: function () {
                            const r = rig.card();
                            rig.sub("v3", "waits-for-the-click", r.tool === "run_command" && r.detail === "touch notes.txt" && r.spoken === true,
                                    r.tool + " " + JSON.stringify(r.detail) + " spoken " + r.spoken);
                            rig.sub("v3", "no-rule-offered", r.grantable === false && (r.parts || []).length === 0,
                                    "grantable " + r.grantable + ", parts " + (r.parts || []).length);
                            rig.sub("v3", "shows-where", r.cwd === rig.repo, "cwd " + r.cwd);
                            rig.sub("v3", "says-why", String(r.reason).indexOf("spoken request") >= 0 && String(r.reason).indexOf("touch") >= 0,
                                    JSON.stringify(r.reason));
                            const t = bus.posts.slice(rig.mem.posts0).filter(x => x.key === "confirm");
                            const ids = t.length === 1 ? (t[0].actions || []).map(x => x.id).join(",") : "";
                            rig.sub("v3", "approval-toast", t.length === 1 && t[0].title === "Run this command?" && String(t[0].body).split("\n")[0] === "touch notes.txt"
                                    && String(t[0].body).indexOf("in " + rig.repo) >= 0 && ids === "run,deny,open" && t[0].timeoutMs === -1,
                                    JSON.stringify(t.map(x => [x.title, x.body, ids])));
                            const it = eng.thePopup ? eng.thePopup.contentItem : null;
                            rig.sub("v3", "other-chat-shows-no-run", !!it && it._confirmHere === null && svc.pendingConfirm !== null,
                                    "the open chat's panel request " + (it ? JSON.stringify(it._confirmHere) : "(no content)"));
                            rig.mem.askToast = t[0];
                            rig.mem.confirmId = r.id;
                            rig.mem.hold = Date.now();
                        }
                    },
                    {
                        // NOTHING RUNS WITHOUT THE CLICK: a second after the toast it is still asked, nothing ran, nothing was released
                        name: "v3h", ms: 4000,
                        start: function () { },
                        until: function () { return Date.now() - rig.mem.hold > 1200; },
                        check: function () {
                            const ran = rig.touched(rig.mem.argvs0);
                            rig.sub("v3h", "nothing-ran-before-the-click", !ran && svc.pendingConfirm !== null && svc.pendingConfirm.id === rig.mem.confirmId,
                                    "touch ran: " + ran + ", still asking: " + (svc.pendingConfirm !== null));
                            rig.sub("v3h", "model-kept-for-the-pending-ask", rig.unloadsSince(rig.mem.unloads0).length === 0,
                                    rig.unloadsSince(rig.mem.unloads0).length + " unload(s) while it waits");
                            bus.click(rig.mem.askToast, "deny");
                        }
                    },
                    {
                        name: "v3b", ms: 15000,
                        start: function () { },
                        until: function () { return rig.done(rig.mem.cid); },
                        check: function () {
                            const a = rig.answer(rig.mem.cid);
                            const c0 = (a.toolCalls || [])[0] || {};
                            rig.sub("v3b", "denied", c0.status === "denied" && !rig.touched(rig.mem.argvs0), c0.status);
                            // the toast that was clicked is old now: its Run does nothing and says so
                            const n = bus.posts.length;
                            const ran0 = rig.argvs.length;
                            bus.click(rig.mem.askToast, "run");
                            const said = bus.posts.slice(n).filter(x => x.key === "said");
                            rig.sub("v3b", "stale-run-does-nothing", rig.argvs.length === ran0 && said.length === 1 && said[0].title === "Already answered",
                                    "new runs " + (rig.argvs.length - ran0) + ", said " + JSON.stringify(said.map(x => x.title)));
                            owner.close();
                        }
                    },
                    {
                        name: "v3c", ms: 15000,
                        start: function () { rig.mem.sawFloor = false; rig.speak("touch a notes file"); },
                        until: function () { return rig.carded() && bus.posts.slice(rig.mem.posts0).some(x => x.key === "confirm"); },
                        check: function () {
                            const t = bus.posts.slice(rig.mem.posts0).filter(x => x.key === "confirm");
                            rig.sub("v3c", "toast-posted", t.length === 1 && svc.pendingConfirm !== null && rig.mem.sawFloor,
                                    t.length + " toast(s), asking " + (svc.pendingConfirm !== null) + ", floor held " + rig.mem.sawFloor);
                            rig.mem.askToast = t[0];
                            rig.mem.unloads0 = rig.reqs().length;
                            rig.mem.hold = Date.now();
                        }
                    },
                    {
                        // no popup, an approval waiting: the model is kept, nothing runs; then the click
                        name: "v3ch", ms: 4000,
                        start: function () { },
                        until: function () { return Date.now() - rig.mem.hold > 1200; },
                        check: function () {
                            const ran = rig.touched(rig.mem.argvs0);
                            rig.sub("v3ch", "nothing-ran-before-the-click", !ran && svc.pendingConfirm !== null, "touch ran: " + ran);
                            rig.sub("v3ch", "model-kept-for-the-pending-ask", rig.unloadsSince(rig.mem.unloads0).length === 0 && machine.holdingFloor,
                                    rig.unloadsSince(rig.mem.unloads0).length + " unload(s), floor " + machine.holdingFloor);
                            bus.click(rig.mem.askToast, "run");
                        }
                    },
                    {
                        name: "v3r", ms: 15000,
                        start: function () { },
                        until: function () { return rig.done(rig.mem.cid); },
                        check: function () {
                            const a = rig.answer(rig.mem.cid);
                            const c0 = (a.toolCalls || [])[0] || {};
                            const ran = rig.touched(rig.mem.argvs0, true);
                            rig.sub("v3r", "run-ran-it-once", c0.status === "done" && c0.decision === "yes" && ran === 1,
                                    c0.status + " " + c0.decision + ", touch ran " + ran + "x");
                            rig.sub("v3r", "one-toast-for-the-answer", rig.toastsOf(rig.mem.cid).length === 1, rig.toastsOf(rig.mem.cid).length + " answer toast(s)");
                        }
                    },
                    {
                        // an approval nobody answers is dropped (the clock shortened to 1.5 s for the test)
                        name: "v3d", ms: 15000,
                        start: function () {
                            svc.voiceConfirmDropMs = 1500;
                            rig.mem.unloads0 = rig.reqs().length;
                            rig.speak("touch a notes file");
                        },
                        until: function () { return rig.done(rig.mem.cid); },
                        check: function () {
                            svc.voiceConfirmDropMs = 600000;
                            const a = rig.answer(rig.mem.cid);
                            const c0 = ((a && a.toolCalls) || [])[0] || {};
                            const t = rig.toastsOf(rig.mem.cid);
                            rig.sub("v3d", "dropped-without-running", svc.pendingConfirm === null && c0.status !== "done"
                                    && !rig.touched(rig.mem.argvs0),
                                    "call " + c0.status + ", asking " + (svc.pendingConfirm !== null));
                            rig.sub("v3d", "one-toast-says-so", t.length === 1 && t[0].title === "Dropped", JSON.stringify(t.map(x => [x.title, x.body])));
                            rig.sub("v3d", "approval-toast-withdrawn", bus.withdrawn.indexOf("llm/confirm") >= 0, JSON.stringify(bus.withdrawn));
                        }
                    },
                    {
                        name: "v3e", ms: 12000,
                        start: function () { },
                        until: function () { return rig.unloadsSince(rig.mem.unloads0).length > 0 && !machine.holdingFloor; },
                        check: function () {
                            rig.sub("v3e", "model-goes-after-a-drop", rig.unloadsSince(rig.mem.unloads0).length >= 1 && !machine.holdingFloor,
                                    rig.unloadsSince(rig.mem.unloads0).length + " unload(s), floor " + machine.holdingFloor);
                        }
                    },
                    {
                        name: "v4", ms: 15000,
                        start: function () { rig.speak("read the readme and look it up online"); },
                        until: function () { return rig.carded(); },
                        check: function () {
                            const r = rig.card();
                            const live = svc.liveToolCalls.length > 0 ? svc.liveToolCalls : ((rig.answer(rig.mem.cid) || {}).toolCalls || []);
                            const c0 = live[0] || {};
                            rig.sub("v4", "read-ran-free", c0.name === "read_file" && c0.decision === "free" && c0.status === "done"
                                    && String(c0.result).indexOf("STUB-README") >= 0,
                                    c0.name + " " + c0.decision + " " + c0.status + " " + JSON.stringify(String(c0.result || "").substring(0, 40)));
                            rig.sub("v4", "search-asks-after-a-read", r.tool === "web_search" && String(r.reason).indexOf("carry it off") >= 0,
                                    r.tool + " " + JSON.stringify(r.reason));
                            rig.deny(r);
                        }
                    },
                    {
                        name: "v4b", ms: 15000,
                        start: function () { },
                        until: function () { return rig.done(rig.mem.cid); },
                        check: function () { rig.sub("v4b", "ended", true, "the turn ended after the refusal"); }
                    },
                    {
                        name: "v5", ms: 15000,
                        start: function () { rig.speak("show my ssh key"); },
                        until: function () { return rig.carded(); },
                        check: function () {
                            const r = rig.card();
                            rig.sub("v5", "secret-asks", r.tool === "run_command" && String(r.reason).indexOf(".ssh") >= 0,
                                    JSON.stringify(r.reason));
                            const w0 = bus.withdrawn.length;
                            rig.deny(r);
                            rig.sub("v5", "answer-in-the-panel-withdraws-the-toast", bus.withdrawn.length === w0 + 1 && bus.withdrawn[w0] === "llm/confirm",
                                    JSON.stringify(bus.withdrawn.slice(w0)));
                        }
                    },
                    {
                        name: "v5b", ms: 15000,
                        start: function () { },
                        until: function () { return rig.done(rig.mem.cid); },
                        check: function () { rig.sub("v5b", "ended", true, "the turn ended after the refusal"); }
                    },
                    {
                        name: "v6", ms: 15000,
                        start: function () { rig.speak("run the pipeline"); },
                        until: function () { return rig.carded(); },
                        check: function () {
                            const r = rig.card();
                            const typed = toolReg.decide("run_command", { command: "git log --oneline | head -1" }, "", null);
                            rig.sub("v6", "stricter-than-typed", String(r.reason).indexOf("`|` is shell syntax") >= 0 && typed.mode === "auto",
                                    "spoken: " + JSON.stringify(r.reason) + "; typed policy: " + typed.mode);
                            rig.deny(r);
                        }
                    },
                    {
                        name: "v6b", ms: 15000,
                        start: function () { },
                        until: function () { return rig.done(rig.mem.cid); },
                        check: function () { rig.sub("v6b", "ended", true, "the turn ended after the refusal"); }
                    },
                    {
                        name: "v8", ms: 15000,
                        start: function () { rig.speak("find the TODO notes here"); },
                        until: function () { return rig.carded(); },
                        check: function () {
                            const r = rig.card();
                            const a = rig.answer(rig.mem.cid) || {};
                            const c0 = ((a.toolCalls || [])[0]) || {};
                            const av = rig.argvs.slice(rig.mem.argvs0);
                            const run = av.length > 0 ? av[av.length - 1] : [];
                            const res = String(c0.result || "");
                            rig.sub("v8", "search-runs-free-below-no-store", r.id === "" && c0.name === "search_files" && c0.decision === "free"
                                    && res.indexOf("todo.txt") >= 0,
                                    c0.name + " " + c0.decision + " " + c0.status + ", card " + r.tool);
                            rig.sub("v8", "never-opens-a-dotenv", res.indexOf("secret-token") < 0 && run.indexOf("!.env") > 0,
                                    "secret in result " + (res.indexOf("secret-token") >= 0) + ", -g !.env in argv " + (run.indexOf("!.env") > 0));
                            rig.deny(r);
                        }
                    },
                    {
                        name: "v9", ms: 15000,
                        start: function () { svc.model = "stub:missing"; rig.speak("explain a commit please"); },
                        until: function () { return rig.done(rig.mem.cid) && rig.toastsOf(rig.mem.cid).length > 0; },
                        check: function () {
                            svc.model = "stub:voice";
                            const t = rig.toastsOf(rig.mem.cid);
                            rig.sub("v9", "failure-says-so-once", t.length === 1 && t[0].title === "No answer" && String(t[0].body).indexOf("stub:missing") >= 0
                                    && rig.strays().length === 0,
                                    JSON.stringify(t.map(x => [x.title, String(x.body).substring(0, 80)])));
                        }
                    },
                    {
                        name: "v7", ms: 15000,
                        start: function () {
                            rig.mem.reqs0 = rig.reqs().length;
                            rig.mem.copies0 = rig.copies().length;
                            rig.mem.posts0 = bus.posts.length;
                            svc.ask("typed: are tools offered?");
                            rig.mem.cid = svc.activeId;
                        },
                        until: function () {
                            if (!rig.done(rig.mem.cid)) return false;
                            if (!rig.mem.doneAt) rig.mem.doneAt = Date.now();
                            return bus.posts.slice(rig.mem.posts0).some(x => x.key === "answer") || Date.now() - rig.mem.doneAt > 3000;
                        },
                        check: function () {
                            const ch = rig.chatsSince(rig.mem.reqs0);
                            const body = ch.length > 0 ? ch[0].body : {};
                            const a = rig.answer(rig.mem.cid);
                            rig.sub("v7", "typed-no-tools", ch.length === 1 && !body.tools && String(a.content).indexOf("TOOLS=no") >= 0,
                                    ch.length + " request(s), tools " + JSON.stringify(body.tools ? body.tools.length : null) + ", answer " + JSON.stringify(a.content));
                            rig.sub("v7", "typed-not-copied", rig.copies().length === rig.mem.copies0 && !a.copiedToClipboard,
                                    "copies " + (rig.copies().length - rig.mem.copies0));
                            const an = bus.posts.slice(rig.mem.posts0).filter(x => x.key === "answer");
                            rig.sub("v7", "typed-keeps-its-answer-notice", an.length === 1 && rig.toastsOf(rig.mem.cid).length === 0 && glyph.needsYou === true,
                                    an.length + " \"answer\" notice(s), glyph needsYou " + glyph.needsYou);
                        }
                    },
                    // ---- llm.jsonc -------------------------------------------------------------------------------------
                    {
                        // tools.ask: a command of the read-only list asks, spoken; so does a tool that only reads, typed and spoken.
                        name: "c1", ms: 15000,
                        start: function () {
                            const typed = n => toolReg.decide(n, n === "calculator" ? { expression: "1+1" } : { command: "git status" }, "", null);
                            const spoken = () => toolReg.decide("calculator", { expression: "1+1" }, "", Object.assign(toolReg.factsFor("calculator", {}, null), { handsFree: true }));
                            const before = [typed("calculator").mode, typed("run_command").mode, spoken().mode].join(" ");
                            toolReg.askNames = ["calculator", "run_command", "no_such_tool"];
                            const t = typed("calculator"), r = typed("run_command"), s = spoken();
                            rig.sub("c1", "reads-ask", before === "free auto free" && t.mode === "ask" && s.mode === "ask" && r.mode === "ask" && !r.grantable,
                                    before + " -> " + [t.mode, r.mode, s.mode].join(" ") + ", " + JSON.stringify(t.reason));
                            rig.sub("c1", "a-refusal-stands", toolReg.decide("no_such_tool", {}, "", null).mode === "refused", "");
                            rig.speak("What is the latest commit abbreviation?");
                        },
                        until: function () { return rig.carded(); },
                        check: function () {
                            const r = rig.card();
                            rig.sub("c1", "spoken-command-asks", r.tool === "run_command" && r.grantable === false
                                    && !rig.argvs.slice(rig.mem.argvs0).some(a => a.indexOf("log") > 0),
                                    r.tool + " " + JSON.stringify(r.reason) + ", " + JSON.stringify(rig.argvs.slice(rig.mem.argvs0).map(a => a.slice(3, 6))));
                            rig.deny(r);
                        }
                    },
                    {
                        name: "c1b", ms: 15000,
                        start: function () { },
                        until: function () { return rig.done(rig.mem.cid); },
                        check: function () {
                            toolReg.askNames = [];
                            const n = toolReg.wireTools.length;
                            toolReg.offNames = ["calculator"];
                            rig.sub("c1b", "off-is-never-offered", toolReg.wireTools.length === n - 1 && !toolReg.validate("calculator", { expression: "1" }).ok
                                    && (toolReg.setEnabled("calculator", true), !toolReg.isOffered("calculator")), n + " -> " + toolReg.wireTools.length);
                            toolReg.offNames = [];
                            toolReg.argDefaults = ({ web_search: { count: 5 } });
                            const c = a => toolReg.validate("web_search", a).norm.count;
                            rig.sub("c1b", "searchResults", c({ query: "x" }) === 5 && c({ query: "x", count: 2 }) === 2, c({ query: "x" }) + " / " + c({ query: "x", count: 2 }));
                            toolReg.argDefaults = ({});
                        }
                    },
                    {
                        name: "c2", ms: 15000,
                        start: function () {
                            toolReg.voiceAutoRun = false;
                            rig.speak("What is the latest commit abbreviation?");
                        },
                        until: function () { return rig.carded(); },
                        check: function () {
                            const r = rig.card();
                            rig.sub("c2", "autoRun-false-asks", r.tool === "run_command" && r.reason === "spoken request: every command asks", JSON.stringify(r.reason));
                            toolReg.voiceAutoRun = true;
                            rig.deny(r);
                        }
                    },
                    {
                        name: "c2b", ms: 15000,
                        start: function () { },
                        until: function () { return rig.done(rig.mem.cid) && !svc.titling; },
                        check: function () { }
                    },
                    {
                        // unloadAfterMin: a typed chat keeps its model that long after the chat is shut
                        name: "c3", ms: 15000,
                        start: function () {
                            owner.close();
                            residency.afterMin = 0.04;
                            stubBackend.think = { "stub:voice": false };
                            rig.mem.reqs0 = rig.mem.unloads0 = rig.reqs().length;
                            rig.mem.doneAt = 0;
                            svc.newChat();
                            svc.ask("typed: are tools offered?");
                            rig.mem.cid = svc.activeId;
                        },
                        until: function () {
                            if (!rig.done(rig.mem.cid) || svc.titling) return false;
                            if (!rig.mem.doneAt) rig.mem.doneAt = Date.now();
                            return Date.now() - rig.mem.doneAt > 900;
                        },
                        check: function () {
                            const n = rig.unloadsSince(rig.mem.unloads0).length;
                            rig.sub("c3", "stays-after-a-typed-chat", n === 0 && residency.waiting, n + " unload(s), waiting " + residency.waiting);
                        }
                    },
                    {
                        name: "c3b", ms: 6000,
                        start: function () { },
                        until: function () { return rig.unloadsSince(rig.mem.unloads0).length > 0; },
                        check: function () { rig.sub("c3b", "goes-when-its-time-is-over", !residency.waiting, "waiting " + residency.waiting); }
                    },
                    {
                        // ... and a spoken ask lets go at once, of its own model too
                        name: "c4", ms: 15000,
                        start: function () {
                            residency.afterMin = 5;
                            svc.voiceModel = "stub:spoken";
                            svc.voiceCopy = false;
                            rig.mem.unloads0 = rig.reqs().length;
                            rig.speak("Explain what a commit is");
                        },
                        until: function () { return rig.done(rig.mem.cid) && rig.unloadsSince(rig.mem.unloads0).length > 1; },
                        check: function () {
                            const who = rig.unloadsSince(rig.mem.unloads0).map(r => r.body.model).sort().join(" ");
                            rig.sub("c4", "spoken-lets-go-at-once", who === "stub:spoken stub:voice" && !residency.waiting, who);
                            const ch = rig.chatsSince(rig.mem.reqs0);
                            rig.sub("c4", "answered-by-its-model", ch.length > 0 && ch[0].body.model === "stub:spoken" && svc.model === "stub:voice", ch.length > 0 ? ch[0].body.model : "none");
                            svc.voiceModel = "";
                        }
                    },
                    {
                        name: "c5", ms: 3000,
                        start: function () { },
                        until: function () { return true; },
                        check: function () {
                            const i = (d, st) => { svc.ctxDefault = d; return svc._ctxModeOf("stub:voice", st) + " " + svc._defaultCtxFor("stub:voice"); };
                            rig.sub("c5", "context-default", i(4096, null) === "manual 4096" && i(6144, null) === "manual 6144" && i(16384, null) === "manual 8192"
                                    && i("auto", null) === "auto 4096" && i("auto", { mode: "manual", manualValue: 8192 }) === "manual 4096"
                                    && i("auto", { mode: "manual", manualValue: 0 }) === "auto 4096", i("auto", null));
                            svc.ownCard = false;
                            rig.sub("c5", "no-auto-on-another-machine", svc._ctxModeOf("stub:voice", null) === "manual" && !svc._autoSupportedFor("stub:voice"), "");
                            svc.ownCard = true;
                            svc.ctxDefault = 4096;
                            const w = (t, id) => { stubBackend.think = t; return stubBackend.wantsThink(id); };
                            rig.sub("c5", "think", w(true, "a") && !w(false, "a") && !w({ a: false }, "a") && w({ a: false }, "b"), "");
                            stubBackend.think = true;
                        }
                    }
                ];
            }
        }
    }
}
