"""The Arch wiki (wiki.archlinux.org): an English title index, leads, "Tips and tricks", packages.

`list=random` is useless here: 50.5 % of the wiki's pages are translations (api_notes 6). So a weekly
index of every page is built once (`list=allpages`, redirects excluded, 9 requests) and the pick is local.

Translations are pages titled `Name (Language)`. 127 English titles also end in a parenthesis (laptop
models: `Dell XPS 13 (9300)`, `Lenovo ThinkPad T14 (AMD) Gen 3`), so a title is a translation only when its
LAST parenthetical is a language (tools/wiki/data/static_pages.json arch.languageSuffixes). A suffix that
is not in that set but could still be a language name (no digit, not an all-caps abbreviation: `Intel`,
`Edgar`, or a language the list has not met) is put to the wiki once, through the `pagelanguage` of one
page that carries it (`prop=info`), and the verdict is stored in the index next to the titles.
"""
import re
import time

from .. import atomic, http, mw, paths

HOST = "wiki.archlinux.org"
INDEX_VERSION = 1
_SUFFIX = re.compile(r"\s\(([^()]+)\)$")
_PKG = re.compile(r"\{\{\s*(?:[Pp]kg|[Aa][Uu][Rr])\s*\|\s*([^|{}]+?)\s*(?:\||\}\})")


# ----------------------------------------------------------------------------- translations

def languages():
    """The set of language names that end a translated title."""
    return frozenset(paths.static_pages()["arch"]["languageSuffixes"])


def suffix_of(title):
    """The last parenthetical of a title (`Systemd (Español)` -> `Español`), or None. A nested one
    (`ASUS MeMO Pad 7 (ME176C(X))`) is not a plain suffix and gives None."""
    m = _SUFFIX.search(title)
    return m.group(1) if m else None


def is_ambiguous(suffix, verdicts=None):
    """A suffix outside the language set that could still be a language name, and has not been asked
    about yet: no digit (a model number or a generation is English), not an ASCII all-caps abbreviation."""
    if suffix in languages() or suffix in (verdicts or {}):
        return False
    if any(c.isdigit() for c in suffix):
        return False
    return not (suffix.isascii() and suffix.isupper())


def is_translation(title, verdicts=None):
    """True for `Name (Language)`. `verdicts` is {suffix: pagelanguage code} for the ambiguous ones."""
    suffix = suffix_of(title)
    if suffix is None:
        return False
    if suffix in languages():
        return True
    code = (verdicts or {}).get(suffix)
    return code is not None and not code.lower().startswith("en")


def english_only(titles, verdicts=None):
    """`titles` without the translations, order kept."""
    return [t for t in titles if not is_translation(t, verdicts)]


def _resolve_verdicts(titles, verdicts):
    """Ask the wiki for the language of one page per ambiguous suffix. -> verdicts extended in a copy."""
    verdicts = dict(verdicts or {})
    reps = {}
    for t in titles:
        s = suffix_of(t)
        if s is not None and s not in reps and is_ambiguous(s, verdicts):
            reps[s] = t
    by_title = {t: s for s, t in reps.items()}
    for chunk in mw.chunks(list(reps.values()), 50):
        q = mw.query(HOST, {"action": "query", "titles": chunk, "prop": "info", "inprop": "url"}).get("query", {})
        for p in q.get("pages", []):
            s = by_title.get(p.get("title"))
            if s is not None:
                verdicts[s] = p.get("pagelanguage") or "en"
    for s in reps:
        verdicts.setdefault(s, "en")            # not answered: keep the page rather than lose it
    return verdicts


# ----------------------------------------------------------------------------- the index

def _fetch_all_titles():
    q = mw.query(HOST, {"action": "query", "list": "allpages", "apnamespace": 0,
                        "apfilterredir": "nonredirects", "aplimit": "max"}, continue_all=True)
    return [p["title"] for p in q.get("query", {}).get("allpages", [])]


def title_index(max_age_days=7, *, force=False):
    """The English title index, from `$XDG_CACHE_HOME/lares/wiki/arch_titles.json` while it is fresh,
    else rebuilt (9 requests). -> {v, source, fetchedAt, total, english, translations, duplicates,
    suffixVerdicts, titles (sorted), stale?}. When the rebuild cannot reach the wiki and an older index
    exists, that one is returned with `stale: true`; with none the network error is raised."""
    path = paths.arch_titles_path()
    cached = atomic.read_json(path)
    ok = isinstance(cached, dict) and cached.get("v") == INDEX_VERSION and isinstance(cached.get("titles"), list)
    now = int(time.time() * 1000)
    if ok and not force and 0 <= now - int(cached.get("fetchedAt") or 0) < max_age_days * 86400 * 1000:
        return cached
    try:
        raw = _fetch_all_titles()
        verdicts = _resolve_verdicts(raw, cached.get("suffixVerdicts") if ok else None)
        english = sorted(set(english_only(raw, verdicts)))
    except (http.NetError, mw.MwError):
        if ok:
            return dict(cached, stale=True)
        raise
    idx = {
        "v": INDEX_VERSION, "source": "list=allpages apnamespace=0 apfilterredir=nonredirects",
        "fetchedAt": now, "total": len(raw), "english": len(english), "translations": len(raw) - len(english),
        "duplicates": len(raw) - len(set(raw)), "suffixVerdicts": verdicts, "titles": english,
    }
    atomic.write_json(path, idx)
    return idx


def english_titles(max_age_days=7):
    return title_index(max_age_days)["titles"]


def tips_subpage(title, titles=None):
    """`<title>/Tips and tricks` when the wiki has that subpage (a page of its own: `Pacman/Tips and
    tricks`), else None."""
    have = titles if titles is not None else english_titles()
    cand = f"{title}/Tips and tricks"
    return cand if cand in set(have) else None


# ----------------------------------------------------------------------------- pages

def lead_html(title):
    """Section 0 as HTML -> mw.parse_section() dict. On Arch the real intro is often not the first <p>
    (a "Related articles" box, a lead-in ending in ":" and a <dl><dd> quote come first): htmltext/intro
    deal with that."""
    return mw.parse_section(HOST, title, 0)


def sections(title):
    return mw.sections(HOST, title)


def _is_tips(heading):
    return heading.strip().lower() in paths.static_pages()["arch"]["tipsHeadings"]


def tips_sections(title, secs=None):
    """The "Tips and tricks" sections of a page, each with its subsections:
    -> [{index, level, title, anchor, ..., subsections: [section...]}]. `section_html` of the parent's
    index returns the whole thing, subsections included."""
    secs = secs if secs is not None else sections(title)
    out = []
    for i, s in enumerate(secs):
        if not _is_tips(s["title"]):
            continue
        sub = []
        for t in secs[i + 1:]:
            if t["level"] <= s["level"]:
                break
            sub.append(t)
        out.append(dict(s, subsections=sub))
    return out


def section_html(title, idx):
    return mw.parse_section(HOST, title, idx)


def pkg_names(wikitext):
    """Package names in `{{Pkg|x}}` / `{{pkg|x}}` / `{{AUR|x}}` templates, first appearance order, no
    repeats. (The template name is case-insensitive at its first letter; a Pkg may sit inside a
    {{Note|...}} or {{Tip|...}}.)"""
    seen, out = set(), []
    for m in _PKG.finditer(wikitext):
        name = m.group(1)
        if name not in seen:
            seen.add(name)
            out.append(name)
    return out


def pkg_templates(title, indexes=(0, 1)):
    """Package names a page names in its lead and its first section (Installation is section 1 on almost
    every software page; `{{Pkg}}` is not in section 0: api_notes 6). One request per section."""
    names, seen = [], set()
    for idx in indexes:
        for n in pkg_names(mw.wikitext_section(HOST, title, idx)):
            if n not in seen:
                seen.add(n)
                names.append(n)
    return names
