"""docs.kernel.org (Sphinx): which documents are worth a card, and their HTML.

The site has no page list, only `searchindex.js` (about 20 MB, `Search.setIndex({...})`), which holds
`docnames` and their first `titles`: 4074 documents, 3504 without the translations. Only the parsed
list is kept (200 KB, refreshed monthly under `$XDG_CACHE_HOME/lares/wiki/kernel_docs.json`).

Which of them are candidates is curation, not enumeration, and lives in tools/wiki/data/static_pages.json
(kernel.*, with the reason beside each subtree): most of the tree is per-driver reference. Weight is the
relative share of a picked page; a table-of-contents page (`.../index`) is never a candidate.
"""
import json
import re
import time

from .. import atomic, http, mw, paths

BASE = "https://docs.kernel.org"
INDEX_URL = BASE + "/searchindex.js"
CACHE_VERSION = 1
_NUMBER = re.compile(r'<span class="section-number">.*?</span>')     # "6. " in front of a title


def parse_searchindex(text):
    """The text of searchindex.js -> [{"d": docname, "t": title}], translations dropped, HTML out of
    the titles."""
    start = text.index("(") + 1
    end = text.rindex(")")
    obj = json.loads(text[start:end])
    out = []
    for d, t in zip(obj["docnames"], obj.get("titles", [])):
        if not d.startswith("translations/"):
            out.append({"d": d, "t": mw.strip_html(_NUMBER.sub("", t))})
    return out


def docs(max_age_days=30, *, force=False):
    """All documents (translations excluded) -> [{"d", "t"}]: from the monthly cache, else downloaded
    (one 20 MB request). A failed refresh returns the older cache when there is one."""
    path = paths.kernel_docs_path()
    cached = atomic.read_json(path)
    ok = isinstance(cached, dict) and cached.get("v") == CACHE_VERSION and isinstance(cached.get("docs"), list)
    now = int(time.time() * 1000)
    if ok and not force and 0 <= now - int(cached.get("fetchedAt") or 0) < max_age_days * 86400 * 1000:
        return cached["docs"]
    try:
        listing = parse_searchindex(http.get(INDEX_URL, accept="text", timeout=120))
    except (http.NetError, ValueError, KeyError):
        if ok:
            return cached["docs"]
        raise
    atomic.write_json(path, {"v": CACHE_VERSION, "fetchedAt": now, "from": INDEX_URL, "docs": listing}, indent=None)
    return listing


def doc_url(docname):
    return f"{BASE}/{docname}.html"


def weight_of(docname, cfg=None):
    """The candidate weight of a document (0 = not a candidate), by the curation in static_pages.json."""
    cfg = cfg or paths.static_pages()["kernel"]
    if docname.rsplit("/", 1)[-1] in cfg["skipLeaves"]:
        return 0.0
    if any(docname.startswith(p) for p in cfg["exclude"]):
        return 0.0
    best = None
    for inc in cfg["include"]:
        if docname.startswith(inc["prefix"]) and (best is None or len(inc["prefix"]) > len(best["prefix"])):
            best = inc
    if best is None:
        return 0.0
    w = float(best["weight"])
    if docname in cfg["pinned"]["docnames"]:
        w *= float(cfg["pinned"]["weight"])
    return w


def candidates(max_age_days=30):
    """The documents worth a card -> [{docname, title, url, area (the top folder), weight, pinned}],
    sorted by docname. Pick with a weighted draw; `weight` is relative."""
    cfg = paths.static_pages()["kernel"]
    pinned = set(cfg["pinned"]["docnames"])
    out = []
    for d in docs(max_age_days):
        w = weight_of(d["d"], cfg)
        if w > 0:
            out.append({"docname": d["d"], "title": d["t"], "url": doc_url(d["d"]), "area": d["d"].split("/")[0],
                        "weight": w, "pinned": d["d"] in pinned})
    out.sort(key=lambda c: c["docname"])
    return out


def page_html(docname):
    """The rendered page. What precedes the first paragraph varies (a field list, a language bar, a
    subtitle), so "the first <p>" is not always an intro: htmltext/intro decide."""
    return http.get(doc_url(docname), accept="text")
