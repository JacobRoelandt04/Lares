#!/usr/bin/env python3
"""comment_strip_diff.py -- a comment rewrite must leave the code exactly as it was.

    python3 tools/dev/comment_strip_diff.py <base-rev> [<path> ...]      every file changed since <base-rev> (or under the paths given)
    python3 tools/dev/comment_strip_diff.py <base-rev> --to <rev> [...]  between two revisions (a commit judged without checking it out)
    python3 tools/dev/comment_strip_diff.py --selftest                    the stripper against its own cases (a hidden code change must be caught)

For every file that differs between <base-rev> and the work tree, both versions are reduced to their code: comments removed by the file's own
language rules, string literals kept whole (a `//` or `#` inside a string is code), then compared word by word (whitespace is not code; Python's
indentation is, and stays). The two reductions must be identical. Prints `SAME <path>` / `CODE <path>` (+ the first differing code word, in context) / `SKIP <path> (<why>)`, and ends in
`COMMENT_STRIP RESULT PASS|FAIL (<n> files, <same> comment-only, <code> with code changes, <skip> skipped)`; the exit status follows the verdict.

Languages: QML, JS, GLSL (.frag .vert .glsl), Rust, C/C++ -- `//` and `/* */`, strings '..' ".." and JS `..`, Rust r"..", r#".."#;
Python -- the tokenizer's COMMENT tokens and docstrings (a string that is a statement of its own); shell -- `#` that starts a word outside
quotes (a heredoc's body is kept as code). A file added or deleted, or of another type, is SKIP: a comment rewrite adds and deletes nothing.
JS and QML regex literals are code too: a `/` where an expression may start (after `( , = : [ ! & | ? { } ;`, after `return`, or first on
its line) opens one, which runs to its closing `/` past escapes and `[...]` classes, so a `//`, a quote or a backtick inside it is part of
it (`/[`*_~#>]/g` once opened a template literal and every comment after it read as code). A `/` after a value is a division.
"""
import io
import re
import subprocess
import sys
import tokenize

C_LIKE = (".qml", ".js", ".mjs", ".frag", ".vert", ".glsl", ".rs", ".c", ".h", ".cpp", ".hpp")
JS_LIKE = (".qml", ".js", ".mjs")              # the languages with regex literals
REGEX_AFTER = set("(,=:[!&|?{};")              # a `/` after one of these starts an expression: a regex, never a division
SHELL = (".sh", ".bash")


def regex_may_start(out):
    """True when the code reduced so far ends where an expression may start (see REGEX_AFTER), at a line start, or after `return`."""
    tail, k = "", len(out) - 1
    while k >= 0 and len(tail.rstrip(" \t")) < 8:     # enough for the last character and a `return` before it
        tail = out[k] + tail
        k -= 1
    t = tail.rstrip(" \t")
    if t == "" or t.endswith("\n"):
        return True
    if t[-1] in REGEX_AFTER:
        return True
    return re.search(r"(?<![\w$.])return$", t) is not None


def regex_end(src, i):
    """The index past the regex literal that starts at src[i] (`/`), its flags included; None if it does not close on its line."""
    j, n, klass = i + 1, len(src), False
    while j < n:
        ch = src[j]
        if ch == "\\":
            j += 2
            continue
        if ch == "\n":
            return None
        if klass:
            klass = ch != "]"
        elif ch == "[":
            klass = True
        elif ch == "/":
            j += 1
            while j < n and (src[j].isalpha()):
                j += 1
            return j
        j += 1
    return None


def strip_c_like(src, ext):
    out, i, n = [], 0, len(src)
    rust = ext == ".rs"
    js = ext in JS_LIKE
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == "//":
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if two == "/*":
            j = src.find("*/", i + 2)
            seg = src[i:(n if j < 0 else j + 2)]
            out.append("\n" * seg.count("\n") or " ")
            i = n if j < 0 else j + 2
            continue
        if js and c == "/" and regex_may_start(out):
            j = regex_end(src, i)
            if j is not None:
                out.append(src[i:j]); i = j
                continue
        if rust and c == "r" and re.match(r'r#*"', src[i:i + 8]) and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_")):
            m = re.match(r'r(#*)"', src[i:])
            close = '"' + m.group(1)
            j = src.find(close, i + len(m.group(0)))
            j = n if j < 0 else j + len(close)
            out.append(src[i:j]); i = j
            continue
        if c in "\"'" or (c == "`" and not rust):
            if rust and c == "'":
                # a lifetime ('a) or a char literal ('x', '\n'): only a closed char literal is a string
                m = re.match(r"'(\\.|[^\\'])'", src[i:])
                if not m:
                    out.append(c); i += 1
                    continue
                out.append(m.group(0)); i += len(m.group(0))
                continue
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                elif src[j] == "\n" and c != "`":
                    break                    # an unclosed quote ends at the line: never swallow the file
                j += 1
            j = min(j + 1, n)
            out.append(src[i:j]); i = j
            continue
        out.append(c); i += 1
    return "".join(out)


def strip_python(src):
    toks = []
    try:
        gen = list(tokenize.generate_tokens(io.StringIO(src).readline))
    except (tokenize.TokenError, SyntaxError) as e:
        raise ValueError(f"python tokenizer: {e}")
    prev_sig = tokenize.NEWLINE
    for k, t in enumerate(gen):
        if t.type == tokenize.COMMENT:
            continue
        if t.type == tokenize.STRING and prev_sig in (tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.NL):
            nxt = next((u for u in gen[k + 1:] if u.type not in (tokenize.COMMENT, tokenize.NL)), None)
            if nxt is not None and nxt.type in (tokenize.NEWLINE, tokenize.ENDMARKER):
                continue                     # a docstring / a bare string statement: documentation
        if t.type in (tokenize.NL, tokenize.NEWLINE):
            toks.append("\n")
        elif t.type == tokenize.INDENT:
            toks.append(" <INDENT> ")         # indentation is Python's code: kept as a token
        elif t.type == tokenize.DEDENT:
            toks.append(" <DEDENT> ")
        elif t.type == tokenize.ENDMARKER:
            pass
        else:
            toks.append(t.string + " ")
        if t.type not in (tokenize.NL, tokenize.COMMENT):
            prev_sig = t.type
    return "".join(toks)


def strip_shell(src):
    out_lines = []
    heredoc = None
    for line in src.split("\n"):
        if heredoc is not None:
            out_lines.append(line)
            if line.strip() == heredoc or (line.lstrip("\t") == heredoc):
                heredoc = None
            continue
        res, i, n, q = [], 0, len(line), None
        while i < n:
            c = line[i]
            if q:
                res.append(c)
                if c == "\\" and q == '"' and i + 1 < n:
                    res.append(line[i + 1]); i += 2
                    continue
                if c == q:
                    q = None
                i += 1
                continue
            if c in "'\"":
                q = c; res.append(c); i += 1
                continue
            if c == "\\" and i + 1 < n:
                res.append(line[i:i + 2]); i += 2
                continue
            if c == "#" and (i == 0 or line[i - 1] in " \t;|&(){}"):
                break
            res.append(c); i += 1
        code = "".join(res)
        m = re.search(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1", code)
        if m:
            heredoc = m.group(2)
        out_lines.append(code)
    return "\n".join(out_lines)


def reduce(path, src):
    ext = "." + path.rsplit(".", 1)[-1] if "." in path.rsplit("/", 1)[-1] else ""
    if ext in C_LIKE:
        code = strip_c_like(src, ext)
    elif ext == ".py" or src.startswith("#!/usr/bin/env python") or src.startswith("#!/usr/bin/python"):
        code = strip_python(src)
    elif ext in SHELL or re.match(r"#!\s*/(usr/)?bin/(env )?(ba)?sh", src):
        code = strip_shell(src)
    else:
        return None
    # Compared as a stream of whitespace-separated words: a comment taken out of a line, or a block comment that spanned lines, moves the
    # code's own whitespace, which is not code (Python's indentation is, and is a token above). Blind spot, the same on both sides: a run of
    # blanks inside a string literal.
    return code.split()


def git(*a):
    return subprocess.run(["git", *a], capture_output=True, text=True, check=True).stdout


def first_diff(a, b):
    for k in range(max(len(a), len(b))):
        x = a[k] if k < len(a) else "<end>"
        y = b[k] if k < len(b) else "<end>"
        if x != y:
            return k, x, y
    return None


def selftest():
    cases = [
        # (name, old, new, ext, expect_same)
        ("qml comment reworded", "Item {\n    // old story, round 3\n    width: 4 // why\n}\n", "Item {\n    // what it is\n    width: 4 // the reason\n}\n", ".qml", True),
        ("qml block comment", "/* a\n b */ x: 1\n", "/* c */ x: 1\n", ".qml", True),
        ("qml code changed beside a comment", "    width: 4 // why\n", "    width: 5 // why\n", ".qml", False),
        ("qml string holding //", 'url: "http://a/b"\n', 'url: "http://a/c"\n', ".qml", False),
        ("qml code moved into a comment", "x: 1\ny: 2\n", "x: 1\n// y: 2\n", ".qml", False),
        ("js template", "const s = `a // b`;\n", "const s = `a // c`;\n", ".js", False),
        ("rust raw string", 'let s = r#"x // y"#; // c\n', 'let s = r#"x // z"#; // d\n', ".rs", False),
        ("rust lifetime", "fn f<'a>(x: &'a str) {} // c\n", "fn f<'a>(x: &'a str) {} // e\n", ".rs", True),
        ("python comment + docstring", '"""old doc"""\nx = 1  # old\n', '"""new doc"""\nx = 1  # new\n', ".py", True),
        ("python string changed", "x = 'a#b'\n", "x = 'a#c'\n", ".py", False),
        ("shell comment", "echo hi # old\n# whole\n", "echo hi # new\n", ".sh", True),
        ("shell hash in quotes", "echo 'a # b'\n", "echo 'a # c'\n", ".sh", False),
        ("shell heredoc body", "cat <<EOF\n# kept\nEOF\n", "cat <<EOF\n# changed\nEOF\n", ".sh", False),
        ("glsl", "float x = 1.0; // a\n", "float x = 1.0; /* b */\n", ".frag", True),
        ("block comment across lines", "a /* x\n y */ b\n", "a b\n", ".js", True),
        ("python indentation is code", "if x:\n    y = 1\nz = 2\n", "if x:\n    y = 1\n    z = 2\n", ".py", False),
        ("qml code joined to its comment", "x: 1 // a\ny: 2\n", "x: 1 // a y: 2\n", ".qml", False),
        # regex literals (JS, QML): what a quote, a backtick or a `//` inside one does not start
        ("regex holding a backtick, comment after it reworded", 'let t = (q || "").replace(/[`*_~#>]/g, "").trim();\n// old story\nx: 1 // why\n',
         'let t = (q || "").replace(/[`*_~#>]/g, "").trim();\n// what it is\nx: 1 // the reason\n', ".qml", True),
        ("regex holding a backtick, code after it changed", 's = a.replace(/[`]/g, "");\nx: 1\n', 's = a.replace(/[`]/g, "");\nx: 2\n', ".qml", False),
        ("regex holding //, comment after it reworded", "u = s.match(/https?:\\/\\//); // a\n", "u = s.match(/https?:\\/\\//); // b\n", ".js", True),
        ("regex changed", "u = s.match(/https?:\\/\\//);\n", "u = s.match(/http:\\/\\//);\n", ".js", False),
        ("regex after return, quote inside", "function f() { return /'/.test(x) } // a\n", "function f() { return /'/.test(x) } // b\n", ".js", True),
        ("a division a / b / c stays code", "v = a / b / c; // one\n", "v = a / b / c; // two\n", ".js", True),
        ("a division before a line comment", "r = a / 2; // note / here\nq = 1;\n", "r = a / 2; // other\nq = 1;\n", ".qml", True),
        ("a division changed", "v = a / b / c;\n", "v = a / b / d;\n", ".js", False),
        ("glsl has no regex: a division by a parenthesis", "float x = (a) / (b); // a\n", "float x = (a) / (b); // b\n", ".frag", True),
    ]
    bad = 0
    for name, old, new, ext, want in cases:
        got = reduce("f" + ext, old) == reduce("f" + ext, new)
        ok = got == want
        bad += not ok
        print(f"{'ok  ' if ok else 'BAD '} {name}: {'same' if got else 'code differs'}")
    print(f"COMMENT_STRIP SELFTEST {'PASS' if not bad else 'FAIL'} ({len(cases) - bad}/{len(cases)})")
    return 1 if bad else 0


def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); return 2
    if a[0] == "--selftest":
        return selftest()
    base, rest = a[0], a[1:]
    to = None
    if rest[:1] == ["--to"]:
        to, rest = rest[1], rest[2:]
    paths = rest
    span = [base, to] if to else [base]
    rows = git("diff", "--name-status", "-M0", *span, "--", *paths).splitlines()   # -M0: no rename pairing, a move is add+delete
    same = code = skip = 0
    for row in rows:
        st, path = row.split("\t", 1)
        if st != "M":
            print(f"SKIP {path} ({'added' if st == 'A' else 'deleted' if st == 'D' else st})"); skip += 1
            continue
        try:
            old = git("show", f"{base}:{path}")
            new = git("show", f"{to}:{path}") if to else open(path, encoding="utf-8").read()
        except (subprocess.CalledProcessError, UnicodeDecodeError, FileNotFoundError) as e:
            print(f"SKIP {path} (unreadable: {e.__class__.__name__})"); skip += 1
            continue
        try:
            ro, rn = reduce(path, old), reduce(path, new)
        except ValueError as e:
            print(f"CODE {path} (cannot reduce: {e})"); code += 1
            continue
        if ro is None:
            print(f"SKIP {path} (not a language this checks)"); skip += 1
            continue
        d = first_diff(ro, rn)
        if d is None:
            print(f"SAME {path}"); same += 1
        else:
            k, x, y = d
            ctx_o, ctx_n = " ".join(ro[max(0, k - 6):k + 6]), " ".join(rn[max(0, k - 6):k + 6])
            print(f"CODE {path}: word {k + 1}: {x[:60]!r} -> {y[:60]!r}\n     - {ctx_o[:160]}\n     + {ctx_n[:160]}"); code += 1
    n = same + code + skip
    print(f"COMMENT_STRIP RESULT {'PASS' if code == 0 else 'FAIL'} ({n} files, {same} comment-only, {code} with code changes, {skip} skipped)")
    return 0 if code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
