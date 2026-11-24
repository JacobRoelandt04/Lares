"""The phone's unlock PIN, kept in the login keyring (the Secret Service: gnome-keyring here) through `secret-tool`.

Attributes: service=lares-bridge, device=<the KDE Connect id, or the device key when there is none>; label "Lares bridge: unlock PIN
for <device name>". The PIN is handed over ONLY on a pipe: `store` writes it to secret-tool's stdin, `lookup` reads it from its stdout.
It is never in an argv, a file, an environment variable, the trace (these calls do not go through actions._exec, which traces the tail
of the output), a log or an answer. A caller keeps the string only as long as it needs to type it.

`locked()` asks the Secret Service over D-Bus WITHOUT prompting (the default collection's `Locked` property, no auto-start): a locked
keyring is never unlocked by this tool -- it opens with the user's password at the lock screen, and a prompt must never pop up because a
popup opened.

Tests need no hook: the probe puts a file-backed `secret-tool` first on PATH and a fake Secret Service on its private session bus
(tools/dev/stubs/bridge/bin/secret-tool, fake_secretservice.py).
"""
import re
import subprocess

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

SERVICE = "lares-bridge"
PIN_RE = re.compile(r"[0-9A-Za-z]{4,16}")
BUS = "org.freedesktop.secrets"
COLLECTION = "/org/freedesktop/secrets/aliases/default"


def valid(pin):
    return bool(PIN_RE.fullmatch(pin or ""))


def label(name):
    return "Lares bridge: unlock PIN for %s" % name


def locked():
    """True when the default collection is locked, False when it is open, None when no Secret Service answers (never started: asking
    does not start it, and never prompts)."""
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        r = bus.call_sync(BUS, COLLECTION, "org.freedesktop.DBus.Properties", "Get",
                          GLib.Variant("(ss)", ("org.freedesktop.Secret.Collection", "Locked")), GLib.VariantType("(v)"),
                          Gio.DBusCallFlags.NO_AUTO_START, 3000, None)
        return bool(r.unpack()[0])
    except GLib.Error:
        return None


def _run(args, stdin=None, timeout=10):
    try:
        r = subprocess.run(["secret-tool"] + args, input=stdin, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (subprocess.TimeoutExpired, OSError):
        return 127, ""


def store(device, name, pin):
    """True when the keyring kept the PIN."""
    rc, _ = _run(["store", "--label=" + label(name), "service", SERVICE, "device", device], stdin=pin)
    return rc == 0


def lookup(device):
    """The PIN, or None when none is kept (or the keyring would not say)."""
    rc, out = _run(["lookup", "service", SERVICE, "device", device])
    pin = out.strip("\r\n")
    return pin if rc == 0 and valid(pin) else None


def clear(device):
    rc, _ = _run(["clear", "service", SERVICE, "device", device])
    return rc == 0
