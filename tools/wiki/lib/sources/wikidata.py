"""Wikidata: the logo (P154) of a page's subject, as a Commons file.

Chain (api_notes 10): the English page's `wikibase_item` (pageprops; with `redirects=1` it is the redirect
TARGET's, never a section's) -> `wbgetclaims` P154 (a Commons file name) -> the file's URL. The name alone is
enough for a URL: `commons.wikimedia.org/wiki/Special:FilePath/<name>` answers with the file's bytes, so
the imageinfo call only adds size, license and artist.

No `maxlag` on Wikidata. It answers "maxlag: Waiting for wdqs..." whenever its QUERY SERVICE lags (measured
2026-09-30: 6 s), which has nothing to do with reading one claim, and mw.call would sit out three waits (30 s)
before giving up. `wbgetclaims` is the only Wikidata call and one small read is worth making anyway.
"""
import urllib.parse

from .. import mw
from . import commons, wikipedia

HOST = "www.wikidata.org"
FILEPATH = "https://commons.wikimedia.org/wiki/Special:FilePath/"
_RANK = {"preferred": 0, "normal": 1}          # deprecated statements are dropped


def qids(titles):
    """{requested title: Q-id or None} for English Wikipedia titles, one request per 50."""
    out = {}
    for chunk in mw.chunks(titles, 50):
        q = mw.query(wikipedia.HOST, {"action": "query", "titles": chunk, "prop": "pageprops",
                                      "ppprop": "wikibase_item", "redirects": 1}).get("query", {})
        by_title = {p.get("title"): p for p in q.get("pages", [])}
        for req, canon in mw.title_map(q, chunk).items():
            out[req] = ((by_title.get(canon) or {}).get("pageprops") or {}).get("wikibase_item")
    return out


def p154_files(qid):
    """Commons file names of the item's logo statements, preferred rank first, deprecated ones dropped."""
    data = mw.call(HOST, {"action": "wbgetclaims", "entity": qid, "property": "P154"}, formatversion=None,
                   maxlag=None)
    claims = (data.get("claims") or {}).get("P154", [])
    ranked = []
    for i, c in enumerate(claims):
        rank = _RANK.get(c.get("rank"))
        snak = c.get("mainsnak") or {}
        val = (snak.get("datavalue") or {}).get("value")
        if rank is None or snak.get("snaktype") != "value" or not isinstance(val, str):
            continue
        ranked.append((rank, i, val))
    return [v for _, _, v in sorted(ranked)]


def filepath_url(file_name):
    return FILEPATH + urllib.parse.quote(file_name.replace(" ", "_"), safe="()!*,'~")


def logo_for(enwiki_title, qid=None):
    """The logo of the subject of an English Wikipedia article, or None (no Wikidata item, no P154).

    -> {qid, file, file_title, url (the original's, or Special:FilePath when Commons has no info),
        filepath_url, mime, svg, width, height, license, artist, credit}. Pass `qid` when it is known
    (wikipedia.batch_meta returns it as `wikibase_item`) to save the pageprops request."""
    if qid is None:
        qid = qids([enwiki_title]).get(enwiki_title)
    if not qid:
        return None
    files = p154_files(qid)
    if not files:
        return None
    name = files[0]
    title = "File:" + name.replace("_", " ")
    info = commons.image_info([title]).get(title) or {}
    fp = filepath_url(name)
    mime = info.get("mime") or ("image/svg+xml" if name.lower().endswith(".svg") else None)
    return {
        "qid": qid, "file": name, "file_title": title, "url": info.get("url") or fp, "filepath_url": fp,
        "mime": mime, "svg": mime == "image/svg+xml", "width": info.get("width"), "height": info.get("height"),
        "license": info.get("license", ""), "artist": info.get("artist", ""), "credit": info.get("credit", ""),
    }
