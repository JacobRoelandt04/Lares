#!/usr/bin/env python3
"""A mockup's Save writes the REAL implementation: promote its values into the module that ships them.

    tools/dev/mockup_promote.py dry   [--all | mockups/x.qml ...] [--root DIR] [--phase rows|fonts|all] [--summary] [--json] [--diff]
                                  (`--dry-run` as the first word is the same; `--apply` is `apply`)
    tools/dev/mockup_promote.py apply [--all | mockups/x.qml ...] [--root DIR] [--phase rows|fonts|all]
    tools/dev/mockup_promote.py plan  mockups/x.qml [--root DIR]                   JSON, what the panel shows per row
    tools/dev/mockup_promote.py save  mockups/x.qml <changes.json|json> [--root DIR] [--mockup-file PATH]
                                  [--shared list.prop,...] [--no-module REASON] [--dry-run] [--lares PATH]

THE USER'S IDEA (PLAN.md, answer 21): the mockups retire as the settings panels of their modules. Tweak a
value with live feedback, press Save, and the real implementation holds it -- no digging through files.
Save used to rewrite only the mockup's own `val:` (tools/dev/mockup_save_defaults.py), so 72 saved values never
reached a module. This is the other half: it finds, for each row, where the module ships that default and
writes it THERE.

WHERE A ROW LANDS. A row writes `<target>.<prop> = <value>`; the target is a chain of objects the mockup
names (`popup.rail` -> the PhaseRail inside SystemUpdatePopup). The write goes
  declaration  the module's OWN component declares the property: its default is rewritten
               (`property real glowMax: 2.6` -> 2.4);
  override     the property is inherited from a base type (GooeyBar's thickness): the module's file takes
               a root-level line (`thickness: 40`) -- the base is not touched;
  use site     the component is SHARED with another module (IconReelStyle: the power reel and the window
               tray; CardViewCycler: weather, wiki, clock): the line goes at the MODULE'S use of it -- in
               the object that instantiates it (`property IconReelStyle style: IconReelStyle { ... }`), or
               dotted through an alias at the module's root (`rail.glowMax: 2.4`, stage-0 fact 10) --
               and the shared declaration stays as it is. A per-row switch ("shared default") writes the
               shared declaration instead, for everyone.
A mockup-local knob (`tun.popupWidth` on a QtObject the mockup builds) is mapped through the binding that
feeds the module (`StocksBarOwner { popupWidth: tun.popupWidth }`); an indirect one takes a `promote:
{ to: "Type.prop", map: [...] }` hint on the row, or an entry in tools/dev/mockup_promote_hints.json.

WHAT IT REFUSES, with the reason in the panel and in the report:
  a binding default (`radius: root.engine ? ... : 0`, `property color c: Theme.accent` with a hex);
  a sentinel (-1 = "the config file decides": pinning it would override launcher.json);
  a type that does not fit (2.5 onto an int, a string index onto a string property);
  a readonly property, an alias; a file the hints protect (the battery files: the user's standing rule);
  a mock service's scenario knobs (not a shipped setting); themed and file-backed rows (not Save's).
A colour row writes `@token` as `Theme.<token>`; a hex over a token-bound default is refused (it would
pin one theme's colour into dark mode).

It never overwrites what it does not understand, writes nothing from a sandbox copy (the panel passes
--no-module there), and plans everything before it writes anything: all the files, or none.
"""
import argparse
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mockup_model as mm                                              # noqa: E402
import mockup_save_defaults as save_defaults                           # noqa: E402
from mockup_model import (Chain, Mockup, PropInfo, Repo, Resolver, consumers, creation_sites,   # noqa: E402
                          effective, fill_root_sites, hosts_of, lookup, use_sites, INT_TYPES, NUMERIC_TYPES)
from mockup_qmlscan import HEX_RE, format_number, literal, parse_js_value  # noqa: E402

UNSET = object()


class Refuse(Exception):
    pass


def short(text, n=60):
    t = re.sub(r"\s+", " ", str(text)).strip()
    return t if len(t) <= n else t[:n - 1] + "…"


# =============================================================================
# values
# =============================================================================
def apply_map(m, v):
    """A hint's `map`: a list indexed by the row's number, or an object keyed by the row's value."""
    if isinstance(m, list):
        try:
            return m[int(round(float(v)))]
        except (IndexError, ValueError, TypeError):
            raise Refuse("the hint's map has no entry for %r" % (v,))
    if isinstance(m, dict):
        keys = [str(v)]
        if isinstance(v, bool):
            keys = ["true" if v else "false"]
        elif isinstance(v, (int, float)) and float(v) == int(v):
            keys = [str(int(v)), str(v)]
        for k in keys:
            if k in m:
                return m[k]
        raise Refuse("the hint's map has no entry for %r" % (v,))
    return v


def apply_transform(tr, v):
    kind = tr[0]
    if kind == "identity":
        return v
    if kind == "not":
        return not bool(v)
    if kind == "ternary":
        return tr[1] if bool(v) else tr[2]
    raise Refuse("unknown transform %r" % (tr,))


def make_literal(repo, value, ptype, color_row, row_kind="", indent="", choices=None, current=None):
    """The QML literal for a Python value onto a property of `ptype`: (text, kind, canonical).
    `row_kind` json: the row's TEXT is JSON -- onto a `string` property it is that text; onto a `var` it is the
    object / list itself, written as a (multi-line) literal at `indent`. A choice row's value is an INDEX: onto
    a number property that is the number; onto a `string` property it is the choice's NAME, when the property's
    `current` default is one of the names (so the names ARE its values), else a map is needed."""
    t = ptype or ""
    if row_kind == "json" and t in ("var", "variant") and isinstance(value, str):
        try:
            obj = json.loads(value)
        except ValueError as e:
            raise Refuse("the JSON does not parse: %s" % e)
        if not isinstance(obj, (dict, list)):
            raise Refuse("a JSON row onto a var wants an object or a list")
        body = json.dumps(obj, indent=4, ensure_ascii=False).replace("\n", "\n" + indent)
        return ("(" + body + ")" if isinstance(obj, dict) else body), "json", json.dumps(obj, sort_keys=True)
    if row_kind == "choice" and t == "string" and isinstance(value, (int, float)) and not isinstance(value, bool):
        names = choices or []
        if current is not None and current in names and 0 <= int(round(float(value))) < len(names):
            value = names[int(round(float(value)))]
        else:
            raise Refuse("a choice row (an index) onto a string property whose default is not one of its choices: add `promote: { map: [...] }`")
    if color_row or (t == "color" and isinstance(value, str)):
        v = str(value)
        if v.startswith("@"):
            key = repo.token_key(v[1:])
            if key is None:
                raise Refuse("no theme token %s" % v)
            return "Theme." + key, "token", key
        if HEX_RE.fullmatch(v):
            return '"%s"' % v.upper(), "color", v.upper()
        raise Refuse("a colour is #RRGGBB, #AARRGGBB or @token, not %r" % v)
    if isinstance(value, bool):
        if t not in ("", "bool", "var", "variant"):
            raise Refuse("a switch onto a %s property" % t)
        return ("true" if value else "false"), "bool", value
    if isinstance(value, (int, float)):
        if t in INT_TYPES:
            if abs(float(value) - round(float(value))) > 1e-9:
                raise Refuse("%s onto an %s property" % (format_number(value), t))
            iv = int(round(float(value)))
            return str(iv), "num", iv
        if t and t not in NUMERIC_TYPES and t not in ("var", "variant"):
            raise Refuse("a number onto a %s property" % t)
        return format_number(value), "num", float(value)
    if isinstance(value, str):
        if t and t not in ("string", "var", "variant", "url", "color"):
            raise Refuse("text onto a %s property" % t)
        return json.dumps(value, ensure_ascii=False), "str", value
    raise Refuse("unsupported value %r" % (value,))


def same_as(repo, lit_kind, canon, eff):
    k = eff.kind
    if lit_kind == "json" and k == "expr":
        try:
            v, _ = parse_js_value(eff.text)
            return json.dumps(v, sort_keys=True) == canon
        except Exception:                       # noqa: BLE001 -- not a data literal: not the same
            return False
    if k in ("none", "expr"):
        return False
    if lit_kind == "num" and k == "num":
        return abs(float(eff.value) - float(canon)) < 1e-9
    if lit_kind == "bool" and k == "bool":
        return eff.value == canon
    if lit_kind == "str" and k == "str":
        return eff.value == canon
    if lit_kind == "color" and k in ("color", "str"):
        return str(eff.value).upper() == canon
    if lit_kind == "token" and k == "token":
        return eff.value == canon or repo.token_key(eff.value) == canon
    return False


def check_replaceable(lit_kind, canon, eff, hint):
    """May a literal of this kind replace what `eff` is? Raises Refuse with the reason."""
    k = eff.kind
    if k == "none":
        return
    if k == "expr" and lit_kind == "json" and re.match(r"\s*(\(\s*\{|\[|\{)", eff.text):
        return                                  # a data literal, not a binding
    if k == "expr":
        raise Refuse("binding default `%s`" % short(eff.text))
    if lit_kind == "token":
        if k in ("color", "token", "str"):
            return
        raise Refuse("the default is a %s literal, the row writes a theme token" % k)
    if lit_kind == "color":
        if k == "token":
            raise Refuse("the default follows the theme (`Theme.%s`): a hex would pin one theme's colour into dark mode -- type @%s to change the token" % (eff.value, eff.value))
        if k in ("color", "str"):
            return
        raise Refuse("the default is a %s, the row writes a colour" % k)
    if lit_kind != k:
        raise Refuse("the default is a %s (`%s`), the row writes a %s" % (k, short(eff.text, 30), lit_kind))
    if lit_kind == "num" and float(eff.value) == -1.0 and float(canon) != -1.0 and not hint.get("allowSentinel"):
        raise Refuse("sentinel -1 (\"automatic\": the config or the code decides); pinning it would override that")


def uses_theme(q):
    """Does this file reach the Theme singleton -- an import of a theme directory, or a `Theme.` read? A token
    written into a file that does not would be an unqualified, unresolved name."""
    return bool(re.search(r"\bTheme\b", q.mask) or re.search(r"^\s*import\s+[^\n]*theme", q.text, re.M | re.I))


def is_mock_file(rel):
    base = os.path.basename(rel)
    return "Mock" in base and "/data/" in rel or base.startswith("Mock") or base.endswith("Mock.qml")


def is_font_prop(name):
    n = name.lower()
    return n.endswith("family") or "fontfamily" in n


# =============================================================================
# edits
# =============================================================================
class Edit:
    __slots__ = ("rel", "start", "end", "text", "line", "what")

    def __init__(self, rel, start, end, text, line, what):
        self.rel, self.start, self.end, self.text, self.line, self.what = rel, start, end, text, line, what


class Insert:
    """A new `name: literal` line in an object's body (grouped per object when rendered)."""
    __slots__ = ("rel", "q", "obj", "name", "text", "line")

    def __init__(self, rel, q, obj, name, text):
        self.rel, self.q, self.obj, self.name, self.text = rel, q, obj, name, text
        self.line = q.line_of(obj.open)


class Part:
    """What one row does to one target property."""

    def __init__(self, label=""):
        self.label = label
        self.status = "skip"          # write | same | refuse | skip
        self.reason = ""
        self.mode = ""                # declaration | override | use-site | singleton | shared-declaration
        self.replaces = []
        self.inserts = []
        self.literal = ""
        self.eff = None
        self.where = ""               # file:line of the write
        self.shared = False           # a shared component declares it: the per-row switch has something to do
        self.alt_where = ""
        self.notes = []

    def refuse(self, why):
        self.status, self.reason = "refuse", why
        return self

    def skip(self, why):
        self.status, self.reason = "skip", why
        return self


class RowPlan:
    def __init__(self, row, value):
        self.row = row
        self.value = value
        self.parts = []
        self.status_override = None
        self.reason_override = ""

    @property
    def status(self):
        if self.status_override:
            return self.status_override
        sts = [p.status for p in self.parts]
        for s in ("write", "refuse", "same", "skip"):
            if s in sts:
                return s
        return "skip"

    @property
    def reason(self):
        if self.reason_override:
            return self.reason_override
        for p in self.parts:
            if p.status == self.status and p.reason:
                return p.reason
        return ""

    @property
    def shared(self):
        return any(p.shared for p in self.parts)

    def set_skip(self, why):
        self.status_override, self.reason_override = "skip", why
        return self

    def set_refuse(self, why):
        self.status_override, self.reason_override = "refuse", why
        return self


def _is_handler(name):
    return bool(re.match(r"on[A-Z]", name)) or name.startswith("Component.") or name.startswith("Behavior")


def render_insert(group):
    """One Edit for all the new lines of one object. group: [Insert] of one (rel, obj)."""
    first = group[0]
    q, obj, rel = first.q, first.obj, first.rel
    lines = [i.name + ": " + i.text for i in sorted(group, key=lambda i: i.name)]
    text = q.text
    body = text[obj.open + 1:obj.close]
    line_no = first.line
    if "\n" not in body:
        # `Type {}` / `Type { id: x }`: written out over several lines, at the indent of the line it sits on
        indent = q.indent_at(obj.start)
        inner = [s.strip() for s in re.split(r";", body) if s.strip()]
        new_body = "\n" + "".join(indent + "    " + l + "\n" for l in inner + lines) + indent
        return Edit(rel, obj.open + 1, obj.close, new_body, line_no, "insert")
    stmts = obj.stmts()
    anchor = None
    for st in stmts:
        if st.kind in ("id", "decl", "alias") or (st.kind == "assign" and not _is_handler(st.name)):
            anchor = st
        else:
            break
    if anchor is not None:
        eol = text.find("\n", anchor.end)
        eol = len(text) if eol < 0 else eol
        ls = q.line_start(anchor.start)
        lead = re.match(r"[ \t]*", text[ls:]).group(0)
        # the anchor starts its line? then its indent is the body's; else (id on the `{` line) one step in
        indent = lead if text[ls:anchor.start].strip() == "" else q.indent_at(obj.start) + "    "
        return Edit(rel, eol, eol, "".join("\n" + indent + l for l in lines), q.line_of(anchor.start), "insert")
    eol = text.find("\n", obj.open)
    indent = q.indent_at(obj.start) + "    "
    if stmts:
        ls = q.line_start(stmts[0].start)
        if text[ls:stmts[0].start].strip() == "":
            indent = re.match(r"[ \t]*", text[ls:]).group(0)
    return Edit(rel, eol, eol, "".join("\n" + indent + l for l in lines), line_no, "insert")


class EditSet:
    """Every file edit of one run: conflict-checked, rendered together, written atomically."""

    def __init__(self, repo):
        self.repo = repo
        self.owner = {}                # (rel, start, end) -> (text, key)
        self.replaces = []
        self.inserts = {}              # (rel, obj.open) -> [Insert]
        self.ins_names = {}            # (rel, obj.open, name) -> (text, key)

    def add(self, part, key):
        """Register a part's edits; False (and the part refused) when they collide with another row's."""
        for e in part.replaces:
            k = (e.rel, e.start, e.end)
            if k in self.owner and self.owner[k][0] != e.text:
                part.refuse("collides with %s, which writes the same place differently" % self.owner[k][1])
                return False
        for i in part.inserts:
            k = (i.rel, i.obj.open, i.name)
            if k in self.ins_names and self.ins_names[k][0] != i.text:
                part.refuse("collides with %s, which writes the same line differently" % self.ins_names[k][1])
                return False
        for e in part.replaces:
            k = (e.rel, e.start, e.end)
            if k not in self.owner:
                self.owner[k] = (e.text, key)
                self.replaces.append(e)
        for i in part.inserts:
            k = (i.rel, i.obj.open, i.name)
            if k not in self.ins_names:
                self.ins_names[k] = (i.text, key)
                self.inserts.setdefault((i.rel, i.obj.open), []).append(i)
        return True

    def edits(self):
        out = list(self.replaces)
        for group in self.inserts.values():
            out.append(render_insert(group))
        return out

    def files(self):
        """{rel: new text}, rendered from the pristine texts."""
        by = {}
        for e in self.edits():
            by.setdefault(e.rel, []).append(e)
        out = {}
        for rel, es in by.items():
            text = self.repo.qml(rel).text
            es = sorted(es, key=lambda e: (e.start, e.end))
            for a, b in zip(es, es[1:]):
                if a.end > b.start:
                    raise RuntimeError("%s: two edits overlap (%d-%d, %d-%d)" % (rel, a.start, a.end, b.start, b.end))
            for e in reversed(es):
                text = text[:e.start] + e.text + text[e.end:]
            out[rel] = text
        return out

    def write(self):
        """All the files or none. -> the relative paths written."""
        new = self.files()
        done = []
        old = {}
        try:
            for rel, text in new.items():
                path = self.repo.abspath(rel)
                with open(path, encoding="utf-8", newline="") as f:
                    old[rel] = f.read()
                tmp = path + ".promote.tmp"
                try:
                    with open(tmp, "w", encoding="utf-8", newline="") as f:
                        f.write(text)
                    os.replace(tmp, path)
                finally:
                    if os.path.exists(tmp):
                        os.unlink(tmp)
                done.append(rel)
        except Exception:
            for rel in done:
                with open(self.repo.abspath(rel), "w", encoding="utf-8", newline="") as f:
                    f.write(old[rel])
            raise
        self.repo.invalidate(new.keys(), shape=False)
        return sorted(new)


# =============================================================================
# the planner
# =============================================================================
class PseudoRow:
    """A font dressing the mockup does by plain assignment (`fontFamily: "Audiowide"`), as a row."""
    kind = "text"
    themed = False
    file_backed = False

    def __init__(self, mockup, type_name, prop, value):
        self.mockup = mockup
        self.list_id = "(dressing)"
        self.prop = prop
        self.key = "(dressing).%s.%s" % (type_name, prop)
        self.val = value
        self.label = "%s.%s" % (type_name, prop)
        self.hint = {}
        self.e = {}
        self.target_expr = None


# properties every Item-family root has: a row may name one without any file declaring it
BUILTIN_PROPS = {"x", "y", "z", "width", "height", "implicitWidth", "implicitHeight", "opacity", "visible", "enabled",
                 "scale", "rotation", "clip", "radius", "color", "spacing", "padding", "margins", "interval", "running",
                 "text", "smooth", "antialiasing", "focus"}


class Planner:
    def __init__(self, repo, mockup, shared=(), phase="rows"):
        self.repo = repo
        self.m = mockup
        self.res = Resolver(mockup)
        self.shared_pick = set(shared)
        self.phase = phase
        self.strict = False       # `set` names properties by hand: one nobody declares is a typo, not a builtin

    # ---- helpers ------------------------------------------------------------------
    def owned(self, rel, chain, holder=False):   # noqa: ARG002 -- `holder` marks a use-site holder (same rule)
        """May this file's content be changed for THIS module alone? The mockup's own drop-in (its content
        file) and a singleton are; anything else is when no other module's files use it."""
        if chain.kind == "singleton":
            return True
        if chain.content and chain.hops and rel == chain.hops[0].file:
            return True
        return not self.repo.shared(rel)

    def _chain_for_type(self, type_name):
        f = self.repo.type_file(type_name)
        if not f:
            return None
        return Chain("component", hops=[self.res.hop(type_name, "", None, None)], content=True, expr=type_name)

    # ---- one row ------------------------------------------------------------------
    def plan_row(self, row, value=UNSET):
        """The plan of one row. A bug in planning one row is THAT row's refusal -- never a crash of the whole
        run (Save must still write the mockup's val:), and never a write."""
        try:
            return self._plan_row(row, value)
        except Exception as e:                      # noqa: BLE001
            import traceback
            traceback.print_exc(file=sys.stderr)
            rp = RowPlan(row, row.val if value is UNSET else value)
            return rp.set_refuse("internal error while planning (%s: %s): the module is left alone" % (type(e).__name__, e))

    def _plan_row(self, row, value=UNSET):
        v = row.val if value is UNSET else value
        rp = RowPlan(row, v)
        if row.themed:
            return rp.set_skip("themed: a theme token -- the theme file is its default")
        if row.file_backed:
            return rp.set_skip("file-backed: the module's own file keeps it (%s)" % (self.m.file_backed.get(row.list_id) or "a config"))
        hint = row.hint
        if hint.get("skip"):
            return rp.set_skip(hint["skip"])
        # hint list: a typed target by name -- the property of that module type
        to = hint.get("to")
        if to:
            dests = to if isinstance(to, list) else [to]
            for dest in dests:
                tname, _, pname = dest.rpartition(".")
                ch = self._chain_for_type(tname)
                if ch is None:
                    p = Part(dest).refuse("the hint names `%s`, which is no type under modules/" % tname)
                    rp.parts.append(p)
                    continue
                try:
                    val2 = apply_map(hint["map"], v) if "map" in hint else v
                except Refuse as r:
                    rp.parts.append(Part(dest).refuse(str(r)))
                    continue
                rp.parts.append(self.plan_chain(row, ch, pname, val2, dest))
            return rp
        chain = self.res.resolve(row.target_expr)
        if chain.kind == "local":
            return self.plan_local(row, v, chain, rp)
        if chain.kind == "unresolved":
            return rp.set_refuse("cannot find the module's component: %s" % chain.error)
        try:
            val2 = apply_map(hint["map"], v) if "map" in hint else v
        except Refuse as r:
            return rp.set_refuse(str(r))
        label = "%s.%s" % (chain.last.type, row.prop)
        rp.parts.append(self.plan_chain(row, chain, row.prop, val2, label))
        return rp

    def plan_local(self, row, v, chain, rp):
        """A knob of an object the mockup builds (`tun`): the module property that reads it."""
        cons = consumers(self.m, chain.head_obj.id, row.prop)
        done = set()
        indirect = []
        foreign = []
        for c in cons:
            if c.chain is None:
                foreign.append(c)
                continue
            if c.transform is None and "map" not in row.hint:
                indirect.append(c)
                continue
            dress = c.transform is not None and c.transform[0] == "ternary" and "Audiowide" in c.transform[1:] and is_font_prop(c.name)
            if self.phase == "fonts" and not dress:
                continue
            try:
                if "map" in row.hint:
                    val2 = apply_map(row.hint["map"], v)
                elif dress and self.phase in ("fonts", "all"):
                    val2 = "Audiowide"            # the shell's face (PLAN.md answers 22 and 33): the dressed branch
                else:
                    val2 = apply_transform(c.transform, v)
            except Refuse as r:
                rp.parts.append(Part("%s.%s" % (c.type, c.name)).refuse(str(r)))
                continue
            key = (c.chain.last.file, c.name)
            if key in done:
                continue
            done.add(key)
            p = self.plan_chain(row, c.chain, c.name, val2, "%s.%s" % (c.type, c.name))
            if dress and self.phase in ("fonts", "all"):
                p.notes.append("font dressing: the shell's face, not the toggle's state")
            rp.parts.append(p)
        if not rp.parts:
            if self.phase == "fonts":
                return rp.set_skip("not a font dressing")
            if indirect:
                c = indirect[0]
                return rp.set_skip("mockup-only: %s.%s is fed by a derived expression (`%s`) -- add `promote: { to: \"Type.prop\", map: ... }` if it is a module setting"
                                   % (c.type, c.name, short(c.expr, 50)))
            if foreign:
                c = foreign[0]
                return rp.set_skip("mockup-only: only the mockup's own %s reads it (%s)" % (c.type, c.name))
            return rp.set_skip("mockup-only: nothing in the module reads it")
        return rp

    # ---- one target property --------------------------------------------------------
    def plan_chain(self, row, chain, prop, value, label):
        """Plan the write of `value` onto `prop` of the chain's target. See the module docstring for the
        three places it can land (declaration, override, use site) and why."""
        repo = self.repo
        part = Part(label)
        if chain.kind == "unresolved":
            return part.refuse(chain.error)
        hops = chain.hops
        last = hops[-1]
        n = len(hops) - 1
        singleton = chain.kind == "singleton"
        tf = last.file
        if tf and is_mock_file(tf):
            return part.skip("mock data: %s is the mock service's scenario, not a shipped setting" % os.path.basename(tf))
        info = lookup(repo, tf, prop, last.inline, last.holder_rel, last.holder_q) if (tf or last.inline) else PropInfo()
        if info.decl is None and not info.overrides and (tf is not None or last.inline is not None):
            # nobody in the module's files declares it: only a builtin (Qt's own) property is left, and those are
            # in no file -- a short list is trusted, and a hand-typed name never (a typo is a QML error)
            if self.strict or prop not in BUILTIN_PROPS:
                return part.refuse("no property `%s` on %s or what it extends" % (prop, last.type))
        if info.readonly:
            return part.refuse("readonly property")
        if info.is_alias:
            return part.refuse("an alias of `%s`: the value lives in its target" % short(info.decl[1].value_text(info.decl[2]), 40))
        creation = []
        if not singleton and not chain.content and chain.head_obj is not None and chain.kind == "component":
            creation = creation_sites(self.m, chain.head_obj)
        sites = [] if singleton else fill_root_sites(repo, use_sites(chain, creation))
        eff = effective(repo, chain, prop, info, sites)
        part.eff = eff
        indent = info.decl[1].indent_at(info.decl[2].start) if info.decl else "    "
        try:
            text, lit_kind, canon = make_literal(repo, value, info.ptype, getattr(row, "kind", "") == "color",
                                                 getattr(row, "kind", ""), indent, (getattr(row, "e", None) or {}).get("choices"),
                                                 eff.value if eff.kind == "str" else None)
        except Refuse as r:
            return part.refuse(str(r))
        part.literal = text

        def at(rel, q, off):
            return "%s:%d" % (rel, q.line_of(off))

        def opt_replace(rel, q, st, mode):
            """Rewrite an existing statement's value (a declaration's default, or an assignment)."""
            o = Part(label)
            o.mode = mode
            if st.vstart is not None:
                ks, vs, vt = literal(q.value_text(st))
            else:
                ks, vs, vt = "none", None, ""
            try:
                check_replaceable(lit_kind, canon, type("E", (), {"kind": ks, "value": vs, "text": vt})(), row.hint)
            except Refuse as r:
                return o.refuse(str(r))
            if repo.protected(rel):
                return o.refuse("%s is protected (the user's standing rule: agents leave it alone)" % rel)
            if lit_kind == "token" and not uses_theme(q):
                return o.refuse("%s does not import Theme: `%s` would be an unresolved name there -- add the import first" % (rel, text))
            if st.vstart is None:       # `property real x` with no default yet
                o.replaces.append(Edit(rel, st.end, st.end, ": " + text, q.line_of(st.start), "append"))
            else:
                a, b = q.value_span(st)
                o.replaces.append(Edit(rel, a, b, text, q.line_of(st.start), "replace"))
                # a comment on the line that still quotes the old default is stale after this
                line_end = q.text.find("\n", b)
                tail = q.text[b:line_end if line_end >= 0 else len(q.text)]
                if "//" in tail and vt and re.search(r"(?<![\w.])%s(?![\w.])" % re.escape(vt.strip('"')), tail.split("//", 1)[1]):
                    o.notes.append("%s:%d: the comment on the line quotes the old value %s" % (rel, q.line_of(st.start), vt))
            o.where = at(rel, q, st.start)
            o.status = "write"
            return o

        def opt_insert(rel, q, obj, name, mode):
            o = Part(label)
            o.mode = mode
            try:
                # a new line shadows whatever the default is: a binding must not be pinned, a sentinel not set
                check_replaceable(lit_kind, canon, eff, row.hint)
            except Refuse as r:
                return o.refuse(str(r))
            if repo.protected(rel):
                return o.refuse("%s is protected (the user's standing rule: agents leave it alone)" % rel)
            if lit_kind == "token" and not uses_theme(q):
                return o.refuse("%s does not import Theme: `%s` would be an unresolved name there -- add the import first" % (rel, text))
            o.inserts.append(Insert(rel, q, obj, name, text))
            o.where = at(rel, q, obj.open)
            o.status = "write"
            return o

        def opt_at_site(site):
            rel, q, ob, prefix = site
            st = ob.member(prefix + prop, ("assign",))
            if st is not None:
                return opt_replace(rel, q, st, "use-site")
            return opt_insert(rel, q, ob, prefix + prop, "use-site")

        def type_root():
            if last.inline is not None:
                return last.holder_rel, last.holder_q, last.inline
            q = repo.qml(tf)
            return tf, q, q.root()

        def opt_type_root():
            """The type's own default for an INHERITED property: a root-level line in its file (or inline body)."""
            rel, q, ob = type_root()
            st = ob.member(prop, ("assign",))
            if st is not None:
                return opt_replace(rel, q, st, "override")
            return opt_insert(rel, q, ob, prop, "override")

        def opt_decl():
            rel, q, st = info.decl
            return opt_replace(rel, q, st, "declaration")

        def owned_site():
            for site in sites:
                if site[2] is not None and self.owned(site[0], chain, True):
                    return site
            return None

        def no_site():
            if not chain.content and chain.head_obj is not None and n == 0:
                o = Part(label).skip("the mockup's own %s: it is shared with other modules and the module has no instance of it to write to" % last.type)
            else:
                o = Part(label).refuse("no file of the module's own to write it into")
            o.nosite = True
            return o

        # the declaration is the hop's own (in its file or its inline body), or inherited
        own_decl = info.decl is not None and (
            (last.inline is not None and info.decl[0] == last.holder_rel and info.decl[1] is last.holder_q)
            or (last.inline is None and bool(info.chain) and info.decl[0] == info.chain[0]))
        target_owned = (tf is not None or last.inline is not None) and self.owned(tf or last.holder_rel, chain)
        existing_owned = None
        for site in reversed(sites):         # the outermost literal already sitting at an owned site wins
            if site[2] is not None and site[2].member(site[3] + prop, ("assign",)) is not None and self.owned(site[0], chain, True):
                existing_owned = site
                break

        main = alt = None
        if singleton:
            main = opt_decl() if info.decl else Part(label).refuse("%s declares no `%s`" % (os.path.basename(tf), prop))
            main.mode = "singleton"
        elif existing_owned is not None:
            main = opt_at_site(existing_owned)
            if info.decl and repo.shared(info.decl[0]):
                alt = opt_decl()
        elif own_decl:
            if target_owned:
                main = opt_decl()
            else:
                s = owned_site()
                main = opt_at_site(s) if s else no_site()
                alt = opt_decl()
        elif tf is None and last.inline is None:
            s = owned_site()                  # a plain Rectangle / Text inside a module file: only the use site has it
            main = opt_at_site(s) if s else no_site()
        elif target_owned:
            main = opt_type_root()
            if info.decl and repo.shared(info.decl[0]):
                alt = opt_decl()
        else:
            s = owned_site()
            main = opt_at_site(s) if s else no_site()
            if info.decl:
                alt = opt_decl()
            elif info.overrides:
                alt = opt_type_root()

        # nowhere to write it for this module alone, and the shared declaration is a binding: that is the reason
        if getattr(main, "nosite", False) and alt is not None and alt.status == "refuse":
            main = alt
        part.shared = alt is not None and alt.status == "write"
        if part.shared:
            part.alt_where = alt.where
        picked = row.key in self.shared_pick and alt is not None
        if picked:
            chosen = alt
            chosen.mode = "shared-declaration"
            eff_decl = effective(repo, chain, prop, info, [])
            if same_as(repo, lit_kind, canon, eff_decl):
                part.status, part.mode, part.where = "same", "shared-declaration", eff_decl.at()
                return part
        else:
            chosen = main
            if same_as(repo, lit_kind, canon, eff):
                part.status, part.mode, part.where = "same", eff.where, eff.at()
                return part
        part.mode = chosen.mode
        if chosen.status != "write":
            part.status, part.reason = chosen.status, chosen.reason
            if chosen.status == "skip" and part.shared:
                part.reason += " (the shared-default switch writes the declaration at %s)" % part.alt_where
            return part
        part.status = "write"
        part.replaces = chosen.replaces
        part.inserts = chosen.inserts
        part.where = chosen.where
        part.notes.extend(chosen.notes)
        # hosts that set it themselves: the shell shows THEIR value
        if chosen.mode in ("declaration", "override") and tf and n == 0:
            for hrel, hq, hob in hosts_of(repo, tf):
                st = hob.member(prop, ("assign",))
                if st is not None:
                    part.notes.append("%s:%d sets `%s: %s` itself: the shell shows that, not the default" % (hrel, hq.line_of(st.start), prop, short(hq.value_text(st), 36)))
        return part

    # ---- font dressing by plain assignment ----------------------------------------------
    _FONT_TERNARY = re.compile(r"""^\s*(?:\(\s*)?[^?]+\?\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\s*(?:\))?\s*$""", re.S)

    def dressing_rows(self):
        """The face the mockup dresses a module object in by plain assignment -- `fontFamily: "Audiowide"`, or
        `fontFamily: win.dressAudiowide ? "Audiowide" : "Inter"` (the shell's face: PLAN.md answers 22 and 33,
        so the dressed branch) -- and the dressings the hints name (a handler-driven one cannot be read)."""
        out = []
        q = self.m.q
        for ob in q.objects():
            if ob.group or q.in_component(ob) or not self.repo.type_file(ob.type):
                continue
            for st in ob.stmts():
                if st.kind != "assign" or "." in st.name or not is_font_prop(st.name) or st.vstart is None:
                    continue
                text = q.value_text(st)
                k, v, _ = literal(text)
                if k == "str":
                    out.append((ob, PseudoRow(self.m, ob.type, st.name, v), False))
                    continue
                mt = self._FONT_TERNARY.match(text)
                if mt:
                    a, b = literal(mt.group(1)), literal(mt.group(2))
                    if a[0] == "str" and b[0] == "str" and "Audiowide" in (a[1], b[1]):
                        out.append((ob, PseudoRow(self.m, ob.type, st.name, "Audiowide"), True))
        return out

    def plan_dressing(self):
        plans = []
        seen = set()
        for ob, pr, forced in self.dressing_rows():
            ch = Chain("component", hops=[self.res.hop(ob.type, self.m.rel, self.m.q, ob)], head_obj=ob,
                       content=(self.m.content_id is not None and ob.id == self.m.content_id), expr=ob.id or ob.type)
            rp = RowPlan(pr, pr.val)
            part = self.plan_chain(pr, ch, pr.prop, pr.val, "%s.%s" % (ob.type, pr.prop))
            if forced:
                part.notes.append("font dressing: the shell's face, not the toggle's state")
            rp.parts.append(part)
            seen.add((ob.type, pr.prop))
            plans.append(rp)
        for dest, face in ((self.repo.hints.get("dressing", {}) or {}).get(self.m.rel, {}) or {}).items():
            tname, _, pname = dest.rpartition(".")
            if (tname, pname) in seen:
                continue
            pr = PseudoRow(self.m, tname, pname, face)
            ch = self._chain_for_type(tname)
            rp = RowPlan(pr, face)
            if ch is None:
                rp.parts.append(Part(dest).refuse("the hint names `%s`, which is no type under modules/" % tname))
            else:
                part = self.plan_chain(pr, ch, pname, face, dest)
                part.notes.append("font dressing named by the hints (the mockup sets it from a handler)")
                rp.parts.append(part)
            plans.append(rp)
        return plans

    # ---- a whole mockup --------------------------------------------------------------
    def plan_all(self, changes=None):
        """Plans for every row at its `val` (changes=None), or for the rows `changes` ({list: {prop: v}}) names."""
        plans = []
        if self.phase in ("rows", "all"):
            for row in self.m.rows():
                if changes is not None:
                    if row.prop not in (changes.get(row.list_id) or {}):
                        continue
                    plans.append(self.plan_row(row, changes[row.list_id][row.prop]))
                else:
                    plans.append(self.plan_row(row))
        elif self.phase == "fonts":
            for row in self.m.rows():
                rp = self.plan_row(row)
                if any(p.notes and any("font dressing" in n for n in p.notes) for p in rp.parts):
                    plans.append(rp)
        if self.phase in ("fonts", "all") and changes is None:
            covered = {p.label for rp in plans for p in rp.parts if any("font dressing" in n for n in p.notes)}
            plans.extend(rp for rp in self.plan_dressing() if not any(p.label in covered for p in rp.parts))
        return plans


# =============================================================================
# reports
# =============================================================================
def part_lines(rp, part):
    row = rp.row
    tag = "[%s]" % row.key
    if part.status == "write":
        first = part.replaces[0] if part.replaces else None
        what = ""
        if first is not None:
            q = None
            what = "%s -> %s" % (short(part.eff.text, 30) if part.eff and part.eff.text else "(none)", part.literal)
        else:
            what = "+ %s: %s" % ((part.inserts[0].name if part.inserts else "?"), part.literal)
        return "write  %-13s %-46s %-36s %s %s" % (part.mode, part.where, part.label, what, tag)
    if part.status == "same":
        return "same   %-13s %-46s %-36s %s %s" % (part.mode, part.where, part.label, part.literal, tag)
    if part.status == "refuse":
        return "REFUSE %-13s %-46s %-36s %s %s" % (part.mode, "", part.label, part.reason, tag)
    return "skip   %-13s %-46s %-36s %s %s" % ("", "", part.label, part.reason, tag)


def report(plans, out=print, notes=True):
    for rp in plans:
        if rp.status_override:
            tag = "REFUSE" if rp.status_override == "refuse" else "skip  "
            out("%s %-13s %-46s %-36s %s [%s]" % (tag, "", "", rp.row.label, rp.reason_override, rp.row.key))
            continue
        for part in rp.parts:
            out(part_lines(rp, part))
            if notes:
                for n in part.notes:
                    out("       note: %s" % n)


def summarize(plans):
    c = {"write": 0, "same": 0, "refuse": 0, "skip": 0}
    for rp in plans:
        c[rp.status] += 1
    return c


def show_diff(repo, es, out=print):
    import difflib
    for rel, new in sorted(es.files().items()):
        old = repo.qml(rel).text
        for line in difflib.unified_diff(old.splitlines(), new.splitlines(), "a/" + rel, "b/" + rel, lineterm="", n=2):
            out(line)


def build_edits(repo, plans):
    es = EditSet(repo)
    for rp in plans:
        for part in rp.parts:
            if part.status == "write":
                es.add(part, rp.row.key)
    return es


# =============================================================================
# the panel's view
# =============================================================================
def plan_json(repo, mockup_rel):
    m = Mockup(repo, mockup_rel)
    pl = Planner(repo, m)
    rows = {}
    for row in m.rows():
        rp = pl.plan_row(row)
        part = next((p for p in rp.parts if p.status == rp.status), rp.parts[0] if rp.parts else None)
        rows[row.key] = {
            "status": rp.status,
            "reason": rp.reason,
            "mode": part.mode if part else "",
            "where": part.where if part else "",
            "shared": rp.shared,
            "sharedWhere": next((p.alt_where for p in rp.parts if p.shared), ""),
            "targets": [p.label for p in rp.parts],
        }
    return {"moduleId": m.module_id, "mockup": mockup_rel, "rows": rows, "errors": m.errors}


# =============================================================================
# commands
# =============================================================================
def find_mockups(repo, names, all_):
    if all_:
        return mm.all_mockups(repo)
    out = []
    for n in names:
        rel = n if not os.path.isabs(n) else repo.relpath(n)
        if not os.path.exists(repo.abspath(rel)):
            raise SystemExit("no mockup %s under %s" % (n, repo.root))
        out.append(rel)
    return out


def cmd_dry_or_apply(args, apply_):
    repo = Repo(args.root)
    rels = find_mockups(repo, args.mockups, args.all)
    total = {"write": 0, "same": 0, "refuse": 0, "skip": 0}
    rows_out = []
    refusals = []
    summary = []
    all_written = []
    for rel in rels:
        try:
            m = Mockup(repo, rel)
        except mm.ModelError as e:
            print("ERROR %s: %s" % (rel, e))
            continue
        pl = Planner(repo, m, phase=args.phase)
        plans = pl.plan_all()
        counts = summarize(plans)
        for k in total:
            total[k] += counts[k]
        es = build_edits(repo, plans)
        counts = summarize(plans)          # collisions may have refused parts
        if args.json:
            for rp in plans:
                rows_out.append({"mockup": rel, "row": rp.row.key, "status": rp.status, "reason": rp.reason,
                                 "parts": [{"label": p.label, "status": p.status, "mode": p.mode, "where": p.where,
                                            "literal": p.literal, "reason": p.reason, "notes": p.notes} for p in rp.parts]})
        else:
            if not args.summary:
                print("== %s (%s)" % (rel, m.module_id))
                report([rp for rp in plans if args.verbose or rp.status in ("write", "refuse")
                        or (rp.status == "skip" and not rp.row.themed and not rp.row.file_backed and not rp.reason.startswith("mock data"))], notes=True)
        files = sorted({e.rel for e in es.edits()})
        if args.diff and not args.json:
            show_diff(repo, es)
        for rp in plans:
            if rp.status == "refuse":
                refusals.append((rel, rp))
        if apply_:
            written = es.write() if es.edits() else []
            all_written.extend(written)
            if not args.json:
                for f in written:
                    print("FILE %s" % f)
        summary.append((rel, m.module_id, summarize(plans), files))
    if args.json:
        print(json.dumps({"rows": rows_out, "total": total}, indent=1))
        return 0
    print()
    print("%-34s %-14s %6s %6s %7s %6s  %s" % ("mockup", "module", "write", "same", "refuse", "skip", "files"))
    for rel, mid, c, files in summary:
        print("%-34s %-14s %6d %6d %7d %6d  %s" % (rel, mid, c["write"], c["same"], c["refuse"], c["skip"], len(files)))
    print("%-34s %-14s %6d %6d %7d %6d" % ("TOTAL", "", total["write"], total["same"], total["refuse"], total["skip"]))
    if refusals:
        print()
        print("REFUSALS (%d)" % len(refusals))
        for rel, rp in refusals:
            print("  %-28s %-34s %s" % (rel, rp.row.key, rp.reason))
    print("MOCKUP_PROMOTE %s %d write, %d same, %d refuse, %d skip%s" % (
        "applied" if apply_ else "dry run", total["write"], total["same"], total["refuse"], total["skip"],
        ("; %d files written" % len(set(all_written))) if apply_ else ""))
    return 0


class _NoMockup:
    """What the planner needs of a mockup when there is none (the `set` command names the types itself)."""
    rel = "(set)"
    content_id = None
    file_backed = {}
    q = None
    win = None

    def __init__(self, repo):
        self.repo = repo


def cmd_set(args):
    """`set Type.prop=value ...`: write module properties by name -- the font decisions (PLAN.md 22, 33) and
    anything else the mockups cannot say. The same planner: declaration or override, refusals, atomic."""
    repo = Repo(args.root)
    shim = _NoMockup(repo)
    plans = []
    es = EditSet(repo)
    for item in args.items:
        dest, _, raw = item.partition("=")
        tname, _, pname = dest.rpartition(".")
        try:
            value = json.loads(raw)
        except ValueError:
            value = raw
        pl = Planner(repo, shim)
        pl.strict = True
        pr = PseudoRow(shim, tname, pname, value)
        pr.key = "set.%s" % dest
        rp = RowPlan(pr, value)
        ch = pl._chain_for_type(tname)
        if ch is None:
            rp.parts.append(Part(dest).refuse("no type `%s` under modules/" % tname))
        else:
            rp.parts.append(pl.plan_chain(pr, ch, pname, value, dest))
        plans.append(rp)
        for part in rp.parts:
            if part.status == "write":
                es.add(part, pr.key)
    report(plans)
    if es.edits():
        if args.diff:
            show_diff(repo, es)
        if args.apply:
            for f in es.write():
                print("FILE %s" % f)
    c = summarize(plans)
    print("MOCKUP_PROMOTE set %s %d write, %d same, %d refuse" % ("applied" if args.apply else "dry run", c["write"], c["same"], c["refuse"]))
    return 1 if c["refuse"] else 0


def cmd_plan(args):
    repo = Repo(args.root)
    rel = find_mockups(repo, args.mockups, False)[0]
    print(json.dumps(plan_json(repo, rel)))
    return 0


LARES_MEANING = {
    0: "done (committed; a running trial's shell restarted, or the deployed shell redeployed to the new commit; nothing to do when nothing changed)",
    1: "FAILED (refused or errored: see its lines above; nothing is restarted)",
    2: "FAILED (usage: the call is wrong -- a bug in the panel)",
    4: "committed, but the restart was REFUSED while pacman / yay runs a package transaction (the guard): the running shell was NOT restarted -- `lares restart` when it is over, `--force` goes on",
}


def commit_files(repo, lares, module_id, files):
    """One click: `lares apply --commit <module> <files>` commits exactly these files and lets the shell follow.
    -> (exit status or None when the tool is absent, lines)."""
    qs = lares or os.path.join(repo.root, "tools", "shell", "lares")
    if not os.access(qs, os.X_OK):
        return None, ["%s is not there: the files are written, nothing is committed" % os.path.relpath(qs, repo.root)]
    # its own session: a mockup that reloads itself when Save writes the files (the file watcher is on) takes its
    # process down, and the commit -- already started, a few ms after the writes -- must not go with it
    p = subprocess.run([qs, "apply", "--commit", module_id] + files, capture_output=True, text=True, cwd=repo.root,
                       start_new_session=True)
    lines = [l for l in (p.stdout + p.stderr).splitlines() if l.strip()]
    lines.append("lares apply exited %d: %s" % (p.returncode, LARES_MEANING.get(p.returncode, "unexpected status")))
    return p.returncode, lines


def cmd_save(args):
    repo = Repo(args.root)
    # the module needs the mockup's lists; the mockup's own val: needs only its path (--mockup-file)
    rel = args.mockup if args.no_module else find_mockups(repo, [args.mockup], False)[0]
    payload = args.changes
    if payload.lstrip().startswith("{"):
        changes = json.loads(payload)
    else:
        with open(payload, encoding="utf-8") as f:
            changes = json.load(f)
    mockup_file = args.mockup_file or repo.abspath(rel)
    module_id = mm.module_id_of(rel)
    module_dry = args.dry_run or args.module_dry
    written = []
    lines = []
    module_note = ""
    failed = False
    block = args.no_module
    if not block:
        # Save commits what it writes: a tree that is not a git work tree could neither commit nor undo it
        top = subprocess.run(["git", "-C", repo.root, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if top.returncode != 0 or os.path.realpath(top.stdout.strip()) != repo.root:
            block = "%s is not the top of a git work tree: nothing Save wrote could be committed or undone" % repo.root
    if block:
        module_note = "module not written: %s" % block
    else:
        try:
            m = Mockup(repo, rel)
            module_id = m.module_id
            pl = Planner(repo, m, shared=[x for x in (args.shared or "").split(",") if x])
            plans = pl.plan_all(changes)
            es = build_edits(repo, plans)
            report(plans, out=lines.append)
            c = summarize(plans)
            if es.edits():
                if args.diff:
                    show_diff(repo, es, out=lines.append)
                files = sorted({e.rel for e in es.edits()})
                if module_dry:
                    written = files
                else:
                    for r in files:
                        st = subprocess.run(["git", "-C", repo.root, "status", "--porcelain", "--", r], capture_output=True, text=True)
                        if st.returncode == 0 and st.stdout.strip():
                            lines.append("note: %s had uncommitted changes before this Save; they are in the commit" % r)
                    written = es.write()
            module_note = "module: %d written, %d already there, %d refused, %d not module settings%s" % (
                c["write"], c["same"], c["refuse"], c["skip"], " (dry run)" if module_dry else "")
        except Exception as e:                      # the mockup's own val: must still be saved
            import traceback
            traceback.print_exc(file=sys.stderr)
            module_note = "module: FAILED before writing anything (%s: %s)" % (type(e).__name__, e)
            failed = True
    for line in lines:
        print(line)
    for f in written:
        print("FILE %s%s" % (f, " (would be written)" if module_dry else ""))
    if module_note:
        print(module_note)
    # the mockup's own val: -- the same lines the panel has always shown
    vlines, changed, errors = save_defaults.apply_changes(mockup_file, changes, args.dry_run)
    for line in vlines:
        print(line)
    print("%d changed, %d skipped%s" % (changed, errors, " (dry run)" if args.dry_run else ""))
    rc = 1 if (errors or failed) else 0
    if written and not module_dry and not block:
        files = [repo.abspath(r) for r in written]
        real = os.path.realpath(mockup_file)
        if changed and real.startswith(repo.root + os.sep):
            files.append(real)
        status, clines = commit_files(repo, args.lares, module_id, files)
        for line in clines:
            print("commit: %s" % line)
        if status in (1, 2):
            print("commit failed (lares apply exited %d)" % status, file=sys.stderr)
            rc = 1
    return rc


def main(argv):
    # the brief's words: `--dry-run` and `--apply` as the first argument are the `dry` and `apply` commands
    argv = list(argv)
    if len(argv) > 1 and argv[1] in ("--apply", "--dry-run", "--dry"):
        argv[1] = "apply" if argv[1] == "--apply" else "dry"
    ap = argparse.ArgumentParser(prog="mockup_promote.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("dry", "apply"):
        p = sub.add_parser(name)
        p.add_argument("mockups", nargs="*")
        p.add_argument("--all", action="store_true")
        p.add_argument("--root", default=None)
        p.add_argument("--phase", choices=("rows", "fonts", "all"), default="rows")
        p.add_argument("--summary", action="store_true")
        p.add_argument("--json", action="store_true")
        p.add_argument("--verbose", action="store_true", help="also list the rows the module already ships")
        p.add_argument("--diff", action="store_true", help="show the files' unified diff")
    p = sub.add_parser("set", help="write module properties by name: Type.prop=value (JSON or text)")
    p.add_argument("items", nargs="+")
    p.add_argument("--root", default=None)
    p.add_argument("--apply", action="store_true")
    p.add_argument("--diff", action="store_true")
    p = sub.add_parser("plan")
    p.add_argument("mockups", nargs=1)
    p.add_argument("--root", default=None)
    p = sub.add_parser("save")
    p.add_argument("mockup")
    p.add_argument("changes")
    p.add_argument("--root", default=None)
    p.add_argument("--mockup-file", default=None)
    p.add_argument("--shared", default="")
    p.add_argument("--no-module", default="")
    p.add_argument("--dry-run", action="store_true", help="plan everything, write nothing (the mockup's val: included)")
    p.add_argument("--module-dry", action="store_true", help="plan the module, write nothing of it; the mockup's val: is written")
    p.add_argument("--diff", action="store_true")
    p.add_argument("--lares", default=None)
    args = ap.parse_args(argv[1:])
    if args.cmd == "dry":
        return cmd_dry_or_apply(args, False)
    if args.cmd == "apply":
        return cmd_dry_or_apply(args, True)
    if args.cmd == "plan":
        return cmd_plan(args)
    if args.cmd == "set":
        return cmd_set(args)
    return cmd_save(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
