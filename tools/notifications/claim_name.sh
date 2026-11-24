#!/usr/bin/env bash
# Free org.freedesktop.Notifications for the notifications mockup's LIVE mode,
# by stopping mako -- and only mako.
#
#   tools/notifications/claim_name.sh            stop mako if it owns the name
#   tools/notifications/claim_name.sh --dry-run  say who owns it, touch nothing
#
# 1. Asks the bus who owns the name (NameHasOwner). Nobody: exit 0, "free".
# 2. Asks for the owner's pid (GetConnectionUnixProcessID) and reads
#    /proc/<pid>/comm. Anything but "mako": exit 2 and leave it alone -- a
#    second shell, dunst, a probe: none of them is ours to stop.
# 3. Sends TERM to THAT pid (never a name match, never pkill) and waits up to
#    5 s for the name to be released. Freed: exit 0. Still owned: exit 3.
#
# mako is also D-Bus-activated (/usr/share/dbus-1/services/
# fr.emersion.mako.service): the next notification sent before the mockup has
# registered, or after it exits, starts it again. That is the way back; this
# script never disables anything.
#
# Runs against whatever bus DBUS_SESSION_BUS_ADDRESS names (the probes run it
# under tools/dev/notifications_bus.sh).
set -u
NAME=org.freedesktop.Notifications
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

dbus() {  # method arg
    gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method "org.freedesktop.DBus.$1" "$2" 2>/dev/null
}
owned() {
    dbus NameHasOwner "$NAME" | grep -q "true"
}

if ! owned; then
    echo "free: nobody owns $NAME"
    exit 0
fi
# The reply is "(uint32 12345,)": the number after the type, not the 32 in it.
pid=$(dbus GetConnectionUnixProcessID "$NAME" | sed -nE 's/.*uint32 ([0-9]+).*/\1/p')
if [ -z "$pid" ]; then
    echo "owned, but the bus did not say by whom: leaving it"
    exit 2
fi
comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo "?")
if [ "$comm" != "mako" ]; then
    echo "owned by $comm (pid $pid), not mako: leaving it"
    exit 2
fi
if [ "$DRY" = 1 ]; then
    echo "owned by mako (pid $pid); --dry-run: not stopped"
    exit 0
fi
kill -TERM "$pid" || { echo "could not signal mako (pid $pid)"; exit 3; }
for _ in $(seq 1 50); do
    if ! owned; then
        echo "freed: mako (pid $pid) stopped, $NAME is free"
        exit 0
    fi
    sleep 0.1
done
echo "mako (pid $pid) was sent TERM but $NAME is still owned after 5 s"
exit 3
