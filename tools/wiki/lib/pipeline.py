"""One plan item -> one entry: fetch, intro, images, entry; and the rabbit hole (`load`).

    Ctx(...)                      everything one batch shares: the rng, the known ids, the judges, the GPU session
    process_item(ctx, i, n, item) -> {"status": "done" | "skip" | "fail", ...}     the batch loop calls it
    load(url, tab, allow_generate, ctx)   -> exit code                              `wiki.py load`

The steps of an item (each one an `item` event for the progress notification):
    candidates  candidates.gather: up to eight fresh pages for the family
    score       popularity (Wikipedia's pageviews), Jev's interest question (one request for all the candidates), then
                the SHARED weighted pick
    fetch       the page's lead (or the section / document), paragraphs, the deterministic cleanup
    intro       Wikipedia: the lead IS the intro (cleanup, then a cut at 80-150 words on a sentence end).
                Everything else: the judge names the paragraph and rates it (locate.choose_intro); a page
                without an acceptable one gets a model-written intro that the judge finds grounded in it.
    images      Wikipedia: photographs; Deepen: the Wikidata logo as a relief, else the family glyph
    write       validate, save atomically, add the index row
A pick that cannot become an entry (no lead, too short, a GPU that is not there) falls to the next candidate, up to
MAX_TRIES; only when all fail is the ITEM skipped: an item settles exactly once (done, skip or fail), which is what
the service counts.

The GPU is taken lazily and only for a LOCAL model (the fallback judge, the writer): `GpuSession.ensure` asks
gpu.guard the first time, latches a refusal for the rest of the batch (one `blocked` event, every item that needs
the card then skips with `gpu-busy` while the ones that do not carry on), and gives the card back at the end.

Jev is used while it answers. The first JudgeUnavailable (network, no key, a spent budget) turns it off for the
rest of the batch with one `warn` event, and the local judge takes over the locator; interest falls to 0.5 and
the graphic screen to the keyword net alone.
"""
import json
import os
import random
import re
import time

from . import (atomic, candidates, cleanup, daily, entry as entrylib, env, generate, gpu, htmltext, http, images, index,
               installed, intro, judge, judge_ollama, locate, logos, mw, paths, title as titlelib)
from .judge import Budget, JudgeError, JudgeUnavailable
from .sources import arch, freedesktop, gentoo, kernel_docs, wikipedia

MAX_TRIES = 4
MIN_WIKIPEDIA_WORDS = 50
MAX_PARAS = 40
MAX_WORDS = 6000
PROSE_WORDS = 15
LIVE_CAP = 50
JEV_CAP_USD = 0.04
LICENSES = {"wikipedia": "CC BY-SA 4.0", "arch": "GFDL 1.3 or later", "gentoo": "CC BY-SA 4.0", "kernel": None,
            "freedesktop": None}
WIKI_OF_HOST = {"en.wikipedia.org": "wikipedia", "wiki.archlinux.org": "arch", "wiki.gentoo.org": "gentoo",
                "docs.kernel.org": "kernel", "specifications.freedesktop.org": "freedesktop"}
VIA_DEEPEN = {"arch-installed": "installed", "arch-discovery": "discovery", "arch-tips": "tips",
              "other-wikis": "other"}


class Skip(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


class Blocked(Exception):
    """A local model is needed and the card cannot give it (busy, spilling, no GPU, Ollama down)."""


# ----------------------------------------------------------------------------- the GPU

class GpuSession:
    """One local model at a time on the card, taken through gpu.guard, never spilled, given back at the end."""

    def __init__(self, url, emit, log):
        self.url = url
        self.emit = emit
        self.log = log
        self.model = None                   # the model this session has resident
        self.blocked = None                 # the guard's refusal, latched

    def ensure(self, model):
        if self.blocked:
            return False
        if self.model and gpu.same_model(self.model, model):
            return True
        if self.model:                      # another model of ours: give the card back before the next one
            gpu.unload(self.model, self.url)
            self.model = None
        r = gpu.guard(model, self.url)
        self.emit({"ev": "gpu", "state": "free" if r["ok"] else "busy", "models": r.get("others") or [],
                   "freeMiB": r.get("freeMiB")})
        if r["ok"]:
            self.model = model
            return True
        self.block(r["reason"], r.get("others") or [], r.get("detail", ""))
        return False

    def block(self, reason, models=(), detail=""):
        if self.blocked:
            return
        self.blocked = {"reason": reason, "models": list(models)}
        self.log("GPU not available (%s): %s" % (reason, detail))
        self.emit({"ev": "blocked", "reason": reason, "models": list(models)})

    def close(self):
        if self.model:
            gpu.unload(self.model, self.url)
            self.model = None


# ----------------------------------------------------------------------------- the context

def _sources(payload_sources):
    base = dict(candidates_default_sources())
    raw = os.environ.get("WIKI_SOURCES")
    for src in (raw, payload_sources):
        if not src:
            continue
        try:
            d = src if isinstance(src, dict) else json.loads(src)
        except ValueError:
            continue
        if isinstance(d, dict):
            base.update({k: bool(v) for k, v in d.items() if k in base})
    return base


def models():
    """models.json with the user's own writer and local judge (wiki.jsonc `models`, handed in as WIKI_MODEL_WRITE / WIKI_MODEL_JUDGE;
    unset or "" = the file's). The judge is the local one that locates an intro once Jev is out (`locate.fallback`); a judge the
    file has no thresholds for takes its "default" set (locate.thresholds_for)."""
    m = dict(judge.models())
    write = os.environ.get("WIKI_MODEL_WRITE", "").strip()
    local = os.environ.get("WIKI_MODEL_JUDGE", "").strip()
    if write:
        m["write"] = dict(m.get("write") or {}, model=write)
    if local:
        m["locate"] = dict(m.get("locate") or {}, fallback="ollama:" + local)
    return m


def candidates_default_sources():
    return {"wikipedia": True, "arch": True, "archTips": True, "gentoo": True, "kernel": True, "freedesktop": True}


def _known_ids():
    ids = set(index.ids())
    st = atomic.read_json(paths.state_path(), {}) or {}
    if isinstance(st.get("seen"), dict):
        ids.update(k for k in st["seen"] if isinstance(k, str))
    return ids


def new_seed():
    """The batch's seed: WIKI_SEED when a probe sets it, else a fresh number. It is written to the progress file so
    that a resumed batch keeps drawing what an uninterrupted one would have."""
    raw = os.environ.get("WIKI_SEED")
    try:
        return int(raw) if raw not in (None, "") else random.SystemRandom().getrandbits(48)
    except ValueError:
        return random.SystemRandom().getrandbits(48)


class Ctx:
    def __init__(self, tab, batch_id, *, emit, log, seed=None, sources=None, recent=(), jev=None, ollama_url=None):
        self.tab = tab
        self.batch_id = batch_id
        self.emit = emit
        self.log = log
        self.seed = new_seed() if seed is None else int(seed)
        self.rng = random.Random(self.seed)
        self.sources = _sources(sources)
        self.recent = [str(t) for t in (recent or ())][-10:]
        self.fam = paths.families()
        self.models = models()
        self.ollama_url = ollama_url or os.environ.get("WIKI_OLLAMA_URL") or judge.DEFAULT_OLLAMA_URL
        self.known = _known_ids()
        self.cache = {}
        self.warned = set()
        self._snap = None
        self._jev = None
        self._jev_ok = (os.environ.get("WIKI_JEV", "1") != "0") if jev is None else bool(jev)
        self._quiet_jev = not self._jev_ok
        cap = os.environ.get("WIKI_JEV_CAP_USD")
        try:
            cap = float(cap) if cap else JEV_CAP_USD
        except ValueError:
            cap = JEV_CAP_USD
        self.budget = Budget(cap, "batch")
        self.gpu = GpuSession(self.ollama_url, emit, log)
        self.day = os.environ.get("WIKI_TODAY") or time.strftime("%Y-%m-%d", time.gmtime())
        self._potd = False

    # ---- installed software, read once per batch
    def snapshot(self):
        if self._snap is None:
            self._snap = installed.snapshot()
        return self._snap

    # ---- Jev
    @property
    def jev_up(self):
        return self._jev_ok

    def _jev_judge(self):
        if self._jev is None:
            self._jev = judge.make("jev", budget=self.budget, mode=(self.models.get("locate") or {}).get("jevMode")
                                   or "twopass")
        return self._jev

    def _jev_down(self, exc):
        self._jev_ok = False
        if self._quiet_jev:
            return
        code = "jev-budget" if getattr(exc, "reason", "") == "jev-budget" else "jev-unavailable"
        if code not in self.warned:
            self.warned.add(code)
            self.log("Jev is off for this batch (%s): %s" % (code, exc))
            self.emit({"ev": "warn", "code": code, "fallback": "ollama"})

    def via_jev(self, fn, default=None):
        """fn(jev judge) while Jev answers; `default` once it does not (one warn) or when its answer cannot be read."""
        if not self._jev_ok:
            return default
        try:
            return fn(self._jev_judge())
        except JudgeUnavailable as e:
            self._jev_down(e)
        except JudgeError as e:
            self.log("Jev answered badly (%s): %s" % (e.reason, e))
        return default

    def jev_usage(self):
        b = self.budget
        return {"tokens": b.tokens_in + b.tokens_out, "calls": b.calls}

    # ---- the questions the pipeline asks
    def interest_many(self, cands):
        """[0..1 | None] per candidate: Jev's answer to ONE request about the whole list (candidates.N_CANDIDATES of
        them share a state and pay the request's framing once), None for each when Jev is off."""
        got = self.via_jev(lambda j: j.interest_many([(c["label"], c.get("extract") or "") for c in cands],
                                                     self.recent))
        return got if got is not None else [None] * len(cands)

    def screen(self, caption, description):
        """p that an image is graphic: Jev's, else the resident local model's, else None (the keyword net only)."""
        p = self.via_jev(lambda j: j.graphic(caption, description))
        if p is not None or self._jev_ok or not self.gpu.model:
            return p
        try:
            return judge_ollama.OllamaJudge(self.gpu.model, url=self.ollama_url).graphic(caption, description)
        except JudgeError:
            return None

    def potd(self):
        """Today's picture of the day (a daily.py dict), fetched once per batch when it is not cached."""
        if self._potd is False:
            self._potd = None
            try:
                d = daily.cached(self.day) or daily.build(self.day, deny=self.fam["guest"]["deny"], log=self.log,
                                                          shorten=self._title_chat())
                self._potd = d.get("potd")
            except (http.NetError, mw.MwError, ValueError, KeyError, OSError) as e:
                self.log("picture of the day: %s" % e)
        return self._potd

    def _title_chat(self):
        """The chat of title.short_title on the model this session already has on the card (never one it would take
        the card for: a title is not worth a load), or None."""
        if not self.gpu.model or self.gpu.blocked:
            return None
        return titlelib.ollama_chat(self.gpu.model, self.ollama_url)

    def for_item(self, i):
        """Every plan item draws from a generator of its own (seed, position): what item 5 chooses does not depend on
        how many draws items 1-4 made, so a batch resumed after a kill chooses what an uninterrupted one would."""
        self.rng = random.Random("%d:%d" % (self.seed, i))

    def close(self):
        self.gpu.close()

    # ---- intro: a located original, else a written one
    def locate_intro(self, page):
        """locate.choose_intro with Jev, or with the local fallback judge once Jev is out. Raises Blocked when
        the card is needed and not there."""
        while True:
            if self._jev_ok:
                j = self._jev_judge()
                try:
                    return locate.choose_intro(page, j, locate.thresholds_for(self.models, j.name)), j.name
                except JudgeUnavailable as e:
                    self._jev_down(e)
                    continue
            spec = (self.models.get("locate") or {}).get("fallback") or "ollama:" + self.models["write"]["model"]
            model = spec.split(":", 1)[1]
            if not self.gpu.ensure(model):
                raise Blocked()
            j = judge.make(spec, ollama_url=self.ollama_url)
            try:
                return locate.choose_intro(page, j, locate.thresholds_for(self.models, j.name)), j.name
            except JudgeUnavailable as e:
                self.gpu.block(e.reason, (), str(e))
                raise Blocked() from None

    def write_intro(self, page):
        """A model-written intro and the judge's verdict on it -> (writer result, {accepted, grounded, reason}, name of
        the grounding judge). Raises Blocked when the card is needed and not there."""
        model = self.models["write"]["model"]
        if not self.gpu.ensure(model):
            raise Blocked()
        try:
            result = generate.write_intro(page, model, self.ollama_url)
        except JudgeUnavailable as e:
            self.gpu.block(e.reason, (), str(e))
            raise Blocked() from None
        gmin = self.models["write"].get("groundedMin")
        for _ in range(2):
            if self._jev_ok:
                j, gname = self._jev_judge(), "jev-1.13"
            else:
                j, gname = judge.make("ollama:" + model, ollama_url=self.ollama_url), model
            try:
                return result, generate.accept(page, result, j, gmin), gname
            except JudgeUnavailable as e:
                if j is self._jev:
                    self._jev_down(e)
                    continue
                self.gpu.block(e.reason, (), str(e))
                raise Blocked() from None
            except JudgeError as e:
                self.log("grounding could not be judged: %s" % e)
                return result, {"accepted": False, "grounded": None, "reason": "judge-error"}, gname
        return result, {"accepted": False, "grounded": None, "reason": "judge-error"}, "jev-1.13"


# ----------------------------------------------------------------------------- pages -> paragraphs

def _has_prose(paras):
    return any(p["kind"] in ("p", "dd") and intro.words(p["text"]) >= PROSE_WORDS for p in paras)


def _limit(paras):
    kept, words = [], 0
    for p in paras:
        w = intro.words(p["text"])
        if len(kept) >= MAX_PARAS or (kept and words + w > MAX_WORDS):
            break
        kept.append(p)
        words += w
    return kept


def _title_of_html(html, fallback):
    m = re.search(r"<title>\s*(.*?)\s*</title>", html, re.S | re.I)
    return mw.strip_html(m.group(1)) if m else fallback


def fetch_page(cand, person=None):
    """The candidate's page as text -> {paras (cleaned), codes, title, revid, url, license}. `person` tells the cleanup
    whether the article is about one (a life span in the parenthesis goes; True for the People family, else unknown).
    Raises Skip("no-lead") for a page that is not there."""
    wiki, title = cand["wiki"], cand["title"]
    try:
        if wiki == "wikipedia":
            r = wikipedia.lead_html(title)
            raw = htmltext.paragraphs(r["html"], "wikipedia", r["url"])
        elif wiki in ("arch", "gentoo"):
            lead = arch.lead_html if wiki == "arch" else gentoo.lead_html
            if cand.get("section"):
                r = arch.section_html(title, cand["section"])
                r["url"] = mw.page_url(arch.HOST, title, cand["fragment"])
                raw = htmltext.paragraphs(r["html"], "arch", r["url"])
            else:
                r = lead(title)
                raw = htmltext.paragraphs(r["html"], wiki, r["url"])
                if wiki == "arch" and not _has_prose(cleanup.clean(raw, "arch")[0]):
                    r1 = arch.section_html(title, "1")           # a hardware page: the article starts in section 1
                    raw = raw + htmltext.paragraphs(r1["html"], "arch", r["url"])
        elif wiki == "kernel":
            html = kernel_docs.page_html(cand["docname"])
            raw = htmltext.paragraphs(html, "kernel", cand["url"])
            heading = next((p["text"] for p in raw if p["kind"] == "heading" and p["text"].strip()), None)
            r = {"title": cand["label"] if cand["label"] != cand["docname"] else (heading or cand["docname"]),
                 "revid": None, "url": cand["url"]}
        else:
            html = freedesktop.page_html(cand["spec"])
            r = {"title": _title_of_html(html, cand["label"]), "revid": None, "url": cand["url"]}
            raw = htmltext.paragraphs(html, "freedesktop", cand["url"])
    except mw.MwError as e:
        raise Skip("no-lead") from e
    except http.Offline:
        raise
    except http.NetError as e:
        raise Skip("no-lead") from e
    cleaned, codes = cleanup.clean(raw, wiki, person=person)
    return {"paras": _limit(cleaned), "codes": codes, "title": r["title"], "revid": r.get("revid"),
            "url": r["url"], "license": LICENSES.get(wiki)}


def judge_page(cand, fetched):
    return {"id": cand["id"], "wiki": cand["wiki"], "title": fetched["title"], "url": fetched["url"], "stratum": "",
            "paras": fetched["paras"], "numbered": intro.numbered(fetched["paras"])}


def _intro_from(paragraphs):
    text, links, words = intro.join(paragraphs)
    codes = intro.stripped_codes(paragraphs)
    return {"text": text, "words": words, "provenance": "cleaned" if codes else "original", "stripped": codes,
            "model": None, "grounded": None, "locator": None, "links": links}


def build_intro(ctx, item, cand, fetched):
    """-> (intro dict, lead judgement {ok, score}). Skip("too-short" | "no-lead") or Blocked."""
    if cand["wiki"] == "wikipedia":
        picked, words = intro.cut(fetched["paras"], 80, 150, sentence_fill=True)
        if not picked:
            raise Skip("no-lead")
        if words < MIN_WIKIPEDIA_WORDS:
            raise Skip("too-short")
        return _intro_from(picked), {"ok": True, "score": None}
    page = judge_page(cand, fetched)
    if not page["paras"]:
        raise Skip("no-lead")
    res, jname = ctx.locate_intro(page)
    if res.get("paras") is not None:
        d = _intro_from(res["paragraphs"])
        d["locator"] = res["locator"]
        return d, {"ok": True, "score": (res["locator"] or {}).get("score")}
    ctx.log("%s: the locator found no intro (%s); the writer takes over" % (cand["id"], res.get("reason")))
    result, verdict, gname = ctx.write_intro(page)
    if not verdict["accepted"]:
        ctx.log("%s: the written intro was refused (%s)" % (cand["id"], verdict["reason"]))
        raise Skip("no-lead")
    text = result["text"]
    d = {"text": text, "words": intro.words(text), "provenance": "generated", "stripped": [],
         "model": "%s+%s" % (gname, ctx.models["write"]["model"]) if gname == "jev-1.13" else ctx.models["write"]["model"],
         "grounded": True, "locator": None, "links": []}
    return d, {"ok": True, "score": verdict["grounded"]}


# ----------------------------------------------------------------------------- images

def glyph_image(family):
    return {"kind": "glyph", "glyphFamily": family, "aspect": 1.0, "focusY": 0.5, "credit": "", "license": "",
            "src": None}


def _logo_titles(cand):
    wiki = cand["wiki"]
    if wiki == "kernel":
        return ["Linux kernel"]
    if wiki == "freedesktop":
        return ["Freedesktop.org"]
    base = cand.get("base") or cand["title"].split("/")[0]
    out = [base]
    pkg = (cand.get("installed") or {}).get("pkg")
    if pkg and pkg.lower() != base.lower():
        out.append(pkg[:1].upper() + pkg[1:])
    return out


def _logo_image(ctx, cand, slug):
    memo = ctx.cache.setdefault("logos", {})
    logo = logos.find(_logo_titles(cand), qid=cand.get("wikibase_item"), log=ctx.log,
                      software_only=cand["wiki"] in ("arch", "gentoo"))
    if not logo:
        return None
    key = logo.get("file")
    if key in memo:
        rel = "img/%s-logo.png" % slug
        with open(os.path.join(paths.state_dir(), memo[key]["file"]), "rb") as f:
            atomic.write_bytes(os.path.join(paths.state_dir(), rel), f.read())
        return dict(memo[key], file=rel, thumb=rel)
    im = logos.bake(logo, slug, log=ctx.log)
    if im:
        memo[key] = im
    return im


def build_images(ctx, item, cand, slug):
    """-> (list of image records, list of files written to clean up on failure)"""
    fam = item["family"]
    written = []
    out = []
    if ctx.tab == "deepen" and cand["wiki"] != "wikipedia" or fam == "wikipedia-cs":
        logo = _logo_image(ctx, cand, slug)
        if logo:
            out.append(logo)
            written.append(logo["file"])
    if not out and cand["wiki"] == "wikipedia":
        got = images.pick_photos(cand["title"], ctx.screen, potd=ctx.potd(), log=ctx.log)
        for n, ph in enumerate(got["photos"]):
            try:
                if ph["potd"]:
                    im = images.copy_potd(ph["potd"], slug, n)
                else:
                    im = images.save_photo(ph["data"], slug, n, credit=ph["credit"], license_=ph["license"],
                                           src="page", file_title=ph["file_title"])
            except (OSError, ValueError) as e:
                ctx.log("image %d of %s: %s" % (n, cand["id"], e))
                continue
            out.append(im)
            written += [im["file"], im["thumb"]]
    if not out:
        out.append(glyph_image(fam))
    return out, written


# ----------------------------------------------------------------------------- the entry

def _category(ctx, item, cand):
    fam = item["family"]
    why = item.get("why") or {}
    if ctx.tab == "discover":
        via = "guest" if fam == ctx.fam["guest"]["id"] else (why.get("via") or "thompson")
        if via not in entrylib.VIA:
            via = "thompson"
    else:
        via = VIA_DEEPEN.get(fam) or (why.get("via") if why.get("via") in entrylib.VIA else "thompson")
    topic = item.get("topic") or cand.get("topic_source") or None
    return {"family": fam, "topic": topic, "via": via,
            "why": {"p": why.get("p"), "oneIn": why.get("oneIn"), "openRate": why.get("openRate")} if why else None}


def build_entry(ctx, item, cand, fetched, intro_d, lead_j, imgs, rank_info):
    inst = cand.get("installed")
    return entrylib.new_entry(
        id=cand["id"], tab=ctx.tab, kind=cand["kind"],
        source={"wiki": cand["wiki"], "host": cand["host"], "title": (cand.get("base") or fetched["title"]),
                "url": fetched["url"] if cand["wiki"] != "wikipedia" else (cand.get("url") or fetched["url"]),
                "revid": fetched["revid"] or cand.get("revid"), "license": fetched["license"],
                "quality": cand.get("quality")},
        title=cand["label"] if cand["wiki"] != "wikipedia" else fetched["title"],
        category=_category(ctx, item, cand), intro=intro_d, images=imgs,
        installed=({"flag": inst["flag"], "pkg": inst.get("pkg"), "unit": inst.get("unit"), "asOf": inst["asOf"]}
                   if inst else None),
        popularity={"views60d": cand.get("views"), "band": (round(cand["band"], 3)
                                                             if isinstance(cand.get("band"), float) else None)},
        judge={"engage": {"judge": "jev" if ctx.jev_up or ctx.budget.calls else "none", "score": round(cand["interest"], 3),
                          "pickedRank": rank_info["rank"], "of": rank_info["of"]},
               "lead": lead_j},
        batch=ctx.batch_id)


def _cleanup_files(rels):
    for rel in rels:
        try:
            os.unlink(os.path.join(paths.state_dir(), rel))
        except OSError:
            pass


def build_candidate(ctx, i, n, item, cand, rank_info):
    """One pick -> the saved entry's result dict, or Skip / Blocked."""
    ctx.emit({"ev": "item", "i": i, "n": n, "stage": "fetch", "title": cand["label"]})
    if cand["id"] in ctx.known:
        raise Skip("duplicate")
    if cand.get("quality_unknown"):
        try:
            cand["quality"] = wikipedia.quality_of(cand["title"])
        except (http.NetError, mw.MwError):
            cand["quality"] = None
    fetched = fetch_page(cand, person=True if item["family"] == "people" else None)
    ctx.emit({"ev": "item", "i": i, "n": n, "stage": "intro", "title": cand["label"]})
    intro_d, lead_j = build_intro(ctx, item, cand, fetched)
    ctx.emit({"ev": "item", "i": i, "n": n, "stage": "images", "title": cand["label"]})
    slug = paths.slug(cand["id"])
    imgs, written = build_images(ctx, item, cand, slug)
    ctx.emit({"ev": "item", "i": i, "n": n, "stage": "write", "title": cand["label"]})
    e = build_entry(ctx, item, cand, fetched, intro_d, lead_j, imgs, rank_info)
    try:
        entrylib.save(e)
    except entrylib.EntryExists:
        _cleanup_files(written)
        raise Skip("duplicate") from None
    except entrylib.Invalid:
        _cleanup_files(written)
        raise
    row = {"id": e["id"], "slug": slug, "family": e["category"]["family"], "topic": e["category"]["topic"],
           "kind": e["kind"], "fetchedAt": e["fetchedAt"], "popularityBand": e["popularity"]["band"],
           "jevScore": e["judge"]["engage"]["score"]}
    index.add_rows(ctx.tab, [row])
    ctx.known.add(e["id"])
    return {"status": "done", "id": e["id"], "row": row, "generated": e["intro"]["provenance"] == "generated"}


def process_item(ctx, i, n, item):
    """One plan item -> {"status": "done", id, row, generated} | {"status": "skip", reason, family}."""
    fam = item.get("family") or ""
    ctx.for_item(i)
    ctx.emit({"ev": "item", "i": i, "n": n, "stage": "candidates", "title": ""})
    cands = candidates.gather(item, ctx)
    if not cands:
        return {"status": "skip", "reason": "no-candidates" if candidates.source_on(fam, ctx.tab, ctx.sources)
                else "source-off", "family": fam}
    ctx.emit({"ev": "item", "i": i, "n": n, "stage": "score", "title": ""})
    ranked = candidates.rank(cands, item, ctx, ctx.interest_many)
    order = sorted(range(len(ranked)), key=lambda k: -ranked[k]["score"])
    rank_of = {id(ranked[k]): pos + 1 for pos, k in enumerate(order)}
    remaining = list(ranked)
    last = "no-lead"
    for _ in range(MAX_TRIES):
        if not remaining:
            break
        k = candidates.weighted_pick([c["score"] for c in remaining], ctx.rng.random())
        cand = remaining.pop(k)
        try:
            return build_candidate(ctx, i, n, item, cand, {"rank": rank_of[id(cand)], "of": len(ranked)})
        except Skip as s:
            last = s.reason
        except Blocked:
            last = "gpu-busy"
    return {"status": "skip", "reason": last, "family": fam}


# ----------------------------------------------------------------------------- the rabbit hole

def parse_url(url):
    """A wiki page URL -> {wiki, host, title, fragment, docname/spec} or None."""
    from urllib.parse import unquote, urlsplit
    p = urlsplit(url)
    host = (p.hostname or "").lower()
    if host == "en.m.wikipedia.org":
        host = "en.wikipedia.org"
    wiki = WIKI_OF_HOST.get(host)
    if not wiki or p.scheme not in ("http", "https"):
        return None
    path = unquote(p.path)
    frag = unquote(p.fragment).replace("_", " ") or None
    if wiki in ("wikipedia", "gentoo"):
        if not path.startswith("/wiki/") or len(path) <= 6:
            return None
        return {"wiki": wiki, "host": host, "title": path[6:].replace("_", " "), "fragment": frag}
    if wiki == "arch":
        if not path.startswith("/title/") or len(path) <= 7:
            return None
        return {"wiki": wiki, "host": host, "title": path[7:].replace("_", " "), "fragment": frag}
    if wiki == "kernel":
        doc = path.lstrip("/")
        doc = doc[:-5] if doc.endswith(".html") else doc
        return {"wiki": wiki, "host": host, "title": doc, "docname": doc, "fragment": None} if doc else None
    spec = path.strip("/").split("/")[0]
    return {"wiki": wiki, "host": host, "title": spec, "spec": spec, "fragment": None} if spec else None


_ORES = re.compile(r"^classification\.prediction\.articletopic/(.+)\|(\d+)$")


def _topic_value(label):
    """An ORES article-topic label -> the `articletopic:` search value ("Culture.Biography.Women" -> women)."""
    last = label.split(".")[-1].rstrip("*")
    return re.sub(r"[\s_]+", "-", last.strip().lower())


def wikipedia_facts(title, fam, log=lambda m: None):
    """One cirrusdoc request -> {family, topic, quality}: the family the article's own topic tags land in
    (highest score), Good / Featured from its templates. Unknown when the request fails."""
    facts = {"family": None, "topic": None, "quality": None}
    try:
        data = mw.call(wikipedia.HOST, {"action": "query", "prop": "cirrusdoc", "titles": title, "redirects": 1})
    except (http.NetError, mw.MwError) as e:
        log("topics of %s: %s" % (title, e))
        return facts
    pages = data.get("query", {}).get("pages", [])
    docs = (pages[0].get("cirrusdoc") if pages else None) or []
    src = docs[0].get("source", {}) if docs else {}
    tmpl = set(src.get("template") or [])
    facts["quality"] = ("featured" if "Template:Featured article" in tmpl
                        else "good" if "Template:Good article" in tmpl else None)
    topic_family = {}
    for f in fam.get("discover", []):
        for t in f.get("topics", []):
            topic_family[t] = f["id"]
    best = None
    for tag in src.get("weighted_tags") or []:
        m = _ORES.match(tag)
        if not m:
            continue
        t = _topic_value(m.group(1))
        if t in topic_family and (best is None or int(m.group(2)) > best[0]):
            best = (int(m.group(2)), t)
    if best:
        facts["family"], facts["topic"] = topic_family[best[1]], best[1]
    return facts


def _drop_old_live(keep):
    """The rabbit hole's cache is an LRU of `keep` pages: the oldest go, with the images they wrote."""
    d = os.path.dirname(paths.live_path("x"))
    try:
        files = sorted((os.path.join(d, f) for f in os.listdir(d) if f.endswith(".json")),
                       key=lambda p: os.stat(p).st_mtime)
    except OSError:
        return
    for p in files[:-keep] if len(files) > keep else []:
        old = atomic.read_json(p, {}) or {}
        _cleanup_files(old.get("files") or [])
        try:
            os.unlink(p)
        except OSError:
            pass


def _followed_candidate(ref, url):
    wiki = ref["wiki"]
    frag = ref["fragment"] if wiki == "arch" else None
    cand = candidates.make(wiki, ref["host"], ref["title"], fragment=frag, url=url.split("#")[0])
    if wiki == "kernel":
        cand.update({"docname": ref["docname"], "id": "docs.kernel.org/" + ref["docname"], "label": ref["docname"]})
    elif wiki == "freedesktop":
        cand.update({"spec": ref["spec"], "id": "specifications.freedesktop.org/" + ref["spec"],
                     "url": "%s/%s/latest/" % (freedesktop.BASE, ref["spec"]), "label": ref["spec"]})
    elif wiki == "arch" and frag and frag.lower() in ("tips and tricks", "tips"):
        secs = arch.tips_sections(ref["title"])
        if secs:
            cand.update({"kind": "tips", "section": secs[0]["index"], "base": ref["title"],
                         "fragment": "Tips and tricks", "label": ref["title"] + ": Tips and tricks",
                         "id": entrylib.default_id(ref["host"], ref["title"], "Tips and tricks")})
    return cand


def _followed_entry(ctx, tab, cand, fetched, ref):
    """The provisional entry of a followed page: the cleaned first paragraphs, a family, an image or the glyph.
    -> (entry, image files written) or (None, [])"""
    wiki = cand["wiki"]
    picked, _ = intro.cut(fetched["paras"], 80, 150, sentence_fill=True)
    if not picked:
        return None, []
    slug = paths.slug(cand["id"])
    quality = topic = None
    imgs, written, inst = [], [], None
    if wiki == "wikipedia":
        facts = wikipedia_facts(fetched["title"], ctx.fam, ctx.log)
        fam_id = facts["family"] or ("wikipedia-cs" if tab == "deepen" else "society")
        topic, quality = facts["topic"], facts["quality"]
        imgs, written = _lead_photo(ctx, fetched["title"], slug)
    else:
        fam_id = "other-wikis"
        if wiki == "arch":
            base = cand.get("base") or fetched["title"].split("/")[0]
            snap = ctx.snapshot()
            inst = installed.match_installed(base, snap) or installed.match_discovery(base, snap)
            fam_id = "arch-tips" if cand["kind"] == "tips" else ("arch-installed" if inst and inst["flag"]
                                                               else "arch-discovery")
    if not imgs:
        imgs = [glyph_image(fam_id)]
    e = entrylib.new_entry(
        id=cand["id"], tab=tab, kind=cand["kind"],
        source={"wiki": wiki, "host": ref["host"], "title": cand.get("base") or fetched["title"],
                "url": fetched["url"], "revid": fetched["revid"], "license": fetched["license"], "quality": quality},
        title=cand["label"] if wiki != "wikipedia" else fetched["title"],
        category={"family": fam_id, "topic": topic, "via": "follow", "why": None}, intro=_intro_from(picked),
        images=imgs,
        installed=({"flag": inst["flag"], "pkg": inst.get("pkg"), "unit": inst.get("unit"), "asOf": inst["asOf"]}
                   if inst else None),
        popularity={"views60d": None, "band": None}, judge={}, batch="follow")
    return e, written


def _remember(hit, *idents):
    """The cache file of a followed page, under every id it is asked for by (the URL's and the canonical one)."""
    for ident in dict.fromkeys(idents):
        atomic.write_json(paths.live_path(ident), hit)
    _drop_old_live(LIVE_CAP)


def load(url, tab, allow_generate, ctx):
    """`wiki.py load`: the page as an entry at once (Wikipedia's is final; the others are provisional), then, for
    a provisional one with `allow_generate` and a free GPU, a written intro as `upgrade`. -> the exit code."""
    t0 = time.monotonic()
    emit = ctx.emit
    ref = parse_url(url)
    if not ref:
        env.log("not a wiki page this tool can read: %s" % url)
        return 2

    def end(ok=1):
        emit({"ev": "end", "ok": ok, "skipped": 0, "failed": 1 - ok, "ms": int((time.monotonic() - t0) * 1000)})
        return 0 if ok else 1

    cand = _followed_candidate(ref, url)
    ask_ident = cand["id"]
    hit = atomic.read_json(paths.live_path(ask_ident))
    page = None
    if isinstance(hit, dict) and isinstance(hit.get("entry"), dict):
        os.utime(paths.live_path(ask_ident))
        emit({"ev": "entry", "entry": hit["entry"], "provisional": bool(hit.get("provisional"))})
        if isinstance(hit.get("upgrade"), dict):
            emit({"ev": "upgrade", "id": hit["entry"]["id"], "intro": hit["upgrade"]})
        if not (allow_generate and hit.get("provisional") and not hit.get("upgrade")):
            return end()
        try:                                              # cached but never written: the page again, for the writer
            page = judge_page(cand, fetch_page(cand))
        except Skip:
            return end()
    else:
        try:
            fetched = fetch_page(cand)
        except Skip:
            emit({"ev": "fail", "reason": "no such page"})
            return end(0)
        if cand["wiki"] not in ("kernel", "freedesktop"):
            cand["id"] = entrylib.default_id(ref["host"], fetched["title"], cand["fragment"])
        if cand["kind"] != "tips":
            cand["label"] = fetched["title"]
        e, written = _followed_entry(ctx, tab, cand, fetched, ref)
        if e is None:
            emit({"ev": "fail", "reason": "no lead"})
            return end(0)
        errs = entrylib.validate(e, check_files=True)
        if errs:
            _cleanup_files(written)
            emit({"ev": "fail", "reason": "invalid entry: " + "; ".join(errs[:3])})
            return end(0)
        provisional = cand["wiki"] != "wikipedia"
        hit = {"v": 1, "entry": e, "provisional": provisional, "upgrade": None, "files": written,
               "at": int(time.time() * 1000)}
        _remember(hit, ask_ident, e["id"])
        emit({"ev": "entry", "entry": e, "provisional": provisional})
        page = judge_page(cand, fetched) if provisional else None
    if allow_generate and hit.get("provisional") and page and page["paras"]:
        try:
            result, verdict, gname = ctx.write_intro(page)
        except Blocked:
            result = None                                 # no card: the cleaned paragraphs stay
        if result is not None and verdict["accepted"]:
            model = ctx.models["write"]["model"]
            up = {"text": result["text"], "words": intro.words(result["text"]), "provenance": "generated",
                  "stripped": [], "model": "%s+%s" % (gname, model) if gname == "jev-1.13" else model,
                  "grounded": True, "locator": None, "links": []}
            hit["upgrade"] = up
            _remember(hit, ask_ident, hit["entry"]["id"])
            emit({"ev": "upgrade", "id": hit["entry"]["id"], "intro": up})
    return end()


def _lead_photo(ctx, title, slug):
    """One hero for a followed Wikipedia page: its page image, cropped, with its credit (three requests at most)."""
    try:
        meta = wikipedia.batch_meta([title])
        if not meta or not meta[0].get("pageimage") or not meta[0].get("thumb"):
            return [], []
        m = meta[0]
        ft = "File:" + m["pageimage"].replace("_", " ")
        info = wikipedia.image_info([ft]).get(ft) or {}
        if info.get("mime") not in images.PHOTO_MIMES or (info.get("width") or 0) < images.MIN_WIDTH:
            return [], []
        if images._keyword_graphic(info.get("description"), m["pageimage"]):
            return [], []
        im = images.save_photo(images._dl(m["thumb"]), slug, 0, credit=images.credit_of(info),
                               license_=info.get("license", ""), src="page", file_title=ft)
        return [im], [im["file"], im["thumb"]]
    except (http.NetError, mw.MwError, OSError, ValueError) as e:
        ctx.log("lead image of %s: %s" % (title, e))
        return [], []
