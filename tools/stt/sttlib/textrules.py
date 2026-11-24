"""The final text's rules (round 5, the user's answers): what is written differs from what the recogniser wrote only where a named rule
says so, and every rule that fired is named in the `seg`'s `rules`. Config: shell.jsonc `dictation.text`, handed over verbatim by the
helper's `start` (a missing object, or a missing key, is the default below).

  codes         (round 8, the user's "arbitrary codes should also work") a run of spelled characters -- letters said one by one, digit
                words, digits, the model's letter groups ("QR ST"), "underscore" / "dash" / "hyphen" / "dot" between them -- is ONE code,
                letters in capitals: "X nine five Z B three oh nine underscore QR ST" -> "X95ZB309_QRST". A run needs three pieces that
                mix letters and digits (and a letter said alone), or a connector word and two pieces; "oh" / "o" is a zero only beside
                a digit; plain numbers and single letters in prose stay words ("option A or B", "plan B", "I have two kids", "one two
                three"). English and Dutch number words (not "een", the article). It runs before the F-keys, which it contains: "F one
                zero" is F10 either way
  fkeys         "F ten", "f ten", "F one zero", "F one O", "F 10", "F twenty four" -> F10 ... F24, always (the keybinds: F1-F24 and
                nothing else; "F is for", "F zero" stay)
  signs         "<name> sign" -> the symbol, from the fixed table SIGNS ("greater than sign" -> >, "at sign" -> @); a name alone is
                prose ("greater than expected", "a sign of", "at the end"). The symbol stands as a word of its own
  leadingQuote  a take that BEGINS with "greater than" (or "greater than sign") begins with ">" and the next word capitalised: the
                user's note headers ("Greater than after review" -> "> After review"); a header the recogniser wrote in title case
                (it does for a short take: "Greater Than After Review") is put in sentence case ("> After review"). Not before a
                comparison's complement ("Greater than expected ...", "greater than or equal", a number): those stay words
  words         the user's own map, whole words, case-insensitive, the replacement as written ({"Hyperland": "Hyprland"}); for words
                the recogniser gets wrong that are NEVER right as heard -- not for real words ("teams" / "themes")
  fillers       the user's own words that are dropped wherever they stand, beside "uh", "um" (sttlib/fillers.py): single words, any case
  repeats       "X <filler> X" -> "X" (sttlib/fillers.py drop_repeats; also across a held thinking pause)
  unfinished    a pause after a sentence that has not ended keeps it open like a filler's pause (`hold`, the revision policy), and a
                sentence that continues one written unfinished begins in lower case (`continues`, rule "continue")

Numbers stay words: only an F-key's number becomes digits.

    r = TextRules(cfg)                                          cfg: the `dictation.text` object or None
    text, rules = r.apply(text, lang, first=True, prev=None)   the final text's rules, after the fillers and the tidy pass
    finish(raw, lang, r, first, prev, marks, tidier)           the whole chain a final goes through (the policy and the takes diff)
"""
import re

from . import fillers
from .fillers import core

DEFAULTS = {
    "symbols": {"fkeys": True, "signs": True, "leadingQuote": True, "codes": True},
    "words": {"Hyperland": "Hyprland"},
    "fillers": [],
    "repeats": True,
    "unfinished": True,
}

# ---- numbers (an F-key's only) --------------------------------------------------------------------------------------------------------
UNITS = {"zero": 0, "o": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
         "nine": 9,
         "nul": 0, "een": 1, "één": 1, "twee": 2, "drie": 3, "vier": 4, "vijf": 5, "zes": 6, "zeven": 7, "acht": 8, "negen": 9}
WHOLE = {"ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
         "eighteen": 18, "nineteen": 19, "twenty": 20,
         "tien": 10, "elf": 11, "twaalf": 12, "dertien": 13, "veertien": 14, "vijftien": 15, "zestien": 16, "zeventien": 17,
         "achttien": 18, "negentien": 19, "twintig": 20, "eenentwintig": 21, "tweeëntwintig": 22, "drieëntwintig": 23,
         "vierentwintig": 24}
for _u, _n in (("one", 1), ("two", 2), ("three", 3), ("four", 4)):
    WHOLE["twenty-" + _u] = 20 + _n
FKEY_MAX = 24
_FGLUED = re.compile(r"^f-?(\d{1,2})$")

# ---- codes (round 8) -------------------------------------------------------------------------------------------------------------------
# the digits said one by one ("een" is the article, "o" / "oh" a zero only beside a digit: handled in `_code_runs`)
DIGIT_WORDS = {"zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
               "nine": "9", "nul": "0", "één": "1", "twee": "2", "drie": "3", "vier": "4", "vijf": "5", "zes": "6", "zeven": "7",
               "acht": "8", "negen": "9"}
ZERO_WORDS = {"o", "oh"}
CONNECTORS = {"underscore": "_", "dash": "-", "hyphen": "-", "dot": "."}
_GROUP = re.compile(r"^[A-Z]{2,4}$")
_ALNUM = re.compile(r"^(?=.*[A-Za-z])(?=.*[0-9])[A-Za-z0-9]{2,12}$")
_DIGITS = re.compile(r"^[0-9]{1,12}$")
CODE_AMBIGUOUS = {"A", "I"}                  # words in their own right: part of a code only when it has three other pieces

# ---- signs --------------------------------------------------------------------------------------------------------------------------
SIGNS = [
    (("greater", "than"), ">"), (("less", "than"), "<"), (("forward", "slash"), "/"),
    (("equals",), "="), (("equal",), "="), (("plus",), "+"), (("minus",), "-"), (("hash",), "#"), (("number",), "#"),
    (("ampersand",), "&"), (("at",), "@"), (("asterisk",), "*"), (("underscore",), "_"), (("pipe",), "|"), (("tilde",), "~"),
    (("caret",), "^"), (("dollar",), "$"), (("percent",), "%"), (("percentage",), "%"), (("euro",), "€"),
    (("backslash",), "\\"), (("slash",), "/"), (("degree",), "°"), (("section",), "§"),
]
# "at sign ..." where "sign" begins a word of its own: "look at sign language", "stop at sign posts"
AT_SIGN_NOT = {"language", "languages", "in", "up", "out", "off", "post", "posts", "board", "boards"}
# what follows "greater than" in a comparison: the take's first words are then prose, not a note header
COMPARISON = {"or", "expected", "usual", "ever", "before", "average", "normal", "anticipated", "equal", "planned", "predicted",
              "zero", "that", "this", "the", "a", "an", "any", "anything", "all", "most", "half", "twice"}

# ---- unfinished sentences --------------------------------------------------------------------------------------------------------
# A pause after one of these HOLDS the sentence (costs only time: the sentence is written up to thinkSilenceMs later) ...
HOLD_WORDS = {
    "en": {"the", "a", "an", "to", "and", "of", "or", "but", "with", "in", "on", "for", "from", "my", "your", "our", "their", "its",
           "that", "which", "who", "whose", "at", "by", "as", "into", "onto", "than", "because", "if", "when", "while", "nor"},
    "nl": {"de", "een", "te", "en", "of", "maar", "met", "in", "op", "voor", "van", "naar", "mijn", "jouw", "uw", "onze", "hun", "om",
           "aan", "bij", "als", "omdat", "want"},          # not "het", "je", "dat", "die": "Ik weet het." ends a sentence
}
# ... and a sentence written ending in one of these is CONTINUED by the next (it changes the next one's first letter, so only words a
# sentence cannot end with: "I want to." and "Turn it on." are whole sentences)
OPEN_WORDS = {
    "en": {"the", "a", "an", "my", "your", "our", "their", "its", "and", "or", "but", "nor"},
    "nl": {"de", "een", "mijn", "jouw", "uw", "onze", "en", "maar"},
}
_END = re.compile(r"[.?!…]$")
_CLOSERS = "\"')]}»”’"
_LEAD = re.compile(r"^[^\w]*", re.UNICODE)
_TRAIL = re.compile(r"[^\w']*$", re.UNICODE)


def _parts(tok):
    """(leading punctuation, word, trailing punctuation)."""
    a = _LEAD.match(tok).end()
    b = _TRAIL.search(tok).start()
    if b < a:
        return tok, "", ""
    return tok[:a], tok[a:b], tok[b:]


def _bare(tok):
    """A token with nothing glued to it: no punctuation either side."""
    a, w, b = _parts(tok)
    return bool(w) and not a and not b


def ended(text):
    """The text's last word carries a sentence's end (., ?, !, …), closing quotes and brackets aside."""
    toks = (text or "").split()
    return bool(toks) and bool(_END.search(toks[-1].rstrip(_CLOSERS)))


class TextRules:
    def __init__(self, cfg=None):
        cfg = cfg if isinstance(cfg, dict) else {}
        sym = cfg.get("symbols") if isinstance(cfg.get("symbols"), dict) else {}
        d = DEFAULTS["symbols"]
        self.fkeys = bool(sym.get("fkeys", d["fkeys"]))
        self.signs = bool(sym.get("signs", d["signs"]))
        self.leading_quote = bool(sym.get("leadingQuote", d["leadingQuote"]))
        self.codes = bool(sym.get("codes", d["codes"]))
        self.repeats = bool(cfg.get("repeats", DEFAULTS["repeats"]))
        self.unfinished = bool(cfg.get("unfinished", DEFAULTS["unfinished"]))
        own = cfg.get("fillers") if isinstance(cfg.get("fillers"), list) else DEFAULTS["fillers"]
        self.fillers = frozenset(core(w) for w in own if isinstance(w, str) and len(w.split()) == 1 and core(w))
        words = cfg.get("words") if isinstance(cfg.get("words"), dict) else DEFAULTS["words"]
        self.words = []                    # (key cores, replacement), longest key first
        self.proper = set()                # words the map spells with a capital: a continued sentence keeps them
        for k, v in words.items():
            if not isinstance(k, str) or not isinstance(v, str) or not k.split() or not v.strip():
                continue
            self.words.append(([core(w) for w in k.split()], v.strip()))
            self.proper |= {w for w in v.split() if w[:1].isupper()}
        self.words.sort(key=lambda kv: -len(kv[0]))

    # ---- the pause and the next sentence --------------------------------------------------------------------------------------
    def hold(self, text, lang="en"):
        """A pause after `text` (fillers gone) is not the sentence's end: no end punctuation, or a word a sentence goes on after."""
        if not self.unfinished:
            return False
        toks = (text or "").split()
        if not toks:
            return False
        return not ended(text) or core(toks[-1]) in HOLD_WORDS.get(lang, HOLD_WORDS["en"])

    def continues(self, prev, lang="en"):
        """A sentence after `prev` (the take's previous written sentence) continues it."""
        if not self.unfinished:
            return False
        toks = (prev or "").split()
        if not any(core(t) for t in toks):
            return False                   # nothing, or only a symbol: a lone ">" header begins what follows
        return not ended(prev) or core(toks[-1]) in OPEN_WORDS.get(lang, OPEN_WORDS["en"])

    def continue_word(self, tok):
        """A continued sentence's first word in lower case -- unless it is "I", an acronym, a mixed-case name or a word the user's
        map spells with a capital."""
        a, w, b = _parts(tok)
        if not w or not w[:1].isupper():
            return tok
        c = w.lower()
        if c == "i" or c.startswith("i'"):
            return tok
        letters = [ch for ch in w if ch.isalpha()]
        if len(letters) >= 2 and all(ch.isupper() for ch in letters):
            return tok                     # GUI, STT
        if any(ch.isdigit() for ch in w):
            return tok                     # a code: X9
        if any(ch.isupper() for ch in w[1:]):
            return tok                     # GitHub, VSCode
        if w in self.proper:
            return tok
        return a + w[:1].lower() + w[1:] + b

    # ---- the rules ------------------------------------------------------------------------------------------------------------
    def apply(self, text, lang="en", first=False, prev=None):
        """(text, rules): `text` through the user's words, the F-keys, the leading ">" (the take's first sentence only), the signs
        and the continuation's lower case, each named in `rules` when it changed something."""
        toks = (text or "").split()
        rules = []

        def did(name, before):
            if toks != before and name not in rules:
                rules.append(name)

        if toks and self.words:
            before = list(toks)
            toks = self._words(toks)
            did("words", before)
        if toks and self.codes:
            before = list(toks)
            toks = self._codes(toks)
            did("code", before)
        if toks and self.fkeys:
            before = list(toks)
            toks = self._fkeys(toks)
            did("fkey", before)
        if toks and first and self.leading_quote:
            before = list(toks)
            toks = self._leading_quote(toks)
            did("leadingQuote", before)
        if toks and self.signs:
            before = list(toks)
            toks = self._signs(toks)
            did("sign", before)
        if toks and not first and self.continues(prev, lang):
            before = list(toks)
            toks[0] = self.continue_word(toks[0])
            did("continue", before)
        return " ".join(toks), rules

    def _words(self, toks):
        out, i = [], 0
        while i < len(toks):
            for key, rep in self.words:
                n = len(key)
                seg = toks[i: i + n]
                if len(seg) < n or not all(_bare(t) for t in seg[1:-1]) or (n > 1 and _parts(seg[0])[2]):
                    continue
                cs = [core(t) for t in seg]
                poss = ""
                if cs[-1].endswith("'s") and cs[-1][:-2] == key[-1]:
                    cs[-1], poss = key[-1], "'s"
                if cs == key:
                    lead = _parts(seg[0])[0]
                    trail = _parts(seg[-1])[2]
                    out.append(lead + rep + poss + trail)
                    i += n
                    break
            else:
                out.append(toks[i])
                i += 1
        return out

    # ---- codes (round 8) ------------------------------------------------------------------------------------------------------
    @staticmethod
    def _piece(w):
        """(kind, text) of one word as a piece of a spelled code, or None. Kinds: "d" a digit (a word or figures), "z" a zero or the
        letter O (its neighbours decide), "l" a letter said alone, "g" a letter group the model wrote ("QR"), "m" a chunk of letters and
        digits ("ZB3"), "c" a connector word. A lower-case "a" is the article, never a letter."""
        lw = w.lower()
        if lw in DIGIT_WORDS:
            return "d", DIGIT_WORDS[lw]
        if _DIGITS.match(w):
            return "d", w
        if lw in CONNECTORS:
            return "c", CONNECTORS[lw]
        if lw in ZERO_WORDS:
            return "z", ""
        if len(w) == 1 and w.isascii() and w.isalpha():
            return None if w == "a" else ("l", w.upper())
        if _GROUP.match(w):
            return "g", w
        if _ALNUM.match(w):
            return "m", w.upper()
        return None

    def _codes(self, toks):
        """THE CODES RULE (module docstring): each maximal run of spelled pieces that qualifies becomes one token."""
        out, i = [], 0
        while i < len(toks):
            run, j = [], i
            while j < len(toks):
                lead, w, trail = _parts(toks[j])
                pc = self._piece(w) if w else None
                if pc is None or (lead and j > i):
                    break
                run.append([pc[0], pc[1], w])
                j += 1
                if trail:
                    break              # punctuation after a piece closes the run: it stays after the code
            made = self._code_of(run) if len(run) >= 2 else None
            if made is None:
                out.append(toks[i])
                i += 1
                continue
            a, b, text = made          # run[a:b] is the code
            if re.fullmatch(r"F[0-9]{1,2}", text) and 1 <= int(text[1:]) <= FKEY_MAX:
                out.append(toks[i])    # an F-key: the F-key rule's ("F one zero", rule `fkey`)
                i += 1
                continue
            out += toks[i: i + a]
            lead = _parts(toks[i + a])[0]
            trail = _parts(toks[i + b - 1])[2]
            out.append(lead + text + trail)
            out += toks[i + b: j]
            i = j
        return out

    @staticmethod
    def _code_of(run):
        """(first piece, one past the last, the code) of the qualifying part of `run` -- [kind, text, word] per piece -- or None."""
        a, b = 0, len(run)
        # a zero is "oh" / "o" beside a digit (or a zero beside one), else the letter O
        z = [k for k, p in enumerate(run) if p[0] == "z"]
        changed = True
        while changed:
            changed = False
            for k in z:
                if run[k][0] != "z":
                    continue
                # the neighbours, a connector between ("two dot oh") looked across
                near = [m - 1 if m < k and m > 0 and run[m][0] == "c" else m + 1 if m > k and m + 1 < len(run) and run[m][0] == "c" else m
                        for m in (k - 1, k + 1)]
                if any(0 <= m < len(run) and run[m][0] == "d" for m in near):
                    run[k][0], run[k][1] = "d", "0"
                    changed = True
        for k in z:
            if run[k][0] == "z":
                run[k][0], run[k][1] = "l", "O"
        while True:
            while a < b and run[a][0] == "c":
                a += 1
            while b > a and run[b - 1][0] == "c":
                b -= 1
            body = run[a:b]
            np_ = sum(1 for p in body if p[0] != "c")
            # "A" and "I" at an edge are words of their own: they join a code of at least four pieces only
            if np_ < 4 and body and body[0][2] in CODE_AMBIGUOUS:
                a += 1
            elif np_ < 4 and body and body[-1][2] in CODE_AMBIGUOUS:
                b -= 1
            else:
                break
        body = run[a:b]
        np_ = sum(1 for p in body if p[0] != "c")
        kinds = {p[0] for p in body}
        letters = bool(kinds & {"l", "g", "m"})
        digits = bool(kinds & {"d", "m"})
        if "c" in kinds:
            ok = np_ >= 2 and (letters or np_ >= 3)
        else:
            ok = np_ >= 3 and letters and digits and "l" in kinds
        if not ok:
            return None
        return a, b, "".join(p[1] for p in body)

    def _fkeys(self, toks):
        out, i = [], 0
        while i < len(toks):
            lead, w, trail = _parts(toks[i])
            g = _FGLUED.match(w.lower())
            if g and 1 <= int(g.group(1)) <= FKEY_MAX:
                out.append(lead + "F%d" % int(g.group(1)) + trail)        # "f10", "F-10" (an "F10" stays as it is)
                i += 1
                continue
            if w.lower() == "f" and not trail:
                val, n = self._number(toks, i + 1)
                if val:
                    out.append(lead + "F%d" % val + _parts(toks[i + n])[2])
                    i += n + 1
                    continue
            out.append(toks[i])
            i += 1
        return out

    @staticmethod
    def _number(toks, j):
        """(value, tokens used) of an F-key's number at toks[j:], 1..24, or (0, 0)."""
        if j >= len(toks):
            return 0, 0

        def word(k):
            if k >= len(toks):
                return None, ""
            lead, w, trail = _parts(toks[k])
            return (w.lower() if not lead else None), trail

        w0, t0 = word(j)
        if w0 is None:
            return 0, 0
        if w0.isdigit():
            v = int(w0)
            if t0 or j + 1 >= len(toks):
                return (v, 1) if 1 <= v <= FKEY_MAX else (0, 0)
            w1, _ = word(j + 1)
            if len(w0) == 1 and w1 is not None and w1.isdigit() and len(w1) == 1 and 10 <= v * 10 + int(w1) <= FKEY_MAX:
                return v * 10 + int(w1), 2                                # "F 1 0"
            return (v, 1) if 1 <= v <= FKEY_MAX else (0, 0)
        if w0 in WHOLE:
            v = WHOLE[w0]
            if v == 20 and not t0:
                w1, _ = word(j + 1)
                if w1 in UNITS and 1 <= UNITS[w1] <= 4 and w1 not in ("o", "oh"):
                    return 20 + UNITS[w1], 2                              # "twenty four"
            return v, 1
        if w0 in UNITS and w0 not in ("o", "oh", "zero", "nul"):
            d0 = UNITS[w0]
            if not t0:
                w1, _ = word(j + 1)
                if w1 in UNITS and 10 <= d0 * 10 + UNITS[w1] <= FKEY_MAX:
                    return d0 * 10 + UNITS[w1], 2                         # "one zero", "one O", "two four"
            return d0, 1
        return 0, 0

    def _leading_quote(self, toks):
        cs = [core(t) for t in toks[:3]]
        if cs[:2] != ["greater", "than"] or not _bare(toks[0]):
            return toks
        n = 3 if len(cs) > 2 and cs[2] == "sign" and not _parts(toks[1])[2] else 2
        rest = toks[n:]                    # the consumed words' own punctuation goes with them ("Greater than: after review")
        if rest:
            c = core(rest[0])
            if c in COMPARISON or c.isdigit() or c in UNITS or c in WHOLE:
                return toks                # "Greater than expected", "greater than or equal", "greater than ten"
            a, w, b = _parts(rest[0])
            titled = all(_parts(t)[1][:1].isupper() for t in toks if _parts(t)[1][:1].isalpha())
            rest = [a + w[:1].upper() + w[1:] + b] + [self.continue_word(t) if titled else t for t in rest[1:]]
        return [">"] + rest

    @staticmethod
    def _signs(toks):
        out, i = [], 0
        while i < len(toks):
            for name, sym in SIGNS:
                n = len(name)
                seg = toks[i: i + n + 1]
                if len(seg) < n + 1 or [core(t) for t in seg] != list(name) + ["sign"]:
                    continue
                if any(_parts(t)[2] for t in seg[:-1]) or any(_parts(t)[0] for t in seg[1:]):
                    continue               # "greater than, sign here": punctuation between is two phrases
                if name == ("at",) and i + n + 1 < len(toks) and core(toks[i + n + 1]) in AT_SIGN_NOT:
                    continue
                out.append(_parts(seg[0])[0] + sym + _parts(seg[-1])[2])
                i += n + 1
                break
            else:
                out.append(toks[i])
                i += 1
        return out


def finish(raw, lang, rules, first=False, prev=None, marks=(), tidier=None):
    """(text, rule names, tidy info | None): a final's whole way from what the recogniser wrote to what is written -- the repeats
    across a filler or a held pause, the fillers, the tidy pass, the text rules. The revision policy calls it for every final, the
    takes diff (tools/dev/stt_takes_diff.py) to replay a logged take."""
    names = []
    text = raw or ""
    if rules.repeats:
        text, fired = fillers.drop_repeats(text, lang, marks, rules.fillers)
        names += fired
    stripped = fillers.strip(text, lang, rules.fillers)
    if stripped.split() != text.split():
        names.append("filler")
    text = stripped
    tidy = None
    if tidier is not None and text:
        before = text
        text, tidy = tidier(text, lang)
        if text.split() != before.split():
            names.append("tidy")
    text, fired = rules.apply(text, lang, first=first, prev=prev)
    return " ".join(text.split()), names + fired, tidy
