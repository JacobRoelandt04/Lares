"""The title a picture of the day wears on its card: the file name made short.

    short_title(file_title, description, chat=None, log=None) -> (title, how)
    clean(file_title)                  deterministic: dates, camera codes, trailing places, a bracketed binomial out
    cut(text, limit=LIMIT)             at a word boundary, "..." when it had to
    ollama_chat(model, url, ...)       the `chat` a caller hands in: messages -> the model's text

A Commons file name is a caption written for a catalogue: "Pez ballesta ondulado (Balistapus undulatus), mar Rojo,
Egipto, 2023-04-15, DD 45.jpg". The card's title row holds two lines (WikiTitleRow, 16 bold), about 48 characters.

1. `clean`: the extension and underscores go (daily.potd_title), the name is split at top-level commas, " - ", "|" and
   ";" into segments, and the segments that are a date, a camera or file-counter code (IMG_1234, DD 45, P1010123), a
   crop/edit note or a credit are dropped, as are ISO and compact dates inside a segment. The FIRST remaining segment is
   the subject; the rest is the trailing place list and goes (a subject of one or two words keeps the next segment:
   "Bell tower, Split" and "Gran Canaria, Roque Nublo" are nothing without it). A bracketed binomial ("(Balistapus undulatus)") goes when a name stands
   before it. What is left is the title when it fits `LIMIT`.
2. Too long still: a short title from the local model, given the file title AND the feed's English description. It is
   asked with the pipeline's writer (models.json `write.model`, the one the intro writer already uses for text: the Jev
   judge answers questions with probabilities, it writes nothing). The answer is CHECKED BY CODE, never trusted: one
   line, within LIMIT, no meta phrase and no recital of the prompt's rules (a small model recites what it is told:
   generate.meta_problem and TITLE_META), and every word of it must be a word of the file title or the description
   (the writer that embellishes loses). One retry with the problem fed back, like write_intro.
3. Else (no model, a bad answer): the cleaned title cut at a word boundary.

The full file title stays where it was: the entry's source.title and url (the link) are the originals.
"""
from __future__ import annotations

import re
import unicodedata

from . import generate, judge
from .judge import JudgeError, JudgeUnavailable, fill, prompts

LIMIT = 48
MAX_WORDS = 8
ELLIPSIS = "…"

_EXT = re.compile(r"\.(?:jpe?g|png|webp|tiff?|gif|svg)$", re.I)
_MONTHS = (r"jan(?:uary|uar|vier)?|feb(?:ruary|ruar|rero)?|f[eé]v(?:rier)?|mar(?:ch|zo|s)?|m[aä]r(?:z)?|apr(?:il)?|abr(?:il)?|"
           r"may|mai|mayo|jun(?:e|io|i)?|juin|jul(?:y|io|i)?|juil(?:let)?|aug(?:ust)?|ago(?:sto)?|aou?t|"
           r"sep(?:t(?:ember)?)?|set(?:tembre)?|oct(?:ober|obre|ubre)?|okt(?:ober)?|nov(?:ember|iembre|embre)?|"
           r"dec(?:ember)?|dic(?:iembre)?|d[eé]c(?:embre)?|dez(?:ember)?")
_YEAR = r"(?:1[5-9]|20)\d\d"
_DATE_SEG = re.compile(
    r"^\W*(?:(?:\d{1,2}(?:st|nd|rd|th|\.|er)?\s+(?:de\s+)?)?(?:%s)\.?(?:\s+de)?\s+(?:\d{1,2}[,.]?\s+)?%s|"
    r"(?:%s)\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+%s|%s|\d{1,2}[-/.]\d{1,2}[-/.]%s|%s[-_./]\d{1,2}[-_./]\d{1,2})\W*$"
    % (_MONTHS, _YEAR, _MONTHS, _YEAR, _YEAR, _YEAR, _YEAR), re.I)
_DATE_IN = re.compile(r"(?<!\d)(?:%s)[-_./]\d{1,2}[-_./]\d{1,2}(?!\d)|(?<!\d)(?:19|20)\d{6}(?!\d)" % _YEAR)
_CODE_SEG = re.compile(
    r"^\W*(?:(?:img|dsc[nf]?|pxl|mvi|dji|gopr|p)[\s_-]?\d[\w\s-]*|(?:[A-Za-z]{1,5}[\s_-]*)?\d{1,8}(?:[\s_-]\d{1,4})?|\(?\d+\)?)\W*$", re.I)
_NOTE_SEG = re.compile(r"^\W*(?:crop(?:ped)?|edit(?:ed)?|retouch(?:ed)?|restored|hdr|v\d+|rev\.?\s*\d+|copy|kopie|\d+x\d+)\W*$", re.I)
_CREDIT_SEG = re.compile(r"^\W*(?:by|photo(?:graph)?(?:\s+by)?|foto(?:\s+de|\s+von)?|©)\s+\S", re.I)
_BINOMIAL = re.compile(r"\s*\((?:[A-Z][a-z]+(?:\s+[a-z]{3,}){1,2}|[A-Z]\.\s*[a-z]{3,}(?:\s+[a-z]{3,})?)\)")
_NOISE_PAREN = re.compile(r"\s*\((?:\d{1,3}|crop(?:ped)?|edit(?:ed)?|cut|retouched|[A-Za-z_-]{0,8}\d{3,}[A-Za-z]?)\)", re.I)
_CODE_IN = re.compile(r"\s*\b(?:img|dsc[nf]?|pxl|mvi|dji|gopr)[\s_-]?\d+\b", re.I)
_SPLIT_AFTER = (",", ";", "|")
_SPLIT_SPACED = (" - ", " – ", " — ")


def file_name(file_title):
    """"File:Split_Cathedral_Bell_Tower - Split.jpg" -> "Split Cathedral Bell Tower - Split"."""
    t = re.sub(r"^file:", "", (file_title or "").strip(), flags=re.I)
    t = _EXT.sub("", t)
    return " ".join(t.replace("_", " ").split())


def _segments(name):
    """The name split at commas, semicolons, bars and spaced dashes that stand outside every bracket."""
    out, buf, depth, i = [], [], 0, 0
    while i < len(name):
        ch = name[i]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth = max(0, depth - 1)
        if depth == 0:
            spaced = next((s for s in _SPLIT_SPACED if name.startswith(s, i)), None)
            if ch in _SPLIT_AFTER or spaced:
                out.append("".join(buf))
                buf = []
                i += len(spaced) if spaced else 1
                continue
        buf.append(ch)
        i += 1
    out.append("".join(buf))
    return [s.strip() for s in out if s.strip()]


def _noise(seg):
    return bool(_DATE_SEG.match(seg) or _CODE_SEG.match(seg) or _NOTE_SEG.match(seg) or _CREDIT_SEG.match(seg))


def _words(s):
    return [w for w in re.findall(r"\w+", s, flags=re.U)]


def clean(file_title):
    """The deterministic short form of a file title (may still exceed LIMIT)."""
    name = file_name(file_title)
    if not name:
        return ""
    segs = [s for s in (_NOISE_PAREN.sub("", _CODE_IN.sub("", _DATE_IN.sub(" ", s))).strip(" -_") for s in _segments(name)) if s and not _noise(s)]
    if not segs:
        return name
    subject = _NOISE_PAREN.sub("", segs[0]).strip()
    bare = _BINOMIAL.sub("", subject).strip()
    if any(len(w) >= 3 for w in _words(bare)):
        subject = bare
    if len(_words(subject)) <= 2 and len(segs) > 1:
        subject = subject + ", " + segs[1]
    return " ".join(subject.split()) or name


def cut(text, limit=LIMIT):
    """`text` at a word boundary within `limit` characters, with an ellipsis when it was cut."""
    text = " ".join((text or "").split())
    if len(text) <= limit:
        return text
    head = text[:limit - 1]
    if " " in head and not text[limit - 1:limit].isspace():
        head = head.rsplit(" ", 1)[0]
    return head.rstrip(" ,;:-–—(") + ELLIPSIS


# ----------------------------------------------------------------------------- the model's short title

# What a model writes when it recites the prompt or talks about its task instead of titling.
TITLE_META = re.compile(r"\b(?:short(?:er|ened)?\s+title|file\s+title|the\s+title|the\s+description|at\s+most|"
                        r"\d+\s+(?:words|characters)|here(?:'s|\s+is)|this\s+(?:image|picture|photo|file)|"
                        r"commons|wikimedia)\b", re.I)


def _fold(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s.casefold()) if not unicodedata.combining(c))


def _vocab(*texts):
    return {_fold(w) for t in texts for w in _words(t)}


def _in_vocab(word, vocab):
    w = _fold(word)
    if w in vocab:
        return True
    # a plural, a gender, a case: one word is the start of the other, at least four letters shared
    return len(w) >= 4 and any(len(v) >= 4 and (v.startswith(w[:max(4, len(w) - 2)]) or w.startswith(v[:max(4, len(v) - 2)]))
                               for v in vocab)


def title_problem(text, file_title, description):
    """Why a model's short title is unusable, in words the retry can hand back; None when it is fine."""
    t = (text or "").strip()
    if not t:
        return "is empty"
    if "\n" in t:
        return "is more than one line"
    if len(t) > LIMIT:
        return "has %d characters" % len(t)
    ws = _words(t)
    if not any(len(w) >= 3 for w in ws):
        return "is too short to be a title"
    if len(ws) > MAX_WORDS:
        return "has %d words" % len(ws)
    meta = generate.meta_problem(t) or (TITLE_META.search(t) or [None])[0]
    if meta:
        return "talks about the task ('%s')" % meta
    vocab = _vocab(file_name(file_title), description)
    alien = [w for w in ws if len(w) >= 4 and not _in_vocab(w, vocab)]
    if alien:
        return "uses a word that is in neither the file title nor the description ('%s')" % alien[0]
    return None


def _tidy(text):
    """The title out of a model's reply: the first non-empty line, markdown and wrapping quotes off, no full stop."""
    t = generate.strip_markdown(text or "")
    t = next((ln.strip() for ln in t.splitlines() if ln.strip()), "")
    t = re.sub(r"^(?:short\s+)?title\s*:\s*", "", t, flags=re.I)
    if len(t) >= 2 and t[0] in "\"“'" and t[-1] in "\"”'":
        t = t[1:-1].strip()
    return t.rstrip(".").strip()


def ask_model(file_title, description, chat, log=lambda m: None):
    """The model's short title, checked, or None. `chat(messages) -> text`; JudgeUnavailable is the caller's no."""
    P = prompts()["title"]
    desc = " ".join((description or "").split())[:600]
    messages = [{"role": "system", "content": P["system"]},
                {"role": "user", "content": fill(P["user"], title=file_name(file_title), description=desc or "(none)")}]
    for attempt in range(2):
        raw = chat(messages)
        t = _tidy(raw)
        problem = title_problem(t, file_title, desc)
        if problem is None:
            return t
        log("picture of the day: the model's short title %r %s" % (t[:60], problem))
        messages = messages + [{"role": "assistant", "content": raw or ""},
                               {"role": "user", "content": fill(P["feedback"], problem=problem)}]
    return None


def short_title(file_title, description="", chat=None, log=lambda m: None):
    """(title, how): how is "cleaned" (the deterministic form fits), "model" (the checked short title of the local
    model) or "cut" (the cleaned form cut at a word boundary: no model, or no usable answer)."""
    base = clean(file_title)
    if len(base) <= LIMIT:
        return base, "cleaned"
    if chat is not None:
        try:
            t = ask_model(file_title, description, chat, log)
        except (JudgeUnavailable, JudgeError) as e:
            log("picture of the day: no model title (%s)" % e)
            t = None
        if t:
            return t, "model"
    return cut(base), "cut"


def ollama_chat(model, url=judge.DEFAULT_OLLAMA_URL, *, client=None, transport=None):
    """The `chat` of short_title on a resident Ollama model: temperature 0, a fixed seed, a few tokens."""
    from . import judge_ollama
    c = client or judge_ollama.OllamaClient(url, transport=transport)

    def chat(messages):
        return c.chat(model, messages, None, {"temperature": 0, "seed": 7, "num_predict": 40})["content"]
    return chat
