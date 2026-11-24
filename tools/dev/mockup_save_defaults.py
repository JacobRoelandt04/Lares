#!/usr/bin/env python3
"""Write tweaked control-panel values back into a mockup's `val:` defaults.

    tools/dev/mockup_save_defaults.py <mockup.qml> <json>  [--dry-run]

<json> is either a path to a JSON file or the JSON text itself (it starts
with `{`). Two shapes are accepted:

    {"railParams": {"orbitRadius": 12, "glowMax": 2.4},
     "popupColors": {"accent": "#4480F4"}}          # keyed by list, then prop

    {"orbitRadius": 12, "accent": "#4480F4"}         # prop only

With the first shape each prop is looked up inside that list's array
(`readonly property var railParams: [ ... ]`), so a prop name that exists on
two targets -- `surfaceColor` on the popup and on the rail -- is unambiguous.
With the second the whole file is searched and a prop that matches more than
one entry is refused.

For each prop the script finds the entry object holding `prop: "<name>"` and
rewrites that entry's `val:` literal only: numbers as bare literals (`12`,
`0.35`, never `12.0`), colours as `"#RRGGBB"` / `"#AARRGGBB"`, booleans as
`true` / `false`, any other string (a text or JSON row's text, a colour's
`"@<token>"`) as a JSON-escaped string literal -- except over a colour: an
entry whose val is a hex colour takes only a colour or `"@<token>"`. Every other byte of the file is left as it was, and a value
that is already the literal in the file is reported as unchanged. Running it
twice with the same input changes nothing the second time.
"""
import json
import os
import re
import sys

PROP_RE = re.compile(r'\bprop:\s*"([A-Za-z_][A-Za-z0-9_]*)"')
VAL_RE = re.compile(r'\bval:\s*("(?:[^"\\]|\\.)*"|true\b|false\b'
                    r'|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)')


def skip_string(text, i):
    """i points at an opening quote; return the index just past the closing one."""
    q = text[i]
    i += 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == q:
            return i + 1
        i += 1
    return i


def object_bounds(text, pos):
    """Bounds [start, end) of the innermost {...} enclosing `pos`.

    Brace-matches while skipping string literals, so a tip containing a brace
    cannot throw the scan off."""
    depth = 0
    start = -1
    i = pos
    while i >= 0:
        c = text[i]
        if c in "\"'":
            # Walk back to the opening quote of this literal.
            j = i - 1
            while j >= 0 and not (text[j] == c and text[j - 1] != "\\"):
                j -= 1
            i = j - 1
            continue
        if c == "}":
            depth += 1
        elif c == "{":
            if depth == 0:
                start = i
                break
            depth -= 1
        i -= 1
    if start < 0:
        return None
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c in "\"'":
            i = skip_string(text, i)
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
        i += 1
    return None


def array_bounds(text, list_name):
    """Bounds of `property var <list_name>: [ ... ]`, or None."""
    m = re.search(r'\bproperty\s+var\s+' + re.escape(list_name) + r'\s*:\s*\[', text)
    if not m:
        return None
    start = m.end() - 1
    depth = 0
    i = start
    while i < len(text):
        c = text[i]
        if c in "\"'":
            i = skip_string(text, i)
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return start, i + 1
        i += 1
    return None


HEX_RE = re.compile(r"#(?:[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})")
TOKEN_RE = re.compile(r"@[A-Za-z_][A-Za-z0-9_]*")


def format_value(value):
    # Before the int check, not after: in Python a bool IS an int, so a
    # switch saved after this test would land in the file as `val: 1` and
    # come back as a slider.
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        if HEX_RE.fullmatch(value):
            return '"' + value.upper() + '"'
        # A text row's words, a JSON row's text, a colour's "@<token>": a
        # JSON string is a valid JS string literal, escapes and all.
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if value == int(value) and abs(value) < 1e15:
            return str(int(value))
        return repr(value)
    raise ValueError("unsupported value %r" % (value,))


def find_entries(text, name, region):
    """Every entry object in `region` whose prop is `name`: list of (start, end)."""
    lo, hi = region
    out = []
    for m in PROP_RE.finditer(text, lo, hi):
        if m.group(1) != name:
            continue
        b = object_bounds(text, m.start())
        if b and b[0] >= lo and b[1] <= hi:
            out.append(b)
    return out


def apply_changes(qml_path, changes, dry=False):
    """Rewrite the `val:` literals `changes` names in `qml_path`.

    -> (lines, changed, errors): `lines` are the report, one `set` / `same` / `SKIP` line per prop, as
    main() prints them (tools/dev/mockup_promote.py prints the same lines when it saves a mockup AND the
    module); `changed` counts the props written, `errors` those skipped."""
    out = []
    with open(qml_path, encoding="utf-8", newline="") as f:
        text = f.read()

    # Flatten to (list_name or None, prop, value).
    flat = []
    for k, v in changes.items():
        if isinstance(v, dict):
            for p, val in v.items():
                flat.append((k, p, val))
        else:
            flat.append((None, k, v))

    # Locate every edit first, then apply from the end so offsets stay valid.
    edits = []
    errors = 0
    for list_name, prop, value in flat:
        try:
            literal = format_value(value)
        except ValueError as e:
            out.append("SKIP %s: %s" % (prop, e))
            errors += 1
            continue
        if list_name:
            region = array_bounds(text, list_name)
            if not region:
                out.append("SKIP %s.%s: no array `property var %s`" % (list_name, prop, list_name))
                errors += 1
                continue
        else:
            region = (0, len(text))
        entries = find_entries(text, prop, region)
        where = ("%s." % list_name if list_name else "") + prop
        if not entries:
            out.append("SKIP %s: no entry with prop: \"%s\"" % (where, prop))
            errors += 1
            continue
        if len(entries) > 1:
            out.append("SKIP %s: %d entries match; key the JSON by list" % (where, len(entries)))
            errors += 1
            continue
        s, e = entries[0]
        vm = VAL_RE.search(text, s, e)
        if not vm:
            out.append("SKIP %s: entry has no val:" % where)
            errors += 1
            continue
        old = vm.group(1)
        # A colour entry stays a colour: a text over a hex val is a caller's
        # mistake (a colour list is known by its string val), never a save.
        if HEX_RE.fullmatch(old.strip('"')) and not (HEX_RE.fullmatch(literal.strip('"'))
                                                    or TOKEN_RE.fullmatch(literal.strip('"'))):
            out.append("SKIP %s: a colour entry takes #RRGGBB or @token, not %s" % (where, literal))
            errors += 1
            continue
        if old == literal:
            out.append("same %s: val: %s" % (where, old))
            continue
        edits.append((vm.start(1), vm.end(1), literal, where, old))

    edits.sort(reverse=True)
    for s, e, literal, where, old in edits:
        text = text[:s] + literal + text[e:]
        out.append("set  %s: val: %s -> %s" % (where, old, literal))

    if edits and not dry:
        tmp = qml_path + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        os.replace(tmp, qml_path)
    return out, len(edits), errors


def main(argv):
    dry = "--dry-run" in argv
    args = [a for a in argv[1:] if a != "--dry-run"]
    if len(args) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    qml_path, payload = args
    if payload.lstrip().startswith("{"):
        changes = json.loads(payload)
    else:
        with open(payload, encoding="utf-8") as f:
            changes = json.load(f)
    lines, changed, errors = apply_changes(qml_path, changes, dry)
    for line in lines:
        print(line)
    print("%d changed, %d skipped%s" % (changed, errors, " (dry run)" if dry else ""))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
