"""Wikimedia Commons and the Wikipedia featured feed: On this day, Picture of the day, today's featured article.

The feed (`api.wikimedia.org/feed/v1/wikipedia/en/featured/YYYY/MM/DD`, UTC date, 380 KB) answers all three
in one request (api_notes 5). `featured()` normalises them to plain dicts: HTML fields are dropped in favour
of the feed's own `.text` variants, titles lose their underscores, and a thumbnail's size is worked out from
the ORIGINAL's (the feed's `thumbnail.width` says 640 for a `960px-` file).
"""
import datetime as dt
import re

from .. import http, mw
from . import wikipedia

FEED = "https://api.wikimedia.org/feed/v1/wikipedia/en/featured"
COMMONS = "commons.wikimedia.org"
LOGO_KEYS = ("Artist", "LicenseShortName", "LicenseUrl", "UsageTerms", "ImageDescription", "Credit",
             "Copyrighted", "ObjectName")


def _day(day):
    if isinstance(day, (dt.date, dt.datetime)):
        return day.strftime("%Y-%m-%d")
    dt.datetime.strptime(day, "%Y-%m-%d")           # rejects anything that is not a date
    return day


def _page(p):
    """A feed page summary -> {title, url, extract, description, thumb, thumb_w, thumb_h, wikibase_item}."""
    t = p.get("titles", {}).get("normalized") or p.get("title", "").replace("_", " ")
    thumb = p.get("thumbnail") or {}
    return {
        "title": t, "url": (p.get("content_urls", {}).get("desktop", {}) or {}).get("page")
        or mw.page_url(wikipedia.HOST, t),
        "extract": p.get("extract", ""), "description": p.get("description", ""),
        "thumb": thumb.get("source"), "thumb_w": thumb.get("width"), "thumb_h": thumb.get("height"),
        "wikibase_item": p.get("wikibase_item"),
    }


def _thumb_size(thumb_url, width, height):
    """(w, h) of a `.../960px-Name.jpg` thumbnail from the original's size: a raster is never upscaled."""
    m = re.search(r"/(\d+)px-", thumb_url or "")
    if not (m and width and height):
        return None, None
    w = min(int(m.group(1)), width)
    return w, round(height * w / width)


def _potd(img):
    if not img:
        return None
    orig = img.get("image") or {}
    thumb = img.get("thumbnail") or {}
    tw, th = _thumb_size(thumb.get("source"), orig.get("width"), orig.get("height"))
    lic = img.get("license") or {}
    return {
        "fileTitle": img.get("title"), "file_page": img.get("file_page"),
        "url": orig.get("source"), "width": orig.get("width"), "height": orig.get("height"),
        "thumb_url": thumb.get("source"), "thumb_w": tw, "thumb_h": th,
        "artist": (img.get("artist") or {}).get("text", ""), "credit_text": (img.get("credit") or {}).get("text", ""),
        "license": lic.get("type", ""), "license_code": lic.get("code", ""), "license_url": lic.get("url", ""),
        "description": (img.get("description") or {}).get("text", ""), "wikibase_item": img.get("wb_entity_id"),
    }


def featured(day):
    """`day` ("YYYY-MM-DD" or a date, UTC) -> {day, otd: [{year, text, title, url, pages: [...]}], potd, tfa}.
    Each OTD entry's `title`/`url` are its first page's. potd/tfa are None on a day the feed lacks them."""
    d = _day(day)
    y, m, dd = d.split("-")
    data = http.get(f"{FEED}/{y}/{m}/{dd}")
    otd = []
    for e in data.get("onthisday", []) or []:
        pages = [_page(p) for p in e.get("pages", []) or []]
        if not pages:
            continue
        otd.append({"year": e.get("year"), "text": e.get("text", ""), "title": pages[0]["title"],
                    "url": pages[0]["url"], "pages": pages})
    tfa = data.get("tfa")
    return {"day": d, "otd": otd, "potd": _potd(data.get("image")), "tfa": _page(tfa) if tfa else None}


def image_info(file_titles, thumb_width=None, keys=LOGO_KEYS):
    """wikipedia.image_info() against Commons itself (a file that lives there, a logo): the same dict."""
    return wikipedia.image_info(file_titles, host=COMMONS, thumb_width=thumb_width, keys=keys)
