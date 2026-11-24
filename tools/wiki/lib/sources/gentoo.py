"""The Gentoo wiki (wiki.gentoo.org): leads, and random English pages.

The lead of a Translate-extension page starts with noise (a language bar, a literal `<translate>` tag
shown as text, alert boxes, a Font Awesome infobox: api_notes 7). That stays in the HTML for htmltext /
cleanup to strip; nothing here touches it.
"""
from .. import mw, paths

HOST = "wiki.gentoo.org"
PAGE = 10                    # list=random rnlimit; about half of a page is translations


def _cfg():
    return paths.static_pages()["gentoo"]


def is_translation(title):
    """A `/xx` translation subpage (`Monit/ru`, `Xfce/Guide/ja`) or a page of the Polish project's own
    tree. Compared with real language codes: `/etc`, `/srv` and `/bin` are English pages."""
    cfg = _cfg()
    if title.startswith(tuple(cfg["nonEnglishPrefixes"])):
        return True
    return "/" in title and title.rsplit("/", 1)[1].lower() in cfg["languageCodes"]


def random_titles(n, *, max_requests=8):
    """`n` random English page titles (namespace 0), distinct. `list=random` returns 10 at a time and
    a translation is skipped, so this asks again until it has n (or `max_requests` answers, then fewer)."""
    out, seen = [], set()
    for _ in range(max_requests):
        if len(out) >= n:
            break
        data = mw.call(HOST, {"action": "query", "list": "random", "rnnamespace": 0, "rnlimit": PAGE})
        for r in data.get("query", {}).get("random", []):
            t = r["title"]
            if t not in seen and not is_translation(t):
                seen.add(t)
                out.append(t)
    return out[:n]


def lead_html(title):
    """Section 0 as HTML -> mw.parse_section() dict."""
    return mw.parse_section(HOST, title, 0)
