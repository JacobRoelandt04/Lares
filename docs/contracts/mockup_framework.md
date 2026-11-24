# Mockup framework

(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Every module is built as a mockup before it is wired into the bar: the
drop-in content on a stage at its own size, and a control panel beside it
that can reach every value the module exposes. The framework is
`modules/common/mockup/`; a module writes only what is about itself.

Start by copying the template, and lay its panel out by "The panel standard" below:

```
cp mockups/template.qml mockups/<module>.qml
```

- Run it: `quickshell -p mockups/<module>.qml` from the config, or
  `tools/dev/sandbox.sh quickshell -p mockups/<module>.qml` from a copy (the sandbox
  names the config as the mockup's repo, `MOCKUP_REPO`: see Environment)
- Render its tabs: `tools/dev/mockup_grab.sh mockups/<module>.qml --list`, then
  `tools/dev/mockup_grab.sh mockups/<module>.qml <outdir> 0 3.1`
- Exercise the panel: `tools/dev/sandbox.sh tools/dev/mockup_panel_test.sh
  mockups/<module>.qml` (saves into copies; ends in `PANEL_TEST RESULT PASS`).
  Its TARGET check fails when a save made from the copy would be lost -- a
  copy that does not know the real config (`MOCKUP_REPO` set empty).
- Smoke it: `tools/dev/smoke.sh mockups/<module>.qml` — every tab's rows exist from
  load, so one launch exercises the whole panel. Do not pipe a
  `timeout`-killed quickshell into grep; the buffered stderr dies with it.
- Check the switch: `tools/dev/theme_sync_probe.sh` — light/dark must finish
  everywhere at once. It proves it by pixels, then greps for the cause.
- Check the wiring: `tools/dev/mockup_wiring_check.py mockups/<module>.qml` — every
  entry against the component it drives (UNSEEN / MISSING / DEAD / CLASH / DRIFT);
  `--root DIR` checks another tree, `--drift-fails` makes DRIFT a gate
- Save writes the module: `tools/dev/mockup_promote.py dry --all` shows what Save would do
  with every row of every mockup (see "Save writes the real implementation" below)

## What the framework gives you

- **Stage** — the content at its own `implicitWidth`/`implicitHeight`, on a
  surface that eases to it the way `thePopup` will, magnified by a render
  transform (so paddings, fonts and particles keep their true relationship),
  panned when the zoom outgrows the window. The scene stands on WHOLE window
  pixels (its centring offset is rounded): the real shell's window sits at the
  screen's origin, and the engine's clip layer lands on the window's pixel grid,
  so a half-pixel stage made a scene grab and the window disagree
  (`mockup_stage_origin.sh` measures all the mockups).
- **Theme crossfade host** — the window holds a `ThemeCrossfade` over its
  body, so a light/dark toggle on the stage is the snapshot crossfade the
  bar's popup will get (`docs/contracts/theme.md`), not the per-token lerp.
- **Panel** — one tab per component, each scrolling on its own, sub-tabs for
  a component with many values. Sliders and hex colour fields write straight
  into the live content. A slider's value is read in a right-aligned slot
  as wide as the widest figure of what is shown at once (a section: a tab or
  a sub-tab), never under 56 px, so its sliders end on one line and a
  panel with short figures keeps long sliders.
- **`*` marks** — after any label whose live value differs from the mockup
  file's `val:`; a tab pill is marked when it holds one; "Reset tab" puts
  them all back.
- **Save** (the button is still called "Save to mockup") — writes the `*` values into
  the REAL implementation and into this file's own `val:` entries, in one process
  (`tools/dev/mockup_promote.py save`): the module's files first (below), then the mockup
  (`tools/dev/mockup_save_defaults.py`; every other byte is left alone, running it twice
  changes nothing), and adopts the values as the defaults, so the marks clear without a
  restart. Numbers, switches, choices (their index), colours (`#RRGGBB` or `@token`) and
  text all save. Not saved: a themed list (it is the theme) and a **file-backed** list
  (below). Then the files the module side wrote are committed and the running shell
  follows: `tools/shell/lares apply --commit "<moduleId>" <files>` (the mockup's own
  file with them) -- `<NAME> - tuning: <module>`, NAME the first word of git's user.name in capitals, a trial's shell restarted, nothing
  when none runs. A Save that changes NO module file (every row already shipped, refused or
  mockup-only) writes the mockup's `val:` and commits nothing (the old Save to mockup never committed either). The strip under the buttons says in a line what happened (the report
  is on hover and on the Profiles tab): `lares` exits 0 *committed* (a trial's shell
  restarts), 3 *committed, but a deployed shell is recorded and the redeploy is not built
  yet: it was NOT restarted*, 4 *committed, but the restart was refused while a package update runs: it was NOT
  restarted* (`lares restart` when it is over), 1 or 2 *COMMIT FAILED*.
- **Save writes the real implementation** (the user, 2026-10-14: "the mockups could retire
  as the gui settings panels for the modules themselves ... pressing save would update the
  real implementation and I'd be done tweaking without digging into files"). For each row,
  `tools/dev/mockup_promote.py` finds where the module ships that default and writes it THERE:
  - **declaration** -- the module's own component declares the property: its default is
    rewritten in place (`property real glowMax: 2.6` -> `2.4`, the comment after it kept);
  - **override** -- the property is inherited from a shared base (GooeyBar's thickness): a
    root-level line in the module's own type; the base is not touched;
  - **use site** -- the component is SHARED (another module's files use it too: IconReelStyle
    serves the power reel and the window tray, CardViewCycler weather / wiki / clock): the line
    goes at THIS module's use of it -- in the object that instantiates it (a typed property's
    default object, `property IconReelStyle style: IconReelStyle { cellPitch: 38 }`; a dotted
    line through an alias, `rail.glowMax: 2.4`, which stage-0 fact 10 proved works in a module
    file) -- and the shared declaration stays. A modified row of such a component carries a
    **shared** switch: on, Save writes the component's own default instead, which every module
    that uses it follows. A row's tip says which road it takes and where.
  - **the mockup's own knobs** (`tun.popupWidth` on a QtObject the mockup builds) are followed
    through the binding that feeds the module (`StocksBarOwner { popupWidth: tun.popupWidth }`,
    `X ? "Audiowide" : "Inter"` included); one that cannot be followed takes a `promote:` hint
    on the row -- `promote: { to: "Type.prop", map: [...], skip: "reason" }` -- or an entry in
    `tools/dev/mockup_promote_hints.json` (protected directories, run-time roots such as silicon's
    `win._popup`, maps, skips; the row's own hint wins).
  - **A file is a module's own, or shared**, by who uses it: `modules/<dir>/` belongs to <dir>
    (`modules/bar/<sub>/` to bar/<sub>), a file in `modules/common/` to the one module whose files
    use it, and is shared when two do (PhaseRail is the update module's through SystemUpdatePopup).
    The mockup's own content (the drop-in) is its module's whoever else uses it.
  What it **refuses**, with the reason in the row's tip and the report: a binding default (it is
  never overwritten, nor shadowed by a use-site literal), a sentinel (a `-1` default means "the
  config decides": pinning it would override launcher.json), a type that does not fit (2.5 onto
  an int, a string index onto a string property), a readonly property, an alias, a hex over a
  token-bound colour (it would pin one theme's colour into dark mode -- a colour row writes
  `@token` as `Theme.<token>`), a protected file (the battery files `tools/dev/mockup_promote_hints.json` lists, the user's
  standing rule), a collision with another row. Not module settings (`skip`): themed and file-backed rows,
  a mock service's scenario knobs, the mockup's stage furniture. It plans everything before it
  writes anything and writes all the files or none; a Save run from a **copy** of the config
  (tools/dev/sandbox.sh), from a redirected save (`PANEL_MOCKUP_PATH`) or in a tree that is not a git work tree
  (Save commits what it writes: nothing could be committed or undone) writes the mockup's `val:` only
  and says why.
  **Fonts**: `fontFamily: "Audiowide"` written straight on a module object of the mockup, and a
  `dressAudiowide` toggle, are promoted too -- `mockup_promote.py dry|apply --phase fonts` forces the
  shell's face (the dressed branch); `mockup_promote.py set Type.prop=value` writes any property by
  name (a typo is refused).
  The commands: `tools/dev/mockup_promote.py dry --all --summary` (every planned write and every
  refusal), `apply --all --root DIR` (writes into DIR; the orchestrator's promotion), `plan` (the
  panel's JSON), `set`; the gates `tools/dev/mockup_promote_cases.py` (+ `ARM=all`), `tools/dev/mockup_qmlscan_cases.py`
  and `tools/dev/mockup_promote_probe.sh` (+ `ARM=all`: a scratch git repo, a stub lares, a real Save
  from a mockup; P11 swaps the REAL `tools/shell/lares` in where the tree has it, or
  `REAL_LARES_FROM=<dir>` names one, and is skipped aloud where neither exists).
- **Profiles** — every value as one JSON file under
  `~/.config/quickshell/mockup_profiles/<moduleId>/`
  (`tools/dev/mockup_profiles.py`): Save as, Load, Overwrite, Delete. Loading is
  an in-memory apply, so switching between two sets is instant.
- **Both write the real tree.** A mockup run from a sandbox copy
  (`tools/dev/sandbox.sh` rsyncs the config with `--delete` on every call) saved
  into the copy and lost it at the next launch while its status line said
  "1 changed". `tools/dev/sandbox.sh` exports `MOCKUP_REPO=<the config>` (a
  caller's own value wins), and the framework maps the copy's paths back onto
  the real tree (`MockupWindow.repoDir` / `inRepo()`); the self-test fails
  when the target is not a git work tree. Only a deliberate act writes there
  -- Save, a profile -- plus the derived `default.json`, which every launch
  rewrites and a copy writes only while its mockup file is the repo's byte for
  byte (`MockupWindow._mayWriteDefault`): a probe that patched a val in its
  copy, or a copy synced before the user's last save, leaves it alone. A
  probe that presses Save or a profile names a scratch repo of its own
  (`notifications_panel_probe.sh`).
- **File-backed lists** — `fileBackedLists: ({ configParams:
  "notifications.json" })` names lists whose values live in a file of the
  module's own, which the mockup writes as their rows move (a config the
  service hot-reloads). Their `val:` is the code's default and stays so: Save
  to mockup leaves them out (a saved val would be overridden by the file at
  the next launch, or would override it), their `*` says "the file sets a
  value of its own", and their tips say where the value lives. They stay in
  Reset and in the profiles (loading one writes the file).
- **Theme controls** — a light/dark toggle, a theme-pair cycle (disabled until
  a second pair exists) and the global crossfade duration and curve. A list
  named in `themedLists` has its values read from and written to the theme
  (`modules/common/theme/`, see `theme.md`) instead of the module's properties:
  such a row never carries a `*` and cannot be reset, because it *is* the
  theme — its tip says so and names the file it edits. A themed list needs no
  `target` at all: `MockupRegistry.colorOf` / `setColor` read and write the
  token, so its `prop` may name a token the module itself never carries (the
  system update's 16 ANSI slots live in `TerminalBackend`, not in the popup).
  It is also **out of the profiles**: a profile is a snapshot of the module's
  knobs, and one that carried theme tokens would copy the live palette in and
  write it back over `themes/<name>.json` on load — flattening every `@alias`
  in that mode's block, one literal per token. Run from a sandbox copy, a
  themed row is **read-only** (its tip says why): Theme writes the themes of
  the tree quickshell runs from, the copy's, and the next sync puts it back.
- **Toolbar** — zoom with a 1:1 button, and a frame counter that counts the
  window's `frameSwapped` (the frames presented; it makes none of its own, so a
  still stage reads about 0 -- a FrameAnimation would render every vsync). The zoom
  is kept across launches, per module, in
  `$XDG_STATE_HOME/lares/mockup/<moduleId>.json`: what a mockup declares
  as `zoom:` is the starting point, the stored value overrides it -- read at
  load, before `fitContent` sizes the window for it. It is a
  view setting, not a value of the module, so it stays out of the profiles.

## The contract

A mockup is `MockupWindow { ... }` and supplies:

| Property | What it is |
|---|---|
| `moduleId` | profile directory name, and the default `mockupFile` name |
| `content` | the drop-in item; the stage reparents and fills it |
| `lists` | `({ listId: <the array> })` — one entry per value list |
| `target` | the object lists write to |
| `targets` | `({ listId: object })` for lists that write elsewhere |
| `tabDefs` | `[{ name, lists, subs, page }]` |
| `pages` | `[ MockupPage { id: ... } ]`, named by a tabDef's `page` |
| `footer` | `Component`, pinned under the tab pages on every tab (the pages scroll above it); default none, and then the panel is byte-for-byte what it was. Declared in the mockup, so it sees the mockup's ids |
| `themedLists` | list ids whose values are theme tokens, not the module's own |
| `fileBackedLists` | `({ listId: "<file>" })` lists kept in a file of the module's own (out of Save) |
| `fitContent` | open wide enough for the content at its zoom beside the panel; the caption warns while the stage cuts it |

`mockupFile` defaults to `mockups/<moduleId>.qml`; set it when the file is
named otherwise. `stageLabel`, `zoom` and `panelWidth` are optional.
`fitContent` is off by default (a mockup magnified on purpose pans instead);
the notifications mockup's 1280 px scene needs it -- at the old 1480 px
window its Clear all sat under the panel and a synthetic click landed there.

**A list id is the name of the property holding it.** The save script finds
the array in the file by `property var <listId>: [`, so
`lists: ({ railParams: win.railParams })` requires a
`readonly property var railParams: [ ... ]` in the same file.

### Entries

```qml
// numeric -> a slider
{ label: "idle width px", prop: "headerIdleWidthPx", group: "Header inset — idle",
  blurb: "Optional; describes the group. Only on its first entry.",
  tip: "What it does, and why the default is what it is.",
  val: 12, from: 0, to: 40, step: 1 }

// colour -> a swatch and a hex field
{ label: "accent", prop: "accent", group: "Palette",
  tip: "...", val: "#4480F4" }
```

```qml
// choice -> a drop-down; the value is the INDEX (a number: saved, compared
// and profiled as one), the row shows the name
{ label: "corner", prop: "spotCorner", group: "Spot", tip: "...",
  val: 0, choices: ["top-right", "top-left", "right-top", "right-bottom"] }

// text -> a line of text (a font family, a title)
{ label: "title", prop: "managerTitle", group: "Title row", tip: "...",
  val: "Notifications", kind: "text" }

// json -> a JSON box under the label; applied only while it parses and has
// its shape ("array", "strings", "object", "rules": an object of objects),
// red with the reason otherwise. The target property holds the TEXT.
{ label: "apps", prop: "appsRules", group: "Rules", tip: "...",
  val: "{\"kitty\":{\"focusSuppress\":false}}", kind: "json", shape: "rules" }

// a colour that FOLLOWS a theme token: "@<token>" is the component's own
// binding (`property color critical: Theme.error`), left in place at load
// when the component may bind that token, else made at load
{ label: "Critical", prop: "criticalLight", group: "Light theme", tip: "...", val: "@error",
  themeMode: "light" }   // a colour that is the module's colour IN ONE MODE (below)
```

A list is a colour list when its first entry's `val` is a string **without a
`kind`**; nothing else marks it (so bools, choices and text rows live in a
param list, beside the numbers of the same component). `val` is the single
source of the default: pushed into the target on load, restored by Reset,
compared against for the `*` marks, and rewritten by Save.

A **colour row whose default is `@<token>`** follows that token in light and
dark and carries no `*`; its field reads `@error`. At load the component's own
binding is kept when it may be that token (it shows the token's colour, and
no token of that colour parts from it in the other mode -- eva's light
catMultilib is also ansiBrightCyan), so a module that stops following the
theme shows here; otherwise the load makes the binding, which is what a
token SAVED over the module's own needs (`System -> @accent`). A hex typed over it is an
override -- one colour in both modes, marked, saved and profiled like any
value; typing `@<token>` (or Reset) puts the BINDING back (never the hex the
token happens to show: that would pin the light colour into the dark theme).
This is how a module's own palette is tuned without touching the shell's
tokens; a `themedLists` list is the other way, editing the theme itself.

**A per-theme colour row** (`themeMode: "light" | "dark"`, round 3: the
notifications' group palette keeps a colour per group per theme, a light and a
dark row each). The module's property is still the plain `Theme.<token>`
binding, which holds the token as it stands in the mode ON SCREEN; the row for
the other mode would therefore show the wrong colour. So for such a row the
registry answers `colorOf` (swatch and hex field) with the token's other-mode
value (`Theme.counterpart`) while its mode is not the one on screen, and
`tokenColorFor(e, tok)` is the token colour the "typed hex equals the default
token" rule compares against. A hex override on one row leaves the other
mode's row at its token; Save, profiles, Reset and `*` are the ordinary ones
(`"@error"` is still the binding, never the hex). The module decides which
row it reads (`GroupPalette.color()`), and how it follows a switch (held mode
under a crossfade picture, a glide on `Theme.fadeProgress` without one) --
see its header; the framework only keeps the rows honest.

**Every entry carries a `tip` and a `group`.** A six-word label cannot say
what "orbit spring" does, and an unexplained slider is one nobody dares
move. This is a rule, not a preference.

**A tip is a claim about the component, and it goes stale with it.** The
notifications panel described SideFade's painted bands for a round after
another stream had rebuilt SideFade to draw nothing, and one tip gave a
number the module no longer produced. Write a tip in the component's own
terms, measure every number it states, and where the component belongs to
someone else, hold the tips to it with a check:
`notifications_panel_tips_check.py` reads the terms, the lines and
whether it can paint from SideFade.qml itself, and the panel probe's `tips:`
steps measure the numbers the tips state on the live stack.

**A `prop` is a property of the module**, never of the mockup. The panel is
only ever a second way to set what the module already exposes; if a value
cannot be reached from the outside, give the component a property for it
rather than reaching into it from the mockup.

`tools/dev/mockup_wiring_check.py` holds you to that. It reports **MISSING** (no
such property — the control writes nothing), **DEAD** (nothing reads it — the
control changes nothing on screen), **CLASH** (the host binds it too, so the
control fights that binding) and **DRIFT** (the mockup's `val:` differs from
the component's own default, so the mockup does not show what the module
ships). The first three exit non-zero.

"Nothing reads it" means the component's own file — and, for a **data object**
whose whole job is to hold numbers for other components (a style shared by
several instances, so that one slider moves all of them), any file under
`modules/` that names its type. Such an object reads none of its own
properties, and every one of them would otherwise be reported dead.

A list in `themedLists` is checked against the theme instead, because it has
no target and the host binding it "clashes" with is the very one that must be
there: **MISSING** is then "no such theme token or alias" and **DEAD** is
"nothing reads `Theme.<token>`".

### Tabs

```qml
tabDefs: [
    { name: "Run",   page: runPage },                       // your own controls
    { name: "Card",  lists: ["cardParams", "cardColors"] },
    { name: "Rail",  subs: [                                // one component, split by what its values do
        { name: "Swirl",   lists: ["railParams"], groups: ["Glow", "Chase"] },
        { name: "Colours", lists: ["railColors"] } ] },
    { name: "List",  lists: ["listParams"], page: listPage } // lists first, then your page
]
```

`groups` narrows a list to those groups, so a forty-value list is split
across sub-tabs without being split in the data. A tab's Reset and its `*`
mark cover every list it reaches, sub-tabs included. The Profiles tab is
appended by the framework.

**All the settings of one component live on one tab.** Splitting them by
kind (all sliders here, all colours there) means tuning one card is a tour
of the panel.

### Pages

A `MockupPage` is a column you fill with your own `TipRow`s, `TipGroup`s,
buttons and readouts — everything that is not a plain number or colour:
what drives the content through its states (a replay, a synthetic run,
per-state jumps), what data it is fed, what it draws. Declare it in `pages`
and name it from a tabDef; the framework parents it under that tab, after
the tab's lists.

`TipRow { tip: "..." }` is a `RowLayout` that explains itself on hover — use
it for every row. `TipGroup { title; blurb }` separates one group from the
next.

### PoseRecorder — scrubbing an animation

A QML animation cannot be looked at. `Animation` has `paused` and nothing else:
no seek, no current time, no reverse. So a choreography made of
SequentialAnimations can be watched at full speed or slowed down, and that is
all — you cannot stop on the frame where a sweep overshoots and step back three
frames to see what it did.

`PoseRecorder` records the RESULT instead. It samples a handful of an object's
numeric properties every frame and plays those frames back — forwards,
backwards, one at a time, or scrubbed to any moment. What plays back is not a
re-derivation of the animation, it is the exact frames the animation produced,
so what you scrub through is what you saw, and the module under it is the
module as it ships.

```qml
PoseRecorder {
    id: rec
    target: popup.vinyl
    props: ["spinDeg", "tiltX", "discHeight", "sleeveX"]
    historySec: 20                        // the ring buffer's depth
    onBeforeScrub: popup.vinyl.freeze()   // stop what else writes the pose
}
```

`arm()` clears and records from now; `seek(ms)`, `step(frames)`, `play(dir)`,
`pause()` and `release()` are the transport; `position` is writable, so a
slider bound to it IS the scrub. `frameCount`, `spanMs`, `frameIndex`,
`scrubbing`, `playing` and `valueAt(name)` are the readout.

Three rules:

- **Numbers only.** Frames are interpolated so a scrub can land between two of
  them, and there is no sensible interpolation of a string.
- **Nothing a binding drives.** Playback assigns, and an assignment from JS
  onto a bound property destroys that binding for good. Pose properties an
  animation writes are exactly right; a colour bound to a theme token is
  exactly wrong.
- **`beforeScrub` is not optional.** It is the host's one chance to stop
  whatever else is writing the pose. Both writing it is the only way this tool
  can lie about what it recorded, and `vinyl_transport_probe_run.sh` arms
  exactly that fault to prove the check is real.

The cost, stated plainly: you can only scrub what has already happened. Run the
sequence once, then walk through it.

`Component.onCompleted` on the mockup's root is safe: the framework's own
handler on the same object runs first (verified), so the defaults are in the
targets before your startup code runs.

## The panel standard

Every mockup's panel is laid out one way, so whoever knows one panel finds their way in all of them. The way is the clock's
(`mockups/clock.qml`, the user's pick), written down here; `mockups/template.qml` follows it. It is about the PANEL: the rows' `prop`,
`val`, `step` and targets are the module's and stay what they are -- only tabs, groups, the order of rows, labels, tips and blurbs follow
the standard.

### Tabs, in this order

| # | Tab | What it holds |
|---|---|---|
| 1 | **Run** | Always first, always called Run: the tab a mockup opens on. What DRIVES the content, never a value of the module: where the data comes from (mock or real, a scenario), one-click states, the calls that move it (navigate, send, open, play), what may reach the desktop (opt-in, off by default), and last a **State** readout of what the content holds now. A mock's knobs that put the content in a state (silicon's machine) are lists on this tab. The mockup's own stage furniture that is not a toolbar control (a stand-in bar, a bar edge) is a **Stage** group here. A second page that drives (a fault injector, an animation recorder) is the second tab, under its own name. |
| 2 | **One tab per component** | Named for the component (Calendar, Rail, Composer), never for a kind of value (no "Sliders", no "Timing"). Outermost first: the popup's frame (Layout / Popup: padding, widths, radii, the tab row), then its parts in the order the eye meets them -- top to bottom, left to right, the popup's first tab before its second --, then what opens from them (a secondary, another face). An aspect the whole scene shares (a popup-wide Swipe, silicon's Motion) is a component of its own, after the parts. |
| 3 | **Colours** | A palette several components read (the notes' tints, the weather's hues). A component's own colours stay on its own tab. |
| 4 | **The bar side** | The bar button (Button, or its own name: Bell) and what the module draws in the bar (Bar). |
| 5 | **Config**, **Data** | Config: the rows a file of the module's own keeps (`fileBackedLists`, the config the service reads). Data: a mock service's tuning that is not a state (the wiki's rabbit-hole odds). |
| 6 | **Host** | The stand-ins the mockup builds for the shell around the content (the engine's thickness, thePopup, the toast lane). |
| 7 | **Profiles** | Appended by the framework. |

The clock is Run | Layout | Calendar | Month | List | Timers | Button | Bar | Profiles. It used to put Timers after Button (the
timers card came after the button tab existed); the standard moves the popup's second tab in with its parts, ahead of the bar side.

**A list lives on ONE tab.** A tab's Reset and its `*` count cover whole lists, so a list spread over two tabs would be reset from
either. Split a list by `groups` across the sub-tabs of one tab instead.

A module whose config file IS the component (the shell: shell.jsonc is the bars' layout) keeps the file-backed rows on that
component's tab, as its first sub-tab named for the file (`shell.jsonc`), the code's own numbers beside it (`Constants`).

### Sub-tabs

A tab longer than about 20 rows splits into sub-tabs (`subs`), each named for what its groups do (one to three groups; `groups`
narrows a list without splitting it in the data, and every row must be on some sub-tab). The component's colours, when the tab has
any, are the last sub-tab, **Colours**. A tab's page is drawn under the lists on every sub-tab. The clock has no sub-tabs: Timers, its
longest tab, is 16 rows in 4 groups.

### Groups

- **Every row has a `group`**: a part of the component or one thing it does, in one to three words, sentence case ("Tab row",
  "Month slide", "Motion blur"). Never "Misc", "Other", "Advanced", "Params".
- **The first row of every group carries a `blurb`**: one line, what the group is ("The coloured square that marks the selected
  day."). The panel draws the heading and the blurb above the group.
- **A group's rows are contiguous in their list.** The heading is drawn where the group changes, so a group split in two shows its
  heading twice.
- **Groups run in the order the clock's tabs do**: what it is (size, layout, geometry), how it looks (type, ink, carve, fill), how it
  answers (swipe, wheel, drag, keys), how it moves (durations, staggers, springs), what it costs (repaint rate, debounce, loading).
  A component made of parts takes its parts in reading order instead, each part's groups in that order.

### Rows

- **`label`**: lower case, a few words, with the unit when the number would be ambiguous without it ("glide ms", "stagger ms",
  "merge px", "sticky edges"). A switch's label says what is ON.
- **`tip`**: three things, in the component's own terms, present tense:
  1. what the value does on screen (or in the module's behaviour);
  2. its unit, when the label does not give it (px, ms, degrees, a fraction of something, wheel units);
  3. why the default is that number ("12 is the shell's popup padding", "55, the same as the grid's week rows").
  A number a tip states is measured, not remembered. No history: no dates, rounds or who asked -- the reason, never the story of it.
  The framework appends the rest itself (where Save writes the row, the file a file-backed row lives in, the value Reset puts back),
  so a tip does not repeat it.
- The row that matters most comes first in its group.

### Pages

- Every control on a page sits in a `TipRow` whose tip says what it does and what it leaves alone; every group of a page starts with a
  `TipGroup` with a `blurb`.
- The Run page's groups, in order: the data (source, scenario), one-click states (Scenarios), the calls that drive it, what would reach
  the desktop (opt-in, off by default), Stage (furniture), State (the readout, last). The clock: Data, Navigate, State.
- A page holds what is not a value of the module: drives, readouts, previews, furniture. A value of the module on a page (a slider
  writing a property) belongs in a list, where it has a `*`, a Reset, a profile and a Save; if the module cannot be reached for it, the
  module gets a property first.

### Reset, marks, Save

- Every tab that shows a list has **Reset tab** in its header (the framework draws it): every list of the tab, sub-tabs included,
  back to its `val:`. A right-click on a row resets that row alone. A page-only tab (Run) has nothing to reset.
- The `*` marks, the tab pill's mark, the status line's count and **Save** (the button "Save to mockup") are the framework's, on every
  mockup alike.

### Stage controls

The toolbar above the stage is the framework's and the same on every mockup: **zoom** (slider and 1:1, kept per module across
launches), the **fps** meter (frames presented, off by default), and on its own line under them the **theme** controls (light / dark,
the theme pair, the crossfade's length and curve). They are view settings: out of the tabs, the profiles and the `val:` defaults. A
mockup does not repeat them on a page. A view option of its own that the toolbar has not got (a bar edge, a render scale, a stage
size) is a Run-page Stage control, or an env variable named in the file's header.

## The content

What the mockup is for is the drop-in, so it must be exactly that:

- **Sized through `implicitWidth`/`implicitHeight`**, per view mode. The
  stage takes its size from them and animates; `width`/`height` on the
  content means the stage cannot size itself and says so on the stage.
- **Self-contained.** No assumption about the host beyond what the module
  documents (`SystemUpdatePopup` is the reference: `verbosityMode`, the
  swipe hold contract `swipeGestureActive` / `gestureHoldWidth`/`Height`).
- **Shared pieces come from `modules/common/components/`** — ShadowBox,
  ListSectionHeader, DownloadStats, RaisedButton, PhaseRail, TabSelector,
  ListSkeleton, GrooveSlider, particles. Before writing one, ask whether it
  exists; when a module grows something general, move it there.
- The mockup may dress it (the user's mockups use `Audiowide`), but the
  module keeps its own defaults.
- **A content whose size changes** is seen through the stage's easing box
  when the mockup sets `clipContent: true` -- what the bar's engine shows
  (GooeyBody clips at the box it animates); off, a layout that changes
  first paints outside the popup still easing after it. A clip delivers no
  input outside its rect, so the stage then also keeps the engine's
  gesture hand-over: while the content's `swipeGestureActive`, a wheel
  outside the stage goes to its `gestureWheel(ev)`. `mockups/clock.qml` is
  the user; `clock_stage_probe.sh` proves both halves.

## Environment

| Variable | Effect |
|---|---|
| `GRAB=<png>` `GRAB_MS=<n>` | grab the window after n ms (1500) and quit |
| `PANEL_TAB` / `PANEL_SUBTAB` | which tab the window opens on |
| `PANEL_LIST_TABS=1` | print `PANEL_TABS 0=Run 3.1=Rail/Sparks ...` and quit |
| `PANEL_TEST=1` | run the panel self-test, ending in `PANEL_TEST RESULT` |
| `FPS=1` | start the frame counter at load and print each reading, so a rate can be compared between two builds from a log rather than read off a label |
| `PANEL_MOCKUP_PATH` / `PANEL_PROFILE_DIR` | save and profile elsewhere (the self-test uses copies); a redirected save does not write the module |
| `PANEL_SAVE_TEST=<json>` | apply `{listId: {prop: value}}`, press Save, print `PANEL_SAVE_TEST ...` lines, quit (`tools/dev/mockup_promote_probe.sh`); `PANEL_SAVE_SHARED=list.prop,...` first turns those rows' shared switches on; `PANEL_SAVE_HOLD=1` stops before Save and `PANEL_SAVE_KEEP=1` stays up after it, so a `GRAB` shows the modified rows / the strip |
| `MOCKUP_PLAN=1` | ask `tools/dev/mockup_promote.py plan` what Save would do per row even in a scripted mode (an interactive session asks a moment after load; a grab, a render or a probe never does, so its panel is what it was) |
| `MOCKUP_LARES=<path>` | the program Save commits through (default `<repo>/tools/shell/lares`; a probe's stub) |
| `MOCKUP_STAGE_ORIGIN=1` | print where the scene stands in the window and quit (`mockup_stage_origin.sh`: whole pixels, as in the real shell) |
| `MOCKUP_REPO` | the config tree the mockup belongs to, when it runs from a copy: Save to mockup and the profiles write there. `tools/dev/sandbox.sh` exports it (the config it copies) unless the caller set it; set EMPTY, every write stays in the copy (and the self-test fails). From a copy a themed row is read-only (Theme writes the tree quickshell runs from, the copy's) |

The zoom is stored per module in `$XDG_STATE_HOME/lares/mockup/`; delete
that file to go back to the mockup's declared `zoom:`.

`PANEL_GRAB` and `PANEL_GRAB_MS` still work as names for `GRAB` / `GRAB_MS`.
A grab prints `GRAB saved <png> panel=<x>`: the panel's left edge, where
`tools/dev/mockup_grab.sh` crops the `_panel.png`. A tab name may hold spaces
(`3.2=Manager/Pin flight`); the keys are the `<n>=` / `<n>.<m>=` tokens of the
PANEL_TABS line (`tools/dev/mockup_grab.sh --keys < log` is that parse alone).

The self-test (`PANEL_TEST=1`) nudges the first row of the first and last
numeric and colour lists, the first switch, and one row of a file-backed list:
that one must come out of Save to mockup still modified, its `val:`
unchanged. Its Save PLANS the module and writes none of it (`--module-dry`), and
waits for the save to end -- planning is seconds, not the 20 ms of the old `val:`
rewrite. `tools/dev/mockup_panel_test.sh` then checks where an unredirected save
and the profiles would go: a file that exists, inside a git work tree -- a
sandbox copy has no `.git`, which is how a copy that does not know the real
config is caught -- that the COPY of the mockup differs from the original in
nothing but `val:` lines, and that no module file of the tree moved.

Module-specific env stays in the module's own file (the system update has
`AUTORUN`, `AUTORUN_MODE`, `AUTO_SWITCH`).

## Files

```
modules/common/mockup/
  MockupWindow.qml     the window: stage, panel, env, self-test
  MockupStage.qml      the zoomable stage that follows the content's size
  MockupPanel.qml      tab strip, the modified count, Save to mockup
  MockupTabPage.qml    one tab: header, Reset, sub-tabs, lists, your page
  MockupTabPill.qml    a tab pill
  MockupPage.qml       a page you fill yourself
  MockupRegistry.qml   lists, targets, defaults, the * bookkeeping, and the
                       one place that knows whether a row is a property or a
                       theme token (colorOf / setColor)
  MockupStore.qml      save-to-mockup and the profile store
  ParamList.qml        a param list's rows: slider, switch, choice, text, JSON
  ColorList.qml        swatch + hex field from a colour list
  TipRow.qml           a row that explains itself on hover
  TipGroup.qml         a group heading
  PoseRecorder.qml     records an object's numeric properties per frame and
                       plays them back -- the only way to scrub a QML animation
  ProfilesPage.qml     the Profiles tab
tools/dev/
  smoke.sh                  load QML files and report every warning
  theme_sync_probe.sh       light/dark finishes everywhere at once
  mockup_grab.sh            render tabs to PNG (--list to see them, --keys to parse a line)
  mockup_panel_test.sh      marks / profiles / save round trip, on copies
  mockup_wiring_check.py    every entry against the component it drives
  mockup_save_defaults.py   rewrite `val:` entries in a mockup file
  mockup_promote.py         Save's other half: the module's files (dry / apply / plan / save / set)
  mockup_model.py           what the pipeline knows of the tree: modules, sharing, a row's target chain
  mockup_qmlscan.py         the tolerant QML structure scanner both stand on
  mockup_promote_hints.json what no mockup can say (protected dirs, run-time roots, skips, maps)
  mockup_promote_cases.py   mockup_qmlscan_cases.py   mockup_promote_probe.sh   the gates
  mockup_profiles.py        the profile store
mockups/template.qml        copy this to start
```

`mockups/system_update.qml` is the worked example: nine tabs, four rail
sub-tabs, ~180 values, a Run page that drives a real `yay -Syu`, a replay
and a synthetic run.
