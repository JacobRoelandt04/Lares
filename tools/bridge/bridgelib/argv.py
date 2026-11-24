"""Every external argv of the tool, built here and nowhere else (pure)."""
import re

KEYCODES = {"power": 26, "volup": 24, "voldown": 25}
VIDEO_MODES = ("mirror", "desktop", "camera")


def scrcpy(cfg, mode, serial, via, title="", screen_off=False, record_path=""):
    """scrcpy for a mode over a transport (usb | tcp); always `-s <serial>`. The sizes come from the config's usb / wifi block."""
    a = ["scrcpy", "-s", serial]
    if title:
        a += ["--window-title", title]
    if mode == "desktop":
        a += ["--new-display"]
    elif mode == "camera":
        a += ["--video-source=camera", "--no-control"]
    elif mode == "audio":
        a += ["--no-video", "--no-control"]
    if mode in VIDEO_MODES:
        m = cfg["mirror"]["usb" if via == "usb" else "wifi"]
        if m["maxSize"]:
            a += ["--max-size=%d" % m["maxSize"]]
        if m["bitRate"]:
            a += ["--video-bit-rate=%s" % m["bitRate"]]
        if m["maxFps"]:
            a += ["--max-fps=%d" % m["maxFps"]]
    if screen_off and mode in ("mirror", "desktop"):
        a += ["--turn-screen-off"]
        if via == "usb":
            a += ["--stay-awake"]
    if record_path:
        a += ["--record=" + record_path]
    return a + list(cfg["mirror"]["extraArgs"])


def record_name(mode, stamp):
    return "phone-%s.%s" % (stamp, "mka" if mode == "audio" else "mp4")


def systemd_run(kind, job_id, tool, argv):
    return ["systemd-run", "--user", "--scope", "--collect", "--quiet", "--expand-environment=no",
            "--unit=lares-bridge-%s-%s" % (kind, job_id), "--", "setsid", "-f", tool, "_run", job_id, "--"] + list(argv)


def adb(*args, serial=None):
    return ["adb"] + (["-s", serial] if serial else []) + list(args)


def adb_connect(addr):
    return adb("connect", addr)


def adb_tcpip(serial, port):
    return adb("tcpip", str(port), serial=serial)


def adb_push(serial, sources, dest):
    return adb("push", *sources, dest.rstrip("/") + "/", serial=serial)


def adb_keyevent(serial, name):
    return adb("shell", "input", "keyevent", str(KEYCODES[name]), serial=serial)


def adb_lockstate(serial, script):
    return adb("shell", script, serial=serial)


def adb_key(serial, code):
    """A key by Android's own name (KEYCODE_WAKEUP, KEYCODE_ENTER)."""
    return adb("shell", "input", "keyevent", code, serial=serial)


def adb_setting_get(serial, ns, name):
    return adb("shell", "settings", "get", ns, name, serial=serial)


def adb_setting_put(serial, ns, name, value):
    return adb("shell", "settings", "put", ns, name, str(int(value)), serial=serial)


def adb_dismiss_keyguard(serial):
    return adb("shell", "wm", "dismiss-keyguard", serial=serial)


def adb_shell_stdin(serial):
    """A shell that reads its commands from stdin (no pty): what is typed into a phone goes there, never into an argv."""
    return adb("shell", "-T", serial=serial)


def adb_usb_calm(serial, on):
    """`svc usb setScreenUnlockedFunctions` with no function = none (the phone keeps USB as it is at an unlock), with `mtp` = File transfer."""
    return adb("shell", "svc", "usb", "setScreenUnlockedFunctions", *(["mtp"] if on else []), serial=serial)


def adb_usb_functions(serial):
    return adb("shell", "svc", "usb", "getFunctions", serial=serial)


def adb_usb_set_functions(serial, name):
    return adb("shell", "svc", "usb", "setFunctions", name, serial=serial)


def adb_usb_unlocked(serial):
    return adb("shell", "dumpsys usb | grep screen_unlocked_functions; true", serial=serial)


def adb_screencap(serial):
    return adb("exec-out", "screencap", "-p", serial=serial)


def adb_facts(serial, script):
    return adb("shell", script, serial=serial)


def aft_mount(point):
    return ["aft-mtp-mount", point]


def fusermount(point, lazy=False):
    return ["fusermount3", "-uz" if lazy else "-u", point]


def opener(cfg, path):
    """files.open with {path} filled in (appended when no element names it)."""
    cmd = list(cfg["files"]["open"])
    if any("{path}" in c for c in cmd):
        return [c.replace("{path}", path) for c in cmd]
    return cmd + [path]


def shot_name(stamp):
    return "phone-%s.png" % stamp


def share_urls(paths):
    from urllib.parse import quote
    return ["file://" + quote(p) for p in paths]


def safe_title(name):
    return re.sub(r"[^\w .\-]", "", name)[:60] or "Phone"
