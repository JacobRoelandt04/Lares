#!/usr/bin/env bash
# Every runner that sources tools/dev/result_lib.sh, handed a QML that does not
# load: its verdict (the last `<NAME> RESULT ...` line it prints; bookkeeping
# may follow it) must be `<NAME> RESULT FAIL (no result: <log>)` and it must exit
# non-zero, and it must not count an ARM whose armed copy never loaded as an
# arm that failed. The reported fault (R2B-CLOCK2, question 2): with another
# stream's file half-edited, notifications_ui_probe.sh printed nothing and
# exited 0.
#
#   tools/dev/runner_noload_check.sh           expect NOLOAD RESULT PASS (last line)
#   ONLY="ui swipe" tools/dev/...          a subset (the keys below)
#   ARM=silent tools/dev/...               result_lib's no-result verdict put back
#                                          to the old one (prints nothing, returns
#                                          0) in each copy: every runner must be
#                                          caught; NOLOAD ARMS PASS when each was
#   ARM=armload tools/dev/...              in the ARM pass only, result_lib cannot
#                                          tell a load failure (rl_isnoresult never
#                                          matches, rl_has always does): every
#                                          runner's arm pass must be caught
#
# How, per runner, twice: a fresh sync of one sandbox (tools/dev/sandbox.sh,
# SANDBOX under SCRATCH), a syntax error appended to the SANDBOX COPY of a QML
# that runner loads, and the runner started from INSIDE that copy -- a runner
# re-execs into a sandbox only when it is not already in one (the probe_lib
# runners find no .git there), so the broken copy is what it runs on.
#   clean  the runner's clean mode, the run a half-edited file breaks: its last
#          verdict line is the no-result verdict, its exit status non-zero, and the log
#          that line names names the broken file (the run failed on the copy,
#          not on something else);
#   arm    one of its arms (through the ARM=all loop where the runner has one,
#          ONLY_ARMS narrowing it to that arm): the arm is reported as not
#          loaded, and the run exits non-zero. A runner with no arms (`-`) has
#          no arm pass, and ARM=armload does not count it.
# Run it from the TREE, not from inside a sandbox copy: a copy has no .git, so a runner that takes a
# base revision reads MOCKUP_REPO, which names this tree here. (To give its quickshells a private
# runtime dir, start it as the command of an offscreen sandbox call that cds
# back: tools/dev/sandbox.sh's own runtime-dir rule then covers every run.)
# Each runner writes under its own SCRATCH/<key>. A load failure exits
# quickshell at once (255), so a runner takes seconds (the mockup's smoke waits
# out its SECS, 12 s).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="${SCRATCH:-$HOME/.cache/claude-notifications/R2C-FIX}/noload"
S="$SCRATCH/sandbox"
mkdir -p "$SCRATCH"

# key  runner[,arg...]  NAME  a QML it loads (statically: a Loader's failure would
# not stop the load)  an arm (all:<arm> = through the runner's ARM=all loop; - =
# the runner has none: the stage-0 runners s0lua .. s0crash run ONE mode per
# call -- ARM=<name> is that mode -- and a probe that does not load ends in the
# same no-result verdict whatever the arm, which the clean pass proves; there is
# no "armed copy did not load" report to ask them for). In an argument @SC is
# the runner's own scratch dir.
TABLE="
mockup   notifications_mockup.sh            NOTIF-MOCKUP modules/notifications/data/NotificationService.qml  -
mockupgrab notifications_mockup.sh,grab,@SC/grab.png NOTIF-MOCKUP modules/notifications/data/NotificationService.qml -
wmockup  wiki_mockup.sh                     WIKI-MOCKUP modules/wiki/data/WikiMock.qml                   -
wmockupgrab wiki_mockup.sh,grab,@SC/grab.png WIKI-MOCKUP modules/wiki/data/WikiMock.qml                  -
wikiveil wiki_veil_probe.sh                 WIKI_VEIL modules/wiki/WikiVeil.qml                          all:nohold
wikiveilsheet wiki_veil_sheet.sh,@SC/out    WIKI_VEIL_SHEET modules/wiki/WikiVeil.qml                    -
wikiveilcost wiki_veil_cost.sh,5            WIKI_VEIL_COST modules/shell/ShellServices.qml               -
omockup  osd_mockup.sh                      OSD-MOCKUP modules/osd/OsdOwner.qml                          -
omockupgrab osd_mockup.sh,grab,@SC/grab.png  OSD-MOCKUP modules/osd/OsdOwner.qml                          -
m2hosted shell_hosted_m2_probe.sh           SHELL_HOSTED_M2 tools/dev/qml/shell_hosted_m2_probe.qml              all:twostores
sdata    silicon_service_probe.sh           SILICON-SERVICE modules/silicon/data/SiliconService.qml        all:nosettle
shm      shell_hosted_m1_probe.sh           SHELL_HOSTED_M1 tools/dev/qml/shell_hosted_m1_probe.qml              all:selfbuild
shmods   shell_modules_probe.sh             SHELL_MODULES tools/dev/qml/shell_modules_probe.qml                  stillbuilt
sspstart stream_start_probe.sh              STREAM_START tools/dev/qml/stream_start_probe.qml                    norecall
shp      shell_probe.sh                     SHELL_PROBE modules/shell/ShellFrame.qml                    all:slimmask
scompile shader_compile_probe.sh,@SC/out  SHADER_COMPILE tools/dev/qml/shader_compile_probe.qml                -
cfgfile  configfile_probe.sh                CONFIGFILE tools/dev/qml/configfile_probe.qml                         nojsonc
sureopen su_reopen_probe.sh                SUREOPEN tools/dev/qml/su_reopen_probe.qml                           noseat
suurl    su_url_close_probe.sh             SUURLCLOSE tools/dev/qml/su_url_close_probe.qml                      noclose
idlemode idle_mode_probe.sh               IDLE_MODE tools/dev/qml/idle_mode_probe.qml                           oldoff
ddcdim   ddc_dim_probe.sh                  DDCDIM tools/dev/qml/ddc_dim_probe.qml                                nofresh
sideswp  side_swipe_probe.sh               SIDESWIPE tools/dev/qml/side_swipe_probe.qml                          pixels
pcglyph  panorama_castglyph_probe.sh      PANORAMA_CASTGLYPH tools/dev/qml/panorama_castglyph_probe.qml          cut
sleepdim sleep_dim_probe.sh               SLEEP_DIM tools/dev/qml/sleep_dim_probe.qml                           oldsaved
balls    balls_probe.sh,slider              BALLS tools/dev/qml/balls_probe.qml                                  nopaint
stkhead  stocks_header_probe.sh             STOCKSHEADER tools/dev/qml/stocks_header_probe.qml                  narrowdate
osdlay   osd_layout_probe.sh                OSDLAYOUT tools/dev/qml/osd_layout_probe.qml                        followmain
batnote  battery_notifier_probe.sh          BATTERY-NOTIFIER tools/dev/qml/battery_notifier_probe.qml           ignorestall
simux    silicon_mux_notice_probe.sh        SILICON-MUX-NOTICE mockups/silicon.qml                               silent
smwatch  silicon_mux_watcher_probe.sh       SILICON-MUX-WATCHER tools/dev/qml/silicon_mux_watcher_probe.qml     nolock
sessvc   session_service_probe.sh           SESSION_SERVICE tools/dev/qml/session_service_probe.qml             nolock
sesstoast session_toast_probe.sh             SESSION_TOAST tools/dev/qml/session_toast_probe.qml                 noconfirm
sglyph   silicon_glyph_probe.sh             SILICON-GLYPH tools/dev/qml/silicon_glyph_probe.qml                 guess
trayreel tray_reel_probe.sh                 TRAY_REEL tools/dev/qml/tray_reel_probe.qml                          noground
dscale   detail_scale_probe.sh              DETAIL_SCALE mockups/shell.qml                                     oldlookup
idlehold idle_hold_env_probe.sh             IDLEHOLD modules/idle/IdleService.qml                        all:nopill
oled     oled_shift_probe.sh                OLED_SHIFT tools/dev/qml/oled_shift_probe.qml                        nodefer
audiolv  audio_levels_probe.sh              AUDIO_LEVELS tools/dev/qml/audio_levels_probe.qml                    old
audiotl  audio_tools_probe.sh               AUDIO_TOOLS tools/dev/qml/audio_tools_probe.qml                      hoverhide
barink   bar_ink_probe.sh                   BAR_INK tools/dev/qml/bar_ink_probe.qml                              reelprimary
drain    toast_drain_probe.sh               TOAST_DRAIN tools/dev/qml/toast_drain_probe.qml                      step4
handover toast_handover_probe.sh            TOAST_HANDOVER tools/dev/qml/toast_handover_probe.qml             nohandover
llmv     llm_voice_probe.sh                 LLM-VOICE modules/bar/llm/components/LlmService.qml                  nocopy
toastr   toast_routes_probe.sh              TOAST_ROUTES tools/dev/qml/toast_routes_probe.qml                    nodefault
lpempty  llm_picker_empty_probe.sh          LLM_PICKER_EMPTY tools/dev/qml/llm_picker_empty_probe.qml            nooffline
plempty  player_library_empty_probe.sh      PLAYER_LIBRARY_EMPTY tools/dev/qml/player_library_empty_probe.qml    nomentpd
sucheck  su_check_failed_probe.sh           SU_CHECK_FAILED tools/dev/qml/su_check_failed_probe.qml              nowords
susnap   su_snapshot_probe.sh                SU_SNAPSHOT tools/dev/qml/su_snapshot_probe.qml                      noskipkeep
snapui   snapshot_ui_probe.sh               SNAPSHOT_UI tools/dev/qml/snapshot_ui_probe.qml                      notestx
snapeng  snapshot_engine_probe.sh           SNAPSHOT_ENGINE modules/bar/system_update/snapshots/SnapshotsPage.qml              noescape
susnull  su_snapnull_sheet.sh,@SC/out       SU_SNAPNULL tools/dev/qml/su_snapnull_sheet.qml                      -
ahdead   aerial_helper_dead_probe.sh        AERIAL_HELPER_DEAD tools/dev/qml/aerial_helper_dead_probe.qml        nolabel
llmvenv  llm_voice_env_probe.sh             LLM-VOICE-ENV modules/bar/llm/LlmBarOwner.qml                        opens    
notesed  notes_editor_probe.sh              NOTESEDIT tools/dev/qml/notes_editor_probe.qml                       imgregex
wsswipe  workspaces_swipe_probe.sh          WORKSPACESSWIPE tools/dev/qml/workspaces_swipe_probe.qml             droplean
vfopen   viewfinder_open_probe.sh           VIEWFINDEROPEN tools/dev/qml/viewfinder_open_probe.qml               nograce
traypk   tray_pocket_probe.sh,@SC/out       TRAYPOCKET mockups/shell.qml                                         outcorner
picprobe picture_probe.sh                   PICTURE_PROBE tools/dev/qml/picture_probe.qml                    anyink
flpool   flourish_pool_probe.sh             FLOURISH_POOL tools/dev/qml/flourish_pool_probe.qml               nogate
osdhide  osd_hide_probe.sh                  OSDHIDE tools/dev/qml/osd_hide_probe.qml                             notuck
osdlk    osd_lockkeys_probe.sh              OSDLOCKKEYS tools/dev/qml/osd_lockkeys_probe.qml                     oldbind
fadeedge fade_edges_probe.sh,@SC/out        FADE_EDGES tools/dev/qml/fade_edges_probe.qml                        noseal
wxink    weather_ink_probe.sh,@SC/out       WEATHER_INK tools/dev/qml/weather_ink_sheet.qml                      -
stknote  stocks_note_probe.sh               STOCKSNOTE tools/dev/qml/stocks_note_probe.qml                       live
wxoff    weather_offline_probe.sh           WXOFFLINE tools/dev/qml/weather_offline_probe.qml                    noretry
calfail  calendar_failed_probe.sh           CALFAILED tools/dev/qml/calendar_failed_probe.qml                    nopublish
wikiempty wiki_empty_probe.sh               WIKIEMPTY tools/dev/qml/wiki_empty_probe.qml                         always
dictcap  dictation_probe_caption.sh         DICTCAP tools/dev/qml/dictation_probe_caption.qml                    -
dicttake dictation_probe_take.sh            DICTTAKE tools/dev/qml/dictation_probe_take.qml                      noshelltarget
stthelper stt_helper_probe.sh              STTHELPER tools/dev/stt_helper_probe.py                               nofallback
dictnotes dictation_probe_notes.sh          DICTNOTES tools/dev/qml/dictation_probe_notes.qml                    richinsert
dictshel dictation_probe_shell.sh           DICTSHELL modules/dictation/DictationService.qml                    noshelltarget
glyphs   bar_glyphs_sheet.sh                BAR_GLYPHS_SHEET tools/dev/qml/bar_glyphs_sheet.qml                   -
float    float_probe.sh                     FLOAT tools/dev/qml/float_probe.qml                                  cellhit
flourish glyph_flourish_probe.sh            GLYPH_FLOURISH tools/dev/qml/glyph_flourish_probe.qml                  still
flstrip  glyph_flourish_strip.sh            GLYPH_FLOURISH_STRIP tools/dev/qml/glyph_flourish_strip.qml          -
picker   picker_probe.sh                    PICKER tools/dev/qml/picker_probe.qml                                nopaste
brsvc    bridge_service_probe.sh            BRIDGE_SERVICE tools/dev/qml/bridge_service_probe.qml                twotoasts
brpopup  bridge_popup_probe.sh              BRIDGE_POPUP tools/dev/qml/bridge_popup_probe.qml                    escboth
brbody   bridge_body_probe.sh,@SC/out       BRIDGE_BODY tools/dev/qml/bridge_body_probe.qml                      hidden
brperf   bridge_flip_perf.sh,@SC/out        BRIDGE_FLIP_PERF tools/dev/qml/bridge_flip_perf.qml                  -
osdddc   osd_ddc_probe.sh                   OSDDDC tools/dev/qml/osd_ddc_probe.qml                               focusrule
sboard   silicon_board_probe.sh,@SC/out     SILICON_BOARD tools/dev/qml/silicon_board_probe.qml                  hidden
reelauto reel_auto_probe.sh                 REEL_AUTO tools/dev/qml/reel_auto_probe.qml                          nowait
papershell lock_env/probes/paper_shell_probe.sh,@SC PAPER_SHELL_PROBE modules/lockscreen/veil/LockVeil.qml -
dialsshell lock_env/probes/dials_shell_probe.sh,@SC DIALS_SHELL_PROBE modules/lockscreen/veil/LockVeil.qml -
icause   idle_auto_causes_probe.sh          ICAUSE tools/dev/qml/idle_auto_causes_probe.qml                  noshare
wask     wiki_ask_probe.sh                  WASK tools/dev/qml/wiki_ask_probe.qml                              bodystarts
traylabel tray_label_edges.sh               TRAYLABEL mockups/windowtray.qml                                     oddlabel
agtoggle audio_glyph_toggle_probe.sh        AUDIO_GLYPH_TOGGLE tools/dev/qml/audio_glyph_toggle_probe.qml      stuckmuted
dictp    dictation_probe.sh                 DICTATION tools/dev/qml/dictation_probe.qml                          nopreedit
reelstrip reel_flourish_strip.sh            REEL_FLOURISH_STRIP tools/dev/qml/reel_flourish_strip.qml            -
cfgload  config_loaders_probe.sh            CONFIG_LOADERS tools/dev/qml/config_loaders_probe.qml                 nojsonc
cfgwatch config_watch_probe.sh              CONFIG_WATCH tools/dev/qml/config_watch_probe.qml                     late
olkcard  osd_lockkeys_card_probe.sh         OSD_LOCKKEYS_CARD tools/dev/qml/osd_lockkeys_card_probe.qml           hiddencard
barclick bar_clicks_probe.sh                BAR_CLICKS tools/dev/qml/bar_clicks_probe.qml                         nocatch
shellopt shell_options_probe.sh             SHELL_OPTIONS tools/dev/qml/shell_options_probe.qml                   items
thhome   themectl_home_probe.sh             THEMECTL_HOME tools/dev/qml/themectl_home_probe.qml                   all:repofirst
thpar    themectl_resolver_parity.sh        THEMECTL_PARITY tools/dev/qml/themectl_resolver_probe.qml             all:jsround
shm3     shell_hosted_m3_probe.sh           SHELL-HOSTED-M3 modules/aerial/AerialBarOwner.qml               noflag
"

prep() {  # key file sc stage -> a synced, broken (and armed) copy; SCRATCH dir sc fresh
    local key=$1 file=$2 sc=$3 stage=$4
    SANDBOX="$S" "$ROOT/tools/dev/sandbox.sh" > /dev/null || { echo "the sandbox did not sync"; return 1; }
    [ -f "$S/$file" ] || { echo "no $file to break"; return 1; }
    printf '\n}}} broken on purpose by tools/dev/runner_noload_check.sh\n' >> "$S/$file"
    local swap=""
    [ "${ARM:-}" = "silent" ] && swap="rl_noresult=return 0"
    [ "${ARM:-}" = "armload" ] && [ "$stage" = arm ] && swap="rl_isnoresult=return 1;rl_has=return 0"
    if [ -n "$swap" ]; then
        python3 - "$S/tools/dev/result_lib.sh" "$swap" <<'PY' || { echo "could not arm"; return 1; }
import re, sys
p, spec = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
for part in spec.split(";"):
    fn, body = part.split("=", 1)
    a = re.search(r"^" + fn + r"\(\) \{\n.*?^\}\n", s, re.S | re.M)
    if not a:
        print("anchor %s not found" % fn); sys.exit(2)
    s = s[:a.start()] + fn + "() {\n    " + body + "\n}\n" + s[a.end():]
open(p, "w", encoding="utf-8").write(s)
PY
    fi
    rm -rf -- "${sc:?}"
    mkdir -p "$sc"
}


one() {  # key runner[,arg...] NAME file arm -> "ok ..." / "BAD ..." lines; 0 when both passes held
    local key=$1 runner=${2%%,*} name=$3 file=$4 armspec=$5 out rc last log why sc args=()
    [ "$runner" != "$2" ] && IFS=, read -r -a args <<< "${2#*,}"
    # -- clean
    sc="$SCRATCH/$key"
    why=$(prep "$key" "$file" "$sc" clean) || { echo "BAD  $key  $why"; return 1; }
    out=$(cd "$S" && env SANDBOX="$S" SCRATCH="$sc" MOCKUP_REPO="$ROOT" ARM= ONLY_ARMS= ONLY= SMOKE= SHEET= MODE= \
          bash "tools/dev/$runner" "${args[@]//@SC/$sc}" 2>&1)
    rc=$?
    printf '%s\n' "$out" > "$sc/runner.out"
    # The verdict is the LAST LINE THAT IS ONE, not the last line: a runner may report bookkeeping after it -- the stage-0 runners' EXIT trap
    # prints lock_env's "<NAME> LOCK_ENV USERENV unchanged" once the verdict is out, and six rows of the table (s0lua .. s0crash) read as BAD
    # for that line alone. A runner that prints no verdict at all leaves `last` empty (BAD), and a PASS printed after the no-result line
    # becomes the last verdict (BAD): nothing a runner can add after the verdict passes it.
    last=$(printf '%s\n' "$out" | awk -v n="$name RESULT " 'index($0, n) == 1 { l = $0 } END { print l }')
    case "$last" in
        "$name RESULT FAIL (no result: "*")") ;;
        *) echo "BAD  $key  clean: the verdict line is not the no-result verdict (rc $rc): ${last:-<no '$name RESULT' line; the last line is: $(printf '%s\n' "$out" | tail -1)>}"; return 1 ;;
    esac
    [ "$rc" != 0 ] || { echo "BAD  $key  clean: the verdict is FAIL but the runner exited 0"; return 1; }
    log=${last#*no result: }
    log=${log%)}
    grep -a -q -F "$(basename "$file")" "$log" 2>/dev/null \
        || { echo "BAD  $key  clean: the log it names does not name the broken file ($log)"; return 1; }
    echo "ok   $key  clean  rc $rc  $last"
    [ "$armspec" = - ] && return 0
    # -- arm
    sc="$SCRATCH/$key-arm"
    why=$(prep "$key" "$file" "$sc" arm) || { echo "BAD  $key  $why"; return 1; }
    local armenv
    case "$armspec" in
        all:*) armenv="ARM=all ONLY_ARMS=${armspec#all:}" ;;
        *) armenv="ARM=$armspec ONLY_ARMS=" ;;
    esac
    # shellcheck disable=SC2086
    out=$(cd "$S" && env SANDBOX="$S" SCRATCH="$sc" MOCKUP_REPO="$ROOT" $armenv ONLY= SMOKE= SHEET= MODE= bash "tools/dev/$runner" 2>&1)
    rc=$?
    printf '%s\n' "$out" > "$sc/runner.out"
    if ! printf '%s\n' "$out" | grep -q -E "the armed copy (did not load|never loaded)"; then
        echo "BAD  $key  arm ($armenv): not reported as an arm that did not load (rc $rc): $(printf '%s\n' "$out" | tail -1)"
        return 1
    fi
    [ "$rc" != 0 ] || { echo "BAD  $key  arm ($armenv): reported, but the runner exited 0"; return 1; }
    echo "ok   $key  arm    rc $rc  $(printf '%s\n' "$out" | grep -m1 -E "the armed copy (did not load|never loaded)" | sed 's/^ *//' | cut -c1-90)"
    return 0
}

keys=${ONLY:-$(printf '%s\n' "$TABLE" | awk 'NF { print $1 }')}
# ARM=armload breaks the arm pass only: a runner without one has nothing to catch.
[ "${ARM:-}" = armload ] && [ -z "${ONLY:-}" ] && keys=$(printf '%s\n' "$TABLE" | awk 'NF && $5 != "-" { print $1 }')
bad=0
n=0
for k in $keys; do
    row=$(printf '%s\n' "$TABLE" | awk -v k="$k" '$1 == k')
    [ -n "$row" ] || { echo "unknown key $k"; exit 2; }
    # shellcheck disable=SC2086
    set -- $row
    n=$((n + 1))
    one "$@" || bad=$((bad + 1))
done
# Leave the copy whole again for whoever syncs it next.
SANDBOX="$S" "$ROOT/tools/dev/sandbox.sh" > /dev/null
if [ -n "${ARM:-}" ]; then
    # Every runner must have been caught with the fault in place.
    if [ "$bad" = "$n" ]; then echo "NOLOAD ARMS PASS (ARM=$ARM: all $n runners caught)"; exit 0; fi
    echo "NOLOAD ARMS FAIL (ARM=$ARM: only $bad of $n caught)"
    exit 1
fi
if [ "$bad" = 0 ]; then
    echo "NOLOAD RESULT PASS ($n runners, clean and arm)"
    exit 0
fi
echo "NOLOAD RESULT FAIL ($bad of $n runners)"
exit 1
