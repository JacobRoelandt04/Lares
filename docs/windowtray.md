# Window title and tray

## What it is

The last module of the left island: the window you are in (its app's icon and its title) and, hidden behind it, the system tray. Rest the pointer on the
title and the tray's icons hang out of the bar as a strip; hover an icon for its name, right-click it for its menu. The title says only what the icon does
not: the app's own name is cut off its end.

## Where it lives

- Bar: the left island, last module (right of the LLM button). It takes whatever the island has left, up to a cap (`titleSlot`, 340 px in
  `modules/shell/ShellConfig.qml`); a title wider than the slot fades into the bar. The island follows the title's width with a short ease.
- Popup: the tray strip, hung from the window icon's cell on the left island, grown down. It is the popup type the reels use (the engine's reel
  slot): it comes out OVER whatever popup is open and leaves it be, and from the power or idle reel's cell to the title the strip travels along
  the bar while it is still out (folds and opens fresh when it has gone). An icon's label or menu is the strip's first level, a submenu the
  second, its submenu the third, each growing out of the one before; over a popup each is a card that hides what is under it.
- The idle reel's automatic switch and the strip never interrupt each other: a hover on the title while the switch plays waits for it to end; a
  switch while the strip is out waits until the strip has closed, then the idle reel comes out and shows it.
- It has no keyboard shortcut and no IPC verb. While a menu is out its keys are the menu's: Escape closes the deepest open level (a popup under
  it stays), then the menu, then the strip.
- With an empty tray the title is inert: no hand cursor, a click does nothing.

## What you can do

- Read the title: it changes by moving only the letters that changed; a new app replaces the whole line and the icon drifts with it. A terminal's title
  waits `terminalTitleMs` before it shows, so a quick command never flashes across the bar.
- Rest the pointer on the title: the strip opens (with `openOn` `"click"` a click toggles it). It closes when the pointer has left the title, the strip and every popup out of it for
  a moment; a menu you are using keeps it open; a click elsewhere does nothing to it.
- Hover a tray icon: its name and status line come out beside the strip after `labelDelayMs` (220 ms) and follow the pointer from icon to icon.
  The label's extent along the strip is EVEN (the engine centres it on the icon's whole-pixel middle; the old plain ceil made one line 29 tall, edges on half pixels), its lines at the rounded middle. Check: `tools/dev/sandbox.sh tools/dev/tray_label_edges.sh` (ARM `oddlabel`).
- Left-click an icon: its own activation (when it has one; an icon that cannot be activated does nothing). The strip closes after an activation.
  Middle-click and the wheel reach an item only if it implements them. Right-click: the item's menu, with its name as the first row; right-click
  the same icon again to take the menu back into its label.
- A menu's submenu row opens the next level beside it; click it again to close it, another submenu row swaps it. Escape and Left close the deepest level; a pick
  closes everything.
- Tray items that ask for attention peek into the bar beside the title; a click on a peeking icon activates it, or, for one that cannot be activated, opens
  the strip with its name out; a right click opens its menu.
- Icons are drawn as ink (the shell's own glyph colour: legible in light and dark whatever the icon theme ships), warm for an item that asks for you, faint for
  a passive one (`trayPassive` `"hide"` leaves it out), accent under the pointer.

## What it shows and where the data comes from

- The window: Hyprland's events (`openwindow`, `closewindow`, `activewindowv2`, `windowtitlev2`, workspace and monitor events) and one batched `hyprctl -j`
  read (`activewindow`, `monitors`, `workspaces`, `clients`), debounced; it dispatches nothing. Which window a bar shows is `follow`: `"screen"` (default) the last
  window of that bar's monitor's active workspace, each screen its own; `"focus"` the focused window whatever the screen. A scratchpad (special workspace)
  hides the regular workspace's window. The app's mark and name come from its desktop entry (the launcher's lookup).
- The tray: Quickshell's `SystemTray` (the StatusNotifier protocol). The shell reads with `busctl` what each item implements (activate, secondary activate,
  scroll, which icon) once per registration, because a call to a method an item lacks is silent; an icon with no attention picture of its own keeps its normal one.
- Missing: with no window the title reads "Desktop" (`desktopText`); with no tray items the title is inert and the strip never opens.
- Locked: the title reads "<name> is away" ("Away" with no name) with the Arch mark; while the session has been locked since it began (the boot
  lock: nobody has walked away yet) it reads "New session" (`bootText`), and the island is born at that length. The first unlock hands over
  to the window's own title by the usual morph.

## Settings

`~/.config/quickshell/config/windowtray.jsonc`, read hot (one that does not parse keeps the previous settings and the shell says where the typo is). `.examples/windowtray.jsonc`
has every key and its default.

| Key | Meaning | Default |
|---|---|---|
| `follow` | `"screen"` or `"focus"` (above) | `"screen"` |
| `stripSuffix` | cut a trailing " - App Name" (the window's initial title or the app's name after `-`, `—`, `–`, `\|`, `·`); never to nothing | true |
| `rewrites` | `[{re, to}]` regex rewrites of the shown title, in order; an invalid regex is skipped and reported | `[]` |
| `terminalClasses` | window classes whose title change is held; `[]` switches it off | kitty, foot, Alacritty, konsole, ... |
| `terminalTitleMs` | how long the hold is (0 to 2000) | 150 |
| `trayOrder` | item ids shown first, in this order, then the rest as they registered | `[]` |
| `trayHide` | item ids not shown | `[]` |
| `trayRename` | `{id: name}` for an item that names itself badly | `{}` |
| `trayIconMode` | `"ink"` or `"colour"` (the strip's icons; the peeking ones are always ink) | `"ink"` |
| `trayPassive` | a passive item is `"faint"` or `"hide"` | `"faint"` |
| `attention` | an item that asks for attention: `"peek"` or `"off"` (its icon in the strip is warm either way) | `"peek"` |
| `openOn` | `"hover"` or `"click"` | `"hover"` |
| `closeOnLeave` | the pointer leaving closes the strip; false: a pick, Escape or a click on the title | true |
| `closeOnActivate` | a left click that activates an item closes it | true |
| `desktopText` | the title with no window | `"Desktop"` |

A custom icon for one app is `shell.jsonc`'s `icons.overrides` (the class, desktop id or icon name to a path or theme name): it holds for the launcher, the title and screen
time alike. An item's id is what `busctl --user introspect` shows as `Id` ("nm-applet", "blueman"). The look (the strip's pitch, the hover delay, the menu rows, the morph's
time) is `WindowTrayStyle.qml`, tuned in `mockups/windowtray.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/windowtray/WindowTrayOwner.qml` | the long-lived half: hover state, every rule of opening and closing, each menu level's state and models, the cells' input |
| `modules/windowtray/WindowTitleButton.qml` | the icon cell, the peeking icons and the title; the island's wanted width |
| `modules/windowtray/TextMorph.qml`, `TextDiff.js` | a line of text that moves only what changed (prefix stands, the middle drifts, the tail slides) |
| `modules/windowtray/TrayStrip.qml`, `TrayCell.qml` | the strip as the popup's content and one icon with its ink and hit area |
| `modules/windowtray/TraySide.qml` | one level of the child chain: the name label, a menu, a submenu (the key says which) |
| `modules/windowtray/WindowTrayStyle.qml` | every number of the module |
| `modules/windowtray/data/ActiveWindowService.qml`, `ActiveWindowState.qml`, `WindowTitle.js` | the window source (events plus batched reads), the facts, the title rules |
| `modules/windowtray/data/TrayService.qml`, `TrayModel.qml`, `TrayRecord.qml`, `TrayCaps.qml`, `TrayMenuModel.qml`, `TrayText.js` | the live tray, its records and click calls, the capability reads, the menu rows, the text cleanup |
| `modules/windowtray/data/WindowTrayConfig.qml`, `WindowTrayConfig.js` | `windowtray.jsonc` and its validation |
| `modules/windowtray/data/ActiveWindowMock.qml`, `TrayMock.qml`, `TrayMockSpecs.js` | the same surface on fixed data (mock shell, mockup) |

Shared components used: `IconReelStyle` and the reel's strip geometry (the strip is the power reel's without the ring), `MenuRows` and `FloatingMenu`'s rows, `TrayInk` (icons as ink),
`AppIcon` and `AppLookup`, `ScrollDressing`, `ConfigFile`, the engine's child chain (`docs/contracts/gooey_engine.md`). The service surfaces and the chain's rules are in
`docs/contracts/windowtray.md`.

## Limits

- An item that implements no `Activate` and has no menu can only show its name.
- A submenu is its own popup, so the chain is the strip, one label or menu, then one popup per submenu level.
- The tray is a StatusNotifier host: an app that offers only an XEmbed tray is not shown.
- The title is one line, cut at the slot's cap.

## How to change it

- Which window a screen shows, a title to trim or rewrite, a tray item to hide, rename or put first: `windowtray.jsonc`.
- What opens and closes the strip: `windowtray.jsonc` (`openOn`, `closeOnLeave`, `closeOnActivate`).
- The strip's spacing, hover and label delays: `modules/windowtray/WindowTrayStyle.qml`, or `mockups/windowtray.qml`
  (`quickshell -p ~/.config/quickshell/mockups/windowtray.qml`), change on the panel, Save.
- The title slot's cap: `titleSlot` in `modules/shell/ShellConfig.qml`.
- The morph of the title (`drift`, `wipe` or `swap`): the `mode` property of `modules/windowtray/TextMorph.qml`.
- Proof: `tools/dev/smoke.sh mockups/windowtray.qml`, `tools/dev/mockup_panel_test.sh mockups/windowtray.qml`, `tools/dev/config_loaders_probe.sh` (`windowtray.jsonc`),
  `tools/dev/sheet_check.sh`, `tools/dev/tray_reel_probe.sh` (the strip in the reel slot: over a popup, the travel, the three levels, the
  keys, the wait both ways; ARMs `asprimary`, `noground`, `noescape`, `noautowait`, `notraywait`, `nolockclose`).
