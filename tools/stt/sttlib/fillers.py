"""Fillers: the "uh"s and "um"s a speaker thinks with, never written (the user's rule, round 4).

Parakeet writes them as words ("the uh F ten key", "two minutes, um", "Uhm, I think"), and a pause after one used to end the
sentence with the filler in it. Two rules, both in the revision policy (sttlib/policy.py):

  strip(text, lang)          the text without its standalone fillers, every hypothesis and every final alike: a filler's comma goes
                             with it, a full stop it carried moves to the word before, and a sentence it began begins with the next
                             word, capitalised
  ends_in_filler(text, lang) the speaker's last word was a filler: the pause after it is thinking, not the end of the sentence
  drop_repeats(text, lang, marks)
                             round 5, the user's rule: "X <filler run> X" -> "X" -- a speaker who stops to think says the last
                             words again after the "uh", and the recogniser writes them twice. On the RAW words (before `strip`), 1-6
                             words compared like `core` (case and punctuation blind), the LATER copy kept with its own casing and
                             punctuation (a sentence it now begins is capitalised). A thinking PAUSE inside the sentence counts as a
                             filler: `marks` are the words heard up to each pause the policy held open, and the pause sits where the
                             final's words agree with them. A repeat with nothing between ("each each") is NOT this rule's: an
                             intended duplicate has no filler in it, and the tidy pass judges the rest. Nor is a copy that ended a
                             sentence ("It works. Uh, it works on the GPU"): two sentences, not a repeat.

Only whole words count. `extra` (the user's own, shell.jsonc dictation.text.fillers: a set of cores, TextRules.fillers) are fillers
like the built in ones, in either language. English "er" is a filler, Dutch "er" is a word ("er is"); "eh?" closing a sentence is a question tag, not a
filler. A stutter fragment ("that m uh more") is the tidy pass's (sttlib/tidy.py), not this.
"""
import re

COMMON = {"uh", "uhh", "uhhh", "um", "umm", "ummm", "uhm", "uhmm", "ehm", "ehmm", "hmm", "hmmm", "hm"}
FILLERS = {
    "en": COMMON | {"erm", "er", "eh"},
    "nl": COMMON | {"euh", "euhm", "eh", "ehh"},
}
_CORE = re.compile(r"^[^\w]+|[^\w]+$", re.UNICODE)
_TERM = re.compile(r"[.?!…]+$")
_WORD = re.compile(r"^[^\w']+|[^\w']+$", re.UNICODE)
REPEAT_MAX = 6


def core(w: str) -> str:
    """A word as the rules compare it: lower case, its leading and trailing punctuation gone (an apostrophe inside stays)."""
    return _WORD.sub("", w).lower()


def _is_filler(tok: str, lang: str, extra=frozenset()) -> bool:
    c = _CORE.sub("", tok).lower()
    if c in extra:
        return True
    if c not in FILLERS.get(lang, FILLERS["en"]):
        return False
    # "eh?" is a question tag ("mooi, eh?"), not a filler
    return not (c == "eh" and tok.rstrip().endswith("?"))


def strip(text: str, lang: str = "en", extra=frozenset()) -> str:
    toks = (text or "").split()
    out = []
    cap = False
    last_dropped = False
    for t in toks:
        if _is_filler(t, lang, extra):
            last_dropped = True
            term = _TERM.search(t)
            if term and out and not _TERM.search(out[-1].rstrip(",;:")):
                out[-1] = out[-1].rstrip(",;:") + term.group(0)
            if t[:1].isupper() and (not out or _TERM.search(out[-1])):
                cap = True                       # the filler began a sentence: the next word begins it now
            continue
        last_dropped = False
        if cap:
            t = t[:1].upper() + t[1:]
            cap = False
        out.append(t)
    if out and last_dropped:
        out[-1] = out[-1].rstrip(",;:")          # "two minutes, um" -> "two minutes"
    return " ".join(out)


def ends_in_filler(text: str, lang: str = "en", extra=frozenset()) -> bool:
    toks = (text or "").split()
    return bool(toks) and _is_filler(toks[-1], lang, extra)


def drop_repeats(text: str, lang: str = "en", marks=(), extra=frozenset()):
    """(text, rules): `text` with every "X <fillers or a held pause> X" said once (module docstring); `rules` names what fired,
    "fillerRepeat" and / or "pauseRepeat"."""
    toks = (text or "").split()
    cuts = set()
    for m in marks or ():
        mt = (m or "").split()
        if 0 < len(mt) < len(toks) and all(core(a) == core(b) for a, b in zip(mt, toks)):
            cuts.add(len(mt))            # the final heard the words before the pause as the pause's own decode did
    # items: [token, kind] -- "w" a word, "f" a filler, "p" a held pause (no token)
    items = []
    for i, t in enumerate(toks):
        if i in cuts:
            items.append([None, "p"])
        items.append([t, "f" if _is_filler(t, lang, extra) else "w"])
    rules = []
    i = 0
    while i < len(items):
        if items[i][1] == "w":
            i += 1
            continue
        j = i
        while j < len(items) and items[j][1] != "w":
            j += 1
        a, later = _repeat_at(items, i, j)
        if a is not None:
            # the copy that goes began a sentence: the one kept begins it now
            prev = next((items[k][0] for k in range(a - 1, -1, -1) if items[k][1] == "w"), None)
            if items[a][0][:1].isupper() and (prev is None or _TERM.search(prev)) and later[0][:1].islower():
                later[0] = later[0][:1].upper() + later[0][1:]
            name = "fillerRepeat" if any(k == "f" for _, k in items[i:j]) else "pauseRepeat"
            if name not in rules:
                rules.append(name)
            del items[a: i]
            i = max(0, a - REPEAT_MAX)       # "the uh the uh the": look again from before the run
            continue
        i = j
    return " ".join(t for t, k in items if k != "p"), rules


def _repeat_at(items, i, j):
    """The longest n (1..REPEAT_MAX) such that the n words right before the run items[i:j] are the n words right after it: (where
    the earlier copy begins, the later copy's first item), or (None, None). A held pause inside a copy is no word and no break (an
    earlier pause that matched nothing); a filler is a break."""
    def side(k, step):
        out = []
        while 0 <= k < len(items) and len(out) < REPEAT_MAX and items[k][1] != "f":
            if items[k][1] == "w":
                out.append(k)
            k += step
        return out

    before, after = side(i - 1, -1), side(j, 1)      # nearest first
    if not before or _TERM.search(items[before[0]][0]):
        return None, None                # the first copy ended a sentence: two sentences, not a repeat
    for n in range(min(len(before), len(after)), 0, -1):
        cb = [core(items[k][0]) for k in reversed(before[:n])]
        ca = [core(items[k][0]) for k in after[:n]]
        if all(cb) and cb == ca:
            return before[n - 1], items[after[0]]
    return None, None
