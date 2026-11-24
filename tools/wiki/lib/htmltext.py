"""HTML -> paragraphs with link offsets, for the wiki module (Python stdlib only).

    paragraphs(html, wiki, base_url) -> [{"text", "links", "kind", "section", "stripped"}]

`wiki` is wikipedia | arch | gentoo | kernel | freedesktop. `kind` is p | dd | li | pre | heading.
`links` are {"s", "e", "target", "url", "wiki"} with s/e counted in UTF-16 code units (JS string
indices, CONTRACT.md); `target` is the article title the link points to (percent-decoded, underscores
as spaces, "#Fragment" kept), `wiki` the wiki the target lives on. A link to anything that is not one
of the five wikis (Wiktionary, a project's home page), an in-page anchor, a red link or a page in a
non-article namespace keeps its TEXT and loses the link.

`stripped` (an addition to the fixed shape) lists the closed-set codes of CONTRACT.md that the HTML
stage removed from the paragraph or from just above it: `hatnote` (a hatnote / dablink block dropped
before this paragraph), `citations` (`sup.reference` numbered [3], `[citation needed]`), `notes`
(lettered footnote markers [a], [n 1]), `pronunciation` (a "listen" audio link), `coordinates`
(a `.geo` span). cleanup.clean() adds its own and reports the union. A bare external link whose text is
"[1]" (`a.external.autonumber`) is replaced by its HOST NAME as plain text ("See [1] or zoxide(1)" reads
"See github.com or zoxide(1)": the number says nothing, the host says where it goes) and nothing is reported,
because nothing was removed; one whose href has no host is dropped and reported as `notes`.

What is dropped, by wiki (all of it in the class tables below):
    every wiki   style/script/tables/figures/forms/nav, `display:none`, `.noprint`, `.mw-empty-elt`,
                 `a.headerlink` (the "¶" after a Sphinx heading),
                 `.shortdescription`, `sup.reference`, `.mw-editsection`, hatnotes, infobox/navbox/
                 sidebar/ambox boxes, thumbs and captions, coordinates, reference lists, `.toc`
    arch         `archwiki-template-box*` (Note/Warning/Tip), `-meta*` (Related articles), `-message*`,
                 `-navigation*` (the "Documents - Internet - ..." bar); the file-name caption of a code box
                 is merged into the code paragraph ("~/.zshrc:" on its first line)
    gentoo       Translate's language bar (`mw-pt-*`), `div.alert`/`.gw-box` boxes, `#infobox-stack`,
                 the literal `<translate>` / `<!--T:1-->` / `<languages />` markup left in the text
    kernel       everything outside `div.body[role=main]`, `.language-selection`, `dl.field-list`
                 (Date/Author), admonitions, a subtitle line under the h1 that only introduces
                 sub-sections, header links, toctrees
    freedesktop  everything outside `#_content`, `.authorgroup`, `.date`, `.copyright`, `.toc`,
                 `.permalink`, `.doc-status` (File Name / ID), `dl.field-list` (Release / Date / Authors),
                 heading numbers

Offsets are UTF-16 code units at the boundary; inside this module and cleanup.py text is a Python
str (code points) and `LinkedText` keeps the links consistent through every edit.
"""
from __future__ import annotations

import bisect
import re
import urllib.parse
from html.parser import HTMLParser

WIKIS = ("wikipedia", "arch", "gentoo", "kernel", "freedesktop")

# The closed set of `intro.stripped` codes (CONTRACT.md), in the order they are reported.
CODES = ("pronunciation", "ipa", "native_names", "dates", "coordinates", "citations",
         "hatnote", "parentheticals", "notes")


# --------------------------------------------------------------------------------------------
# UTF-16 <-> code point offsets
# --------------------------------------------------------------------------------------------

def u16len(text: str) -> int:
    return len(text.encode("utf-16-le", "surrogatepass")) // 2


def _astral(text: str) -> list[int]:
    """Code-point indices of characters beyond the BMP (two UTF-16 units each)."""
    return [i for i, ch in enumerate(text) if ord(ch) > 0xFFFF]


def cp_to_u16(text: str, i: int) -> int:
    """UTF-16 offset of code-point index `i` in `text`."""
    if text.isascii():
        return i
    return i + bisect.bisect_left(_astral(text), i)


def u16_to_cp(text: str, j: int) -> int:
    """Code-point index of UTF-16 offset `j` in `text`."""
    if text.isascii():
        return j
    adj = [a + k for k, a in enumerate(_astral(text))]      # UTF-16 offset of the k-th astral char
    return j - bisect.bisect_left(adj, j)


def links_to_u16(text: str, links: list[dict]) -> list[dict]:
    """Copies of `links` (code-point s/e) with s/e in UTF-16 units."""
    if text.isascii():
        return [dict(l) for l in links]
    astral = _astral(text)
    out = []
    for l in links:
        m = dict(l)
        m["s"] = l["s"] + bisect.bisect_left(astral, l["s"])
        m["e"] = l["e"] + bisect.bisect_left(astral, l["e"])
        out.append(m)
    return out


def links_from_u16(text: str, links: list[dict]) -> list[dict]:
    """Copies of `links` (UTF-16 s/e) with s/e as code-point indices."""
    if text.isascii():
        return [dict(l) for l in links]
    adj = [a + k for k, a in enumerate(_astral(text))]
    out = []
    for l in links:
        m = dict(l)
        m["s"] = l["s"] - bisect.bisect_left(adj, l["s"])
        m["e"] = l["e"] - bisect.bisect_left(adj, l["e"])
        out.append(m)
    return out


# --------------------------------------------------------------------------------------------
# Text that carries links through edits
# --------------------------------------------------------------------------------------------

_INVISIBLE = re.compile("[\u200b\ufeff\u200e\u200f\u2060\u00ad\u202a-\u202e\u2066-\u2069]")
_WS_RUN = re.compile(r"\s+")
_TRIM_SET = " \t\r\n\u00a0\u200b\ufeff\u200e\u200f\u2060\u00ad"


class LinkedText:
    """A str plus links {"s", "e", ...} in code points. `cut` is the only mutation: it keeps every
    link on the same characters (shifted), shrinks one that contains the cut, and drops one the cut
    removes or straddles."""

    def __init__(self, text: str, links: list[dict]):
        self.text = text
        self.links = links

    def cut(self, a: int, b: int, repl: str = "") -> None:
        if a == b and not repl:
            return
        d = len(repl) - (b - a)
        kept = []
        for l in self.links:
            s, e = l["s"], l["e"]
            if e <= a:
                kept.append(l)
            elif s >= b:
                l["s"] = s + d; l["e"] = e + d
                kept.append(l)
            elif s <= a and b <= e and not (s == a and e == b):
                l["e"] = e + d
                kept.append(l)
            # else: the cut removes the link, or cuts through its edge
        self.text = self.text[:a] + repl + self.text[b:]
        self.links = kept

    def sub(self, pattern: "re.Pattern", repl="") -> bool:
        """Replace every match (right to left, so offsets stay valid). `repl` is a str or a
        function of the match. True if anything changed."""
        changed = False
        for m in reversed(list(pattern.finditer(self.text))):
            r = repl(m) if callable(repl) else m.expand(repl)
            if r != m.group(0):
                self.cut(m.start(), m.end(), r)
                changed = True
        return changed

    def trim_links(self) -> None:
        """Pull every link's edges in over whitespace; drop the ones with no text left."""
        kept = []
        for l in self.links:
            s, e = l["s"], l["e"]
            while s < e and self.text[s] in _TRIM_SET:
                s += 1
            while e > s and self.text[e - 1] in _TRIM_SET:
                e -= 1
            if e > s:
                l["s"], l["e"] = s, e
                kept.append(l)
        self.links = kept

    def merge_adjacent(self) -> None:
        """Two links that touch and point at the same URL are one (an anchor split by markup)."""
        out = []
        for l in sorted(self.links, key=lambda x: (x["s"], x["e"])):
            if out and out[-1]["e"] == l["s"] and out[-1]["url"] == l["url"]:
                out[-1]["e"] = l["e"]
            else:
                out.append(l)
        self.links = out

    def normalize_ws(self) -> bool:
        """Delete invisible characters, collapse whitespace runs to one space, trim both ends.
        True if the text changed."""
        before = self.text
        self.trim_links()
        self.sub(_INVISIBLE, "")
        self.trim_links()
        self.sub(_WS_RUN, lambda m: m.group(0) if m.group(0) == " " else " ")
        n = len(self.text) - len(self.text.lstrip(" "))
        if n:
            self.cut(0, n)
        m = len(self.text) - len(self.text.rstrip(" "))
        if m:
            self.cut(len(self.text) - m, len(self.text))
        self.trim_links()
        return self.text != before


# --------------------------------------------------------------------------------------------
# Tree
# --------------------------------------------------------------------------------------------

_VOID = frozenset("area base br col embed hr img input link meta param source track wbr".split())
_PHRASING = frozenset(
    "a abbr b bdi bdo big cite code data dfn em font i kbd label mark q s samp small span strike "
    "strong sub sup time tt u var".split())
_P_CLOSERS = frozenset(
    "address article aside blockquote center details dir div dl fieldset figcaption figure footer "
    "form h1 h2 h3 h4 h5 h6 header hgroup hr main menu nav ol p pre section table ul".split())
_HEADINGS = frozenset("h1 h2 h3 h4 h5 h6".split())
_BLOCK = _P_CLOSERS | frozenset(
    "li dd dt tr td th tbody thead tfoot caption summary body html".split())


_MAX_DEPTH = 200          # a page that never closes its tags must not blow the recursion limit


class _Node:
    __slots__ = ("tag", "attrs", "kids", "cls", "skip", "caption")

    def __init__(self, tag: str, attrs: dict):
        self.tag = tag
        self.attrs = attrs
        self.kids: list = []
        self.cls = frozenset((attrs.get("class") or "").split())
        self.skip = False
        self.caption = ""                            # a code box's file-name caption, merged into this pre


class _TreeBuilder(HTMLParser):
    """A forgiving tree: end tags that were never opened are ignored, an end tag closes everything
    open above its own element, and p / li / dt / dd / td close themselves the way HTML says."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root = _Node("#root", {})
        self.stack = [self.root]

    def handle_starttag(self, tag, attrs):
        self._start(tag, attrs, False)

    def handle_startendtag(self, tag, attrs):
        self._start(tag, attrs, True)

    def handle_endtag(self, tag):
        if tag in _VOID:
            return
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                del self.stack[i:]
                return

    def handle_data(self, data):
        kids = self.stack[-1].kids
        if kids and isinstance(kids[-1], str):
            kids[-1] += data
        else:
            kids.append(data)

    def _start(self, tag, attrs, selfclose):
        self._implied(tag)
        node = _Node(tag, {k: (v or "") for k, v in reversed(attrs)})
        self.stack[-1].kids.append(node)
        if tag not in _VOID and not selfclose and len(self.stack) < _MAX_DEPTH:
            self.stack.append(node)

    def _implied(self, tag):
        if tag in _P_CLOSERS:
            for i in range(len(self.stack) - 1, 0, -1):
                t = self.stack[i].tag
                if t == "p":
                    del self.stack[i:]
                    break
                if t not in _PHRASING:
                    break
        if tag == "li":
            self._close_until({"li"}, {"ul", "ol", "menu"})
        elif tag in ("dd", "dt"):
            self._close_until({"dd", "dt"}, {"dl"})
        elif tag in ("td", "th"):
            self._close_until({"td", "th"}, {"tr", "table"})
        elif tag == "tr":
            self._close_until({"tr"}, {"table"})
        elif tag in ("thead", "tbody", "tfoot"):
            self._close_until({"thead", "tbody", "tfoot"}, {"table"})

    def _close_until(self, targets, stop):
        for i in range(len(self.stack) - 1, 0, -1):
            t = self.stack[i].tag
            if t in targets:
                del self.stack[i:]
                return
            if t in stop:
                return


def _parse(html: str) -> _Node:
    tb = _TreeBuilder()
    tb.feed(html)
    tb.close()
    return tb.root


def _find(node: _Node, pred):
    for k in node.kids:
        if isinstance(k, str):
            continue
        if pred(k):
            return k
        r = _find(k, pred)
        if r is not None:
            return r
    return None


# --------------------------------------------------------------------------------------------
# What is dropped
# --------------------------------------------------------------------------------------------

_DROP_TAGS = frozenset(
    "style script noscript template head title svg canvas iframe object embed audio video form "
    "button select textarea input nav header footer aside figure figcaption table caption link "
    "meta base map area".split())

# hatnote / disambiguation notes: dropped, and reported as `hatnote` on the paragraph below them
_HATNOTE_CLASSES = frozenset({"hatnote", "dablink", "rellink"})

_DROP_CLASSES = frozenset("""
mw-editsection mw-editsection-like mw-editsection-bracket shortdescription noprint mw-empty-elt
infobox navbox navbox-styles vertical-navbox sidebar metadata ambox tmbox ombox cmbox fmbox imbox
mbox-small side-box sistersitebox thumb thumbinner thumbcaption tright tleft gallery gallerybox
mw-hidden-cats toc mw-toc mw-jump-link printonly navigation-not-searchable mw-ext-cite-error error
mw-references-wrap references reflist refbegin mw-cite-backlink reference-text Z3988 flagicon
sr-only preview-warning mw-message-box warningbox errorbox successbox headerlink
""".split())

_DROP_CLASS_PREFIXES = ("infobox", "navbox", "geo-", "mw-gallery")

_WIKI_DROP_CLASSES = {
    "wikipedia": frozenset(),
    "arch": frozenset(),
    "gentoo": frozenset({"alert", "gw-box", "list-group", "list-group-item", "fa"}),
    "kernel": frozenset("""
        language-selection admonition admonition-title toctree-wrapper contents topic
        sphinxsidebar related footer versionmodified field-list rubric kerneltoc
        kernel-toc-contents footnote footnote-list""".split()),
    "freedesktop": frozenset("""
        authorgroup author-info date copyright toc-abstract permalink crumbs bubble bubble-container
        clearme buttons bypass-block imprint-label number doc-status field-list""".split()),
}
_WIKI_DROP_PREFIXES = {
    "arch": ("archwiki-template-box", "archwiki-template-meta", "archwiki-template-message",
             "archwiki-template-navigation"),
    "gentoo": ("mw-pt-",),
}
_DROP_IDS = frozenset({
    "coordinates", "toc", "infobox-stack", "catlinks", "siteSub", "contentSub", "jump-to-nav",
    "mw-navigation", "footer", "_header", "_fixed-header-wrap", "_toolbar-wrap", "_bottom-navigation",
    "_footer-wrap", "_toc-bubble-wrap", "_logo"})
_DROP_ROLES = frozenset({"navigation", "complementary", "banner", "contentinfo", "search", "dialog"})
_DISPLAY_NONE = re.compile(r"display\s*:\s*none", re.I)


# --------------------------------------------------------------------------------------------
# Links
# --------------------------------------------------------------------------------------------

_HOSTS = {
    "en.wikipedia.org": "wikipedia",
    "wiki.archlinux.org": "arch",
    "wiki.gentoo.org": "gentoo",
    "docs.kernel.org": "kernel",
    "specifications.freedesktop.org": "freedesktop",
}
_DEFAULT_BASE = {
    "wikipedia": "https://en.wikipedia.org/",
    "arch": "https://wiki.archlinux.org/",
    "gentoo": "https://wiki.gentoo.org/",
    "kernel": "https://docs.kernel.org/",
    "freedesktop": "https://specifications.freedesktop.org/",
}
_PATH_PREFIX = {"wikipedia": "/wiki/", "arch": "/title/", "gentoo": "/wiki/"}
# Non-article namespaces (a followed link must be an article). First letter case-insensitive.
_NAMESPACES = {
    "wikipedia": {"help", "category", "file", "image", "special", "template", "talk", "user",
                  "user talk", "wikipedia", "wp", "portal", "draft", "module", "mediawiki", "media",
                  "book", "timedtext", "wikt", "wiktionary"},
    "arch": {"help", "category", "file", "special", "template", "talk", "user", "archwiki",
             "mediawiki"},
    "gentoo": {"help", "category", "file", "special", "template", "talk", "user", "project",
               "mediawiki", "gentoo wiki"},
    "kernel": set(),
    "freedesktop": set(),
}


def _title_from(path: str, wiki: str, query: str) -> str | None:
    """The page title in a URL of `wiki`, or None if the URL is not a page view."""
    if wiki in _PATH_PREFIX:
        prefix = _PATH_PREFIX[wiki]
        if path.startswith(prefix):
            return path[len(prefix):]
        if path.endswith("/index.php") or path == "/index.php":
            q = urllib.parse.parse_qs(query)
            if "redlink" in q or "action" in q:
                return None
            t = q.get("title")
            return t[0] if t else None
        return None
    p = path.strip("/")
    if wiki == "kernel" and p.endswith(".html"):
        p = p[:-5]
    return p or None


def resolve_link(href: str, cls: frozenset, wiki: str, base_url: str) -> dict | None:
    """{"target", "url", "wiki"} for an anchor that is an article link of one of the five wikis,
    else None (red link, in-page anchor, external site, other namespace)."""
    if not href or "new" in cls:
        return None
    base = base_url or _DEFAULT_BASE[wiki]
    url = urllib.parse.urljoin(base, href.strip())
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https"):
        return None
    target_wiki = _HOSTS.get((u.hostname or "").lower())
    if target_wiki is None:
        return None
    raw = _title_from(u.path, target_wiki, u.query)
    if not raw:
        return None
    title = urllib.parse.unquote(raw).replace("_", " ").strip()
    frag = urllib.parse.unquote(u.fragment).replace("_", " ").strip()
    if not title:
        return None
    ns = title.split(":", 1)[0].strip().lower() if ":" in title else ""
    if ns and ns in _NAMESPACES.get(target_wiki, ()):
        return None
    bu = urllib.parse.urlsplit(base)
    if frag and (bu.hostname or "").lower() == (u.hostname or "").lower():
        btitle = _title_from(bu.path, target_wiki, bu.query)
        if btitle is not None and urllib.parse.unquote(btitle).replace("_", " ").strip() == title:
            return None                              # a link to a section of this very page
    return {"target": title + ("#" + frag if frag else ""), "url": url, "wiki": target_wiki}


# --------------------------------------------------------------------------------------------
# Extraction
# --------------------------------------------------------------------------------------------

_SUP = str.maketrans("0123456789+-\u2212=()", "\u2070\u00b9\u00b2\u00b3\u2074\u2075\u2076\u2077\u2078\u2079\u207a\u207b\u207b\u207c\u207d\u207e")
_SUB = str.maketrans("0123456789+-\u2212=()", "\u2080\u2081\u2082\u2083\u2084\u2085\u2086\u2087\u2088\u2089\u208a\u208b\u208b\u208c\u208d\u208e")
_NUMERIC_MARK = re.compile(r"\d+(?:\s*[\u2013,\-]\s*\d+)*")
_MARKUP = re.compile(r"</?translate>|<!--T:\d+-->|<languages\s*/>")
_KIND_OF = {"li": "li", "dt": "li", "dd": "dd", "pre": "pre", "blockquote": "p",
            **{h: "heading" for h in _HEADINGS}}


class _Extractor:
    def __init__(self, wiki: str, base_url: str):
        self.wiki = wiki
        self.base = base_url
        self.out: list[dict] = []
        self.parts: list[str] = []
        self.n = 0
        self.links: list[dict] = []
        self.open: list[list] = []          # [info, start] for every anchor around the cursor
        self.section = ""
        self.inline_codes: set[str] = set()
        self.block_codes: set[str] = set()
        self.drop_classes = _DROP_CLASSES | _WIKI_DROP_CLASSES.get(wiki, frozenset())
        self.drop_prefixes = _DROP_CLASS_PREFIXES + _WIKI_DROP_PREFIXES.get(wiki, ())

    # -- what to drop -------------------------------------------------------------------------
    def _drop(self, el: _Node):
        """None to keep `el`; else (code | None, is_block)."""
        if el.skip:
            return (None, True)
        tag, cls, at = el.tag, el.cls, el.attrs
        block = tag in _BLOCK
        if cls & _HATNOTE_CLASSES:
            return ("hatnote", True)
        if tag == "sup" and ("reference" in cls or "mw-ref" in cls):
            mark = re.sub(r"[\[\]\s]", "", self._plain(el))
            return ("citations" if _NUMERIC_MARK.fullmatch(mark) else "notes", False)
        if "mw-ref" in cls:
            return ("notes", False)
        if tag == "sup" and "Inline-Template" in cls:
            return ("citations", False)
        if "haudio" in cls:
            return ("pronunciation", False)
        if self._is_autonumber(el) and self._bare_host(el) is None:
            return ("notes", False)                  # a bare external link rendered "[1]" that names no host
        if el.attrs.get("id") == "coordinates" or "geo" in cls or any(c.startswith("geo-") for c in cls):
            return ("coordinates", block)
        if tag in _DROP_TAGS or "hidden" in at or _DISPLAY_NONE.search(at.get("style", "")):
            return (None, block)
        if cls & self.drop_classes or any(c.startswith(self.drop_prefixes) for c in cls):
            return (None, block)
        if at.get("id") in _DROP_IDS or at.get("role") in _DROP_ROLES:
            return (None, block)
        return None

    def _plain(self, el: _Node) -> str:
        """The text of `el` with the same drops applied, no links, no structure."""
        out = []
        for k in el.kids:
            if isinstance(k, str):
                out.append(k)
            elif k.tag == "br":
                out.append(" ")
            elif self._drop(k) is None:
                out.append(self._plain(k))
        return "".join(out)

    @staticmethod
    def _is_autonumber_text(text: str) -> bool:
        return re.fullmatch(r"\[\d+\]", text.strip()) is not None

    def _is_autonumber(self, el: _Node) -> bool:
        """A bare external link the page shows as its running number: `<a class="external autonumber">[1]</a>`."""
        return el.tag == "a" and "autonumber" in el.cls and self._is_autonumber_text(self._plain(el))

    @staticmethod
    def _bare_host(el: _Node) -> str | None:
        """The host name of an anchor's href, lower-cased, without a leading "www." ("github.com"); None when it has
        none (a mailto:, a relative path)."""
        try:
            host = urllib.parse.urlsplit(el.attrs.get("href", "").strip()).hostname or ""
        except ValueError:
            return None
        return re.sub(r"^www\.", "", host.lower()) or None

    # -- buffer -------------------------------------------------------------------------------
    def _text(self, s: str) -> None:
        if s:
            self.parts.append(s)
            self.n += len(s)

    def _flush(self, kind: str) -> None:
        """Emit the buffered text as one paragraph of `kind` (or nothing, if it is empty)."""
        text = "".join(self.parts)
        for entry in self.open:                      # an anchor that spans the boundary is cut in two
            if self.n > entry[1]:
                self.links.append({"info": entry[0], "s": entry[1], "e": self.n})
            entry[1] = 0
        links = [{"s": l["s"], "e": l["e"], **l["info"]} for l in self.links]
        self.parts, self.n, self.links = [], 0, []
        if kind == "pre":
            body = text.strip("\n").rstrip()
            if not body.strip():
                self.inline_codes.clear()
                return
            self._emit(body, [], "pre")
            return
        lt = LinkedText(text, links)
        if "<" in text and self.wiki in ("gentoo", "arch", "wikipedia"):
            lt.sub(_MARKUP, "")
        lt.normalize_ws()
        lt.merge_adjacent()
        if not any(ch.isalnum() for ch in lt.text):
            self.inline_codes.clear()
            return
        if kind == "heading":
            self.section = lt.text
        self._emit(lt.text, links_to_u16(lt.text, lt.links), kind)

    def _emit(self, text: str, links: list[dict], kind: str) -> None:
        codes = self.block_codes | self.inline_codes
        self.block_codes, self.inline_codes = set(), set()
        self.out.append({"text": text, "links": links, "kind": kind, "section": self.section,
                         "stripped": [c for c in CODES if c in codes]})

    # -- walk ---------------------------------------------------------------------------------
    def walk(self, node: _Node, kind: str) -> None:
        for k in node.kids:
            if isinstance(k, str):
                self._text(k)
            else:
                self._element(k, kind)

    def _element(self, el: _Node, kind: str) -> None:
        drop = self._drop(el)
        if drop is not None:
            code, block = drop
            if code:
                (self.block_codes if block else self.inline_codes).add(code)
            return
        tag = el.tag
        if tag == "br":
            self._text("\n" if kind == "pre" else " ")
        elif tag in ("wbr", "img"):
            pass
        elif self._is_autonumber(el):                # (a host-less one was dropped above)
            prev = self.parts[-1][-1] if self.parts else ""
            self._text(("" if not prev or prev.isspace() or prev in "([{\"'\u201c\u2018/" else " ") + self._bare_host(el))
        elif tag == "a":
            self._anchor(el, kind)
        elif tag in ("sup", "sub"):
            self._supsub(el, kind)
        elif "mwe-math-element" in el.cls or tag == "math":
            self._text(self._math(el))
        elif tag in _BLOCK:
            self._flush(kind)
            inner = _KIND_OF.get(tag, kind)
            if tag == "pre" and el.caption:
                self._text(el.caption + ":\n")
            self.walk(el, inner)
            self._flush(inner)
        else:
            self.walk(el, kind)

    def _anchor(self, el: _Node, kind: str) -> None:
        info = None if kind == "pre" else resolve_link(
            el.attrs.get("href", ""), el.cls, self.wiki, self.base)
        if info is None:
            self.walk(el, kind)
            return
        entry = [info, self.n]
        self.open.append(entry)
        self.walk(el, kind)
        self.open.remove(entry)
        if self.n > entry[1]:
            self.links.append({"info": info, "s": entry[1], "e": self.n})

    def _supsub(self, el: _Node, kind: str) -> None:
        raw = self._plain(el).strip()
        if el.tag == "sup" and self.wiki == "arch" and raw == "AUR":
            self._text(" (AUR)")                     # {{AUR|pkg}}: the marker is a superscript
        elif raw and re.fullmatch(r"[0-9+\-\u2212]+", raw):
            self._text(raw.translate(_SUP if el.tag == "sup" else _SUB))
        else:
            self.walk(el, kind)

    def _math(self, el: _Node) -> str:
        m = el if el.tag == "math" else _find(el, lambda n: n.tag == "math")
        if m is not None:
            t = _mathml(m).strip()
            if t:
                return t
        img = _find(el, lambda n: n.tag == "img")
        alt = (img.attrs.get("alt", "") if img else "")
        return re.sub(r"^\{\\displaystyle\s*|\}$", "", alt).strip()


def _mathml(n) -> str:
    """A plain-text reading of MathML: enough for "e^iπ + 1 = 0" and "x²", not typesetting."""
    if isinstance(n, str):
        return n.strip()
    t = n.tag
    kids = [k for k in n.kids if not isinstance(k, str)]
    if t in ("annotation", "annotation-xml", "mphantom"):
        return ""
    if t == "semantics":
        return _mathml(kids[0]) if kids else ""
    if t in ("mi", "mn", "mo", "mtext", "ms"):
        return "".join(k if isinstance(k, str) else _mathml(k) for k in n.kids).strip()
    if t in ("msup", "msub") and len(kids) >= 2:
        base, arg = _mathml(kids[0]), _mathml(kids[1])
        table = _SUP if t == "msup" else _SUB
        if re.fullmatch(r"[0-9+\-\u2212]+", arg):
            return base + arg.translate(table)
        return base + ("^" if t == "msup" else "_") + (arg if len(arg) == 1 else "(" + arg + ")")
    if t == "mfrac" and len(kids) >= 2:
        a, b = _mathml(kids[0]), _mathml(kids[1])
        return (a if len(a) == 1 else "(" + a + ")") + "/" + (b if len(b) == 1 else "(" + b + ")")
    if t == "msqrt":
        return "\u221a(" + "".join(_mathml(k) for k in kids) + ")"
    if t == "mspace":
        return " "
    return "".join(_mathml(k) for k in kids)


def _mark_subtitles(node: _Node, ex: _Extractor) -> None:
    """Kernel docs: a short line right under the h1 whose next sibling is a sub-section is a
    subtitle ("Documentation for sysrq.c"), not the intro. It is dropped."""
    els = [k for k in node.kids if isinstance(k, _Node)]
    if node.tag == "section":
        for i, k in enumerate(els):
            if k.tag in _HEADINGS:
                if i + 1 < len(els) and els[i + 1].tag == "p" and (
                        i + 2 >= len(els) or els[i + 2].tag == "section"):
                    text = re.sub(r"\s+", " ", ex._plain(els[i + 1])).strip()
                    if text and len(text.split()) <= 8 and not re.search(r"[.!?:]$", text):
                        els[i + 1].skip = True
                break
    for k in els:
        _mark_subtitles(k, ex)


_CAPTION_STYLE = re.compile(r"margin-bottom\s*:\s*0[^;]*;\s*border-bottom\s*:\s*none", re.I)
_CODE_STYLE = re.compile(r"border-top-style\s*:\s*dashed", re.I)


def _mark_code_captions(node: _Node, ex: _Extractor) -> None:
    """An Arch code box is two <pre>s: the file-name caption (no bottom margin or border) and the code
    (dashed top border). The caption is merged into the code's paragraph as its first line, so one
    code box is one paragraph."""
    els = [k for k in node.kids if isinstance(k, _Node)]
    for a, b in zip(els, els[1:]):
        if (a.tag == "pre" and b.tag == "pre" and _CAPTION_STYLE.search(a.attrs.get("style", ""))
                and _CODE_STYLE.search(b.attrs.get("style", ""))):
            caption = re.sub(r"\s+", " ", ex._plain(a)).strip()
            if caption:
                a.skip = True
                b.caption = caption
    for k in els:
        _mark_code_captions(k, ex)


def paragraphs(html: str, wiki: str, base_url: str = "") -> list[dict]:
    """Extract the prose of `html` (an `action=parse` fragment, or a whole page for kernel and
    freedesktop) as an ordered list of paragraphs; see the module docstring."""
    if wiki not in WIKIS:
        raise ValueError("unknown wiki %r" % (wiki,))
    tree = _parse(html)
    root = tree
    if wiki == "kernel":
        root = (_find(tree, lambda n: n.attrs.get("role") == "main")
                or _find(tree, lambda n: "body" in n.cls) or tree)
    elif wiki == "freedesktop":
        root = _find(tree, lambda n: n.attrs.get("id") == "_content") or tree
    ex = _Extractor(wiki, base_url)
    if wiki == "kernel":
        _mark_subtitles(root, ex)
    _mark_code_captions(root, ex)
    ex.walk(root, "p")
    ex._flush("p")
    return ex.out
