pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell

import "modules/common/components"
import "modules/common/power"
import "modules/common/system"
import "modules/silicon/data"
import "modules/common/theme"
import "modules/common/mockup"
import "modules/bar/llm/components"

// =============================================================================
// mockups/llm.qml
//
// Mockup for LlmPopup.qml, on the shared mockup framework
// (modules/common/mockup/, contract in docs/contracts/mockup_framework.md). The
// framework owns the window: the stage on the left that follows the popup's
// implicit size, and the tabbed control panel on the right with the * marks,
// Reset, "Save to mockup" and the profiles. This file provides only what is
// about the LLM module: the popup and the three things that can drive it, the
// value lists, and the Run page.
//
//   quickshell -p mockups/llm.qml            open it
//   tools/dev/mockup_grab.sh <this> [tab]    render a tab
//   tools/dev/mockup_panel_test.sh <this>    marks / profiles / save round trip
//
// Three sources, chosen on the Run tab. LIVE IS THE DEFAULT: the module exists
// to talk to a real model, and a mockup that only ever renders canned markdown
// proves the renderer and nothing else.
//
//   live    the real Ollama on localhost:11434, gemma4:e2b by default -- the
//           smallest model on this machine, so a question comes back in seconds.
//   mock    a synthetic stream, no network at all. Every markdown block kind in
//           one answer; use it for looking at visuals, or with ollama stopped.
//   replay  mockups/fixtures/llm_stream_e4b.ndjson, a real gemma4:e4b answer with
//           its own timing and its thinking deltas.
//
// The store writes to a MOCKUP path, never to the module's real conversation
// file, so playing here cannot lose real history.
//
// LLM_SOURCE=live|mock|replay picks the source at launch; LLM_ASK="..." sends a
// question once everything is up; LLM_SEED=1 fills the history; LLM_COLLAPSE=1
// folds every answer (all four for headless grabs and smoke runs).
// =============================================================================
MockupWindow {
    id: win

    moduleId: "llm"
    // The framework derives the save target from `moduleId` -- and this
    // file is not test_llm.qml, so it must say where it lives or "Save to
    // mockup" writes into a file that does not exist (round 16).
    title: "LlmPopup mockup"
    // The popup is 900 px wide with the history out (620 folded); this leaves it room at 1:1.
    width: 1480
    // 1:1 by default. Zoom in from the toolbar for the material -- the carved
    // question box, the header's swept inset, the code block's rim; magnifying
    // by default only puts the composer off the bottom of the stage.
    zoom: 1.0
    content: popup
    // The stage stands in for thePopup, which paints the popup's background;
    // the popup itself draws none (it is a drop-in).
    stageColor: popup.surfaceColor

    target: popup
    // Two lists write to objects beside the popup: the service's loop limits
    // and the runner's.
    targets: ({
            svcParams: svc,
            toolRunParams: tools
        })

    lists: ({
            layoutParams: win.layoutParams,
            sidebarParams: win.sidebarParams,
            transcriptParams: win.transcriptParams,
            turnParams: win.turnParams,
            markdownParams: win.markdownParams,
            composerParams: win.composerParams,
            popupColors: win.popupColors,
            stateColors: win.stateColors,
            categoryHues: win.categoryHues,
            codeColors: win.codeColors,
            svcParams: win.svcParams,
            toolRunParams: win.toolRunParams
        })

    // Every colour this module uses is a theme token; none of them is a value
    // of the popup, so all four colour lists edit themes/<name>.json directly.
    themedLists: ["popupColors", "stateColors", "categoryHues", "codeColors"]

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Popup",
            subs: [
                {
                    name: "Frame",
                    lists: ["layoutParams"]
                },
                {
                    name: "Colours",
                    lists: ["popupColors", "stateColors"]
                }
            ]
        },
        {
            name: "Sidebar",
            lists: ["sidebarParams"]
        },
        {
            name: "Chat",
            subs: [
                {
                    name: "List",
                    lists: ["transcriptParams"]
                },
                {
                    name: "Turn",
                    lists: ["turnParams"]
                },
                {
                    name: "Markdown",
                    lists: ["markdownParams", "codeColors"]
                },
                {
                    name: "Categories",
                    lists: ["categoryHues"]
                }
            ]
        },
        {
            name: "Composer",
            subs: [
                {
                    name: "Field",
                    lists: ["composerParams"],
                    groups: ["Composer", "Path completion"]
                },
                {
                    name: "Attachments",
                    lists: ["composerParams"],
                    groups: ["Attachments", "Chip", "pdf menu"]
                },
                {
                    name: "Tools",
                    lists: ["composerParams"],
                    groups: ["Tools"]
                },
                {
                    name: "Picker",
                    lists: ["composerParams"],
                    groups: ["Picker", "Footer"]
                }
            ]
        },
        {
            name: "Tools",
            lists: ["svcParams", "toolRunParams"],
            page: toolsPage
        }
    ]

    // =====================================================================
    //  WHAT DRIVES THE CONTENT
    //
    // These live OUTSIDE the popup on purpose: that is the module's own
    // arrangement, and the reason a generation survives the popup closing.
    // The mockup is standing in for the bar-side module object.
    // =====================================================================
    LlmBackend {
        id: liveBackend
        baseUrl: win.endpoint
        protocol: win.protocol
    }

    LlmMockRun {
        id: mockBackend
        fixturePath: win.source === "replay" ? RepoRoot.dir + "/mockups/fixtures/llm_stream_e4b.ndjson" : ""
    }

    LlmStore {
        id: store
        // Never the module's real file. The mockup seeds, renames and deletes
        // conversations for a living.
        path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/llm/mockup_conversations.json"
    }

    // The tool registry and the "come back" seam, beside the service: the
    // module's own arrangement, since a tool keeps running with the popup
    // closed. `attended` is what the bar binds to the popup's visibility;
    // here it is a Run-tab toggle, so the 15 s notification is reachable.
    LlmTools {
        id: tools
        store: store
    }
    LlmAttention {
        id: attention
        service: svc
        attended: win.attended
        // The mockup has no popup to open; the Run tab counts the requests.
        onShowRequested: win.attentionRequests++
    }

    // THE MACHINE (R3 LLMGPU): silicon's mock, the shell's ONE OllamaGpu (not live here: no process, simulated waits) and the
    // chat's LlmMachine, exactly as LlmServices builds them -- the first request of a turn waits for the card, a Balanced
    // floor is held while a model is loaded. Nothing reaches the machine: `live` stays false.
    SiliconMock {
        id: machineSilicon
        playing: false
    }
    OllamaGpu {
        id: machineGpu
        silicon: machineSilicon
        simMs: 1800
    }
    LlmMachine {
        id: machine
        service: svc
        gpu: machineGpu
        lingerMs: 1500
    }

    LlmService {
        id: svc
        sendGate: machine
        backend: win.source === "live" ? liveBackend : mockBackend
        store: store
        tools: tools
        // A literal, not a binding: `switchModel` writes this property, and a
        // binding here would be destroyed by the first switch -- after which
        // the panel and the popup would quietly disagree about which model is
        // answering.
        model: "gemma4:e2b"
    }

    property string endpoint: "http://localhost:11434"
    property bool attended: true
    property int attentionRequests: 0
    // The probe verdict for the current model, re-read when a probe lands
    // (a function result, not a binding -- the popup does the same).
    property var probeInfo: ({ state: "none", ms: 0, why: "" })
    function refreshProbe() { win.probeInfo = svc.toolProbeInfo(svc.model); }
    Connections {
        target: svc
        function onToolProbeChanged(model) { win.refreshProbe(); }
        function onModelChanged() { win.refreshProbe(); }
    }
    property string protocol: Quickshell.env("LLM_PROTOCOL") || "ollama"
    property string source: Quickshell.env("LLM_SOURCE") || "live"

    // The mock and the live server offer different model names, so switching
    // source has to land on one the new backend actually has -- otherwise the
    // pill names a model nothing can answer with. Only when the current one is
    // absent: a name that exists on both sides survives the switch. A plain
    // assignment, not `switchModel`, because reconfiguring the mockup is not
    // the user changing model mid-conversation and must not write a note into
    // the transcript.
    readonly property var _activeModels: win.source === "live" ? liveBackend.models : mockBackend.models
    on_ActiveModelsChanged: win.syncModel()
    function syncModel() {
        const ms = win._activeModels;
        if (!ms || ms.length === 0)
            return;
        for (let i = 0; i < ms.length; i++)
            if (ms[i].id === svc.model)
                return;
        svc.model = ms[0].id;
    }

    // =====================================================================
    //  THE DROP-IN CONTENT
    //
    // Exactly what goes into thePopup: sized by its own implicitWidth /
    // implicitHeight, given a service and nothing else. The stage gives it a
    // surface to sit on.
    // =====================================================================
    LlmPopup {
        id: popup
        service: svc
        // Host-level typeface choice. The module keeps its own default
        // ("Inter", now installed); this is the mockup dressing it to match the
        // rest of the user's surface.
        fontFamily: "Audiowide"
        // The reading face. Audiowide everywhere was heavy; the user asked
        // for Exo 2 on the text you read and write -- prompt, answer,
        // thinking, sent prompt -- and only there.
        bodyFontFamily: "Exo 2"
        monoFamily: "Consolas"
        onAttachRequested: win.pickFile()
        onLinkActivated: url => Qt.openUrlExternally(url)
    }

    // ---- The file chooser is the HOST's job, not the popup's -------------
    // A plain FileDialog: Qt routes it through the xdg-desktop-portal, and
    // the desktop's FileChooser backend is now termfilechooser -> yazi in a
    // kitty window (portals.conf + the termfilechooser config; verified live
    // 2026-09-02 -- an unthemed Qt 6.11 FileDialog opened the yazi picker).
    // The previous direct kitty+yazi spawn produced the same picker; going
    // through the portal keeps the mockup identical to what any other app on
    // this desktop opens.
    FileDialog {
        id: filePicker
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            for (let i = 0; i < filePicker.selectedFiles.length; i++) {
                const p = filePicker.selectedFiles[i].toString().replace(/^file:\/\//, "");
                if (p.length > 0) {
                    win.attachStatus = "picked: " + p;
                    popup.attachFile(decodeURIComponent(p));
                }
            }
        }
    }
    property string attachStatus: "nothing picked yet"
    function pickFile() {
        filePicker.open();
    }

    // =====================================================================
    //  SEEDING
    //
    // The sidebar needs a history to be worth looking at, and a real one takes
    // days to accumulate. These are written into the MOCKUP store.
    // =====================================================================
    readonly property var seedTitles: ["Why does my Wayland session drop frames?", "Explain how a Unix pipe works", "Rust lifetimes in one paragraph", "Best way to bisect a kernel regression", "What is a GGUF file", "Shell one-liner to dedupe a file", "Difference between mmap and read", "Pacman hooks I should know about", "A conversation whose title is long enough that it cannot possibly fit inside the history panel and has to be dealt with"]
    readonly property var seedCategories: ["system", "system", "code", "system", "explain", "system", "explain", "system", "other"]

    function seedHistory() {
        const day = 86400000;
        const now = Date.now();
        const ages = [0, 0, day, day * 3, day * 5, day * 12, day * 30, day * 90, 0];
        for (let i = 0; i < win.seedTitles.length; i++) {
            const id = store.create(svc.model, false);
            store.setTitle(id, win.seedTitles[i]);
            const at = now - ages[i] - i * 3600000;
            store.appendMessage(id, {
                role: "user",
                content: win.seedTitles[i],
                at: at
            });
            const cat = win.seedCategories[i];
            const glyph = svc.categoryFor(cat).glyph;
            store.appendMessage(id, {
                role: "assistant",
                content: "A seeded answer for **" + win.seedTitles[i] + "**.\n\nIt exists so the sidebar has something to sort, search, favourite and rename.",
                model: svc.model,
                title: win.seedTitles[i],
                category: cat,
                icon: glyph,
                at: at + 4000
            });
            store.setIcon(id, glyph);
            store.setCategory(id, cat);
        }
        // One with no title at all, so the skeleton has something to stand in
        // for without waiting on a model.
        const blank = store.create(svc.model, false);
        store.appendMessage(blank, {
            role: "user",
            content: "A question whose answer is still being named",
            at: now - 60000
        });
        store.appendMessage(blank, {
            role: "assistant",
            content: "The answer arrived; its title has not.",
            model: svc.model,
            titlePending: true,
            category: "other",
            at: now - 55000
        });
        store.flush();
    }

    // One conversation with every shape a turn can take: a plain answer, an
    // answer with code, a very long question, a model switch, and a failure.
    // Seeding history gives the sidebar something to sort; this gives the
    // transcript something to be.
    function seedConversation() {
        const now = Date.now();
        const id = store.create(svc.model, false);
        store.setTitle(id, "Reading a stream in QML");
        store.appendMessage(id, {
            role: "user",
            content: "How do I read a process's stdout line by line in QML?",
            at: now - 900000
        });
        store.appendMessage(id, {
            role: "assistant",
            model: svc.model,
            at: now - 895000,
            title: "Reading a stream in QML",
            category: "code",
            thinking: "The question is about Quickshell's Io module. SplitParser buffers until its marker, StdioCollector fires per buffer arrival -- mention both and say which one to reach for.",
            thinkingMs: 2400,
            stats: {
                evalTokens: 214,
                tokensPerSecond: 46.2,
                totalMs: 4630,
                // This one paid for the weights; the next seeded answer does
                // not, so one render shows the footer in both states.
                loadMs: 8337.4
            },
            content: "Use a `SplitParser` when the output is line-delimited:\n\n```qml\nProcess {\n    command: [\"journalctl\", \"-f\"]\n    stdout: SplitParser {\n        splitMarker: \"\\n\"\n        onRead: (line) => root.consume(line)\n    }\n}\n```\n\n> The marker is **stripped** from `data`.\n\nIf the stream carries prompts with no trailing newline, or `\\r`-redrawn meters, reach for `StdioCollector { waitForEnd: false }` instead and diff `text` against a stored offset."
        });
        store.appendMessage(id, {
            role: "note",
            content: "switched to " + svc.model,
            at: now - 600000
        });
        store.appendMessage(id, {
            role: "user",
            content: "Which one does the terminal in the system update use, and why that one rather than the other? I remember there was something about prompts that never reach a newline and progress meters that redraw themselves with a carriage return instead, but I have forgotten which way round it goes and what the consequence was.",
            at: now - 599000
        });
        store.appendMessage(id, {
            role: "assistant",
            model: svc.model,
            at: now - 596000,
            title: "StdioCollector versus SplitParser",
            category: "system",
            stats: {
                evalTokens: 88,
                tokensPerSecond: 51.9,
                totalMs: 1700
            },
            content: "`StdioCollector`, with `waitForEnd: false`.\n\n| what | why |\n| :--- | :--- |\n| prompts | `Continue? [Y/n] ` never reaches a newline |\n| meters | pacman redraws with `\\r`, not `\\n` |"
        });
        store.appendMessage(id, {
            role: "user",
            content: "Now write it as a shader.",
            at: now - 300000
        });
        store.appendMessage(id, {
            role: "assistant",
            model: svc.model,
            at: now - 299000,
            content: "",
            category: "code",
            error: "llama-server process has terminated: exit status 1: cudaMalloc failed: out of memory"
        });
        store.setIcon(id, svc.categoryFor("code").glyph);
        store.setCategory(id, "code");
        store.flush();
        svc.open(id);
        return id;
    }

    function clearHistory() {
        const ids = [];
        for (let i = 0; i < store.conversations.count; i++)
            ids.push(store.conversations.get(i).convId);
        for (let i = 0; i < ids.length; i++)
            store.remove(ids[i]);
        store.flush();
    }

    Component.onCompleted: {
        // The framework's own onCompleted has already pushed every `val:` into
        // the popup, so anything here sees the defaults in place.
        if (win.source === "live")
            liveBackend.refreshModels();
        win.syncModel();
        // Renders: THEME=light|dark switches the theme state file (the runner
        // restores it), LLM_TOOLSCRIPT=1 arms the mock's tool turn,
        // LLM_CONFIRM=<yes|no|always>:<ms> answers the confirmation by itself.
        const th = Quickshell.env("THEME") || "";
        if (th === "light" || th === "dark")
            Theme.setMode(th);
        if ((Quickshell.env("LLM_TOOLSCRIPT") || "") !== "")
            win.armMockToolTurn();
        if ((Quickshell.env("LLM_TOOLBLOCK_OPEN") || "") !== "")
            popup.toolBlockCollapsed = false;
        const ca = Quickshell.env("LLM_CONFIRM") || "";
        if (ca.indexOf(":") > 0) {
            autoConfirm.answer = ca.split(":")[0];
            autoConfirm.interval = Number(ca.split(":")[1]) || 4000;
            autoConfirm.running = true;
        }
        const q = Quickshell.env("LLM_ASK") || "";
        if (q.length > 0)
            autoAsk.pending = q;
        // LLM_QUEUE="first|second|third": when the ask starts, queue these behind it, each on the next
        // model in turn (the render of the queue strip); LLM_SLOW=1 makes the mock answer slowly
        // enough to still be answering when the grab is taken.
        win.queueWanted = (Quickshell.env("LLM_QUEUE") || "").split("|").filter(t => t.length > 0);
        if ((Quickshell.env("LLM_SLOW") || "") !== "")
            mockBackend.speed = 0.04;
    }
    property var queueWanted: []
    Connections {
        target: svc
        function onTurnStarted() {
            const list = win.queueWanted;
            win.queueWanted = [];
            const ms = win._activeModels;
            for (let i = 0; i < list.length; i++) {
                if (ms.length > 0) svc.switchModel(ms[i % ms.length].id);
                svc.enqueue(list[i], []);
            }
        }
    }

    // THE MOCK TOOL TURN: three rounds the way a real model would do them --
    // a free read (calculator), then an act that asks (a run_command), then
    // the answer. Arms the mock and switches the wrench on; the next ask
    // consumes it.
    function armMockToolTurn() {
        // mock:small declares no tool calling (its dot says so); the wrench
        // is inert on it and the service sends no tools. mock:medium is the
        // proven one.
        if (win.source === "mock" && !mockBackend.capsOf(svc.model).tools)
            svc.model = "mock:medium";
        mockBackend.toolScript = [
            { thinking: "", text: "Let me work that out first.", calls: [{ name: "calculator", args: { expression: "17*23" } }] },
            { thinking: "", text: "391. Now the disk:", calls: [{ name: "run_command", args: { command: "df -h ~ | tail -1; sleep 1" } }] },
            { thinking: "", text: "17 × 23 is **391**, and the line above is what `df -h ~` printed for your home directory's filesystem -- the Avail column is what is left. The `sleep 1` after it is the part that asked.\n\nNothing else to run.", calls: [] }
        ];
        svc.toolsEnabled = true;
    }
    Timer {
        id: autoConfirm
        property string answer: "yes"
        repeat: true
        onTriggered: {
            if (svc.pendingConfirm) {
                svc.answerConfirm(svc.pendingConfirm.id, autoConfirm.answer);
                autoConfirm.running = false;
            }
        }
    }

    Timer {
        id: autoAsk
        property string pending: ""
        // Long enough for an LLM_ATTACH file's base64 read to land first, so a
        // headless vision run sends the image with the question the way the
        // composer would.
        interval: 1400
        running: autoAsk.pending.length > 0
        onTriggered: {
            const att = [];
            const chips = popup.composerAttachments();
            for (let i = 0; i < chips.length; i++)
                if (!chips[i].pending && !chips[i].failed)
                    att.push(chips[i]);
            svc.ask(autoAsk.pending, att);
            popup.clearAttachments();
            autoAsk.pending = "";
        }
    }

    Timer {
        interval: 200
        running: (Quickshell.env("LLM_ATTACH") || "") !== ""
        onTriggered: popup.attachFile(Quickshell.env("LLM_ATTACH"))
    }

    // Headless grabs need states that only a click reaches otherwise.
    Timer {
        id: autoSeed
        interval: 200
        running: (Quickshell.env("LLM_SEED") || "") !== ""
        onTriggered: {
            win.seedHistory();
            win.seedConversation();
        }
    }

    Timer {
        id: autoCollapse
        interval: 6000
        running: (Quickshell.env("LLM_COLLAPSE") || "") !== ""
        onTriggered: popup.collapseAllAnswers()
    }

    Timer {
        id: autoRail
        interval: 900
        running: (Quickshell.env("LLM_RAIL") || "") !== ""
        onTriggered: popup.sidebarOpen = false
    }

    // =====================================================================
    //  THE MODULE'S OWN PANEL PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Source"
                blurb: "What is answering. Live is the default; mock and replay never touch the network."
            }

            TipRow {
                tip: "Live talks to the Ollama on localhost -- the module's whole point, and what the module ships against. Mock is a synthetic stream that renders every markdown block kind, for visuals or with the service stopped. Replay plays mockups/fixtures/llm_stream_e4b.ndjson, a real gemma4:e4b answer with its own timing and its thinking deltas."
                spacing: 8
                Button {
                    text: "Live"
                    checkable: true
                    checked: win.source === "live"
                    onClicked: {
                        win.source = "live";
                        liveBackend.refreshModels();
                    }
                }
                Button {
                    text: "Mock"
                    checkable: true
                    checked: win.source === "mock"
                    onClicked: win.source = "mock"
                }
                Button {
                    text: "Replay"
                    checkable: true
                    checked: win.source === "replay"
                    onClicked: win.source = "replay"
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Where the live backend lives. Anything that speaks Ollama's /api/chat or an OpenAI-compatible /v1/chat/completions works; the wire is chosen below."
                spacing: 8
                Label {
                    text: "Endpoint"
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 90
                }
                TextField {
                    Layout.fillWidth: true
                    text: win.endpoint
                    font.family: "Audiowide"
                    font.pixelSize: 13
                    onEditingFinished: win.endpoint = text
                }
                Button {
                    text: "Refresh"
                    onClicked: {
                        liveBackend.refreshModels();
                        liveBackend.refreshLoaded();
                    }
                }
            }

            TipRow {
                tip: "Which wire the live backend speaks. `ollama` is /api/chat with NDJSON frames -- it carries the reasoning stream and the eval-rate telemetry the header and the footer show. `openai` is /v1/chat/completions with SSE, which every other local server also speaks, so this is the switch that proves the module is not tied to Ollama."
                spacing: 8
                Label {
                    text: "Protocol"
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 90
                }
                Button {
                    text: "ollama"
                    checkable: true
                    checked: win.protocol === "ollama"
                    onClicked: win.protocol = "ollama"
                }
                Button {
                    text: "openai"
                    checkable: true
                    checked: win.protocol === "openai"
                    onClicked: win.protocol = "openai"
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "backend: " + win.source + "   online: " + (win.source === "live" ? liveBackend.online : true) + "   models: " + (win.source === "live" ? liveBackend.models.length : mockBackend.models.length) + (liveBackend.lastError.length > 0 && win.source === "live" ? "\nerror: " + liveBackend.lastError : "")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }

            TipGroup {
                title: "Model"
                blurb: "Which model answers the next turn. Switching mid-conversation writes a note into the transcript and re-sends the whole history."
            }

            TipRow {
                tip: "The same list the popup's own model pill shows, beside the send button. Picking here is exactly what picking there does, so the two cannot disagree. gemma4:e2b is the smallest model on this machine and answers in seconds; the 26b and 31b hold the GPU for minutes."
                spacing: 8
                ComboBox {
                    id: modelBox
                    Layout.fillWidth: true
                    font.family: "Audiowide"
                    font.pixelSize: 13
                    model: {
                        const src = win.source === "live" ? liveBackend.models : mockBackend.models;
                        const out = [];
                        for (let i = 0; i < src.length; i++)
                            out.push(src[i].id);
                        return out;
                    }
                    currentIndex: {
                        const ms = modelBox.model;
                        for (let i = 0; i < ms.length; i++)
                            if (ms[i] === svc.model)
                                return i;
                        return -1;
                    }
                    onActivated: svc.switchModel(modelBox.currentText)
                }
                Button {
                    text: "Warm"
                    enabled: win.source === "live"
                    onClicked: liveBackend.warm(svc.model)
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: {
                    const l = (win.source === "live" ? liveBackend.loaded : mockBackend.loaded) || ({});
                    const keys = Object.keys(l);
                    if (keys.length === 0)
                        return "nothing loaded";
                    let s = "";
                    for (let i = 0; i < keys.length; i++) {
                        const e = l[keys[i]];
                        const pct = e.size > 0 ? Math.round(100 * e.sizeVram / e.size) : 0;
                        s += keys[i] + ": " + pct + "% on the GPU, ctx " + e.ctx + "\n";
                    }
                    return s.trim();
                }
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }

            TipGroup {
                title: "Ask"
                blurb: "Drive a turn without typing into the popup."
            }

            TipRow {
                tip: "Attaches a file the way the paperclip and a drag onto the conversation do: images ride to the model as base64, readable text is inlined as a fenced block, anything else is refused on its chip. gemma4 is a vision model, so a PNG is a real test."
                spacing: 8
                Button {
                    text: "Attach a file"
                    onClicked: win.pickFile()
                }
                TextField {
                    id: attachPathField
                    Layout.fillWidth: true
                    placeholderText: "or type a path"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                    onAccepted: {
                        if (text.trim().length > 0)
                            popup.attachFile(text.trim());
                    }
                }
            }

            TipRow {
                tip: "Sends the question through the service exactly as the composer does, so the transcript, the store, the streaming header and the title request that follows the answer all behave as they would in the shell."
                spacing: 8
                TextField {
                    id: askField
                    Layout.fillWidth: true
                    placeholderText: "a question"
                    text: "Explain how a Unix pipe works, with a table and a bash example."
                    font.family: "Audiowide"
                    font.pixelSize: 13
                    onAccepted: svc.ask(askField.text, [])
                }
                Button {
                    text: "Ask"
                    enabled: !svc.generating
                    onClicked: svc.ask(askField.text, [])
                }
                Button {
                    text: "Stop"
                    enabled: svc.generating
                    onClicked: svc.stop()
                }
            }

            TipRow {
                tip: "How fast the synthetic and replayed streams arrive. 1 is the fixture's own pace; raise it to watch a long answer resolve, drop it to watch the markdown blocks close one at a time. It does nothing to a live model."
                spacing: 8
                Label {
                    text: "Stream speed"
                    color: "#5D5D5F"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 110
                }
                Slider {
                    id: speedSlider
                    Layout.fillWidth: true
                    from: 0.1
                    to: 8
                    value: 1
                    onMoved: mockBackend.speed = value
                }
                Label {
                    text: speedSlider.value.toFixed(2) + "x"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    Layout.preferredWidth: 56
                }
            }

            TipRow {
                tip: "A cold 26B model takes 33-41 seconds to load before the first token arrives. This arms that wait on the mock so the waiting state can be looked at without paying for it."
                spacing: 8
                CheckBox {
                    id: stallToggle
                    text: "Simulate a cold load"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onCheckedChanged: mockBackend.simulateLoadStall = checked
                }
                CheckBox {
                    id: failToggle
                    text: "Fail midway"
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onCheckedChanged: mockBackend.failMidway = checked
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Arms the mock with a three-round tool turn (a calculator read that runs free, a `df -h ~ | tail -1; sleep 1` whose `sleep` asks while the rest passes, then the answer) and switches the wrench on; type anything and send, or press Ask. Mock source only -- the live backend does its own calling."
                spacing: 8
                Button {
                    text: "Mock tool turn"
                    enabled: win.source === "mock"
                    onClicked: win.armMockToolTurn()
                }
                Label {
                    text: mockBackend.toolScript.length > 0 ? mockBackend.toolScript.length + " rounds armed" : ""
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Session"
                blurb: "The switches in the sidebar's header row, reachable from here."
            }

            TipRow {
                tip: "Incognito conversations are never written to the store's file and vanish on reload; the button only appears in the popup while the open conversation is new and empty, which is the only moment the choice means anything. Pinned means the host may not unload the popup when it closes, so reopening lands exactly where it was left."
                spacing: 8
                CheckBox {
                    text: "Incognito"
                    checked: svc.incognito
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: svc.setIncognito(!svc.incognito)
                }
                CheckBox {
                    text: "Pinned (keepAlive)"
                    checked: svc.sessionPinned
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: svc.sessionPinned = !svc.sessionPinned
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Folds the history panel to its rail and back, which is what the burger button does. The burger keeps its y either way; everything else stacks under it."
                spacing: 8
                Button {
                    text: popup.sidebarOpen ? "Fold sidebar" : "Open sidebar"
                    onClicked: popup.sidebarOpen = !popup.sidebarOpen
                }
                Button {
                    text: "New chat"
                    onClicked: svc.newChat()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Folds every answer in the conversation down to its titled header, or opens them all again -- the same thing the chevron on the title row does. This is what the module's headers exist for once a conversation is long."
                spacing: 8
                Button {
                    text: "Collapse all"
                    onClicked: popup.collapseAllAnswers()
                }
                Button {
                    text: "Expand all"
                    onClicked: popup.expandAllAnswers()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "What the bar binds to the popup's visibility. Unticked, the popup counts as closed: a confirmation nobody answers for confirmNotifyMs raises the notification (here: counted in State)."
                spacing: 8
                CheckBox {
                    text: "Popup attended (visible)"
                    checked: win.attended
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: win.attended = !win.attended
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Machine"
                blurb: "What a loaded model asks of the machine: the dGPU (shared with the wiki) and a Balanced floor on the CPU profile. Silicon here is the mock; nothing leaves the process."
            }

            TipRow {
                tip: "The mock machine's state before the chat is asked anything. The floor raises Quiet to Balanced (and puts Quiet back when the model is gone), raises a Balanced tuned to lower power, and never takes Performance down. The GPU mode is the starting point of the card: Integrated and Smart are switched to Hybrid for the chat and put back after."
                spacing: 8
                Label {
                    text: "profile"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Button { text: "Quiet"; onClicked: machineSilicon.externalProfile("quiet") }
                Button { text: "Balanced"; onClicked: machineSilicon.externalProfile("balanced") }
                Button { text: "Performance"; onClicked: machineSilicon.externalProfile("performance") }
                Label {
                    text: "card"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Button { text: "Integrated"; onClicked: machineSilicon.externalGpuMode(0) }
                Button { text: "Smart"; onClicked: machineSilicon.externalGpuMode(1) }
                Button { text: "Hybrid"; onClicked: machineSilicon.externalGpuMode(2) }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "A manual profile change while the floor is held: the user's hand wins, the hold is dropped for good and nothing is put back when the model goes. (The same as stepping the profile in silicon's popup.)"
                spacing: 8
                Button {
                    text: "Step the profile by hand"
                    onClicked: machineSilicon.externalProfile(machineSilicon.cpu.profile === "quiet" ? "performance" : "quiet")
                }
                CheckBox {
                    text: "First load lands on the CPU"
                    checked: machineGpu.simCpu
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: machineGpu.simCpu = !machineGpu.simCpu
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "card: " + machineGpu.phase + (machineGpu.reason !== "" ? " (" + machineGpu.reason + ")" : "") + "   holders: " + (machineGpu.holders.length ? machineGpu.holders.join(", ") : "none") + "   mode: " + machineSilicon.gpuMode + " -> " + machineSilicon.gpuModeTarget + "\nprofile: " + machineSilicon.cpu.profile + "   held: " + (PowerBus.heldProfile === "" ? "no" : PowerBus.heldProfile + " by " + PowerBus.heldBy + (PowerBus.heldIsFloor ? " (floor)" : "")) + "\nwanted: " + machine.wanted + "   card: " + machine.holdingCard + "   floor: " + machine.holdingFloor + (machine.note !== "" ? "\nnote: " + machine.note : "") + (svc.waitSay !== "" ? "\nthe turn waits: " + svc.waitSay : "")
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }

            TipGroup {
                title: "History"
                blurb: "The mockup's own store, at ~/.local/state/lares/llm/mockup_conversations.json -- never the module's real file."
            }

            TipRow {
                tip: "Writes ten conversations spread over today, yesterday, the last week and older -- including one whose title is far too long for the panel and one whose title has not been generated yet -- so the sidebar's date sections, its search, its favourites, its rename and its skeleton all have something to work on."
                spacing: 8
                Button {
                    text: "Seed history"
                    onClicked: win.seedHistory()
                }
                Button {
                    text: "Seed a conversation"
                    onClicked: win.seedConversation()
                }
                Button {
                    text: "Clear all"
                    onClicked: win.clearHistory()
                }
                Button {
                    text: "Clear default model"
                    enabled: svc.defaultModel !== ""
                    onClicked: svc.setDefaultModel("")
                }
                Button {
                    text: "Unload current model"
                    enabled: svc.canUnload
                    onClicked: svc.unloadNow()
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the service believes right now."
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "generating: " + svc.generating + "   waiting: " + svc.waitingForModel + "   titling: " + svc.titling + "\nconversation: " + (svc.activeId === "" ? "none" : svc.activeId) + "   messages: " + svc.messages.length + "\nlive: " + svc.liveText.length + " chars   thinking: " + svc.liveThinking.length + " chars" + (svc.lastStats ? "\nlast: " + svc.lastStats.evalTokens + " tok at " + svc.lastStats.tokensPerSecond.toFixed(1) + " tok/s" : "") + (svc.lastError.length > 0 ? "\nerror: " + svc.lastError : "") + "\nattach: " + win.attachStatus + "\ntools: phase " + (svc.toolPhase === "" ? "idle" : svc.toolPhase) + "   pending: " + (svc.pendingConfirm ? svc.pendingConfirm.title : "none") + "   overdue: " + svc.confirmIsOverdue + "   attention requests: " + win.attentionRequests + "\ndefault model: " + (svc.defaultModel === "" ? "—" : svc.defaultModel) + "   canUnload: " + svc.canUnload + "   round prompt: " + svc.roundPromptTokens + " tok"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: "size: " + popup.implicitWidth.toFixed(0) + " x " + popup.implicitHeight.toFixed(0) + "   keepAlive: " + popup.keepAlive
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 13
            }
        },
        MockupPage {
            id: toolsPage

            TipGroup {
                title: "Wrench"
                blurb: "The three switches behind tool calling, and what the probe says about the current model."
            }

            TipRow {
                tip: "The wrench's latch, the same value the composer's button toggles: with it on, every message carries the enabled tools. Off, the model is never told they exist. The probe runs after the first finished answer of a model this process has not measured yet; off, the dot only ever shows the server's claim. Folded blocks open on the handle line alone."
                spacing: 8
                CheckBox {
                    text: "Tools on (the wrench)"
                    checked: svc.toolsEnabled
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: svc.toolsEnabled = !svc.toolsEnabled
                }
                CheckBox {
                    text: "Probe after an answer"
                    checked: svc.toolProbeEnabled
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: svc.toolProbeEnabled = !svc.toolProbeEnabled
                }
                CheckBox {
                    text: "Blocks open folded"
                    checked: popup.toolBlockCollapsed
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: popup.toolBlockCollapsed = !popup.toolBlockCollapsed
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "Wrench on from the start: the popup switches the service's latch on once, when it is first given a service, so a fresh shell offers tools without a click. Off is the module default -- a model is told about tools only after the user asks for them. The scope switch runs every tool inside a transient systemd user scope (systemd-run --user --scope, 21 ms) that is killed and counted when the call ends, so nothing a command starts outlives it -- a `sleep &` or a `set -m` escapee dies with the call; off falls back to the bare timeout wrapper, which a process that changes its own group can outlive."
                spacing: 8
                CheckBox {
                    text: "Tools on by default"
                    checked: popup.toolsDefaultOn
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: popup.toolsDefaultOn = !popup.toolsDefaultOn
                }
                CheckBox {
                    text: "systemd scope per call"
                    checked: tools.scoped
                    font.family: "Audiowide"
                    font.pixelSize: 14
                    onClicked: tools.scoped = !tools.scoped
                }
                Label {
                    text: "scope: " + tools.scopeState + (tools.cgroupRoot ? "" : " (no user manager)")
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipRow {
                tip: "The probe's verdict for the model on the pill: none (never measured), declared (the server says tools, unmeasured), proven (called calculator right and used the result, with the round trip), failed (with why). Probe now LOADS the model if it is cold -- the automatic probe never does -- and re-measures a proven one."
                spacing: 8
                Label {
                    text: "probe " + svc.model + ": " + win.probeInfo.state + (win.probeInfo.ms > 0 ? " · " + win.probeInfo.ms + " ms" : "") + (win.probeInfo.why ? " · " + win.probeInfo.why : "")
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Button {
                    text: "Probe now (loads the model)"
                    enabled: win.probeInfo.state !== "none"
                    onClicked: svc.probeNow(svc.model)
                }
                Item {
                    Layout.fillWidth: true
                }
            }

            TipGroup {
                title: "Registry"
                blurb: "Every tool file under " + tools.dir + " as loaded. A tool the loader rejected is listed under errors with the reason; the file is the edit surface, this tab only shows and toggles."
            }

            Repeater {
                model: tools.entries
                delegate: TipRow {
                    id: entryRow
                    required property var modelData
                    tip: (entryRow.modelData.description || "") + (entryRow.modelData.actions ? "\n\n" + Object.keys(entryRow.modelData.actions).map(k => k + ": " + (entryRow.modelData.exec || []).concat(entryRow.modelData.actions[k].argv || []).join(" ")).join("\n") : "\n\nargv: " + (entryRow.modelData.argv || []).map(a => Array.isArray(a) ? "[" + a.join(" ") + "]" : String(a)).join(" "))
                    spacing: 8
                    CheckBox {
                        text: entryRow.modelData.name + "  ·  " + entryRow.modelData.kind + (entryRow.modelData.actions ? "  ·  " + Object.keys(entryRow.modelData.actions).length + " actions" : "") + "  ·  " + (entryRow.modelData.allow || "free")
                        checked: tools.isOffered(entryRow.modelData.name)
                        font.family: "Audiowide"
                        font.pixelSize: 13
                        onClicked: tools.setEnabled(entryRow.modelData.name, !tools.isOffered(entryRow.modelData.name))
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                visible: tools.errors.length > 0
                text: "errors:\n" + tools.errors.map(e => "  " + (e.file || "?") + (e.name ? " · " + e.name : "") + (e.action ? "/" + e.action : "") + ": " + (e.reason || JSON.stringify(e))).join("\n")
                color: "#EC0000"
                font.family: "Audiowide"
                font.pixelSize: 13
            }

            TipGroup {
                title: "Allowances"
                blurb: "What 'allow any future like this' remembered, global across conversations until revoked here or from the wrench's right-click menu."
            }

            Repeater {
                model: tools.grants
                delegate: TipRow {
                    id: grantRow
                    required property var modelData
                    tip: grantRow.modelData.tool + " · key " + grantRow.modelData.key + " · granted " + new Date(grantRow.modelData.at || 0).toLocaleString(Qt.locale(), "yyyy-MM-dd hh:mm")
                    spacing: 8
                    Label {
                        text: (grantRow.modelData.label || grantRow.modelData.key) + "  ·  " + (grantRow.modelData.uses || 0) + " uses"
                        color: "#5D5D5F"
                        font.family: "Audiowide"
                        font.pixelSize: 13
                    }
                    Button {
                        text: "×"
                        onClicked: tools.forget(grantRow.modelData.tool, grantRow.modelData.key)
                    }
                    Item {
                        Layout.fillWidth: true
                    }
                }
            }

            TipRow {
                tip: "Revokes every remembered allowance at once; the next acting call asks again."
                spacing: 8
                Label {
                    visible: tools.grants.length === 0
                    text: "no allowances"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Button {
                    text: "Forget all"
                    enabled: tools.grants.length > 0
                    onClicked: tools.forgetAll()
                }
                Item {
                    Layout.fillWidth: true
                }
            }
        }
    ]

    // =====================================================================
    //  VALUES
    // =====================================================================
    // The service's loop limits (target: svc), contract §5.1.
    readonly property var svcParams: [
        {
            label: "activity after ms",
            prop: "activityAfterMs",
            group: "The quiet clock",
            blurb: "When the foot of the answer says what a silent model is doing.",
            tip: "How long the model has to be busy in one of the silent ways -- reading the prompt, thinking, writing a tool call -- before the foot of the answer says so. Shorter and a one-frame phase flashes a line in; 1 s is past every flicker the mock and the real wire produce, and short against a phase that matters (the tool call measured 13.2 s).",
            val: 1000,
            from: 0,
            to: 5000,
            step: 250
        },
        {
            label: "quiet after ms",
            prop: "quietAfterMs",
            group: "The quiet clock",
            tip: "How long the socket must deliver NOTHING, after the round has sent bytes, before the turn says the model is writing a tool call. Ollama streams prose and thinking but buffers a call whole -- measured 13.2 s of silence after the thinking on ornith-1.5:9b, 72.57 s on a long script -- so time since the last byte is the only honest live signal there is. 1.5 s because the slowest model here streams at 8 tok/s (125 ms between tokens); 3 s left the line saying \"thinking\" long after the thinking had ended.",
            val: 1500,
            from: 500,
            to: 15000,
            step: 250
        },
        {
            label: "residency hold ms",
            prop: "residencyHoldMs",
            group: "Residency",
            blurb: "Keeping the model loaded while a tool turn waits for an answer.",
            tip: "How often a PARKED tool turn pings the server to keep its model. Ollama's keep-alive clock starts at the END of the last request, and a parked confirmation is the one window of a turn with nothing in flight, so past the backend's ten minutes the weights go and the next round pays a full reload. Four minutes is comfortably under ten without being arithmetic on it; 0 switches the hold off.",
            val: 240000,
            from: 0,
            to: 540000,
            step: 30000
        },
        {
            label: "round deadline floor ms",
            prop: "roundTimeoutMs",
            group: "Loop",
            blurb: "The tool loop's deadlines and limits: rounds, calls per round, repeats.",
            tip: "The FLOOR under a round's deadline, and its manual override. Above it the deadline is what this model's own measured prompt rate says the prompt just sent needs, times four, capped at fifteen minutes. A constant cannot work here: the same model in the same turn gave its first byte at 12.7 s for a 5262-token prompt and at 53.0 s for an 18909-token one. Three minutes because every legitimate silence measured on this machine is under it: 53 s of prompt evaluation on a 35b, 74.5 s to write an 18 KB tool call, 157 s for a cold 23 GB load. 0 switches the bound off, which is what shipped before round 17 and is why one round ran for twenty minutes.",
            val: 180000,
            from: 0,
            to: 600000,
            step: 15000
        },
        {
            label: "repeat echo",
            prop: "toolRepeatEcho",
            group: "Loop",
            tip: "The same call (name and arguments) this many times gets the previous result echoed back instead of running again -- a model re-reading a file it just read.",
            val: 2,
            from: 1,
            to: 5,
            step: 1
        },
        {
            label: "repeat stop",
            prop: "toolRepeatStop",
            group: "Loop",
            tip: "The same call this many times ends the turn with an error: the model is looping, and no result will change that.",
            val: 3,
            from: 2,
            to: 6,
            step: 1
        },
        {
            label: "history cap",
            prop: "toolHistoryCap",
            group: "Loop",
            tip: "Bytes of each OLD tool result replayed into later turns' history. 2 KB keeps what the model concluded from without feeding a 32 KB grep back on every question.",
            val: 2048,
            from: 256,
            to: 16384,
            step: 256
        },
        {
            label: "tokens per tool",
            prop: "toolTokensPerDefinition",
            group: "Loop",
            tip: "Prompt tokens one tool definition costs on the wire, for the picker's 'definitions cost ~N tokens' line. 173 is the measured figure: 2081 tokens for the 12 shipped definitions on gemma4 e2b and e4b (the same tokenizer family); a model with a different tokenizer is within a few percent.",
            val: 173,
            from: 50,
            to: 400,
            step: 1
        },
        {
            label: "title deadline floor ms",
            prop: "titleTimeoutMs",
            group: "Titles",
            blurb: "The request that names a conversation.",
            tip: "The FLOOR of a classify request's deadline, and its manual override. Above it the deadline is what the model's own measured prompt rate says the request needs, times four, capped at two minutes: a flat 30 s was under half of what the 35b needed here -- 806 prompt tokens at 20.6 tok/s is 39.1 s before the model reads a word, and the reply landed at 41.97 s.",
            val: 30000,
            from: 5000,
            to: 120000,
            step: 1000
        },
        {
            label: "bring back after ms",
            prop: "confirmNotifyMs",
            group: "Confirmation",
            blurb: "A tool confirmation left waiting with the popup closed.",
            tip: "How long a confirmation may wait unanswered with the popup closed before the shell is asked to bring it back. 15 s is 'they walked away', not 'they are reading it'.",
            val: 15000,
            from: 3000,
            to: 60000,
            step: 1000
        }
    ]

    // The runner's limits (target: tools), contract §5.8.
    readonly property var toolRunParams: [
        {
            label: "sudo window ms",
            prop: "sudoAuthWindowMs",
            group: "Runner",
            blurb: "How a tool's command runs: its time limit, sudo's extra time and how much output is kept.",
            tip: "Time a command that may run sudo gets ON TOP of its own limit, for Howdy's scan and a typed password -- both happen inside the command's clock, and a 60 s limit would kill the password box under the user's fingers. It is also how long the password box waits before it withdraws the question. 2 min: Howdy gives up after 4 s, and sudo asks up to three times.",
            val: 120000,
            from: 20000,
            to: 600000,
            step: 10000
        },
        {
            label: "timeout ms",
            prop: "toolTimeoutMs",
            group: "Runner",
            tip: "Wall time a tool may run before `timeout` ends it (exit 124 -> timedOut, partial output kept). A tool's own timeoutMs in its file wins when set; 20 s is a grep of the home directory, not a build.",
            val: 20000,
            from: 2000,
            to: 120000,
            step: 1000
        },
        {
            label: "output cap",
            prop: "toolOutputCap",
            group: "Runner",
            tip: "Bytes of a result the model receives: the first three quarters and the last quarter, with a cut marker between. 32 KB is what a small model can still reason over at 8k context.",
            val: 32768,
            from: 4096,
            to: 262144,
            step: 4096
        },
        {
            label: "flood kill bytes",
            prop: "toolFloodKillBytes",
            group: "Runner",
            tip: "Total bytes a child may write before it is killed outright (status flood): `yes` or a runaway tail must not fill memory while the cap only trims what is kept.",
            val: 1048576,
            from: 65536,
            to: 8388608,
            step: 65536
        },
        {
            label: "kill grace ms",
            prop: "toolKillGraceMs",
            group: "Runner",
            tip: "After SIGTERM (a stop, or `timeout` firing), how long before SIGKILL. 2 s lets a well-behaved child flush and exit.",
            val: 2000,
            from: 500,
            to: 10000,
            step: 500
        },
        {
            label: "preflight ms",
            prop: "preflightMs",
            group: "Runner",
            tip: "Time allowed for write_file's preflight stat -- the 'overwrites 2.3 KB' line in the confirmation -- before the box opens without it.",
            val: 2000,
            from: 500,
            to: 10000,
            step: 500
        }
    ]

    readonly property var layoutParams: [
        {
            label: "padding px",
            prop: "padding",
            group: "Frame",
            blurb: "One number for every gap. The space outside a container equals the space inside it, so the history's left inset equals the conversation's right inset and the two containers' feet land on one line.",
            tip: "Space at the popup's edge, between the two containers, and between a container's edge and its content. 12 everywhere in the shell.",
            val: 12,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "container radius",
            prop: "containerRadius",
            group: "Frame",
            tip: "Corner radius of the carved containers -- history, transcript, composer. 14 is the shell's container radius; a box that meets a container's corner shares its curve.",
            val: 14,
            from: 0,
            to: 28,
            step: 1
        },
        {
            label: "row inset px",
            prop: "rowInset",
            group: "Frame",
            tip: "How far a row is held off its container's edge. The rows are inset, never the viewport -- insetting the viewport holds the section headers away from the corners they are supposed to meet.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "resize ms",
            prop: "containerResizeMs",
            group: "Frame",
            tip: "How long the sidebar takes to fold or open. 260 ms OutCubic is the shell's resize easing, the same one thePopup uses on the popup itself.",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "title row h",
            prop: "titleRowHeight",
            group: "Frame",
            tip: "Height of the conversation title line and its collapse-all button, above the transcript. Small on purpose: it is a label, not a card.",
            val: 24,
            from: 14,
            to: 44,
            step: 1
        },
        {
            label: "button h",
            prop: "buttonHeight",
            group: "Frame",
            tip: "Height of the raised buttons in the sidebar's header row. 30 is the shell's raised-button height.",
            val: 30,
            from: 20,
            to: 48,
            step: 1
        },
        {
            label: "min width",
            prop: "minWidth",
            group: "Size",
            blurb: "What the popup asks its host for with the history OUT (history + conversation). Folded, the popup is the history's footprint narrower and the conversation keeps its width.",
            tip: "900 leaves ~590 px of prose beside an open history panel, about 90 characters at 12 px -- past that a line is tiring to read. The folded popup is 280 px less.",
            val: 900,
            from: 760,
            to: 1600,
            step: 10
        },
        {
            label: "min height",
            prop: "minHeight",
            group: "Size",
            tip: "Fixed rather than measured: a conversation has no natural height, and a popup that grew with every answer would never settle.",
            val: 640,
            from: 360,
            to: 1100,
            step: 10
        }
    ]

    readonly property var sidebarParams: [
        {
            label: "open width",
            prop: "sidebarOpenWidth",
            group: "Panel",
            blurb: "The history panel: open, or folded away entirely.",
            tip: "Width with the history showing. 268 fits a six-word title at 12 px plus the time on the right. Folded, the panel goes to zero and the conversation takes the whole width -- the session's buttons stay in the top row either way.",
            val: 268,
            from: 160,
            to: 420,
            step: 4
        },
        {
            label: "button gap",
            prop: "buttonGap",
            group: "Panel",
            tip: "Between the session's buttons in the top row, and the width of the slot incognito opens and closes. 8 reads as four separate controls at 30 px without the row looking gappy.",
            val: 8,
            from: 2,
            to: 20,
            step: 1
        },
        {
            label: "row gap",
            prop: "sidebarRowGap",
            group: "List",
            blurb: "The history list: date sections, then one row per conversation.",
            tip: "Gap between two conversation rows.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "title px",
            prop: "sidebarTitleSize",
            group: "Type",
            blurb: "Two sizes, and nothing between them.",
            tip: "A conversation's title. 12 is the shell's body size; it is the only thing in the row the eye is meant to read.",
            val: 12,
            from: 9,
            to: 18,
            step: 1
        },
        {
            label: "time px",
            prop: "sidebarTimeSize",
            group: "Type",
            tip: "The time on the right of a row, the count on a group header, and the match count while searching. 10 is the compact figure size -- there to be found, not to be read.",
            val: 10,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "row anim ms",
            prop: "sidebarAnimMs",
            group: "Motion",
            blurb: "How rows arrive and leave: a group collapsing, a filter, a new conversation, a deletion.",
            tip: "How long one row takes to travel in from the left or out to the right. 240 is the shared list-row duration, so a row leaving this list moves at the same speed as a package row leaving the update's.",
            val: 240,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "wave concurrency",
            prop: "sidebarWaveConcurrency",
            group: "Motion",
            tip: "How many rows are airborne at once when a group folds: the per-row delay is the travel time divided by this. 240/6 is the same 40 ms cadence the search wave has always had. What BOUNDS a wave is the viewport, not this number -- only rows you can see are given a rank -- so raising it makes the fold brisker, never longer.",
            val: 6.0,
            from: 1,
            to: 12,
            step: 0.5
        }
    ]

    readonly property var transcriptParams: [
        {
            label: "result lines",
            prop: "toolBlockMaxLines",
            group: "Tool block",
            blurb: "A tool call's block in the conversation.",
            tip: "Result lines a finished tool block shows before it folds to a handle with a count. 40 is a screen of grep hits; a 32 KB result never scrolls the conversation.",
            val: 40,
            from: 5,
            to: 200,
            step: 5
        },
        {
            label: "turn spacing",
            prop: "turnSpacing",
            group: "List",
            blurb: "The scrolling body of exchanges.",
            tip: "Gap between one exchange and the next. 6 matches the list row spacing everywhere else in the shell.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "follow band px",
            prop: "followBand",
            group: "List",
            tip: "How close to the bottom counts as 'following'. Auto-scroll is a band, not a boolean: a reader who scrolled up keeps their place, and a resize does not strand the newest tokens under the edge.",
            val: 60,
            from: 0,
            to: 200,
            step: 5
        },
        {
            label: "edge fade px",
            prop: "listFadeHeight",
            group: "List",
            tip: "The band at each end of EVERY scrolling box in the popup: the history, the answers, the draft, the chip strip, the confirmation's preview and the allowances. Its opacity is how far that end is from the content, so it is off exactly at each rest and cannot burn at the end of a list.",
            val: 34,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "scroll speed",
            prop: "scrollSpeed",
            group: "List",
            tip: "Pixels per wheel notch as a multiple of the shell's 120, in every box the popup scrolls. It is one number because it used to be four: the confirmation's preview was left on the desktop's own style hint at 72 px, the model list and the chip strip ran at half, and only the transcript and the history were right.",
            val: 1.0,
            from: 0.2,
            to: 4,
            step: 0.05
        },
        {
            label: "body px",
            prop: "bodyPixelSize",
            group: "Type",
            blurb: "One density for the whole transcript.",
            tip: "Prose size. There is one view now, so nothing changes it at runtime -- binding a font size to something a view switch changes re-shapes every text in the list at once, which cost the system update 26 of its 37 ms per switch.",
            val: 13,
            from: 9,
            to: 20,
            step: 1
        },
        {
            label: "code px",
            prop: "codePixelSize",
            group: "Type",
            tip: "Size of a fenced code block and of inline code. Consolas Bold 12 is the shell's terminal type, so code in an answer and code in the update's terminal read as the same material.",
            val: 12,
            from: 8,
            to: 18,
            step: 1
        },
        {
            label: "figure px",
            prop: "figureSize",
            group: "Type",
            tip: "The small print: token counts, rate, the time under a question, the answer count above the transcript. 10 is the shell's compact figure size.",
            val: 10,
            from: 8,
            to: 14,
            step: 1
        },
        {
            label: "mark size",
            prop: "logoSize",
            group: "Empty state",
            blurb: "The selected model's mark, carved into an empty conversation.",
            tip: "How wide the selected model's mark is drawn in an empty conversation, in pixels. 0 hides it. The mark is carved into the surface with the same inset shadow and bevel a ShadowBox uses, and the two lines under it are pushed down by whatever it takes.",
            val: 170,
            from: 0,
            to: 320,
            step: 2
        },
        {
            label: "mark depth",
            prop: "logoDepthScale",
            group: "Empty state",
            tip: "How deep the carve goes, as a fraction of what was baked into the texture. Below 1 narrows it exactly; above 1 clamps at the baked depth.",
            val: 1.0,
            from: 0.0,
            to: 2.0,
            step: 0.05
        },
        {
            label: "mark bevel",
            prop: "logoBevelWidth",
            group: "Empty state",
            tip: "The lit rim outside the mark's edge, as a fraction of the carve's depth. 0.15 is a 1.5 px rim on the 11 px wall at 170 -- the container ShadowBox's own bevel-to-inset ratio, so the mark and the boxes around it agree.",
            val: 0.15,
            from: 0.0,
            to: 1.0,
            step: 0.02
        },
        {
            label: "mark falloff",
            prop: "logoFalloff",
            group: "Empty state",
            tip: "The inset's decay curve. 1 is a ShadowBox's own: within a level of the floor 5 px into the wall, which is what makes the shadow let go instead of holding across it. The old 0.6 held the shade across the whole wall and read as too deep.",
            val: 1.0,
            from: 0.2,
            to: 3.0,
            step: 0.05
        },
        {
            label: "mark ambient",
            prop: "logoAmbient",
            group: "Empty state",
            tip: "How much of the inset is isotropic rather than lit from one side. 1.0 is exactly a ShadowBox's band, with no directional shading at all.",
            val: 0.42,
            from: 0.0,
            to: 1.0,
            step: 0.02
        },
        {
            label: "mark highlight",
            prop: "logoHighlightGain",
            group: "Empty state",
            tip: "How much lighter an up-facing wall is than a down-facing one.",
            val: 0.85,
            from: 0.0,
            to: 2.0,
            step: 0.05
        },
        {
            label: "mark light angle",
            prop: "logoLightAngle",
            group: "Empty state",
            tip: "Where the light comes from, in degrees clockwise from straight up. The shell lights everything from above, so 0 keeps the mark agreeing with every carved box around it.",
            val: 0,
            from: -180,
            to: 180,
            step: 5
        },
        {
            label: "mark fade ms",
            prop: "logoPresenceMs",
            group: "Empty state",
            tip: "How long the mark takes to arrive or leave when the selected model changes: the two lines translate and the image fades on this one clock. 260 is the shell's resize easing.",
            val: 260,
            from: 0,
            to: 600,
            step: 20
        }
    ]

    readonly property var turnParams: [
        {
            label: "question max w",
            prop: "turnQuestionMaxWidth",
            group: "Question",
            blurb: "One exchange: the question, the thinking drawer, the answer.",
            tip: "How much of the body a question may take, as a fraction, before it wraps. The box hugs its text and sits against the right edge -- that is what makes it read as the side you typed, with no coloured bubble and no tail.",
            val: 0.78,
            from: 0.3,
            to: 1,
            step: 0.01
        },
        {
            label: "question lines",
            prop: "turnQuestionMaxLines",
            group: "Question",
            tip: "How many lines a sent question shows before it folds itself away behind a chevron. Four is a paragraph; past that the answer matters more than the question.",
            val: 4,
            from: 1,
            to: 12,
            step: 1
        },
        {
            label: "box radius",
            prop: "turnBoxRadius",
            group: "Question",
            tip: "Corner radius of the carved question box and the thinking drawer. 10 is one step tighter than the container they sit in.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "thumb size",
            prop: "turnThumbSize",
            group: "Question",
            tip: "Edge of an attached image's thumbnail above the question. 64 is readable as a picture and still lets three sit on one line.",
            val: 64,
            from: 32,
            to: 160,
            step: 4
        },
        {
            label: "padding",
            prop: "turnQuestionPadding",
            group: "Question box",
            blurb: "The box around a question, and its attachment chips.",
            tip: "Text inset inside the question box.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "radius",
            prop: "turnQuestionRadius",
            group: "Question box",
            tip: "Corner radius; defaults to the box radius.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "chevron strip",
            prop: "turnQuestionChevronStrip",
            group: "Question box",
            tip: "Fold-strip height beyond the chevron's figure size, so the mark never sits on the last line.",
            val: 8,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "chip gap",
            prop: "turnChipGap",
            group: "Question box",
            tip: "Gap between attachment chips under a question.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "header radius",
            prop: "turnHeaderRadius",
            group: "Header",
            blurb: "The titled bar that folds the answer under it, with the category's icon on its left and the category's colour in its inset.",
            tip: "Radius of the header's carved box. The topmost header takes the container's radius instead, so the two curves coincide at the corner.",
            val: 14,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "title px",
            prop: "turnTitleSize",
            group: "Header",
            tip: "Size of a turn's title -- the topic the model named the exchange after. 15 is the shell's list-section title size, so a folded conversation reads like any other sectioned list.",
            val: 15,
            from: 10,
            to: 22,
            step: 1
        },
        {
            label: "subtitle px",
            prop: "turnSubtitleSize",
            group: "Header",
            tip: "Size of the line under it: which model answered, and when -- or what it is doing right now.",
            val: 11,
            from: 8,
            to: 16,
            step: 1
        },
        {
            label: "wait period ms",
            prop: "turnWaitPeriodMs",
            group: "Header",
            tip: "One trip of the wait band: the head crosses, then the tail follows it out. A language model reports no progress, so the band loops rather than fills -- it says 'working', not 'this far'. Under about 1400 ms it reads frantic, over about 2800 ms it reads stalled.",
            val: 2000,
            from: 800,
            to: 4000,
            step: 50
        },
        {
            label: "wait head span",
            prop: "turnWaitHeadSpan",
            group: "Header",
            tip: "Fraction of the trip the LEADING edge is in motion. Below 1 it parks at the right end for the rest of the trip while the tail closes up behind it.",
            val: 0.62,
            from: 0.3,
            to: 1,
            step: 0.01
        },
        {
            label: "wait tail span",
            prop: "turnWaitTailSpan",
            group: "Header",
            tip: "Fraction of the trip the TRAILING edge is in motion; it starts at 1 minus this. head + tail - 1 is the overlap, the part of the trip where both edges move. Lower it for a beat of the parked mark between trips.",
            val: 0.62,
            from: 0.3,
            to: 1,
            step: 0.01
        },
        {
            label: "expand ms",
            prop: "turnExpandMs",
            group: "Header",
            tip: "How long an answer takes to fold away or open. The travel is capped at what is on screen, so a 100-line and a 1000-line answer fold at the same speed.",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "fold cap margin",
            prop: "turnFoldCapMargin",
            group: "Header",
            tip: "How far past the viewport's bottom edge a fold is animated. The swap between the animated height and the answer's true height happens here, so it has to be off screen -- that cap is the whole reason a 100-line and a 1000-line answer fold identically. Set it very large and the round-1 behaviour comes back: a long answer throws everything below it up the screen.",
            val: 48,
            from: 0,
            to: 400,
            step: 4
        },
        {
            label: "padding h",
            prop: "turnHeaderPaddingH",
            group: "Header box",
            blurb: "The carved box that holds a turn's title and subtitle.",
            tip: "Text clearance from the header box's sides. 11 clears the inset shadow so the title never sits in the shading.",
            val: 11,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "padding v",
            prop: "turnHeaderPaddingV",
            group: "Header box",
            tip: "Clearance above the title and below the subtitle.",
            val: 8,
            from: 2,
            to: 16,
            step: 1
        },
        {
            label: "bottom gap",
            prop: "turnHeaderBottomGap",
            group: "Header box",
            tip: "Space under the header box before the body; equals the row inset.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "icon size",
            prop: "turnHeaderIconSize",
            group: "Header box",
            tip: "The glyph slot. Default is the title size + 3, so the icon carries the title's optical weight.",
            val: 18,
            from: 12,
            to: 28,
            step: 1
        },
        {
            label: "icon gap",
            prop: "turnHeaderIconGap",
            group: "Header box",
            tip: "Glyph to title column.",
            val: 8,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "idle width",
            prop: "turnSweepIdleWidth",
            group: "Header sweep",
            blurb: "The colour band in the header box's inset: a mark at rest, a sweep while the turn runs.",
            tip: "The mark the band grows from and comes back to, at the inset's left -- the old accent stripe's footprint.",
            val: 26,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "idle feather",
            prop: "turnSweepIdleFeather",
            group: "Header sweep",
            tip: "Colour-to-shadow crossover when parked. Tight, so the mark ends decisively.",
            val: 12,
            from: 0.25,
            to: 12,
            step: 0.25
        },
        {
            label: "under way feather",
            prop: "turnSweepActiveFeather",
            group: "Header sweep",
            tip: "How soft each edge of the band is. Wide, so a moving edge reads as a wash and not a seam; one feather serves both edges.",
            val: 12,
            from: 0.25,
            to: 40,
            step: 0.5
        },
        {
            label: "idle depth",
            prop: "turnSweepIdleDepth",
            group: "Header sweep",
            tip: "How far the inset reaches when parked.",
            val: 7.5,
            from: 1,
            to: 16,
            step: 0.5
        },
        {
            label: "under way depth",
            prop: "turnSweepActiveDepth",
            group: "Header sweep",
            tip: "Reach under way. Equal to idle by default so the box does not breathe.",
            val: 7.5,
            from: 1,
            to: 16,
            step: 0.5
        },
        {
            label: "idle strength",
            prop: "turnSweepIdleStrength",
            group: "Header sweep",
            tip: "Edge alpha of the inset when parked.",
            val: 0.65,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "under way strength",
            prop: "turnSweepActiveStrength",
            group: "Header sweep",
            tip: "Edge alpha under way.",
            val: 0.65,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "idle falloff",
            prop: "turnSweepIdleFalloff",
            group: "Header sweep",
            tip: "Decay curve of the inset when parked; above 1 hugs the edge.",
            val: 0.9,
            from: 0.2,
            to: 3,
            step: 0.1
        },
        {
            label: "under way falloff",
            prop: "turnSweepActiveFalloff",
            group: "Header sweep",
            tip: "Decay curve under way.",
            val: 0.9,
            from: 0.2,
            to: 3,
            step: 0.1
        },
        {
            label: "blend end",
            prop: "turnSweepBlendEnd",
            group: "Header sweep",
            tip: "Fraction of the sweep at which the idle look has fully become the active one.",
            val: 0.32,
            from: 0.05,
            to: 1,
            step: 0.01
        },
        {
            label: "block gap",
            prop: "turnBlockGap",
            group: "Body",
            blurb: "Inside one exchange.",
            tip: "Space between the question box, the thinking drawer, the answer and the footer.",
            val: 8,
            from: 0,
            to: 28,
            step: 1
        },
        {
            label: "drawer inset",
            prop: "turnDrawerInset",
            group: "Body",
            tip: "How far the thinking text is held off the drawer's left edge, so the reasoning reads as an aside rather than as more answer.",
            val: 10,
            from: 0,
            to: 32,
            step: 1
        },
        {
            label: "handle gap",
            prop: "turnDrawerGap",
            group: "Thinking drawer",
            blurb: "The folded drawer that holds the model's thinking.",
            tip: "Handle line to prose.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "block spacing",
            prop: "turnDrawerBlockSpacing",
            group: "Thinking drawer",
            tip: "Between blocks in the drawer; tighter than the answer's 8 -- it is an aside.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "heading spacing",
            prop: "turnDrawerHeadingSpacing",
            group: "Thinking drawer",
            tip: "Extra space above a heading in the drawer.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "button gap",
            prop: "turnFooterButtonGap",
            group: "Footer",
            blurb: "The action buttons and the tok/s figures under an answer.",
            tip: "Between the four action buttons.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "button height",
            prop: "turnFooterButtonHeight",
            group: "Footer",
            tip: "Action button height.",
            val: 24,
            from: 18,
            to: 36,
            step: 1
        },
        {
            label: "button min width",
            prop: "turnFooterButtonMinWidth",
            group: "Footer",
            tip: "Minimum action button width.",
            val: 26,
            from: 20,
            to: 48,
            step: 1
        },
        {
            label: "figure margin",
            prop: "turnFooterFigureMargin",
            group: "Footer",
            tip: "Right margin of the tok/s figures. 6 + the row inset 6 = the card padding 12.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "padding",
            prop: "turnErrorPadding",
            group: "Error strip",
            blurb: "The strip that says a turn failed.",
            tip: "Inner padding of the error strip.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "bar gap",
            prop: "turnWaitBarGap",
            group: "Waiting",
            blurb: "The bars that breathe while an answer is awaited.",
            tip: "Between the pulsing bars while an answer is awaited.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "bar travel",
            prop: "turnWaitBarTravel",
            group: "Waiting",
            tip: "How far each END of a waiting bar travels while it breathes, in pixels. A distance rather than a fraction, so a long line and a short one move by the same visible amount -- 8 px is what the shortest of the three already did when the pulse was a scale, so no line pulses harder than it used to.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "stagger ms",
            prop: "turnWaitBarStaggerMs",
            group: "Waiting",
            tip: "The beat between one waiting bar's breath and the next one's, so the column waves top to bottom instead of blinking as one block.",
            val: 100,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "seam fade",
            prop: "turnSeamFadeHeight",
            group: "Motion",
            blurb: "The dissolve at a fold's moving edge.",
            tip: "Dissolve band at a moving fold edge. 42 = three lines visibly dissolving.",
            val: 42,
            from: 0,
            to: 96,
            step: 2
        },
        {
            label: "line height",
            prop: "bodyLineHeight",
            group: "Type",
            blurb: "The reading face's line pitch.",
            tip: "Line pitch of the reading face, as a multiple of its size. 1.15 puts Exo 2 at 18.4 px on a 13 px body -- a paragraph's measure rather than a UI label's. The answer, the thinking and the sent prompt take it; an editable field has no line pitch to take.",
            val: 1.15,
            from: 1.0,
            to: 1.6,
            step: 0.01
        },
        {
            label: "autoscroll zone",
            prop: "autoScrollDeadZone",
            group: "Selection",
            blurb: "Dragging a selection past the container's edge scrolls it, the way every text view does.",
            tip: "How far past the edge the pointer must go before the view starts moving. 12 px stops a selection that merely reaches the last line from running away.",
            val: 12,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "autoscroll ramp",
            prop: "autoScrollRamp",
            group: "Selection",
            tip: "Overshoot, in px, over which the speed climbs from nothing to the cap. 140 gives fine control near the edge and full speed when you mean it.",
            val: 140,
            from: 20,
            to: 400,
            step: 5
        },
        {
            label: "autoscroll max",
            prop: "autoScrollMaxSpeed",
            group: "Selection",
            tip: "The fastest the view scrolls while a selection drags past the edge, px per second. 1100 crosses a long answer in about a second without losing the text.",
            val: 1100,
            from: 200,
            to: 3000,
            step: 50
        }
    ]

    readonly property var markdownParams: [
        {
            label: "block spacing",
            prop: "mdBlockSpacing",
            group: "Markdown",
            blurb: "How the rendered answer is set. Every block is its own small document; only the last one is still being written. Nothing in an answer scrolls -- code wraps and tables fit.",
            tip: "Gap between two markdown blocks -- a paragraph and the list under it, say. 8 is a little under the type's own line height, which is what makes a block read as one thing.",
            val: 8,
            from: 0,
            to: 28,
            step: 1
        },
        {
            label: "heading space",
            prop: "mdHeadingSpacing",
            group: "Markdown",
            tip: "Extra space ABOVE a heading, on top of the block spacing. A heading belongs to what follows it, so the space in front of it has to be larger than the space behind.",
            val: 12,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "code radius",
            prop: "mdCodeRadius",
            group: "Markdown",
            tip: "Corner radius of a fenced code block's carved box. 10 keeps it one step tighter than the container it sits in.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "heading scale",
            prop: "mdHeadingScale",
            group: "Document",
            blurb: "Headings, code boxes, quotes and lists in an answer.",
            tip: "Multiplies the per-level heading step (h1 +50%, down to h4 +5%). 0 puts every heading at body size.",
            val: 1.0,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "code padding",
            prop: "mdCodePadding",
            group: "Document",
            tip: "Code box inner padding.",
            val: 10,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "code lid height",
            prop: "mdCodeHeaderHeight",
            group: "Document",
            tip: "The code box's lid (language + copy).",
            val: 26,
            from: 16,
            to: 40,
            step: 1
        },
        {
            label: "quote inset",
            prop: "mdQuoteInset",
            group: "Document",
            tip: "Text inset after the quote bar.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "quote bar width",
            prop: "mdQuoteBarWidth",
            group: "Document",
            tip: "Quote bar width.",
            val: 3,
            from: 1,
            to: 8,
            step: 0.5
        },
        {
            label: "table radius",
            prop: "mdTableRadius",
            group: "Document",
            tip: "Table and image box radius.",
            val: 10,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "table cell pad h",
            prop: "mdTableCellPadH",
            group: "Document",
            tip: "Cell padding, horizontal. Live, no rebuild.",
            val: 10,
            from: 2,
            to: 20,
            step: 1
        },
        {
            label: "table cell pad v",
            prop: "mdTableCellPadV",
            group: "Document",
            tip: "Cell padding, vertical.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        },
        {
            label: "image inset",
            prop: "mdImageInset",
            group: "Document",
            tip: "Image inset inside its box.",
            val: 6,
            from: 0,
            to: 16,
            step: 1
        }
    ]

    readonly property var composerParams: [
        {
            label: "min lines",
            prop: "composerMinLines",
            group: "Composer",
            blurb: "The field the question is typed into, with the attach and tools buttons on its left and the model pill beside send on its right.",
            tip: "How tall the field is with nothing in it. One line: the composer should not look like a form before anything has been asked.",
            val: 1,
            from: 1,
            to: 6,
            step: 1
        },
        {
            label: "max lines",
            prop: "composerMaxLines",
            group: "Composer",
            tip: "How far it grows before it scrolls instead, at which point its own scroll bar appears in the lane already reserved for it. Six lines is a long question.",
            val: 6,
            from: 2,
            to: 20,
            step: 1
        },
        {
            label: "padding",
            prop: "composerPadding",
            group: "Composer",
            tip: "Clearance inside the field: text to edge, and buttons to edge.",
            val: 10,
            from: 0,
            to: 28,
            step: 1
        },
        {
            label: "button size",
            prop: "composerButtonSize",
            group: "Composer",
            tip: "Edge of the attach, tools and send buttons. 28 is a comfortable pointer target that still fits inside a one-line field.",
            val: 28,
            from: 18,
            to: 44,
            step: 1
        },
        {
            label: "resize ms",
            prop: "composerResizeMs",
            group: "Composer",
            tip: "The field's and the chip strip's height easing. 260 OutCubic is the shell's one resize clock.",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "completion rows",
            prop: "completionMaxRows",
            group: "Path completion",
            blurb: "The @-path list that opens over the composer while a path is typed.",
            tip: "How many rows the @-path list may stand before it scrolls inside itself. Six is about two prompt lines; every row past that is taken from the conversation.",
            val: 6,
            from: 2,
            to: 12,
            step: 1
        },
        {
            label: "completion entries drawn",
            prop: "completionMaxEntries",
            group: "Path completion",
            tip: "The most matches DRAWN; the count line still states the true total. Five thousand matches is a typing mistake rather than a list, and the answer to it is another character.",
            val: 120,
            from: 20,
            to: 400,
            step: 10
        },
        {
            label: "completion radius",
            prop: "completionRadius",
            group: "Path completion",
            tip: "The carved list's corner. 10 is the confirmation's own inner radius, so the two boxes that share the groove agree.",
            val: 10,
            from: 4,
            to: 16,
            step: 1
        },
        {
            label: "pdf pictures",
            prop: "pdfImageCap",
            group: "Attachments",
            blurb: "What the model gets to LOOK at inside a pdf.",
            tip: "The DEFAULT a newly attached pdf starts from: how many of its own pictures ride, after duplicates and decoration (arrows, rules) are dropped. Each attached file then keeps its own -- right-click a pdf chip's pictures glyph to change that one file. An extracted picture costs 50-258 tokens by its area, far less than a rendered page: a real 74-page deck sends 21 pictures for 1500 tokens.",
            val: 32,
            from: 0,
            to: 80,
            step: 1
        },
        {
            label: "pdf smallest picture",
            prop: "pdfImageMinArea",
            group: "Attachments",
            tip: "The DEFAULT a newly attached pdf starts from: the smallest embedded picture that still counts as a figure, in px^2 (10 000 = 100x100). Per-file from the chip's own menu. Decoration -- arrows, rules, plates -- is caught by pixel density, not by this; this only drops genuine thumbnails the model could not read anyway.",
            val: 10000,
            from: 0,
            to: 40000,
            step: 500
        },
        {
            label: "pdf pages (pages mode)",
            prop: "pdfPageCap",
            group: "Attachments",
            tip: "The DEFAULT for pages mode -- the fallback for a document whose figures are vector art, where there is nothing embedded to extract. Whole pages rendered as images, about 268 tokens each whatever the dpi. Per-file from the chip's own menu.",
            val: 24,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "pdf dpi",
            prop: "pdfDpi",
            group: "Attachments",
            tip: "Resolution PAGE images are rendered at in pages mode. 110 is the first value that does not upscale a 16:9 slide into the vision encoder's 768 px input; below it small print is misread (measured on a 5 pt ladder: 90 dpi wrong 3/3, 110 exact 3/3), above it only costs bytes. Extracted pictures ride at their own resolution and ignore this.",
            val: 110,
            from: 72,
            to: 200,
            step: 2
        },
        {
            label: "chip size",
            prop: "chipSize",
            group: "Chip",
            blurb: "An attachment's chip in the composer's strip.",
            tip: "Side of the rounded-square attachment chip. 64 fits the two-bar silhouette, the control stack in the corner and an 8 px name underneath.",
            val: 64,
            from: 40,
            to: 96,
            step: 1
        },
        {
            label: "strip fade",
            prop: "chipFadeWidth",
            group: "Chip",
            tip: "Width of the strip's edge fades when chips overflow it. 24 is about a third of a chip -- enough to read as a fade rather than a cut.",
            val: 24,
            from: 0,
            to: 64,
            step: 1
        },
        {
            label: "reveal ms",
            prop: "chipRevealMs",
            group: "Chip",
            tip: "Reveal of the x / pictures stack on hover, and their own hover fades -- one clock for both.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "name size",
            prop: "chipNameFontSize",
            group: "Chip",
            tip: "The filename under the silhouette. 8 with a middle elide still shows the stem and the extension.",
            val: 8,
            from: 6,
            to: 11,
            step: 1
        },
        {
            label: "menu width",
            prop: "pdfMenuWidth",
            group: "pdf menu",
            blurb: "The picture-settings menu of an attached pdf.",
            tip: "The picture-settings menu's width. 200 gives a compact slider real travel and keeps the panel landscape -- never a square.",
            val: 224,
            from: 140,
            to: 320,
            step: 2
        },
        {
            label: "slider scale",
            prop: "pdfMenuSliderScale",
            group: "pdf menu",
            tip: "GrooveSlider sizeScale in the menu. 0.8 keeps the ball at 9.6 px inside a 13 px channel.",
            val: 0.8,
            from: 0.5,
            to: 1.2,
            step: 0.05
        },
        {
            label: "settle ms",
            prop: "pdfMenuSettleMs",
            group: "pdf menu",
            tip: "How long the ball must stand still, while held, before a change is sent. A re-extract costs about 1.2 s on a real deck, so never per frame; release always sends.",
            val: 250,
            from: 50,
            to: 1000,
            step: 10
        },
        {
            label: "pictures max",
            prop: "pdfImageCapMax",
            group: "pdf menu",
            tip: "Top of the pictures slider.",
            val: 80,
            from: 8,
            to: 200,
            step: 1
        },
        {
            label: "smallest picture max",
            prop: "pdfImageMinAreaMax",
            group: "pdf menu",
            tip: "Top of the smallest-picture slider (px^2).",
            val: 40000,
            from: 5000,
            to: 100000,
            step: 500
        },
        {
            label: "smallest picture step",
            prop: "pdfImageMinAreaStep",
            group: "pdf menu",
            tip: "Step of the smallest-picture slider.",
            val: 500,
            from: 100,
            to: 2000,
            step: 100
        },
        {
            label: "pages max",
            prop: "pdfPageCapMax",
            group: "pdf menu",
            tip: "Top of the pages slider (pages mode).",
            val: 60,
            from: 8,
            to: 120,
            step: 1
        },
        {
            label: "wrench tip width",
            prop: "wrenchTipWidth",
            group: "Tools",
            blurb: "The wrench beside the composer: its tool listing, the allowances menu and a tool call's confirmation.",
            tip: "How wide the tool listing wraps in the wrench's tip. The bubble sizes itself from its content, so this number decides the bubble's width.",
            val: 280,
            from: 180,
            to: 420,
            step: 10
        },
        {
            label: "allowances max height",
            prop: "grantsMenuMaxHeight",
            group: "Tools",
            tip: "The ceiling on the allowances panel: the rules scroll under it while the title and Revoke all stay put. Also clamped by the room above the wrench.",
            val: 320,
            from: 120,
            to: 520,
            step: 10
        },
        {
            label: "confirmation lines",
            prop: "confirmMaxLines",
            group: "Tools",
            tip: "Lines of a confirmation's detail (the command, the file) shown before its box scrolls inside. 12 shows a whole short script and keeps a pasted novel from pushing the prompt off the popup.",
            val: 12,
            from: 3,
            to: 40,
            step: 1
        },
        {
            label: "allowances width",
            prop: "grantsMenuWidth",
            group: "Tools",
            tip: "Width of the allowances menu behind the wrench (right-click): tool, rule, uses and the revoke mark in fixed slots.",
            val: 300,
            from: 200,
            to: 480,
            step: 4
        },
        {
            label: "default stripe colour",
            prop: "pickerStripeMutedSaturation",
            group: "Picker",
            blurb: "The model picker: its rows, the default model's stripe, the capability dots, the VRAM bars and the notes' tip.",
            tip: "How much of the accent's colour is left in the stripe of the DEFAULT model's row. 0.22 is the system update's own drain, so the faint mark in the model list and the faint mark on an unfavourited package are one mark rather than two lookalikes.",
            val: 0.22,
            from: 0.05,
            to: 0.6,
            step: 0.01
        },
        {
            label: "default stripe grey",
            prop: "pickerStripeMutedLightnessMix",
            group: "Picker",
            tip: "How far that faint stripe travels from the ground it lies on toward mid-grey. Relative, not absolute: 0.4732 reproduces the update's light-mode stripe exactly and still reads on the dark list, which one fixed lightness cannot do.",
            val: 0.4732,
            from: 0,
            to: 1,
            // Four decimals: the value is a measured match to the update's own
            // stripe, and a coarser step would quantise it away the first time
            // a profile round-tripped it.
            step: 0.0001
        },
        {
            label: "default stripe fade ms",
            prop: "pickerDefaultStripeFadeMs",
            group: "Picker",
            tip: "How long the stripe takes to appear or go when a right-click tags or clears the default model. 160 is the shell's presence fade, and on a row that is not the selection it is the only feedback the gesture has.",
            val: 160,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "stripe select ms",
            prop: "pickerStripeSelectFadeMs",
            group: "Picker",
            tip: "How long the stripe takes to travel from the drained default colour to the full accent when that row is also picked. 120 is the row's own hover number, so the mark and the wash move together.",
            val: 120,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "resize ms",
            prop: "pickerResizeMs",
            group: "Picker",
            tip: "How long the model list takes to change size when a brand with a different number of models is chosen. The box grows upward from the pill, so the FOOT is pinned and the tabs ride the moving top edge; 260 OutCubic is the shell's one resize clock, the same the prompt field uses. 0 is round 15's instant snap.",
            val: 260,
            from: 0,
            to: 800,
            step: 10
        },
        {
            label: "capability dot",
            prop: "capDotSize",
            group: "Picker",
            tip: "Capability dot ink. 5 reads as a mark, not a button.",
            val: 5,
            from: 3,
            to: 9,
            step: 1
        },
        {
            label: "capability slot",
            prop: "capSlotWidth",
            group: "Picker",
            tip: "Dot pitch and hover slot. 12 is the smallest a pointer can park on; the VRAM bar spans the dots' ink, so this sets its width too.",
            val: 12,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "VRAM bar height",
            prop: "vramBarHeight",
            group: "Picker",
            tip: "VRAM bar thickness; every end is a capsule inside it.",
            val: 4,
            from: 2,
            to: 8,
            step: 1
        },
        {
            label: "VRAM min step px",
            prop: "vramMinStepPx",
            group: "Picker",
            tip: "Minimum visible step between the card's fill and the model's. 6 = half the bar plus the bar at 4 px, so the exposed stub reads as bar, not as a halo round a cap.",
            val: 6,
            from: 2,
            to: 12,
            step: 1
        },
        {
            label: "VRAM track opacity",
            prop: "vramTrackOpacity",
            group: "Picker",
            tip: "The bar's remainder: the accent faded back.",
            val: 0.22,
            from: 0.05,
            to: 0.6,
            step: 0.01
        },
        {
            label: "VRAM card opacity",
            prop: "vramCardOpacity",
            group: "Picker",
            tip: "The card's used share. Must sit between the track and the model's full accent, or the three stop reading as three.",
            val: 0.45,
            from: 0.1,
            to: 0.9,
            step: 0.01
        },
        {
            label: "row height",
            prop: "modelRowHeight",
            group: "Picker",
            tip: "A model row: name, meta line, dots and bar.",
            val: 42,
            from: 32,
            to: 56,
            step: 1
        },
        {
            label: "VRAM swap ms",
            prop: "vramSwapMs",
            group: "Picker",
            tip: "How long the whole VRAM-bar swap takes when the selection moves from one model to another: the old bar's retreat and the new one's growth are halves of ONE curve, so the motion is fastest either side of the handover rather than at each bar's own start.",
            val: 420,
            from: 120,
            to: 1200,
            step: 10
        },
        {
            label: "VRAM refresh ms",
            prop: "vramLiveRefreshMs",
            group: "Picker",
            tip: "How often an open model list re-asks for VRAM figures, so a bar follows a model loading in. The service tightens its own read throttle to match while the list is open.",
            val: 1000,
            from: 250,
            to: 5000,
            step: 50
        },
        {
            label: "swipe px to angle",
            prop: "pickerSwipePixelToAngle",
            group: "Picker",
            tip: "How many wheel pixels of a two-finger swipe count as one degree of the pill's travel. 2.5 is the system update's own feel.",
            val: 2.5,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "notes tip width",
            prop: "pickerNotesTipWidth",
            group: "Picker",
            tip: "Width of the model-notes tip that opens to the LEFT of the list. 200 wraps a strength to two lines at 10 px without the tip becoming a column.",
            val: 200,
            from: 120,
            to: 320,
            step: 4
        },
        {
            label: "notes tip gap",
            prop: "pickerNotesTipGap",
            group: "Picker",
            tip: "Gap between the list's edge and its notes tip.",
            val: 6,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "load floor ms",
            prop: "turnLoadFloorMs",
            group: "Footer",
            blurb: "When a turn's load figure is shown.",
            tip: "Below this, a turn's load figure is the runner lookup and not the weights, so none is shown. Measured: a warm model answers in 1.3 to 1.8 ms across three context sizes, a cold load is 4362.6 ms, and a resident model asked at another context length is 3229.0 ms; the user's 84 stored turns hold nothing between 25.6 ms and 2956.5 ms.",
            val: 250,
            from: 0,
            to: 2000,
            step: 10
        }
    ]

    readonly property var popupColors: [
        {
            label: "surface",
            prop: "surface",
            group: "Ground",
            blurb: "The theme's own tokens. Editing one here writes themes/<name>.json for the active mode -- it is a real edit, not a session tweak.",
            tip: "The popup's background, painted by the host. Everything else is carved into or raised out of this one surface.",
            val: "#EAEDF5"
        },
        {
            label: "panel sunk",
            prop: "panelSunk",
            group: "Ground",
            tip: "Fill of a sunk panel: the composer's field, and the groove a scroll bar's thumb runs in.",
            val: "#E1E4EB"
        },
        {
            label: "list box",
            prop: "listBox",
            group: "Ground",
            tip: "Fill of a carved container: the transcript and the history panel. Between the surface and the header box, so three depths are legible at once.",
            val: "#E6E9F0"
        },
        {
            label: "header box",
            prop: "headerBox",
            group: "Ground",
            tip: "Fill of a box standing on a container: a turn's header, a group header, the question box, a scroll thumb, a skeleton bar.",
            val: "#DCDFE6"
        },
        {
            label: "header bevel",
            prop: "headerBoxBevel",
            group: "Ground",
            tip: "The light rim outside a header box's carved edge.",
            val: "#EEF0F7"
        },
        {
            label: "header shadow",
            prop: "headerBoxShadow",
            group: "Ground",
            tip: "The deepest part of a header box's inset shadow -- and the band the category's colour sweeps through while its answer streams.",
            val: "#AAADB4"
        },
        {
            label: "bevel",
            prop: "bevel",
            group: "Relief",
            blurb: "The two bands that make an edge read as carved.",
            tip: "The light rim OUTSIDE a carved edge. Slightly above the surface, so the eye reads the edge as going down.",
            val: "#EEF0F7"
        },
        {
            label: "border",
            prop: "border",
            group: "Relief",
            tip: "The inset shadow inside a carved edge, and the rule under a table's header row.",
            val: "#CED1D7"
        },
        {
            label: "text primary",
            prop: "textPrimary",
            group: "Ink",
            blurb: "Three weights of text, and nothing between them.",
            tip: "Prose, titles and the answer itself.",
            val: "#5D5D5F"
        },
        {
            label: "text muted",
            prop: "textMuted",
            group: "Ink",
            tip: "Subtitles, the thinking drawer, a category icon. Still 4.5:1 on the surface, so it is quieter without being harder to read.",
            val: "#6F6F72"
        },
        {
            label: "text faint",
            prop: "textFaint",
            group: "Ink",
            tip: "Figures, times, placeholders, a code block's language label, and the 'other' category -- everything the eye should skip unless it is looking for it.",
            val: "#8A8A8C"
        },
        {
            label: "accent",
            prop: "accent",
            group: "Accent",
            blurb: "One accent, for selection, the send button and links.",
            tip: "The selected conversation, the send button, a link in an answer, and the caret at the end of the text still arriving.",
            val: "#4480F4"
        },
        {
            label: "accent hover",
            prop: "accentHover",
            group: "Accent",
            tip: "The accent under a pointer. The change is a fraction eased over 120 ms and mixed here, never a colour animation.",
            val: "#4D91F8"
        },
        {
            label: "accent bevel",
            prop: "accentBevel",
            group: "Accent",
            tip: "The highlight inside a raised accent button's edge, which is what makes it read as a plateau rather than a patch of colour.",
            val: "#8DB3F8"
        },
        {
            label: "text on accent",
            prop: "textOnAccent",
            group: "Accent",
            tip: "Ink on an accent plateau: the send glyph, a lit pin.",
            val: "#EAEDF5"
        }
    ]

    readonly property var stateColors: [
        {
            label: "ok",
            prop: "ok",
            group: "States",
            blurb: "What a turn can end up being, and what a button is made of.",
            tip: "A finished answer's marks.",
            val: "#44C145"
        },
        {
            label: "error",
            prop: "error",
            group: "States",
            tip: "The backend refused or died. An out-of-memory from too many GPU layers arrives here verbatim, because the number that caused it is the useful part. It is also the Yes of a delete.",
            val: "#EC0000"
        },
        {
            label: "error tint",
            prop: "errorTint",
            group: "States",
            tip: "Fill of the carved strip a failure is written on, so the message is a card rather than red text loose on the surface.",
            val: "#FDE4E7"
        },
        {
            label: "button plateau",
            prop: "buttonPlateau",
            group: "Buttons",
            blurb: "The raised material: new chat, incognito, pin, burger, send, copy, delete.",
            tip: "The top of a raised button. The same value as the surface: a button is the surface pushed up, not a different colour.",
            val: "#EAEDF5"
        },
        {
            label: "plateau hover",
            prop: "buttonPlateauHover",
            group: "Buttons",
            tip: "The plateau under a pointer, and a scroll thumb under one. A short fade and the hand cursor are the only things that announce an affordance in this shell.",
            val: "#F2F4F9"
        },
        {
            label: "button bevel",
            prop: "buttonBevel",
            group: "Buttons",
            tip: "The highlight INSIDE a raised edge -- the counterpart of the carved box's outer rim, which is what makes the two read as one material.",
            val: "#FFFFFF"
        },
        {
            label: "button shadow",
            prop: "buttonShadow",
            group: "Buttons",
            tip: "The drop shadow a raised button casts on the surface. Spread 5 against the carved box's 3: a shadow spreads, a highlight is a line.",
            val: "#AAADB4"
        }
    ]

    readonly property var categoryHues: [
        {
            label: "code",
            prop: "llmCode",
            group: "Categories",
            val: "#8839EF",
            blurb: "The six conversation categories, each its own hue. None of them is the accent (which marks a conversation with no category yet) or the faint ink.",
            tip: "Code questions. Mauve -- distinct from the accent blue that marks an uncategorised conversation; code used to borrow the accent and the two were indistinguishable."
        },
        {
            label: "system",
            prop: "llmSystem",
            group: "Categories",
            val: "#FE640B",
            tip: "System and shell questions. Orange."
        },
        {
            label: "explain",
            prop: "llmExplain",
            group: "Categories",
            val: "#40A02B",
            tip: "Explanations and concepts. Green."
        },
        {
            label: "write",
            prop: "llmWrite",
            group: "Categories",
            val: "#EA76CB",
            tip: "Writing and wording. Pink."
        },
        {
            label: "data",
            prop: "llmData",
            group: "Categories",
            val: "#04A5E5",
            tip: "Data, tables, numbers. Sky -- kept away from the accent's blue."
        },
        {
            label: "other",
            prop: "llmOther",
            group: "Categories",
            val: "#DD7878",
            tip: "Everything the classifier could not place. A warm rose of its own, so 'other' never reads as 'no category yet' (the accent) or as disabled ink (the faint grey)."
        }
    ]

    readonly property var codeColors: [
        {
            label: "code fill",
            prop: "terminalBg",
            group: "Code block",
            blurb: "A fenced code block is a carved box in the terminal's own colours, so code in an answer and code in the update's terminal read as one material.",
            tip: "Fill of a fenced code block. The terminal's background, so the two are the same surface.",
            val: "#E1E4EB"
        },
        {
            label: "code ink",
            prop: "terminalFg",
            group: "Code block",
            tip: "Unhighlighted code -- punctuation, plain identifiers, and every language the highlighter does not know.",
            val: "#5D5D5F"
        },
        {
            label: "keyword",
            prop: "ansiBrightMagenta",
            group: "Syntax",
            blurb: "Highlighting uses the theme's ANSI slots rather than colours of its own, because the shell already has a palette for code.",
            tip: "if, for, def, fn, return. Bright magenta is what most terminal themes reserve for keywords.",
            val: "#C838C6"
        },
        {
            label: "string",
            prop: "ansiGreen",
            group: "Syntax",
            tip: "Quoted text, in every language the highlighter knows.",
            val: "#48D148"
        },
        {
            label: "number",
            prop: "ansiYellow",
            group: "Syntax",
            tip: "Numeric literals, and the true/false/null constants that behave like them.",
            val: "#FF6D12"
        },
        {
            label: "function",
            prop: "ansiBlue",
            group: "Syntax",
            tip: "A name immediately followed by an opening bracket -- the closest a regex lexer gets to knowing what a call is.",
            val: "#4D91F8"
        },
        {
            label: "type",
            prop: "ansiCyan",
            group: "Syntax",
            tip: "Type names, and a shell command in the first position of a line.",
            val: "#00D6DE"
        }
    ]
}
