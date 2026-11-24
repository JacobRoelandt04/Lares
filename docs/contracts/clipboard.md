# Clipboard: contract

(The plans, stage-0 facts and round notes this contract names beside it are no longer in `docs/`: they are in git history,
`git log --all -- 'docs/agent_added_files_and_folders/clipboard_progress/'`.)
(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Frozen 2026-10-09, before the streams split. Plan: `PLAN.md`. A change to anything here is made here
first, and every stream is told.

## Processes

The service starts one watcher, supervised:

    setpriv --pdeathsig TERM -- wl-paste --watch python3 <shellDir>/tools/clipboard/clip.py ingest

- `wl-paste` spawns one `clip.py ingest` per clipboard change, with `CLIPBOARD_STATE` set. The child
  inherits wl-paste's stdout, so every event it prints reaches the service's pipe. Stage 0 item 3
  confirms this.
- One-shot commands (`clip.py pin <id>` ...) are separate Processes, argv only. Secret bytes never go in
  argv: they go through stdin (`keep`).
- The store has ONE writer, the tool. QML reads `index.json` once at start and then follows events.

## Paths and config

- State: `$CLIP_STATE`, else `$XDG_STATE_HOME/lares/clipboard`, else
  `~/.local/state/lares/clipboard`.
  - `index.json`: `{"version":1,"entries":[record,...]}`, newest first. Written atomically
    (`.part` + fsync + `os.replace`) under `flock` on `index.lock`.
  - `blobs/<id>.<ext>`: the full bytes of an entry whose `text` is truncated, and of every non-text
    entry.
  - `thumbs/<id>.webp`: images only, PIL, WebP at quality 60 (a few KB), longest side `thumbPx` (default
    320). Only the newest `thumbsMax` (48) unpinned images, plus every pinned one, have one: an older
    image keeps its blob (a paste never needs the thumb) and loses its thumb, `thumb: null`, and its
    card shows the placeholder. Missing PIL also means `thumb: null`. The store drops the thumbs at
    every prune and says so with one `update` event per record; a copy of such an image again (a bump)
    cuts a new thumb from its blob, and pinning one does too. Qt reads WebP through qt6-imageformats.
    Thumbs written before round 2 (`<id>.png`, 384 px) stay valid for as long as their record names them.
  - A corrupt `index.json` is moved to `index.json.corrupt` and the store starts empty. At load, blobs
    and thumbs that no record names are swept.
- Config: `$CLIP_CONFIG`, else `$XDG_CONFIG_HOME/quickshell/config/clipboard.jsonc`. Missing keys take the
  defaults below. The repo carries `clipboard.example.jsonc`, and `clipboard.json` is gitignored.

```json
{
  "maxItems": 1000, "maxAgeDays": 30, "maxImageMB": 25, "maxTotalMB": 500, "thumbPx": 320,
  "thumbsMax": 48, "textIndexKB": 16,
  "secrets": { "ttlS": 120, "dropOnLock": true, "dropOnSourceClear": true,
               "heuristic": true, "threshold": 0.5 },
  "ignoreApps": [],
  "sealApps": ["Proton Pass", "proton-pass"],
  "pasteKeys": { "default": "CTRL,V",
                 "classes": { "kitty": "CTRL SHIFT,V", "foot": "CTRL SHIFT,V", "Alacritty": "CTRL SHIFT,V",
                              "org.wezfurlong.wezterm": "CTRL SHIFT,V", "com.mitchellh.ghostty": "CTRL SHIFT,V" } },
  "reofferOnClose": true,
  "openOverFullscreen": true,
  "pasteDelayMs": 120,
  "enter": "paste", "joiner": "\n", "copyOnClose": true, "restoreAtStart": true,
  "pinnedFirst": true, "openOn": "all", "undoSec": 8
}
```

Limits apply to unpinned entries only. Pinned entries never expire or prune.

## Record

```json
{ "id": "<first 16 hex of sha256(bytes)>", "kind": "text|code|link|colour|image|files",
  "mime": "text/plain;charset=utf-8", "types": ["...offered types..."],
  "text": "<utf-8, at most textIndexKB; for files the uri-list, for images ''>", "truncated": false,
  "blob": "<id>.<ext>|null", "thumb": "<id>.webp|null",
  "bytes": 123, "lines": 1, "w": 0, "h": 0,
  "source": { "cls": "kitty", "title": "...", "address": "0x55d0c2a1b2c0" },
  "via": "copy|edit|transform|join|reoffer|import",
  "first": 1760000000000, "last": 1760000000000, "uses": 1,
  "pinned": false, "title": "" }
```

- Same bytes means the same id. A copy of an existing id is a BUMP (`last`, `uses`), never a second
  record.
- `kind` comes from `lib/kinds.py`:
  - `link`: a single URL.
  - `colour`: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()` or `hsla()`, whole text.
  - `code`: a heuristic over the text.
  - `files`: `text/uri-list` was offered.
  - `image`: an `image/*` type was offered (png preferred).
  - Otherwise `text`.
- Times are epoch ms. Imported cliphist entries have `first: 0` and `via: "import"`.

## Events (NDJSON on stdout, one object per line)

| ev | fields | when |
|---|---|---|
| `add` | `entry` | new record stored |
| `bump` | `id, last, uses` | existing record copied again |
| `update` | `entry` | pin / unpin / rename / tag; an image that lost its thumbnail (past `thumbsMax`) or got one back |
| `remove` | `ids, why` (`delete`/`prune`/`seal`/`scrub`) | records gone from disk |
| `secret` | `b64, mime, reason` (`hint`/`app`/`heuristic`), `source, t` | a sealed copy; NOTHING written. (The service's own Seal makes `reason: "manual"` secrets; no event carries that.) |
| `clear` | `t` | `CLIPBOARD_STATE=clear` |
| `nil` | `t` | `CLIPBOARD_STATE=nil`: the source went away, OR an explicit clear (stage 0: on sway 1.12 `wl-copy --clear` reads `nil`, never `clear`). The watch also fires once at start with the current state. |
| `empty` | `t, source` | data of zero bytes (a password manager "clearing" by writing nothing) |
| `skip` | `why` (`toolarge`/`unsupported`/`ignored`) | a copy the store refused; `ignored`: made in a class of `ignoreApps` (nothing of it is in the event) |
| `error` | `msg` | anything that failed; never contains clipboard bytes |

- `secret` never carries a hash or a length. Nothing about a secret touches disk or argv.
- No event is ever written to a log by the tool.
- Exit codes: `ingest` always exits 0, so the watcher loop never sees a failure. One-shot commands exit
  0 on success, 1 on a bad argument or unknown id, and 2 on a store error.

## Tool commands (`tools/clipboard/clip.py <cmd>`)

| cmd | in | out |
|---|---|---|
| `ingest` | env `CLIPBOARD_STATE`, stdin | one event |
| `keep` | stdin bytes, `--mime M --source-cls C --source-title T --via V` | `add`/`bump` |
| `seal <id>` | | `remove why=seal` (the service already holds the bytes, read from the blob or `text` BEFORE the call) |
| `pin <id>` / `unpin <id>` / `rename <id> <title>` | | `update` |
| `tag <id> <via>` | | `update` |
| `delete <id>...` | | `remove why=delete` |
| `prune` | | `remove why=prune` (if any) |
| `import-cliphist` | `cliphist` on PATH | a summary `{"ev":"import","added":n,"dropped":m}` |
| `config` | | `{"ev":"config","config":{...merged...},"stateDir":...,"configPath":...}`: the shell takes every default and both paths from here |

`ingest` in detail:
- `nil` and `clear` print their event and read nothing.
- An active window of `ignoreApps` ends it there: `skip`, sensitive or not.
- `sensitive`: read stdin, print `secret` with `reason: "hint"`. Never call anything that writes.
- `data`:
  1. Drain stdin.
  2. `wl-paste --list-types`, then pick the type: an `image/*` type, else `text/uri-list`, else
     `text/plain;charset=utf-8`, `text/plain`, `UTF8_STRING`.
  3. `wl-paste -n -t <picked>` for the bytes. Stage 0 confirms that these equal the watch's stdin for
     text.
  4. `hyprctl -j activewindow` for the source.
  5. `secret.classify(...)` decides BEFORE anything is written.
  6. Store, then print `add`/`bump`.
- Zero bytes means `empty`.
- Over `maxImageMB` (images) or 8 MB (anything else) means `skip`.

`lib/secret.py`: `classify(data: bytes, mime, source_cls, cfg) -> (bool, reason|None)`.
- `app`: the source class matches `sealApps` (case-insensitive).
- `heuristic`, text only. Single line after a trim, and one of:
  - a known token: `ghp_`, `gho_`, `github_pat_`, `glpat-`, `sk-`, `sk-ant-`, `xox[abpr]-`, `AKIA[0-9A-Z]{16}`,
    a JWT, or a PEM private-key block (multi-line allowed for PEM only);
  - a password shape: 8-128 chars, no whitespace, at least 3 character classes, entropy over
    `threshold`-scaled bits, and NOT a URL, path, email, UUID, hex digest or commit SHA, pure number,
    version, colour, identifier (snake/camel/kebab of dictionary-ish parts) or base64 data URI;
  - a passphrase: 3-8 alphabetic words joined by one of `-._ ` with at least one capital or digit, as
    Proton Pass's memorable passwords are.

## Service API (QML; `ClipboardService` and `ClipboardMock` alike)

The content reads only this.
- Properties:
  - `entries`: a ListModel of `QtObject { property var d }` records, newest first.
  - `serial`: bumped on every write, including reorders.
  - `secrets`: an array of `{key, mime, reason, source, t, expiresAt}`. Never the bytes; those stay in
    a private map.
  - `hidden`: `holds.screencast`.
  - `ready` and `error`.
  - `prefs`: the popup's own keys of the config, `{enter, joiner, copyOnClose, pinnedFirst, openOn}`
    (`ClipboardModel.PREFS` has their defaults); the owner reads `openOverFullscreen` and `undoWindowMs`
    beside it, the picker `pasteKeys`.
- Functions:
  - `paste(keys, opts)` with `opts = {mode:"paste"|"copy", via, text?, joiner?}`. `keys` are record
    ids or secret keys, in pick order. `text` overrides the bytes (edit and transform).
  - `pin(id, on)`, `rename(id, title)`, `remove(id)`, `undoRemove()`, `seal(id)`, `keep(secretKey)`,
    `dropSecret(key)`.
  - `revealSecret(key)` returns the secret's text for a PEEK only (added 2026-10-09). The caller holds it
    in a property while the peek lasts and clears it after; nothing else ever reads a secret's text.
  - `transforms(id)` returns the names that apply. `transform(id, name)` returns the text.
- The origin window `{address, cls}` is set by the owner at open: `service.origin`.
- `hostOpen` (bool, written by the owner): true while the clipboard popup is open. The paste key goes
  out only after it turns false (the layer surface has let go of the keyboard), `pasteDelayMs` later,
  and only if the active window is still `origin.address`. While the popup is up, Hyprland's active
  toplevel is ALREADY the origin (a layer surface is not a toplevel), so the address alone proves
  nothing.
- Rows of `entries` have two roles (settled 2026-10-09, the launcher's pattern): `key` (the record id)
  and `rec` (the `QtObject { property var d }`).
- A paste of two or more keys with no `text` puts the joined text on the clipboard. The watcher stores it
  like any copy, and the service tags it `via: "join"`.
- `empty` counts as a source clear: secrets drop (when `dropOnSourceClear`) and nothing is re-offered.
- `secret` and `empty` events carry `source: {cls, title}` (no address). `keep` takes `--source-address`
  too. `import-cliphist` prints only its summary, so the service re-reads `index.json` after it.
- Survive close works only on the entry the clipboard was holding, never on a secret.
  - sway sends `nil` for both a clear and a closed source. The entry is offered again when its
    `source.address` is gone, but never for the watcher's first event.
  - Hyprland sends nothing for either (0.md). The service acts on `closewindow` for the source window
    and checks with `wl-paste --list-types` that the clipboard is empty.
  - `windowClosed(address)` is public, so a probe can drive it.

## Stream ownership

- **A** (stage 1): `tools/clipboard/**`, `tools/lib/atomic.py` (moved from wiki; `tools/wiki/lib/atomic.py`
  becomes the wiki's thin wrapper adding its `env.scrub`), `clipboard.example.jsonc`, `.gitignore`'s
  `clipboard.json` line, `clipboard_py_cases.py`.
- **B** (stage 2 JS + mock): `modules/clipboard/data/ClipboardModel.js`, `ClipTransforms.js`,
  `ClipboardMock.qml`, `clipboard_js_cases.js`.
- **C** (stage 3 on the mock): `modules/clipboard/*.qml` except `data/`, `test_clipboard.qml`, the
  stage 3 tests.
- **Host** (stage 2 service): `modules/clipboard/data/ClipboardService.qml`,
  `modules/common/components/SupervisedStream.qml`, the SleepWatcher migration,
  `clipboard_service_probe.sh`.
