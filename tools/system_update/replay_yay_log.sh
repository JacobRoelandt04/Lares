#!/usr/bin/env bash
# Paces a captured `yay -Syu` log through stdout at a configurable interval
# per line, so test_update_parser.qml / mockups/system_update.qml can
# replay a known-good transcript through TerminalBackend deterministically.
#
# Usage:
#   tools/system_update/replay_yay_log.sh [log_file] [delay_seconds]
#
# Defaults:
#   log_file       = newest /tmp/yay-syu-capture-*.log
#   delay_seconds  = 0.03 (≈ 40s to replay 1336 lines)
#
# Pause behaviour: on lines that look like an interactive yay/pacman prompt
# (Proceed / Packages to exclude / cleanBuild / Diffs), the replay halts and
# waits for one line on stdin before continuing. This lets the popup's
# prompt-answer UI exercise its buttons against the recording. The reply is
# read but discarded — the captured log is fixed, so what comes next is
# whatever yay actually emitted at record time.
#
# Fast path: delay == 0 skips the bash loop entirely and uses pure awk so
# headless smoke tests aren't dominated by per-line bash overhead. Prompts
# are NOT paused in this mode.

set -u

FILE="${1:-}"
DELAY="${2:-0.03}"

# Prefer a real capture if one is lying around, otherwise fall back to the
# checked-in sample. /tmp is a tmpfs on this machine, so real captures do not
# survive a reboot — without the fallback the mockup's Replay button fails with
# "no log file found" every time the machine restarts, which is exactly what it
# used to do.
if [[ -z "$FILE" ]]; then
    FILE=$(ls -1t /tmp/yay-syu-capture-*.log 2>/dev/null | head -1)
fi
if [[ -z "$FILE" || ! -f "$FILE" ]]; then
    FALLBACK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fixtures/yay-syu-sample.log"
    if [[ -f "$FALLBACK" ]]; then
        FILE="$FALLBACK"
        echo "[replay] no capture found, using bundled sample" >&2
    fi
fi

if [[ ! -f "$FILE" ]]; then
    echo "replay_yay_log: no log file found (tried: $FILE)" >&2
    echo "Pass the path of a captured log." >&2
    exit 1
fi

echo "[replay] file=$FILE  delay=${DELAY}s" >&2

# A replay ENDS THE WAY THE RUN ENDED. script(1) writes the command's exit
# status on the typescript's last line, and a replay that always exited 0
# made every failed run replay as a success -- the parser's finish() is
# handed the exit code, and 0 is what turned the 2026-09-11 download failure
# into "Update complete".
recorded_exit() {
    local c
    c=$(grep -o 'COMMAND_EXIT_CODE="[0-9]*"' "$FILE" 2>/dev/null | tail -1 | tr -dc '0-9')
    echo "${c:-0}"
}

if [[ "$DELAY" == "0" || "$DELAY" == "0.0" ]]; then
    awk '{print $0; fflush()}' "$FILE"
    exit "$(recorded_exit)"
fi

is_prompt() {
    # Captured lines still carry ANSI SGR escapes around the literal text, so
    # match on the bare substring rather than a strict line-start anchor.
    # Both "install?" and "installation?" forms — yay rewords across versions.
    case "$1" in
        *"Proceed with install"*)      return 0 ;;
        *"Packages to exclude"*)       return 0 ;;
        *"Packages to cleanBuild"*)    return 0 ;;
        *"Diffs to show"*)             return 0 ;;
        *"PKGBUILDs to edit"*)         return 0 ;;
        *"Edit PKGBUILD with"*)        return 0 ;;
        # A question yay printed and went on past (2026-10-29: ":: Remove make dependencies after install? [y/N] :: (1/6) Parsing
        # SRCINFO: ..." on ONE line, the run carrying on with no input) is not a stop: the real run never waited there, and the parser
        # opens a prompt only where the question is the last thing on the line, so a replay that waited for a reply to it waited for ever.
        *"Remove make dependencies"*)
            local bare
            bare=$(printf '%s' "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g')
            [[ "$bare" =~ \[[yY]/[nN]\][[:space:]]*[yYnN]?[[:space:]]*$ ]] && return 0 ;;
    esac
    return 1
}

# fd 3 reads the log so fd 0 stays free for backend.submit() bytes
# arriving via the PTY.
exec 3< "$FILE"
while IFS= read -r line <&3; do
    printf '%s\n' "$line"
    if is_prompt "$line"; then
        IFS= read -r _reply || true
    else
        sleep "$DELAY"
    fi
done
exit "$(recorded_exit)"
