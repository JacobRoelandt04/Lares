"""What is installed and what is in place: the `have` table of the watch line and the rows of `doctor`."""
import os
import shutil
import subprocess

from . import kdc as kdclib
from . import parse

_version_cache = {}


def which(name):
    return shutil.which(name) or ""


def scrcpy_version():
    """"5.0.1" or "" -- one `scrcpy --version` per binary (path + mtime), 3 s at most."""
    p = which("scrcpy")
    if not p:
        return ""
    try:
        key = (p, os.stat(p).st_mtime)
    except OSError:
        return ""
    if key not in _version_cache:
        try:
            r = subprocess.run([p, "--version"], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=3)
            _version_cache[key] = parse.parse_scrcpy_version(r.stdout + r.stderr) or "unknown"
        except (OSError, subprocess.TimeoutExpired):
            _version_cache[key] = "unknown"
    return _version_cache[key]


def have():
    return {"adb": bool(which("adb")), "scrcpy": scrcpy_version(), "aft": bool(which("aft-mtp-mount")),
            "sshfs": bool(which("sshfs")), "fusermount": bool(which("fusermount3"))}


def usb_mount_ok(paths, cfg):
    d = paths.expand(cfg["files"]["usbMount"])
    return os.path.isdir(d) and os.access(d, os.W_OK | os.X_OK)


def kdc_installed():
    return kdclib.installed(which)


def rows(paths, cfg, env):
    """[{id, ok, text, hint}]: env is the watch line's env (kdeconnect state, have)."""
    h = env["have"]
    d = paths.expand(cfg["files"]["usbMount"])
    opener = cfg["files"]["open"][0]
    out = []

    def row(i, ok, text, hint=""):
        out.append({"id": i, "ok": bool(ok), "text": text, "hint": "" if ok else hint})
    row("adb", h["adb"], "adb is installed" if h["adb"] else "adb is not installed", "sudo pacman -S android-tools")
    row("scrcpy", h["scrcpy"], "scrcpy %s is installed" % h["scrcpy"] if h["scrcpy"] else "scrcpy is not installed",
        "sudo pacman -S scrcpy")
    row("aft", h["aft"], "aft-mtp-mount is installed" if h["aft"] else "aft-mtp-mount is not installed (the cable's files)",
        "sudo pacman -S android-file-transfer")
    row("fusermount", h["fusermount"], "fusermount3 is installed" if h["fusermount"] else "fusermount3 is not installed",
        "sudo pacman -S fuse3")
    row("sshfs", h["sshfs"], "sshfs is installed" if h["sshfs"] else "sshfs is not installed (KDE Connect's Wi-Fi files)",
        "sudo pacman -S sshfs")
    row("systemd-run", bool(which("systemd-run")), "systemd-run is installed", "systemd is required to run jobs")
    k = env["kdeconnect"]
    row("kdeconnect", k != "missing", "KDE Connect is installed" if k != "missing" else "KDE Connect is not installed",
        "sudo pacman -S kdeconnect")
    if k != "missing":
        row("kdeconnectd", k == "running", "KDE Connect is running" if k == "running" else "KDE Connect is not running",
            "Start kdeconnectd (it starts with the session)")
    row("usbMount", usb_mount_ok(paths, cfg), "%s is a folder you can mount on" % d,
        "sudo mkdir -p %s && sudo chown $USER %s" % (d, d))
    row("opener", bool(which(opener)), "%s opens a mounted phone" % opener, "Install %s or change files.open in bridge.jsonc" % opener)
    return out


def plain(rs):
    """Lines for `lares setup`: `ok   <text>` or `MISSING <text> -- <hint>`."""
    return ["%s %s%s" % ("ok     " if r["ok"] else "MISSING", r["text"], "" if r["ok"] or not r["hint"] else " -- " + r["hint"])
            for r in rs]
