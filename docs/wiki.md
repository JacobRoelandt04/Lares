# Wiki

## What it is

One article a day on two tabs, picked for you: Discover (a good Wikipedia article from a subject you might not know) and Deepen (your own
field: the Arch wiki pages of what you have installed and what you have not, tips, kernel and freedesktop documents). It has no bar button: it
shows up where you have a minute, as a small card on the calendar, in an empty notification manager, on the lock screen and at the foot of the
launcher, and opens full-size from any of them. What you open, like and skip steers what you are shown next.

## Where it lives

- The clock popup's Calendar tab: a small card ("tear-off") under the appointments. Click it for the full card, a second popup beside the clock popup.
- The notification manager's empty state: a wide card.
- The lock screen: a read-only card (Discover only, no pointer, no links) in the media slot when no music is playing.
- The launcher: one line at its foot, "Today: <title>", Discover only (`wiki.jsonc` `show.launcher`, the launcher tune's `wikiTeaser`); a click opens the clock popup's wiki card.
- Notification asks: "Only 5 Discover entries left -- process 30 new ones now?" with two buttons, **Process 30 now** and **Later**, and a progress
  card; a click on the body of either card opens the wiki.
- The full card is the clock popup's secondary (`ClockBarOwner.openWiki`); there is no shortcut and no IPC verb.

## What you can do

The full card (Discover | Deepen: a two-finger sideways swipe over the card or the dots in the bottom padding switch tabs)
- Look at the picture well: a click steps to the next picture; the pictures also advance by themselves while the pointer is elsewhere. An article
  with no photograph shows its **veil** there instead (below). Hover it for
  the buttons: More, Less and "I knew this" on the left, Save and Next on the right, the dots between them. More / Less / Knew are a choice you can
  undo (press it again; More and Less switch each other); it counts when the day rolls over. Hover a picture to see its credit.
- Read the title, the paragraph and the marks at its foot: a sparkle for an intro a local model wrote, a pencil for one that was cleaned up.
- The row beside the title: the subject's glyph (hover: "Physics . you open 40 % . picked 1 in 9"), a package mark when a Deepen page is about
  something you have installed, and the source's logo, which opens the source in the browser.
- A plain click on a link in the paragraph opens it in the browser and closes the card and the clock popup. Ctrl+click follows it inside the
  card (the rabbit hole): a back chip appears at the picture's top-left and walks one step back.
- Save writes the article to `<notesRoot>/<notesFolder>/<title>.md`; the button holds the accent once written and its tip names the note.
- Next picks a new article for the tab (the card on show is never repeated); one left unseen is marked done.

The veils (an article with no picture)
- Most Deepen pages and some Discover ones have no photograph. Their picture well shows a veil: a slow pattern cut into the card's own
  material, in the same tones as the card, moving just enough to be alive beside the text. There are five:

  | Name | What it is |
  |---|---|
  | `contours` | the map of a country that is not there: engraved contour lines of a slowly changing terrain, every fifth one heavier |
  | `links` | wandering nodes joined by engraved lines; a line that is stretched lets go and comes back when the nodes close again |
  | `ripples` | three slow wave sources and the pattern where their waves cross: no line, only the surface rising and falling |
  | `maze` | the one-line maze, a diagonal wall in every square; now and then a wall swings a quarter turn |
  | `cells` | the floor cut into plateaus by seams, like dried clay or a pavement of cut stones, each drifting a little |

- Which one an article gets, and what it looks like, comes from the article's id alone: the same article is always the same picture, and
  nothing is stored. The family's hue is mixed into the deepest shade only.
- A page whose subject has a logo (systemd's, Firefox's: from Wikidata) keeps it, carved on a flat plate in the middle of its veil.
- The small cards (calendar, notification manager, lock screen) show the same veil as a STILL thumbnail: the middle of the picture at its
  first frame. Nothing moves there, and nothing moves on the lock screen.
- A veil moves only while the full card is on show: not while the popup is hidden, the shell is idle or locked, or the theme is fading over.
  A photograph whose file has gone missing shows the article's veil too, instead of an empty well.

How it learns
- An article is seen only once you have READ it: `seenMs` (5 s) in the wiki detail you opened from the clock, per tab (Discover read and
  Deepen never opened replaces Discover's alone); a card on screen elsewhere (the notification manager) never makes it seen. A seen
  article is replaced at the next rollover and never shown again. A pointer resting on the card for `dwellMs` is a
  weak like; Next before `quickNextMs` a weak dislike; opening a link and following one count for you; More and Less count more. Old taste fades
  (half-life 90 days) and nothing is ever ruled out entirely.
- The day rolls at `rolloverHour`; an article nobody saw carries over.

Refilling
- When a tab has `askAt` unseen entries left, one notification asks to process `batchSize` new ones, with two buttons. **Process 30 now** starts the
  batch (a notification shows progress). **Later** closes the ask for 24 h (`reaskMs`; kept in `state.json`, so a restart does not post it again,
  and the count dropping does not bring it back sooner), then it asks again. A click on the card body only opens the wiki on that tab: it no longer
  starts a GPU batch. The buttons of a stale card (an ask already answered, deferred or closed, or a batch running) start nothing: Process opens the
  wiki, Later does nothing. Prove with `tools/dev/wiki_ask_probe.sh` (the real service, a recording notifier, a stub tool; with its ARMs).

## What it shows and where the data comes from

- The pool is built by `tools/wiki/wiki.py` (Python, standard library and PIL; one JSON event per line on stdout). A batch finds candidate pages in the
  enabled sources and fetches their pictures. For pages with no ready introduction (Arch, Gentoo, kernel docs, freedesktop) a judge names the best
  paragraph and rates it, and plain code cuts the intro from the page, so the words are the source's own. When that is refused, a local model writes one
  paragraph from the page's text only, and it is kept only when a judge finds it grounded in that text (the sparkle mark).
  - Judge: Jev (`Defapi`) when `jev` is true and the key is present, else the local Ollama (`ollamaUrl`). A batch has a spend cap of $0.04 for Jev.
  - The key is `jevKey` in your `config/wiki.jsonc` (copy `.examples/wiki.jsonc` if you have none, then `chmod 600` it; `config/` is never
    committed). The tool reads it itself; the shell forwards only the keys it names to the tool, never this one, and `lares config` and the
    shell's config messages never print it (the spec marks it `secret`). An old `~/.config/quickshell/.env` is read no more: a batch without
    `jevKey` says so and names the file to move it from; delete the `.env` once the key is moved.
  - The local model runs on the dGPU: before a batch the shell switches the GPU mode to Hybrid through the silicon module, wakes the card, restarts
    Ollama only if it started on the CPU (needs the one-line polkit rule `tools/wiki/polkit/49-wiki-ollama-restart.rules.in`, installed once by you: its INSTALL line), and
    puts the mode back afterwards unless you changed it meanwhile. Without the rule a batch that needs the restart pauses and the progress card says so.
- Discover draws from Wikipedia's Good and Featured articles by 13 subject families (history, geography, people, visual and performing arts, literature,
  philosophy, society, physical and life sciences, earth, technology, everyday life) plus the far side of computing as a guest. Deepen has five families:
  installed Arch wiki pages, Arch wiki pages to discover, Wikipedia computing, Arch tips and tricks, other wikis (Gentoo, kernel docs, freedesktop). Families and
  their glyphs and hues are in `modules/wiki/data/families.json`.
- Kept in: pool and pictures under `$XDG_CACHE_HOME/lares/wiki/` (index, entries, images); the day's picks, seen set, choices, interest and asks in
  `$XDG_STATE_HOME/lares/wiki/state.json`.
- A tab with nothing yet shows a skeleton then "No articles yet" (and what it waits for: a batch running, the GPU, the network). When a
  batch could start now (none runs or waits, the network is up; a busy GPU is a retry) a **Process articles** button stands under the
  words: it starts the same batch as the refill notification's "Process N now", for the tab on show. A rabbit-hole page on its way
  shows the same skeleton in place. Offline the pool still serves.
  The tool is polite to Wikimedia: an identified User-Agent and a pause between requests.

## Settings

`~/.config/quickshell/config/wiki.jsonc`, read hot (a file that does not parse keeps the last good one; a bad value takes its default; both are named in the
service's `lastError`). `.examples/wiki.jsonc` has every key.

| Key | Meaning | Default |
|---|---|---|
| `askAt` | unseen entries left that trigger the refill ask (0 .. 1000) | 5 |
| `batchSize` | entries per batch (1 .. 200) | 30 |
| `rolloverHour` | local hour the wiki day rolls (0 .. 12) | 4 |
| `seenMs` | read this long in the wiki detail = seen | 5000 |
| `dwellMs` | pointer on the card this long = weak like | 15000 |
| `quickNextMs` | Next before this = weak dislike | 4000 |
| `ollamaUrl` | the local Ollama (the tool's; and the shell's GPU helper's while the LLM's server is not this machine's) | `http://localhost:11434` |
| `jev` | false: the local model does everything | true |
| `notesRoot`, `notesFolder` | where Save writes (`~/` is the home; one plain folder name) | `~/Documents/Notes`, `Wiki` |
| `sources.wikipedia`, `arch`, `archTips`, `gentoo`, `kernel`, `freedesktop` | switch a source off and its families leave the next batches (what is in the pool stays); `archTips` only with `arch` | all true |
| `show.calendar`, `notifications`, `lock`, `launcher` | where the card is: the calendar's tear-off (off, the card still opens from a notification), an empty manager, the lock, the launcher's line | all true |
| `families` | `{ "<subject>": false }`: never picked (its entries stay in the pool, uncounted by the refill ask) and never fetched | `{}` |
| `askAgainHours` | "Later" on the refill ask asks again after this (1 .. 720) | 24 |
| `jevCapUsd` | what one batch may spend at Jev (0 .. 10) | 0.04 |
| `models.write`, `judge` | the local writer and judge ("" = `tools/wiki/data/models.json`'s) | "" |

The card's look and motion (width, slide time, auto-advance, the carve) are tuned in `mockups/wiki.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/wiki/WikiPopup.qml` | the full card: two tabs on one wheel reader, naturalHeight over both tabs, the engine's secondary contract |
| `modules/wiki/WikiHero.qml`, `WikiCarousel.qml`, `WikiTrail.qml`, `WikiIntro.qml`, `WikiTitleRow.qml`, `WikiSkeleton.qml`, `LogoLink.qml` | the picture well and its buttons, the pictures, the back chip, the paragraph, the title row, the loading shapes, a logo that is a link |
| `modules/wiki/WikiVeil.qml`, `WikiVeilPick.js`, `WikiVeilStyle.qml`, `shaders/wiki_veil*.frag` + `wiki_veil.glsl` | a veil (one shader, one clock), which veil an id gets, the veils' numbers, one shader per pattern over the shared shading |
| `modules/wiki/WikiCompactCard.qml`, `WikiTeaser.qml` | the small card (tear-off, wide, lock variants); the launcher's one line |
| `modules/wiki/WikiStyle.qml`, `WikiGlyphs.js` | sizes and fades; the glyph table (`tools/wiki/check_glyphs.py` checks it against the font) |
| `modules/wiki/data/WikiService.qml` | the data layer: the pool on disk, the day's pick per tab, seen and choices, the refill ask, the batch |
| `modules/wiki/data/WikiState.qml`, `WikiConfig.qml`, `WikiBatch.qml`, `WikiTool.qml`, `WikiViewModel.qml` | the state file; `wiki.jsonc`; the batch runner; the tool process; the getters |
| `modules/wiki/data/Interest.js`, `WikiPool.js`, `WikiCardModel.js` | pure JS: discounted Thompson sampling on subject and topic, the day, slots and refill rule, the card |
| `modules/wiki/data/WikiMock.qml` | the same service surface on fixed data |
| `tools/wiki/wiki.py`, `tools/wiki/lib/` | the tool: batch, load (rabbit hole), daily, save-note, installed, gpu |

Shared components used: `CardViewCycler` (tabs by swipe and dots), `ShadowBox`, `RaisedButton`, `LogoRelief`, `SkeletonBar`, `HoverTip`, `WheelStepper`,
`DesktopNotifier`, `ConfigFile`, `BoundaryClock` (the day's turn), `OllamaGpu` (the GPU hand shared with the LLM chat).
Service pair: `WikiService` (live) / `WikiMock` (mock shell and mockup), one per shell. The service surface, the tool's events and the card object are specified in
`docs/contracts/wiki.md`; what the sources answer is in `docs/contracts/wiki_api_notes.md`.

## Limits

- Discover only offers Wikipedia's Good and Featured articles; the pool grows by batches you answer, it does not top itself up silently.
- Intros are the source's own unless the page has none worth reading; a generated or edited one carries its mark.
- A batch needs the network; a local-model batch needs the GPU free (it refuses rather than spilling into RAM).
- The lock card shows no links; the launcher teaser is Discover only.
- While a veil moves, the whole bar window is drawn again at the veil's rate (20 ticks a second by default), as for any moving thing in a
  popup; a card with a photograph draws nothing at rest.

## How to change it

- A cadence, a threshold, a source, the notes folder: `wiki.jsonc`.
- The look of the card (width, picture slide time, the band of buttons): `mockups/wiki.qml` (`quickshell -p ~/.config/quickshell/mockups/wiki.qml`), change on
  the panel, Save; or the properties at the top of `modules/wiki/WikiPopup.qml` and `modules/wiki/WikiStyle.qml`.
- A veil (pace, frame rate, line weight, how much hue, each pattern's own numbers): the mockup's **Veils** tab, one sub-tab per pattern; the Run
  tab's **veil** box shows one pattern on every card (scenario `noImage` has two entries with no picture, `Systemd` has a logo). Save writes
  `modules/wiki/WikiVeilStyle.qml`. A shader (`modules/wiki/shaders/`) is rebaked with `tools/dev/bake_shaders.sh wiki_veil`.
- A family's name, glyph or hue: `modules/wiki/data/families.json`.
- Proof: `tools/dev/smoke.sh mockups/wiki.qml`, `tools/dev/wiki_mockup.sh`, `tools/dev/mockup_panel_test.sh mockups/wiki.qml`, `tools/dev/config_loaders_probe.sh` (`wiki.jsonc`),
  `tools/dev/sheet_check.sh`; for the veils `tools/dev/wiki_veil_probe.sh` (with its ARMs) and `tools/dev/wiki_veil_sheet.sh` (every veil, light and dark, to PNG).
