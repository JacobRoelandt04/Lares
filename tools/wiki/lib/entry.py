"""The entry record (CONTRACT.md "Entry (v: 1)"): a factory, a validator, and atomic load/save.

An entry is immutable once written: save() refuses to replace one unless told to, because a card the
user has already seen must not change under them (the rabbit hole's cache under live/ is the exception
and passes overwrite=True). validate() is the gate every writer passes; the QML side trusts what it
lets through.
"""
import copy
import json
import os
import time

from . import atomic, paths

VERSION = 1
TABS = paths.TABS
KINDS = ("article", "tips", "potd")
PROVENANCE = ("original", "cleaned", "generated")
VIA = ("thompson", "guest", "installed", "discovery", "tips", "other", "daily", "follow")
QUALITY = ("good", "featured", None)
IMAGE_KINDS = ("photo", "relief", "glyph")
IMAGE_SRC = ("page", "potd", "logo")
# the closed set of intro.stripped codes (WikiCardModel.markTips maps them to words)
STRIPPED = ("pronunciation", "ipa", "native_names", "dates", "coordinates", "citations", "hatnote",
            "parentheticals", "notes")
_NESTED = ("source", "category", "intro", "popularity")


def u16len(s):
    """Length of `s` in UTF-16 code units: what a JavaScript string index counts."""
    return len(s.encode("utf-16-le")) // 2


def default_id(host, title, fragment=None):
    """`en.wikipedia.org/Battle_of_Hastings` (underscores; `#Fragment` for a section entry)."""
    ident = f"{host}/{title.replace(' ', '_')}"
    return ident + ("#" + fragment.replace(" ", "_") if fragment else "")


def new_entry(**fields):
    """A complete entry with every contract key present. Nested objects (source, category, intro,
    popularity) are merged over their defaults; other fields replace. `id` is derived from
    source.host + source.title when not given, `intro.words` from the text, `fetchedAt` is now."""
    e = {
        "v": VERSION, "id": None, "tab": None, "kind": "article",
        "source": {"wiki": None, "host": None, "title": None, "url": None, "revid": None,
                   "license": None, "quality": None},
        "title": None,
        "category": {"family": None, "topic": None, "via": None, "why": None},
        "intro": {"text": "", "words": 0, "provenance": "original", "stripped": [], "model": None,
                  "grounded": None, "locator": None, "links": []},
        "images": [], "installed": None,
        "popularity": {"views60d": None, "band": None},
        "judge": {}, "batch": None, "fetchedAt": None,
    }
    for k, v in fields.items():
        if k not in e:
            raise KeyError(f"unknown entry field {k!r}")
        if k in _NESTED and isinstance(v, dict):
            e[k].update(copy.deepcopy(v))
        else:
            e[k] = copy.deepcopy(v)
    intro = e["intro"]
    if "words" not in (fields.get("intro") or {}):
        intro["words"] = len(intro["text"].split())
    src = e["source"]
    if e["id"] is None and src.get("host") and src.get("title"):
        e["id"] = default_id(src["host"], src["title"])
    if e["title"] is None:
        e["title"] = src.get("title")
    if e["fetchedAt"] is None:
        e["fetchedAt"] = int(time.time() * 1000)
    return e


def _isint(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _isnum(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def validate(e, check_files=False, base_dir=None):
    """A list of human-readable errors; empty means valid. With check_files every image's `file` and
    `thumb` must exist relative to base_dir (default: the state directory)."""
    errs = []

    def need(cond, msg):
        if not cond:
            errs.append(msg)
        return cond

    if not need(isinstance(e, dict), "entry is not an object"):
        return errs
    need(e.get("v") == VERSION, f"v must be {VERSION}, is {e.get('v')!r}")
    need(isinstance(e.get("id"), str) and e.get("id"), "id must be a non-empty string")
    need(e.get("tab") in TABS, f"tab must be one of {TABS}, is {e.get('tab')!r}")
    need(e.get("kind") in KINDS, f"kind must be one of {KINDS}, is {e.get('kind')!r}")
    need(isinstance(e.get("title"), str) and e.get("title"), "title must be a non-empty string")
    need(_isint(e.get("fetchedAt")), "fetchedAt must be an integer (epoch ms)")
    need(e.get("batch") is None or isinstance(e.get("batch"), str), "batch must be a string or null")

    src = e.get("source")
    if need(isinstance(src, dict), "source must be an object"):
        for k in ("wiki", "host", "title", "url"):
            need(isinstance(src.get(k), str) and src.get(k), f"source.{k} must be a non-empty string")
        need(src.get("revid") is None or _isint(src.get("revid")), "source.revid must be an integer or null")
        need(src.get("license") is None or isinstance(src.get("license"), str),
             "source.license must be a string or null")
        need(src.get("quality") in QUALITY, f"source.quality must be good, featured or null, is "
                                            f"{src.get('quality')!r}")

    cat = e.get("category")
    if need(isinstance(cat, dict), "category must be an object"):
        need(isinstance(cat.get("family"), str) and cat.get("family"), "category.family must be a string")
        need(cat.get("topic") is None or isinstance(cat.get("topic"), str),
             "category.topic must be a string or null")
        need(cat.get("via") in VIA, f"category.via must be one of {VIA}, is {cat.get('via')!r}")
        need(cat.get("why") is None or isinstance(cat.get("why"), dict), "category.why must be an object or null")

    intro = e.get("intro")
    if need(isinstance(intro, dict), "intro must be an object"):
        text = intro.get("text")
        if need(isinstance(text, str) and text.strip(), "intro.text must be a non-empty string"):
            n16 = u16len(text)
            need(intro.get("provenance") in PROVENANCE,
                 f"intro.provenance must be one of {PROVENANCE}, is {intro.get('provenance')!r}")
            need(_isint(intro.get("words")) and intro["words"] >= 0, "intro.words must be a non-negative integer")
            st = intro.get("stripped")
            if need(isinstance(st, list), "intro.stripped must be a list"):
                bad = [c for c in st if c not in STRIPPED]
                need(not bad, f"intro.stripped has codes outside the closed set: {bad}")
            need(intro.get("model") is None or isinstance(intro.get("model"), str),
                 "intro.model must be a string or null")
            need(intro.get("grounded") in (True, False, None), "intro.grounded must be true, false or null")
            if intro.get("provenance") == "generated":
                need(isinstance(intro.get("model"), str) and intro.get("model"),
                     "a generated intro must name its model")
            if intro.get("provenance") != "generated":
                need(intro.get("model") is None and intro.get("grounded") is None,
                     "model/grounded belong to generated intros only")
            links = intro.get("links")
            if need(isinstance(links, list), "intro.links must be a list"):
                prev_end = 0
                for i, ln in enumerate(links):
                    w = f"intro.links[{i}]"
                    if not need(isinstance(ln, dict), f"{w} must be an object"):
                        continue
                    s, en = ln.get("s"), ln.get("e")
                    if need(_isint(s) and _isint(en), f"{w}: s and e must be integers"):
                        need(0 <= s < en <= n16, f"{w}: [{s},{en}) is outside the text (0..{n16} UTF-16 units)")
                        need(s >= prev_end, f"{w}: overlaps or precedes the previous link")
                        prev_end = max(prev_end, en)
                    need(isinstance(ln.get("target"), str) and ln.get("target"), f"{w}: target must be a string")
                    need(isinstance(ln.get("url"), str) and ln.get("url"), f"{w}: url must be a string")
                    need(isinstance(ln.get("wiki"), str) and ln.get("wiki"), f"{w}: wiki must be a string")

    imgs = e.get("images")
    if need(isinstance(imgs, list), "images must be a list"):
        base = base_dir or paths.state_dir()
        for i, im in enumerate(imgs):
            w = f"images[{i}]"
            if not need(isinstance(im, dict), f"{w} must be an object"):
                continue
            kind = im.get("kind")
            need(kind in IMAGE_KINDS, f"{w}.kind must be one of {IMAGE_KINDS}, is {kind!r}")
            need(im.get("src") in IMAGE_SRC + (None,), f"{w}.src must be one of {IMAGE_SRC}")
            if kind == "glyph":
                need(not im.get("file"), f"{w}: a glyph image has no file (it stands for \"no picture\": the card draws the article's veil)")
            elif kind in ("photo", "relief"):
                for k in ("file", "thumb"):
                    if need(isinstance(im.get(k), str) and im.get(k), f"{w}.{k} must be a path string"):
                        need(not os.path.isabs(im[k]) and ".." not in im[k].split("/"),
                             f"{w}.{k} must be relative to the state dir")
                        if check_files:
                            need(os.path.isfile(os.path.join(base, im[k])), f"{w}.{k}: {im[k]} does not exist")
                need(_isint(im.get("w")) and im["w"] > 0 and _isint(im.get("h")) and im["h"] > 0,
                     f"{w}: w and h must be positive integers")
            asp = im.get("aspect")
            need(asp is None or (_isnum(asp) and asp > 0), f"{w}.aspect must be a positive number")
            fy = im.get("focusY")
            need(fy is None or (_isnum(fy) and 0 <= fy <= 1), f"{w}.focusY must be within 0..1")
            for k in ("credit", "license", "fileTitle"):
                need(im.get(k) is None or isinstance(im.get(k), str), f"{w}.{k} must be a string or null")

    inst = e.get("installed")
    need(inst is None or (isinstance(inst, dict) and isinstance(inst.get("flag"), bool)),
         "installed must be null or {flag: bool, pkg, unit, asOf}")
    pop = e.get("popularity")
    if need(pop is None or isinstance(pop, dict), "popularity must be an object"):
        if pop:
            need(pop.get("views60d") is None or (_isint(pop["views60d"]) and pop["views60d"] >= 0),
                 "popularity.views60d must be a non-negative integer or null")
            need(pop.get("band") is None or (_isnum(pop["band"]) and 0 <= pop["band"] <= 1),
                 "popularity.band must be within 0..1 or null")
    need(e.get("judge") is None or isinstance(e.get("judge"), dict), "judge must be an object")
    return errs


class EntryExists(Exception):
    pass


class Invalid(ValueError):
    def __init__(self, errors):
        super().__init__("invalid entry: " + "; ".join(errors))
        self.errors = errors


def load(path):
    """The entry stored at `path` (see paths.entry_path for where the tool keeps them)."""
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save(e, path=None, *, overwrite=False, check_files=True):
    """Validate, then write atomically. The default path is entries/<tab>/<slug>.json. Raises Invalid,
    or EntryExists when the file is there and `overwrite` is False."""
    errs = validate(e, check_files=check_files)
    if errs:
        raise Invalid(errs)
    p = path or paths.entry_path(e["tab"], e["id"])
    if os.path.exists(p) and not overwrite:
        raise EntryExists(p)
    atomic.write_json(p, e)
    return p
