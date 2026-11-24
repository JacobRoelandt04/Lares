#!/usr/bin/env python3
"""Profile store for a mockup's control panel: one JSON file per profile.

    tools/dev/mockup_profiles.py list    <dir>
    tools/dev/mockup_profiles.py save    <dir> <name> <json>
    tools/dev/mockup_profiles.py delete  <dir> <name>
    tools/dev/mockup_profiles.py default <dir> <json>

`list` prints one JSON object with every profile's contents, so the panel
can apply a profile without another round trip:

    {"names": ["default", "warm", "tight-swirl"], "profiles": {"warm": {...}, ...}}

A profile is `{"<listId>": {"<prop>": value}}` -- the same shape
tools/dev/mockup_save_defaults.py takes -- plus a `_meta` entry the panel ignores.
Names are limited to letters, digits, space, dot, dash and underscore, so a
name is always a plain file name inside <dir>.

`default` writes the reserved `default.json`: every registered entry at its
`val:` in the mockup file. It is DERIVED, rewritten from the QML at every
launch, and it is what a module deployed into the bar reads instead of the
mockup's QML -- so `save` and `delete` refuse that name. A tuning set that
lived there would be overwritten at the next launch without a word.
"""
import json
import os
import re
import sys
import time

NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}")

# The derived profile. Reserved on this side too, so the rule holds for a
# hand-run command and not only for the panel's buttons.
DEFAULT_NAME = "default"


def die(msg, code=1):
    print(msg, file=sys.stderr)
    return code


def is_default(name):
    return name.strip().lower() == DEFAULT_NAME


def path_for(d, name):
    if not NAME_RE.fullmatch(name):
        raise ValueError("bad profile name %r" % name)
    return os.path.join(d, name + ".json")


def write_json(p, obj):
    os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, p)


def cmd_list(d):
    names = []
    profiles = {}
    if os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json") or fn.startswith("."):
                continue
            name = fn[:-5]
            try:
                with open(os.path.join(d, fn), encoding="utf-8") as f:
                    obj = json.load(f)
            except (OSError, ValueError) as e:
                print("skipping %s: %s" % (fn, e), file=sys.stderr)
                continue
            if not isinstance(obj, dict):
                continue
            obj.pop("_meta", None)
            names.append(name)
            profiles[name] = obj
    print(json.dumps({"names": names, "profiles": profiles}))
    return 0


def cmd_save(d, name, payload):
    if is_default(name):
        return die("%s holds the mockup's val: entries and is rewritten at "
                   "every launch; save under another name" % DEFAULT_NAME)
    p = path_for(d, name)
    obj = json.loads(payload)
    if not isinstance(obj, dict):
        return die("profile must be a JSON object")
    obj["_meta"] = {"saved": time.strftime("%Y-%m-%d %H:%M:%S")}
    write_json(p, obj)
    print("saved " + name)
    return 0


def cmd_delete(d, name):
    if is_default(name):
        return die("%s holds the mockup's val: entries and is rewritten at "
                   "every launch; it cannot be deleted" % DEFAULT_NAME)
    p = path_for(d, name)
    if not os.path.exists(p):
        return die("no profile " + name)
    os.remove(p)
    print("deleted " + name)
    return 0


def cmd_default(d, payload):
    obj = json.loads(payload)
    if not isinstance(obj, dict):
        return die("default profile must be a JSON object")
    # Whatever was there is replaced: regenerating it from the QML on every
    # launch is the only thing that keeps it honest with the `val:` entries.
    obj["_meta"] = {
        "derived": "the mockup's val: entries",
        "note": "rewritten at every mockup launch; edit the QML, not this file",
        "written": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    write_json(os.path.join(d, DEFAULT_NAME + ".json"), obj)
    print("wrote " + DEFAULT_NAME)
    return 0


def main(argv):
    try:
        if len(argv) == 3 and argv[1] == "list":
            return cmd_list(argv[2])
        if len(argv) == 5 and argv[1] == "save":
            return cmd_save(argv[2], argv[3], argv[4])
        if len(argv) == 4 and argv[1] == "delete":
            return cmd_delete(argv[2], argv[3])
        if len(argv) == 4 and argv[1] == "default":
            return cmd_default(argv[2], argv[3])
    except (ValueError, OSError) as e:
        return die(str(e))
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
