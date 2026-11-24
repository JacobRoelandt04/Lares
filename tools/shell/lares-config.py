#!/usr/bin/env python3
"""lares-config.py -- reads the user's Hyprland config for tools/shell/lares; called by it only.

    lares-config.py check --ctx CTX.json [--summary]     `lares binds`: the lines the shell needs, and how the config compares
    lares-config.py cleanup-marks --state DIR --persist DIR [--file PATH]... [--dry-run]
                                                      `lares cleanup-marks`: the one write -- see CLEANUP below

CHECK. The config is Lua (Hyprland 0.57): every `.lua` file under the Hyprland config dir is read, comments and strings
skipped, and every call of hl.bind / hl.exec_cmd / hl.env / hl.layer_rule is taken with its arguments (a call may span
lines). A key is compared by what Hyprland binds -- the modifier mask and the key, case folded -- so "SUPER + SHIFT + S" and
"SHIFT + SUPER + S" are one key. Each line the shell needs (CTX: its keys, layer rules, the environment line, the autostart
lines) is one of
    ok        the config has it
    MISSING   the config does not have it: the line to add, and where
    CONFLICT  the key the shell needs is bound to something else (or bound twice: Hyprland runs every bind of a key)
    DIFFERS   the line is there with another option or value (a volume key without { locked = true } does nothing on the lock)
and every other line of the config that names the shell is checked for
    STALE     a bind of a lares: global the shell does not have, a `lares` command that is gone, a path into the
              deployed snapshot that the snapshot does not have -- and, since the project became Lares, a line that still names
              the OLD name: a quickshell:<name> global (the app id is lares), qs-shell / qs-lock-session / qs-lock-held /
              qs-lock-warm, a path under ~/.local/state/quickshell/{shell,lock}, a layer rule of the qs-bar / qs-curtain
              namespaces. The shell's own line for it is the MISSING one beside it; `lares deploy` keeps a one-line shim at
              each old entry-point name until you have changed the line (`lares cleanup-old-name` refuses before that)
    note      a line that is not wrong, only not needed (the geoclue agent, which `lares start` starts itself)
The exit status is 0 when nothing is MISSING / CONFLICT / DIFFERS / STALE, 1 otherwise. Nothing is written.

CLEANUP. An earlier version of `lares deploy` edited the user's configs and marked every line it touched:
    <c> qs-shell deploy BEGIN <id>[: <why>]     the lines it added follow, up to
    <c> qs-shell deploy END <id>
    <c> qs-shell deploy: <a line it took out>
(<c> is the file's comment: -- Lua, # hyprlang and bash, // JSONC). The cleanup keeps the added lines as plain lines and drops
the BEGIN / END marks and the taken-out lines; a run of blank lines that a dropped block leaves behind becomes one. Every other
line stays byte for byte. The files are the ones named with --file and every file deploy's record (STATE/record.json) names,
except chezmoi's source dir (${XDG_DATA_HOME:-~/.local/share}/chezmoi): chezmoi is not used, so the cleanup never runs it and
leaves its sources exactly as they are (the user's call, 2026-11-10). The plan and its diff are shown, then a typed yes; before anything is written every
file is read again, and one that changed since the plan REFUSES the run. Each file is written whole (a temp file renamed over
it, its mode kept); a failed write puts back what this run wrote. Then deploy's record goes: STATE (record.json, deploy.json,
originals/ -- the files as they were before the first deploy, the user's) is moved into PERSIST/deploy-archive-<date>/, with the
logs an earlier trial left (PERSIST/last-trial/); PERSIST/first-trial-done is removed. REFUSED, with nothing written: a block
that never ends (or an END with no BEGIN, or one inside another), a marked file that is a symlink.
"""
import argparse
import datetime
import difflib
import hashlib
import json
import os
import re
import shlex
import shutil
import sys

MARK_BEGIN = re.compile(r"^\s*(?:--|#|//) qs-shell deploy BEGIN (\S+?)(?::.*)?\s*$")
MARK_END = re.compile(r"^\s*(?:--|#|//) qs-shell deploy END (\S+)\s*$")
MARK_OLD = re.compile(r"^\s*(?:--|#|//) qs-shell deploy:")


class Refused(Exception):
    pass


def sha(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def tilde(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if home and path.startswith(home + "/") else path


# ==================================================================================================
# Lua: the calls of a config file
# ==================================================================================================
def lua_calls(text, names):
    """[(name, line, [arg texts])] for every call of one of the names, outside comments and strings."""
    out, i, n, line = [], 0, len(text), 1
    pat = re.compile(r"(?<![\w.])(" + "|".join(re.escape(x) for x in names) + r")\s*\(")
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif text.startswith("--", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                j = text.find("]" + m.group(1) + "]", i)
                j = n if j < 0 else j + len(m.group(1)) + 2
            else:
                j = text.find("\n", i)
                j = n if j < 0 else j
            line += text.count("\n", i, j)
            i = j
        elif c in "\"'":
            j = skip_string(text, i)
            line += text.count("\n", i, j)
            i = j
        else:
            m = pat.match(text, i)
            if m and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] in "_.")):
                end = balanced(text, m.end() - 1)
                if end is not None:
                    out.append((m.group(1), line, split_args(text[m.end():end - 1])))
                i = m.end()
            else:
                i += 1
    return out


def skip_string(text, i):
    q, j = text[i], i + 1
    while j < len(text):
        if text[j] == "\\":
            j += 2
            continue
        if text[j] == q or text[j] == "\n":
            return j + 1
        j += 1
    return j


def balanced(text, open_at):
    """The index after the ")" that closes the "(" at open_at; None when it never closes."""
    depth, i = 0, open_at
    while i < len(text):
        c = text[i]
        if c in "\"'":
            i = skip_string(text, i)
            continue
        if text.startswith("--", i):
            j = text.find("\n", i)
            i = len(text) if j < 0 else j
            continue
        if c in "({[":
            depth += 1
        elif c in ")}]":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def split_args(s):
    args, depth, cur, i = [], 0, "", 0
    while i < len(s):
        c = s[i]
        if c in "\"'":
            j = skip_string(s, i)
            cur += s[i:j]
            i = j
            continue
        if c in "({[":
            depth += 1
        elif c in ")}]":
            depth -= 1
        if c == "," and depth == 0:
            args.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        args.append(cur.strip())
    return args


ESC = {"n": "\n", "t": "\t", "\\": "\\", '"': '"', "'": "'"}


def lua_string(arg):
    """The value of a single string literal; None for anything else (a variable, a concatenation)."""
    m = re.match(r'^"((?:[^"\\\n]|\\.)*)"$', arg) or re.match(r"^'((?:[^'\\\n]|\\.)*)'$", arg)
    if not m:
        return None
    return re.sub(r"\\(.)", lambda e: ESC.get(e.group(1), e.group(1)), m.group(1))


def modmask_key(spec):   # Hyprland's modifier mask: a lock key is bound WITH its own modifier on 0.57 (CAPS + Caps_Lock, MOD2 + Num_Lock)
    mod, key = 0, ""
    for part in spec.split("+"):
        u = part.strip().upper()
        if u == "SHIFT":
            mod |= 1
        elif u in ("CAPS", "LOCK"):
            mod |= 2
        elif u in ("CTRL", "CONTROL"):
            mod |= 4
        elif u in ("ALT", "MOD1"):
            mod |= 8
        elif u == "MOD2":
            mod |= 16
        elif u == "MOD3":
            mod |= 32
        elif u in ("SUPER", "WIN", "LOGO", "MOD4"):
            mod |= 64
        elif u == "MOD5":
            mod |= 128
        else:
            key = part.strip()
    return mod, key.lower()


def lock_key_unmodded(mk):
    """A bind of Caps_Lock without CAPS, or Num_Lock without MOD2: Hyprland 0.57 holds a lock key's own modifier while the key is down
    and matches binds with it applied, so such a bind never fires (tools/dev/osd_lockkeys_probe.sh)."""
    mod, key = mk
    return (key == "caps_lock" and not mod & 2) or (key == "num_lock" and not mod & 16)


def dispatcher(arg):
    """("global", name) | ("exec", command) | ("other", text)."""
    m = re.match(r"^hl\.dsp\.global\(\s*(.*?)\s*\)$", arg, re.S)
    if m:
        v = lua_string(m.group(1))
        if v is not None and v.startswith("lares:"):
            return ("global", v[len("lares:"):])
        if v is not None and v.startswith("quickshell:"):
            return ("oldglobal", v[len("quickshell:"):])
        return ("other", arg)
    m = re.match(r"^hl\.dsp\.exec_cmd\(\s*(.*?)\s*\)$", arg, re.S)
    if m:
        v = lua_string(m.group(1))
        if v is not None:
            return ("exec", v)
    return ("other", re.sub(r"\s+", " ", arg))


def words(cmd):
    try:
        return shlex.split(cmd)
    except ValueError:
        return cmd.split()


# ==================================================================================================
# check
# ==================================================================================================
class Config:
    def __init__(self, hypr_dir):
        self.binds, self.execs, self.envs, self.rules = [], [], [], []
        files = []
        for d, ds, fs in os.walk(hypr_dir):
            ds[:] = sorted(x for x in ds if not x.startswith("."))
            files += [os.path.join(d, f) for f in sorted(fs) if f.endswith(".lua")]
        for path in files:
            try:
                text = open(path, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError):
                continue
            where = os.path.relpath(path, hypr_dir)
            for name, line, args in lua_calls(text, ["hl.bind", "hl.exec_cmd", "hl.env", "hl.layer_rule"]):
                at = "%s:%d" % (where, line)
                if name == "hl.bind" and len(args) >= 2:
                    keys = lua_string(args[0])
                    if keys is None:
                        continue
                    opts = args[2] if len(args) > 2 else ""
                    self.binds.append({"id": len(self.binds), "at": at, "keys": keys, "mk": modmask_key(keys), "disp": dispatcher(args[1]),
                                       "locked": bool(re.search(r"\blocked\s*=\s*true", opts)),
                                       "nonconsuming": bool(re.search(r"\bnon_consuming\s*=\s*true", opts)), "raw": args})
                elif name == "hl.exec_cmd" and args:
                    v = lua_string(args[0])
                    if v is not None:
                        self.execs.append({"id": len(self.execs), "at": at, "cmd": v})
                elif name == "hl.env" and len(args) >= 2:
                    k, v = lua_string(args[0]), lua_string(args[1])
                    if k is not None:
                        self.envs.append({"at": at, "name": k, "value": v})
                elif name == "hl.layer_rule" and args:
                    t = args[0]
                    nm = re.search(r"\bname\s*=\s*(\"[^\"]*\"|'[^']*')", t)
                    ns = re.search(r"\bnamespace\s*=\s*(\"[^\"]*\"|'[^']*')", t)
                    self.rules.append({"at": at, "name": lua_string(nm.group(1)) if nm else None,
                                       "ns": lua_string(ns.group(1)) if ns else None,
                                       "no_anim": bool(re.search(r"\bno_anim\s*=\s*true", t))})


class Report:
    PROBLEMS = ("MISSING", "CONFLICT", "DIFFERS", "STALE")

    def __init__(self):
        self.sections, self.counts = [], {k: 0 for k in self.PROBLEMS}

    def section(self, title):
        self.sections.append((title, []))

    def row(self, status, label, text, line=None):
        if status in self.counts:
            self.counts[status] += 1
        self.sections[-1][1].append((status, label, text, line))

    def problems(self):
        return sum(self.counts.values())

    def print(self):
        for title, rows in self.sections:
            if not rows:
                continue
            print(title)
            for status, label, text, line in rows:
                print("  %-9s %-30s %s" % (status, label, text))
                if line:
                    print("  %-9s %-30s %s" % ("", "", line))
            print()


def stale_reasons(cmd, ctx):
    """Why an exec command is stale: a `lares` command that is gone, a snapshot path the snapshot does not have."""
    out = []
    w = words(cmd)
    for i, t in enumerate(w):
        if os.path.basename(t) == "lares" and i + 1 < len(w):
            sub = w[i + 1]
            if sub in ctx["removed_commands"]:
                out.append("runs `lares %s`, which is gone (%s)" % (sub, ctx["removed_commands"][sub]))
            elif sub == "binds" and i + 2 < len(w) and w[i + 2] in ("apply", "check"):
                out.append("runs `lares binds %s`, which is gone" % w[i + 2])
    for t in w:
        for link, real in ctx["snapshots"].items():
            if t.startswith(link + "/") and real and not os.path.lexists(real + t[len(link):]):
                out.append("names %s, which the deployed snapshot does not have" % t)
    old = ctx.get("old") or {}
    for t in w:
        new = old.get("names", {}).get(os.path.basename(t))
        if new:
            out.append("runs `%s`, the OLD name (now `%s`)" % (os.path.basename(t), new))
        for root in old.get("roots", []):
            if t == root or t.startswith(root + "/") or ("=" in t and t.split("=", 1)[1].startswith(root)):
                out.append("names %s, the OLD snapshot path (now under %s)" % (t, old["new_state"]))
                break
    return out


def bind_line(ctx, row):
    f = ctx["forms"]
    what = row["what"]
    if what.startswith("global:"):
        disp = f["global"] % what[len("global:"):]
    else:
        disp = f["exec"] % what[len("exec:"):].replace("\\", "\\\\").replace('"', '\\"')
    opt = {"locked": f["opt_locked"], "nonconsuming": f["opt_nonconsuming"]}.get(row["opt"], "")
    return f["bind"] % (row["keys"], disp, opt)


def describe(disp):
    kind, v = disp
    return {"global": "lares:%s" % v, "oldglobal": "quickshell:%s" % v, "exec": "exec_cmd(%s)" % v}.get(kind, v)


def same_exec(a, b):
    return words(a) == words(b)


# The same two lines tools/panorama/panorama-import.py replaces and writes (keep them in step).
PANO_REQ_MONITORS = re.compile(r'^\s*(?:pcall\(\s*require\s*,\s*|require\s*\(?\s*)["\']config/monitors["\']\s*\)?\s*(?:--.*)?$')
PANO_REQ_PANORAMA = re.compile(r'^\s*pcall\(\s*require\s*,\s*["\']config/panorama["\']\s*\)')
PANO_MONITOR_CALL = re.compile(r'^\s*hl\.monitor\s*\(')


def panorama_rows(rep, hypr_dir):
    """The displays are Panorama's (docs/panorama.md): one line requires its generated file, and no other file sets a monitor
    (a rule there beats or fights the engine's). Before `lares panorama-import` the row says to run it."""
    rep.section("displays -- Panorama (the generated config/panorama.lua)")
    gen = os.path.join(hypr_dir, "config", "panorama.lua")
    req, old, others = [], [], []
    for d, _, names in os.walk(hypr_dir):
        for n in sorted(names):
            if not n.endswith(".lua"):
                continue
            path = os.path.join(d, n)
            if os.path.realpath(path) == os.path.realpath(gen):
                continue
            try:
                lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
            except OSError:
                continue
            for i, line in enumerate(lines, 1):
                at = "%s:%d" % (tilde(path), i)
                if PANO_REQ_PANORAMA.match(line):
                    req.append(at)
                elif PANO_REQ_MONITORS.match(line):
                    old.append(at)
                elif PANO_MONITOR_CALL.match(line):
                    others.append(at)
    line = 'pcall(require, "config/panorama")'
    if not req and not old:
        rep.row("MISSING", "panorama", "nothing requires it: `lares panorama-import` moves your monitor config into Panorama (once, a diff and a typed yes)", line)
    elif not req:
        rep.row("MISSING", "panorama", "%s still requires config/monitors: `lares panorama-import` replaces it (once, a diff and a typed yes)" % old[0], line)
    elif not os.path.isfile(gen):
        rep.row("DIFFERS", "panorama", "%s requires it, but %s is not there (it is generated, so a clone of your config never has it): the shell writes it at its next start"
                % (req[0], tilde(gen)))
    else:
        rep.row("ok", "panorama", req[0])
    for at in old if req else []:
        rep.row("STALE", "monitors", "%s requires config/monitors beside Panorama: the two fight over the displays" % at)
    for at in others if req else []:   # before the import, the MISSING row above is the one thing to do
        rep.row("CONFLICT", "hl.monitor", "%s sets a monitor outside Panorama: its rule fights the engine's (arrange it in the popup instead)" % at)


def check(ctx, summary):
    cfg = Config(ctx["hypr_dir"])
    rep = Report()
    files = {k: tilde(v) for k, v in ctx["files"].items()}
    seen_binds = set()

    # ---- the keys ----
    rep.section("keys -- %s (any .lua file of %s counts)" % (files["keybinds"], tilde(ctx["hypr_dir"])))
    for row in ctx["binds"]:
        line = bind_line(ctx, row)
        mk = modmask_key(row["keys"])
        hits = [b for b in cfg.binds if b["mk"] == mk]
        for b in hits:
            seen_binds.add(b["id"])
        if row["what"].startswith("global:"):
            want = ("global", row["what"][len("global:"):])
            good = [b for b in hits if b["disp"] == want]
        else:
            want = ("exec", row["what"][len("exec:"):])
            good = [b for b in hits if b["disp"][0] == "exec" and same_exec(b["disp"][1], want[1])]
        if not hits:
            rep.row("MISSING", row["keys"], "add to %s:" % files["keybinds"], line)
            continue
        others = [b for b in hits if b not in good]
        if good and not others:
            b = good[0]
            opt_ok = (row["opt"] != "locked" or b["locked"]) and (row["opt"] != "nonconsuming" or b["nonconsuming"])
            if not opt_ok:
                what = "{ locked = true }: it does nothing while the screen is locked" if row["opt"] == "locked" \
                    else "{ non_consuming = true }: the key no longer reaches the application"
                rep.row("DIFFERS", row["keys"], "%s binds it without %s" % (b["at"], what), line)
            elif len(good) > 1:
                rep.row("CONFLICT", row["keys"], "bound %d times (%s): Hyprland runs every one" % (len(good), ", ".join(x["at"] for x in good)), line)
            else:
                rep.row("ok", row["keys"], b["at"])
            continue
        for b in others:
            why = []
            if b["disp"][0] == "exec":
                why = stale_reasons(b["disp"][1], ctx)
            elif b["disp"][0] == "oldglobal":
                why = ["binds quickshell:%s, the OLD app id (the shell's is lares)" % b["disp"][1]]
            if why:
                rep.row("STALE", row["keys"], "%s %s; the shell's line:" % (b["at"], "; ".join(why)), line)
            else:
                rep.row("CONFLICT", row["keys"], "%s binds it to %s; the shell's line:" % (b["at"], describe(b["disp"])), line)

    # ---- the layer rules ----
    rep.section("layer rules -- %s" % files["layerrules"])
    for r in ctx["layer_rules"]:
        line = ctx["forms"]["layer_rule"] % (r["name"], r["ns"])
        named = [x for x in cfg.rules if x["name"] == r["name"]]
        same = [x for x in cfg.rules if x["ns"] == r["ns"] and x["no_anim"]]
        if same:
            rep.row("ok", r["name"], same[0]["at"])
        elif named:
            rep.row("DIFFERS", r["name"], "%s names the rule, with another namespace or without no_anim = true:" % named[0]["at"], line)
        else:
            rep.row("MISSING", r["name"], "add to %s:" % files["layerrules"], line)

    # ---- the environment ----
    rep.section("environment -- %s" % files["environment"])
    e = ctx["env"]
    line = ctx["forms"]["env"] % (e["name"], e["value"])
    hits = [x for x in cfg.envs if x["name"] == e["name"]]
    if not hits:
        rep.row("MISSING", e["name"], "add to %s:" % files["environment"], line)
    elif any(x["value"] == e["value"] for x in hits):
        rep.row("ok", e["name"], next(x["at"] for x in hits if x["value"] == e["value"]))
    else:
        x = hits[0]
        why = stale_reasons(x["value"] or "", ctx)
        rep.row("STALE" if why else "DIFFERS", e["name"], "%s sets it to %s%s:" % (x["at"], x["value"], "; " + "; ".join(why) if why else ""), line)

    # ---- the autostart lines ----
    rep.section("autostart -- inside hl.on(\"hyprland.start\", ...) in %s" % files["autostart"])
    used_execs = set()
    for a in ctx["autostart"]:
        line = ctx["forms"]["autostart_exec"] % a["cmd"].replace("\\", "\\\\").replace('"', '\\"')
        hits = [x for x in cfg.execs if same_exec(x["cmd"], a["cmd"])]
        for x in hits:
            used_execs.add(x["id"])
        if hits:
            rep.row("ok", a["label"], hits[0]["at"])
        else:
            rep.row("MISSING", a["label"], "add (%s):" % a["why"], line)

    # ---- the displays (Panorama) ----
    panorama_rows(rep, ctx["hypr_dir"])

    # ---- the rest of the config that names the shell ----
    rep.section("other lines that name the shell")
    globals_ = set(ctx["globals"])
    for b in cfg.binds:
        if b["id"] in seen_binds:
            continue
        if b["disp"][0] == "global" and b["disp"][1] not in globals_:
            rep.row("STALE", b["keys"], "%s binds lares:%s, a global the shell does not have" % (b["at"], b["disp"][1]))
        elif b["disp"][0] == "global" and lock_key_unmodded(b["mk"]):
            rep.row("STALE", b["keys"], "%s binds lares:%s on a bare lock key, which never fires on Hyprland 0.57 (the key is "
                    "matched WITH its own modifier: the shell's line is above)" % (b["at"], b["disp"][1]))
        elif b["disp"][0] == "oldglobal":
            rep.row("STALE", b["keys"], "%s binds quickshell:%s, the OLD app id: the line is hl.dsp.global(\"lares:%s\")" % (b["at"], b["disp"][1], b["disp"][1]))
        elif b["disp"][0] == "exec":
            for why in stale_reasons(b["disp"][1], ctx):
                rep.row("STALE", b["keys"], "%s %s" % (b["at"], why))
    old_ns = (ctx.get("old") or {}).get("namespaces", {})
    for r in cfg.rules:
        if r["ns"] in old_ns:
            rep.row("STALE", "layer rule", "%s names the OLD namespace %s (now %s): the shell's rule is in the layer rules above" % (r["at"], r["ns"], old_ns[r["ns"]]))
    for x in cfg.execs:
        if x["id"] in used_execs:
            continue
        for why in stale_reasons(x["cmd"], ctx):
            rep.row("STALE", "exec_cmd", "%s %s" % (x["at"], why))
        first = (words(x["cmd"]) or [""])[0]
        for n in ctx.get("notes", []):
            if first in n["programs"]:
                rep.row("note", "exec_cmd", "%s %s" % (x["at"], n["note"]))

    counts = rep.counts
    if summary:
        n = rep.problems()
        if n == 0:
            print("your Hyprland config has every line the shell needs")
        else:
            print("%d line(s) of your Hyprland config differ from what the shell needs (%s): lares binds shows them"
                  % (n, ", ".join("%d %s" % (counts[k], k) for k in Report.PROBLEMS if counts[k])))
        return 0 if n == 0 else 1
    rep.print()
    print("%s -- nothing was written" % ", ".join("%d %s" % (counts[k], k) for k in Report.PROBLEMS))
    return 0 if rep.problems() == 0 else 1


# ==================================================================================================
# cleanup-marks
# ==================================================================================================
def clean(text):
    """(new text, marks dropped, old lines dropped). Raises Refused on a block that is not closed properly."""
    nl = text.endswith("\n")
    lines = (text[:-1] if nl else text).split("\n") if text else []
    out, block, marks, old, dropped_since = [], None, 0, 0, False
    for n, line in enumerate(lines, 1):
        m = MARK_BEGIN.match(line)
        if m:
            if block is not None:
                raise Refused("line %d opens block %s inside block %s" % (n, m.group(1), block[0]))
            block = (m.group(1), n)
            marks += 1
            dropped_since = True
            continue
        m = MARK_END.match(line)
        if m:
            if block is None:
                raise Refused("line %d ends block %s, which never began" % (n, m.group(1)))
            if m.group(1) != block[0]:
                raise Refused("line %d ends block %s inside block %s" % (n, m.group(1), block[0]))
            block = None
            marks += 1
            dropped_since = True
            continue
        if MARK_OLD.match(line):
            old += 1
            dropped_since = True
            continue
        if line.strip() == "" and out and out[-1].strip() == "" and dropped_since:
            continue   # a blank run a dropped block leaves behind becomes one blank line
        if line.strip() != "":
            dropped_since = False
        out.append(line)
    if block is not None:
        raise Refused("block %s (line %d) never ends" % block)
    new = "\n".join(out) + ("\n" if nl and out else "")
    return new, marks, old


def has_marks(text):
    return any(MARK_BEGIN.match(l) or MARK_END.match(l) or MARK_OLD.match(l) for l in text.split("\n"))


def unified(path, old, new):
    lines = difflib.unified_diff(old.splitlines(True), new.splitlines(True), "%s (now)" % tilde(path), "%s (cleaned)" % tilde(path))
    return "".join(l if l.endswith("\n") else l + "\n\\ No newline at end of file\n" for l in lines)


def read_text(path):
    with open(path, "rb") as f:
        data = f.read()
    return data, data.decode("utf-8")


def write_whole(path, data, mode):
    d = os.path.dirname(path) or "."
    tmp = os.path.join(d, ".%s.lares-cleanup.%d" % (os.path.basename(path), os.getpid()))
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def plan_cleanup(args):
    files, seen = [], set()
    rec_path = os.path.join(args.state, "record.json")
    rec = {}
    if os.path.exists(rec_path):
        try:
            rec = json.load(open(rec_path)).get("files", {})
        except (OSError, ValueError):
            rec = {}
    for p in list(args.file or []) + sorted(rec):
        if p not in seen:
            seen.add(p)
            files.append(p)
    # chezmoi is not used: its source dir (the record lists hypridle.conf's template there) is left exactly as it is
    cz_dir = os.path.realpath(os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "chezmoi"))
    plan = []
    for path in files:
        if os.path.realpath(path).startswith(cz_dir + os.sep):
            plan.append({"path": path, "state": "left"})
            continue
        if not os.path.lexists(path):
            plan.append({"path": path, "state": "absent"})
            continue
        if os.path.islink(path):
            try:
                _, text = read_text(path)
            except (OSError, UnicodeDecodeError):
                text = ""
            if has_marks(text):
                raise Refused("%s is a symlink: the cleanup writes regular files only (clean its target by hand)" % tilde(path))
            plan.append({"path": path, "state": "clean"})
            continue
        if not os.path.isfile(path):
            plan.append({"path": path, "state": "absent"})
            continue
        data, text = read_text(path)
        item = {"path": path, "before": sha(data), "mode": os.stat(path).st_mode & 0o7777, "old_text": text}
        if has_marks(text):
            try:
                item["new_text"], item["marks"], item["old_lines"] = clean(text)
            except Refused as e:
                raise Refused("%s: %s" % (tilde(path), e))
            item["state"] = "clean-up"
        else:
            item["state"] = "clean"
        plan.append(item)
    return plan


def state_plan(args):
    items = []
    if os.path.isdir(args.state):
        items.append(("state", args.state))
    logs = os.path.join(args.persist, "last-trial")
    if os.path.isdir(logs):
        items.append(("logs", logs))
    marker = os.path.join(args.persist, "first-trial-done")
    if os.path.exists(marker):
        items.append(("drop", marker))
    return items


def archive_dir(persist):
    base = os.path.join(persist, "deploy-archive-" + datetime.date.today().isoformat())
    d, n = base, 2
    while os.path.exists(d):
        d, n = "%s-%d" % (base, n), n + 1
    return d


def cmd_cleanup(args):
    try:
        plan = plan_cleanup(args)
    except Refused as e:
        print("REFUSED: %s -- nothing was written" % e)
        return 1
    writes = [item for item in plan if item.get("state") == "clean-up"]
    st = state_plan(args)
    if not writes and not st:
        print("nothing to clean up: no file carries the marks of `lares deploy`, and no deploy record is kept")
        return 0
    print("lares cleanup-marks -- the lines an earlier `lares deploy` added stay as plain lines; its BEGIN / END marks and the")
    print("lines it had commented out (\"qs-shell deploy: <line>\") go. Nothing else in the files changes.\n")
    for item in plan:
        if item.get("state") == "clean-up":
            print("WILL CLEAN  %s: %d mark line(s) and %d commented-out line(s) out" % (tilde(item["path"]), item["marks"], item["old_lines"]))
        elif item.get("state") == "clean":
            print("clean       %s" % tilde(item["path"]))
        elif item.get("state") == "left":
            print("left alone  %s (chezmoi's source: chezmoi is not used)" % tilde(item["path"]))
        elif item.get("state") == "absent":
            print("not there   %s" % tilde(item["path"]))
    arch = archive_dir(args.persist)
    for kind, path in st:
        if kind == "state":
            print("WILL MOVE   %s (deploy's record, and originals/: your files as they were before the first deploy) to %s/"
                  % (tilde(path), tilde(arch)))
        elif kind == "logs":
            print("WILL MOVE   %s (an earlier trial's logs) to %s/" % (tilde(path), tilde(arch)))
        else:
            print("WILL REMOVE %s (an earlier trial's marker)" % tilde(path))
    for item in writes:
        print()
        sys.stdout.write(unified(item["path"], item["old_text"], item["new_text"]))
    if args.dry_run:
        print("\nnothing was changed")
        return 0
    sys.stdout.write("\nType yes to write the files above: ")
    sys.stdout.flush()
    answer = sys.stdin.readline().strip()
    if not sys.stdin.isatty():
        print()   # a terminal echoes the typed line's end; an answer from a pipe does not
    if answer != "yes":
        print("nothing was written")
        return 1
    for item in writes:   # the plan was made from these bytes: anything that moved since refuses the whole run
        if os.path.islink(item["path"]) or not os.path.isfile(item["path"]) or sha(open(item["path"], "rb").read()) != item["before"]:
            print("REFUSED: %s changed while the plan was shown -- nothing was written; run it again" % tilde(item["path"]))
            return 1
    done = []
    try:
        for item in writes:
            write_whole(item["path"], item["new_text"].encode("utf-8"), item["mode"])
            done.append(item)
            print("written     %s" % tilde(item["path"]))
    except OSError as e:
        print("FAILED writing %s: %s -- putting back what this run wrote" % (tilde(item["path"]), e))
        for d in done:
            try:
                write_whole(d["path"], d["old_text"].encode("utf-8"), d["mode"])
            except OSError as e2:
                print("FAILED to put back %s: %s" % (tilde(d["path"]), e2))
        return 1
    if st:
        os.makedirs(arch, exist_ok=True)
        for kind, path in st:
            if kind == "state":
                for name in sorted(os.listdir(path)):
                    shutil.move(os.path.join(path, name), os.path.join(arch, name))
                os.rmdir(path)
                print("moved       %s -> %s/" % (tilde(path), tilde(arch)))
            elif kind == "logs":
                shutil.move(path, os.path.join(arch, os.path.basename(path)))
                print("moved       %s -> %s/" % (tilde(path), tilde(arch)))
            else:
                os.unlink(path)
                print("removed     %s" % tilde(path))
    print("\ndone: the config files hold plain lines now; `lares binds` checks them against what the shell needs")
    return 0


def main():
    ap = argparse.ArgumentParser(prog="lares-config.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--ctx", required=True)
    c.add_argument("--summary", action="store_true")
    m = sub.add_parser("cleanup-marks")
    m.add_argument("--state", required=True)
    m.add_argument("--persist", required=True)
    m.add_argument("--file", action="append")
    m.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    if args.cmd == "check":
        return check(json.load(open(args.ctx)), args.summary)
    return cmd_cleanup(args)


if __name__ == "__main__":
    sys.exit(main())
