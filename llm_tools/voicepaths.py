#!/usr/bin/env python3
"""voicepaths.py -- the facts a SPOKEN request's tool call is judged on, read off the disk.

    python3 -I llm_tools/voicepaths.py [--git] --cwd <dir> -- <path>...

One line of JSON on stdout, exit 0:

    {"cwd": "<real path of <dir>, or of $HOME when <dir> is not a directory>",
     "given": true | false,                    (whether <dir> itself was used)
     "paths": {"<path>": "<real path>", ...},  (each <path> taken against that cwd, every link that exists followed)
     "filters": ["<name>", ...]}               (--git: the filter drivers the REPOSITORY's own configuration defines)

LlmVoicePolicy.js judges every path twice, as written and as this resolves it, so a link into ~/.ssh is a path into ~/.ssh.
A path that does not exist resolves as far as it does (os.path.realpath, strict=False): what is not there cannot be read.

THE FILTER LIST. A repository's .git/config (and any file it includes) can name a `filter.<x>.clean` that git runs on a plain
`git diff`; the hands-free git switches each of these off with `-c filter.<x>.clean=` and its siblings. Only the scopes the
repository controls are listed (local, worktree, command); a filter of the user's own ~/.gitconfig (git-lfs) is theirs. git is
asked `config --get-regexp`, which reads configuration files and runs nothing -- no hook, no fsmonitor, no filter.

Nothing here writes. Run with -I (no user site, no script directory on sys.path).
"""
import json
import os
import subprocess
import sys


def filters_of(cwd):
    try:
        r = subprocess.run(["git", "-C", cwd, "--no-pager", "config", "--null", "--show-scope", "--name-only",
                            "--get-regexp", r"^filter\."],
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=1.5,
                           env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode not in (0, 1):
        return []
    parts = r.stdout.decode("utf-8", "replace").split("\0")
    names = set()
    for i in range(0, len(parts) - 1, 2):
        scope, key = parts[i], parts[i + 1]
        if scope in ("global", "system") or not key.startswith("filter."):
            continue
        rest = key[len("filter."):]
        if "." in rest:
            names.add(rest.rsplit(".", 1)[0])
    return sorted(names)


def main(argv):
    git = False
    cwd = ""
    i = 0
    while i < len(argv) and argv[i] != "--":
        if argv[i] == "--git":
            git = True
        elif argv[i] == "--cwd" and i + 1 < len(argv):
            i += 1
            cwd = argv[i]
        else:
            print(json.dumps({"error": "unknown argument " + argv[i]}))
            return 2
        i += 1
    words = argv[i + 1:] if i < len(argv) else []
    home = os.environ.get("HOME", "/")
    given = bool(cwd) and os.path.isabs(cwd) and os.path.isdir(cwd)
    base = os.path.realpath(cwd if given else home)
    out = {"cwd": base, "given": given, "paths": {}, "filters": []}
    for w in words:
        out["paths"][w] = os.path.realpath(os.path.join(base, w))
    if git:
        f = filters_of(base)
        if f is None:
            print(json.dumps({"error": "git config did not answer"}))
            return 1
        out["filters"] = f
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
