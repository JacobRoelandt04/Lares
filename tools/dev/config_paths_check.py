#!/usr/bin/env python3
"""Every product path to a hand-edited config names it in config/ (CLAUDE.md, "EVERY HAND-EDITED CONFIG IS config/<name>.jsonc").

    python3 tools/dev/config_paths_check.py          CONFIG_PATHS RESULT PASS | FAIL (<n> files, <offenders>)
    ARM=old python3 tools/dev/config_paths_check.py  a line naming the OLD place is fed in: must FAIL on it (CONFIG_PATHS ARMS RESULT PASS)

WHY (2026-11-12). The move to config/ rewrote the paths spelled `quickshell/<name>.jsonc` and missed the ones BUILT from a variable
(`services.configDir + "/shell.jsonc"`): the deployed shell read six configs from where they no longer were, and the user's scale
fell back to 1. Rule: a CODE line (comments skipped) of the product (modules/, lock/, shell.qml, tools/ but tools/dev/, helpers/)
that names `<name>.json` / `<name>.jsonc` of a user config must name it under config/ -- a `/config/` or `"config",` on the line, or
the folder in the variable it is built from (`configFilesDir`). `.examples/<name>.jsonc` (the templates) are not configs.
"""
import os
import re
import subprocess
import sys

NAMES = ("calendars|clipboard|idle|launcher|llm|notifications|osd|shell|silicon|stocks|system_update|weather|windowtray|wiki|"
         "screentime|locale|lockscreen|bridge|panorama|aerial|airplay|breaks|snapshots|audio|clock|notes|picker|player|power|workspaces")
# (session.json is also the notes' state file: only its .jsonc name is the config)
NAMED = re.compile(r'["/]((?:%s)\.jsonc?|session\.jsonc)["\']' % NAMES)
OK = re.compile(r'config/|"config",|\'config\',|configFilesDir|\.examples/|strip_suffix|ends_with')
# A line that only SAYS a name (a log message) is no path.
MESSAGE = re.compile(r'console\.(log|warn|error|info)\(|eprintln!|\bprint\(|\bwarn \(|\bsay \(|\bdie \(')
# Lines that name the OLD place on purpose, each with its reason.
ALLOW = {
    ("tools/shell/lares", "--file \"$LARES_CONFIG_DIR/llm.jsonc\""):
        "cleanup-marks: an earlier deploy wrote its marks in the old place, so that is where it must look",
    ("tools/session/sessionlib/state.py", '"session.jsonc")'):
        "the last part of a path that is joined over two lines, \"config\" on the one before",
    ("modules/panorama/data/EngineLink.qml", 'root.runtimeDir + "/panorama.json"'):
        "the display engine's runtime state ($XDG_RUNTIME_DIR/lares/panorama.json, written by Hyprland's engine.lua), not a config",
}
ROOTS = ("modules/", "lock/", "shell.qml", "tools/", "helpers/")
SUFFIX = (".qml", ".js", ".py", ".sh", ".rs", ".bash")


def code_lines(path, text):
    """(n, line) of the lines that are code: comment lines, docstrings, Rust doc comments and a Rust test module skipped (a test
    makes the old place on purpose)."""
    out, in_doc = [], False
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if path.endswith(".rs") and s.startswith("#[cfg(test)]"):
            break
        if path.endswith(".py") and s.startswith(('"""', "'''")):
            if not (len(s) > 3 and s.endswith(('"""', "'''"))):
                in_doc = not in_doc
            continue
        if in_doc or not s or s.startswith(("//", "#", "*", "/*")):
            continue
        out.append((n, line))
    return out


def offenders(files):
    bad = []
    for path, text in files:
        for n, line in code_lines(path, text):
            if NAMED.search(line) and not OK.search(line) and not MESSAGE.search(line) \
                    and not any(path == f and needle in line for (f, needle) in ALLOW):
                bad.append("%s:%d: %s" % (path, n, line.strip()[:140]))
    return bad


def tracked():
    names = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split()
    keep = [f for f in names if f.startswith(ROOTS) and not f.startswith("tools/dev/") and (f.endswith(SUFFIX) or "/" not in f)
            and os.path.isfile(f)]
    # the shell's own tools without a suffix (lares, themectl)
    keep += [f for f in names if f in ("tools/shell/lares", "tools/shell/lares-supervise", "tools/theme/themectl")]
    out = []
    for f in sorted(set(keep)):
        try:
            out.append((f, open(f, encoding="utf-8").read()))
        except (OSError, UnicodeDecodeError):
            pass
    return out


def main():
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    files = tracked()
    if os.environ.get("ARM") == "old":
        files.append(("modules/shell/Armed.qml", '        configPath: services.configDir + "/shell.jsonc"\n'))
    bad = offenders(files)
    for b in bad:
        print("  " + b)
    if os.environ.get("ARM") == "old":
        ok = any(b.startswith("modules/shell/Armed.qml") for b in bad)
        print("ARM old: %s" % ("failed as it must" if ok else "STAYED GREEN -- the check cannot see the old place"))
        print("CONFIG_PATHS ARMS RESULT %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok else 1
    print("CONFIG_PATHS RESULT %s (%d files, %d naming a config outside config/)" % ("PASS" if not bad else "FAIL", len(files), len(bad)))
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
