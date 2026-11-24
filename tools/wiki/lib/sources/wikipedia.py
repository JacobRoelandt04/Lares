"""English Wikipedia: which articles, their page data, lead HTML, images, popularity, quality.

Everything follows docs/contracts/wiki_api_notes.md. The points that matter:
  * A random Good/Featured article by topic is a CirrusSearch query (`articletopic:` is a flat list of 64
    values; `a|b` ORs, two keywords AND) sorted `srsort=random`. Both qualities in ONE query works only as
    `hastemplate:"Good article|Featured article"` (the pipe INSIDE the quotes); a parenthesised OR of two
    hastemplate clauses answers 0 hits without an error (api_notes 4 missed the quoted-pipe form).
  * `pages` of a generator/titles query come back in no particular order: sort by `index` (generator) or
    by the order the titles were asked in.
  * imageinfo `thumbwidth`/`thumbheight` echo the REQUEST (960) even for a file that is smaller: the
    file's own `width`/`height` are the truth.
  * The lead is `action=parse&section=0`; turning it into paragraphs is htmltext's job, not this file's.
"""
import re
import urllib.parse

from .. import http, mw, paths

HOST = "en.wikipedia.org"
_REST = "https://en.wikipedia.org/api/rest_v1"
PAGEVIEWS_DAYS = 60
PAGEVIEWS_BATCH = 20        # titles per request; api_notes used 4, and 12 in one answer came back whole
META_BATCH = 20             # extracts (exintro) are capped at 20 pages per request
IMAGEINFO_BATCH = 20
IMAGE_KEYS = ("Artist", "LicenseShortName", "LicenseUrl", "UsageTerms", "ImageDescription", "Credit",
              "Attribution", "Copyrighted", "ObjectName", "DateTimeOriginal")
_QUALITY_CATEGORIES = {"Category:Featured articles": "featured", "Category:Good articles": "good"}


# ----------------------------------------------------------------------------- which articles

def quality_clause(quality):
    """The hastemplate clause for "good" | "featured" | "both". The two single clauses are families.json's
    (query.good / query.featured, the one source). "both" is ONE query with the pipe INSIDE the quotes,
    `hastemplate:"Good article|Featured article"` (97 + 28 = 125 hits for physics, checked live on
    2026-09-30); the per-quality form stays the planner's contract, so use "both" only when one merged
    random draw is what is wanted."""
    q = paths.families()["query"]
    if quality in ("good", "featured"):
        return q[quality]
    if quality == "both":
        names = [re.fullmatch(r'hastemplate:"([^"]+)"', q[k]).group(1) for k in ("good", "featured")]
        return 'hastemplate:"%s"' % "|".join(names)
    raise ValueError(f"quality must be good, featured or both, not {quality!r}")


def _or(topics):
    return "|".join(topics) if isinstance(topics, (list, tuple)) else str(topics)


def search_query(topic, quality="both", lens=None, extra=""):
    """`articletopic:<topic> [articletopic:<lens>] hastemplate:"..." [extra]`.

    `topic` is one articletopic value, a "a|b" string or a list (OR). `lens` is a second articletopic
    keyword, i.e. an AND (the Geography family's region, the computing guest's far side). `extra` is
    appended verbatim: negations (`-articletopic:software`), a quoted phrase."""
    parts = ["articletopic:" + _or(topic)]
    if lens:
        parts.append("articletopic:" + _or(lens))
    parts.append(quality_clause(quality))
    if extra:
        limit = paths.families()["query"]["maxClauseChars"]
        if len(extra.strip()) > limit:
            raise ValueError(f"CirrusSearch refuses more than {limit} characters beside articletopic and "
                             f"hastemplate; split the clause into several queries")
        parts.append(extra.strip())
    return " ".join(parts)


def search_random(query, n=10):
    """One random-order page of a CirrusSearch query -> {titles, totalhits}. `srsort=random` answers a
    fresh sample on every call (a second page of it was not tested: ask again and dedupe)."""
    data = mw.call(HOST, {
        "action": "query", "list": "search", "srsearch": query, "srsort": "random",
        "srlimit": max(1, min(int(n), 50)), "srnamespace": 0})
    q = data.get("query", {})
    return {"titles": [h["title"] for h in q.get("search", [])],
            "totalhits": q.get("searchinfo", {}).get("totalhits", 0)}


def random_by_topic(topic, quality="both", n=10, lens=None, extra=""):
    """Titles of up to `n` random Good/Featured articles of `topic` (see search_query). An empty topic
    intersection answers []: no error, no warning."""
    return search_random(search_query(topic, quality, lens, extra), n)["titles"]


# ----------------------------------------------------------------------------- page data

_META_PROPS = "pageimages|info|pageprops"


def _image(d, prefix):
    if not d:
        return {prefix: None, prefix + "_w": None, prefix + "_h": None}
    return {prefix: d.get("source"), prefix + "_w": d.get("width"), prefix + "_h": d.get("height")}


def _meta(page):
    """One `pages[]` object -> {title, pageid, index, url, revid, length, pageimage, thumb(+_w/_h),
    original(+_w/_h), wikibase_item, extract, missing}. `thumb` is the page-image URL at 960 px wide, or the
    original file itself when that is smaller (`thumbnail_unscaled`)."""
    m = {
        "title": page.get("title"), "pageid": page.get("pageid"), "index": page.get("index"),
        "url": page.get("canonicalurl") or page.get("fullurl") or mw.page_url(HOST, page.get("title", "")),
        "revid": page.get("lastrevid"), "length": page.get("length"),
        "pageimage": page.get("pageimage"),
        "wikibase_item": (page.get("pageprops") or {}).get("wikibase_item"),
        "extract": page.get("extract"), "missing": bool(page.get("missing")),
    }
    m.update(_image(page.get("thumbnail"), "thumb"))
    m.update(_image(page.get("original"), "original"))
    return m


def search_meta(query, n=5):
    """A random search and the page data of its hits in ONE request (generator=search), rank order
    (`index`). Adds the plain-text lead as `extract` (n is capped at 20: the extracts limit)."""
    n = max(1, min(int(n), META_BATCH))
    data = mw.call(HOST, {
        "action": "query", "generator": "search", "gsrsearch": query, "gsrsort": "random",
        "gsrlimit": n, "gsrnamespace": 0, "prop": "pageimages|extracts|info|pageprops",
        "exintro": 1, "explaintext": 1, "piprop": "thumbnail|name|original", "pithumbsize": 960,
        "inprop": "url", "ppprop": "wikibase_item"})
    pages = data.get("query", {}).get("pages", [])
    return [_meta(p) for p in sorted(pages, key=lambda p: p.get("index", 0))]


def batch_meta(titles, extracts=False):
    """Page data for known titles, in the order asked. Redirects are followed (`requested` says what was
    asked); a missing page is left out. -> list of the dicts of _meta() plus `requested`."""
    out = []
    for chunk in mw.chunks(titles, META_BATCH):
        params = {"action": "query", "titles": chunk, "prop": _META_PROPS, "piprop": "thumbnail|name|original",
                  "pithumbsize": 960, "inprop": "url", "ppprop": "wikibase_item", "redirects": 1}
        if extracts:
            params.update({"prop": _META_PROPS + "|extracts", "exintro": 1, "explaintext": 1})
        q = mw.query(HOST, params, continue_all=True).get("query", {})
        by_title = {p.get("title"): p for p in q.get("pages", [])}
        for req, canon in mw.title_map(q, chunk).items():
            p = by_title.get(canon)
            if p is None or p.get("missing"):
                continue
            m = _meta(p)
            m["requested"] = req
            out.append(m)
    return out


def lead_html(title):
    """The lead section's HTML -> mw.parse_section() dict (title is the canonical one after redirects)."""
    return mw.parse_section(HOST, title, 0)


# ----------------------------------------------------------------------------- images

def media_list(title):
    """The page's images in page order, from the REST media-list (better than prop=images, which is
    alphabetical and full of icons; api_notes 3). Only real, gallery-worthy images:
    -> [{title ("File:..."), lead (bool), section (int), caption, ext, thumb (1x URL), srcset {1x: URL, 2x: URL}}]."""
    t = urllib.parse.quote(title.replace(" ", "_"), safe="()!*,'~")
    data = http.get(f"{_REST}/page/media-list/{t}")
    out = []
    for it in data.get("items", []):
        if it.get("type") != "image" or not it.get("showInGallery") or not it.get("title"):
            continue
        srcset = {}
        for s in it.get("srcset", []):
            src = s.get("src", "")
            srcset[s.get("scale", "1x")] = ("https:" + src) if src.startswith("//") else src
        name = it["title"]
        out.append({
            "title": name.replace("_", " "), "lead": bool(it.get("leadImage")), "section": it.get("section_id"),
            "caption": (it.get("caption") or {}).get("text", ""),
            "ext": name.rsplit(".", 1)[-1].lower() if "." in name else "",
            "thumb": srcset.get("1x"), "srcset": srcset,
        })
    return out


def _credit(artist, credit, license_):
    who = artist or credit or ""
    if len(who) > 160:
        who = who[:159].rstrip() + "…"
    return ", ".join(x for x in (who, license_) if x)


def image_info(file_titles, *, host=HOST, thumb_width=960, keys=IMAGE_KEYS):
    """Size, type, license and credit of files, one request per 20.

    -> {requested title: {title, url (the original: never fetch it for a hero), thumb_url, thumb_w, thumb_h,
        page_url, width, height, size, mime, artist, license, license_url, description, credit_text,
        credit, copyrighted, date, repository}}. Extmetadata values are HTML on the wire and plain text here.
    A file with no imageinfo (missing) has no key.

    `width`/`height` are the file's own. `thumbwidth`/`thumbheight` echo the request (960 even for a
    700 px file: api_notes 3) and are used for nothing; the thumbnail's size is worked out from the file's:
    a raster is never upscaled (`thumbnail_unscaled`), an SVG is rasterised at the requested width."""
    files = list(file_titles)
    out = {}
    for chunk in mw.chunks(files, IMAGEINFO_BATCH):
        params = {"action": "query", "titles": chunk, "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata",
                  "iiextmetadatafilter": list(keys)}
        if thumb_width:
            params["iiurlwidth"] = thumb_width
        # no continue_all: imageinfo answers a `continue` that walks a file's OLDER revisions
        q = mw.query(host, params).get("query", {})
        by_title = {p.get("title"): p for p in q.get("pages", [])}
        for req, canon in mw.title_map(q, chunk).items():
            page = by_title.get(canon)
            infos = page.get("imageinfo") if page else None
            if not infos:
                continue
            ii = infos[0]
            width = ii.get("width")
            height = ii.get("height")
            mime = ii.get("mime")
            thumb_w = thumb_h = None
            if width and height:
                thumb_w = thumb_width if (mime == "image/svg+xml" and thumb_width) else min(width, thumb_width or width)
                thumb_h = round(height * thumb_w / width)
            md = ii.get("extmetadata") or {}

            def val(k):
                return mw.strip_html((md.get(k) or {}).get("value", ""))

            lic = val("LicenseShortName") or val("UsageTerms")
            out[req] = {
                "title": canon, "url": ii.get("url"), "thumb_url": ii.get("thumburl") or ii.get("url"),
                "thumb_w": thumb_w, "thumb_h": thumb_h, "page_url": ii.get("descriptionurl"),
                "width": width, "height": height, "size": ii.get("size"), "mime": mime,
                "artist": val("Artist"), "license": lic, "license_url": val("LicenseUrl"),
                "description": val("ImageDescription"), "credit_text": val("Credit"),
                "credit": _credit(val("Artist"), val("Credit"), lic),
                "copyrighted": {"True": True, "False": False}.get(val("Copyrighted")),
                "date": val("DateTimeOriginal"), "repository": page.get("imagerepository"),
            }
    return out


# ----------------------------------------------------------------------------- popularity, quality

def pageviews(titles, days=PAGEVIEWS_DAYS):
    """{requested title: views over the last `days` days}. prop=pageviews answers `{date: views|null}`
    for `days` days ending YESTERDAY, and yesterday is often still null (not yet published: api_notes 4).
    The last date is dropped for EVERY title, so all sums cover the same days (59), and a null elsewhere
    (an article younger than the window) counts as 0. A title with no data at all is 0."""
    out = {}
    for chunk in mw.chunks(titles, PAGEVIEWS_BATCH):
        q = mw.query(HOST, {"action": "query", "titles": chunk, "prop": "pageviews", "pvipdays": days},
                     continue_all=True).get("query", {})
        by_title = {p.get("title"): p for p in q.get("pages", [])}
        for req, canon in mw.title_map(q, chunk).items():
            pv = (by_title.get(canon) or {}).get("pageviews") or {}
            keys = sorted(pv)[:-1]
            out[req] = sum(pv[k] or 0 for k in keys)
    return out


def qualities(titles):
    """{requested title: "featured" | "good" | None}: one request for the batch (api_notes 1)."""
    out = {}
    for chunk in mw.chunks(titles, 50):
        q = mw.query(HOST, {"action": "query", "titles": chunk, "prop": "categories",
                            "clcategories": list(_QUALITY_CATEGORIES), "cllimit": "max"},
                     continue_all=True).get("query", {})
        by_title = {p.get("title"): p for p in q.get("pages", [])}
        for req, canon in mw.title_map(q, chunk).items():
            cats = {c.get("title") for c in (by_title.get(canon) or {}).get("categories", [])}
            found = [v for k, v in _QUALITY_CATEGORIES.items() if k in cats]
            out[req] = "featured" if "featured" in found else ("good" if found else None)
    return out


def quality_of(title):
    """"featured" | "good" | None for one (canonical) title."""
    return qualities([title])[title]
