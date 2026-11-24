#!/usr/bin/env bash
# shell_gates.sh -- the shell assembly's battery: every functional and render gate of the MERGED tree, in tiers, ONE AT A
# TIME, one summary line each. Written by stream V (the verification pass of wave 1); re-run at wave 2 and at the cutover.
#
#   tools/dev/shell_gates.sh <outdir> [--tier quick|qml|env|exclusive|all] [gate ...]
#   tools/dev/shell_gates.sh --list [--tier ...]       the gates (tier, name, kind, command) -- runs nothing
#   RETRY=1 ...        a red gate is run once more at once: the table says "red twice" or FLAKY (both logs' lines)
#   TIMEOUT=900 ...    seconds a gate may take by default (its whole process tree is stopped; a few gates ask for more)
#   KEEP=1 ...         keep every PNG a gate made (default: the big ones go, except the renders a gate marks %keep)
#   DRY=1 ...          print every gate's resolved command, run nothing
#   ARM=break ...      the battery's own proof: tools/dev/qml/configfile_probe.qml gets a syntax error in the gate's SANDBOX COPY and the gate must go RED
#                      (ends `SHELL_GATES ARM break: ... RED, as it must`, or NOT PROVEN)
#   tools/dev/shell_gates.sh --arms        the static checks' ARMs: one fault each in a scratch git copy (a syntax error in a runner, a duplicate noload key,
#                      a promoted value that no longer matches its mockup, a lint warning in a changed file, a mockup row of a property that is
#                      not there); each check must go RED on its own words and the unpatched copy GREEN. (`grade_selftest` is the grader's.)
#   SMOKE_SECS=5 ...   seconds `tools/dev/smoke.sh --all` gives each file (its own default is 8)
#   UNTIL=HH:MM ...    start no gate after this time of day and stop a running one when it comes (a gate cut short is `NOT RUN`,
#                      never red): for a machine that suspends at a known hour. RESUME=1 skips every gate that finished in <outdir>
#                      already (its stored line is printed again and counted), so a run goes on where it was stopped.
#   KNOWN_RED=<file>   gates that are red for a reason somebody else is fixing: tools/dev/shell_gates_known_red.txt (`gate  reason`, one
#                      per line). Such a gate that is red prints `RED (known: <reason>)` and does not fail the run; one that is
#                      green says so (take it out of the file). The final line counts them: they are never hidden.
#
# Ends in `SHELL_GATES RESULT PASS|FAIL`. <outdir>/summary.txt (and summary_<tier>.txt) has, per gate,
#     == <name> rc=<rc> <s>s :: <the gate's RESULT lines>        (a red one is followed by `   | the lines that say why`)
# and <outdir>/<tier>/<name>/run1.log is the gate's log.
#
# THE TIERS.
#   quick      node / python cases, the static checks (bash -n over every runner, the noload table, the wiring checker over
#              every mockup, the promotion's dry run = 0 writes, qmllint over every QML file changed since the assembly's
#              base), the shader checks, themectl's cases, the rest sampler's self-test. No quickshell. A few minutes.
#   qml        the gates of what the tree keeps, offscreen, each in a sandbox copy of THIS tree (the sandbox the script
#              names, deleted at the end): the hosted-mode probes, the theme sync, the two config-loader probes, the trial
#              tool's and the deploy tool's fake worlds, themectl's home and resolver parity, the mockup promotion probe, the
#              launchers of the notifications, OSD, auth and wiki mockups, one panel self-test per mockup, and
#              `tools/dev/smoke.sh --all` (the last one, the longest).
#   env        the gates that need a compositor: tools/dev/lock_env.sh's isolated, nested Hyprland (the shell probe in four
#              settings, the lock owner's load probe, the smoke of every file that holds a PanelWindow) and the noload table
#              in shards (a runner handed a QML that does not load must say so).
#   exclusive  the machine-exclusive benchmarks: the dictation bench (tools/dev/stt_bench.sh, minutes of full CPU / iGPU), and EVERY GPU
#              test (a GPU benchmark, prime-run, the dGPU): never in the quick tier, the user's rule (2026-11-19), held by quick_gpu.
#   all        quick, qml, env. (The default.)
#
# HOW A GATE RUNS (so that no gate can reach the desktop, and a timeout leaves nothing behind).
#   box   `tools/dev/sandbox.sh -u <this script's knobs> QT_QPA_PLATFORM=offscreen ... bash tools/dev/<runner>` in a transient user
#         scope (systemd-run --user --scope): a copy of the tree, a private XDG config / state / cache (the theme state is
#         SEEDED: theme_sync_probe.sh toggles the mode, which persists, and the live shell follows that file), a private
#         SCRATCH, no WAYLAND_DISPLAY and no HYPRLAND_INSTANCE_SIGNATURE (nothing reaches the real compositor), an empty
#         QT_QPA_PLATFORMTHEME (no call to the portal on the user's bus). A timeout stops the scope; so does the end of the
#         gate, which also lists and kills what it left running.
#   tree  the same, but the runner is started from the tree itself (no copy): the gates that read git (a BASE revision) or
#         build the helpers (helpers/ is not in a sandbox copy), and that sandbox themselves. The worktree is compared before
#         and after (git status): a gate that wrote in it is named in the line.
#   env   tree, plus the lock_env name the gate uses: it waits (up to 10 min) while somebody else's nested session of that
#         name is up, so two sessions never stop each other's compositor. No QT_QPA_PLATFORM: the gate runs a compositor.
#   run   a plain command (node, python) from the tree.   fn   a function of this script (a static check).
#   (`%rc` in a row: a runner that has no verdict line by design and only exits non-zero when it finds something; `%need=<ERE>`
#   (dots for blanks): the log must also match it -- the number that matters, for a runner that prints numbers; `%meta`: the log is
#   ABOUT no-result verdicts -- tools/dev/runner_noload_check.sh prints one on every ok row, as it should -- so the `no result:` rule does
#   not apply and only the last verdict line says: NOLOAD RESULT PASS.)
#   Green means: the runner exited 0 AND the LAST verdict line of its log (`... RESULT PASS|FAIL`, or the older
#   `NAME PASS|FAIL`) is a PASS AND no `no result:` line. (The exit status alone is not enough -- several old runners end in a
#   `grep` -- and the verdict alone is not either: a gate whose log must be clean exits 1 after printing PASS.) A render gate that
#   has no verdict line is green when it exited 0 and drew at least one PNG. `smoke` is green when it exited 0.
#
# WHAT IS NOT IN ANY TIER. Everything that reads the real session (tools/dev/screentime_live_probe.sh reads the screentime daemon, read only,
# and is the user's to run after the turnover), the stage-0 platform fact runners, the captures, films and benchmarks were deleted by the
# cleanup of 2026-11-02 (tag pre-cleanup has them). The pixel baseline of the cleanup itself is tools/dev/sheet_check.sh.
#
# THE BASELINE. `git archive <rev> | tar -x -C <dir>` a frozen copy of an older revision, copy this script into it, and run it
# from there: every gate then runs on that copy, and the two summaries are "red before / red after". A gate whose runner is not in
# the tree it runs from is `skip`, not red.
set -u
{   # ONE BRACE GROUP: bash parses the whole script before running a line of it, so editing this file under a live run changes nothing
cd "$(dirname "$0")/../.." || exit 2
ROOT=$(pwd)
# shellcheck source=tools/dev/result_lib.sh
. tools/dev/result_lib.sh
NAME=SHELL_GATES
LINT_BASE="${LINT_BASE:-cea42db}"              # the assembly's base: qmllint_changed lints the QML files changed since it

# ---------------------------------------------------------------------------------------------------------------------
# arguments (the hidden `--fn <function> [args]` runs one of the static checks below and exits: how a fn gate gets its scope)
OUT=""; TIER=all; LIST=0; NAMES=()
[ "${1:-}" = "--arms" ] && set -- --fn gate_arms        # the ARMs of the static checks (see gate_arms)
FNMODE=0; [ "${1:-}" = "--fn" ] && FNMODE=1
while [ $# -gt 0 ] && [ "$FNMODE" = 0 ]; do
    case "$1" in
        --tier) TIER="${2:-}"; shift 2 ;;
        --tier=*) TIER="${1#--tier=}"; shift ;;
        --list) LIST=1; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 2 ;;
        --*) echo "unknown option $1"; exit 2 ;;
        *) if [ -z "$OUT" ] && [ "$LIST" = 0 ]; then OUT="$1"; else NAMES+=("$1"); fi; shift ;;
    esac
done
case "$TIER" in quick|qml|env|exclusive|all) ;; *) echo "unknown tier '$TIER' (quick|qml|env|exclusive|all)"; exit 2 ;; esac
case "${ARM:-}" in "") ;; break) [ ${#NAMES[@]} -gt 0 ] || NAMES=(configfile); [ "$TIER" = all ] && TIER=qml ;; *) echo "unknown ARM=${ARM} (break)"; exit 2 ;; esac
TIMEOUT="${TIMEOUT:-900}"
RETRY="${RETRY:-0}"
DRY="${DRY:-0}"
KNOWN_RED="${KNOWN_RED:-$ROOT/tools/dev/shell_gates_known_red.txt}"
SMOKE_SECS="${SMOKE_SECS:-5}"
UNTIL="${UNTIL:-}"; UNTIL_EPOCH=0
[ -n "$UNTIL" ] && { UNTIL_EPOCH=$(date -d "$UNTIL" +%s 2> /dev/null) || { echo "bad UNTIL=$UNTIL (HH:MM)"; exit 2; }; }
RESUME="${RESUME:-0}"
if [ "$LIST" = 0 ] && [ "$FNMODE" = 0 ]; then
    [ -n "$OUT" ] || { sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 2; }
    mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
fi
SB="/tmp/lares-sandbox-shellgates-$$"       # the sandboxes this run names (deleted at the end, and only these): $SB for the box gates,
SBT="$SB-tree"                           # $SBT for the gates that sandbox themselves and are told where

# ---------------------------------------------------------------------------------------------------------------------
# the tables.   tier  name  kind  [%tmo=S] [%render] [%smoke] [%keep] [%lockenv=a,b] [NAME=VALUE ...] [UNSET=NAME ...] command words
# (@OUT = the gate's own output directory). The words are split on blanks: no quoting; a `~` inside a NAME=VALUE is a blank in the value.
TABLE_QUICK="
quick  grade_selftest  fn   gate_selftest_grade
quick  bash_syntax     fn   gate_bash_syntax
quick  noload_table    fn   gate_noload_table
quick  wiring_all      fn   gate_wiring_all
quick  promote_dry     fn   gate_promote_dry
quick  qmllint_changed fn   gate_qmllint_changed
quick  js_shell_layout run  node tools/dev/shell_layout_cases.js
quick  lock_boot_rule  run  bash tools/dev/lock_boot_rule_cases.sh
quick  lock_boot_rule_arms run ARM=all bash tools/dev/lock_boot_rule_cases.sh
quick  cursor_overlay  run  python3 -B tools/dev/cursor_overlay_check.py
quick  cursor_overlay_arms run ARM=noreset python3 -B tools/dev/cursor_overlay_check.py
quick  cursor_window_arms run ARM=nowindow python3 -B tools/dev/cursor_overlay_check.py
quick  wheel_readers   run  python3 -B tools/dev/wheel_readers_check.py
quick  wheel_readers_arms run ARM=reader python3 -B tools/dev/wheel_readers_check.py
quick  shader_ubo      run  python3 -B tools/dev/shader_ubo_match.py
quick  shader_glslang  run  bash tools/dev/shader_glslang_gate.sh
quick  shader_glslang_arms run ARM=all bash tools/dev/shader_glslang_gate.sh
quick  qt_gc_attach    run  bash tools/dev/qt_gc_attach_probe.sh
quick  promote_cases   run  python3 -B tools/dev/mockup_promote_cases.py
quick  qmlscan_cases   run  python3 -B tools/dev/mockup_qmlscan_cases.py
quick  runner_rows     fn   gate_runner_rows
quick  row_inputs      fn   gate_row_inputs
quick  tree_launch     fn   gate_tree_launch
quick  desktop_launch  fn   gate_desktop_launch
quick  quick_gpu       fn   gate_quick_gpu
quick  platform_noise  fn   gate_platform_noise
quick  smoke_filter    fn   gate_smoke_filter
quick  themectl_cases   run  python3 -B tools/dev/themectl_cases.py
quick  hidden_repaint_cases run python3 -B tools/dev/hidden_repaint_cases.py
quick  hidden_repaint_cases_arms run ARM=all python3 -B tools/dev/hidden_repaint_cases.py
quick  session_cases    run  python3 -B tools/dev/session_cases.py
quick  session_cases_arms run ARM=all python3 -B tools/dev/session_cases.py
quick  session_hook     run  bash tools/dev/session_hook_probe.sh
quick  session_hook_arms run ARM=all bash tools/dev/session_hook_probe.sh
quick  lares_watchdog   run  bash tools/dev/lares_watchdog_probe.sh
quick  lares_init       run  python3 -B tools/dev/lares_init_cases.py
quick  lares_init_arms  run  ARM=all python3 -B tools/dev/lares_init_cases.py
quick  suspend_lab      run  python3 -B tools/dev/suspend_lab_cases.py
quick  suspend_lab_arms run  ARM=all python3 -B tools/dev/suspend_lab_cases.py
quick  shell_remap_cases run node tools/dev/shell_remap_cases.js
quick  config_paths    run  python3 -B tools/dev/config_paths_check.py
quick  config_paths_arm run  env ARM=old python3 -B tools/dev/config_paths_check.py
quick  file_root_names      run  python3 -B tools/dev/file_root_names.py
quick  file_root_names_arm  run  env ARM=noimport python3 -B tools/dev/file_root_names.py
quick  config_spec     run  node tools/dev/config_spec_check.js
quick  config_spec_arms run env ARM=all node tools/dev/config_spec_check.js
quick  clip_config     run  python3 -B tools/dev/clip_config_cases.py
quick  themectl_bag     run  python3 -B tools/dev/themectl_bag_parity.py
quick  themectl_yazi    run  python3 -B tools/dev/themectl_yazi_probe.py
quick  lares_sweep        run  tools/dev/lares_sweep_probe.sh
quick  llm_voice_cases run  node tools/dev/llm_voice_cases.js
quick  dictation_sources run  python3 tools/dev/dictation_probe_sources.py
quick  rest_sampler    run  bash tools/dev/perf/shell_rest_sampler_selftest.sh
quick  noload_shards   fn   gate_noload_shards
quick  silicon_shader_gen run node tools/dev/silicon_shader_gen.js --check
quick  aerial_model     run  node tools/dev/aerial_model_cases.js
quick  aerial_shader_gen run node tools/dev/board_gen/gen.js aerial --check
quick  aerial_holo_cases run node tools/dev/aerial_holo_cases.js
quick  aerial_silk      run  python3 -B tools/aerial/make_silk.py --check
quick  aerial_facts     run  node tools/dev/aerial_facts_cases.js
quick  aerial_clearance run node tools/dev/aerial_clearance_cases.js
quick  aerial_rig_install run bash tools/dev/aerial_rig_install_probe.sh
quick  aerial_rig_dry   run bash tools/dev/aerial_rig_probe.sh --selftest
quick  weather_aq_axis  run  bash tools/dev/weather_aq_axis_probe.sh
quick  wiki_potd_title  run  python3 -B tools/dev/wiki_potd_title_cases.py
quick  wiki_key         run  python3 -B tools/dev/wiki_key_cases.py
quick  wiki_key_arms    run  env ARM=all python3 -B tools/dev/wiki_key_cases.py
quick  privacy          run  python3 -B tools/publish/privacy_check.py
quick  privacy_cases    run  python3 -B tools/dev/privacy_check_cases.py
quick  privacy_arms     run  env ARM=all python3 -B tools/dev/privacy_check_cases.py
quick  publish_cases    run  python3 -B tools/dev/publish_cases.py
quick  publish_arms     run  env ARM=all python3 -B tools/dev/publish_cases.py
quick  bar_hues         run  bash tools/dev/bar_hues_table.sh
quick  dst_audit        run  node tools/dev/dst_audit_cases.js
quick  themectl_programs run  python3 -B tools/dev/themectl_programs_probe.py
quick  flourish_parts   run  python3 -B tools/dev/flourish_parts.py --check
quick  reel_outlines    run  python3 -B tools/dev/reel_glyph_outlines.py --check
quick  weather_ink_parts run python3 -B tools/dev/weather_ink_parts.py --check
quick  hypr_joint_cases run  node tools/dev/hypr_joint_cases.js
quick  bridge_cases     run  python3 -B tools/dev/bridge_cases.py
quick  bridge_cases_arms run ARM=all python3 -B tools/dev/bridge_cases.py
quick  panorama_cases   run  node tools/dev/panorama_cases.js
quick  panorama_cases_arms run node tools/dev/panorama_cases.js --arms
quick  panorama_lua     run  lua tools/dev/panorama_cases.lua
quick  panorama_lua_arms run lua tools/dev/panorama_cases.lua --arms
quick  panorama_layout  run  node tools/dev/panorama_layout_cases.js
quick  panorama_layout_arms run node tools/dev/panorama_layout_cases.js --arms
quick  panorama_import  run  bash tools/dev/panorama_import_probe.sh
quick  panorama_ddc_parse run node tools/dev/panorama_ddc_parse_cases.js
quick  osd_pointer      run  node tools/dev/osd_pointer_cases.js
quick  cast_parse       run  node tools/dev/cast_parse_cases.js
quick  cast_parse_arms  run  node tools/dev/cast_parse_cases.js --arms
quick  bridge_cast_cases run python3 -B tools/dev/bridge_cast_cases.py
quick  launcher_answers run  bash tools/dev/launcher_answers_probe.sh
quick  airplay_setup    run  bash tools/dev/airplay_setup_probe.sh
quick  snapshot_setup   run  bash tools/dev/snapshot_setup_probe.sh
quick  snapshot_setup_arms run ARM=all bash tools/dev/snapshot_setup_probe.sh
quick  snapshot_cases   run  python3 -B tools/dev/snapshot_cases.py
quick  snapshot_cases_arms run %tmo=900 ARM=all python3 -B tools/dev/snapshot_cases.py
quick  snapshot_install run  %tmo=600 bash tools/dev/snapshot_install_probe.sh
quick  snapshot_install_arms run %tmo=1200 ARM=all bash tools/dev/snapshot_install_probe.sh
quick  snapshot_restic  run  %tmo=900 bash tools/dev/snapshot_restic_probe.sh
quick  snapshot_offsite_cases run %tmo=600 python3 -B tools/dev/snapshot_offsite_cases.py
quick  snapshot_rescue  run  %tmo=900 bash tools/dev/snapshot_rescue_probe.sh
quick  silicon_helper_tests run %tmo=900 bash tools/dev/silicon_helper_tests.sh
"

# The qml tier. The mockup panels (one self-test per mockup) are generated: gen_panels.
TABLE_QML="
qml  theme_sync         box   theme_sync_probe.sh @OUT
qml  shell_hosted_m1    box   shell_hosted_m1_probe.sh
qml  shell_modules      box   %tmo=600 shell_modules_probe.sh
qml  stream_start       tree  %tmo=300 stream_start_probe.sh
qml  shell_modules_arms box   %tmo=1800 ARM=all shell_modules_probe.sh
qml  osd_mockup         box   osd_mockup.sh
qml  notifications_mockup box notifications_mockup.sh
qml  auth_render        box   auth_render.sh
qml  shell_hosted_m2    box   shell_hosted_m2_probe.sh
qml  notif_live         box   notif_live_probe.sh
qml  notif_live_arms    box   %tmo=900 ARM=all notif_live_probe.sh
qml  usb_notifier       tree  %tmo=300 usb_notifier_probe.sh
qml  usb_notifier_arms  tree  %tmo=900 ARM=all usb_notifier_probe.sh
qml  stock_notif        box   stock_notif_probe.sh
qml  stock_notif_arms   box   %tmo=900 ARM=all stock_notif_probe.sh
qml  shell_hosted_m3    box   shell_hosted_m3_probe.sh
qml  wiki_mockup        box   wiki_mockup.sh
qml  wiki_veil          box   %tmo=600 wiki_veil_probe.sh
qml  wiki_veil_arms     box   %tmo=2400 ARM=all wiki_veil_probe.sh
qml  wiki_veil_sheet    box   wiki_veil_sheet.sh @OUT
qml  configfile         box   configfile_probe.sh
qml  boost_client       box   boost_client_probe.sh
qml  config_loaders     box   config_loaders_probe.sh
qml  config_watch       box   config_watch_probe.sh
qml  config_watch_arms  box   %tmo=900 ARM=all config_watch_probe.sh
qml  bar_clicks         box   bar_clicks_probe.sh
qml  bar_clicks_arms    box   %tmo=600 ARM=all bar_clicks_probe.sh
qml  shell_options      box   %tmo=300 shell_options_probe.sh
qml  shell_options_arms box   %tmo=900 ARM=all shell_options_probe.sh
qml  lares_tool      box   %tmo=1500 lares_tool_probe.sh
qml  lares_deploy    box   %tmo=900 lares_deploy_probe.sh
qml  mockup_promote_probe tree %tmo=1800 mockup_promote_probe.sh
qml  shader_compile     tree  shader_compile_probe.sh
qml  silicon_service    tree  %tmo=1800 silicon_service_probe.sh
qml  themectl_home      box   themectl_home_probe.sh
qml  themectl_parity    box   themectl_resolver_parity.sh
qml  smoke_all          fn    %tmo=5400 SMOKE_SECS=@SMOKE_SECS gate_smoke_all
qml  su_reopen          tree  su_reopen_probe.sh
qml  su_url_close       tree  su_url_close_probe.sh
qml  favorites_move     tree  favorites_move_probe.sh
qml  favorites_move_arms tree ARM=nomigrate favorites_move_probe.sh
qml  side_swipe         tree  %tmo=200 side_swipe_probe.sh
qml  side_swipe_arms    tree  %tmo=900 ARM=all side_swipe_probe.sh
qml  idle_mode          box   idle_mode_probe.sh
qml  ddc_dim            tree  %tmo=300 ddc_dim_probe.sh
qml  sleep_dim          box   sleep_dim_probe.sh
qml  balls_slider       tree  balls_probe.sh slider
qml  balls_popup        tree  balls_probe.sh popup
qml  balls_rail_popup   tree  BALLS_SECTION=sinks balls_probe.sh popup
qml  balls_rail         tree  balls_probe.sh rail
qml  balls_menu         tree  balls_probe.sh menu
qml  stocks_header      tree  stocks_header_probe.sh
qml  osd_layout         tree  osd_layout_probe.sh
qml  silicon_mux_notice tree  %tmo=300 silicon_mux_notice_probe.sh
qml  battery_notifier   tree  %tmo=120 battery_notifier_probe.sh
qml  silicon_mux_watcher tree %tmo=300 silicon_mux_watcher_probe.sh
qml  session_service    tree  %tmo=300 session_service_probe.sh
qml  session_service_arms tree %tmo=900 ARM=all session_service_probe.sh
qml  presets_popup      tree  %tmo=200 presets_popup_probe.sh
qml  session_toast    tree  %tmo=400 session_toast_probe.sh
qml  session_toast_arms tree %tmo=900 ARM=all session_toast_probe.sh
qml  silicon_glyph      tree  %tmo=300 silicon_glyph_probe.sh
qml  tray_reel          box   tray_reel_probe.sh
qml  gooey_overshoot    tree  %tmo=900 gooey_overshoot_poses.sh @OUT
qml  detail_scale       tree  %tmo=900 detail_scale_probe.sh @OUT
qml  oled_shift         box   oled_shift_probe.sh
qml  audio_levels       box   audio_levels_probe.sh
qml  audio_tools        box   audio_tools_probe.sh
qml  bar_ink            box   bar_ink_probe.sh
qml  toast_drain        box   toast_drain_probe.sh
qml  toast_drain_truth  box   MODE=truth toast_drain_probe.sh
qml  toast_handover     box   toast_handover_probe.sh
qml  llm_voice_arms     run   %tmo=120 node tools/dev/llm_voice_cases.js --arms
qml  llm_voice          box   %tmo=300 llm_voice_probe.sh
qml  toast_routes       box   %tmo=600 toast_routes_probe.sh
qml  toast_routes_arms  box   %tmo=1500 ARM=all toast_routes_probe.sh
qml  themectl_bag_arms  run   %tmo=600 env ARM=all python3 -B tools/dev/themectl_bag_parity.py
qml  themectl_yazi_arms run   %tmo=900 env ARM=all python3 -B tools/dev/themectl_yazi_probe.py
qml  dictation_caption  run   %tmo=600 bash tools/dev/dictation_probe_caption.sh @OUT/caption_sheet.png
qml  dictation_take     run   %tmo=300 bash tools/dev/dictation_probe_take.sh
qml  stt_helper         run   %tmo=300 bash tools/dev/stt_helper_probe.sh
qml  aerial_helper      run   %tmo=300 bash tools/dev/aerial_helper_probe.sh
qml  aerial_service     box   %tmo=600 aerial_service_probe.sh
qml  aerial_scene       box   %tmo=900 aerial_scene_probe.sh
qml  aerial_integration box   %tmo=600 aerial_integration_probe.sh
qml  aerial_globe       box   %tmo=900 aerial_globe_probe.sh
qml  aerial_holo        box   %tmo=900 aerial_holo_probe.sh
qml  aerial_qr          box   %tmo=600 aerial_qr_probe.sh
qml  aerial_panels      box   %tmo=600 aerial_panels_probe.sh
qml  aerial_panels_arms box   %tmo=1800 ARM=all aerial_panels_probe.sh
qml  llm_picker_empty   box   %tmo=300 llm_picker_empty_probe.sh
qml  llm_picker_empty_arms box %tmo=900 ARM=all llm_picker_empty_probe.sh
qml  player_library_empty box  %tmo=300 player_library_empty_probe.sh
qml  player_library_empty_arms box %tmo=900 ARM=all player_library_empty_probe.sh
qml  su_check_failed    box   %tmo=300 su_check_failed_probe.sh
qml  su_check_failed_arms box  %tmo=900 ARM=all su_check_failed_probe.sh
qml  su_snapshot        box   %tmo=600 su_snapshot_probe.sh
qml  su_snapshot_arms   box   %tmo=1800 ARM=all su_snapshot_probe.sh
qml  snapshot_ui        box   %tmo=600 snapshot_ui_probe.sh
qml  snapshot_ui_arms   box   %tmo=1800 ARM=all snapshot_ui_probe.sh
qml  snapshot_engine    tree  %tmo=900 snapshot_engine_probe.sh
qml  snapshot_engine_arms tree %tmo=2400 ARM=all snapshot_engine_probe.sh
qml  su_snapnull        tree  %tmo=900 su_snapnull_sheet.sh --vs-rev 5240ca80
qml  snapshot_restic_arms run %tmo=2400 ARM=all bash tools/dev/snapshot_restic_probe.sh
qml  aerial_helper_dead box   %tmo=300 aerial_helper_dead_probe.sh
qml  aerial_helper_dead_arms box %tmo=900 ARM=all aerial_helper_dead_probe.sh
qml  aerial_life        box   %tmo=900 aerial_life_probe.sh
qml  aerial_r3_label    box   %tmo=900 WHAT=probe aerial_r3_label.sh @OUT
qml  aerial_tunnel      box   %tmo=600 aerial_tunnel_probe.sh @OUT
qml  dictation_notes    run   %tmo=300 bash tools/dev/dictation_probe_notes.sh
qml  bar_glyphs_sheet   box   %tmo=900 BEFORE=none THEMES=eva MODES=light bar_glyphs_sheet.sh @OUT
qml  dst_audit_arms     run   %tmo=600 node tools/dev/dst_audit_cases.js --arms
qml  notes_editor       tree  %tmo=600 notes_editor_probe.sh
qml  workspaces_swipe   tree  %tmo=300 workspaces_swipe_probe.sh
qml  viewfinder_open    tree  %tmo=300 viewfinder_open_probe.sh
qml  tray_pocket        tree  %tmo=900 tray_pocket_probe.sh @OUT
qml  picture_probe      box   picture_probe.sh
qml  flourish_pool      box   flourish_pool_probe.sh
qml  weather_ink        box   weather_ink_probe.sh @OUT
qml  weather_offline    box   %tmo=300 weather_offline_probe.sh
qml  weather_offline_arms box %tmo=600 ARM=all weather_offline_probe.sh
qml  calendar_failed    box   %tmo=300 calendar_failed_probe.sh
qml  calendar_failed_arms box %tmo=900 ARM=all calendar_failed_probe.sh
qml  osd_hide           tree  %tmo=600 osd_hide_probe.sh
qml  osd_lockkeys_card  box   osd_lockkeys_card_probe.sh
qml  osd_lockkeys_card_arms box %tmo=600 ARM=all osd_lockkeys_card_probe.sh
qml  osd_ddc            tree  %tmo=300 osd_ddc_probe.sh
qml  fade_edges         tree  %tmo=2400 fade_edges_probe.sh @OUT
qml  stocks_note        tree  stocks_note_probe.sh
qml  stocks_note_arms   tree  %tmo=900 ARM=all stocks_note_probe.sh
qml  lockveil_paper     box   %tmo=1800 SWEEP_EVERY=12 lockveil_paper_check.sh
qml  lock_paper_shell   tree  %tmo=300 lock_env/probes/paper_shell_probe.sh @OUT
qml  lock_dials_shell   tree  %tmo=600 lock_env/probes/dials_shell_probe.sh @OUT
qml  themectl_accent  run  tools/dev/notifications_bus.sh python3 -B tools/dev/themectl_accent_probe.py
qml  themectl_libadwaita  run  tools/dev/notifications_bus.sh python3 -B tools/dev/themectl_libadwaita_probe.py
qml  gooey_aura         tree  %tmo=900 gooey_aura_probe.sh @OUT
qml  gooey_seam         tree  %tmo=600 gooey_seam_shadow_probe.sh
qml  float_probe        tree  float_probe.sh
qml  glyph_flourish     box   glyph_flourish_probe.sh
qml  glyph_flourish_strip box %tmo=900 WHAT=strip MODES=light glyph_flourish_strip.sh @OUT
qml  picker             box   picker_probe.sh
qml  silicon_board      box   %tmo=900 silicon_board_probe.sh @OUT
qml  reel_auto          box   reel_auto_probe.sh
qml  idle_auto_causes   box   idle_auto_causes_probe.sh
qml  idle_floor         tree  idle_floor_probe.sh
qml  panel_backlight    tree  panel_backlight_probe.sh
qml  break_model        tree  break_model_probe.sh
qml  bt_battery         box   bt_battery_probe.sh
qml  bt_battery_motion  box   bt_battery_motion_probe.sh
qml  osd_pill_open      box   osd_pill_open_probe.sh
qml  launcher_answers_ui box  launcher_answers_ui_probe.sh
qml  airplay            box   airplay_probe.sh
qml  wiki_ask           box   wiki_ask_probe.sh
qml  wiki_empty         box   %tmo=300 wiki_empty_probe.sh
qml  wiki_empty_arms    box   %tmo=900 ARM=all wiki_empty_probe.sh
qml  audio_glyph_toggle box   audio_glyph_toggle_probe.sh
qml  tray_label_edges   box   tray_label_edges.sh
qml  stt_policy         run   bash tools/dev/stt_policy_probe.sh
qml  reel_strip         box   %tmo=600 reel_flourish_strip.sh @OUT
qml  bridge_tool        run   %tmo=600 bash tools/dev/bridge_tool_probe.sh
qml  bridge_decor       run   %tmo=300 python3 -B tools/bridge/make_decor.py --check
qml  bridge_service     box   bridge_service_probe.sh
qml  bridge_popup       box   bridge_popup_probe.sh
qml  bridge_cast        box   %tmo=600 bridge_cast_probe.sh
qml  bridge_resize      box   %tmo=300 bridge_resize_probe.sh
qml  panorama_ui        tree  %tmo=900 panorama_ui_probe.sh
qml  panorama_castglyph tree  %tmo=300 panorama_castglyph_probe.sh
qml  panorama_tabs      tree  %tmo=300 panorama_tabs_probe.sh
qml  cast_service       tree  %tmo=300 cast_service_probe.sh
qml  cast_tool          tree  %tmo=600 cast_tool_probe.sh
qml  panorama_service   tree  %tmo=300 panorama_service_probe.sh
qml  panorama_common    tree  %tmo=900 panorama_common_probe.sh
qml  panorama_enginelink tree %tmo=300 panorama_enginelink_probe.sh
qml  bridge_body        box   %tmo=600 bridge_body_probe.sh @OUT
"

TABLE_ENV="
env  shell_probe        env   %tmo=1500 %lockenv=shp0 shell_probe.sh
env  shell_root         env   %tmo=900 %lockenv=strp shell_root_probe.sh
env  perf_tour          env   %tmo=600 %lockenv=ptp LOCK_ENV=ptp perf_tour_probe.sh
env  prewarm_stall      env   %tmo=600 %lockenv=enps prewarm_stall_probe.sh
env  visible_ink        env   %tmo=900 %lockenv=ikvi visible_ink_probe.sh
env  aerial_keys        env   %tmo=900 %lockenv=aerkeys LOCK_ENV=aerkeys aerial_keys_env_probe.sh
env  aerial_keys_arms   env   %tmo=2400 %lockenv=akoldre ARM=all aerial_keys_env_probe.sh
env  shell_probe_scale  env   %tmo=1500 %lockenv=shps SCALE=1.25 HYPR_SCALE=1.5 SCALE_OUT2=1.75 shell_probe.sh
env  idle_hold          env   %tmo=900 %lockenv=idlehold idle_hold_env_probe.sh
env  idle_hold_arms     env   %tmo=2400 %lockenv=idlehold ARM=all idle_hold_env_probe.sh
env  lock_targets       env   %tmo=600 %lockenv=r2b_tg lock_env/probes/b_targets_probe.sh
env  osd_layout_live    env   %tmo=600 %lockenv=osdlayout LIVE=1 osd_layout_probe.sh
env  llm_voice_env      env   %tmo=900 %lockenv=llmvenv llm_voice_env_probe.sh
env  session_env        env   %tmo=600 %lockenv=sre0 LOCK_ENV=sre0 session_env_probe.sh
env  session_env_half   env   %tmo=600 %lockenv=sre0 LOCK_ENV=sre0 MODE=half session_env_probe.sh
env  session_env_locked env   %tmo=600 %lockenv=sre0 LOCK_ENV=sre0 MODE=locked session_env_probe.sh
env  session_env_arms   env   %tmo=1800 %lockenv=sre0 LOCK_ENV=sre0 ARM=all session_env_probe.sh
env  shell_joint        env   %tmo=1500 %lockenv=sjoint LOCK_ENV=sjoint shell_joint_probe.sh @OUT
env  silicon_board_shim env   %tmo=1200 %lockenv=sbshim SHIM=1 LOCK_ENV=sbshim silicon_board_probe.sh @OUT
env  bridge_body_shim   env   %tmo=900 %lockenv=brbody SHIM=1 LOCK_ENV=brbody bridge_body_probe.sh @OUT
env  bridge_look_env    env   %tmo=600 %lockenv=brlook LOCK_ENV=brlook bridge_look_env_probe.sh
env  bridge_look_arms   env   %tmo=900 %lockenv=brlook LOCK_ENV=brlook ARM=all bridge_look_env_probe.sh
env  lock_boot_film     env   %tmo=1200 %lockenv=pdlkboot lock_boot_film.sh
env  group_tabs        env   %tmo=900 %lockenv=nightgroup ../hypr-group-tabs/test.sh
env  group_tabs_arm_force   env  %tmo=900 %lockenv=gtarmf ARM=force ../hypr-group-tabs/test.sh
env  group_tabs_arm_release env  %tmo=900 %lockenv=gtarmr ARM=release ../hypr-group-tabs/test.sh
env  bar_boot_film      env   %tmo=900 %lockenv=barboot bar_boot_film.sh
env  bar_boot_film_late env   %tmo=900 %lockenv=bblate BB_ENV=bblate LATE_LOCK=1 bar_boot_film.sh
env  shell_lockwait     env   %tmo=600 %lockenv=lockwait shell_lockwait_probe.sh
env  shell_lockwait_arms env  %tmo=600 %lockenv=lockwait ARM=all shell_lockwait_probe.sh
env  themectl_programs_hypr run %tmo=900 %lockenv=thprog HYPR=1 LOCK_ENV=thprog python3 -B tools/dev/themectl_programs_probe.py
env  themectl_hyprpaper      env %tmo=600 %lockenv=thpaper themectl_hyprpaper_env_probe.sh
env  themectl_hyprpaper_arms env %tmo=900 %lockenv=thpaper ARM=all themectl_hyprpaper_env_probe.sh
env  themectl_prompt         env %tmo=600 %lockenv=thprompt themectl_prompt_env_probe.sh
env  themectl_prompt_arms    env %tmo=900 %lockenv=thprompt ARM=all themectl_prompt_env_probe.sh
env  hidden_repaint          env %tmo=600 %lockenv=hidrep hidden_repaint_env_probe.sh
env  hidden_repaint_stop     env %tmo=600 %lockenv=hidrep HR_MODE=interrupt hidden_repaint_env_probe.sh
env  hidden_repaint_debug    env %tmo=600 %lockenv=hidrep HR_MODE=debug hidden_repaint_env_probe.sh
env  hidden_repaint_vscode   env %tmo=600 %lockenv=hidrep HR_MODE=vscode hidden_repaint_env_probe.sh
env  hidden_repaint_arms     env %tmo=3000 %lockenv=hidrep ARM=all hidden_repaint_env_probe.sh
env  presets_lockwatch       env %tmo=300 %lockenv=presetlw presets_lockwatch_env_probe.sh
env  presets_lockwatch_arms  env %tmo=900 %lockenv=presetlw ARM=all presets_lockwatch_env_probe.sh
env  curtain_repaint         env %tmo=900 %lockenv=currep curtain_repaint_env_probe.sh
env  curtain_repaint_debug   env %tmo=900 %lockenv=currep CR_MODE=debug curtain_repaint_env_probe.sh
env  curtain_repaint_arms    env %tmo=3000 %lockenv=crnorepa,crnohold,crtrigge,crlate ARM=all curtain_repaint_env_probe.sh
env  themectl_evince         env %tmo=600 %lockenv=thevince themectl_evince_env_probe.sh
env  themectl_evince_arms    env %tmo=1200 %lockenv=thevince ARM=all themectl_evince_env_probe.sh
env  reel_film          env   %tmo=900 %lockenv=a1reelfilm reel_film.sh @OUT
env  dictation          env   %tmo=900 %lockenv=sttproto dictation_probe.sh
env  dictation_shell    env   %tmo=900 %lockenv=dictshell dictation_probe_shell.sh
env  sleep_film         env   %tmo=900 %lockenv=slpfilm sleep_lockenv_film.sh @OUT
env  sleep_film_emptypic env  %tmo=900 %lockenv=slpfilm ARM=emptypic sleep_lockenv_film.sh @OUT
env  sleep_film_emptys0 env   %tmo=900 %lockenv=slpfilm ARM=emptys0 sleep_lockenv_film.sh @OUT
env  osd_hide_live      env   %tmo=600 %lockenv=osdhide LIVE=1 osd_hide_probe.sh
env  osd_lockkeys       env   %tmo=600 %lockenv=osdlockkeys osd_lockkeys_probe.sh
env  side_swipe_env     env   %tmo=300 %lockenv=sideswipe side_swipe_env_probe.sh
env  fade_edges_env     env   %tmo=2400 %lockenv=fadeedge ENV=1 fade_edges_probe.sh @OUT
env  smoke_panelwindow  fn    %tmo=900 %lockenv=vspw SMOKE_SECS=@SMOKE_SECS gate_smoke_panelwindow
env  noload_table_1     fn    %meta %tmo=1800 gate_noload_rows 1 8
env  noload_table_2     fn    %meta %tmo=1800 gate_noload_rows 2 8
env  noload_table_3     fn    %meta %tmo=1800 gate_noload_rows 3 8
env  noload_table_4     fn    %meta %tmo=1800 gate_noload_rows 4 8
env  noload_table_5     fn    %meta %tmo=1800 gate_noload_rows 5 8
env  noload_table_6     fn    %meta %tmo=1800 gate_noload_rows 6 8
env  noload_table_7     fn    %meta %tmo=1800 gate_noload_rows 7 8
env  noload_table_8     fn    %meta %tmo=1800 gate_noload_rows 8 8
env    shell_probe_ratio    env   %tmo=1500 %lockenv=shpr BAR_RATIO=1.25 POPUP_RATIO=1.5 shell_probe.sh
env    shell_probe_hot      env   %tmo=900 %lockenv=shph SHP_WATCH=1 ONLY=p13 shell_probe.sh
env    panorama_facts       env   %tmo=600 %lockenv=pnfx panorama_hypr_facts.sh
env    panorama_engine      env   %tmo=900 %lockenv=pe1 panorama_engine_env_probe.sh
env    panorama_shell       env   %tmo=900 %lockenv=pnsh panorama_shell_env_probe.sh
env    snapshot_offsite_arms run %tmo=1800 ARM=all python3 -B tools/dev/snapshot_offsite_cases.py
"

# The exclusive tier: the orchestrator runs these alone, on a quiet machine, with --tier exclusive.
TABLE_EXCL="
exclusive stt_bench    run   %tmo=7200 bash tools/dev/stt_bench.sh @OUT
exclusive bridge_flip_perf box %tmo=600 bridge_flip_perf.sh @OUT
exclusive wiki_veil_cost env  %tmo=1800 %lockenv=wkcost wiki_veil_cost.sh
exclusive silicon_mux_score run bash tools/dev/silicon_mux_score_probe.sh
exclusive snapshot_vm  run   %tmo=7200 bash tools/dev/snapshot_vm.sh
"

# The runners of tools/dev/runner_noload_check.sh's table that are deliberately in NO tier: `pattern  reason`, one per line, the pattern a shell glob
# on the runner's name (or its path under tools/dev/). The noload table is the one list every stream adds a runner to, so it is the list that cannot be
# forgotten: gate_runner_rows fails on a runner that has neither a row (here) nor an entry below. An entry needs
# its reason and must still match a runner. (Empty since the cleanup: every runner of the trimmed noload table has a row.)
ROWLESS="
"

# ---------------------------------------------------------------------------------------------------------------------
# the static checks (fn gates). Each prints `<NAME> RESULT PASS|FAIL (...)` and returns 0 on a pass.
gate_bash_syntax() {
    local bad=0 n=0 f
    for f in tools/dev/*.sh tools/dev/perf/*.sh tools/dev/lock_env/*.sh tools/system_update/*.sh tools/shell/lares tools/shell/lares-lib.sh tools/shell/lares-supervise; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        bash -n "$f" 2> /tmp/lares-sg-bn.$$ || { echo "SYNTAX $f: $(head -2 /tmp/lares-sg-bn.$$)"; bad=$((bad + 1)); }
    done
    rm -f /tmp/lares-sg-bn.$$
    local py
    py=$(python3 -B - tools/*/*.py <<'PY' 2>&1
import ast, sys
bad = 0
for f in sys.argv[1:]:
    try:
        ast.parse(open(f, encoding="utf-8").read(), f)
    except SyntaxError as e:
        print("SYNTAX %s: %s" % (f, e)); bad += 1
print("PYFILES %d BAD %d" % (len(sys.argv) - 1, bad))
sys.exit(1 if bad else 0)
PY
    ) || bad=$((bad + 1))
    echo "$py"
    [ "$bad" = 0 ] && { echo "BASH_SYNTAX RESULT PASS ($n shell scripts + python files parse)"; return 0; }
    echo "BASH_SYNTAX RESULT FAIL ($bad)"; return 1
}

# The noload table was union-merged by every stream: the keys must be unique, each row 5 columns, each runner and QML must exist.
gate_noload_table() {
    python3 -B - tools/dev/runner_noload_check.sh <<'PY'
import os, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^TABLE="\n(.*?)^"\n', src, re.S | re.M)
if not m:
    print("NOLOAD_TABLE RESULT FAIL (no TABLE found)"); sys.exit(1)
bad, keys, n = [], {}, 0
for line in m.group(1).splitlines():
    if not line.strip():
        continue
    n += 1
    f = line.split()
    if len(f) != 5:
        bad.append("row %r has %d columns, wants 5" % (line[:60], len(f))); continue
    key, runner, name, qml, arm = f
    if key in keys:
        bad.append("duplicate key %s" % key)
    keys[key] = 1
    r = runner.split(",")[0]
    if not os.path.isfile("tools/dev/" + r):
        bad.append("%s: no tools/dev/%s" % (key, r))
    if not os.path.isfile(qml):
        bad.append("%s: no %s" % (key, qml))
    if arm != "-" and not re.match(r"^(all:)?[A-Za-z0-9_]+$", arm):
        bad.append("%s: odd arm %r" % (key, arm))
for b in bad:
    print("BAD", b)
print("NOLOAD_TABLE RESULT %s (%d rows, %d unique keys, %d bad)" % ("FAIL" if bad else "PASS", n, len(keys), len(bad)))
sys.exit(1 if bad else 0)
PY
}

# The noload rows must fit their shards: the shard rows of the env tier (`gate_noload_rows K N`) are K = 1..N, once each, all of one N, and the
# table's rows are at most NOLOAD_SHARD_ROWS (30) a shard -- whoever adds rows past that adds a shard row (one gate, one timeout) first.
gate_noload_shards() {
    NOLOAD_SHARD_ROWS="${NOLOAD_SHARD_ROWS:-30}" python3 -B - << 'PY'
import os, re, sys
src = open("tools/dev/shell_gates.sh", encoding="utf-8").read()
env = re.search(r'^TABLE_ENV="\n(.*?)^"\n', src, re.S | re.M).group(1)
shards = []
for line in env.splitlines():
    m = re.search(r"\bgate_noload_rows\s+(\d+)\s+(\d+)\s*$", line)
    if m:
        shards.append((int(m.group(1)), int(m.group(2)), line.split()[1]))
bad = []
if not shards:
    bad.append("no shard row (gate_noload_rows K N) in the env tier")
else:
    ns = {n for _, n, _ in shards}
    if len(ns) != 1:
        bad.append("the shard rows disagree about N: %s" % sorted(ns))
    n = max(ns)
    ks = sorted(k for k, _, _ in shards)
    if ks != list(range(1, n + 1)):
        bad.append("the shard rows are K = %s, wanted 1..%d once each" % (ks, n))
    table = re.search(r'^TABLE="\n(.*?)^"\n', open("tools/dev/runner_noload_check.sh", encoding="utf-8").read(), re.S | re.M).group(1)
    rows = [f for f in (l.split() for l in table.splitlines()) if len(f) >= 5 and ".sh" in f[1]]
    cap = int(os.environ["NOLOAD_SHARD_ROWS"])
    if len(rows) > n * cap:
        bad.append("%d noload rows do not fit %d shards of %d: add a shard row (and raise N in every row)" % (len(rows), n, cap))
    print("%d rows in %d shards (at most %d each)" % (len(rows), n, cap))
for b in bad:
    print("BAD", b)
print("NOLOAD_SHARDS RESULT %s (%d bad)" % ("FAIL" if bad else "PASS", len(bad)))
sys.exit(1 if bad else 0)
PY
}

# Every runner of the noload table has a place in the battery: a row of the tables above or a ROWLESS entry with its reason. A stream
# that adds a runner to the noload table (the one list every stream adds to) and forgets its row fails here, naming the runner.
gate_runner_rows() {
    ROWLESS="$ROWLESS" python3 -B - <<'PY'
import fnmatch, os, re, sys
src = open("tools/dev/shell_gates.sh", encoding="utf-8").read()


def names_in(text):
    return {os.path.basename(x) for x in re.findall(r"([A-Za-z0-9_./-]+\.(?:sh|py|js))\b", text)}


def code_lines(path):
    return "\n".join(l for l in open(path, encoding="utf-8").read().splitlines() if not l.lstrip().startswith("#"))


rowed = set()
for name in ("TABLE_QUICK", "TABLE_QML", "TABLE_ENV", "TABLE_EXCL"):
    m = re.search(r'^%s="\n(.*?)^"\n' % name, src, re.S | re.M)
    if not m:
        print("RUNNER_ROWS RESULT FAIL (no %s found)" % name)
        sys.exit(1)
    rowed |= names_in(m.group(1))
m = re.search(r'^TABLE="\n(.*?)^"\n', open("tools/dev/runner_noload_check.sh", encoding="utf-8").read(), re.S | re.M)
runners = {}
for line in m.group(1).splitlines():
    f = line.split()
    if f:
        runners.setdefault(f[1].split(",")[0], []).append(f[0])
bad, rowless, used = [], [], set()
for line in os.environ.get("ROWLESS", "").splitlines():
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    parts = line.split(None, 1)
    if len(parts) < 2 or not parts[1].strip():
        bad.append("ROWLESS entry %r has no reason" % parts[0])
    rowless.append(parts[0])
n_row = n_less = 0
for r, keys in sorted(runners.items()):
    base = os.path.basename(r)
    if not os.path.isfile("tools/dev/" + r):
        bad.append("%s: no tools/dev/%s (noload key %s)" % (r, r, keys[0]))
        continue
    if base in rowed:
        n_row += 1
        continue
    hit = [pat for pat in rowless if fnmatch.fnmatch(base, pat) or fnmatch.fnmatch(r, pat)]
    if hit:
        used.update(hit)
        n_less += 1
        continue
    bad.append("%s (noload key %s) has no shell_gates row and is not in ROWLESS" % (r, ", ".join(keys)))
for pat in rowless:
    if pat not in used and not any(fnmatch.fnmatch(os.path.basename(r), pat) or fnmatch.fnmatch(r, pat) for r in runners):
        bad.append("ROWLESS %s matches no runner of the noload table (stale)" % pat)
for b in bad:
    print("BAD", b)
print("RUNNER_ROWS RESULT %s (%d runners in the noload table: %d with a row, %d in ROWLESS; %d bad)"
      % ("FAIL" if bad else "PASS", len(runners), n_row, n_less, len(bad)))
sys.exit(1 if bad else 0)
PY
}

# A row that passes `VAR=value` must be read by the runner it runs: the notes_popup_theme row said `MODE=themesync` and
# notes_popup_probe.sh takes the mode as its FIRST ARGUMENT, so for as long as the row existed it ran the ordinary probe a second time and the
# theme sync never ran. Static, the runner's own reads: the variable must be read by the runner script (`$VAR`, `${VAR`, a quoted "VAR", `process.env.VAR`),
# or by a file the runner names (a QML's Quickshell.env("VAR"): the environment passes through) -- but then the runner must not SET it itself
# (`MODE=probe` on its own launch line shadows the row's value: the QML never sees it). Reads in comment lines do not count.
gate_row_inputs() {
    python3 -B - <<'PY'
import os, re, sys
src = open("tools/dev/shell_gates.sh", encoding="utf-8").read()
rows = []   # (label, [env names], script path, [files named among its arguments])


def resolve(path):
    path = path.replace("@OUT", "")
    for cand in ("tools/dev/" + path, path):
        if path and os.path.isfile(cand):
            return cand
    return None


def env_names(words):
    return [w.split("=", 1)[0] for w in words if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w) and not w.startswith("UNSET=")]


for name in ("TABLE_QUICK", "TABLE_QML", "TABLE_ENV", "TABLE_EXCL"):
    for line in re.search(r'^%s="\n(.*?)^"\n' % name, src, re.S | re.M).group(1).splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        envs, script, extra = [], None, []
        for w in f[3:]:
            if w.startswith("%") or w.startswith("UNSET="):
                continue
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
                envs.append(w.split("=", 1)[0])
                continue
            r = resolve(w)
            if script is None:
                if r and r.endswith((".sh", ".py", ".js")):
                    script = r
            elif r:
                extra.append(r)
        if envs and script:
            rows.append((f[1], envs, script, extra))


def code(path):
    t = open(path, encoding="utf-8", errors="replace").read()
    if path.endswith(".sh"):
        t = "\n".join(l for l in t.splitlines() if not l.lstrip().startswith("#"))
    return t


def reads(text, v):
    return re.search(r"\$\{?!?%s\b|[\"']%s[\"']|process\.env\.%s\b" % (v, v, v), text) is not None


def closure(paths):
    seen, todo, out = set(), list(paths), []
    while todo and len(seen) < 14:
        p = todo.pop()
        if p in seen or not os.path.isfile(p):
            continue
        seen.add(p)
        t = code(p)
        out.append(t)
        for f in re.findall(r"([A-Za-z0-9_./-]+\.(?:sh|py|js|qml))\b", t):
            r = resolve(f) or (f if os.path.isfile(f) else None)
            if r and r not in seen:
                todo.append(r)
    return "\n".join(out)


PLATFORM = re.compile(r"^(QT_|QS_|XDG_|WAYLAND_|HYPRLAND_|LC_|LANG$|HOME$|PATH$|TMPDIR$)")   # read by Qt, Quickshell or the system, not by a script
bad, checked = [], 0
for label, envs, script, extra in rows:
    own = code(script)
    for v in envs:
        checked += 1
        if PLATFORM.match(v) or reads(own, v):
            continue
        if not reads(closure([script] + extra), v):
            bad.append("%s: %s= is read by nothing the runner %s starts" % (label, v, script))
        elif re.search(r"(^|[\s;(&|])%s=" % v, own, re.M):
            bad.append("%s: %s= reaches a file the runner starts, but %s sets %s itself on its own launch line (the row's value never arrives)" % (label, v, script, v))
for b in bad:
    print("BAD", b)
print("ROW_INPUTS RESULT %s (%d rows with variables, %d variables, %d bad)" % ("FAIL" if bad else "PASS", len(rows), checked, len(bad)))
sys.exit(1 if bad else 0)
PY
}

# A gate run FROM THE TREE (kind tree / env / run) must not start a quickshell in the tree: it writes its .qmlls.ini there and a quickshell
# already running in that root reloads -- the whole reason tools/dev/sandbox.sh exists (a runner of the env tier once did it from the main
# tree, and the link then pointed into a nested session that was dead after a reboot). Static, over those rows' runners: one that launches a quickshell must show a copy being made (sandbox.sh,
# rsync, git archive, cp -r / -a, mktemp -d), and none may launch a path rooted at the tree's own variables ($ROOT, $HERE, $PWD, $REPO). A net with
# holes (a path that reaches the tree through a function's parameter passes it), so one_run ALSO watches .qmlls.ini around every gate of
# those kinds and makes one that changed it red ("STARTED A QUICKSHELL IN THE TREE").
# NO TEST WINDOW ON THE USER'S DESKTOP (the user: "Can you not have qs tests appear on my desktop :)" -- an agent ran a hands-on
# launcher, and its window came up on the live desktop). Every runner under tools/dev/ that starts a
# quickshell must be one of: OFFSCREEN (QT_QPA_PLATFORM=offscreen in its own code -- a bare run included, so a row's env does not count),
# NESTED (tools/dev/lock_env.sh's Hyprland: `lock_env.sh`, `"$E" run`, AUTOSTART=, or a file under tools/dev/lock_env/ that only runs in it), or
# HANDS-ON (the LARES_SHOW guard: it opens a window only from a terminal or with LARES_SHOW=1, so an agent's or a gate's call is refused).
# EXEMPT names a file whose "launch" is only words (a string a check prints); a stale entry fails.
# The user's rule (2026-11-19): a GPU test never runs in the quick tier. A quick row whose runner (or a file it names) speaks of a GPU
# benchmark, prime-run or the NVIDIA offload variables fails -- even a stubbed one: the round-12 mux score probe's "no tools" case ran
# the REAL glmark2 and vkmark on the desktop once they were installed. Such a gate goes to the exclusive tier.
gate_quick_gpu() {
    python3 -B -c '
import os, re, sys
GPU = re.compile(r"\b(glmark2|vkmark|vkcube|glxgears|prime-run|nvidia-smi)\b|__NV_PRIME_RENDER_OFFLOAD|__GLX_VENDOR_LIBRARY_NAME")
src = open("tools/dev/shell_gates.sh", encoding="utf-8").read()
table = re.search(r"^TABLE_QUICK=\"(.*?)^\"", src, re.S | re.M).group(1)
bad, n = [], 0
for row in table.splitlines():
    w = row.split()
    if len(w) < 4 or w[0] != "quick" or w[2] == "fn":
        continue
    n += 1
    for tok in w[3:]:
        for f in (tok, "tools/dev/" + tok):
            if re.search(r"\.(sh|py|js|qml)$", f) and os.path.isfile(f):
                code = "\n".join(l for l in open(f, encoding="utf-8", errors="replace").read().splitlines() if not l.lstrip().startswith("#"))
                m = GPU.search(code)
                if m:
                    bad.append("%s (%s): names %s -- a GPU test goes to the exclusive tier" % (w[1], f, m.group(0)))
                break
for b in bad:
    print("BAD", b)
print("QUICK_GPU RESULT %s (%d quick rows read; %d run a GPU test)" % ("FAIL" if bad else "PASS", n, len(bad)))
sys.exit(1 if bad else 0)
'
}
gate_desktop_launch() {
    python3 -B - <<'PY2'
import glob, re, sys
launch = re.compile(r'(?:^|[\s;|&(`"\'])(?:exec\s+)?quickshell\s+(.*)')
SAFE = re.compile(r'QT_QPA_PLATFORM[=:-]+offscreen|lock_env\.sh|"\$E" (run|up)|AUTOSTART=|LARES_SHOW')
EXEMPT = {
    "tools/dev/lares_tool_probe.sh": "the words of a check (\"the shell is quickshell -n -p <repo>/shell.qml ...\"), not a launch",
    "tools/dev/perf/shell_rest_sampler_selftest.sh": "a test string of the sampler's own match, not a launch",
}
def code_of(p):
    return [l for l in open(p, encoding="utf-8", errors="replace").read().splitlines() if not l.lstrip().startswith("#")]
def launches(p):
    out = []
    for l in code_of(p):
        m = launch.search(l)
        if not m or re.match(r'^(-\S+\s+)*(ipc|list|kill|log|msg)\b', m.group(1)):
            continue
        if re.search(r'-p\b|--path|\.qml', m.group(1)):
            out.append(l.strip())
    return out
bad, n = [], 0
for p in sorted(glob.glob("tools/dev/**/*.sh", recursive=True)):
    if p.startswith("tools/dev/lock_env/"):
        continue
    ls = launches(p)
    if p in EXEMPT:
        if not ls:
            bad.append("%s: EXEMPT entry, but the file no longer looks like a launch -- drop the entry" % p)
        continue
    if not ls:
        continue
    n += 1
    if not SAFE.search("\n".join(code_of(p))):
        bad.append("%s: starts a quickshell that can open a window on the user's desktop (not offscreen, not nested, no LARES_SHOW guard): %s" % (p, ls[0][:100]))
for b in bad:
    print("BAD", b)
print("DESKTOP_LAUNCH RESULT %s (%d runners launch a quickshell; %d could reach the desktop)" % ("FAIL" if bad else "PASS", n, len(bad)))
sys.exit(1 if bad else 0)
PY2
}

gate_tree_launch() {
    python3 -B - <<'PY'
import os, re, sys
src = open("tools/dev/shell_gates.sh", encoding="utf-8").read()
launch = re.compile(r'(?:^|[\s;|&(`"\'])(?:exec\s+)?quickshell\s+(.*)')
COPY = re.compile(r'sandbox\.sh|rsync |git archive|cp -[ra]+ |mktemp -d|a1_tree ')
ROOTED = re.compile(r'-p\s+["\']?\$\{?(ROOT|HERE|PWD|REPO)\}?/|-p\s+["\']?\$\(pwd\)')


def code_of(path):
    return [l for l in open(path, encoding="utf-8", errors="replace").read().splitlines() if not l.lstrip().startswith("#")]


def launches(path):
    out = []
    for l in code_of(path):
        m = launch.search(l)
        if not m:
            continue
        rest = m.group(1)
        if re.match(r'^(-\S+\s+)*(ipc|list|kill|log|msg)\b', rest):
            continue
        if re.search(r'-p\b|--path|\.qml', rest):
            out.append(l.strip())
    return out


bad, seen, n = [], set(), 0
for name in ("TABLE_QUICK", "TABLE_QML", "TABLE_ENV", "TABLE_EXCL"):
    for line in re.search(r'^%s="\n(.*?)^"\n' % name, src, re.S | re.M).group(1).splitlines():
        f = line.split()
        if len(f) < 4 or f[2] not in ("tree", "env", "run"):
            continue
        script = None
        for w in f[3:]:
            if w.startswith("%") or w.startswith("UNSET=") or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
                continue
            w = w.replace("@OUT", "")
            for c in ("tools/dev/" + w, w):
                if os.path.isfile(c) and c.endswith(".sh"):
                    script = c
                    break
            if script:
                break
        if not script or script in seen:
            continue
        seen.add(script)
        ls = launches(script)
        if not ls:
            continue
        n += 1
        text = "\n".join(code_of(script))
        rooted = [l for l in ls if ROOTED.search(l)]
        if rooted:
            bad.append("%s (row %s, %s): launches a quickshell on the tree itself: %s" % (script, f[1], f[2], rooted[0][:100]))
        elif not COPY.search(text):
            bad.append("%s (row %s, %s): launches a quickshell and makes no copy (sandbox.sh, rsync, git archive, cp -r, mktemp -d): %s" % (script, f[1], f[2], ls[0][:100]))
for b in bad:
    print("BAD", b)
print("TREE_LAUNCH RESULT %s (%d runners of tree / env / run rows launch a quickshell; %d bad)" % ("FAIL" if bad else "PASS", n, len(bad)))
sys.exit(1 if bad else 0)
PY
}

# THE ONE FILTER OF THE Qt 6.12 TEXT-INPUT WARNING (tools/dev/result_lib.sh RL_QT_TEXTINPUT_RE + RL_QT_TEXTINPUT_ENABLE_RE / rl_platform_noise). Three halves:
#  1. the function drops exactly the platform's two lines (disable "but X is focused", enable "but X has focus"; both pointer shapes) -- and keeps every decoy: another message of the
#     category, the same function with other words, another level, another category, a real fault, a blank line;
#  2. the two logs the brief names are judged through it (tools/dev/smoke.sh -- which gate smoke_panelwindow runs -- and shell_probe.sh's
#     log-clean);
#  3. no other script carries a pattern of its own for the warning (LEGACY lists the exceptions; it is empty, and an entry whose file no
#     longer has a copy fails, as ROWLESS's do). The text-input probe that proved the line is the platform's was deleted with the cleanup:
#     if the platform stops printing it, the filter in tools/dev/result_lib.sh is dead weight and goes (tag pre-cleanup has the probe).
gate_platform_noise() {
    python3 -B - <<'PY'
import os, re, subprocess, sys
LEGACY = {}
CONSUMERS = ["tools/dev/smoke.sh", "tools/dev/shell_probe.sh"]
SCAN_SKIP = {"tools/dev/result_lib.sh", "tools/dev/shell_gates.sh"}
PAT = re.compile(r"disableSurface|enableSurface|Trying to (?:dis|en)able|QWaylandTextInput|qt\.qpa\.wayland\.te")
bad = []
# 1. the cases
HEAD = "  WARN qt.qpa.wayland.textinput: virtual void QtWaylandClient::QWaylandTextInputv3::"
TAIL = "(wl_surface*) Trying to disable 0x%s but 0x%s is focused"
drop = [HEAD + "disableSurface" + TAIL % ("7ff0d8b80f20", "7ff0d8d94a40"),
        HEAD + "disableSurface" + TAIL % ("7f4f3c4f9360", "0"),
        HEAD.strip() + "disableSurface" + TAIL % ("1", "2")]
ETAIL = "(wl_surface*) Trying to enable 0x%s but 0x%s has focus"
drop += [HEAD + "enableSurface" + ETAIL % ("7f5d92dbff40", "7f5d92dbff40"),
         HEAD + "enableSurface" + ETAIL % ("7f4f3c4f9360", "0")]
keep = [HEAD + "enableSurface" + TAIL % ("7f4f3c4f9360", "0"),
        HEAD + "enableSurface" + ETAIL % ("7f4f3c4f9360", "0") + ", twice",
        HEAD + "disableSurface" + ETAIL % ("7f4f3c4f9360", "0"),
        HEAD.replace("WARN", "ERROR") + "enableSurface" + ETAIL % ("1", "0"),
        HEAD + "enableSurface" + ETAIL.replace("has focus", "is focused") % ("1", "0"),
        HEAD + "commitState" + ETAIL % ("1", "0"),
        HEAD + "disableSurface" + TAIL % ("7f4f3c4f9360", "0") + ", twice",
        HEAD.replace("WARN", "ERROR") + "disableSurface" + TAIL % ("1", "0"),
        HEAD.replace("textinput", "window") + "disableSurface" + TAIL % ("1", "0"),
        "  WARN qt.qpa.wayland.textinput: something else entirely",
        "x" + HEAD + "disableSurface" + TAIL % ("1", "0"),
        '  WARN qml: Binding loop detected for property "x"',
        ""]
lines = []
for i, k in enumerate(keep):
    lines.append(k)
    if i < len(drop):
        lines.append(drop[i])
out = subprocess.run(["bash", "-c", ". tools/dev/result_lib.sh; rl_platform_noise"], input="\n".join(lines) + "\n", capture_output=True, text=True)
got = out.stdout.split("\n")[:-1]
if out.returncode != 0:
    bad.append("rl_platform_noise exited %d" % out.returncode)
for l in drop:
    if l in got:
        bad.append("cases: kept what it must drop: %s" % l.strip()[:120])
for l in keep:
    if l not in got:
        bad.append("cases: a decoy was dropped: %s" % l.strip()[:120])
if got != keep:
    bad.append("cases: the output is not exactly the decoys, in order (%d lines, wanted %d)" % (len(got), len(keep)))
empty = subprocess.run(["bash", "-c", "set -o pipefail; . tools/dev/result_lib.sh; printf '' | rl_platform_noise"], capture_output=True, text=True)
if empty.returncode != 0:
    bad.append("an empty log makes rl_platform_noise fail (exit %d): a clean run would read as a failure under pipefail" % empty.returncode)
# 2. the consumers
for f in CONSUMERS:
    try:
        code = [l for l in open(f).read().split("\n") if not l.lstrip().startswith("#")]
    except OSError:
        bad.append("consumer %s is gone" % f)
        continue
    if not any("rl_platform_noise" in l for l in code):
        bad.append("%s does not pipe its judged log through rl_platform_noise" % f)
# 3. no other copy
seen = set()
for root, dirs, files in os.walk("tools/dev"):
    dirs[:] = [d for d in dirs if d not in ("fixtures", "__pycache__")]
    for n in files:
        if not n.endswith((".sh", ".py", ".js")):
            continue
        p = os.path.join(root, n)
        if p in SCAN_SKIP:
            continue
        try:
            txt = open(p, errors="replace").read()
        except OSError:
            continue
        if PAT.search(txt):
            seen.add(p)
            if p not in LEGACY:
                bad.append("%s carries a private copy of the text-input pattern (use rl_platform_noise, tools/dev/result_lib.sh)" % p)
for p in sorted(LEGACY):
    if p not in seen:
        bad.append("LEGACY entry %s no longer has a copy of the pattern: remove it from LEGACY" % p)
for b in bad:
    print("PLATFORM_NOISE FAIL " + b)
print("PLATFORM_NOISE RESULT %s (%d cases, %d consumers, %d legacy copies known)" % ("FAIL" if bad else "PASS", len(drop) + len(keep), len(CONSUMERS), len(LEGACY)))
sys.exit(1 if bad else 0)
PY
}

# Every mockup's wiring: nothing UNSEEN / MISSING / DEAD / CLASH, and every DRIFT row is one the promotion REFUSES by design.
gate_wiring_all() {
    local bad=0 n=0 m out
    for m in ${WIRING_ONLY:-$(grep -l 'MockupWindow' mockups/*.qml)}; do
        n=$((n + 1))
        out=$(python3 -B tools/dev/mockup_wiring_check.py "$m" --drift-fails 2>&1)
        local rc=$?
        if [ "$rc" != 0 ]; then
            # only DRIFT may be non-empty, and every drift row must say the promotion refuses it
            local sections drift
            sections=$(printf '%s\n' "$out" | grep -a -E '^(UNSEEN|MISSING|DEAD|CLASH) \([1-9]')
            drift=$(printf '%s\n' "$out" | sed -n '/^DRIFT/,$p' | tail -n +2 | grep -a -E '^\s+\S' | grep -a -v 'promotion refuses')
            if [ -n "$sections" ] || [ -n "$drift" ]; then
                echo "BAD $m rc=$rc: $sections $(printf '%s' "$drift" | head -2)"
                bad=$((bad + 1))
            else
                echo "ok  $m: drift rows are all refusals ($(printf '%s\n' "$out" | grep -a -c 'promotion refuses'))"
            fi
        fi
    done
    echo "WIRING RESULT $([ "$bad" = 0 ] && echo PASS || echo FAIL) ($n mockups, $bad bad)"
    [ "$bad" = 0 ]
}

# The promoted values are in the modules: the promotion's dry run over every mockup (the rows phase) plans NO write. A row that still writes is a promotion
# that never reached its module -- or a Save pipeline that cannot find it: from the F2 merge on the shell frame's use of every owner made them "shared"
# and the planner SKIPPED their rows, which is how a dry run could say 0 and mean "nothing I can see" (tools/dev/mockup_promote_hints.json `owned`).
# (The fonts phase is another run -- the user's call -- and plans its own ten writes; the notes mockup's dressing row is a hinted skip in this one.)
gate_promote_dry() {
    local out rc rows
    out=$(python3 -B tools/dev/mockup_promote.py dry --all 2>&1); rc=$?
    printf '%s\n' "$out" | grep -a -E '^(write|MOCKUP_PROMOTE dry run)'
    rows=$(printf '%s\n' "$out" | awk '$1 == "write" { print $4 }' | sort -u | tr '\n' ' ')
    if [ "$rc" = 0 ] && [ -z "$rows" ] && printf '%s\n' "$out" | grep -q -E '^MOCKUP_PROMOTE dry run 0 write'; then
        echo "PROMOTE_DRY RESULT PASS (every promoted value is in its module: $(printf '%s\n' "$out" | sed -n 's/^MOCKUP_PROMOTE dry run 0 write, \([0-9]*\) same, \([0-9]*\) refuse, \([0-9]*\) skip.*/\1 same, \2 refused, \3 skipped/p'))"
        return 0
    fi
    echo "PROMOTE_DRY RESULT FAIL (rc $rc, the plan would write: ${rows:-<no summary line>})"
    return 1
}

# qmllint over every QML file changed since the assembly's base. Known false positives of the linter: PanelWindow "not creatable",
# GlobalShortcut / PostReloadHook unresolved (the shell's types the linter cannot see), and three facts about Quickshell's OWN types that
# its type information does not carry (qmllint 6.12, quickshell 0.3.2; each is a documented member that works): a model's `values`
# (UntypedObjectModel), such a model as a Connections target, and ShellScreen's `name` (QuickshellScreenInfo). An Info line (an unused
# import that registers a directory) is not a fault. Not linted: fixture trees (partial on purpose) and tools/dev/qt_gc_attach/ (its `Probe` module is
# registered by probe.cpp at run time: the linter cannot see it, and qt_gc_attach_probe.sh builds and runs it). A Loader's item or a createObject() result is a bare QObject to the linter: the call site says so with
# `// qmllint disable missing-property` (ClockPopupContent), not a pattern here.
gate_qmllint_changed() {
    local files lint bad
    files=$(git diff --name-only --diff-filter=AM "$LINT_BASE" HEAD -- '*.qml' | grep -v -E '^tools/dev/(fixtures|qt_gc_attach)/' | while read -r f; do [ -f "$f" ] && echo "$f"; done)
    [ -n "$files" ] || { echo "QMLLINT RESULT FAIL (no changed QML file found since $LINT_BASE)"; return 1; }
    # shellcheck disable=SC2086
    lint=$(/usr/lib/qt6/bin/qmllint -I . -I /usr/lib/qt6/qml $files 2>&1)
    bad=$(printf '%s\n' "$lint" | grep -a -E '^(Warning|Error)' \
        | grep -a -v -E 'Type PanelWindow is not creatable|Type GlobalShortcut is used but it is not resolved|PostReloadHook was not found|not declared as singleton in qmldir|Member "values" not found on type "UntypedObjectModel"|Cannot assign binding of type UntypedObjectModel to QObject|Member "name" not found on type "QuickshellScreenInfo"')
    printf '%s\n' "$lint" | grep -a -E '^(Warning|Error|Info)' | sed 's/^/  /' | head -60
    if [ -n "$bad" ]; then
        printf '%s\n' "$bad" | sed 's/^/BAD /' | head -20
        echo "QMLLINT RESULT FAIL ($(printf '%s\n' "$bad" | wc -l) warning(s) in $(printf '%s\n' "$files" | wc -l) files)"
        return 1
    fi
    echo "QMLLINT RESULT PASS ($(printf '%s\n' "$files" | wc -l) files changed since $LINT_BASE, only the linter's known false positives)"
}

# tools/dev/runner_noload_check.sh, every row of its table (a runner handed a QML that does not load must end
# on the no-result verdict). Runs from the tree: the adapter's and RowFlight's BASE files come out of git.
# SHARDED: `gate_noload_rows K N` takes the rows whose place in the list is K modulo N (the shard rows noload_table_1..N of the env tier). One
# row is two runs of a runner, ~26 s on a loaded machine, and the whole list outgrew a gate's default 900 s after 35 of its 156 rows (round 2):
# each shard is its own gate with its own timeout, and noload_shards (quick) fails when the rows no longer fit them.
gate_noload_rows() {
    local keys k=${1:-1} n=${2:-1}
    keys=$(sed -n '/^TABLE="$/,/^"$/p' tools/dev/runner_noload_check.sh | awk 'NF >= 5 && $2 ~ /\.sh/ { print $1 }' \
        | awk -v k="$k" -v n="$n" 'NR % n == k % n' | tr '\n' ' ')
    [ -n "$keys" ] || { echo "NOLOAD RESULT FAIL (no row of the table for shard $k of $n)"; return 1; }
    echo "the table's rows, shard $k of $n: $keys"
    # Run from the TREE (the adapter's and RowFlight's BASE files come out of git), and NOT as the command of an offscreen sandbox call, which is the
    # check's own advice for a private runtime dir: inside one every nested sandbox call shares ITS runtime dir (the `.lares-sandbox-rt` marker), and
    # shell_render's parallel `quickshell -n` cells then refuse each other ("An instance of this configuration is already running"): the first cell's
    # log names no broken file and the srender row reads BAD -- one run in two (measured: BAD, ok, and ok bare three times). This gate's own stand-in
    # runtime dir (one_run: a `fn` kind) already keeps whatever the check starts directly out of /run/user, and each nested sandbox call that is
    # NOT inside another makes a private one of its own.
    ONLY="$keys" SCRATCH="${SCRATCH:-/tmp}/noload" tools/dev/runner_noload_check.sh
}

# ---- the grader (above the --fn dispatch: gate_selftest_grade calls it) ----
VRE='RESULT (PASS|FAIL)|ARMS (PASS|FAIL)|^[A-Za-z][A-Za-z0-9_.-]*( [A-Za-z0-9_.-]+)* (PASS|FAIL)([ :(]|$)|^(PASS|FAIL)([ :(]|$)|THEME_SYNC (static )?(PASS|FAIL)'

# grade <log> <rc> <vkind> <outdir> [need]: sets G_GREEN (1/0), G_LINES. `need` (an ERE, from %need=) must also match the log.
grade() {
    local log=$1 rc=$2 vkind=$3 od=$4 need=${5:-} clean last
    clean=$(mktemp "${TMPDIR:-/tmp}/lares-sg-clean.XXXXXX")
    rl_clean "$log" | sed -E 's/^ *(DEBUG|INFO|WARN|ERROR) qml: //' > "$clean"       # a probe's own lines come out of quickshell with this prefix
    # the lines to show: the RESULT lines (distinct), else the last verdict lines
    G_LINES=$(grep -a -o -E "[A-Za-z0-9_ .-]*RESULT (PASS|FAIL)[^|]*" "$clean" | sed 's/^ *//' | cut -c1-110 | awk '!seen[$0]++' | tail -4 | tr '\n' '|' | sed 's/|$//')
    [ -n "$G_LINES" ] || G_LINES=$(grep -a -E "$VRE" "$clean" | cut -c1-110 | tail -2 | tr '\n' '|' | sed 's/|$//')
    [ -n "$G_LINES" ] || G_LINES="(no verdict line)"
    last=$(grep -a -E "$VRE" "$clean" | tail -1)
    local word; word=$(printf '%s\n' "$last" | grep -a -o -w -E 'PASS|FAIL' | head -1)
    G_GREEN=0
    if [ "$rc" = 0 ] && { [ "$vkind" = meta ] || ! grep -a -q "no result: " "$clean"; }; then
        case "$vkind" in
            smoke)  grep -a -q -E "\.qml +clean$" "$clean" && G_GREEN=1 ;;
            rc)     [ -s "$clean" ] && G_GREEN=1 && [ -z "$last" ] && G_LINES="(exit 0, $(grep -a -c . "$clean") lines, no verdict line by design)" ;;
            render) if [ -n "$last" ]; then [ "$word" = PASS ] && G_GREEN=1
                    else [ -n "$(find "$od" -name '*.png' -print -quit 2> /dev/null)" ] && G_GREEN=1 && G_LINES="(drew PNGs, no verdict line)"; fi ;;
            *)      [ "$word" = PASS ] && G_GREEN=1 ;;
        esac
    fi
    if [ "$G_GREEN" = 1 ] && [ -n "$need" ]; then
        if grep -a -q -E "$need" "$clean"; then
            [ -z "$last" ] && G_LINES="(needs: $(grep -a -E -m1 "$need" "$clean" | sed 's/^ *//' | cut -c1-100))"
        else
            G_GREEN=0; G_LINES="(the log lacks /$need/)"
        fi
    fi
    rm -f "$clean"
}

# The grader on synthetic logs: what is green and what is red, case by case. (A grader that cannot say RED proves nothing.)
gate_selftest_grade() {
    local d n=0 bad=0
    d=$(mktemp -d /tmp/lares-sg-grade.XXXXXX)
    gcase() {  # name want(1|0) rc vkind need text [png]
        local name=$1 want=$2 rc=$3 vk=$4 need=$5 text=$6 png=${7:-}
        n=$((n + 1))
        printf '%b' "$text" > "$d/log"; rm -rf "$d/out"; mkdir -p "$d/out"
        [ -n "$png" ] && : > "$d/out/a.png"
        grade "$d/log" "$rc" "$vk" "$d/out" "$need"
        if [ "$G_GREEN" != "$want" ]; then echo "SELFTEST FAIL $name: wanted $want, got $G_GREEN ($G_LINES)"; bad=$((bad + 1)); fi
    }
    gcase "a RESULT PASS"                          1 0 std ""  "x\nFOO RESULT PASS (3 ok)\n"
    gcase "a RESULT FAIL, exit 0 (old runners)"    0 0 std ""  "FOO RESULT FAIL (1 failed)\n"
    gcase "a PASS with exit 1 (the log must be clean)" 0 1 std "" "FOO RESULT PASS\nWARN something\n"
    gcase "a PASS that says 0 FAIL"                1 0 std ""  "WALLJOIN RESULT PASS (5 ok, 0 FAIL)\n"
    gcase "armed controls print FAIL, the last verdict is PASS" 1 0 std "" "TS RESULT FAIL\nthe control -- must FAIL:\n  x FAIL\nPASS tab selector\n"
    gcase "a PASS, then a FAIL"                    0 0 std ""  "PASS one\nFAIL two\n"
    gcase "no verdict line at all"                 0 0 std ""  "just some output\n"
    gcase "the no-result verdict"                  0 1 std ""  "FOO RESULT FAIL (no result: /tmp/x.log)\n"
    gcase "a PASS beside a no-result line"         0 0 std ""  "FOO RESULT PASS\nBAR RESULT FAIL (no result: /tmp/x.log)\n"
    gcase "a probe's own lines (DEBUG qml: prefix)" 1 0 std "" " DEBUG qml: RAILSWIRL PASS\n"
    gcase "meta: no-result lines are the subject, the last verdict is PASS" 1 0 meta "" "ok a clean rc 1 A RESULT FAIL (no result: /x)\nNOLOAD RESULT PASS (1 runners)\n"
    gcase "meta: the last verdict is FAIL"        0 0 meta "" "ok a clean rc 1 A RESULT FAIL (no result: /x)\nNOLOAD RESULT FAIL (1 of 2 runners)\n"
    gcase "meta: exit 1 with a PASS line"         0 1 meta "" "NOLOAD RESULT PASS (1 runners)\n"
    gcase "a timeout (rc 124) with a PASS line"    0 124 std "" "FOO RESULT PASS\n"
    gcase "render: PNGs, no verdict"               1 0 render "" "ok x.png\n" png
    gcase "render: no PNG, no verdict"             0 0 render "" "ok x.png\n"
    gcase "render: a RESULT FAIL beside a PNG"     0 0 render "" "FOO RESULT FAIL\n" png
    gcase "rc kind: output and exit 0"             1 0 rc ""   "lint clean\nprobe clean\n"
    gcase "rc kind: no output"                     0 0 rc ""   ""
    gcase "rc kind: exit 1"                        0 1 rc ""   "lint clean\n"
    gcase "smoke: clean lines, exit 0"             1 0 smoke "" "test_a.qml        clean\ntest_b.qml        clean\n"
    gcase "smoke: a warning, exit 1"               0 1 smoke "" "test_a.qml        1 distinct warning(s)\n"
    gcase "smoke: nothing was smoked"              0 0 smoke "" "\n"
    gcase "need: the number is there"              1 0 rc "maxGlueErr=0\\.00" "GLUE RESULT samples=9 maxGlueErr=0.00\n"
    gcase "need: the number is not"                0 0 rc "maxGlueErr=0\\.00" "GLUE RESULT samples=9 maxGlueErr=3.10\n"
    rm -rf "$d"
    echo "GRADE_SELFTEST RESULT $([ "$bad" = 0 ] && echo PASS || echo FAIL) ($n cases, $bad wrong)"
    [ "$bad" = 0 ]
}

# ARMs of the static checks (tools/dev/shell_gates.sh --arms): each patches ONE thing in a scratch git copy of this tree (a `git archive HEAD`, committed as
# the base), runs the check there, and the check must go RED on its own words; the unpatched copy runs first and must be GREEN (so the harness is
# not what fails). Nothing is written in the tree.
gate_arms() {
    local W="${SCRATCH:-/tmp}/sg-arms" rc=0 base
    rm -rf "$W"; mkdir -p "$W/t0"
    git archive HEAD | tar -x -C "$W/t0" || { echo "SHELL_GATES_ARMS RESULT FAIL (git archive)"; return 1; }
    ( cd "$W/t0" && git init -q && git add -A && git -c user.name=arm -c user.email=arm@arm commit -q -m base ) || { echo "SHELL_GATES_ARMS RESULT FAIL (scratch repo)"; return 1; }
    base=$(git -C "$W/t0" rev-parse HEAD)
    arm_case() {  # name gate needle python-patch [WIRING_ONLY] [control-patch] (the patches read sys.argv[1] = the tree)
        local name=$1 gate=$2 needle=$3 patch=$4 out
        rm -rf "$W/t1"; cp -a "$W/t0" "$W/t1"
        if [ -n "${6:-}" ]; then   # a harmless change first (the lint gate looks at files changed since the base)
            printf '%s\n' "$6" | python3 - "$W/t1" && ( cd "$W/t1" && git -c user.name=arm -c user.email=arm@arm commit -q -am control )
        fi
        # the control: the copy without the fault is green
        out=$( cd "$W/t1" && LINT_BASE="$base" WIRING_ONLY="${5:-}" bash tools/dev/shell_gates.sh --fn "$gate" 2>&1 ); local crc=$?
        if [ "$crc" != 0 ]; then echo "ARM $name: THE CONTROL IS RED ($gate on the unpatched copy): $(printf '%s\n' "$out" | tail -2 | tr '\n' ' ')"; rc=1; return; fi
        printf '%s\n' "$patch" | python3 - "$W/t1" || { echo "ARM $name: the anchor is gone"; rc=1; return; }
        # add -A: an arm may ADD a file (desktopbare's runner, rowbare's), which `commit -am` would leave untracked and unseen
        ( cd "$W/t1" && git add -A && git -c user.name=arm -c user.email=arm@arm commit -q -m arm ) || { echo "ARM $name: nothing changed"; rc=1; return; }
        out=$( cd "$W/t1" && LINT_BASE="$base" WIRING_ONLY="${5:-}" bash tools/dev/shell_gates.sh --fn "$gate" 2>&1 ); crc=$?
        if [ "$crc" != 0 ] && printf '%s\n' "$out" | grep -q -F "$needle"; then echo "ARM $name: FAILED AS IT MUST ($gate: $(printf '%s\n' "$out" | grep -m1 -F "$needle" | cut -c1-110))"
        else echo "ARM $name: DID NOT FAIL AS IT MUST (rc $crc, wanted '$needle'): $(printf '%s\n' "$out" | tail -2 | tr '\n' ' ')"; rc=1; fi
    }
    arm_case syntax gate_bash_syntax "SYNTAX tools/dev/config_loaders_probe.sh" 'import sys
p = sys.argv[1] + "/tools/dev/config_loaders_probe.sh"
s = open(p).read()
open(p, "w").write(s + "\nif then\n")'
    arm_case shardlost gate_noload_shards "the shard rows are K = [1, 2, 3, 4, 5, 6, 7]" 'import sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
i = s.index("env  noload_table_8 ")
j = s.index("\n", i) + 1
open(p, "w").write(s[:i] + s[j:])'
    arm_case rowbare gate_tree_launch "zz_bare_launch_probe.sh (row zz_bare, tree): launches a quickshell on the tree itself" 'import sys
t = sys.argv[1]
open(t + "/tools/dev/zz_bare_launch_probe.sh", "w").write("#!/usr/bin/env bash\ncd \"$(dirname \"$0\")/../..\"\nROOT=$(pwd)\nquickshell -p \"$ROOT/test_zz.qml\"\n")
p = t + "/tools/dev/shell_gates.sh"
s = open(p).read()
u = s.replace("qml  configfile         box   configfile_probe.sh\n", "qml  zz_bare            tree  zz_bare_launch_probe.sh\nqml  configfile         box   configfile_probe.sh\n", 1)
assert u != s
open(p, "w").write(u)'
    arm_case quickgpu gate_quick_gpu "names glmark2 -- a GPU test goes to the exclusive tier" 'import sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
t = s.replace("exclusive silicon_mux_score run bash tools/dev/silicon_mux_score_probe.sh\n", "", 1).replace("quick  quick_gpu       fn   gate_quick_gpu\n", "quick  quick_gpu       fn   gate_quick_gpu\nquick  silicon_mux_score run  bash tools/dev/silicon_mux_score_probe.sh\n", 1)
assert t != s
open(p, "w").write(t)'
    arm_case desktopbare gate_desktop_launch "zz_window_probe.sh: starts a quickshell that can open a window on the user's desktop" 'import sys
t = sys.argv[1]
open(t + "/tools/dev/zz_window_probe.sh", "w").write("#!/usr/bin/env bash\ncd \"$(dirname \"$0\")/../..\"\ntimeout 20 quickshell -p test_zz.qml > /dev/null 2>&1\n")'
    arm_case rowforgotten gate_runner_rows "themectl_home_probe.sh (noload key thhome) has no shell_gates row" 'import sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
t = s.replace("qml  themectl_home      box   themectl_home_probe.sh\n", "", 1)
assert t != s
open(p, "w").write(t)'
    arm_case rowlessreason gate_runner_rows "ROWLESS entry 'configfile_probe.sh' has no reason" 'import re, sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
t = s.replace("ROWLESS=\"\n", "ROWLESS=\"\nconfigfile_probe.sh\n", 1)
assert t != s
open(p, "w").write(t)'
    arm_case rowlessstale gate_runner_rows "ROWLESS zz_gone_probe.sh matches no runner" 'import sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
t = s.replace("ROWLESS=\"\n", "ROWLESS=\"\nzz_gone_probe.sh            a runner that was removed\n", 1)
assert t != s
open(p, "w").write(t)'
    arm_case rowenvdead gate_row_inputs "shell_probe_hot: ZZ_NOT_READ= is read by nothing" 'import sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
t = s.replace("SHP_WATCH=1 ONLY=p13 shell_probe.sh\n", "SHP_WATCH=1 ONLY=p13 ZZ_NOT_READ=1 shell_probe.sh\n", 1)
assert t != s
open(p, "w").write(t)'
    arm_case noisebroad gate_platform_noise "cases: a decoy was dropped" 'import sys
p = sys.argv[1] + "/tools/dev/result_lib.sh"
s = open(p).read()
t = s.replace("virtual void QtWaylandClient::QWaylandTextInputv3::disableSurface\\(wl_surface\\*\\) Trying to disable 0x[0-9a-f]+ but 0x[0-9a-f]+ is focused$", ".*$", 1)
assert t != s
open(p, "w").write(t)'
    arm_case noiseconsumer gate_platform_noise "tools/dev/smoke.sh does not pipe its judged log through rl_platform_noise" 'import sys
p = sys.argv[1] + "/tools/dev/smoke.sh"
s = open(p).read()
t = s.replace("        | rl_platform_noise \\\n", "", 1)
assert t != s
open(p, "w").write(t)'
    arm_case noisecopy gate_platform_noise "tools/dev/configfile_probe.sh carries a private copy of the text-input pattern" 'import sys
p = sys.argv[1] + "/tools/dev/configfile_probe.sh"
s = open(p).read()
open(p, "w").write(s + "\ngrep -v QWaylandTextInputv3 /dev/null\n")'
    arm_case noisestale gate_platform_noise "LEGACY entry tools/dev/configfile_probe.sh no longer has a copy of the pattern" 'import sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
t = s.replace("LEGACY = {}\n", "LEGACY = {\"tools/dev/configfile_probe.sh\": \"an entry whose file has no copy\"}\n", 1)
assert t != s
open(p, "w").write(t)'
    arm_case smokeunscoped gate_smoke_filter "the mpd socket warning of an unnamed file was let through" 'import sys
p = sys.argv[1] + "/tools/dev/shell_gates.sh"
s = open(p).read()
a = "(len(a) < 3 or f in " + "a[2])"      # split, so this very line is not the first place the anchor is found
assert s.count(a) == 1, s.count(a)
open(p, "w").write(s.replace(a, "True"))'
    arm_case noloaddup gate_noload_table "duplicate key mockup" 'import sys
p = sys.argv[1] + "/tools/dev/runner_noload_check.sh"
lines = open(p).read().split("\n")
i = [k for k, l in enumerate(lines) if l.startswith("mockup ")][0]
lines.insert(i + 1, lines[i])
open(p, "w").write("\n".join(lines))'
    arm_case promote gate_promote_dry "the plan would write: SystemUpdatePopup.normalListScale" 'import re, sys
p = sys.argv[1] + "/modules/bar/system_update/components/SystemUpdatePopup.qml"
s = open(p).read()
t = re.sub(r"normalListScale: 1\.2\b", "normalListScale: 1.25", s, count=1)
assert t != s
open(p, "w").write(t)'
    # (on ScrollDressing.qml since 2026-10-25: qmllint 6.12 no longer resolves ThemeControl.qml's root and reports nothing unqualified there)
    arm_case lint gate_qmllint_changed "QMLLINT RESULT FAIL" 'import sys
p = sys.argv[1] + "/modules/common/components/ScrollDressing.qml"
s = open(p).read()
i = s.rindex("}")
open(p, "w").write(s[:i] + "    property int armBad: nothingDeclaredHere + 1\n" + s[i:])' "" 'import sys
p = sys.argv[1] + "/modules/common/components/ScrollDressing.qml"
open(p, "a").write("// control: a harmless change\n")'
    arm_case wiring gate_wiring_all "WIRING RESULT FAIL" 'import sys
p = sys.argv[1] + "/mockups/clock.qml"
s = open(p).read()
t = s.replace(chr(112) + "rop: \"padding\"", chr(112) + "rop: \"paddingARM\"", 1)
assert t != s
open(p, "w").write(t)' mockups/clock.qml
    # ---- the dynamic half of tree_launch: a gate run from the tree that changes .qmlls.ini (a quickshell started in the tree) is red, whatever it said.
    # A scratch copy gets a tree-kind row whose runner prints a PASS and, armed (ZZ_TOUCH=1), makes the .qmlls.ini link again; the control is green.
    {
        local cout ccrc
        rm -rf "$W/t1"; cp -a "$W/t0" "$W/t1"
        python3 - "$W/t1" << 'PY' || { echo "ARM canary: the anchor is gone"; rc=1; }
import sys
t = sys.argv[1]
open(t + "/tools/dev/zz_touch_probe.sh", "w").write('#!/usr/bin/env bash\n[ "${ZZ_TOUCH:-}" = 1 ] && ln -sfn /nonexistent/zz-touched "$(dirname "$0")/../../.qmlls.ini"\necho "ZZ RESULT PASS"\n')
p = t + "/tools/dev/shell_gates.sh"
s = open(p).read()
u = s.replace("qml  configfile         box   configfile_probe.sh\n", "qml  zz_touch           tree  zz_touch_probe.sh\nqml  configfile         box   configfile_probe.sh\n", 1)
assert u != s
open(p, "w").write(u)
PY
        cout=$( cd "$W/t1" && LINT_BASE="$base" bash tools/dev/shell_gates.sh "$W/canary0" zz_touch 2>&1 ); ccrc=$?
        if [ "$ccrc" != 0 ]; then echo "ARM canary: THE CONTROL IS RED (a gate that touches nothing): $(printf '%s\n' "$cout" | tail -2 | tr '\n' ' ')"; rc=1
        else
            sed -i 's/tree  zz_touch_probe.sh/tree  ZZ_TOUCH=1 zz_touch_probe.sh/' "$W/t1/tools/dev/shell_gates.sh"
            cout=$( cd "$W/t1" && LINT_BASE="$base" bash tools/dev/shell_gates.sh "$W/canary1" zz_touch 2>&1 ); ccrc=$?
            if [ "$ccrc" != 0 ] && printf '%s\n' "$cout" | grep -q "STARTED A QUICKSHELL IN THE TREE"; then
                echo "ARM canary: FAILED AS IT MUST (a tree gate that changed .qmlls.ini: $(printf '%s\n' "$cout" | grep -m1 'started a quickshell in the tree' | cut -c1-110))"
            else echo "ARM canary: DID NOT FAIL AS IT MUST (rc $ccrc): $(printf '%s\n' "$cout" | tail -2 | tr '\n' ' ')"; rc=1; fi
        fi
    }
    # ---- the ARM of the one probe whose runner is kept for it: mockup_promote_probe.sh, through its own ARM=all loop.
    if [ "${ARMS_PROBES:-1}" = 1 ]; then
        # the promote probe's OWN arm for the integration fault it was given a seed for (an owner the shell frame mounts reads as "shared" and no Save of its
        # rows reaches its module): the probe cuts its scratch copy from HEAD, so this one runs from the tree, through the probe's ARM=all loop
        local pout pcrc
        mkdir -p "$W/mpp"
        pout=$(env -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u ARM -u ONLY -u ONLY_ARMS ARM=all ONLY_ARMS=ownedskip SCRATCH="$W/mpp" tools/dev/mockup_promote_probe.sh 2>&1); pcrc=$?
        if [ "$pcrc" = 0 ] && printf '%s\n' "$pout" | grep -q -F "ARM ownedskip: FAIL, as it must -- red: P1"; then
            echo "ARM ownedskip: FAILED AS IT MUST (mockup_promote_probe.sh: $(printf '%s\n' "$pout" | grep -m1 -F 'ARM ownedskip' | sed 's/^ *//' | cut -c1-100))"
        else echo "ARM ownedskip: DID NOT FAIL AS IT MUST (rc $pcrc): $(printf '%s\n' "$pout" | tail -2 | tr '\n' ' ')"; rc=1; fi
    fi
    rm -rf "$W"
    echo "SHELL_GATES_ARMS RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL)"
    return "$rc"
}

# What a smoke run says that is NOT a fault of the file, by the file's own nature: an OFFSCREEN platform has no window masks, no icon theme, no
# Hyprland and no Wayland clipboard; a probe's own negative scenario logs the refusal it is there to cause; a harness whose environment its runner
# provides (a path, a binary) says so when it is started bare. Each pattern is a reason, not a mute: anything else a file says fails the gate.
smoke_filter() {  # reads tools/dev/smoke.sh's output on stdin; prints it, then SMOKE RESULT <name> PASS|FAIL
    python3 -B -c '
import re, sys
name = sys.argv[1]
ALLOW = [
 (r"This plugin does not support setting window masks", "the offscreen platform has no window masks (the gooey engine asks for one)"),
 (r"\$HYPRLAND_INSTANCE_SIGNATURE is unset|Error making request: QLocalSocket::ServerNotFoundError|does not support hyprland_global_shortcuts_v1|GlobalShortcut will not work|Failed to create wl_display", "a probe of the live Hyprland, started with no compositor"),
 (r"No PanelWindow backend loaded", "a layer-shell window needs a compositor (the env tier smokes these)"),
 (r"Could not load icon", "the offscreen run has no icon theme"),
 (r"ClipboardService: the clipboard watcher exited|ClipboardService: PermissionError", "the clipboard probes need a Wayland socket (their runner starts a headless sway)"),
 (r"refused to write to a password prompt", "the probe is the negative scenario: a password prompt must be refused"),
 (r"SupervisedStreamProbe: the child exited", "the probe scripts a child that dies"),
 (r"Process failed to start, likely because the binary could not be found", "a binary its runner names (ST_BIN) or one the probe makes absent on purpose"),
 (r"QFileSystemWatcher::addPath: path is empty", "a path its runner passes (the LLM store) is not set when the file is started bare"),
 (r"QML ProxyFloatingWindow: Setting .(width|height). is deprecated", "a perf driver harness (tools/dev/perf/launcher_scroll.sh), not the shell"),
 # A sandbox does not link the mpd or the PipeWire of the session (see tools/dev/sandbox.sh, the session audio is not linked): a file that reaches
 # for the daemon says so when it is smoked bare. NAMED FILES ONLY -- the same words from any other file are a fault.
 (r"^WARN quickshell\.io\.socket: Socket error for Socket_QML_\d+\(0x[0-9a-f]+\) QLocalSocket::ServerNotFoundError$",
  "the mpd probes connect to the mpd socket of the session and a sandbox has none (SANDBOX_LINK=mpd opts in; the real-daemon gates are mpd_probe_run.sh and playerdata_probe_run.sh LIVE=1, which links it itself; test_playerdata_probe.qml builds no MpdService under LIVE=0 and left this list)",
  ("test_mpd_probe.qml", "test_osd_live_probe.qml")),
 (r"^ERROR quickshell\.service\.pipewire\.loop: Failed to connect pipewire context\. Errno: 112$",
  "the PipeWire probes need a daemon and a sandbox has none (SANDBOX_LINK=pipewire opts in; volume_device_probe.sh makes its own; osd_live_probe.sh reads the session daemon, read only)",
  ("test_vinyl_perf.qml", "test_volume_device_probe.qml", "test_osd_live_probe.qml", "test_audio_facts_probe.qml", "test_audio_live_probe.qml",
   "test_pipewire_nodes_probe.qml",
   # the audio pill probes: audio_glyph_toggle_probe.sh starts its own daemon, audio_glyph_live_probe.sh reads the session daemon (read only)
   "tools/dev/qml/audio_glyph_toggle_probe.qml", "tools/dev/qml/audio_glyph_live_probe.qml",
   # the dictation probe: dictation_probe.sh starts its own private PipeWire (stt_pw_fixture.sh); smoked bare the mic of the service reaches for one
   "tools/dev/qml/dictation_probe.qml",
   # the AirPlay probe: airplay_probe.sh starts its own private PipeWire with the RAOP sinks it needs; smoked bare there is none
   "tools/dev/qml/airplay_probe.qml")),
 (r"^WARN qml: AudioService: pactl subscribe exited \(1\): pa_context_connect\(\) failed: Connection refused; restarting it, backing off to 60 s while it fails$",
  "the live audio probe reads the PipeWire / PulseAudio of the session, read only, and a sandbox links neither (SANDBOX_LINK=pipewire opts in)",
  ("test_audio_live_probe.qml",)),
 (r"^WARN scene: QML Image at @modules/common/components/VinylDisc\.qml\[\d+:\d+\]: Cannot open: file:///tmp/[abc]\.png$",
  "the cover images of the lock media probe are made by its runner (COVERS=<dir>); smoked bare the default /tmp has none",
  ("test_lock_media_probe.qml",)),
 (r"^WARN qml: OSD: the keyboard light.s Fn-key watcher exited \((127|1)\): .*; restarting it, backing off to 60 s while it fails$",
  "the Fn-key watcher of the keyboard light is a child its runner stubs (PROBE_DIR/stubs/idlehelper, KBDSRC_HELPER): smoked bare its path is not set and the child fails to start",
  ("test_osd_brightness_probe.qml", "test_osd_kbd_source_probe.qml")),
 (r"^WARN qml: ClipboardService: clip\.py config failed \(127\)$",
  "the python of the clipboard service probe is the stub of its runner (STUB_DIR/slowpy): smoked bare the path does not exist (the config read the jsonc round added at start-up)",
  ("test_clipboard_service_probe.qml",)),
 (r"^WARN: Cannot create idle monitor as ext-idle-notify-v1 is not supported by the current compositor\.$",
  "the sleep / dim probe runs the real SoftIdle, whose idle monitors need a compositor: its runner drives them by hand (sleep_dim_probe.sh), and smoked bare there is none; the idle-cause and shell-hosted probes build the real idle layer the same way",
  ("tools/dev/qml/sleep_dim_probe.qml", "tools/dev/qml/idle_auto_causes_probe.qml", "tools/dev/qml/shell_hosted_m1_probe.qml")),
 (r"tools/dev/qml/tools/dev/fixtures/stock_notif/cases\.js|^ERROR: Failed to load configuration$|caused by @stock_notif_(probe|sheet)\.qml\[\d+:\d+\]: Script qs:@/qs/tools/dev/fixtures/stock_notif/cases\.js unavailable|caused by @tools/dev/fixtures/stock_notif/cases\.js\[-1:-1\]: File not found",
  "the stocks card harnesses are copied by their runner to its config root (stock_notif_probe.sh notif_run), where tools/dev/fixtures/stock_notif resolves; smoked in place the import cannot, and stock_notif_probe.sh is their gate",
  ("tools/dev/qml/stock_notif_probe.qml", "tools/dev/qml/stock_notif_sheet.qml")),
]
rows, cur, per = [], None, {}
for line in sys.stdin.read().splitlines():
    print(line)
    m = re.match(r"^(\S+\.qml)\s+(clean|\d+ distinct warning)", line)
    if m:
        cur = m.group(1); per[cur] = [] if m.group(2) != "clean" else None
        continue
    m = re.match(r"^\s+(\d+) (.*)$", line)
    if m and cur and per.get(cur) is not None:
        per[cur].append(m.group(2))
bad, allowed, clean = [], 0, 0
if not per:
    print("SMOKE RESULT %s FAIL (smoke printed no file line: nothing was smoked)" % name)
    sys.exit(1)
for f, ws in per.items():
    if ws is None:
        clean += 1; continue
    left = [w for w in ws if not any(re.search(a[0], w) and (len(a) < 3 or f in a[2]) for a in ALLOW)]
    if left:
        bad.append((f, left))
    else:
        allowed += 1
for f, left in bad:
    print("SMOKE BAD %s: %s" % (f, " | ".join(left)[:300]))
print("SMOKE RESULT %s %s (%d files: %d clean, %d with only environment warnings, %d with others)" % (name, "FAIL" if bad else "PASS", len(per), clean, allowed, len(bad)))
sys.exit(1 if bad else 0)
' "$1"
}

# smoke_filter's allowances for the files that reach for a daemon a sandbox does not link are PER FILE: the named file's warning is the environment's, the
# same words from any other file are a fault (a socket that fails in a module is exactly what the smoke is there to find).
gate_smoke_filter() {
    local out rc=0
    out=$(printf '%s\n' \
        "test_mpd_probe.qml                         2 distinct warning(s)   (/x/log)" \
        "    2 WARN quickshell.io.socket: Socket error for Socket_QML_5(0x7f94f9d52180) QLocalSocket::ServerNotFoundError" \
        "test_vinyl_perf.qml                        1 distinct warning(s)   (/x/log)" \
        "    1 ERROR quickshell.service.pipewire.loop: Failed to connect pipewire context. Errno: 112" \
        "test_other.qml                             1 distinct warning(s)   (/x/log)" \
        "    1 WARN quickshell.io.socket: Socket error for Socket_QML_5(0x7f94f9d52180) QLocalSocket::ServerNotFoundError" \
        "test_vinyl_other.qml                       1 distinct warning(s)   (/x/log)" \
        "    1 ERROR quickshell.service.pipewire.loop: Failed to connect pipewire context. Errno: 112" \
        "test_osd_brightness_probe.qml              1 distinct warning(s)   (/x/log)" \
        "    1 WARN qml: OSD: the keyboard light's Fn-key watcher exited (127): setpriv: failed to execute null/stubs/idlehelper: No such file or directory; restarting it, backing off to 60 s while it fails" \
        "test_osd_other.qml                         1 distinct warning(s)   (/x/log)" \
        "    1 WARN qml: OSD: the keyboard light's Fn-key watcher exited (127): setpriv: failed to execute null/stubs/idlehelper: No such file or directory; restarting it, backing off to 60 s while it fails" \
        "test_clean.qml                             clean" | smoke_filter CASES 2>&1)
    printf '%s\n' "$out" | grep -q "^SMOKE BAD test_other.qml: " || { echo "SMOKE_FILTER FAIL: the mpd socket warning of an unnamed file was let through"; rc=1; }
    printf '%s\n' "$out" | grep -q "^SMOKE BAD test_vinyl_other.qml: " || { echo "SMOKE_FILTER FAIL: the PipeWire warning of an unnamed file was let through"; rc=1; }
    printf '%s\n' "$out" | grep -q "^SMOKE BAD test_osd_other.qml: " || { echo "SMOKE_FILTER FAIL: the Fn-key watcher warning of an unnamed file was let through"; rc=1; }
    printf '%s\n' "$out" | grep -q "^SMOKE BAD test_mpd_probe.qml\|^SMOKE BAD test_vinyl_perf.qml\|^SMOKE BAD test_osd_brightness_probe.qml" && { echo "SMOKE_FILTER FAIL: a named file's environment warning was flagged"; rc=1; }
    printf '%s\n' "$out" | grep -q "(7 files: 1 clean, 3 with only environment warnings, 3 with others)" || { echo "SMOKE_FILTER FAIL: the tally is not 1 clean / 3 environment / 3 others: $(printf '%s\n' "$out" | tail -1)"; rc=1; }
    echo "SMOKE_FILTER RESULT $([ "$rc" = 0 ] && echo PASS || echo FAIL) (per-file allowances: three named files allowed, the same words from three others flagged)"
    return "$rc"
}

# tools/dev/smoke.sh over every mockup and harness (tools/dev/smoke.sh --all's files) that can load OFFSCREEN. A file that holds a PanelWindow cannot ("No PanelWindow backend loaded":
# a layer-shell window needs a compositor): those run in the nested Hyprland (gate_smoke_panelwindow, env tier).
smoke_files() { ( shopt -s nullglob; echo mockups/*.qml tools/dev/qml/*.qml test_*.qml ); }   # tools/dev/smoke.sh --all's files

gate_smoke_all() {
    local files n sb="/tmp/lares-sandbox-shellgates-sm$$"
    files=$(grep -L 'PanelWindow' $(smoke_files) | tr '\n' ' ')
    n=$(echo "$files" | wc -w)
    echo "smoke: $n files, ${SMOKE_SECS}s each ($(grep -l 'PanelWindow' $(smoke_files) | wc -l) files hold a PanelWindow and need a compositor: gate smoke_panelwindow)"
    # shellcheck disable=SC2086
    SANDBOX="$sb" tools/dev/sandbox.sh -u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi SECS="$SMOKE_SECS" \
        bash tools/dev/smoke.sh $files 2>&1 | smoke_filter SMOKE_ALL
    local rc=${PIPESTATUS[1]}
    rm -rf "$sb" "$sb.lrrt"
    return $rc
}

# The same smoke for the files that hold a PanelWindow, as clients of tools/dev/lock_env.sh's nested Hyprland (smoke.sh lets a lock-holding
# file load there: LOCK_ENV_DIR). From a sandbox copy: a quickshell rewrites .qmlls.ini where it starts.
gate_smoke_panelwindow() {
    local E="$ROOT/tools/dev/lock_env.sh" sb="/tmp/lares-sandbox-shellgates-pw$$" files rc
    export LOCK_ENV=vspw
    files=$(grep -l 'PanelWindow' $(smoke_files) | tr '\n' ' ')
    SANDBOX="$sb" tools/dev/sandbox.sh > /dev/null || { echo "SMOKE_PANELWINDOW RESULT FAIL (the sandbox did not sync)"; return 1; }
    "$E" down > /dev/null 2>&1
    OUTPUTS=2 "$E" up > /dev/null || { echo "SMOKE_PANELWINDOW RESULT FAIL (the nested Hyprland did not come up)"; "$E" down > /dev/null 2>&1; rm -rf "$sb" "$sb.lrrt"; return 1; }
    echo "smoke in the nested Hyprland: $(echo "$files" | wc -w) files that hold a PanelWindow, ${SMOKE_SECS}s each"
    # shellcheck disable=SC2086
    "$E" run bash -c 'cd "$1" && shift && SECS="$1" && shift && exec bash tools/dev/smoke.sh "$@"' _ "$sb" "$SMOKE_SECS" $files 2>&1 | smoke_filter SMOKE_PANELWINDOW
    rc=${PIPESTATUS[1]}
    "$E" down > /dev/null 2>&1
    rm -rf "$sb" "$sb.lrrt"
    return $rc
}

if [ "$FNMODE" = 1 ]; then shift; "$@"; exit $?; fi

# ---------------------------------------------------------------------------------------------------------------------
# the mockups' panel self-tests, one gate per mockup (generated: a new mockup is covered the day it is written)
gen_panels() {
    local m n
    for m in $(grep -l 'MockupWindow' mockups/*.qml); do
        n=$(basename "$m" .qml)
        echo "qml  panel_$n box %tmo=240 mockup_panel_test.sh $m"
    done
}

table_for() {  # tier -> its rows
    case "$1" in
        quick) printf '%s\n' "$TABLE_QUICK" ;;
        qml) printf '%s\n' "$TABLE_QML"; gen_panels ;;
        env) printf '%s\n' "$TABLE_ENV" ;;
        exclusive) printf '%s\n' "$TABLE_EXCL" ;;
    esac
}
# Every row's tier column names the table it sits in. table_for hands a tier its own table whatever the column says, so a qml row typed into
# the env table ran in the env pass and `--tier qml <name>` called it unknown (seven rows of the feedback round, found 2026-11-02).
tables_agree() {
    local t tier key bad=""
    for t in quick qml env exclusive; do
        while read -r tier key _; do
            [ -n "${key:-}" ] && [ "$tier" != "$t" ] && bad="$bad $key($tier in $t)"
        done < <(table_for "$t")
    done
    [ -z "$bad" ] || { echo "SHELL_GATES RESULT FAIL (rows in another tier's table:$bad)"; exit 1; }
}
tables_agree
tiers_of() { case "$TIER" in all) [ ${#NAMES[@]} -gt 0 ] && echo "quick qml env exclusive" || echo "quick qml env" ;; *) echo "$TIER" ;; esac; }

# ---------------------------------------------------------------------------------------------------------------------
# --list
if [ "$LIST" = 1 ]; then
    for t in $( [ "$TIER" = all ] && echo "quick qml env exclusive" || echo "$TIER" ); do
        n=0
        while read -r tier key kind rest; do
            [ -n "${key:-}" ] || continue
            n=$((n + 1))
            printf '%-9s %-26s %-5s %s\n' "$tier" "$key" "$kind" "$rest"
        done < <(table_for "$t")
        echo "-- $t: $n gates"
    done
    exit 0
fi

# ---------------------------------------------------------------------------------------------------------------------
# running a gate
CUR_UNIT=""
cleanup() {
    [ -n "$CUR_UNIT" ] && systemctl --user stop "$CUR_UNIT.scope" > /dev/null 2>&1
    case "$SB" in /tmp/lares-sandbox-shellgates-*) rm -rf "$SB" "$SB.lrrt" "$SB-out" "$SBT" "$SBT.lrrt" "$SB-nl" "$SB-nl.lrrt" ;; esac    # only the copies this run named ($SB-out: shell_hosted_m3's default output dir, ROOT-out; six of them sat in /tmp)
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# the lock_env sessions in /tmp/lrlk-* with a live process in them: another user of the nested compositor
lockenv_busy() {  # names (comma list) -> 0 when one is up
    local names=$1 n p
    for n in ${names//,/ }; do
        [ -d "/tmp/lrlk-$n" ] || continue
        for p in /proc/[0-9]*; do
            [ -O "$p" ] || continue
            { tr '\0' '\n' < "$p/environ"; } 2> /dev/null | grep -qx "LOCK_ENV_DIR=/tmp/lrlk-$n" && return 0
        done
    done
    return 1
}

ql_state() {   # the tree's .qmlls.ini as it is now: its target and its own mtime (a quickshell started in the tree makes the link again)
    printf '%s|%s' "$(readlink "$ROOT/.qmlls.ini" 2> /dev/null)" "$(stat -c %Y "$ROOT/.qmlls.ini" 2> /dev/null)"
}

known_reason() {  # gate -> its reason when listed as a known red, else nothing
    [ -f "$KNOWN_RED" ] || return 0
    awk -v k="$1" '$1 == k { $1 = ""; sub(/^ +/, ""); print; exit }' "$KNOWN_RED"
}

why_of() {  # log -> the lines that say why a gate is red
    rl_clean "$1" | grep -a -E "FAIL|no result|ERROR|^\s*LOG |WARN|Cannot assign|Unable to assign|Binding loop|non-existent|TypeError|ReferenceError|TIMEOUT|is not a type|not installed|not found|BAD |refus" \
        | grep -a -v -E "quickshell.tooling|WAYLAND_DISPLAY|QT_QPA_PLATFORM to |WARNING ---|actually running wayland|RESULT PASS|ARMS|ARM " \
        | sed 's/^ *DEBUG qml: //; s/^ *//' | cut -c1-230 | awk '!seen[$0]++' | head -8
}

# one_run <tier> <key> <kind> <n> <words...>: the log in <out>/<tier>/<key>/run<N>.log; sets LAST_RC, LAST_SECS, LAST_GREEN, LAST_LINES, LAST_NOTE
one_run() {
    local tier=$1 key=$2 kind=$3 n=$4; shift 4
    LAST_CUT=0
    local d="$OUT/$tier/$key" unit start w tmo=$TIMEOUT vkind=std lockenvs="" keep=0 runner="" need="" rt=""
    local envs=() unsets=() args=()
    rm -rf "$d/out" "$d/cfg" "$d/state" "$d/cache" "$d/pw" "$d/llm" "$d/si"
    mkdir -p "$d/out" "$d/cfg/theme" "$d/state" "$d/cache"
    printf '{"theme":"eva","mode":"light"}\n' > "$d/cfg/theme/state.json"
    # The gate's SCRATCH (and @OUT) is a SHORT, REAL directory (moved to <out>/out when the gate ends): a socket path ends at 108 bytes, and a gate that
    # makes a socket under its scratch (the clipboard probes' headless sway) failed "Unable to open wayland socket" under a long output dir. (Not a
    # symlink to the long one: launcher_service_probe compares the realpaths of the links it makes, and eight of its checks read the two prefixes as two places.)
    local sc="/tmp/lrg-$$-${key:0:20}"
    rm -rf "$sc"; mkdir -p "$sc"
    for w in "$@"; do
        w=${w//@SMOKE_SECS/$SMOKE_SECS}
        if [ -z "$runner" ]; then
            case "$w" in
                %tmo=*) tmo=${w#%tmo=} ;;
                %render) vkind=render ;;
                %smoke) vkind=smoke ;;
                %rc) vkind=rc ;;
                %meta) vkind=meta ;;
                %need=*) need=${w#%need=} ;;
                %keep) keep=1 ;;
                %lockenv=*) lockenvs=${w#%lockenv=} ;;
                UNSET=*) unsets+=(-u "${w#UNSET=}") ;;
                *=*) envs+=("${w//\~/ }") ;;        # a `~` in a value is a blank (the words are split on blanks: ONLY=layer~mask~ipc)
                *) runner=$w ;;
            esac
        else
            args+=("${w//@OUT/$sc}")
        fi
    done
    # a runner of tools/dev/ missing from this tree (a baseline of a revision before the kit moved there) is skipped, not red
    if [ "$kind" = box ] || [ "$kind" = boxh ] || [ "$kind" = tree ] || [ "$kind" = env ]; then
        if [ ! -f "tools/dev/$runner" ]; then LAST_RC=0; LAST_SECS=0; LAST_GREEN=1; LAST_LINES="skip (no tools/dev/$runner in this tree)"; LAST_NOTE=""; rm -rf "$sc"; return; fi
    fi
    local log="$d/run$n.log"
    # env's options (-u) come BEFORE its first NAME=VALUE: after one, a `-u` is taken for the command
    local base_u=(-u WAYLAND_DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE -u ARM -u ONLY -u ONLY_ARMS -u MODE -u SMOKE -u PHASES -u TIMEOUT -u RETRY -u KEEP -u BEFORE -u SECS -u TRIAL)
    local base_s=("XDG_CONFIG_HOME=$d/cfg" "XDG_STATE_HOME=$d/state" "XDG_CACHE_HOME=$d/cache" "SCRATCH=$sc" "QT_QPA_PLATFORMTHEME=")
    # A gate that starts a quickshell itself (kind tree / run / fn) gets a runtime dir of its own: quickshell keeps a directory per
    # instance under $XDG_RUNTIME_DIR/quickshell/by-id and never removes it (a runner without one once left 1086 dead dirs there). The
    # stand-in links every entry of the real one but quickshell's tree (the bus, pipewire, ... still answer) and goes with the gate.
    rt=""
    if { [ "$kind" = tree ] || [ "$kind" = run ] || [ "$kind" = fn ]; } && [ "$DRY" != 1 ]; then
        rt=$(mktemp -d /tmp/lrrt-sg.XXXXXX) && chmod 700 "$rt"
        ( shopt -s dotglob nullglob
          for e in "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/*; do b=${e##*/}; [ "$b" = quickshell ] || ln -s "$e" "$rt/$b"; done )
        base_s+=("XDG_RUNTIME_DIR=$rt")
    fi
    local cmd=()
    case "$kind" in
        box|boxh)
            if [ "${ARM:-}" = break ] && [ "$key" = configfile ]; then
                cmd=("$ROOT/tools/dev/sandbox.sh" -u SANDBOX "${base_u[@]}" "${unsets[@]}" "${base_s[@]}" QT_QPA_PLATFORM=offscreen "${envs[@]}" \
                     bash -c 'printf "\n}}} broken on purpose by ARM=break\n" >> tools/dev/qml/configfile_probe.qml; exec bash "$@"' gate "tools/dev/$runner" "${args[@]}")
            else
                cmd=("$ROOT/tools/dev/sandbox.sh" -u SANDBOX "${base_u[@]}" "${unsets[@]}" "${base_s[@]}" QT_QPA_PLATFORM=offscreen "${envs[@]}" bash "tools/dev/$runner" "${args[@]}")
            fi ;;
        tree)
            cmd=(env -u SANDBOX "${base_u[@]}" "${unsets[@]}" "${base_s[@]}" QT_QPA_PLATFORM=offscreen "SANDBOX=$SBT" "${envs[@]}" bash "tools/dev/$runner" "${args[@]}") ;;
        env)
            cmd=(env -u SANDBOX "${base_u[@]}" "${unsets[@]}" "${base_s[@]}" "SANDBOX=$SBT" "${envs[@]}" bash "tools/dev/$runner" "${args[@]}") ;;
        run)
            cmd=(env "${base_u[@]}" "${unsets[@]}" "${base_s[@]}" "${envs[@]}" "$runner" "${args[@]}") ;;
        fn)
            cmd=(env -u SANDBOX "${base_u[@]}" "${unsets[@]}" "${base_s[@]}" "${envs[@]}" bash "$ROOT/tools/dev/shell_gates.sh" --fn "$runner" "${args[@]}") ;;
        *) echo "unknown kind $kind for $key"; LAST_RC=2; LAST_SECS=0; LAST_GREEN=0; LAST_LINES="(bad table row)"; LAST_NOTE=""; return ;;
    esac
    if [ "$DRY" = 1 ]; then
        if [ "$kind" = fn ]; then echo "  [fn] $runner ${args[*]:-}"; else printf '  [%s] (cd %s && %s)\n' "$kind" "$ROOT" "${cmd[*]}"; fi
        LAST_RC=0; LAST_SECS=0; LAST_GREEN=1; LAST_LINES="(dry)"; LAST_NOTE=""; rm -rf "$sc"; return
    fi
    [ -n "$lockenvs" ] && { [ "$kind" = env ] || [ "$kind" = fn ]; } && {
        local waited=0
        while lockenv_busy "$lockenvs" && [ "$waited" -lt 600 ]; do sleep 10; waited=$((waited + 10)); done
        [ "$waited" -gt 0 ] && echo "   (waited ${waited}s for the nested session $lockenvs to be free)"
    }
    if [ "$kind" = boxh ]; then
        # the gates that drive helpers/ (update-run.sh, sudo-askpass) want it BESIDE them, in the copy: a sandbox leaves helpers/ out and
        # its rsync does not delete what it excludes, so the helpers go in first (without the Rust crates' target/ dirs)
        mkdir -p "$SB/helpers" && rsync -a --exclude target/ "$ROOT/helpers/" "$SB/helpers/"
    fi
    local wt_before wt_after ql_before ql_after qmlls_touched=0
    wt_before=$(git status --porcelain=v1 2> /dev/null | grep -v ' \.qmlls\.ini$' | md5sum)
    ql_before=$(ql_state)
    unit="shellgate-$key-$$-$n"
    CUR_UNIT=$unit
    LAST_CUT=0
    if [ "$UNTIL_EPOCH" -gt 0 ]; then
        local left=$((UNTIL_EPOCH - $(date +%s)))
        if [ "$left" -lt "$tmo" ]; then tmo=$left; LAST_CUT=1; fi
    fi
    start=$SECONDS
    (
        if [ "$kind" = box ] || [ "$kind" = boxh ]; then export SANDBOX="$SB"; fi
        systemd-run --user --scope --quiet --collect -u "$unit" --expand-environment=no -- "${cmd[@]}" < /dev/null > "$log" 2>&1
        echo "rc=$?" > "$d/rc$n"
    ) &
    local pid=$!
    while kill -0 "$pid" 2> /dev/null && [ $((SECONDS - start)) -lt "$tmo" ]; do sleep 1; done
    if kill -0 "$pid" 2> /dev/null; then
        systemctl --user stop "$unit.scope" 2> /dev/null
        echo "TIMEOUT after ${tmo}s (the gate's scope was stopped)" >> "$log"
        echo "rc=124" > "$d/rc$n"
    fi
    wait "$pid" 2> /dev/null
    if [ "$LAST_CUT" = 1 ] && [ "$(sed 's/rc=//' "$d/rc$n" 2> /dev/null)" = 124 ]; then
        echo "CUT by the deadline UNTIL=$UNTIL (the gate's scope was stopped; not a verdict)" >> "$log"
    else
        LAST_CUT=0
    fi
    # what the gate left running: given a moment (a sandbox watcher ends itself), listed, then stopped
    local cg procs i
    cg=$(systemctl --user show "$unit.scope" -p ControlGroup --value 2> /dev/null)
    if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ]; then
        for i in 1 2 3 4 5 6; do
            procs=$(cat "/sys/fs/cgroup$cg/cgroup.procs" 2> /dev/null)
            [ -z "$procs" ] && break
            sleep 0.5
        done
        if [ -n "$procs" ]; then
            { echo "LEFTOVER after the gate (stopped):"; ps -o pid,etimes,comm,args -p "$(echo "$procs" | paste -sd, -)" 2> /dev/null | cut -c1-180; } >> "$log"
            LAST_NOTE=" (left processes running)"
        fi
    fi
    systemctl --user stop "$unit.scope" > /dev/null 2>&1
    CUR_UNIT=""
    [ -n "$rt" ] && rm -rf "$rt"
    LAST_SECS=$((SECONDS - start))
    LAST_RC=$(sed 's/rc=//' "$d/rc$n" 2> /dev/null || echo "?")
    LAST_NOTE="${LAST_NOTE:-}"
    wt_after=$(git status --porcelain=v1 2> /dev/null | grep -v ' \.qmlls\.ini$' | md5sum)
    if [ "$wt_before" != "$wt_after" ]; then
        LAST_NOTE="$LAST_NOTE (wrote in the worktree: $(git status --porcelain=v1 | grep -v ' \.qmlls\.ini$' | head -3 | sed 's/^...//' | tr '\n' ' '))"
        { echo "WORKTREE TOUCHED by the gate:"; git status --porcelain=v1 | grep -v ' \.qmlls\.ini$'; } >> "$log"
    fi
    # A gate run from the TREE that started a quickshell there made its .qmlls.ini again (tree_launch's dynamic half): red, whatever it said.
    ql_after=$(ql_state)
    if [ "$ql_before" != "$ql_after" ] && [ "$kind" != box ] && [ "$kind" != boxh ]; then
        qmlls_touched=1
        LAST_NOTE="$LAST_NOTE (STARTED A QUICKSHELL IN THE TREE: .qmlls.ini was '${ql_before%|*}', is '${ql_after%|*}')"
        { echo "QMLLS TOUCHED by the gate: a quickshell was started in $ROOT"; echo "  before: $ql_before"; echo "  after:  $ql_after"; } >> "$log"
    fi
    grade "$log" "$LAST_RC" "$vkind" "$sc" "$need"
    LAST_GREEN=$G_GREEN
    LAST_LINES=$G_LINES
    [ "$qmlls_touched" = 1 ] && { LAST_GREEN=0; LAST_LINES="started a quickshell in the tree (.qmlls.ini changed): $LAST_LINES"; }
    [ "$LAST_CUT" = 1 ] && { LAST_GREEN=0; LAST_LINES="NOT RUN (cut by the deadline $UNTIL)"; }
    rm -rf "$d/out"; mv "$sc" "$d/out"       # the gate's scratch joins its other files (paths in its log name the short one)
    # what a gate leaves: the sandboxes it made, the bulky grabs (after the grading: a render gate is judged by its PNGs)
    find "$d" -maxdepth 6 \( -name 'lares-sandbox*' -o -name '*.lrrt' \) -prune -exec rm -rf {} + 2> /dev/null
    if [ -z "${KEEP:-}" ] && [ "$keep" = 0 ]; then
        find "$d" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.mp4' \) -size +300k -delete 2> /dev/null
        # a green gate's working files go too (the first qml pass left 3.6 GB in a tmpfs with a per-user quota): its log and verdict stay; a red one keeps all
        [ "$LAST_GREEN" = 1 ] && rm -rf "$d/out" "$d/cache" "$d/state" "$d/cfg"
    fi
}

# ---------------------------------------------------------------------------------------------------------------------
# the run
want() {  # name -> 0 when no gate names were given, or this one is among them
    [ ${#NAMES[@]} -eq 0 ] && return 0
    local g; for g in "${NAMES[@]}"; do [ "$g" = "$1" ] && return 0; done
    return 1
}
SUMALL="$OUT/summary.txt"
[ "$DRY" = 1 ] || : > "$SUMALL"
echo "== shell_gates: $(git rev-parse --short HEAD 2> /dev/null || echo '?') ($(git log -1 --format=%s 2> /dev/null | cut -c1-60)), $(quickshell --version 2> /dev/null | sed "s/ (revision.*//"), tier $TIER, TIMEOUT ${TIMEOUT}s, RETRY $RETRY" | tee -a "$SUMALL"
RED=0; TOTAL=0; REDNAMES=""; KNOWN=0; KNOWNNAMES=""; NOTRUN=0; NOTRUNNAMES=""
declare -A NSEEN
for t in $(tiers_of); do
    SUMT="$OUT/summary_$t.txt"; [ "$DRY" = 1 ] || : > "$SUMT"
    T0=$SECONDS; nt=0; rt=0
    echo "== tier $t" | tee -a "$SUMALL" "$SUMT" > /dev/null
    echo "== tier $t"
    while read -r tier key kind rest; do
        [ -n "${key:-}" ] || continue
        want "$key" || continue
        NSEEN[$key]=1
        nt=$((nt + 1)); TOTAL=$((TOTAL + 1))
        LAST_NOTE=""
        gd="$OUT/$tier/$key"
        if [ "$RESUME" = 1 ] && [ "$DRY" != 1 ] && [ -f "$gd/done.state" ]; then
            st=$(cat "$gd/done.state"); cat "$gd/done.txt" | tee -a "$SUMALL" "$SUMT"
            case "$st" in red) RED=$((RED + 1)); rt=$((rt + 1)); REDNAMES="$REDNAMES $key" ;; known) KNOWN=$((KNOWN + 1)); KNOWNNAMES="$KNOWNNAMES $key" ;; esac
            continue
        fi
        if [ "$UNTIL_EPOCH" -gt 0 ] && [ "$(date +%s)" -ge "$UNTIL_EPOCH" ] && [ "$DRY" != 1 ]; then
            echo "== $key NOT RUN (the deadline $UNTIL came)" | tee -a "$SUMALL" "$SUMT"
            NOTRUN=$((NOTRUN + 1)); NOTRUNNAMES="$NOTRUNNAMES $key"
            continue
        fi
        # shellcheck disable=SC2086
        one_run "$tier" "$key" "$kind" 1 $rest
        status=""; first=""
        if [ "$LAST_GREEN" = 0 ] && [ "$RETRY" = 1 ] && [ "$DRY" != 1 ] && [ "$LAST_CUT" = 0 ]; then
            first="$LAST_LINES (rc $LAST_RC, ${LAST_SECS}s)"; secs1=$LAST_SECS
            # shellcheck disable=SC2086
            one_run "$tier" "$key" "$kind" 2 $rest
            if [ "$LAST_GREEN" = 1 ]; then status=" FLAKY (run 1: $first)"; else status=" RED x2"; fi
            LAST_SECS=$((LAST_SECS + secs1))
        fi
        line="== $key rc=$LAST_RC ${LAST_SECS}s :: $LAST_LINES$LAST_NOTE$status"
        known=$(known_reason "$key")
        state=green
        if [ "$LAST_CUT" = 1 ]; then
            line="== $key rc=$LAST_RC ${LAST_SECS}s :: $LAST_LINES"
            NOTRUN=$((NOTRUN + 1)); NOTRUNNAMES="$NOTRUNNAMES $key"; state=notrun
        elif [ "$LAST_GREEN" = 0 ] && [ -n "$known" ]; then
            state=known
            line="$line  <-- RED (known: $known)"
            KNOWN=$((KNOWN + 1)); KNOWNNAMES="$KNOWNNAMES $key"
        elif [ "$LAST_GREEN" = 0 ]; then
            state=red
            line="$line  <-- RED"
            RED=$((RED + 1)); rt=$((rt + 1)); REDNAMES="$REDNAMES $key"
        elif [ -n "$known" ]; then
            line="$line  (listed as a known red but GREEN: take it out of $(basename "$KNOWN_RED"))"
        fi
        if [ "$DRY" != 1 ]; then
            {
                echo "$line"
                if [ "$LAST_GREEN" = 0 ] && [ "$state" != notrun ]; then
                    n=1; [ "$RETRY" = 1 ] && n=2
                    why_of "$OUT/$tier/$key/run$n.log" | sed 's/^/   | /'
                    echo "   | log: $OUT/$tier/$key/run$n.log"
                fi
            } > "$gd/done.txt"
            tee -a "$SUMALL" "$SUMT" < "$gd/done.txt"
            [ "$state" = notrun ] && rm -f "$gd/done.txt" || echo "$state" > "$gd/done.state"
        fi
    done < <(table_for "$t")
    echo "== tier $t: $nt gates, $rt red, $((SECONDS - T0))s wall" | { [ "$DRY" = 1 ] && cat || tee -a "$SUMALL" "$SUMT"; }
done
# a gate name that matched nothing
for g in "${NAMES[@]:-}"; do
    [ -n "$g" ] || continue
    [ -n "${NSEEN[$g]:-}" ] || { echo "unknown gate '$g' (tools/dev/shell_gates.sh --list)"; RED=$((RED + 1)); }
done
if [ "$TIER" = all ] && [ ${#NAMES[@]} -eq 0 ]; then
    echo "== NOT RUN (machine-exclusive; the orchestrator runs them alone with --tier exclusive): $(table_for exclusive | awk 'NF { printf "%s ", $2 }')" | { [ "$DRY" = 1 ] && cat || tee -a "$SUMALL"; }
fi
if [ "${ARM:-}" = break ]; then
    case "$REDNAMES" in
        *" configfile"*) echo "$NAME ARM break: configfile went RED with its QML broken in the sandbox copy, as it must" | tee -a "$SUMALL"; exit 0 ;;
        *) echo "$NAME ARM break: the broken gate did NOT go red -- the battery proves nothing" | tee -a "$SUMALL"; exit 1 ;;
    esac
fi
if [ "$NOTRUN" -gt 0 ]; then
    echo "$NAME NOT FINISHED ($NOTRUN of $TOTAL gates not run -- the deadline $UNTIL:$NOTRUNNAMES; $RED red:$REDNAMES)" | { [ "$DRY" = 1 ] && cat || tee -a "$SUMALL"; }
    [ "$RED" = 0 ] && exit 3 || exit 1
fi
if [ "$RED" = 0 ]; then
    echo "$NAME RESULT PASS ($TOTAL gates, tier $TIER$([ "$KNOWN" -gt 0 ] && echo ", $KNOWN known red:$KNOWNNAMES"))" | { [ "$DRY" = 1 ] && cat || tee -a "$SUMALL"; }
    exit 0
fi
echo "$NAME RESULT FAIL ($RED of $TOTAL not green:$REDNAMES$([ "$KNOWN" -gt 0 ] && echo "; $KNOWN known red:$KNOWNNAMES"))" | { [ "$DRY" = 1 ] && cat || tee -a "$SUMALL"; }
exit 1
}
exit $?
