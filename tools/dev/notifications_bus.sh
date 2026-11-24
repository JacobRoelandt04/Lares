#!/usr/bin/env bash
# Run a command on a PRIVATE session bus with no activatable services.
#   tools/dev/notifications_bus.sh <command...>
# Every notification probe runs under this: the server it starts owns
# org.freedesktop.Notifications only there (on the user's bus that name is
# mako's), and nothing -- no portal, no mako -- is D-Bus-activated inside it.
# The command's environment carries LARES_TEST_BUS=1: "this bus was made for a test"
# (tools/dev/smoke.sh keeps a bus that says so, and makes one of its own otherwise).
HERE="$(cd "$(dirname "$0")" && pwd)"
exec env LARES_TEST_BUS=1 dbus-run-session --config-file="$HERE/fixtures/notifications/dbus-session.conf" -- "$@"
