#!/usr/bin/env python3
"""Edit the bridge probe's world file (the fake KDE Connect and the fake adb both read it).

    world.py <file> set <dotted.path> <json>      world.py <file> get <dotted.path>
"""
import json
import os
import sys


def load(p):
    try:
        with open(p) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(p, w):
    tmp = p + ".%d.tmp" % os.getpid()
    with open(tmp, "w") as f:
        json.dump(w, f)
    os.replace(tmp, p)


def set_path(w, path, value):
    parts = path.split(".")
    for k in parts[:-1]:
        w = w.setdefault(k, {})
    w[parts[-1]] = value


def get_path(w, path):
    for k in path.split("."):
        w = w.get(k) if isinstance(w, dict) else None
    return w


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 4 and a[1] == "set":
        w = load(a[0])
        set_path(w, a[2], json.loads(a[3]))
        save(a[0], w)
    elif len(a) == 3 and a[1] == "get":
        print(json.dumps(get_path(load(a[0]), a[2])))
    else:
        sys.exit(__doc__)
