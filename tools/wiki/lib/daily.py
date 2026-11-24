"""The day's extras: On this day (a line on the tear-off) and the Picture of the day.

    build(day, force=False)   -> the daily dict, written to `$XDG_CACHE_HOME/lares/wiki/daily/<day>.json`
    cached(day)               -> the dict on disk, or None (a batch reads it to know today's picture)

One request (the featured feed: On this day, the picture, today's featured article, api_notes 5) and one download
(the picture's 960 px thumbnail, cropped 16:9 and square like every hero, into `img/potd-<day>.jpg` /
`-thumb.jpg`, relative to the state dir).

On this day. The feed lists about twenty events, each with the pages it links. The best is scored: the linked
article (the page whose title the event's text names, else the first) has a thumbnail (+2), the text is one line
(under 220 characters, +1), the article's title is in the text (+1), and a text about killing, war or disaster loses
1.5 (the line sits on a card meant to be looked at with a coffee); an event whose article or text passes the deny list
that keeps computing's near side out of Discover is not a candidate. Ties break by a draw seeded with the day, so a day's line is stable and days differ. The card
opens that article by Ctrl+click.

Picture of the day. `relatesTo` is the id of a Discover entry in the pool whose images already carry that file
(the batch put it there, or the page's own media list named it) -- no request; that article shows it as its first
carousel image. A picture no article of the pool shows is its own Discover entry (`kind: "potd"`), at most one per
ISO week: title = the picture's file name, intro = the feed's caption cleaned like a lead and cut on a sentence end
(a caption is short, so 30 words are enough here where an article's lead needs 50), image = the photo (its own
files), source = the Commons file page, `category` = visual-arts / via daily. The depicted article, and with it a
better family and the caption's links, is not known: `commons.featured` keeps the caption's text and drops its
HTML. The week is recorded in the daily cache: every day's file names its ISO week (`week`) and, when it made the
entry, `potd.entryId`; a day looks at the other six of its week before it makes one.
"""
import datetime as dt
import os
import random
import re

from . import atomic, cleanup, entry, http, images, index, intro, mw, paths, title as titlelib
from .candidates import denied
from .sources import commons

MAX_TEXT = 220
DESC_MAX = 300
POTD_MIN_WORDS = 30
POTD_FAMILY = "visual-arts"
_GRIM = re.compile(r"(?i)\b(kill\w*|died|dead|death|massacre\w*|assassinat\w+|bomb\w*|attack\w*|war|wars|execut\w+|"
                   r"earthquake|disaster|genocide|shot|crash\w*|sink\w*|sank|tsunami|hurricane|famine)\b")


def cached(day):
    d = atomic.read_json(paths.daily_path(day))
    return d if isinstance(d, dict) and d.get("v") == 1 and d.get("day") == day else None


def _page_for(event):
    """The event's linked article: the page whose title its text names (the longest), else the first."""
    text = event.get("text", "")
    named = [p for p in event["pages"] if p["title"] and p["title"] in text]
    return max(named, key=lambda p: len(p["title"])) if named else event["pages"][0]


def pick_otd(events, day, deny):
    scored = []
    for e in events:
        if not e.get("pages") or not e.get("text"):
            continue
        p = _page_for(e)
        if denied(p["title"], e["text"], deny):
            continue
        s = (2.0 if p.get("thumb") else 0.0) + (1.0 if len(e["text"]) <= MAX_TEXT else 0.0) \
            + (1.0 if p["title"] in e["text"] else 0.0) - (1.5 if _GRIM.search(e["text"]) else 0.0)
        scored.append((s, e, p))
    if not scored:
        return None
    best = max(s for s, _, _ in scored)
    top = [(e, p) for s, e, p in scored if s == best]
    e, p = random.Random(day).choice(top)
    return {"year": e.get("year"), "text": e["text"], "title": p["title"], "url": p["url"]}


def _relates_to(file_title):
    """A Discover entry of the pool that already carries the picture's file."""
    for row in index.read()["tabs"]["discover"]:
        e = atomic.read_json(os.path.join(paths.entries_dir("discover"), row["slug"] + ".json"))
        if e and e.get("kind") != "potd" and any(im.get("fileTitle") == file_title for im in e.get("images", [])):
            return e["id"]                               # (the picture's own entry is not "an article that shows it")
    return None


def _potd(p, day, log):
    if not p or not p.get("thumb_url"):
        return None
    try:
        data = http.get(p["thumb_url"], accept="bytes", timeout=40)
    except http.NetError as e:
        log("picture of the day: %s" % e)
        return None
    credit = ", ".join(x for x in (p.get("artist"), p.get("license")) if x)
    desc = " ".join((p.get("description") or "").split())
    if len(desc) > DESC_MAX:
        desc = desc[:DESC_MAX - 1].rstrip() + "…"
    try:
        im = images.save_photo(data, "potd-" + day, 0, credit=credit, license_=p.get("license") or "", src="potd",
                               file_title=p["fileTitle"])
    except (OSError, ValueError) as e:
        log("picture of the day is not an image: %s" % e)
        return None
    return {"fileTitle": p["fileTitle"], "file": im["file"], "thumb": im["thumb"], "credit": credit,
            "license": p.get("license") or "", "description": desc, "relatesTo": _relates_to(p["fileTitle"]),
            "entryId": None, "w": im["w"], "h": im["h"], "aspect": im["aspect"], "focusY": im["focusY"]}


def iso_week(day):
    """"2026-09-30" -> "2026-W40"."""
    y, w, _ = dt.date.fromisoformat(day).isocalendar()
    return "%d-W%02d" % (y, w)


def week_days(day):
    """The seven days (Monday first) of the ISO week `day` is in."""
    d = dt.date.fromisoformat(day)
    monday = d - dt.timedelta(days=d.weekday())
    return [(monday + dt.timedelta(days=i)).isoformat() for i in range(7)]


def week_entry(day):
    """The id of the potd entry another day of `day`'s ISO week made (its daily file says so), or None."""
    for d in week_days(day):
        if d != day:
            eid = ((cached(d) or {}).get("potd") or {}).get("entryId")
            if eid:
                return eid
    return None


def potd_title(file_title):
    """"File:Split_Cathedral_Bell_Tower - Split.jpg" -> "Split Cathedral Bell Tower - Split" (the file's own name)."""
    return titlelib.file_name(file_title)


def potd_intro(description):
    """(text, links, stripped codes) of a picture's caption made into an intro, or None when it is not one: cleaned
    like a Wikipedia lead, cut on a sentence end at 150 words, and at least POTD_MIN_WORDS long."""
    text = " ".join((description or "").split())
    if not text:
        return None
    cleaned, _ = cleanup.clean([{"text": text, "links": [], "kind": "p", "section": "", "stripped": []}], "wikipedia")
    picked, words = intro.cut(cleaned)
    if not picked or words < POTD_MIN_WORDS:
        return None
    body, links, _ = intro.join(picked)
    return body, links, intro.stripped_codes(picked)


def weekly_entry(day, p, potd, deny, log, shorten=None):
    """The picture as its own Discover entry -> the entry's id, or None: it relates to an article of the pool (that
    article carries it), the week has an entry already, its caption is no intro, it is about what Discover keeps out
    or reads as graphic, or its entry exists. `p` is the feed's picture, `potd` the cropped one this day's file holds.
    The title is the file name made short (lib/title.py); `shorten` is the `chat` of a local model that may shorten
    it further, or None (the deterministic form only). The source keeps the file's own title for the link."""
    if potd["relatesTo"] or week_entry(day):
        return None
    title = potd_title(p["fileTitle"])
    caption = " ".join((p.get("description") or "").split())
    made = potd_intro(caption)
    if not made or not title or denied(title, caption, deny) or images._keyword_graphic(caption, title):
        return None
    title, how = titlelib.short_title(p["fileTitle"], caption, shorten, log)
    if how != "cleaned":
        log("picture of the day: title %r from %r (%s)" % (title, potd_title(p["fileTitle"]), how))
    text, links, codes = made
    ident = entry.default_id(commons.COMMONS, p["fileTitle"])
    if os.path.exists(paths.entry_path("discover", ident)):
        return None
    slug = paths.slug(ident)
    im = images.copy_potd(potd, slug, 0)
    e = entry.new_entry(
        id=ident, tab="discover", kind="potd",
        source={"wiki": "commons", "host": commons.COMMONS, "title": p["fileTitle"],
                "url": p.get("file_page") or mw.page_url(commons.COMMONS, p["fileTitle"]),
                "license": p.get("license") or None},
        title=title, category={"family": POTD_FAMILY, "topic": None, "via": "daily", "why": None},
        intro={"text": text, "provenance": "cleaned" if codes else "original", "stripped": codes, "links": links},
        images=[im], batch="daily")
    try:
        entry.save(e)
    except (entry.EntryExists, entry.Invalid) as ex:
        for rel in (im["file"], im["thumb"]):
            try:
                os.unlink(os.path.join(paths.state_dir(), rel))
            except OSError:
                pass
        log("picture of the day as an entry: %s" % ex)
        return None
    index.add_rows("discover", [{"id": ident, "slug": slug, "family": POTD_FAMILY, "topic": None, "kind": "potd",
                                 "fetchedAt": e["fetchedAt"], "popularityBand": None, "jevScore": None}])
    return ident


def build(day, *, force=False, deny=(), log=lambda m: None, shorten=None):
    """The day's extras. A cached day is returned as it is unless `force`."""
    if not force:
        hit = cached(day)
        if hit:
            return hit
    feed = commons.featured(day)
    potd = _potd(feed["potd"], day, log)
    if potd:
        prev = (cached(day) or {}).get("potd") or {}      # a forced rebuild of the day that made the week's entry
        potd["entryId"] = prev.get("entryId") if prev.get("fileTitle") == potd["fileTitle"] else None
        if not potd["entryId"]:
            try:
                potd["entryId"] = weekly_entry(day, feed["potd"], potd, deny, log, shorten)
            except (OSError, ValueError, KeyError) as e:     # the entry is a bonus: it never costs the day its extras
                log("picture of the day as an entry: %s" % e)
    daily = {"v": 1, "day": day, "week": iso_week(day), "otd": pick_otd(feed["otd"], day, deny), "potd": potd}
    atomic.write_json(paths.daily_path(day), daily)
    return daily
