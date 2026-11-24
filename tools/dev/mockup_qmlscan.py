#!/usr/bin/env python3
"""A small, tolerant QML structure scanner: what the mockup pipeline needs to
find a property's declaration, an object's members and the spans to rewrite.

Used by tools/dev/mockup_promote.py (Save writes the real implementation) and
tools/dev/mockup_wiring_check.py. It is NOT a QML parser: it understands exactly
enough of the language to answer

    which object is `id: foo`, and what type is it
    which statements sit directly inside an object (assignments, declarations,
    child objects, handlers), with the span of each value
    is a value a LITERAL (a number, a bool, a string, a colour) or an
    expression (a binding)

and to do it without being fooled by comments, strings, regular expressions
or brackets inside strings. Every answer is an offset into the file's text, so
an edit is a splice and every other byte stays as it was.

The unit tests are in tools/dev/mockup_qmlscan_cases.py.
"""
import json
import re

IDENT = r"[A-Za-z_][A-Za-z0-9_]*"
TYPE_RE = re.compile(r"[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")

# What a previous character says about a `/`: after one of these it opens a
# regular expression literal, otherwise it is a division.
_REGEX_AFTER = set("(,=:[!&|?{};") | {""}

NUM_RE = re.compile(r"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?")
HEX_RE = re.compile(r"#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})")


_MASK_RE = re.compile(
    r"//[^\n]*"                                         # line comment
    r"|/\*.*?\*/"                                       # block comment
    r"|\"(?:[^\"\\\n]|\\.)*\"?"                         # "string" (an unterminated one ends with its line)
    r"|'(?:[^'\\\n]|\\.)*'?"                            # 'string'
    r"|`(?:[^`\\]|\\.)*`?"                              # `template`
    r"|(?:(?<=[(,=:\[!&|?{};])|(?<=\breturn)|(?<=\btypeof)|(?<=\bcase))\s*/(?![/*])(?:[^/\\\n\[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+/[gimsuy]*",   # /regex/ after an operator or return
    re.S)


def mask_source(text, keep_strings=False):
    """`text` with comments and the insides of string / regex / template
    literals replaced by spaces (newlines kept), so every offset still
    addresses the original and a bracket in a string is not a bracket.
    `keep_strings` blanks the comments only (to read a file name in a string)."""
    def blank(m):
        t = m.group(0)
        c = t.lstrip()[:1]
        if t.startswith("//") or t.startswith("/*"):
            return re.sub(r"[^\n]", " ", t)
        if c in "\"'`" and t[:1] == c:
            if keep_strings:
                return t
            body = t[1:-1] if len(t) > 1 and t[-1] == c else t[1:]
            tail = t[-1] if len(t) > 1 and t[-1] == c else ""
            return c + re.sub(r"[^\n]", " ", body) + tail
        # a regex literal (possibly with leading blanks)
        lead = len(t) - len(t.lstrip())
        core = t[lead:]
        k = core.rfind("/")
        return t[:lead] + "/" + re.sub(r"[^\n]", " ", core[1:k]) + core[k:]
    return _MASK_RE.sub(blank, text)


_BR_RE = re.compile(r"[()\[\]{}]")


def match_table(mask):
    """{open offset: close offset} for ( [ { in the masked text."""
    pairs = {}
    stack = []
    close_of = {")": "(", "]": "[", "}": "{"}
    for m in _BR_RE.finditer(mask):
        c = m.group(0)
        i = m.start()
        if c in "([{":
            stack.append((c, i))
        else:
            # tolerate a stray closer: pop to the matching opener if any
            while stack and stack[-1][0] != close_of[c]:
                stack.pop()
            if stack:
                _, o = stack.pop()
                pairs[o] = i
    return pairs


class Stmt:
    """One depth-0 statement of an object body."""
    __slots__ = ("kind", "name", "start", "end", "vstart", "vend", "ptype",
                 "readonly", "obj", "line")

    def __init__(self, **kw):
        for k in self.__slots__:
            setattr(self, k, kw.get(k))

    def __repr__(self):
        return "Stmt(%s %s [%s:%s] v=[%s:%s])" % (self.kind, self.name, self.start, self.end, self.vstart, self.vend)


class Obj:
    """A QML object: `Type { ... }`, `Type on prop { ... }` or a group `name { ... }`."""
    __slots__ = ("type", "start", "open", "close", "parent", "children", "id", "group", "_stmts", "src", "component", "comp_name")

    def __init__(self, src, type_, start, open_, close, group=False):
        self.component = False          # this object IS the body of an inline `component Name: Type { }`
        self.comp_name = None
        self.src = src
        self.type = type_
        self.start = start
        self.open = open_
        self.close = close
        self.parent = None
        self.children = []
        self.id = None
        self.group = group
        self._stmts = None

    def __repr__(self):
        return "Obj(%s id=%s [%s:%s])" % (self.type, self.id, self.open, self.close)

    def stmts(self):
        if self._stmts is None:
            self._stmts = self.src._statements(self)
        return self._stmts

    def member(self, name, kinds=("assign",)):
        for s in self.stmts():
            if s.kind in kinds and s.name == name:
                return s
        return None


_CONT_START = ("?", ":", "&&", "||", "+", "-", "*", "/", ".", ")", "]", "==", "!=", "<", ">",
               "%", "|", "&", "^", "=", ",")
_CONT_END = set("?:+-*/%&|^<>=,([{.!")


class Qml:
    """A file, scanned."""

    def __init__(self, path, text=None):
        self.path = path
        if text is None:
            with open(path, encoding="utf-8", newline="") as f:
                text = f.read()
        self.text = text
        self.mask = mask_source(text)
        self.pairs = match_table(self.mask)
        self._line_starts = None
        self._objects = None
        self._root = None

    # ---- positions ---------------------------------------------------------
    def line_starts(self):
        if self._line_starts is None:
            ls = [0]
            for m in re.finditer("\n", self.text):
                ls.append(m.end())
            self._line_starts = ls
        return self._line_starts

    def line_of(self, off):
        import bisect
        return bisect.bisect_right(self.line_starts(), off)      # 1-based

    def line_start(self, off):
        return self.line_starts()[self.line_of(off) - 1]

    def indent_at(self, off):
        ls = self.line_start(off)
        m = re.match(r"[ \t]*", self.text[ls:])
        return m.group(0)

    # ---- objects -----------------------------------------------------------
    _JS_WORDS = {"else", "try", "finally", "do", "default", "if", "for", "while", "switch", "catch", "return",
                 "typeof", "in", "of", "new", "delete", "void", "case", "break", "continue", "throw", "function"}

    def objects(self):
        if self._objects is not None:
            return self._objects
        mask = self.mask
        # every brace's enclosing brace, so a group candidate can be checked to
        # sit directly in an object body and not in a function's block
        brace_parent = {}
        stack = []
        opens = sorted(o for o in self.pairs if mask[o] == "{")
        for o in opens:
            while stack and self.pairs[stack[-1]] < o:
                stack.pop()
            brace_parent[o] = stack[-1] if stack else None
            stack.append(o)
        objs = []
        object_opens = set()
        cand_groups = []
        for o in opens:
            c = self.pairs[o]
            # the token(s) before the brace
            j = o - 1
            while j >= 0 and mask[j].isspace():
                j -= 1
            if j < 0:
                continue
            k = j
            while k >= 0 and (mask[k].isalnum() or mask[k] in "_."):
                k -= 1
            word = mask[k + 1:j + 1]
            if not word:
                continue
            tstart = k + 1
            before = mask[max(0, tstart - 90):tstart]
            mon = re.search(r"([A-Z][A-Za-z0-9_.]*)\s+on\s+$", before)
            if mon and re.fullmatch(IDENT, word):
                # `Type on prop {`
                objs.append(Obj(self, mon.group(1), tstart - (len(before) - mon.start(1)), o, c))
                object_opens.add(o)
            elif TYPE_RE.fullmatch(word):
                pre = mask[max(0, tstart - 8):tstart].rstrip()
                if pre.endswith("enum") or pre.endswith("new") or pre.endswith("."):
                    continue
                objs.append(Obj(self, word, tstart, o, c))
                object_opens.add(o)
            elif re.fullmatch(IDENT, word) and word[0].islower() and word not in self._JS_WORDS:
                if self._starts_statement(tstart):
                    cand_groups.append(Obj(self, word, tstart, o, c, group=True))
        for g in cand_groups:
            if brace_parent.get(g.open) in object_opens:
                objs.append(g)
                object_opens.add(g.open)
        # nesting
        objs.sort(key=lambda x: (x.open, -x.close))
        stack = []
        for ob in objs:
            while stack and stack[-1].close < ob.open:
                stack.pop()
            if stack:
                ob.parent = stack[-1]
                stack[-1].children.append(ob)
            stack.append(ob)
        self._objects = objs
        for ob in objs:
            if ob.group:
                continue
            mc = re.search(r"(?:^|[\n{;])[ \t]*component[ \t]+(" + IDENT + r")[ \t]*:[ \t]*$", mask[max(0, ob.start - 120):ob.start])
            if mc:
                ob.component = True
                ob.comp_name = mc.group(1)
        self._assign_ids(objs)
        return objs

    @staticmethod
    def in_component(ob):
        """Is `ob` inside an inline component definition (not an instance of anything in the file)?"""
        while ob is not None:
            if ob.component:
                return True
            ob = ob.parent
        return False

    _ID_RE = re.compile(r"(?:^|(?<=[\n{;]))[ \t]*id[ \t]*:[ \t]*(" + IDENT + r")[ \t]*(?=[;\n}])")

    def _assign_ids(self, objs):
        """`id: name` lines to the object they sit directly in: the innermost
        object around the offset, provided no other brace pair intervenes."""
        if not objs:
            return
        import bisect
        opens = [o.open for o in objs]               # sorted by open
        for m in self._ID_RE.finditer(self.mask):
            at = m.start(1)
            k = bisect.bisect_right(opens, at) - 1
            while k >= 0 and objs[k].close < at:
                k -= 1
            # the innermost object whose body holds `at`; objs are sorted by
            # open, so the nearest earlier open that is still open is it
            cand = None
            j = k
            while j >= 0:
                if objs[j].open < at < objs[j].close:
                    cand = objs[j]
                    break
                j -= 1
            if cand is not None and cand.id is None:
                # `id:` must be at the object's depth 0: no unrelated brace between
                depth_ok = True
                for ch in cand.children:
                    if ch.open < at < ch.close:
                        depth_ok = False
                if depth_ok:
                    cand.id = m.group(1)

    def _starts_statement(self, off):
        j = off - 1
        while j >= 0 and self.mask[j] in " \t":
            j -= 1
        return j < 0 or self.mask[j] in "\n{;"

    def root(self):
        if self._root is None:
            top = [o for o in self.objects() if o.parent is None and not o.group]
            self._root = top[0] if top else None
        return self._root

    def by_id(self, ident):
        """The object with `id: ident`; one inside an inline component only when nothing else has it."""
        inner = None
        for ob in self.objects():
            if ob.id == ident:
                if not self.in_component(ob):
                    return ob
                inner = inner or ob
        return inner

    def objects_of_type(self, typename):
        return [o for o in self.objects() if o.type == typename and not o.group]

    # ---- statements --------------------------------------------------------
    def _statements(self, ob):
        """Depth-0 statements of an object body, with value spans."""
        mask = self.mask
        lo, hi = ob.open + 1, ob.close
        pairs = self.pairs
        pending = []
        i = lo
        stmt_start = None
        last_sig = ""            # last significant char of the current statement
        while i < hi:
            c = mask[i]
            if c in "([{":
                if stmt_start is None:
                    stmt_start = i
                j = pairs.get(i)
                if j is None or j >= hi:
                    i += 1
                    continue
                last_sig = mask[j]
                i = j + 1
                continue
            if c == "\n":
                if stmt_start is not None:
                    j = i + 1
                    while j < hi and mask[j] in " \t\n\r":
                        j += 1
                    continues = last_sig in _CONT_END or (j < hi and mask.startswith(_CONT_START, j))
                    if not continues:
                        pending.append((stmt_start, i))
                        stmt_start = None
                        last_sig = ""
                i += 1
                continue
            if c == ";":
                if stmt_start is not None:
                    pending.append((stmt_start, i))
                    stmt_start = None
                    last_sig = ""
                i += 1
                continue
            if not c.isspace():
                if stmt_start is None:
                    stmt_start = i
                last_sig = c
            i += 1
        if stmt_start is not None:
            pending.append((stmt_start, hi))
        out = []
        for s, e in pending:
            st = self._classify(ob, s, e)
            if st is not None:
                out.append(st)
        return out

    def _classify(self, ob, s, e):
        mask = self.mask
        while e > s and mask[e - 1].isspace():
            e -= 1
        if e <= s:
            return None
        head = mask[s:e]
        line = self.line_of(s)
        m = re.match(r"((?:(?:readonly|required|default)\s+)*)property\s+alias\s+(" + IDENT + r")\s*:", head)
        if m:
            return Stmt(kind="alias", name=m.group(2), start=s, end=e, vstart=s + m.end(), vend=e,
                        readonly="readonly" in m.group(1), line=line)
        m = re.match(r"((?:(?:readonly|required|default)\s+)*)property\s+([A-Za-z_][A-Za-z0-9_.<>]*)\s+(" + IDENT + r")\s*(:)?", head)
        if m:
            vs = s + m.end(4) if m.group(4) else None
            return Stmt(kind="decl", name=m.group(3), ptype=m.group(2), start=s, end=e, vstart=vs,
                        vend=e if vs is not None else None, readonly="readonly" in m.group(1), line=line)
        m = re.match(r"signal\s+(" + IDENT + ")", head)
        if m:
            return Stmt(kind="signal", name=m.group(1), start=s, end=e, line=line)
        m = re.match(r"(?:async\s+)?function\s+(" + IDENT + ")", head)
        if m:
            return Stmt(kind="function", name=m.group(1), start=s, end=e, line=line)
        if re.match(r"enum\s", head):
            return Stmt(kind="enum", name="", start=s, end=e, line=line)
        m = re.match(r"component\s+(" + IDENT + r")\s*:", head)
        if m:
            return Stmt(kind="component", name=m.group(1), start=s, end=e, line=line)
        m = re.match(r"id\s*:", head)
        if m:
            return Stmt(kind="id", name="id", start=s, end=e, vstart=s + m.end(), vend=e, line=line)
        for child in ob.children:
            if child.start == s:
                return Stmt(kind="group" if child.group else "object", name=child.type, start=s, end=e, obj=child, line=line)
        m = re.match(r"(" + IDENT + r"(?:\s*\.\s*" + IDENT + r")*)\s*:(?!:)", head)
        if m:
            name = re.sub(r"\s+", "", m.group(1))
            return Stmt(kind="assign", name=name, start=s, end=e, vstart=s + m.end(), vend=e, line=line)
        return Stmt(kind="other", name="", start=s, end=e, line=line)

    def inline_component(self, name):
        """The body object of `component <name>: Base { ... }` in this file (its type is the base), or None."""
        for ob in self.objects():
            if ob.component and ob.comp_name == name:
                return ob
        return None

    def object_in_value(self, st):
        """The (first) object written inside the value of a declaration / assignment:
        `property Style style: Style { ... }` -> that Style object."""
        if st.vstart is None:
            return None
        best = None
        for ob in self.objects():
            if st.vstart <= ob.start and ob.close <= st.vend:
                if best is None or ob.start < best.start:
                    best = ob
        return best

    # ---- values ------------------------------------------------------------
    def value_text(self, st):
        """The value expression of an assign / decl / alias statement,
        trailing comment and space dropped."""
        if st.vstart is None:
            return None
        s, e = st.vstart, st.vend
        # the mask has the comments blanked; trim the blanks off the end
        while e > s and self.mask[e - 1].isspace():
            e -= 1
        while s < e and self.mask[s].isspace():
            s += 1
        return self.text[s:e]

    def value_span(self, st):
        """(start, end) of the value text in the file, trimmed like value_text."""
        s, e = st.vstart, st.vend
        while e > s and self.mask[e - 1].isspace():
            e -= 1
        while s < e and self.mask[s].isspace():
            s += 1
        return s, e


def literal(expr):
    """Classify a value expression.

    -> ("num", float|int, text) | ("bool", bool, text) | ("str", str, text)
       | ("color", "#RRGGBB", text) | ("token", "name", text)   (`Theme.name`)
       | ("expr", None, text)"""
    t = expr.strip()
    if t.startswith("(") and t.endswith(")") and re.fullmatch(r"\(\s*[^()]*\)", t):
        inner = t[1:-1].strip()
        if inner and not inner.startswith("{") and not inner.startswith("["):
            t2 = inner
        else:
            t2 = t
    else:
        t2 = t
    if re.fullmatch(NUM_RE, t2):
        v = float(t2)
        if re.fullmatch(r"[-+]?\d+", t2):
            return ("num", int(t2), t)
        return ("num", v, t)
    if t2 == "true":
        return ("bool", True, t)
    if t2 == "false":
        return ("bool", False, t)
    m = re.fullmatch(r'"((?:[^"\\\n]|\\.)*)"', t2) or re.fullmatch(r"'((?:[^'\\\n]|\\.)*)'", t2)
    if m:
        try:
            s = json.loads('"' + m.group(1).replace('\\\'', "'").replace('"', '\\"') + '"') if t2[0] == "'" else json.loads(t2)
        except ValueError:
            s = m.group(1)
        if HEX_RE.fullmatch(s):
            return ("color", s, t)
        return ("str", s, t)
    m = re.fullmatch(r"Theme\.(" + IDENT + ")", t2)
    if m:
        return ("token", m.group(1), t)
    return ("expr", None, t)


def format_number(v):
    if isinstance(v, bool):
        raise ValueError("bool is not a number")
    if isinstance(v, int):
        return str(v)
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    r = repr(round(v, 9))
    return r


def format_literal(kind, v):
    """The QML literal for a Python value of a row's kind."""
    if kind == "bool":
        return "true" if v else "false"
    if kind == "num":
        return format_number(v)
    if kind == "color":
        return '"' + str(v).upper() + '"'
    if kind == "str":
        return json.dumps(v, ensure_ascii=False)
    raise ValueError(kind)


# ---- JS-literal parsing (a mockup's entries: unquoted keys, single quotes,
# trailing commas, comments) -------------------------------------------------
class JsParseError(ValueError):
    pass


def parse_js_value(text, pos=0):
    """Parse one JS literal (object, array, string, number, bool, null,
    undefined) from `text` at `pos` -> (value, end). Identifiers other than
    the keywords become the marker `Expr(source)`."""
    p = _JsP(text, pos)
    v = p.value()
    return v, p.i


class Expr(str):
    """A source expression the literal parser could not evaluate."""


class _JsP:
    def __init__(self, text, i):
        self.t = text
        self.i = i

    def ws(self):
        t = self.t
        n = len(t)
        while self.i < n:
            c = t[self.i]
            if c.isspace():
                self.i += 1
            elif t.startswith("//", self.i):
                j = t.find("\n", self.i)
                self.i = n if j < 0 else j
            elif t.startswith("/*", self.i):
                j = t.find("*/", self.i + 2)
                self.i = n if j < 0 else j + 2
            else:
                break

    def value(self):
        """One value; a trailing binary operator chain is folded for + (strings
        and numbers) and otherwise kept whole as an Expr (raw source text)."""
        start = self.i
        v = self.primary()
        while True:
            save = self.i
            self.ws()
            t = self.t
            if self.i >= len(t) or t[self.i] in ",}])":
                self.i = save if self.i >= len(t) else self.i
                return v
            if t[self.i] == "+" and not isinstance(v, Expr):
                self.i += 1
                w = self.primary()
                if isinstance(w, Expr) or isinstance(v, (dict, list)) or isinstance(w, (dict, list)):
                    return self._raw(start)
                try:
                    v = v + w if isinstance(v, str) == isinstance(w, str) else str(v) + str(w)
                except TypeError:
                    return self._raw(start)
                continue
            # any other operator (ternary, arithmetic, comparison, call chain): take the whole expression
            return self._raw(start)

    def _raw(self, start):
        """The raw source of an expression from `start` to the next depth-0 , } ] )."""
        t = self.t
        i = start
        depth = 0
        n = len(t)
        mask = mask_source(t[start:])
        while i < n:
            c = mask[i - start]
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif c == "," and depth == 0:
                break
            i += 1
        self.i = i
        return Expr(t[start:i].strip())

    def primary(self):
        self.ws()
        t = self.t
        if self.i >= len(t):
            raise JsParseError("end of text")
        c = t[self.i]
        if c == "{":
            return self.obj()
        if c == "[":
            return self.arr()
        if c in "\"'":
            return self.string()
        if c == "(":
            self.i += 1
            v = self.value()
            self.ws()
            if self.i < len(t) and t[self.i] == ")":
                self.i += 1
            return v
        m = NUM_RE.match(t, self.i)
        if m and (c.isdigit() or c in "+-."):
            self.i = m.end()
            s = m.group(0)
            return int(s) if re.fullmatch(r"[-+]?\d+", s) else float(s)
        m = re.compile(r"[A-Za-z_$][A-Za-z0-9_$.]*").match(t, self.i)
        if m:
            w = m.group(0)
            self.i = m.end()
            if w == "true":
                return True
            if w == "false":
                return False
            if w in ("null", "undefined"):
                return None
            if self.i < len(t) and t[self.i] == "(":
                depth = 0
                j = self.i
                while j < len(t):
                    if t[j] == "(":
                        depth += 1
                    elif t[j] == ")":
                        depth -= 1
                        if depth == 0:
                            break
                    j += 1
                w = t[m.start():j + 1]
                self.i = j + 1
            return Expr(w)
        raise JsParseError("unexpected %r at %d" % (c, self.i))

    def string(self):
        t = self.t
        q = t[self.i]
        i = self.i + 1
        buf = []
        while i < len(t):
            c = t[i]
            if c == "\\":
                nxt = t[i + 1]
                if nxt == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", t[i + 2:i + 6]):
                    buf.append(chr(int(t[i + 2:i + 6], 16)))
                    i += 6
                    continue
                buf.append({"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "0": "\0"}.get(nxt, nxt))
                i += 2
                continue
            if c == q:
                self.i = i + 1
                return "".join(buf)
            buf.append(c)
            i += 1
        raise JsParseError("unterminated string")

    def key(self):
        self.ws()
        t = self.t
        if t[self.i] in "\"'":
            return self.string()
        m = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*|\d+").match(t, self.i)
        if not m:
            raise JsParseError("bad key at %d" % self.i)
        self.i = m.end()
        return m.group(0)

    def obj(self):
        self.i += 1
        out = {}
        while True:
            self.ws()
            if self.t[self.i] == "}":
                self.i += 1
                return out
            k = self.key()
            self.ws()
            if self.t[self.i] != ":":
                raise JsParseError("expected ':' at %d" % self.i)
            self.i += 1
            out[k] = self.value()
            self.ws()
            if self.t[self.i] == ",":
                self.i += 1

    def arr(self):
        self.i += 1
        out = []
        while True:
            self.ws()
            if self.t[self.i] == "]":
                self.i += 1
                return out
            out.append(self.value())
            self.ws()
            if self.t[self.i] == ",":
                self.i += 1
