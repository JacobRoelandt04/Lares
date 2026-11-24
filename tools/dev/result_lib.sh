# shellcheck shell=bash
# Sourced by probe runners, never run. The verdict of a run is the probe's
# own RESULT line; this is what a runner says when there is none.
#
# WHY. A QML that fails to load prints no RESULT line at all: quickshell
# logs "Failed to load configuration" and exits 255 at once. A runner that
# reads its verdict as `grep ... | tail -1 || echo "... FAIL"` then prints
# NOTHING and exits 0 -- `tail` succeeds on empty input, so the `||` never
# runs. notifications_ui_probe.sh did exactly that while another stream had
# a file half-edited (R2B-CLOCK2, question 2): a silent, pass-shaped run.
# So a runner that found no RESULT line prints
#
#     <NAME> RESULT FAIL (no result: <log>)
#
# as its last line, after the log's own load errors, and exits non-zero.
# `tools/dev/runner_noload_check.sh` proves it for every runner that sources this.

# rl_clean <log>: the log without quickshell's colour codes.
rl_clean() {
    sed -r 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null
}

# rl_has <log> <ERE>: 0 when a line of the log matches.
rl_has() {
    rl_clean "$1" | grep -a -q -E "$2"
}

# rl_noresult <NAME> <log>: the log's load errors, then the verdict line.
# Returns 1: a run without a result is a failed run.
rl_noresult() {
    rl_clean "$2" | grep -a -E "^\s*ERROR|caused by" | head -6 | sed 's/^ */    /'
    echo "$1 RESULT FAIL (no result: $2)"
    return 1
}

# rl_result <NAME> <log> [ERE]: the probe's last RESULT line (default
# `<NAME> RESULT .*`, taken from the line, prefix dropped), or rl_noresult.
# Returns 0 only when that line is a PASS.
rl_result() {
    local res
    res=$(rl_clean "$2" | grep -a -o -E "${3:-$1 RESULT .*}" | tail -1)
    if [ -z "$res" ]; then
        rl_noresult "$1" "$2"
        return $?
    fi
    echo "$res"
    case "$res" in *"RESULT PASS"*) return 0 ;; esac
    return 1
}

# rl_isnoresult <text>: 0 when <text> (a runner's output) is a no-result
# verdict. An ARM whose armed copy never loaded failed for the wrong reason
# and proves nothing, so the ARM=all loops reject it with this.
rl_isnoresult() {
    printf '%s\n' "$1" | grep -q "RESULT FAIL (no result: "
}

# ---- the one platform warning a Qt 6.12 Wayland client prints that is nobody's fault ------------------------------------------------
# qtwayland 6.12 (qt6-wayland 6.12.0-1) logs, when a window of the XDG-toplevel kind -- a Quickshell FloatingWindow, any application
# window -- loses the text input, a line of the shape
#
#     WARN qt.qpa.wayland.textinput: virtual void QtWaylandClient::QWaylandTextInputv3::disableSurface(wl_surface*)
#          Trying to disable 0x7ff0d8b80f20 but 0x7ff0d8d94a40 is focused          (one line; "but 0x0 is focused" too)
#
# It is the platform's: a QML file of ONE bare FloatingWindow and nothing else, started in tools/dev/lock_env.sh, prints it in every run,
# and a bare PanelWindow (layer surface), with or without a TextInput, never does (platform_textinput_probe.sh, at tag pre-cleanup, re-proves both
# after a Qt update, and fails when the platform stops printing it -- a filter with no reason left goes). It names two surface
# pointers and nothing of the shell, so it varies run to run only by those two addresses.
#
# THE ENABLE FORM. The same family prints one more exact line when a LAYER surface gets its keyboard back after the shell took it away
# (the key release of an open popup, GooeyEngine.releaseKeys: keyboard mode None, then OnDemand again when the pointer returns -- the
# compositor re-enters a surface qtwayland never left):
#
#     WARN qt.qpa.wayland.textinput: virtual void QtWaylandClient::QWaylandTextInputv3::enableSurface(wl_surface*)
#          Trying to enable 0x7f5d92dbff40 but 0x7f5d92dbff40 has focus          (one line; "but 0x0 has focus" too)
#
# Also the platform's, proved with no shell code: a QML file of ONE bare PanelWindow holding a focused TextInput, whose
# WlrLayershell.keyboardFocus goes OnDemand -> None -> OnDemand twice while a pointer moves over it, prints it once per return in every
# run; the same file with the pointer still, and the same panel left at OnDemand, print none (the same probe, kind
# `reclaim`, plus its `panel` and `none` controls; it fails when the platform stops printing the line).
#
# THE FILTER IS THE LINE, NOT THE CATEGORY. Where a log is judged for warnings, these exact lines are dropped and nothing else: another
# message of the same `qt.qpa.wayland.textinput` category, the same function with other words, a different level, all still count.
# Every runner that judges a log pipes it through rl_platform_noise; none carries a pattern of its own for it
# (tools/dev/shell_gates.sh `platform_noise` fails on a second copy of the pattern).
RL_QT_TEXTINPUT_RE='^\s*WARN qt\.qpa\.wayland\.textinput: virtual void QtWaylandClient::QWaylandTextInputv3::disableSurface\(wl_surface\*\) Trying to disable 0x[0-9a-f]+ but 0x[0-9a-f]+ is focused$'
RL_QT_TEXTINPUT_ENABLE_RE='^\s*WARN qt\.qpa\.wayland\.textinput: virtual void QtWaylandClient::QWaylandTextInputv3::enableSurface\(wl_surface\*\) Trying to enable 0x[0-9a-f]+ but 0x[0-9a-f]+ has focus$'

# rl_platform_noise: stdin without those lines (ANSI codes already stripped, as rl_clean does). Always exits 0: `sed`, not `grep -v`,
# which exits 1 on an empty result and would fail a `set -o pipefail` pipeline for the very log that came out clean.
rl_platform_noise() {
    sed -E -e "/$RL_QT_TEXTINPUT_RE/d" -e "/$RL_QT_TEXTINPUT_ENABLE_RE/d"
}
