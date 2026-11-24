"""MediaWiki api.php: what every wiki source shares.

formatversion=2 everywhere (real booleans, `pages` an array), maxlag=5 on every call with a wait-and-
retry when the servers report lag, continuation merged into one answer, and the three `action=parse`
shapes the module needs (a section's HTML, the section list, a section's wikitext).
"""
import html
import html.parser
import re
import urllib.parse

from . import env, http

MAXLAG = 5
MAXLAG_RETRIES = 3
MAX_PAGES = 60                       # continuation pages one query() may walk (Arch allpages needs 9)

_API = {
    "wiki.archlinux.org": "https://wiki.archlinux.org/api.php",
    "wiki.gentoo.org": "https://wiki.gentoo.org/api.php",
}
_PAGE_PREFIX = {"wiki.archlinux.org": "/title/"}     # every other host: /wiki/
_LIST_KEYS_DEDUPED = ("redirects", "normalized", "converted", "interwiki")


class MwError(Exception):
    """The API answered {"error": {...}}. `code` is MediaWiki's ("missingtitle", "maxlag", ...)."""

    def __init__(self, code, info, data=None):
        super().__init__(env.scrub(f"{code}: {info}"))
        self.code = code
        self.info = info
        self.data = data


def api_url(host):
    return _API.get(host) or f"https://{host}/w/api.php"


def page_url(host, title, fragment=None):
    """Canonical URL of a page: en.wikipedia.org/wiki/Title, wiki.archlinux.org/title/Title."""
    t = urllib.parse.quote(title.replace(" ", "_"), safe="/:()!*,;@~'&=+$")
    u = f"https://{host}{_PAGE_PREFIX.get(host, '/wiki/')}{t}"
    if fragment:
        u += "#" + urllib.parse.quote(fragment.replace(" ", "_"), safe="()!*,;:@~'&=+$")
    return u


def chunks(seq, n):
    """`seq` in lists of at most n. A lone string is one item, not its characters."""
    seq = [seq] if isinstance(seq, str) else list(seq)
    for i in range(0, len(seq), n):
        yield seq[i:i + n]


# ----------------------------------------------------------------------------- calls

def call(host, params, *, formatversion=2, maxlag=MAXLAG):
    """One api.php request. Adds format=json, formatversion, maxlag; raises MwError on an error object.
    A maxlag error waits (5, 10, 15 s) and asks again, MAXLAG_RETRIES times."""
    p = {"format": "json"}
    if formatversion is not None:
        p["formatversion"] = formatversion
    if maxlag is not None:
        p["maxlag"] = maxlag
    p.update(params)
    url = api_url(host)
    for attempt in range(MAXLAG_RETRIES + 1):
        data = http.get(url, params=p)
        err = data.get("error") if isinstance(data, dict) else None
        if not err:
            return data
        code = err.get("code", "unknown")
        if code == "maxlag" and attempt < MAXLAG_RETRIES:
            http._sleep(5 * (attempt + 1))
            continue
        raise MwError(code, err.get("info", ""), data)
    raise AssertionError("unreachable")


def _merge_list(dst, key, items):
    cur = dst.setdefault(key, [])
    if key in _LIST_KEYS_DEDUPED:
        cur.extend(i for i in items if i not in cur)
    else:
        cur.extend(items)


def _merge_page(dst, src):
    for k, v in src.items():
        if isinstance(v, list) and isinstance(dst.get(k), list):
            dst[k].extend(v)
        elif isinstance(v, dict) and isinstance(dst.get(k), dict):
            dst[k].update(v)
        else:
            dst[k] = v


def _merge_query(dst, src):
    for k, v in src.items():
        if k == "pages" and isinstance(v, list):
            by = {(p.get("pageid"), p.get("title")): p for p in dst.setdefault("pages", [])}
            for p in v:
                cur = by.get((p.get("pageid"), p.get("title")))
                if cur is None:
                    dst["pages"].append(p)
                    by[(p.get("pageid"), p.get("title"))] = p
                else:
                    _merge_page(cur, p)
        elif isinstance(v, list):
            _merge_list(dst, k, v)
        elif isinstance(v, dict):
            dst.setdefault(k, {}).update(v)
        else:
            dst[k] = v


def query(host, params, continue_all=False, *, max_pages=MAX_PAGES, formatversion=2):
    """action=query (or another `action` in params). With continue_all the `continue` object is fed back
    until the answer is complete and the pieces are merged: lists are concatenated (allpages, search),
    `pages` are merged by page (a prop that continues adds to the same page), dicts are updated."""
    p = dict(params)
    p.setdefault("action", "query")
    data = call(host, p, formatversion=formatversion)
    if not continue_all:
        return data
    acc = {}
    seen = set()
    for _ in range(max_pages):
        for k, v in data.items():
            if k == "query":
                _merge_query(acc.setdefault("query", {}), v)
            elif k not in ("continue", "batchcomplete"):
                acc[k] = v
        cont = data.get("continue")
        if not cont:
            acc["batchcomplete"] = True
            return acc
        token = tuple(sorted((k, str(v)) for k, v in cont.items()))
        if token in seen:
            raise MwError("continue-loop", f"the same continuation twice: {cont}", data)
        seen.add(token)
        p.update(cont)
        data = call(host, p, formatversion=formatversion)
    raise MwError("continue-limit", f"more than {max_pages} continuation pages", acc)


def title_map(query_obj, requested):
    """requested title -> canonical title, through `normalized` then `redirects`."""
    norm = {n["from"]: n["to"] for n in query_obj.get("normalized", [])}
    redir = {r["from"]: r["to"] for r in query_obj.get("redirects", [])}
    out = {}
    for t in requested:
        c = norm.get(t, t)
        out[t] = redir.get(c, c)
    return out


def parse_section(host, title, section=0):
    """A section's rendered HTML (0 = the lead), following redirects.

    -> {title (canonical: the redirect's target), pageid, revid, displaytitle (an HTML span),
        html, redirects, host, url}. A missing page raises MwError("missingtitle")."""
    data = call(host, {
        "action": "parse", "page": title, "prop": "text|revid|displaytitle", "section": section,
        "disableeditsection": 1, "disabletoc": 1, "disablelimitreport": 1, "redirects": 1})
    p = data["parse"]
    return {
        "title": p["title"], "pageid": p.get("pageid"), "revid": p.get("revid"),
        "displaytitle": p.get("displaytitle"), "html": p["text"], "redirects": p.get("redirects") or [],
        "host": host, "url": page_url(host, p["title"]),
    }


def sections(host, title):
    """The page's section list: [{index (str, what `section=` takes), level, toclevel, number, line (the
    heading's HTML), title (plain), anchor, byteoffset}]."""
    data = call(host, {"action": "parse", "page": title, "prop": "sections", "redirects": 1})
    out = []
    for s in data["parse"].get("sections", []):
        out.append({
            "index": str(s.get("index", "")), "level": int(s.get("level", 0) or 0),
            "toclevel": int(s.get("toclevel", 0) or 0), "number": s.get("number", ""),
            "line": s.get("line", ""), "title": strip_html(s.get("line", "")),
            "anchor": s.get("anchor", ""), "byteoffset": s.get("byteoffset"),
        })
    return out


def wikitext_section(host, title, section):
    """The wikitext of one section (`{{Pkg|zsh}}` and all)."""
    data = call(host, {"action": "parse", "page": title, "section": section, "prop": "wikitext",
                       "redirects": 1})
    return data["parse"].get("wikitext", "")


# ----------------------------------------------------------------------------- small HTML -> text

_BLOCK = {"br", "p", "div", "li", "tr", "td", "th", "dd", "dt", "table", "ul", "ol", "h1", "h2", "h3", "h4"}


class _Text(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("style", "script"):
            self._skip += 1
        elif tag in _BLOCK:
            self.out.append(" ")

    def handle_endtag(self, tag):
        if tag in ("style", "script"):
            self._skip = max(0, self._skip - 1)
        elif tag in _BLOCK:
            self.out.append(" ")

    def handle_data(self, data):
        if not self._skip:
            self.out.append(data)


def strip_html(s):
    """Plain text of a small HTML fragment (a Commons artist or description): tags dropped, entities
    decoded, block boundaries become spaces, whitespace collapsed. Not for article bodies (htmltext)."""
    if not s:
        return ""
    if "<" not in s and "&" not in s:
        return re.sub(r"\s+", " ", s).strip()
    p = _Text()
    p.feed(s)
    p.close()
    return re.sub(r"\s+", " ", html.unescape("".join(p.out)).replace("\xa0", " ")).strip()
