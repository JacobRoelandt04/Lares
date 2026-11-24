"""English or Dutch, from a transcript: a function-word test (research 8.5, candidate b).

Only words that are frequent in one language and rare or absent in the other count ("in", "is", "was", "me", "we" are in both and
are left out). The answer is (lang, p) with p the share of the winning side, or (None, 0) when no counted word was heard.
"""
import math
import re

NL = set(
    "de het een en van ik je jij niet dat die dit op te zijn voor met maar ook er wat als hij zij ze aan om bij nog wel naar "
    "hebben heeft heb kan kunnen of geen u wordt worden nu al dan hoe waar wie waarom omdat moet moeten zou zouden kunnen "
    "deze onze ons mijn jouw hun haar wordt werd door uit over tegen zonder tussen veel meer heel echt gaan gaat ging komt "
    "kom komen zeggen zegt doen doet gedaan alleen wanneer welke iets niets iemand niemand hier daar zo toch even nee ja "
    "ben bent zijn hebt gaat wil willen weet weten".split()
)
EN = set(
    "the a an and of to it that this for on with as are be not have has had you he she they at by from or but what so if "
    "would could should can will there their them his her our your my which who when where why how about into than then "
    "been being do does did done just only also very really because while these those some any no yes all more most other "
    "such through over after before under between without".split()
)
_WORD = re.compile(r"[a-zà-ÿ']+")


def guess(text: str):
    words = _WORD.findall((text or "").lower())
    nl = sum(1 for w in words if w in NL)
    en = sum(1 for w in words if w in EN)
    if nl + en == 0:
        return None, 0.0
    if nl >= en:
        return "nl", nl / (nl + en)
    return "en", en / (nl + en)


# A detector's answer outside the two languages maps to the nearer one (research 8.5).
NEAR_NL = {"nl", "af", "de", "fy", "lb", "li"}


def near(code):
    if not code:
        return None
    return "nl" if code.lower().strip("<|>") in NEAR_NL else "en"


def detector(method, dec):
    """audio -> (lang | None, p, how): the language tests of research 8.5 the bench compares.

    self-fw   the decoder, given no language (Parakeet always; Whisper detects), read by the function-word test
    score     forced English and forced Dutch, the higher mean token log-probability wins (Canary)
    """
    if method == "self-fw":
        def fw(audio):
            lang, p = guess(dec.decode(audio, None))
            return lang, p, "detect"
        return fw
    if method == "score":
        def score(audio):
            (_, en), (_, nl) = dec.scored(audio, "en"), dec.scored(audio, "nl")
            p = 1.0 / (1.0 + math.exp(-abs(nl - en) * 5))
            return ("nl" if nl > en else "en"), p, "detect"
        return score
    return None
