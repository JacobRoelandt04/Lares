"""The pool index (`index.json`): one row per entry, written by the tool only, read by the QML service.

    { "v": 1, "tabs": { "discover": [row...], "deepen": [row...] } }
    row = { id, slug, family, topic, kind, fetchedAt, popularityBand, jevScore }

Every change is read-modify-write under a flock on `index.json.lock` and lands through an atomic
write, so two batches (one per tab) and a reader never see half a file.
"""
from . import atomic, paths

VERSION = 1
ROW_KEYS = ("id", "slug", "family", "topic", "kind", "fetchedAt", "popularityBand", "jevScore")


def _empty():
    return {"v": VERSION, "tabs": {t: [] for t in paths.TABS}}


def _normalise(idx):
    """Whatever was on disk, as a well-formed index (a torn or foreign file reads as empty)."""
    if not isinstance(idx, dict) or not isinstance(idx.get("tabs"), dict):
        return _empty()
    out = _empty()
    for t in paths.TABS:
        rows = idx["tabs"].get(t)
        if isinstance(rows, list):
            out["tabs"][t] = [r for r in rows if isinstance(r, dict) and r.get("id")]
    return out


def read():
    """The index; an empty one when the file is missing or unreadable."""
    return _normalise(atomic.read_json(paths.index_path(), None))


def ids(tab=None):
    """The ids present in `tab`, or in both tabs."""
    idx = read()
    tabs = (tab,) if tab else paths.TABS
    return {r["id"] for t in tabs for r in idx["tabs"][t]}


def _row(row):
    r = {k: row.get(k) for k in ROW_KEYS}
    if not r["id"]:
        raise ValueError("an index row needs an id")
    if not r["slug"]:
        r["slug"] = paths.slug(r["id"])
    r.update({k: v for k, v in row.items() if k not in ROW_KEYS})
    return r


def add_rows(tab, rows):
    """Add rows to `tab`; a row whose id is already there replaces it in place. Returns how many rows
    were new."""
    if tab not in paths.TABS:
        raise ValueError(f"tab must be one of {paths.TABS}, not {tab!r}")
    rows = [_row(r) for r in rows]
    if not rows:
        return 0
    with atomic.Lock(paths.index_lock_path()):
        idx = read()
        cur = idx["tabs"][tab]
        pos = {r["id"]: i for i, r in enumerate(cur)}
        added = 0
        for r in rows:
            if r["id"] in pos:
                cur[pos[r["id"]]] = r
            else:
                pos[r["id"]] = len(cur)
                cur.append(r)
                added += 1
        atomic.write_json(paths.index_path(), idx)
    return added


def remove(ids_to_remove):
    """Drop rows by id from both tabs. Returns how many were removed."""
    gone = set(ids_to_remove)
    if not gone:
        return 0
    n = 0
    with atomic.Lock(paths.index_lock_path()):
        idx = read()
        for t in paths.TABS:
            keep = [r for r in idx["tabs"][t] if r["id"] not in gone]
            n += len(idx["tabs"][t]) - len(keep)
            idx["tabs"][t] = keep
        if n:
            atomic.write_json(paths.index_path(), idx)
    return n
