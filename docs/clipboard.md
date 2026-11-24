# Clipboard

## What it is

A shelf of everything you recently copied, one keystroke away. Press `Alt+V`, find a card by typing or by arrows, press Enter, and it is pasted
into the window you came from. Text, links, code, colours, images and files each get a card that looks like what they are; passwords and tokens are
held back in memory and never reach the disk.

## Where it lives

- No bar button. `Alt+V` (the shell's global shortcut `clipboard`) opens it from the focused screen's bottom bar, with the keyboard already in it;
  pressed again it closes. Escape closes it too. A click on another window closes it.
- It opens over a fullscreen window too (it floats there as a pill), unless `clipboard.jsonc` says `openOverFullscreen: false`.
- Size: `shelfCards` cards wide (4 by default), one shelf tall; the editor and the shelf share the same rectangle, so the popup never resizes through a mode.
- No IPC verb.

## What you can do

- Type to search (the field is always live); the chips All, Text, Image, Link and Pinned filter. `Tab` / `Shift+Tab` move between the chips.
- Move the focus mark with the arrows, `Home` / `End`, `PgUp` / `PgDn`, or the mouse; a click focuses a card, a double click pastes it.
- `Enter` pastes the focused card; `Shift+Enter` copies it without pasting (`enter: "copy"`: the other way round, the double click with it). With cards marked (`Ctrl+Space` marks or unmarks, in pick order), `Enter` pastes them joined
  and `Shift+Enter` copies them joined.
- `Alt+1` .. `Alt+9` paste the nth visible card (the digits show while `Alt` is held).
- `Ctrl+P` (or the star on a card) pins or unpins: a pinned entry is never dropped, and a pinned entry you renamed shows its title as the card's first line.
- `Ctrl+E` edits a text card: `Ctrl+Enter` pastes the edit, `Esc` keeps it as a new card, `Ctrl+Esc` throws it away; the original stays.
- `Ctrl+T`, the Menu key or a right-click opens the card's menu: "Paste as ..." (transforms: trim, one line, upper, lower, title, strip tracking from a link,
  JSON pretty / minify, URL decode / encode, base64 decode / encode, a file URI as a path), Edit, Rename, Mark, Pin, Seal (hold a copy back as a secret),
  Keep (a copy the heuristic sealed that you say is no secret becomes a normal card), Delete.
- `Delete` removes a card; the header offers Undo for 8 s (a draining button). A sealed copy is forgotten instead.
- Hold `Ctrl+R` to peek at a sealed copy; it is shown only while the key is held and cleared on release.
- Esc clears the query, then the marks, then closes. A card you picked is copied on the way out, so a later `Ctrl+V` pastes it (`copyOnClose`).
- The faces: text (with the lines that fit), code (monospace), link (host and path), colour (a swatch), image (a thumbnail), files (the names), sealed (a
  veiled card with a countdown). Each card's footer shows the source app's icon, how long ago, and the pin star (or the digit while `Alt` is held).

## What it shows and where the data comes from

- The history is written by `tools/clipboard/clip.py`, the store's only writer, fed by `wl-paste --watch` on a supervised stream: one JSON event per
  clipboard change. The store lives in `$XDG_STATE_HOME/lares/clipboard/` (`index.json`, `blobs/`, `thumbs/`). `cliphist` history can be imported
  (`clip.py import-cliphist`).
- Pasting: the popup copies the card with `wl-copy`, lets go of the keyboard, and `pasteDelayMs` later sends the paste shortcut to the window the popup was
  opened over (found with one `hyprctl -j activewindow` at the key press); a terminal gets `Ctrl+Shift+V` through `pasteKeys`. With no active window it only copies.
- Secrets (sealed): a copy from an app in `sealApps` or one with a sensitive hint, and, with `secrets.heuristic`, single-line text shaped like a token or a
  password. A sealed copy lives in the shell's memory only, expires after `secrets.ttlS`, is dropped when the screen locks (`dropOnLock`) or when its source clears
  the clipboard (`dropOnSourceClear`), is never offered back after the app that owned it quits, and goes back to the clipboard with the sensitive flag.
  While the screen is being shared, sealed cards are not shown at all.
- Survives closing the source: when the app that owned the clipboard quits and the clipboard empties, the entry is put back (`reofferOnClose`). At start an
  empty clipboard gets the newest entry (never a sealed one; `restoreAtStart`).
- An app in `ignoreApps` leaves nothing: its copies (a sensitive one too) are neither stored nor sealed, and what was on the clipboard before one is not
  offered again after it. The class is the active window's as the copy is made.
- Limits applied by `clip.py` pruning after every copy: `maxItems`, `maxAgeDays`, `maxTotalMB`, `maxImageMB` (images larger are not recorded), thumbnails only for the newest
  `thumbsMax` images; text over `textIndexKB` is cut in the index, with the full text beside it.

## Settings

`~/.config/quickshell/config/clipboard.jsonc`, comments allowed, every key optional. `clip.py` re-reads it at every copy and is the only source of the defaults; the
shell asks it again (`clip.py config`) when the file changes. `.examples/clipboard.jsonc` has every key and its default.

| Key | Meaning | Default |
|---|---|---|
| `maxItems`, `maxAgeDays`, `maxImageMB`, `maxTotalMB` | history limits (oldest go first; pinned never) | 1000, 30, 25, 500 |
| `thumbPx`, `thumbsMax`, `textIndexKB` | thumbnail size, how many images keep one, the index's text cut | 320, 48, 16 |
| `secrets.ttlS`, `dropOnLock`, `dropOnSourceClear`, `heuristic`, `threshold` | a sealed copy's life, when it goes, the credential detector and its entropy bar | 120, true, true, true, 0.5 |
| `ignoreApps` | window classes whose copies are not recorded at all | none |
| `sealApps` | window classes whose copies are always sealed | Proton Pass, proton-pass |
| `pasteKeys.default`, `pasteKeys.classes` | the paste shortcut (`"MODS,KEY"`), per window class; the terminals' `CTRL SHIFT,V` stay | `CTRL,V` |
| `reofferOnClose`, `openOverFullscreen`, `pasteDelayMs` | put an entry back, open over a fullscreen window, ms before the paste key | true, true, 120 |
| `enter`, `joiner` | what Enter and a double click do (`paste` or `copy`), what stands between entries pasted as one | `paste`, a line break |
| `copyOnClose`, `restoreAtStart` | Escape copies the card you chose, an empty clipboard gets the newest entry at the start | true, true |
| `pinnedFirst`, `openOn`, `undoSec` | pinned cards stand first, the chip it opens on, how long a delete can be undone | true, `all`, 8 |

The shelf's look (card size, gap, card count, the focus lift or well, fades) is `ClipStyle.qml`, tuned in `mockups/clipboard.qml`; Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/clipboard/ClipboardBarOwner.qml` | bar side: opens on the shortcut (one `hyprctl` read for the origin and fullscreen), the focus grab, `hostOpen` |
| `modules/clipboard/ClipboardPopup.qml`, `ClipHeader.qml`, `ClipEditor.qml`, `ClipStyle.qml` | the popup and its key map, the header (search, chips, count, undo), the editor, every number of the shelf |
| `modules/clipboard/shelf/ClipShelf.qml`, `ClipCard.qml` | the horizontal shelf with a pool of cards; one card |
| `modules/clipboard/shelf/faces/` | one face per kind: `TextFace`, `CodeFace`, `LinkFace`, `ColourFace`, `ImageFace`, `FilesFace`, `SealedFace`; `ClipParse.js` reads a record's text |
| `modules/clipboard/data/ClipboardService.qml` | the live service: the watcher, the entries, secrets in a private map, paste, survive-close, restore at start |
| `modules/clipboard/data/ClipboardModel.js`, `ClipTransforms.js` | pure JS: ranking and filters, the transforms |
| `modules/clipboard/data/ClipboardMock.qml` | the same surface for the mockup and the mock shell |
| `tools/clipboard/clip.py`, `tools/clipboard/lib/` | the store's writer: ingest, keep, seal, pin, rename, delete, prune, import |

Shared components used: `SupervisedStream` (the watcher with backoff), `CarvedSearchField`, `TabSelector` (the chips), `UndoDrainButton`, `FloatingMenu`, `ScrollDressing`,
`BoundaryClock` and `RelTime.js` (the cards' relative times), `AppLookup` (the source icons), `KineticScroll`, `RaisedButton`, `ShadowBox`, `EditKeys.js`. The service surface is
`docs/contracts/clipboard.md`.

## Limits

- Wayland only; the paste goes to the window that was active when you pressed the shortcut, and is skipped if that window is gone.
- A sealed copy never survives a shell restart (it is memory only).
- Pinned entries and their blobs stay whatever the limits say.

## How to change it

- A limit, a paste key for another terminal, a sealed app: `clipboard.jsonc`.
- Card size, how many cards, the focus look: `mockups/clipboard.qml` (`quickshell -p ~/.config/quickshell/mockups/clipboard.qml`), change on the panel, Save; or `modules/clipboard/ClipStyle.qml`.
- A transform: `modules/clipboard/data/ClipTransforms.js` (`available` and `apply`), and its menu row in `modules/clipboard/ClipboardPopup.qml`.
- A card face: the matching file in `modules/clipboard/shelf/faces/`.
- Proof: `tools/dev/clip_config_cases.py` (clipboard.jsonc in the tool: wrong values, `ignoreApps`; ARM `recorded`), `tools/dev/smoke.sh mockups/clipboard.qml`, `tools/dev/mockup_panel_test.sh mockups/clipboard.qml`, `tools/dev/sheet_check.sh`.
