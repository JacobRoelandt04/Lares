"""Choosing an original intro for a page that has none by rule (Arch, Gentoo, kernel docs, freedesktop).

    choose_intro(page, judge, thresholds=None) -> {paras, reason, provenance, ...}
    thresholds_for(models_cfg, judge_name)     -> the fitted thresholds of one judge

The judge names a paragraph and rates it (judge.Judge.locate). choose_intro then

  1. refuses when the judge found no paragraph ("judge-none") or gives its own pick less than
     `minPick` ("low-confidence");
  2. refuses when any of the four rule probabilities is under its threshold ("rule:<name>"), asking the
     judge for the rules first when its locate did not carry them;
  3. expands FORWARD from the pick with intro.cut(..., sentence_fill=True) into 80-150 words: whole
     paragraphs, and when the next one would overshoot, the whole sentences of it that fit. A pick that
     is not prose (a list item, a pointer line: cut skips it) is refused ("not-prose");
  4. refuses an intro under `minWords` ("too-short"): the writer does better than a stub.

A refusal means "the writer runs": {paras: None, provenance: "none"}. Acceptance returns provenance
"original" with the paragraph indices, the cut paragraphs (links are kept, offsets already adjusted by
intro.cut), the joined text and word count, and `locator` in the shape of entry.intro.locator:
{judge, para, of, score, rules}.

Thresholds come from data/models.json (`locate.thresholds`, one set per judge, fitted on the
labelled corpus). A JudgeUnavailable from the judge propagates (the batch switches to the
fallback judge); any other JudgeError is a page without a verdict.
"""
from __future__ import annotations

from . import intro, judge
from .judge import JudgeError, JudgeUnavailable, RULE_KEYS

DEFAULT_THRESHOLDS = {"defines": 0.7, "hook": 0.6, "selfContained": 0.7, "noHowTo": 0.6,
                      "minPick": 0.5, "minWords": 50}


def thresholds_for(models_cfg, judge_name):
    """The thresholds of `judge_name` ("jev" | "ollama:<model>") from a models.json dict; its own set when
    fitted, else "default", else the built-in ones; any key the set lacks comes from the built-ins."""
    table = ((models_cfg or {}).get("locate") or {}).get("thresholds") or {}
    name = "jev" if judge_name.startswith("jev") else judge_name
    out = dict(DEFAULT_THRESHOLDS)
    out.update(table.get("default") or {})
    out.update(table.get(name) or {})
    return out


def _none(reason, **extra):
    r = {"paras": None, "reason": reason, "provenance": "none"}
    r.update(extra)
    return r


def choose_intro(page, judge_, thresholds=None, *, result=None):
    """See the module docstring. `result` is a locate() answer already in hand (the eval replays stored
    ones); without it the judge is asked."""
    th = dict(DEFAULT_THRESHOLDS)
    th.update(thresholds if thresholds is not None else thresholds_for(judge.models(), judge_.name))
    try:
        res = result if result is not None else judge_.locate(page)
    except JudgeUnavailable:
        raise
    except JudgeError as e:
        return _none("judge-error:" + e.reason)
    para = res.get("para")
    if para is None:
        return _none("judge-none", locate=res)
    if (res.get("confidence") or 0.0) < th["minPick"]:
        return _none("low-confidence", locate=res)

    rules = res.get("rules")
    if rules is None:
        try:
            rules = judge_.rules(page, [para])
        except JudgeUnavailable:
            raise
        except JudgeError as e:
            return _none("judge-error:" + e.reason, locate=res)
    failing = [k for k in RULE_KEYS if rules.get(k, 0.0) < th[k]]
    if failing:
        return _none("rule:" + ",".join(failing), locate=res, rules={k: rules.get(k) for k in RULE_KEYS})

    paras = page.get("paras") or []
    if not 0 <= para < len(paras):
        return _none("bad-index", locate=res)
    picked, words = intro.cut(paras[para:], sentence_fill=True)
    if not picked or not paras[para]["text"].startswith(picked[0]["text"]):
        return _none("not-prose", locate=res)                 # cut skipped the pick: not an intro paragraph
    if words < th["minWords"]:
        return _none("too-short", locate=res, words=words)
    idx = list(range(para, para + len(picked)))
    return {"paras": idx, "reason": "ok", "provenance": "original", "paragraphs": picked,
            "text": "\n\n".join(p["text"] for p in picked), "words": words,
            "locator": {"judge": "jev" if judge_.name.startswith("jev") else "ollama",
                        "name": judge_.name, "para": para, "of": res.get("of"),
                        "score": res.get("confidence"), "rules": {k: rules.get(k) for k in RULE_KEYS}}}
