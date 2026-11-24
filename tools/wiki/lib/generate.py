"""The writer of the fallback intro: a local model, grounded in the page's own text.

    write_intro(page, model, ollama_url, ...) -> {text, words, model, ms, tokens, ok, reason, ...}
    accept(page, result, judge, grounded_min) -> {accepted, grounded, reason}
    page_text(page, max_words=2500)           the source the writer is given (and the grounding judge)
    strip_markdown(text)                      what a small model's answer is cleaned of

The prompt (data/prompts.json `write`): the four rules, "write ONE paragraph of 80-150 words for a curious
newcomer using ONLY facts in the text below; no headings, no lists, no commands", then the title and the
first ~2500 words of the page. think:false (through OllamaClient), temperature 0.3 and a fixed seed: a
little variety, the same answer on a re-run. The answer is cleaned (markdown, a "Here is ..." preamble, the
longest paragraph kept), its words are counted, and when they fall outside 80-150 ONE retry is made in the
same conversation with the count fed back. The better of the two attempts wins (in range, else nearer).

Acceptance is not the writer's business: accept() asks judge.grounded(source, text) and compares it with
`write.groundedMin` from models.json. An accepted text is presented as a model-written intro (the sparkle
mark); a rejected one is dropped and the entry has no intro.
"""
from __future__ import annotations

import re
import time

from . import judge, judge_ollama
from .judge import fill, prompts, rules_block

MIN_WORDS, MAX_WORDS = 80, 150
SOURCE_WORDS = 2500
MIN_SOURCE_WORDS = 40


def page_text(page, max_words=SOURCE_WORDS):
    """The page as plain text for the writer: prose paragraphs as they are, headings as their own line,
    list items with a dash, code shortened to one line; cut at `max_words` words on a paragraph end."""
    out, total = [], 0
    for p in page.get("paras") or ():
        text = " ".join((p.get("text") or "").split())
        if not text:
            continue
        kind = p.get("kind", "p")
        if kind == "pre":
            text = judge.clip(text, 200)
        elif kind == "li":
            text = "- " + text
        w = judge.words(text)
        if total + w > max_words:
            if out:
                break
            text, w = _cut_words(text, max_words), max_words         # one huge paragraph: cut it, at a sentence end
        out.append(text)
        total += w
        if total >= max_words:
            break
    return "\n\n".join(out)


def _cut_words(text, n):
    """The first `n` words of `text`, backed up to the last sentence end when that loses under 40 %."""
    cut = " ".join(text.split()[:n])
    ends = [m.end() for m in re.finditer(r"[.!?][\"')\]]*(?=\s|$)", cut)]
    return cut[:ends[-1]] if ends and ends[-1] >= 0.6 * len(cut) else cut


_PREAMBLE = re.compile(r"^\s*(?:sure[,!.]?\s*)?(?:here(?:'s| is| are)|below is)\b[^:\n]{0,100}:\s*", re.I)


_PREAMBLE_ONLY = re.compile(r"(?:sure[,!.]?\s*)?(?:here(?:'s| is| are)|below is)\b[^:\n]{0,100}:", re.I)


def strip_markdown(text):
    """One plain paragraph: fences, headings, bullets, emphasis, backticks and links removed, a preamble
    dropped, the longest paragraph kept, whitespace collapsed, wrapping quotes taken off."""
    t = (text or "").replace("\r\n", "\n")
    t = re.sub(r"```.*?```", " ", t, flags=re.S)
    t = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", t)
    t = re.sub(r"^[ \t]{0,3}#{1,6}[ \t].*$\n?", "", t, flags=re.M)     # a heading line is not the paragraph
    t = re.sub(r"^[ \t]*(?:[-*+]|\d+[.)])[ \t]+", "", t, flags=re.M)
    t = re.sub(r"(\*\*|__|\*|`)", "", t)
    t = re.sub(r"(?<![\w])_([^_\n]+)_(?![\w])", r"\1", t)
    blocks = [" ".join(b.split()) for b in re.split(r"\n\s*\n", t) if b.strip()]
    blocks = [b for b in blocks if not _PREAMBLE_ONLY.fullmatch(b)] or blocks       # "Here is the paragraph:" alone
    if not blocks:
        return ""
    t = max(blocks, key=lambda b: len(b.split()))
    t = _PREAMBLE.sub("", t).strip()
    if len(t) >= 2 and t[0] in "\"\u201c" and t[-1] in "\"\u201d" and not re.search("[\"\u201c\u201d]", t[1:-1]):
        t = t[1:-1].strip()                       # the whole answer wrapped in one pair of quotes
    return t


# A written intro that talks about the page or recites the prompt's rules is not an intro (a small model
# writes "The subject is a guide ...", "A concrete hook is that ...", "This article provides ...").
_META = re.compile(r"\b(?:the subject is|a concrete hook|concrete hook|self-contained|"
                   r"this (?:article|page|guide|document|section|paragraph|text|wiki)\b|"
                   r"the (?:article|page|guide|document|text) (?:describes|explains|covers|provides))", re.I)


def meta_problem(text):
    """The first meta phrase in `text`, or None."""
    m = _META.search(text or "")
    return m.group(0) if m else None


def _problem(text, words):
    """Why a written paragraph is unusable, in words the retry can hand back to the model; None if fine."""
    if not text:
        return "is empty"
    meta = meta_problem(text)
    if meta:
        return "talks about the text or its rules ('%s')" % meta
    if _gap(words):
        return "has %d words" % words
    return None


def _gap(words):
    """How far a word count is outside 80-150 (0 = inside)."""
    return max(MIN_WORDS - words, words - MAX_WORDS, 0)


def write_intro(page, model, ollama_url=judge.DEFAULT_OLLAMA_URL, *, client=None, transport=None,
                source_words=SOURCE_WORDS, temperature=0.3, seed=7, num_predict=500):
    """Write the intro of `page` with `model`. Never raises for a bad answer: `ok` says whether the text is
    in range and `reason` why not ("no-source", "empty", "words:<n>"). A model that cannot be reached
    raises judge.JudgeUnavailable (the batch stops or falls back)."""
    P = prompts()["write"]
    source = page_text(page, source_words)
    if judge.words(source) < MIN_SOURCE_WORDS:
        return {"text": "", "words": 0, "model": model, "ms": 0.0, "tokens": 0, "ok": False,
                "reason": "no-source", "retried": False, "attempts": 0, "evalTokens": 0, "evalNs": 0,
                "promptTokens": 0}
    client = client or judge_ollama.OllamaClient(ollama_url, transport=transport)
    messages = [{"role": "system", "content": fill(P["system"], **rules_block())},
                {"role": "user", "content": fill(P["user"], title=judge.page_title(page), text=source)}]
    opts = {"temperature": temperature, "seed": seed, "num_predict": num_predict}
    t0 = time.monotonic()
    tokens = ev_tok = ev_ns = 0
    best, retried, attempts, prompt_tokens = "", False, 0, 0
    for attempt in range(3):
        r = client.chat(model, messages, None, opts)
        attempts += 1
        tokens += r["promptTokens"] + r["evalTokens"]
        ev_tok += r["evalTokens"]
        ev_ns += r["evalNs"]
        prompt_tokens = max(prompt_tokens, r["promptTokens"])
        text = strip_markdown(r["content"])
        w = judge.words(text)
        problem = _problem(text, w)
        if not best or (problem is None) or (meta_problem(best) and not meta_problem(text)) or \
                (not meta_problem(text) and _gap(w) < _gap(judge.words(best))):
            best = text
        if problem is None or attempt == 2:
            break
        retried = True
        messages = messages + [{"role": "assistant", "content": r["content"]},
                               {"role": "user", "content": fill(P["feedback"], problem=problem)}]
    w = judge.words(best)
    problem = _problem(best, w)
    ok = problem is None
    reason = "ok" if ok else ("empty" if not best else ("meta" if meta_problem(best) else "words:%d" % w))
    return {"text": best, "words": w, "model": model, "ms": (time.monotonic() - t0) * 1000.0,
            "tokens": tokens, "ok": ok, "reason": reason,
            "retried": retried, "attempts": attempts, "evalTokens": ev_tok, "evalNs": ev_ns,
            "promptTokens": prompt_tokens}


def accept(page, result, judge_, grounded_min=None, source_words=SOURCE_WORDS):
    """Whether a written intro may be shown: it is in range AND the judge finds it grounded in the page.
    -> {accepted, grounded, reason}; `grounded` is None when it was not asked (the text was unusable)."""
    if grounded_min is None:
        grounded_min = judge.models()["write"]["groundedMin"]
    if not result.get("ok"):
        return {"accepted": False, "grounded": None, "reason": result.get("reason") or "unusable"}
    p = judge_.grounded(page_text(page, source_words), result["text"])
    if p < grounded_min:
        return {"accepted": False, "grounded": p, "reason": "ungrounded"}
    return {"accepted": True, "grounded": p, "reason": "ok"}
