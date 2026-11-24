#!/usr/bin/env python3
"""Lares launcher answers: one long-lived child, JSON lines on stdin / stdout.

The contract is docs/contracts/launcher_answers.md.  Request {"id": n, "q": "..."} or {"id": n, "cmd": "ping"};
reply {"id": n, "answers": [...]} (at most 3, best first, [] for "not an answer").  A currency answer made while the
rates are being fetched is `pending` and is followed by a second reply with the same id.  Exits on EOF.

Standard library only, no eval: a real tokenizer and parser for the arithmetic, exact Fractions where it can be.
Stdout carries replies and nothing else; trouble is one line on stderr.
Options (launcher.jsonc "answers"): --home-currency XXX, --currencies XXX,YYY (the ones shown beside an amount), --kinds a,b (the
families that answer, by name). Home settings (tests override them): LARES_HOME_CURRENCY, LARES_ANSWERS_TZ,
LARES_ANSWERS_NOW, LARES_ECB_URL, XDG_CACHE_HOME.
"""
import sys, os, re, json, math, threading, time
from fractions import Fraction
from decimal import Decimal, localcontext, ROUND_HALF_EVEN
import datetime as dt

NNBSP = " "
DIG = "0123456789"
HOME_CUR = os.environ.get("LARES_HOME_CURRENCY", "EUR").upper()
CURRENCIES = ["USD", "EUR", "GBP", "JPY", "CHF"]


class Bad(Exception):
    """Not an answer (a parse that fails, a value that does not exist)."""


# ------------------------------------------------------------------------------------------------- number display
def group(ds):
    """Group the digits of an unsigned integer string in threes (U+202F)."""
    out = []
    while len(ds) > 3:
        out.append(ds[-3:])
        ds = ds[:-3]
    out.append(ds)
    return NNBSP.join(reversed(out))


def fmt(x, sig=12, maxexact=40):
    """(shown, plain) for a Fraction / int / float: 12 significant digits, exact integers, scientific past 1e15 / under 1e-5."""
    if isinstance(x, float):
        if x != x or x in (float("inf"), float("-inf")):
            raise Bad()
        if x == int(x) and abs(x) < 1e15:
            x = Fraction(int(x))
    if isinstance(x, int):
        x = Fraction(x)
    neg = x < 0
    with localcontext() as c:
        c.prec = sig
        if isinstance(x, Fraction):
            if x.denominator == 1:
                ds = str(abs(x.numerator))
                if len(ds) <= maxexact:
                    sg = "-" if neg else ""
                    return sg + (group(ds) if len(ds) >= 5 else ds), sg + ds
            d = Decimal(abs(x.numerator)) / Decimal(x.denominator)
        else:
            d = +Decimal(abs(x))
    if d == 0:
        return "0", "0"
    d = d.normalize()
    e = d.adjusted()
    sg = "-" if neg else ""
    if e >= 15 or e < -5:
        s = format(d, "e").replace("e+", "e")
        return sg + s, sg + s
    plain = format(d, "f")
    ip, _, fp = plain.partition(".")
    shown = group(ip) if len(ip) >= 5 else ip
    if fp:
        shown += "." + fp
    return sg + shown, sg + plain


def fmt_dec(x, dp):
    """A Fraction rounded to dp decimals, (shown, plain)."""
    with localcontext() as c:
        c.prec = 40
        d = Decimal(x.numerator) / Decimal(x.denominator)
        d = d.quantize(Decimal(1).scaleb(-dp), rounding=ROUND_HALF_EVEN)
    plain = format(d, "f")
    if plain.startswith("-") and d == 0:
        plain = plain[1:]
    neg = plain.startswith("-")
    ip, _, fp = plain.lstrip("-").partition(".")
    shown = ("-" if neg else "") + (group(ip) if len(ip) >= 5 else ip) + ("." + fp if fp else "")
    return shown, plain


def A(kind, value, copy, expr, detail="", alts=None, swatch=None, pending=False):
    a = {"kind": kind, "value": value, "copy": copy, "expr": expr, "detail": detail, "alts": (alts or [])[:3]}
    if swatch:
        a["swatch"] = swatch
    a["pending"] = pending
    return a


def alt(label, value, copy=None):
    return {"label": label, "value": value, "copy": value if copy is None else copy}


# ------------------------------------------------------------------------------------------------- numbers in text
def scan_number(s, i):
    """Number starting at s[i] (a digit or '.'): (Fraction, end, base).  Commas: exactly 3 digits groups, else decimal."""
    n = len(s)
    if s[i] == "0" and i + 1 < n and s[i + 1] in "xXbBoO":
        c = s[i + 1].lower()
        base = {"x": 16, "b": 2, "o": 8}[c]
        digs = {"x": "0123456789abcdefABCDEF", "b": "01", "o": "01234567"}[c]
        k = i + 2
        while k < n and s[k] in digs:
            k += 1
        if k > i + 2:
            return Fraction(int(s[i + 2:k], base)), k, base
    k = i
    while k < n and s[k] in DIG:
        k += 1
    ip = s[i:k]
    grouped = False
    dec = None
    while k < n and s[k] == "," and k + 1 < n and s[k + 1] in DIG and dec is None:
        m = k + 1
        while m < n and s[m] in DIG:
            m += 1
        run = s[k + 1:m]
        if len(run) == 3 and ip:
            ip += run
            grouped = True
            k = m
        elif not grouped and ip:
            dec = run
            k = m
        else:
            break
    if dec is None and k + 1 < n and s[k] == "." and s[k + 1] in DIG:
        m = k + 1
        while m < n and s[m] in DIG:
            m += 1
        dec = s[k + 1:m]
        k = m
    v = Fraction(int(ip or "0"))
    if dec:
        v += Fraction(int(dec), 10 ** len(dec))
    if k < n and s[k] in "eE":
        t = k + 1
        if t < n and s[t] in "+-":
            t += 1
        if t < n and s[t] in DIG:
            u = t
            while u < n and s[u] in DIG:
                u += 1
            ex = int(s[k + 1:u])
            if abs(ex) > 400:
                raise Bad()
            v *= Fraction(10) ** ex
            k = u
    return v, k, 10


def num_of(text):
    """The whole of text as a plain number (Fraction), or None."""
    t = text.strip()
    sign = 1
    if t[:1] in "+-":
        sign = -1 if t[0] == "-" else 1
        t = t[1:].strip()
    if not t or (t[0] not in DIG and not (t[0] == "." and len(t) > 1 and t[1] in DIG)):
        return None
    try:
        v, j, b = scan_number(t, 0)
    except Bad:
        return None
    if j != len(t) or b != 10:
        return None
    return sign * v


NUM = r"[-+]?(?:\d[\d,]*(?:\.\d+)?|\.\d+)(?:e[-+]?\d+)?"


# ------------------------------------------------------------------------------------------------- durations
class Dur:
    """A length of time in seconds, so 3h20m + 45m and 2:30 * 3 run through the same parser."""
    __slots__ = ("s",)

    def __init__(self, s):
        self.s = Fraction(s)

    def __add__(self, o):
        if isinstance(o, Dur):
            return Dur(self.s + o.s)
        raise Bad()

    def __sub__(self, o):
        if isinstance(o, Dur):
            return Dur(self.s - o.s)
        raise Bad()

    def __mul__(self, o):
        if isinstance(o, (Fraction, int, float)) and not isinstance(o, Dur):
            return Dur(self.s * Fraction(o))
        raise Bad()

    __rmul__ = __mul__

    def __truediv__(self, o):
        if isinstance(o, Dur):
            return self.s / o.s
        if isinstance(o, (Fraction, int, float)):
            return Dur(self.s / Fraction(o))
        raise Bad()

    def __neg__(self):
        return Dur(-self.s)

    def __lt__(self, o):
        return self.s < 0


# ------------------------------------------------------------------------------------------------- math: lexer, parser
CONST = {"pi": math.pi, "tau": math.tau, "e": math.e, "phi": (1 + 5 ** 0.5) / 2}
FUNCS = ("sqrt", "cbrt", "abs", "round", "floor", "ceil", "sin", "cos", "tan", "asin", "acos", "atan", "ln", "log",
         "log2", "log10", "exp", "sinh", "cosh", "tanh", "fact")
DEGWORDS = ("deg", "degs", "degree", "degrees")


def lex_math(s):
    toks = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == " ":
            i += 1
        elif c in DIG or (c == "." and i + 1 < n and s[i + 1] in DIG):
            v, j, b = scan_number(s, i)
            toks.append(("n", v, s[i:j], b))
            i = j
        elif c in "π√":
            toks.append(("i", "pi" if c == "π" else "sqrt"))
            i += 1
        elif c.isalpha():
            j = i
            while j < n and s[j].isalpha() and s[j] not in "π√":
                j += 1
            w = s[i:j].lower()
            if w == "log" and s[j:j + 2] == "10":
                w, j = "log10", j + 2
            elif w == "log" and s[j:j + 1] == "2":
                w, j = "log2", j + 1
            toks.append(("o", "*") if w == "x" else ("i", w))
            i = j
        elif c == "°":
            toks.append(("i", "deg"))
            i += 1
        elif c == "*" and s[i:i + 2] == "**":
            toks.append(("o", "^"))
            i += 2
        elif c in "×·":
            toks.append(("o", "*"))
            i += 1
        elif c == "÷":
            toks.append(("o", "/"))
            i += 1
        elif c in "+-*/^()!%":
            toks.append(("o", c))
            i += 1
        else:
            raise Bad()
    return toks


def iroot(n, k):
    """Exact integer k-th root of n >= 0, or None."""
    if n < 2:
        return n
    x = 1 << ((n.bit_length() + k - 1) // k)
    while True:
        y = ((k - 1) * x + n // x ** (k - 1)) // k
        if y >= x:
            break
        x = y
    return x if x ** k == n else None


def exact_root(a, k):
    if isinstance(a, Fraction) and a >= 0:
        p, q = iroot(a.numerator, k), iroot(a.denominator, k)
        if p is not None and q is not None:
            return Fraction(p, q)
    return None


def fpow(a, b):
    if isinstance(a, Dur) or isinstance(b, Dur):
        raise Bad()
    if isinstance(a, Fraction) and isinstance(b, Fraction):
        if b.denominator == 1:
            e = int(b)
            if abs(e) > 10000 or (a == 0 and e < 0):
                raise Bad()
            if max(a.numerator.bit_length(), a.denominator.bit_length()) * abs(e) > 60000:
                raise Bad()
            return a ** e
        if b.denominator <= 8 and a >= 0:
            r = exact_root(a, b.denominator)
            if r is not None and abs(b.numerator) <= 64:
                return r ** b.numerator
    r = float(a) ** float(b)
    if isinstance(r, complex):
        raise Bad()
    return r


def ffunc(name, v):
    if isinstance(v, Dur):
        raise Bad()
    if name == "sqrt":
        r = exact_root(v, 2) if isinstance(v, Fraction) else None
        if r is not None:
            return r
        if v < 0:
            raise Bad()
        return math.sqrt(v)
    if name == "cbrt":
        if isinstance(v, Fraction):
            r = exact_root(abs(v), 3)
            if r is not None:
                return r if v >= 0 else -r
        return math.copysign(abs(v) ** (1 / 3), v)
    if name == "abs":
        return abs(v)
    if name in ("floor", "ceil"):
        return Fraction(math.floor(v) if name == "floor" else math.ceil(v))
    if name == "round":
        if isinstance(v, Fraction):
            r = math.floor(abs(v) + Fraction(1, 2))
            return Fraction(r if v >= 0 else -r)
        return Fraction(round(v))
    f = float(v)
    if name == "fact":
        return fact(v)
    if name in ("log", "log10", "ln", "log2"):
        if f <= 0:
            raise Bad()
        return {"log": math.log10, "log10": math.log10, "ln": math.log, "log2": math.log2}[name](f)
    return {"sin": math.sin, "cos": math.cos, "tan": math.tan, "asin": math.asin, "acos": math.acos, "atan": math.atan,
            "exp": math.exp, "sinh": math.sinh, "cosh": math.cosh, "tanh": math.tanh}[name](f)


def fact(v):
    if not isinstance(v, Fraction) or v.denominator != 1 or v < 0 or v > 3000:
        raise Bad()
    return Fraction(math.factorial(int(v)))


class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0
        self.ops = 0
        self.base = False

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def expr(self):
        v = self.term()
        while True:
            t = self.peek()
            if t and t[0] == "o" and t[1] in "+-":
                self.i += 1
                self.ops += 1
                r = self.term()
                v = v + r if t[1] == "+" else v - r
            else:
                return v

    def starts_atom(self, t):
        if t is None:
            return False
        if t[0] == "n" or t[0] in ("d",):
            return True
        if t[0] == "i":
            return t[1] in CONST or t[1] in FUNCS
        return t[0] == "o" and t[1] == "("

    def term(self):
        v = self.unary()
        while True:
            t = self.peek()
            if t is None:
                return v
            if t[0] == "o" and t[1] in "*/%":
                self.i += 1
                self.ops += 1
                r = self.unary()
                if t[1] == "*":
                    v = v * r
                elif t[1] == "/":
                    v = v / r
                else:
                    v = self.mod(v, r)
            elif t[0] == "i" and t[1] == "mod":
                self.i += 1
                self.ops += 1
                v = self.mod(v, self.unary())
            elif self.starts_atom(t) and not (t[0] in "nd" and self.t[self.i - 1][0] in "nd"):
                self.ops += 1
                v = v * self.unary()
            else:
                return v

    @staticmethod
    def mod(a, b):
        if isinstance(a, Fraction) and isinstance(b, Fraction):
            if b == 0:
                raise Bad()
            return a - b * math.floor(a / b)
        raise Bad()

    def unary(self):
        t = self.peek()
        if t and t[0] == "o" and t[1] in "+-":
            self.i += 1
            v = self.unary()
            return -v if t[1] == "-" else v
        return self.power()

    def power(self):
        b = self.postfix()
        t = self.peek()
        if t and t[0] == "o" and t[1] == "^":
            self.i += 1
            self.ops += 1
            return fpow(b, self.unary())
        return b

    def postfix(self):
        v = self.atom()
        while True:
            t = self.peek()
            if t and t[0] == "o" and t[1] == "!":
                self.i += 1
                self.ops += 1
                v = fact(v)
            elif t and t[0] == "i" and t[1] in DEGWORDS:
                self.i += 1
                self.ops += 1
                if isinstance(v, Dur):
                    raise Bad()
                v = float(v) * math.pi / 180
            else:
                return v

    def atom(self):
        t = self.peek()
        if t is None:
            raise Bad()
        self.i += 1
        if t[0] == "n":
            if t[3] != 10:
                self.base = True
            return t[1]
        if t[0] == "d":
            return Dur(t[1])
        if t[0] == "o" and t[1] == "(":
            v = self.expr()
            c = self.peek()
            if not (c and c[0] == "o" and c[1] == ")"):
                raise Bad()
            self.i += 1
            return v
        if t[0] == "i":
            if t[1] in CONST:
                return CONST[t[1]]
            if t[1] in FUNCS:
                self.ops += 1
                n = self.peek()
                if n and n[0] == "o" and n[1] == "(":
                    self.i += 1
                    v = self.expr()
                    c = self.peek()
                    if not (c and c[0] == "o" and c[1] == ")"):
                        raise Bad()
                    self.i += 1
                else:
                    v = self.postfix()
                return ffunc(t[1], v)
        raise Bad()


def run_parser(toks):
    p = Parser(toks)
    try:
        v = p.expr()
    except (ZeroDivisionError, OverflowError, ValueError, TypeError, RecursionError):
        raise Bad()
    if p.i != len(toks):
        raise Bad()
    if isinstance(v, Fraction) and v.denominator == 1 and v.numerator.bit_length() > 60000:
        raise Bad()
    return v, p


def render_expr(toks):
    out = ""
    for k, t in enumerate(toks):
        if t[0] == "n":
            s = t[2]
        elif t[0] == "i":
            s = {"pi": "π", "deg": "°"}.get(t[1], t[1])
        elif t[0] == "d":
            s = t[2]
        else:
            s = {"*": "×", "/": "÷"}.get(t[1], t[1])
        prev = toks[k - 1] if k else None
        if t[0] == "o" and t[1] in ")!%":
            out += s
        elif t[0] == "i" and t[1] == "deg":
            out += s
        elif prev is not None and prev[0] == "o" and prev[1] == "(":
            out += s
        elif prev is not None and prev[0] == "i" and prev[1] in FUNCS and t[0] == "o" and t[1] == "(":
            out += s
        elif t[0] == "o" and t[1] == "(" and prev is not None and prev[0] in ("n", "i") and not (prev[0] == "i" and prev[1] in FUNCS):
            out += " " + s
        else:
            out += (" " if out else "") + s
    return out


BASE_PREFIX = {16: "0x", 2: "0b", 8: "0o"}


def to_base(n, b):
    if n == 0:
        return "0"
    digs = "0123456789abcdefghijklmnopqrstuvwxyz"
    s = ""
    m = abs(n)
    while m:
        m, r = divmod(m, b)
        s = digs[r] + s
    return s


def base_str(n, b):
    return ("-" if n < 0 else "") + BASE_PREFIX.get(b, "") + to_base(n, b)


def base_alts(n, skip):
    out = []
    for lab, b in (("hex", 16), ("bin", 2), ("oct", 8), ("dec", 10)):
        if b == skip:
            continue
        s = base_str(n, b) if b != 10 else fmt(Fraction(n))[0]
        out.append(alt(lab, s, base_str(n, b) if b != 10 else str(n)))
    return out[:3]


def number_answer(kind, v, expr, alts=None, detail=""):
    shown, plain = fmt(v)
    alts = list(alts or [])
    if isinstance(v, Fraction):
        if v.denominator != 1 and v.denominator <= 100000 and len(alts) < 3:
            alts.append(alt("fraction", f"{v.numerator}/{v.denominator}"))
        elif v.denominator == 1 and len(str(abs(v.numerator))) > 15 and len(alts) < 3:
            s, _ = fmt(v, maxexact=0)
            alts.append(alt("scientific", s))
    return A(kind, shown, plain, expr, detail, alts)


def eval_math(text):
    """(value, parser, tokens) of an arithmetic text or Bad."""
    toks = lex_math(text.lower())
    if not toks:
        raise Bad()
    v, p = run_parser(toks)
    return v, p, toks


def fam_math(orig, low):
    t = low.rstrip("= ").strip()
    if not t or not re.search(r"[\d.πe]", t):
        return None
    try:
        v, p, toks = eval_math(t)
    except (Bad, RecursionError):
        return None
    if isinstance(v, Dur) or p.ops == 0:
        return None
    expr = render_expr(toks)
    if p.base and isinstance(v, Fraction) and v.denominator == 1:
        n = int(v)
        shown, plain = fmt(v)
        return [A("base", shown, plain, expr, "", base_alts(n, 10))]
    return [number_answer("math", v, expr)]


# ------------------------------------------------------------------------------------------------- bases
BASEWORDS = {"hex": 16, "hexadecimal": 16, "bin": 2, "binary": 2, "oct": 8, "octal": 8, "dec": 10, "decimal": 10}


def base_target(t):
    t = t.strip()
    if t in BASEWORDS:
        return BASEWORDS[t]
    m = re.fullmatch(r"base\s*(\d{1,2})", t)
    if m and 2 <= int(m.group(1)) <= 36:
        return int(m.group(1))
    return None


def fam_base(orig, low):
    m = re.fullmatch(r"(0x[0-9a-f]+|0b[01]+|0o[0-7]+)", low)
    if m:
        v, _, b = scan_number(low, 0)
        n = int(v)
        shown, plain = fmt(v)
        return [A("base", shown, plain, low.replace("0x", "0x").lower(), "", base_alts(n, b))]
    b = None
    src = None
    label = ""
    m = re.fullmatch(r"(hex|hexadecimal|bin|binary|oct|octal|dec|decimal|base\s*\d{1,2})\s+(.+)", low)
    if m:
        b = base_target(m.group(1))
        src = m.group(2)
        label = m.group(1)
    else:
        m = re.fullmatch(r"(.+)\s+(?:in|to|as|into|->|→)\s+(\S+(?:\s*\d{1,2})?)", low)
        if m:
            b = base_target(m.group(2))
            src = m.group(1)
            label = m.group(2)
    if b is None or src is None:
        return None
    try:
        v, p, toks = eval_math(src)
    except (Bad, RecursionError):
        return None
    if not isinstance(v, Fraction) or v.denominator != 1:
        return None
    n = int(v)
    expr = f"{render_expr(toks)} → {label.strip()}"
    if b == 10:
        shown, plain = fmt(v)
        return [A("base", shown, plain, expr, "", base_alts(n, 10))]
    s = base_str(n, b)
    if b not in BASE_PREFIX:
        return [A("base", s, s, expr, f"base {b}", base_alts(n, 0)[:3])]
    return [A("base", s, s, expr, f"{abs(n).bit_length() or 1} bits", base_alts(n, b))]


# ------------------------------------------------------------------------------------------------- percent
def pct_answer(expr, v, detail="", alts=None, unit=""):
    shown, plain = fmt(v)
    return [A("percent", shown + unit, plain, expr, detail, alts)]


def fam_percent(orig, low):
    if "%" not in low and "percent" not in low and "pct" not in low:
        return None
    t = re.sub(r"^(?:what(?:'s| is)|whats)\s+", "", low)
    P = r"\s*(?:%|percent|pct)"
    m = re.fullmatch(rf"({NUM}){P}\s+of\s+({NUM})", t)
    if m:
        a, b = num_of(m.group(1)), num_of(m.group(2))
        if a is None or b is None:
            return None
        return pct_answer(f"{fmt(a)[0]} % of {fmt(b)[0]}", a * b / 100)
    m = re.fullmatch(rf"({NUM}){P}\s+off\s+({NUM})", t)
    if m:
        a, b = num_of(m.group(1)), num_of(m.group(2))
        if a is None or b is None:
            return None
        return pct_answer(f"{fmt(b)[0]} − {fmt(a)[0]} %", b - b * a / 100, f"− {fmt(b * a / 100)[0]}")
    m = (re.fullmatch(rf"({NUM})\s+is\s+what{P}(?:\s+of)?\s+({NUM})", t) or
         re.fullmatch(rf"what{P}\s+is\s+({NUM})\s+of\s+({NUM})", t) or
         re.fullmatch(rf"what{P}\s+of\s+({NUM})\s+is\s+({NUM})", t))
    if m:
        a, b = num_of(m.group(1)), num_of(m.group(2))
        if m.re.pattern.startswith("what") and "of\\s+(" in m.re.pattern.split("is", 1)[0] + "":
            pass
        if a is None or b is None or b == 0:
            return None
        return pct_answer(f"{fmt(a)[0]} of {fmt(b)[0]}", a / b * 100, "", None, " %")
    m = re.fullmatch(rf"({NUM})\s+is\s+({NUM}){P}\s+of\s+what", t)
    if m:
        a, b = num_of(m.group(1)), num_of(m.group(2))
        if a is None or b is None or b == 0:
            return None
        shown, plain = fmt(a * 100 / b)
        return [A("percent", shown, plain, f"{fmt(a)[0]} is {fmt(b)[0]} % of …")]
    m = re.fullmatch(rf"({NUM})\s*([-+*/x×÷])\s*({NUM}){P}", t)
    if m:
        a, b = num_of(m.group(1)), num_of(m.group(3))
        op = m.group(2)
        if a is None or b is None:
            return None
        if op == "+":
            r, d = a * (1 + b / 100), f"+ {fmt(a * b / 100)[0]}"
        elif op == "-":
            r, d = a * (1 - b / 100), f"− {fmt(a * b / 100)[0]}"
        elif op in "*x×":
            r, d = a * b / 100, ""
        else:
            if b == 0:
                return None
            r, d = a / (b / 100), ""
        return pct_answer(f"{fmt(a)[0]} {op.replace('*', '×').replace('x', '×').replace('/', '÷')} {fmt(b)[0]} %", r, d)
    m = (re.fullmatch(rf"(?:(?:percent(?:age)?|%|pct)\s+change|change)(?:\s+from)?\s+({NUM})\s+(?:to|->|→)\s+({NUM})", t) or
         re.fullmatch(rf"({NUM})\s+(?:to|->|→)\s+({NUM})\s+(?:in|as){P}", t))
    if m:
        a, b = num_of(m.group(1)), num_of(m.group(2))
        if a is None or b is None or a == 0:
            return None
        r = (b - a) / a * 100
        shown, plain = fmt(r)
        return [A("percent", ("+" if r > 0 else "") + shown + " %", plain, f"{fmt(a)[0]} → {fmt(b)[0]}", "")]
    return None


# ------------------------------------------------------------------------------------------------- ratios and resolutions
RATIOS = [(16, 9), (16, 10), (4, 3), (21, 9), (32, 9), (3, 2), (5, 4), (1, 1), (2, 1), (9, 16), (16, 18)]
# name -> (w, h, title)
RES = {
    "720p": (1280, 720, "HD"), "hd": (1280, 720, "HD"), "hd ready": (1280, 720, "HD"),
    "1080p": (1920, 1080, "Full HD"), "fhd": (1920, 1080, "Full HD"), "full hd": (1920, 1080, "Full HD"),
    "1440p": (2560, 1440, "QHD"), "qhd": (2560, 1440, "QHD"), "wqhd": (2560, 1440, "WQHD"),
    "2160p": (3840, 2160, "4K UHD"), "4k": (3840, 2160, "4K UHD"), "uhd": (3840, 2160, "UHD"), "4k uhd": (3840, 2160, "4K UHD"),
    "dci 4k": (4096, 2160, "DCI 4K"), "4k dci": (4096, 2160, "DCI 4K"), "dci4k": (4096, 2160, "DCI 4K"),
    "5k": (5120, 2880, "5K"), "5k2k": (5120, 2160, "5K2K UltraWide"), "8k": (7680, 4320, "8K UHD"),
    "4320p": (7680, 4320, "8K UHD"), "2k": (2560, 1440, "2K · QHD as monitors are sold"), "wuxga": (1920, 1200, "WUXGA"),
    "1200p": (1920, 1200, "WUXGA"), "wqxga": (2560, 1600, "WQXGA"), "1600p": (2560, 1600, "WQXGA"),
    "wxga": (1280, 800, "WXGA"), "xga": (1024, 768, "XGA"), "svga": (800, 600, "SVGA"), "vga": (640, 480, "VGA"),
    "sxga": (1280, 1024, "SXGA"), "uxga": (1600, 1200, "UXGA"), "wsxga+": (1680, 1050, "WSXGA+"),
    "wquxga": (3840, 2400, "WQUXGA"), "qxga": (2048, 1536, "QXGA"), "hd+": (1600, 900, "HD+"),
    "qhd+": (3200, 1800, "QHD+"), "uwqhd": (3440, 1440, "UWQHD"), "uwfhd": (2560, 1080, "UWFHD"),
    "dqhd": (5120, 1440, "DQHD"), "dfhd": (3840, 1080, "DFHD"), "480p": (854, 480, "SD"), "360p": (640, 360, "360p"),
    "240p": (426, 240, "240p"),
}
ULTRA = {1080: 2560, 1440: 3440, 2160: 5120, 1600: 3840, 1200: 2560}
SUPER = {1080: 3840, 1440: 5120, 2160: 7680}
RES_ALTS = {"4k": [(4096, 2160, "DCI 4K")], "uhd": [(4096, 2160, "DCI 4K")], "2160p": [(4096, 2160, "DCI 4K")],
            "5k": [(5120, 2160, "5K2K")], "2k": [(2048, 1080, "DCI 2K")], "1440p": [(3440, 1440, "UWQHD")],
            "1080p": [(2560, 1080, "UWFHD")], "720p": [(1366, 768, "WXGA")]}


def ratio_of(w, h):
    """(text, exact): the reduced ratio when it is a known one, else the nearest known one marked with ≈."""
    g = math.gcd(w, h)
    a, b = w // g, h // g
    if (a, b) == (8, 5):
        a, b = 16, 10
    if (a, b) in RATIOS or (a <= 40 and b <= 40):
        return f"{a}:{b}", True
    r = w / h
    best = min(RATIOS, key=lambda x: abs(x[0] / x[1] - r))
    if abs(best[0] / best[1] - r) / r < 0.04:
        return f"≈ {best[0]}:{best[1]}", False
    return f"{a}:{b}", False


def mp(w, h):
    return fmt(Fraction(w * h, 10 ** 6), sig=3)[0]


def res_alt(w, h, label=""):
    return alt(label or "resolution", f"{w} × {h}", f"{w}x{h}")


def res_answer(w, h, title, expr, extra_alts=(), diag=None):
    rt, _ = ratio_of(w, h)
    detail = f"{rt} · {mp(w, h)} MP"
    alts = []
    for aw, ah, lab in extra_alts:
        alts.append(alt(lab, f"{aw} × {ah}", f"{aw}x{ah}"))
    if diag:
        ppi = math.hypot(w, h) / float(diag)
        pitch = 25.4 / ppi
        wi = float(diag) * w / math.hypot(w, h)
        hi = float(diag) * h / math.hypot(w, h)
        shown = fmt(Fraction(round(ppi * 10), 10))[0]
        d = f"{w}×{h} on {fmt(diag)[0]}″ · {fmt(pitch, sig=3)[0]} mm dot pitch · {fmt(wi * 2.54, sig=3)[0]} × {fmt(hi * 2.54, sig=3)[0]} cm"
        return [A("resolution", f"{shown} PPI", shown, expr, d,
                  [alt("dot pitch", f"{fmt(pitch, sig=3)[0]} mm", fmt(pitch, sig=3)[0]),
                   alt("size", f"{fmt(wi * 2.54, sig=3)[0]} × {fmt(hi * 2.54, sig=3)[0]} cm"),
                   res_alt(w, h, title)])]
    if title and title != expr:
        detail = f"{title} · " + detail
    return [A("resolution", f"{w} × {h}", f"{w}x{h}", expr, detail, alts)]


def even(x):
    return int(round(x / 2)) * 2


def height_ratio_width(h, a, b):
    if (a, b) == (21, 9) and h in ULTRA:
        return ULTRA[h]
    if (a, b) == (32, 9) and h in SUPER:
        return SUPER[h]
    return even(h * a / b)


RES_NAME_RE = "|".join(sorted((re.escape(k) for k in RES), key=len, reverse=True))


def parse_diag(s):
    """(diagonal in inches Fraction, text without it) or (None, s)."""
    m = re.search(r"(?:^|\s)(\d+(?:\.\d+)?)\s*(?:-?\s?inch(?:es)?|in\b|\"|″)", s)
    if not m:
        return None, s
    return Fraction(m.group(1)), (s[:m.start()] + " " + s[m.end():]).strip()


def fam_resolution(orig, low):
    t = low.replace("×", "x")
    t = t.replace("ultra wide", "ultrawide")
    # a ratio alone: the common resolutions of it
    m = re.fullmatch(r"(\d{1,2}):(\d{1,2})", t)
    if m:
        a, b = int(m.group(1)), int(m.group(2))
        if (a, b) not in ((16, 9), (16, 10), (4, 3), (21, 9), (32, 9), (3, 2), (5, 4)):
            return None
        hs = {(16, 9): [720, 1080, 1440, 2160], (16, 10): [800, 1200, 1600, 2400], (4, 3): [768, 1200, 1536],
              (21, 9): [1080, 1440, 2160], (32, 9): [1080, 1440, 2160], (3, 2): [1200, 1600, 2000], (5, 4): [1024, 1536],
              (1, 1): [1080, 2160], (2, 1): [1080, 1440], (9, 16): [1920]}[(a, b)]
        sizes = [(height_ratio_width(h, a, b), h) for h in hs]
        pick = sizes[1] if len(sizes) > 1 else sizes[0]
        rest = [s for s in sizes if s != pick]
        # 1080p-ish first: that is what is asked for most
        return [A("resolution", f"{pick[0]} × {pick[1]}", f"{pick[0]}x{pick[1]}", f"{a}:{b}",
                  f"common {a}:{b} resolutions · {mp(*pick)} MP",
                  [res_alt(w, h, f"{h}p") for w, h in rest])]
    diag, rest = parse_diag(t)
    # ratio + width / height
    m = re.fullmatch(rf"(\d{{1,2}})\s*:\s*(\d{{1,2}})\s+(?:(?:at|of|with)\s+)?({NUM})\s*(wide|width|w|tall|high|height|h)?", rest)
    if m and diag is None and (m.group(4) or re.search(r"\b(?:at|of|with)\b", rest)):
        a, b = int(m.group(1)), int(m.group(2))
        v = num_of(m.group(3))
        if not a or not b or v is None or v <= 0:
            return None
        tall = (m.group(4) or "w")[0] in "th"
        if tall:
            w, h = v * a / b, v
        else:
            w, h = v, v * b / a
        wv, hv = fmt(Fraction(w).limit_denominator(10 ** 6), sig=6), fmt(Fraction(h).limit_denominator(10 ** 6), sig=6)
        exact = (w == int(w) and h == int(h))
        return [A("ratio", f"{fmt(round(w))[0]} × {fmt(round(h))[0]}", f"{round(w)}x{round(h)}", f"{a}:{b} at {fmt(v)[0]} {'tall' if tall else 'wide'}",
                  "" if exact else f"exactly {wv[0]} × {hv[0]}", [])]
    # aspect of a size
    m = re.fullmatch(r"(?:aspect(?:\s+ratio)?(?:\s+of)?|ratio(?:\s+of)?)\s+(\d{2,5})\s*x\s*(\d{2,5})|(\d{2,5})\s*x\s*(\d{2,5})\s+(?:aspect(?:\s+ratio)?|ratio)", t)
    if m:
        w, h = int(m.group(1) or m.group(3)), int(m.group(2) or m.group(4))
        rt, exact = ratio_of(w, h)
        a, b = ratio_pair(w, h)
        dec = fmt(Fraction(w, h), sig=4)[0]
        name = RES_BY_SIZE.get((w, h))
        return [A("ratio", rt, rt.replace("≈ ", ""), f"{w} × {h}", "" if exact else f"reduced {a}:{b}",
                  [alt("decimal", f"{dec} : 1", dec)] + ([alt("name", name)] if name else []))]
    # NxM alone, or with a diagonal
    m = re.fullmatch(r"(\d{3,5})\s*x\s*(\d{3,5})", rest)
    if m:
        w, h = int(m.group(1)), int(m.group(2))
        return res_answer(w, h, RES_BY_SIZE.get((w, h), ""), f"{w} × {h}" + (f" on {fmt(diag)[0]}″" if diag else ""), (), diag)
    # a name or NNNNp, with an optional ratio (or "ultrawide")
    ratio = None
    r = rest
    mm = re.search(r"\b(\d{1,2}):(\d{1,2})\b", r)
    if mm:
        ratio = (int(mm.group(1)), int(mm.group(2)))
        r = r[:mm.start()] + " " + r[mm.end():]
    if "ultrawide" in r:
        ratio = ratio or (21, 9)
        r = r.replace("ultrawide", " ")
    r = re.sub(r"\s+", " ", r).strip()
    if not r:
        return None
    if r in RES:
        w, h, title = RES[r]
        extra = RES_ALTS.get(r, [])
    else:
        mp_ = re.fullmatch(r"(\d{3,4})p", r)
        if not mp_ or not 240 <= int(mp_.group(1)) <= 8640:
            return None
        h = int(mp_.group(1))
        w, title, extra = height_ratio_width(h, 16, 9), r, []
    if ratio and ratio != ratio_pair(w, h):
        w = height_ratio_width(h, *ratio)
        title, extra = f"{h}p {ratio[0]}:{ratio[1]}", []
    label = (r if r.endswith("p") and r[:-1].isdigit() else r.upper()) + (f" {ratio[0]}:{ratio[1]}" if ratio else "")
    return res_answer(w, h, title, label + (f" on {fmt(diag)[0]}″" if diag else ""), extra, diag)


def ratio_pair(w, h):
    g = math.gcd(w, h)
    return (w // g, h // g)


RES_BY_SIZE = {}
for _k, (_w, _h, _t) in RES.items():
    RES_BY_SIZE.setdefault((_w, _h), _t)
RES_BY_SIZE[(1366, 768)] = "WXGA"
RES_BY_SIZE[(2560, 1440)] = "QHD"


# ------------------------------------------------------------------------------------------------- colours
CSS = """aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff beige f5f5dc bisque ffe4c4 black 000000
blanchedalmond ffebcd blue 0000ff blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 chocolate d2691e
coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b
darkgray a9a9a9 darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b darkolivegreen 556b2f darkorange ff8c00
darkorchid 9932cc darkred 8b0000 darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f darkslategrey 2f4f4f
darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff
firebrick b22222 floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc ghostwhite f8f8ff gold ffd700 goldenrod daa520
gray 808080 grey 808080 green 008000 greenyellow adff2f honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 ivory fffff0
khaki f0e68c lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 lemonchiffon fffacd lightblue add8e6 lightcoral f08080
lightcyan e0ffff lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 lightpink ffb6c1 lightsalmon ffa07a
lightseagreen 20b2aa lightskyblue 87cefa lightslategray 778899 lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0
lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3
mediumpurple 9370db mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a mediumturquoise 48d1cc
mediumvioletred c71585 midnightblue 191970 mintcream f5fffa mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080
oldlace fdf5e6 olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 palegoldenrod eee8aa palegreen 98fb98
paleturquoise afeeee palevioletred db7093 papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd powderblue b0e0e6
purple 800080 rebeccapurple 663399 red ff0000 rosybrown bc8f8f royalblue 4169e1 saddlebrown 8b4513 salmon fa8072 sandybrown f4a460
seagreen 2e8b57 seashell fff5ee sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 slategrey 708090
snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee
wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32""".split()
CSS = dict(zip(CSS[0::2], CSS[1::2]))


def rgb_to_hsl(r, g, b):
    r, g, b = r / 255, g / 255, b / 255
    mx, mn = max(r, g, b), min(r, g, b)
    l = (mx + mn) / 2
    d = mx - mn
    if d == 0:
        return 0, 0, l
    s = d / (1 - abs(2 * l - 1))
    if mx == r:
        h = ((g - b) / d) % 6
    elif mx == g:
        h = (b - r) / d + 2
    else:
        h = (r - g) / d + 4
    return h * 60, s, l


def hsl_to_rgb(h, s, l):
    h = (h % 360) / 60
    c = (1 - abs(2 * l - 1)) * s
    x = c * (1 - abs(h % 2 - 1))
    r, g, b = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][int(h) % 6]
    m = l - c / 2
    return [round((v + m) * 255) for v in (r, g, b)]


def rgb_to_oklch(r, g, b):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = lin(r), lin(g), lin(b)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    C = math.hypot(a, bb)
    h = math.degrees(math.atan2(bb, a)) % 360 if C > 1e-4 else 0
    return L, C, h


def colour_answer(r, g, b, alpha, expr):
    hexs = "#%02x%02x%02x" % (r, g, b) + ("%02x" % round(alpha * 255) if alpha < 1 else "")
    h, s, l = rgb_to_hsl(r, g, b)
    L, C, ok = rgb_to_oklch(r, g, b)
    ap = ""
    apc = ""
    if alpha < 1:
        ap = " / %d%%" % round(alpha * 100)
        apc = ", %s" % fmt(Fraction(round(alpha * 1000), 1000))[1]
    fnr = "rgba" if alpha < 1 else "rgb"
    fnh = "hsla" if alpha < 1 else "hsl"
    hh, ss, ll = round(h) % 360, round(s * 100), round(l * 100)
    alts = [
        alt("rgb", f"{fnr}({r} {g} {b}{ap})", f"{fnr}({r}, {g}, {b}{apc})"),
        alt("hsl", f"{fnh}({hh} {ss}% {ll}%{ap})", f"{fnh}({hh}, {ss}%, {ll}%{apc})"),
        alt("oklch", f"oklch({L:.2f} {C:.3f} {ok:.0f}{ap})", f"oklch({L:.2f} {C:.3f} {ok:.0f}{ap})"),
    ]
    return [A("colour", hexs, hexs, expr, "", alts, swatch=hexs)]


def fam_colour(orig, low):
    t = low.strip()
    m = re.fullmatch(r"#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})", t)
    if m:
        h = m.group(1)
        if len(h) in (3, 4):
            h = "".join(c * 2 for c in h)
        r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
        a = int(h[6:8], 16) / 255 if len(h) == 8 else 1
        return colour_answer(r, g, b, a, t)
    m = re.fullmatch(r"rgba?\s*\(?\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*[,\s]\s*(\d{1,3})\s*(?:[,/\s]\s*(\d*\.?\d+)(%?))?\s*\)?", t)
    if m:
        r, g, b = int(m.group(1)), int(m.group(2)), int(m.group(3))
        if max(r, g, b) > 255:
            return None
        a = 1.0
        if m.group(4):
            a = float(m.group(4)) / (100 if m.group(5) else 1)
            if a > 1:
                return None
        return colour_answer(r, g, b, a, t)
    m = re.fullmatch(r"hsla?\s*\(?\s*(\d{1,3}(?:\.\d+)?)(?:deg|°)?\s*[,\s]\s*(\d{1,3}(?:\.\d+)?)%?\s*[,\s]\s*(\d{1,3}(?:\.\d+)?)%?\s*(?:[,/\s]\s*(\d*\.?\d+)(%?))?\s*\)?", t)
    if m:
        hh, ss, ll = float(m.group(1)), float(m.group(2)), float(m.group(3))
        if hh > 360 or ss > 100 or ll > 100:
            return None
        a = 1.0
        if m.group(4):
            a = float(m.group(4)) / (100 if m.group(5) else 1)
            if a > 1:
                return None
        r, g, b = hsl_to_rgb(hh, ss / 100, ll / 100)
        return colour_answer(r, g, b, a, t)
    m = re.fullmatch(r"colou?r\s+([a-z]+)", t)
    if m and m.group(1) in CSS:
        h = CSS[m.group(1)]
        return colour_answer(int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 1, m.group(1))
    return None


# ------------------------------------------------------------------------------------------------- units
Z6 = (0, 0, 0, 0, 0, 0)
L_, M_, T_, TH_, D_, AN_ = [tuple(1 if i == j else 0 for j in range(6)) for i in range(6)]


def dmul(a, b):
    return tuple(x + y for x, y in zip(a, b))


def dpow(a, n):
    return tuple(x * n for x in a)


UNITS = {}
LOWER = {}


def add(dims, factor, names, ci=True):
    f = Fraction(factor) if not isinstance(factor, str) else Fraction(factor)
    for nm in names.split():
        UNITS[nm] = (f, dims)
        if ci:
            LOWER.setdefault(nm.lower(), (f, dims))


AREA, VOL = dpow(L_, 2), dpow(L_, 3)
SPEED = dmul(L_, dpow(T_, -1))
RATE = dmul(D_, dpow(T_, -1))
ENERGY = dmul(dmul(dpow(L_, 2), M_), dpow(T_, -2))
POWER = dmul(dmul(dpow(L_, 2), M_), dpow(T_, -3))
PRESS = dmul(dmul(dpow(L_, -1), M_), dpow(T_, -2))
FORCE = dmul(dmul(L_, M_), dpow(T_, -2))
FREQ = dpow(T_, -1)
add(L_, 1, "m meter meters metre metres")
add(L_, 1000, "km kilometer kilometers kilometre kilometres")
add(L_, Fraction(1, 100), "cm centimeter centimeters centimetre centimetres")
add(L_, Fraction(1, 1000), "mm millimeter millimeters millimetre millimetres")
add(L_, Fraction(1, 10 ** 6), "um µm micron microns micrometer micrometers")
add(L_, Fraction(1, 10 ** 9), "nm nanometer nanometers")
add(L_, Fraction(1609344, 1000), "mi mile miles")
add(L_, Fraction(9144, 10000), "yd yard yards")
add(L_, Fraction(3048, 10000), "ft foot feet")
add(L_, Fraction(254, 10000), "in inch inches")
add(L_, 1852, "nmi")
add(L_, 9460730472580800, "ly lightyear lightyears")
add(L_, 149597870700, "au")
add(M_, 1, "kg kilogram kilograms kilo kilos")
add(M_, Fraction(1, 1000), "g gram grams gramme grammes")
add(M_, Fraction(1, 10 ** 6), "mg milligram milligrams")
add(M_, Fraction(1, 10 ** 9), "ug µg mcg microgram micrograms")
add(M_, 1000, "t tonne tonnes")
add(M_, Fraction(45359237, 10 ** 8), "lb lbs pound pounds")
add(M_, Fraction(28349523125, 10 ** 12), "oz ounce ounces")
add(M_, Fraction(635029318, 10 ** 8), "st stone")
add(M_, Fraction(90718474, 10 ** 8), "ton tons")
add(M_, Fraction(1, 5000), "ct carat carats")
add(SPEED, Fraction(44704, 100000), "mph")
add(SPEED, Fraction(10, 36), "kph kmh kmph")
add(SPEED, Fraction(1852, 3600), "kn knot knots kt")
add(SPEED, Fraction(34029, 100), "mach")
add(AREA, 10000, "ha hectare hectares")
add(AREA, Fraction(40468564224, 10 ** 7), "acre acres ac")
add(AREA, 1, "sqm")
add(AREA, 10 ** 6, "sqkm")
add(AREA, Fraction(9290304, 10 ** 8), "sqft")
add(AREA, Fraction(645160, 10 ** 9), "sqin")
add(AREA, Fraction(83612736, 10 ** 8), "sqyd")
add(AREA, Fraction(2589988110336, 10 ** 6), "sqmi")
add(VOL, Fraction(1, 1000), "l liter liters litre litres")
add(VOL, Fraction(1, 10 ** 6), "ml milliliter milliliters millilitre millilitres cc")
add(VOL, Fraction(1, 10 ** 5), "cl centiliter centiliters")
add(VOL, Fraction(1, 10 ** 4), "dl deciliter deciliters")
add(VOL, Fraction(3785411784, 10 ** 12), "gal gallon gallons")
add(VOL, Fraction(454609, 10 ** 8), "impgal")
add(VOL, Fraction(946352946, 10 ** 12), "qt quart quarts")
add(VOL, Fraction(473176473, 10 ** 12), "pt pint pints")
add(VOL, Fraction(2365882365, 10 ** 13), "cup cups")
add(VOL, Fraction(295735295625, 10 ** 16), "floz")
add(VOL, Fraction(147867647813, 10 ** 16), "tbsp tablespoon tablespoons")
add(VOL, Fraction(492892159375, 10 ** 17), "tsp teaspoon teaspoons")
# data: bytes first so a lowercase "mb" is megabytes; case decides the rest
for _n, _p in (("k", 3), ("M", 6), ("G", 9), ("T", 12), ("P", 15)):
    add(D_, 10 ** _p, f"{_n}B {_n}byte {_n}bytes", ci=_n != "k")
add(D_, 1, "B byte bytes")
add(D_, 1000, "kB KB kilobyte kilobytes")
add(D_, 10 ** 6, "megabyte megabytes")
add(D_, 10 ** 9, "gigabyte gigabytes")
add(D_, 10 ** 12, "terabyte terabytes")
for _n, _p in (("Ki", 10), ("Mi", 20), ("Gi", 30), ("Ti", 40), ("Pi", 50)):
    add(D_, 2 ** _p, f"{_n}B {_n}byte {_n}bytes")
LOWER["kb"] = UNITS["kB"]
LOWER["kib"] = UNITS["KiB"]
add(D_, Fraction(1, 8), "b bit bits")
for _n, _p in (("k", 3), ("K", 3), ("M", 6), ("G", 9), ("T", 12)):
    add(D_, Fraction(10 ** _p, 8), f"{_n}b {_n}bit {_n}bits", ci=False)
LOWER["kbit"] = UNITS["kbit"]
LOWER["mbit"] = UNITS["Mbit"]
LOWER["gbit"] = UNITS["Gbit"]
for _n, _p in (("Ki", 10), ("Mi", 20), ("Gi", 30)):
    add(D_, Fraction(2 ** _p, 8), f"{_n}b {_n}bit", ci=False)
add(RATE, Fraction(1, 8), "bps")
for _n, _p in (("k", 3), ("M", 6), ("G", 9), ("T", 12)):
    add(RATE, Fraction(10 ** _p, 8), f"{_n}bps {_n}bit/s {_n}b/s", ci=_n != "k")
LOWER["kbps"] = UNITS["kbps"]
add(RATE, Fraction(1000, 8), "Kbps")
add(T_, 1, "s sec secs second seconds")
add(T_, Fraction(1, 1000), "ms millisecond milliseconds")
add(T_, Fraction(1, 10 ** 6), "us µs microsecond microseconds")
add(T_, Fraction(1, 10 ** 9), "ns nanosecond nanoseconds")
add(T_, 60, "min mins minute minutes")
add(T_, 3600, "h hr hrs hour hours")
add(T_, 86400, "d day days")
add(T_, 604800, "wk wks week weeks")
add(T_, 2629800, "mo month months")
add(T_, 31557600, "y yr yrs year years")
add(ENERGY, 1, "J joule joules")
add(ENERGY, 1000, "kJ kilojoule kilojoules")
add(ENERGY, 10 ** 6, "MJ megajoule megajoules")
add(ENERGY, Fraction(4184, 1000), "cal")
add(ENERGY, 4184, "kcal Cal calorie calories")
add(ENERGY, 3600, "Wh")
add(ENERGY, 3600000, "kWh")
add(ENERGY, 3600000000, "MWh")
add(ENERGY, Fraction(105505585262, 10 ** 8), "btu")
add(ENERGY, Fraction(1602176634, 10 ** 28), "ev")
add(POWER, 1, "W watt watts")
add(POWER, 1000, "kW kilowatt kilowatts")
add(POWER, 10 ** 6, "MW megawatt megawatts", ci=False)
add(POWER, Fraction(1, 1000), "mW milliwatt milliwatts", ci=False)
add(POWER, Fraction(745699871582270, 10 ** 12), "hp horsepower bhp")
add(POWER, Fraction(73549875, 100000), "ps")
add(PRESS, 1, "Pa pascal pascals")
add(PRESS, 1000, "kPa kilopascal")
add(PRESS, 100, "hPa")
add(PRESS, 10 ** 6, "MPa", ci=False)
add(PRESS, 100000, "bar")
add(PRESS, 100, "mbar")
add(PRESS, Fraction(6894757293168, 10 ** 9), "psi")
add(PRESS, 101325, "atm")
add(PRESS, Fraction(101325, 760), "mmhg")
add(PRESS, Fraction(101325, 760), "torr")
add(PRESS, Fraction(3386389, 1000), "inhg")
add(FORCE, 1, "N newton newtons")
add(FORCE, Fraction(44482216152605, 10 ** 13), "lbf")
add(FORCE, Fraction(980665, 100000), "kgf")
add(FREQ, 1, "Hz hertz")
add(FREQ, 1000, "kHz")
add(FREQ, 10 ** 6, "MHz", ci=False)
add(FREQ, 10 ** 9, "GHz")
add(AN_, 1, "rad radian radians")
add(AN_, Fraction(31415926535897932, 10 ** 16 * 180), "deg degree degrees")
add(AN_, Fraction(31415926535897932, 10 ** 16 * 200), "grad")

PREFIXED = {"sq": 2, "square": 2, "cubic": 3}
TEMPS = {"c": "c", "celsius": "c", "centigrade": "c", "f": "f", "fahrenheit": "f", "k": "k", "kelvin": "k"}
ALTS = {
    L_: ["m", "cm", "ft", "in", "km", "mi", "mm"], M_: ["kg", "g", "lb", "oz"], SPEED: ["km/h", "mph", "m/s", "kn"],
    AREA: ["m2", "ft2", "acre", "ha", "km2"], VOL: ["l", "ml", "gal", "floz", "cup", "m3"],
    D_: ["MB", "GB", "MiB", "GiB", "Mb", "Gb"], RATE: ["Mbps", "MB/s", "Gbps", "kB/s"], T_: ["s", "min", "h", "d", "wk"],
    ENERGY: ["J", "kJ", "kcal", "kWh", "Wh", "btu"], POWER: ["W", "kW", "hp"], PRESS: ["Pa", "kPa", "bar", "psi", "atm"],
    FORCE: ["N", "lbf", "kgf"], FREQ: ["Hz", "kHz", "MHz"], AN_: ["deg", "rad"],
}


def disp(label):
    return re.sub(r"(?<=[a-z])([23])$", lambda m: "²³"[int(m.group(1)) - 2], label)


def lookup_unit(t):
    if t in UNITS:
        return UNITS[t]
    lw = t.lower()
    if lw in LOWER:
        return LOWER[lw]
    if lw.endswith("s") and lw[:-1] in LOWER:
        return LOWER[lw[:-1]]
    return None


def parse_unit(t, depth=0):
    """(factor, dims) of a unit text (case matters for data units), or None."""
    t = t.strip().rstrip(".").strip()
    if not t or depth > 2:
        return None
    t = t.replace("·", "*").replace(" per ", "/")
    if "/" in t:
        a, b = t.split("/", 1)
        ua = parse_unit(a, depth + 1) if a.strip() else (Fraction(1), Z6)
        ub = parse_unit(b, depth + 1)
        if ua is None or ub is None:
            return None
        return ua[0] / ub[0], dmul(ua[1], dpow(ub[1], -1))
    if "*" in t:
        f, d = Fraction(1), Z6
        for part in t.split("*"):
            u = parse_unit(part, depth + 1)
            if u is None:
                return None
            f, d = f * u[0], dmul(d, u[1])
        return f, d
    if " " in t:
        w = t.split(" ", 1)
        if w[0].lower() in PREFIXED:
            u = parse_unit(w[1], depth + 1)
            if u and u[1] == L_:
                n = PREFIXED[w[0].lower()]
                return u[0] ** n, dpow(L_, n)
            return None
        k = t.lower().replace("fluid ounce", "floz").replace("fl oz", "floz").replace("us gal", "gal").replace("uk gal", "impgal").replace("imp gal", "impgal").replace("nautical mile", "nmi").replace("light year", "lightyear").replace("us gallon", "gal")
        k = k.replace(" ", "")
        if k != t.lower().replace(" ", "") or k in LOWER or k in UNITS:
            return lookup_unit(k)
        return None
    u = lookup_unit(t)
    if u:
        return u
    m = re.fullmatch(r"(.+?)\^?([23])", t)
    if m:
        b = lookup_unit(m.group(1))
        if b and b[1] == L_:
            n = int(m.group(2))
            return b[0] ** n, dpow(L_, n)
    m = re.fullmatch(r"(sq|square|cubic)\.?(.+)", t, re.I)
    if m:
        b = lookup_unit(m.group(2).strip())
        if b and b[1] == L_:
            n = PREFIXED[m.group(1).lower()]
            return b[0] ** n, dpow(L_, n)
    return None


def temp_code(t):
    t = re.sub(r"[°\s]|degrees?|deg", "", t.strip().lower())
    return TEMPS.get(t)


K273 = Fraction("273.15")


def to_kelvin(v, c):
    return v + K273 if c == "c" else (v - 32) * 5 / 9 + K273 if c == "f" else v


def from_kelvin(k, c):
    return k - K273 if c == "c" else (k - K273) * 9 / 5 + 32 if c == "f" else k


TNAME = {"c": "°C", "f": "°F", "k": "K"}


def split_conv(s):
    s = s.replace("→", " to ").replace("->", " to ")
    m = re.fullmatch(r"(.+)\s(?:in|to|as|into)\s(.+)", re.sub(r"\s+", " ", s))
    return (m.group(1), m.group(2)) if m else (None, None)


def source_amount(src):
    """(amount Fraction, unit text) from '5 ft', '5ft', '5\'11"', 'km' (amount 1)."""
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*(?:'|′|ft|feet|foot)\s*(\d+(?:\.\d+)?)\s*(?:\"|″|in|inch|inches)?", src.strip())
    if m:
        return Fraction(m.group(1)) * 12 + Fraction(m.group(2)), "in"
    s = src.strip()
    if s[:1] in "+-" or s[:1] in DIG or (s[:1] == "." and len(s) > 1 and s[1] in DIG):
        sign = 1
        if s[0] in "+-":
            sign = -1 if s[0] == "-" else 1
            s = s[1:].strip()
        if not s or s[0] not in DIG + ".":
            return None
        try:
            v, j, b = scan_number(s, 0)
        except Bad:
            return None
        if b != 10:
            return None
        rest = s[j:].strip()
        rest = rest.replace("\"", "in").replace("″", "in").replace("'", "ft").replace("′", "ft") if rest in ('"', "'", "″", "′") else rest
        return sign * v, rest
    return Fraction(1), s


def fam_unit(orig, low):
    src, dst = split_conv(orig)
    if src is None:
        return None
    sa = source_amount(src)
    if sa is None:
        return None
    amt, su = sa
    if not su:
        return None
    dst = dst.strip()
    # fuel economy
    fs, fd = su.lower().replace(" ", ""), dst.lower().replace(" ", "")
    if {fs, fd} == {"mpg", "l/100km"}:
        if amt == 0:
            return None
        r = Fraction("235.214583") / amt
        shown, plain = fmt(r, sig=6)
        lab = "l/100km" if fd == "l/100km" else "mpg"
        return [A("unit", f"{shown} {lab}", plain, f"{fmt(amt)[0]} {fs} → {lab}", "", [])]
    ts, td = temp_code(su), temp_code(dst)
    if ts and td:
        k = to_kelvin(amt, ts)
        if k < 0:
            return None
        r = from_kelvin(k, td)
        shown, plain = fmt(r, sig=12)
        alts = [alt(TNAME[c], fmt(from_kelvin(k, c), sig=6)[0] + " " + TNAME[c], fmt(from_kelvin(k, c), sig=6)[1]) for c in "cfk" if c not in (ts, td)]
        return [A("unit", f"{shown} {TNAME[td]}", plain, f"{fmt(amt)[0]} {TNAME[ts]} → {TNAME[td]}", "", alts)]
    us, ud = parse_unit(su), parse_unit(dst)
    if us is None or ud is None or us[1] != ud[1] or us[1] == Z6:
        return None
    r = amt * us[0] / ud[0]
    shown, plain = fmt(r)
    dl = disp(dst)
    detail = f"1 {disp(su)} = {fmt(us[0] / ud[0], sig=6)[0]} {dl}" if amt != 1 else ""
    alts = []
    for lab in ALTS.get(us[1], []):
        u = parse_unit(lab)
        if u is None or u[0] in (us[0], ud[0]):
            continue
        alts.append(alt(disp(lab), f"{fmt(amt * us[0] / u[0], sig=6)[0]} {disp(lab)}", fmt(amt * us[0] / u[0], sig=6)[1]))
        if len(alts) == 3:
            break
    return [A("unit", f"{shown} {dl}", plain, f"{fmt(amt)[0]} {disp(su)} → {dl}", detail, alts)]


# ------------------------------------------------------------------------------------------------- time arithmetic
TUNIT = {"h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600, "m": 60, "min": 60, "mins": 60, "minute": 60,
         "minutes": 60, "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1, "d": 86400, "day": 86400, "days": 86400,
         "w": 604800, "wk": 604800, "week": 604800, "weeks": 604800}
SURE = {"h", "hr", "hrs", "hour", "hours", "min", "mins", "minute", "minutes", "sec", "secs", "second", "seconds"}
TARGET = {"s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1, "min": 60, "mins": 60, "minute": 60, "minutes": 60, "m": 60,
          "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600, "d": 86400, "day": 86400, "days": 86400,
          "w": 604800, "wk": 604800, "week": 604800, "weeks": 604800, "ms": Fraction(1, 1000), "h:mm": "hm"}
UNIT_RE = r"(?:hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s|days?|d|weeks?|wks?|w)(?![a-z])"
DURATION_RE = re.compile(rf"(?:\d+(?:\.\d+)?\s*{UNIT_RE}\s*)+")
ONE_RE = re.compile(rf"(\d+(?:\.\d+)?)\s*({UNIT_RE})")
CLOCK_RE = re.compile(r"(\d+):(\d{2})(?::(\d{2}))?(?![\d:])")


def lex_time(s):
    toks = []
    i, n = 0, len(s)
    sure = False
    barem = False
    while i < n:
        c = s[i]
        if c == " ":
            i += 1
            continue
        m = CLOCK_RE.match(s, i)
        if m:
            sec = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3) or 0)
            toks.append(("d", Fraction(sec), m.group(0)))
            sure = True
            i = m.end()
            continue
        m = DURATION_RE.match(s, i)
        if m:
            tot = Fraction(0)
            for u in ONE_RE.finditer(m.group(0)):
                tot += Fraction(u.group(1)) * TUNIT[u.group(2)]
                if u.group(2) in SURE:
                    sure = True
                if u.group(2) == "m":
                    barem = True
            toks.append(("d", tot, m.group(0).strip()))
            i = m.end()
            continue
        if c in DIG or (c == "." and i + 1 < n and s[i + 1] in DIG):
            v, j, b = scan_number(s, i)
            if b != 10:
                raise Bad()
            toks.append(("n", v, s[i:j], 10))
            i = j
        elif c in "+-*/()":
            toks.append(("o", c))
            i += 1
        elif c in "x×÷":
            toks.append(("o", "*" if c != "÷" else "/"))
            i += 1
        else:
            raise Bad()
    return toks, sure, barem


def fmt_hms(sec):
    neg = sec < 0
    sec = abs(sec)
    if sec.denominator != 1:
        return None
    sec = int(sec)
    h, r = divmod(sec, 3600)
    m, s = divmod(r, 60)
    parts = []
    if h:
        parts.append(f"{h}h")
    if m:
        parts.append(f"{m}m")
    if s:
        parts.append(f"{s}s")
    if not parts:
        parts = ["0m"]
    return ("-" if neg else "") + " ".join(parts)


def fmt_clock(sec):
    neg = sec < 0
    sec = abs(sec)
    total = int(sec)
    h, r = divmod(total, 3600)
    m, s = divmod(r, 60)
    return ("-" if neg else "") + (f"{h}:{m:02d}:{s:02d}" if s else f"{h}:{m:02d}")


def fam_timearith(orig, low):
    if not re.search(r"\d", low):
        return None
    m = re.fullmatch(r"(.+?)\s+(?:in|to|as)\s+(h:mm|[a-z]+)", low)
    target = None
    body = low
    if m and m.group(2) in TARGET:
        body, target = m.group(1), m.group(2)
    try:
        toks, sure, barem = lex_time(body)
    except Bad:
        return None
    if not any(t[0] == "d" for t in toks):
        return None
    if not sure and not barem and not (target):
        return None
    if not sure and barem and not any(t[0] == "o" for t in toks) and not target:
        return None
    ptoks = toks
    v, p = (None, None)
    try:
        v, p = run_parser(ptoks)
    except Bad:
        return None
    if p.ops == 0 and target is None:
        return None
    if not isinstance(v, Dur):
        return None
    expr = render_expr(ptoks) + (f" → {target}" if target else "")
    sec = v.s
    if target:
        unit = TARGET[target]
        if unit == "hm":
            return [A("time", fmt_clock(sec), fmt_clock(sec), expr, "", [])]
        r = sec / Fraction(unit)
        shown, plain = fmt(r)
        return [A("time", f"{shown} {target}", plain, expr, "", [alt("h:mm", fmt_clock(sec))])]
    hm = fmt_hms(sec)
    if hm is None:
        return None
    alts = [alt("h:mm", fmt_clock(sec)),
            alt("", fmt(sec / 3600, sig=6)[0] + " h", fmt(sec / 3600, sig=6)[1]),
            alt("", fmt(sec / 60, sig=6)[0] + " min", fmt(sec / 60, sig=6)[1])]
    return [A("time", hm, hm, expr, "", alts)]


# ------------------------------------------------------------------------------------------------- currency
ECB_URL = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"
CODES = set("USD EUR JPY BGN CZK DKK GBP HUF PLN RON SEK CHF ISK NOK TRY AUD BRL CAD CNY HKD IDR ILS INR KRW MXN MYR NZD PHP SGD THB ZAR".split())
SYMS = {"$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY", "₹": "INR", "₩": "KRW", "₺": "TRY", "zł": "PLN", "r$": "BRL",
        "₪": "ILS", "฿": "THB", "us$": "USD", "a$": "AUD", "c$": "CAD", "nz$": "NZD", "hk$": "HKD", "s$": "SGD", "chf": "CHF"}
CNAMES = {"dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD", "euro": "EUR", "euros": "EUR", "yen": "JPY",
          "sterling": "GBP", "quid": "GBP", "pound sterling": "GBP", "pounds sterling": "GBP", "franc": "CHF", "francs": "CHF",
          "rupee": "INR", "rupees": "INR", "yuan": "CNY", "renminbi": "CNY", "won": "KRW", "zloty": "PLN"}
CDEC = {"JPY": 0, "KRW": 0, "IDR": 0}
STALE_S = float(os.environ.get("LARES_ECB_STALE_S", 12 * 3600))
RETRY_S = 300


def cur_code(t):
    t = t.strip().lower()
    if t in SYMS:
        return SYMS[t]
    if t in CNAMES:
        return CNAMES[t]
    if re.fullmatch(r"[a-z]{3}", t) and t.upper() in CODES:
        return t.upper()
    return None


CURTOK = r"(?:[$€£¥₹₩₺₪฿]|zł|r\$|us\$|a\$|c\$|nz\$|hk\$|s\$|[a-z]{3,16}(?: sterling)?)"
SUFFIX = {"k": 1000, "m": 10 ** 6, "bn": 10 ** 9, "b": 10 ** 9}


def parse_currency(low):
    """{amount, src, dst} or None, from the typed text alone (no rates needed)."""
    SEP = r"(?:in|to|into|as|->|→)"
    m = re.fullmatch(rf"([$€£¥₹₩₺₪฿]|us\$|a\$|c\$|nz\$|hk\$|s\$|r\$)\s*({NUM})\s*(k|m|bn)?\s*(?:{SEP}\s*({CURTOK}))?", low)
    if m:
        src, amt, suf, dst = cur_code(m.group(1)), num_of(m.group(2)), m.group(3), m.group(4)
        if amt is None:
            return None
    else:
        m = re.fullmatch(rf"({NUM})\s*(k|m|bn)?\s*({CURTOK})\s*(?:{SEP}\s*({CURTOK}))?", low)
        if m:
            amt, suf, src, dst = num_of(m.group(1)), m.group(2), cur_code(m.group(3)), m.group(4)
            if amt is None:
                return None
        else:
            m = re.fullmatch(rf"([a-z]{{3}})\s+{SEP}\s+({CURTOK})", low)
            if not m:
                return None
            amt, suf, src, dst = None, None, cur_code(m.group(1)), m.group(2)
    if src is None:
        return None
    if dst is not None:
        dst = cur_code(dst)
        if dst is None:
            return None
    if amt is not None and suf:
        amt *= SUFFIX[suf]
    return {"amount": amt, "src": src, "dst": dst}


class RateStore:
    def __init__(self):
        self.lock = threading.Lock()
        self.rates = None
        self.date = ""
        self.fetched = 0.0
        self.loaded_cache = False
        self.inflight = False
        self.failed_at = 0.0
        self.fail_reason = ""
        self.waiting = None

    @staticmethod
    def path():
        base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
        return os.path.join(base, "lares", "launcher", "ecb-rates.json")

    def load_cache(self):
        if self.loaded_cache:
            return
        self.loaded_cache = True
        try:
            with open(self.path(), encoding="utf-8") as f:
                j = json.load(f)
            rates = {k: Fraction(str(v)) for k, v in j["rates"].items()}
            if len(rates) >= 5:
                self.rates, self.date, self.fetched = rates, str(j.get("date", "")), float(j.get("fetched", 0))
        except (OSError, ValueError, KeyError, TypeError, ArithmeticError):
            pass

    def fresh(self):
        return self.rates is not None and time.time() - self.fetched < STALE_S

    def want_fetch(self):
        """Start a fetch when one is due and none runs; True when a fetch is (now) in flight."""
        with self.lock:
            if self.fresh():
                return False
            if self.inflight:
                return True
            if time.time() - self.failed_at < RETRY_S and self.failed_at:
                return False
            self.inflight = True
        threading.Thread(target=self._fetch, daemon=True).start()
        return True

    def _fetch(self):
        ok = False
        try:
            import urllib.request
            url = os.environ.get("LARES_ECB_URL", ECB_URL)
            req = urllib.request.Request(url, headers={"User-Agent": "lares-launcher/0.1"})
            with urllib.request.urlopen(req, timeout=5) as r:
                data = r.read(1 << 20).decode("utf-8", "replace")
            d = re.search(r"time=['\"](\d{4}-\d{2}-\d{2})['\"]", data)
            pairs = re.findall(r"currency=['\"]([A-Z]{3})['\"]\s+rate=['\"]([0-9.]+)['\"]", data)
            if not d or len(pairs) < 5:
                raise ValueError("unexpected ECB document")
            raw = dict(pairs)
            rates = {k: Fraction(v) for k, v in raw.items()}
            now = time.time()
            p = self.path()
            os.makedirs(os.path.dirname(p), exist_ok=True)
            tmp = p + f".{os.getpid()}.tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"date": d.group(1), "fetched": now, "rates": raw}, f)
            os.replace(tmp, p)
            with self.lock:
                self.rates, self.date, self.fetched, self.failed_at = rates, d.group(1), now, 0.0
            ok = True
        except Exception as e:  # network, parse, disk: all just "no fresh rates"
            with self.lock:
                self.failed_at = time.time()
                self.fail_reason = type(e).__name__
            warn(f"ecb fetch failed: {type(e).__name__}: {e}")
        finally:
            with self.lock:
                self.inflight = False
            on_rates_done(ok)


STORE = RateStore()


def cur_fmt(r, code, sig5=False):
    if sig5:
        return fmt(r, sig=5)
    if r != 0 and abs(r) < 1:
        return fmt(r, sig=4)
    return fmt_dec(r, CDEC.get(code, 2))


def fam_currency(orig, low):
    parsed = parse_currency(low)
    if parsed is None:
        return None
    src, dst, amt = parsed["src"], parsed["dst"], parsed["amount"]
    if dst is None:
        dst = HOME_CUR if src != HOME_CUR else next((c for c in CURRENCIES if c != src), None)
        if dst is None:
            return None
    if src == dst:
        return None
    STORE.load_cache()
    pending = STORE.want_fetch()
    rate_query = amt is None
    a = Fraction(1) if rate_query else amt
    expr = f"{fmt(a)[0] if not rate_query else '1'} {src} → {dst}"
    r = STORE.rates
    if r is None:
        if pending:
            return [A("currency", "…", "", expr, "fetching ECB rates…", [], pending=True)]
        return [A("currency", "rates unavailable", "", expr, "the ECB rates could not be fetched and none are cached", [])]
    if (src != "EUR" and src not in r) or (dst != "EUR" and dst not in r):
        return None
    rs = Fraction(1) if src == "EUR" else r[src]
    rd = Fraction(1) if dst == "EUR" else r[dst]
    res = a / rs * rd
    shown, plain = cur_fmt(res, dst, rate_query)
    stale = not STORE.fresh()
    det = f"ECB {STORE.date} · 1 {src} = {fmt(rd / rs, sig=5)[0]} {dst}"
    if stale and not pending:
        det += " (offline, last known)"
    alts = []
    for other in ([HOME_CUR] if HOME_CUR not in (src, dst) else []) + CURRENCIES:
        if other in (src, dst) or other in [x["label"] for x in alts] or (other != "EUR" and other not in r):
            continue
        ro = Fraction(1) if other == "EUR" else r[other]
        s2, p2 = cur_fmt(a / rs * ro, other, rate_query)
        alts.append(alt(other, f"{s2} {other}", p2))
        if len(alts) == 2:
            break
    return [A("currency", f"{shown} {dst}", plain, expr, det, alts, pending=pending)]


# ------------------------------------------------------------------------------------------------- stdout
OUT_LOCK = threading.Lock()
LATEST = {"id": -1}


def warn(msg):
    try:
        sys.stderr.write("lares-answers: " + msg.replace("\n", " ")[:300] + "\n")
        sys.stderr.flush()
    except Exception:
        pass


def send(obj):
    line = json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n"
    with OUT_LOCK:
        sys.stdout.buffer.write(line.encode("utf-8"))
        sys.stdout.buffer.flush()


def on_rates_done(ok):
    """A fetch ended: the newest waiting currency query gets its second reply, if it is still the latest."""
    w = STORE.waiting
    STORE.waiting = None
    if w is None or w[0] != LATEST["id"]:
        return
    try:
        send({"id": w[0], "answers": answers_for(w[1])})
    except Exception as e:
        warn(f"update failed: {e}")


# ------------------------------------------------------------------------------------------------- dates and zones
MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
MONTHNAMES = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
DAYNAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MONTH_RE = "(?:" + "|".join(sorted(MONTHNAMES + MONTHS + ["sept"], key=len, reverse=True)) + ")"
HOLIDAYS = {"christmas": (12, 25), "xmas": (12, 25), "new year": (1, 1), "new years": (1, 1), "new year's": (1, 1),
            "new years day": (1, 1), "halloween": (10, 31), "valentines": (2, 14), "valentine's day": (2, 14),
            "new years eve": (12, 31), "christmas eve": (12, 24)}


def month_num(w):
    w = w[:3]
    return MONTHS.index(w) + 1


_ZONES = {}


def home_zone():
    if "home" in _ZONES:
        return _ZONES["home"]
    from zoneinfo import ZoneInfo
    z = None
    for cand in (os.environ.get("LARES_ANSWERS_TZ"), os.environ.get("TZ")):
        if cand:
            try:
                z = ZoneInfo(cand.lstrip(":"))
                break
            except Exception:
                pass
    if z is None:
        try:
            tgt = os.path.realpath("/etc/localtime")
            if "zoneinfo/" in tgt:
                z = ZoneInfo(tgt.split("zoneinfo/", 1)[1])
        except Exception:
            z = None
    if z is None:
        z = ZoneInfo("UTC")
    _ZONES["home"] = z
    return z


def home_label():
    """The home zone as a place, the way the user names it: Europe/Brussels -> Brussels (UTC stays UTC)."""
    k = getattr(home_zone(), "key", "") or "UTC"
    return k.rsplit("/", 1)[-1].replace("_", " ")


def now_utc():
    s = os.environ.get("LARES_ANSWERS_NOW")
    if s:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    return dt.datetime.now(dt.timezone.utc)


def today():
    return now_utc().astimezone(home_zone()).date()


ABBR = {"utc": "UTC", "gmt": "UTC", "z": "UTC", "zulu": "UTC", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles",
        "pt": "America/Los_Angeles", "est": "America/New_York", "edt": "America/New_York", "et": "America/New_York",
        "cst": "America/Chicago", "cdt": "America/Chicago", "ct": "America/Chicago", "mst": "America/Denver",
        "mdt": "America/Denver", "mt": "America/Denver", "akst": "America/Anchorage", "akdt": "America/Anchorage",
        "hst": "Pacific/Honolulu", "cet": "Europe/Brussels", "cest": "Europe/Brussels", "eet": "Europe/Athens",
        "eest": "Europe/Athens", "wet": "Europe/Lisbon", "west": "Europe/Lisbon", "bst": "Europe/London",
        "msk": "Europe/Moscow", "ist": "Asia/Kolkata", "jst": "Asia/Tokyo", "kst": "Asia/Seoul", "sgt": "Asia/Singapore",
        "hkt": "Asia/Hong_Kong", "aest": "Australia/Sydney", "aedt": "Australia/Sydney", "acst": "Australia/Adelaide",
        "awst": "Australia/Perth", "nzst": "Pacific/Auckland", "nzdt": "Pacific/Auckland", "sast": "Africa/Johannesburg",
        "brt": "America/Sao_Paulo", "pkt": "Asia/Karachi", "ict": "Asia/Bangkok", "wib": "Asia/Jakarta"}
ALIAS = {
    "new york": "America/New_York", "nyc": "America/New_York", "new york city": "America/New_York", "boston": "America/New_York",
    "washington": "America/New_York", "washington dc": "America/New_York", "dc": "America/New_York", "miami": "America/New_York",
    "atlanta": "America/New_York", "philadelphia": "America/New_York", "toronto": "America/Toronto", "montreal": "America/Toronto",
    "ottawa": "America/Toronto", "detroit": "America/Detroit", "los angeles": "America/Los_Angeles", "la": "America/Los_Angeles",
    "san francisco": "America/Los_Angeles", "sf": "America/Los_Angeles", "seattle": "America/Los_Angeles",
    "portland": "America/Los_Angeles", "san diego": "America/Los_Angeles", "las vegas": "America/Los_Angeles",
    "silicon valley": "America/Los_Angeles", "vancouver": "America/Vancouver", "chicago": "America/Chicago",
    "houston": "America/Chicago", "dallas": "America/Chicago", "austin": "America/Chicago", "mexico city": "America/Mexico_City",
    "denver": "America/Denver", "phoenix": "America/Phoenix", "salt lake city": "America/Denver", "honolulu": "Pacific/Honolulu",
    "hawaii": "Pacific/Honolulu", "anchorage": "America/Anchorage", "alaska": "America/Anchorage", "havana": "America/Havana",
    "bogota": "America/Bogota", "lima": "America/Lima", "santiago": "America/Santiago", "caracas": "America/Caracas",
    "buenos aires": "America/Argentina/Buenos_Aires", "sao paulo": "America/Sao_Paulo", "são paulo": "America/Sao_Paulo",
    "rio": "America/Sao_Paulo", "rio de janeiro": "America/Sao_Paulo", "brasilia": "America/Sao_Paulo",
    "london": "Europe/London", "edinburgh": "Europe/London", "manchester": "Europe/London", "glasgow": "Europe/London",
    "dublin": "Europe/Dublin", "lisbon": "Europe/Lisbon", "madrid": "Europe/Madrid", "barcelona": "Europe/Madrid",
    "paris": "Europe/Paris", "lyon": "Europe/Paris", "marseille": "Europe/Paris", "brussels": "Europe/Brussels",
    "antwerp": "Europe/Brussels", "ghent": "Europe/Brussels", "bruges": "Europe/Brussels", "amsterdam": "Europe/Amsterdam",
    "rotterdam": "Europe/Amsterdam", "the hague": "Europe/Amsterdam", "luxembourg": "Europe/Luxembourg", "berlin": "Europe/Berlin",
    "munich": "Europe/Berlin", "hamburg": "Europe/Berlin", "frankfurt": "Europe/Berlin", "cologne": "Europe/Berlin",
    "zurich": "Europe/Zurich", "geneva": "Europe/Zurich", "bern": "Europe/Zurich", "vienna": "Europe/Vienna",
    "prague": "Europe/Prague", "budapest": "Europe/Budapest", "warsaw": "Europe/Warsaw", "rome": "Europe/Rome",
    "milan": "Europe/Rome", "copenhagen": "Europe/Copenhagen", "stockholm": "Europe/Stockholm", "oslo": "Europe/Oslo",
    "helsinki": "Europe/Helsinki", "reykjavik": "Atlantic/Reykjavik", "athens": "Europe/Athens", "bucharest": "Europe/Bucharest",
    "sofia": "Europe/Sofia", "belgrade": "Europe/Belgrade", "zagreb": "Europe/Zagreb", "kyiv": "Europe/Kyiv",
    "kiev": "Europe/Kyiv", "istanbul": "Europe/Istanbul", "moscow": "Europe/Moscow", "st petersburg": "Europe/Moscow",
    "cairo": "Africa/Cairo", "johannesburg": "Africa/Johannesburg", "cape town": "Africa/Johannesburg", "lagos": "Africa/Lagos",
    "nairobi": "Africa/Nairobi", "casablanca": "Africa/Casablanca", "dubai": "Asia/Dubai", "abu dhabi": "Asia/Dubai",
    "riyadh": "Asia/Riyadh", "doha": "Asia/Qatar", "tehran": "Asia/Tehran", "tel aviv": "Asia/Jerusalem",
    "jerusalem": "Asia/Jerusalem", "karachi": "Asia/Karachi", "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata",
    "new delhi": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata", "chennai": "Asia/Kolkata",
    "hyderabad": "Asia/Kolkata", "kolkata": "Asia/Kolkata", "calcutta": "Asia/Kolkata", "dhaka": "Asia/Dhaka",
    "kathmandu": "Asia/Kathmandu", "colombo": "Asia/Colombo", "bangkok": "Asia/Bangkok", "hanoi": "Asia/Bangkok",
    "saigon": "Asia/Ho_Chi_Minh", "ho chi minh": "Asia/Ho_Chi_Minh", "jakarta": "Asia/Jakarta", "manila": "Asia/Manila",
    "singapore": "Asia/Singapore", "kuala lumpur": "Asia/Kuala_Lumpur", "beijing": "Asia/Shanghai", "shanghai": "Asia/Shanghai",
    "shenzhen": "Asia/Shanghai", "guangzhou": "Asia/Shanghai", "chengdu": "Asia/Shanghai", "hong kong": "Asia/Hong_Kong",
    "taipei": "Asia/Taipei", "seoul": "Asia/Seoul", "tokyo": "Asia/Tokyo", "osaka": "Asia/Tokyo", "kyoto": "Asia/Tokyo",
    "sydney": "Australia/Sydney", "melbourne": "Australia/Melbourne", "brisbane": "Australia/Brisbane", "perth": "Australia/Perth",
    "adelaide": "Australia/Adelaide", "canberra": "Australia/Sydney", "auckland": "Pacific/Auckland", "wellington": "Pacific/Auckland",
    "japan": "Asia/Tokyo", "china": "Asia/Shanghai", "india": "Asia/Kolkata", "korea": "Asia/Seoul", "uk": "Europe/London",
    "britain": "Europe/London", "england": "Europe/London", "france": "Europe/Paris", "germany": "Europe/Berlin",
    "spain": "Europe/Madrid", "italy": "Europe/Rome", "netherlands": "Europe/Amsterdam", "belgium": "Europe/Brussels",
    "switzerland": "Europe/Zurich", "ireland": "Europe/Dublin", "portugal": "Europe/Lisbon", "poland": "Europe/Warsaw",
    "turkey": "Europe/Istanbul", "egypt": "Africa/Cairo", "uae": "Asia/Dubai", "russia": "Europe/Moscow",
    "brazil": "America/Sao_Paulo", "argentina": "America/Argentina/Buenos_Aires", "mexico": "America/Mexico_City",
    "thailand": "Asia/Bangkok", "vietnam": "Asia/Ho_Chi_Minh", "indonesia": "Asia/Jakarta", "israel": "Asia/Jerusalem",
    "new zealand": "Pacific/Auckland", "south africa": "Africa/Johannesburg", "sweden": "Europe/Stockholm",
    "norway": "Europe/Oslo", "denmark": "Europe/Copenhagen", "finland": "Europe/Helsinki", "greece": "Europe/Athens",
    "austria": "Europe/Vienna", "czechia": "Europe/Prague",
}
_CITY = {}


def city_table():
    if _CITY:
        return _CITY
    paths = ["/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"]
    try:
        import zoneinfo
        paths = [os.path.join(p, "zone1970.tab") for p in zoneinfo.TZPATH] + paths
    except Exception:
        pass
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                for line in f:
                    if line.startswith("#") or not line.strip():
                        continue
                    cols = line.rstrip("\n").split("\t")
                    if len(cols) >= 3:
                        name = cols[2]
                        city = name.rsplit("/", 1)[-1].replace("_", " ").lower()
                        _CITY.setdefault(city, name)
            break
        except OSError:
            continue
    for k, v in ALIAS.items():
        _CITY.setdefault(k, v)
    return _CITY


def resolve_zone(text):
    """(tzinfo, label) for a city, an alias, an abbreviation or utc+5:30; or None."""
    from zoneinfo import ZoneInfo
    t = re.sub(r"\s+", " ", text.strip().lower())
    t = re.sub(r"^(?:in|at|the)\s+", "", t)
    if not t:
        return None
    try:
        m = re.fullmatch(r"(?:utc|gmt)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?", t)
        if m:
            off = int(m.group(2)) * 60 + int(m.group(3) or 0)
            if off > 14 * 60:
                return None
            off = -off if m.group(1) == "-" else off
            lab = f"UTC{m.group(1)}{int(m.group(2))}" + (f":{m.group(3)}" if m.group(3) else "")
            return dt.timezone(dt.timedelta(minutes=off)), lab
        if t in ABBR:
            return ZoneInfo(ABBR[t]), t.upper()
        name = city_table().get(t)
        if name is None and "/" in t:
            name = t.title().replace(" ", "_")
        if name is None:
            return None
        return ZoneInfo(name), (t.upper() if len(t) <= 3 else " ".join(w.capitalize() for w in t.split("/")[-1].replace("_", " ").split()))
    except Exception:
        return None


def fmt_date(d):
    return f"{DAYS[d.weekday()]} {d.day} {MONTHS[d.month - 1].capitalize()} {d.year}"


def plural(n, w):
    return f"{n} {w}" + ("" if n in (1, -1) else "s")


def add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    y += d.year
    m += 1
    for day in range(d.day, 0, -1):
        try:
            return dt.date(y, m, day)
        except ValueError:
            continue
    raise Bad()


def parse_date(s):
    """(year or None, month, day) / a date for relative words, or None."""
    s = s.strip()
    t = today()
    if s in ("today", "now"):
        return t
    if s == "tomorrow":
        return t + dt.timedelta(days=1)
    if s == "yesterday":
        return t - dt.timedelta(days=1)
    if s in HOLIDAYS:
        mo, d = HOLIDAYS[s]
        return (None, mo, d)
    m = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})", s)
    if m:
        try:
            return dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            return None
    m = re.fullmatch(r"(\d{1,2})\.(\d{1,2})\.(\d{4})", s)
    if m:
        try:
            return dt.date(int(m.group(3)), int(m.group(2)), int(m.group(1)))
        except ValueError:
            return None
    m = re.fullmatch(rf"(\d{{1,2}})(?:st|nd|rd|th)?\s+({MONTH_RE})\.?(?:,?\s+(\d{{4}}))?", s)
    if m:
        return (int(m.group(3)) if m.group(3) else None, month_num(m.group(2)), int(m.group(1)))
    m = re.fullmatch(rf"({MONTH_RE})\.?\s+(\d{{1,2}})(?:st|nd|rd|th)?(?:,?\s+(\d{{4}}))?", s)
    if m:
        return (int(m.group(3)) if m.group(3) else None, month_num(m.group(1)), int(m.group(2)))
    return None


def resolve_date(p, mode="this"):
    """A date from parse_date's answer; a missing year takes the next / last / this occurrence."""
    if p is None or isinstance(p, dt.date):
        return p
    y, mo, d = p
    t = today()

    def mk(yy):
        try:
            return dt.date(yy, mo, d)
        except ValueError:
            return None
    if y is not None:
        return mk(y)
    if mode == "next":
        for yy in (t.year, t.year + 1, t.year + 2, t.year + 4):
            c = mk(yy)
            if c and c >= t:
                return c
    elif mode == "last":
        for yy in (t.year, t.year - 1, t.year - 2, t.year - 4):
            c = mk(yy)
            if c and c <= t:
                return c
    return mk(t.year)


def date_answer(d, expr, detail="", alts=None):
    return [A("date", fmt_date(d), d.isoformat(), expr, detail, alts)]


def days_answer(n, expr, d2=None):
    alts = []
    if abs(n) >= 7:
        w, r = divmod(abs(n), 7)
        alts.append(alt("", plural(w, "week") + (" " + plural(r, "day") if r else ""), f"{n / 7:.2f}".rstrip("0").rstrip(".")))
    if abs(n) >= 60:
        alts.append(alt("", f"{fmt(Fraction(abs(n) * 1000, 30437), sig=3)[0]} months", ""))
    return [A("date", plural(n, "day"), str(n), expr, fmt_date(d2) if d2 else "", [x for x in alts if x["copy"] or True][:3])]


def iso_week_range(y, w):
    try:
        mon = dt.date.fromisocalendar(y, w, 1)
    except ValueError:
        return None
    return mon, mon + dt.timedelta(days=6)


UNITSD = r"(days?|d|weeks?|wks?|w|months?|mo|years?|yrs?|y|hours?|hrs?|h|minutes?|mins?)"


def add_span(base, sign, n, unit):
    """base date + sign*n units (date) or datetime for hours/minutes."""
    u = unit[0] if unit[:2] not in ("mo", "mi") else unit[:2]
    if u == "d":
        return base + dt.timedelta(days=int(sign * n)) if n == int(n) else None
    if u == "w":
        return base + dt.timedelta(days=int(sign * n * 7)) if (n * 7) == int(n * 7) else None
    if u == "mo":
        return add_months(base, int(sign * n)) if n == int(n) else None
    if u == "y":
        return add_months(base, int(sign * n * 12)) if n == int(n) else None
    return None


def fam_date(orig, low):
    t = low
    t0 = today()
    # unix
    m = re.fullmatch(r"(?:unix|epoch|timestamp)(?:\s+time)?\s+(\d{1,13})", t)
    if m:
        v = int(m.group(1))
        if v > 10 ** 11:
            v //= 1000
        try:
            d = dt.datetime.fromtimestamp(v, dt.timezone.utc)
        except (OverflowError, OSError, ValueError):
            return None
        loc = d.astimezone(home_zone())
        return [A("date", d.strftime("%Y-%m-%d %H:%M:%S") + " UTC", d.strftime("%Y-%m-%d %H:%M:%S"), f"unix {v}", fmt_date(d.date()),
                  [alt("local", loc.strftime("%Y-%m-%d %H:%M:%S ") + (loc.tzname() or ""), loc.strftime("%Y-%m-%d %H:%M:%S")),
                   alt("iso", d.strftime("%Y-%m-%dT%H:%M:%SZ"))])]
    m = re.fullmatch(r"(?:now|today|time)\s+(?:in|to|as)\s+(?:unix|epoch|timestamp)|(?:unix|epoch|timestamp)\s+(?:now|time)", t)
    if m:
        n = int(now_utc().timestamp())
        return [A("date", str(n), str(n), "now → unix", now_utc().strftime("%Y-%m-%d %H:%M:%S") + " UTC", [])]
    m = re.fullmatch(r"(.+?)\s+(?:in|to|as)\s+(?:unix|epoch|timestamp)", t)
    if m:
        d = resolve_date(parse_date(m.group(1)))
        if d is None:
            return None
        n = int(dt.datetime(d.year, d.month, d.day, tzinfo=home_zone()).timestamp())
        return [A("date", str(n), str(n), f"{d.isoformat()} → unix", "local midnight", [])]
    # days until / since / between
    m = re.fullmatch(r"(?:how many )?days?\s+(until|till|to|since|from)\s+(.+)", t)
    if m:
        mode = "last" if m.group(1) in ("since", "from") and m.group(1) == "since" else "next"
        d = resolve_date(parse_date(m.group(2)), mode)
        if d is None:
            return None
        n = (d - t0).days if m.group(1) != "since" else (t0 - d).days
        return days_answer(n, f"{m.group(1)} {fmt_date(d)}", d)
    m = re.fullmatch(r"days?\s+between\s+(.+?)\s+and\s+(.+)", t)
    if m:
        a, b = resolve_date(parse_date(m.group(1))), resolve_date(parse_date(m.group(2)))
        if a is None or b is None:
            return None
        return days_answer(abs((b - a).days), f"{a.isoformat()} ↔ {b.isoformat()}")
    # date - date
    m = re.fullmatch(r"(.+?)\s+-\s+(.+)", t)
    if m:
        pa, pb = parse_date(m.group(1)), parse_date(m.group(2))
        if pa is not None and pb is not None:
            a, b = resolve_date(pa), resolve_date(pb)
            if a is None or b is None:
                return None
            return days_answer((a - b).days, f"{a.isoformat()} − {b.isoformat()}")
    # date +- n unit  /  +90 days / n unit from now / ago
    m = re.fullmatch(rf"(?:(.+?)\s*)?([+-])\s*(\d+(?:\.\d+)?)\s*{UNITSD}", t)
    if m:
        base = resolve_date(parse_date(m.group(1))) if m.group(1) else t0
        if base is None:
            return None
        return span_answer(base, m.group(2), Fraction(m.group(3)), m.group(4), t)
    m = re.fullmatch(rf"(\d+(?:\.\d+)?)\s*{UNITSD}\s+(from now|from today|ago|from tomorrow)", t)
    if m:
        base = t0 + dt.timedelta(days=1) if m.group(3) == "from tomorrow" else t0
        return span_answer(base, "-" if m.group(3) == "ago" else "+", Fraction(m.group(1)), m.group(2), t)
    # weeks
    m = re.fullmatch(r"week\s+(\d{1,2})(?:\s+(\d{4}))?", t)
    if m:
        y = int(m.group(2)) if m.group(2) else t0.isocalendar()[0]
        r = iso_week_range(y, int(m.group(1)))
        if r is None:
            return None
        a, b = r
        return [A("date", f"{a.day} {MONTHS[a.month - 1].capitalize()} – {b.day} {MONTHS[b.month - 1].capitalize()} {b.year}", a.isoformat(),
                  f"week {m.group(1)} {y}", "ISO week, Monday to Sunday", [alt("monday", a.isoformat()), alt("sunday", b.isoformat())])]
    m = re.fullmatch(r"(?:week(?: number| of year| no)?|current week|which week|what week)(?:\s+(?:of|is)\s+(.+))?", t)
    if m and (m.group(1) or t != "week"):
        d = resolve_date(parse_date(m.group(1))) if m.group(1) else t0
        if d is None:
            return None
        iy, iw, iwd = d.isocalendar()
        a = dt.date.fromisocalendar(iy, iw, 1)
        return [A("date", f"week {iw}", str(iw), f"{d.isoformat()}", f"{a.isoformat()} – {(a + dt.timedelta(days=6)).isoformat()} · ISO {iy}", [])]
    if t in ("day of year", "day of the year", "doy"):
        n = t0.timetuple().tm_yday
        return [A("date", f"day {n}", str(n), t0.isoformat(), f"of {366 if (t0.year % 4 == 0 and (t0.year % 100 or t0.year % 400 == 0)) else 365}", [])]
    m = re.fullmatch(r"(?:what )?day (?:of the week )?(?:is|of)\s+(.+)|weekday\s+(.+)", t)
    if m:
        d = resolve_date(parse_date(m.group(1) or m.group(2)))
        if d is None:
            return None
        return [A("date", DAYNAMES[d.weekday()], DAYNAMES[d.weekday()], d.isoformat(), fmt_date(d), [])]
    return None


def span_answer(base, sign, n, unit, expr):
    sg = -1 if sign == "-" else 1
    u = unit[:2] if unit[:2] in ("mo", "mi") else unit[0]
    if u in ("h", "mi"):
        now = now_utc().astimezone(home_zone())
        d = now + dt.timedelta(hours=float(sg * n)) if u == "h" else now + dt.timedelta(minutes=float(sg * n))
        return [A("date", d.strftime("%a %-d %b %Y %H:%M"), d.strftime("%Y-%m-%d %H:%M"), expr, "", [])]
    r = add_span(base, sg, n, unit)
    if r is None:
        return None
    return date_answer(r, expr, f"{(r - today()).days:+d} days from today" if r != today() else "")


# ---- zones
CLOCK = r"(?:\d{1,2}(?::\d{2}){1,2}\s*(?:am|pm)?|\d{1,2}\s*(?:am|pm)|noon|midnight)"


def parse_clock(s):
    s = s.strip()
    if s == "noon":
        return 12, 0, 0
    if s == "midnight":
        return 0, 0, 0
    m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)?", s)
    if not m:
        return None
    h, mi, se = int(m.group(1)), int(m.group(2) or 0), int(m.group(3) or 0)
    if m.group(4):
        if not 1 <= h <= 12:
            return None
        h = h % 12 + (12 if m.group(4) == "pm" else 0)
    if h > 23 or mi > 59 or se > 59:
        return None
    return h, mi, se


def aware(day, hms, tz):
    """A wall time in tz; a time the clocks skip moves forward past the gap."""
    naive = dt.datetime(day.year, day.month, day.day, *hms)
    d = naive.replace(tzinfo=tz)
    back = d.astimezone(dt.timezone.utc).astimezone(tz)
    if back.replace(tzinfo=None) != naive:
        d = back
    return d


def zone_out(srcdt, dstdt, slab, dlab, expr, home_dst=False):
    dd = (dstdt.date() - srcdt.date()).days
    mark = {0: "", 1: " (tomorrow)", -1: " (yesterday)"}.get(dd, f" ({dd:+d} days)")
    ab = dstdt.tzname() or ""
    hm = dstdt.strftime("%H:%M")
    v = f"{hm} {ab}".strip() + mark
    h12 = dstdt.strftime("%-I:%M %p")
    sab = srcdt.tzname() or ""
    def off(d):
        o = d.utcoffset()
        mins = int(o.total_seconds() // 60)
        s = "+" if mins >= 0 else "-"
        mins = abs(mins)
        return f"UTC{s}{mins // 60}" + (f":{mins % 60:02d}" if mins % 60 else "")
    det = f"{slab} {srcdt.strftime('%H:%M')} {sab} ({off(srcdt)}) = {dlab} {hm} {ab} ({off(dstdt)}) · {dstdt.strftime('%a %-d %b')}"
    return [A("zone", v, hm, expr, det,
              [alt("12 h", h12), alt("UTC", dstdt.astimezone(dt.timezone.utc).strftime("%H:%M UTC")), alt("iso", dstdt.isoformat(timespec="minutes"))])]


NOWWORDS = r"(?:time|now|current time|the time|what time is it|what's the time|whats the time|time now|time right now)"


def fam_zone(orig, low):
    t = low
    day = None
    m = re.search(r"\b(\d{4}-\d{2}-\d{2})\b", t)
    if m:
        try:
            day = dt.date.fromisoformat(m.group(1))
        except ValueError:
            return None
        t = (t[:m.start()] + " " + t[m.end():])
    rel = 0
    m = re.search(r"\b(tomorrow|yesterday|today)\b", t)
    if m:
        rel = {"tomorrow": 1, "yesterday": -1, "today": 0}[m.group(1)]
        t = t[:m.start()] + " " + t[m.end():]
        if rel == 0 and m.group(1) == "today" and not re.search(CLOCK, t):
            return None
    t = re.sub(r"\s+", " ", t).strip()
    home = home_zone()
    nowu = now_utc()
    sep = re.fullmatch(r"(.*?)\s+(?:in|to|into|->|→)\s+(.+)", t)
    if sep:
        left, right = sep.group(1).strip(), sep.group(2).strip()
        dz = resolve_zone(right)
        if dz is None:
            return None
        if re.fullmatch(NOWWORDS, left) or left in ("", "now", "time"):
            if left == "":
                return None
            local = nowu.astimezone(home)
            dtz = nowu.astimezone(dz[0])
            return zone_out(local, dtz, home_label(), dz[1], f"now → {dz[1]}")
        cm = re.match(rf"({CLOCK})(?:\s+(.+))?$", left)
        if not cm:
            return None
        hms = parse_clock(cm.group(1))
        if hms is None:
            return None
        if cm.group(2):
            sz = resolve_zone(cm.group(2))
            if sz is None:
                return None
        else:
            sz = (home, home_label())
        sday = day or (nowu.astimezone(sz[0]).date() + dt.timedelta(days=rel))
        s = aware(sday, hms, sz[0])
        d = s.astimezone(dz[0])
        return zone_out(s, d, sz[1], dz[1], f"{cm.group(1).strip()} {sz[1]} → {dz[1]}")
    cm = re.match(rf"({CLOCK})\s+(.+)$", t)
    if cm:
        hms = parse_clock(cm.group(1))
        sz = resolve_zone(cm.group(2))
        if hms is None or sz is None:
            return None
        sday = day or (nowu.astimezone(sz[0]).date() + dt.timedelta(days=rel))
        s = aware(sday, hms, sz[0])
        d = s.astimezone(home)
        return zone_out(s, d, sz[1], home_label(), f"{cm.group(1).strip()} {sz[1]} → {home_label()}")
    m = re.fullmatch(rf"{NOWWORDS}\s+(?:in\s+|at\s+)?(.+)|(.+?)\s+time", t)
    if m:
        z = resolve_zone(m.group(1) or m.group(2))
        if z is None:
            return None
        local = nowu.astimezone(home)
        return zone_out(local, nowu.astimezone(z[0]), home_label(), z[1], f"now in {z[1]}")
    return None


# ------------------------------------------------------------------------------------------------- dispatch and the pipe
FAMILIES = (fam_colour, fam_resolution, fam_percent, fam_currency, fam_base, fam_zone, fam_date, fam_timearith, fam_unit, fam_math)
_REPORTED = set()


def answers_for(q):
    orig = re.sub(r"\s+", " ", q.replace(" ", " ").replace(" ", " ").replace("−", "-").replace("–", "-").replace("’", "'").replace("”", '"').replace("“", '"')).strip()
    if not orig or len(orig) > 200:
        return []
    low = orig.lower()
    for fam in FAMILIES:
        try:
            r = fam(orig, low)
        except Bad:
            continue
        except Exception as e:  # a bug in one family must not take the others down
            key = (fam.__name__, type(e).__name__)
            if key not in _REPORTED:
                _REPORTED.add(key)
                warn(f"{fam.__name__}: {type(e).__name__}: {e}")
            continue
        if r:
            return r[:3]
    return []


def handle(req):
    rid = req.get("id")
    LATEST["id"] = rid
    if req.get("cmd") == "ping":
        send({"id": rid, "pong": True})
        return
    q = req.get("q")
    if not isinstance(q, str):
        send({"id": rid, "answers": []})
        return
    ans = answers_for(q)
    send({"id": rid, "answers": ans})
    if any(a.get("pending") for a in ans):
        with STORE.lock:
            STORE.waiting = (rid, q)
            done = not STORE.inflight
        if done:  # the fetch ended while this answer was made
            on_rates_done(True)


WARM = ("2+2*3", "sqrt(16)", "0xff + 1", "255 in hex", "15% of 80", "5 ft in cm", "70 f in c", "100 mbps in MB/s", "3h20m + 45m",
        "#4480f4", "1440p 21:9", "27in 4k", "16:9 at 1440 wide", "3pm tokyo in brussels", "days until 24 dec", "week 47", "now in unix",
        "steam", "visual studio code")


def prewarm():
    """Idle time after the start: compile the regexes and build the tables the first real queries would pay for.
    No currency (that would fetch) and nothing is sent."""
    for q in WARM:
        try:
            answers_for(q)
        except Exception:
            pass


def option(argv, name):
    i = argv.index(name) if name in argv else -1
    return argv[i + 1] if 0 <= i < len(argv) - 1 else None


def words(text):
    return [w.strip() for w in text.split(",") if w.strip()]


def main(argv):
    global HOME_CUR, CURRENCIES, FAMILIES
    home, shown, kinds = (option(argv, n) for n in ("--home-currency", "--currencies", "--kinds"))
    if home:
        HOME_CUR = home.upper()
    if shown is not None:
        CURRENCIES = [c.upper() for c in words(shown)]
    if kinds is not None:
        FAMILIES = tuple(f for f in FAMILIES if f.__name__[4:] in words(kinds))
    threading.Thread(target=prewarm, daemon=True).start()
    stdin = sys.stdin.buffer
    while True:
        raw = stdin.readline()
        if not raw:
            break
        req = None
        try:
            req = json.loads(raw)
            if not isinstance(req, dict):
                continue
            handle(req)
        except Exception as e:
            warn(f"bad request: {type(e).__name__}: {e}")
            try:
                rid = req.get("id") if isinstance(req, dict) else None
                if rid is not None:
                    send({"id": rid, "answers": []})
            except Exception:
                pass


if __name__ == "__main__":
    main(sys.argv[1:])
