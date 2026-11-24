"""Which pages a batch item may become: candidates per family, and the ranking that picks one.

    gather(item, ctx)                        -> [candidate]     up to N_CANDIDATES fresh pages for one plan item
    rank(cands, item, ctx, interest_many)    -> [candidate]     the same, each with score / band / interest
    weighted_pick(scores, u)                 -> index           the SHARED pick (Interest.weightedPick, same table)
    pop_weight(band, target)                 -> 0.2 .. 1        closeness to the item's popularity target

A plan item is what Interest.planBatch made of one draw: {family, topic, kind, band, why}. `family` names the
source of the candidates (modules/wiki/data/families.json is the one table):

    Discover families     random Good / Featured articles by articletopic (a random region lens for Geography),
                          `discoverExclude` negated so computing and software cannot enter through another
                          family, and the guest's deny list applied to every candidate (title + first sentence)
    computing (the guest) the far side only, in tiers: an intersection of computing with a partner topic, then
                          the allow phrases, then B-class pages (only while `bClassFallback`)
    wikipedia-cs          Good / Featured computing + software minus the guest's partner topics (the far side)
    arch-installed        English Arch titles that are about something INSTALLED (installed.py)
    arch-discovery        English Arch titles about software the repositories offer and that is NOT installed
    arch-tips             the "Tips and tricks" of installed software: a subpage `X/Tips and tricks`, else a
                          section of X (kind tips, id `...#Tips_and_tricks`)
    other-wikis           one of Gentoo (random English pages), the kernel docs (weighted curation), freedesktop
                          specifications, whichever the source toggles leave on

A candidate is a plain dict: {wiki, host, title (the wiki's), label (what a card calls it), id, url, kind, fragment,
quality, extract, revid, wikibase_item, installed, ...}. Nothing is fetched twice: `extract` (a plain-text lead
from the search's own generator) is what the interest question reads: one request for the whole list.

Ranking. Popularity is Wikipedia's only: pageviews of the batch's candidates, `band` = the candidate's quantile
among them (0 = least read, 1 = most read), then weighted by closeness to the item's `band` target with the same
bell as Interest.popularityWeight (width 0.35, floor 0.2). Interest is Jev's score (0..1) or 0.5 when there is no
Jev. The candidate's score is interest x popularity weight, and the pick is w_i = max(0.05, s_i)^2 walked with a
uniform u.
"""
import math

from . import entry, installed, intro, mw
from .sources import arch, freedesktop, gentoo, kernel_docs, wikipedia

N_CANDIDATES = 8
KERNEL_HOST = "docs.kernel.org"
FREEDESKTOP_HOST = "specifications.freedesktop.org"
POP_WIDTH = 0.35            # Interest.js resolve(): popWidth / popFloor
POP_FLOOR = 0.2
TIPS_PROBES = 10            # sections() requests a tips item may spend looking for a Tips section
TEMPLATE_PROBES = 6         # {{Pkg}} lookups (two requests each) when the title match finds too few pages
MIN_MATCHED = 3
_PARTNER_KEEP = ("history", "biography", "women", "mathematics", "visual-arts", "video-games")


# ----------------------------------------------------------------------------- the shared arithmetic

def weighted_pick(scores, u):
    """Interest.weightedPick: w_i = max(0.05, s_i)^2, normalised; the first i whose cumulative weight is above u
    (strictly); n - 1 when rounding leaves the last one a hair under u; -1 for no candidates."""
    n = len(scores) if scores else 0
    if n == 0:
        return -1
    w = []
    total = 0.0
    for s in scores:
        try:
            s = float(s)
        except (TypeError, ValueError):
            s = 0.0
        if not math.isfinite(s):
            s = 0.0
        v = max(0.05, s)
        w.append(v * v)
        total += w[-1]
    acc = 0.0
    for i in range(n):
        acc += w[i] / total
        if acc > u:
            return i
    return n - 1


def pop_weight(band, target, width=POP_WIDTH, floor=POP_FLOOR):
    """Interest.popularityWeight: 1 for an unknown band, else the bell around the target, never under `floor`."""
    if not isinstance(band, (int, float)) or isinstance(band, bool) or not math.isfinite(band):
        return 1.0
    z = (band - target) / width
    return max(floor, math.exp(-z * z))


def quantile_bands(views):
    """{title: views} -> {title: band}: the share of the OTHER titles that were read less, with ties sharing
    their average rank; a lone title sits in the middle."""
    n = len(views)
    if n == 0:
        return {}
    if n == 1:
        return {t: 0.5 for t in views}
    vals = sorted(views.values())
    out = {}
    for t, v in views.items():
        below = sum(1 for x in vals if x < v)
        equal = sum(1 for x in vals if x == v)
        out[t] = (below + (equal - 1) / 2.0) / (n - 1)
    return out


def weighted_sample(items, weights, k, rng):
    """`k` distinct items drawn with probability proportional to their weights (Efraimidis-Spirakis keys)."""
    keyed = []
    for it, w in zip(items, weights):
        w = max(float(w), 1e-9)
        keyed.append((rng.random() ** (1.0 / w), it))
    keyed.sort(key=lambda kv: -kv[0])
    return [it for _, it in keyed[:k]]


# ----------------------------------------------------------------------------- filters

def first_sentence(text):
    text = (text or "").strip()
    if not text:
        return ""
    spans = intro.sentences(text)
    return text[spans[0][0]:spans[0][1]] if spans else text[:240]


def denied(title, lead, deny):
    """The guest's deny list (families.json guest.deny) against title + the first sentence of the lead:
    a case-insensitive substring hit rejects the candidate."""
    hay = ((title or "") + " " + first_sentence(lead)).lower()
    return any(d.lower() in hay for d in deny)


def phrase_clauses(allow, max_chars=300, join=" OR "):
    """The allow phrases as CirrusSearch clauses `("a" OR "b" ...)`, filled greedily in list order to at most
    `max_chars` characters each (the limit is CirrusSearch's), the way families.json guest.queries.phrase says."""
    out, cur = [], []
    for phrase in allow:
        piece = '"%s"' % phrase
        trial = "(" + join.join(cur + [piece]) + ")"
        if cur and len(trial) > max_chars:
            out.append("(" + join.join(cur) + ")")
            cur = [piece]
        else:
            cur.append(piece)
    if cur:
        out.append("(" + join.join(cur) + ")")
    return out


def family_obj(fam, family_id):
    for f in fam.get("discover", []):
        if f["id"] == family_id:
            return f
    g = fam.get("guest") or {}
    if g.get("id") == family_id:
        return g
    for f in fam.get("deepen", []):
        if f["id"] == family_id:
            return f
    return {"id": family_id}


def source_on(family, tab, sources):
    """The source toggle a family needs (WikiService._tabCfg has the same table)."""
    s = sources
    if tab == "discover":
        return bool(s.get("wikipedia", True))
    if family in ("arch-installed", "arch-discovery"):
        return bool(s.get("arch", True))
    if family == "arch-tips":
        return bool(s.get("arch", True)) and bool(s.get("archTips", True))
    if family == "wikipedia-cs":
        return bool(s.get("wikipedia", True))
    if family == "other-wikis":
        return bool(s.get("gentoo", True) or s.get("kernel", True) or s.get("freedesktop", True))
    return True


# ----------------------------------------------------------------------------- candidate records

def make(wiki, host, title, *, label=None, kind="article", fragment=None, ident=None, url=None, quality=None,
         **extra):
    c = {"wiki": wiki, "host": host, "title": title, "label": label or title, "kind": kind, "fragment": fragment,
         "id": ident or entry.default_id(host, title, fragment),
         "url": url or (mw.page_url(host, title, fragment) if wiki in ("wikipedia", "arch", "gentoo") else None),
         "quality": quality, "extract": "", "revid": None, "wikibase_item": None, "installed": None}
    c.update(extra)
    return c


def _from_metas(metas, ctx, *, quality=None, deny=None):
    """Page data of search hits -> candidates: missing pages, known ids (the pool, seen) and denied leads dropped."""
    out, have = [], set()
    for m in metas:
        if m.get("missing") or not m.get("title"):
            continue
        c = make("wikipedia", wikipedia.HOST, m["title"], quality=quality, extract=m.get("extract") or "",
                 revid=m.get("revid"), wikibase_item=m.get("wikibase_item"), url=m.get("url"),
                 pageimage=m.get("pageimage"), thumb=m.get("thumb"))
        if c["id"] in ctx.known or c["id"] in have:
            continue
        if deny and denied(c["title"], c["extract"], deny):
            continue
        have.add(c["id"])
        out.append(c)
    return out


# ----------------------------------------------------------------------------- Wikipedia

def _quality_order(hits, rng):
    ga, fa = int((hits or {}).get("ga") or 0), int((hits or {}).get("fa") or 0)
    if ga + fa <= 0:
        first = "good"
    else:
        first = "featured" if rng.random() < fa / float(ga + fa) else "good"
    return [first, "good" if first == "featured" else "featured"]


def _searched(topic_arg, hits, ctx, *, lens=None, extra="", deny=None):
    """One random Good / Featured query per quality (the contract), the family's own ratio deciding which goes
    first; the second only when the first yields nothing usable."""
    for quality in _quality_order(hits, ctx.rng):
        q = wikipedia.search_query(topic_arg, quality, lens, extra)
        metas = wikipedia.search_meta(q, N_CANDIDATES)
        cands = _from_metas(metas, ctx, quality=quality, deny=deny)
        if cands:
            return cands
    return []


def _discover(item, ctx):
    fam = family_obj(ctx.fam, item["family"])
    topics = fam.get("topics") or []
    topic = item.get("topic") or ""
    topic_arg = topic if topic in topics else "|".join(topics)
    if not topic_arg:
        return []
    lens = ctx.rng.choice(fam["lenses"]) if fam.get("lenses") else None
    extra = " ".join("-articletopic:" + t for t in ctx.fam.get("discoverExclude", []))
    deny = ctx.fam["guest"]["deny"] if ctx.fam.get("discoverDeny") else None
    return _searched(topic_arg, fam.get("hits"), ctx, lens=lens, extra=extra, deny=deny)


def _guest(item, ctx):
    g = ctx.fam["guest"]
    deny = g["deny"]
    partners = [p["topic"] for p in g.get("partners", []) if (p.get("ga") or 0) + (p.get("fa") or 0) > 0]
    cands = []
    if partners:                                                     # tier 1: an intersection with a partner
        metas = wikipedia.search_meta(wikipedia.search_query("computing", "both", partners), N_CANDIDATES)
        cands = _from_metas(metas, ctx, quality=None, deny=deny)
    if not cands:                                                    # tier 2: the allow phrases
        clauses = phrase_clauses(g.get("allow", []), g.get("queries", {}).get("phrase", {}).get("clauseMaxChars", 300),
                                 g.get("queries", {}).get("phrase", {}).get("clauseJoin", " OR "))
        ctx.rng.shuffle(clauses)
        for clause in clauses:
            metas = wikipedia.search_meta(wikipedia.search_query("computing", "both", None, clause), N_CANDIDATES)
            cands = _from_metas(metas, ctx, quality=None, deny=deny)
            if cands:
                break
    if not cands and g.get("bClassFallback") and partners:           # tier 3: B-class pages
        cands = _bclass(partners, ctx, deny)
    for c in cands:
        c["quality_unknown"] = c["quality"] is None
    return cands


def _bclass(partners, ctx, deny):
    q = "articletopic:computing articletopic:" + "|".join(partners)
    titles = wikipedia.search_random(q, 20)["titles"]
    if not titles:
        return []
    data = mw.query(wikipedia.HOST, {"action": "query", "prop": "pageassessments", "palimit": "max",
                                     "titles": titles[:50]}).get("query", {})
    keep = []
    for t in titles:
        page = next((p for p in data.get("pages", []) if p.get("title") == t), None)
        classes = [v.get("class") for v in ((page or {}).get("pageassessments") or {}).values()]
        if "B" in classes:
            keep.append(t)
    if not keep:
        return []
    return _from_metas(wikipedia.batch_meta(keep[:N_CANDIDATES], extracts=True), ctx, quality=None, deny=deny)


def _wikipedia_cs(item, ctx):
    fam = family_obj(ctx.fam, "wikipedia-cs")
    topics = fam.get("topics") or ["computing", "software"]
    topic = item.get("topic") or ""
    topic_arg = topic if topic in topics else "|".join(topics)
    regions = set()
    for f in ctx.fam.get("discover", []):
        regions.update(f.get("lenses") or [])
    far = [p["topic"] for p in ctx.fam["guest"].get("partners", [])
           if p["topic"] in _PARTNER_KEEP and p["topic"] not in regions]
    extra = " ".join("-articletopic:" + t for t in far)
    return _searched(topic_arg, fam.get("hits"), ctx, extra=extra)


# ----------------------------------------------------------------------------- Arch

def _arch_cand(title, ctx, **kw):
    return make("arch", arch.HOST, title, **kw)


def _arch_matches(ctx, wanted):
    """Every English Arch title `wanted(title)` accepts (an installed.match_* answer), in index order, unknown
    ids only. -> [(title, installed dict)]"""
    titles = arch.english_titles()
    out = []
    for t in titles:
        m = wanted(t)
        if m and entry.default_id(arch.HOST, t) not in ctx.known:
            out.append((t, m))
    return out


def _arch_installed(item, ctx):
    snap = ctx.snapshot()
    pool = _arch_matches(ctx, lambda t: installed.match_installed(t, snap))
    pool = [p for p in pool if "/" not in p[0]] or pool
    picked = ctx.rng.sample(pool, min(N_CANDIDATES, len(pool)))
    cands = [_arch_cand(t, ctx, installed=m) for t, m in picked]
    if len(cands) < MIN_MATCHED:                       # too few by name: the pages' own {{Pkg}} / {{AUR}} say what they are about
        cands += _arch_by_templates(ctx, snap, wants_installed=True, have={c["id"] for c in cands},
                                    room=N_CANDIDATES - len(cands))
    return cands


def _arch_discovery(item, ctx):
    snap = ctx.snapshot()
    pool = _arch_matches(ctx, lambda t: installed.match_discovery(t, snap) if "/" not in t else None)
    picked = ctx.rng.sample(pool, min(N_CANDIDATES, len(pool)))
    cands = [_arch_cand(t, ctx, installed=m) for t, m in picked]
    if len(cands) < MIN_MATCHED:                       # too few by name: ask the pages' own {{Pkg}} / {{AUR}}
        cands += _arch_by_templates(ctx, snap, wants_installed=False, have={c["id"] for c in cands},
                                    room=N_CANDIDATES - len(cands))
    return cands


def _arch_by_templates(ctx, snap, *, wants_installed, have, room):
    titles = [t for t in arch.english_titles() if "/" not in t and installed.match_installed(t, snap) is None
              and installed.match_discovery(t, snap) is None
              and entry.default_id(arch.HOST, t) not in ctx.known and entry.default_id(arch.HOST, t) not in have]
    out = []
    for t in ctx.rng.sample(titles, min(TEMPLATE_PROBES, len(titles))):
        if len(out) >= room:
            break
        try:
            names = arch.pkg_templates(t)
        except (mw.MwError, KeyError):
            continue
        m = installed.by_templates(t, snap, names)
        if m and m["flag"] == wants_installed:
            out.append(_arch_cand(t, ctx, installed=m))
    return out


def _arch_tips(item, ctx):
    snap = ctx.snapshot()
    titles = arch.english_titles()
    tset = set(titles)
    pool = _arch_matches(ctx, lambda t: installed.match_installed(t, snap) if "/" not in t else None)
    ctx.rng.shuffle(pool)
    cands, probes = [], 0
    for t, m in pool:
        if len(cands) >= N_CANDIDATES:
            break
        sub = t + "/Tips and tricks"
        if sub in tset:                                # the tips have a page of their own
            ident = entry.default_id(arch.HOST, sub)
            if ident not in ctx.known:
                cands.append(_arch_cand(sub, ctx, kind="tips", label=t + ": Tips and tricks", installed=m,
                                        base=t))
            continue
        if probes >= TIPS_PROBES:
            continue
        probes += 1
        try:
            tips = arch.tips_sections(t)
        except (mw.MwError, KeyError):
            continue
        if not tips:
            continue
        ident = entry.default_id(arch.HOST, t, "Tips and tricks")
        if ident in ctx.known:
            continue
        cands.append(_arch_cand(t, ctx, kind="tips", fragment="Tips and tricks", label=t + ": Tips and tricks",
                                installed=m, section=tips[0]["index"], base=t))
    return cands


# ----------------------------------------------------------------------------- the other wikis

def _other(item, ctx):
    s = ctx.sources
    order = [n for n in ("gentoo", "kernel", "freedesktop") if s.get(n, True)]
    if not order:
        return []
    src = ctx.rng.choice(order)
    n = N_CANDIDATES
    if src == "gentoo":
        titles = [t for t in gentoo.random_titles(n * 2) if entry.default_id(gentoo.HOST, t) not in ctx.known]
        return [make("gentoo", gentoo.HOST, t, topic_source="gentoo") for t in titles[:n]]
    if src == "kernel":
        docs = [d for d in kernel_docs.candidates() if KERNEL_HOST + "/" + d["docname"] not in ctx.known]
        pick = weighted_sample(docs, [d["weight"] for d in docs], n, ctx.rng)
        return [make("kernel", KERNEL_HOST, d["docname"], label=d["title"] or d["docname"], url=d["url"],
                     ident=KERNEL_HOST + "/" + d["docname"], topic_source="kernel", docname=d["docname"])
                for d in pick]
    specs = ctx.cache.get("fd_specs")
    if specs is None:
        specs = ctx.cache["fd_specs"] = freedesktop.specs()
    host = FREEDESKTOP_HOST
    specs = [sp for sp in specs if host + "/" + sp["id"] not in ctx.known]
    pick = ctx.rng.sample(specs, min(n, len(specs)))
    return [make("freedesktop", host, sp["id"], label=sp["id"].replace("-", " "), url=sp["url"],
                 ident=host + "/" + sp["id"], topic_source="freedesktop", spec=sp["id"]) for sp in pick]


# ----------------------------------------------------------------------------- entry points

def gather(item, ctx):
    """Up to N_CANDIDATES candidates for one plan item; [] when the family has nothing left to offer."""
    family = item["family"]
    tab = ctx.tab
    if not source_on(family, tab, ctx.sources):
        return []
    if tab == "discover":
        return _guest(item, ctx) if family == ctx.fam["guest"]["id"] else _discover(item, ctx)
    return {"arch-installed": _arch_installed, "arch-discovery": _arch_discovery, "arch-tips": _arch_tips,
            "wikipedia-cs": _wikipedia_cs, "other-wikis": _other}.get(family, lambda i, c: [])(item, ctx)


def rank(cands, item, ctx, interest_many):
    """Score the candidates. `interest_many(cands) -> [0..1 | None]` is Jev's question about all of them at once (a
    None: no answer for that one, 0.5 is used). Adds views / band / popw / interest / score to each candidate and
    returns them in the order given."""
    wiki_titles = [c["title"] for c in cands if c["wiki"] == "wikipedia"]
    views = wikipedia.pageviews(wiki_titles) if wiki_titles else {}
    bands = quantile_bands({t: views.get(t, 0) for t in wiki_titles})
    target = item.get("band")
    interest = list(interest_many(cands)) + [None] * len(cands)
    for c, v in zip(cands, interest):
        if c["wiki"] == "wikipedia":
            c["views"] = int(views.get(c["title"], 0))
            c["band"] = bands.get(c["title"])
            c["popw"] = pop_weight(c["band"], target if isinstance(target, (int, float)) else 0.5)
        else:
            c["views"], c["band"], c["popw"] = None, None, 1.0
        c["interest"] = 0.5 if v is None else float(v)
        c["score"] = c["interest"] * c["popw"]
    return cands
