# Theming the shell (and the desktop)

(The progress notes this contract names (`shell_progress/`) are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/shell_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Design settled 2026-08-30 from four investigations, three competing proposals
and three judges. The traps at the end are all measured, not guessed.

**Built so far (2026-08-31):** the engine (`modules/common/theme/Theme.qml`, a
singleton), the eva light/dark pair (`themes/eva.json`), the crossfade, and the
mockup's theme controls. `SystemUpdatePopup` reads every colour from it, and
`MockupRegistry` routes the mockup's colour lists through it rather than
writing the popup's properties. Steps 1, 2, 7, 8 (beyond the one module), 9 and
10 of the migration below were still to do then — in particular nothing outside
quickshell was themed, so `themectl` and `~/.config/theme/themes/` did not
exist: the shell read `<repo>/themes/*.json` and only
`~/.config/theme/state.json` was written.

**Since then (2026-10-21, shell round 2, stream T): `themectl` exists, and the
themes have a home.** `tools/theme/themectl` (`apply`, `set`, `toggle`, `next`,
`diff`, `list`, `doctor`, `install`, `restore`, `resolve`) writes the desktop's
colours from templates for the quickshell state file, the wallpaper, Hyprland,
kitty, btop, starship, GTK, fastfetch and hyprlock (+ the old script's state
file, kept in step); the themes live in `~/.config/theme/themes/` (the user's
copies first, `<repo>/themes/*.json` the fallback, a Save landing in the file
that was read); the resolver is written twice (themectl and
`modules/common/theme/ThemeResolve.js`, held to the same answers by
`tools/dev/themectl_resolver_parity.sh`); and the shell's theme button can drive it
(shell.json `"theme": { "apply": "themectl" }`; `"shell"`, the Theme singleton
alone, is the default until the user has read the diff). The table against the
old `theme-switch.py`, the one-time edits the user makes, the facts measured and
the gates are in `docs/agent_added_files_and_folders/shell_progress/T.md`.

51 tokens. The 18 added on 2026-08-31 are the terminal's: `terminalSelection`,
`terminalSelectionText`, and the sixteen ANSI slots
(`ansiBlack`…`ansiBrightWhite`), copied from the user's own kitty themes so the
popup's scrollback and a real kitty window colour yay identically. They are
per-slot properties rather than the `"ansi": [...]` array this document first
sketched, because the control panel addresses one token per row; `Theme.ansi` /
`Theme.ansiBright` are built from them for `TerminalBackend`, which indexes
them by SGR code. A colour is baked into a line's HTML when the line is parsed,
so an edit (or a switch) reaches output that arrives after it; scrollback keeps
the ink it was written in. Unstyled text — the bulk of a run — follows
`terminalFg` live, because the view sets its own `color` from it.

**Second sweep, 2026-08-31.** Switching to dark exposed what a theme cannot
reach: not a wrong token but a colour nothing ever passed. Seven of them, all
the same shape — a component declaring an eva-light literal that no host
overrode (`GrooveTrack`'s channel through `PhaseRail`, `ListSkeleton`'s
`rowBarColor`, `ShadowBox`'s defaults under the prompt's text fields,
`RaisedButton`'s two text colours, `TerminalBackend`'s palette,
`TerminalView`'s chrome) — plus one that was a *relationship* rather than a
value (`UpdatePackageRow`'s muted stripe: an absolute lightness of 0.72, which
is drained on a light list and brighter than the fill it must light up into on
a dark one; it is now a fixed fraction of the way from the ground the row lies
on toward mid-grey, which reproduces 0.72 exactly on the light list box). The
lesson is in the traps below.

## The decision

Three layers, two files, and the code keeps its defaults.

- **L0 — the shipped default, in the code.** For the ~45 shared tokens that is
  the declaration in `ThemeScope.qml`; for a module's private knobs it is the
  last argument of `theme.n("headerIdleWidth", 7.5)` at the site that uses it.
  Never copied into a file. Delete every JSON and the shell renders as coded.
- **L1 — the theme**, `~/.config/theme/themes/<name>.json`: ~45 tokens, a
  light/dark pair, hand-written, ~90 lines. The desktop's source of truth,
  read by quickshell *and* nine other programs.
- **L2 — the overlay**, written by the mockup panel, empty until you touch
  something. `overrides.json` holds detached tokens (per theme, per mode);
  `tuning.json` holds live values for module-private knobs (theme-blind).

A module claims a scope once — `property ThemeScope theme:
Theme.forModule("system_update")` — then reads `theme.accent` for tokens and
`theme.n(key, default)` for its own knobs. Children take `theme: root.theme`,
which replaces the 243 colour pass-through lines threaded by hand today.

Switching is one atomic write of `~/.config/theme/state.json`. A `FileView`
sees it and bindings re-evaluate in 1–2 ms: **the engine is never reloaded and
nothing in the session resets.**

## Why this shape

**Verified:** writing JSON anywhere never triggers Quickshell's scanner;
editing a `.qml` always does. So a theme must be data, not code — and that is
also why "Save to mockup" resets a running mockup while a profile save does
not.

**Overruled, deliberately:** do not put every panel value in the theme file.
962 of the shell's ~1206 knobs are numerics that do not differ between light
and dark. Pinning them into generated JSON inverts the source of truth — the
QML literal they came from becomes decorative, and `mockup_wiring_check.py`'s
DRIFT check reports green while the JSON says something else. Live-tuning a
deployed shell and theming it are two different lifetimes, so they get two
files.

**Also overruled:** `squishMax`, the 11 particle tunings duplicated verbatim
between `PhaseRail` and `Workspaces`, and the recovery spring that reads
2.5/0.2 in `SquishItem` and 3.2/0.20 in `GrooveSlider` are **drift, not theme
values**. They must be one number — fixed by one shared defaults object in
`modules/common/components/`, not by putting eleven spark values in every
theme file forever.

## File format

```
~/.config/theme/          # NOT inside ~/.config/quickshell — nine programs read it
  state.json              # {"theme":"eva","mode":"light"} — the only file a toggle writes
  themes/eva.json         # a light/dark pair, ~90 lines
  overrides.json          # detached tokens; machine-written; empty until you detach
  tuning.json             # live module-knob values; machine-written
  targets.json            # per-app file + template + reload command
  themectl                # the generator; replaces theme-switch.py
```

```json
{
  "name": "eva",
  "common": {
    "radiusContainer": 14, "radiusCompact": 10, "pad": 12,
    "resizeMs": 260, "fadeMs": 160, "easeStandard": "OutCubic",
    "fontUi": "Inter", "fontDisplay": "Audiowide", "sizeBody": 12
  },
  "light": {
    "surface": "#EAEDF5", "surfaceSunk": "#E1E4EB", "surfaceListBox": "#E6E9F0",
    "bevel": "#EEF0F7", "border": "#CED1D7", "shadowDeep": "#AAADB4",
    "textPrimary": "#5D5D5F", "textMuted": "#8A8A8C", "textFaint": "#B8BBC2",
    "textOnAccent": "@surface",
    "accent": "#4480F4", "accentHover": "#4D91F8",
    "ok": "#44C145", "warn": "#FF6D12", "error": "#EC0000",
    "catCore": "@warn", "catExtra": "@ok", "catAur": "@accent",
    "ansiBlack": "#5D5D5F", "ansiRed": "#F14C4C", "...": ""
  },
  "dark": { "surface": "#1E1E2E", "accentHover": "@accent lighten 0.06", "...": "" },
  "assets": {
    "light": { "gtkTheme": "Everforest-Teal-Light", "vscodeTheme": "Eva Light Bold",
               "wallpaper": "eva_-_light_-_pink-dunes.jpg" }
  }
}
```

Rules that keep it hand-writable:

- **`common` merges under both modes** — a duration is written once.
- **Every key is optional**, falling through to L0 (the *code* default, not
  another theme's colour). A nine-line derived theme is legal; a half-written
  dark block renders as shipped light values, not as magenta.
- **`@name` is an alias, `@name lighten|darken|alpha n` a recipe**, cycle-
  guarded. `catAur: "@accent"` splits roles that share a hex today so they can
  move apart later.
- **Literals stay first-class.** `#4480F4 → #4D91F8` is not reproducible by
  any single lighten (best factor is 14/255 off per channel). Store the pair.
- Generate the first theme, don't type it: `themectl dump-shipped >
  themes/eva.json` writes out the L0 declarations.

## Shared by default, detach is a switch

Tokens are **declared properties** on `ThemeScope`, not string lookups —
`theme.surfce` becomes a lint error instead of a value that is silently
unthemeable, and a shared-token drag costs **0.62 ms/tick instead of 15.5**
(measured both ways). `c(key, def)` / `n(key, def)` stay public for
module-private keys only.

Overrides are keyed **theme → module → token → mode**: a hex tuned against
eva-light is meaningless under everbox, and a detach made in light must not
survive the flip onto a dark surface. `setDetached()` seeds the override with
the value already on screen, so flipping the switch changes nothing visually —
it only redirects where the next edit lands.

Each scope gets its own slice pushed to it; scopes do **not** bind to one map
on the singleton (13 ms/tick vs 3.2, and one detach would invalidate every
module).

## What "Save" means, per gesture

| Gesture | Writes | Lifetime | Live? |
|---|---|---|---|
| Theme tab, any row | `themes/<name>.json` | the theme, all apps | yes, 1–2 ms |
| Module tab, token row, detach **off** | same file — it *is* the token | the theme | yes |
| Module tab, token row, detach **on** | `overrides.json` | this theme + module | yes |
| Module tab, private knob | `tuning.json` | this module, all themes | yes |
| **Save** (to mockup) | the module's files (its declaration, or its use of a shared component) **and** `val:` in `test_<module>.qml`, committed through `lares apply --commit` | the shipped default (L0) | **no** — reloads the engine; a running trial's shell restarts on the commit |
| Profile Save | `mockup_profiles/<module>/<name>.json` | a scratch experiment | n/a |

One sentence: **`tuning.json` is what you edit at 11pm on a running shell;
"Save to mockup" is what you commit in the morning to make it the default** -- and since the
shell assembly it commits itself: Save writes the module's real default (tools/dev/mockup_promote.py:
`mockup_framework.md`, "Save writes the real implementation"), so there is no morning step.
Add a **"Promote to shipped default"** button that does the `val:` rewrite and
deletes the now-redundant `tuning.json` entry, so the two can never disagree.

## Tooltip provenance

Two sources, because a mockup window only instantiates one module yet the tip
must name the others.

- **Static:** `theme_scan.py` → `modules/common/theme/usage.json`,
  generated and committed. Pass 1 builds each module's instantiation closure
  (the regex must catch `Common.ShadowBox {` and `delegate: Foo {`, or six
  components are lost). Pass 2 joins the tokens each reachable file names.
- **Live:** the detached set, read from the scope maps, mode-aware.

> **textMuted** — secondary text: subtitles, counts, the prompt's detail line.
> Takes effect in: clock, system update.
> Detached in: battery (light, `#7A7B80`).
> Also reaches, not loaded here: audio.

**Runtime provenance is not available** — with declared token properties QML
evaluates every one at completion, so a scope reports all 45 "used" whether
read or not. The manifest is what pays for the typed façade.

Three checks join `mockup_wiring_check.py`: **UNREACHED** (an entry names a key
nothing reachable asks for), **UNSCOPED** (a reachable file asks for a token but
was never handed `theme: root.theme`, so a detach silently cannot reach it —
the design's weakest joint) and **COUPLED** (one key, two different L0
defaults).

## Replacing theme-switch.py

`~/.config/theme/themectl`, one Python file driven by `targets.json`, so an
upstream format change is a JSON edit rather than a code edit. **Every target
prints `ok` or `FAIL <reason>`** — the old script's real fault is not any one
target, it is `stdout=DEVNULL, stderr=DEVNULL` on line 106, which is why two
completely dead targets went unnoticed for months.

Colour-driven, each a whole file themectl owns (every primitive verified on
this machine): **waybar** (`@define-color` + SIGUSR2, reloads CSS in place),
**wofi**, **mako** (`include=`), **hyprlock** (`source =`), **hyprland** (a
generated `.lua` + `hyprctl eval "dofile(…)"`), **kitty**
(`current-theme.conf`), **starship**, **wleave**, **quickshell**. **btop** is
not colour-driven any more (stream TB, 2026-10-22, the user: "ignore custom btop
palettes for now"): `themes/current.theme` is a LINK to the stock
`flat-remix(-light).theme` of the mode, named by the theme's `assets` (+
SIGUSR2); the shell-token template waits, unrendered.

Cannot be colour-driven — these take a preinstalled name or an asset, which is
what the theme's `assets` block is for: **VSCode** (hand `window.autoDetectColorScheme`
+ preferred light/dark themes once, then a mode toggle writes nothing),
**GTK/icons** (`gsettings` ×3 is the live channel), **fastfetch** (a stable
`archlogo_current.png` symlink).

**Three branches get deleted, not ported:**
- **xfconf** — unreachable. `/Net/ThemeName` does not exist, `xfce4-settings`
  is not installed, no `xfsettingsd` runs. It has never done anything.
- **The Hyprland border regex** — dead code. The machine is on
  `configProvider: lua`; the patched `appearance.conf` says evadark while the
  live compositor says evalight. `hyprctl keyword` is gone too ("can't work
  with non-legacy parsers. Use eval.").
- **The VSCode JSON rewrite** — a landmine, not dormant. It fails today only
  because of a trailing comma at `settings.json:29`; fix that comma and the
  next switch reindents 96 lines and deletes every comment. (R3: themectl has a
  `vscode` target after all, of type `setting`: it edits the one line of the
  text and touches nothing else -- shell_progress/T.md.)

One honest duplication: the recipe resolver exists in QML and in Python. Keep
the grammar to three ops and add a fixture test that renders one theme through
both and diffs, or the shell and the terminal will drift.

## Migration, in order

1. **Reconcile the palette.** ~half a day, worth doing alone. CLAUDE.md's table
   documents a palette the code does not use: `#6F6F72` "muted" has **one**
   occurrence in `modules/` while the real muted is `#8A8A8C` (29, twelve of
   them on a property named `mutedColor`); `#B8BBC2` is used 13× as
   `faintColor` and is not in the table at all. Then pick one hex per role
   where two ship today (error `#D20F39` vs `#EC0000` vs `#F14C4C`; warn
   `#FE640B` vs `#FF6D12`; ok `#40A02B` vs `#44C145`). A design decision with
   renders, its own commit, revertable alone.
2. **`~/.config/theme/` + `themectl` + `targets.json`.** Quickshell untouched.
   Worth doing alone: it retires a script with two dead targets and resyncs a
   desktop currently split between evalight and evadark. Run beside the old
   script and diff every generated file first.
3. **The engine, consumed by nothing.** `modules/common/theme/{qmldir,Theme.qml,
   ThemeScope.qml}` + `test_theme.qml`. Zero visual change. Must include the
   `state.json` FileView (without it a `.qml` edit silently reverts the shell
   to light) and `setToken()`'s echo guard.
4. **Leaf components** — ShadowBox, RaisedButton, TabSelector, ListSectionHeader,
   PhaseRail, DownloadStats, ListSkeleton. All 21 ShadowBox call sites keep
   working untouched, because a declared value still replaces a default
   binding. Without this step there is no dark mode, only light chrome on a
   dark surface: `TabSelector` declares 11 colour properties and **neither** of
   its two call sites passes one.
5. **`system_update`** — the biggest single diff; delete the 74 pass-through
   lines and the 32 palette declarations that then resolve identically.
6. **The panel** — `key:` on entries, `writeValue`/`baseValueOf`, the detach
   switch, the Theme tab, "Promote to shipped default". **`applyDefaults` must
   skip keyed entries.**
7. **`theme_scan.py` + `usage.json` + the tooltip + the three new checks.**
8. **Dark.** The 63 Catppuccin literals are quarantined in 14 files and leak
   nowhere, but 9 of battery's sit inside JS ternary bodies and must be lifted
   to properties first.
9. **One module per commit** as each mockup is built: clock, workspaces, gooey,
   audio, battery last.
10. **Stragglers** — `TerminalView` is the only visual component with zero
    colour properties (15 hardcoded).

**Never themed:** `modules/common/mockup/` (49 dev-chrome literals). The panel
stays unthemed so it is still readable while the theme you are editing is
broken, and so the panel is never mistaken for the content on the stage.

## The snapshot crossfade (round 18)

A per-token lerp is one clock, but the bindings on it are one per token per
item, and the LLM popup's five thousand items paid 33–88 ms a frame for the
fade (seven stepping frames, measured) while the system update, a tenth the
size, ran at 120. So a switch is now a picture: a host that can hold one
(`ThemeCrossfade { target: body }`, a SIBLING of what it captures, and the
mockup window has one round `body`) registers with `Theme.registerHost(h)`
(`unregisterHost(h)` when it goes) — every WINDOW with themed content has its
own, the shell's bar windows and the OSD and auth pill windows included — and
`_apply(animate)` takes this path when any is registered (`crossfadeHost` is
still readable: the first one):

1. `aboutToSwitch()` — every host schedules its `ShaderEffectSource` capture,
   with the quad already at opacity 1 (the grab runs in the renderer's
   preprocess pass, BEFORE the draw, so the frame draws its own pixels back
   over themselves; a hidden or opacity-0 quad is a blocked subtree and never
   grabs — measured, then the 120 ms `_hostFallback` commits with no picture).
2. `commitSwitch()`, once EVERY host has said `Theme.hostReady(h)` — its
   `scheduledUpdateCompleted`, or at the ask when it cannot take a picture (no
   size, window not shown), or by unregistering; the 120 ms `_hostFallback` is
   the net — every token
   is written once (`_fromC = _toC = next; _mix = 1`), `settled()` is emitted
   and the bakers rebuild synchronously inside this frame, behind the
   picture; then `snapAnim` drives `_snapMix` 0→1 over `fadeMs`.
3. `fadeProgress` is `_snapMix` on this path (`_mix` on the lerp path), so a
   consumer that eases on it sees one clock either way; each host's quad is
   `opacity: 1 - Theme.fadeProgress`. `crossfading` is true while the picture
   is up. A host that was asked and has no picture at the commit, or joins
   mid-switch, draws nothing for the fade (`_missed`: its texture is an earlier
   switch's). Measured on two real outputs (120 and 60 Hz): the old single slot
   cut 8 of 20 pictures of an animating window, the host list 0
   (`shell_progress/E2.md` section 3, `theme_hosts_outputs.sh`).

Without a host the lerp path is unchanged (`settled()` fires when the fade
lands), so `SystemUpdatePopup` and anything in a bar without a host behave as
before. `tools/dev/theme_sync_probe.sh` still passes on both.

What made the commit frame affordable: `Theme.counterpart(hex, token)` — the
value a colour will have in the other mode, by the token it defaults to (three
of the code palette's tokens share a value with another token in light mode
and part in the dark: ansiBrightMagenta/catFlatpak, ansiBlue/accent,
ansiBrightCyan/catMultilib) — and `Theme.claimIdleSlot()`, one idle bake per
frame across every surface. `CodeBlock` keeps two documents and bakes the
other mode's ahead at rest with these, so a switch swaps (CodeBlock's header).

Numbers (76 conversations, eight 48 KB answers, offscreen+rhi): ask→fade was
165–311 ms of freeze followed by a fade with 28–88 ms frames; it is a 42–57 ms
commit frame and a fade at 16–17 ms a frame. `llm_themeswitch_probe.sh`
gates COMMIT ≤ 100, FADE worst ≤ 25, SETTLE ≤ 60.

## Traps (all measured)

- **A theme cannot reach a colour nobody passes.** Every dark-mode fault found
  after the pair shipped was a component's own eva-light default standing
  because its host never overrode it — invisible in light mode, where the
  literal happens to be right. Grep a component for `#` before calling it
  themed; a clean render in the theme you developed in proves nothing.
- **Never put a `Behavior on <color>` downstream of the theme.** The theme is
  already one clock; a second one below it can only lag, and it cannot tell a
  state change from the colour moving underneath it, so it catches every
  switch and not just the hover it was written for. Seven of them were found
  this way: the row's stripe, its fill and its icon, the rail's tone and its
  notch labels, the run glyph, and `RaisedButton`'s plateau — each arriving
  120 to 900ms after the card it sits on. Ease the *fraction* (hover, done,
  failed: 0→1) and mix the themed colours with
  `modules/common/components/Mix.js`. Both ends of the mix stay live, so a
  switch *during* a state change is in step too.
  `tools/dev/theme_sync_probe.sh` is the guard: it toggles the mode and proves by
  pixels that nothing is still moving after the fade — with the pulsing and
  breathing parts held still, so 0% of the surface is excluded — and then
  greps the popup's whole dependency closure for a colour animation.
- **A drain, a tint or a shade is a relationship, not a value.** An absolute
  lightness that reads as "faint" on a light ground reads as "bright" on a
  dark one, and inverts the meaning of whatever it was contrasted against.
  Express it relative to a themed colour: it then crossfades for free and
  needs no mode flag anywhere.
- **Never write a component property for a themed row** (`t[e.prop] = v`). A JS
  assignment destroys a QML binding permanently — the item then ignores every
  later theme change *and* the re-attach. Measured: after one such write the
  popup kept the typed colour through a full light↔dark switch.
  `MockupRegistry.colorOf` / `setColor` are the only doors; `ColorList` used
  to go round them, and `applyDefaults()` would sever every theme binding the
  moment a mockup opened had it not skipped themed lists.
- **Read a themed row from the theme, not from the target.** A themed list may
  have no target at all, and its `prop` may name a token the module does not
  carry. Reading the target regardless assigned `undefined` to a QColor —
  twenty warnings per launch, from a list whose values were perfectly fine.
- **Nothing but a deliberate edit may write the theme file.** A profile that
  collected themed rows replayed them through `setToken` on load, one literal
  per token, and flattened every `@alias` in the active mode's block. Whatever
  snapshots a module's state must skip the theme; the theme is not the
  module's state.
- **Never mutate a `var` in place.** `overrides[k] = v` updates nothing and
  warns about nothing. `Object.assign` and reassign.
- **Never write a QML property from inside a binding's call path** — a memo
  cache becomes a dependency of the binding and re-triggers unrelated
  consumers. Counters go in a `.pragma library`.
- **Parse in `Component.onCompleted`, not `onLoaded`.** The singleton is
  constructed *by* the first binding evaluation, so `FileView.onLoaded` is
  always too late; neither `preload` nor `blockLoading` prevents one painted
  frame of the fallback.
- **`watchChanges: true` alone does nothing** — call `reload()` from
  `onFileChanged` yourself.
- **`FileView` reads are not atomic.** A chunked writer produced six truncated
  reads per write. Write temp-then-rename, guard every parse, never clobber on
  empty, and route the error to the panel — `JSON.parse` gives a bare
  `SyntaxError` with no line number.
- **`qmldir` belongs in `modules/common/theme/` only.** Mandatory there (else
  every member access warns), but it *replaces* Quickshell's synthesis for its
  directory — one in `components/` would need an entry per component or the
  config fails to load.
- **A singleton does not survive a config reload**, and only
  `PersistentProperties` does — value types only, under an unbroken chain of
  Reloadable ancestors. Nothing that matters may live only in `Theme`'s memory.
- **Authoring hazard:** `sed -i`, `mv` and Claude Code's `Edit` tool replace the
  inode, and only every *second* such edit to a watched `.qml` fires
  `Reloading configuration...`. The shell can be running code that no longer
  matches the file. Confirm the reload line; never assume it.
