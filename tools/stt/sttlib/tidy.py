"""The tidy pass (shell.jsonc `"dictation": { "tidy": true }`, off by default): a sentence's final text without its false starts,
repeats, stutters and self-corrected words, the way Google's Rambler reads lazily spoken speech (research section 2.4).

A small instruct model PROPOSES which words go; it cannot write a word of its own: its decoding is constrained to an in-order
subsequence of the sentence's own words (whole words, each with its punctuation, so a word is kept or dropped, never cut). Then a
deterministic GUARD decides (CLAUDE.md: a small local model asked to obey rules recites them -- check the output, never the prompt):

  only removal    the output's words are an in-order subsequence of the input's (case and punctuation blind); a word that is not
                  the input's, or one out of order, refuses the WHOLE proposal ("added")
  explained       each run of removed words is applied only if it is a disfluency the guard can name: a REPEAT (the run is said
                  again right before or after it), a RESTART (it begins with the word the speaker starts again with and ends where
                  the recogniser heard the break: a comma or a dash), a CORRECTION (words, then a cue -- "sorry", "I mean", "no",
                  "nee", "ik bedoel" -- that ends the run: the corrected words go with the cue, never the cue alone), or a STUTTER
                  (fragments the next word begins with). A run it cannot name stays in the sentence (round 6, the user's call:
                  "apply the explainable part" -- "works works rather well" with "rather" dropped too writes "works rather well");
                  the runs are judged again against what is kept until none changes. The words are matched to the sentence from
                  its END: the speaker's last saying is the one kept, so "The the report" keeps the second "the".
  enough kept     at least half the words stay, after the unexplained runs are put back; else nothing is applied

A refused or late proposal leaves the sentence as it was heard (the fillers are gone either way: sttlib/fillers.py). Reordering is
not offered: removal alone covers the false starts, repeats and stutters the user named.

    t = load(tid, device)       tid: a TIDY_MODELS id or a stub; device "CUDA" | "CPU"
    out, info = t(text, lang)   info: {"ok", "why", "ms", "proposed", "kept"}: ok -- a removal was applied, or the proposal
                                changed nothing; why -- what refused it, or what was put back ("unexplained 'rather'");
                                kept -- the removed runs put back
    text, why, kept = guard(src, proposal, lang)    the guard alone (the sentence as written)
"""
import json
import os
import re
import time
from pathlib import Path

import numpy as np

from .fillers import core
from .textrules import HOLD_WORDS

HOME = Path(os.environ.get("LARES_STT_HOME", Path.home() / ".cache" / "lares-stt"))
MODELS_DIR = HOME / "models"

# The candidates (onnx-community exports, each pinned to the revision benched; research section 11.5 has the numbers). `q4`:
# 4-bit weights (MatMulNBits) with fp32 activations -- one file for onnxruntime's CPU and CUDA providers alike.
TIDY_MODELS = {
    "qwen2.5-0.5b-instruct": {
        "repo": "onnx-community/Qwen2.5-0.5B-Instruct", "rev": "22942cb7d7ba4cc81bb4673549ca4d4614469b5e", "chat": "chatml",
        "onnx": "onnx/model_q4.onnx",
        "files": ["onnx/model_q4.onnx", "tokenizer.json", "config.json", "generation_config.json"],
    },
    "gemma-3-1b-it": {
        "repo": "onnx-community/gemma-3-1b-it-ONNX", "rev": "a58439f40017d3b99c7d378ff525e54e0ba08ebf", "chat": "gemma",
        "onnx": "onnx/model_q4.onnx",
        "files": ["onnx/model_q4.onnx", "onnx/model_q4.onnx_data", "tokenizer.json", "config.json", "generation_config.json"],
    },
}
TIDY_PICK = "gemma-3-1b-it"
BUDGET_MS = int(os.environ.get("LARES_STT_TIDY_BUDGET_MS", "2500"))

SYSTEM = ("You clean up dictated speech. Remove false starts, repeated words, stutters and words the speaker corrected. "
          "Keep every other word exactly as it is, in the same order. Write only the cleaned sentence.")
# few-shot pairs: what a removal looks like, and that a clean sentence stays whole
EXAMPLES = [
    ("I want to, I want to go home.", "I want to go home."),
    ("We meet on Thursday, sorry, Friday.", "We meet on Friday."),
    ("The the report is ready.", "The report is ready."),
    ("This sentence is already clean.", "This sentence is already clean."),
    ("Ik wil, ik wil naar huis.", "Ik wil naar huis."),
    ("Zet de, zet de verwarming hoger.", "Zet de verwarming hoger."),
]

# ---- the guard ---------------------------------------------------------------------------------------------------------------------
CUES = {
    "en": [["sorry"], ["i", "mean"], ["no"], ["wait"], ["actually"], ["rather"], ["or", "rather"]],
    "nl": [["sorry"], ["ik", "bedoel"], ["nee"], ["wacht"], ["of", "nee"], ["eigenlijk"], ["pardon"]],
}


def _ends_in_cue(span, lang):
    """The run ends with a correction cue and has a word before it: the length of the cue, else 0."""
    cs = [core(w) for w in span]
    for cue in CUES.get(lang, []) + (CUES["en"] if lang != "en" else []):
        n = len(cue)
        if len(cs) > n and cs[-n:] == cue:
            return n
    return 0


# words a speaker breaks off on (round 8): a restart's abandoned run stops where a phrase cannot end ("let's go to the,"), not at a
# complete phrase -- "one is a brain, one is a pencil" is an enumeration, and the guard once wrote "one is a pencil" (the user's take
# of 2026-11-13: the brain was gone). The sets of HOLD_WORDS (a pause after one is unfinished) plus the verbs and pronouns a clause
# stops on.
_BREAK_EXTRA = {
    "en": {"is", "are", "was", "were", "be", "been", "have", "has", "had", "will", "would", "should", "could", "can", "do", "does",
           "did", "i", "we", "you", "they", "he", "she", "it", "not", "so", "then", "just", "also", "very", "really"},
    "nl": {"is", "zijn", "was", "waren", "heb", "heeft", "hebben", "zal", "zou", "kan", "kunnen", "ik", "we", "wij", "je", "jij",
           "ze", "zij", "hij", "het", "niet", "dan", "ook", "zo", "heel"},
}


def _broken_off(span, lang):
    """The removed run ends where a phrase cannot: on a function word (`the`, `to`, `and` ...) or a bare verb / pronoun."""
    last = span[-1]
    return last in HOLD_WORDS.get(lang, HOLD_WORDS["en"]) or last in _BREAK_EXTRA.get(lang, _BREAK_EXTRA["en"])


def _explained(src, a, b, kept, lang):
    """Is src[a:b] (removed) a disfluency the guard can name?"""
    span = [core(w) for w in src[a:b]]
    k = b - a
    before = [core(w) for w in src[max(0, a - k): a]]
    after_all = [core(src[i]) for i in range(b, len(src)) if i in kept]
    after = [core(w) for w in src[b: b + k]]
    if span == before or span == after:
        return "repeat"
    if after_all and span[0] == after_all[0] and re.search(r"[,\u2014-]$", src[b - 1]) and _broken_off(span, lang):
        return "restart"
    n = _ends_in_cue(src[a:b], lang)
    if n and k <= n + 4:
        return "correction"
    if after_all and k <= 2 and all(s and len(s) < len(after_all[0]) and after_all[0].startswith(s) for s in span):
        return "stutter"
    return ""


def _runs(n, kept):
    """The runs [a, b) of indices not in `kept`."""
    a = 0
    while a < n:
        if a in kept:
            a += 1
            continue
        b = a
        while b < n and b not in kept:
            b += 1
        yield a, b
        a = b


def guard(src_text: str, out_text: str, lang: str = "en"):
    """(text, why, kept): the sentence as the guard lets the proposal write it (module docstring) -- `src_text` itself when
    nothing may be applied; `why` names what refused the proposal or what was put back; `kept`: the removed runs put back."""
    src, out = src_text.split(), out_text.split()
    if not out:
        return src_text, "empty", []
    kept, i = set(), len(src) - 1
    for w in reversed(out):
        c = core(w)
        while i >= 0 and core(src[i]) != c:
            i -= 1
        if i < 0:
            return src_text, "added '%s'" % w, []
        kept.add(i)
        i -= 1
    # the runs it cannot name go back in; putting one back changes what follows another run, so judge again until none changes
    back = []
    while True:
        bad = [(a, b) for a, b in _runs(len(src), kept) if not _explained(src, a, b, kept, lang)]
        if not bad:
            break
        for a, b in bad:
            kept.update(range(a, b))
            back.append(" ".join(src[a:b]))
    if len(kept) * 2 < len(src):
        return src_text, "removed %d of %d words" % (len(src) - len(kept), len(src)), back
    if len(kept) == len(src):
        return src_text, ("unexplained '%s'" % "', '".join(back)) if back else "", back
    text = _recap(src_text, " ".join(src[k] for k in sorted(kept)))
    return text, ("unexplained '%s' kept" % "', '".join(back)) if back else "", back


def _recap(src_text, out_text):
    """The sentence's first letter as the speaker's sentence had it (a removed first word leaves a lower-case one)."""
    if out_text and src_text[:1].isupper() and out_text[:1].islower():
        return out_text[:1].upper() + out_text[1:]
    return out_text


# ---- the model -----------------------------------------------------------------------------------------------------------------------
def _providers(device):
    if device == "CUDA":
        return [("CUDAExecutionProvider", {"device_id": 0, "cudnn_conv_algo_search": "HEURISTIC",
                                           "arena_extend_strategy": "kSameAsRequested"}), "CPUExecutionProvider"]
    return ["CPUExecutionProvider"]


class OnnxLm:
    """A decoder-only ONNX export (onnx-community's: input_ids, attention_mask, [position_ids], past_key_values.N.key/value ->
    logits, present.N.key/value) driven by hand: greedy, with the constrained word choice of `propose`."""

    def __init__(self, tid: str, device: str = "CPU", threads: int = 4):
        import onnxruntime as rt
        from tokenizers import Tokenizer

        spec = TIDY_MODELS[tid]
        d = MODELS_DIR / tid
        self.id, self.chat = tid, spec["chat"]
        self.tok = Tokenizer.from_file(str(d / "tokenizer.json"))
        cfg = json.loads((d / "config.json").read_text())
        so = rt.SessionOptions()
        so.intra_op_num_threads = threads
        so.inter_op_num_threads = 1
        so.add_session_config_entry("session.intra_op.allow_spinning", "0")
        if device == "CUDA":
            rt.preload_dlls(cuda=False, cudnn=True)
        self.s = rt.InferenceSession(str(d / spec["onnx"]), sess_options=so, providers=_providers(device))
        got = self.s.get_providers()[0]
        if device == "CUDA" and got != "CUDAExecutionProvider":
            raise RuntimeError("the CUDA provider did not take the model (" + got + ")")
        self.device = "CUDA" if got == "CUDAExecutionProvider" else "CPU"
        ins = {i.name: i for i in self.s.get_inputs()}
        self.kv_names = sorted([n for n in ins if n.startswith("past_key_values.")],
                               key=lambda n: (int(n.split(".")[1]), n.endswith("value")))
        self.kv_type = np.float16 if "float16" in ins[self.kv_names[0]].type else np.float32
        self.has_pos = "position_ids" in ins
        heads = cfg.get("num_key_value_heads") or cfg.get("num_attention_heads")
        hd = cfg.get("head_dim") or cfg["hidden_size"] // cfg["num_attention_heads"]
        self.kv_shape = (1, heads, 0, hd)
        self.out_names = [o.name for o in self.s.get_outputs()]
        self.eos = self._special("<|im_end|>" if self.chat == "chatml" else "<end_of_turn>")
        # the fixed part of the prompt, run once and kept (each sentence then costs only its own tokens)
        self._prefix_ids = self._ids(self._prefix(), True)
        self._prefix_kv, _ = self._run(self._prefix_ids, None, 0)

    def _special(self, s):
        i = self.tok.token_to_id(s)
        if i is None:
            raise RuntimeError("no token " + s)
        return i

    def _ids(self, text, first=False):
        ids = self.tok.encode(text, add_special_tokens=False).ids
        if first and self.chat == "gemma":
            ids = [self._special("<bos>")] + ids
        return ids

    def _turn(self, role, text):
        if self.chat == "chatml":
            return "<|im_start|>%s\n%s<|im_end|>\n" % (role, text)
        return "<start_of_turn>%s\n%s<end_of_turn>\n" % ("model" if role == "assistant" else "user", text)

    def _prefix(self):
        if self.chat == "chatml":
            p = self._turn("system", SYSTEM)
        else:
            p = ""
        for i, (a, b) in enumerate(EXAMPLES):
            p += self._turn("user", (SYSTEM + "\n\n" + a) if (i == 0 and self.chat == "gemma") else a) + self._turn("assistant", b)
        return p + ("<|im_start|>user\n" if self.chat == "chatml" else "<start_of_turn>user\n")

    def _suffix(self, text):
        if self.chat == "chatml":
            return text + "<|im_end|>\n<|im_start|>assistant\n"
        return text + "<end_of_turn>\n<start_of_turn>model\n"

    def _run(self, ids, kv, past):
        n = len(ids)
        feeds = {"input_ids": np.array([ids], dtype=np.int64),
                 "attention_mask": np.ones((1, past + n), dtype=np.int64)}
        if self.has_pos:
            feeds["position_ids"] = np.arange(past, past + n, dtype=np.int64)[None, :]
        for j, name in enumerate(self.kv_names):
            feeds[name] = kv[j] if kv is not None else np.zeros(self.kv_shape, dtype=self.kv_type)
        outs = self.s.run(self.out_names, feeds)
        logits = outs[0][0, -1]
        return outs[1:], logits

    def propose(self, words, deadline):
        """The kept word indices: greedy decoding over the words' own tokens only, a word whole once begun, in order."""
        n = len(words)
        first = [self._ids(w) for w in words]               # a sentence's first word: no space before it
        later = [self._ids(" " + w) for w in words]
        # a state: (word, token offset, form) -> the words completed on the way there
        states = {(j, 0, f): () for j in range(n) for f in (0, 1)}
        ids = self._ids(self._suffix(" ".join(words)))
        kv, logits = self._run(ids, self._prefix_kv, len(self._prefix_ids))
        past = len(self._prefix_ids) + len(ids)
        done = None
        for _ in range(sum(len(t) for t in later) + 2):
            allowed = {}
            for (j, k, f), path in states.items():
                t = (first if f == 0 else later)[j][k]
                allowed.setdefault(t, []).append((j, k, f, path))
            at_boundary = any(k == 0 for (_, k, _) in states) and any(p for p in states.values())
            cand = list(allowed)
            if at_boundary:
                cand.append(self.eos)
            best = cand[int(np.argmax(logits[cand]))]
            if best == self.eos:
                done = min((p for (_, k, _), p in states.items() if k == 0 and p), key=lambda p: p[-1])
                break
            nxt = {}
            for j, k, f, path in allowed[best]:
                toks = (first if f == 0 else later)[j]
                if k + 1 < len(toks):
                    nxt.setdefault((j, k + 1, f), path)
                else:
                    p2 = path + (j,)
                    for j2 in range(j + 1, n):
                        nxt.setdefault((j2, 0, 1), p2)
                    if j == n - 1:
                        done = p2         # the sentence's last word is out: nothing may follow it
            if done is not None or not nxt:
                break
            states = nxt
            if time.monotonic() > deadline:
                return None
            kv, logits = self._run([best], kv, past)
            past += 1
        else:
            done = None
        if done is None:
            # out of steps or of ways on: the words completed so far (none: the guard refuses an empty proposal)
            done = next((p for p in states.values() if p), ())
        return list(done)


class Stub:
    """A tidier for the probes: `stub-add` proposes the sentence plus a word it never had (the guard must refuse it), `stub-echo`
    proposes the sentence unchanged."""

    def __init__(self, tid):
        self.id, self.device = tid, "CPU"

    def text(self, words):
        return " ".join(words + ["banana"]) if self.id == "stub-add" else " ".join(words)


class Tidier:
    def __init__(self, model, budget_ms=BUDGET_MS):
        self.m = model
        self.id, self.device = model.id, model.device
        self.budget_ms = budget_ms

    def __call__(self, text, lang="en"):
        t0 = time.perf_counter()
        words = text.split()
        info = {"model": self.id, "ok": False, "why": "", "proposed": ""}
        if len(words) < 3:
            info.update(ok=True, why="short", proposed=text)
            return text, self._ms(info, t0)
        try:
            if isinstance(self.m, Stub):
                prop = self.m.text(words)
            else:
                keep = self.m.propose(words, time.monotonic() + self.budget_ms / 1000.0)
                if keep is None:
                    info["why"] = "late"
                    return text, self._ms(info, t0)
                prop = " ".join(words[i] for i in keep)
        except Exception as e:  # noqa: BLE001 -- a tidy that fails leaves the sentence as heard
            info["why"] = "error: " + str(e)[:120]
            return text, self._ms(info, t0)
        prop = _recap(text, prop)
        info["proposed"] = prop
        out, why, back = guard(text, prop, lang)
        # ok: a removal it can name was applied, or the proposal changed nothing (a clean sentence)
        ok = out.split() != text.split() or prop.split() == text.split()
        info.update(ok=ok, why=why, kept=back)
        return out, self._ms(info, t0)

    @staticmethod
    def _ms(info, t0):
        info["ms"] = int((time.perf_counter() - t0) * 1000)
        return info


def present():
    return [t for t, s in TIDY_MODELS.items() if all((MODELS_DIR / t / f).exists() for f in s["files"])]


def load(tid: str, device: str = "CPU", threads: int = 4):
    if tid.startswith("stub-"):
        return Tidier(Stub(tid))
    if tid not in TIDY_MODELS:
        raise RuntimeError("unknown tidy model " + tid)
    if tid not in present():
        raise RuntimeError("the tidy model is not on disk: run tools/stt/fetch.py tidy")
    return Tidier(OnnxLm(tid, device, threads))
