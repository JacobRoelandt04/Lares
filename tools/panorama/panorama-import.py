#!/usr/bin/env python3
"""tools/panorama/panorama-import.py -- `lares panorama-import [--dry-run]`: Panorama takes over the monitor config, ONCE.

What it does (the user's decision 6: "Panorama owns all"):
  - reads ~/.config/hypr/config/monitors.lua (every `hl.monitor({...})` that is not commented out);
  - keeps the laptop panel's block and every external block that places a display (mode, position, scale ...) as Panorama
    setups: the panel bound to its live description (a read-only `hyprctl -j monitors all`), an external as a placeholder
    `port:<connector>` that takes the identity of the first real display seen on that port;
  - DROPS a mirror block (the old "mirror every HDMI display" rule: a never-seen display is extended and asked now) and every
    `hl.workspace_rule` (the split is Panorama's);
  - writes ~/.local/state/lares/panorama/setups.json and the generated ~/.config/hypr/config/panorama.lua
    (tools/panorama/generate.py);
  - in hyprland.lua, replaces `require("config/monitors")` by `pcall(require, "config/panorama")`;
  - replaces monitors.lua by a one-line note (the original is in the backup);
  - backs up both edited files under ~/.local/state/lares/panorama/import-<date>/ first;
  - loads the engine live (`hyprctl eval 'dofile("<panorama.lua>")'`, never `hyprctl reload`). The setups equal what is in
    force, so nothing moves.

It shows the plan and the diffs and writes nothing until `yes` is typed (the cleanup-marks pattern). A file that changed while
the plan was shown refuses the whole run. A second run has nothing to do. HYPR_DIR / LARES_STATE / HYPRCTL may point it at a fake
home (tools/dev/lares_deploy_probe.sh).
"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
HYPR = os.environ.get("HYPR_DIR") or os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), "hypr")
STATE = os.environ.get("LARES_STATE") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "lares")
HYPRCTL = os.environ.get("HYPRCTL", "hyprctl")

# The same two lines lares-config.py's `check` looks for (its "monitors (Panorama)" section).
REQ_MONITORS = re.compile(r'^(\s*)(?:pcall\(\s*require\s*,\s*|require\s*\(?\s*)["\']config/monitors["\']\s*\)?\s*$')
REQ_PANORAMA = re.compile(r'^\s*pcall\(\s*require\s*,\s*["\']config/panorama["\']\s*\)')
PANORAMA_LINE = 'pcall(require, "config/panorama")   -- Lares Panorama: the displays (generated; arrange them in the popup)'
INTERNAL = re.compile(r"^(eDP|LVDS|DSI)-")


class Refused(Exception):
    pass


def tilde(p):
    return "~" + p[len(HOME):] if p.startswith(HOME + os.sep) else p


def sha(b):
    return hashlib.sha256(b).hexdigest()


def strip_comments(text):
    """Lua comments out (`--` to the end of the line, `--[[ ]]` blocks), strings kept."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c:
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("--[[", i):
            j = text.find("]]", i)
            i = n if j < 0 else j + 2
        elif text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def calls(text, name):
    """The `{...}` table text of every `name({...})` call."""
    res, pat = [], re.compile(re.escape(name) + r"\s*\(\s*\{")
    for m in pat.finditer(text):
        i, depth, j = m.end() - 1, 0, m.end() - 1
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        res.append(text[i + 1:j])
    return res


def fields(table):
    """key = value pairs of a flat Lua table (strings, numbers, booleans)."""
    out = {}
    for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'|true|false|-?[0-9.]+)', table):
        k, v = m.group(1), m.group(2)
        if v[0] in "\"'":
            out[k] = v[1:-1]
        elif v in ("true", "false"):
            out[k] = v == "true"
        else:
            out[k] = float(v) if "." in v else int(v)
    return out


def spec_of(f):
    pos = str(f.get("position", "0x0"))
    m = re.match(r"^(-?\d+)x(-?\d+)$", pos)
    return {
        "enabled": not f.get("disabled", False),
        "mode": str(f.get("mode", "preferred")),
        "position": [int(m.group(1)), int(m.group(2))] if m else [0, 0],
        "scale": f.get("scale", "auto") if f.get("scale") != "auto" else "auto",
        "transform": int(f.get("transform", 0)) % 4,
        "mirror": False,
        "vrr": int(f.get("vrr", 0)),
        "bitdepth": int(f.get("bitdepth", 8)),
        "cm": str(f.get("cm", "srgb")),
        "sdrbrightness": float(f.get("sdrbrightness", 1)),
        "sdrsaturation": float(f.get("sdrsaturation", 1)),
    }


def live_identity(name):
    """The panel's description from a read-only `hyprctl -j monitors all` (None when Hyprland does not answer)."""
    try:
        out = subprocess.run([HYPRCTL, "-j", "monitors", "all"], capture_output=True, text=True, timeout=5).stdout
        for m in json.loads(out):
            if m.get("name") == name:
                d = re.sub(r"[ \t\r\n]+", " ", m.get("description") or "").strip()
                return d or None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    return None


def set_key(ids):
    return " + ".join(sorted(ids, key=lambda s: s.encode("utf-8")))   # BYTE order, as PanoramaModel.setKeyOf


def plan_import():
    hl = os.path.join(HYPR, "hyprland.lua")
    mon = os.path.join(HYPR, "config", "monitors.lua")
    if not os.path.isfile(hl):
        raise Refused("%s is not there" % tilde(hl))
    hl_bytes = open(hl, "rb").read()
    hl_text = hl_bytes.decode("utf-8")
    lines = hl_text.split("\n")
    req_at = [i for i, l in enumerate(lines) if REQ_MONITORS.match(l)]
    has_pan = any(REQ_PANORAMA.match(l) for l in lines)
    if has_pan and not req_at:
        return None   # done before
    if not req_at and not has_pan:
        raise Refused("%s has no require(\"config/monitors\") line to replace: add `%s` to it yourself" % (tilde(hl), PANORAMA_LINE.split("   ")[0]))
    if len(req_at) > 1:
        raise Refused("%s requires config/monitors %d times" % (tilde(hl), len(req_at)))
    new_lines = list(lines)
    i = req_at[0]
    indent = REQ_MONITORS.match(lines[i]).group(1)
    if has_pan:
        del new_lines[i]
    else:
        new_lines[i] = indent + PANORAMA_LINE
    new_hl = "\n".join(new_lines)

    mon_bytes = open(mon, "rb").read() if os.path.isfile(mon) else b""
    mon_text = mon_bytes.decode("utf-8")
    body = strip_comments(mon_text)
    kept, dropped = [], []
    for t in calls(body, "hl.monitor"):
        f = fields(t)
        out = str(f.get("output", ""))
        if out == "":
            dropped.append("the catch-all rule (Panorama registers its own)")
        elif f.get("mirror"):
            dropped.append("%s: mirrors %s (a never-seen display is extended now, and its toast offers Mirror)" % (out, f["mirror"]))
        elif out.startswith("desc:"):
            dropped.append("%s: a description rule (Panorama keys displays by their description itself)" % out)
        else:
            kept.append((out, spec_of(f)))
    for t in calls(body, "hl.workspace_rule"):
        f = fields(t)
        dropped.append("workspace %s on %s (the split is Panorama's: a row of workspace chips per display)" % (f.get("workspace"), f.get("monitor")))

    displays, internal_id, ext = {}, None, []
    for out, spec in kept:
        if INTERNAL.match(out):
            d = live_identity(out)
            ident = d or "port:" + out
            displays[ident] = {"label": "Laptop", "custom": False, "internal": True, "port": out, "placeholder": d is None}
            internal_id = (ident, spec)
        else:
            ident = "port:" + out
            displays[ident] = {"label": out, "custom": False, "internal": False, "port": out, "placeholder": True}
            ext.append((ident, spec))
    setups = {}
    now = int(datetime.datetime.now().timestamp())
    if internal_id:
        setups[set_key([internal_id[0]])] = {"name": "", "custom": False, "used": now, "outputs": {internal_id[0]: internal_id[1]}}
        for ident, spec in ext:
            setups[set_key([internal_id[0], ident])] = {"name": "", "custom": False, "used": 0,
                                                       "outputs": {internal_id[0]: internal_id[1], ident: spec}}
    data = {"v": 1, "displays": displays, "setups": setups, "split": {}}
    note = ("-- The displays are Panorama's now (Lares): arrange them in the popup. The generated file is config/panorama.lua;\n"
            "-- this file's old rules are kept in @BACKUP@/monitors.lua.\n")
    return {"hl": hl, "hl_bytes": hl_bytes, "hl_old": hl_text, "hl_new": new_hl, "mon": mon, "mon_bytes": mon_bytes,
            "mon_old": mon_text, "mon_new": note, "kept": kept, "dropped": dropped, "data": data, "panel": internal_id}


def unified(path, old, new):
    lines = difflib.unified_diff(old.splitlines(True), new.splitlines(True), "%s (now)" % tilde(path), "%s (after)" % tilde(path))
    return "".join(l if l.endswith("\n") else l + "\n\\ No newline at end of file\n" for l in lines)


def write_whole(path, data, mode=0o644):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".%s.panorama-import.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def backup_dir():
    base = os.path.join(STATE, "panorama", "import-" + datetime.date.today().isoformat())
    d, n = base, 2
    while os.path.exists(d):
        d, n = "%s-%d" % (base, n), n + 1
    return d


def main():
    ap = argparse.ArgumentParser(prog="lares panorama-import")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    try:
        p = plan_import()
    except Refused as e:
        print("REFUSED: %s -- nothing was written" % e)
        return 1
    if p is None:
        print("nothing to import: hyprland.lua already requires config/panorama")
        return 0
    setups_path = os.path.join(STATE, "panorama", "setups.json")
    lua_path = os.path.join(HYPR, "config", "panorama.lua")
    print("lares panorama-import -- Panorama takes over the monitor config (once). What it keeps, as setups:\n")
    for out, spec in p["kept"]:
        print("  KEEP  %-10s %s at %d,%d scale %s%s" % (out, spec["mode"], spec["position"][0], spec["position"][1], spec["scale"],
                                                        ", %d-bit" % spec["bitdepth"] if spec["bitdepth"] != 8 else ""))
    if p["panel"] and p["panel"][0].startswith("port:"):
        print("        (Hyprland did not answer: the panel is matched by its port until it is seen)")
    for d in p["dropped"]:
        print("  DROP  %s" % d)
    if os.path.exists(setups_path):
        print("\n  REFUSED: %s exists already (a Keep in the popup made it): delete it first to import again" % tilde(setups_path))
        return 1
    print("\n  WILL WRITE %s (the setups)" % tilde(setups_path))
    print("  WILL WRITE %s (generated: the engine + the setups)" % tilde(lua_path))
    bdir = backup_dir()
    p["mon_new"] = p["mon_new"].replace("@BACKUP@", tilde(bdir))
    print("  WILL BACK UP %s and %s to %s/" % (tilde(p["hl"]), tilde(p["mon"]), tilde(bdir)))
    print()
    sys.stdout.write(unified(p["hl"], p["hl_old"], p["hl_new"]))
    if p["mon_bytes"]:
        sys.stdout.write(unified(p["mon"], p["mon_old"], p["mon_new"]))
    if args.dry_run:
        print("\nnothing was changed")
        return 0
    sys.stdout.write("\nType yes to write the files above: ")
    sys.stdout.flush()
    answer = sys.stdin.readline().strip()
    if not sys.stdin.isatty():
        print()
    if answer != "yes":
        print("nothing was written")
        return 1
    for path, before in ((p["hl"], p["hl_bytes"]), (p["mon"], p["mon_bytes"])):
        now = open(path, "rb").read() if os.path.isfile(path) else b""
        if sha(now) != sha(before):
            print("REFUSED: %s changed while the plan was shown -- nothing was written; run it again" % tilde(path))
            return 1
    os.makedirs(bdir, exist_ok=True)
    shutil.copy2(p["hl"], os.path.join(bdir, "hyprland.lua"))
    if p["mon_bytes"]:
        shutil.copy2(p["mon"], os.path.join(bdir, "monitors.lua"))
    print("backed up   %s/" % tilde(bdir))
    write_whole(setups_path, (json.dumps(p["data"], indent=1, sort_keys=True) + "\n").encode("utf-8"))
    print("written     %s" % tilde(setups_path))
    gen = [sys.executable, os.path.join(HERE, "generate.py"), setups_path, os.path.join(HERE, "engine.lua"), lua_path]
    r = subprocess.run(gen, capture_output=True, text=True)
    if r.returncode != 0:
        print("FAILED generating %s: %s -- hyprland.lua and monitors.lua were not touched" % (tilde(lua_path), (r.stdout + r.stderr).strip()))
        return 1
    print("written     %s" % tilde(lua_path))
    mode = os.stat(p["hl"]).st_mode & 0o7777
    write_whole(p["hl"], p["hl_new"].encode("utf-8"), mode)
    print("written     %s" % tilde(p["hl"]))
    if p["mon_bytes"]:
        write_whole(p["mon"], p["mon_new"].encode("utf-8"), os.stat(p["mon"]).st_mode & 0o7777)
        print("written     %s" % tilde(p["mon"]))
    try:
        r = subprocess.run([HYPRCTL, "eval", 'dofile("%s")' % lua_path], capture_output=True, text=True, timeout=10)
        said = (r.stdout + r.stderr).strip()
        print("loaded      the engine in the running Hyprland (%s)" % (said or "no answer"))
    except (OSError, subprocess.TimeoutExpired) as e:
        print("not loaded  (%s): it loads at your next login" % e)
    print("\ndone: plug a display in; open Panorama from the bar to arrange it. `lares binds` checks the line.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
