# Notes

## What it is

Your plain-text notes as tiles, one click from the bar. Open a tile and write in an editor that renders markdown as you type (Obsidian's live
preview: the line with the caret shows its marks, every other line is rendered). The notes are ordinary `.md` files in one folder (`~/Documents/Notes`), so any
other tool can read, edit and sync them; the module adds only a hidden index for colours, sizes and order.

## Where it lives

- Bar: left island, between the theme button and the LLM button (a notes glyph).
- Popup: one popup with two views. Browse: a grid of tiles (560 x 440 by default). Editor: the open note (420 x 480 by default, and each note remembers
  the size you gave it). Opening a tile morphs the tile into the note; going back morphs it home.
- Click the glyph to open or close it. `Alt+N` (the shell's global shortcut `notes`) opens it from the keyboard with the keys held for typing and
  closes it again; a click outside closes a key-opened popup. Opening it by the key plays the glyph's flourish, as a hover does (on the screen the
  popup opens on; a close plays nothing).
- Keys on the grid: typing searches (a leading space types nothing), Backspace and `Ctrl+Backspace` / `Ctrl+W` / `Ctrl+U` edit the query, `Esc` closes. The arrows,
  Home, End, PgUp and PgDn show a highlight (the tiles' hover look: lifted, lighter plateau) and move it over the notes and folders (not the "+" tile),
  scrolling it into view; Enter opens it as a click does. With one search hit, Enter opens it with no highlight shown. The highlight stays until the
  pointer moves over the grid, a key types or the list changes. A mouse user never sees it.
- Drop target: drag a file over the glyph and hold it a moment; the popup opens so you can drop the file into it.
- Where it opens: `shell.jsonc`, `outlets.notes` (`bar`, `along`); see `.examples/shell.jsonc`.
- No IPC verb.
- The glyph's flourish: hover the glyph (once per entry, after the pointer moves) and the top sheet is PEELED off the block. Something pulls
  the folded corner up and to the left, the fold travels across the sheet and slows as the paper tightens, the sheet snaps free, flies off
  up-left against gravity, tipping back and shrinking to nothing, and the sheet underneath folds its own corner: the icon ends exactly as it
  began. At rest there is no block: the next sheet rises in from just behind (a little smaller, in a paler ink) only when the peel starts.
  About 1.25 s. It is decorative, so the OLED care's random flourishes play it too: group `notes` (`oled.flourishes.glyphs` in
  shell.jsonc, `"notes": false` takes it out).

## What you can do

Browse
- Click `+` (always the first tile) to start a note; it gets a file only when it has text (`notes.jsonc` `newName`, "Untitled", when the title stays empty).
- Click a tile to open it. A tile shows the title, the first lines (images, code, tables and front matter skipped, fading at the foot) and the time of
  the last change. Right-click a tile: Rename, a colour swatch row (none, red, orange, yellow, green, teal, blue, purple, pink), Show in file manager,
  Send to LLM (when the chat is there), and Delete (moves to the trash after a confirm; "Remove from list" for a linked note).
- Groups are folders, to any depth: a group tile is a carved well with up to four mini tiles. Click it to go inside; the chevron at the top left (or
  a two-finger swipe back) goes up. Esc only closes the popup (clearing a typed search with it): it goes back nowhere, so the popup reopens on the note or
  folder it was left on (`notes.jsonc` `escape: "back"`: in an open note it goes back to the tiles, `openAt`: what it opens on). Click a group's name in the header to rename the folder.
- Drag a tile to reorder (the Custom sort) or rest it on another tile to make a group from the two (or drop on a group to move it in); dragging from a
  group's header band moves it up one level. Tiles glide to their new cells.
- Sort (top right): Name, Modified, Created, Size, Custom, with a direction.
- Search: just type while the grid shows; the header turns into the query (with a magnifier) and the grid into the matches in names and text; Backspace
  edits it, Esc clears it.
- Resize the popup by its free edges and far corners like a window; the opposite edge stays put.
- A note that is a link to a file elsewhere (a symlink) carries a small link glyph, its tip showing the real path. Drop a file from the file manager onto the
  popup and it is linked into the folder you are viewing and opened. Removing a link from the list never touches the file.

Editor
- Type markdown: headings, bold, italic, strike, lists and tasks (click a box), quotes, callouts, code fences, tables, front matter, links and images.
  Enter continues a list or a quote; Tab indents. Shift+Enter, as in VS Code, opens an empty line below the caret's line and moves there; the text after
  the caret stays where it was.
- `Ctrl+B`, `Ctrl+I`, `Ctrl+Shift+X` wrap the selection; `Ctrl+K` inserts a link; `Ctrl+Z` / `Ctrl+Y` undo and redo; the terminal's line-editing keys (`Ctrl+W`,
  `Ctrl+U`, `Alt+B` / `Alt+F`, word kills) work on the caret's line. `Ctrl+click` opens a link (`notes.jsonc` `linkClick: "click"`: a plain click too); a `[[wikilink]]` opens the note of that name.
- The title above the text is the file name; it renames when the caret leaves it.
- Paste an image: it lands in the root's `.attachments` folder and is linked relatively, on a line of its own, which renders as the image (a name with spaces is written `![](<path with spaces.png>)`, the CommonMark form;
  `Markdown.js` reads it, so the LLM view draws it too). A dropped image is linked where it lies, on a line of its own.
- Dictation: the popup answers the shell's dictation contract (`dictationActive`, `dictationPreedit(text)`, `dictationCommit(text)` on `NotesPopup`): the
  live text is shown underlined at the caret and is not in the file until committed; a commit goes through the editor's own paste path (the title takes
  it too, without line breaks or slashes).
- Saved by itself 800 ms after you stop typing (5 s at most while typing), and at once on back, on switching note and on close. If the file changes on
  disk while you have unsaved edits, a band at the top asks Keep mine / Load theirs.
- Caret and scroll are remembered per note.

## What it shows and where the data comes from

- The files under the root (`notes.jsonc` `root`): every text file is a note (`.md` hidden in the title, any other extension kept: `script.py`), every folder a
  group. Hidden names are never listed. The folder is watched (`inotifywait`), so a note added, renamed or moved outside the shell appears at once;
  a rename found by inode keeps its colour, size and place.
- `<root>/.notes.json`: sort, custom order, colours (as names), per-note sizes. It is only written when you change one of those.
- `$XDG_STATE_HOME/lares/notes/session.json`: the caret and the scroll each note was left at. The view, the folder and the open note live in memory:
  a reopen finds them, a new shell session starts on the root.
- With no folder yet, the browse view shows only the `+` tile; the first write creates it.

## Settings

`config/notes.jsonc` (`.examples/notes.jsonc`; read hot, the root as the shell starts):

| Key | Default | What it is |
|---|---|---|
| `root` | `~/Documents/Notes` | the folder the notes are in |
| `openAt` | `last` | what the popup opens on: `last` (where it was left this session), `root` (the tiles), `new` (a new note) |
| `escape` | `close` | Escape in an open note: `close`, or `back` (to the tiles; Escape there closes) |
| `confirmDelete` | `true` | deleting a note or a group asks first |
| `newName` | `Untitled` | the name of a note that has none |
| `linkClick` | `ctrl` | a link opens on Ctrl+click, or on any `click` (in the line being edited a click puts the caret) |

Where the popup opens is `shell.jsonc` `outlets.notes`. Everything else is look and feel, tuned in `mockups/notes.qml` (the tile sizes,
browse and note sizes, the morph time, the swipe-back distance, the editor's fonts and sizes); Save writes the module.

## How it is built

| Path | Role |
|---|---|
| `modules/notes/NotesBarOwner.qml`, `NotesBarButton.qml` | bar side: toggle, `shortcutPressed()` with the focus grab, spring-loading, saving on close |
| `modules/notes/parts/NotePeelPose.js`, `NoteParts.js` | the glyph's flourish as a pure function of its clock (the numbers are `DEFAULTS` at its top); the font's outline, generated by `tools/dev/flourish_parts.py` |
| `modules/notes/NotesStore.qml` | what outlives the popup: view, folder, open documents with undo, sizes, the session, autosave |
| `modules/notes/NotesPopup.qml`, `NotesHeader.qml` | the popup, the morph between views, the header row (edge resizing: `modules/common/components/PopupEdgeResize.qml` + `EdgeResize.js`, shared with the bridge's cast) |
| `modules/notes/browse/` | `NotesGrid` (placement, drag, drop), `NoteTile`, `GroupTile`, `NewNoteTile`; `GridLayout.js` the pure placement |
| `modules/notes/editor/NoteEditorPane.qml` | the open note with its title, images, the disk-change band |
| `modules/notes/LiveMarkdownEditor.qml`, `LiveMarkdownLine.qml`, `LineViewport.qml`, `LineDocument.qml` | the live-preview editor over a line document; the renderer is `modules/common/components/LiveMarkdown.js` |
| `modules/notes/data/NotesService.qml` | the tree as one flat model, the ops, the watch, search, the file-manager portal |
| `modules/notes/data/NotesFileOps.qml`, `NotesIndex.qml`, `NoteFile.qml`, `NotesScan.js` | every file operation one `sh -c` at a time (never clashing names, `gio trash`); `.notes.json`; one note's file; the scan |
| `tools/notes/portal_pick.py` | opens the file-chooser portal at a note's folder (Show in file manager) |

Shared components used: `ShadowBox` and `RaisedButton` (tiles stand proud, wells are carved), `FloatingMenu` (the tile menu), `SortControl`, `ScrollDressing`,
`SwipeScrub` (swipe back), `DragIntent.js` (group or reorder), `EditKeys.js`, `Markdown.js` (the LLM view's markdown rules: a note renders the same in both),
`FileDropOverlay`, `RelTime.js` and `BoundaryClock` (the tiles' relative times). The gesture rules: `docs/contracts/gestures.md`; lists that animate: `docs/contracts/list_animation.md`.

## Limits

- Text files only: a non-text file, a hidden name and a non-text link are not listed. A broken link is listed and says so.
- One store serves every screen, so two screens' popups edit the same open documents.
- A pasted image needs the note's folder to be writable.

## How to change it

- A tile colour name or tint: the `swatches` list in `modules/notes/NotesPopup.qml` and the palette that maps a key to a tint.
- Sizes (tile min / max, the browse and note boxes, the grid gap): `mockups/notes.qml` (`quickshell -p ~/.config/quickshell/mockups/notes.qml`), change on the
  panel, Save; or the properties at the top of `modules/notes/NotesBarOwner.qml`.
- The notes folder: `notes.jsonc` `root` (restart the shell).
- A sort mode: `modules/notes/NotesHeader.qml` (the menu rows) and `modules/notes/data/NotesScan.js` (the comparators).
- Proof: `tools/dev/smoke.sh mockups/notes.qml`, `tools/dev/mockup_panel_test.sh mockups/notes.qml`, `tools/dev/notes_editor_probe.sh` (Esc, Shift+Enter, the
  pasted image rendering, dictation, notes.jsonc; ARMs imgregex, escback, shiftsplit, precommit, backcloses, arriveout), `tools/dev/float_probe.sh` (the cards'
  float: deal, sway, lean, clicks on a tilted card, calm during a drag), `tools/dev/sheet_check.sh`.
