#!/usr/bin/env python3
"""`lares config`: the hand-edited config/*.jsonc against what the shell takes.

    lares config                 every file: ok, or its mistakes with their lines (exit 1 when there is one)
    lares config NAME ...        these files (shell, osd, "clock.jsonc" ...)
    lares config set [NAME ...]  every key YOU set that is not the default, beside the default
    lares config find WORD       the keys whose name or words hold WORD: file, key, default, what it takes

It reads .examples/schema/<name>.schema.json (made from modules/common/config/specs and the comments of .examples/<name>.jsonc by
tools/dev/config_schema.js) and never writes anything. The shell checks the same files with ConfigCheck.js and says a mistake in a toast
as you save: the two are held to one table of cases (tools/dev/fixtures/config_cases.json, tools/dev/config_spec_check.js).
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "lib"))
import jsonc  # noqa: E402

SCHEMAS = os.path.join(ROOT, ".examples", "schema")
KEEP = " -- the last good version stays in force"
ARM = os.environ.get("LARES_CONFIG_ARM", "")        # a probe's fault (config_spec_check.js): "noranges", "showsecret"
# what the shell does not read (another program does): nothing says a mistake in them but this command and that program's own log
MAX_SHOWN = 60


def names():
    return sorted(f[:-len(".schema.json")] for f in os.listdir(SCHEMAS) if f.endswith(".schema.json"))


def schema_of(name):
    with open(os.path.join(SCHEMAS, name + ".schema.json"), encoding="utf-8") as f:
        return json.load(f)


def config_path(name):
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "quickshell", "config", name + ".jsonc")


# ---- the text ----------------------------------------------------------------------------------------------------------------

def places(t):
    """The offset of every key and list entry of a valid text, and the keys given twice in one object (ConfigCheck.places)."""
    at, twice, i, n = {}, [], 0, len(t)

    def ws():
        nonlocal i
        while i < n and t[i] in " \t\n\r":
            i += 1

    def string():
        nonlocal i
        start = i
        i += 1
        while i < n and t[i] != '"':
            i += 2 if t[i] == "\\" else 1
        i += 1
        return json.loads(t[start:i])

    def value(path):
        nonlocal i
        ws()
        c = t[i]
        if c == "{":
            i += 1
            seen = {}
            ws()
            while i < n and t[i] != "}":
                ws()
                where = i
                k = string()
                p = path + (k,)
                if k in seen:
                    twice.append((p, where, seen[k]))
                seen[k] = where
                at[p] = where
                ws()
                i += 1
                value(p)
                ws()
                if i < n and t[i] == ",":
                    i += 1
                ws()
            i += 1
        elif c == "[":
            i += 1
            k = 0
            ws()
            while i < n and t[i] != "]":
                ws()
                p = path + (k,)
                at[p] = i
                value(p)
                k += 1
                ws()
                if i < n and t[i] == ",":
                    i += 1
                ws()
            i += 1
        elif c == '"':
            string()
        else:
            while i < n and t[i] not in ",]} \t\n\r":
                i += 1

    value(())
    return at, twice


def path_words(path):
    out = ""
    for p in path:
        if isinstance(p, int):
            out += "[%d]" % p
        elif re.match(r"^[A-Za-z_$][\w$-]*$", p, re.ASCII):
            out += ("" if out == "" else ".") + p
        else:
            out += "[" + json.dumps(p, ensure_ascii=False) + "]"
    return out


def shown(v):
    s = json.dumps(v, ensure_ascii=False, separators=(",", ":"))
    if isinstance(v, float) and v == int(v):
        s = str(int(v))
    return s[:57] + "..." if len(s) > MAX_SHOWN else s


# ---- one value against one schema node ------------------------------------------------------------------------------------------

def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def kind_ok(t, v):
    return {"boolean": isinstance(v, bool), "string": isinstance(v, str), "array": isinstance(v, list), "object": isinstance(v, dict), "null": v is None,
            "number": is_number(v), "integer": is_number(v) and float(v) == int(v)}[t]


def distance(a, b):
    prev2, prev = None, list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        cur = [i]
        for j in range(1, len(b) + 1):
            same = 0 if a[i - 1] == b[j - 1] else 1
            v = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + same)
            if prev2 is not None and i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
                v = min(v, prev2[j - 2] + 1)
            cur.append(v)
        prev2, prev = prev, cur
    return prev[-1]


def maybe(k, words):
    best, cost, a = "", 3, k.lower()
    for w in words:
        b = w.lower()
        d = 0 if a == b else distance(a, b)
        if d < cost and d < max(len(a), len(b)) / 2:
            best, cost = w, d
    return "" if best == "" else ' -- did you mean "%s"?' % best


def take(s, v, path):
    """(ok, problems) of a value against a schema node; a problem is (path, why)."""
    wants = s.get("x-wants")

    def bad():                                     # a secret (x-secret) is named, never quoted
        return False, [(path, "%s, must be %s" % ("is not what it must be" if s.get("x-secret") else "is " + shown(v), wants or "an object"))]
    if "anyOf" in s:
        first = None
        for alt in s["anyOf"]:
            ok, problems = take(alt, v, path)
            if ok and not problems:
                return True, []
            if first is None or (ok and not first[0]):
                first = (ok, problems)
        return first if first and first[0] else bad()
    if "enum" in s:
        return (True, []) if any(type(e) is type(v) and e == v for e in s["enum"]) else bad()
    t = s.get("type")
    if t is None:
        return True, []
    types = t if isinstance(t, list) else [t]
    if not any(kind_ok(x, v) for x in types):
        return bad()
    if v is None:
        return True, []
    if is_number(v) and ARM != "noranges":
        if ("minimum" in s and v < s["minimum"]) or ("maximum" in s and v > s["maximum"]):
            return bad()
    if isinstance(v, str) and "pattern" in s and not re.search(s["pattern"], v):
        return bad()
    if isinstance(v, list):
        lo, hi = s.get("minItems"), s.get("maxItems")
        if (lo is not None and len(v) < lo) or (hi is not None and len(v) > hi):
            if "command" in (wants or ""):
                return bad()
            want = " %d .. %d" % (lo, hi) if lo is not None and hi is not None else " at least %d" % lo if lo is not None else " at most %d" % hi
            return False, [(path, "has %d entries, must have%s" % (len(v), want))]
        items = s.get("items", {})
        if "command" in (wants or ""):
            return (True, []) if all(isinstance(x, str) for x in v) and v[0] else bad()
        problems = []
        for i, x in enumerate(v):
            problems += take(items, x, path + (i,))[1]
        return True, problems
    if isinstance(v, dict):
        props, more, problems, ok = s.get("properties", {}), s.get("additionalProperties", True), [], True
        refused = set()                            # a required key whose value is refused counts as missing too (as the shell's read does)
        for k, x in v.items():
            if k in props:
                if k == "$schema" and path:
                    problems.append((path + (k,), "is not a key"))
                    continue
                kok, kp = take(props[k], x, path + (k,))
                problems += kp
                if not kok:
                    refused.add(k)
            elif more is False:
                problems.append((path + (k,), "is not a key" + maybe(k, [p for p in props if p != "$schema"])))
            elif isinstance(more, dict):
                problems += take(more, x, path + (k,))[1]
        for k in s.get("required", []):
            if k not in v or k in refused:
                problems.append((path, 'has no "%s"' % k))
                ok = False
        return ok, problems
    return True, []


def mistakes(schema, text):
    if text.strip() == "":
        return []
    clean = jsonc.strip(text)
    try:
        value = json.loads(clean)
    except ValueError as e:
        line, what = getattr(e, "lineno", 0), getattr(e, "msg", str(e))
        pos = getattr(e, "pos", 0)
        if what.startswith("Expecting ',' delimiter") or what.startswith("Expecting ':' delimiter"):
            # where it belongs: right after the value before it
            back = len(clean[:pos].rstrip())
            line = clean.count("\n", 0, back) + 1
            what = "missing comma" if "','" in what else "missing colon"
        return ["line %d: %s%s" % (line, what, KEEP)]
    if not isinstance(value, dict):
        return ["the file is not an object { ... }" + KEEP]
    at, twice = places(clean)

    def line_of(path):
        for n in range(len(path), 0, -1):
            if path[:n] in at:
                return text.count("\n", 0, at[path[:n]]) + 1
        return 0
    out = []
    for p, where, first in twice:
        out.append((text.count("\n", 0, where) + 1, "%s is given twice (the first on line %d does not count)" % (path_words(p), text.count("\n", 0, first) + 1)))
    for p, why in take(schema, value, ())[1]:
        out.append((line_of(p), (path_words(p) + " " if p else "the file ") + why))
    out.sort(key=lambda m: m[0])
    return [("line %d: " % n if n > 0 else "") + say for n, say in out]


# ---- the command ------------------------------------------------------------------------------------------------------------------

def pick(args):
    known = names()
    if not args:
        return known
    out = []
    for a in args:
        n = re.sub(r"\.jsonc?$", "", os.path.basename(a))
        if n not in known:
            sys.exit("lares config: no file %s.jsonc%s (%s)" % (n, maybe(n, known).replace(" --", ","), " ".join(known)))
        out.append(n)
    return out


def check(args):
    wrong = 0
    for name in pick(args):
        path = next((p for p in jsonc.candidates(config_path(name)) if os.path.isfile(p)), None)
        if path is None:
            if args:
                print("--    %s.jsonc  (no file: every key is at its default)" % name)
            continue
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = mistakes(schema_of(name), f.read())
        if not lines:
            print("ok    %s.jsonc" % name)
            continue
        wrong += 1
        print("WRONG %s.jsonc  (%s)" % (name, path))
        for m in lines:
            print("        " + m)
    return 1 if wrong else 0


def leaves(schema, path=()):
    for k, s in schema.get("properties", {}).items():
        if k == "$schema" or s.get("deprecated"):
            continue
        if s.get("type") == "object" and s.get("properties") and "default" not in s:
            yield from leaves(s, path + (k,))
        else:
            yield path + (k,), s


def holds_secret(s):
    """The schema node is a secret or holds one somewhere below (a list of calendars whose URLs carry their access token)."""
    if not isinstance(s, dict) or ARM == "showsecret":
        return False
    if s.get("x-secret"):
        return True
    subs = list(s.get("properties", {}).values()) + [s.get("items"), s.get("additionalProperties")] + s.get("anyOf", [])
    return any(holds_secret(x) for x in subs)


def at_path(v, path):
    for p in path:
        if not isinstance(v, dict) or p not in v:
            return None, False
        v = v[p]
    return v, True


def mine(args):
    for name in pick(args):
        path = next((p for p in jsonc.candidates(config_path(name)) if os.path.isfile(p)), None)
        if path is None:
            continue
        try:
            value = jsonc.load(path)
        except (OSError, ValueError) as e:
            print("%s: does not parse (%s)" % (path, e))
            continue
        for p, s in leaves(schema_of(name)):
            v, there = at_path(value, p)
            if there and v != s.get("default"):
                secret = holds_secret(s)
                said = ("%d entries" % len(v) if isinstance(v, list) else "(set)") if secret else shown(v)
                print("%s  %s = %s   (default %s)" % (name, path_words(p), said,
                                                    shown(s["default"]) if "default" in s else "none"))
    return 0


def find(word):
    w, hits = word.lower(), 0
    for name in names():
        for p, s in leaves(schema_of(name)):
            words = s.get("description", "")
            if w in path_words(p).lower() or w in words.lower():
                hits += 1
                first = words.split("\n\n")[0].replace("\n", " ")
                print("%s.jsonc  %s   (default %s; %s)" % (name, path_words(p), shown(s["default"]) if "default" in s else "none", s.get("x-wants", "an object")))
                if first and not first.startswith("Takes "):
                    print("        " + (first[:157] + "..." if len(first) > 160 else first))
    if hits == 0:
        print("no key holds '%s'" % word)
    return 0 if hits else 1


def main(argv):
    if argv[:1] == ["--cases"] and len(argv) == 2:
        with open(argv[1], encoding="utf-8") as f:
            print(json.dumps({c["name"]: mistakes(schema_of(c["file"]), "\n".join(c["text"])) for c in json.load(f)}))
        return 0
    if argv and argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    if argv[:1] == ["set"]:
        return mine(argv[1:])
    if argv[:1] == ["find"] and len(argv) == 2:
        return find(argv[1])
    return check(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
