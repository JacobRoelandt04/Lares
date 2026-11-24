#!/usr/bin/env bash
# Delete a screenshot: to the Trash (recoverable) and tell the shell.
#
#   tools/notifications/shot_trash.sh <file.png>
#
# The one helper behind every "delete this shot": the OSD capture card's trash icon, the notification's trash button,
# and swappy's delete button (tools/notifications/swappy_trash.c). `gio trash` first, so a mistake is recoverable from
# the Trash (and from swappy's Save while its window is open); a file that cannot be trashed (gio missing, a mount
# with no trash) is removed. Then `quickshell ipc call osd capture deleted <path> ""`: the OSD takes down the shot's
# card if it is still up and the shot's notification leaves the manager. A file that is already gone is not an error
# (the same shot deleted from the card and from swappy); the shell is still told, so a stale card goes.
#
# The IPC handler takes three arguments (what, a, b) and IpcHandler has no optional ones: a call with two is refused
# ("Not enough arguments") and nothing happens -- a call with two whose refusal is swallowed by `|| true` would trash
# the file and the shell would never hear. So the call's third argument is empty, and a call that fails is not
# silent: the file IS trashed, but the shell was not told, which is exit 3 and a line on stderr (the callers run this
# detached, so the exit status is for a terminal and for tests).
set -u
file="${1:-}"
[ -n "$file" ] || { echo "usage: $0 <file.png>" >&2; exit 2; }
if [ -e "$file" ]; then
    if ! { command -v gio > /dev/null 2>&1 && gio trash -- "$file" > /dev/null 2>&1; }; then
        rm -f -- "$file" || exit 1
    fi
fi
if ! told=$(quickshell ipc call osd capture deleted "$file" "" 2>&1); then
    echo "shot_trash: trashed, but the shell was not told: $told" >&2
    exit 3
fi
