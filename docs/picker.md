# Picker (emoji, symbols and Nerd Fonts)

## What it is

One popup for the characters a keyboard does not have: emoji, the Windows alt codes, math, arrows, currency, Greek and kaomoji, and the icons of the installed Nerd Font. Press `Alt+Period`, find a cell by typing
or by arrows, press Enter, and it is pasted into the window you came from. It replaces `rofimoji` on the same key.

## Where it lives

- No bar button. `Alt+Period` (the shell's global shortcut `picker`) opens it out of the focused screen's bottom bar, with the keyboard already in it; pressed again it
  closes. Escape closes it too. A click on another window closes it.
- It opens over a fullscreen window too, unless the clipboard's `openOverFullscreen` is false (it pastes through the clipboard's own path).
- The popup is one size (12 Emoji columns by default); nothing resizes through a tab, a search or a section.
- No IPC verb.

## What you can do

- Three tabs, **Emoji**, **Symbols** and **Nerd** (`Tab` / `Shift+Tab` switch; `picker.jsonc` says which there are and which it opens on). The Symbols tab holds Alt codes, Math, Arrows, Currency, Greek and Kaomoji.
- One search over all tabs, by name and keyword ("red heart", "arrow", "table flip"). With something typed, each tab's label says how many it found, and an empty page
  says where the hits are ("12 in Symbols, 3 in Nerd (Tab)").
- **Nerd** is the icon list of the Nerd Font installed on this machine, searched by the words of the icon's name: `nf-md-lightbulb_on` is the words md, lightbulb, on, so
  "lightbulb on" finds it, "md" lists the Material Design set, and a whole pasted name finds that icon first. A category bar has one cell per icon set (Material Design,
  Font Awesome, Codicons, Devicons, Octicons, Seti-UI, Weather, Powerline, Linux logos, Custom, Other); the foot shows the highlighted icon's full name and code point.
  `Enter` / a click pastes the **glyph**, `Ctrl+Enter` / `Ctrl+click` pastes its **name** (`nf-md-lightbulb_on`); `Ctrl+Shift+Enter` puts the name in the tray (names are
  joined by a space). Recents and the tray work as on the other tabs. A glyph that two names share is one tile (320 of 10 995 names in 3.5.1); the other name is searched too.
- On Symbols, **digits are an alt code**: `233` shows the code that is 233 first (the theta, `Alt+233`, CP437) and the others that start with it; `0233` is the e acute
  (`Alt+0233`, CP1252). Each alt-code tile carries its code(s) under the glyph; the foot names them in full for the highlighted one.
- Move the highlight with the arrows (`Home` / `End` / `PgUp` / `PgDn`: a visible page of rows), or the mouse. `Ctrl+Left` / `Ctrl+Right` step the category; the bar under the grid jumps to a
  category (smileys, people, animals, food, travel, activities, objects, symbols, flags; on Symbols its sets) and follows the grid as it scrolls.
- `Enter` (or a click) picks the highlighted cell. `Shift+Enter` (or `Shift`+click) puts it in the **tray** without closing: the foot lists the tray, tiles show a badge,
  and the next plain pick pastes the whole tray joined, in one paste. `Backspace` on an empty search takes the tray's last pick back.
  *Why the tray is pasted at the close and not pick by pick:* the popup holds the keyboard, so a key can only be sent after it lets go; one paste into the window the
  clipboard service verified is still the active one cannot land anywhere else, where a paste per pick would need the keyboard released and taken back between picks.
- **Recent** is the first section of each tab: what you pasted most and latest (the launcher's frecency), remembered across sessions.
- **Forgetting recents.** `Delete` on a highlighted Recent tile takes that one out of the recents (only there: with the highlight anywhere else, or with a search typed, `Delete`
  does nothing). A **Clear** plate at the right end of the Recent header clears *that tab's* recents (Emoji, Symbols or Nerd each have their own), all of its records, the ones past
  the row too. It turns into **Undo** for `undoMs` (10 s, `PickerStyle`), draining in its own shading like the notification manager's Clear all; Undo puts back exactly what was
  cleared (counts and times), and when the drain runs out it is gone for good. With Recent gone, the Undo stays where the header was: at the right end of the tab's first header
  (the same y, so nothing moves under the pointer and nothing shifts when it expires). Another tab, or closing the popup, also ends the Undo. Nothing announces either: a
  colour fade and the hand cursor on the plate; right-click still opens the skin-tone popover.
- **One skin tone**, for every emoji that takes one: right-click such an emoji (or press `Ctrl+T` / the Menu key, or click the hand in the foot) for a popover of the six
  tones. The choice applies to the whole grid, the recents and every paste from then on, and is remembered.
- `Esc` closes the tone popover, then clears the search, then the tray, then closes. Closing without a pick pastes nothing.

## What it shows and where the data comes from

- `modules/picker/data/picker_data.json` is **committed**, so the shell never needs rofimoji. `tools/picker/build_data.py` writes it from rofimoji's data
  (`/usr/lib/python3*/site-packages/picker`, or `--rofimoji <dir>`): the emoji files with their extra keywords, `kaomoji.csv`, the math / arrows / currency / Greek blocks,
  and the skin-tone base set. The alt-code tables come from Python's `cp437` and `cp1252` codecs (Alt+1..31 and Alt+127 are the IBM graphic symbols, written out in the
  tool). `--oem cp850` rebuilds the OEM half for a Western European Windows; `--check` says whether the asset on disk is current. The asset records its source versions.
- Emoji are drawn with Noto Color Emoji (the font's bitmaps are 136 px, so they stay sharp up to about 100 logical px at any shell scale); a skin tone is applied by
  inserting the modifier after the base character (ZWJ sequences keep the rest). Families and couples-with-hearts take none.
- The memory is `$XDG_STATE_HOME/lares/picker/state.json`: `{ "version": 1, "tone": 0..5, "tab": "", "frecency": { "<char>": { "count", "recent" } } }` (`tab`: the last tab, kept with `openTab: "last"`), written debounced and atomic.
- Pasting is the clipboard module's path (`docs/clipboard.md`, "Pasting"): the text goes on the clipboard with `wl-copy`, the popup lets go of the keyboard, and
  `pasteDelayMs` later the active window is checked against the one the key was pressed over and that window class's paste key is sent (`pasteKeys`). With no active window
  it only copies. The copy lands in the clipboard history as any copy does.

### The Nerd list: where it comes from

Nerd Fonts changes its icon library from release to release, so the list is **not committed**. `tools/picker/nerd_fetch.py ensure` (run by `PickerService.ensureNerd()`, once per
shell, the first time the Nerd tab is shown; never at start, at every open or on a timer):

1. finds the font (fontconfig's Symbols Nerd Font, else any installed Nerd Font; `--font` / `$NERD_FONT`) and reads its **version from the font itself** -- the name table's
   "Version 001.000;Nerd Fonts 3.5.1" -- never from the package manager, so it holds on any distro;
2. when `$XDG_CACHE_HOME/lares/picker/nerd.json` is already for that version and that font file, says `current` (~0.2 s, no network);
3. else fetches `glyphnames.json` for that tag (`https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v<version>/glyphnames.json`; curl, a generic User-Agent, a 30 s
   timeout) into `glyphnames-<version>.json`, keeps **only the code points the font's cmap draws** (a tile of a glyph the font lacks would be a box) and writes `nerd.json`.

A failure is a stated reason, and the page says it in one line ("No Nerd Fonts list: offline: cannot reach raw.githubusercontent.com (curl 7). Leave this tab and come back to retry.", "no glyphnames.json at ...
(HTTP 404)", "no Nerd Font is installed", "python fontTools is missing"); the other tabs never notice, and the next visit to the Nerd tab asks again. The list's keys have no
`nf-` prefix (`md-home`); the tool adds it for the name that is pasted. Measured here (3.5.1, the Symbols Nerd Font): 10 995 names, 10 617 distinct characters, all drawn by the font.

Cost in the shell's QML engine (QV4): index build 28 ms for 10 617 icons, a name search 10 ms (a one-letter query ~25 ms), on top of the ~35 ms a keystroke already costs on the
other tabs. A search is one prepared string per icon and `indexOf` (the fuzzy fallback is the letters found in order inside the name, from three letters, when no word matched);
a character -> icon map is not built (10 600 keys cost ~700 ms to build in QV4), so the Nerd recents are found in one pass.

## Settings

`config/picker.jsonc` (`.examples/picker.jsonc`; read hot):

| Key | Default | What it is |
|---|---|---|
| `tabs` | `["emoji", "symbols", "nerd"]` | the tabs, in order; without `nerd` the Nerd Fonts list is never fetched, one alone has no selector |
| `openTab` | `emoji` | the tab every open starts on, or `last` |
| `nerdPick` | `glyph` | what Enter takes of a Nerd icon: `glyph` or `name`; Ctrl+Enter takes the other |
| `recents` | `true` | the Recent row |
| `pick` | `paste` | a pick is pasted (and copied), or only copied (`copy`) |

The picker's own memory is the state file above, the paste keys and the fullscreen rule are the clipboard's (`clipboard.jsonc`). The look
(columns, cell sizes, the highlight's glide, the foot) is `modules/picker/PickerStyle.qml`, tuned in `mockups/picker.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/picker/PickerBarOwner.qml` | bar side: opens on the shortcut (one `hyprctl` read for the origin and fullscreen), the focus grab, `hostOpen` |
| `modules/picker/PickerPopup.qml` | the popup: state, both searches, the sections, the keys, the tray, the Escape chain |
| `modules/picker/PickerGrid.qml`, `PickerFoot.qml`, `PickerTonePop.qml`, `PickerStyle.qml` | the pooled grid with its one well and the Clear / Undo plate (one `UndoDrainButton` in a clipping layer over the box, at the header's y less the scroll: the headers are pooled rows, so it is not one of them); the category bar, caption and tone button; the tone popover; every number |
| `modules/picker/data/PickerModel.js` | pure: the asset's shape, the word search (fuzzy only as the fallback), the Nerd index and search, the skin tone, the digit jump, the grid's rows |
| `modules/picker/data/PickerService.qml` | the data (read on first use), the memory (`forget(ch)`, `clearRecents(tab)` returning what it took out, `restoreRecents(saved)`; each moves `serial`), the paste through the injected clipboard service, the Nerd list (`ensureNerd`, `nerdState`) |
| `modules/picker/data/picker_data.json` | the committed data asset |
| `tools/picker/build_data.py` | builds the asset |
| `tools/picker/nerd_fetch.py` | the Nerd list for the installed font: version from the name table, fetch, coverage filter, cache |
| `tools/dev/picker_nerd_check.py`, `tools/dev/fixtures/glyphnames-3.5.1.json` | its unit check, and the bytes raw.githubusercontent.com answered for 3.5.1 (the probe's curl stub serves it) |

Shared components used: `TabSelector`, `CarvedSearchField`, `ShadowBox`, `RaisedButton`, `ScrollDressing` (KineticScroll / ScrollFeel), `FuzzyMatch`, `EditKeys.js`; from other
modules the clipboard service (paste) and the launcher's `Frecency.js` (which belongs in `common/` the next time someone moves it).

The grid is a ring of row slots in a Flickable (a few more than the box shows): crossing a row boundary rebinds one slot. Nothing animates but the highlight's glide, the
keyboard's scroll and presence fades; a search swaps the page at once. (`docs/contracts/list_animation.md` is about rows that expand and collapse; there are none.)
The grid's viewport stands inside the carve's rim (3 px at the top and foot), while the fade's outline is the whole box: an outline that is the clip leaves the clip's first
two rows bare under the border (the glyphs showed through, 2026-11-15). `view` keeps the box's size and place, so nothing else moves. The `picker` site of
`tools/dev/fade_edges_probe.sh` holds it, ARM `flush`.

## Limits

- Wayland only; the paste goes to the window that was active when you pressed the key, and is skipped if that window is gone.
- The Nerd tab needs a Nerd Font installed (`ttf-nerd-fonts-symbols`, or any patched font), python's fontTools and curl, and the network once per font version.
- Alt codes assume the OEM page is CP437 (the user's choice); a Windows in the Netherlands uses CP850 (`build_data.py --oem cp850`).
- `build_data.py` drops a row with a character no installed font covers (it would draw as a box or lose characters; 1112 of 1562 kaomoji with the fonts installed here). Installing a CJK font (`noto-fonts-cjk`) and re-running `tools/picker/build_data.py` brings the dropped kaomoji back; `--keep-uncovered` keeps them regardless.

## How to change it

- Refresh the data: `tools/picker/build_data.py` (then commit the asset). A set of symbols: `SYMBOL_SETS` in the tool.
- Size, columns, glide: `mockups/picker.qml` (`quickshell -p mockups/picker.qml`), change on the panel, Save; or `PickerStyle.qml`.
- The key: `hl.bind("ALT + PERIOD", hl.dsp.global("lares:picker"))` in the Hyprland config (`lares binds` prints it).
- Proof: `tools/dev/smoke.sh mockups/picker.qml`, `tools/dev/picker_probe.sh` (paste, tray, Escape, tone, digits, the Nerd tab: one fetch per version, glyph on Enter and name on Ctrl+Enter, a failed fetch; ARMs
  `nopaste`, `wrongtone`, `nodigitjump`, `nameonenter`, `ctrlglyph`, `reask`, `refetch`, `nofilter`, `nofailline`; Clear / Undo / Delete: a real click on the plate, the per-tab scope, the state file after each, the expiry, ARM `clearalltabs`; picker.jsonc, ARM `copypastes`),
  `tools/dev/mockup_panel_test.sh mockups/picker.qml`, `tools/dev/theme_sync_probe.sh`, `SITES=picker tools/dev/fade_edges_probe.sh` (the fade covers the clip to the device pixel, ARM `flush`). `PICKER_SCROLL=<px>` scrolls a grab's grid.
