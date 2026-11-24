"""A local model as the judge: the same questions as judge_jev, answered through Ollama's /api/chat.

    OllamaClient(url, transport=None)   one place that talks to /api/chat (think:false, its fallback,
                                        JSON parsing, timings); generate.py uses it for the writer
    OllamaJudge(model, url=...)         the Judge interface (judge.py) on top of it
    CANDIDATES                          the five models that fit the RTX 4060's 8 GiB at ctx 8192

Structured output, the way LlmBackend.classify does it: `format` = a JSON schema, stream:false, temperature
0, `think:false` for a model that can think (ornith-1.5 thinks by default and would burn hundreds of
tokens on a five-field answer). A model without a thinking switch answers HTTP 400 to `think`; the client
retries once without it and remembers, per model. options.num_ctx 8192 (the size the residency figures
in LlmModelNotes.qml were measured at: another num_ctx would reload the model), keep_alive "5m" while a
run is going.

The locator's paragraph is an ENUM of "0".."n-1" plus "none" (enum is the schema feature every Ollama
build supports; a nullable integer is not portable). The four rule numbers come back in the same
answer, ordered after the pick so the model has committed to a paragraph before it rates it.

Calibration caveat: a local model's probability is what it STATES about itself. It is not a computed
probability like Jev's, small models cluster near 0.9 and 0.1, and it says nothing about how often it is
right: `probs` therefore holds only {pick: stated confidence, "none": the rest}. The eval fits a
threshold per model on the labelled corpus instead of trusting the number.

The page view is cut to about 9 000 characters (judge.views) so prompt + page stay well inside 8192
tokens; `promptTokens` is returned and a prompt at 90 % of the window is reported as `truncated`.

Transport: transport(url, body, headers, timeout) -> parsed JSON. The default is http.post_json.
"""
from __future__ import annotations

import json
import time

from . import http, judge
from .judge import Judge, JudgeError, JudgeUnavailable, clamp01, fill, prompts, rules_block

DEFAULT_URL = judge.DEFAULT_OLLAMA_URL
NUM_CTX = 8192
# resident on the 8 GiB card at ctx 8192 (LlmModelNotes.qml), fastest first
CANDIDATES = ["gemma4:e2b", "granite4.2:3b", "gemma4:e4b", "granite4.2:8b", "ornith-1.5:9b"]


def _default_transport(url, body, headers, timeout):
    return http.post_json(url, body, headers=headers, timeout=timeout)


def parse_json_content(text):
    """The JSON object in a model's reply. Schema-constrained output is pure JSON; a server without
    schema support hands it back in a fence or a sentence, so fall back to the outermost braces."""
    if not isinstance(text, str) or not text.strip():
        raise JudgeError("empty answer", reason="bad-json")
    try:
        d = json.loads(text)
    except ValueError:
        a, b = text.find("{"), text.rfind("}")
        if a < 0 or b <= a:
            raise JudgeError("no JSON object in the answer: %r" % text[:80], reason="bad-json") from None
        try:
            d = json.loads(text[a:b + 1])
        except ValueError:
            raise JudgeError("unreadable JSON in the answer: %r" % text[:80], reason="bad-json") from None
    if not isinstance(d, dict):
        raise JudgeError("the answer is not a JSON object", reason="bad-json")
    return d


class OllamaClient:
    def __init__(self, url=DEFAULT_URL, transport=None, num_ctx=NUM_CTX, keep_alive="5m", timeout=300,
                 think=False):
        self.url = url.rstrip("/")
        self.transport = transport or _default_transport
        self.num_ctx = num_ctx
        self.keep_alive = keep_alive
        self.timeout = timeout
        self.think = think                 # what to send as `think`; None sends nothing
        self._no_think = set()             # models that answered 400 to `think`
        self.calls = 0
        self.prompt_tokens = 0
        self.eval_tokens = 0
        self.eval_ns = 0
        self.total_ns = 0

    def chat(self, model, messages, schema=None, options=None):
        """One /api/chat call -> {content, promptTokens, evalTokens, evalNs, totalNs, ms}. Raises
        JudgeUnavailable when Ollama cannot be reached or the model is not installed, JudgeError otherwise."""
        opts = {"temperature": 0, "num_ctx": self.num_ctx}
        opts.update(options or {})
        body = {"model": model, "messages": messages, "stream": False, "keep_alive": self.keep_alive,
                "options": opts}
        if schema is not None:
            body["format"] = schema
        if self.think is not None and model not in self._no_think:
            body["think"] = self.think
        t0 = time.monotonic()
        while True:
            try:
                d = self.transport(self.url + "/api/chat", body, None, self.timeout)
                break
            except http.HttpError as e:
                if e.status == 400 and "think" in body:
                    del body["think"]              # the model has no thinking switch: use it as it is
                    self._no_think.add(model)
                    continue
                if e.status == 404:
                    raise JudgeUnavailable("model %s is not installed (HTTP 404)" % model,
                                           reason="model-missing") from None
                raise JudgeError("Ollama answered HTTP %s: %s" % (e.status, str(e)[:160]),
                                 reason="ollama-error") from None
            except http.NetError as e:
                raise JudgeUnavailable("Ollama is not reachable: %s" % e, reason="ollama-unavailable") from None
        ms = (time.monotonic() - t0) * 1000.0
        if not isinstance(d, dict) or d.get("error"):
            raise JudgeError("Ollama error: %s" % (d.get("error") if isinstance(d, dict) else d),
                             reason="ollama-error")
        msg = d.get("message") or {}
        pt, et = int(d.get("prompt_eval_count") or 0), int(d.get("eval_count") or 0)
        en, tn = int(d.get("eval_duration") or 0), int(d.get("total_duration") or 0)
        self.calls += 1
        self.prompt_tokens += pt
        self.eval_tokens += et
        self.eval_ns += en
        self.total_ns += tn
        return {"content": msg.get("content") or "", "promptTokens": pt, "evalTokens": et, "evalNs": en,
                "totalNs": tn, "ms": ms, "truncated": pt >= 0.9 * self.num_ctx}

    def tokps(self):
        """Generated tokens per second by the server's own counters (eval_count / eval_duration)."""
        return self.eval_tokens / (self.eval_ns / 1e9) if self.eval_ns else None


def _num(d, *keys):
    for k in keys:
        if k in d:
            return clamp01(d[k])
    raise JudgeError("the answer has none of %s: %r" % (keys, sorted(d)), reason="bad-json")


def _rules_from(d):
    return {"defines": _num(d, "defines"), "hook": _num(d, "hook"),
            "selfContained": _num(d, "self_contained", "selfContained"),
            "noHowTo": 1.0 - _num(d, "howto_opening", "howto")}


_RULE_PROPS = {"defines": {"type": "number"}, "hook": {"type": "number"},
               "self_contained": {"type": "number"}, "howto_opening": {"type": "number"}}


class OllamaJudge(Judge):
    def __init__(self, model, url=DEFAULT_URL, client=None, transport=None, max_paras=40, max_chars=600,
                 max_total=9000):
        self.model = model
        self.name = "ollama:" + model
        self.client = client or OllamaClient(url, transport=transport)
        self.max_paras, self.max_chars, self.max_total = max_paras, max_chars, max_total
        self.ms_total = 0.0

    # -- plumbing

    def _ask(self, system, user, schema):
        r = self.client.chat(self.model, [{"role": "system", "content": system},
                                          {"role": "user", "content": user}], schema)
        self.ms_total += r["ms"]
        return parse_json_content(r["content"]), r

    def _system(self, key):
        p = prompts()
        return fill(p["local"][key], definition=p["definition"], **rules_block())

    # -- the interface

    def locate(self, page):
        pairs = judge.views(page, max_paras=self.max_paras, max_chars=self.max_chars,
                            max_total=self.max_total)
        if not pairs:
            return {"para": None, "probs": {}, "confidence": 1.0, "rules": None, "ms": 0.0, "tokens": 0,
                    "judge": self.name, "of": 0}
        options = [str(i) for i, _ in pairs] + ["none"]
        schema = {"type": "object",
                  "properties": dict([("intro_para", {"type": "string", "enum": options}),
                                      ("confidence", {"type": "number"})] + list(_RULE_PROPS.items())),
                  "required": ["intro_para", "confidence", "defines", "hook", "self_contained",
                               "howto_opening"]}
        user = fill(prompts()["local"]["locate_user"], title=judge.page_title(page),
                    paragraphs=judge.numbered_view(pairs))
        d, r = self._ask(self._system("locate_system"), user, schema)
        choice = str(d.get("intro_para", "none")).strip()
        shown = {str(i) for i, _ in pairs}
        if choice not in shown:
            choice = "none"                      # "none", or a number the model was not offered
        conf = _num(d, "confidence")
        para = None if choice == "none" else int(choice)
        return {"para": para,
                "probs": {choice: conf, "none" if choice != "none" else "other": round(1.0 - conf, 4)},
                "confidence": conf,
                "rules": _rules_from(d) if para is not None else None,
                "ms": r["ms"], "tokens": r["promptTokens"] + r["evalTokens"],
                "promptTokens": r["promptTokens"], "evalTokens": r["evalTokens"], "evalNs": r["evalNs"],
                "truncated": r["truncated"], "judge": self.name, "of": len(pairs)}

    def rules(self, page, paras_idx):
        idx = [int(i) for i in paras_idx]
        pairs = judge.views(page, max_paras=self.max_paras, max_chars=self.max_chars,
                            max_total=self.max_total, focus=idx)
        schema = {"type": "object", "properties": dict(_RULE_PROPS),
                  "required": ["defines", "hook", "self_contained", "howto_opening"]}
        user = fill(prompts()["local"]["rules_user"], title=judge.page_title(page),
                    paragraphs=judge.numbered_view(pairs), judged=judge.para_phrase(idx))
        d, r = self._ask(self._system("rules_system"), user, schema)
        out = _rules_from(d)
        out.update({"ms": r["ms"], "tokens": r["promptTokens"] + r["evalTokens"]})
        return out

    def grounded(self, source_text, summary):
        d, _ = self._ask(prompts()["local"]["grounded_system"],
                         fill(prompts()["local"]["grounded_user"], source=source_text, summary=summary),
                         {"type": "object", "properties": {"grounded": {"type": "number"}},
                          "required": ["grounded"]})
        return _num(d, "grounded")

    def graphic(self, caption, description):
        d, _ = self._ask(prompts()["local"]["graphic_system"],
                         fill(prompts()["local"]["graphic_user"], caption=caption, description=description),
                         {"type": "object", "properties": {"graphic": {"type": "number"}},
                          "required": ["graphic"]})
        return _num(d, "graphic")

    def interest(self, title, lead, recent_titles):
        d, _ = self._ask(prompts()["local"]["interest_system"],
                         fill(prompts()["local"]["interest_user"], recent="; ".join(recent_titles or ()) or "(nothing yet)",
                              title=title, lead=judge.clip(lead or "", 600)),
                         {"type": "object", "properties": {"interest": {"type": "number"}},
                          "required": ["interest"]})
        return _num(d, "interest")

    def usage(self):
        c = self.client
        return {"calls": c.calls, "tokensIn": c.prompt_tokens, "tokensOut": c.eval_tokens, "usd": 0.0,
                "tokps": c.tokps(), "msTotal": self.ms_total}
