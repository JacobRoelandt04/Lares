# llm -- the chat with a local language model

## What it is
A chat popup for the models that run on this machine through Ollama: history on the left, the open conversation in the middle, the composer
under it, in the shell's carved and raised material. It answers in markdown (code, tables, math), can read files and pictures, and can use
tools (run a command, read a file, take a screenshot...) after asking. The answer lives outside the popup, so it goes on while the popup is
shut, and a notification says when it is done.

## Where it lives
- Bar: the left island of the top bar, module id `llm` (after `notes`). The button is a four-pointed star, one shape: the muted ink with no
  model in memory and its own colour (magenta) while a model sits in memory; the ink is the accent while an answer streams, a tool runs or a spoken ask waits for its turn, the warn colour while a confirmation waits or
  an answer finished with no chat open, and muted otherwise.
- Popup: 900 x 640 design px with the history open (the history takes its room from the popup, so shut it is narrower), drawn at
  `scale.popups.llm` of `shell.jsonc` (1.1 by default). It opens out of the left slim bar, under the left island; the outlet is
  `outlets.llm` in `shell.jsonc` (`{ "bar": "left", "along": 0 }`). The popup asks the engine for the keyboard.
- No shortcut and no IPC verb of its own. The notes module's "Send to LLM" (right click on a note) opens the chat on a new conversation with
  the note attached. A SPOKEN ask (the dictation's Alt+fn+F10, wave B) comes in through `LlmService.voiceAsk` (below, "Spoken asks") and
  runs in the background: no popup opens.
- The star's flourish: hover the star (once per entry, after the pointer moves) and THE SPARK KINDLES. It winds back and pulls in, then
  lets go: a quarter turn forward (four points, so it lands on itself) with its points drawn out long and thin, and two small stars are
  flung out of it along the diagonals, one up to the right and a smaller one down to the left -- for a moment the icon is the three-star
  cluster everyone draws for this, made out of the one star -- which hang, turn the other way and wink out. No shimmer and no second
  object. About 0.9 s, in whatever colour the star has. It is decorative, so the OLED care's random flourishes play it too: group `llm`
  (`oled.flourishes.glyphs` in shell.jsonc, `"llm": false` takes it out).

## What you can do
- Top row: the burger folds the history to nothing and back; the pin keeps the model loaded after the popup closes (an answer that is
  streaming is never cut either way); the incognito switch (offered only on an empty conversation; afterwards the title row's faint count slot reads "Incognito") makes a chat that never touches the
  disk; "New chat".
- History: search, and conversations grouped Favorites / Today / Yesterday / Previous 7 days / Older (each group folds). A row can be
  starred (the star flies the row to the Favorites shelf), renamed or deleted (a Yes / No in the row); the marks show on hover.
- Conversation: every answer is a section with a title and a category the model gave it (code, system, explain, write, data, other), each
  with its own colour in the header's inset and its own topic icon; a click on the header folds it, a button in the title row folds or
  unfolds them all, so a long conversation scans as a list of questions. An answer has a thinking drawer (for models that think), and
  copy, regenerate, edit and delete under it. Code blocks wrap and have a copy button; tables and math render in place.
- Composer: a field that grows with the text; attach files with the button, by drag and drop onto the popup, or by sending a note;
  pictures, text files, PDFs and videos (four frames ride as pictures) become chips, and a chip's menu sets how much of a PDF is sent
  (pages, images, the smallest image kept). Audio is refused with a reason. Messages sent while the model is busy wait in a queue strip
  above the composer: a click takes one back, a right click moves it to the front, the cross removes it.
- Model pill beside send: lists the installed models with dots for vision, tool calling (proven by a probe) and thinking, a VRAM bar
  for what the model holds right now, and a tip on what each model is for. A right click on a loaded row's bar unloads it. The open list
  also sets the context size: Manual (a figure) or Auto (tuned by a measurement against the card).
- Tools: the wrench in the composer turns tools on and off (inert and faint for a model that cannot call tools). An acting tool call opens
  a confirmation inside the composer showing the exact command, path or content that will run: "Run" (Return or Y), "Don't run" (Escape
  or N) and "Always allow <rule>" where a rule can be written. A right click on the wrench lists the remembered allowances, each with its
  cross, and "Revoke all". Reading tools run without asking. `sudo` always asks: the camera first, then the password in the shell's
  authentication toast; the chat never holds the password.
- Stop kills the request, so the server stops generating at once.

## Spoken asks
Say something and the model acts on it without a click: "what is the latest commit abbreviation" gives the hash, on the clipboard, about as
fast as the model answers.
- The contract (fixed; the dictation module calls it): `LlmService.voiceAsk(text: string, context: var): void`, `context = { windowClass,
  windowTitle, cwd }`, any of them "". It starts a NEW conversation titled from the words, queued ahead of typed messages that wait (spoken
  asks in the order they were spoken), and asks the server for its models itself when they are not described yet. It is SILENT (the user,
  2026-11-13: "silent and running in the background"): no popup opens, the new conversation is NOT made the active one, and a chat that is
  open keeps showing what it showed (the queue runs by conversation id; the popup's queue strip lists the ask as "in <title>"). How you
  know it was heard and what came of it: the bar star turns the accent from the moment the ask is queued until its turn ends, and at the end
  ONE toast per ask (below) comes. Stop in an open chat ends the spoken turn too (one generating state for the whole service).
- The turn is HANDS-FREE. Tools ride whenever the model can call them, wrench or not (the model decides; there is no router). The
  conversation carries a short system note: that it was spoken, the window that was in front (as data), and "Commands run in <cwd>"; every
  tool of that conversation runs in that directory (the home directory when it is gone), relative paths included.
- What runs without a click: a `run_command` that is ONE plain command from `git ls cat head tail wc grep date pwd which df du uname stat
  file` -- plain ASCII, none of `; & | $ ( ) < > \` or a backtick anywhere, no unquoted glob or brace, no `NAME=value` before it, a `~` only as
  `~` or `~/...`; git only with `log status show diff rev-parse describe blame`, `branch` listing, `remote -v`, never `-c`, `-C`, `--output`,
  `--ext-diff`, `--textconv`, `--show-signature` or a `%G` format; never `tail -f`, `date -s`/`-f`, `file -C`, `grep -R`; and no path into a
  secret store (`~/.ssh`, `~/.gnupg`, `.env` files, keyrings, password stores, `/etc/shadow`, browser profiles, cloud credentials, the
  shell's own state), as written or through a link. It runs as the exact argv that was judged, never through bash, and git with every
  setting a repository could use to run a program switched off. The reading tools run free except into a secret store (and a search below
  one), the clipboard and the screen; a web search runs free only until the turn has read anything from the machine. EVERYTHING ELSE waits
  for the user's OK, with no "Always allow" offered and no remembered rule applied (those are the typed chat's).
- The OK is given from a toast, with no chat open: a sticky toast "Run this command?" shows the exact command, the folder it runs in and why
  it asks, with Run / Deny / Open chat. Run and Deny are the chat panel's own answers (`answerConfirm`); nothing runs without the click; a
  toast whose ask is gone (answered in the chat, the turn ended) does nothing and says "Already answered"; an answer anywhere withdraws it.
  A command longer than one short line is offered only Deny and Open chat (the toast never asks for a Run the user cannot read whole). A chat
  that is open on ANOTHER conversation shows no Run for it (Return or Y would answer a command the user never saw): the toast carries it.
  An approval nobody answers in 10 minutes (`LlmService.voiceConfirmDropMs`) drops the ask, says so in its toast and lets the model go.
  Typed chats keep the old rule: no Run in a notification, only a Show after 15 s.
- ONE ANSWER TOAST PER ASK, normal timeout, kept in the manager: the first four lines of the answer, "Open chat" opens THAT conversation (with
  the keyboard). An answer that is one code block, one command line or one short value is also put on the clipboard (a private conversation's
  marked sensitive, so the clipboard history keeps none), and the same toast then says "Copied" with the value. A turn that ends with no answer
  says why in the same one toast (the server's reason, or the drop); a Stop pressed in a chat posts none. A spoken answer is not latched on
  the star as "unseen" and posts no generic "answer ready" notice. Typed chats work exactly as before.
- THE MODEL GOES WITH THE ASK: when the turn ends and no chat is open on any screen the model is released (`LlmResidency`; a typed chat's may stay,
  `unloadAfterMin`), so the dGPU and the Balanced CPU floor follow after `LlmMachine`'s 5 s linger; a pending approval keeps the model until it is
  answered or dropped, and a message waiting in the queue holds the release until its own turn ends.

## What it shows and where the data comes from
| Part | Source |
|---|---|
| Models, capabilities, what is loaded, VRAM | Ollama's HTTP API on `llm.jsonc` `server.url` (`/api/tags`, `/api/show`, `/api/ps`); the wire is `ollama` NDJSON or an OpenAI-compatible SSE one (`server.protocol`). No key is read or sent. A server that is not this machine's (its host is not localhost, a loopback address or this machine's name) leaves this machine's card and CPU alone, and no VRAM is shown |
| Answers, titles, categories | one `curl` child per request that may be abandoned (killing it closes the socket, which ends the request on the server); Qt's XHR for the short reads |
| Conversations | one JSON file, `~/.local/state/lares/llm/<store>` (incognito chats are never written); the allowances in `<store minus .json>.tools.json`, the context sizes in `.ctx.json`, preferences in `.prefs.json` |
| Attachments | `pdftotext`, `pdfinfo`, `ffmpeg`, `ffprobe` and `cat`, one at a time |
| Tools | the files of `llm_tools/` (below) |
| Math | `tools/llm/mathrender.py`, a worker that renders LaTeX to a transparent mask the theme tints |
| The card and the CPU | the shell's one `OllamaGpu` (the dGPU for as long as a model is loaded) and a Balanced floor on the CPU profile through `PowerBus` (silicon) |
A turn waits for the card to be ready so the weights load onto the GPU the first time; if the model still runs on the CPU with the card up,
ollama is restarted once and the model loaded again. When the server is down the model list says so and sending is refused with the reason.
Closing the last popup of the chat puts an empty conversation away and, unless the session is pinned or an answer is streaming, lets the
model go; an answer that finishes with no chat open posts a notice with an Open button, and a confirmation nobody answered for 15 s posts a
sticky one.
`llm_tools/tools.json` defines `run_command` (asks; the rule is `program verb` per simple command), `search_files`, `read_file`,
`clipboard_read`, `clipboard_write`, `screenshot`, `fetch_url` (asks once per host), `notify`, `write_file` (asks per directory),
`calculator` and `web_search` (the local SearXNG at `127.0.0.1:8888`); `system.json` and `hyprctl.json` are families of fixed actions
(kernel, disks, memory, packages, battery, volume, media; windows and workspaces of Hyprland); `policy.json` holds the patterns that
always ask or never run and the places a grant can never write (`~/.ssh`, `~/.gnupg`, `~/.password-store`, this config's tools,
the shell's state).

## Settings
`~/.config/quickshell/config/llm.jsonc` (template `.examples/llm.jsonc`; read hot, the three marked * as the shell starts):

| Key | Default | What it is |
|---|---|---|
| `store` * | `conversations.json` | the conversation file in `~/.local/state/lares/llm/`, a plain `<name>.json` |
| `notePrompt` | `""` | text put in the composer, selected, when a note is sent to the chat |
| `systemPrompt` | `""` | told to the model at the start of every chat |
| `server.url`, `server.protocol` * | localhost:11434, `ollama` | the server (`ollama` or `openai`) |
| `unloadAfterMin` | 0 | minutes a typed chat's model stays after the chat is shut (-1: until unloaded by hand; Ollama's own keep-alive is never shorter) |
| `think` | true | whether a model that can think does, or per model `{ "qwen3:8b": false }` |
| `context.default` | 4096 | tokens for a model not tuned in the picker, or `auto` (measured after its first typed answer) |
| `context.autoMax`, `vramReserveMiB` | 32768, 768 | `auto`'s cap for a small model, and the card's memory it leaves free; a tuned value they could have bound is measured again |
| `tools.on` | false | the wrench at the shell's start |
| `tools.off`, `tools.ask` | `[]` | tools never offered, and tools that ask every time (stricter only: a refusal stands, no rule is offered; spoken asks too) |
| `tools.rounds`, `callsPerRound` | 12, 8 | the tool loop's limits |
| `tools.searchUrl`, `searchResults` | 127.0.0.1:8888, 8 | the SearXNG of `web_search` (its own `SEARXNG_URL` until the file says otherwise), and how many results when the model names no number |
| `history` | `session` | the list of conversations when the chat opens: as it was left this session, `closed`, `open` |
| `titles` | `model` | who titles an answer: the model, or the question's `words` |
| `maxConversations` * | 200 | past it the oldest unpinned conversation goes |
| `attachFrom` | `~` | where the file chooser opens first |
| `voice.model`, `copy`, `autoRun`, `dropMin` | `""`, true, true, 10 | a spoken ask's model (let go of with it), its answer on the clipboard, its read-only commands unasked, its unanswered approval's life |
| `machine.cpuFloor` | `balanced` | the CPU profile held while a model is loaded, or `none` |

The tools themselves are data: `llm_tools/*.json` (hot reloaded; a bad entry is dropped and named in the log).
The popup's size is `scale.popups.llm`; its look (fonts, sizes, the sweep and fold motion, the picker) is tuned in `mockups/llm.qml`
(`quickshell -p ~/.config/quickshell/mockups/llm.qml`; Save writes the module), whose Run tab replays a captured stream or runs a canned
mock with no network.

## How it is built
| Path | Role |
|---|---|
| `modules/bar/llm/parts/SparklePose.js`, `SparkleParts.js` | the star's flourish as a pure function of its clock (the numbers are `DEFAULTS` at its top); the font's outline, generated by `tools/dev/flourish_parts.py` |
| `modules/bar/llm/LlmBarButton.qml`, `LlmBarOwner.qml` | the star; the bar-side owner (opens the popup, the file chooser through the desktop portal, Send to LLM, hover build) |
| `modules/bar/llm/LlmServices.qml`, `LlmConfig.qml` | everything that outlives the popup, once per shell (backend, store, tools, attention, service, machine, residency); the `llm.jsonc` reader |
| `components/LlmService.qml` | the conversation: what is sent, kept and shown, titles and categories, the queue, residency, the context budget |
| `components/LlmBackend.qml`, `CurlRequest.qml` | the one place that knows the wire; one killable curl per request |
| `components/LlmStore.qml`, `LlmMachine.qml`, `LlmResidency.qml`, `LlmServerUrl.js`, `LlmAttention.qml` | the conversations on disk; the card and the CPU floor; the chat put away and how long its model stays; whose machine the server is; the "come back" notices, and a spoken ask's toasts (its answer, its approval) |
| `components/LlmTools.qml`, `LlmToolPolicy.js`, `LlmShell.js` | the registry, the grants and the runner (one job at a time, in its own systemd scope); the pure rules; how a command line is read |
| `components/LlmVoicePolicy.js`, `llm_tools/voicepaths.py` | a spoken turn's rules (the hands-free list, the secret stores, the taint, what is copied); the preflight that resolves its directory and paths on disk |
| `components/LlmPopup.qml` and `LlmSidebar`, `LlmTranscript`, `LlmTurn`, `LlmToolBlock`, `LlmComposer`, `LlmModelPicker`, `LlmConfirmPanel`, `LlmGrantsMenu`, `LlmPdfMenu`, `LlmQueueStrip` | the popup and its parts |
| `components/MarkdownView.qml`, `CodeBlock.qml`, `MathOverlays.qml`, `MathInk.qml` | the renderer (streams in O(tail), blocks freeze when final) |
| `components/LlmAttachmentLoader.qml`, `LlmAttachmentChip.qml`, `LlmPathCompleter.qml` | attachments and path completion |
| `components/LlmModelNotes.qml`, `LlmModelLogos.qml`, `LlmTopicIcons.qml` | what each model is for, the logos, the topic icons |
| `components/LlmMockRun.qml` | the backend's twin with no network |
| `llm_tools/`, `tools/llm/mathrender.py` | the tool data, the askpass helper and the `sudo` shim; the math worker |
Shared parts used (`modules/common/components`): `ShadowBox`, `RaisedButton`, `ListSectionHeader`, `AnimatedListRow`, `SkeletonBar`,
`RowFlight` (the favourite's flight), `ScrollDressing`, `HoverTip`, `FileDropOverlay`, `TabSelector`; `OllamaGpu` (`modules/common/system`)
and `PowerBus` (`modules/common/power`) for the machine; `NotificationBus` (`modules/common/notify`) for the notices; the shell's
`AuthBroker` for sudo. The chat's service bundle is built once per shell and shared by every screen's owner.

## Limits
- Ollama does not stream a tool call: it buffers the whole call and delivers it in one piece, so a model writing a long script shows no
  bytes for as long as it takes. The chat shows the time since the last byte and invents no token count.
- Ollama has no image generation here; audio attachments are refused because the wire drops them; a video rides as a few frames.
- Ollama abandons a request only when the connection closes, which is why every request that may be abandoned is a curl child.
- Models with no embedding head get documents stuffed into the context rather than retrieved; the context is budgeted in tokens, newest
  first, and every picture that does not ride is named in the message.
- `web_search` needs a SearXNG instance whose JSON format is enabled; without one the tool says so.
- The `pkexec` of a command asks through the desktop's polkit agent, not the chat; a command that names `/usr/bin/sudo` in full skips the
  shim and may reuse one authentication within that call.
- The conversation file is bounded in bytes: past the cap, old pictures are dropped from disk (their chips keep a preview) and re-attaching
  the file brings them back.

## How to change it
- Where the chat opens, or its size: `outlets.llm` and `scale.popups.llm` in `shell.jsonc`.
- A tool's wording, timeout or whether it asks: its entry in `llm_tools/tools.json` (`kind` `read` runs freely, `act` asks; `allow` is the
  grant's unit); a new fixed action: `system.json` or `hyprctl.json`; what always asks: `policy.json`.
- Which model new chats start on: the picker's right click; the server: `llm.jsonc` `server`.
- The categories and their colours: `LlmService.qml` (the schema) and `LlmTurn.qml`; the model tips: `LlmModelNotes.qml`.
- A look value: `mockups/llm.qml`'s tabs, then Save.
- What a spoken ask may run unasked: `PROGRAMS`, `GIT_VERBS` and the secret lists in `components/LlmVoicePolicy.js` -- a security boundary,
  so a change starts in the case table.
Gate: `tools/dev/smoke.sh mockups/llm.qml`, then `tools/dev/smoke.sh shell.qml`. After a change to a spoken ask, the tools' rules or what `llm.jsonc` does:
`node tools/dev/llm_voice_cases.js` (`--arms`), `tools/dev/llm_voice_probe.sh` (a stub ollama; the glyph, the toasts, the approvals, the release; `ARM=all`) and
`tools/dev/llm_voice_env_probe.sh` (the real shell in lock_env: a spoken ask opens no popup and moves no open chat, the compositor sees no keyboard request).
