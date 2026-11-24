pragma ComponentBehavior: Bound

import "../../common/config"
import "../../common/config/ConfigSpecs.js" as Specs

// =============================================================================
// LlmConfig.qml -- the user's llm.jsonc, READ HOT through its spec (.examples/llm.jsonc documents every key; specs/llm.js has their types,
// ranges and defaults; JsonConfig the rest): `settings` has every key, right from the first turn.
//
// LlmServices takes what the chat does with them, LlmBarOwner the bar side's. `store`, `server` and `maxConversations` are what the file said
// as the shell started (ShellServices holds them: their stores and requests are not re-pointed).
// =============================================================================
JsonConfig {
    name: "llm"
    spec: Specs.specOf("llm")
}
