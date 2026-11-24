"""The judge interface of the intro pipeline, and what every implementation shares.

A judge answers questions about a wiki page. Two implementations: judge_jev.JevJudge (System One through
Defapi, one request per page, probabilities the model itself computes) and judge_ollama.OllamaJudge (a
resident local model, JSON-schema constrained). The batch and the eval only ever talk to this interface:

    Judge.locate(page)                        -> {para, probs, confidence, rules, ms, tokens, ...}
    Judge.rules(page, paras_idx)              -> {defines, hook, selfContained, noHowTo, ms, tokens}
    Judge.grounded(source_text, summary)      -> p            every claim of summary is in the source
    Judge.graphic(caption, description)       -> p            the image is graphic or disturbing
    Judge.interest(title, lead, recent_titles)-> score 0..1   how likely this reader opens it
    Judge.interest_many(candidates, recent)   -> [score|None] the same for a list of (title, lead) pairs; a judge
                                                that can put them in ONE request does (Jev), the rest loop
    Judge.usage()                             -> {calls, tokensIn, tokensOut, usd, ...}

`page` is the eval corpus shape (also what the batch builds from a fetched page):
    {id, wiki, title, url, stratum, paras: [{text, links, kind, section, stripped}], numbered}
`para` is an index into page["paras"], or None when the judge finds no paragraph that qualifies.
`rules` are PROBABILITIES 0..1 that the rule holds, all four "higher is better": `noHowTo` is one minus
the probability of a how-to opening. `rules` is None when there is no paragraph to judge. `confidence`
is the probability the judge gives its own pick.

Calibration caveat: Jev's numbers are computed probabilities but a "no" sits near 0.5, not near 0
(jev_api.md section 7), and a local model's number is only its STATED confidence. Neither is comparable
with the other, which is why the thresholds are fitted per judge on the labelled corpus
and stored per judge in data/models.json.

Errors: JudgeUnavailable (the judge cannot answer now: network, no key, a budget) -> the caller falls
back to the next judge; BudgetExceeded is one of those; JudgeError (an answer that cannot be read, a bad
request) -> the page has no verdict. Messages are scrubbed of the Jev key.

Also here: Budget (the Jev spend guard), the page views that fit a judge's context, the prompt and
model-config loaders.
"""
from __future__ import annotations

import json
import os

from . import env, intro, paths

RULE_KEYS = ("defines", "hook", "selfContained", "noHowTo")
DEFAULT_OLLAMA_URL = "http://127.0.0.1:11434"
JEV_USD_PER_INPUT_TOKEN = 0.084e-6      # jev_api.md section 4: output tokens are free
DEFAULT_BUDGET_USD = 0.05               # the whole eval run (the credit is $0.20 in total)


# ----------------------------------------------------------------------------- errors

class JudgeError(Exception):
    reason = "judge-error"

    def __init__(self, message, reason=None):
        super().__init__(env.scrub(message))
        if reason:
            self.reason = reason


class JudgeUnavailable(JudgeError):
    """The judge cannot answer now. The batch falls back to another judge (event warn, code = reason)."""
    reason = "judge-unavailable"


class BudgetExceeded(JudgeUnavailable):
    reason = "jev-budget"


class BadRequest(JudgeError):
    """The service refused the request itself (HTTP 400): a bug in our request, not an outage."""
    reason = "bad-request"


# ----------------------------------------------------------------------------- the Jev spend guard

class Budget:
    """Dollars spent on Jev, counted from `usage.input_tokens` (jev_api.md: $0.084 per million input
    tokens, output free), and a cap that REFUSES the next call: check() raises BudgetExceeded when the
    call, at its estimated cost, would take the total past the cap. A child budget (one per eval phase)
    counts against its parent as well, so a phase cannot eat the whole run's allowance."""

    def __init__(self, cap_usd=DEFAULT_BUDGET_USD, name="run", parent=None):
        self.cap_usd = float(cap_usd)
        self.name = name
        self.parent = parent
        self.spent = 0.0
        self.tokens_in = 0
        self.tokens_out = 0
        self.calls = 0
        self.refused = 0

    def child(self, name, cap_usd):
        return Budget(min(float(cap_usd), self.cap_usd), name, parent=self)

    def remaining(self):
        r = self.cap_usd - self.spent
        return min(r, self.parent.remaining()) if self.parent else r

    def check(self, est_usd=0.0):
        """Raise BudgetExceeded unless a call costing about `est_usd` still fits under the cap."""
        if self.spent + est_usd > self.cap_usd:
            b = self
            while b is not None:                      # the run's summary counts what a phase refused
                b.refused += 1
                b = b.parent
            raise BudgetExceeded(
                "Jev budget '%s' reached: $%.4f spent of $%.4f in %d calls, the next call (about $%.5f) "
                "is refused" % (self.name, self.spent, self.cap_usd, self.calls, est_usd))
        if self.parent:
            try:
                self.parent.check(est_usd)
            except BudgetExceeded:
                self.refused += 1                     # the run said no: this phase was refused too
                raise

    def add(self, tokens_in, tokens_out=0):
        usd = int(tokens_in) * JEV_USD_PER_INPUT_TOKEN
        self.spent += usd
        self.tokens_in += int(tokens_in)
        self.tokens_out += int(tokens_out)
        self.calls += 1
        if self.parent:
            self.parent.add(tokens_in, tokens_out)
        return usd

    def summary(self):
        return {"name": self.name, "capUsd": self.cap_usd, "spentUsd": round(self.spent, 6),
                "calls": self.calls, "tokensIn": self.tokens_in, "tokensOut": self.tokens_out,
                "refused": self.refused}

    def line(self):
        return "jev $%.4f / $%.2f (%d calls, %d tokens in)" % (self.spent, self.cap_usd, self.calls,
                                                              self.tokens_in)


def estimate_jev_usd(chars):
    """A deliberately high estimate of a request's cost from the size of its JSON: about 0.4 tokens per
    character of prose (code is worse) plus the model's own 300-token framing."""
    return (0.4 * chars + 300) * JEV_USD_PER_INPUT_TOKEN


# ----------------------------------------------------------------------------- the interface

class Judge:
    name = "judge"

    def locate(self, page):
        raise NotImplementedError

    def rules(self, page, paras_idx):
        raise NotImplementedError

    def grounded(self, source_text, summary):
        raise NotImplementedError

    def graphic(self, caption, description):
        raise NotImplementedError

    def interest(self, title, lead, recent_titles):
        raise NotImplementedError

    def interest_many(self, candidates, recent_titles):
        """[score 0..1 | None] for a list of (title, lead) pairs, in order; None where that candidate has no answer.
        The default asks interest() once per candidate (a local model); JevJudge overrides it with ONE request,
        because a request pays about 300 tokens of framing whatever it asks (jev_api.md section 4). A judge that
        cannot answer at all (JudgeUnavailable) still raises: the caller falls back as it does everywhere else."""
        out = []
        for title, lead in candidates:
            try:
                out.append(self.interest(title, lead, recent_titles))
            except JudgeUnavailable:
                raise
            except JudgeError:
                out.append(None)
        return out

    def usage(self):
        return {"calls": 0, "tokensIn": 0, "tokensOut": 0, "usd": 0.0}


# ----------------------------------------------------------------------------- prompts and model config

_cache: dict = {}


def _load_data(name):
    path = paths.data_path(name)
    key = (path, os.stat(path).st_mtime_ns)
    if _cache.get(name, (None,))[0] != key:
        with open(path, encoding="utf-8") as f:
            _cache[name] = (key, json.load(f))
    return _cache[name][1]


def prompts():
    """tools/wiki/data/prompts.json."""
    return _load_data("prompts.json")


def models():
    """tools/wiki/data/models.json: who judges, who writes, the fitted thresholds."""
    return _load_data("models.json")


def fill(template, **kw):
    """`template` with each {name} replaced by str(value): a literal replace, so a template may hold any
    other brace."""
    out = template
    for k, v in kw.items():
        out = out.replace("{" + k + "}", str(v))
    return out


def rule_text(key):
    return prompts()["rules"][key]


def rules_block():
    """The four rules as prompts.json words them, keyed for fill(): defines, hook, selfContained, noHowTo."""
    return {k: rule_text(k) for k in RULE_KEYS}


# ----------------------------------------------------------------------------- page views

def page_title(page):
    return page.get("title") or page.get("id") or ""


def words(text):
    return len(text.split())


def clip(text, limit):
    """`text` cut at a word boundary to about `limit` characters, "..." marking the cut."""
    text = " ".join(text.split())
    if limit is None or len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0] if " " in text[:limit] else text[:limit]
    return cut.rstrip(" ,;:") + "\u2026"


def para_text(p):
    """A paragraph as the judge reads it: prose as it is, "(code) ...", "(heading) ...", "(list) ..."
    (intro.numbered's own wording, without the number)."""
    s = intro.numbered([p])
    return s[s.index("] ") + 2:]


def views(page, *, max_paras=40, max_chars=600, max_total=9000, focus=(), focus_chars=1100):
    """[(index, text)] of the paragraphs a judge is shown, in page order, from the top: each clipped to
    `max_chars` (the paragraphs in `focus` to `focus_chars`), at most `max_paras` of them and about
    `max_total` characters in all. An intro sits near the top, and a local model's 8192-token context is
    a hard wall (Ollama cuts the start of an over-long prompt, the instructions with it)."""
    out, total = [], 0
    focus = set(focus)
    for i, p in enumerate(page.get("paras") or ()):
        if len(out) >= max_paras:
            break
        text = clip(para_text(p), focus_chars if i in focus else max_chars)
        if not text:
            continue
        if out and total + len(text) > max_total and i not in focus:
            break
        out.append((i, text))
        total += len(text)
    return out


def numbered_view(pairs):
    return "\n\n".join("[%d] %s" % (i, t) for i, t in pairs)


def para_phrase(idx):
    """[3] -> "Paragraph 3"; [3, 4] -> "Paragraphs 3 and 4 read together"."""
    idx = [int(i) for i in idx]
    if len(idx) == 1:
        return "Paragraph %d" % idx[0]
    head = ", ".join(str(i) for i in idx[:-1])
    return "Paragraphs %s and %d read together" % (head, idx[-1])


def synthetic_page(title, text):
    """A one-paragraph page, for judging a written text with rules()."""
    return {"id": "synthetic/" + title, "title": title,
            "paras": [{"text": text, "kind": "p", "links": [], "section": "", "stripped": []}]}


def clamp01(x):
    """A model's number as a probability: 0..1 as is, 1..100 read as a percentage, else clamped."""
    try:
        v = float(x)
    except (TypeError, ValueError):
        return 0.0
    if 1.0 < v <= 100.0:
        v /= 100.0
    return max(0.0, min(1.0, v))


def make(spec, *, budget=None, ollama_url=DEFAULT_OLLAMA_URL, **kw):
    """A judge from its config name: "jev" (kw: mode), "ollama:<model>"."""
    if spec == "jev" or spec.startswith("jev:"):
        from . import judge_jev
        mode = kw.pop("mode", None)
        if ":" in spec:
            mode = spec.split(":", 1)[1]
        return judge_jev.JevJudge(budget=budget, mode=mode or "twopass", **kw)
    if spec.startswith("ollama:"):
        from . import judge_ollama
        return judge_ollama.OllamaJudge(spec.split(":", 1)[1], url=ollama_url, **kw)
    raise ValueError("unknown judge %r (jev | jev:onepass | jev:twopass | ollama:<model>)" % spec)
