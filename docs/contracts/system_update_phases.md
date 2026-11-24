# `yay -Syu` phase reference

(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Reference for the system-update popup parser. Based on real capture
`/tmp/yay-syu-capture-2026-04-24-16-56-31.log` (1336 lines, 1.4 MB raw,
7 AUR packages + 116 official arch packages + DKMS + 3-kernel initramfs
rebuild + one sha256-FAILED AUR source).

The goal of this document: enumerate **every distinct phase** a typical
`yay -Syu` walks through, the **exact textual markers** that open/close
each phase, the **sub-phases** inside (with their own markers), what
**progress bars or prompts** appear, and the **package categorisation**
inside each. So the popup's parser + renderer can be state-driven,
deterministic, and understandable.

## Implementation notes (2026-08-30)

This document was written on 2026-04-24 from one capture, before any parser
existed. The parser (`modules/bar/system_update/components/PackageUpdateParser.qml`),
the popup (`SystemUpdatePopup.qml`) and the rail (`PhaseRail.qml`) were built
against it and then corrected by four rounds of real runs (2026-08-26 to
2026-08-30). The text below is kept as the reference for yay's OUTPUT; where
the implementation went another way a `> Built:` / `> Superseded:` note sits
under the section. Summary of the divergences:

- **Phase IDs.** The parser keeps A-O as written and adds `INITIAL` (before
  any output; the sudo/Howdy wait lives here), `PROMPT_EDIT_PKGBUILD`
  (yay 13's "PKGBUILDs to edit?" between G and H) and `COMPLETE`. Pacman's
  sub-phases are `L0_RESOLVE`, `L1_TABLE`, `L2_DOWNLOAD`, `L3_INTEGRITY`,
  `L4_PREHOOKS`, `L5_CHANGES`, `L6_POSTHOOKS` and, for the AUR install,
  `N0_LOAD`, `N1_TABLE`, `N3_INTEGRITY`, `N5_CHANGES`, `N6_POSTHOOKS`
  (the AUR transaction prints the same table and asks the same Proceed
  question as the official one, so it has the same `1` step). See §1.
- **Order on a mixed run (yay 13, 2026-08-30 capture):** sync -> AUR search
  -> upgrade list / exclude -> PKGBUILD download + cleanBuild / diffs (+ edit)
  -> makepkg "Making package" + "Retrieving sources" (curl meter redrawn with
  bare `\r`, no cursor escapes) -> SRCINFO -> DB sync 2 -> pacman resolve,
  which may print ":: The following package cannot be upgraded due to
  unresolvable dependencies:" and then yay's ":: Do you want to skip the
  above packages for this upgrade? [y/N] " WITHOUT a newline -> table /
  proceed -> download / install / hooks -> makepkg build ("Making package"
  again, "Checking runtime deps" first) -> `pacman -U` (second proceed) ->
  hooks. So L.0 / L.1 come AFTER phase I on a mixed run, and phase I's
  second "Making package" per package is phase M (the parser latches
  `_pastOfficialInstall` to tell them apart).
- **No Kernel phase.** DKMS removal is a pre-transaction hook; DKMS builds
  and `mkinitcpio` are post-transaction hooks (10/19 and 11/19 on this
  machine, a bus reload after them). The popup shows kernel work as the
  operation text inside its Install and Hooks steps. A dedicated "Kernel"
  notch existed for two days and was removed (`9650d73`). §L.6.a/b and §3's
  "Kernel work" grouping are therefore reference only.
- **The rail, not progress bars.** §4's inventory of bars became one
  element: `PhaseRail` with notches Sync, Resolve, [Sources], Download,
  Install, Hooks, [AUR] (AUR notches only when the transaction has AUR
  packages, decided at resolve time). The ball rests in a notch for
  unmeasurable phases and travels toward the next one in proportion for
  measurable ones. Mapping in §1.
- **Hooks are counted at START.** pacman prints `(n/m) hook` when hook n
  begins; `hooksDone = n-1` while it runs. Same for `(n/m) upgrading`:
  `installsDone = n-1`, `installsStarted = n`. Reading n as done showed
  "2/2" with a full groove while DKMS still had ten seconds to go.
- **Per-package download progress exists.** §L.2's "don't bother listing
  per-package" is superseded: pacman parks a live region (one row per
  concurrent download + Total) that never crosses a newline; the backend
  emits those cursor-addressed rows as `screenRows` and the parser maps
  each to its package by rebuilding `<name>-<newVer>-<arch>`.
- **Prompts without a newline** (the skip question, and any `[y/N]` in the
  tail) are opened from the backend's `previewUpdated` tail with the
  context current at that moment (`processPromptTail`); the committed
  line with the answer on it does not re-open them. Wording drifts between
  yay versions ("Proceed with install?" vs "installation?"), so matches are
  bare substrings. Kinds and UI in §5.
- **Verbosity modes** are not §7's: quiet = status card only, normal = card
  + rail + category list, verbose = + terminal 70/30. No structured tree
  next to the terminal.
- **UI groupings** are per repo (Core / Extra / Multilib / AUR / Flatpak /
  unknown repos), favourites pinned on top; no role / flavour axes in the
  UI (the parser still records `role` and `flavour` per row). §3.
- **Placement.** Everything is in `modules/common/components/`; there is no
  `modules/system_update/` and no bar module yet (§10).
- **Terminal.** The PTY is sized 120x50 (`stty` inside `script -qefc`) so
  pacman lays its table and download rows out at a sane width; the capture
  this doc came from was 260 columns.
- **Captures.** The original `/tmp/yay-syu-capture-2026-04-24-16-56-31.log`
  is gone from /tmp; use `tools/system_update/fixtures/yay-syu-sample.log`,
  `update_real_run_in_test_log.txt` (157 packages, vanilla, no kernel) and
  the recorded runs under `~/.local/share/system-update-logs/runs/<stamp>/`
  (`transcript.log` + `ui-state.jsonl`; the 2026-08-26 run has linux +
  DKMS, the 2026-08-30 10:57 run has exclude + skip-dep + one AUR package).
  `tools/system_update/replay_yay_log.sh` replays any of them; `replay_real_log.sh`
  prints the rail's step sequence; `analyse_ui_log.py` checks a
  recorded run.

---

## 0. What `yay` actually is

`yay` is a thin Go orchestrator over `pacman` + `makepkg`. A single
`yay -Syu` invocation is really:

1. `pacman -Sy` (sync dbs)
2. Query AUR RPC for each locally-installed AUR package
3. Print the combined upgrade list
4. Ask interactive questions (exclude, cleanBuild, diffs)
5. For every AUR package: run `makepkg -o` (fetch+extract+prepare),
   then later run `makepkg -e` (build+package in fakeroot)
6. Run `pacman -Su` (the big official transaction)
7. Finally run `pacman -U <built AUR pkg.tar.zst files>`

Every line of text you see in `yay -Syu` originates from one of: `yay`
itself, `pacman`, `makepkg`, a post-install `.install` scriptlet inside
a package, a pacman hook program (`mkinitcpio`, `dkms`, `glib-compile-schemas`,
`update-desktop-database`, …), or an external helper like `gpg`.

Knowing this, the parser is a tree: top-level phases (yay-driven),
pacman sub-phases (line-by-line progress), hook sub-output, makepkg
sub-output.

---

## 1. Lifecycle overview

Top-level phases in the order they actually fire. Letter keys used as
phase IDs throughout this doc and in the parser state machine.

| # | ID | Name | Trigger (first line) | End (last line) |
|---|------|------|---|---|
| A | `DB_SYNC_1` | Sync package databases | `:: Synchronizing package databases...` | `<repo> is up to date` for every repo |
| B | `AUR_SEARCH` | Search AUR for updates | `:: Searching AUR for updates...` | `:: N packages to upgrade/install.` |
| C | `UPGRADE_LIST` | Numbered upgrade list | `  N  <repo>/<pkg>   oldver -> newver` (first row) | last numbered row (count-down to `  1`) |
| D | `PROMPT_EXCLUDE` | Packages to exclude | `==> Packages to exclude:` | `==> ` (user-input received) |
| E | `GROUPED_SUMMARY` | Dependency/explicit grouped summary | `Sync Dependency (N):` | `AUR Dependency (N):` or nearest |
| F | `PKGBUILD_CACHE` | PKGBUILD cache check | `:: PKGBUILD up to date, skipping download: X` (or `:: Downloading PKGBUILD: X`) | last such line |
| G | `PROMPT_CLEANBUILD` | cleanBuild question | `==> Packages to cleanBuild?` | `==> ` |
| H | `PROMPT_DIFFS` | diff display question | `==> Diffs to show?` | `==> ` |
| I | `AUR_SRC_FETCH` | makepkg source-fetch loop | `==> Making package: X` (no fakeroot yet) | `==> Sources are ready.` |
| J | `SRCINFO_PARSE` | yay SRCINFO parse | `:: (1/N) Parsing SRCINFO: X` | `:: (N/N) Parsing SRCINFO: X` |
| K | `DB_SYNC_2` | Sync again before main install | `:: Synchronizing package databases...` (2nd occurrence) | repo `is up to date` |
| L | `OFFICIAL_INSTALL` | Official pacman transaction (big one) | `:: Starting full system upgrade...` | `:: Running post-transaction hooks...` end (last hook done) |
| M | `AUR_BUILD_LOOP` | makepkg build + package loop | `==> Making package: X` (2nd occurrence per pkg, with fakeroot) | `==> Finished making: X` for last pkg |
| N | `AUR_INSTALL` | Pacman install of built AUR pkgs | `loading packages...` (no `::` prefix) | last `:: Running post-transaction hooks...` hook done |
| O | `FINAL_ERRORS` | Failed-package report | ` -> Failed to install the following packages.` | EOF |

Notes on ordering:

- **K** and **L** happen *after* **I/J** because yay re-syncs databases right
  before invoking pacman for the big upgrade. This second sync is usually
  a no-op but we must detect it so we don't conflate it with phase A.
- **I** and **M** both start with `==> Making package:`. They're
  distinguished by the lines *between*: phase I has `Sources are ready.`,
  `Extracting sources...`, no `fakeroot`; phase M has `Entering fakeroot
  environment...` and `Starting package()...`. The second `==> Making
  package: X` for the SAME package name always means the fakeroot build.
- Prompts D, G, H are **inline** — they pause the stream waiting for
  user input. The popup must detect these and surface them as input
  affordances (not just text).
- Prompts are optional — `yay --noconfirm` skips D/G/H and the `[Y/n]`
  proceed prompt in L and N.

> Built. Parser phase IDs: `INITIAL`, A-O as above, plus `PROMPT_EDIT_PKGBUILD`
> after H, and `COMPLETE`. The popup maps them to rail notches like this
> (`SystemUpdatePopup._rawStep`, high-water mark by key so the ball never
> goes back when yay revisits an earlier phase):
>
> | Parser state | Notch | Progress |
> |---|---|---|
> | `INITIAL` (auth), A, B, K (`DB_SYNC_2`) | Sync | — |
> | C, D, E, F, G, H, `PROMPT_EDIT_PKGBUILD`, J, `L0_RESOLVE`, `L1_TABLE` | Resolve | — |
> | `N0_LOAD`, `N1_TABLE` (the AUR transaction's table and its Proceed question) | AUR | builds done / total |
> | I `AUR_SRC_FETCH` (only when the run has AUR work, else Resolve) | Sources | curl bytes per file, packages fetched |
> | `L2_DOWNLOAD`, and the `pacman_proceed` prompt on a mixed run | Download | Total-row bytes (preferred over the package count) |
> | `L3_INTEGRITY`, `L4_PREHOOKS` (first 10 %), `L5_CHANGES` (rest); `N3`, `N5` | Install | packages started / total |
> | `L6_POSTHOOKS`, `N6_POSTHOOKS` | Hooks | hooks completed / total |
> | M `AUR_BUILD_LOOP`, N `AUR_INSTALL` | AUR | builds done / total |
> | O, `COMPLETE` | last notch | full |

---

## 2. Phase details

### A. DB_SYNC_1 — Sync package databases

```
:: Synchronizing package databases...
 core
 extra
 multilib
 multilib is up to date core is up to date extra is up to date
```

- `:: ` lines come from pacman itself (cyan bold in real colour).
- Below that, three rows for the three repos configured in
  `/etc/pacman.conf`: `core`, `extra`, `multilib`. A user with testing
  repos enabled would see more.
- Pacman re-writes those repo rows in place using cursor-up escapes
  (`\x1b[1F`, `\x1b[2F`). Raw capture has `multilib is up to date core
  is up to date extra is up to date` on one line — artefact of my strip
  collapsing the cursor movements. In the live renderer we need to
  either:
  - Apply a minimal cursor-up model inside `TerminalBackend.qml`
    (re-renders just that 3-row region), OR
  - Collapse to a single line `DB sync: core ✓  extra ✓  multilib ✓`
    via pattern recognition.
- Downloads happen here too (usually milliseconds, shows as `<repo>
  <size> <rate>` transient).
- End marker: all three repos reached `is up to date` *or* completed
  downloading (`<repo>                  X KB   Y KB/s`).

**UI hint (normal mode):** one line — `Syncing package databases` with a
3-bullet indicator that fills as each repo is checked.

> Built: the card title reads "Syncing package databases" and the ball sits in
> the Sync notch; no per-repo bullets. The cursor-up problem is solved in
> `TerminalBackend`: it keeps a screen model for cursor-addressed rows, so the
> repo rows redraw in place in the terminal view and reach the parser as
> `screenRows`.

### B. AUR_SEARCH — Query AUR RPC

```
:: Searching AUR for updates...
:: Searching databases for updates...
 -> Flagged Out Of Date AUR Packages: proton-mail-bin  python-dlib  stremio  tidal-dl-ng
 -> python-pyqtdarktheme: local (2.1.0-5) is newer than AUR (2.1.0-4)
:: 122 packages to upgrade/install.
```

- `:: Searching AUR for updates...` = yay hits the AUR RPC endpoint for
  every locally-installed AUR package.
- `:: Searching databases for updates...` = yay compares local pacman db
  with synced repo dbs (same thing `checkupdates` does).
- ` -> Flagged Out Of Date AUR Packages:` — warning. AUR packages whose
  maintainer has flagged the upstream as stale. Shown as a SINGLE LINE
  with packages space-separated. Possibly very long.
- ` -> <pkg>: local (X) is newer than AUR (Y)` — a local package with a
  manually-installed newer version than what AUR has. One line per such
  package.
- `:: N packages to upgrade/install.` — total count yay computed,
  combining official and AUR.

**UI hint:** quick spinner `Searching for updates`, then collapse to a
summary line with the count and any warnings (flagged / locally newer)
as a small yellow badge.

### C. UPGRADE_LIST — Numbered upgrade table

```
122  core/archlinux-keyring              20260409-1              -> 20260420-1
121  core/ca-certificates-mozilla        3.122-1                 -> 3.123-1
...
  1  aur/visual-studio-code-bin          1.116.0-1               -> 1.117.0-1
```

- Fixed-width yay output. Columns: number (right-justified, width of
  max), `<repo>/<pkg>` (left-justified padded), old version (padded),
  `->`, new version.
- Numbers count *down* (largest to 1) so user can type `^5` to exclude
  the top 5.
- `<repo>` is one of `core`, `extra`, `multilib`, `testing`, `aur`, and
  any custom repos. We classify packages by this prefix.
- AUR rows always sort last (repo order: core < extra < multilib < aur).
- Total rows = count from phase B.

**UI hint:** parse every row into
`{number, repo, name, oldVer, newVer, isAur}`. Expose as a scrollable
list in the popup (quiet/normal: just a count + expand; verbose: full
list). Group by repo in display:
- `core/` (N pkgs)
- `extra/` (N pkgs)
- `multilib/` (N pkgs)
- `aur/` (N pkgs)

### D. PROMPT_EXCLUDE

```
==> Packages to exclude: (eg: "1 2 3", "1-3", "^4" or repo name)
 -> Excluding packages may cause partial upgrades and break systems
==> 
```

- `==> ` trailing space with no newline = yay's prompt-ready state.
- Valid inputs: empty (include all), list `1 2 3`, range `1-5`,
  exclusion `^4` (everything EXCEPT 4), repo name `core`.
- Input goes into `TerminalBackend.submit()`. The exclusion is applied
  silently — the rest of the run continues with the reduced set.

**UI hint:** popup prompt with "Skip packages" text input. Default
empty = include all. Optional helper buttons per repo ("Exclude AUR").

> Built: the banner asks "Packages to exclude" with the terminal's own hint as
> the field placeholder (`eg: "1 2 3", "1-3", "^4" or repo name`), an
> Exclude/Apply button (disabled while empty) and the default "Exclude none".
> The parser applies the answer the way yay does (`excludeSelection`: numbers,
> ranges, `^`, a repo word) so excluded rows leave the list and the later
> `Package (N)` table lands on the right rows. No per-repo helper buttons.

### E. GROUPED_SUMMARY

```
Sync Dependency (84): python-click-8.3.3-1, openvpn-2.7.2-1, ...
Sync Explicit (31): gimp-3.2.4-1, libreoffice-fresh-26.2.2-4, ...
AUR Explicit (5): docker-desktop-4.70.0-1, visual-studio-code-bin-1.117.0-1, ...
AUR Dependency (2): electron39-bin-39.8.9-1, electron40-bin-40.9.2-1
```

- yay prints up to 4 lines (may omit any that would be empty):
  - `Sync Dependency (N)` — official deps pulled in by other pkgs.
  - `Sync Explicit (N)` — official pkgs the user installed directly.
  - `AUR Dependency (N)` — AUR pkgs pulled in as deps of other AUR pkgs.
  - `AUR Explicit (N)` — AUR pkgs the user installed directly.
- Each line is `<kind> (N): <pkg1-ver>, <pkg2-ver>, ..., <pkgN-ver>` —
  comma-separated. This is YAY’s OWN grouping label; use these for the
  Dep/Expl classification in our UI. Versions here are already the
  target versions (vs. phase C which shows old→new).
- Lines can be very long — one fullscreen-wide log line per category.

**UI hint:** four counters `Sync Dep / Sync Expl / AUR Dep / AUR Expl`.
Click to expand the list.

### F. PKGBUILD_CACHE

```
:: PKGBUILD up to date, skipping download: docker-desktop
:: PKGBUILD up to date, skipping download: visual-studio-code-bin
...
```

- One line per AUR package. Either `:: PKGBUILD up to date, skipping
  download: <pkg>` (cached) or `:: Downloading PKGBUILD: <pkg>` (fresh).
- All AUR pkgs in the upgrade set appear here, so we can count
  AUR-touched packages from this phase alone if needed.

**UI hint:** silent by default, rolled up into the AUR-build phase
progress. Verbose mode shows each line.

### G. PROMPT_CLEANBUILD

```
  7 docker-desktop                   (Installed) (Build Files Exist)
  6 visual-studio-code-bin           (Installed) (Build Files Exist)
...
  1 electron40-bin                   (Installed) (Build Files Exist)
==> Packages to cleanBuild?
==> [N]one [A]ll [Ab]ort [I]nstalled [No]tInstalled or (1 2 3, 1-3, ^4)
==> 
```

- Re-prints the numbered AUR list (without version, just `(Installed)`
  / `(Build Files Exist)` annotations).
- Asks whether to wipe `$HOME/.cache/yay/<pkg>/` before building.
- Default `[N]one` — reuse cached extracted sources, which is fast.
- Input: `N`/empty = none, `A` = all, `Ab` = abort the whole run,
  `I` = installed only, `No` = not-installed, or number list.

**UI hint:** one prompt row with a select: "Reuse cached builds".
Default "None (reuse all)". Advanced UI offers per-package toggles.

### H. PROMPT_DIFFS

Identical structure to G but for showing diffs between committed
PKGBUILDs and cached ones:

```
(same 7-line list)
==> Diffs to show?
==> [N]one [A]ll [Ab]ort [I]nstalled [No]tInstalled or (1 2 3, 1-3, ^4)
==> 
```

- Default None. Yes → yay pipes the diff through `$PAGER`, which on a
  PTY-less process would break. In our popup we probably want to force
  `PAGER=cat`.

**UI hint:** secondary row "Show diffs". Default None.

> Built: G, H and yay 13's "PKGBUILDs to edit?" (`PROMPT_EDIT_PKGBUILD`) share
> one field + default button, shown ONE AT A TIME with a breath between (the
> questions arrive back to back and used to swap in place). `PAGER=cat` is not
> forced; answering diffs with anything but None is untested.

### I. AUR_SRC_FETCH — First makepkg pass (no fakeroot)

Per-package, repeating:

```
==> Making package: postman-bin 12.6.8-1 (Fri 24 Apr 2026 05:02:05 PM CEST)
==> Checking runtime dependencies...
==> Checking buildtime dependencies...
==> Retrieving sources...
  -> Found postman.desktop
  -> Found postman-12.6.8-linux-x64.tar.gz
==> Validating source files with sha256sums...
    postman.desktop ... Passed
==> Validating source_x86_64 files with sha256sums...
    postman-12.6.8-linux-x64.tar.gz ... Passed
==> Removing existing $srcdir/ directory...
==> Extracting sources...
  -> Extracting postman-12.6.8-linux-x64.tar.gz with bsdtar
==> Sources are ready.
```

Markers per sub-step:

| Sub-step | Marker (first line) | Ends on |
|---|---|---|
| deps-check | `==> Checking runtime dependencies...` | next `==>` |
| src-retrieve | `==> Retrieving sources...` | next `==>` |
| src-validate | `==> Validating source files with sha256sums...` (also `..._x86_64`, `..._i686`, etc.) | next `==>` |
| src-fail | `==> ERROR: One or more files did not pass the validity check!` | line after |
| src-extract | `==> Extracting sources...` | next `==>` |
| src-prepare | `==> Starting prepare()...` (optional, only if PKGBUILD has `prepare()`) | `==> Sources are ready.` |
| src-ready | `==> Sources are ready.` | always last in phase I for this pkg |

Source validation sub-lines (indented 4 spaces):
- `<file> ... Passed` — sha256 match
- `<file> ... FAILED` — mismatch; next line is `==> ERROR: One or more
  files did not pass the validity check!`, then yay prints an error
  summary and the package is NOT built (e.g. `nordzy-cursors` in this
  capture).
- `<file> ... Skipped` — if `SKIP` in sha256sums (common for PGP-only)

Arch-specific sections appear for PKGBUILDs with `source_x86_64=`,
`source_i686=`, `source_aarch64=` etc.

**Download progress inside `==> Retrieving sources`**: when a source is
NOT cached, a full curl-style progress bar appears:
```
  -> Downloading Nordzy-cursors.tar.gz...
  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                 Dload  Upload   Total   Spent    Left  Speed
100 2413k  100 2413k    0     0  3024k      0 --:--:-- --:--:-- --:--:-- 3021k
```
(Didn't appear in this capture because all sources were cached; would
appear on first `-Syu` after cleanBuild=All or when PKGBUILD bumps a
source URL.)

> Seen since (2026-08-30 run). makepkg's curl redraws the meter with bare
> `\r` and no cursor escapes; the parser splits lines with embedded `\r`
> into progress rows and reads them into `sourceFetchFile / Pct / BytesDone /
> BytesTotal / Rate / Eta` and `aurSourcesDone`. These drive the Sources
> notch, the figures on the card, and the AUR category header and row. The
> pre-transaction "Making package" is phase I; the same header after the
> official transaction is phase M (see §M).

Git sources:
```
  -> Cloning <pkg>-git git repo...
Cloning into bare repository '/home/user/.cache/yay/<pkg>/<pkg>-git'...
remote: Enumerating objects: 12345, done.
remote: Counting objects: 100% (234/234), done.
...
Receiving objects: 100% (12345/12345), 45.67 MiB | 20.12 MiB/s, done.
Resolving deltas: 100% (8765/8765), done.
```

**At end of phase I**, if ANY package failed src-validate, yay dumps:
```
 -> error downloading sources: /home/user/.cache/yay/nordzy-cursors 
	 context: error downloading sources: /home/user/.cache/yay/nordzy-cursors 
	 context: exit status 1 
```
Two identical lines plus trailing blanks. Detect `^ -> error downloading
sources:` as the "srcfetch failed summary" marker.

**UI hint:** one row per AUR package, showing state `fetching sources /
extracted / FAILED`. Failed packages are marked red, rest continue.

### J. SRCINFO_PARSE

```
:: (1/7) Parsing SRCINFO: postman-bin
:: (2/7) Parsing SRCINFO: electron40-bin
...
:: (7/7) Parsing SRCINFO: nordzy-cursors
```

- yay parses `.SRCINFO` of each AUR package (even failed ones like
  nordzy-cursors — the PKGBUILD was downloaded, only the tarball
  failed).
- Very fast. One line per package. Good anchor for "N of M ready"
  counter.

**UI hint:** ignore in quiet/normal; verbose shows them.

### K. DB_SYNC_2

Identical markers to phase A. The only context clue distinguishing it
is **which is the second occurrence in the stream** — use an ordinal
counter in the parser.

In verbose mode show as "Re-sync before install"; quiet/normal ignore.

### L. OFFICIAL_INSTALL — The main pacman transaction

This is the biggest phase. Breaks into many sub-phases:

#### L.0 start / resolve

```
:: Starting full system upgrade...
resolving dependencies...
looking for conflicting packages...
```

No progress spinner, just sit-and-wait. Conflicts would print here as
`:: <pkg> and <other> are in conflict. Remove <other>? [y/N]` (a
prompt!) — not in this capture.

> Seen since (2026-08-30 run, a package excluded at D whose dependency was
> then unresolvable):
>
> ```
> warning: <pkg>: ignoring package upgrade (old -> new)
> warning: cannot resolve "<dep>", a dependency of "<pkg2>"
> :: The following package cannot be upgraded due to unresolvable dependencies:
>       <pkg2>
> :: Do you want to skip the above package for this upgrade? [y/N]
> ```
>
> The last line is printed WITHOUT a newline. The parser captures the list as
> `_unresolvable` (it is the question's context and the skip set), opens the
> prompt from the tail as `yay_skip_dep`, and on "y" drops exactly those rows
> (`skipContextPackages`). On a mixed run this whole block comes AFTER the AUR
> source fetch (phase I), so L.0 / L.1 map to the Resolve notch while the ball
> is held at Sources by the high-water mark, and the proceed prompt maps to
> Download so the ball waits beside the highlighted categories.

#### L.1 Package table

```
Package (116)                       Old Version              New Version               Net Change  Download Size

extra/alsa-card-profiles            1:1.6.3-1                1:1.6.4-1                   0.00 MiB       0.03 MiB
...
extra/xterm                         407-1                    409-1                       0.00 MiB       0.45 MiB

Total Download Size:    176.99 MiB
Total Installed Size:  7699.51 MiB
Net Upgrade Size:       376.07 MiB

:: Proceed with installation? [Y/n] 
```

- Column-aligned. Trailing blank `Download Size` means the package is
  already cached in `/var/cache/pacman/pkg/`.
- `Package (N)` row count is the TOTAL packages pacman will touch — it
  matters for the per-package counter in L.5.
- `Total Installed Size` = disk footprint of the new set.
- `Net Upgrade Size` = delta (new − old).
- `Total Download Size` = only non-cached.
- Then the yes/no prompt. Default `Y`.

**UI hint:** summary card with three bytes totals. Full table in
verbose.

#### L.2 :: Retrieving packages...

```
:: Retrieving packages...
 mesa-1:26.0.5-1-x86_64
 Total ( 0/88)      0.0  B  0.00  B/s 00:00 [------------...] 0%
 ollama-0.21.1-1-x86_64
 Total ( 0/88)      ...
 ...
 Total (88/88)    177.0 MiB  16.7 MiB/s 00:11 [################] 100%
```

- `N/88`: the number of *completed* downloads over the total non-cached
  count. So 88 of 116 packages needed download; the other 28 were cached.
- Each `<pkg>-<ver>-<arch>` line announces the file about to start.
- The `Total` line is a CR-overwriting progress bar — fixed 260-char
  terminal width from the capture header. Columns:
  - `Total (n/N)` left-justified
  - space-padded to ~center
  - `<bytes downloaded>` right-aligned
  - `<rate>` e.g. `37.8 MiB/s`
  - `<eta>` e.g. `00:03` (HH:MM or MM:SS)
  - `[####-----]` bar
  - `NN%` percent
- Parser note: the `<pkg>-<ver>-<arch>` label is one line, then the
  `Total` bar gets overwritten. Our backend already handles \r
  collapse, so both survive.

**UI hint:** big global progress bar + currently-downloading package
name + speed/ETA. Don't bother listing per-package lines individually.

> Superseded: per-package progress is available and shown. pacman keeps a live
> region on screen (one row per concurrent download, up to ParallelDownloads,
> plus the `Total` row) and repaints it with CR and CSI row moves, never
> emitting a newline for the whole phase. `TerminalBackend.screenRows` hands
> those rows to the parser synchronously per chunk (a timer would reorder them
> against the newline-terminated lines); trailing CRs are stripped before the
> ANSI parse (CR means "overwrite from column 0", which emptied every row).
> Each row is matched to its package by rebuilding `<name>-<newVer>-<arch>`
> (there is no unambiguous split point in `libyuv-r2921+644251f25-1-x86_64`);
> truncated names resolve by prefix/suffix. Verified on a 212-package capture:
> 26 745 rows matched, all packages tracked to 100 %. The aggregate row gives
> `downloadSoFar / Rate / Eta / Pct`; the rail prefers the byte percent over
> the package count. The download step ends at 100 % when the Total row does;
> the last package holds a small tail (`tailHold` 8 %) so it is not shown done
> before pacman says so. `Total Download Size` / `Total Installed Size` /
> `Net Upgrade Size` are parsed into bytes.

#### L.3 Integrity checks (5 parallel steps)

```
(116/116) checking keys in keyring                                  [################] 100%
(116/116) checking package integrity                                [################] 100%
(116/116) loading package files                                     [################] 100%
(116/116) checking for file conflicts                               [################] 100%
(116/116) checking available disk space                             [################] 100%
```

- Five pacman steps, each runs (N/M) per-package progress that hits
  100% before the next step starts.
- Possible mid-output: `warning: could not get file information for ...` —
  pacman warnings about missing files. Not blocking.

**UI hint:** five tick-marks or a 5-step breadcrumb.

#### L.4 :: Running pre-transaction hooks...

```
:: Running pre-transaction hooks...
(1/2) Removing linux initcpios...
(2/2) Remove DKMS modules
==> dkms remove --no-depmod evdi/1.14.15 -k 6.19.11-arch1-1
==> dkms remove --no-depmod it87/301.8dd7f65 -k 6.19.11-arch1-1
==> dkms remove --no-depmod nvidia/595.58.03 -k 6.19.11-arch1-1
==> dkms remove --no-depmod evdi/1.14.15 -k 6.18.22-1-lts
==> dkms remove --no-depmod it87/301.8dd7f65 -k 6.18.22-1-lts
==> dkms remove --no-depmod nvidia/595.58.03 -k 6.18.22-1-lts
==> depmod 6.19.11-arch1-1
==> depmod 6.18.22-1-lts
```

- Each hook is one `(n/N) <Description>...` line.
- Hooks often emit their own output; the `==> dkms remove ...` lines
  are the DKMS hook speaking. These are sub-output of hook `(2/2)`.
- In this capture, 2 pre-hooks fired. The number varies based on what
  packages are being replaced (initcpio, dkms, systemd, ldconfig,
  gpg-keyring hooks are the common ones).

**UI hint:** pre-hooks tend to be terse. A single "Running pre-install
hooks" row with the current hook name.

#### L.5 :: Processing package changes...

The actual install phase. Per-package:

```
:: Processing package changes...
(  1/116) upgrading alsa-card-profiles        [################] 100%
(  2/116) upgrading glibc                     [################] 100%
Generating locales...
  en_US.UTF-8... done
Generation complete.
(  3/116) upgrading systemd-libs              [################] 100%
```

Prefix variants (lines before the `[bar]`):

| Verb | Means |
|---|---|
| `upgrading` | old ver → new ver |
| `installing` | new package, no old |
| `reinstalling` | same ver, re-install |
| `downgrading` | old ver → older ver |
| `removing` | old ver, going away |

**Scriptlet output** between package bars is from the package's
`.install` file. Examples from this capture:
- glibc: `Generating locales...` / `<locale>... done` / `Generation complete.`
- archlinux-keyring: `==> Appending keys from archlinux.gpg...` /
  `==> Updating trust database...` / `gpg: next trustdb check due at 2026-10-21`
- xterm: `New optional dependencies for xterm` /
  `    luit: locale converter for -lc option [installed]`

Scriptlet output is unformatted — can include `gpg:` debug lines,
error-like strings, etc. It's package-specific and unpredictable.

**Per-package association:** scriptlet output belongs to the LAST
`(n/N) upgrading|installing|... <pkg>` line. Parser must track current
package and attribute lines until the next `(n/N)` prefix.

**UI hint:**
- Quiet: one-line `Installing N of 116: <pkg>` with an overall bar.
- Normal: per-package row with state (queued / installing / done),
  scriptlet count badge.
- Verbose: full stream.

> Built: L.3, L.4 and L.5 are ONE rail step, "Install" (the integrity checks
> and pre-transaction hooks take its first tenth, the package changes the
> rest, so the groove never runs backwards). The live `(n/m) upgrading X` row
> is package n STARTING: `installsDone = n-1`, `installsStarted = n`, and the
> newline-terminated 100 % copy of the row is what makes it n. Rows get an
> `installing` state (they used to jump from queued to installed). No
> scriptlet count badge; scriptlet output is only in the terminal.

#### L.6 :: Running post-transaction hooks...

```
:: Running post-transaction hooks...
( 1/22) Creating system user accounts...
( 2/22) Creating temporary files...
( 3/22) Updating journal message catalog...
...
(22/22) Updating the desktop file MIME type cache...
```

22 hooks in this capture. Common post-hooks with important sub-output:

##### L.6.a DKMS install (hook `(14/22) Install DKMS modules`)

```
(14/22) Install DKMS modules
==> dkms install --no-depmod evdi/1.14.15 -k 6.18.24-1-lts
==> dkms install --no-depmod nvidia/595.58.03 -k 6.19.13-arch1-1
==> dkms install --no-depmod it87/301.8dd7f65 -k 6.19.13-arch1-1
==> dkms install --no-depmod nvidia/595.58.03 -k 6.18.24-1-lts
==> dkms install --no-depmod it87/301.8dd7f65 -k 6.18.24-1-lts
==> dkms install --no-depmod evdi/1.14.15 -k 6.19.13-arch1-1
==> depmod 6.18.24-1-lts
==> depmod 6.19.13-arch1-1
```

One `==> dkms install --no-depmod <mod>/<ver> -k <kernel>` per
(module × kernel) combination. Then `==> depmod <kernel>` per kernel.

**In this capture DKMS ran silently** because modules were already
cached (same version, just rebuild metadata). In a real compile
scenario the output expands to:

```
==> dkms install --no-depmod nvidia/595.58.03 -k 6.19.13-arch1-1

Building module:
Cleaning build area...
make -j16 KERNELRELEASE=6.19.13-arch1-1 all KERNEL_UNAME=6.19.13-arch1-1 CC=cc NV_EXCLUDE_BUILD_MODULES='' LD=ld KBUILD_EXTRA_WARN=1...............
Signing module:
 - /var/lib/dkms/nvidia/595.58.03/build/nvidia.ko
 - /var/lib/dkms/nvidia/595.58.03/build/nvidia-modeset.ko
 - /var/lib/dkms/nvidia/595.58.03/build/nvidia-drm.ko
 - /var/lib/dkms/nvidia/595.58.03/build/nvidia-uvm.ko
 - /var/lib/dkms/nvidia/595.58.03/build/nvidia-peermem.ko
Cleaning build area...
```

That `make -j16 ... ................` line ends with a series of dots
that are printed as dots accumulate while make runs — NOT a standard
progress bar, just status ticking. Takes ~2-5 minutes for nvidia.

**UI hint:** expose each (module, kernel) pair as a sub-row. Render
the `........` ticking as a spinner. Emit progress as "nvidia rebuilt
against linux-g14 / linux-lts / linux".

##### L.6.b Initramfs rebuild (hook `(16/22) Updating linux initcpios`)

**Once per installed kernel** (linux-g14, linux-lts, linux here):

```
(16/22) Updating linux initcpios...
==> Building image from preset: /etc/mkinitcpio.d/linux-g14.preset: 'default'
==> Using default configuration file: '/etc/mkinitcpio.conf'
  -> -k /boot/vmlinuz-linux-g14 -g /boot/initramfs-linux-g14.img
==> Starting build: '6.18.9-arch1-1-g14'
  -> Running build hook: [base]
  -> Running build hook: [udev]
  -> Running build hook: [autodetect]
  -> Running build hook: [microcode]
  -> Running build hook: [modconf]
  -> Running build hook: [kms]
  -> Running build hook: [keyboard]
  -> Running build hook: [keymap]
  -> Running build hook: [consolefont]
==> WARNING: consolefont: no font found in configuration
  -> Running build hook: [numlock]
  -> Running build hook: [block]
  -> Running build hook: [filesystems]
  -> Running build hook: [resume]
  -> Running build hook: [fsck]
==> Generating module dependencies
==> Creating zstd-compressed initcpio image: '/boot/initramfs-linux-g14.img'
  -> Early uncompressed CPIO image generation successful
==> Initcpio image generation successful
==> Building image from preset: /etc/mkinitcpio.d/linux-lts.preset: 'default'
  ...
==> Initcpio image generation successful
==> Building image from preset: /etc/mkinitcpio.d/linux.preset: 'default'
  ...
==> Initcpio image generation successful
```

Markers per kernel:
- start: `==> Building image from preset: /etc/mkinitcpio.d/<name>.preset: 'default'`
- end: `==> Initcpio image generation successful`
- `'<name>'` identifies the kernel (`linux`, `linux-lts`, `linux-g14`,
  `linux-zen`, etc.)
- Inside each: the build-hook list (base, udev, autodetect, ...,
  filesystems, resume, fsck). User-configurable in `/etc/mkinitcpio.conf`
  but these are the Arch defaults.

Presets can have multiple targets (`default` + `fallback`) — would show
up as two `Building image from preset: ... 'default'` and `... 'fallback'`
per kernel.

**UI hint:** user explicitly called out "when my g14 kernel is building
again, I want to see that". Surface each kernel image build as its own
sub-phase with hooks ticking off as a sub-progress. Summary: "Rebuilding
initramfs for linux-g14 (12/15 hooks) → linux-lts → linux".

##### L.6.c Other post-hooks (quiet one-liners)

Most post-hooks emit no sub-output and finish in milliseconds:
- `Creating system user accounts...`
- `Creating temporary files...`
- `Updating journal message catalog...`
- `Updating udev hardware database...`
- `Applying kernel sysctl settings...`
- `Reloading system manager configuration...`
- `Reloading user manager configuration...`
- `Updating the MIME type database...`
- `Enqueuing marked services...`
- `Reloading device manager configuration...`
- `Arming ConditionNeedsUpdate...`
- `Rebuilding certificate stores...`
- `Updating module dependencies...`
- `Restarting cronie for libc upgrade...` (only when glibc upgrades)
- `Reloading system bus configuration...`
- `Checking for old perl modules...`
- `Compiling GSettings XML schema files...`
- `Updating icon theme caches...`
- `Updating the info directory file...`
- `Updating the desktop file MIME type cache...`

**UI hint:** collapse to single "Running post-install hooks (14/22)".
Verbose shows the list. Highlight DKMS + initramfs hooks because they
have the longest runtime and can fail.

> Built as the "Hooks" step. `(n/m) hook` is printed when hook n STARTS, so
> `hooksDone = n-1` while it runs, m once the phase ends; `hooksStarted = n`.
> The DKMS / initramfs sub-output (L.6.a / L.6.b) is parsed into `dkmsOps`,
> `initramfsBuilds`, `currentDkmsOp`, `currentInitramfsKernel/Hook` and
> shown as the operation text under the Hooks (or Install, for pre-hooks)
> step; the fields are cleared on every new hook line so a DKMS line during
> the PRE-hooks cannot leak into the post-hooks. There is no separate kernel
> panel or notch (see the implementation notes). Hooks are closed at
> COMPLETE, and on the hand-over to the AUR build if pacman never prints a
> closing line.

### M. AUR_BUILD_LOOP — makepkg build + package in fakeroot

Per-package, order = reverse-dependency topology (deps first, then
dependents). In this capture: postman-bin → docker-desktop → vscode-bin
→ nordzy-hyprcursors → electron40-bin → electron39-bin. The failed
nordzy-cursors was skipped but appeared in phase I.

```
==> Making package: postman-bin 12.6.8-1 (Fri 24 Apr 2026 05:02:05 PM CEST)
==> Checking runtime dependencies...
==> Checking buildtime dependencies...
==> Retrieving sources...
  -> Found postman.desktop
  -> Found postman-12.6.8-linux-x64.tar.gz
==> Validating source files with sha256sums...
    postman.desktop ... Passed
==> Validating source_x86_64 files with sha256sums...
    postman-12.6.8-linux-x64.tar.gz ... Passed
==> Removing existing $srcdir/ directory...
==> Extracting sources...
  -> Extracting postman-12.6.8-linux-x64.tar.gz with bsdtar
==> Sources are ready.
==> Making package: postman-bin 12.6.8-1 (Fri 24 Apr 2026 05:02:08 PM CEST)
==> Checking runtime dependencies...
==> Checking buildtime dependencies...
==> WARNING: Using existing $srcdir/ tree
==> Entering fakeroot environment...
==> Starting package()...
==> Tidying install...
  -> Removing libtool files...
  -> Removing static library files...
  -> Purging unwanted files...
  -> Compressing man and info pages...
==> Checking for packaging issues...
==> Creating package "postman-bin"...
  -> Generating .PKGINFO file...
  -> Generating .BUILDINFO file...
  -> Generating .MTREE file...
  -> Compressing package...
==> Leaving fakeroot environment.
==> Finished making: postman-bin 12.6.8-1 (Fri 24 Apr 2026 05:02:11 PM CEST)
==> Cleaning up...
```

**The SAME package has TWO `==> Making package: <pkg> <ver> (<time>)`
headers.** First = the phase-I fetch; second (in this phase M) = the
build+package pass, which always has `Entering fakeroot environment...`
a few lines later. If you see `==> WARNING: Using existing $srcdir/
tree`, you're in the build pass. If you see `==> Sources are ready.`
as the last marker before the next `==>`, you were in the fetch pass.

Sub-steps of phase M per package:

| Step | Marker | End |
|---|---|---|
| deps-check | `==> Checking runtime dependencies...` | `==> Checking buildtime dependencies...` + 1 line |
| sources-reuse-warning | `==> WARNING: Using existing $srcdir/ tree` | next `==>` |
| fakeroot-enter | `==> Entering fakeroot environment...` | `==> Leaving fakeroot environment.` |
| **pkgver** | `==> Starting pkgver()...` (optional, for `-git` pkgs) | `==> Updated version: <pkg> <newver>` |
| **prepare** | `==> Starting prepare()...` (optional) | next `==>` |
| **build** | `==> Starting build()...` (optional — BINARY pkgs skip this!) | `==> Entering fakeroot environment...` |
| **check** | `==> Starting check()...` (optional) | `==> Entering fakeroot environment...` |
| **package** | `==> Starting package()...` (ALWAYS present) | `==> Tidying install...` |
| tidying | `==> Tidying install...` | `==> Checking for packaging issues...` |
| packaging-check | `==> Checking for packaging issues...` | `==> Creating package "<pkg>"...` |
| create-pkg | `==> Creating package "<pkg>"...` | `==> Leaving fakeroot environment.` |
| done | `==> Finished making: <pkg> <ver> (<time>)` | `==> Cleaning up...` |

**Binary AUR packages (`-bin` suffix)**: no `build()`, usually just a
`package()` that copies files into `$pkgdir/`. Output between `Starting
package()...` and `Tidying install...` is free-form — typically bsdtar
output, mkdir/cp lines, sed transforms, etc. In this capture it was
mostly file listings from `tar` (nordzy-hyprcursors) or nothing at all
(postman-bin, docker-desktop, vscode-bin).

**Source AUR packages (compiled)**: `Starting build()...` → large
amount of output from whatever build system the package uses. Common
patterns the parser needs to tolerate:

- **Cargo (Rust)** — e.g. `yay` itself, `paru`, `bat`, `zellij`:
  ```
  ==> Starting build()...
     Compiling libc v0.2.155
     Compiling proc-macro2 v1.0.79
     Compiling unicode-ident v1.0.12
     ...
     Compiling yay v12.3.4
      Finished release [optimized] target(s) in 2m 35s
  ```
  One line per crate. Total crate count is large (several hundred for
  a big Rust binary). Rarely a progress bar, usually scrolling text.
  At end: `Finished release [optimized] target(s) in <time>`.
  Cargo can also show:
  ```
     Compiling syn v2.0.60
      Building [=======>                ] 123/456: crate-name
  ```
  with a CR-overwriting bar when run in a TTY (we have a PTY so this
  appears).

- **Ninja / CMake** — e.g. `mesa-git`, `qt6-*-git`:
  ```
  ==> Starting build()...
  -- The C compiler identification is GNU 15.1.1
  -- The CXX compiler identification is GNU 15.1.1
  ...
  -- Configuring done
  -- Generating done
  -- Build files have been written to: /home/user/.cache/yay/pkg/src/build
  [1/3456] Building CXX object src/CMakeFiles/foo.dir/bar.cpp.o
  [2/3456] Building CXX object src/CMakeFiles/foo.dir/baz.cpp.o
  ...
  [3456/3456] Linking CXX executable foo
  ```
  `[N/M]` is ninja's per-action counter. No CR overwriting — each action
  is a separate line (but in TTY mode with `-v`, output is scrolling).
  On multi-core builds actions are interleaved (not strictly ordered).

- **Make** — e.g. many classic autotools projects:
  ```
  ==> Starting build()...
  make  all-recursive
  make[1]: Entering directory '/home/user/.cache/yay/pkg/src/foo-1.2.3'
  Making all in src
  make[2]: Entering directory '/.../src'
    CC foo.o
    CC bar.o
    CCLD foo
  make[2]: Leaving directory '/.../src'
  make[1]: Leaving directory '/.../foo-1.2.3'
  ```
  Depth-tracked by `make[N]`. Per-file step lines start with whitespace
  then verb (`CC`, `CCLD`, `CXX`, `CXXLD`, `AR`, `LD`, ...).

- **Autotools configure**:
  ```
  ==> Starting build()...
  checking build system type... x86_64-pc-linux-gnu
  checking host system type... x86_64-pc-linux-gnu
  checking for gcc... gcc
  checking whether the C compiler works... yes
  ...
  configure: creating ./config.status
  config.status: creating Makefile
  config.status: executing depfiles commands
  ```
  Extremely chatty. Most lines are `checking for X... <result>`.

- **Go build** — e.g. `yay`, `docker`:
  ```
  ==> Starting build()...
  go build -ldflags="-s -w" -o yay
  ```
  Usually a single line then silence until done (Go's build is quiet
  by default).

- **Meson** — modern projects like mesa, systemd:
  ```
  The Meson build system
  Version: 1.10.2
  Source dir: /home/user/.cache/yay/pkg/src/foo
  Build dir: /home/user/.cache/yay/pkg/build
  ...
  Run-time dependency <dep> found: YES 1.2.3
  ...
  Build targets in project: 234
  ```
  Then handoff to `ninja` for the actual build.

- **Python setup.py / pyproject**:
  ```
  * Building wheel...
  running build
  running build_py
  ...
  * Built <pkg>-<ver>-py3-none-any.whl
  * Installing <pkg>-<ver>-py3-none-any.whl
  ```
  Or pip-style with live progress.

- **Kernel module builds** (inside DKMS, already covered in L.6.a):
  ```
  make -C /usr/src/linux-6.19.13-arch1-1 M=/var/lib/dkms/nvidia/595.58.03/build modules
    CC [M]  /var/lib/dkms/nvidia/595.58.03/build/nvidia-drv.o
    CC [M]  /var/lib/dkms/nvidia/595.58.03/build/nvidia-modeset.o
    ...
    LD [M]  /var/lib/dkms/nvidia/595.58.03/build/nvidia.ko
  make[1]: Leaving directory '/usr/lib/modules/6.19.13-arch1-1/build'
  ```

**linux-g14 kernel** (user mentioned): this is not an AUR package in
the usual sense — it's in a custom `[g14]` repo per the g14 wiki. If
the user compiles it *themselves* (e.g. `linux-g14` AUR variant), it's
a Kbuild compile:
```
==> Starting build()...
  HOSTCC  scripts/basic/fixdep
  HOSTCC  scripts/kconfig/conf.o
  HOSTCC  scripts/kconfig/confdata.o
  ...
  CC      init/main.o
  CC      init/version.o
  ...
  LD      vmlinux.o
  MODPOST vmlinux.symvers
  MODPOST Module.symvers
  CC [M]  drivers/foo/bar.o
  ...
```
Thousands of `CC` / `LD` lines. Takes 20-40 minutes on a laptop.

If the user just reuses the precompiled `[g14]` repo version, the
kernel is installed as an *official* Arch package (phase L) and the
only compile-like output is in the initramfs rebuild (L.6.b) and any
DKMS modules (L.6.a) being recompiled against it.

**Error paths in phase M:**

```
==> Validating source files with sha256sums...
    Nordzy-cursors.tar.gz ... FAILED
==> ERROR: One or more files did not pass the validity check!
```
→ package skipped, not built, not installed. Shown in phase O.

Compile errors:
```
==> ERROR: A failure occurred in build().
    Aborting...
 -> error making: <pkg>-exit status 4
```

PGP key not in user keyring:
```
==> Verifying source file signatures with gpg...
    <file> ... FAILED (unknown public key ABCDEF)
==> ERROR: One or more PGP signatures could not be verified!
```

Missing build dep:
```
==> Checking runtime dependencies...
==> ERROR: Could not resolve all dependencies.
```

**UI hint:** one row per AUR package with state:
- `queued` (grey)
- `fetching` (anim spinner, phase I)
- `building` (orange, with sub-progress for cargo/ninja counts if parsable)
- `packaging` (yellow — inside fakeroot)
- `done` (green)
- `failed` (red, with error message)

In verbose mode the full stream shows through. Build/compile output is
the LARGEST and NOISIEST part of a full update — expect 10k+ lines from
a big compile.

### N. AUR_INSTALL — Final pacman install of built AUR pkgs

yay calls `pacman -U <pkg1.pkg.tar.zst> <pkg2.pkg.tar.zst> ...`. This
doesn't start with `:: Synchronizing...` or `:: Starting full system
upgrade...` — it's a `-U` install, not `-Su`. Start marker:

```
loading packages...
resolving dependencies...
looking for conflicting packages...

Package (6)             Old Version  New Version  Net Change

docker-desktop          4.69.0-1     4.70.0-1       1.36 MiB
electron39-bin          39.8.8-1     39.8.9-1       0.00 MiB
electron40-bin          40.9.1-1     40.9.2-1       0.00 MiB
nordzy-hyprcursors      2.4.0-1      2.5.0-1       -0.35 MiB
postman-bin             12.5.6-1     12.6.8-1       7.18 MiB
visual-studio-code-bin  1.116.0-1    1.117.0-1      0.22 MiB

Total Installed Size:  3488.50 MiB
Net Upgrade Size:         8.41 MiB

:: Proceed with installation? [Y/n] 
```

- No `<repo>/` prefix on package names (they're local files).
- No `Download Size` column (nothing to download).
- Same `[Y/n]` prompt.

Then the same pacman sub-phases as L.3→L.6:

```
(6/6) checking keys in keyring                         [################] 100%
(6/6) checking package integrity                       [################] 100%
(6/6) loading package files                            [################] 100%
(6/6) checking for file conflicts                      [################] 100%
(6/6) checking available disk space                    [################] 100%
:: Processing package changes...
(1/6) upgrading postman-bin                            [################] 100%
Stopping docker-desktop for all users
(2/6) upgrading docker-desktop                         [################] 100%
Enabling use of privileged ports by Docker Desktop
kubernetes.docker.internal already in /etc/hosts
Restarting docker-desktop for users who previously had it enabled
Warning: The unit file, source configuration file or drop-ins of docker-desktop.service changed on disk. Run 'systemctl --user daemon-reload' to reload units.
(3/6) upgrading visual-studio-code-bin                 [################] 100%
==> NOTE: Custom flags should be put directly in: ~/.config/code-flags.conf
(4/6) upgrading nordzy-hyprcursors                     [################] 100%
(5/6) upgrading electron40-bin                         [################] 100%
(6/6) upgrading electron39-bin                         [################] 100%
:: Running post-transaction hooks...
(1/5) Reloading user manager configuration...
(2/5) Updating the MIME type database...
(3/5) Arming ConditionNeedsUpdate...
(4/5) Updating icon theme caches...
(5/5) Updating the desktop file MIME type cache...
```

No pre-hooks usually (nothing DKMS-ish to clean when replacing AUR
binaries). 5 post-hooks is typical for AUR-only.

**UI hint:** same renderer as phase L but simpler because no
download/sync/DKMS/initramfs layers.

### O. FINAL_ERRORS

```
 -> Failed to install the following packages. Manual intervention is required:
nordzy-cursors - exit status 1
```

- Only appears if any AUR package failed phase I or M.
- Each failed package: `<pkg> - <reason>` on its own line.
- Manual fixes: user re-runs `yay -Syu` after fixing the issue (e.g.
  clear cache, update PKGBUILD, add PGP key).

**UI hint:** red banner at bottom of the popup with "N package(s)
failed" and expandable list of names + reasons. Offer "Retry" button
(re-runs `yay -S <failed-pkg>`) and "Open in editor" (opens the yay
cache dir).

---

## 3. Package categorisation for the UI

From the data we see in phase C (numbered list) and phase E (grouped
summary), categorize like this:

### Primary axis: source

- **Official Arch**: repo = `core`, `extra`, `multilib`, `testing`,
  `community` (legacy), or any custom repo in `/etc/pacman.conf`
  (`[g14]`, `[chaotic-aur]`, etc.).
- **AUR**: repo = `aur` in yay's output.

### Secondary axis: role

- **Explicit** — user asked for this by name.
- **Dependency** — pulled in by something else.

Both come from `Sync Dependency (N)`, `Sync Explicit (N)`, `AUR
Dependency (N)`, `AUR Explicit (N)` in phase E.

### Tertiary axis: install flavour

- **Binary / pre-compiled** — `-bin` AUR, any official pkg.
- **Source AUR (compiled)** — detected in phase M by presence of
  `==> Starting build()...`.
- **Git AUR** — `-git` suffix on pkg name, identified by
  `==> Starting pkgver()...` in phase M.
- **Kernel**: names matching `^linux(-lts|-zen|-g14|-...)?$` —
  triggers initramfs rebuild in L.6.b. Headers package
  `^linux.*-headers$` triggers DKMS rebuild in L.6.a.
- **DKMS module source** — detected by name containing `-dkms` or by
  its entry showing up in the DKMS remove/install hook output.
- **Flatpak / snap / other** — NOT covered by yay; a separate updater
  would handle them. Out of scope for phase-2 v1.

### UI groupings (for the popup's "packages" panel)

```
┌─ Official Arch (116) ────────────────────────────┐
│  ▸ core (27)                                      │
│  ▸ extra (82)                                     │
│  ▸ multilib (7)                                   │
├─ AUR (7) ────────────────────────────────────────┤
│  ▸ binary -bin (6)                                │
│  ▸ source (0)                                     │
│  ▸ git -git (0)                                   │
│  ▸ failed (1: nordzy-cursors)                     │
├─ Kernel work ─────────────────────────────────────┤
│  ▸ initramfs rebuilt: linux-g14 / linux-lts / linux│
│  ▸ DKMS modules: nvidia, evdi, it87 × 3 kernels   │
└───────────────────────────────────────────────────┘
```

> Superseded. The popup groups by REPO, one collapsible category each:
> Core / Extra / Multilib / AUR / Flatpak in `AvailableUpdatesService.
> categoryOrder`, unknown repos (e.g. a `[g14]` or `[chaotic-aur]` line)
> inserted after the known official ones with their own colour, and a
> pinned "Favourites" category on top (`$XDG_STATE_HOME/lares/system-update/favorites.json`,
> right-click a row to toggle). Category colours follow yay's own syntax
> highlighting in kitty eva-light. Role (explicit / dependency) and flavour
> (bin / git / kernel / dkms) are still parsed per row but not used for
> grouping; there is no "Kernel work" group.

---

## 4. Progress bars across all phases (inventory)

Where in the run to show what:

| Phase | Bar type | Data |
|---|---|---|
| A (DB_SYNC_1) | 3-step ticker | `core ✓ / extra ✓ / multilib ✓` |
| L.2 (retrieve) | single bar + rate + ETA | `N/88`, pkg name, MiB/s, MM:SS |
| L.3 (5 checks) | 5-step ticker | each (N/M) hits 100% |
| L.5 (install) | single bar | `N/116` pkgs installed |
| L.6 post-hooks | single bar | `N/22` hooks done |
| L.6.a DKMS | multi-sub | each (mod, kernel) a sub-dot |
| L.6.b initramfs | per-kernel | current hook inside current image |
| M AUR build | single bar | `N/M` packages built |
| M per-pkg build | conditional | cargo `N/M` crates, ninja `[N/M]`, dots for DKMS |
| N.checks | 5-step ticker | as L.3 |
| N.install | single bar | `N/6` |

Active status line: whichever phase is current + most granular bar.

> Superseded by the rail (see the implementation notes and §1's mapping).
> The measurable steps are Sources (curl bytes), Download (Total-row bytes),
> Install (package count, hooks in the first tenth), Hooks (hook count) and
> AUR (builds done); everything else is a resting ball with a particle
> swirl. Per-package figures (bytes / rate / ETA while downloading, curl
> figures for AUR sources) sit on the rows and the category headers, laid
> out by `DownloadStats` in fixed-width slots so a changing digit moves
> nothing. The header meter (`Meter.qml`) that this table was written for
> was replaced by the rail on 2026-08-26 (`bd3d401`).

---

## 5. Prompt detection & input

Distinct prompts to recognise:

| Prompt | Regex match | Default | Input type |
|---|---|---|---|
| Sudo password | `^\[sudo\] password for \S+: $` | — | password |
| yay exclude | `^==> Packages to exclude:` | empty | text/nums |
| yay cleanBuild | `^==> Packages to cleanBuild\?` | `N` | choice |
| yay diffs | `^==> Diffs to show\?` | `N` | choice |
| pacman proceed | `^:: Proceed with installation\? \[Y/n\] $` | `Y` | y/n |
| pacman conflict | `^:: \S+ and \S+ are in conflict\. Remove \S+\? \[y/N\] $` | `N` | y/n |
| pacman retrieval retry | `^:: Proceed with installation\? \[Y/n\] $` after a fail | `Y` | y/n |
| AUR rebuild continue | `^==> Restart building \S+\? \[y/N\] $` | `N` | y/n |
| Import PGP key | `^==> Import\? \[Y/n\] $` | `Y` | y/n |

All prompts share the property that they're printed WITHOUT a trailing
newline — the final byte in the chunk is either `:` or space after `]`.
Our backend's `awaitingInput` / `passwordPrompt` detection must handle
each.

The yay `==> ` prompts are uniquely identifiable because they're
preceded by a `==> <question>` line and followed by a tail `==> `.

> Built. Prompt kinds as implemented (`parser.currentPromptKind`, mirrored as
> scalars because bindings through a `var` object were unreliable):
>
> | Kind | Opened by | Banner |
> |---|---|---|
> | `yay_exclude` | `==> Packages to exclude:` (committed line) | field + Exclude/Apply + "Exclude none" |
> | `yay_cleanbuild` | `==> Packages to cleanBuild?` | field + default |
> | `yay_diffs` | `==> Diffs to show?` | field + default |
> | `yay_edit_pkgbuild` | `==> PKGBUILDs to edit?` (yay 13) | field + default |
> | `pacman_proceed` | `Proceed with install` + `[Y/n]` in the TAIL (bare substring; yay 12 said "installation") | yes / no raised pair, default in accent |
> | `yay_skip_dep` | `skip the above package` in the tail | yes / no, with pacman's unresolvable list as context |
> | `yay_yesno` | any other `[y/N]` / `[Y/n]` in the tail | yes / no, question text as title |
> | `password` | `TerminalBackend.passwordPrompt` heuristic (sudo), not the parser | masked field; "Authenticating…" shown before sudo prints anything (Howdy/PAM) |
>
> Still unhandled: pacman conflict (`Remove X? [y/N]`) and PGP import
> (`==> Import? [Y/n]`) would fall into `yay_yesno` and get a plain yes/no
> without special context; retry-after-download-failure is untested.
> Default detection (`[Y/n]` vs `[y/N]`) is done (`currentPromptDefault`).
> Replies go through `backend.submit()`; the mock answers itself after 2 s.

---

## 6. Parser state machine (proposed)

One top-level state and a stack of nested "phase" frames. Pseudocode:

```
state = { phase: null, frame: {}, stack: [] }

for each line in stream:
  classify(line) by regex against the markers above
  when entering a new phase, push a frame with { id, start_line, meta }
  when a marker closes a frame, pop and emit the completed frame

emit events:
  - phase_started(id, meta)
  - phase_progress(id, value, total?, label?)
  - phase_ended(id, outcome: success|failed|skipped)
  - prompt_opened(kind, text, default)
  - prompt_closed(kind, user_input)
  - package_event(pkg, kind: queued|fetching|building|packaging|installed|failed, detail?)
```

The QML side subscribes to events and updates its tree model. The
terminal backend stays as-is (just a colourful byte stream renderer);
the parser is an additional consumer that reads from the same
`lineAppended` / `previewUpdated` signals.

> Built differently: `PackageUpdateParser` is a QML Item whose STATE is
> bindable (`phase`, `subPhase`, labels, counters, `currentPrompt*`,
> `awaitingUserInput`, ListModels `packages` / `hooks` / `initramfsBuilds`
> / `dkmsOps` / `errors`), with a few signals for things a binding cannot
> express (`phaseEntered`, `subPhaseEntered`, `packageEvent`, `promptOpened`
> / `promptClosed`, `packageProgress(name, state, pct, ...)` written into
> the one row it names, `initramfsKernelStarted/Ended`, `dkmsOpLogged`). No
> frame stack. It consumes four backend signals: `lineAppended` (committed
> lines), `progressPreview` (CR-redrawn progress rows), `previewUpdated`
> (the live tail, for prompts without a newline) and `screenRows`
> (cursor-addressed rows). Lines longer than `maxTableRowChars` (400) are
> not pattern-matched. `MockUpdateRun` fakes the same surface without a
> process.

---

## 7. Verbosity modes (mapping to phases)

From `system_update.md`: quiet, normal, verbose.

### Quiet
- Show only: current top-level phase name, one global progress bar,
  any pending prompt, final success/error count.
- Example: "Building AUR packages (3/7) — electron40-bin"
- Suppress: all inline output, sub-phases, hook names, scriptlet output.

### Normal
- Show: top-level phase with expandable sub-phase rows
  (current one auto-expanded).
- Show: per-package install state, DKMS module rebuild list,
  initramfs kernel list, key warnings/notes from scriptlets.
- Suppress: raw command output, configure-check lines, file listings.

### Verbose
- Show: everything. Full TerminalView-style scrollback of the raw
  stream. Also shows the structured tree alongside (or above) as a
  secondary nav — click a phase to jump to its byte range.

All three modes write the FULL raw stream to the log file (with ANSI
preserved), regardless of which UI mode. The user's 2-update log
rotation rule applies to the log file.

> Superseded (what shipped, `SystemUpdatePopup.verbosityMode`):
>
> - **quiet** — the status card alone: phase title, "n / m packages · eta"
>   on one line, the prompt banner when a question is open. The popup's
>   implicit height is the tab row + the card, so the host can collapse.
> - **normal** — card + phase rail + the carved category list with live
>   per-package state (self-draining as packages finish).
> - **verbose** — the same with `TerminalView` beside it (70/30, wrap
>   toggle, selection + copy). No structured tree, no click-to-jump.
>
> A two-finger horizontal swipe anywhere in the popup switches view (the
> terminal owns the gesture while it is scrolling). Logging: `SystemUpdateLogger`
> keeps the 2 most recent raw logs in `~/.cache/lares/system-update-logs/`;
> real runs from the mockup additionally record `transcript.log` +
> `ui-state.jsonl` per run under `~/.local/share/system-update-logs/runs/`
> (`UiStateRecorder`), which is NOT pruned.

---

## 8. Gaps — what this capture didn't exercise

Must-handle cases NOT present in this log; our parser should tolerate
them via pattern inference:

1. **Fresh PKGBUILD download** (`:: Downloading PKGBUILD: <pkg>` instead
   of `:: PKGBUILD up to date, skipping download: <pkg>`).
2. **Diff viewer invocation** if user chooses `A` at phase H — would
   dump each PKGBUILD diff through `less` by default; we need
   `PAGER=cat` forced in env, or detect and swallow.
3. **Package conflict resolution** (`:: X and Y are in conflict…
   Remove X? [y/N]`).
4. **PGP key import prompt** (`==> Import? [Y/n]`).
5. **Partial download failure + retry** (`error: failed retrieving
   file 'X' from Y : operation timed out`, then pacman asks to retry).
6. **Compiled AUR package** — all 7 in this capture were `-bin` or
   static-asset. A cargo-based compile (e.g. `linutil-bin` → compiled
   variant, `paru`, `zellij-git`) would add hundreds to thousands of
   `Compiling <crate>` lines inside phase M.
7. **`-git` AUR package** — invokes `pkgver()` which runs a git
   describe against the local clone. Output:
   ```
   ==> Starting pkgver()...
   ==> Updated version: hyprland-git r4519.g123abc-1
   ```
8. **DKMS actual compile** — we saw `dkms install --no-depmod nvidia/
   595.58.03 -k 6.19.13-arch1-1` execute silently because modules were
   cached. Under a KERNEL version bump (not seen here), dkms prints
   `Building module: / Cleaning build area... / make -j… / Signing
   module: …` — this can take 2-5 min for nvidia.
9. **Kernel-panic-worthy package** (`linux-g14` actually compiling from
   source): user mentioned this explicitly. ~20-40 min of `CC`/`LD`
   lines from Kbuild. Parser should recognise Kbuild verbs:
   `  HOSTCC`, `  CC`, `  CC [M]`, `  LD`, `  LD [M]`, `  AR`,
   `  BUILD`, `  MODPOST`, `  EXTRACT_CERTS`, `  DEPMOD`.
10. **Timeshift snapshot** (legacy pre-step from `update-sys.sh`) —
    would be handled BEFORE yay even runs, so separate parser territory.
11. **`[Y/n]` default-Y detection** — `[Y/n]` means default Y on empty
    input, `[y/N]` means default N. The popup needs to honour these.

Phase 2 spec should leave hooks open to add these without re-plumbing.

> Status 2026-08-30: 1 seen and handled (`:: Downloading PKGBUILD`, Resolve);
> 11 done (`currentPromptDefault`). New since: the skip-dependency question
> (handled, see §L.0), AUR source fetch with a live curl meter (handled,
> §I). Still open, no transcript exercised them: 2 (diff viewer / `PAGER`),
> 3 (conflict prompt; falls into `yay_yesno`), 4 (PGP import; same), 5
> (retry), 6 (cargo / ninja / make output — the build is one "AUR" step
> with `currentAurBuildStep`, compile lines are terminal-only), 7 (`-git`
> `pkgver()`), 8 (a real DKMS compile; the 2026-08-26 run had DKMS +
> initramfs but cached modules), 9 (Kbuild), 10 (Timeshift — not part of
> the run at all).

---

## 9. Data model (TypeScript-ish pseudocode for the QML model)

```ts
type PhaseId = "DB_SYNC_1"|"AUR_SEARCH"|"UPGRADE_LIST"|...|"FINAL_ERRORS";

type Package = {
  name: string;
  repo: "core"|"extra"|"multilib"|"aur"|string;
  oldVer?: string;
  newVer: string;
  isAur: boolean;
  role: "explicit"|"dependency"|"unknown";
  flavour: "binary"|"source"|"git"|"bin"|"kernel"|"dkms";
  state: "queued"|"fetching"|"building"|"packaging"|"installing"|"done"|"failed";
  error?: string;
  buildBytes?: string[];        // raw log offsets for verbose mode
};

type Phase = {
  id: PhaseId;
  startLine: number;
  endLine?: number;
  label: string;
  outcome?: "success"|"failed"|"skipped";
  progress?: { value: number; total: number; rate?: string; eta?: string };
  subPhases: Phase[];
  // phase-specific detail:
  packages?: Package[];         // for UPGRADE_LIST, OFFICIAL_INSTALL, AUR_INSTALL
  hooks?: { name: string; subOutput: string[] }[];  // for pre/post hooks
  dkmsOps?: { module: string; version: string; kernel: string; op: "install"|"remove" }[];
  initramfs?: { kernel: string; hooks: string[]; success: boolean }[];
};

type UpdateRun = {
  startedAt: number;
  command: string;          // "yay -Syu"
  phases: Phase[];
  packages: Map<string, Package>;   // global lookup
  prompts: Prompt[];
  errors: { pkg: string; reason: string }[];
  done: boolean;
  exitCode?: number;
};
```

> Built shape (flat, not a tree): `parser.packages` rows are
> `{number, repo, name, oldVer, newVer, isAur, role, flavour, state, error,
> pct, bytesDone, bytesTotal, rate, eta, ...}` with `state` in queued /
> downloading / downloaded / installing / installed / fetching / building /
> built / failed (see `_findOrAdd` / `_update`); `hooks` `{name, phase,
> index, total}`; `initramfsBuilds` `{kernel, preset, hookCount, success}`;
> `dkmsOps` `{op, module, version, kernel}`; `errors` `{pkg, reason}`.
> Phases are not stored as objects: `phase` / `subPhase` are the current
> ones and the UI keeps its own high-water step. `UiStateRecorder` writes
> what the UI believed per change (`ui-state.jsonl`) beside the transcript
> for post-mortems.

---

## 10. Next steps for phase 2 implementation

1. Build `modules/bar/system_update/components/PackageUpdateParser.qml` — a
   headless QML Item that subscribes to a `TerminalBackend`'s
   `lineAppended` / `previewUpdated` and emits the events listed in §6.
   No UI. ~600-800 lines of regex + state transitions.
2. Build `test_update_parser.qml` in project root — feeds the capture
   log at `/tmp/yay-syu-capture-*.log` into a TerminalBackend using a
   `cat` command, then renders the parser's emitted event list next to
   the terminal. Visual regression harness.
3. Build `SystemUpdatePopup.qml` — the actual popup renderer with the
   three verbosity modes and the package grouping tree.
4. Build `SystemUpdateIcon.qml` — the bar icon with idle / available /
   updating states and animated mini-progress driven by the same
   parser.
5. Build an idle poller (`yay -Qua` + `checkupdates` every 15 min,
   configurable) — separate from the update runner.
6. Wire up log rotation — keep the 2 most recent raw ANSI logs in
   `~/.cache/lares/system-update-logs/YYYY-MM-DD_HH-MM-SS.log`,
   oldest deleted on new-run start.

Each of steps 1-6 is a separate prompt/turn. They drop into
`modules/system_update/` or `modules/common/components/` respectively
per the CLAUDE.md placement rule.

> Status 2026-08-30: 1 done (`375a4c4`, then reworked through 2026-08-30);
> 2 done (`test_update_parser.qml`, `tools/system_update/replay_yay_log.sh`); 3 done
> (`76b72e6`, but the popup's shape is nothing like the 2b version: rail
> instead of meter, per-repo carved list, prompt banner in the card — see
> `docs/system_update.md`); 4 done (`SystemUpdateIcon`; nothing
> feeds `staleDays` yet); 5 half: `AvailableUpdatesService` exists with
> `refresh()`, the timer-driven poller and the bar module that would own it
> do not; 6 done (`SystemUpdateLogger`), plus `UiStateRecorder` for real
> runs. Placement: everything went to `modules/common/components/`; there is
> no `modules/system_update/`.
