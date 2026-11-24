"""The revision policy (research section 8.4): live words that fix themselves, committed at a pause.

An UTTERANCE is a VAD speech region. While it is open the decoder re-decodes it from its start every hop (never across utterances),
and each hypothesis H(k) is shown whole: the STABLE prefix is LocalAgreement-2 (the longest word prefix H(k) and H(k-1) agree on,
compared case- and punctuation-blind), which only grows within the utterance, followed by H(k)'s words past it. When the speech
ends (endSilenceMs of silence; a soft cut at a pause past softCutS, a hard cut at hardCutS) the utterance is decoded once more and
emitted as a `seg`: final, never revised. So committed text is never touched and a preedit is never more than one utterance.

FILLERS (round 4, the user's rule; sttlib/fillers.py): no hypothesis and no final ever shows a standalone "uh" / "um" -- they are
stripped before the agreement is computed and before a final is written -- and a pause that follows one is THINKING, not the end of
the sentence: it closes only after `thinkSilenceMs` (the newest hypothesis tells whether the speech before the pause ended in a
filler; when it did not hear that far, the utterance is decoded once more at the pause, and a close right after reuses that decode).

UNFINISHED SENTENCES (round 5): a pause after words that have not ended a sentence -- no end punctuation, or a word a sentence goes
on after ("the", "and", "to"; sttlib/textrules.py HOLD_WORDS) -- is thinking too, judged the same way, and waits the same
`thinkSilenceMs` (not once the utterance is past softCutS: then its next pause cuts it); the `think` event says why ("filler" |
"unfinished"). The speaker's words up to each such pause are kept with the sentence, so the final can find the pause among its own
words.

THE FINAL'S MODEL may differ by language (`final_decoders`: Canary for Dutch, research 11.5). A final then goes through ONE chain
(textrules.finish): a repeat across a filler or a held pause said once ("X uh X" -> "X"), the fillers, THE TIDY PASS (sttlib/tidy.py,
off unless the shell asks: false starts, repeats and stutters), and the text rules (`text`, shell.jsonc `dictation.text`: the user's
words, F-keys, "<name> sign", the take's leading ">", and a sentence that continues one written unfinished begun in lower case --
also in its live words). `seg` carries what was heard (`raw`) beside what is written (`text`) and the names of the rules that changed
it (`rules`).

THE LANGUAGE (section 8.5): forced, or `auto` -- decode at once in the prior, and when `lidSpeechMs` of speech is in (or the first
utterance ends first) the detector decides; a decision that differs re-decodes the open utterance at once. Fixed for the take.

The engine has no clock and no audio source of its own: `feed(samples, now)` and `tick(now)` are called by a driver -- the helper on
the wall clock with pw-record's audio, the bench on a simulated clock that advances by the audio and by every decode's measured cost
(so the bench's latencies are the live ones without waiting in real time). Events go to `emit(dict)`.
"""
import re
import time

import numpy as np

from . import fillers, textrules

RATE = 16000
FRAME = 512

DEFAULTS = {
    "endSilenceMs": 700,
    "hopMs": 700,
    "firstHopMs": 500,
    "preRollMs": 300,
    "minSpeechMs": 96,
    "tailMs": 200,
    "softCutS": 15.0,
    "hardCutS": 25.0,
    "softPauseMs": 250,
    "threshold": 0.5,
    "thinkSilenceMs": 3000,
    "lidSpeechMs": 1500,
    "minDecodeMs": 400,
}

_NORM = re.compile(r"[^\w']+", re.UNICODE)


def norm(w: str) -> str:
    return _NORM.sub("", w.lower())


def words_of(text: str) -> list:
    return [w for w in (text or "").split() if w]


def agreed(prev: list, words: list) -> int:
    """How many of `words` (from the front) the previous hypothesis `prev` agrees with, compared by LETTERS (case, punctuation and
    word breaks blind): "good bye now" and "goodbye now" agree on all of it, a split or merge of up to four words counts. A word that
    is only punctuation agrees with anything (it carries no letter)."""
    i = j = 0
    while i < len(prev) and j < len(words):
        a, b = norm(prev[i]), norm(words[j])
        if not a:
            i += 1
            continue
        if not b:
            j += 1
            continue
        ii, jj = i + 1, j + 1
        while a != b:
            if len(a) < len(b) and ii < len(prev) and ii - i < 4:
                a += norm(prev[ii])
                ii += 1
            elif len(b) < len(a) and jj < len(words) and jj - j < 4:
                b += norm(words[jj])
                jj += 1
            else:
                return j
        i, j = ii, jj
    return j


def tail_from(stable: list, words: list) -> int:
    """Where in `words` the text AFTER the stable words begins, by letters: the first word that starts at or past the letters the
    stable words hold. A hypothesis that re-splits or merges words before that point (the stable "goodbye now", the new "good bye now
    again") still continues from the right word -- the old index arithmetic (`words[len(stable):]`) showed "now" twice there, or froze
    the sentence when the new hypothesis had fewer words (round 8, the user's duplicated live text)."""
    n = sum(len(norm(w)) for w in stable)
    seen = 0
    for k, w in enumerate(words):
        if seen >= n:
            return k
        seen += len(norm(w))
    return len(words)


class Engine:
    def __init__(self, decoder, vad, emit, cfg=None, detector=None, final_decoder=None, final_decoders=None, tidier=None,
                 text=None):
        self.decoder = decoder
        # THE SECOND PASS (research 8.4): a better, slower model for the one final decode of each utterance, the fast one for the
        # live hypotheses -- one for every language (`final_decoder`), or per language (`final_decoders`, {"nl": canary}, which
        # wins); None: the live model for both
        self.final_decoder = final_decoder
        self.final_decoders = dict(final_decoders or {})
        self.tidier = tidier              # (text, lang) -> (text, info), or None
        self.text = textrules.TextRules(text)   # shell.jsonc `dictation.text`, verbatim (None: the defaults)
        self.vad = vad
        self.emit = emit
        self.cfg = dict(DEFAULTS, **(cfg or {}))
        self.detector = detector          # audio -> (lang | None, p, how)
        self.take = None
        self.decode_log = []              # (audio_ms, decode_ms, final) for stats

    # ---- the take ------------------------------------------------------------------------------------------------------
    def start(self, take, lang="auto", prior="en", now=0.0):
        self.take = take
        self.mode = lang if lang in ("en", "nl") else "auto"
        self.lang = self.mode if self.mode != "auto" else (prior if prior in ("en", "nl") else "en")
        self.lang_decided = self.mode != "auto"
        self.lang_how = "forced" if self.lang_decided else "prior"
        self.vad.reset()
        self.buf = np.zeros(RATE * 30, dtype=np.float32)
        self.n = 0
        self.speech_frames = 0
        self.seg = 0
        self.rev = 0
        self.floor = 0                    # an utterance never starts before the previous one ended
        self._speech_run = 0
        self._silence_run = 0
        self._in_speech = False
        self.open = False
        self.finals = []                  # closed utterances waiting for their final decode, oldest first
        self._prev_text = None            # the take's last written sentence (None: nothing written yet)
        self._check = None                # (a, b, lang, raw): a decode made to judge a pause, for that close's final to reuse
        self.u_start = self.u_end = self.last_speech = 0
        self._reset_hyp()
        self.next_decode = 0.0
        self.segs = 0
        self.lid_from = None
        self.onset_sample = 0
        self.last_decode_ms = 0.0
        if self.lang_decided:
            self.emit({"ev": "lang", "take": take, "lang": self.lang, "p": 1.0, "how": "forced"})

    def _reset_hyp(self):
        self.prev_words = []
        self.stable = []
        self.shown = ""
        self.hyps = 0
        self._raw_last = ""               # the newest live decode as the model wrote it (fillers and all)
        self._raw_upto = 0                # ... and the sample it heard up to
        self._think_key = -1              # the pause judged (by its last speech sample), the judgement ("filler" | "unfinished" | "")
        self._think = ""
        self._think_raw = ""              # ... and the words heard up to it
        self._held_at = -1                # the pause last held open
        self._marks = []                  # the words heard up to each held pause of this utterance (fillers.drop_repeats)

    def _append(self, samples):
        need = self.n + samples.size
        if need > self.buf.size:
            nb = np.zeros(max(need, self.buf.size * 2), dtype=np.float32)
            nb[: self.n] = self.buf[: self.n]
            self.buf = nb
        self.buf[self.n: need] = samples
        self.n = need

    def feed(self, samples, now):
        if self.take is None or samples.size == 0:
            return
        base_frame = self.vad.frames
        self._append(samples)
        c = self.cfg
        thr, neg = c["threshold"], c["threshold"] - 0.15
        for i, p in enumerate(self.vad.feed(samples)):
            f = base_frame + i
            end = (f + 1) * FRAME
            if p >= thr:
                self.speech_frames += 1
                self._in_speech = True
            elif p < neg:
                self._in_speech = False
            if not self.open:
                self._speech_run = self._speech_run + 1 if self._in_speech else 0
                if self._speech_run * FRAME * 1000 / RATE >= c["minSpeechMs"]:
                    onset = (f - self._speech_run + 1) * FRAME
                    self.u_start = max(self.floor, onset - int(c["preRollMs"] * RATE / 1000))
                    self.last_speech = end
                    self.open = True
                    self._silence_run = 0
                    self._reset_hyp()
                    self.next_decode = now + c["firstHopMs"] / 1000.0
                    self.onset_sample = onset
                    if self.lid_from is None:
                        self.lid_from = self.u_start       # the detector hears the take from its first utterance on
                continue
            if self._in_speech:
                self.last_speech = end
                self._silence_run = 0
            else:
                self._silence_run += 1
            sil_ms = self._silence_run * FRAME * 1000 / RATE
            length_s = (end - self.u_start) / RATE
            pause = sil_ms >= c["endSilenceMs"] or (length_s >= c["softCutS"] and sil_ms >= c["softPauseMs"])
            held = pause and self._holds(sil_ms, length_s)
            if pause and (not held or sil_ms >= c["thinkSilenceMs"]):
                self._close(min(end, self.last_speech + int(c["tailMs"] * RATE / 1000)), "think" if held else "pause")
            elif length_s >= c["hardCutS"]:
                self._close(end, "hard")

    def _close(self, u_end, why):
        # A SNAPSHOT: the next utterance may open in the same feed (a decode blocks the loop, so one feed can carry a pause and
        # the speech after it), and it must not move what this one's final decode reads -- that lost whole sentences.
        self.open = False
        self._speech_run = 0
        self.u_end = u_end
        self.floor = u_end
        self.finals.append({"a": self.u_start, "b": u_end, "why": why, "hyps": self.hyps, "marks": list(self._marks)})

    def _thinking(self):
        """Why the pause under way is thinking, not the sentence's end: "filler" (the last word was one), "unfinished" (the words
        before it have not ended a sentence), or "" (judged once per pause)."""
        if self._think_key == self.last_speech:
            return self._think
        self._think_key = self.last_speech
        if self._raw_upto >= self.last_speech:
            raw = self._raw_last              # the newest hypothesis heard all the speech before this pause
        else:
            b = min(self.n, self.last_speech + int(self.cfg["tailMs"] * RATE / 1000))
            raw = self._decode(self.u_start, b, False)
            self._check = (self.u_start, b, self.lang, raw)
        self._think_raw = raw
        if fillers.ends_in_filler(raw, self.lang, self.text.fillers):
            self._think = "filler"
        elif self.text.hold(fillers.strip(raw, self.lang, self.text.fillers), self.lang):
            self._think = "unfinished"
        else:
            self._think = ""
        return self._think

    def _holds(self, sil_ms, length_s):
        """The pause under way keeps the sentence open: after a filler from the first, after unfinished words once it is a real
        pause (endSilenceMs) in an utterance not yet past softCutS -- a long one is cut at its next pause whatever it ends with, or
        held pauses would carry it to the hard cut, which cuts mid-word."""
        why = self._thinking()
        held = why == "filler" or (why == "unfinished" and sil_ms >= self.cfg["endSilenceMs"] and length_s < self.cfg["softCutS"])
        if held and self._held_at != self.last_speech:
            self._held_at = self.last_speech
            self._marks.append(self._think_raw)
            self.emit({"ev": "think", "take": self.take, "seg": self.seg, "waitMs": int(self.cfg["thinkSilenceMs"]), "why": why})
        return held

    @property
    def pending_final(self):
        return self.finals[-1]["why"] if self.finals else None

    # ---- decoding --------------------------------------------------------------------------------------------------------
    def _final_dec(self):
        return self.final_decoders.get(self.lang) or self.final_decoder or self.decoder

    def _decode(self, a, b, final, lang=None):
        audio = self.buf[a:b]
        t0 = time.perf_counter()
        dec = self._final_dec() if final else self.decoder
        text = dec.decode(audio, lang or self.lang)
        ms = (time.perf_counter() - t0) * 1000
        self.decode_log.append(((b - a) * 1000 / RATE, ms, final))
        self.last_decode_ms = ms
        return text

    def _maybe_detect(self, now, force=False):
        if self.lang_decided or self.detector is None:
            return
        if not force and self.speech_frames * FRAME * 1000 / RATE < self.cfg["lidSpeechMs"]:
            return
        end = self.n if self.open else self.u_end
        lang, p, how = self.detector(self.buf[max(self.lid_from, end - 8 * RATE): end])
        self.lang_decided = True
        if lang in ("en", "nl"):
            changed = lang != self.lang
            self.lang, self.lang_how = lang, how
            if changed and self.open:
                self.prev_words, self.stable = [], []      # the old language's words are no agreement for the new one
                self._raw_upto = 0                         # ... nor its hypothesis a hearing of the speech
                self.next_decode = now
        self.emit({"ev": "lang", "take": self.take, "lang": self.lang, "p": round(p, 3), "how": self.lang_how})

    def tick(self, now):
        """Decode when due; returns True when it decoded (the driver's clock advances by the work)."""
        if self.take is None:
            return False
        if self.pending_final is not None:
            self._maybe_detect(now, force=True)
            self._final()
            return True
        if not self.open:
            return False
        self._maybe_detect(now)
        if now < self.next_decode or (self.n - self.u_start) * 1000 / RATE < self.cfg["minDecodeMs"]:
            return False
        if self._raw_upto >= self.last_speech and self._silence_run > 0:
            return False                  # nothing said since the last decode (a pause): the same words again
        t0 = time.perf_counter()
        upto = self.n
        text = self._decode(self.u_start, upto, False)
        self._raw_last, self._raw_upto = text, upto
        self._hyp(fillers.strip(text, self.lang, self.text.fillers))
        took = time.perf_counter() - t0
        self.next_decode = now + max(self.cfg["hopMs"] / 1000.0, 1.5 * took)
        return True

    def _hyp(self, text):
        words = words_of(text)
        if words and self.text.continues(self._prev_text, self.lang):
            words[0] = self.text.continue_word(words[0])   # as the final will write it (textrules: "continue")
        k = agreed(self.prev_words, words)
        t = tail_from(self.stable, words)
        if t < k:
            self.stable = self.stable + words[t:k]   # the agreement reaches past what is stable: it grows, the old words stay
        self.prev_words = words
        shown = " ".join(self.stable + words[tail_from(self.stable, words):])
        if shown != self.shown:
            self.shown = shown
            self.rev += 1
            self.hyps += 1
            self.emit({"ev": "hyp", "take": self.take, "seg": self.seg, "rev": self.rev, "stable": " ".join(self.stable),
                       "text": shown})

    def _final(self):
        u = self.finals.pop(0)
        why = u["why"]
        chk, self._check = self._check, None
        if chk is not None and chk[:3] == (u["a"], u["b"], self.lang) and self._final_dec() is self.decoder:
            raw = chk[3]                  # the pause's own decode heard exactly this sentence
        else:
            raw = self._decode(u["a"], u["b"], True)
        text, rules, tidy = textrules.finish(raw, self.lang, self.text, first=self._prev_text is None, prev=self._prev_text,
                                             marks=u["marks"], tidier=self.tidier)
        audio_ms = int((u["b"] - u["a"]) * 1000 / RATE)
        if text:
            self._prev_text = text
        if text or u["hyps"]:
            # an empty final after shown words still closes the segment: the shell clears its preedit
            ev = {"ev": "seg", "take": self.take, "seg": self.seg, "text": text, "lang": self.lang,
                  "atMs": int(u["a"] * 1000 / RATE), "audioMs": audio_ms, "cut": why, "raw": " ".join(words_of(raw)),
                  "rules": rules}
            if tidy is not None:
                ev["tidy"] = tidy
            self.emit(ev)
            self.emit({"ev": "stats", "take": self.take, "seg": self.seg, "decodeMs": int(self.last_decode_ms),
                       "rtf": round(self.last_decode_ms / max(1, audio_ms), 3), "tidyMs": tidy["ms"] if tidy else 0})
            self.seg += 1
            self.segs += 1
        if not self.open:
            self._reset_hyp()

    def stop(self, now, reason="stop"):
        """Finish the open utterance (decoded once more, emitted), then `ended`."""
        if self.take is None:
            return
        if self.open:
            self._close(self.n, "stop")
        if self.finals:
            self._maybe_detect(now, force=True)
        while self.finals:
            self._final()
        self.emit({"ev": "ended", "take": self.take, "reason": reason, "segs": self.segs})
        self.take = None

    def cancel(self):
        if self.take is None:
            return
        self.emit({"ev": "ended", "take": self.take, "reason": "cancel", "segs": self.segs})
        self.take = None
