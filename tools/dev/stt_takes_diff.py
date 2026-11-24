#!/usr/bin/env python3
"""stt_takes_diff.py -- what the dictation wrote (the take log) against what the user kept (feedback/*.md at a commit).

The user dictates feedback, then corrects it by hand ("usually punctuation or a word here or there"); some corrections are the model's
errors, some his own rewording. This lines every logged take up with the text he committed and names each difference.

  tools/dev/stt_takes_diff.py <commit>                the table and the summary
  tools/dev/stt_takes_diff.py <commit> --json         the same as JSON
  tools/dev/stt_takes_diff.py <commit> --rules        and the takes again through today's text rules (sttlib/textrules.py): which
                                                      differences they fix, which remain, which they make
  options: --log <takes.jsonl> (default ~/.local/state/lares/dictation/takes.jsonl, read only), --whole (align against the
           whole files, not only the lines <commit> added), --tidy (the re-run also runs the tidy pass on the CPU: loads Gemma)

HOW. The text is the lines <commit> added to feedback/*.md (where the dictated words landed; --whole: every line). Each take's
pieces (its written sentences, in order) are anchored by word trigrams (bigrams for a short take), then aligned word by word against
that stretch of text (a weighted edit distance whose free ends let the text run on either side; one word may stand for two -- "stop
word" / "stopword", "cross compare" / "cross-compare" -- and up to three spoken words for one written symbol -- "F ten" / "F10",
"greater than" / ">", judged by the text rules themselves). A take whose stretch another take matches better was redone (takes 11 /
12: the first is "superseded") and is left out of the counts, as is a take with under half its words found (another conversation's).

THE CLASSES (one row per difference):
  punctuation   the same word with other punctuation, or joined / split ("stop word" / "stopword")
  casing        the same word in other case
  filler        a filler the policy removed (from `heard`; correct unless the written text has it)
  symbol        spoken words the user wrote as a symbol or a key name (F10, >)
  model         a word or words replaced by something that SOUNDS alike: the recogniser misheard ("Hyperland" / "Hyprland")
  reword        replaced by something that does not: the user's own rewording (his rule)
  insertion     words the user added inside the take's stretch
  deletion      words of the take the user removed
  split         a piece boundary (a pause ended the sentence) inside one written sentence; "visible" when it left a full stop or a
                capital the user had to undo
  repeat        two copies said in a row: across a filler (what the repeats rule removes), or with nothing between (kept: intended)
  script        a word in another script (Cyrillic for English speech)
  foreign       a Dutch word in an English take ("ik")
SOUNDS ALIKE: the two sides' phonetic keys (a reduced Metaphone below: the first letter, then consonants only, voiced and voiceless
pairs merged -- b/p, d/t/th, g/k/c/q/j, v/f, z/s, m/n -- digraphs sh/ch/ph/ck folded, doubled letters collapsed, digits spelled) or their
letters agree to at least 3/4 (difflib's ratio), or the letters differ by one in a word of three or more ("dui" / "gui"). It is a
judgement, so the table prints both sides and the closeness: read the rows, not only the counts.
"""
import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "stt"))
from sttlib import fillers, textrules  # noqa: E402  (pure Python: no numpy)
from sttlib.fillers import core  # noqa: E402

LOG = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "lares" / "dictation" / "takes.jsonl"
DUTCH_ONLY = {"ik", "het", "een", "niet", "maar", "ook", "jij", "wij", "dit", "naar", "hebben", "heb", "wil", "zijn", "graag", "dus"}
NUM = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
       "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
CLOSE = 0.75
RULES = textrules.TextRules()


# ---- sounds alike -------------------------------------------------------------------------------------------------------------
def spell(n):
    n = int(n)
    if n < 20:
        return NUM[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else NUM[n % 10])
    return "".join(NUM[int(d)] for d in str(n))


def phon(word):
    """A reduced Metaphone key (module docstring)."""
    w = re.sub(r"\d+", lambda m: spell(m.group(0)) if len(m.group(0)) < 3 else "".join(NUM[int(d)] for d in m.group(0)),
               word.lower())
    w = re.sub(r"[^a-z]", "", w)
    if not w:
        return ""
    for a, b in (("^kn", "n"), ("^gn", "n"), ("^pn", "n"), ("^wr", "r"), ("^wh", "w"), ("^x", "s")):
        w = re.sub(a, b, w)
    for a, b in (("ph", "f"), ("th", "t"), ("sh", "x"), ("ch", "x"), ("ck", "k"), ("qu", "kw"), ("x", "ks")):
        w = w.replace(a, b)
    w = re.sub(r"(?<=.)gh(?![aeiou])", "", w)
    w = re.sub(r"c(?=[eiy])", "s", w)
    w = w.translate(str.maketrans("cqzvbdgmj", "kksfptknk"))
    head = "A" if w[0] in "aeiouy" else w[0]
    key = head + re.sub(r"[aeiouyhw]", "", w[1:])
    return re.sub(r"(.)\1+", r"\1", key)


def closeness(a_words, b_words):
    pa = "".join(phon(w) for w in a_words)
    pb = "".join(phon(w) for w in b_words)
    la = "".join(core(w) for w in a_words)
    lb = "".join(core(w) for w in b_words)
    r1 = difflib.SequenceMatcher(None, pa, pb).ratio() if pa and pb else 0.0
    r2 = difflib.SequenceMatcher(None, la, lb).ratio() if la and lb else 0.0
    if len(la) == len(lb) >= 3 and sum(x != y for x, y in zip(la, lb)) == 1:
        r2 = max(r2, CLOSE)               # one letter apart: "dui" / "gui"
    return max(r1, r2)


def latin(tok):
    return all(not ch.isalpha() or "LATIN" in unicodedata.name(ch, "") for ch in tok)


# ---- the text -------------------------------------------------------------------------------------------------------------------
def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout


def text_tokens(commit, whole):
    """[(token, file, line)] of the feedback text: the lines `commit` added (or every line). A markdown header's #s are dropped;
    a quote's ">" stays (the user writes it, and says it)."""
    lines = []
    if whole:
        for f in git("ls-tree", "--name-only", commit, "feedback/").split():
            if f.endswith(".md"):
                lines += [(f, i + 1, ln) for i, ln in enumerate(git("show", "%s:%s" % (commit, f)).splitlines())]
    else:
        f, n = None, 0
        for ln in git("show", "--format=", "--unified=0", commit, "--", "feedback/").splitlines():
            if ln.startswith("+++ "):
                f = ln[6:] if ln.startswith("+++ b/") else None
            elif ln.startswith("@@"):
                n = int(re.search(r"\+(\d+)", ln).group(1))
            elif ln.startswith("+") and f and f.endswith(".md"):
                lines.append((f, n, ln[1:]))
                n += 1
    out = []
    for f, n, ln in lines:
        toks = ln.split()
        while toks and re.fullmatch(r"#+", toks[0]):
            toks = toks[1:]
        out += [(t, f, n) for t in toks]
    return out


# ---- alignment ------------------------------------------------------------------------------------------------------------------
def joined(ws):
    return "".join(core(w).replace("-", "") for w in ws)


def as_symbol(spoken, written):
    """Up to three spoken words the text rules write as the one written token (F10, >)."""
    out, _ = RULES.apply(" ".join(spoken), "en", first=True, prev=None)
    return [t.rstrip(".,;:!?").lower() for t in out.split()] == [written.rstrip(".,;:!?").lower()]


def align(T, W, lines):
    """Ops [(kind, [take idx], [text idx])] aligning take tokens T with text tokens W (on `lines`); the text's ends are free."""
    n, m = len(T), len(W)
    tc, wc = [core(t) for t in T], [core(w) for w in W]
    INF = float("inf")
    D = [[INF] * (m + 1) for _ in range(n + 1)]
    B = [[None] * (m + 1) for _ in range(n + 1)]
    for j in range(m + 1):
        D[0][j] = 0.0                                 # the text may begin anywhere
    sim_cache = {}

    def sub(i, j):
        if T[i] == W[j] or (tc[i] and tc[i] == wc[j]):
            return 0.0, "="                         # ">" is ">" though it has no letters
        k = (tc[i], wc[j])
        if k not in sim_cache:
            sim_cache[k] = closeness([T[i]], [W[j]])
        return 0.4 + 1.6 * (1 - sim_cache[k]), "s"

    for i in range(n + 1):
        for j in range(m + 1):
            d = D[i][j]
            if d == INF:
                continue
            if i < n and j < m:
                c, kind = sub(i, j)
                if d + c < D[i + 1][j + 1]:
                    D[i + 1][j + 1], B[i + 1][j + 1] = d + c, (i, j, kind)
            if i < n and d + 1 < D[i + 1][j]:
                D[i + 1][j], B[i + 1][j] = d + 1, (i, j, "d")
            if j < m:
                c = 0.0 if i in (0, n) else 1.0      # text before the take's first word or after its last is not inserted
                if d + c < D[i][j + 1]:
                    D[i][j + 1], B[i][j + 1] = d + c, (i, j, "i")
            if i + 2 <= n and j < m and joined(T[i: i + 2]) == joined(W[j: j + 1]) and wc[j]:
                if d + 0.1 < D[i + 2][j + 1]:
                    D[i + 2][j + 1], B[i + 2][j + 1] = d + 0.1, (i, j, "join")
            if i < n and j + 2 <= m and joined(T[i: i + 1]) == joined(W[j: j + 2]) and tc[i]:
                if d + 0.1 < D[i + 1][j + 2]:
                    D[i + 1][j + 2], B[i + 1][j + 2] = d + 0.1, (i, j, "join")
            if j < m and not wc[j] or (j < m and re.fullmatch(r"F\d{1,2}", W[j])):
                for k in (1, 2, 3):
                    if i + k <= n and as_symbol(T[i: i + k], W[j]) and d + 0.1 < D[i + k][j + 1]:
                        D[i + k][j + 1], B[i + k][j + 1] = d + 0.1, (i, j, "sym")
    j = min(range(m + 1), key=lambda jj: D[n][jj])
    i, ops = n, []
    while i > 0:
        pi, pj, kind = B[i][j]
        ops.append((kind, list(range(pi, i)), list(range(pj, j))))
        i, j = pi, pj
    ops.reverse()
    while ops and ops[0][0] == "i":
        ops.pop(0)
    while ops and ops[-1][0] == "i":
        ops.pop()                                     # text after the take's last word is not the user's insertion
    return _edges(ops, W, lines)


def _edges(ops, W, lines):
    """The take's first (last) words deleted while the text right before (after) them, in the same sentence and line, matched
    nothing: the free end took a substitution ("No, now that" / "But now that"). Pair them as one."""
    def pair(dels, js):
        return [("s", ti, [j]) for (_, ti, _), j in zip(dels, js)]

    k = 0
    while k < len(ops) and ops[k][0] == "d":
        k += 1
    if 0 < k < len(ops) and ops[k][2]:
        w0, js = ops[k][2][0], []
        for j in range(w0 - 1, max(-1, w0 - 1 - k), -1):
            if lines[j] != lines[w0] or re.search(r"[.?!:]$", W[j]):
                break
            js.insert(0, j)
        if js:
            ops = ops[:k - len(js)] + pair(ops[k - len(js): k], js) + ops[k:]
    k = 0
    while k < len(ops) and ops[len(ops) - 1 - k][0] == "d":
        k += 1
    if 0 < k < len(ops) and ops[len(ops) - 1 - k][2]:
        wl, js = ops[len(ops) - 1 - k][2][-1], []
        for j in range(wl + 1, min(len(W), wl + 1 + k)):
            if lines[j] != lines[wl] or re.search(r"[.?!:]$", W[j - 1]):
                break
            js.append(j)
        if js:
            n = len(ops) - k
            ops = ops[:n] + pair(ops[n: n + len(js)], js) + ops[n + len(js):]
    return ops


def anchor(tc, index, ntext, n=1):
    """Up to n text indices where the take's words may begin, by word n-gram votes, best first ([]: not found)."""
    for k in (3, 2, 1):
        if len(tc) < k:
            continue
        votes = Counter()
        grams = 0
        for p in range(len(tc) - k + 1):
            g = tuple(tc[p: p + k])
            if not all(g):
                continue
            grams += 1
            for c in index[k].get(g, ()):
                votes[c - p] += 1
        if not votes:
            continue
        def window(o):
            return sum(votes[o + d] for d in range(-12, 13))

        short = len(tc) <= 5              # "Greater Than After Review": a bigram is all a short take has
        need = max(2 if k > 1 and not short else 1, 0.2 * grams)
        if k == 1 and len(tc) > 3:
            continue
        out = []
        for o in sorted(votes, key=lambda o: (-window(o), o)):
            if window(o) < need or len(out) >= n:
                break
            if all(abs(o - p) > 12 for p, _ in out):
                out.append((max(0, min(o, ntext - 1)), window(o) / max(1, grams)))
        if out:
            return out
    return []


def build_index(text):
    cs = [core(t) for t, _, _ in text]
    idx = {k: defaultdict(list) for k in (1, 2, 3)}
    for k in (1, 2, 3):
        for c in range(len(cs) - k + 1):
            idx[k][tuple(cs[c: c + k])].append(c)
    return idx


# ---- one take ---------------------------------------------------------------------------------------------------------------------
def tokens_of(pieces):
    T, piece = [], []
    for k, p in enumerate(pieces):
        for t in p.split():
            T.append(t)
            piece.append(k)
    return T, piece


def place(T, text, index):
    """The best of the anchor's candidate places (a short take tries several: "Greater Than After Review" finds its bigrams
    in other sentences too, and only the alignment sees "greater than" -> ">")."""
    tc = [core(t) for t in T]
    best = None
    for a, score in anchor(tc, index, len(text), 8 if len(T) <= 12 else 2):
        lo, hi = max(0, a - 15), min(len(text), a + len(T) + 40)
        W = [t for t, _, _ in text[lo:hi]]
        ops = align(T, W, [(f, n) for _, f, n in text[lo:hi]])
        good = sum(len(ti) for k, ti, _ in ops if k in ("=", "join", "sym"))
        exact = sum(len(ti) for k, ti, _ in ops if k == "=")
        if best is None or (good, exact) > best[0]:
            best = ((good, exact), {"lo": lo, "ops": [(k, ti, [lo + j for j in wi]) for k, ti, wi in ops],
                                    "score": round(score, 2)})
    return best[1] if best else None


def classify(take, T, piece, pl, text, lang):
    """The difference rows of one placed take."""
    rows = []
    ops = pl["ops"]
    hunk = []

    def flush():
        if not hunk:
            return
        ti = [i for _, a, _ in hunk for i in a]
        wi = [j for _, _, b in hunk for j in b]
        tw, ww = [T[i] for i in ti], [text[j][0] for j in wi]
        if ti and wi:
            close = closeness(tw, ww)
            odd = any(not latin(w) for w in tw) or (lang == "en" and any(core(w) in DUTCH_ONLY for w in tw))
            cls = "model" if close >= CLOSE or odd else "reword"   # another script or language: misheard, whatever it is
        else:
            close, cls = None, "deletion" if ti else "insertion"
        rows.append(row(cls, ti, wi, tw, ww, close))
        hunk.clear()

    def row(cls, ti, wi, tw, ww, close=None):
        r = {"take": take, "class": cls, "said": " ".join(tw), "written": " ".join(ww),
             "where": "%s:%d" % (text[wi[0]][1], text[wi[0]][2]) if wi else "", "piece": piece[ti[0]] if ti else None}
        if wi:
            # mid-sentence: the written word before it does not end a sentence (a capital there is the recogniser's, left standing)
            r["mid"] = wi[0] > 0 and text[wi[0] - 1][1:] == text[wi[0]][1:] and not re.search(r"[.?!:]$", text[wi[0] - 1][0])
        if close is not None:
            r["close"] = round(close, 2)
        return r

    for kind, ti, wi in ops:
        if kind in ("s", "d", "i"):
            hunk.append((kind, ti, wi))
            continue
        flush()
        tw, ww = [T[i] for i in ti], [text[j][0] for j in wi]
        if kind == "join":
            rows.append(row("punctuation", ti, wi, tw, ww))
        elif kind == "sym":
            rows.append(row("symbol", ti, wi, tw, ww))
        else:
            t, w = tw[0], ww[0]
            ta, tword, tb = textrules._parts(t)
            wa, wword, wb = textrules._parts(w)
            if (ta, tb) != (wa, wb):
                rows.append(row("punctuation", ti, wi, tw, ww))
            if tword != wword and tword.lower() == wword.lower():
                rows.append(row("casing", ti, wi, tw, ww))
    flush()
    for r in rows:
        if r["class"] in ("model", "reword", "deletion"):
            if any(not latin(w) for w in r["said"].split()):
                r["also"] = "script"
            elif lang == "en" and any(core(w) in DUTCH_ONLY for w in r["said"].split()):
                r["also"] = "foreign"
    return rows


def boundaries(take, T, piece, pl, text, pieces, heard):
    """Every piece boundary: does the written text run the sentence across it (a split), and what the rules would say."""
    at = {}
    for kind, ti, wi in pl["ops"]:
        if wi:
            for i in ti:
                at[i] = (wi[0], wi[-1])
    out = []
    for b in range(1, len(T)):
        if piece[b] == piece[b - 1]:
            continue
        k = piece[b - 1]
        if b - 1 not in at or b not in at:
            continue
        w_end, w_next = at[b - 1][1], at[b][0]
        same_line = text[w_end][1:] == text[w_next][1:]
        ends = bool(re.search(r"[.?!:]$", text[w_end][0].rstrip("\"')")))
        split = same_line and not ends and w_next > w_end
        visible = split and (bool(re.search(r"[.?!]$", T[b - 1])) or (T[b][:1].isupper() and text[w_next][0][:1].islower()))
        h = heard[k] if k < len(heard) else pieces[k]
        out.append({"take": take, "piece": k, "split": split, "visible": visible,
                    "end": " ".join(T[max(0, b - 4): b]), "next": " ".join(T[b: b + 3]),
                    "written": " ".join(t for t, _, _ in text[max(0, w_end - 3): w_next + 3]),
                    "hold": RULES.hold(fillers.strip(h, "en"), "en"), "continue": RULES.continues(pieces[k], "en")})
    return out


def repeats(take, pieces, heard, lang):
    out = []
    for k, p in enumerate(pieces):
        ws = p.split()
        for i in range(1, len(ws)):
            for n in (3, 2, 1):
                if i - n >= 0 and i + n <= len(ws) and [core(w) for w in ws[i - n: i]] == [core(w) for w in ws[i: i + n]] \
                        and core(ws[i]):
                    out.append({"take": take, "piece": k, "kind": "no filler", "words": " ".join(ws[i - n: i + n])})
                    break
    for k, h in enumerate(heard):
        fixed, names = fillers.drop_repeats(h, lang)
        if names:
            out.append({"take": take, "piece": k, "kind": "across a filler", "words": h, "once": fillers.strip(fixed, lang)})
    return out


# ---- the takes through today's rules ---------------------------------------------------------------------------------------------
def rerun(pieces, heard, lang, held, tidier):
    """The take's written pieces as today's chain would write them from what was heard: every final through textrules.finish; with
    `held`, a pause the unfinished rule holds joins the next piece to it (the log has no pause lengths: this assumes it was under
    thinkSilenceMs; without, the next piece is only continued in lower case)."""
    raws = [(r, []) for r in (heard or pieces)]
    if held:
        merged = []
        for r, _ in raws:
            last = merged[-1][0] if merged else ""
            if merged and (fillers.ends_in_filler(last, lang) or RULES.hold(fillers.strip(last, lang), lang)):
                first = r.split()
                if first:
                    first[0] = RULES.continue_word(first[0])       # one sentence: the recogniser hears it go on
                merged[-1] = (last + " " + " ".join(first), merged[-1][1] + [last])
            else:
                merged.append((r, []))
        raws = merged
    out, prev = [], None
    for r, marks in raws:
        text, names, _ = textrules.finish(r, lang, RULES, first=prev is None, prev=prev, marks=marks, tidier=tidier)
        if text:
            out.append(text)
            prev = text
    return out


# ---- the run ---------------------------------------------------------------------------------------------------------------------
def diff_all(takes, text, index, pick_pieces):
    """Place and classify every take; a take another one matches better on the same stretch is superseded."""
    res = []
    for tk in takes:
        pieces = pick_pieces(tk)
        T, piece = tokens_of(pieces)
        pl = place(T, text, index) if T else None
        matched = sum(len(ti) for k, ti, _ in (pl["ops"] if pl else []) if k in ("=", "join", "sym")) if pl else 0
        ws = [j for _, _, wi in (pl["ops"] if pl else []) for j in wi]
        res.append({"tk": tk, "pieces": pieces, "T": T, "piece": piece, "pl": pl, "matched": matched,
                    "span": (min(ws), max(ws)) if ws else None})
    for r in res:
        r["status"] = "ok"
        if r["pl"] is None or r["matched"] < 0.5 * max(1, len(r["T"])):
            r["status"] = "not found"
    # two takes on one stretch: the one that matches fewer words was redone ("superseded"), or is a short take whose words are
    # the longer one's ("inside": the user said them again as a test)
    for r in res:
        for o in res:
            if o is r or r["status"] != "ok" or o["status"] == "not found":
                continue
            a = max(r["span"][0], o["span"][0])
            b = min(r["span"][1], o["span"][1])
            if b - a >= 0.5 * min(r["span"][1] - r["span"][0], o["span"][1] - o["span"][0]) and b >= a and (
                    (o["matched"], o["tk"]["take"]) > (r["matched"], r["tk"]["take"])):
                inside = o["span"][0] <= r["span"][0] and r["span"][1] <= o["span"][1]
                r["status"] = "%s take %s" % ("inside" if inside else "superseded by", o["tk"]["take"])
    return res


def summarise(res, text, lang_of):
    rows, splits, reps = [], [], []
    fill = 0
    script = []
    for r in res:
        tk = r["tk"]
        for p in r["pieces"]:
            script += [w for w in p.split() if not latin(w)]
        if r["status"] != "ok":
            continue
        heard = tk.get("heard") or []
        fill += sum(1 for h in heard for w in h.split() if fillers._is_filler(w, lang_of(tk)))
        rows += classify(tk["take"], r["T"], r["piece"], r["pl"], text, lang_of(tk))
        splits += boundaries(tk["take"], r["T"], r["piece"], r["pl"], text, r["pieces"], heard)
        reps += repeats(tk["take"], r["pieces"], heard, lang_of(tk))
    count = Counter(x["class"] for x in rows)
    count["filler"] = fill
    count["split"] = sum(1 for s in splits if s["split"])
    count["split (visible)"] = sum(1 for s in splits if s["visible"])
    count["repeat (no filler)"] = sum(1 for x in reps if x["kind"] == "no filler")
    count["repeat (across a filler)"] = sum(1 for x in reps if x["kind"] == "across a filler")
    count["script"] = len(script)
    count["foreign"] = sum(1 for x in rows if x.get("also") == "foreign")
    return {"rows": rows, "splits": splits, "repeats": reps, "count": dict(count), "script": script}


def read_takes(text):
    """(records, glued): every JSON record in the take log, in order, however the lines are broken -- a record written onto the
    last one with no newline between (`}{"at"`: the file was saved without its last newline) is read apart, and counted."""
    dec, out, glued, i, n, prev_end = json.JSONDecoder(), [], 0, 0, len(text), 0
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return out, glued
        if out and "\n" not in text[prev_end:i]:
            glued += 1
        rec, prev_end = dec.raw_decode(text, i)
        out.append(rec)
        i = prev_end


ORDER = ["punctuation", "casing", "filler", "symbol", "model", "reword", "insertion", "deletion", "split", "split (visible)",
         "repeat (no filler)", "repeat (across a filler)", "script", "foreign"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("commit")
    ap.add_argument("--log", default=str(LOG))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--whole", action="store_true")
    ap.add_argument("--rules", action="store_true")
    ap.add_argument("--tidy", action="store_true")
    a = ap.parse_args()
    with open(a.log, encoding="utf-8") as fh:
        takes, glued = read_takes(fh.read())
    if glued:
        print("%s: %d record(s) glued to the one before (the file lost a newline); read apart" % (a.log, glued), file=sys.stderr)
    text = text_tokens(a.commit, a.whole)
    index = build_index(text)

    def lang_of(tk):
        return tk.get("lang") if tk.get("lang") in ("en", "nl") else "en"

    res = diff_all(takes, text, index, lambda tk: tk.get("pieces") or [])
    base = summarise(res, text, lang_of)
    out = {"commit": a.commit, "takes": len(takes), "status": {str(r["tk"]["take"]): r["status"] for r in res},
           "logged": base}

    if a.rules:
        tidier = None
        if a.tidy:
            from sttlib import tidy as tidylib
            tidier = tidylib.load(tidylib.TIDY_PICK, "CPU")
        for name, held in (("rules, pauses held (under thinkSilenceMs)", True), ("rules, pauses past thinkSilenceMs", False)):
            rr = diff_all(takes, text, index,
                          lambda tk, held=held: rerun(tk.get("pieces") or [], tk.get("heard") or [], lang_of(tk), held, tidier))
            out[name] = compare(base, summarise(rr, text, lang_of))
    if a.json:
        print(json.dumps(out, indent=1, ensure_ascii=False))
        return 0
    report(out, res)
    return 0


def key(r):
    return (r["take"], r["class"], r["where"], r["written"])


def compare(before, after):
    """What the rules fixed (a row gone), what remains, what they made (a row new): rows matched by take, class and written words."""
    b = Counter(key(r) for r in before["rows"])
    a = Counter(key(r) for r in after["rows"])
    fixed = [r for r in before["rows"] if a[key(r)] < b[key(r)]]
    made = [r for r in after["rows"] if b[key(r)] < a[key(r)]]
    remain = [r for r in after["rows"] if b[key(r)] and r["class"] != "punctuation"]
    sb = {(s["take"], s["piece"], s["written"]) for s in before["splits"] if s["split"]}
    sa = {(s["take"], s["written"]) for s in after["splits"] if s["split"]}
    return {"count": after["count"], "fixed": fixed, "made": made, "remain": remain,
            "splits fixed": [s for s in before["splits"] if s["split"] and (s["take"], s["written"]) not in sa],
            "splits": len(sb)}


def report(out, res):
    print("STT TAKES DIFF  commit %s, %d takes in the log" % (out["commit"], out["takes"]))
    for r in res:
        st = r["status"]
        print("  take %-3s %-28s %s" % (r["tk"]["take"], st, (" | ".join(r["pieces"]))[:96]))
    lg = out["logged"]
    print("\nDIFFERENCES (take, class, said -> written, where)")
    for x in lg["rows"]:
        extra = (" [%s]" % x["also"]) if x.get("also") else ""
        extra += (" close %.2f" % x["close"]) if "close" in x else ""
        print("  %-3s %-11s %-34s -> %-34s %s%s" % (x["take"], x["class"], repr(x["said"])[:34], repr(x["written"])[:34],
                                                     x["where"], extra))
    print("\nPIECE BOUNDARIES (split: the written sentence runs on across the pause; hold / continue: today's rules)")
    for s in lg["splits"]:
        print("  %-3s %-5s %-7s hold=%-5s continue=%-5s %r | %r  ~ %r" % (
            s["take"], "SPLIT" if s["split"] else "end", "visible" if s["visible"] else "", s["hold"], s["continue"],
            s["end"][-40:], s["next"][:30], s["written"][:70]))
    print("\nREPEATS")
    for x in lg["repeats"]:
        print("  %-3s %-16s %r%s" % (x["take"], x["kind"], x["words"][:90], (" -> %r" % x["once"][:60]) if "once" in x else ""))
    if lg["script"]:
        print("\nOTHER SCRIPT: %s" % " ".join(lg["script"]))
    print("\nSUMMARY (logged takes)")
    for c in ORDER:
        print("  %-26s %d" % (c, lg["count"].get(c, 0)))
    sp = [s for s in lg["splits"]]
    if sp:
        tab = Counter((s["split"], s["hold"]) for s in sp)
        tc = Counter((s["split"], s["continue"]) for s in sp)
        print("  boundaries: %d; the hold rule holds %d of %d splits and %d of %d real sentence ends (time only);"
              % (len(sp), tab[(True, True)], tab[(True, True)] + tab[(True, False)], tab[(False, True)],
                 tab[(False, True)] + tab[(False, False)]))
        print("              the continue rule lower-cases %d of %d splits and %d of %d real sentence ends (a wrong letter)"
              % (tc[(True, True)], tc[(True, True)] + tc[(True, False)], tc[(False, True)], tc[(False, True)] + tc[(False, False)]))
    for name in [k for k in out if k.startswith("rules")]:
        rr = out[name]
        print("\nTHROUGH TODAY'S RULES -- %s" % name)
        for c in ORDER:
            b, a = lg["count"].get(c, 0), rr["count"].get(c, 0)
            if b or a:
                print("  %-26s %3d -> %3d" % (c, b, a))
        print("  fixed:")
        for x in rr["fixed"]:
            print("    %-3s %-11s %r -> %r" % (x["take"], x["class"], x["said"][:40], x["written"][:40]))
        for s in rr["splits fixed"]:
            print("    %-3s %-11s %r | %r" % (s["take"], "split", s["end"][-40:], s["next"][:30]))
        print("  remain (punctuation aside):")
        for x in rr["remain"]:
            print("    %-3s %-11s %r -> %r" % (x["take"], x["class"], x["said"][:40], x["written"][:40]))
        print("  made (a difference the rules introduce; \"left\": a capital the user left standing mid-sentence):")
        for x in rr["made"]:
            left = x["class"] == "casing" and x.get("mid") and x["written"][:1].isupper() and x["said"][:1].islower()
            print("    %-3s %-11s %r -> %r%s" % (x["take"], x["class"], x["said"][:40], x["written"][:40], "  left" if left else ""))
        if not rr["made"]:
            print("    none")


if __name__ == "__main__":
    sys.exit(main())
