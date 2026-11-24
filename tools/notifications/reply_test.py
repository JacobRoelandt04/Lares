#!/usr/bin/env python3
"""Send ONE notification that carries an inline-reply box, and say what comes back.

    tools/notifications/reply_test.py                  one notification, wait 60 s for a reply
    tools/notifications/reply_test.py --wait 120       wait longer
    tools/notifications/reply_test.py --summary Anna --body "Are you coming tonight?" \\
                                      --placeholder "Reply to Anna"
    tools/notifications/reply_test.py --json           the one line of JSON a script can read

WHY IT EXISTS. `notify-send` cannot make a notification with a reply box: libnotify's tool has
no way to add the `inline-reply` action or to listen for the answer. A sender that wants one
(KDE Connect's SMS notification, a chat client built for it) adds an action named `inline-reply`
and, optionally, the KDE hint `x-kde-reply-placeholder-text`; the server shows a text field, and
when the user sends it, emits `NotificationReplied(id, text)` to the sender and closes the
notification. This script is that sender, and it prints what it hears.

WHAT IT PRINTS. The server on the session bus (the shell's, once it owns the name), whether it
ADVERTISES `inline-reply` among its capabilities, then the notification's id, then each signal
that names it -- ActionInvoked (a button, or the body: `default`), NotificationReplied (the
text typed), NotificationClosed (with its reason) -- and, at the end, a verdict:

    replied "on my way"         exit 0   the box worked: the text reached the sender
    closed without a reply      exit 3   the notification went (swiped, timed out, a button) unanswered
    no answer in N s            exit 4   the notification is still up (close it with `--close ID`)

If the server does not advertise `inline-reply` the notification is still sent and the verdict says
what happened (a server that does not know the action shows a plain notification).

Signal Desktop, for one, never sends the action on Linux: its notification is the web API's
`new Notification(title, { body, icon, silent, tag })` with a click, nothing else (Signal 8.31,
`/usr/lib/signal-desktop/resources/app.asar`, bundles/preload/main.js `rawNotify`), so no
notification server can show a reply box for it. This script is the way to see the box.

WITHOUT PYTHON, the same notification from a terminal (the box appears on the toast; the reply goes to
the sender, which here is gdbus and not listening -- watch it with `gdbus monitor --session --dest
org.freedesktop.Notifications`, or use this script, which prints it). This is the line to send
to the shell's server on a private bus (GDBUS):

    gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.Notify "Reply test" 0 "mail-message-new" "Gdbus Anna" "Are we still on for tonight?" "['inline-reply', 'Reply']" "{'x-kde-reply-placeholder-text': <'Reply to Anna'>}" 20000

It talks to whatever bus DBUS_SESSION_BUS_ADDRESS names: the user's own for the real shell; the
probes run it under tools/dev/notifications_bus.sh.
"""
import argparse
import json
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

NAME = "org.freedesktop.Notifications"
PATH = "/org/freedesktop/Notifications"
IFACE = "org.freedesktop.Notifications"
REASONS = {1: "expired", 2: "dismissed", 3: "closed by a call", 4: "undefined"}


def say(args, text):
    if not args.json:
        print(text, flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--summary", default="Anna")
    ap.add_argument("--body", default="Are we still on for tonight? I can move the table if you are late.")
    ap.add_argument("--app", default="Reply test")
    ap.add_argument("--icon", default="mail-message-new")
    ap.add_argument("--placeholder", default="Reply to Anna", help="the reply box's placeholder (the KDE hint)")
    ap.add_argument("--wait", type=float, default=60.0, help="seconds to wait for an answer")
    ap.add_argument("--timeout", type=int, default=-1, help="expire_timeout in ms (-1: the server's default)")
    ap.add_argument("--no-reply-action", action="store_true", help="send the same notification WITHOUT the inline-reply action (what Signal sends)")
    ap.add_argument("--close", type=int, metavar="ID", help="close notification ID and exit")
    ap.add_argument("--json", action="store_true", help="print one line of JSON at the end, nothing else")
    args = ap.parse_args()

    DBusGMainLoop(set_as_default=True)
    try:
        bus = dbus.SessionBus()
        server = dbus.Interface(bus.get_object(NAME, PATH), IFACE)
        if args.close:
            server.CloseNotification(dbus.UInt32(args.close))
            say(args, "closed %d" % args.close)
            return 0
        info = [str(x) for x in server.GetServerInformation()]
        caps = [str(c) for c in server.GetCapabilities()]
    except dbus.exceptions.DBusException as e:
        msg = "no notification server on the session bus (%s)" % e.get_dbus_name()
        print(json.dumps({"error": msg}) if args.json else msg, file=sys.stderr if not args.json else sys.stdout)
        return 2

    advertised = "inline-reply" in caps
    say(args, "server: %s %s (spec %s), by %s" % (info[0], info[2], info[3], info[1]))
    say(args, "capabilities: %s" % " ".join(sorted(caps)))
    say(args, "inline-reply advertised: %s" % ("yes" if advertised else "NO -- this server will not show a reply box"))

    actions = ["default", "Open"]
    if not args.no_reply_action:
        actions += ["inline-reply", "Reply"]
    hints = {"desktop-entry": dbus.String("reply-test")}
    if not args.no_reply_action:
        hints["x-kde-reply-placeholder-text"] = dbus.String(args.placeholder)

    events = []
    loop = GLib.MainLoop()
    state = {"id": None, "closed": False}
    t0 = time.time()

    def on_signal(*a, **kw):
        member = kw.get("member")
        if state["id"] is None or not a or int(a[0]) != state["id"]:
            return
        rest = [str(x) for x in a[1:]]
        events.append({"signal": member, "args": rest, "t": round(time.time() - t0, 2)})
        if member == "ActionInvoked":
            say(args, "  ActionInvoked  %s" % ", ".join(rest))
        elif member == "NotificationReplied":
            say(args, "  NotificationReplied  %r" % rest[0])
            GLib.timeout_add(150, loop.quit)
        elif member == "NotificationClosed":
            say(args, "  NotificationClosed  %s" % REASONS.get(int(a[1]), a[1]))
            state["closed"] = True
            GLib.timeout_add(150, loop.quit)

    bus.add_signal_receiver(on_signal, dbus_interface=IFACE, path=PATH, member_keyword="member")
    nid = int(server.Notify(args.app, dbus.UInt32(0), args.icon, args.summary, args.body,
                            dbus.Array(actions, signature="s"), dbus.Dictionary(hints, signature="sv"),
                            dbus.Int32(args.timeout)))
    state["id"] = nid
    say(args, "sent notification %d%s; waiting up to %d s for an answer..." % (
        nid, "" if not args.no_reply_action else " (NO inline-reply action)", args.wait))
    GLib.timeout_add(int(args.wait * 1000), loop.quit)
    loop.run()

    replies = [e for e in events if e["signal"] == "NotificationReplied"]
    if replies:
        verdict, code = "replied %s" % json.dumps(replies[0]["args"][0]), 0
    elif state["closed"]:
        verdict, code = "closed without a reply", 3
    else:
        verdict, code = "no answer in %d s (notification %d is still up: --close %d)" % (args.wait, nid, nid), 4
    if args.json:
        print(json.dumps({"id": nid, "advertised": advertised, "capabilities": sorted(caps), "server": info,
                          "events": events, "verdict": verdict, "exit": code,
                          "replied": replies[0]["args"][0] if replies else None}))
    else:
        print(verdict)
    return code


if __name__ == "__main__":
    sys.exit(main())
