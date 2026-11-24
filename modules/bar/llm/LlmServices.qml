pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/auth"
import "../../common/config/ConfigCheck.js" as Check
import "../../common/config/ConfigSpecs.js" as Specs
import "components"
import "components/LlmServerUrl.js" as ServerUrl

// =============================================================================
// LlmServices.qml -- the LLM chat's services, built ONCE for the shell.
//
// The engine builds a popup's content on open and destroys it on close, and a generation, the conversations and
// the tool jobs must outlive that: an answer lives in the object that drains its stream (LlmService's header), a
// tool keeps running with the popup shut, and a confirmation nobody answered has to reach the user as a
// notification. So they live here, beside the bar side's owner, in the arrangement mockups/llm.qml declares
// beside its LlmPopup -- in the mockup's order:
//
//   backend     LlmBackend (the real server) or LlmMockRun (no network at all), by `live`
//   store       LlmStore         the conversations; its sidecars (.ctx / .tools / .prefs) follow `storePath`'s name
//   tools       LlmTools         the registry, the grants, the runner, the sudo askpass pair
//   attention   LlmAttention     "come back": the confirmation nobody answered, the answer that finished unseen
//   service     LlmService       the turn, the titles, the residency; the popup binds to this and nothing else
//   machine     LlmMachine       what a loaded model asks of the machine: the dGPU through the shell's ONE OllamaGpu
//                                (`gpu`, shared with the wiki) and a Balanced FLOOR on the CPU profile (PowerBus), for as long as
//                                a model is loaded; the service's first request of a turn waits for the card (its `sendGate`)
//   residency   LlmResidency     the chat put away when nobody looks, and how long its model stays (llm.jsonc "unloadAfterMin")
//
// THE HOST'S INPUTS (ShellServices; every one has a safe default, so a host that sets none of them gets a bundle
// that touches nothing real):
//   live            false (the default) = LlmMockRun: a canned answer, no network. The live shell says true.
//   settings        llm.jsonc (LlmConfig.settings, every key there); unset, the file's defaults.
//   baseUrl, protocol   the server, "http://localhost:11434" and "ollama" (llm.jsonc "server" as the shell started). A probe points
//                   them at a stub server. `remote`: it is not this machine's, and then nothing is done to this machine for the chat:
//                   no card (LlmMachine gets no `gpu`), no CPU floor, no reading of this machine's card (LlmService.ownCard).
//   maxConversations    the store's limit (as the shell started).
//   storePath       the conversation file: $XDG_STATE_HOME/lares/llm/conversations.json when live, and the MOCK
//                   chat's own mock_conversations.json beside it when not, so a bundle that was never told it is
//                   live cannot reach the real history whatever the host forgot to pass. The shell passes llm.jsonc's
//                   store (conversations.json); a mock shell a private one.
//   model           the model new turns start on, read ONCE at creation. The service itself moves it to the
//                   store's default-model preference as soon as the server's list lands (LlmService, "A DEFAULT
//                   MODEL IS A PREFERENCE"), and every switch the user makes writes the property from then on, so
//                   it is the service's, not this bundle's: this one is only where it starts. In the mock it is the
//                   mock's first model (the mock offers other names than the server).
//   broker, howdyMode, howdyTimeoutMs   where sudo's password is asked (the shell's AuthBroker, whose toast draws the
//                   face line from the shared HowdyConfig). With no broker a sudo request is refused with a note.
//   gpu             the shell's OllamaGpu (modules/common/system; null = the card is not ours to drive, the gate is always open
//                   and only the profile floor works). A host that runs the machine builds it `live`.
//   attended        the host writes the OR of every screen's owner `sharedFlags.attended`: a popup of the chat is
//                   showing somewhere. LlmAttention posts nothing while it is true.
//
// NOTHING HERE TOUCHES THE GPU. A service that ran `nvidia-smi` the moment it was built would wake the discrete GPU
// on every shell start (it stays up 20-60 s) for a chat nobody has opened, and the shell builds its services at
// login. The service is declared with `probeGpuAtStart: false`: the card is read by the first thing that needs
// it -- the model picker opening, a finished answer, the context tuner. Nothing here contacts the server either:
// the model list is fetched when a popup first shows.
//
// Declare it under an Item or a Scope; a probe hosts it in a window.
// =============================================================================
Item {
    id: bundle

    // ---- the host's inputs ----------------------------------------------------------------------------------
    property bool live: false
    property string baseUrl: "http://localhost:11434"
    property string protocol: "ollama"
    property var settings: Check.defaults(Specs.specOf("llm"))
    property int maxConversations: 200
    readonly property string serverUrl: ServerUrl.clean(bundle.baseUrl)
    readonly property bool remote: bundle.live && !ServerUrl.isLocal(bundle.baseUrl, hostName.text())
    readonly property string _stateDir: (Quickshell.env("XDG_STATE_HOME") || ((Quickshell.env("HOME") || "") + "/.local/state")) + "/lares/llm"
    property string storePath: bundle._stateDir + (bundle.live ? "/conversations.json" : "/mock_conversations.json")
    property string model: "gemma4:e2b"
    property var broker: AuthBus.broker
    property string howdyMode: "absent"
    property int howdyTimeoutMs: 4000
    property bool attended: false
    property var gpu: null

    // ---- what it holds ------------------------------------------------------------------------------------------
    readonly property var backend: bundle.live ? liveBackend : mockBackend
    readonly property alias store: theStore
    readonly property alias tools: theTools
    readonly property alias attention: theAttention
    readonly property alias service: theService
    readonly property alias machine: theMachine
    readonly property alias residency: theResidency

    // This machine's name: a server under it is this machine's.
    FileView {
        id: hostName
        path: "/etc/hostname"
        blockLoading: true
        printErrors: false
        watchChanges: false
    }

    LlmBackend {
        id: liveBackend
        baseUrl: bundle.serverUrl
        protocol: bundle.protocol
        think: bundle.settings.think
        // The net under a crash is never shorter than what the model stays by itself (LlmResidency).
        keepAlive: bundle.settings.unloadAfterMin < 0 ? "-1m" : Math.max(10, Math.ceil(bundle.settings.unloadAfterMin) + 1) + "m"
    }

    LlmMockRun {
        id: mockBackend
    }

    LlmStore {
        id: theStore
        path: bundle.storePath
        maxConversations: bundle.maxConversations
    }

    // The registry and the "come back" seam sit beside the service because a tool keeps running with the popup
    // closed. `attended` is the host's: the OR of the screens' popups.
    LlmTools {
        id: theTools
        store: theStore
        broker: bundle.broker
        howdyMode: bundle.howdyMode
        howdyTimeoutMs: bundle.howdyTimeoutMs
        offNames: bundle.settings.tools.off
        askNames: bundle.settings.tools.ask
        voiceAutoRun: bundle.settings.voice.autoRun
        // what the tool says by itself (SEARXNG_URL, its own number) stands until the file says otherwise
        toolEnv: bundle.settings.tools.searchUrl === bundle._fileDefaults.tools.searchUrl ? ({})
            : ({ web_search: { SEARXNG_URL: bundle.settings.tools.searchUrl } })
        argDefaults: bundle.settings.tools.searchResults === bundle._fileDefaults.tools.searchResults ? ({})
            : ({ web_search: { count: bundle.settings.tools.searchResults } })
    }
    readonly property var _fileDefaults: Check.defaults(Specs.specOf("llm"))

    LlmAttention {
        id: theAttention
        service: theService
        attended: bundle.attended
    }

    LlmMachine {
        id: theMachine
        service: theService
        gpu: bundle.remote ? null : bundle.gpu
        floorEnabled: !bundle.remote && bundle.settings.machine.cpuFloor !== "none"
    }

    LlmResidency {
        id: theResidency
        service: theService
        attended: bundle.attended
        afterMin: bundle.settings.unloadAfterMin
    }

    LlmService {
        id: theService
        backend: bundle.backend
        sendGate: theMachine
        store: theStore
        tools: theTools
        // Where the model starts, read once: `switchModel` writes this property, and the first write ends the binding,
        // which is the hand-over this wants (the mockup declares a literal for the same reason). In the mock the
        // server's names are not on offer.
        model: bundle.live || mockBackend.models.length === 0 ? bundle.model : mockBackend.models[0].id
        // A LITERAL, never a binding: the service reads it while it is built (LlmService.probeGpuAtStart).
        probeGpuAtStart: false
        ownCard: !bundle.remote
        systemPrompt: bundle.settings.systemPrompt
        modelTitles: bundle.settings.titles === "model"
        ctxDefault: bundle.settings.context["default"]
        ctxQualityCap: bundle.settings.context.autoMax
        ctxReserveMiB: bundle.settings.context.vramReserveMiB
        toolRoundsMax: bundle.settings.tools.rounds
        toolCallsPerRoundMax: bundle.settings.tools.callsPerRound
        voiceModel: bundle.settings.voice.model
        voiceCopy: bundle.settings.voice.copy
        voiceConfirmDropMs: Math.round(bundle.settings.voice.dropMin * 60000)
    }

    // The wrench as the shell starts; from then on it is where the user left it.
    Component.onCompleted: {
        if (bundle.settings.tools.on)
            theService.toolsEnabled = true;
    }
}
