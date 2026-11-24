# Wiki module — contract (binding for every stream)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/wiki_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

`PLAN.md` beside this file holds the user's decisions; this file fixes names, shapes and file
ownership so streams can run in parallel. A stream that needs a change here stops and asks the
orchestrator. API facts learned live go into `wiki_api_notes.md` / `wiki_jev_api.md` (Stage 0).

## Paths

| What | Where | Writer |
|---|---|---|
| Entries (immutable once written) | `$XDG_STATE_HOME/lares/wiki/entries/<tab>/<slug>.json` | tool |
| Entry images | `$XDG_STATE_HOME/lares/wiki/img/<slug>-<n>.jpg`, `-thumb.jpg` | tool |
| Pool index | `$XDG_STATE_HOME/lares/wiki/index.json` (atomic) | tool only |
| Service state | `$XDG_STATE_HOME/lares/wiki/state.json` (atomic) | service only |
| Batch progress + lock | `$XDG_STATE_HOME/lares/wiki/batch/<tab>.progress.json`, `<tab>.lock` | tool |
| Daily extras | `$XDG_CACHE_HOME/lares/wiki/daily/YYYY-MM-DD.json` | tool |
| Rabbit-hole pages | `$XDG_CACHE_HOME/lares/wiki/live/<slug>.json` (LRU 50) | tool |
| Arch title index | `$XDG_CACHE_HOME/lares/wiki/arch_titles.json` (weekly) | tool |
| User config | `~/.config/quickshell/config/wiki.jsonc` (gitignored), template `wiki.example.jsonc` | user |
| Secret | `~/.config/quickshell/config/wiki.jsonc` → `"jevKey"` (config/ gitignored; chmod 600; spec `secret`) | user |
| Families | `modules/wiki/data/families.json` (QML, node and Python read it) | Stage 0 |

`<slug>` = host-prefixed, filesystem-safe id: `en.wikipedia.org__Battle_of_Hastings`,
`wiki.archlinux.org__Pacman`, `wiki.archlinux.org__Pacman#Tips_and_tricks` → `…__Pacman--Tips_and_tricks`.
Every writer: write `<file>.part`, fsync, `os.replace`. Probes set private `XDG_*` dirs.

## Entry (`v: 1`)

```json
{
  "v": 1,
  "id": "en.wikipedia.org/Battle_of_Hastings",
  "tab": "discover",                       // discover | deepen
  "kind": "article",                       // article | tips | potd
  "source": { "wiki": "wikipedia", "host": "en.wikipedia.org", "title": "Battle of Hastings",
              "url": "https://en.wikipedia.org/wiki/Battle_of_Hastings", "revid": 123,
              "license": "CC BY-SA 4.0", "quality": "featured" },   // good|featured|null
  "title": "Battle of Hastings",
  "category": { "family": "history", "topic": "military-and-warfare",
                "via": "thompson",         // thompson|guest|installed|discovery|tips|other|daily|follow
                "why": { "p": 0.11, "oneIn": 9, "openRate": 0.4 } },
  "intro": { "text": "…", "words": 118,
             "provenance": "cleaned",      // original | cleaned | generated
             "stripped": ["pronunciation", "dates"],
             "model": null,                // "jev-1.13+ornith-1.5:9b" when generated
             "grounded": null,             // true|false|null (generated only)
             "locator": null,              // {judge:"jev"|"ollama", para, of, score, rules:{defines,hook,selfContained,noHowTo}}
             "links": [ { "s": 12, "e": 20, "target": "Norman conquest",
                          "wiki": "wikipedia", "url": "https://en.wikipedia.org/wiki/Norman_conquest" } ] },
  "images": [ { "kind": "photo",           // photo | relief | glyph (the pool's word for "no picture")
                "file": "img/en.wikipedia.org__Battle_of_Hastings-0.jpg",   // relative to state dir
                "thumb": "img/en.wikipedia.org__Battle_of_Hastings-0-thumb.jpg",
                "w": 960, "h": 540, "aspect": 1.33, "focusY": 0.5,
                "credit": "Bayeux Tapestry, public domain", "license": "PD",
                "src": "page",             // page | potd | logo
                "fileTitle": "File:Bayeux Tapestry scene57.jpg" } ],
  "installed": null,                       // deepen: {flag:true|false, pkg, unit, asOf}
  "popularity": { "views60d": 48213, "band": 0.62 },   // band = quantile in the family's pool
  "judge": { "engage": { "judge": "jev", "score": 0.71, "pickedRank": 2, "of": 5 },
             "lead": { "ok": true, "score": 0.9 } },
  "batch": "2026-09-30T13:40:00Z-discover",
  "fetchedAt": 1790000000000
}
```

`kind: "glyph"` images carry no `file`: the kind stands for "no picture and no logo", and the card draws the
article's veil for it (below). `kind: "relief"` is the SUBJECT's own logo (Wikidata P154, baked by `lib/logos.py`),
not the source's.
Intro links carry offsets into `intro.text` after cleanup, counted in **UTF-16 code units**
(JS string indices — Python converts: `len(text[:i].encode("utf-16-le"))//2`).
`intro.stripped` codes (closed set; `WikiCardModel.markTips` maps them to words):
`pronunciation`, `ipa`, `native_names`, `dates`, `coordinates`, `citations`, `hatnote`,
`parentheticals` (any other removed aside), `notes` (footnote markers/`[1]`).

## Daily (`daily/<YYYY-MM-DD>.json`)

```json
{ "v": 1, "day": "2026-09-30",
  "otd": { "year": 1791, "text": "…", "title": "The Magic Flute", "url": "…" },
  "potd": { "fileTitle": "File:…", "file": "…jpg", "thumb": "…", "credit": "…",
            "license": "…", "description": "…", "relatesTo": "en.wikipedia.org/…" | null } }
```

## Index (`index.json`)

`{ "v":1, "tabs": { "discover": [row…], "deepen": [row…] } }` with
`row = { id, slug, family, topic, kind, fetchedAt, popularityBand, jevScore }`. The service
reads it (FileView, static path, `reload()` on the tool's `done`/`end` events).

## State (`state.json`, service only)

```json
{ "v": 1,
  "seen": { "<id>": 1790000000000 },
  "slots": { "discover": { "day": "2026-09-30", "id": "…", "shownMs": 0, "why": {…} },
             "deepen":   { … } },
  "interest": { "discover": { "events": [ {"f":"history","t":"…","k":"open","w":1.0,"at":…} ] },
                "deepen": { … } },          // events bounded (last 400 per tab)
  "ask": { "discover": { "latchedAt": 5, "at": …, "answered": false }, "deepen": {…} },
  "batch": { "running": false, "tab": null, "pid": 0 },
  "jev": { "tokens": 0, "calls": 0 } }
```

## Families (`modules/wiki/data/families.json`)

```json
{ "v": 1,
  "discover": [ { "id": "history", "label": "History", "glyph": "f1da", "hue": "mdOrange",
                  "topics": ["history", "military-and-warfare", …] }, … ],
  "guest":    { "id": "computing", "label": "Computing", "glyph": "…", "hue": "mdGray",
                "topics": ["computing"], "allow": ["history of computing", …],
                "deny": ["linux", "operating system", "software", "internet", "data science",
                         "machine learning", "artificial intelligence"] },
  "deepen":   [ { "id": "arch-installed", "label": "Arch · yours", "share": 0.30, … },
                { "id": "arch-discovery", "label": "Arch · new", "share": 0.30, … },
                { "id": "wikipedia-cs", "share": 0.15 }, { "id": "arch-tips", "share": 0.15 },
                { "id": "other-wikis", "share": 0.10 } ] }
```

`glyph` = hex codepoint in Symbols Nerd Font (verified against the TTF); `hue` = a Theme token
name — never a colour in data.

## `tools/wiki/wiki.py` (stdlib + PIL; NDJSON on stdout, one object per line, flushed)

```
wiki.py batch --tab discover|deepen --n 30 [--resume]      stdin: {"plan":[{family,topic,kind}], "recent":[titles], "n":30}
wiki.py load --url URL --tab T [--allow-generate]
wiki.py daily [--day YYYY-MM-DD]
wiki.py save-note --tab T --id ID --notes-root DIR --folder Wiki
wiki.py installed | gpu | index | validate
exit: 0 done (even with some fails), 2 usage, 3 blocked (gpu busy / spill), 4 network down
```

Events:

```
{"ev":"start","batch":"…","tab":"…","n":30,"todo":30,"resumed":false}
{"ev":"gpu","state":"free|busy","models":[…],"freeMiB":…}
{"ev":"warn","code":"jev-unavailable|jev-budget","fallback":"ollama"}
{"ev":"item","i":3,"n":30,"stage":"candidates|score|fetch|intro|images|write","title":"…"}
{"ev":"done","i":3,"n":30,"id":"…","row":{index row},"generated":false,"ms":…}
{"ev":"skip","i":4,"reason":"duplicate|seen|no-lead|too-short|graphic","family":"…"}
{"ev":"fail","i":5,"reason":"…","family":"…"}
{"ev":"blocked","reason":"gpu-busy|spill","models":[…]}
{"ev":"entry","entry":{…},"provisional":true}          (load)
{"ev":"upgrade","id":"…","intro":{…}}                    (load, when a ✦ intro was written)
{"ev":"daily","daily":{…}}                               (daily)
{"ev":"saved","path":"…","key":"Wiki/<title>.md"}        (save-note)
{"ev":"end","ok":28,"skipped":2,"failed":0,"ms":…}
```

Rules: `jevKey` read from config/wiki.jsonc by the tool itself (`lib/env.py`; `.env` is read no more), key only in memory; never in argv, env
of children, logs, events or fixtures. UA `lares-wiki/0.1 (https://github.com/JacobRoelandt04/Lares)`,
`maxlag=5`, ≥ 0.3 s between requests to one host. `WIKI_HTTP_MAP` (JSON host→base URL) redirects
hosts to a stub in probes. GPU guard: refuse (exit 3) unless `/api/ps` shows no other model, and
after load `size_vram == size` AND nvidia-smi free ≥ headroom. `think:false` for thinking models.
Unload `keep_alive: 0` at the end. Resume: `batch/<tab>.progress.json` `{plan, done:[ids], running}`
+ `flock` on `<tab>.lock`.

## QML surfaces

**`WikiService` / `WikiMock`** (same members; `WikiViewModel.qml` shared)

```
readonly property bool ready, offline, busy;  readonly property string lastError, day
property bool popupOpen;  property real nowMs          // owner binds popupOpen; mock pins nowMs
readonly property int serial                           // bumps on any change a getter reads
readonly property var daily;  readonly property var batch   // {running, tab, done, total, blocked, lastError}
signal updated(); signal openRequested(string tab); signal noteSaved(string tab, string id, bool ok, string keyOrError)
signal refillAsked(string tab, int left); signal batchFinished(string tab, int ok, int failed)
// getters — read only, never ask (a getter called from a binding must not fetch)
function card(tab); function trail(tab); function canBack(tab); function unseen(tab); function loading(tab); function whyText(card)
// asks — from handlers
function ensureSlots(); function shown(tab, id, visibleMs); function hoverDwell(tab, id, ms)
function next(tab); function more(tab, id); function less(tab, id); function knew(tab, id)
function openSource(tab, id); function openLink(tab, id, url); function follow(tab, link); function followOnThisDay(); function back(tab); function closeCard()
function saveToNote(tab, id); function startBatch(tab); function refresh(); function requestOpen(tab)
```

**Card object** (what views read; facts only — no colours):

```
{ id, tab, kind, title, familyLabel, glyph, hueToken, whyText,
  intro, introLinks:[{s,e,url,target}], words, provenance, stripped:[], model,
  source:{wiki, name, logo, url, license, quality},
  images:[{kind, url, thumbUrl, aspect, focusY, credit, license}],
  installed, followed, otd:{year, text, url} | null }
```

`images` is never empty and its kinds are `photo | relief | veil`: the pool's `glyph`, and an entry with no image at
all, become ONE `{kind: "veil"}` record (no url). A veil carries no data of its own: what it draws comes from the
card's `id` (the pattern, its seed, its starting time) and `hueToken`.

**`WikiVeil.qml`** — the picture of an article that has none (the full card's well, a thumbnail):
`seedKey` (the article's id), `pattern ""` (a name of `patterns` forces one), `hue` (a colour: the family's),
`groundColor (Theme.listBox)`, `running true` (a thumbnail says false: it is the picture at its start), `zoom 1`,
`cornerRadius 0` (its own rounded mask), `plateRadius 0` (> 0: a flat disc at the centre for a carved logo),
`style (WikiVeilStyle)`; `readonly patterns` (`contours, links, ripples, maze, cells`), `pick`, `shown`, `time`,
`ticking`; `function seek(seconds)` (renders and probes). The pick is `WikiVeilPick.of(key) -> {pattern, seed[4], t0}`:
a hash of the key and nothing else, the same in node and QV4. One fragment shader per pattern
(`modules/wiki/shaders/wiki_veil_<name>.frag` over `wiki_veil.glsl`: one uniform block, one shading), a pure function
of `time`; ONE Timer at `style.fps` that runs only while `running`, visible, sized and the theme is not crossfading.
`WikiVeilStyle` is `WikiStyle.veil`; its `only` ("" in the shell) shows one pattern for every article.

**`WikiPopup.qml`** — full card, the clock popup's secondary root:
`service, fontFamily "Inter", cardWidth 448, padding 12, radius 14, style (WikiStyle),
autoAdvanceMs 7000, slideMs 260, seenMs 3000, dwellMs 15000`;
engine contract `secondaryKey, secondaryCutout, secondaryMoving`; `readonly naturalHeight`
(content only, max over both tabs' current entries); `readonly tab, tabIndex`;
`readonly swipeGestureActive`; `function gestureWheel(ev)`; `signal closeRequested()`;
`function showTab(id)`.

**`WikiCompactCard.qml`**: `service, tab "discover", variant "tearoff"|"wide"|"lock",
groundColor (Theme.listBox), fontFamily, renderScale, padding 10, radius 12, active (bool, default
true: gates the only motion — a 160 ms presence fade), attended (bool, default = active: counts
toward "seen"), collapseWhenEmpty (false)`;
`signal activated(var card)`; `signal onThisDayActivated(bool follow)`;
`readonly card, empty, loading`. No service → no children, 0 size.
Heights are FIXED per variant for a given width (text clamped/elided, never article-dependent):
`tearoff` = 106 (thumb 64 + 22; title row with glyph left of the title, intro text 4 lines beside the thumb and 1 below it), `wide` = 84 (thumb 64; title row, 3 intro lines), `lock` = 92 (thumb 72; 4 intro lines); the On-this-day line shows only for a card with no intro; no
`lockFull` (the lock session opted out; add it when a host needs a hero band). Loading = a skeleton at the same geometry (static when
!active). Compact cards tick NOTHING at rest (no timers, no carousel). The lock variants show
Discover only, no why-text and no installed badge (public screen). Agreed with the lockscreen
session 2026-09-30. Its consumer: `variant "lock"`, host width ~440 (≥ 360), one 92 px
reclaimable row shared with the mini vinyl, `collapseWhenEmpty: true`, `active` = `attended` =
lock awake; placeholder `WikiCompactCard { service: null }` until Stage 3B. The mockup's Compact
tab renders the lock variant at 440 × 92.

**`WikiTeaser.qml`**: `service, groundColor, fontFamily`; `implicitHeight 18`; `signal activated()`.

**Signals weights (Interest.js defaults):** open +1.0, more +1.5, less −1.5, dwell +0.25,
quick_next −0.25, follow +0.4, knew 0 (popularity shift only), seen-ignored 0.
Half-life 90 d. Cap: discover max/min share ≤ 4, deepen ≤ 2; computing pinned at the floor.

## File ownership

| Stream | Owns |
|---|---|
| 0A captures | `tools/wiki/capture_fixtures.sh`, `fixtures/wiki/{wikipedia,arch,gentoo,kernel,freedesktop,wikidata,feed,commons,pageviews}/**`, `urls.tsv`, `docs/contracts/wiki_api_notes.md` |
| 0B jev | `tools/wiki/jev_probe.py`, `fixtures/wiki/jev/**`, `docs/contracts/wiki_jev_api.md` |
| 0C families | `modules/wiki/data/families.json`, `fixtures/wiki/weighted_pick_cases.json` |
| 1 eval | `tools/wiki/lib/{judge,judge_jev,judge_ollama,locate,generate,gpu}.py`, `wiki_intro_eval.py`, `wiki_eval_sheet.py`, `fixtures/wiki/eval/**`, `tools/wiki/data/models.json`, `docs/agent_added_files_and_folders/wiki_progress/eval_report.md` |
| 2P1 | `tools/wiki/lib/{http,env,paths,ndjson,atomic,mw,htmltext,cleanup,intro,entry,index}.py`, `tools/wiki/lib/sources/**`, `tools/wiki/data/{static_pages,cleanup_rules}.json`, `wiki_py_cases.py` |
| 2P2 | `tools/wiki/wiki.py`, `tools/wiki/lib/{candidates,installed,images,logos,daily,notes,batch}.py`, `wiki_stub_server.py`, `wiki_batch_probe.sh` |
| 2J1 | `modules/wiki/data/{Interest,WikiPool,WikiCardModel}.js`, `wiki_js_cases.js` |
| 2J2 | `modules/wiki/data/*.qml`, `modules/wiki/data/fixtures/**`, `test_wiki_service_probe.qml`, `wiki_service_probe.sh`, `wiki.example.jsonc` |
| 3A | `modules/wiki/{WikiPopup,WikiHero,WikiCarousel,WikiTitleRow,WikiIntro,WikiTrail,WikiSkeleton,WikiStyle}.qml`, `modules/wiki/LogoLink.qml` |
| 3B | `modules/wiki/{WikiCompactCard,WikiTeaser}.qml`, `modules/wiki/WikiGlyphs.js`, `tools/wiki/bake_glyphs.py`, `assets/wiki/**`, `assets/logos/src/{wikipedia,gentoo,linux,freedesktop,commons}.svg` + baked PNGs |
| 3C | `test_wiki*.qml`, `wiki_{mockup,render,click_probe,swipe_probe}.sh` |
| 4A | `modules/clock/{ClockBarOwner,ClockPopupContent}.qml`, `modules/clock/calendar/AppointmentList.qml`, `test_wiki_clock_probe.qml`, `wiki_clock_probe.sh` |
| 4B | `modules/notifications/{NotificationManagerPopup,NotificationsBarOwner}.qml` |
| 4C | `modules/launcher/{LauncherPopup,LauncherBarOwner,LauncherTune}.qml` |
| 4D | `test_wiki_{refill,notes}_probe.qml`, `wiki_{refill,notes}_probe.sh` |

Commits stage explicit paths only (other sessions work in this tree). Never `git add -A`.

## Additions from stream 2J2 (binding for 2P2)

- Every tool job gets env `WIKI_OLLAMA_URL`, `WIKI_JEV` ("1"/"0"), `WIKI_SOURCES` (JSON of the
  wiki.json source toggles `wikipedia, arch, archTips, gentoo, kernel, freedesktop`), `WIKI_JEV_CAP_USD`
  (wiki.jsonc `jevCapUsd`) and `WIKI_MODEL_WRITE` / `WIKI_MODEL_JUDGE` (wiki.jsonc `models`, "" = models.json's:
  `pipeline.models()`). The tool reads these; a switched-off source is never fetched.
- Batch stdin: `{plan, recent, n, sources}`; plan items are `Interest.planBatch` rows
  `{family, topic, kind, band, why}`. With `--resume` stdin is `{recent, n}` and the plan comes
  from `batch/<tab>.progress.json`. The tool ignores unknown keys.
- `state.json` gains `opened: [{id, title, at}]` (last 20) — the source of `recent`.
- The `end` event may carry `jev: {tokens, calls}`; the service adds it to `state.jev`.
- The progress notification carries a `default` action "Open" (notify-send exits at once
  without an action, so the next post could not replace it); its click → `openRequested(tab)`.
- `shown(tab, id, visibleMs)` takes CUMULATIVE visible ms; hosts call it ~1/s while the card is
  fully visible. `openSource` also marks the card seen.
- Hosts' `DesktopNotifier` must list the service's `notifyKeys`
  (`refill-discover`, `refill-deepen`, `progress`).

## Additions from stream 2P2 (the batch tool as built)

- `batch/<tab>.progress.json` = `{plan, n, seed, settled[], done[], counts, batch, running, pid,
  startedAt}`, written after every item BEFORE its event. `--resume` resumes by plan position;
  every item draws from `Random("<seed>:<i>")`, so a resumed batch makes the choices an
  uninterrupted one would (proved against a never-killed control run).
- One terminal event (`done` | `skip` | `fail`) per plan item; a candidate that cannot become an
  entry falls to the next one (≤ 4 tries) silently. Extra skip reasons: `source-off`,
  `no-candidates`, `too-short` (a Wikipedia lead under 50 words). Exit 1 = a request could not
  be served (no such entry/page).
- Extra env: `WIKI_SEED` (probes), `WIKI_TODAY`.
- SIGTERM from a living parent = cancel; after the parent died (a shell reload) = stay resumable.
- A generated intro's `model` = `jev-1.13+<writer>` when Jev graded it.
- Deepen `category.via` = `installed` | `discovery` | `tips` | `other`; `thompson` only for
  wikipedia-cs and Discover. Followed pages learn quality + family from one `prop=cirrusdoc`.

## Additions from stream 2P3

- `Judge.interest_many(candidates, recent) -> [score | None]`: Jev asks up to 12 candidates in
  ONE request (one `score` question per candidate over one shared state); verified live
  2026-09-30 (4 candidates, 1 call, 1.2 s, $0.00007, each score reached its own candidate).
- Daily cache: top-level `week` ("2026-W40") and `potd.entryId`. A Picture of the day that
  relates to no pool article becomes, at most once per ISO week, a Discover entry
  `kind: "potd"`, `id: commons.wikimedia.org/File:…`, `source.wiki: "commons"`,
  `category {family: "visual-arts", via: "daily"}`, intro = the caption cleaned and cut
  (≥ 30 words, else none). The service reloads the index when `potd.entryId` is set.
- Bare `[n]` external links read as their host ("See github.com or zoxide(1)").

## Additions from the post-review round (2026-10-24, stream MODSE: the card's buttons)
- A card's More / Less / "I knew this" press is a CHOICE kept per card in `state.json` `choices` ("tab|id" -> {taste: more|less|"",
  knew, day, f, t, band}); More and Less are one choice (the other switches it, the same again undoes it). Interest hears nothing until
  the day rolls over: `WikiService._commitChoices` at the rollover (rolloverHour) and at a start that finds a past day's choices.
- Service API: `choiceOf(tab, id)` (read with `choiceSerial`), the press entry points; WikiMock adds `commitChoices()` for the mockup.
  Save stays an immediate file write.

