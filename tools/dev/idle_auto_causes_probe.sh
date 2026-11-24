#!/usr/bin/env bash
# idle_auto_causes_probe.sh -- the idle auto layer's screen-share, wiki-batch, download and package-job causes (tools/dev/qml/idle_auto_causes_probe.qml) on the
# shell's MOCK services in a sandbox copy: debounce, mode, rank (a share outranks a batch), the cause's words, the toasts' holds reading the SAME
# share watcher, and the download's 2-minute age on a pinned clock (DownloadRules), and DownloadWatch against REAL files in a private folder (growing, renamed, stalled, deleted, aria2's control file; the folder is
# found through `xdg-user-dir` with a private user-dirs.dirs), and the package jobs: PackageJobRules on a pinned clock and synthetic process
# records, the restart guard's matcher (lares's bash function) and the JS port held to ONE table (tools/dev/pm_transact_cases.txt), and PackageJobWatch
# (pkgjobs.py) against a FAKE /proc and lock file (never the real /var/lib/pacman, never a real pacman or yay). Nothing touches the desktop, ~/Downloads, hypridle, logind or the live shell.
#
#   tools/dev/idle_auto_causes_probe.sh              ICAUSE RESULT PASS | FAIL (<n>/<n> checks)
#   ARM=<name> tools/dev/idle_auto_causes_probe.sh   the fault patched into the sandbox copy; passes when the check it aims at FAILS:
#     noshare      the share is no holder                                  -> "a shared screen raises normal"
#     sharesoft    a share asks soft, not normal                           -> "a shared screen raises normal"
#     nowiki       a wiki batch is no holder                               -> "a wiki batch raises soft"
#     nodownload   a download is no holder                                 -> "a download raises soft after the on debounce"
#     nowire       ShellServices does not bind the share to the layer      -> "a shared screen raises normal"
#     nosharedhold the toasts' holds keep their own watcher                -> "the holds read the SAME watcher"
#     nodebounce   a holder counts at once                                 -> "a share does nothing before the on debounce"
#     nooff        a holder lets go at once                                -> "a share that lets go keeps normal until the off debounce"
#     nostall      a stalled download counts for ever                      -> "a stalled download stops counting"
#     norename     a rename does not end a download                        -> "a rename (the download finished) ends it at once"
#     nocrdownload .crdownload is not a partial file                       -> "a Chromium .crdownload counts"
#     noaria       aria2's control file is no marker                       -> "aria2: the data file's writes count while its control file stands"
#     anyfile      every file is a download                                -> "a plain file and a subfolder's partial file count nothing"
#     noage        the minimum age is not checked                          -> "a download that grew 119 s does not count"
#     noreset      a stall keeps the age                                   -> "a stall resets the age (a resumed download starts its 2 minutes again)"
#     pkgnoage     (packages) the minimum age is not checked                -> "a job that ran 119 s does not count"
#     checkupdates (packages) the private-database copy is counted          -> "checkupdates' copy never counts"
#     double       (packages) the shell's own update is told from no one    -> "... and it is not counted a second time"
#     ignoreoff    (ContentHold) the ignore list sets nothing aside        -> "... and holds nothing: FreeRDP's SDL client is on the default list"
#     substring    (ContentHold) a listed name matches as a substring      -> "a name that only CONTAINS a listed one holds too"
#     nocase       (ContentHold) names match in the case given              -> "a logind idle inhibitor of who SDL-FreeRDP3 (any case) is ignored"
#     noignorewire SoftIdle does not hand ContentHold the list              -> "the shell's idle service reads the list from idle.jsonc"
#     nohotignore  (IdleConfig) a list the file gives is not read           -> "the list is read hot: an empty contentIgnore makes the FreeRDP holder count at once"
#     nokeyplay    (ShortcutRouter) a key that opens a popup plays no glyph   -> "the key OPENS notes: the focused screen's glyph plays once"
#     closeplays   (ShortcutRouter) a key that CLOSES plays it too            -> "the key CLOSES it"
#     allscreens   (ShortcutRouter) every screen's glyph plays                -> "the key OPENS notes: the focused screen's glyph plays once, the other"
#   (the key flourish: tools/dev/qml/key_flourish_probe.qml, the second harness, its own KEYFL result; the REAL router and NotesBarButton over stand-in owners)
#   (the ignore list: ContentHold on stub dbus-monitor / hyprctl / logind sources, one line in the log per ignored name)
# The verdict is the probe's own RESULT line (tools/dev/result_lib.sh).
set -u
cd "$(dirname "$0")/../.." || exit 1
. tools/dev/result_lib.sh
D="$(mktemp -d "${SCRATCH:-/tmp}/icause.XXXXXX")"
KEEP_D=0
trap '[ "$KEEP_D" = 1 ] || [ -n "${KEEP:-}" ] || rm -rf "$D"' EXIT
ARMCMD="" NEEDLE=""
case "${ARM:-}" in
    "") ;;
    noshare)    NEEDLE="a shared screen raises normal"
                ARMCMD="sed -i 's|    { key: \"share\", mode: \"normal\" },||' modules/idle/IdleAutoRules.js" ;;
    sharesoft)  NEEDLE="a shared screen raises normal"
                ARMCMD="sed -i 's|    { key: \"share\", mode: \"normal\" },|    { key: \"share\", mode: \"soft\" },|' modules/idle/IdleAutoRules.js" ;;
    nowiki)     NEEDLE="a wiki batch raises soft"
                ARMCMD="sed -i 's|    { key: \"wiki\", mode: \"soft\" },||' modules/idle/IdleAutoRules.js" ;;
    nodownload) NEEDLE="a download raises soft after the on debounce"
                ARMCMD="sed -i 's|    { key: \"download\", mode: \"soft\" },||' modules/idle/IdleAutoRules.js" ;;
    nowire)     NEEDLE="a shared screen raises normal"
                ARMCMD="sed -i 's|        value: shareWatchItem.active|        value: false|' modules/shell/ShellServices.qml" ;;
    nosharedhold) NEEDLE="the holds read the SAME watcher"
                ARMCMD="sed -i 's|        value: shareWatchItem\$|        value: null|' modules/shell/ShellServices.qml" ;;
    nodebounce) NEEDLE="a share does nothing before the on debounce"
                ARMCMD="sed -i 's|            h._timer.interval = h.on ? h.onMs : h.offMs;|            h._timer.interval = h.on ? 1 : h.offMs;|' modules/idle/IdleAuto.qml" ;;
    nooff)      NEEDLE="a share that lets go keeps normal until the off debounce"
                ARMCMD="sed -i 's|            h._timer.interval = h.on ? h.onMs : h.offMs;|            h._timer.interval = h.on ? h.onMs : 1;|' modules/idle/IdleAuto.qml" ;;
    nostall)    NEEDLE="a stalled download stops counting"
                ARMCMD="sed -i 's|        if (nowMs - state.act\[k\] < stallMs)\$|        if (true)|' modules/common/system/DownloadRules.js" ;;
    norename)   NEEDLE="a rename (the download finished) ends it at once"
                ARMCMD="sed -i 's/ev.indexOf(\"DELETE\") >= 0 || ev.indexOf(\"MOVED_FROM\") >= 0/ev.indexOf(\"DELETE\") >= 0/' modules/common/system/DownloadRules.js" ;;
    nocrdownload) NEEDLE="a Chromium .crdownload counts"
                ARMCMD="sed -i 's/(part|crdownload|download)/(part|download)/' modules/common/system/DownloadRules.js" ;;
    noaria)     NEEDLE="aria2: the data file's writes count while its control file stands"
                ARMCMD="sed -i 's/(aria2|ytdl)/(ytdl)/' modules/common/system/DownloadRules.js" ;;
    anyfile)    NEEDLE="a plain file and a subfolder's partial file count nothing"
                ARMCMD="sed -i 's/(part|crdownload|download)/(part|crdownload|download|txt)/' modules/common/system/DownloadRules.js" ;;
    noage)      NEEDLE="a download that grew 119 s does not count"
                ARMCMD="sed -i 's| \&\& nowMs - state.start\[k\] >= minAgeMs||' modules/common/system/DownloadRules.js" ;;
    noreset)    NEEDLE="a stall resets the age (a resumed download starts its 2 minutes again)"
                ARMCMD="sed -i 's/if (a === undefined || nowMs - a >= stallMs)/if (a === undefined)/' modules/common/system/DownloadRules.js" ;;
    pkgnoage)   NEEDLE="a job that ran 119 s does not count"
                ARMCMD="sed -i 's|    return st.present \&\& st.start !== null \&\& nowMs - st.start >= minAgeMs;|    return st.present;|' modules/common/system/PackageJobRules.js" ;;
    checkupdates) NEEDLE="checkupdates' copy never counts"
                ARMCMD="sed -i 's|        if (x === \"--dbpath\" .*|        if (false)|' modules/common/system/PackageJobRules.js" ;;
    double)     NEEDLE="... and it is not counted a second time"
                ARMCMD="sed -i 's|        out.push({ pid: p.pid, tool: p.comm, what: what, own: isOwn });|        out.push({ pid: p.pid, tool: p.comm, what: what, own: false });|' modules/common/system/PackageJobRules.js" ;;
    ignoreoff)  NEEDLE="... and holds nothing: FreeRDP's SDL client is on the default list"
                ARMCMD="sed -i 's|^function ignores(list, name) {|&\n    return false;|' modules/idle/ContentRules.js" ;;
    substring)  NEEDLE="a name that only CONTAINS a listed one holds too"
                ARMCMD="sed -i 's|        if (_key(list\[i\]) === k)|        if (k.indexOf(_key(list[i])) >= 0)|' modules/idle/ContentRules.js" ;;
    nocase)     NEEDLE="a logind idle inhibitor of who SDL-FreeRDP3 (any case) is ignored"
                ARMCMD="sed -i 's|[.]trim()[.]toLowerCase()|.trim()|' modules/idle/ContentRules.js" ;;
    noignorewire) NEEDLE="the shell's idle service reads the list from idle.jsonc"
                ARMCMD="sed -i '/^        ignore: root.settings.contentIgnore\$/d' modules/idle/SoftIdle.qml" ;;
    nohotignore) NEEDLE="the list is read hot: an empty contentIgnore makes the FreeRDP holder count at once"
                ARMCMD="sed -i 's|        contentIgnore: _names(o.contentIgnore, d.contentIgnore)|        contentIgnore: d.contentIgnore|' modules/idle/IdleConfig.js" ;;
    nokeyplay)  NEEDLE="the key OPENS notes: the focused screen's glyph plays once"
                ARMCMD="sed -i 's|^            root._keyFlourish(key, o);|            void 0;|' modules/shell/ShortcutRouter.qml" ;;
    closeplays) NEEDLE="the key CLOSES it"
                ARMCMD="sed -i 's|        if (!was \&\& o.popupMine === true)|        if (true)|' modules/shell/ShortcutRouter.qml" ;;
    allscreens) NEEDLE="the key OPENS notes: the focused screen's glyph plays once, the other"
                ARMCMD="sed -i 's|FlourishRegistry.entriesUnder(frame)|FlourishRegistry.entries|' modules/shell/ShortcutRouter.qml" ;;
    *) echo "unknown ARM=$ARM"; exit 2 ;;
esac
# private dirs: the download folder, user-dirs.dirs naming it, a seeded theme state, a private state home (the mock shell's own files)
mkdir -p "$D/dl" "$D/cfg/theme" "$D/state" "$D/pk" "$D/ch"
# the stub sources of the ignore list's ContentHold: dbus-monitor's lines (tail -F), `hyprctl -j clients`, logind's ListInhibitors
: > "$D/ch/dbus.log"; echo '[]' > "$D/ch/clients.json"; echo '{"data":[[]]}' > "$D/ch/logind.json"
printf 'XDG_DOWNLOAD_DIR="%s"\n' "$D/dl" > "$D/cfg/user-dirs.dirs"
cp "${XDG_CONFIG_HOME:-$HOME/.config}/theme/state.json" "$D/cfg/theme/state.json" 2> /dev/null || printf '{"theme":"eva","mode":"light"}\n' > "$D/cfg/theme/state.json"
LARES_ENV='env -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=rhi XDG_CONFIG_HOME="$D_CFG" XDG_STATE_HOME="$D_STATE" DL_DIR="$D_DL" PK_DIR="$D_PK" CH_DIR="$D_CH" CASES="$PWD/tools/dev/pm_transact_cases.txt" SHELL_SERVICES=mock'
# the two harnesses one after the other in the one (armed) copy; the second runs whatever the first said
run='set -e; '"${ARMCMD:+$ARMCMD; }"'set +e; '"$LARES_ENV"' timeout 120 quickshell -p tools/dev/qml/idle_auto_causes_probe.qml; '"$LARES_ENV"' timeout 90 quickshell -p tools/dev/qml/key_flourish_probe.qml'
# the restart guard's matcher (lares's own bash function) over the shared table: the JS port is held to the same lines inside the QML probe
: > "$D/log"
fn=$(awk '/^pm_args_transact\(\) \{/{p=1} p{print} p&&/^}/{exit}' tools/shell/lares)
if [ -z "$fn" ]; then echo "ICAUSE FAIL the restart guard's pm_args_transact was not found in tools/shell/lares" >> "$D/log"; else
    bn=0 bbad=""
    eval "$fn"
    while IFS=$'\t' read -r want args; do
        case $want in ''|'#'*) continue ;; esac
        bn=$(( bn + 1 ))
        # shellcheck disable=SC2086
        if pm_args_transact $args; then got=yes; else got=no; fi
        [ "$got" = "$want" ] || bbad="$bbad [$want: $args]"
    done < tools/dev/pm_transact_cases.txt
    if [ "$bn" -gt 30 ] && [ -z "$bbad" ]; then echo "ICAUSE ok   the table of cases: lares's pm_args_transact agrees on all $bn lines" >> "$D/log"
    else echo "ICAUSE FAIL the table of cases: lares's pm_args_transact disagrees  [$bn cases; wrong:$bbad]" >> "$D/log"; fi
fi
D_CFG="$D/cfg" D_STATE="$D/state" D_DL="$D/dl" D_PK="$D/pk" D_CH="$D/ch" SANDBOX="${SANDBOX:-/tmp/lares-sandbox-idle-auto-causes}" tools/dev/sandbox.sh bash -c "$run" >> "$D/log" 2>&1
rl_clean "$D/log" | grep -a 'ICAUSE \(ok\|FAIL\) ' | sed 's/^.*ICAUSE /ICAUSE /'
rl_clean "$D/log" | grep -a 'KEYFL \(ok\|FAIL\) ' | sed 's/^.*KEYFL /KEYFL /'
warn=$(rl_clean "$D/log" | grep -aiE "binding loop|Cannot assign|Unable to assign|TypeError|ReferenceError|is not a function|unqualified" | rl_platform_noise | head -5)
[ -n "$warn" ] && printf 'WARN %s\n' "$warn"
if [ -n "${ARM:-}" ]; then
    if ! rl_has "$D/log" 'ICAUSE RESULT' || ! rl_has "$D/log" 'KEYFL RESULT'; then KEEP_D=1; echo "ARM $ARM: the armed copy did not load -- it proves nothing ($D/log)"; exit 1; fi
    if rl_clean "$D/log" | grep -a '\(ICAUSE\|KEYFL\) FAIL' | grep -aqF -- "$NEEDLE"; then echo "ARM $ARM: failed as it must ('$NEEDLE')"; exit 0; fi
    KEEP_D=1; echo "ARM $ARM: DID NOT FAIL on '$NEEDLE' -- the probe cannot see it ($D/log)"; exit 1
fi
res=$(rl_result ICAUSE "$D/log" 'ICAUSE RESULT .*'); rc=$?
if rl_isnoresult "$res"; then KEEP_D=1; fi
# each ignored name is said once when first set aside: sdl-freerdp3 (the default list), again after the empty list let it count and the user's list set it aside
if [ "$rc" = 0 ]; then
    n=$(rl_clean "$D/log" | grep -ac 'LARES idle content ignored: sdl-freerdp3$')
    if [ "$n" != 2 ]; then res="ICAUSE RESULT FAIL (the log should say 'idle content ignored: sdl-freerdp3' twice, said $n times: $D/log)"; rc=1; KEEP_D=1; fi
fi
# the key flourish's harness: its own result, or the run has none
if ! rl_has "$D/log" 'KEYFL RESULT'; then KEEP_D=1; rl_noresult ICAUSE "$D/log"; exit 1; fi
if [ "$rc" = 0 ] && ! rl_has "$D/log" 'KEYFL RESULT PASS'; then res="ICAUSE RESULT FAIL (the key flourish: $(rl_clean "$D/log" | grep -a -o 'KEYFL RESULT .*' | tail -1))"; rc=1; KEEP_D=1; fi
if [ "$rc" = 0 ] && rl_clean "$D/log" | grep -aq 'ICAUSE FAIL the table of cases: lares'; then res="ICAUSE RESULT FAIL (lares's pm_args_transact disagrees with the table)"; rc=1; fi
[ -n "$warn" ] && [ "$rc" = 0 ] && { res="ICAUSE RESULT FAIL (warnings in the log: $D/log)"; rc=1; KEEP_D=1; }
printf '%s\n' "$res"
exit $rc
