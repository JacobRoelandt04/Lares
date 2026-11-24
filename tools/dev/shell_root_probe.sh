#!/usr/bin/env bash
# shell_root_probe.sh -- the shell.qml stub and its `file:` root (shell.jsonc `workarounds.fileRoot`), checked on the real mock shell in
# tools/dev/lock_env.sh's nested Hyprland:
#
#   ONE TYPE WORLD   with qt.qml.diskcache.debug on, every compiled unit names its URL. In `file` mode no repo file may be loaded under
#                    two schemes, and the stub's world (qs:) holds only the stub: a singleton loaded twice is two singletons. In `qs`
#                    mode (LARES_FILE_ROOT=0, what lares-supervise passes for shell.jsonc's `fileRoot: false`) nothing is loaded from
#                    file: (the shell as before).
#   THE SCAN         Quickshell's scanner reads no repo directory in `file` mode (its debug log names none), and all of them in `qs`.
#   THE LINES        `LARES root file|qs`, `LARES start root=<ms> services=<ms>`, `LARES ready`.
#   THE IPC          target `shell` answers `ping` (ok) and the live `toggle <owner>` (open, then shut; none for an unknown owner)
#                    from a body created after the load.
#   THE CACHE        a second start on the same QML_DISK_CACHE_PATH refuses nothing ("File has to be a local file" is 0 in file mode)
#                    and the stub's world is the only thing compiled again.
#
#   SANDBOX=/tmp/lares-sbx-<stream> tools/dev/shell_root_probe.sh        ARM=split: the stub reads Sleep (a singleton of the body's), which
#   must fail ONE TYPE WORLD.   KEEP=1 keeps the logs (printed).
# Ends in `SHELL_ROOT RESULT PASS|FAIL`.
set -u
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -z "${SR_INNER:-}" ]; then
    exec "$HERE/tools/dev/sandbox.sh" SR_INNER=1 ARM="${ARM:-}" KEEP="${KEEP:-}" bash tools/dev/shell_root_probe.sh
fi
cd "$HERE" || exit 1
T="$HERE"      # this half stands in a sandbox copy (the outer half re-executed through sandbox.sh): never the tree
[ ! -e "$T/.git" ] || { echo "SHELL_ROOT RESULT FAIL (the inner half was started in a work tree, not in a sandbox copy)"; exit 1; }
. tools/dev/result_lib.sh
[ ! -e .git ] || { echo "SHELL_ROOT RESULT FAIL (not in a sandbox copy)"; exit 1; }
E="$HERE/tools/dev/lock_env.sh"
export LOCK_ENV="${LOCK_ENV:-strp}"
W=$(mktemp -d /tmp/lares-srp.XXXXXX)
QPID=""
cleanup() {
    [ -n "$QPID" ] && kill "$QPID" 2> /dev/null
    "$E" down > /dev/null 2>&1
    wait 2> /dev/null
    [ -n "${KEEP:-}" ] && echo "SHELL_ROOT logs kept: $W" || rm -rf "$W"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

if [ "${ARM:-}" = split ]; then
    python3 - << 'PY' || { echo "SHELL_ROOT RESULT FAIL (ARM split: the anchor is gone)"; exit 1; }
import sys
p = "shell.qml"; s = open(p).read()
a1, a2 = '//@ if env("LARES_FILE_ROOT") == "0"\n', '        console.log("LARES root " + (file ? "file" : "qs"));\n'
if s.count(a1) != 1 or s.count(a2) != 1: sys.exit(1)
s = s.replace(a1, 'import "modules/common/system"\n' + a1).replace(a2, a2 + '        console.log("ARM split sleep mode=" + Sleep.mode);\n')
open(p, "w").write(s)
PY
    echo "SHELL_ROOT ARM split: the stub reads Sleep"
fi

fail=0
check() { if [ "$1" = 0 ]; then echo "SHELL_ROOT ok   $2"; else echo "SHELL_ROOT FAIL $2"; fail=1; fi; }

"$E" down > /dev/null 2>&1
OUTPUTS=1 "$E" up > /dev/null || { echo "SHELL_ROOT RESULT FAIL (the nested Hyprland did not come up)"; exit 1; }
CFG="/tmp/lrlk-$LOCK_ENV/state/lares-shell-mock/config"
mkdir -p "$CFG"
ipc() { "$E" run quickshell ipc --path "$T/shell.qml" call shell "$@" 2> /dev/null; }

start() {   # start <mode> <cache dir> <log>
    local fr=(); [ "$1" = qs ] && fr=(LARES_FILE_ROOT=0)
    "$E" run env SHELL_SERVICES=mock MOCKUP_REPO= QS_DISABLE_CRASH_HANDLER=1 QS_DISABLE_FILE_WATCHER=1 QML_DISK_CACHE_PATH="$2" "${fr[@]}" \
        quickshell --log-rules "qt.qml.diskcache.debug=true;quickshell.qmlscanner.debug=true" -n -p "$T/shell.qml" > "$3" 2>&1 &
    QPID=$!
    local deadline=$(( $(date +%s) + 120 ))
    until grep -aq "LARES ready" "$3" 2> /dev/null; do
        kill -0 "$QPID" 2> /dev/null && [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 0.2
    done
    sleep 1
}
stop() { kill "$QPID" 2> /dev/null; wait "$QPID" 2> /dev/null; QPID=""; }

# the units each run compiled or read, by scheme: `<scheme>\t<repo path>`
units() {
    sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -aoE 'QUrl\("(qs:@/qs/|file://'"$HERE"'/)[^"]*"\)' \
        | sed -E 's#QUrl\("qs:@/qs/#qs\t#; s#QUrl\("file://'"$HERE"'/#file\t#; s#"\)$##' | sort -u
}

for mode in file qs; do
    log="$W/$mode.cold.log"; cache="$W/cache.$mode/lares/qmlcache"     # not made here: Qt makes the cache's directory itself
    if ! start "$mode" "$cache" "$log"; then echo "SHELL_ROOT FAIL $mode: no LARES ready ($(tail -3 "$log" | tr '\n' ' '))"; fail=1; stop; continue; fi
    t=$(sed 's/\x1b\[[0-9;]*m//g' "$log")
    grep -q "LARES root $mode\$" <<< "$t"; check $? "$mode: says LARES root $mode"
    grep -qE "LARES start root=[0-9]+ (load=[0-9]+ )?services=[0-9]+" <<< "$t"; check $? "$mode: says $(grep -oE 'LARES start root=[0-9]+ (load=[0-9]+ )?services=[0-9]+' <<< "$t" | head -1)"
    # ONE Sleep singleton, the config's own copy, runs logind's monitor (Sleep.qml: a copy that missed its own URL would run none)
    nmon=0
    for pp in /proc/[0-9]*; do
        { tr '\0' ' ' < "$pp/cmdline"; } 2> /dev/null | grep -q "gdbus monitor --system --dest org.freedesktop.login1" || continue
        { tr '\0' '\n' < "$pp/environ"; } 2> /dev/null | grep -qx "LOCK_ENV_DIR=/tmp/lrlk-$LOCK_ENV" && nmon=$((nmon + 1))
    done
    [ "$nmon" = 1 ]; check $? "$mode: one logind monitor (Sleep's watcher): $nmon"
    r=$(ipc ping); [ "$r" = ok ]; check $? "$mode: ipc ping -> '$r'"
    r=$(ipc toggle clock); [ "$r" = open ]; check $? "$mode: ipc toggle clock -> '$r'"
    sleep 1.5
    r=$(ipc toggle clock); [ "$r" = shut ]; check $? "$mode: ipc toggle clock again -> '$r'"
    r=$(ipc toggle nosuchowner); [ "$r" = none ]; check $? "$mode: ipc toggle nosuchowner -> '$r'"
    stop
    nscan=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -acE "qmlscanner: Scanning directory \"$HERE/modules")
    if [ "$mode" = file ]; then [ "$nscan" = 0 ]; else [ "$nscan" -gt 50 ]; fi; check $? "$mode: the scanner read $nscan module directories"
    u="$W/$mode.units"; units "$log" > "$u"
    nq=$(grep -c "^qs" "$u"); nf=$(grep -c "^file" "$u")
    both=$(cut -f2 "$u" | sort | uniq -d | tr '\n' ' ')
    [ -z "$both" ]; check $? "$mode: no other file under two schemes ($nq on qs:, $nf on file:)${both:+ -- twice: $(head -c 300 <<< "$both")}"
    if [ "$mode" = file ]; then
        extra=$(grep "^qs" "$u" | cut -f2 | grep -vx 'shell\.qml' | tr '\n' ' ')
        [ -z "$extra" ]; check $? "file: the stub's world is the stub only${extra:+ -- also: $(head -c 300 <<< "$extra")}"
        [ "$nf" -gt 300 ]; check $? "file: the body is on file: ($nf units)"
        # the warm start: the same cache
        log2="$W/file.warm.log"
        if start file "$cache" "$log2"; then
            stop
            n=$(grep -ac "File has to be a local file" "$log2"); nst=$(grep -c "^qs" "$u")
            [ "$n" -le $(( nst * 2 )) ]; check $? "file warm: $n refusals (the stub's $nst units on qs: only)"
            miss=$(sed 's/\x1b\[[0-9;]*m//g' "$log2" | grep -acE "Error loading \"file:")
            [ "$miss" = 0 ]; check $? "file warm: every file: unit from the cache ($miss compiled again)"
        else echo "SHELL_ROOT FAIL file warm: no LARES ready"; fail=1; stop; fi
    else
        [ "$nf" = 0 ]; check $? "qs: nothing on file: ($nf)"
    fi
done
if [ "$fail" = 0 ]; then echo "SHELL_ROOT RESULT PASS"; else echo "SHELL_ROOT RESULT FAIL"; exit 1; fi
