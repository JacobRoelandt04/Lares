# Presets

## What it is

A preset is a named picture of the whole desktop: arrange the windows the way a kind of work wants them, save that as "dev", and
later load it to get the same desktop back in one step. It is session restore's picture (`docs/session.md`), kept under a name until
you delete it. The popup shows one card per preset, each with a small drawing of its workspaces as tiled mini screens.

## Where it lives

- **The button and the tab**: there is no presets button. The presets are the second tab, "Presets", of the machine popup behind the
  panorama glyph (`modules/panorama/popup/PanoramaTabs.qml`; docs/panorama.md "The popup"): one popup, two tabs, each at its own size
  (Displays 460 wide; Presets 596, or 304 -- one column -- while no preset is saved). A click opens it on the tab the situation gives: Presets while only the laptop's own screen is there,
  Displays once another display is connected or a mirror is up; the tab you click or swipe to is yours until the next click decides
  again. Loading a preset closes the popup and the glyph plays its flourish once (its windows go and are dealt in again). The old `presets` id in `shell.jsonc`'s
  `zones` is still read and ignored.
- **The popup** (`modules/presets/PresetsPopup.qml`, a drop-in; PanoramaTabs mounts it unchanged): a grid of cards, two across, up to three rows before it scrolls.
  With no preset saved there is only the save card and the popup is one column wide; the first save widens it to two (the new card and the
  save card part as the box grows), the last delete's end narrows it again.
  The save card shows the desktop as it is NOW and follows it while the tab is on show: Hyprland's window, workspace and monitor events
  (and a display change Panorama sees) read it again, debounced 250 ms, one read at a time; the same desktop read again changes nothing,
  so the name you are typing stays (`PresetsService` holdWatch / desktopChanged).
  - `PresetCard.qml`: the preset's name and window count, its face, **Load** and **Add**.
  - `PresetFace.qml` + `PresetFaceLayout.js`: one mini screen per workspace that has windows, side by side at one scale, each its
    monitor's aspect, tiled as Hyprland tiled it (the saved place and size, every edge on a whole pixel), an app icon in each tile. A
    tabbed group is one tile with a tab strip (a segment per tab, the one on show in the accent); a floating window stands over the
    tiles; a fullscreen one fills its screen. The workspace's name is under its screen, the special workspace is a small badge at the
    end. Seven workspaces do not fit: the strip ends in "+N".
  - `PresetNewCard.qml`: the last card, "Save this desktop": the desktop as it is now, a name field and Save.
- **The service**: `modules/presets/data/PresetsService.qml`, one per shell (ShellServices `presets`). It asks the tool
  (`tools/session/lares-session preset ...`) and keeps the answers; a load runs through the session service
  (`SessionService.loadPreset`: the session restore's progress toast and result toast). The mock serves `PresetFixtures.js`.
- **The tool**: `lares session preset list | current | save | rename | delete | undelete | load` (docs/session.md "Presets", the formats in
  docs/contracts/session.md section 9). The files: `~/.local/share/lares/session/presets/<name>.json`.
- **The mockups**: `mockups/presets.qml` (Run, Layout, Face, Float, Tilt, Deal) for the drop-in alone; `mockups/panorama.qml` (`TAB=presets`)
  for the two tabs together. The cards' float ticks at 20 Hz at rest (`restHz`), as the displays' tiles do.

## What you can do

- **Load**: the desktop becomes the preset. Whatever is open and not in the preset is closed, so the first click asks: the button
  turns into "Close 7 windows?" (in the error colour) and a second click within 4 s loads. Moving the pointer off the card, or Escape,
  takes it back. With nothing to close it loads at once.
- **Add**: the preset's windows are added to what is open; nothing closes. Never asks.
- In both, a window the preset has that is already open is **moved into place**, not opened twice (a terminal in the same directory
  running the same program, VS Code on the same folder, a browser window; the table is in docs/session.md). The windows are prepared
  out of sight and appear at once, like a session restore; the popup closes, and one toast says how far it is, then what was done
  ("2 windows opened, 6 moved into place, 1 closed") or what needs you (a window that would not close because it asks to save, a
  command typed and waiting for Enter).
- **Terminals** come back the way a clean session restore brings them back: a program on the run list (nvim, lazygit, btop, yazi, ...)
  runs again, anything else is typed at the prompt and waits for Enter. `claude --resume <id>` comes back as a fresh `claude` in its
  directory (a preset is a layout, not yesterday's conversation).
- **Save this desktop**: type a name on the last card and press Enter or Save. A name that is taken is refused with the shell's wiggle
  and the reason on the card ("dev exists: right-click it to save over").
- **Right click a card**: *Save this desktop here* (asks "Replace?"), *Rename* (a field over the name; Enter keeps it, Escape or a click
  elsewhere drops it; a taken name wiggles), *Delete* (the card stays a few seconds, faded, with an Undo button that drains).
- The keys, once the pointer has moved onto the popup: arrows move between the cards, Enter is the card's Load (its confirm too), on the
  last card Enter goes to the name field. Escape closes the menu, then a rename, then a confirm, and only then the popup.

## Settings

Every number is `modules/presets/PresetsStyle.qml` (the mockup's panel writes it). The tool's settings are session restore's
(`config/session.jsonc`): `closeTimeoutMs` (how long a replace waits for a window to close, 8 s), `skipClasses` and `apps` (a class set to
`"skip"` is never started, and never closed by a replace), `presets.claude` (a Claude Code terminal comes back `"fresh"` or `"resume"`d),
`presets.confirmReplace` (false: Load closes the other windows without its "Close N windows?"). A deleted preset's Undo lasts
`PresetsService.undoMs` (5 s). Presets work whether session restore is switched on or not.

## Limits

- What is inside a window is the app's own (a browser's tabs, an editor's files): a preset puts the window back, the app fills it.
- Tiled layout is approximate, as in a session restore (Hyprland's dwindle tree cannot be read back).
- A window that asks "save changes?" when it is closed stays open; the result toast names it.

## Checks

```
tools/dev/presets_popup_probe.sh           # the popup on the mock, clicked for real (ARM=all)
tools/dev/panorama_tabs_probe.sh           # the tab: by situation, held by the owner, swipe, Escape, the glyph's deal (ARM=all)
tools/dev/session_service_probe.sh         # scenario G: a preset's load, its toasts, a login's ask kept
python3 tools/dev/session_cases.py         # groups preset, reuse (the tool)
MODE=preset tools/dev/session_env_probe.sh # a real preset saved, rearranged, added and replaced in the nested Hyprland
```
