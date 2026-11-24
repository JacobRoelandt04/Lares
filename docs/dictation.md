# Dictation

## What it is

Speech to text, on this laptop, into whatever text field has the keyboard. Press fn+F10 (the microphone key) and speak: the words of the
sentence you are saying appear underlined in the field and correct themselves as you go; a pause writes the sentence for good. Press
again to stop. English or Dutch, one language per take, detected from your first words (Shift+fn+F10 forces Dutch). Fillers ("uh",
"um") are never written, and a pause right after one is thinking, not the end of the sentence. With the NVIDIA card on the bus (Hybrid
or Smart mode) a take runs there; otherwise on the Arc iGPU. The tidy pass (off) removes false starts, repeats and stutters. Two more
keys (round 5): Ctrl+fn+F10 transcribes the sound of the focused window (a video, a call) onto the clipboard, and Alt+fn+F10 asks the
local model a spoken question. A PROTOTYPE, OFF until `shell.jsonc` says `"dictation": { "enabled": true }`. The research and the design behind it:
`docs/agent_added_files_and_folders/stt/research.md` (the bench's numbers are its section 11).

## Where it lives

- `modules/dictation/DictationService.qml` -- ONE per shell (`ShellServices.dictation`): the take, where the text goes, the mic, the aura,
  the take log. `DictationShortcuts.qml` -- the four global shortcuts. `DictationText.js` -- the config's defaults and the pure rules.
- `modules/osd/kinds/OsdCaption.qml` -- the caption card of a window take and a voice ask: the OSD's kind `caption` (round 5), so it
  hangs from the bar beside your popups; `OsdStyle.qml`'s `caption*` numbers size it.
- `tools/stt/lares_stt.py` -- the speech helper, a supervised child of the shell in a private Python (`~/.local/share/lares/stt/venv`),
  running light (no model) whenever the switch is on: the microphone (`pw-record`, stream `lares-dictation`), the VAD, the model,
  the language, the revision policy. `tools/stt/sttlib/` holds
  its parts: `policy.py` (the revision policy, the fillers and thinking-pause rules), `fillers.py`, `decoders.py` (the models, the device
  per take), `devguard.py` (round 8: a decoder that falls to the CPU when its GPU raises), `tidy.py` (the tidy pass and its guard), `stubs.py` (the probe's stand-in decoder, only with `LARES_STT_STUBS=1`),
  `sources.py` (round 5: which processes are the focused window's, the streams of a window take, the cwd under a terminal). Models and
  test clips in `~/.cache/lares-stt/`.
- `tools/stt/ime/lares-ime.c` -- the input method (`zwp_input_method_v2`) that puts the words into the focused field; started per take, so no
  app sees an input method unless you are dictating. Built into `~/.cache/lares-stt/bin/lares-ime`, never into the repo -- and never by
  a deploy: after a change to it run `tools/stt/ime/build.sh` once (the shell says so when the binary is older than its source:
  `ready` carries its protocol version).
- `tools/stt/setup.sh` -- the one-time setup (venv, packages, the picked model, lares-ime). `tools/stt/fetch.py` -- downloads; `fetch.py remove`
  deletes a model. `tools/stt/bench.py` + `tools/dev/stt_bench.sh` -- the bench (`--dgpu` for the NVIDIA card); `tools/stt/tidy_cases.tsv`
  -- the tidy pass's test sentences.
- The keys: `tools/shell/lares` BINDS_TABLE (`XF86Launch5` -> `lares:dictate`, `SHIFT + XF86Launch5` -> `lares:dictate-nl`,
  `CTRL + XF86Launch5` -> `lares:dictate-source`, `ALT + XF86Launch5` -> `lares:dictate-ask`); `lares deploy` writes them
  into keybinds.lua's keys block.

## What you can do

- **fn+F10**: start. The microphone listens from the press (within ~0.1 s: the helper is already running, light); a muted microphone is
  unmuted (one at 0 % is raised to its last volume). With `"shadow": { "aura": true }` the aura's smaller half -- the centre island --
  fades in at once: listening, the model still loading; the whole aura comes the moment words can appear. Speak at once: what you say
  while the model loads is written when it is up. **fn+F10** again: the last sentence is finished and written, the mic is put back as
  it was, the aura fades out. A take stopped before the model is up is written when it is (or goes to the clipboard).
- **Ctrl+fn+F10** (round 5): transcribe the sound of the window that has the focus when you press it -- a video in the browser, a call,
  a player in a terminal. Nothing of yours is heard: the microphone is not touched and there is no aura. A caption card hangs from the
  bar (where the OSD comes out) with the last lines of what is said, the sentence being spoken muted after them; it says when the
  window has made no sound yet and keeps waiting (a video you start after the press is heard from its first word). **Ctrl+fn+F10**
  again (or any dictation key): the card goes and the whole transcript is on the clipboard, with a toast "Transcript copied". Whatever
  the window plays from its own processes is heard (a browser plays from a child process); no other app's sound ever is.
- **Alt+fn+F10** (round 5): ask the local model. Speak a question ("what is the latest commit abbreviation"); the mic, its mute and the
  aura as in a normal take, the caption card shows what it hears. When you have finished -- 2.5 s after your last sentence was written
  (`askEndMs`), or the key again -- the question goes to the LLM chat, which opens on the focused screen without taking the keyboard
  and answers it hands-free (`docs/llm.md`, "Spoken asks"), with the window you were in as context and, when that window is a
  terminal, the directory of its shell (commands run there). Nothing is typed and nothing is copied by the dictation; a take with no
  words asks nothing (a toast says so), and so does one that ends any other way than cleanly.
- **Shift+fn+F10**: the same in Dutch, no detection. Without it the language is detected from the first ~1.5 s of speech; until then the
  words come in the language of the last take, and a take that turns out to be the other language is heard again in the right one
  (a correction like any other).
- Where the words go: the shell's own fields first -- the notes editor and the LLM prompt, when the popup they are in has the caret
  (round 6: the words go there, never to the app under the popup) --, else the focused text field of any app that speaks Wayland's
  text input (GTK, Qt, Firefox / Zen, Chromium, kitty). A password or other secret field takes nothing; a terminal never gets a
  newline. With no text field focused the text of the take is on the clipboard when you stop, with a toast. An Xwayland app listed
  in `typeInto` gets the final text typed.
- A take can never get stuck (round 6): a speech helper that does not answer the press within 8 s, or does not finish the take 6 s
  after you stop it, is started again and the take ends (a toast says so; the shell log says what it was doing). A press while a
  take is finishing ends it at once once 2 s have passed since the stop.
- **A take ends with its reason, never in silence** (round 8). A GPU that fails in the middle of a take (the iGPU's OpenVINO raising
  `clWaitForEvents -14`, CUDA out of memory) is no end: the helper loads the model on the CPU, hears the same audio again and the take
  goes on, nothing lost; a toast says "The iGPU stopped responding; switched to the CPU, the take goes on", and the later takes of
  that helper run on the CPU until it is started again (at rest). A helper that goes quiet (no beat for 5 s) or whose decode hangs
  (12 s) ends the take with a toast that says so; after a decode that hung on a GPU the next take runs on the CPU. A helper that
  crashes or exits says why in the toast (its last error line, "segmentation fault", "killed, probably for memory"), and the take log
  records it.
- **The final text's rules** (`dictation.text`, all on): "F ten" is written F10, spelled codes ("X nine five Z B three oh nine
  underscore QR ST") one code, X95ZB309_QRST, "greater than sign" >, a take that begins "greater
  than" begins with ">", your own spellings (`words`), your own fillers (`fillers`), a word repeated across an "uh" or a pause once, and a sentence you paused in the
  middle of waits for you (`thinkSilenceMs`) and goes on in lower case. Details under "How it works".
- **Fillers** ("uh", "um", "uhm", "ehm", "er"; Dutch "euh", "ehm", "eh") never reach the field: not in the underlined words, not in the
  written sentence. A pause right after one keeps the sentence open for `thinkSilenceMs` (3 s) instead of ending it after 0.7 s, so
  "I think, uh ... [2 s] ... we should go" is one sentence, without the "uh".
- **The tidy pass** (`"tidy": true`): each sentence's false starts, repeats, stutters and corrected words are removed before it is written
  ("I want to, I want to go home" -> "I want to go home"; "on Thursday, sorry, Friday" -> "on Friday"). A small model proposes, a fixed
  rule check decides: the removals it can name are applied and any other is put back (round 6: "works works rather well" with the
  model dropping "rather" too is written "works rather well"); a word the sentence never had refuses the whole proposal.
  ~0.7 s more per sentence on the CPU.
- Every take is logged (text only, never audio, never a password, pin, hidden or sensitive field) in
  `~/.local/state/lares/dictation/takes.jsonl`, the last `logKeep` (round 6: a file saved without its last newline gets one before the
  next record, and a record finished while one is being written waits for it): the focused window's class at the press (`window`), the device
  (`device`; `X>CPU` when a GPU fell to the CPU mid-take), the take's `mode` (type | source | ask), the timings from the press in ms (`times`: `capture` the helper had the start, `listening` its first samples, `running`
  the model up, `firstWord`), every route in order with its time (`routes`), and per sentence `segs` -- `raw` (what the model wrote),
  `text` (what was written) and `rules` (the text rules that changed it); `pieces` and `heard` as before.
  Round 8 adds what was missing when a take ended early: `helperReason` (the helper's own `ended.reason`: stop | cancel | error), `exit`
  (the helper process ended mid-take: its `code`, `words`, `stderr` last line and the last three), `stall` (why the shell ended it:
  `start` | `stop` | `forced` | `loop` | `silent`, with the beat's `loopMs`), `fallbacks` (each GPU failure: `from`, `to`, `why` in words,
  `detail` the exception's first lines, `ms`), and per sentence `cut` (`pause` | `think` | `hard` | `stop`), `atMs`, `audioMs`, `lang`.
  One record per line, always (the writer ends the file with a newline before it appends).
- The first take after a shell start or a rest (`keepWarmMin`, 10 min) loads the model while it listens: ~5 s on the iGPU (the very
  first after setup ~13 s: the iGPU compiles it once), the tidy model beside it; the small aura says so. `"preload": true` keeps the
  model loaded after the first take.

## Settings (`shell.jsonc` `dictation`, read hot; `.examples/shell.jsonc` documents each)

`enabled` (false), `model` ("auto": the bench's pick), `device` ("auto": the NVIDIA card when it is on the bus, else the iGPU; "cuda",
"gpu" (the iGPU), "cpu"), `tidy` (false), `endSilenceMs` (700), `thinkSilenceMs` (3000), `hopMs` (700), `keepWarmMin` (10), `dgpuKeepMin`
(2), `preload` (false: the model is let go `keepWarmMin` after the last take; true: only a take on the NVIDIA card is), `typeInto` ([]),
`micVolume` (-1: the last volume), `logTakes` (true), `logKeep` (100), `text` (the text rules' object, handed to the helper verbatim: "The
text rules" below), `askEndMs` (2500: a voice ask ends this long after its last sentence; 0 = only the key ends it), and how a take goes:

| Key | Meaning | Default |
|---|---|---|
| `key` | `"toggle"`, or `"hold"`: the plain and the Shift key take while they are held (a release while the take is starting ends it as a stop does; a press while the last one finishes starts the next if the key is still down) | `"toggle"` |
| `endAfterMin` | a take in which nothing was said for this long ends, with a toast; 0 never | 0 |
| `unmute` | a muted mic (or one at 0 %) is unmuted for the take; false: the take does not start and says so | true |
| `aura` | the aura comes with a take | true |
| `copy` | `"fallback"` (what no field took) or `"always"` (the whole text; never of a take a secret field saw) | `"fallback"` |
| `language`, `altLanguage` | the plain key's (`"auto"`, `"en"`, `"nl"`) and the Shift key's | `"auto"`, `"nl"` |

## Setting it up (the user's steps)

1. `tools/stt/setup.sh` (about 10 GB with the iGPU's compiled model: a private Python with onnxruntime's CUDA build and cuDNN, the
   models for the iGPU and the NVIDIA card, the tidy model, lares-ime; no root, nothing system-wide; CUDA's own libraries are Arch's
   `cuda` package, already installed).
2. `lares deploy` (the keys).
3. `"dictation": { "enabled": true }` in `~/.config/quickshell/config/shell.jsonc`.
4. Check on the desktop (only the desktop can prove these): VS Code shows the underlined words (if not: `--enable-wayland-ime` in
   `~/.config/code-flags.conf`); Shift+fn+F10 really arrives as `SHIFT + XF86Launch5` (`wev`); your Flemish is heard well enough (the take log
   shows what was heard).

## How it works

- **The policy** (`sttlib/policy.py`, research 8.4). A sentence is a VAD speech region (Silero, 32 ms frames). While you speak it is decoded
  again from its start every `hopMs` (stretched to 1.5x the last decode when decodes are slow); the words two successive decodes agree on
  are its stable prefix, which only grows; the field shows the stable words and the newest decode's words after them, so any word of the
  sentence may still change. After `endSilenceMs` of silence the sentence is decoded once more and committed: committed text is never
  touched again, so nothing has to be deleted from an app's text.
- **The protocol** between the shell and the helper is JSON lines (research 8.6): `start` (with `text`, shell.jsonc's `dictation.text`) /
  `stop` / `cancel` / `unload` / `quit` / `ping` / `trace` in; `ready`, `capture`, `listening`, `device`, `loading`, `loaded`, `running`,
  `lang`, `hyp` (the whole sentence, idempotent), `seg` (final: `raw`, `text`, `rules`, `cut`), `stats`, `ended`, `error`, `pong`, `trace`,
  and (round 8) `beat` (once a second while a take is live, from a thread of its own: `loopMs`, how long ago the main loop turned, and its
  `phase`), `fallback` (a GPU decode failed, the CPU runs the take: `from`, `to`, `why`, `detail`) out; `error` with `what: "crash"` is an
  exception of the main loop (the take ends `ended` reason `error`, the helper lives on and is started again). The shell and lares-ime speak
  tab-separated lines (`preedit`, `commit`, `type`, `quit` in; `ready`, `rebound`, `activate`, `deactivate`, `content`, `surrounding`,
  `done`, `unavailable` out).
- **The order of a take** (round 5: "nothing said after the press is lost"). The helper runs light whenever the switch is on: it answers
  `ready` before anything heavy is imported (~50 ms), and a `start` starts `pw-record` before anything else (`capture`; the first
  samples: `listening`). numpy, onnxruntime, OpenVINO, the VAD and the models load on the take's loader thread meanwhile -- the tidy
  model on the CPU beside the live one -- and at `running` the policy hears everything since the press on the clock it was said on, so a
  sentence said during the load is written whole. A stop during the load ends the capture at once; its words are written when the
  models are up. `keepWarmMin` after the last take the helper is started again, light. The shell's aura: the island group at the press,
  all of it at `running`.
- **The first take is live** (round 5). Hyprland 0.57.1 sends the input method `activate` only when a text field ENABLES, drops an
  enable made while no input method exists, and a new input method's bind does not enter a field already on the focused window -- one
  entered with no input method around (an app that makes its text input when its window is first focused; or one left behind by a take
  whose focus moved). Such a field never activated the take's input method: the take went to the clipboard, the next one was live.
  lares-ime now binds once more when no `activate` came 200 ms after its `ready` (`rebound`): the destroy leaves the field, the new bind
  enters it, the app enables. With no field it costs one more bind (~1 ms).
- **The script mask** (round 5). Parakeet cannot be told the language and now and then wrote English in Cyrillic ("Эндэ мочул." for "in
  the module"). In an English or Dutch decode every vocabulary token holding a letter of another script (Cyrillic, Greek: 1720 of 8193)
  is masked out of the transducer's greedy decode (`sttlib/decoders.py`; `LARES_STT_SCRIPT_MASK=0` turns it off for a comparison).
- **The text rules** (round 5; `sttlib/textrules.py`, shell.jsonc `dictation.text`, documented in `.examples/shell.jsonc`; a missing key is
  its default, every one on). A final goes through one chain (`textrules.finish`): a repeat across a filler or a held pause said once
  ("X uh X" -> "X": `fillerRepeat`, `pauseRepeat`; a repeat with nothing between is kept), the fillers (`filler`), the tidy pass when on
  (`tidy`), your own spellings (`words`: whole words, any case, `"Hyperland": "Hyprland"`; never for pairs that are both real words),
  F-keys (`fkey`: "F ten", "F one zero", "F one O" -> F10, F1-F24 only; numbers otherwise stay words), "<name> sign" -> the symbol from a
  fixed table (`sign`: "greater than sign" -> >, "at sign" -> @, "hash sign" -> #; the name alone is prose: "greater than expected",
  "at the end"), a take that begins "greater than" begins with ">" (`leadingQuote`: a note header, "> After review"), and a sentence that
  continues one written unfinished begins in lower case (`continue`). Every rule that changed a sentence is named in the seg's `rules`
  and the take log's `segs`.
- **Spelled codes** (round 8, `symbols.codes`, on; rule `code`): letters said one by one, digits (`zero` ... `nine`; Dutch `nul` ...
  `negen`, not "een": the article), figures, the model's letter groups ("QR ST", all capitals, 2-4 letters) and `underscore` / `dash` /
  `hyphen` / `dot` between them make ONE code with the letters in capitals: "X nine five Z B three oh nine underscore QR ST" ->
  `X95ZB309_QRST`. A run needs three pieces that mix letters and digits with a letter said alone, or a connector word and two pieces;
  "oh" / "o" is a zero only beside a digit (across a connector too: "two dot oh"); "A" and "I" at the edge of a run join it only when it
  has four pieces; a lower-case "a" never counts. So plain numbers ("one two three"), a lone letter ("option A or B", "plan B", "the A
  team"), "I have two kids", "COVID nineteen" and "ninety-two C" stay words. The F-key rule keeps "F one zero" (it runs first, rule
  `fkey`); a code's first letter is never lower-cased by `continue`. Cases: `tools/stt/text_cases.tsv` family `code`.
- **The live words are aligned, not indexed** (round 8). The partial the field shows is the stable words plus what the newest decode says
  after them, found by LETTERS (case, punctuation and word breaks blind: `policy.agreed`, `policy.tail_from`) -- a decode that re-splits
  or merges words before the stable end ("good bye" / "goodbye") neither shows a word twice nor freezes the sentence, and the stable
  words never change once shown.
- **Unfinished sentences** (round 5). A pause after words that have not ended a sentence -- no end punctuation, or a word a sentence goes
  on after ("the", "and", "to" ...) -- is thinking like a pause after a filler: the sentence stays open up to `thinkSilenceMs` (not past
  `softCutS`: a long sentence is cut at its next pause). The helper's `think` says why (`filler` | `unfinished`); the take log keeps each
  as `thinks`.
- **The models** (the bench's pick, `tools/stt/lares_stt.py` PICK; numbers in the research document's section 11). NVIDIA Parakeet TDT
  0.6B v3 hears and writes every take, its encoder on the Arc iGPU through OpenVINO: a 10 s sentence re-heard in ~0.13 s, the first
  word ~0.7 s after you start, the final text ~0.85 s after you pause. A take with a forced language (Shift+fn+F10) gets the second
  pass: Parakeet's live words, then each sentence's final text from NVIDIA Canary 1B v2 told the language (Parakeet cannot be told
  one, and Canary's Dutch is better), ~2-3 s after the pause. An auto take's language is read from Parakeet's own words after 3 s.
- **The load** (round 5). On the card and on the iGPU only the fp32 encoder runs, so the int8 encoder onnx-asr would also build (652 MB)
  is never made; OpenVINO's device list is read once per process.
- **Compute, per take** (research 11.5). At each take's start the helper reads one cheap fact: is the NVIDIA card on the PCI bus with
  the nvidia driver (sysfs only: nothing opened, nothing woken; Integrated mode takes the card off the bus). Yes: CUDA -- Parakeet's
  fp32 encoder on the card (its decoding loop on the CPU) for every take and every final, English and Dutch (the card's bench:
  7.8 % / 8.0 %, the final 0.79 s after the pause; Canary's fp16 export decoded Dutch at 24.5 % there and was dropped), a forced
  Dutch take's Canary as on the iGPU, the tidy model on the card (97 ms a sentence); on AC and on battery (your answer). A CUDA start that fails anyway says why in ~0.05 s and the take runs on the iGPU
  -- in Smart mode every app starts blocked, so allow `lares-stt` (the helper's process name) in silicon's list once it shows there. No: the Arc iGPU as before (the fp32
  exports at f16; their int8 exports decode to garbage there), Canary on the CPU only for Shift+fn+F10. A helper that ran a take on
  the card is let go `dgpuKeepMin` after the last take (a CUDA context keeps the card awake while it lives). The NPU waits for the
  user-space driver (`intel-npu-driver`, a pacman step).
- **Fillers** (`sttlib/fillers.py`, `policy.py`). Every hypothesis and every final is stripped of standalone fillers (their comma goes
  with them, a full stop they carried moves to the word before, a sentence they began starts with the next word). When the speech
  before a pause ended in a filler -- read from the newest hypothesis, or from one decode at the pause when that one did not hear so far
  -- the sentence closes only after `thinkSilenceMs`.
- **The tidy pass** (`sttlib/tidy.py`). Gemma 3 1B (onnx-community's 4-bit export, onnxruntime, ~0.8 GB) is asked to clean the sentence,
  with its decoding constrained to the sentence's own words, whole and in order: it can drop words, never write one. A guard then
  applies each removed run it can name -- a repeat, a restart (the run starts with the word the speaker starts again with and ends at
  the break the recogniser heard, a comma or dash), a correction (words then a cue: "sorry", "I mean", "no", "nee", "ik bedoel"), a
  stutter -- and puts any other back (round 6; the runs are judged again against what is kept until none changes); a word the
  sentence never had, or fewer than half the words left, and the sentence is written as heard. The seg's `tidy` says what was put
  back (`kept`). A tidy that takes longer than 2.5 s is dropped.

- **The shell's own fields** (round 6). Hyprland never announces a field in the shell's own layer surface to a new input method, so
  a take into the notes editor went to the clipboard (the user's take of 2026-11-09, over VS Code). A popup content takes the words
  itself by declaring `dictationActive` (its field has the caret -- false when the popup's keys went to an app), `dictationPreedit(text)`
  (the live words underlined at the caret, replacing the last; "" clears), `dictationCommit(text)` (inserted at the caret for good)
  and, optionally, `dictationBefore()` (the text before the caret on its line: the spacing). `ShellServices.dictationTarget` is the
  content of the focused screen's open popup -- the primary, then its secondary -- then any other screen's, whose field has the caret;
  the service reads it at the press (route `shell`: no input method is started) and follows it through the take, settled 120 ms
  (a caret moving between two lines of a note is no change): a field that gains the caret takes the rest of the take, one that loses it
  hands the rest to the input method (started then) or the clipboard. The notes popup (`NotesPopup`, the editor and its title) and the
  LLM chat (`LlmPopup`, its prompt) declare it. Round 8: `dictationPreedit` / `dictationCommit` answer a bool -- false is "the field took
  nothing" (the service logs `shelldropped`, keeps the piece for the clipboard and never counts it delivered); a content that answers
  nothing took it. The notes editor puts the live words into a line's rich-text edit as HTML that reads as itself (the space every piece
  after a word starts with was dropped by `insert`, so the old preedit was never found and the words stacked until the commit rewrote the
  line; `&` `<` `>` were markup), measures what came in and finds it again by place and size; a preedit standing in the title is taken
  out before the title is committed.
- **A take can never get stuck** (round 6: a helper went silent after `listening`; its takes waited on it, and a press while one was
  stopping did nothing for 60 s). The helper answers a start at once (`capture`); one that does not within 8 s (`startAnswerMs`), or that
  does not end a take 6 s after the stop, is stalled: the take ends (`stalled` / `timeout` in the take log), the helper is asked for
  every thread's stack (`trace`, answered from its stdin reader -- its main loop may be what is stuck) and started again, and the shell
  log gets the reason, the take's last events, the helper's last stderr lines and that trace. A press while the take is stopping ends
  it at once once 2 s have passed since the stop (`forced`), and the helper is pinged: no `pong` within 5 s is a stall too. A line of a
  take that has ended is never read (a late `running` plays no aura); a keep-warm restart takes no start until the next helper is
  `ready`; a new take's input method waits for the last take's to go (up to 1 s, then it is ended); an AuraEvents event never plays
  over a take's aura (its 2 s life ended the take's aura under the user's words). The helper's fatal signals print every thread's
  Python stack on stderr (`faulthandler`).
  Round 8 (the take of 2026-11-13: the iGPU raised inside a decode, the helper's main loop died with the exception and the process went
  on, answering nothing -- the take ended only on the 6 s stop timer): every main-loop turn is guarded (`Helper.fail`: `error` what
  `crash`, the take ended `error`, the shown words written), a GPU decode that raises is recovered (`sttlib/devguard.py`, `Guarded`), and
  the shell listens while a take runs: the helper's beat thread says once a second how long ago its main loop turned; no beat for
  `beatMs` (5 s) or a loop that has not turned for `loopStuckMs` (12 s; `loadStuckMs` 45 s while it loads the CPU fallback) is a stall
  (`silent` / `loop` in the take log), a late tick of the shell's own GUI thread forgives itself, and a decode that hung on a GPU puts
  the next take on the CPU until the rest restart. Toasts name the cause (`_stallWords`, `_exitWords`).

- **The window take** (round 5; `sttlib/sources.py`). The shell reads the focused window at the press (`hyprctl -j activewindow`, read
  only) and sends the helper `start` with `source: "window"` (no mic node), then `window` with its pid. The helper records a STEREO
  `pw-record` with `node.autoconnect = false` and no target (`lares-dictation-window`): the session manager never links it. ONE
  `pw-dump -m` child for the take follows the graph, and every OUTPUT stream whose process belongs to the window -- the window's pid,
  every descendant (asked per stream, so a process started after the press counts), and the window's own ancestors (their own pids
  only, up to the session's: the compositor, systemd, a display manager, the shell) -- is linked into the capture with `pw-link`, port
  to port by channel (mono and the centre into both). A stream that comes is linked when it comes; one that goes takes its links with
  it. Nothing else is linked, no stream's target, volume or the defaults are touched, and the links die with the capture. The two
  channels are averaged into the mono the model hears. No no-audio stop (a paused video sends nothing), and a capture that falls silent
  mid-sentence is fed the silence the wall clock says it was, so the sentence is written at the pause. Parakeet hears it as an auto
  take (the script mask on), with the tidy pass off (someone else's speech) and the user's text rules but the note header ("greater
  than" at a take's start); the detected language does not become yours. The caption's head says what happens ("Waiting for sound
  from <app>", "Transcribing <app>"); the take log keeps route `source` and the streams it linked (`streams`: serial and app).
- **The voice ask** (round 5). A normal mic take whose finals collect into one question; the input method is never started. The helper
  says `speech` whenever an utterance opens, which holds the ask open; after the last final, `askEndMs` of quiet ends it (8 s from
  `running` with nothing said). The `window` op asks the helper for the cwd: the shell under the window when the window's children are
  shells on ttys (kitty, foot, alacritty) -- the only one, or the one whose tty's foreground program (or, for an idle shell, whose
  directory) the window's title names; "" when they cannot be told apart. At a clean end: `LlmService.voiceAsk(question, { windowClass,
  windowTitle, cwd })` (the window at the press). Route `ask` in the take log.
- **The caption** (round 5). The OSD's event kind `caption` (`modules/osd/data/OsdKinds.js`), shown in place every second while a window
  take or an ask runs (`ms` 2.5 s: a shell that stops renewing it loses it by itself) and withdrawn at the end (`OsdService.withdraw` ->
  `OsdOwner.withdraw`: out of the queue, down if it is up). Anything else the OSD shows takes the slot as over any event (a key at
  once, an event after `minShowMs`), and the next renewal brings the words back. A fixed size (`OsdStyle.captionExtent`: 380 px and four
  lines on a bar, 520 px and three lines in the fullscreen pill), so it never resizes while the words come in.

## Checks after a change

- `tools/dev/dictation_probe.sh` -- the whole chain in a nested Hyprland on a private PipeWire whose mic plays FLEURS clips: fn+F10
  dispatched through Hyprland, live words in the field's preedit, a revision, the final text in the field, the mic muted -> unmuted ->
  muted, the aura asked in and out, the clipboard with no field, a secret field (hidden / sensitive hints) refused, the typing route's
  keyboard typing into a field while a bare-Escape bind stays quiet; then, on the helper's stand-in decoder and a recording with a
  filler, a 2 s pause and a marker (`tools/dev/stt_filler_wav.py`), no filler shown and one sentence across the pause; the tidy pass on
  with a model that adds a word, refused; the device from a fake PCI tree (no card: the iGPU; a card: CUDA asked, refused here, the
  iGPU); round 5: I -- a window whose text input was made and enabled before the bind (`tools/dev/dictation_probe_ticlient.c`): the
  first take is live (one `rebound`), L -- a take stopped while the model loads is written once it is up, K -- the capture rig
  (`tools/dev/dictation_probe_capture.sh`) presses 100 ms before a clip's first word, with the helper just started: the first word is
  written; the aura's asks (island at the press, all at `running`); the switch off. lares-ime is built from the tree under test.
  S -- a window take (Ctrl+fn+F10 through Hyprland): a window process whose child starts playing 3 s after the press and another app
  playing beside it; the caption says it waits, the window's stream is linked when it comes and nothing else is (the fixture's own
  `pw-link -l`), live words on the caption, the transcript on the stub clipboard with its toast, the caption withdrawn, the mic and the
  aura untouched, the take log's route and stream; Q -- a voice ask (Alt+fn+F10) from a terminal window (a shell on a pty in a
  directory made there): the take ends by itself after the question, a stub `voiceAsk` gets the words, the class, the title and the
  shell's directory once, nothing typed or copied, the mic and the aura as in A.
  ARMs `nopreedit`, `stableonly`, `nomic`, `noclip`, `nopassword`, `keycode9`, `offignored`, `nofiller`, `nothink`, `noguard`, `nogate`,
  `norebind`, `latecapture`, `auragroup`, `linkall`, `sourcemic`, `noask`. `DICTATION_FROM=I` runs round 5's steps alone (a developer's
  shortcut, never the verdict).
- `tools/dev/dictation_probe_take.sh` (round 6; offscreen, ~45 s) -- the service's side of a take against a stand-in helper that
  misbehaves on cue (`tools/dev/dictation_probe_helper.py`), a stand-in lares-ime and a stand-in shell field: T1 the shell route at the
  press (no input method), T2 a field that loses the caret (a blink is no change), T3 one that gains it, T8 a press right after a take
  (its input method waits for the last one's), T6 a forced end while the model loads (the ping answered, the late `running` ignored),
  T4 a helper silent after `running` (restarted, the next take normal), T5 one that never answers a start, T7 a keep-warm restart with a
  press in the same turn, T9 the aura held for the take, T10 the take log (a file with no last newline, two records at once), and the
  shell log's report of each stall (threads and stderr). ARMs `noshelltarget`, `nosettle`, `noimewait`, `stoppingdeaf`, `laterunning`,
  `nowatchdog`, `notrace`, `nostartwatch`, `warmrace`, `noeol`, `logdrop`. Round 8: T11 the helper's main loop raised (`crash`: the take
  ends `error`, the shown words written, a toast with the cause, the helper restarted), T12 a GPU fallback (`gpufail`: told in words, the
  take goes on), T13 the listening watchdog (`silent`: the take ends within `beatMs`, not at the stop's 6 s), T14 a stuck loop (`loopstuck`)
  and the GPU resting for the next take, T16 the helper process dying (`die`: exit 139 and its stderr line in the toast), T15 the take
  log's new fields; ARMs `nolistenwatch`, `noloopwatch`, `nofallbacktoast`, `noexitwhy`. The probe keeps its own copy of the service's
  log (the service's is capped at 200: an index into it reads nothing once it is full).
- `tools/dev/stt_helper_probe.sh` (round 8; ~1 min of CPU, no model, no PipeWire) -- the REAL `lares_stt.py` on its stand-in decoder and a
  fake `pw-record` that plays a FLEURS clip: H1 a GPU decoder that raises after its first decode is recovered on the CPU with the sentences
  of a fault-free take, the next take on the CPU with the reason in its `device` event; H2 an exception of the helper's own ends the take
  `error` and the helper takes the next one; H3 the beat. ARMs `nofallback`, `nocrashguard`, `nobeat`.
- `tools/dev/dictation_probe_notes.sh` (round 8; offscreen, seconds) -- the real notes popup and editor: each partial's words once at the
  caret (also at the end of a 500-character line), `&` `<` `>` as spoken, a commit's answer (true; false when nothing can take it), the
  title never committed with a preedit in it, no `QTextCursor::setPosition` warning. ARMs `richinsert`, `nocommitanswer`, `titlecommit`.
- `tools/dev/dictation_probe_shell.sh` (round 6; lock_env, the real `shell.qml` on mock services with the dictation live on the
  stand-in helper and the real lares-ime) -- the user's case: a stand-in app with a text field focused (`dictation_probe_ticlient.c`),
  the notes popup opened BY KEY over it (Alt+N's global) on a note: the take's words land in the note, the app gets nothing; the same
  for the LLM chat's prompt; an AuraEvents ask during a take answers that the take holds the aura. ARM `noshelltarget`.
- `python3 tools/dev/dictation_probe_sources.py` -- `sttlib/sources.py` on a fake /proc and canned `pw-dump` batches (seconds): the
  window's tree, the terminal's cwd, the links by channel, a stream that comes later and one that goes. ARM `nodescend`.
- `tools/dev/stt_policy_probe.sh` -- the revision policy with the real VAD and stand-in decoders (seconds): every speech frame in a
  sentence, each final decoding its own sentence, the stable prefix only growing, one final per sentence; fillers never shown, a
  pause after one keeping the sentence open while a plain pause still ends one, the tidy pass off / refused / passed, the guard on
  fixed sentences (as the sentence each proposal writes: round 6's partial apply; round 8: an enumeration is no restart). Round 8: the
  partial builder against rewritten hypothesis sequences (`partials`), the spelled-code cases. ARMs `nosnapshot`, `nofiller`, `nothink`,
  `noguard`, `wholerefuse`, `nofillerrepeat`, `nounfinished`, `nosign`, `nofkey`, `noleadgt`, `indextail`, `nocodes`, `anyrestart`.
- `tools/dev/stt_bench.sh` -- the bench (machine-exclusive: minutes of full CPU / iGPU), the tidy pass on its test sentences;
  `tools/dev/stt_bench.sh --dgpu` the same on the NVIDIA card (refuses while it is off the bus).
- `tools/dev/lares_deploy_probe.sh` -- the keys block carries the four dictation binds.
- Lint and smoke the module and `shell.qml` (the mock shell builds the service inert: `live` false).

## Open (requests and later)

- **The caption for a typing take with no field** (its words on the OSD card instead of nowhere until the clipboard): the OSD's kind
  `caption` exists now (round 5); a typing take does not use it yet.
- **Unproven on the desktop** (round 5): that Ctrl+fn+F10 and Alt+fn+F10 arrive as `CTRL + XF86Launch5` / `ALT + XF86Launch5` (`wev`);
  a real browser's and a real Electron app's streams (their `application.process.id` against the window's tree: Zen's matched its
  window's pid on this machine, read only); a Flatpak app (its pulse client's pid is the sandbox's own, so it is not matched); a stream
  that pauses (the gap rule is proven on a stream that ends); kitty with several tabs (the title rule).
- **Unproven on the desktop** (round 6): the shell route on your real notes and LLM popups (proven in the nested Hyprland on mock
  services); why the helper of take 9 (2026-11-09) went silent -- the next stall prints the helper's threads and stderr in the shell
  log (`lares log`); the helper's stderr lines reach that report only once `SupervisedStream` hands them over (`errorLine`, asked of
  the orchestrator: until then the report carries the threads and says "(none)").
- **The typing route's lares-ime** (`typer`, `--type-only`) has the same quit race the input method had: a take right after one that typed
  writes into the one that is going. Not fixed (no `typeInto` class is configured).
- **The notes Markdown pass** (research 8.7) is designed, not built.
- **Unproven paths**: a terminal field (no newline: kitty reports purpose terminal; the probe's Qt field cannot), a take that follows
  the focus from one field to another, a mid-take crash of the helper (the shown words are committed), the typing route chosen by a
  real Xwayland window's class (`typeInto`; the probe drives the typing keyboard itself). Round 8's own: the iGPU / CUDA fallback on the
  real GPUs (proven on a stand-in decoder that raises the user's exception), the beat watch against a real hung `infer`, and the notes
  preedit with the user's voice in his real note.
- **A Qt password field (echoMode Password) is no field**: Qt enables no text input for it, the input method is never activated, and
  the take goes to the clipboard as if nothing were focused. A field marked hidden / sensitive (GTK's password entries, Qt's
  ImhHiddenText) is refused.
- **The card's numbers**: built and proven up to the card (the fact, the gate, the CUDA libraries load, a CUDA start refused with its
  reason and the take carrying on), never run on it -- the machine was in Integrated mode. After a switch to Hybrid: `tools/dev/stt_bench.sh
  --dgpu`, then the pick in `lares_stt.py` PICK["cuda"] follows its table (research 11.5).
- **A real "uh"**: no recording of a spoken filler was at hand, so the chain's filler steps run on a stand-in decoder; your take log's
  `heard` field is the real test (the fillers Parakeet wrote, and that none reached the field).
- The NPU (after `intel-npu-driver`), Flemish fine-tunes, a voice-reactive aura: research section 9.
