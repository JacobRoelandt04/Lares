# Launcher round 1 — frozen contract

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/launcher_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

**As built (end of round 1):** the names below held; the additions each stream made are in its
own file (D.md "API for the host", I.md "CONTRACT DEVIATIONS", S.md per component). The ones a
host meets: keys are `app:<desktopId>` / `f:<path under the scripts root>`; `config`, `state`,
`favorites` are null until the service's onCompleted -- bind `gridRows`, `gridColumns`,
`iconTheme`; records also carry `keywords`, `description`, `count`, `categories`; op callbacks
are `cb(ok, result, error)`; `entry()` is the level's plain record (a query's match indices are
in `rows`); AppIconRelief's highlight fraction is `focusF` (Item.focus is FINAL) and it takes
`groundColor` and `fallbackHue`; MorphCard takes `raised`; SwipeScrub's first `scrub()` comes
with `active` false and a `commit()` without a scrub is a tilt notch.

Approved plan: `~/.claude/plans/your-job-is-to-parsed-sonnet.md` (decisions + design; do not
re-ask what it lists). Every stream builds against the names below; a stream that needs a
change writes it in its progress file and asks the host (U) — it never edits another stream's
files. Hands off for everyone: `modules/common/theme/Theme.qml`, `themes/eva.json`,
`tools/dev/theme_sync_probe.sh`, `LogoRelief.qml`, `shaders/logo_relief.frag`,
`tools/bake_logo_relief.py` (the stocks session). Existing Theme tokens only.

Test hygiene for every stream: own `SANDBOX=$SCRATCH/lares-sandbox-<stream>` and
`SCRATCH=<session scratchpad>/<stream>`; private `XDG_CONFIG/STATE/DATA/CACHE_HOME` with a
seeded `theme/state.json`; offscreen grabs `QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi`;
never pkill/pgrep quickshell; quit from a Timer; no perf benchmark while another quickshell
runs (perf runs are serialised by the host at the end). Streams do NOT commit; the host
commits each landed stream.

## S — shared components (`modules/common/components/`)

`FavoritesStore.qml`
```
property string path            // set once, static FileView path
readonly property var favorites  // string[]
readonly property int serial     // bumps on every change (read it first in bindings)
function isFavorite(key): bool   // O(1) set lookup
function add(key) / remove(key) / toggle(key)
signal favoriteChanged(string key, bool favorite)
```
Self-echo skip, coalesced atomic `sh … mv` write (AvailableUpdatesService.qml:263-413 moves
onto it, file format `{ "favorites": [...] }` unchanged).

`SortControl.qml` (notes' sort label + FloatingMenu, NotesHeader/NotesPopup move onto it)
```
property Item overlayItem
property var modes: []           // [{ id, label, directional: bool }]
property string mode
property bool ascending: true
property var extraRows: []       // [{ id, label, checked: bool }] after a separator
property string fontFamily: "Inter"
signal sortRequested(string mode, bool ascending)
signal extraTriggered(string id)
function openMenu()
// implicitWidth/Height = the label; label "Name ↑", muted → accent on hover
```

`FuzzyMatch.js` (`.pragma library`)
```
match(query, text) -> null | { score, indices: [int] }         // higher is better
best(query, fields: [string], weights: [real]) -> null | { score, field, indices }
```
fzf-style: word-start bonus, consecutive-run bonus, gap penalty, case-insensitive,
space-separated terms each must match.

Moved from `modules/notes/browse/` (APIs unchanged, notes imports updated):
`DragIntent.js`, `GridLayout.js`. New, extracted from `NotesPopup.qml` (notes consumes them,
bit-identical renders):
- `LevelMorph.js`: `fractions(dir, me) -> { recede, zoom, arrive, faceF }`, `lerp`,
  `lerpRect(a, b, t)`, `zoomRect(r, focus, z)`, `cardRect(tile, full, dir, me) -> {x,y,w,h,s}`.
- `MorphClock.qml`: `morphMs: 320`, `mt`, readonly `me` (OutCubic), `runTo(t)`, `stop()`,
  `scrubTo(p)` (chase the fingers' share p: target `1 - cbrt(1 - p)`, never faster than the
  clock; added 14:35 for the host), `signal landed()`.
- `SwipeScrub.qml`: the swipe-back reader (NotesPopup.qml:981-1125): `units: 900`, `sign: 1`,
  readonly `active`, `gestureWheel(ev): bool`, `signal scrub(real p)`, `signal commit()`,
  `signal cancel()`, tilt notch = one whole back; MouseArea + zero-delta lift + idle timer.
- `MorphCard.qml` generic: `face: Component`, `facts`, `grow`, `faceF`, `tileW`, `tileH`,
  `tileRadius`, `tileColor`, `groundColor`, `radii` (notes passes its three tiles as faces).

## I — icons

`modules/common/icons/AppIcon.qml` (with `AppIcons.qml` and `IconResolve.js`): an app's mark is the icon the active icon
theme gives it, drawn as it is -- a plain Image of the file the theme names, decoded at the size it is seen at (`DeviceScale`),
no processing and no cache of ours (Qt's pixmap cache). A name the theme lacks is the one fallback icon (never Quickshell's
checkerboard); `~desktop` and `~locked` are the Arch mark.
```
AppIcon { size: 40; icon: facts.icon; kind: facts.kind; appId: facts.desktopId }   // a launcher row
property string cls, appId, icon, kind     // what to resolve (a window class, a desktop id, a theme name)
property int size: 40
property bool asynchronous: false
property real renderScale: -1              // device px per item px; -1 finds it (DeviceScale)
readonly property bool ready               // the picture is decoded
```
The baked relief icons this section described before (`tools/app_icons/bake_app_icon.py`, `AppIconStore.qml`,
`AppIconRelief.qml`, the atlas) were removed on 2026-10-31 (9cf29511, "every app icon is the icon theme's own").

## D — data (`modules/launcher/data/`)

`LauncherService.qml`
```
property var iconStore: null                  // host hands the AppIconStore
readonly property var config                  // LauncherConfig (launcher.json)
readonly property var state                   // LauncherState (state.json)
readonly property var favorites               // FavoritesStore($XDG_STATE_HOME/lares/launcher/favorites.json)
property string query: ""
property string sortMode: "default"           // "default" | "name" | "recent" (persisted)
property bool sortAscending: true
property string layout: "list"                // "list" | "columns" (persisted)
property string folder: ""                    // "" = root, else folder key
readonly property int serial
readonly property ListModel rows              // the current level/query; each row { key, rec }
//   rec (a QtObject { property var d }) d = { key, kind: "app"|"script"|"desktop"|"folder",
//   desktopId, name, genericName, icon, folderKey, folderName, isLink, realPath, favorite,
//   frecency, terminal, matchIndices: [int], minis: [desktopId|key] }
function setQuery(q) / setSort(mode, asc) / setLayout(l) / openFolder(key) / closeFolder()
function launch(key, keepOpen)                // records frecency, emits launched
function toggleFavorite(key) / hide(key) / unhide(desktopId) / hiddenApps(): [..]
function makeFolder(targetKey, draggedKey, cb) / moveInto(key, folderKey, cb)
function moveOut(key, cb) / renameFolder(key, name, cb) / addForeign(path, folderKey, cb)
function entry(key): var
signal launched(string key, bool keepOpen)
signal failed(string key, string message)
// added 14:20 for the mockup / probes (host request):
property string configPath / favoritesPath / statePath   // XDG defaults; set once at creation
scriptsRoot override (see D.md for the exact name)
property bool dryRun: false        // launch() starts nothing; records frecency, sets lastCommand
readonly property string lastCommand
readonly property int appCount     // visible root apps before the query
```
`LauncherConfig.qml` (`$XDG_CONFIG_HOME/quickshell/config/launcher.jsonc`, hand-edited, parsed
through `JsonComments.strip` (stocks added it: comments allowed, errors name the line):
`columns: 2, rows: 9,
scriptsRoot, iconTheme, hidden: []`), `LauncherState.qml`
(`$XDG_STATE_HOME/lares/launcher/state.json`: frecency `{id: {count, recent: [ms…10]}}`,
sort, layout), `LauncherFileOps.qml`, `LaunchRunner.qml`, `Frecency.js`, `ScriptHeader.js` —
internal to D.

## U — host (main session)
`modules/launcher/{LauncherBarOwner,LauncherPopup,LauncherHeader}.qml`,
`modules/launcher/browse/{LauncherGrid,AppRow,FolderRow}.qml`, `test_launcher.qml`,
`launcher_popup_probe.sh`, `launcher_render.sh`,
`docs/launcher.md`.

## E — engine
`GooeyBar { thickness; radius (default engine.maxR); reserve (default thickness) }`,
`engine.edgeReserve: { top, right, bottom, left }`; `engine.thickness` only a default.
The launcher's bar: `GooeyBar { edge: "bottom"; thickness: 6; reserve: 0; rawPos: 0;
rawLen: <screen width> }`; the popup opens with
`engine.open(ownerId, barId, rawLen / 2, null, null, false, component, 1)`. Hover on the bar
is the host's (U) input item over the bar's rect, not an engine feature.
