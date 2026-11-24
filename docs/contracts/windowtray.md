# Window title + tray -- CONTRACT (frozen 2026-10-13, before the streams)

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/windowtray_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Plan: `~/.claude/plans/your-job-is-to-peppy-pumpkin.md`. Facts: `0.md` (read it first).
Names below are fixed: a stream that needs another name asks the host (orchestrator) first.

## File ownership

| stream | owns (may create/edit) | must not touch |
|---|---|---|
| **A data** | `modules/windowtray/data/**`, `windowtray.example.jsonc`, `windowtray_js_cases.js`, `windowtray_tray_probe.sh` + `test_windowtray_tray_probe.qml`, `windowtray_service_probe.sh` + `test_windowtray_service_probe.qml` | everything else |
| **B shared** | `modules/common/components/{TextMorph,AppMark,MenuRows,TrayInk}.qml`, `modules/common/components/shaders/icon_ink.frag(.qsb)`, `modules/common/components/FloatingMenu.qml`, `modules/launcher/data/AppIconStore.qml` (the union), `test_floating_menu_render.qml` + `floating_menu_render.sh`, `test_text_morph_probe.qml` + `text_morph_probe.sh`, `test_app_mark_render.qml` + `app_mark_render.sh` | everything else -- and NEVER `modules/screentime/**`, `AppIconRelief.qml` or `shaders/app_relief.*`: another session is rewriting them (2026-10-13) |
| **C module (host)** | `modules/windowtray/*.qml` (not `data/`), `test_windowtray.qml`, `windowtray_{popup_probe,morph_probe,render}.sh` + their QML, docs | A's and B's files |

Everyone may READ anything. Nobody runs `git stash/checkout/reset/restore`. Commit with explicit
paths only (`git commit -m ... -- <paths>`), title `CLAUDE - windowtray <stream>: ...`. Tests run in
the sandbox (`tools/dev/sandbox.sh`, `SCRATCH=$HOME/.cache/claude-windowtray/<stream>`; /tmp has a quota).

## House rules that bite here (CLAUDE.md has the rest)

`pragma ComponentBehavior: Bound` + qualified access; Theme tokens only, never a literal or a
colour Behavior (ease a FRACTION, mix with `Mix.js`); a Repeater model never carries a colour
(rows are FACTS); text-bearing things on whole pixels; lint with
`/usr/lib/qt6/bin/qmllint -I . -I /usr/lib/qt6/qml`; smoke with `tools/dev/smoke.sh`; zero warnings;
a probe that cannot fail proves nothing (arm it); quit from a 0 ms Timer, never onCompleted.

---

## A. `modules/windowtray/data/`

### `WindowTitle.js` (`.pragma library`, node-testable: no Qt calls)

```js
stripSuffix(title, names) -> string      // drops " <sep> <name>" at the END for the first name in
                                         // `names` that matches (case-insensitive, trimmed);
                                         // sep in - — – | · ; never strips to "" (keeps the title)
applyRewrites(title, rules) -> string    // rules [{re, to}] in order; `re` a JS regex string, `to`
                                         // with $1..; an invalid regex is skipped (never throws)
shownTitle(raw, ctx) -> string           // ctx {initialTitle, appName, rules, stripSuffix: bool}:
                                         // stripSuffix(raw, [initialTitle, appName]) then rewrites;
                                         // collapses whitespace; "" stays ""
```
`graphemes` and `diffPlan` are NOT re-implemented: they are `modules/common/components/
TextDiff.js` (written by the host, node-tested by `text_diff_cases.js`); WindowTitle.js
imports it (`.import "../../common/components/TextDiff.js" as TextDiff`) for `stripSuffix`'s
needs only. The BUSY rule (a title that keeps changing swaps instead of morphing) lives in
TextMorph, the one component that decides to animate -- not here.

### `TrayText.js` (`.pragma library`, node-testable)

```js
stripMnemonic(s) -> string               // "_Exit" -> "Exit", "Save__As" -> "Save_As"
stripMarkup(s) -> string                 // tags removed, &amp; &lt; &gt; &quot; &#39; &nbsp; decoded,
                                         // whitespace collapsed
nameOf(f, cfg, lookupName) -> string     // f {id, title, tooltipTitle}; cfg {rename:{id:name}};
                                         // order: cfg.rename[id], title (unless it equals id, case-
                                         // insensitive), tooltipTitle, lookupName, id
statusTextOf(f, name) -> string          // f {tooltipTitle, tooltipDescription}: the tooltip's text
                                         // (markup stripped) that is not just the name; "" when none.
                                         // title+description joined " · " when both say something
collapseSeparators(rows) -> rows         // rows [{separator: bool, ...}]: no leading, trailing or
                                         // doubled separators
```

### `WindowTrayConfig.qml` (Item; FileView + JsonComments like `OsdConfig.qml`)

`configPath` (default `$XDG_CONFIG_HOME/quickshell/config/windowtray.jsonc`), `live` (false: no file
touched), `readonly property var config` with defaults filled:
`{ follow: "screen", stripSuffix: true, rewrites: [{re, to}], terminalClasses: [], terminalTitleMs: 150,
   trayOrder: [ids], trayHide: [ids], trayRename: {id: name}, trayIconMode: "ink", trayPassive: "faint",
   attention: "peek", openOn: "hover", closeOnLeave: true, closeOnActivate: true, desktopText: "Desktop" }`,
`lastError`, `serial`, `ensureLoaded()`. `windowtray.example.jsonc` documents every key (comments
allowed) and ports waybar's two rewrites.

### `ActiveWindowService.qml` and `ActiveWindowMock.qml` (same public API)

```
in:  live: bool                 // false: Hyprland is never touched (LazyLoader inactive)
     follow: "screen"|"focus"   // screen: the last window of THIS bar's monitor's active
                                // workspace (hyprctl -j monitors on workspacev2 / focusedmonv2 /
                                // moveworkspacev2 / monitoradded/removed; 0.md: Quickshell's
                                // monitors are empty); focus: Hyprland.activeToplevel
     screenName: string         // the bar's monitor name ("eDP-1"); "" -> follow focus
     config: var                // WindowTrayConfig.config (rewrites, stripSuffix)
     appLookup: AppLookup       // for appName
out: readonly address, cls, title (raw), initialTitle, appName, shownTitle
     readonly empty: bool       // no window (empty workspace): shownTitle "Desktop", cls "~desktop"
     readonly focused: bool     // this bar's monitor holds the focus (always true for "focus")
     readonly urgent: bool
     readonly serial: int       // bumps on every change of any out property
```
Read-only always: it dispatches nothing. The class is `lastIpcObject.class` (refreshToplevels
on openwindow/closewindow/windowtitlev2 as needed; `activeToplevel` null at start -> the
toplevel with `focusHistoryID === 0`). A title change is the `windowtitlev2` event for that
address; keep the number of refreshes per event at one.

Mock extra: `function setWindow({cls, title, initialTitle, empty, focused, urgent})`,
`function play(name)` / `stop()`, `readonly property var scripts` (names): `kittyCwd` (cwd
edits in one window), `tabSwitch` (browser tabs), `appSwitch` (kitty -> zen -> code -> kitty),
`spinner` (Claude Code's "◐ x"/"◑ x" at ~1.2 Hz), `emptyWorkspace`, `longTitle`, `emoji`
(graphemes: flags, ZWJ family, skin tone). Times by a Timer is fine for the mockup.

### `TrayService.qml` and `TrayMock.qml` (same public API)

```
in:  live: bool                 // TrayService: false -> SystemTray never touched
     config: var                // trayOrder / trayHide / trayRename
     appLookup: AppLookup
out: readonly property ListModel rows   // ONE role, `rec`: a TrayRecord. Rows are mirrored on
                                        // insert/remove (never rebuilt from an array); a record is
                                        // kept by identity for the item's life
     readonly count: int, readonly empty: bool
     readonly attention: [string]       // keys of items in NeedsAttention, in row order
     readonly serial: int               // bumps on insert/remove/reorder (ListModel move emits nothing)
fn:  record(key) -> TrayRecord|null
     leftClick(key) -> bool     // activate() when rec.canActivate; false otherwise (round 2:
                                // a left click NEVER opens a menu -- only the right button does)
     middleClick(key)           // secondaryActivate() if caps say so, else nothing
     scroll(key, delta, horizontal)   // only if caps say so
     menuHandle(key) -> QsMenuHandle|mock node|null
```
`TrayRecord.qml` (a QtObject in `data/`; TrayService and TrayMock both create it):
```
key: string                // item.id, made unique ("id", "id#2") -- the row key everywhere
item: var                  // the SystemTrayItem (or the mock item)
name: string               // TrayText.nameOf, live
statusText: string         // TrayText.statusTextOf, live
iconSource: string         // item.icon, or image://icon/<IconName read by TrayCaps> for an item
                           // without IconPixmap (0.md: Quickshell's checkerboard after NewIcon)
status: string             // "passive" | "active" | "attention"
hasMenu: bool
canActivate: bool          // not onlyMenu and caps.activate not false (round 2)
caps: var                  // {activate, secondary, scroll, known: bool} (known false: assume SNI default)
```
The delegate binds to the record's properties: nm-applet's animating icon changes ONE
`iconSource`, never the model.

`TrayMock`: items from `fixtures/windowtray/*.json` shapes or inline specs, menus as
JS trees with QsMenuEntry's field names (`text, icon, isSeparator, enabled, buttonType,
checkState, hasChildren, children`). Extra: `add(spec)`, `remove(key)`, `setStatus(key, s)`,
`setIcon(key, url)`, `setTooltip(key, t, d)`, `readonly property var log` (actions taken:
`"activate <key>"`, `"secondary <key>"`, `"scroll <key> <d> <h>"`, `"trigger <key> <path>"`) and
`signal acted(string line)`.

### `TrayCaps.qml`

```
in:  live: bool
fn:  capsFor(itemId) -> {activate, secondary, scroll, iconPixmap, known}
     iconNameFor(itemId) -> string ("" until read)
     refreshIcon(itemId)        // re-read IconName (debounced: one call in flight per item,
                                // a request during it re-runs once after)
     refresh()                  // re-read the watcher's list and introspect new entries
readonly serial: int            // bumps when any answer changes
```
How: `busctl --user get-property org.kde.StatusNotifierWatcher /StatusNotifierWatcher
org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems`; per `:<svc>/<path>` entry,
`busctl --user get-property <svc> <path> org.kde.StatusNotifierItem Id` and `busctl --user
introspect --xml-interface <svc> <path>` (methods `Activate`, `SecondaryActivate`, `Scroll`;
property `IconPixmap`). Processes only, a few per registration, nothing per frame.

### `TrayMenuModel.qml`

```
in:  handle: var                // QsMenuHandle (real) or a mock node; null = closed
     mock: bool
out: readonly property ListModel rows   // ONE role `rec`: QtObject { property var d } with
                                        // d = {index, label, icon, separator, disabled, check:
                                        // "none"|"checkbox"|"radio", checked, submenu}
                                        // (MenuRows' row facts), separators collapsed
     readonly loaded: bool      // children arrived (or `loadTimeoutMs` 600 passed: then rows may be
                                // empty and `empty` is true)
     readonly empty: bool
     readonly title: string     // "" (the owner knows the item's name)
fn:  trigger(i) -> bool         // the i-th row's entry triggered() ONCE per open (answer once);
                                // false if not pickable
     childHandle(i) -> handle   // a submenu row's entry, to push as the next `handle`
```

## B. shared components (`modules/common/components/`)

### `TextMorph.qml` (Item)

```
in:  text: string
     fontFamily, pixelSize, bold, color          // the face; colour from the host (themed)
     maxWidth: real (0 = unlimited)
     endFade: real (24)          // px of the end faded into `ground` when cut; 0 = ElideRight
     ground: color               // what the fade fades into (the bar's surface)
     mode: "drift"|"wipe"|"swap"
     durationMs: int (220)       // OutCubic
     driftPx: real (3)
     holdWidth: bool             // true: implicitWidth stays where it is (the strip is open);
                                 // the text still changes inside it, the end fade covers it
     key: var                    // a change of key with the text = a whole replacement (the app
                                 // changed); the host drifts its icon on outF/inF
out: implicitWidth (the cell's width ON THE ONE CLOCK; whole pixels), implicitHeight
     readonly morphing: bool, readonly u: real (0..1 eased), readonly outF, inF: real
     readonly truncated: bool, readonly replacing: bool, readonly keyFrom: var
```
Behaviour: the plan is `TextDiff.diffPlan(shown, next)`. Round 2: EVERY morph plays out (the
user: "always play out the animation"); a text that arrives meanwhile is queued, the latest
only, and morphs from where the running one lands -- the round-1 busy rule is gone. Prefix still; both middles clipped to
the live gap [midX, tailX(u)]; tail slides; two kerning offsets (`pre+X[0]` minus `X[0]`,
hidden Texts of the same face, never FontMetrics); x fractional; a shaping guard (pieces vs
whole > 0.5 px -> swap); `Theme.crossfading` -> settle at once; at rest ONE plain
Text (pixel-identical handover); no Timer/animation running at rest.

### `TextDiff.js` (`.pragma library`, DONE by the host): `graphemes(s)`, `diffPlan(from, to) ->
null | {pre, oldMid, newMid, tail}` on grapheme boundaries; `text_diff_cases.js`.

### `AppMark.qml` (Item) -- a NEW component (not a promotion this round)

Another session is rewriting `ScreentimeAppIcon` and `AppIconRelief` (tinted relief, local
marks) uncommitted in the tree: AppMark uses AppIconRelief's COMMITTED API only (`entry`,
`textureSource`, `groundColor`, `iconSize`, `fallbackHue`, `colourStrength`, `focusF`) and no
screentime file is touched. Unifying ScreentimeAppIcon onto AppMark is backlog, after that
round lands.

```
cls, info (AppLookup record), iconStore, pageProvider (function(page) -> Item|null; default
uses iconStore.pageItem), entryId: string ("" = info.desktopId; "class:<cls>" for an asset
icon), markStyle: "relief"|"flat", flatSource: string (an icon URL/path for flat; "" = from
info.icon via Quickshell.iconPath), size, ground (default Theme.surface), hue, fallbackHue,
fontFamily
```
No entry (nothing baked, no asset): a carved initial in the app's hue (ScreentimeAppIcon's
old fallback, re-created here); `~desktop`: AppLookup's monitor glyph. Flat: the icon as is
(IconImage-like Image, sourceSize x renderScale). `renderScale` in.

### `MenuRows.qml` (Item)

```
rows: var (array of facts, OR a ListModel whose single role is a record with `d`)
keyIndex: int, confirming: string
fontFamily, fontPixelSize, rowHeight, hoverMs, swatches, swatchColor, currentSwatch
signal activated(var row, int index)    // a pickable row clicked (confirm rows: asked first)
signal answered(string id, bool yes)
signal swatchPicked(string key)
signal hoveredIndexChanged(int index)
```
Row facts: FloatingMenu's (`id, label, danger, confirm, disabled, separator, "swatches"`) plus
`icon` (url), `check` ("checkbox"|"radio"), `checked`, `submenu` (a trailing chevron), `back`
(a leading chevron: the submenu's way back). Optional columns take 0 px unless some row uses
them -- FloatingMenu's existing menus render BYTE-IDENTICALLY (`floating_menu_render.sh
BEFORE=<rev>`).

### `TrayInk.qml` (Item) + `shaders/icon_ink.frag`

```
source: url, size: real, mode: "ink"|"colour", ink: color, renderScale: real
```
ink: premultiplied `ink * tex.a * qt_Opacity`; colour: the image as is. The Image is the
texture provider (no layer), `sourceSize` = size x renderScale, whole-pixel placement. Bake
with `tools/dev/bake_shaders.sh` (GLSL 1.20 safe, 300 es).

### `AppIconStore.qml`: `request()` while a bake runs UNIONS the queued list with the new one by
id (the launcher and the bar both ask); `app_icon_store_probe.sh` + a union case.

## C. the module (host) -- for A and B to know who calls them

`WindowTrayOwner` (engine, bar, barId, ownerId, window service, tray service, style,
reelStyle, iconStore, appLookup), `WindowTitleButton` (bar cell: AppMark + peek + TextMorph),
`TrayStrip` (primary, `continuesBarCell`), `TrayCell`, `TraySide` (every level of the engine's
child chain: label | menu by key `"label"` / `"menu:<item>:<level>:<slot>"`), `WindowTrayStyle`.
The owner holds every TrayMenuModel.

### Round 2 (2026-10-13/14): the menu as a child chain

- A submenu is the NEXT LEVEL of the engine's child chain (`engine.childPopups`: the
  secondary, the tertiary, the quaternary), not a key swap with a back row. TraySide speaks the
  engine contract for its own child (`secondaryOpen/Anchor/Side/AnchorAt/WidthFrom`,
  `secondaryChildKey`); the owner keeps per level `levelOpen[]`, `levelKey[]`, `levelAnchor[]`,
  `levelSlot[]`, `levelRow[]`, `levelInfo[][]` and TWO TrayMenuModels (`menuModelOf(level,
  slot)`): the shown one keeps drawing while the next loads into the other.
- A level's SHOWN model is never let go while that level is out: a submenu's entries are owned
  by its parent opener (0.md), and releasing the parent emptied the submenu at rest (item 8).
- Owner API TraySide reads: `menuModelOf`, `menuHeightOf(level, slot)`, `menuRowTop(level, slot,
  i)`, `menuPick(level, slot, index, row, rowTop)`, `setSideHover(level, on)`, `keyLevel`,
  `keyIndex`, `subSide`, `levelOpen/levelKey/levelAnchor`, `sideItem` (level 0 only).
- The strip declares `secondaryAnchorAt` / `secondaryWidthFrom` from the owner: a box laid
  against the bar face (flushGap) is anchored at that face and opens from a point -- out of the
  inner corner of bar and strip (item 5); the menu is anchored at the label's face-side edge, so
  label -> menu grows from that edge with nothing translating (item 2).
- `maskCatchAll: owner.menuOpen` + `outsidePress()`: a press in the void closes everything
  (item 4). A right click on the icon whose menu is out takes it back into its label.

### Round 3 (2026-10-14)

- TraySide (any level) declares for its child `secondaryOpenAt: 0.5` and `secondaryOpenMin:
  menuRowHeight + 2 * menuPad`: held level with its row (anchor point 0), opened about its own
  centre, never from less than one row's menu. The strip passes the owner's `sideOpenAt`: the
  anchor point for a label, 0.5 for a menu opened fresh off the face, the face for a flush box.

### Round 4 (shell assembly round 2, 2026-10-22, stream WT)

- `WindowTrayConfig.config` gains `terminalClasses` (the window classes whose title waits; default `WindowTrayConfig.TERMINALS`, kitty first; `[]` = off)
  and `terminalTitleMs` (0..2000, default 150). `ActiveWindowState` holds a change of THE TITLE ALONE of such a window that long before it writes it
  (a title that comes back within it never shows; the latest is written; any other change writes through and drops what waited); a config object
  without `terminalClasses` holds nothing. `WindowTitle.isTerminal(cls, classes)`.
- `ActiveWindowMock.scripts` gains `kittyCommands`.
- `WindowTitleButton.wantedWidth` (readonly, whole px, uncapped): what the button will ask for once settled -- the cell, the peeks at their targets, the title
  heading for the bar, its end; frozen while the strip is open (caught up at its close) and shrinking only past `WindowTrayStyle.islandDeadBand` (6 px).
  The shell's layout reads it as `widths.windowtray` (`ShellLayout.widthOf`, capped by `titleSlot`). `peekWidth` (readonly, animated) is the room the
  peeking icons take now: the shell cuts the title short of it (`maxTitleWidth`).
- `WindowTrayOwner`: `renderScale` is the POPUP's (label, menus), `stripScale` the BAR's (the strip); `_bar`, `_pop`, `_k` are the engine's two ratios and
  popup units per strip unit. Every number that meets a strip distance with a label's or a menu's goes through `_k`.
