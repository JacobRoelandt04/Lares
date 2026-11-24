"""Hand-edited configs, `config/<name>.jsonc` first, comments allowed.

The shell's QML side is ConfigFile.qml + JsonComments.js; this is the same rule for the tools (clipboard, weather
accuracy, themectl, the wiki). Every config the user edits is `<name>.jsonc` (VS Code takes comments in that name without a
word) in the config directory's `config/` folder (2026-11-12). A loader names the file where it lives; the `.json` beside it is
read when there is no .jsonc, and -- only for a file in a folder named `config` -- the same names one level up, where every
config lived before. The first that exists wins.

    candidates("/x/config/osd.jsonc") -> ["/x/config/osd.jsonc", "/x/config/osd.json", "/x/osd.jsonc", "/x/osd.json"]
    candidates("/x/osd.json")         -> ["/x/osd.jsonc", "/x/osd.json"]
    pair(path)                  -> the first two (the file's own place)
    resolve(path)               -> the file in force: the first candidate that exists, else the first (where a first write goes:
                                   a writer makes its folder, `ensure_dir`)
    load(path)                  -> the parsed value; OSError when none exists, ValueError when it does not parse
    strip(text)                 -> the text with `//` and `/* */` comments blanked OUTSIDE strings (every character keeps
                                   its place, so a position in the stripped text is the same in the file)

Mirrors JsonComments.strip: an unterminated `/*` and a lone `/` are left for the parser to refuse.
"""
import json
import os


def strip(text):
    out = []
    i, n = 0, len(text)
    in_str = esc = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and text[i + 1:i + 2] == "/":
            j = text.find("\n", i)
            if j < 0:
                j = n
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j]))
            i = j
            continue
        if c == "/" and text[i + 1:i + 2] == "*":
            j = text.find("*/", i + 2)
            if j < 0:
                out.append(text[i:])
                break
            out.append("".join(ch if ch == "\n" else " " for ch in text[i:j + 2]))
            i = j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def pair(path):
    p = str(path)
    if p.endswith(".jsonc"):
        return p, p[:-1]
    if p.endswith(".json"):
        return p + "c", p
    return p, ""


def candidates(path):
    jsonc, js = pair(path)
    out = [jsonc] + ([js] if js else [])
    d = os.path.dirname(jsonc)
    if js and os.path.basename(d) == "config":
        up = os.path.dirname(d)
        name = os.path.basename(jsonc)
        out += [os.path.join(up, name), os.path.join(up, name[:-1])]
    return out


def resolve(path):
    c = candidates(path)
    for p in c:
        if os.path.exists(p):
            return p
    return c[0]


def ensure_dir(path):
    """The folder a first write into `path` needs (config/ may not exist yet)."""
    d = os.path.dirname(str(path))
    if d:
        os.makedirs(d, exist_ok=True)


def loads(text):
    return json.loads(strip(text))


def load(path):
    with open(resolve(path), encoding="utf-8") as f:
        return loads(f.read())
