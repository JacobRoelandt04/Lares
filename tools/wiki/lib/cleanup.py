"""Deterministic cleanup of a lead's paragraphs (PLAN.md "Text": marked with the pencil).

    clean(paras, wiki) -> (paras, stripped_codes)

`paras` is what htmltext.paragraphs() returns (link offsets in UTF-16 units). Nothing here asks a
model. What is removed is data-driven (`data/cleanup_rules.json`), and only when a rule matches:

  * hatnote lines that survived as text ("X" redirects here. For other uses, see ...)
  * citation markers [1] [12][13] [citation needed]; footnote marks [a] [n 1] [note 2]
  * coordinates (51°30′N 0°07′W)
  * inside a parenthesis, clause by clause (clauses are split at ";"): IPA (/ˈɔɪlər/, [baχ]),
    pronunciation respellings (OY-lər, "pronounced ..."), "listen", native-name clauses
    (German: ..., Ancient Greek: ..., lit. '...', romanized: ...), a clause in a non-Latin script,
    birth/death dates ((21 March 1685 - 28 July 1750), (born 1 May 1900)) and, in the lead's subject
    phrase only, year ranges ((1685-1750)). Whether an unmarked range is a life span depends on the
    `person` argument of clean() (True / False / None = judge by the name's shape); "born ..." and
    "died ..." go whatever it says. A clause that is none of these stays: aliases
    ("also known as X", "born Maria Skłodowska") inform. When every clause goes, the parenthesis
    goes; when some stay, the parenthesis stays with them.
    a clause that only points elsewhere ("see below", "see § History") goes as `parentheticals`
  * the empty "()" and the doubled space or space before a comma this leaves

Every removal shifts the link offsets that follow it; a link inside a removed span is dropped.
Wikipedia gets all of it; the other wikis only lose markup, citation marks and footnote marks
(a pronunciation on the Arch wiki is worth keeping). `clean` runs its passes to a fixpoint, so
clean(clean(x)) == clean(x): a second call removes nothing and reports the same codes.

Each returned paragraph carries `stripped`, the codes that applied to it (htmltext's plus these), so
the caller can report the codes of the paragraphs it kept (intro.stripped_codes).
"""
from __future__ import annotations

import json
import os
import re
import unicodedata

from .htmltext import CODES, LinkedText, links_from_u16, links_to_u16

_RULES_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "cleanup_rules.json")
_MAX_PASSES = 8


# --------------------------------------------------------------------------------------------
# Rules, compiled once
# --------------------------------------------------------------------------------------------

class _Rules:
    def __init__(self, path: str = _RULES_PATH):
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
        self.raw = raw
        self.wikis = raw["wikis"]
        self.text_rules = {}
        for rid, r in raw["text_rules"].items():
            flags = re.I if "i" in r.get("flags", "") else 0
            self.text_rules[rid] = (r.get("code"), re.compile(r["pattern"], flags))
        h = raw["hatnote_text"]
        self.hatnote_max = h["max_words"]
        self.hatnote = [re.compile(p) for p in h["patterns"]]
        p = raw["parentheticals"]
        self.lead_window = p["lead_window"]
        self.copula = re.compile(p["copula"], re.I)
        self.pronounce = re.compile(p["pronounce_markers"], re.I)
        self.listen = re.compile(p["listen_markers"], re.I)
        self.xref = [re.compile(x, re.I) for x in p["xref_patterns"]]
        self.ipa_set = frozenset(p["ipa_chars"])
        self.ipa_slash = re.compile(r"/[^/\n]{1,70}/")
        self.ipa_bracket = re.compile(r"\[[^\[\]\n]{1,70}\]")
        self.labels = re.compile(
            r"(?<![\w])(?:%s)\s*:" % "|".join(p["ipa_labels"]), re.I)
        langs = "|".join(sorted(map(re.escape, p["languages"]), key=len, reverse=True))
        mods = "|".join(sorted(map(re.escape, p["language_modifiers"]), key=len, reverse=True))
        lang = r"(?:(?:%s)\s+)?(?:%s)" % (mods, langs)
        scripts = "|".join(p["script_labels"])
        label = r"(?:%s|%s)" % (lang, scripts)
        self.native = re.compile(
            r"^%s(?:\s*(?:,|/|and|or|&)\s*%s)*\s*(?:\([^)]*\))?\s*:" % (label, label))
        self.native_lit = re.compile(
            r"^(?:%s)" % "|".join(re.escape(m) for m in p["native_markers"]), re.I)
        self.nonlatin = frozenset(p["nonlatin_scripts"])
        self.event_words = frozenset(w.lower() for w in p["event_words"])
        self.name_particles = frozenset(p["name_particles"])
        self.name_not_first = frozenset(p["name_not_first"])
        months = "|".join(sorted(p["months"], key=len, reverse=True))
        self.month = re.compile(r"\b(?:%s)\b\.?" % months)
        self.born = re.compile(r"\b(?:%s)(?=\s|\d|$)" % "|".join(p["born_markers"]), re.I)
        self.approx = re.compile(r"(?<![\w])(?:%s)(?=\s|\d|$)" % "|".join(p["approx_markers"]), re.I)
        self.empty_parens = re.compile(r"(?<!\w)\(\s*[;,\s]*\)")


_RULES: _Rules | None = None


def rules() -> _Rules:
    global _RULES
    if _RULES is None:
        _RULES = _Rules()
    return _RULES


# --------------------------------------------------------------------------------------------
# Parentheses
# --------------------------------------------------------------------------------------------

def _match_close(text: str, a: int) -> int | None:
    depth = 0
    for i in range(a, len(text)):
        ch = text[i]
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
    return None


def _split_clauses(text: str, lo: int, hi: int) -> list[tuple[int, int]]:
    """[(start, end)] of the clauses of text[lo:hi], split at ';' outside nested () and []."""
    spans, depth, start = [], 0, lo
    for i in range(lo, hi):
        ch = text[i]
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth = max(0, depth - 1)
        elif ch == ";" and depth == 0:
            spans.append((start, i))
            start = i + 1
    spans.append((start, hi))
    return spans


_DATE_MARKS = str.maketrans({"–": "-", "—": "-", "−": "-", "‒": "-"})


def _date_kind(clause: str, R: _Rules) -> tuple[str | None, bool]:
    """(kind, explicit). kind: "full" (a date range with day or month, or born/died + a full date),
    "born" (born/died + a year), "years" (a year range), or None. A single date without born/died is
    not a life span. `explicit` is True when the clause says born / died / baptised / buried."""
    s = clause
    s = re.sub(r"\[[^\]]*\]", " ", s)
    s = re.sub(r"\(?\b[ON]\.S\.\)?", " ", s)
    s = re.sub(r",?\s*\baged\s+\d+", " ", s)
    s = s.translate(_DATE_MARKS)
    s = re.sub(r"\b(?:AD|CE)\s?\d{1,4}\b|\b\d{1,4}(?:/\d{1,4})?\s?(?:BC|BCE|AD|CE|B\.C\.|A\.D\.)(?!\w)", "Y", s)
    s = R.month.sub("M", s)
    born = bool(R.born.search(s))
    s = R.born.sub("B", s)
    s = R.approx.sub("C", s)
    s = re.sub(r"\b\d{3,4}(?:/\d{1,2})?\b", "Y", s)
    s = re.sub(r"\b\d{1,2}(?:st|nd|rd|th)?\b", "D", s)
    s = re.sub(r"\b(?:or|to)\b", "-", s)
    s = re.sub(r"[\s,]+", "", s)
    item = r"[BC]*(?:D(?:-D)?MY|MD(?:-D)?Y|MY|D(?:-D)?M|MD(?:-D)?|Y)\??"
    if not re.fullmatch(r"%s(?:-(?:%s)?)?" % (item, item), s):
        return None, False
    has_dm = "D" in s or "M" in s
    if born:
        return ("full" if has_dm else "born"), True
    if "-" in s:
        return ("full" if has_dm else "years"), False
    return None, False


def _subject_run(before: str, R: _Rules) -> list[str]:
    """The capitalised words (with name particles, initials, Roman numerals) that end `before`: the
    noun phrase a parenthesis is attached to. "the Second World War" -> [Second, World, War]."""
    run: list[str] = []
    for i, tok in enumerate(reversed(before.split())):
        if i and tok[-1:] in (",", ";", ":"):
            break                                    # a comma before the phrase ends it
        w = tok.strip(",;:")
        if w and (w[0].isupper() or w in R.name_particles):
            run.append(w)
        else:
            break
    run.reverse()
    while run and run[0] in R.name_particles:
        run.pop(0)
    return run


def _looks_like_person(before: str, R: _Rules) -> bool:
    """Cheap: does the phrase in front of the parenthesis read as a personal name (two or more
    capitalised words, none of them an event, place-type or institution word)?"""
    run = _subject_run(before, R)
    if len(run) < 2 or run[0] in R.name_not_first:
        return False
    return not any(w.lower() in R.event_words for w in run)


def _unmarked_dates_ok(person: bool | None, before: str, R: _Rules) -> bool:
    """May a date range that does not say born/died be taken for a life span?"""
    if person is None:
        return _looks_like_person(before, R)
    return bool(person)


def _only_nonlatin(clause: str, R: _Rules) -> bool:
    seen = False
    for ch in clause:
        if not ch.isalpha():
            continue
        try:
            script = unicodedata.name(ch).split()[0]
        except ValueError:
            return False
        if script == "LATIN" or script not in R.nonlatin:
            return False
        seen = True
    return seen


def _ipa_atoms(s: str, R: _Rules) -> tuple[str, bool]:
    """`s` with every /.../ and [...] that holds an IPA letter blanked out; and whether any was."""
    hit = [False]

    def blank(m):
        if any(ch in R.ipa_set for ch in m.group(0)):
            hit[0] = True
            return " "
        return m.group(0)

    s = R.ipa_slash.sub(blank, s)
    s = R.ipa_bracket.sub(blank, s)
    return s, hit[0]


_SYL = re.compile(r"[A-Za-z\u0259\u026a\u028a\u025b\u0254\u00e6\u028c\u0251\u0252\u02c8\u02cc']+")
_SYL_SEP = re.compile("[-\u2010\u2011\u2027\u00b7]")
_TOKEN_SPLIT = re.compile(r"[\s,/]+|\bor\b|\band\b")


def _is_strong_respelling(tok: str) -> bool:
    """Hyphenated syllables with a stressed all-caps one: OY-lər, JOH-hahn, BAKH-ə."""
    parts = _SYL_SEP.split(tok)
    return (len(parts) >= 2 and all(_SYL.fullmatch(p) for p in parts)
            and any(re.fullmatch(r"[A-Z]+", p) for p in parts))


def _respelling(s: str, ipa: bool) -> bool:
    """Is `s` nothing but pronunciation respellings? A bare all-caps "BAKH" only counts beside a
    strong one or an IPA atom (a lone acronym is an acronym)."""
    strong = bare = 0
    for tok in _TOKEN_SPLIT.split(s):
        tok = tok.strip("\u2009\u202f\"'\u201c\u201d")
        if not tok:
            continue
        if _is_strong_respelling(tok):
            strong += 1
        elif re.fullmatch(r"[A-Z]{2,}", tok):
            bare += 1
        else:
            return False
    return strong > 0 or (bare > 0 and ipa)


def _classify_clause(clause: str, lead: bool, R: _Rules, unmarked_ok: bool) -> tuple[bool | None, set]:
    """(remove this clause?, the codes it counts as). None: a "lit. ..." gloss, which goes only in the
    lead's subject phrase or beside a native name that goes."""
    c = clause.strip()
    if not c:
        return True, set()
    codes: set = set()
    if R.native.match(c):
        codes.add("native_names")
        if _ipa_atoms(c, R)[1]:
            codes.add("ipa")
        if R.pronounce.search(c):
            codes.add("pronunciation")
        return True, codes
    if R.native_lit.match(c):                        # a gloss of a native name: decided by _handle_paren
        return None, {"native_names"}
    if R.pronounce.search(c):
        codes.add("pronunciation")
        if _ipa_atoms(c, R)[1]:
            codes.add("ipa")
        return True, codes
    kind, explicit = _date_kind(c, R)
    if kind == "born" or (explicit and kind) or (unmarked_ok and (kind == "full" or (kind == "years" and lead))):
        return True, {"dates"}
    if any(x.match(c) for x in R.xref):              # "(see below)", "(see § History)"
        return True, {"parentheticals"}
    if _only_nonlatin(c, R):
        return True, {"native_names"}
    rest, ipa = _ipa_atoms(c, R)
    rest = R.labels.sub(" ", rest)
    if ipa:
        codes.add("ipa")
    if R.listen.search(rest):
        rest = R.listen.sub(" ", rest)
        codes.add("pronunciation")
    rest = re.sub(r"\b(?:or|and|also)\b", " ", rest).strip(" ,;/-\u2013")
    if not rest:
        return bool(codes), codes
    if _respelling(rest, ipa):
        codes.add("pronunciation")
        return True, codes
    parts = [x for x in re.split(r",\s*(?![^()\[\]]*[)\]])", c) if x.strip()]
    if len(parts) > 1:                               # "/bjɜːrk/ BYURK, Icelandic: [...]": every part must go
        sub = [_classify_clause(x, lead, R, unmarked_ok) for x in parts]
        if all(v[0] for v in sub):
            return True, set().union(*(v[1] for v in sub))
    return False, set()


def _handle_paren(lt: LinkedText, a: int, b: int, codes: set, first_prose: bool, R: _Rules,
                  person: bool | None) -> bool:
    """Classify the clauses of the parenthesis at text[a..b] (b is its ')') and cut the ones that
    match. True if anything was cut."""
    text = lt.text
    if not re.search(r"\w", text[a + 1:b]):
        return False                                 # "()" and "(;)": the empty_parens rule's, not a clause's
    lead = (first_prose and a <= R.lead_window
            and not R.copula.search(text[:a])
            and not re.search(r"[.!?]\s", text[:a]))
    unmarked_ok = _unmarked_dates_ok(person, text[:a], R)
    spans = _split_clauses(text, a + 1, b)
    verdicts = [_classify_clause(text[s:e], lead, R, unmarked_ok) for s, e in spans]
    has_native = any(v[0] and "native_names" in v[1] for v in verdicts)
    verdicts = [(bool(v[0] if v[0] is not None else (lead or has_native)), v[1]) for v in verdicts]
    if not any(v[0] for v in verdicts):
        return False
    if all(v[0] for v in verdicts):
        for _, cs in verdicts:
            codes |= cs
        lt.cut(a, b + 1)
        return True
    n = len(spans)
    i = n - 1
    while i >= 0:                                    # runs of removable clauses, last run first
        if not verdicts[i][0]:
            i -= 1
            continue
        j = i
        while j - 1 >= 0 and verdicts[j - 1][0]:
            j -= 1
        for k in range(j, i + 1):
            codes |= verdicts[k][1]
        if i < n - 1:
            lt.cut(spans[j][0], spans[i + 1][0])     # the run and the ';' after it
        else:
            lt.cut(spans[j - 1][1], spans[i][1])     # the ';' before it and the run
        i = j - 1
    return True


def _process_parens(lt: LinkedText, codes: set, first_prose: bool, R: _Rules, person: bool | None) -> bool:
    changed = False
    for a in reversed([i for i, ch in enumerate(lt.text) if ch == "("]):
        if a >= len(lt.text) or lt.text[a] != "(":
            continue
        b = _match_close(lt.text, a)
        if b is not None and _handle_paren(lt, a, b, codes, first_prose, R, person):
            changed = True
    return changed


# --------------------------------------------------------------------------------------------
# One paragraph
# --------------------------------------------------------------------------------------------

_FIXUPS = (
    (re.compile(r"[ \t]{2,}"), " "),
    (re.compile(r"\s+(?=[,.;:!?)\]”’])"), ""),
    (re.compile(r"(?<=[(\[“‘])\s+"), ""),
    (re.compile(r",(?:\s*,)+"), ","),
)


def _fixups(lt: LinkedText) -> None:
    for pat, repl in _FIXUPS:
        lt.sub(pat, repl)
    lt.normalize_ws()


def _clean_para(p: dict, active: list, first_prose: bool, R: _Rules, person: bool | None) -> dict | None:
    text = p["text"]
    lt = LinkedText(text, links_from_u16(text, p["links"]))
    codes = set(p.get("stripped") or ())
    for _ in range(_MAX_PASSES):
        changed = False
        for rid in ("markup", "citations", "notes", "coordinates"):
            if rid in active:
                code, pat = R.text_rules[rid]
                hit = pat.search(lt.text) is not None
                if hit:
                    lt.sub(pat, "")
                    changed = True
                    if code:
                        codes.add(code)
        if "parentheticals" in active:
            changed |= _process_parens(lt, codes, first_prose, R, person)
        if "empty_parens" in active and R.empty_parens.search(lt.text):
            lt.sub(R.empty_parens, "")
            changed = True
        if not changed:
            break
        _fixups(lt)
    if not any(ch.isalnum() for ch in lt.text):
        return None
    lt.trim_links()
    out = dict(p)
    out["text"] = lt.text
    out["links"] = links_to_u16(lt.text, lt.links)
    out["stripped"] = [c for c in CODES if c in codes]
    return out


def _is_hatnote_text(p: dict, R: _Rules) -> bool:
    if p["kind"] != "p" or len(p["text"].split()) > R.hatnote_max:
        return False
    return any(pat.search(p["text"]) for pat in R.hatnote)


def clean(paras: list[dict], wiki: str, person: bool | None = None) -> tuple[list[dict], list[str]]:
    """Cleaned copies of `paras` and the union of the codes applied, in CODES order.

    `person` says whether the article is about a person, which decides what a date range in the
    subject's parenthesis is: a life span (strip) or the article's core fact ("World War II (1
    September 1939 - 2 September 1945)": keep).
      True   strip date ranges, as a birth-death pair.
      False  keep every date range; only a clause that says born / died / baptised / buried goes.
      None   unknown: strip an unmarked range only when the phrase in front of the parenthesis reads
             as a personal name (two or more capitalised words, none an event or institution word:
             War, Battle, Empire, University ...); otherwise keep it. A kept date is harmless, a
             stripped event date is a loss."""
    R = rules()
    active = R.wikis.get(wiki, R.wikis["default"])
    items = []
    for p in paras:                                  # copies: the input is never touched
        q = dict(p)
        q["links"] = [dict(l) for l in p.get("links", ())]
        q["stripped"] = list(p.get("stripped") or ())
        items.append(q)
    if "hatnote_text" in active:                     # hatnotes that reached us as text
        i = 0
        while i < len(items) and _is_hatnote_text(items[i], R):
            i += 1
        if i:
            items = items[i:]
            if items:
                items[0]["stripped"] = sorted(set(items[0]["stripped"]) | {"hatnote"}, key=CODES.index)
    first = next((k for k, p in enumerate(items) if p["kind"] in ("p", "dd")), -1)
    out = []
    for k, p in enumerate(items):
        if p["kind"] in ("pre", "heading"):
            out.append(p)
            continue
        q = _clean_para(p, active, k == first, R, person)
        if q is not None:
            out.append(q)
    codes = {c for p in out for c in (p.get("stripped") or ())}
    return out, [c for c in CODES if c in codes]
