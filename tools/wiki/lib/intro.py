"""Choosing the intro: whole paragraphs, 80-150 words, never a cut sentence (PLAN.md "Text").

    cut(paras, min_words=80, max_words=150) -> (paras, words)
    numbered(paras)                         -> the judge's view, "[0] text\\n\\n[1] text ..."
    select(paras, indices)                  -> the paragraphs a locator picked
    join(paras, sep="\\n")                   -> (one block, links on it, words) for the entry's intro.text
    sentences(text)                         -> [(start, end)] sentence spans (code points)
    stripped_codes(paras)                   -> the cleanup codes of exactly these paragraphs

`cut` works on what cleanup.clean() returned (word counts are of the cleaned text). It takes whole
leading prose paragraphs (kind p or dd) until it has min_words, and stops before a paragraph that would
take it over max_words. Leading headings, code, list items, epigraphs ("..." - Linus T.), pointers
("See the terminal emulator article", "For the fork, see X") and pure lead-ins ("From the project web
page:") are skipped; it stops at the first heading, code block, list item or pointer after the start,
and before a lower-case dd (a fragment that continues a lead-in). A paragraph that ends in ':' before a
dd / list / code block loses its closing sentence ("There are two approaches:") and keeps the rest.
If the FIRST paragraph alone is over max_words it is cut at the last sentence end within max_words (or,
when even its first sentence is longer, at that sentence's end). Links that fall past the cut are
dropped. If everything is under min_words it returns what there is: the judge decides. A word is a
whitespace-separated token.

Measured on 49 live Wikipedia leads (the "cut at a paragraph end" rule): 25 land in 80-150 words, 24
fall under 80 (14 under 65) because a short first paragraph is followed by a long one. With
`sentence_fill=True` (off by default) the next paragraph's whole sentences top such an intro up:
all 49 land in 80-150, and none ends mid-sentence.

The sentence splitter does not split on e.g. / i.e. / etc. / vs., titles and units (Mr. Dr. St. Mt.),
initials (J. S. Bach), dotted acronyms (U.S. a.m.), "c. 1066" or "No. 5", decimals (no space after the
dot), or a dot followed by a lower-case word. It errs towards NOT splitting: a missed boundary only makes
the cut earlier, a false one would cut a sentence in half.
"""
from __future__ import annotations

import json
import os
import re

from .htmltext import CODES, cp_to_u16

_RULES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "cleanup_rules.json")
_PROSE = ("p", "dd")

_DATA: dict | None = None


def _data() -> dict:
    global _DATA
    if _DATA is None:
        with open(_RULES_PATH, encoding="utf-8") as f:
            raw = json.load(f)
        _DATA = {
            "abbr": frozenset(a.lower() for a in raw["abbreviations"]),
            # abbreviations that only count before a digit: "No. 5", "vol. 3"
            "numbered_abbr": frozenset(a.lower() for a in raw["numbered_abbreviations"]),
            "pointers": [re.compile(p) for p in raw["intro"]["pointer_patterns"]],
        }
    return _DATA


def _abbreviations() -> tuple:
    d = _data()
    return d["abbr"], d["numbered_abbr"]


def words(text: str) -> int:
    return len(text.split())


# --------------------------------------------------------------------------------------------
# Sentences
# --------------------------------------------------------------------------------------------

_BOUNDARY = re.compile(r"([.!?…]+)([\"'”’)\]»]*)(\s+)")
_OPENERS = "\"'“‘([«"


def _starts_sentence(text: str, i: int, dot_ok_digit: bool) -> bool:
    """May a sentence start at text[i]? An upper-case letter, or an opening quote/bracket and then
    one; a digit only when the caller says the dot before it was a real full stop."""
    if i >= len(text):
        return False
    ch = text[i]
    while ch in _OPENERS and i + 1 < len(text):
        i += 1
        ch = text[i]
    if ch.isdigit():
        return dot_ok_digit
    return ch.isupper()


def sentences(text: str) -> list[tuple[int, int]]:
    """Spans (start, end) of the sentences of `text`; end excludes the space that follows."""
    abbr, numbered_abbr = _abbreviations()
    spans, start = [], 0
    for m in _BOUNDARY.finditer(text):
        term = m.group(1)
        nxt = m.end()
        if term.startswith("."):
            before = text[start:m.start()]
            tok = before.split()[-1] if before.split() else ""
            tok = tok.lstrip("\"'“‘([«")
            low = tok.lower().rstrip(".")
            if len(term) == 1:
                if (low in abbr or re.fullmatch(r"[A-Za-z]", tok)
                        or re.fullmatch(r"(?:[A-Za-z]{1,3}\.)+[A-Za-z]{0,3}", tok)):
                    continue                       # e.g.  J.  U.S.  a.m.  Ph.D.  Mr.  etc.
                if low in numbered_abbr and text[nxt:nxt + 1].isdigit():
                    continue                       # No. 5   vol. 3
            digit_ok = len(term) == 1 and low not in abbr and len(tok) >= 3 and not tok.isdigit()
        else:
            digit_ok = True
        if not _starts_sentence(text, nxt, digit_ok):
            continue
        spans.append((start, m.start() + len(term) + len(m.group(2))))
        start = nxt
    if start < len(text.rstrip()):
        spans.append((start, len(text.rstrip())))
    return spans


# --------------------------------------------------------------------------------------------
# Cutting
# --------------------------------------------------------------------------------------------

def is_lead_in(paras: list[dict], i: int) -> bool:
    """A paragraph that ends in ':' and introduces the quote, list or code block right after it."""
    p = paras[i]
    if p["kind"] not in _PROSE or not p["text"].rstrip().endswith(":"):
        return False
    return i + 1 < len(paras) and paras[i + 1]["kind"] in ("dd", "li", "pre")


def _is_pointer(p: dict) -> bool:
    """"See the terminal emulator article ...", "For the 2025 fork, see X.": a pointer, not an intro."""
    return p["kind"] in _PROSE and any(pat.match(p["text"]) for pat in _data()["pointers"])


def _is_epigraph(p: dict) -> bool:
    """A dd that is a quotation with an attribution: "..." - Linus T."""
    t = p["text"].strip()
    return (p["kind"] == "dd" and t[:1] in "\"\u201c\u2018"
            and re.search(r"[\"\u201d\u2019]\s*[\u2014\u2013-]{1,2}\s*[^.]{1,40}\.?$", t) is not None)


def _copy(p: dict) -> dict:
    q = dict(p)
    q["links"] = [dict(l) for l in p.get("links", ())]
    if "stripped" in q:
        q["stripped"] = list(q["stripped"])
    return q


def _prefix(p: dict, end: int) -> dict:
    """A copy of `p` cut at code-point `end`, the links that reach past it dropped."""
    text = p["text"]
    q = _copy(p)
    q["text"] = text[:end].rstrip()
    limit = cp_to_u16(text, len(q["text"]))
    q["links"] = [l for l in q["links"] if l["e"] <= limit]
    return q


def _sentence_cut(text: str, max_words: int) -> int:
    """Index in `text` (code points) to cut a paragraph that is too long: the end of the last sentence
    that fits max_words, or the end of the first sentence when even that is too long."""
    best = None
    for s, e in sentences(text):
        if words(text[:e]) <= max_words:
            best = e
        elif best is None:
            return e
        else:
            break
    return best if best is not None else len(text)


def _fit_prefix(p: dict, room: int) -> dict | None:
    """The longest run of whole sentences at the start of `p` that fits `room` words, or None."""
    text = p["text"]
    best = None
    for _, e in sentences(text):
        if words(text[:e]) > room:
            break
        best = e
    return None if best is None else _prefix(p, best)


def _candidate(paras: list[dict], j: int) -> dict | None:
    """paras[j] as an intro paragraph: itself, or minus the closing sentence that only introduces
    the list / quote / code after it ("There are two approaches:"), or None when that is all it is."""
    p = paras[j]
    if not is_lead_in(paras, j):
        return p
    sents = sentences(p["text"])
    if len(sents) < 2:
        return None
    return _prefix(p, sents[-2][1])


def cut(paras: list[dict], min_words: int = 80, max_words: int = 150,
        sentence_fill: bool = False) -> tuple[list[dict], int]:
    """The intro of a page: (paragraphs, their word count). See the module docstring.
    `sentence_fill` (off by default, the plan says "cut at a paragraph end"): when the next whole
    paragraph would take a too-short intro over max_words, add as many of its whole sentences as fit."""
    picked: list[dict] = []
    total = 0
    for j, p in enumerate(paras):
        if not picked:
            if p["kind"] not in _PROSE or not p["text"].strip() or _is_epigraph(p) or _is_pointer(p):
                continue                                 # leading junk
        else:
            if p["kind"] not in _PROSE or _is_pointer(p):
                break
            if p["kind"] == "dd" and p["text"][:1].islower():
                break                                    # a fragment that continues a lead-in
        cand = _candidate(paras, j)
        if cand is None:
            if picked:
                break
            continue
        w = words(cand["text"])
        if not picked:
            if w > max_words:
                q = _prefix(cand, _sentence_cut(cand["text"], max_words))
                return [q], words(q["text"])
            picked.append(_copy(cand))
            total = w
        else:
            if total + w > max_words:
                if sentence_fill and total < min_words:
                    extra = _fit_prefix(cand, max_words - total)
                    if extra is not None:
                        picked.append(extra)
                        total += words(extra["text"])
                break
            picked.append(_copy(cand))
            total += w
        if total >= min_words:
            break
    return picked, total


# --------------------------------------------------------------------------------------------
# The judge's view, and the locator's answer
# --------------------------------------------------------------------------------------------

def numbered(paras: list[dict]) -> str:
    """"[0] text" blocks separated by a blank line. Code is "[n] (code) ..." (one line, at most 200
    characters), a heading "[n] (heading) ...", a list item "[n] (list) ..."."""
    out = []
    for i, p in enumerate(paras):
        kind, text = p["kind"], p["text"]
        if kind == "pre":
            one = " ".join(text.split())
            out.append("[%d] (code) %s" % (i, one if len(one) <= 200 else one[:200].rstrip() + "…"))
        elif kind == "heading":
            out.append("[%d] (heading) %s" % (i, text))
        elif kind == "li":
            out.append("[%d] (list) %s" % (i, text))
        else:
            out.append("[%d] %s" % (i, text))
    return "\n\n".join(out)


def join(paras: list[dict], sep: str = "\n") -> tuple[str, list[dict], int]:
    """One block for the entry's `intro.text`: the paragraphs' texts joined by `sep` (a line break by
    default), their links shifted onto it (UTF-16 units, so `sep` counts as len(sep) units), and the
    word count. `cut` itself returns the paragraphs separately and joins nothing."""
    texts, links, offset = [], [], 0
    for p in paras:
        for l in p.get("links", ()):
            m = dict(l)
            m["s"] += offset
            m["e"] += offset
            links.append(m)
        texts.append(p["text"])
        offset += cp_to_u16(p["text"], len(p["text"])) + cp_to_u16(sep, len(sep))
    return sep.join(texts), links, sum(words(t) for t in texts)


def select(paras: list[dict], indices) -> list[dict]:
    """The paragraphs at `indices` (the locator's pick), in the order given, each once; an index that
    is not a valid position is ignored."""
    out, seen = [], set()
    for i in indices or ():
        try:
            k = int(i)
        except (TypeError, ValueError):
            continue
        if 0 <= k < len(paras) and k not in seen:
            seen.add(k)
            out.append(_copy(paras[k]))
    return out


def stripped_codes(paras: list[dict]) -> list[str]:
    """The `intro.stripped` of exactly these paragraphs, in the contract's order."""
    have = {c for p in paras for c in (p.get("stripped") or ())}
    return [c for c in CODES if c in have]
