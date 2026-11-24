# Tools, helpers and LLM tools

Three folders hold programs rather than QML:

- **`tools/`** -- programs the user runs by hand, that `lares` runs, or that the shell starts for one job (a screenshot, a
  clipboard write, a wiki batch). Grouped by the module they serve. `tools/dev/` is the developer's kit: what proves a change
  (below, "The dev kit").
- **`helpers/`** -- programs that live outside the shell: a daemon (screen time), a root helper (silicon), and the system update's
  detached runner and sudo. Rust crates are built with `cargo` and installed by their own `install.sh`, which the user runs.
- **`llm_tools/`** -- what the LLM popup's model may call, and the rules that limit it.

Nothing here is run by a test against the real desktop: the tests stub what touches the machine.

**Root** marks what needs root or changes the system; nothing in the shell runs it without the user.

## tools/

### The shell, the lock, the theme

| Name | What it is for | Who runs it |
|---|---|---|
| `tools/shell/lares` | the shell's control: `deploy`, `start`, `restart`, `status`, `log`, `binds`, `setup`, `apply --commit`, `preview`, `oled`, `update-running`, `cleanup-marks`, `migrate-name`, `cleanup-old-name`, `snapshot`, `session`, `publish`, `help` ([shell.md](shell.md)) | the user; `start` from Hyprland's autostart at login; the rescue key Super+Shift+F12 (`restart`) |
| `tools/shell/lares-supervise` | keeps the shell running: restarts it when it exits; a crash loop (more than three exits in a minute) is said once through Hyprland's own notification and tried again every 30 s, doubling to 5 min | `lares start`, as Hyprland's child |
| `tools/shell/lares-lib.sh` | helpers both scripts share | sourced |
| `tools/publish/lares-publish` | the public copy: `check` / `build` the export of a commit without `tools/publish/exclude.txt`'s paths, as the local branch `public`'s next commit ([publishing.md](publishing.md)) | `lares publish` |
| `tools/publish/privacy_check.py` | the leak check: the export view against the private list (`config/privacy.jsonc`) and the generic rules; exceptions in `privacy_allow.txt` | `lares publish`, the quick tier (`privacy`) |
| `tools/shell/lares-config.py` | reads your Hyprland config for `binds` / `setup` (every `.lua` file: keys, layer rules, the environment, autostart); `cleanup-marks`, the one write, takes out an earlier deploy's marks after a diff and a typed yes | `lares` |
| `tools/shell/lares-migrate.py` | the move to the name Lares: `migrate-name` (one exchange per directory, symlink at the old path, a typed yes), `cleanup-old-name` (refuses while anything names an old thing), and what `deploy` asks (is it migrated; which old entry points still need a shim) | `lares` |
| `tools/shell/lares-sweep` | the retention sweep: one table of what may age out of the caches ([shell.md](shell.md) "Retention") | the supervisor, daily; the user (`--dry-run`) |
| `tools/shell/root/` | **Root.** `lares-boot-lock` and `hyprland-lares.desktop`: the lock at boot, installed beside the old `qs-boot-lock` / `hyprland-qslock.desktop`; `lares setup` prints the commands to install them and their undo | the user, by hand |
| `tools/shell/lares-init.py` | `lares init`: the config files a new machine's hardware asks for, written once | the user, on a new machine |
| `tools/shell/needs.tsv` | what the shell uses, the package that has it and what it is for | read by `lares setup` |
| `tools/shell/sudo-offer.bash` | in a terminal, offers to rerun a command that failed for want of root with sudo, one key | the user sources it from `~/.bashrc` |
| `tools/lockscreen/` | the lock's launcher, supervisor and helpers ([lockscreen.md](lockscreen.md)) | hypridle, the power reel, the boot lock |
| `tools/session/lares-session`, `sessionlib/`, `rules.json` | session restore: the snapshot of the Hyprland session, the run-or-type rules, the restore ([session.md](session.md)) | the shell (`begin`, `watch`, `end`), the user through `lares session` |
| `tools/snapshot/lares-snapshot`, `lares-offsite`, `root/` | system snapshots: the CLI and undo plan (`lares snapshot`), the Proton Drive copy (`lares snapshot offsite`), and the root tool, hooks, polkit files, installer and rescue the user installs by hand ([snapshots.md](snapshots.md)) | the shell (`SnapshotService`), the user through `lares snapshot`; pacman, through the hooks |
| `tools/session/session-hook.bash` | the bash hook: a terminal's running line (the mark) and a restored terminal's command (typed or run) | sourced from the user's `~/.bashrc` |
| `tools/theme/themectl` | the desktop's theme generator: `apply`, `set`, `toggle`, `next`, `diff`, `list`, `doctor`, `install`, `migrate`, `restore`, `resolve` ([theme.md](theme.md)) | the theme button (`"apply": "themectl"`), the user |
| `tools/theme/targets.json`, `templates/` | which programs follow the theme, and the file each gets | `themectl` |
| `tools/theme/windows/` | a small agent for the Windows VM that applies the mode `themectl` leaves in its shared folder (`INSTALL.md`) | the user, inside the VM |
| `tools/hypr-group-tabs/` | a Hyprland plugin (C++) that draws a window group's tabs on the window border, reserving no space; `make all`, `make install` to `~/.local/lib/hyprland-plugins/` (`CHEATSHEET.md`) | the user builds it; Hyprland loads it |
| `tools/lib/jsonc.py`, `tools/lib/atomic.py` | the tools' config rule (`<name>.jsonc` first, comments allowed) and atomic file writes | imported by the tools |
| `tools/dev/config_migrate.py`, `config_migrate_proof.py` | a one-time move of the live configs into the current layout, and its proof on a copy | once, by hand, after a backup |

### Per module

| Name | What it is for | Who runs it |
|---|---|---|
| `tools/audio/lares-audio-diag` | what the session's audio manager is doing when a call to the sound server hangs (read only) | the audio popup |
| `tools/player/audio_diagnose.py` | what is wrong with the audio path, as one JSON line (read only) | the player's health check, when a problem is confirmed |
| `tools/player/audio_level_tap.py` | the music's level (RMS and peak, ~30 a second) from the PCM a PipeWire recorder pipes in | the player's level meter (`PlayerLevelTap`) |
| `tools/clipboard/clip.py` + `lib/` | the clipboard store's only writer: ingest a copy, keep, seal, pin, rename, import cliphist | the clipboard service; `wl-paste --watch`; `lares` once |
| `tools/notes/portal_pick.py` | opens the file-chooser portal at a folder ("Show in file manager") | notes, the launcher, the LLM |
| `tools/notifications/claim_name.sh` | stops mako if it holds the notification name (the notifications mockup's live mode) | the notifications mockup |
| `tools/notifications/shot_edit.sh` + `swappy_trash.c` | opens a screenshot in swappy so Save writes over it, and makes swappy's trash button delete the file | the OSD's and the notification's Edit |
| `tools/notifications/shot_trash.sh` | moves a screenshot to the Trash and tells the shell | the OSD's trash icon, the notification |
| `tools/notifications/reply_test.py` | sends one notification with a reply box and prints what comes back | the user, to try replies |
| `tools/notifications/notify_client.py` | a notification client: `caps`, `info`, `close`, `send` | the notifications mockup's Run page |
| `tools/osd/shot.sh` | a screenshot (`region` or `screen`) to `~/Pictures/Screenshots/`, copied (osd.jsonc `capture`), shown on the OSD | Super+Shift+S |
| `tools/osd/sysfs_pollpri.py` | prints a line whenever firmware changes the keyboard light (the Fn key) | the OSD's keyboard-light source |
| `tools/llm/mathrender.py` | LaTeX to an alpha mask the LLM transcript tints with the theme | the LLM popup |
| `tools/llm/llm_tokps.py` | a model's prompt and generation speed on this machine (the figures in the model notes) | the user, for a new model |
| `tools/system_update/replay_yay_log.sh` + `fixtures/` | plays a captured `yay -Syu` log back as if it ran, pausing at its questions | the system update's replay (the mock shell, the mockup's Run tab) |
| `tools/wiki/wiki.py` + `lib/`, `data/` | every network, text and model step of the wiki (batches, intros, judging) | the wiki service |
| `tools/wiki/check_glyphs.py` | checks that the font has every glyph `families.json` names (families and marks) | the user, after a glyph changes |
| `tools/wiki/polkit/49-wiki-ollama-restart.rules.in` | **Root.** lets the shell restart `ollama.service` without a prompt (for the wiki's GPU batch) | installed by the user (`@USER@` filled in: the file's INSTALL line) |
| `tools/wiki/jev_probe.py`, `capture_fixtures.sh` | one request to the Jev judge; a capture of the live APIs into `tools/dev/fixtures/wiki` | the user, when an API changes |
| `tools/stocks/stock_logo.py` | fetches and bakes one stock's logo | the stocks service |
| `tools/stocks/verify_cnbc_map.sh`, `capture_fixtures.sh` | checks the symbol map against CNBC; captures the live responses into `modules/stocks/data/fixtures` | the user, when an API changes |
| `tools/silicon/calibrate_overhead.sh` + `gpu_sample.py` | measures silicon's two power-overhead numbers on this laptop, unplugged (~12 min) | the user |
| `tools/silicon/make_clicks.py`, `make_glyphs.py`, `make_silkscreen.py` | silicon's click sounds, the board's printed figures, its silkscreen texture | the user, after a design change |
| `tools/silicon/capture_sysfs.sh`, `stage0_facts.py`, `make_upower_fixture.py` | read-only snapshots of the machine's power settings and a synthetic battery history, as test fixtures | the user |
| `tools/weather_accuracy/` | logs every hour what five forecast models and KMI predicted and what the station measured, and scores them (`README.md`; a user timer, `weather-accuracy.timer`) | systemd, once the user installs the timer |
| `tools/bake_logo_relief.py`, `tools/mask_from_photo.py` | turn a logo (or a mark in a photo) into the texture `LogoRelief` carves into the surface | the user, for a new logo |
| `tools/wallpapers/` | `bauhaus_wallpapers.html`, a page that draws one composition in the eva theme's light and dark palettes, and `check.js`, its checks in node | the user, in a browser |

## helpers/

| Name | What it is for | How it runs |
|---|---|---|
| `helpers/screentimed/` | the screen-time daemon (Rust): records which app has the focus, serves the screentime popup over a socket (`README.md`) | a systemd user service; `cargo build --release`, then `./install.sh` (no root) |
| `helpers/silicon_helper/` | **Root.** silicon's helper (Rust): the CPU profile, the GPU mode, the charge limit, the boot profile; a polkit action with no prompt for the user, and three units for the boot and the GPU switch | `pkexec` from the silicon service; `cargo build --release`, then `sudo ./install.sh` |
| `helpers/update-run.sh` | owns a system update run, detached from the shell, so a shell restart never kills `yay` mid-transaction | the system update popup |
| `helpers/update-attach.sh` | attaches a terminal to a running update: watch, answer, abort, status | the user, when the popup cannot |
| `helpers/sudo-askpass` | the `sudo` yay is given, so every sudo of a run asks the shell's password card, never the run's terminal | `update-run.sh` |
| `helpers/system_update_helper/` | a Rust driver that reports pacman's progress as JSON events; no module runs it | nothing |

## llm_tools/

The LLM popup's model can call these ([llm.md](llm.md)). Each runs as a job the user sees; anything risky asks first.

| Name | What it lets the model do |
|---|---|
| `llm_tools/tools.json` | the list of tools the model is offered: run a command, search files, read a file, read and write the clipboard, take a screenshot, fetch a URL, notify, write a file, calculate, search the web |
| `llm_tools/policy.json` | the rules: commands that always ask (sudo, rm, dd, reboot, systemctl stop ...), commands never run, paths never granted for writing (`~/.ssh`, `~/.gnupg`, the password store, `llm_tools` itself), hosts never fetched (localhost) |
| `llm_tools/hyprctl.json` | Hyprland: windows, workspaces, monitors; reads run freely, dispatches ask |
| `llm_tools/system.json` | facts about this machine: kernel, disks, memory, packages, updates, battery, date; all read only |
| `llm_tools/calc.py` | evaluate one arithmetic expression (a safe subset of Python) |
| `llm_tools/fetch.py` | one http(s) GET, HTML reduced to text, capped |
| `llm_tools/search.py` | one query through the SearXNG instance on this machine |
| `llm_tools/shot.py` | a screenshot (full or a region), scaled, as JSON |
| `llm_tools/write.py` | write one file atomically, after the user confirms |
| `llm_tools/askpass.py` | sudo's `SUDO_ASKPASS`: asks the shell's password card ([auth.md](auth.md)); also used by the system update |
| `llm_tools/bin/sudo` | **Root.** the model's `sudo`: always asks (never a cached credential), through the password card |

## The dev kit (`tools/dev/`)

What a change is proved with. Every runner works from anywhere (it finds the repo from its own place), never touches the running
desktop (a private copy of the config, offscreen, or a nested Hyprland), and ends in one `<NAME> RESULT PASS|FAIL` line.

| Name | What it is for |
|---|---|
| `sandbox.sh <command>` | runs a command against a private copy of the config (`SANDBOX=<dir>`), with a private runtime dir; every quickshell a test starts goes through it |
| `smoke.sh <file.qml> ...` | loads files and fails on any warning (`--all`: every mockup and harness) |
| `lock_env.sh up/run/down` + `lock_env/` | an isolated nested Hyprland (private runtime, config and bus) for what needs a compositor or the lock |
| `notifications_bus.sh <command>` | a private session bus, so nothing claims a name on the user's |
| `result_lib.sh`, `lares_runtime.py` | the one-verdict-line rule and the private runtime dirs, shared by the runners |
| `sheet_check.sh <outdir>` | THE regression check: renders the reference sheet (the mock shell and every mockup, both modes, `sheet_states.txt`) and compares it pixel for pixel with a baseline, judges the logs, runs the kept gates. `--baseline` takes the baseline first; then `SHEET_BASELINE=<outdir>/sheet tools/dev/sheet_check.sh <new>` |
| `shell_gates.sh <outdir> --tier quick` | the static checks in a few minutes (syntax, the wiring of every mockup, the promotion's dry run, qmllint, the generators' checks); `qml` and `env` tiers run the gates below |
| `shell_probe.sh`, `shell_hosted_m{1,2,3}_probe.sh`, `config_loaders_probe.sh`, `configfile_probe.sh`, `theme_sync_probe.sh`, `shader_compile_probe.sh` | the shell's gates: the real `shell.qml` in a nested Hyprland, the owners in shell-hosted mode, the config loaders, the theme switch, every shader on the real driver (each refusal named by its pack and GLSL variant; `ATTRIBUTE=<log>` re-reads an earlier run's log) |
| `lares_tool_probe.sh`, `lares_deploy_probe.sh`, `lock_supervisor_probe.sh` | `lares` in a fake world (the restart guard, preview, apply; deploy, start, the crash loop, binds, setup, cleanup-marks on copies of real configs); the lock's supervisor in a nested Hyprland |
| `silicon_service_probe.sh`, `themectl_cases.py`, `themectl_home_probe.sh`, `themectl_resolver_parity.sh` | silicon's data layer on a fake machine; themectl in a fake home and its two resolvers |
| `suspend_lab.py check / stage / ladder / sleep / report / history` (cases: `suspend_lab_cases.py`) | does the machine suspend and come back: the kernel's own rehearsals (`/sys/power/pm_test`), then a real sleep woken by the clock; one record per test under `~/.local/state/lares/suspend-lab/`. **The user runs the tests**, in a terminal (they refuse without one); an agent runs `check`, `report`, `history` and reads the records |
| `themectl_prompt_env_probe.sh`, `hidden_repaint_cases.py`, `hidden_repaint_env_probe.sh`, `curtain_repaint_env_probe.sh` | the theme switch on what is already there, nested: a printed starship prompt follows it (real kitty, starship, yazi); the hidden workspaces and tabs are shown under the curtain and repaint (the plan, the tool against the real Hyprland, the real shell with the button clicked) |
| `snapshot_cases.py`, `snapshot_rule_cases.json`, `snapshot_install_probe.sh`, `snapshot_restic_probe.sh`, `snapshot_offsite_cases.py`, `snapshot_setup_probe.sh` | system snapshots: the rule and the undo plan offline (both languages, one table), the installer on a fake root, the root tool and hook on a real restic repository, the Proton copy against a stand-in CLI, `lares setup`'s rows and printed step |
| `snapshot_rescue_probe.sh`, `snapshot_vm.sh` + `snapshot_vm/` | the rescue without a VM; the rescue and a restore in a KVM virtual machine (exclusive tier; needs KVM and the prepared work folder) |
| `su_snapshot_probe.sh`, `su_snapnull_sheet.sh`, `snapshot_ui_probe.sh`, `snapshot_engine_probe.sh` | the popup's snapshot notch, line, failure card and page; the popup with no service; the page; the engine with the page as the side popup |
| `proton_cli_try.sh` | THE USER'S, from a terminal only: what the real `proton-drive` CLI does (never in a tier) |
| `session_cases.py`, `session_hook_probe.sh`, `session_service_probe.sh`, `session_env_probe.sh` | session restore: its tables offline, the bash hook on a pty, the shell's service on a stub tool, a real session saved and restored in the nested Hyprland |
| `mockup_promote.py`, `mockup_save_defaults.py`, `mockup_profiles.py` (+ `mockup_model.py`, `mockup_qmlscan.py`, `mockup_promote_hints.json`) | what a mockup's Save and Profiles run; `mockup_promote.py dry --all --summary` previews every Save |
| `mockup_panel_test.sh <mockup>`, `mockup_wiring_check.py <mockup>`, `mockup_grab.sh <mockup> [tab]`, `mockup_promote_probe.sh` | a mockup's panel round trip, its rows against their components, a tab to PNG, the Save pipeline end to end |
| `notifications_mockup.sh`, `osd_mockup.sh`, `wiki_mockup.sh`, `auth_render.sh` (`run`, `smoke`, `grab`) | the four mockups that need a private bus or config: `run` opens one on the desktop |
| `bake_shaders.sh [--all]`, `shader_ubo_match.py`, `gooey_field_ubo.py`, `silicon_shader_gen.js [--check]` (= `board_gen/gen.js silicon`: the board toolkit's generator, `modules/common/board/README.md`) | rebuild the `.qsb` packs (per target, `qsb -p`, for a source that names `QSHADER_`; the bake fails on a refused variant), check a shader pair's uniform block, generate the gooey field's and silicon's shader blocks |
| `shader_glslang_gate.sh [<pack>...]` | every GLSL variant of every pack (100 es, 120, 150, 300 es) validated by glslang for its stage and version, offline: what NVIDIA's ES context refuses (an array constructor or an integer clamp in ES 1.00) fails here with no GPU, and every 100 es / 120 variant's uniform instance name must equal the pack's reflection (a mismatch draws with every uniform at 0); `ARM=arrayctor|intclamp|instname|all` |
| `qt_gc_attach_probe.sh` | Qt's incremental collector loses live QML helpers when a GC cycle starts inside a component's build and the root gets its parent before the cycle resumes: builds `qt_gc_attach/probe.cpp` against Qt's private headers, steps the collector by hand (fault / whole cycle / none / the cure), checks `ShellScreen.qml` carries the cure, and says when a Qt no longer has the fault; `ARM=nocure`. Run after a Qt update |
| `qml_census.sh build\|command [<pid>]\|self-test` | the QML objects of a RUNNING process whose storage was collected while they live (flags, declaration site, parent chain): a library loaded with gdb. `command` only PRINTS the sudo line for the user; `self-test` injects into its own offscreen process |
| `silicon_board_probe.sh [<out>]` (+ `qml/silicon_board_probe.qml`, `qml/board_probe_shaders/`), `egl_nvidia_shim.c` | does the real silicon board DRAW on this context, per variant (cached, uncached, forcecard, patchoff; diagnostics nolod, noao, novert, mech_*): offscreen by default; `SHIM=1` NVIDIA's OpenGL ES path on Mesa (the EGL vendor shim, a Wayland client in lock_env); `WAYLAND=1` the user's dGPU-only boot only; `ARM=oldboard|hidden` |
| `shell_joint_probe.sh [<out>]` (`SWEEP=1`), `hypr_joint_cases.js`, `shell_joint_judge.py` | the shell's joint against a real tiled window's corner in a nested Hyprland, each state shot over a black and a white background (the wallpaper's share per pixel exact): the border left and the seam, `ARM=oldoverlap|nooverlap`; the joint arithmetic's cases |
| `tray_reel_probe.sh`, `reel_ring_sheet.sh`, `reel_shell_sheet.sh`, `reel_ring_compose.py` | the reel slot's strips (T1-T11: THE REEL PASS's ground, ring and halo over a popup, its fade; ARMs noground, noreelring, noreelfade, swapblink, nowarm); `reel_ring_sheet.sh`: a mock engine's before/after cells (idle / power / tray / label / menu over a sky popup, a list popup and none, at rest and mid-merge; `BENCH=<n>` times the scene, `COLD=1` with the shader cache off); `reel_shell_sheet.sh <out> [cell ...]`: the same over the REAL shell frame's popups (mock services, `TREE=` another revision), plus films (`to-<reel>`, `open-<owner>`) and a per-frame trace of a switch (`trace-<reel>`); `reel_ring_compose.py` lays two trees side by side with the differing pixels per cell (`--crops`), or a film as a strip (`--film`) |
| `side_swipe_probe.sh`, `side_swipe_env_probe.sh`, `wheel_readers_check.py`, `wheel_record.sh` | the one wheel reader and the mouse's side buttons (docs/contracts/gestures.md): offscreen with the recorded events of a real mouse and of fingers; nested, with real notches, fingers and side buttons and the held pointer; a static check that no bare reader is left; and, for a PERSON at their desk only (LARES_SHOW), a recorder of what their own mouse sends a Qt window |
| `ddc_dim_probe.sh` | the idle dimming of external displays over DDC (`modules/idle/DdcDim.qml`) on a stub ddcutil timed like the user's monitor |
| `glyph_flourish_probe.sh`, `glyph_flourish_strip.sh`, `flourish_pool_probe.sh` | every glyph flourish's rest / end / hover / pose checks (incl. `qml/pill_flourish_probe.qml`: the audio and network pills; ARMs still, latch, fullbars, mutedwave, bothhalves, restblock, quarter; the stocks line: stocksclosedarrow, stockswrongway, stocksrestwarp, stocksmodelive); filmstrips (`SET=pills`, `PILLSCALE`); the OLED care's random pool |
| `dictation_probe_take.sh`, `stt_helper_probe.sh`, `dictation_probe_notes.sh`, `stt_policy_probe.sh` | the dictation service's take lifecycle against a stand-in helper (T1-T16: crash, GPU fallback, silence, stuck loop, the log's fields); the real `lares_stt.py` on a stand-in decoder (H1-H3); live words in the real notes editor; the text rules, the partial builder and the tidy guard |
| `bridge_cases.py`, `bridge_tool_probe.sh`, `bridge_seam.js` | the bridge's tool: the pure rules as a case table (the merge of a device across KDE Connect / adb / USB, the transport ladder, every argv, `can`, the parsers on the fixtures; ARMs storedip, nousbfirst, weakmerge); the REAL tool in a fake world under `env -i` (a private bus with `stubs/bridge/fake_kdeconnectd.py`, `fake_adb_server.py`, PATH stubs of adb / scrcpy / aft-mtp-mount / fusermount3 / systemd-run, a fake `/sys` and mount table): the watch line and a line per event, every one-shot's JSON and exit status, a job that outlives its starter, a killed wrapper reads failed, only its own stale mount cleaned, no fork at rest; and THE SEAM: the service's own parser on the tool's lines and the service's argv through the tool; ARMs nopidfd, cleanforeign, noack |
| `bridge_service_probe.sh`, `bridge_popup_probe.sh` | the bridge's service against a stub tool (not live: no Process exists; the rows keep their objects; the serial last; one closing toast per send; ARMs twotoasts, progressstays, seriallate, alwayswatch) and its popup with real clicks and wheels through the window (each scenario's screen, a tile reaches the service, the tile-to-page morph, the swipe's one reader and its role, the Escape chain, input after a turn, the body's keys, the Details page behind the device menu and a back that carries nothing, the pointer's light chasing a pointer that comes in elsewhere; ARMs tworeaders, escboth, noblock, lightjump) |
| `bridge_body_probe.sh`, `bridge_body_sheet.sh`, `bridge_flip_perf.sh` | the bridge's phone body on the real PhoneStage: it draws, the cached layer = the live body, the display's edges whole pixels with the stage off the device grid, every pose of a turn on its glass and inside the stage, a real turn lands on the back, still at rest (scales 1, 1.25, 1.5625; ARMs hidden, nosnap, nogrid, nomatrix, nocache, leftclock; `SHIM=1 LOCK_ENV=<name>` the NVIDIA ES path, ARM novert); a row of poses to look at (`POSES`, `MODE`, `SCALE`, `SKIN`, `BUSY`); what a frame costs, by grabs (a frame's own timing reads 0 offscreen) |
| `bridge_sheet.sh` | the bridge popup's states (home, Wi-Fi, a send, the pages, the details, asleep, pairing, the menu, mid-turn, the back, the top and the bottom wall) as PNGs and one contact sheet per mode, from the mockup on the mock service; judges nothing |
| `bridge_capture.sh` | THE USER'S, from a terminal only: what this phone, adb, scrcpy, aft and KDE Connect really print, into `~/.cache/lares/bridge/` (never the repo); `--wireless`, `--with-push`, `--with-mount`, `--with-usbmode` |
| `picker_probe.sh` | the emoji / alt-code / Nerd Fonts picker with stubbed `wl-copy` / `hyprctl` / `curl`: the paste and its key per window class, Shift multi-pick, Escape, the global tone, the digit jump, a Nerd pick (glyph on Enter, name on Ctrl+Enter), one fetch per font version, the failure line; runs `picker_nerd_check.py` (the cmap filter, the version parse, the real list against the installed font; its list `fixtures/glyphnames-3.5.1.json`) first; ARMs nopaste, wrongtone, nodigitjump, nameonenter, ctrlglyph, reask, refetch, nofilter, nofailline, copypastes |
| `clip_config_cases.py` | `clipboard.jsonc` in `tools/clipboard` (a temporary store, stubbed `wl-paste` / `hyprctl`): a wrong value is its default, `ignoreApps` leaves nothing; ARM recorded |
| `comment_strip_diff.py <rev>` | a comment-only change must leave the code as it was |
| `perf/shell_rest_sampler.sh`, `perf/frame_journal_report.py` | the shell's CPU at rest, thread by thread (`--trial <s>` reads the running shell, its pid from lares's state); what a day of the frame journal holds |
| `perf/frame_split.sh <outdir> <scenario...>` (+ `frame_split.py`, `frame_split_ablate.py`, `qml_profile.py`), `perf/shell_mem.sh <outdir> <variant...>` | WHERE a frame's time goes: the mock shell in the nested Hyprland with Qt's own per-frame timing (polish / sync / render, the GUI thread's ms per frame) through scenarios (`minute`, `rest:<s>`, `toast:<n>`, `osd:<n>`, `spinner:<n>`, `popup:<owner>` = open, rest and close of any owner's popup, `title`, `focus`: the window title is live there; `SHELL_JSONC_FILE` = the shell's own config, `HYPR_EXTRA` + `WINDOWS` = a compositor replica, `FS_ENV="XDG_CACHE_HOME=<dir>"` = warm caches); `PROFILE=1` adds Qt's QML profiler and a table of JS functions, bindings and handlers by self time; `ABL=<name>` runs it with one thing ablated in its sandbox copy. `shell_mem.sh`: the settled mock shell's resident memory per variant (`off:<module>`, `nothp`, `noprewarm`, `env:VAR=VALUE`); two starts of one tree differ by up to ~40 MiB, so only larger differences count |
| `perf/start_split.sh <outdir>` (`SPECS="new:warm new:cold new:off new:warm:qs new:warm:-<module>"`, `ROUNDS`), `perf/start_profile.sh`, `perf/lock_start_split.sh`, `perf/prewarm_report.py <shell.log>` | how long the shell takes to START, by phase (launch, "Launching config", the first QML line, `LARES shown`, `LARES ready`; `LARES start root= load= services=`), interleaved over cache states, a module switched off or an ablation script (`SS_PATCH`, `SS_ENV`); the QML profiler from the first line (shares only: the debugger turns the disk cache off); the same for the real lock in the nested session (stub PAM); the prewarm's `LARES prewarm` lines as a table (per entry build / block / plain / clip) |
| `perf_tour_probe.sh`, `prewarm_stall_probe.sh`, `boost_client_probe.sh`, `shell_root_probe.sh`, `file_root_names.py` | the user's tour (`tools/shell/lares-perf-tour`) run against the nested mock shell; a popup used during the warm-up does not stop it (ARM parked); the boost's client against a stub server (ARMs norate, noclose); the `file:` root is ONE type world, serves the IPC and reads its cache (ARM split); no file's own type loses to a module when loaded from `file:` (quick tier, ARM noimport) |
| `perf/field_shape_record.sh`, `perf/field_shape_replay.js`, `perf/field_shape_qv4.sh` (+ `field_shape_lib.js`, `field_shape_phases.js`, `field_shape_patch.py`, `field_shape_extract.py`, `field_shape_scenarios.txt`) | THE ENGINE'S GEOMETRY, BIT FOR BIT: the real engine's `GooeyGeometry.fieldShape()` inputs recorded from the nested mock shell (every popup, interrupted toggles, travels, secondaries, toasts, the OSD; the corpus stays outside git), replayed call by call through TWO versions of the file with every output, the state after it and the inputs compared as canonical JSON (node for speed, `field_shape_qv4.sh ... identity` in the shell's own engine; `FS_ARM=const|order|state` must fail), and timed in QV4 (`bench <passes>`, interleaved; `field_shape_phases.js` per phase). A change to GooeyGeometry.js is proved with it |
| `perf/veil_perf.sh` (+ `veil_perf.py`, `veil_gputime.c`, `veil_ablate.py`, `qml/veil_perf.qml`), `perf/veil_lock_rest.sh`, `perf/veil_pixels.sh` (+ `qml/veil_perf_pixels.qml`) | the lock veils' cost in the nested Hyprland: GPU ms per frame by GL timestamps (an LD_PRELOAD, since Qt's own GPU time reads nothing here), GUI time per tick, the first frame cold and warm, A/B inside ONE process (`--ab`: the GPU's clock moves between processes); the REAL lock at rest must draw 0 frames, every veil, with and without the shell beside it; a veil change is proved pixel for pixel over 105 jobs x both modes x two sizes against another tree (0 px; armed, it fails) |
| `screentime_live_probe.sh`, `launcher_presets_profiles.py`, `config_effective.py` | the installed screentime daemon, read only; the flourish presets as launcher profiles; what a config directory comes to, key by key |
| `qml/` (+ its `modules` link), `fixtures/`, `stubs/` | the gates' harnesses, their data, silicon's fake machine |

## How to change something here

- **A shell or lock script**: edit it, then `tools/dev/lares_tool_probe.sh` (lares, in a fake home) or
  `tools/dev/lock_supervisor_probe.sh` (the lock, in a nested Hyprland). `lares deploy` copies the committed tree.
- **themectl**: `python3 tools/dev/themectl_cases.py` and `tools/dev/themectl_home_probe.sh`.
- **system snapshots**: `python3 tools/dev/snapshot_cases.py`, `snapshot_install_probe.sh`, `snapshot_restic_probe.sh`, `snapshot_setup_probe.sh` and, for the popup, `su_snapshot_probe.sh` ([snapshots.md](snapshots.md)).
- **session restore**: `python3 tools/dev/session_cases.py`, `tools/dev/session_hook_probe.sh`, `tools/dev/session_service_probe.sh`,
  and for `restore.py` / `capture.py` `tools/dev/session_env_probe.sh` (also `MODE=half`, `MODE=locked`).
- **A Rust helper**: `cargo test --offline` in its folder, then its `install.sh`.
- **What the LLM may do**: `llm_tools/policy.json` (patterns are regular expressions), `llm_tools/tools.json`.
