#!/usr/bin/env python3
"""file_root_names.py -- the names a `file:` root could resolve differently (shell.qml's stub, shell.jsonc `workarounds.fileRoot`).

Loaded from `file:`, a QML file's own directory (Qt's implicit import) LOSES to a module it imports when both name a type: ShellMain's
`ShellScreen` became Quickshell's uncreatable ShellScreen ("ShellScreen can only be obtained via Quickshell.screens"), where on
Quickshell's `qs:` scheme the scanner's qmldir made the local file win. A collision is not always a load failure: a creatable module
type with the same properties would be used in silence, and a file a Loader builds later fails only when it is opened.

So: for every .qml under the given roots that USES a type name (`Name {` or `Name.` at a word start) which is BOTH a file of its own
directory (Name.qml, or a qmldir line there) AND exported by a module the file imports unqualified, the file must import its own
directory explicitly AFTER that module (`import "."`, which outranks it) -- else it is listed. A directory import of another directory
("../x") is checked the same way: the later import wins.

    python3 tools/dev/file_root_names.py [root ...]        (default: modules shell.qml)
Ends in `FILE_ROOT_NAMES RESULT PASS|FAIL`. ARM=noimport drops ShellMain's `import "."` in memory: PASS when that collision is found.
"""
import glob
import os
import re
import sys

QML = "/usr/lib/qt6/qml"


def module_exports():
    """{module uri: set(type names)} from every installed qmltypes and qmldir"""
    ex = {}
    for f in glob.glob(QML + "/**/*.qmltypes", recursive=True):
        for m in re.finditer(r'exports:\s*\[([^\]]*)\]', open(f, errors="replace").read()):
            for e in re.findall(r'"([^"/]+)/([A-Za-z_][A-Za-z0-9_]*) ', m.group(1)):
                ex.setdefault(e[0], set()).add(e[1])
    for f in glob.glob(QML + "/**/qmldir", recursive=True):
        uri = None
        for line in open(f, errors="replace"):
            w = line.split()
            if len(w) >= 2 and w[0] == "module":
                uri = w[1]
            elif uri and len(w) >= 3 and w[0] in ("singleton",) and w[1][:1].isupper():
                ex.setdefault(uri, set()).add(w[1])
            elif uri and len(w) >= 3 and w[0][:1].isupper() and w[2].endswith(".qml"):
                ex.setdefault(uri, set()).add(w[0])
    return ex


def local_names(d):
    names = {os.path.basename(p)[:-4] for p in glob.glob(os.path.join(d, "*.qml")) if os.path.basename(p)[:1].isupper()}
    q = os.path.join(d, "qmldir")
    if os.path.exists(q):
        names = set()
        for line in open(q):
            w = line.split()
            if len(w) >= 3 and w[0] == "singleton":
                names.add(w[1])
            elif len(w) >= 3 and w[0][:1].isupper() and w[2].endswith(".qml"):
                names.add(w[0])
    return names


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', ' ', s, flags=re.S)
    s = re.sub(r'(?m)//.*$', '', s)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', s)


def main():
    roots = [a for a in sys.argv[1:]] or ["modules", "shell.qml"]
    arm = os.environ.get("ARM", "")
    ex = module_exports()
    files = []
    for r in roots:
        files += [r] if r.endswith(".qml") else glob.glob(os.path.join(r, "**", "*.qml"), recursive=True)
    bad = 0
    any_shellmain = [False]
    for f in sorted(files):
        if "/fixtures/" in f:
            continue
        text = open(f, errors="replace").read()
        if arm == "noimport" and f.endswith("modules/shell/ShellMain.qml"):
            text = text.replace('import "."\n', '')
        d = os.path.dirname(os.path.abspath(f))
        # the imports in order: ("mod", uri) | ("dir", abs dir)   (qualified imports cannot collide)
        imps = []
        for m in re.finditer(r'(?m)^\s*import\s+("([^"]+)"|([A-Za-z][\w.]*))[^\n]*$', text):
            line = m.group(0)
            if re.search(r'\bas\s+\w+\s*$', line):
                continue
            if m.group(2) is not None:
                if m.group(2).endswith(".js"):
                    continue
                imps.append(("dir", os.path.normpath(os.path.join(d, m.group(2)))))
            else:
                imps.append(("mod", m.group(3)))
        body = strip_comments(text)
        used = set(re.findall(r'(?<![\w.])([A-Z][A-Za-z0-9_]*)\s*(?:\{|\.)', body))
        own = local_names(d) - {os.path.basename(f)[:-4]}
        for name in sorted(used & own):
            # who would win on file: the LAST explicit import that has it; the implicit own directory only when none has it
            winner = ("dir", d)
            for kind, what in imps:
                if kind == "mod" and name in ex.get(what, ()):
                    winner = (kind, what)
                elif kind == "dir" and name in local_names(what):
                    winner = (kind, what)
            if winner != ("dir", d):
                bad += 1
                if f.endswith("modules/shell/ShellMain.qml") and name == "ShellScreen":
                    any_shellmain[0] = True
                print(f"FILE_ROOT_NAMES {f}: `{name}` is {os.path.relpath(d)}/{name}.qml on qs:, but {winner[1]}'s on file: "
                      f"(add `import \".\"` after it)")
    print(f"FILE_ROOT_NAMES {len(files)} files")
    if arm == "noimport":
        ok = any_shellmain[0]
        print("FILE_ROOT_NAMES RESULT %s (ARM noimport: %s)" % ("PASS" if ok else "FAIL",
              "ShellMain's ShellScreen found as it must be" if ok else "NOT FOUND -- the check cannot see it"))
        return 0 if ok else 1
    if bad:
        print(f"FILE_ROOT_NAMES RESULT FAIL ({bad} names)")
        return 1
    print("FILE_ROOT_NAMES RESULT PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
