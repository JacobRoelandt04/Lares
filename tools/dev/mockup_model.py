#!/usr/bin/env python3
"""What the settings pipeline knows about the tree.

The model under tools/dev/mockup_promote.py (a mockup's Save writes the real implementation) and
tools/dev/mockup_wiring_check.py (every panel row against the component it drives). It answers, from the
files alone and without running anything:

    Repo     the tree: which file is type `Foo`, who instantiates it, which MODULE a file belongs to and
             whether it is SHARED (used from another module's files too), the theme's tokens, the hints
    Mockup   a mockups/<module>.qml: its lists, its rows (what kind each is, what it writes to), its targets
    Resolver a row's target expression (`popup.rail`) -> the chain of objects it names, hop by hop, each
             with the file that declares its type and the object that instantiates it
    lookup   where a property is declared (the type's own file or a base), what overrides it on the way
    effective the default the module actually ships for a row: a use-site literal wins over the
             declaration it sits on

THE MODULE OF A FILE. `modules/<dir>/...` belongs to <dir>, `modules/bar/<sub>/...` to bar/<sub>. A file in
`modules/common/` belongs to the one module whose files use it (SystemUpdatePopup -> the update module,
PhaseRail through it), and to 'common' -- shared -- when two modules' files do. A file is SHARED when
common, or when another module's files use it too (IconReelStyle: the power reel and the window tray;
CardViewCycler: weather, wiki, clock). A file nobody uses yet (a popup whose owner is still to be written)
is nobody's, and is not shared. Only files under modules/ count as users: a mockup is not a module, and
the mockup framework is not either.

Offsets are into the file's text; nothing here writes.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mockup_qmlscan import Qml, literal, parse_js_value, mask_source, JsParseError   # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.dirname(os.path.dirname(HERE))

NUMERIC_TYPES = {"real", "double", "qreal", "int", "uint", "long", "short", "number"}
INT_TYPES = {"int", "uint", "long", "short"}


class ModelError(Exception):
    pass


# =============================================================================
# the tree
# =============================================================================
class Repo:
    _WORD = re.compile(r"(?<![\w.])([A-Z][A-Za-z0-9_]*)\b")
    _URL = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.qml\b")

    def __init__(self, root=None):
        self.root = os.path.realpath(root or DEFAULT_ROOT)
        self._qml = {}
        self._raw = {}
        self._types = None
        self._users = None
        self._owners = None
        self._hints = None
        self._theme = None
        self._single = {}

    # ---- files --------------------------------------------------------------
    def abspath(self, rel):
        return os.path.join(self.root, rel)

    def relpath(self, path):
        return os.path.relpath(os.path.realpath(path), self.root)

    def qml(self, rel):
        q = self._qml.get(rel)
        if q is None:
            q = self._qml[rel] = Qml(self.abspath(rel))
        return q

    def raw(self, rel):
        """The file's text, read once (for the scans that look at every file under modules/)."""
        t = self._raw.get(rel)
        if t is None:
            with open(self.abspath(rel), encoding="utf-8") as f:
                t = self._raw[rel] = f.read()
        return t

    def invalidate(self, rels, shape=True):
        """Forget these files (they were written). `shape`: and everything derived from who uses whom -- a
        promotion writes literals and property lines, never a type reference, so it keeps the index."""
        for r in rels:
            self._qml.pop(r, None)
            self._raw.pop(r, None)
            self._single.pop(r, None)
        if shape:
            self._users = None
            self._owners = None

    @property
    def types(self):
        """{type name: relative path} for every .qml under modules/ (no basename repeats today)."""
        if self._types is None:
            t = {}
            for d, dirs, files in os.walk(os.path.join(self.root, "modules")):
                dirs.sort()
                for f in sorted(files):
                    if f.endswith(".qml"):
                        t.setdefault(f[:-4], os.path.relpath(os.path.join(d, f), self.root))
            self._types = t
        return self._types

    def type_file(self, name):
        if not name:
            return None
        return self.types.get(name.rsplit(".", 1)[-1])

    def is_singleton(self, rel):
        v = self._single.get(rel)
        if v is None:
            with open(self.abspath(rel), encoding="utf-8") as f:
                head = f.read(600)
            v = self._single[rel] = bool(re.search(r"^\s*pragma\s+Singleton\b", head, re.M))
        return v

    # ---- who uses whom ------------------------------------------------------------
    def users(self):
        """{file: set of files under modules/ that name its type} -- an instantiation, a typed property, a
        singleton read, or `Name.qml` in a string; comments do not count."""
        if self._users is None:
            idx = {}
            names = self.types
            for rel in sorted(names.values()):
                if rel.startswith("modules/common/mockup/"):
                    continue
                text = self.raw(rel)
                words = set(self._WORD.findall(mask_source(text)))
                words |= set(self._URL.findall(mask_source(text, keep_strings=True)))
                for w in words:
                    target = names.get(w)
                    if target and target != rel:
                        idx.setdefault(target, set()).add(rel)
            self._users = idx
        return self._users

    def users_of(self, rel):
        return sorted(self.users().get(rel, ()))

    # ---- modules and sharing --------------------------------------------------
    @staticmethod
    def module_dir(rel):
        parts = rel.split("/")
        if len(parts) < 3 or parts[0] != "modules" or parts[1] == "common":
            return None
        if parts[1] == "bar" and len(parts) > 3:
            return "bar/" + parts[2]
        return parts[1]

    def owners(self):
        """{file: module | 'common' | None} -- see the module docstring."""
        if self._owners is None:
            idx = self.users()
            own = {}
            commons = []
            for rel in self.types.values():
                dm = self.module_dir(rel)
                if dm:
                    own[rel] = dm
                else:
                    commons.append(rel)
            changed = True
            while changed:
                changed = False
                for rel in commons:
                    seen = set()
                    for u in idx.get(rel, ()):
                        o = own.get(u)
                        if o:
                            seen.add(o)
                    new = None if not seen else (next(iter(seen)) if len(seen) == 1 else "common")
                    if own.get(rel) != new:
                        own[rel] = new
                        changed = True
            self._owners = own
        return self._owners

    def owner(self, rel):
        return self.owners().get(rel)

    def shared(self, rel):
        h = self.hints
        if rel in h.get("shared", ()):
            return True
        if rel in h.get("owned", ()):
            return False
        o = self.owner(rel)
        if o is None:
            return False
        if o == "common":
            return True
        for u in self.users_of(rel):
            ou = self.owner(u)
            if ou is not None and ou != o:
                return True
        return False

    def protected(self, rel):
        return any(rel == p or rel.startswith(p.rstrip("/") + "/") for p in self.hints.get("protected", ()))

    # ---- hints ------------------------------------------------------------------
    @property
    def hints(self):
        if self._hints is None:
            p = os.path.join(self.root, "tools", "dev", "mockup_promote_hints.json")
            try:
                with open(p, encoding="utf-8") as f:
                    self._hints = json.load(f)
            except (OSError, ValueError):
                self._hints = {}
        return self._hints

    def row_hint(self, mockup_rel, key):
        rows = self.hints.get("rows", {}).get(mockup_rel, {}) or {}
        return rows.get(key) or rows.get(key.split(".", 1)[0] + ".*") or {}

    # ---- the theme --------------------------------------------------------------
    def theme(self):
        """(token names, alias -> token) from Theme.qml's own two maps."""
        if self._theme is None:
            with open(self.abspath("modules/common/theme/Theme.qml"), encoding="utf-8") as f:
                src = f.read()

            def block(name):
                m = re.search(r"property var %s: \(\{(.*?)\n    \}\)" % name, src, re.S)
                return dict(re.findall(r'"(\w+)":\s*"([^"]*)"', m.group(1))) if m else {}
            self._theme = (set(block("defaults")), block("aliases"))
        return self._theme

    def token_key(self, tok):
        """The Theme property a token name (or alias) stands for, or None."""
        names, aliases = self.theme()
        if tok in names:
            return tok
        return aliases.get(tok)


# =============================================================================
# a mockup
# =============================================================================
class Row:
    """One entry of a mockup's value list."""

    def __init__(self, mockup, list_id, entry, order, color_list):
        self.mockup = mockup
        self.list_id = list_id
        self.e = entry
        self.order = order
        self.prop = entry.get("prop")
        self.label = entry.get("label") or self.prop
        self.val = entry.get("val")
        self.key = "%s.%s" % (list_id, self.prop)
        self.themed = list_id in mockup.themed
        self.file_backed = list_id in mockup.file_backed
        v = self.val
        if color_list:
            self.kind = "color"
        elif isinstance(v, bool):
            self.kind = "bool"
        elif isinstance(entry.get("choices"), list) and entry.get("choices"):
            self.kind = "choice"
        elif entry.get("kind") == "json":
            self.kind = "json"
        elif entry.get("kind") == "text" or isinstance(v, str):
            self.kind = "text"
        else:
            self.kind = "num"
        self.target_expr = mockup.targets.get(list_id) or mockup.target
        h = dict(mockup.repo.row_hint(mockup.rel, self.key))
        own = entry.get("promote")
        if isinstance(own, dict):
            h.update(own)
        self.hint = h

    def __repr__(self):
        return "Row(%s %s=%r)" % (self.kind, self.key, self.val)


class Mockup:
    """A mockups/<module>.qml built on MockupWindow."""

    def __init__(self, repo, rel):
        self.repo = repo
        self.rel = rel
        self.q = repo.qml(rel)
        win = None
        for ob in self.q.objects():
            if ob.type == "MockupWindow" and ob.parent is None:
                win = ob
                break
        if win is None:
            raise ModelError("%s: no MockupWindow at its top" % rel)
        self.win = win
        self.module_id = self._string("moduleId") or module_id_of(rel)
        self.target = self._ident("target")
        self.content_id = self._ident("content")
        self.targets = self._dict("targets")
        self.themed = self._strings("themedLists")
        self.file_backed = self._dict("fileBackedLists")
        self.errors = []
        self.list_ids = list((self._dict("lists") or {}).keys())
        self._rows = None

    # ---- root assignments --------------------------------------------------------
    def _stmt(self, name):
        st = self.win.member(name, ("assign", "decl"))
        return st

    def _text(self, name):
        st = self._stmt(name)
        return self.q.value_text(st) if st else None

    def _string(self, name):
        t = self._text(name)
        if t is None:
            return None
        k, v, _ = literal(t)
        return v if k in ("str", "color") else None

    def _ident(self, name):
        t = self._text(name)
        return t.strip() if t and re.fullmatch(r"[A-Za-z_][\w.]*", t.strip()) else None

    def _dict(self, name):
        t = self._text(name)
        if not t:
            return {}
        try:
            v, _ = parse_js_value(t)
        except (JsParseError, IndexError):
            return {}
        return {k: str(x) for k, x in v.items()} if isinstance(v, dict) else {}

    def _strings(self, name):
        t = self._text(name)
        if not t:
            return []
        try:
            v, _ = parse_js_value(t)
        except (JsParseError, IndexError):
            return []
        return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []

    # ---- rows --------------------------------------------------------------------
    def entries(self, list_id):
        """The parsed entries of `property var <list_id>: [ ... ]` in the mockup's root (or None)."""
        st = self.win.member(list_id, ("decl",))
        if st is None or st.vstart is None:
            return None
        try:
            v, _ = parse_js_value(self.q.value_text(st))
        except (JsParseError, IndexError) as e:
            self.errors.append("%s: list %s does not parse (%s)" % (self.rel, list_id, e))
            return None
        return [x for x in v if isinstance(x, dict)] if isinstance(v, list) else None

    def rows(self):
        if self._rows is None:
            out = []
            for lid in self.list_ids:
                es = self.entries(lid)
                if es is None:
                    self.errors.append("%s: list %s is registered but not found as `property var %s: [...]`" % (self.rel, lid, lid))
                    continue
                color = bool(es) and isinstance(es[0].get("val"), str) and not es[0].get("kind")
                for i, e in enumerate(es):
                    if e.get("prop"):
                        out.append(Row(self, lid, e, i, color))
            self._rows = out
        return self._rows

    def row(self, key):
        for r in self.rows():
            if r.key == key:
                return r
        return None


def module_id_of(rel):
    """The module a mockup file is named for: mockups/<moduleId>.qml (a fixture tree's test_<moduleId>.qml too)."""
    b = os.path.basename(rel)[:-4] if rel.endswith(".qml") else os.path.basename(rel)
    return b[5:] if b.startswith("test_") else b


def all_mockups(repo):
    """Relative paths of every mockup: the mockups/*.qml that hold a MockupWindow."""
    out = []
    d = repo.abspath("mockups")
    names = ["mockups/" + f for f in sorted(os.listdir(d))] if os.path.isdir(d) else []
    for f in names:
        if f.endswith(".qml"):
            try:
                with open(repo.abspath(f), encoding="utf-8") as fh:
                    if "MockupWindow {" in fh.read():
                        out.append(f)
            except OSError:
                pass
    return out


# =============================================================================
# a target expression, hop by hop
# =============================================================================
class Hop:
    """One object on the way from the mockup to what a row writes to."""
    __slots__ = ("file", "type", "holder_rel", "holder_q", "holder_obj", "seg", "multi", "inline")

    def __init__(self, file, type_, holder_rel, holder_q, holder_obj, seg=None, multi=False, inline=None):
        self.inline = inline            # an inline `component Name: Base {}` of the holder's file: the type is its base
        self.file = file                # the type's own file (None: a builtin such as Rectangle)
        self.type = type_
        self.holder_rel = holder_rel    # the file the object is written in ('' = the mockup)
        self.holder_q = holder_q
        self.holder_obj = holder_obj    # the object's body there: where a use-site line goes
        self.seg = seg                  # the alias / property name that reached it from the previous hop
        self.multi = multi              # reached through a dotted alias path (no dotted write through it)


class Chain:
    def __init__(self, kind, hops=None, head_obj=None, content=False, error=None, expr=None):
        self.kind = kind                # component | local | singleton | unresolved
        self.hops = hops or []
        self.head_obj = head_obj        # the mockup's own object the expression starts at
        self.content = content          # that object is the mockup's content (the drop-in)
        self.error = error
        self.expr = expr

    @property
    def last(self):
        return self.hops[-1] if self.hops else None


class Resolver:
    def __init__(self, mockup):
        self.m = mockup
        self.repo = mockup.repo

    def hop(self, type_name, holder_rel, holder_q, holder_obj, seg=None, multi=False):
        """A hop for an object of `type_name` written in the holder's file: its own file, or the base of an
        inline component the holder defines (silicon's `component Field: ParticleField`)."""
        f = self.repo.type_file(type_name)
        inline = None
        if f is None and holder_q is not None:
            inline = holder_q.inline_component(type_name)
            if inline is not None:
                f = self.repo.type_file(inline.type)
        return Hop(f, type_name, holder_rel, holder_q, holder_obj, seg, multi, inline)

    def resolve(self, expr, _depth=0):
        if not expr:
            return Chain("unresolved", error="the mockup names no target for this list", expr=expr)
        if _depth > 6:
            return Chain("unresolved", error="`%s` expands too deep" % expr, expr=expr)
        # a typed root the mockup gets at run time (silicon's `win._popup`): named by a hint
        dyn = (self.repo.hints.get("dynamic", {}).get(self.m.rel, {}) or {})
        for key in sorted(dyn, key=len, reverse=True):
            if expr == key or expr.startswith(key + "."):
                return self._from_type(dyn[key], expr[len(key) + 1:], expr)
        head, *segs = expr.split(".")
        obj = self.m.q.by_id(head)
        if obj is self.m.win and segs:
            # `win._director`: a read-only property of the mockup that points at a live object
            st = self.m.win.member(segs[0], ("decl",))
            if st is not None and st.vstart is not None:
                inner = self._unguard(self.m.q.value_text(st))
                if inner:
                    return self.resolve(".".join([inner] + segs[1:]), _depth + 1)
            return Chain("unresolved", error="`%s` is no resolvable property of the mockup's window" % expr, expr=expr)
        if obj is None:
            f = self.repo.type_file(head)
            if f and self.repo.is_singleton(f) and not segs:
                return Chain("singleton", hops=[Hop(f, head, "", None, None)], expr=expr)
            return Chain("unresolved", error="no object `%s` in %s" % (head, self.m.rel), expr=expr)
        f = self.repo.type_file(obj.type)
        content = self.m.content_id == head
        if f is None:
            if segs:
                return Chain("unresolved", error="`%s` is a plain %s: nothing to follow `%s` into" % (head, obj.type, ".".join(segs)), expr=expr)
            return Chain("local", hops=[Hop(None, obj.type, self.m.rel, self.m.q, obj)], head_obj=obj, content=content, expr=expr)
        hops = [self.hop(obj.type, self.m.rel, self.m.q, obj)]
        for seg in segs:
            nxt = self.follow(hops[-1], seg)
            if isinstance(nxt, str):
                return Chain("unresolved", error=nxt, expr=expr)
            hops.extend(nxt)
        return Chain("component", hops=hops, head_obj=obj, content=content, expr=expr)

    @staticmethod
    def _unguard(text):
        """`cond ? win.x.y : null` -> `win.x.y`; a plain path stays; anything else is None."""
        t = text.strip()
        m = re.fullmatch(r"(?:[^?]+)\?\s*([\w.]+)\s*:\s*null", t, re.S)
        if m:
            return m.group(1)
        return t if re.fullmatch(r"[\w.]+", t) else None

    def _from_type(self, type_name, rest, expr):
        """A chain that starts at the module's own `type_name` (a runtime instance of it) and follows `rest`."""
        f = self.repo.type_file(type_name)
        if not f:
            return Chain("unresolved", error="hint: no type `%s` under modules/" % type_name, expr=expr)
        hops = [Hop(f, type_name, "", None, None)]
        for seg in [x for x in rest.split(".") if x]:
            nxt = self.follow(hops[-1], seg)
            if isinstance(nxt, str):
                return Chain("unresolved", error=nxt, expr=expr)
            hops.extend(nxt)
        return Chain("component", hops=hops, head_obj=None, content=True, expr=expr)

    def follow(self, hop, seg):
        """The hop(s) `seg` leads to from the object of `hop`: an alias to a child object (a path may
        run through several), or a typed property holding an object. A string is the reason it cannot."""
        if hop.file is None:
            return "`%s` is a plain %s: nothing to follow `%s` into" % (hop.type, hop.type, seg)
        if hop.inline is not None:
            # an inline component's own aliases / typed properties live in its body; fall to the base's
            ist = hop.inline.member(seg, ("alias",))
            if ist is not None:
                parts = [p.strip() for p in hop.holder_q.value_text(ist).split(".")]
                child = hop.holder_q.by_id(parts[0])
                if child is not None:
                    hops = [self.hop(child.type, hop.holder_rel, hop.holder_q, child, seg, multi=len(parts) > 1)]
                    for sub in parts[1:]:
                        nxt = self.follow(hops[-1], sub)
                        if isinstance(nxt, str):
                            return nxt
                        hops.extend(nxt)
                    return hops
        fq = self.repo.qml(hop.file)
        root = fq.root()
        if root is None:
            return "%s has no root object" % hop.file
        st = root.member(seg, ("alias",))
        if st is not None:
            parts = [p.strip() for p in fq.value_text(st).split(".")]
            child = fq.by_id(parts[0])
            if child is None:
                return "%s: `alias %s` names `%s`, which is no object of the file" % (hop.file, seg, parts[0])
            hops = [self.hop(child.type, hop.file, fq, child, seg, multi=len(parts) > 1)]
            for sub in parts[1:]:
                nxt = self.follow(hops[-1], sub)
                if isinstance(nxt, str):
                    return "%s: `alias %s` -> %s: %s" % (hop.file, seg, ".".join(parts), nxt)
                hops.extend(nxt)
            return hops
        st = root.member(seg, ("decl",))
        if st is not None and st.ptype and st.ptype[0].isupper():
            ob = fq.object_in_value(st)
            if ob is not None:
                return [self.hop(st.ptype, hop.file, fq, ob, seg)]
            return "%s: `property %s %s` has no object of its own to write into" % (hop.file, st.ptype, seg)
        base = self.repo.type_file(root.type)
        if base:
            return "%s: no alias or typed property `%s` (declared in a base type, %s, if at all)" % (hop.file, seg, os.path.basename(base))
        return "%s: no alias or typed property `%s`" % (hop.file, seg)


# =============================================================================
# a property: where it is declared, what overrides it
# =============================================================================
class PropInfo:
    """decl: (rel, Qml, Stmt) of the declaration (None: a builtin property or none at all);
    overrides: root-level `prop: v` assignments met on the way UP the type chain, nearest first;
    chain: the files walked."""

    def __init__(self):
        self.decl = None
        self.overrides = []
        self.chain = []

    @property
    def ptype(self):
        return self.decl[2].ptype if self.decl else None

    @property
    def readonly(self):
        return bool(self.decl and self.decl[2].readonly)

    @property
    def is_alias(self):
        return bool(self.decl and self.decl[2].kind == "alias")


def lookup(repo, rel, prop, inline=None, inline_rel=None, inline_q=None):
    """Where `prop` is declared for the type whose file is `rel`: its own root, else a base type's. An
    inline component's body (`inline`, written in `inline_rel`) is nearer than the base file."""
    info = PropInfo()
    if inline is not None:
        st = inline.member(prop, ("decl", "alias"))
        if st is not None:
            info.decl = (inline_rel, inline_q, st)
            return info
        ov = inline.member(prop, ("assign",))
        if ov is not None:
            info.overrides.append((inline_rel, inline_q, ov))
    cur = rel
    seen = set()
    while cur and cur not in seen:
        seen.add(cur)
        info.chain.append(cur)
        fq = repo.qml(cur)
        root = fq.root()
        if root is None:
            break
        st = root.member(prop, ("decl", "alias"))
        if st is not None:
            info.decl = (cur, fq, st)
            break
        ov = root.member(prop, ("assign",))
        if ov is not None:
            info.overrides.append((cur, fq, ov))
        cur = repo.type_file(root.type)
    return info


class Eff:
    """The default a module ships for a property, and where it is written."""
    __slots__ = ("kind", "value", "text", "rel", "line", "where")

    def __init__(self, kind, value, text, rel, line, where):
        self.kind, self.value, self.text, self.rel, self.line, self.where = kind, value, text, rel, line, where

    def at(self):
        return "%s:%s" % (self.rel, self.line) if self.rel else "(nowhere)"

    def __repr__(self):
        return "Eff(%s %r @%s %s)" % (self.kind, self.value, self.at(), self.where)


def use_sites(chain, creation_sites=()):
    """Where a write for this chain can sit, nearest the property first:
    [(holder_rel, holder_q, obj, prefix)]. `prefix` is the dotted alias path from that object down to the
    target ('' when the object IS the target). The chain's first hop is the mockup's own object, so its
    place in module code is the root of the type's file (dotted through the aliases) -- when the head is
    the mockup's content; for another head the module's own creation sites (a typed property's default
    object the mockup hands the head to) stand in."""
    hops = chain.hops
    n = len(hops) - 1
    out = []
    for j in range(n, 0, -1):
        segs = [h.seg for h in hops[j + 1:]]
        if any(h.multi for h in hops[j + 1:]) or any(s is None for s in segs):
            continue
        h = hops[j]
        out.append((h.holder_rel, h.holder_q, h.holder_obj, "".join(s + "." for s in segs)))
        if h.inline is not None and not segs:
            out.append((h.holder_rel, h.holder_q, h.inline, ""))
    segs = [h.seg for h in hops[1:]]
    ok0 = not any(h.multi for h in hops[1:]) and not any(s is None for s in segs)
    prefix0 = "".join(s + "." for s in segs)
    if chain.content and hops[0].file:
        # the module's own file: its root object, dotted through the aliases
        if ok0 or n == 0:
            q0 = None
            out.append((hops[0].file, None, None, prefix0))     # q / obj filled by the caller (needs the repo)
    else:
        for (rel, q, ob) in creation_sites:
            if ok0 or n == 0:
                out.append((rel, q, ob, prefix0))
    return out


def fill_root_sites(repo, sites):
    """use_sites() leaves the content root's Qml / object unset (it needs the repo): fill them."""
    out = []
    for rel, q, ob, prefix in sites:
        if q is None:
            q = repo.qml(rel)
            ob = q.root()
        out.append((rel, q, ob, prefix))
    return out


def effective(repo, chain, prop, info, sites):
    """The default shipped for `prop` on this chain's target: the OUTERMOST use-site assignment, else the
    nearest override on the type chain, else the declaration's own default."""
    for rel, q, ob, prefix in reversed(sites):
        if ob is None:
            continue
        st = ob.member(prefix + prop, ("assign",))
        if st is not None:
            k, v, t = literal(q.value_text(st))
            return Eff(k, v, t, rel, q.line_of(st.start), "use-site")
    for rel, q, st in info.overrides:
        k, v, t = literal(q.value_text(st))
        return Eff(k, v, t, rel, q.line_of(st.start), "override")
    if info.decl:
        rel, q, st = info.decl
        if st.kind == "decl" and st.vstart is not None:
            k, v, t = literal(q.value_text(st))
            return Eff(k, v, t, rel, q.line_of(st.start), "declaration")
        if st.kind == "alias":
            return Eff("expr", None, q.value_text(st), rel, q.line_of(st.start), "alias")
        return Eff("none", None, "", rel, q.line_of(st.start), "declaration")
    return Eff("none", None, "", None, None, "builtin")


# =============================================================================
# a mockup-local object's properties: which module property reads them
# =============================================================================
class Consumer:
    """`Y: <expr of tun.P>` on an object of a module's type (or a `Binding { target; property; value }`
    onto one): the mockup feeds the module's Y from the row. `chain` is that object as a target."""
    __slots__ = ("chain", "type", "name", "expr", "transform", "line")

    def __init__(self, chain, type_, name, expr, transform, line):
        self.chain, self.type, self.name, self.expr, self.transform, self.line = chain, type_, name, expr, transform, line


_TERNARY = re.compile(r"^(?P<neg>!)?\s*(?P<ref>[\w.]+)\s*\?\s*(?P<a>\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|[-\w.]+)\s*:\s*(?P<b>\"(?:[^\"\\]|\\.)*\"|'(?:[^'\\]|\\.)*'|[-\w.]+)$", re.S)


def _transform(text, ref):
    t = text.strip()
    if t.startswith("(") and t.endswith(")"):
        t = t[1:-1].strip()
    if t == ref:
        return ("identity",)
    if t == "!" + ref:
        return ("not",)
    m = _TERNARY.match(t)
    if m and m.group("ref") == ref:
        a, b = _lit(m.group("a")), _lit(m.group("b"))
        if a is not _NO and b is not _NO:
            if m.group("neg"):
                a, b = b, a
            return ("ternary", a, b)
    return None


def consumers(mockup, obj_id, prop):
    """Statements of the mockup that read `<obj_id>.<prop>`, as module properties. A statement on an
    object that is not a module type (an Item, a Text) is returned with chain None: it is the mockup's own."""
    repo, q = mockup.repo, mockup.q
    resolver = Resolver(mockup)
    out = []
    ref = "%s.%s" % (obj_id, prop)
    pat = re.compile(r"(?<![\w.])%s\.%s\b" % (re.escape(obj_id), re.escape(prop)))
    for ob in q.objects():
        if ob.group or q.in_component(ob):
            continue
        if ob.type == "Binding":
            sts = {s.name: s for s in ob.stmts() if s.kind == "assign"}
            if not all(k in sts for k in ("target", "property", "value")):
                continue
            vtext = q.value_text(sts["value"])
            if not pat.search(mask_source(vtext)):
                continue
            k, pname, _ = literal(q.value_text(sts["property"]))
            ch = resolver.resolve(q.value_text(sts["target"]).strip())
            if k != "str" or ch.kind != "component":
                out.append(Consumer(None, "Binding", pname if k == "str" else "?", vtext, None, q.line_of(ob.start)))
                continue
            out.append(Consumer(ch, ch.last.type, pname, vtext, _transform(vtext, ref), q.line_of(ob.start)))
            continue
        rel = repo.type_file(ob.type)
        for st in ob.stmts():
            if st.kind != "assign" or "." in st.name or st.vstart is None:
                continue
            text = q.value_text(st)
            if not pat.search(mask_source(text)):
                continue
            if not rel:
                out.append(Consumer(None, ob.type, st.name, text, None, q.line_of(st.start)))
                continue
            ch = Chain("component", hops=[Hop(rel, ob.type, mockup.rel, q, ob)], head_obj=ob,
                       content=(mockup.content_id is not None and ob.id == mockup.content_id), expr=ob.id or ob.type)
            out.append(Consumer(ch, ob.type, st.name, text, _transform(text, ref), q.line_of(st.start)))
    return out


_NO = object()


def _lit(t):
    k, v, _ = literal(t)
    return v if k in ("num", "bool", "str", "color") else _NO


def creation_sites(mockup, head_obj):
    """Where the MODULE creates the object a mockup made and handed over: `Y: <head id>` on an object of a
    module type whose file declares `property <Type> Y: <Type> { ... }` -> [(rel, Qml, the inline object)]."""
    repo, q = mockup.repo, mockup.q
    hid = head_obj.id
    out = []
    seen = set()
    if not hid:
        return out
    for ob in q.objects():
        rel = repo.type_file(ob.type) if not ob.group else None
        if not rel:
            continue
        for st in ob.stmts():
            if st.kind == "assign" and "." not in st.name and q.value_text(st) and q.value_text(st).strip() == hid:
                fq = repo.qml(rel)
                root = fq.root()
                if root is None:
                    continue
                d = root.member(st.name, ("decl",))
                if d is None or d.ptype != head_obj.type:
                    continue
                inner = fq.object_in_value(d)
                if inner is not None and inner.type == head_obj.type and (rel, inner.open) not in seen:
                    seen.add((rel, inner.open))
                    out.append((rel, fq, inner))
    return out


def hosts_of(repo, rel, exclude=()):
    """Objects of the type in `rel` instantiated in OTHER module files: [(host rel, Qml, Obj)]."""
    name = os.path.basename(rel)[:-4]
    out = []
    for u in repo.users_of(rel):
        if u in exclude:
            continue
        fq = repo.qml(u)
        for ob in fq.objects_of_type(name):
            out.append((u, fq, ob))
    return out
