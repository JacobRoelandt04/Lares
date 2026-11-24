#!/usr/bin/env python3
"""mathrender.py -- LaTeX math to an ALPHA-ONLY picture, for the LLM transcript.

The picture is a mask: white ink whose alpha is the coverage. The shell tints it with the
theme's own text colour in a shader (MathInk.qml, shaders/icon_ink.frag), so a light/dark
switch re-renders nothing and a formula follows the text beside it.

    mathrender.py --serve [--cache DIR]      a worker: JSON lines in, JSON lines out
    mathrender.py --once TEX [--display] [--px 14] [--scale 1.25] [--out FILE]

A request:   {"id": 7, "tex": "\\frac{a}{b}", "display": false, "px": 14, "scale": 1.25}
An answer:   {"id": 7, "ok": true, "key": "<md5>", "file": "/.../<md5>.png", "w": 20.4, "h": 31.2, "d": 9.6}
             {"id": 7, "ok": false, "key": "<md5>", "why": "..."}
w, h and d are LOGICAL pixels (device pixels / scale); d is how far the picture reaches BELOW the
baseline, so a host puts the baseline of the formula on the baseline of the text.

THE KEY is md5 of  "v1" US tex US display US px(.3f) US scale(.3f)  -- the QML side computes the same
string with Qt.md5, which is how it can know a formula's size from the index (`index.jsonl`, one line
per render, failures included) BEFORE the worker has said anything, so a transcript opened a second
time lays out at once. Pictures live next to the index and are pruned oldest-first past a cap.

WHAT MATHTEXT COVERS. matplotlib's mathtext is not LaTeX: no environments, no \\textbf, no \\bigl.
`translate()` maps the cheap differences (\\textbf -> \\mathbf, \\dfrac -> \\frac, \\displaystyle dropped,
\\lvert -> |, \\pmod ...); `aligned` / `align` / `gather` / `split` and a bare `\\\\` become rows,
rendered one by one and stacked (a row's `&` is an alignment column). Anything it still cannot parse
(matrices, cases, \\underbrace) answers ok:false and the shell shows the source.
"""
import argparse
import hashlib
import json
import os
import re
import select
import sys
import time

VERSION = "v1"
FONTSET = "dejavusans"
PAD = 2                 # transparent device px around the ink, so an italic overhang is never cut
MAX_FILES = 6000
IDLE_EXIT_S = 180.0


def key_of(tex, display, px, scale):
    s = "\x1f".join([VERSION, tex, "1" if display else "0", "%.3f" % px, "%.3f" % scale])
    return hashlib.md5(s.encode("utf-8")).hexdigest()


# ---- LaTeX -> mathtext ------------------------------------------------------------------------

_DROP = ("displaystyle", "textstyle", "scriptstyle", "scriptscriptstyle", "limits", "nolimits",
         "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr", "Biggl", "Biggr", "big", "Big", "bigg", "Bigg",
         "nonumber", "notag", "hline", "centering", "strut", "mathstrut", "allowbreak", "protect")
_RENAME = {
    "textbf": "mathbf", "textit": "mathit", "textrm": "mathrm", "textsf": "mathsf", "texttt": "mathtt",
    "textsc": "mathrm", "mathds": "mathbb", "bm": "mathbf", "boldsymbol": "boldsymbol", "mbox": "text",
    "dfrac": "frac", "tfrac": "frac", "cfrac": "frac", "lvert": "|", "rvert": "|", "lVert": "\\|",
    "rVert": "\\|", "operatorname*": "operatorname", "implies": "Rightarrow", "iff": "Leftrightarrow",
    "to": "rightarrow", "gets": "leftarrow", "land": "wedge", "lor": "vee", "lnot": "neg", "ne": "neq",
    "le": "leq", "ge": "geq", "dots": "ldots", "dotsc": "ldots", "dotsb": "cdots", "dotsm": "cdots",
    "vdots": "vdots", "colon": ":", "mathbbm": "mathbb",
}
_ENVS = ("aligned", "align", "align*", "alignedat", "split", "gather", "gather*", "gathered", "eqnarray",
         "eqnarray*", "multline", "multline*", "equation", "equation*", "displaymath", "flalign", "flalign*")


def _group(s, i):
    """s[i] is '{': return (inner, index after the matching '}') or None."""
    if i >= len(s) or s[i] != "{":
        return None
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
        j += 1
    return None


def translate(tex):
    """One expression's LaTeX -> what mathtext reads. Pure; never raises."""
    s = tex
    # \label{..} \tag{..} carry no picture
    s = re.sub(r"\\(label|tag|tag\*)\s*\{[^{}]*\}", "", s)
    out = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c != "\\":
            out.append(c)
            i += 1
            continue
        m = re.match(r"\\([A-Za-z]+\*?)", s[i:])
        if not m:
            out.append(s[i:i + 2])           # \, \; \{ \% \\ ...
            i += 2
            continue
        name = m.group(1)
        j = i + len(m.group(0))
        if name in _DROP:
            i = j
            continue
        if name == "pmod":
            g = _group(s, j)
            if g:
                out.append(r"\ \left(\mathrm{mod}\ " + translate(g[0]) + r"\right)")
                i = g[1]
                continue
        if name in ("bmod", "mod"):
            out.append(r"\ \mathrm{mod}\ ")
            i = j
            continue
        if name == "boxed" or name == "displaystyle":
            g = _group(s, j)
            if g:
                out.append("{" + translate(g[0]) + "}")
                i = g[1]
                continue
        if name in ("underbrace", "overbrace"):
            g = _group(s, j)
            if g:
                out.append("{" + translate(g[0]) + "}")
                i = g[1]
                k = i
                if k < n and s[k] in "_^":
                    g2 = _group(s, k + 1)
                    if g2:
                        i = g2[1]
                continue
        if name == "text" or name == "mbox":
            g = _group(s, j)
            if g:
                out.append(r"\text{" + g[0] + "}")   # text is literal: not translated
                i = g[1]
                continue
        if name in _RENAME:
            r = _RENAME[name]
            out.append(("\\" + r) if r[:1].isalpha() else r)
            i = j
            if r[:1].isalpha() is False and j < n and s[j].isalpha():
                out.append(" ")
            continue
        out.append("\\" + name)
        i = j
    return "".join(out)


def split_rows(tex):
    """Rows of a multi-line formula (an aligned-like environment or a bare \\\\); None when one line."""
    s = tex.strip()
    for env in _ENVS:
        m = re.match(r"^\\begin\{" + re.escape(env) + r"\}(?:\{[^{}]*\})?(.*)\\end\{" + re.escape(env) + r"\}$", s, re.S)
        if m:
            s = m.group(1)
            break
    if "\\\\" not in s and s == tex.strip():
        return None
    rows = [r.strip() for r in re.split(r"\\\\(?:\[[^\]]*\])?", s)]
    rows = [r for r in rows if r]
    return rows if len(rows) > 1 or s != tex.strip() else None


# ---- rendering --------------------------------------------------------------------------------

_np = None
_mt = None


def _lazy():
    global _np, _mt
    if _mt is None:
        import matplotlib
        matplotlib.use("Agg")
        matplotlib.rcParams["mathtext.fontset"] = FONTSET
        import numpy
        from matplotlib import mathtext
        from matplotlib.font_manager import FontProperties
        _np = numpy
        _mt = (mathtext, FontProperties)
    return _np, _mt


def _render_one(expr, px, scale):
    """expr (already translated) -> (alpha uint8 HxW, depth in device px). Raises on a parse error."""
    np, (mathtext, FontProperties) = _lazy()
    rp = _parser().parse("$" + expr + "$", dpi=72.0 * scale, prop=FontProperties(size=px))
    return np.array(rp.image, dtype=np.uint8), float(rp.depth)


_parser_obj = None


def _parser():
    global _parser_obj
    if _parser_obj is None:
        _parser_obj = _mt[0].MathTextParser("agg")
    return _parser_obj


def render(tex, display, px, scale):
    """-> (alpha array HxW, depth device px, total height H). Raises ValueError with a short reason."""
    np, _ = _lazy()
    try:
        rows = split_rows(tex)
        if rows is None:
            a, d = _render_one(translate(tex), px, scale)
        else:
            cells = []
            for r in rows:
                parts = [translate(p.strip()) for p in r.split("&")]
                cells.append(parts)
            ncol = max(len(p) for p in cells)
            imgs = []
            for parts in cells:
                line = []
                for p in parts:
                    if p == "":
                        line.append((np.zeros((0, 0), dtype=np.uint8), 0.0))
                    else:
                        line.append(_render_one(p, px, scale))
                imgs.append(line)
            # column widths: even columns (1st, 3rd ..) right-aligned, odd ones left-aligned: the `&` of an
            # align environment sits between a right-aligned lhs and a left-aligned rhs.
            colw = [max((ln[c][0].shape[1] for ln in imgs if c < len(ln)), default=0) for c in range(ncol)]
            gap = int(round(px * scale * 0.35))
            width = sum(colw) + gap * (ncol - 1)
            lines = []
            for ln in imgs:
                h = max((im.shape[0] for im, _ in ln), default=1)
                dep = max((dd for im, dd in ln if im.shape[0] > 0), default=0.0)
                above = max((im.shape[0] - dd for im, dd in ln if im.shape[0] > 0), default=1.0)
                canvas = np.zeros((int(round(above + dep)) + 1, width), dtype=np.uint8)
                x = 0
                for c, (im, dd) in enumerate(ln):
                    if im.shape[0] > 0:
                        top = int(round(above - (im.shape[0] - dd)))
                        left = x + (colw[c] - im.shape[1] if c % 2 == 0 and ncol > 1 else 0)
                        canvas[top:top + im.shape[0], left:left + im.shape[1]] = np.maximum(
                            canvas[top:top + im.shape[0], left:left + im.shape[1]], im)
                    x += colw[c] + gap
                lines.append((canvas, dep))
            lead = int(round(px * scale * 0.45))
            total = sum(cv.shape[0] for cv, _ in lines) + lead * (len(lines) - 1)
            a = np.zeros((total, width), dtype=np.uint8)
            y = 0
            for cv, _ in lines:
                a[y:y + cv.shape[0], :] = cv
                y += cv.shape[0] + lead
            d = lines[-1][1]
    except Exception as e:                     # mathtext's parse errors are many types
        msg = str(e).strip().splitlines()
        raise ValueError((msg[-1] if msg else type(e).__name__)[:120])
    if a.size == 0 or int(a.max()) == 0:
        raise ValueError("empty")
    a = np.pad(a, PAD)
    return a, d + PAD


def save_png(alpha, path):
    from PIL import Image
    np, _ = _lazy()
    rgba = np.empty(alpha.shape + (4,), dtype=np.uint8)
    rgba[:, :, :3] = 255
    rgba[:, :, 3] = alpha
    tmp = path + ".tmp"
    Image.fromarray(rgba, "RGBA").save(tmp, format="PNG", optimize=False)
    os.replace(tmp, path)


class Cache:
    def __init__(self, root):
        self.root = root
        os.makedirs(root, exist_ok=True)
        self.index_path = os.path.join(root, "index.jsonl")
        self.index = {}
        self._load()

    def _load(self):
        try:
            with open(self.index_path, "r", encoding="utf-8") as f:
                for ln in f:
                    try:
                        e = json.loads(ln)
                    except ValueError:
                        continue
                    k = e.get("k")
                    if k and (not e.get("ok", True) or os.path.exists(self.png(k))):
                        self.index[k] = e
        except OSError:
            pass
        # compact + prune: keep what has a file (or is a recorded failure), oldest picture first out
        pngs = []
        try:
            for fn in os.listdir(self.root):
                if fn.endswith(".png"):
                    p = os.path.join(self.root, fn)
                    pngs.append((os.path.getmtime(p), p))
        except OSError:
            pass
        if len(pngs) > MAX_FILES:
            pngs.sort()
            for _, p in pngs[:len(pngs) - int(MAX_FILES * 0.8)]:
                try:
                    os.remove(p)
                except OSError:
                    pass
                self.index.pop(os.path.basename(p)[:-4], None)
        self._rewrite()

    def _rewrite(self):
        tmp = self.index_path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                for e in self.index.values():
                    f.write(json.dumps(e, separators=(",", ":")) + "\n")
            os.replace(tmp, self.index_path)
        except OSError:
            pass

    def png(self, k):
        return os.path.join(self.root, k + ".png")

    def add(self, e):
        self.index[e["k"]] = e
        try:
            with open(self.index_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(e, separators=(",", ":")) + "\n")
        except OSError:
            pass


def answer(cache, req):
    tex = str(req.get("tex", ""))
    display = bool(req.get("display", False))
    px = float(req.get("px", 14))
    scale = float(req.get("scale", 1))
    k = key_of(tex, display, px, scale)
    a = {"id": req.get("id"), "key": k}
    hit = cache.index.get(k)
    if hit is not None:
        if hit.get("ok", True):
            try:
                os.utime(cache.png(k), None)
            except OSError:
                pass
            a.update(ok=True, file=cache.png(k), w=hit["w"], h=hit["h"], d=hit["d"])
        else:
            a.update(ok=False, why=hit.get("why", ""))
        return a
    try:
        alpha, depth = render(tex, display, px, scale)
    except ValueError as e:
        cache.add({"k": k, "ok": False, "why": str(e)})
        a.update(ok=False, why=str(e))
        return a
    save_png(alpha, cache.png(k))
    h, w = alpha.shape
    e = {"k": k, "ok": True, "w": round(w / scale, 3), "h": round(h / scale, 3), "d": round(depth / scale, 3)}
    cache.add(e)
    a.update(ok=True, file=cache.png(k), w=e["w"], h=e["h"], d=e["d"])
    return a


def serve(root):
    cache = Cache(root)
    out = sys.stdout
    fd = sys.stdin.fileno()
    buf = b""
    last = time.time()
    while True:
        r, _, _ = select.select([fd], [], [], 5.0)
        if not r:
            if time.time() - last > IDLE_EXIT_S:
                return 0
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            return 0
        last = time.time()
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                req = json.loads(line.decode("utf-8"))
                resp = answer(cache, req)
            except Exception as e:                 # a bad request must not end the worker
                resp = {"id": None, "ok": False, "why": "bad request: %s" % e}
            out.write(json.dumps(resp, separators=(",", ":")) + "\n")
            out.flush()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--once")
    ap.add_argument("--display", action="store_true")
    ap.add_argument("--px", type=float, default=14)
    ap.add_argument("--scale", type=float, default=1)
    ap.add_argument("--out")
    ap.add_argument("--cache", default=os.environ.get("LARES_MATH_CACHE") or os.path.expanduser("~/.cache/lares/llm-math"))
    a = ap.parse_args()
    if a.serve:
        return serve(a.cache)
    if a.once is not None:
        try:
            alpha, depth = render(a.once, a.display, a.px, a.scale)
        except ValueError as e:
            print(json.dumps({"ok": False, "why": str(e)}))
            return 1
        out = a.out or "mathrender.png"
        save_png(alpha, out)
        h, w = alpha.shape
        print(json.dumps({"ok": True, "file": out, "w": w / a.scale, "h": h / a.scale, "d": depth / a.scale}))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
