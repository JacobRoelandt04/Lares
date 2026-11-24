#!/usr/bin/env bash
# wheel_record.sh -- records what this machine's mouse or touchpad really sends a Qt window: wheel events (angle, pixels, phase,
# device), the side buttons, motion and notches while one is held, and the Wayland requests under them. HANDS-ON: it opens a small
# window on the desktop, so it runs only from a terminal or with LARES_SHOW=1, never from a gate or an agent.
#
#   tools/dev/wheel_record.sh            follow the steps in the window; the record is printed at the end and kept in
#                                        ~/.cache/lares-dev/wheel-record.log (and .wayland)
# /usr/lib/qt6/bin/qml, not a quickshell: the same Qt Wayland plugin, and nothing of the running shell is touched.
set -u
cd "$(dirname "$0")/../.." || exit 1
if [ ! -t 1 ] && [ "${LARES_SHOW:-}" != 1 ]; then
    echo "wheel_record: opens a window on your desktop; run it from a terminal (or LARES_SHOW=1)"; exit 1
fi
D="$HOME/.cache/lares-dev"; mkdir -p "$D"
WAYLAND_DEBUG=client QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=wayland QML_DISABLE_DISK_CACHE=1 \
    /usr/lib/qt6/bin/qml tools/dev/qml/wheel_record.qml 2> "$D/wheel-record.wayland" &
P=$!
wait "$P"
grep -a -o 'WR {.*}' "$D/wheel-record.wayland" > "$D/wheel-record.log"
echo "$(grep -c . "$D/wheel-record.log") events recorded in $D/wheel-record.log"
