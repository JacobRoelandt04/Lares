"""Run it again, or only type it?

A restored terminal's program is RUN by itself only when everything below holds; otherwise the command is written at
the prompt and the user presses Enter. The default is `type`: a program nobody listed costs one key, a risky one that
ran by itself could cost a half-done transaction.

  1. the last session ended cleanly (after a crash everything is typed: whatever ran may be why it crashed);
  2. nothing of the job runs as root;
  3. the job is ONE command (a pipeline's pieces are known, its redirections are not). A CHAIN (`cd repo; lg`,
     `cd x && claude -r`) is read as the command of it that is RUNNING: what came before is done -- the shell already
     stands where the `cd` put it -- and is never typed or run again; when commands still FOLLOW the running one, it
     and they are typed;
  4. when the bash hook recorded the typed line: it starts with a program or an alias for one (a function may do
     anything after the program on screen), it is a simple line (no ; & | < > $ ` ( )), and the program it names is
     the one that is running;
  5. the REAL argv passes a `run` rule (rules.json + the user's `run` list), and the user's `type` list does not name it.

Cases: tools/dev/session_classify_cases.tsv (python3 tools/dev/session_cases.py).
"""
import os
import re
import shlex

_META = re.compile(r"[;&|<>$`()\n]")


def _base(word):
    return os.path.basename(word or "").lstrip("-")


def _short_has(arg, letter):
    return len(arg) >= 2 and arg[0] == "-" and arg[1] != "-" and letter in arg[1:]


def _flag_match(arg, flag):
    """`-f` matches a short cluster holding f (`-fu`), `--follow` matches itself and `--follow=x`."""
    if flag.startswith("--"):
        return arg == flag or arg.startswith(flag + "=")
    if len(flag) == 2 and flag[0] == "-":
        return _short_has(arg, flag[1])
    return arg == flag


def _watch_rest(args):
    """watch's own options stripped: what it runs."""
    takes = {"-n", "--interval", "-q", "--equexit", "-s", "--shotsdir"}
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            return args[i + 1:]
        if not a.startswith("-"):
            return args[i:]
        if a in takes:
            i += 1
        i += 1
    return []


def argv_rule(argv, rules, cfg, depth=0):
    """(ok, reason) for one real argv."""
    if not argv:
        return False, "no command"
    name = _base(argv[0])
    args = argv[1:]
    if name in (cfg.get("type") or []):
        return False, "set to type in session.jsonc"
    if name in rules.get("wrappers", []):
        return False, "asks for root"
    if name in (cfg.get("run") or []):
        return True, ""
    if name in rules.get("interpreters", []) and any(not a.startswith("-") for a in args):
        return False, "a script"
    rule = rules.get("run", {}).get(name)
    if rule is None:
        if depth and name in rules.get("readonly", []):
            return True, ""
        return False, rules.get("type", {}).get(name) or "not on the run list"
    if rule.get("bare") and args:
        return False, "runs something (only the bare program is on the run list)"
    if rule.get("denyPlus") and any(re.match(r"^\+[^0-9]", a) for a in args):
        return False, "runs an editor command"
    for flag in rule.get("deny", []):
        if any(_flag_match(a, flag) for a in args):
            return False, "the option %s is not on the run list" % flag
    need = rule.get("need")
    if need and not any(_flag_match(a, f) for a in args for f in need):
        return False, "a one-shot command (it is only re-run while following)"
    if "sub" in rule:
        sub = next((a for a in args if not a.startswith("-")), None)
        if sub not in rule["sub"]:
            return False, rules.get("type", {}).get(name) or "changes a repository"
    if "only" in rule:
        values = rule.get("values", [])
        i = 0
        while i < len(args):
            a = args[i]
            if a.startswith("-"):
                flag = a.split("=", 1)[0]
                if flag not in rule["only"]:
                    return False, "the option %s is not on the run list" % flag
                if flag in values and "=" not in a and i + 1 < len(args) and not args[i + 1].startswith("-"):
                    i += 1
            else:
                return False, "it was started with a prompt or an argument"
            i += 1
    if rule.get("wrap"):
        rest = _watch_rest(args)
        if not rest:
            return False, "nothing to watch"
        if len(rest) == 1 and re.search(r"\s", rest[0]):
            return False, "watches a shell line"
        return argv_rule(rest, rules, cfg, depth + 1)
    return True, ""


def _typed_ok(typed, argv):
    """(ok, reason): may the typed line stand for the running program?"""
    kind, text = typed.get("kind", ""), typed.get("text", "")
    if kind not in ("file", "alias"):
        return False, {"function": "a shell function", "builtin": "a shell builtin", "keyword": "a shell construct"}.get(
            kind, "not a plain command")
    if _META.search(text):
        return False, "a compound line"
    words = text.split()
    if not words:
        return False, "not a plain command"
    running = _base(argv[0]) if argv else ""
    if kind == "alias":
        alias = typed.get("alias", "")
        if not alias.strip() or _META.search(alias):
            return False, "an alias for more than one command"
        if _base(alias.split()[0]) != running:
            return False, "the running program is not the alias's"
        return True, ""
    if _base(words[0]) != running:
        return False, "the running program is not the typed one"
    return True, ""


def split_chain(text):
    """A typed line cut at its top-level `;`, `&&`, `||` and newlines:
    [{"text", "sep" (what follows it, "" for the last), "complex" (it holds a pipe, a redirection, `&`, a subshell or an
    expansion)}], or None when its quotes do not close."""
    segs, cur, quote, complex_, i, n = [], [], None, False, 0, len(text)

    def cut(sep):
        nonlocal cur, complex_
        t = "".join(cur).strip()
        if t:
            segs.append({"text": t, "sep": sep, "complex": complex_})
        elif segs and sep and not segs[-1]["sep"]:
            segs[-1]["sep"] = sep
        cur, complex_ = [], False

    while i < n:
        c = text[i]
        if quote == "'":
            cur.append(c)
            if c == "'":
                quote = None
        elif c == "\\" and i + 1 < n:
            cur.append(text[i:i + 2])
            i += 1
        elif quote == '"':
            cur.append(c)
            if c == '"':
                quote = None
            elif c in "$`":
                complex_ = True
        elif c in "'\"":
            quote = c
            cur.append(c)
        elif text.startswith("&&", i) or text.startswith("||", i):
            cut(text[i:i + 2])
            i += 1
        elif c in ";\n":
            cut(";")
        else:
            if c in "|&<>()$`":
                complex_ = True
            cur.append(c)
        i += 1
    if quote:
        return None
    cut("")
    if segs:
        segs[-1]["sep"] = ""
    return segs


def _chain(typed, tops):
    """A typed line of several commands (`cd repo; lg`): which one is running, and what is left of the line.

    The commands before the running one are DONE -- a `cd` among them is why the shell stands where it stands -- so they
    are never typed or run again; the ones after it have not started. Returns None for a line that is one command, else
    {"text": the running command and what follows it, "typed": the mark of the running command alone (or None),
     "tail": what follows it, "why": why it is only typed (or None)}."""
    segs = split_chain(typed.get("text", ""))
    if not segs or len(segs) < 2:
        return None
    words = dict(typed.get("words") or {})
    running = {_base(t["argv"][0]) for t in tops if t.get("argv")}

    def info(seg):
        parts = seg["text"].split()
        w = parts[0] if parts else ""
        rec = words.get(w)
        if rec is None and seg is segs[0] and typed.get("kind"):
            rec = {"kind": typed.get("kind"), "alias": typed.get("alias", "")}      # a hook older than the triples
        if rec and rec.get("kind") == "alias":
            alias = rec.get("alias", "")
            target = _base(alias.split()[0]) if alias.strip() else ""
        else:
            target = _base(w)
        return rec, target

    hits = [k for k, seg in enumerate(segs) if info(seg)[1] in running]
    if len(hits) != 1:
        # Not told apart (the same program twice, or none named): the real argv is what runs, where the shell stands.
        text = shlex.join(tops[0]["argv"]) if len(tops) == 1 else typed.get("text", "")
        return {"text": text, "typed": None, "tail": "", "why": "which command of the line is running could not be told"}
    k = hits[0]
    seg, rest = segs[k], segs[k + 1:]
    tail = ""
    prev = seg
    for s in rest:
        tail += ("; " if prev["sep"] == ";" else " %s " % prev["sep"]) + s["text"]
        prev = s
    rec, _ = info(seg)
    out = {"text": seg["text"] + tail, "typed": None, "tail": tail, "why": None}
    if rest:
        out["why"] = "more commands follow it on the line"
    elif seg["complex"]:
        out["why"] = "a compound line"
    elif rec is None:
        out["why"] = "the terminal's bash hook is an older one"
    else:
        out["typed"] = {"kind": rec.get("kind", ""), "alias": rec.get("alias", ""), "text": seg["text"]}
    return out


def command_text(job):
    """What a shell needs to run the job again: the typed line when there is one, else the real argv."""
    typed = job.get("typed")
    if typed and typed.get("text", "").strip():
        return typed["text"]
    tops = job.get("tops") or []
    return " | ".join(shlex.join(t["argv"]) for t in tops)


def classify(job, rules, cfg, clean=True, why_unclean="the last session did not end cleanly", claude="resume"):
    """{"mode": "run" | "type", "command": text, "reason": why it is only typed ("" when run)}

    `claude` (session.jsonc `claude` for a restore, `presets.claude` for a preset load): a Claude Code job the run list
    accepts -- `claude`, `claude --resume <id>`, `-r`, `--continue` -- comes back as its own conversation ("resume"), as a
    bare `claude`, a fresh session in the same directory ("fresh": a preset is a layout, not a pointer into one
    conversation; the session id stays out of it -- store facts, judge with today's rules), or as "resume" typed ("type")."""
    tops = job.get("tops") or []
    is_claude = len(tops) == 1 and bool(tops[0].get("argv")) and _base(tops[0]["argv"][0]) == "claude"
    fresh = bool(claude == "fresh" and is_claude and argv_rule(tops[0]["argv"], rules, cfg)[0])
    if fresh:
        job = dict(job, claude=None)
    text = command_text(job)
    if not text.strip():
        return {"mode": "none", "command": "", "reason": "no command could be read"}
    typed = job.get("typed") if (job.get("typed") or {}).get("text", "").strip() else None
    chain = _chain(typed, tops) if typed else None
    tail = ""
    if chain:
        text, typed, tail = chain["text"], chain["typed"], chain["tail"]
    out = {"mode": "type", "command": text, "reason": ""}

    verdict = None
    if job.get("root"):
        verdict = "runs as root"
    elif chain and chain["why"]:
        verdict = chain["why"]
    elif len(tops) != 1:
        verdict = "a pipeline or several commands"
    else:
        argv = tops[0]["argv"]
        if typed:
            ok, why = _typed_ok(typed, argv)
            if not ok:
                verdict = why
        if verdict is None:
            ok, why = argv_rule(argv, rules, cfg)
            if not ok:
                verdict = why
    # Claude Code: the session on screen has an id; "claude" alone would open a new one.
    if job.get("claude") and is_claude and argv_rule(tops[0]["argv"], rules, cfg)[0]:
        out["command"] = "claude --resume " + job["claude"] + tail

    if fresh:
        out["command"] = "claude" + tail
    if verdict is None and not clean:
        verdict = why_unclean
    if verdict is None and is_claude and claude == "type":
        verdict = "session.jsonc types it"
    if verdict is None:
        out["mode"] = "run"
    else:
        out["reason"] = verdict
    return out
