#!/usr/bin/env python3
"""A stand-in for an app that restores its own windows (a browser, an editor): ONE process, one window per line of the
titles file, opened by itself wherever the compositor puts them. tools/dev/session_env_probe.sh starts it inside the
nested Hyprland only.

    stub_multi.py <titles file> [<app id>]
"""
import sys

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, Gtk  # noqa: E402

titles = [t for t in open(sys.argv[1], encoding="utf-8").read().splitlines() if t.strip()]
app_id = sys.argv[2] if len(sys.argv) > 2 else "stub.multi"


def activate(app):
    for t in titles:
        w = Gtk.ApplicationWindow(application=app, title=t)
        w.set_default_size(500, 300)
        w.set_child(Gtk.Label(label=t))
        w.present()


app = Gtk.Application(application_id=app_id, flags=Gio.ApplicationFlags.NON_UNIQUE)
app.connect("activate", activate)
app.run([])
