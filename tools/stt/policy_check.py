#!/usr/bin/env python3
"""policy_check.py -- the revision policy (sttlib/policy.py) against its own promises, with the real VAD and a STAND-IN decoder.

The stand-in answers one word per 0.4 s of audio after a fixed delay, so the run costs seconds, needs no model and is the same
every time; the delay makes one feed carry a pause and the speech after it (what a real decode does to the helper's loop).
Four FLEURS clips are joined with pauses of 0.85, 1.2 and 0.8 s (each ends a sentence) and fed through the engine on
the simulated clock (bench.simulate). Checks, one line each, `PCHECK ok|FAIL <check>: <detail>`, last `PCHECK RESULT PASS|FAIL`:

  cover     every speech frame the VAD found lies inside some final sentence
  decoded   each final's words are the stand-in's answer for its own span (no final decodes another sentence's audio: the
            snapshot taken at the close, which a sentence opening in the same feed must not move)
  ordered   the sentences are in order and do not overlap
  stable    within a sentence the stable prefix only grows, and is a prefix of the text shown with it
  final     every sentence that showed words ends with exactly one final (`seg`), and nothing follows `ended`

Round 4, a second run (B): three clips, the first followed by a FILLER (a burst of speech the stand-in hears as "uh") and a 2 s
pause, the second by a plain 1.2 s pause. The stand-in here writes words for speech only (one per 0.4 s of it, numbered by where they
are in the whole recording, so every decode agrees) and "uh," for the filler:

  fillers   the stand-in wrote "uh" (a `seg`'s `raw` has it) and no hypothesis and no final shows it
  think     the pause after the filler kept the sentence open (`think` said so; the first final runs from the first clip through
            the second) while the plain pause after the second clip still ended its sentence
  tidy      the tidy pass: off (no tidier) leaves no `tidy` on any final; a tidier that adds a word ("stub-add") is refused by the
            guard and the final is the sentence as heard; one that changes nothing ("stub-echo") passes
  guard     the guard's rules on fixed sentences, as the sentence it writes: removals it can name are applied; an added or moved
            word or half the sentence gone refuse the proposal (the sentence as heard); a cue removed alone or a removal it cannot
            name is put back while the rest is applied (round 6: "works works rather well" with "rather" dropped too writes
            "works rather well")

Round 5, run C: a SCRIPTED stand-in (each clip is said as fixed words; a decode writes the words of every clip it hears, a clip heard in
part its first words in proportion), five recordings of two clips:

  unfinished  "We should go to the" + a 1.2 s pause + "station before noon." is ONE sentence (the pause after an unfinished sentence
              is held, `think` says "unfinished"), while "We should go." + the same pause still ends one
  continue    the same unfinished words + a 3.6 s pause (past thinkSilenceMs) end the sentence, and the next begins in lower case,
              in its live words and in its final ("continue" among its rules)
  repeat      "So it can" + a held pause + "so it can think about the command." and "... what I just said, uh," + a pause + "what I
              just said before." are written with the words once ("pauseRepeat", "fillerRepeat")

And the case table (text_cases.tsv): every row through textrules.finish, one check per family (`cases <family>`): what is written and
the rule names the seg carries; `cases off`: with every `dictation.text` switch off each row is written as round 4 wrote it.
"""
import os
import sys
import time
from pathlib import Path

os.environ.setdefault("OPENBLAS_NUM_THREADS", "2")
sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

from bench import clips, simulate  # noqa: E402
from sttlib import decoders, fillers, textrules, tidy  # noqa: E402
from sttlib.policy import Engine  # noqa: E402
from sttlib.audio import read_wav  # noqa: E402
from sttlib.vad import StreamingVad  # noqa: E402

RATE = 16000


class StandIn:
    id, device, forceable, autolang = "stand-in", "CPU", True, False

    def __init__(self, delay):
        self.delay = delay

    def decode(self, audio, lang):
        time.sleep(self.delay)
        words = ["w%d" % i for i in range(int(audio.size / (0.4 * RATE)))]
        return (" ".join(words) + ".") if words else ""     # a sentence that ends: the pause after it ends it


class Speaker:
    """The stand-in of run B: it finds what it is given in the whole recording (the samples are the recording's own, so the bytes
    are found) and writes one word per 0.4 s of SPEECH in it -- numbered by its place in the recording -- and "uh," for a filler."""

    id, device, forceable, autolang = "speaker", "CPU", True, False

    def __init__(self, full, speech, filler_spans, delay):
        self.full, self.bytes = full, full.tobytes()
        self.speech = speech              # per 512-sample frame of `full`: speech or not
        self.fills = filler_spans         # [(a, b)] in samples of `full`
        self.delay = delay
        cum, n = [], 0
        for i, sp in enumerate(speech):
            cum.append(n)
            if sp and not any(a <= i * 512 < b for a, b in filler_spans):
                n += 512
        self.cum = cum

    def decode(self, audio, lang):
        time.sleep(self.delay)
        off = where(self.bytes, audio)
        if off is None:
            return ""
        out, last, said = [], None, set()
        for f in range(off // 512, min(len(self.speech), (off + audio.size) // 512)):
            if not self.speech[f]:
                continue
            fill = next((k for k, (a, b) in enumerate(self.fills) if a <= f * 512 < b), None)
            if fill is not None:
                if fill not in said:
                    said.add(fill)
                    out.append("uh,")
                continue
            w = self.cum[f] // int(0.4 * RATE)
            if w != last:
                out.append("w%d" % w)
                last = w
        if out and not out[-1].startswith("uh"):
            out[-1] += "."                # a sentence that ends (one that ends in "uh," is thinking)
        return " ".join(out)


def where(full_bytes, audio):
    """The sample offset of `audio` in the recording whose bytes are `full_bytes` (found by its first non-silent samples)."""
    nz = np.flatnonzero(audio)
    if nz.size == 0:
        return None
    i = int(nz[0])
    needle = audio[i: i + 256].tobytes()
    pos = full_bytes.find(needle)
    while pos >= 0 and pos % 4:
        pos = full_bytes.find(needle, pos + 1)
    return None if pos < 0 else pos // 4 - i


class Script:
    """Run C's stand-in: each clip of the recording is said as fixed words; a decode writes the words of every clip it hears, a
    clip heard in part its first words in proportion (so the live words grow)."""

    id, device, forceable, autolang = "script", "CPU", True, False

    def __init__(self, full, spans, delay):
        self.bytes, self.spans, self.delay = full.tobytes(), spans, delay

    def decode(self, audio, lang):
        time.sleep(self.delay)
        off = where(self.bytes, audio)
        if off is None:
            return ""
        a, b = off, off + audio.size
        out = []
        for sa, sb, words in self.spans:
            ov = min(b, sb) - max(a, sa)
            if ov > 0:
                out += words if ov >= 0.9 * (sb - sa) else words[: int(len(words) * ov / (sb - sa))]
        return " ".join(out)


def cut_clips(vad, n):
    """n FLEURS clips, each cut to its speech (the clips carry seconds of their own silence)."""
    out = []
    for c in clips("en", n):
        a = read_wav(c["file"])
        vad.reset()
        sp = [i for i, p in enumerate(vad.feed(a)) if p >= 0.5]
        out.append(a[max(0, sp[0] * 512 - 1600): min(a.size, (sp[-1] + 1) * 512 + 1600)])
    return out


def scripted(vad, cut, first, gap_s, second):
    """Two clips said as `first` and `second` with `gap_s` of silence between, through the policy: (events, segs)."""
    lead = RATE
    gap = np.zeros(int(gap_s * RATE), np.float32)
    audio = np.concatenate([cut[0], gap, cut[1]])
    full = np.concatenate((np.zeros(lead, np.float32), audio, np.zeros(int(1.5 * RATE), np.float32)))
    b0 = lead + cut[0].size
    spans = [(lead, b0, first.split()), (b0 + gap.size, b0 + gap.size + cut[1].size, second.split())]
    vad.reset()
    ev, _, _ = simulate(Script(full, spans, 0.05), vad, audio, "en")
    return [e for _, e in ev], [e for _, e in ev if e["ev"] == "seg"]


def run_c(say):
    """Run C (module docstring): unfinished sentences held, continued in lower case, repeats across a filler or a held pause."""
    vad = StreamingVad(decoders.MODELS_DIR / "silero-vad")
    cut = cut_clips(vad, 2)

    def texts(segs):
        return [e["text"] for e in segs]

    ev1, s1 = scripted(vad, cut, "We should go to the", 1.2, "station before noon.")
    ev2, s2 = scripted(vad, cut, "We should go.", 1.2, "Station before noon.")
    why = [e.get("why") for e in ev1 if e["ev"] == "think"]
    ok = texts(s1) == ["We should go to the station before noon."] and "unfinished" in why and texts(s2) == ["We should go.",
                                                                                                             "Station before noon."]
    say(ok, "unfinished", "unfinished + 1.2 s: %r (think: %s); finished + 1.2 s: %r" % (texts(s1), why or "none", texts(s2)))

    ev3, s3 = scripted(vad, cut, "We should go to the", 3.6, "Station before noon.")
    second = [e for e in ev3 if e["ev"] == "hyp" and e["seg"] == 1]
    upper = [e["text"] for e in second if e["text"][:1].isupper()]
    ok = (texts(s3) == ["We should go to the", "station before noon."] and "continue" in s3[1].get("rules", [])
          and second and not upper)
    say(ok, "continue", "unfinished + 3.6 s: %r, rules %s; %d live hypotheses of the second, %d begin in upper case%s"
        % (texts(s3), [e.get("rules") for e in s3], len(second), len(upper), (" (%r)" % upper[0]) if upper else ""))

    _, s4 = scripted(vad, cut, "So it can", 1.2, "so it can think about the command.")
    _, s5 = scripted(vad, cut, "I might repeat what I just said, uh,", 2.0, "what I just said before.")
    ok = (texts(s4) == ["So it can think about the command."] and "pauseRepeat" in s4[0].get("rules", [])
          and texts(s5) == ["I might repeat what I just said before."] and "fillerRepeat" in s5[0].get("rules", []))
    say(ok, "repeat", "across a held pause: %r %s; across a filler: %r %s"
        % (texts(s4), [e.get("rules") for e in s4], texts(s5), [e.get("rules") for e in s5]))


def run_cases(say):
    """The case table (text_cases.tsv), one check per family."""
    rules = textrules.TextRules()
    fams = {}
    for line in Path(__file__).with_name("text_cases.tsv").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        family, lang, prev, raw, want, names = line.split("\t")
        n, wrong = fams.setdefault(family, [0, []])
        fams[family][0] = n + 1
        if family == "hold":
            got = "hold" if rules.hold(fillers.strip(raw, lang), lang) else "close"
            if got != want:
                wrong.append("%r: %s, not %s" % (raw, got, want))
            continue
        parts = raw.split(" || ")
        marks = [" ".join(parts[:k]) for k in range(1, len(parts))]
        first = prev == "-"
        text, got_rules, _ = textrules.finish(" ".join(parts), lang, rules, first=first,
                                              prev=None if first else ("Done." if prev == "+" else prev), marks=marks)
        want_rules = [] if names == "-" else names.split(",")
        if text != want or got_rules != want_rules:
            wrong.append("%r -> %r %s, not %r %s" % (raw, text, got_rules, want, want_rules))
    for family, (n, wrong) in fams.items():
        say(not wrong, "cases " + family, "%d of %d rows as written%s" % (n - len(wrong), n, ("; " + " | ".join(wrong[:2]))
                                                                            if wrong else ""))
    # every switch off (shell.jsonc dictation.text): each row is written as round 4 wrote it -- the fillers gone, nothing else --
    # and no pause is held for unfinished words
    off = textrules.TextRules({"symbols": {"fkeys": False, "signs": False, "leadingQuote": False, "codes": False}, "words": {}, "repeats": False,
                               "unfinished": False})
    changed, n = [], 0
    for line in Path(__file__).with_name("text_cases.tsv").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        family, lang, prev, raw, _, _ = line.split("\t")
        n += 1
        if family == "hold":
            if off.hold(fillers.strip(raw, lang), lang):
                changed.append("%r held" % raw)
            continue
        flat = raw.replace(" || ", " ")
        first = prev == "-"
        text, got, _ = textrules.finish(flat, lang, off, first=first, prev=None if first else ("Done." if prev == "+" else prev),
                                        marks=[raw.split(" || ")[0]] if " || " in raw else [])
        if text != " ".join(fillers.strip(flat, lang).split()) or set(got) - {"filler"}:
            changed.append("%r -> %r %s" % (raw, text, got))
    say(not changed, "cases off", "every switch off: %d of %d rows as round 4 wrote them%s"
        % (n - len(changed), n, ("; " + " | ".join(changed[:2])) if changed else ""))


    # the user's own fillers (dictation.text.fillers): dropped like the built in ones, whole words, any case; nothing else is
    own = textrules.TextRules({"fillers": ["Basically", "you know", 5]})
    rows = [("So basically, I like it.", "So I like it."), ("Basically we go.", "We go."), ("The the basically basics, uh, stay.", "The the basics, stay."),
            ("I go, basically I go home.", "I go home."), ("You know it.", "You know it.")]
    wrong = ["%r -> %r" % (raw, textrules.finish(raw, "en", own)[0]) for raw, want in rows if textrules.finish(raw, "en", own)[0] != want]
    say(not wrong and fillers.ends_in_filler("I go basically,", "en", own.fillers) and not fillers.ends_in_filler("I go basically,", "en"),
        "cases own fillers", "%d of %d rows as written%s" % (len(rows) - len(wrong), len(rows), "; " + " | ".join(wrong[:3]) if wrong else ""))


# (the sentence, the model's proposal, what the guard lets it write)
GUARD_CASES = [
    ("We meet on Thursday, sorry, Friday.", "We meet on Friday.", "We meet on Friday."),
    ("I want to, I want to go home.", "I want to go home.", "I want to go home."),
    ("The the report is ready.", "The report is ready.", "The report is ready."),
    ("Let's go to the, let's meet at the station.", "Let's meet at the station.", "Let's meet at the station."),
    ("It should correct that m more often.", "It should correct that more often.", "It should correct that more often."),
    ("The report is ready.", "The report is ready now.", "The report is ready."),
    ("The report is ready.", "Ready the report is.", "The report is ready."),
    ("We meet on Thursday, sorry, Friday.", "We meet on Thursday, Friday.", "We meet on Thursday, sorry, Friday."),
    ("He went to, he drove to Antwerp.", "He went to Antwerp.", "He went to, he drove to Antwerp."),
    ("We need to buy bread and milk today.", "We need bread.", "We need to buy bread and milk today."),
    # round 6, partial: the user's own sentence (feedback/dictation.md), the model dropping "rather" beside the repeat
    ("I think it works works rather well.", "I think it works well.", "I think it works rather well."),
    ("To be clear I don't want you to change the model because I think it works works rather well.",
     "To be clear I don't want you to change the model because I think it works well.",
     "To be clear I don't want you to change the model because I think it works rather well."),
    ("We meet on Thursday, sorry, Friday at the station.", "We meet on Friday at station.", "We meet on Friday at the station."),
    # round 8: the user's take of 2026-11-13 -- an enumeration is not a restart (the guard wrote "one is a pencil": the brain was gone) ...
    ("Then we could morph the icon into three things where one is a brain, one is a", "Then we could morph the icon into three things where one is a",
     "Then we could morph the icon into three things where one is a brain, one is a"),
    ("I think we should go to the, we should meet at the station.", "I think we should meet at the station.",
     "I think we should meet at the station."),
    # ... while a phrase broken off mid-way is still one
    ("He said it is, it is fine.", "He said it is fine.", "He said it is fine."),
]


def run_b(say):
    """Run B (module docstring): fillers, the thinking pause, the tidy pass, the guard."""
    vad = StreamingVad(decoders.MODELS_DIR / "silero-vad")
    cut = cut_clips(vad, 3)
    # the filler: half a second from the middle of the third clip (speech to the VAD; "uh," to the stand-in)
    mid = cut[2].size // 2
    filler = cut[2][mid: mid + RATE // 2]
    parts = [cut[0], np.zeros(RATE // 10, np.float32), filler, np.zeros(2 * RATE, np.float32), cut[1],
             np.zeros(int(1.2 * RATE), np.float32), cut[2]]
    audio = np.concatenate(parts)
    lead = RATE
    full = np.concatenate((np.zeros(lead, np.float32), audio, np.zeros(int(1.5 * RATE), np.float32)))
    vad.reset()
    speech = [p >= 0.5 for p in vad.feed(full)]
    f0 = lead + cut[0].size + RATE // 10
    fills = [(f0, f0 + filler.size)]
    c1_end = lead + cut[0].size
    c2_start = f0 + filler.size + 2 * RATE
    c2_end = c2_start + cut[1].size
    vad.reset()
    ev, _, _ = simulate(Speaker(full, speech, fills, 0.3), vad, audio, "en")
    segs = [e for _, e in ev if e["ev"] == "seg"]
    hyps = [e for _, e in ev if e["ev"] == "hyp"]
    shown = [e["text"] for e in hyps] + [e["text"] for e in segs]
    leaked = [t for t in shown if fillers.ends_in_filler(t, "en") or any(fillers._is_filler(w, "en") for w in t.split())]
    heard = sum(1 for e in segs if "uh" in e.get("raw", "").split(",")[0] or "uh," in e.get("raw", ""))
    say(heard > 0 and not leaked, "fillers", ("the stand-in said \"uh\" (in %d final(s)' raw text); no hypothesis or final shows it"
        % heard) if not leaked else "shown with a filler: %r" % leaked[:2])
    spans = [(int(e["atMs"] * RATE / 1000), int((e["atMs"] + e["audioMs"]) * RATE / 1000)) for e in segs]
    # the sentence that holds the filler (the first clip has a pause of its own, so it need not be the first sentence)
    held = next(((a, b) for a, b in spans if a <= f0 < b), (0, 0))
    thinks = [e for _, e in ev if e["ev"] == "think"]
    joined = held[0] <= c1_end - RATE // 2 and held[1] >= c2_start + RATE // 2
    split_after = any(a >= c2_end - RATE // 4 for a, _ in spans)
    say(bool(thinks) and joined and split_after, "think",
        "%d think event(s); the filler's sentence %.2f-%.2f s runs from clip 1 (to %.2f s) through the pause into clip 2 (from "
        "%.2f s); the plain pause after clip 2 (%.2f s) ends one; sentences %s"
        % (len(thinks), held[0] / RATE, held[1] / RATE, c1_end / RATE, c2_start / RATE, c2_end / RATE,
           " ".join("[%.2f-%.2f]" % (a / RATE, b / RATE) for a, b in spans)))

    # the tidy pass through the engine, on run A's simpler stand-in
    a = np.concatenate([cut[0], np.zeros(RATE, np.float32), cut[1]])
    res = {}
    for name, tdr in (("off", None), ("stub-add", tidy.load("stub-add")), ("stub-echo", tidy.load("stub-echo"))):
        vad.reset()
        ev2, _, _ = simulate(StandIn(0.05), vad, a, "en", tidier=tdr)
        res[name] = [e for _, e in ev2 if e["ev"] == "seg" and e["text"]]
    off_ok = res["off"] and not any("tidy" in e for e in res["off"])
    add_ok = res["stub-add"] and all(e.get("tidy", {}).get("ok") is False and e["tidy"]["why"].startswith("added")
                                     and "banana" not in e["text"] for e in res["stub-add"])
    echo_ok = res["stub-echo"] and all(e.get("tidy", {}).get("ok") is True for e in res["stub-echo"])
    ex = (res["stub-add"] or [{}])[0]
    say(bool(off_ok and add_ok and echo_ok), "tidy",
        "off: %d finals, none tidied; stub-add: refused (%s), wrote \"%s\"; stub-echo: %s"
        % (len(res["off"]), ex.get("tidy", {}).get("why", "-"), ex.get("text", "")[:60],
           "passed" if echo_ok else "NOT passed"))

    wrong = []
    for src, out, want in GUARD_CASES:
        got, why, _ = tidy.guard(src, out, "en")
        if got != want:
            wrong.append("%r -> %r: wrote %r (%s)" % (src, out, got, why or "applied"))
    say(not wrong, "guard", "%d of %d sentences judged as they must be" % (len(GUARD_CASES) - len(wrong), len(GUARD_CASES))
        + ("; " + " | ".join(wrong[:2]) if wrong else ""))


class _NoVad:
    frames = 0

    def reset(self):
        pass


def letters(text):
    """The letters of a text, case, punctuation and word breaks blind (what two spellings of the same speech share)."""
    return "".join(ch for ch in text.lower() if ch.isalnum() or ch == "'")


# hypothesis sequences of ONE sentence as the model rewrites it (round 8, the user's duplicated live text): each is (what a decode wrote)
PARTIAL_CASES = {
    # a word split in two after it was stable, then merged again: the shown text never holds a word twice or stops growing
    "resplit": ["good bye now", "good bye now again", "goodbye now again maybe", "goodbye now again maybe so", "good bye now again maybe so yes",
                "good bye now again maybe so yes then"],
    # a merge before the stable end, a split after it, a case and punctuation change on a stable word
    "merge": ["I will go to the sea side", "I will go to the sea side today", "I will go to the seaside today,", "I will go to the Seaside today, and",
              "I will go to the seaside today, and then"],
    # a hypothesis that is SHORTER than the stable text (the model dropped its last words): the shown text does not shrink or double
    "shrink": ["we could try that", "we could try that again", "we could try", "we could try that again now"],
    # the model rewrites an early word altogether
    "rewrite": ["I scream for them", "I scream for them all", "ice cream for them all today"],
}


def run_partials(say):
    """THE PARTIAL BUILDER (policy.Engine._hyp) by word alignment, never by index: for every rewritten sequence the text shown after
    each hypothesis is the stable words followed by what the hypothesis says past them -- by LETTERS, so a word split or merged before
    the stable end does not show anything twice or drop it -- the stable words only grow, and a hypothesis shorter than the stable
    text leaves the shown text as it was."""
    wrong = []
    for name, seq in PARTIAL_CASES.items():
        ev = []
        eng = Engine(None, _NoVad(), ev.append)
        eng.start(1)
        last_stable, shown = [], ""
        for k, h in enumerate(seq):
            n0 = len(ev)
            eng._hyp(h)
            if len(ev) > n0:
                shown = ev[-1]["text"]
            st = list(eng.stable)
            sl, hl = letters(" ".join(st)), letters(h)
            if st[: len(last_stable)] != last_stable:
                wrong.append("%s #%d: the stable words changed: %r -> %r" % (name, k, last_stable, st))
            elif not letters(shown).startswith(sl):
                wrong.append("%s #%d: %r does not start with the stable words %r" % (name, k, shown, st))
            elif hl.startswith(sl) and letters(shown) != hl:
                wrong.append("%s #%d: %r after %r shows %r: letters twice or dropped" % (name, k, h, st, shown))
            elif sl.startswith(hl) and letters(shown) != sl:
                wrong.append("%s #%d: a shorter hypothesis %r moved the shown text to %r" % (name, k, h, shown))
            last_stable = st
        if name == "rewrite" and not letters(shown).endswith(letters(seq[-1])[-5:]):
            wrong.append("rewrite: %r does not follow the newest hypothesis %r to its end" % (shown, seq[-1]))
    say(not wrong, "partials", "%d rewritten sequences, each hypothesis shown once, the stable words only grow%s"
        % (len(PARTIAL_CASES), ("; " + " | ".join(wrong[:3])) if wrong else ""))


def main():
    bad = 0

    def say(ok, what, detail):
        nonlocal bad
        bad += not ok
        print(f"PCHECK {'ok' if ok else 'FAIL'} {what}: {detail}", flush=True)

    # 0.85 / 0.8 s: past the 700 ms that ends a sentence and short enough that the next one opens in the same feed as the close
    # (a feed carries what came in during a 0.6 s decode); 1.2 s: a plain sentence end
    gaps = [0.85, 1.2, 0.8, 0.0]
    vad = StreamingVad(decoders.MODELS_DIR / "silero-vad")
    parts = []
    for a, g in zip(cut_clips(vad, 4), gaps):
        parts += [a, np.zeros(int(g * RATE), np.float32)]
    audio = np.concatenate(parts)
    vad.reset()
    probs = vad.feed(audio)
    lead = RATE  # simulate() puts 1 s of silence first
    # speech frames in runs of at least 13 (416 ms: the stand-in's smallest word -- a shorter burst may rightly say nothing)
    flags = [p >= 0.5 for p in probs]
    speech, i = [], 0
    while i < len(flags):
        j = i
        while j < len(flags) and flags[j]:
            j += 1
        if j - i >= 13:
            speech += [lead + k * 512 for k in range(i, j)]
        i = j + 1
    vad.reset()
    ev, _, _ = simulate(StandIn(0.6), vad, audio, "en")

    segs = [e for _, e in ev if e["ev"] == "seg"]
    spans = [(int(e["atMs"] * RATE / 1000), int((e["atMs"] + e["audioMs"]) * RATE / 1000)) for e in segs]
    lost = [s for s in speech if not any(a <= s < b for a, b in spans)]
    say(not lost and segs, "cover", f"{len(segs)} sentences over {len(speech)} speech frames; "
        + (f"{len(lost)} frames in no sentence, first at {lost[0] / RATE:.2f} s" if lost else "every speech frame is in one"))
    # the stand-in answers one word per 0.4 s of what it was given: a final whose words do not match its span decoded other audio
    wrong = [(e["seg"], len(e["text"].split()), int((b - a) / (0.4 * RATE))) for e, (a, b) in zip(segs, spans)
             if abs(len(e["text"].split()) - int((b - a) / (0.4 * RATE))) > 1]
    say(segs and not wrong, "decoded", "every final decoded its own sentence's audio" if not wrong
        else f"(seg, words, expected) {wrong[:3]}: a final decoded audio that is not its sentence")
    say(all(spans[i][1] <= spans[i + 1][0] for i in range(len(spans) - 1)) and [e["seg"] for e in segs] == list(range(len(segs))),
        "ordered", " ".join(f"[{a / RATE:.2f}-{b / RATE:.2f}]" for a, b in spans))

    bad_stable = []
    last = {}
    for _, e in ev:
        if e["ev"] != "hyp":
            continue
        st, tx = e["stable"].split(), e["text"].split()
        prev = last.get(e["seg"], [])
        if tx[: len(st)] != st or len(st) < len(prev) or st[: len(prev)] != prev:
            bad_stable.append((e["seg"], e["rev"]))
        last[e["seg"]] = st
    say(not bad_stable and last, "stable", f"{sum(1 for _, e in ev if e['ev'] == 'hyp')} hypotheses"
        + (f"; broken at (seg, rev) {bad_stable[:3]}" if bad_stable else "; the stable prefix only grew"))

    shown = {e["seg"] for _, e in ev if e["ev"] == "hyp" and e["text"]}
    finals = [e["seg"] for e in segs]
    end_at = next((i for i, (_, e) in enumerate(ev) if e["ev"] == "ended"), None)
    say(shown <= set(finals) and len(finals) == len(set(finals)) and end_at == len(ev) - 1, "final",
        f"sentences with words {sorted(shown)}, finals {finals}, `ended` last: {end_at == len(ev) - 1}")
    run_partials(say)
    run_b(say)
    run_c(say)
    run_cases(say)
    print("PCHECK RESULT", "PASS" if not bad else "FAIL", flush=True)
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
