# Jev via Defapi — the API as it really is

(The gates, probes and fixtures this contract names without a directory went with the cleanup: tag `pre-cleanup` has them. What a change is proved with now is in `tools/dev/`, [tools.md](../tools.md).)

Measured 2026-09-30 with `tools/wiki/jev_probe.py`: 12 live requests (1 x 404, 1 x 400, 10 x 200),
8 603 input + 925 output tokens, **$0.00072** spent. Fixtures with every shape:
`fixtures/wiki/jev/` (its README says how each was obtained). The key is `jevKey` in
`~/.config/quickshell/config/wiki.jsonc` (`dk-` + 32 characters).

## 1. The call

```
POST https://api.defapi.org/api/v1/decisions
Authorization: Bearer <JEV_API_KEY>
Content-Type: application/json
Accept: application/json
```

Model: `"typesafe/jev-1.13"` (developer/model). The reply's `model` is the dated snapshot
`typesafe/jev-1.13-20260917`. Nothing else is needed: the wiki's `User-Agent`
(`quickshell-wiki/0.1 (https://github.com/JacobRoelandt04/Lares)`) was accepted; redirects were never seen.

**Doc/reality mismatch, the first one:** Defapi's model page and TypeSafe's docs say
`POST /v1/systemone`. On `api.defapi.org` that path is a 404
(`{"message":"Route POST:/v1/systemone not found","error":"Not Found","statusCode":404}`, a
Fastify-style body, `error_404_wrong_path.json`). The model page has no code sample in its HTML;
it loads one in the browser from `https://defapi.org/api/sample-codes/15?developerCode=typesafe&modelCode=jev-1.13`
(an OpenAPI document, kept as `defapi_decisions_openapi.yaml`), and that names `/api/v1/decisions`.
The `x-api-key` header style was not tried; Bearer works and is what the spec declares.

## 2. Request

```json
{ "model": "typesafe/jev-1.13",
  "state": "<string> | { any JSON object } | [ any JSON array ]",
  "questions": { "<id>": { "type": "noul|choice|score", "instructions": "<string>", "criteria": … } } }
```

`<id>` is echoed back and never seen by the model. Optional top-level `provider`, `session_id`,
`user` exist in the spec and were not used.

| type | `instructions` | `criteria` | limit |
|---|---|---|---|
| `noul` | required string: the statement whose truth is asked | optional `{ "true": "…", "false": "…" }` (worked; a bare question also worked) | none seen |
| `choice` | required string | **required** map `{ "<option>": "<description>" }`; the option names are the answer keys | up to 255 options |
| `score` | required string | **required** ordered array of level descriptions | 2–10 levels; 11 gives a 400 |

Notes that come from running it, not from the docs:

- **`instructions` is required for all three types** (Defapi spec: `required: [type, instructions]`),
  and its type is a string there; TypeSafe's own docs also allow an object or array, not tried.
- The **state as a JSON object worked** (`{"paragraphs": {"0": "…"}, "recently_opened_titles": [...]}`),
  and the model reads keys as names: a question can say "Paragraph 3" or "image_b" and be understood.
- Choice option names and descriptions are both visible to the model (spec). Descriptions
  are required by the spec even when trivial (`"3": "paragraph 3"`); `null` values were not tried.
- Score levels are **0-indexed** by position in `criteria`.

## 3. Response

```json
{ "model": "typesafe/jev-1.13-20260917",
  "answers": {
    "intro_para": { "type": "choice", "choice": "1",
                    "probabilities": { "0": 0, "1": 0.99, "2": 0, "none": 0.01 }, "confidence": 0.99 },
    "has_hook":   { "type": "noul", "noul": 0.96 },
    "interest":   { "type": "score", "score": 1.03,
                    "legend": { "0": "Certainly not", "1": "Unlikely", … },
                    "probabilities": { "0": 0.04, "1": 0.9, "2": 0.06, "3": 0, "4": 0 },
                    "confidence": 0.91 } },
  "usage": { "input_tokens": 545, "output_tokens": 77, "cost": 4.578e-05 },
  "id": "gen-dec-…", "provider": "TypeSafe", "task_id": "ta…", "consumed": "0.00004578" }
```

| Wanted | JSON path | Notes |
|---|---|---|
| yes/no probability | `answers.<id>.noul` | 0..1, two decimals; no `confidence` on a noul |
| picked option | `answers.<id>.choice` | the criteria key exactly as sent (a string) |
| option probabilities | `answers.<id>.probabilities.<option>` | every option is present, sums to about 1 |
| choice/score confidence | `answers.<id>.confidence` | 0..1; not the same number as the winner's probability (0.67 vs 0.64 seen) |
| score | `answers.<id>.score` | expected level, 0..(levels-1), two decimals. Normalise as `score / (levels - 1)` |
| score distribution | `answers.<id>.probabilities["0".."n-1"]` | an **object** keyed by level index (a TypeSafe blog shows an array; Defapi returns an object) |
| level words | `answers.<id>.legend` | index -> the description sent |
| tokens | `usage.input_tokens`, `usage.output_tokens` | |
| dollars | `consumed` (string) and `usage.cost` (number) | the same number |

The order of keys inside `answers` follows the request. Probabilities are rounded to two
decimals, so a "certain" answer is `1` and ties are possible.

## 4. Usage and cost

`consumed = input_tokens x $0.084 / 1 000 000`; **output tokens are free** (checked on all 10 successful requests,
e.g. 3 101 in -> `0.000260484`). Defapi's own spec example uses a 0.042 rate; that is the vendor's
price, not what this account is billed.

| Request | questions | input | output | ms |
|---|---|---|---|---|
| 1 noul, 100-token state | 1 | 394 | 21 | 1152 |
| the same + 1 noul | 2 | 415 | 37 | 832 |
| choice(4) + noul + score(5) | 3 | 545 | 77 | 1400 |
| 4 noul on one paragraph alone | 4 | 402 | 78 | 938 |
| 4 noul, whole page as context | 4 | 685 | 78 | 759 |
| grounding + 2 image noul | 3 | 550 | 63 | 1102 |
| grounding alone | 1 | 490 | 23 | 1198 |
| choice(6) + 4 noul + score(5), 230-word object state | 6 | 889 | 148 | 1173 |
| choice(10), 9 paragraphs, 2.7 KB | 1 | 1132 | 88 | 1129 |
| choice(38), 37 paragraphs, 8 KB | 1 | 3101 | 312 | 752 |

Reading the table:

- A fixed overhead of about **250–300 input tokens per request** (the model's own framing) sits
  under everything. A short noul adds about 20 input tokens, a choice about 12 per option. The
  state is **not** repeated per question: three questions cost 150 tokens more than one.
- **Group the questions of one state into one request.** A separate call per question pays the
  overhead again.
- The state costs about 0.3–0.4 tokens per character of prose (code-heavy text is worse).
- A locator over a normal page (1 500 tokens) is about $0.00013; rules + grounding + two image
  filters about $0.00015; so an entry is roughly **$0.0003**, and $0.20 buys on the order of
  600 entries (20 batches of 30). Even the 3 100-token page cost a fortieth of a cent.
- The wiki tool should keep a running total from `usage` (the `jev` counter in `state.json`) and
  stop at a per-batch cap, as PLAN says; the balance itself cannot be read (no endpoint known).

## 5. Latency

Ten 2xx requests, a new TLS connection each, from the laptop:
752 / 759 / 832 / 938 / 1102 / 1129 / 1152 / 1173 / 1198 / 1400 ms; **median 1.1 s, mean 1.04 s**.
It does not track the size of the request (752 ms at 3 100 tokens, 1 400 ms at 545): the time is
the gateway hop, not the model (TypeSafe claims 70–500 ms end to end; Defapi resells it through
OpenRouter per its spec text). The 404 took 634 ms and the 400 712 ms. Plan a batch on about
1.2 s per Jev call, sequential; parallel calls were not tried.

## 6. Errors

| Seen | Status | Body |
|---|---|---|
| wrong route | 404 | `{"message":"Route POST:/v1/systemone not found","error":"Not Found","statusCode":404}` |
| 11 score levels | 400 | `{"code":400,"message":"HTTP 400: {\"detail\":\"Too many score levels. Must have at most 10 levels.\"}"}` |

The 400 wraps the upstream JSON as a string inside `message` (the spec says `"code": 1` for
Defapi's errors; the real one is `400`). Documented in the spec but **not seen** (the probe
never sends a bad key):

| Status | Body |
|---|---|
| 400 | `{"code":1,"message":"model is required"}` / `"model not found"` |
| 401 | `{"code":1,"message":"No API key provided"}` / `"Invalid API key"` |
| 500 | `{"code":1,"message":"Internal server error","detail":"Failed to forward request to upstream API"}` |

TypeSafe's own list adds 422 (validation), 429 (rate limit, with `retry-after`) and 529
(overloaded); through Defapi those probably arrive wrapped like the 400. What an empty balance
looks like is unknown. The tool's rule can stay simple: any non-2xx or network error is
`jev-unavailable` after one retry on 5xx/429, and the run continues on the local model. A 400
is a bug in our request and is logged with its `message` (the key is never in a message).

Limits known: 255 options per choice, 2–10 score levels, context 64 000 tokens for state plus all
questions (TypeSafe also states 32 000 for state plus the longest single question). TypeSafe's
published rate limits (250 000 tokens/s, 1 200 requests/min) are its own; Defapi's are not
published and no rate-limit header was seen. The largest request sent was 3 101 tokens and 38
options.

## 7. How the wiki uses it

The state is where the page lives, the questions are what we ask about it. One request per
purpose, all questions about that state together.

**Locator (choice).** State: `{"page_title": …, "paragraphs": {"0": …, "1": …}}` (or one string
with `[n]` prefixes; both worked). Question `intro_para`: choice, criteria = one key per paragraph
index plus `"none"`, each described just as `"paragraph n"` (the text is in the state, so a longer
description only costs tokens). Instructions: which paragraph is the best introduction to the
topic for a newcomer, saying what the subject is and why it matters, and is not a hatnote, an
instruction or a link list. Result: `answers.intro_para.choice` (accept unless `"none"`, and read
`probabilities[choice]` as the confidence: 1.0 on a clean page, 0.67 with a look-alike neighbour).
Measured: the true intro was found in a 5-paragraph page (1.0), a 9-paragraph page (0.67, a look-alike filler paragraph took 0.32) and a
37-paragraph page (1.0). Wikipedia needs no locator (its lead is the intro).

**Rules (noul x4).** `defines_up_front`, `concrete_hook`, `self_contained` and
`howto_opening` (this one is inverted: true is bad). Send them in the same request as the page
state, worded "Paragraph n …", so the model has the title and the neighbours. Measured:

| Paragraph | defines | hook | self-contained | how-to opening |
|---|---|---|---|---|
| a real intro (in page) | 0.95 | 0.81 | 0.91 | – |
| an instruction line (in page) | – | – | – | 0.96 |
| a config detail (in page) | 0.48 | 0.46 | 0.53 | 0.54 |
| the same config detail, alone, no title | 0.73 | 0.60 | 0.83 | 0.57 |

So a "no" comes back near 0.5, not near 0: the model is confident about yes and merely unsure
about no. A pass threshold near 0.7 separates these cases; the locator's own choice is the
stronger signal. Stage 1 must set the thresholds on the labelled corpus. Do not judge a paragraph
without the page: the isolated one scored higher on all four rules.

**Grounding (noul).** State `{"source_lead": …, "summary": …}`, question "Every factual claim in
summary is supported by source_lead". A summary that invents a claim ("roll a whole system back
in under a second") scored **0.08**; the faithful one **0.97**. The cleanest signal seen.

**Graphic image filter (noul).** State `{"image_a": {"caption": …, "description": …}, "image_b": …}`,
one noul per image ("image_b shows graphic or disturbing content such as corpses, gore or explicit
violence"). A screenshot scored **0.01**, a bombing photograph caption **0.97**; several images in
one request cost about 30 tokens each. Reject at 0.5 or more.

**Interest (score).** State carries `recently_opened_titles` beside the candidate; the question
asks how likely a reader who recently opened them is to open this article, 5 levels
("Certainly not" … "Certainly"). Use `score / 4` as a preference weight for ranking candidates
inside a family, never as a filter: it answered 1.0 ("Unlikely", 0.76) for an unrelated Snapper
page after Bayeux Tapestry / Pacman / Kelvin-Helmholtz, and 1.03 for a file-synchroniser stub with
no recent titles at all. Whether it tracks what the user actually opens is a Stage 1 / Stage 5
question; the Thompson sampler stays the primary steer.

Cost per entry when the locator and the rest are two requests (locator, then rules + grounding +
images + interest for the chosen paragraph and its images): about two calls, 2.4 s, $0.0003.
Sequential over a batch of 30: about 75 s of Jev time.

## 8. Remaining uncertainty

- The balance is unreadable and it is unknown whether the 400 was billed (the requests before it
  cost $0.00072 by `consumed`; a balance check in the dashboard would settle it).
- Defapi's rate limits, concurrency behaviour and the empty-balance error are unknown.
- `jev-latest` (TypeSafe's alias) was not tried on Defapi; `typesafe/jev-1.13` is pinned and worked.
  The reply's dated snapshot suffix may change when TypeSafe ships a fix, and thresholds should be
  re-checked then.
- Object/array `instructions`, `null` choice descriptions and states beyond 3 100 tokens
  are untested.
- Noul calibration is only sampled (five paragraphs, two images, two summaries); the thresholds
  above are hypotheses for Stage 1's corpus, not results.
