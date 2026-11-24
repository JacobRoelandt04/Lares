"""The images of an entry: choose them, screen them, crop them (PIL), write them.

    pick_photos(title, screen, potd=None, ...)  -> {photos: [{data, info, src}], graphic, considered}
    save_photo(data, slug, n, ...)              -> the entry's image dict (kind photo), files written
    crop_hero(im, focus_y) / crop_thumb(im, focus_y)

What a hero is. Wikipedia's media list gives the page's images in page order (`prop=images` is alphabetical and full of
icons: api_notes 3). A file is dropped by its NAME when it is plainly not a picture of the subject (flags, arms,
logos, icons, signatures, locator maps), by its TYPE when it is not a photograph format (SVG, TIFF, GIF, video,
audio), and by its SIZE (under 300 px wide, or a strip: 4:1 and beyond) once imageinfo has the real dimensions (the
FILE's own `width`, never `thumbwidth`, which echoes the request). What is left is screened for graphic content:
a keyword net first (a caption or description that says corpse, gore, mass grave ...), then the judge's noul on
caption and description (p >= 0.6 drops the image). If EVERY image was dropped for being graphic the entry keeps
no photograph (the caller shows the family glyph); nothing else is lost.

The crop (the mock's build_mock.py wrote the same rule down): the hero is the largest 16:9 window of the source
centred on (0.5, focusY) and clamped to the image, scaled down to 960 px wide (never up); the thumbnail is the
largest square around the same centre, scaled down to 192 px (never up). focusY is 0.33 for a portrait (the face sits
in the upper third), 0.5 otherwise. `aspect` in the record is the SOURCE's width / height, `w`/`h` the hero file's.
JPEG quality 85. The picture of the day that belongs to the article (its media list names the file) becomes image
0 with `src: "potd"`; `src` is "page" for the rest.
"""
import io
import os
import re

from PIL import Image, ImageOps

from . import atomic, http, paths
from .sources import wikipedia

MAX_IMAGES = 4
HERO_W = 960
THUMB = 192
JPEG_Q = 85
PHOTO_EXT = ("jpg", "jpeg", "png", "webp")
PHOTO_MIMES = ("image/jpeg", "image/png", "image/webp")
MIN_WIDTH = 300
MIN_WIDTH_LATER = 400          # an image after the first must be a little bigger: the small ones are thumbnails
MAX_STRIP = 4.0                # width / height beyond this (or its inverse) is a banner, not a picture
INFO_BATCH = 12                # files asked about in one imageinfo request
MAX_BYTES = 8 * 1024 * 1024
GRAPHIC_P = 0.6

_NOT_A_PICTURE = re.compile(
    r"(?i)(?:^|[\s_:(\-])(?:(?:flag[\s_]of|coat[\s_]of[\s_]arms|logo|icon|symbol|seal[\s_]of|signature|pictogram|locator|"
    r"location[\s_]map|wikiproject|blank|question[\s_]book|ambox|padlock)(?=[\s_.)\-]|$)|commons-|edit-)")
_GRAPHIC_WORDS = re.compile(
    r"(?i)\b(corpses?|cadavers?|dead bod(?:y|ies)|bodies of|mutilat\w+|gore|gory|decapitat\w+|lynching|autopsy|"
    r"severed|charred (?:remains|bod\w+)|mass graves?|tortur\w+|massacre victims?|victims? of the massacre)\b")


# ----------------------------------------------------------------------------- pixels

def _flat_rgb(im):
    """`im` as opaque RGB: EXIF rotation applied, transparency composited onto white."""
    im = ImageOps.exif_transpose(im)
    if im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info):
        rgba = im.convert("RGBA")
        ground = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        return Image.alpha_composite(ground, rgba).convert("RGB")
    return im.convert("RGB")


def focus_for(width, height):
    return 0.33 if height > width else 0.5


def crop_hero(im, focus_y=0.5, focus_x=0.5):
    """The largest 16:9 window of `im` around the focus point, clamped to the image, at most HERO_W wide."""
    w, h = im.size
    target = 16.0 / 9.0
    cw, ch = (round(h * target), h) if w / h > target else (w, round(w / target))
    cw, ch = max(1, min(cw, w)), max(1, min(ch, h))
    left = max(0, min(w - cw, round(focus_x * w - cw / 2)))
    top = max(0, min(h - ch, round(focus_y * h - ch / 2)))
    hero = im.crop((left, top, left + cw, top + ch))
    if hero.size[0] > HERO_W:
        hero = hero.resize((HERO_W, round(HERO_W * 9 / 16)), Image.LANCZOS)
    return hero


def crop_thumb(im, focus_y=0.5, focus_x=0.5):
    """The largest square of `im` around the focus point, at most THUMB px."""
    w, h = im.size
    side = min(w, h)
    left = max(0, min(w - side, round(focus_x * w - side / 2)))
    top = max(0, min(h - side, round(focus_y * h - side / 2)))
    th = im.crop((left, top, left + side, top + side))
    if side > THUMB:
        th = th.resize((THUMB, THUMB), Image.LANCZOS)
    return th


def _jpeg(im):
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=JPEG_Q, optimize=True)
    return buf.getvalue()


def save_photo(data, slug, n, *, credit="", license_="", src="page", file_title=None):
    """Decode `data`, crop it, write `img/<slug>-<n>.jpg` and `-<n>-thumb.jpg` atomically -> the entry's image
    record. Raises OSError / PIL's exceptions on bytes that are not a picture."""
    with Image.open(io.BytesIO(data)) as raw:
        raw.load()
        im = _flat_rgb(raw)
    sw, sh = im.size
    fy = focus_for(sw, sh)
    hero, thumb = crop_hero(im, fy), crop_thumb(im, fy)
    hp, tp = "img/%s-%d.jpg" % (slug, n), "img/%s-%d-thumb.jpg" % (slug, n)
    base = paths.state_dir()
    atomic.write_bytes(os.path.join(base, hp), _jpeg(hero))
    atomic.write_bytes(os.path.join(base, tp), _jpeg(thumb))
    return {"kind": "photo", "file": hp, "thumb": tp, "w": hero.size[0], "h": hero.size[1],
            "aspect": round(sw / sh, 2), "focusY": fy, "credit": credit or "", "license": license_ or "",
            "src": src, "fileTitle": file_title}


def copy_potd(potd, slug, n):
    """The day's picture as image `n` of an entry whose article shows it: the daily step already cropped it
    (`potd.file` / `potd.thumb`, relative to the state dir); the entry gets files of its own, so removing one
    entry never breaks another. -> the image record (src "potd")."""
    base = paths.state_dir()
    hp, tp = "img/%s-%d.jpg" % (slug, n), "img/%s-%d-thumb.jpg" % (slug, n)
    for src, dst in ((potd["file"], hp), (potd["thumb"], tp)):
        with open(os.path.join(base, src), "rb") as f:
            atomic.write_bytes(os.path.join(base, dst), f.read())
    return {"kind": "photo", "file": hp, "thumb": tp, "w": potd.get("w"), "h": potd.get("h"),
            "aspect": potd.get("aspect"), "focusY": potd.get("focusY", 0.5), "credit": potd.get("credit", ""),
            "license": potd.get("license", ""), "src": "potd", "fileTitle": potd.get("fileTitle")}


# ----------------------------------------------------------------------------- choosing

def _norm_file(t):
    return re.sub(r"[\s_]+", " ", t or "").strip().lower()


def _dl(url):
    data = http.get(url, accept="bytes", timeout=40)
    if len(data) > MAX_BYTES:
        raise http.HttpError("image is %d bytes" % len(data), url=url)
    return data


def credit_of(info):
    """A one-line credit for the tip: the artist (or a short credit line), else "Wikimedia Commons", then the
    licence. Commons' own `Credit` field is sometimes a paragraph; anything over 100 characters is not a credit."""
    who = (info.get("artist") or "").strip()
    if not who or len(who) > 100:
        who = (info.get("credit_text") or "").strip()
    if not who or len(who) > 100:
        who = "Wikimedia Commons"
    return ", ".join(x for x in (who, info.get("license")) if x)


def _keyword_graphic(*texts):
    return any(_GRAPHIC_WORDS.search(t or "") for t in texts)


def pick_photos(title, screen, *, potd=None, limit=MAX_IMAGES, log=lambda m: None):
    """The photographs of a Wikipedia article, bytes downloaded, best first.

    `screen(caption, description) -> p | None` is the graphic-content question (None: nobody could answer, the
    keyword net alone has run). `potd` is the day's picture ({fileTitle, file, thumb, credit, license,
    description}, files under the state dir) and leads when the article names that file.
    -> {photos: [{potd: the potd dict | None, data (bytes), file_title, credit, license}], graphic: n dropped as
        graphic, considered: n files that passed type and size}"""
    out = {"photos": [], "graphic": 0, "considered": 0}
    try:
        media = wikipedia.media_list(title)
    except http.NetError as e:
        log("media list of %s: %s" % (title, e))
        return out
    named = {_norm_file(m["title"]): m for m in media}
    pot = None
    if potd and potd.get("fileTitle") and _norm_file(potd["fileTitle"]) in named:
        pot = potd
    wanted = [m for m in media if m["ext"] in PHOTO_EXT and not _NOT_A_PICTURE.search(m["title"])]
    wanted.sort(key=lambda m: not m["lead"])                                   # stable: page order after the lead
    if pot:
        wanted = [m for m in wanted if _norm_file(m["title"]) != _norm_file(pot["fileTitle"])]
    wanted = wanted[:INFO_BATCH]
    infos = {}
    if wanted:
        try:
            infos = wikipedia.image_info([m["title"] for m in wanted])
        except http.NetError as e:
            log("imageinfo of %s: %s" % (title, e))
    if pot:
        out["photos"].append({"potd": pot})
    for m in wanted:
        if len(out["photos"]) >= limit:
            break
        info = infos.get(m["title"])
        if not info or info.get("mime") not in PHOTO_MIMES:
            continue
        w, h = info.get("width") or 0, info.get("height") or 0
        first = not out["photos"]
        if w < (MIN_WIDTH if first else MIN_WIDTH_LATER) or h <= 0 or w / h > MAX_STRIP or h / w > MAX_STRIP:
            continue
        out["considered"] += 1
        caption, desc = m.get("caption", ""), (info.get("description") or "")[:600]
        if _keyword_graphic(caption, desc, m["title"]):
            out["graphic"] += 1
            continue
        p = screen(caption, desc)
        if p is not None and p >= GRAPHIC_P:
            out["graphic"] += 1
            continue
        try:
            data = _dl(info["thumb_url"] or info["url"])
        except http.NetError as e:
            log("image %s: %s" % (m["title"], e))
            continue
        out["photos"].append({"potd": None, "data": data, "file_title": m["title"],
                              "credit": credit_of(info), "license": info.get("license", "")})
    return out
