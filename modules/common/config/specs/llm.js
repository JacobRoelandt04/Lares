.pragma library

// The spec of config/llm.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/llm.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    store: ["text", "conversations.json", { re: "^[A-Za-z0-9_][A-Za-z0-9_.-]*\\.json$", like: "conversations.json", start: true }],
    notePrompt: ["text", ""],
    systemPrompt: ["text", ""],
    server: {
        url: ["text", "http://localhost:11434", { re: "^https?://", like: "http://localhost:11434", start: true }],
        protocol: ["word", "ollama", ["ollama", "openai"], { start: true }]
    },
    unloadAfterMin: ["num", 0, -1, 1440],
    think: ["either", true, ["bool", undefined], ["map", undefined, ["bool", undefined]]],
    context: {
        "default": ["either", 4096, ["word", undefined, ["auto"]], ["int", undefined, 512, 1048576]],
        autoMax: ["int", 32768, 4096, 1048576],
        vramReserveMiB: ["int", 768, 768, 65536]
    },
    tools: {
        on: ["bool", false],
        off: ["list", [], ["text", undefined]],
        ask: ["list", [], ["text", undefined]],
        rounds: ["int", 12, 1, 40],
        callsPerRound: ["int", 8, 1, 32],
        searchUrl: ["text", "http://127.0.0.1:8888", { re: "^https?://", like: "http://127.0.0.1:8888" }],
        searchResults: ["int", 8, 1, 20]
    },
    history: ["word", "session", ["session", "closed", "open"]],
    titles: ["word", "model", ["model", "words"]],
    maxConversations: ["int", 200, 1, 10000, { start: true }],
    attachFrom: ["path", "~"],
    voice: { model: ["text", ""], copy: ["bool", true], autoRun: ["bool", true], dropMin: ["num", 10, 1, 240] },
    machine: { cpuFloor: ["word", "balanced", ["balanced", "none"]] }
};
