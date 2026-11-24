#!/usr/bin/env python3
"""config_migrate.py -- the ONE-TIME rewrite of the user's live configs into the cleanup's layout (stage C4).

    python3 tools/dev/config_migrate.py <dir> --dry      the plan, key by key; writes nothing
    python3 tools/dev/config_migrate.py <dir> --write    the same plan, then every file at once

<dir> is the folder that holds the live configs (~/.config/quickshell). Only these names are read there, `<name>.jsonc` first and
`<name>.json` when there is no .jsonc (ConfigFile's rule): shell notifications osd silicon launcher stocks weather windowtray clipboard,
and the two this stage makes, idle and llm. calendars.jsonc and .env are never opened.

WHAT IT DOES TO EACH KEY (the table below, then the defaults):
  moved     a key that now lives in another file or under another name: shell.jsonc's `idle` -> idle.jsonc, `llm.notePrompt` and
            `llmStore` -> llm.jsonc (`notePrompt`, `store`), `scale.llm` -> `scale.popups.llm` (and an output's the same way).
  constant  a key that is no setting any more: the module's own constant now (its QML property default, tuned in its mockup). The
            constant must already BE the live value -- the cleanup set every constant to the user's value -- so the key is simply left
            out. A live value that differs (the user changed it after the constant was set) REFUSES the run, naming the key, its value
            and the constant's.
  no reader a key nothing reads (the props' switch, the old padding and gap, a removed group): left out, with the reason.
  default   a key whose value IS the default (the value .examples/<name>.jsonc holds, which is the code's): left out.
  kept      everything else: the user's own choices, unchanged.
An object is walked key by key (the loaders merge key by key), except the few whose loader takes them whole (LEAF). Under a map whose
keys are the user's (FREE: apps, islands, wallpapers ...) an entry the example does not have is kept as it is.

IT REFUSES, WITH NOTHING WRITTEN: a file that does not parse, a key it does not know, a constant that is not the live value, a moved
key that would land on a different value already in its new file. It plans every file before it writes any.

THE NEW FILES are minimal jsonc: one header line naming .examples/<name>.jsonc (every key documented there), then the user's keys.
A file left with no key is written as that header and an empty object (`{` and `}` on lines of their own, where
lares-deploy's llm.jsonc edit finds its anchor); idle.jsonc and llm.jsonc are made the same way when absent. The user's own
comments in a rewritten file are lost (the backup keeps them): --dry counts them per file. tools/dev/config_migrate_proof.py proves a
run: the effective values before and after, key by key.
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "lib"))
import jsonc  # noqa: E402  (the shell's own comment stripper and file rule)

NAMES = ["shell", "notifications", "osd", "silicon", "launcher", "stocks", "weather", "windowtray", "clipboard", "idle", "llm"]
NEW_FILES = ["idle", "llm"]

# path (dotted, `*` = any one key) -> new path in its new file
MOVES = [
    ("shell.idle.*", "idle.*"),
    ("shell.llm.notePrompt", "llm.notePrompt"),
    ("shell.llmStore", "llm.store"),
    ("shell.scale.llm", "shell.scale.popups.llm"),
    ("shell.scale.outputs.*.llm", "shell.scale.outputs.*.popups.llm"),
]
# path -> (QML type, property, how a live value reads as the property's): the keys that became constants
NULL_IS_ASK = "null asks Hyprland: the property's -1"
CONSTANTS = {
    "shell.titleSlot": ("ShellConfig", "titleSlot", None),
    "shell.workspacesScale": ("ShellConfig", "workspacesScale", None),
    "shell.workspacesPitch": ("ShellConfig", "workspacesPitch", None),
    "shell.workspacesWidth": ("ShellConfig", "workspacesWidth", None),
    "shell.inkGap": ("ShellConfig", "inkGap", None),
    "shell.minVoid": ("ShellConfig", "minVoid", None),
    "shell.joint.rounding": ("ShellConfig", "jointRounding", NULL_IS_ASK),
    "shell.joint.border": ("ShellConfig", "jointBorder", NULL_IS_ASK),
    "shell.shadow.reach": ("ShellConfig", "shadowReach", None),
    "shell.shadow.strength": ("ShellConfig", "shadowStrength", None),
    "shell.shadow.spread": ("ShellConfig", "shadowSpread", None),
    "shell.shadow.softness": ("ShellConfig", "shadowSoftness", None),
    "shell.shadow.blend": ("ShellConfig", "shadowBlend", None),
    "notifications.images.avatarMax": ("NotificationService", "avatarMax", None),
    "notifications.images.pictureMaxHeight": ("NotificationStyle", "pictureMaxHeight", None),
    "notifications.toasts.staggerMs": ("ToastScheduler", "staggerMs", None),
    "osd.minShowMs": ("OsdOwner", "minShowMs", None),
    "silicon.idle.calmAfterMs": ("IdleLadder", "calmAfterMs", None),
    "silicon.idle.haltAfterMs": ("IdleLadder", "haltAfterMs", None),
    "silicon.idle.statsHaltedMs": ("IdleLadder", "statsHaltedMs", None),
    "silicon.idle.batteryHaltedMs": ("IdleLadder", "batteryHaltedMs", None),
    "silicon.sounds.latch": ("SiliconSounds", "latchVolume", None),
    "silicon.sounds.dip": ("SiliconSounds", "dipVolume", None),
    "silicon.sounds.plug": ("SiliconSounds", "plugVolume", None),
    "silicon.sounds.variant.latch": ("SiliconSounds", "latchTake", None),
    "silicon.sounds.variant.dip": ("SiliconSounds", "dipTake", None),
    "silicon.sounds.variant.plug": ("SiliconSounds", "plugTake", None),
    "silicon.sounds.variant.plug_out": ("SiliconSounds", "plugOutTake", None),
    "silicon.look.scale": ("SiliconBarOwner", "sizeScale", None),
}
NO_READER = {
    "shell.player": "the player's props were deleted (C2): nothing reads `player.props`",
    "shell.padding": "replaced by the spacing rule (inkGap) before the cleanup: ignored by the loader",
    "shell.gap": "replaced by the spacing rule (inkGap) before the cleanup: ignored by the loader",
    "silicon.mux": "the MUX's windows are the root helper's: the loader ignored the group with a warning",
    "windowtray.classIcons": "replaced by shell.jsonc's icons.overrides before the cleanup: ignored by the loader",
    "launcher.iconTheme": "the launcher's icons are the desktop's icon theme: nothing reads the key",
}
# taken whole by their loader: compared whole with the default, never walked
LEAF = {"notifications.spot", "osd.spot"}
# maps whose keys are the user's: an entry the example lacks is kept whole
FREE = {"shell.islands", "shell.scale.popups", "shell.scale.pills", "shell.scale.outputs", "shell.theme.wallpapers", "shell.icons.overrides",
        "notifications.apps", "notifications.sources", "notifications.sources.*", "osd.layout.codes", "windowtray.trayRename",
        "clipboard.pasteKeys.classes", "stocks.sudden.bySymbol", "idle", "llm"}
MISSING = object()


def match(pattern, path):
    p, q = pattern.split("."), path.split(".")
    return len(p) == len(q) and all(a == "*" or a == b for a, b in zip(p, q))


def matches_any(patterns, path):
    return any(match(p, path) for p in patterns)


def qml_default(typ, prop, repo=ROOT):
    hits = glob.glob(os.path.join(repo, "modules", "**", typ + ".qml"), recursive=True)
    if len(hits) != 1:
        raise SystemExit("config_migrate: %s.qml found %d times" % (typ, len(hits)))
    rx = re.compile(r"^\s*property\s+\w+\s+%s\s*:\s*(.+?)\s*(//.*)?$" % re.escape(prop))
    for line in open(hits[0], encoding="utf-8"):
        m = rx.match(line)
        if m:
            return json.loads(m.group(1)), os.path.relpath(hits[0], repo)
    raise SystemExit("config_migrate: %s declares no property %s" % (typ, prop))


def read_live(d, name):
    for ext in (".jsonc", ".json"):
        p = os.path.join(d, name + ext)
        if os.path.isfile(p):
            text = open(p, encoding="utf-8").read()
            return p, text
    return None, None


def comment_lines(text):
    """How many lines of the file hold a comment (they are lost in the rewrite)."""
    stripped = jsonc.strip(text).split("\n")
    return sum(1 for a, b in zip(text.split("\n"), stripped) if a.rstrip() != b.rstrip())


def same(a, b):
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(a - b) < 1e-9
    if isinstance(a, dict) and isinstance(b, dict):
        return set(a) == set(b) and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def show(v):
    s = json.dumps(v, ensure_ascii=False)
    return s if len(s) <= 90 else s[:87] + "..."


class Plan:
    def __init__(self, live_dir, repo=ROOT):
        self.live_dir, self.repo = live_dir, repo
        self.lines = {n: [] for n in NAMES}
        self.refusals = []
        self.counts = {"kept": 0, "moved": 0, "constant": 0, "default": 0, "no reader": 0}
        self.out = {}
        self.src = {}

    def note(self, name, kind, text):
        self.lines[name].append("   %-10s %s" % (kind, text))
        if kind in self.counts:
            self.counts[kind] += 1

    def refuse(self, why):
        self.refusals.append(why)

    def build(self):
        live, examples = {}, {}
        for n in NAMES:
            path, text = read_live(self.live_dir, n)
            self.src[n] = (path, text)
            if text is not None:
                try:
                    live[n] = jsonc.loads(text)
                except ValueError as e:
                    self.refuse("%s does not parse: %s" % (os.path.basename(path), e))
                    continue
                if not isinstance(live[n], dict):
                    self.refuse("%s: the top level is not an object" % os.path.basename(path))
                    continue
            ex = os.path.join(self.repo, ".examples", n + ".jsonc")
            examples[n] = jsonc.load(ex) if os.path.isfile(ex) else {}
        if self.refusals:
            return
        # 1. the moves: out of their file, into their new place (a new file's own keys are walked with it)
        incoming = {n: {} for n in NAMES}
        for n in list(live):
            self._moves(n, live[n], live[n], n, incoming)
        for n in NEW_FILES + [x for x in NAMES if x not in NEW_FILES]:
            obj = live.get(n, {})
            for k, v in incoming[n].items():
                if k in obj and not same(obj[k], v):
                    self.refuse("%s.%s: moved from shell.jsonc as %s, but %s.jsonc already says %s" % (n, k, show(v), n, show(obj[k])))
                obj[k] = v
            if n in live or incoming[n]:
                live[n] = obj
        if self.refusals:
            return
        # 2. the walk: constants, no reader, defaults, kept
        for n in NAMES:
            if n not in live:
                continue
            obj = live[n]
            if n == "shell" and isinstance(obj.get("shadow"), dict) and not isinstance(obj["shadow"].get("mode"), str):
                obj["shadow"] = dict(obj["shadow"], mode="halo")       # an object with no mode IS a halo (ShellLayout.shadowOf)
                self.note(n, "kept", "shadow.mode = \"halo\"   (written out: an object without a mode is a halo, and its numbers leave)")
            kept = self._walk(n, n, obj, examples[n])
            self.out[n] = kept if kept is not MISSING else {}

    def _moves(self, name, root, obj, path, incoming):
        """Take every key of the MOVES table out of `obj` (a node of the file `root`, at `path`): into `incoming[file]` for another
        file, or to its new place in `root` for a move within the file. A `*` in a move is the same key on both sides."""
        if not isinstance(obj, dict):
            return
        for k in list(obj):
            p = path + "." + k
            for src, dst in MOVES:
                if not match(src, p):
                    continue
                parts = p.split(".")
                real = []
                star = [parts[i] for i, s_ in enumerate(src.split(".")) if s_ == "*"]
                for d_ in dst.split("."):
                    real.append(star.pop(0) if d_ == "*" else d_)
                target, v = real[0], obj.pop(k)
                if target == name:
                    node = root
                    for key in real[1:-1]:
                        if not isinstance(node.get(key), dict):
                            node[key] = {}
                        node = node[key]
                    if real[-1] in node and not same(node[real[-1]], v):
                        self.refuse("%s: moved to %s, which already says %s" % (p, ".".join(real), show(node[real[-1]])))
                    node[real[-1]] = v
                else:
                    incoming[target][".".join(real[1:])] = v
                self.note(name, "moved", "%s = %s -> %s.jsonc %s" % (p.split(".", 1)[1], show(v), target, ".".join(real[1:])))
                break
            else:
                if k in obj:
                    self._moves(name, root, obj[k], p, incoming)

    def _walk(self, name, path, live, ex):
        if path != name and path in NO_READER:
            self.note(name, "no reader", "%s = %s   (%s)" % (path.split(".", 1)[1], show(live), NO_READER[path]))
            return MISSING
        rel = path.split(".", 1)[1] if "." in path else ""
        if path in CONSTANTS:
            typ, prop, how = CONSTANTS[path]
            want, where = qml_default(typ, prop, self.repo)
            have = -1 if (how == NULL_IS_ASK and live is None) else live
            if not same(have, want):
                self.refuse("%s.%s = %s, but the constant %s.%s (%s) is %s: set the constant to the live value first, or the key back"
                            % (name, rel, show(live), typ, prop, where, show(want)))
            else:
                self.note(name, "constant", "%s = %s -> %s.%s (%s)" % (rel, show(live), typ, prop, where))
            return MISSING
        # an empty object where the loader merges key by key adds nothing: it is the default, whatever the example holds there
        if isinstance(live, dict) and not live and path not in LEAF and (isinstance(ex, dict) or matches_any(FREE, path)):
            self.note(name, "default", "%s = {}   (an empty group merges nothing)" % rel)
            return MISSING
        # a group that holds keys of the table (silicon's idle and sounds, notifications' images) is walked whatever the example says:
        # the example no longer has the group, and its keys are known by the table
        known_group = self._is_group(path) and not isinstance(ex, dict)
        if isinstance(live, dict) and live and path not in LEAF and (isinstance(ex, dict) or matches_any(FREE, path) or known_group):
            free = matches_any(FREE, path)
            if not isinstance(ex, dict):
                ex = {}
            out = {}
            for k, v in live.items():
                child = path + "." + k
                exv = ex.get(k, MISSING) if isinstance(ex, dict) else MISSING
                if exv is MISSING and not free and child not in NO_READER and child not in CONSTANTS and not self._under_known(child):
                    self.refuse("%s: a key the migration does not know (%s)" % (child, show(v)))
                    continue
                if exv is MISSING and free and child not in NO_READER and child not in CONSTANTS:
                    if isinstance(v, dict) and matches_any(FREE, child):
                        r = self._walk(name, child, v, {})
                        if r is not MISSING:
                            out[k] = r
                        continue
                    out[k] = v
                    self.note(name, "kept", "%s = %s" % (child.split(".", 1)[1], show(v)))
                    continue
                r = self._walk(name, child, v, exv)
                if r is not MISSING:
                    out[k] = r
            return out if out else MISSING
        if ex is not MISSING and same(live, ex):
            self.note(name, "default", "%s = %s" % (rel, show(live)))
            return MISSING
        self.note(name, "kept", "%s = %s" % (rel, show(live)))
        return live

    def _is_group(self, path):
        """Is `path` a group that holds keys of the table (silicon.idle for silicon.idle.calmAfterMs)?"""
        return any(c.startswith(path + ".") for c in list(CONSTANTS) + list(NO_READER))

    def _under_known(self, path):
        """Is `path` such a group, or a key below one of the table's?"""
        return self._is_group(path) or any(path.startswith(c + ".") for c in list(CONSTANTS) + list(NO_READER))


def render(name, obj):
    head = ("// %s.jsonc -- only your changes: a key left out is its default. Every key, what it does, its default and its range:\n"
            "// .examples/%s.jsonc in the shell's folder.\n") % (name, name)
    return head + dump(obj, 0) + "\n"


def dump(v, ind):
    """JSON, four spaces: an object one key a line; a list of plain values on one line; a list of objects on one line when it fits
    in 120 columns, one item a line otherwise."""
    pad, inner = " " * ind, " " * (ind + 4)
    if isinstance(v, dict):
        if not v:
            return "{\n" + pad + "}" if ind == 0 else "{}"
        rows = ["%s%s: %s" % (inner, json.dumps(k, ensure_ascii=False), dump(x, ind + 4)) for k, x in v.items()]
        return "{\n" + ",\n".join(rows) + "\n" + pad + "}"
    if isinstance(v, list):
        flat = json.dumps(v, ensure_ascii=False)
        if all(not isinstance(x, (dict, list)) for x in v) or len(flat) + ind <= 120:
            return flat
        return _multi(v, ind)
    return json.dumps(v, ensure_ascii=False)


def _multi(v, ind):
    pad, inner = " " * ind, " " * (ind + 4)
    return "[\n" + ",\n".join(inner + dump(x, ind + 4) for x in v) + "\n" + pad + "]"


def main(argv):
    if len(argv) != 2 or argv[1] not in ("--dry", "--write") or not os.path.isdir(argv[0]):
        print(__doc__)
        return 2
    d, write = os.path.abspath(argv[0]), argv[1] == "--write"
    plan = Plan(d)
    plan.build()
    files = []
    for n in NAMES:
        path, text = plan.src.get(n, (None, None))
        if n not in plan.out and n not in NEW_FILES:
            if path is None:
                continue
        target = path or os.path.join(d, n + ".jsonc")
        obj = plan.out.get(n, {})
        lost = comment_lines(text) if text is not None else 0
        state = "rewrite" if path else "create"
        print("== %s  (%s%s)" % (os.path.basename(target), state, (": %d line(s) of your comments go, the backup keeps them" % lost) if lost else ""))
        for line in plan.lines[n]:
            print(line)
        print("   %-10s %s: %d top-level key(s)%s" % ("WRITE" if write else "would write", os.path.basename(target), len(obj),
                                                    " (a stub: everything is the default)" if not obj else ""))
        files.append((target, render(n, obj)))
    c = plan.counts
    summary = "kept %d, moved %d, constants %d, dropped as default %d, no reader %d, refused %d" % (
        c["kept"], c["moved"], c["constant"], c["default"], c["no reader"], len(plan.refusals))
    for r in plan.refusals:
        print("REFUSE " + r)
    if plan.refusals:
        print("CONFIG_MIGRATE REFUSED (%s): nothing written" % summary)
        return 1
    if not write:
        print("CONFIG_MIGRATE PLAN %d file(s): %s" % (len(files), summary))
        return 0
    for target, text in files:
        tmp = target + ".c4-new"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, target)
    print("CONFIG_MIGRATE WROTE %d file(s): %s" % (len(files), summary))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
