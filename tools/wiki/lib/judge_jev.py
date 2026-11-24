"""Jev (TypeSafe System One, through the Defapi reseller) as the judge.

    JevJudge(budget=Budget(), mode="twopass"|"onepass")

The protocol as it really is: docs/contracts/wiki_jev_api.md. `POST https://api.defapi.org/api/v1/
decisions`, `Authorization: Bearer <key>`, body {model, state, questions}. The key comes from
env.jev_key() (`jevKey` in config/wiki.jsonc) at the first call and lives in one private attribute: it is put in the
Authorization header and nowhere else (not in the body, a message, a repr, an event or a log; every
message is scrubbed by env.scrub anyway).

Locating and rating a page is ONE question set over ONE state ({"page_title", "paragraphs": {"0": ...}}),
in one of two shapes (the eval measures both on the corpus and models.json keeps the better):

  twopass  request 1: the choice `intro_para` over "0".."n-1" + "none".
           request 2 (only when the pick is not "none"): the four rule noul about "Paragraph N", with the
           same whole page as state (jev_api.md: a paragraph judged without its page scores higher on every
           rule, so the page always travels). Costs the page's tokens twice.
  onepass  one request: the choice and the four rule noul phrased about "the paragraph that best
           introduces the topic". Half the cost; the rules describe whatever paragraph the model would
           pick, not necessarily the one the choice answered.

Rules come back as probabilities of "yes"; a "no" sits near 0.5 (jev_api.md section 7), so the thresholds
are fitted, not assumed. `noHowTo` is 1 - P(howto_opening).

Interest in a batch of candidates is ONE request too (`interest_many`): the state is {recently_opened_titles,
candidates: [{n, title, lead}]} and each candidate gets its own `score` question (`interest_<n>`), because a request
pays about 300 tokens of framing whatever it asks and the state is not repeated per question (jev_api.md section 4).
At most MAX_INTEREST candidates travel together, so a request stays a few thousand tokens.

Money: every call is counted from usage.input_tokens (Budget). Before a call its cost is ESTIMATED from
the size of the JSON, and the budget refuses (BudgetExceeded, reason "jev-budget") a call that would pass
the cap. Any non-2xx or network failure is JudgeUnavailable ("jev-unavailable") after one retry on
429 / 5xx; a 400 is a bug in our request (BadRequest, logged with its message, never retried).

Transport: transport(url, body, headers, timeout) -> parsed JSON; the default is http.post_json (which
honours WIKI_HTTP_MAP, so a probe can put a stub behind api.defapi.org). Tests inject a fake one.
"""
from __future__ import annotations

import json
import time

from . import env, http, judge
from .judge import (BadRequest, Budget, Judge, JudgeError, JudgeUnavailable, clamp01, estimate_jev_usd,
                    fill, prompts)

URL = "https://api.defapi.org/api/v1/decisions"
MODEL = "typesafe/jev-1.13"
MODES = ("twopass", "onepass")
MAX_OPTIONS = 255
MAX_INTEREST = 12           # candidates of one interest request: 12 x (600-character lead + a question) is ~3 500 tokens
INTEREST_LEAD_CHARS = 600


def _default_transport(url, body, headers, timeout):
    return http.post_json(url, body, headers=headers, timeout=timeout)


class JevJudge(Judge):
    name = "jev"

    def __init__(self, budget=None, mode="twopass", key=None, transport=None, url=URL, max_paras=30,
                 max_chars=450, max_total=12000, timeout=30, retry_wait=1.0, sleep=time.sleep,
                 budget_usd=None):
        """`budget`: a Budget shared with the rest of the run; without one a private Budget of `budget_usd`
        dollars (default judge.DEFAULT_BUDGET_USD) guards this judge alone."""
        if mode not in MODES:
            raise ValueError("mode must be one of %s" % (MODES,))
        self.budget = budget if budget is not None else Budget(
            judge.DEFAULT_BUDGET_USD if budget_usd is None else budget_usd)
        self.mode = mode
        self._key = key
        self.transport = transport or _default_transport
        self.url = url
        self.max_paras, self.max_chars, self.max_total = max_paras, max_chars, max_total
        self.timeout = timeout
        self.retry_wait = retry_wait
        self._sleep = sleep
        self.calls = 0
        self.ms_total = 0.0

    def __repr__(self):                       # never the key
        return "JevJudge(mode=%s, spent=$%.4f)" % (self.mode, self.budget.spent)

    # -- the one place a request leaves

    def _headers(self):
        if not self._key:
            self._key = env.jev_key()
        if not self._key:
            hint = env.old_env_hint()
            raise JudgeUnavailable(hint or "no jevKey in config/wiki.jsonc", reason="no-key")
        return {"Authorization": "Bearer " + self._key}

    def _call(self, state, questions):
        """One request -> (answers dict, usage dict, ms). Budget-checked before, counted after."""
        body = {"model": MODEL, "state": state, "questions": questions}
        chars = len(json.dumps(body, ensure_ascii=False))
        self.budget.check(estimate_jev_usd(chars))
        headers = self._headers()
        t0 = time.monotonic()
        attempt = 0
        while True:
            try:
                d = self.transport(self.url, body, headers, self.timeout)
                break
            except http.HttpError as e:
                if e.status == 400:
                    raise BadRequest("Jev refused the request (HTTP 400): %s" % str(e.body or e)[:300]) from None
                if e.status in (429, 500, 502, 503, 504) and attempt == 0:
                    attempt += 1
                    self._sleep(min(self.retry_wait if e.retry_after is None else e.retry_after, 30.0))
                    continue
                raise JudgeUnavailable("Jev answered HTTP %s" % e.status, reason="jev-unavailable") from None
            except http.NetError as e:
                raise JudgeUnavailable("Jev is not reachable: %s" % e, reason="jev-unavailable") from None
        ms = (time.monotonic() - t0) * 1000.0
        answers = d.get("answers") if isinstance(d, dict) else None
        usage = (d.get("usage") if isinstance(d, dict) else None) or {}
        if not isinstance(answers, dict):
            raise JudgeError("Jev answered without `answers`", reason="bad-response")
        tin, tout = int(usage.get("input_tokens") or 0), int(usage.get("output_tokens") or 0)
        if tin == 0:                          # a reply that names no usage is still charged: estimate
            tin = int(0.4 * chars + 300)
        usd = self.budget.add(tin, tout)
        self.calls += 1
        self.ms_total += ms
        return answers, {"tokensIn": tin, "tokensOut": tout, "usd": usd}, ms

    @staticmethod
    def _noul(answers, qid):
        a = answers.get(qid)
        if not isinstance(a, dict) or "noul" not in a:
            raise JudgeError("Jev's answer has no noul for %r" % qid, reason="bad-response")
        return clamp01(a["noul"])

    # -- states and questions

    def _state(self, page, focus=()):
        pairs = judge.views(page, max_paras=self.max_paras, max_chars=self.max_chars,
                            max_total=self.max_total, focus=focus)
        return {"page_title": judge.page_title(page), "paragraphs": {str(i): t for i, t in pairs}}, pairs

    def _choice(self, pairs):
        P = prompts()["jev"]
        crit = {str(i): fill(P["paragraph_option"], n=i) for i, _ in pairs[:MAX_OPTIONS - 1]}
        crit["none"] = P["none_option"]
        return {"type": "choice", "instructions": P["intro_para"], "criteria": crit}

    def _rule_questions(self, template_key, P_phrase=None):
        tpl = prompts()["jev"][template_key]
        return {qid: {"type": "noul",
                      "instructions": fill(text, P=P_phrase) if P_phrase else text}
                for qid, text in tpl.items()}

    def _rules_from(self, answers):
        return {"defines": self._noul(answers, "defines_up_front"),
                "hook": self._noul(answers, "concrete_hook"),
                "selfContained": self._noul(answers, "self_contained"),
                "noHowTo": 1.0 - self._noul(answers, "howto_opening")}

    # -- the interface

    def locate(self, page):
        state, pairs = self._state(page)
        if not pairs:
            return {"para": None, "probs": {}, "confidence": 1.0, "rules": None, "ms": 0.0, "tokens": 0,
                    "judge": self.name, "mode": self.mode, "calls": 0, "of": 0, "costUsd": 0.0}
        questions = {"intro_para": self._choice(pairs)}
        if self.mode == "onepass":
            questions.update(self._rule_questions("rules_onepass"))
        answers, u, ms = self._call(state, questions)
        a = answers.get("intro_para")
        if not isinstance(a, dict) or "choice" not in a:
            raise JudgeError("Jev's answer has no choice for intro_para", reason="bad-response")
        choice = str(a["choice"])
        probs = {str(k): clamp01(v) for k, v in (a.get("probabilities") or {}).items()}
        valid = {str(i) for i, _ in pairs}
        para = int(choice) if choice in valid else None
        conf = probs.get(choice, clamp01(a.get("confidence", 0)))
        tokens, usd, calls, rules = u["tokensIn"] + u["tokensOut"], u["usd"], 1, None
        if para is not None:
            if self.mode == "onepass":
                rules = self._rules_from(answers)
            else:
                r2 = self._rules_call(page, [para])
                rules = {k: r2[k] for k in ("defines", "hook", "selfContained", "noHowTo")}
                tokens, usd, calls, ms = tokens + r2["tokens"], usd + r2["costUsd"], 2, ms + r2["ms"]
        return {"para": para, "probs": probs, "confidence": conf, "rules": rules, "ms": ms,
                "tokens": tokens, "tokensIn": u["tokensIn"], "judge": self.name, "mode": self.mode,
                "calls": calls, "of": len(pairs), "costUsd": usd,
                "modelConfidence": clamp01(a.get("confidence", 0))}

    def _rules_call(self, page, idx):
        state, _ = self._state(page, focus=idx)
        answers, u, ms = self._call(state, self._rule_questions("rules_twopass", judge.para_phrase(idx)))
        out = self._rules_from(answers)
        out.update({"ms": ms, "tokens": u["tokensIn"] + u["tokensOut"], "tokensIn": u["tokensIn"],
                    "costUsd": u["usd"]})
        return out

    def rules(self, page, paras_idx):
        return self._rules_call(page, [int(i) for i in paras_idx])

    def grounded(self, source_text, summary):
        answers, _, _ = self._call(
            {"source_text": source_text, "summary": summary},
            {"grounded": {"type": "noul", "instructions": prompts()["jev"]["grounded"]}})
        return self._noul(answers, "grounded")

    def graphic(self, caption, description):
        answers, _, _ = self._call(
            {"image": {"caption": caption, "description": description}},
            {"graphic": {"type": "noul", "instructions": prompts()["jev"]["graphic"]}})
        return self._noul(answers, "graphic")

    @staticmethod
    def _level_score(answer, levels):
        """A score answer as 0..1 (`score` is the expected level, 0..levels-1), or None when it cannot be read."""
        if not isinstance(answer, dict):
            return None
        try:
            return max(0.0, min(1.0, float(answer["score"]) / max(1, levels - 1)))
        except (KeyError, TypeError, ValueError):
            return None

    def interest(self, title, lead, recent_titles):
        P = prompts()["jev"]
        answers, _, _ = self._call(
            {"candidate": {"title": title, "lead": judge.clip(lead or "", INTEREST_LEAD_CHARS)},
             "recently_opened_titles": list(recent_titles or ())},
            {"interest": {"type": "score", "instructions": P["interest"], "criteria": P["interest_levels"]}})
        v = self._level_score(answers.get("interest"), len(P["interest_levels"]))
        if v is None:
            raise JudgeError("Jev's answer has no score for interest", reason="bad-response")
        return v

    def interest_many(self, candidates, recent_titles):
        """[score 0..1 | None] for (title, lead) pairs: ONE request per MAX_INTEREST candidates, one `score` question
        each (`interest_<n>`, n from 1). None where Jev's answer for a candidate cannot be read; JudgeError when none
        of them can."""
        pairs = list(candidates)
        out = []
        for a in range(0, len(pairs), MAX_INTEREST):
            out.extend(self._interest_chunk(pairs[a:a + MAX_INTEREST], list(recent_titles or ())))
        return out

    def _interest_chunk(self, pairs, recent):
        P = prompts()["jev"]
        levels = len(P["interest_levels"])
        state = {"recently_opened_titles": recent,
                 "candidates": [{"n": n, "title": t, "lead": judge.clip(lead or "", INTEREST_LEAD_CHARS)}
                                for n, (t, lead) in enumerate(pairs, 1)]}
        questions = {"interest_%d" % n: {"type": "score", "instructions": fill(P["interest_candidate"], n=n),
                                         "criteria": P["interest_levels"]} for n in range(1, len(pairs) + 1)}
        answers, _, _ = self._call(state, questions)
        got = [self._level_score(answers.get("interest_%d" % n), levels) for n in range(1, len(pairs) + 1)]
        if pairs and all(v is None for v in got):
            raise JudgeError("Jev's answer has no score for any interest question", reason="bad-response")
        return got

    def usage(self):
        b = self.budget
        return {"calls": self.calls, "tokensIn": b.tokens_in, "tokensOut": b.tokens_out,
                "usd": b.spent, "msTotal": self.ms_total}

    def estimate_locate(self, page):
        """(tokens, usd) a locate() of this page costs, about: jev_api.md measured 0.33 input tokens per
        character of state, 12 per choice option, 20 per noul and a 300-token framing per request. The
        twopass shape pays the page state twice."""
        state, pairs = self._state(page)
        state_toks = 0.33 * len(json.dumps(state, ensure_ascii=False))
        one = state_toks + 12 * (len(pairs) + 1) + 300
        toks = int(one + 4 * 20) if self.mode == "onepass" else int(one + (state_toks + 4 * 60 + 300))
        return toks, toks * judge.JEV_USD_PER_INPUT_TOKEN
