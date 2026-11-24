"""What each action can do for a device right now, and why not (`can`): a pure function of the device and the machine.

Optimistic where only trying can tell: a phone reachable over the LAN with adb installed can be mirrored over TCP. `why` is one short
sentence in the user's words, `hint` what to do. With `ok` false they say why it cannot; with `ok` true and `why` set they say why the
LAST try failed (tries, kept until the device's links change) -- a failure is told, never a lock: the action stays pressable and a
press tries again (the user's review 2026-11-19: one failed Wi-Fi shot left the tile dead).
"""

ACTIONS = ("mirror", "mountUsb", "mountWifi", "send", "shot", "ring", "clip", "key", "pair", "unpair", "arm", "facts", "unlock")
TRYABLE = ("mirror", "mountUsb", "mountWifi", "send", "shot", "key", "arm", "facts", "unlock")

HINT_PLUG = "Plug it in once, or pair it for Wireless debugging (Details)"


def ok(via=""):
    return {"ok": True, "why": "", "hint": "", "via": via}


def no(why, hint=""):
    return {"ok": False, "why": why, "hint": hint, "via": ""}


def _kdc_gate(dev, env, need_plugin=None, need_reach=True):
    """None when KDE Connect can serve this device, else the refusal."""
    state = env.get("kdeconnect", "missing")
    if state == "missing":
        return no("KDE Connect is missing", "sudo pacman -S kdeconnect")
    if state != "running":
        return no("KDE Connect is not running")
    k = dev.get("kdc")
    if not k:
        return no("Not paired in KDE Connect")
    if not k["paired"]:
        return no("Not paired")
    if need_reach and not k["reachable"]:
        return no("Out of reach", "Same Wi-Fi as this computer")
    if need_plugin and need_plugin not in k["plugins"]:
        label = {"findmyphone": "Find my phone", "clipboard": "Clipboard sharing", "sftp": "File browsing", "share": "Sharing"}
        return no("%s is off in KDE Connect" % label.get(need_plugin, need_plugin))
    return None


def adb_path(dev, env):
    """(via, None) or (None, refusal): how adb can reach the phone, usb | tcp."""
    have = env["have"]
    if not have.get("adb"):
        return None, no("adb is missing", "sudo pacman -S android-tools")
    a, u, k = dev.get("adb"), dev.get("usb"), dev.get("kdc")
    if a and a["transport"] == "usb" and a["state"] == "device":
        return "usb", None
    if a and a["transport"] == "tcp" and a["state"] == "device":
        return "tcp", None
    if a and a["state"] == "unauthorized":
        return None, no("Not allowed yet", "Accept the prompt on the phone")
    if u and u.get("adbIface"):
        return "usb", None
    if u and not u.get("adbIface"):
        return None, no("USB debugging is off", "Developer options on the phone")
    if a and a["state"] == "offline":
        return None, no("adb sees it offline", "Replug the cable")
    if k and k["reachable"] and k["addresses"]:
        return "tcp", None
    return None, no("adb is not connected", HINT_PLUG)


def can_table(dev, env, cfg, tries=None):
    have = env["have"]
    out = {}
    a, u, k = dev.get("adb"), dev.get("usb"), dev.get("kdc")
    via, refusal = adb_path(dev, env)

    # mirror
    if refusal:
        out["mirror"] = refusal
    elif not have.get("scrcpy"):
        out["mirror"] = no("scrcpy is missing", "sudo pacman -S scrcpy")
    else:
        out["mirror"] = ok(via)

    # the cable's files
    m = dev.get("mounts", {}).get("usb", {})
    if not have.get("aft"):
        out["mountUsb"] = no("aft-mtp-mount is missing", "sudo pacman -S android-file-transfer")
    elif not have.get("fusermount"):
        out["mountUsb"] = no("fusermount3 is missing", "sudo pacman -S fuse3")
    elif m.get("state") in ("mounted", "stale", "mounting"):
        out["mountUsb"] = ok()
    elif not u:
        out["mountUsb"] = no("No cable")
    elif not env.get("usbMountDirOk", True):
        d = cfg["files"]["usbMount"]
        out["mountUsb"] = no("%s is missing" % d, "sudo mkdir -p %s && sudo chown $USER %s" % (d, d))
    elif not u.get("mtpIface") and not u.get("adbIface"):
        # with adb on the cable `mount` asks the phone for File transfer itself (svc usb setFunctions mtp)
        out["mountUsb"] = no("USB mode is not File transfer", "Choose it in the phone's USB notification")
    else:
        out["mountUsb"] = ok()

    # the Wi-Fi files (KDE Connect's sftp)
    m = dev.get("mounts", {}).get("wifi", {})
    if not have.get("sshfs"):
        out["mountWifi"] = no("sshfs is missing", "sudo pacman -S sshfs")
    elif m.get("state") in ("mounted", "stale", "mounting"):
        out["mountWifi"] = ok()
    else:
        out["mountWifi"] = _kdc_gate(dev, env, "sftp") or ok()

    # send
    if via in ("usb", "tcp") and a and a["state"] == "device":
        out["send"] = ok("adb")
    else:
        g = _kdc_gate(dev, env, "share")
        if g is None:
            out["send"] = ok("kdeconnect")
        else:
            out["send"] = no("Out of reach")

    out["shot"] = refusal or ok()
    out["key"] = refusal or ok()
    out["facts"] = refusal or ok()
    # unlock: an adb path and a PIN kept in the keyring that did not fail last time (Android throttles and escalates wrong
    # attempts: a failed PIN is never typed again until it is set again)
    pin = dev.get("pin", "none")
    if refusal:
        out["unlock"] = refusal
    elif pin == "none":
        out["unlock"] = no("No PIN kept", "Set it on the Details page")
    elif pin == "failed":
        out["unlock"] = no("The PIN failed last time", "Set it again on the Details page")
    else:
        out["unlock"] = ok(via)
    out["ring"] = _kdc_gate(dev, env, "findmyphone") or ok()
    out["clip"] = _kdc_gate(dev, env, "clipboard") or ok()

    if not k:
        out["pair"] = no("Open KDE Connect on the phone")
    elif k["paired"]:
        out["pair"] = no("Already paired")
    elif not k["reachable"]:
        out["pair"] = no("Out of reach", "Same Wi-Fi as this computer")
    elif k["pairRequested"]:
        out["pair"] = no("Waiting for the phone", "Accept it there")
    elif k["pairRequestedByPeer"]:
        out["pair"] = no("The phone asks to pair")
    elif env.get("kdeconnect") != "running":
        out["pair"] = no("KDE Connect is not running")
    else:
        out["pair"] = ok()
    out["unpair"] = ok() if k and k["paired"] and env.get("kdeconnect") == "running" else \
        no("Not paired" if k else "Not paired in KDE Connect")

    if a and a["transport"] == "usb" and a["state"] == "device" and have.get("adb"):
        out["arm"] = ok()
    elif refusal and (a or u):
        out["arm"] = refusal
    else:
        out["arm"] = no("No cable")
    if out["arm"]["ok"] is False and not have.get("adb"):
        out["arm"] = refusal

    for act, t in (tries or {}).items():
        if act in TRYABLE and out.get(act, {}).get("ok"):
            out[act] = dict(out[act], why=t.get("reason", "") or "The last try failed", hint=t.get("hint", ""))
    return {a_: out[a_] for a_ in ACTIONS}
