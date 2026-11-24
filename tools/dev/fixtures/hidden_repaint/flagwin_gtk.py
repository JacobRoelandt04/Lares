"""A GTK 4 window that turns from white to black when the flag file appears. argv: title flag"""
import os
import sys
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk, GLib, Gdk  # noqa: E402

TITLE, FLAG = sys.argv[1], sys.argv[2]


def css(c):
    p = Gtk.CssProvider()
    p.load_from_string("window { background: %s; }" % c)
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), p, 900)


def poll():
    if os.path.exists(FLAG):
        css("black")
        return False
    return True


def act(app):
    w = Gtk.ApplicationWindow(application=app, title=TITLE)
    w.set_default_size(600, 400)
    css("white")
    w.present()
    GLib.timeout_add(60, poll)


a = Gtk.Application(application_id="lares.probe." + TITLE)
a.connect("activate", act)
a.run([])
