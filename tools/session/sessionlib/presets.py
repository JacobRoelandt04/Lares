"""Presets: a named picture of the whole desktop, kept until the user deletes it (docs/contracts/session.md "Presets").

    $XDG_DATA_HOME/lares/session/presets/<slug>.json    a version-1 snapshot (what `capture` makes) plus
                                                        {"preset": {"name", "created", "updated"}}   (epoch seconds)
    .../presets/.trash/<slug>.json                      a deleted one; swept at the next successful save

Outside snapshots/, so their rotation (`keep`) never touches one. Every call that writes runs under the state lock (the CLI
holds it); the files are written atomically. `slug` = the name lowercased, every run of characters outside [a-z0-9] one
"-", trimmed; two names with one slug are one preset.

The FACE is what the popup draws for a preset (or for the desktop as it is): monitors and workspaces with their windows.
"""
import contextlib
import os
import re
import time

from . import plan as planlib
from . import state as st

NAME_MAX = 40


class PresetError(Exception):
    """`reason` is the word the CLI answers with: name | exists | missing."""

    def __init__(self, reason):
        Exception.__init__(self, reason)
        self.reason = reason


def clean_name(name):
    n = (name or "").strip()
    if not 1 <= len(n) <= NAME_MAX or not slug_of(n):
        raise PresetError("name")
    return n


def slug_of(name):
    return re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")


def _ensure(paths):
    for d in (os.path.dirname(paths.presets), paths.presets):
        os.makedirs(d, mode=0o700, exist_ok=True)
        with contextlib.suppress(OSError):
            os.chmod(d, 0o700)


def _path(paths, slug, trash=False):
    return os.path.join(paths.presets_trash if trash else paths.presets, slug + ".json")


def _sweep_trash(paths):
    try:
        names = os.listdir(paths.presets_trash)
    except OSError:
        return
    for n in names:
        with contextlib.suppress(OSError):
            os.unlink(os.path.join(paths.presets_trash, n))


def load(paths, name_or_slug):
    """The stored preset (snapshot + "preset") by name, or None."""
    slug = slug_of(name_or_slug)
    if not slug:
        return None
    data = st.read_json(_path(paths, slug))
    return data if isinstance(data, dict) and isinstance(data.get("preset"), dict) else None


def save(paths, name, snap, over=False, now=None):
    """Keep `snap` (a fresh capture) as the preset `name`. Raises PresetError("name" | "exists")."""
    name = clean_name(name)
    slug = slug_of(name)
    _ensure(paths)
    old = load(paths, slug)
    if old and not over:
        raise PresetError("exists")
    now = time.time() if now is None else now
    meta = {"name": name, "created": (old or {}).get("preset", {}).get("created", now), "updated": now}
    body = {k: v for k, v in snap.items() if k not in ("id", "reason")}
    body["preset"] = meta
    st.write_json(_path(paths, slug), body)
    _sweep_trash(paths)
    return slug


def rename(paths, old, new, now=None):
    new = clean_name(new)
    old_slug, new_slug = slug_of(old), slug_of(new)
    cur = load(paths, old_slug)
    if not cur:
        raise PresetError("missing")
    if new_slug != old_slug and load(paths, new_slug):
        raise PresetError("exists")
    cur["preset"] = dict(cur["preset"], name=new, updated=time.time() if now is None else now)
    st.write_json(_path(paths, new_slug), cur)
    if new_slug != old_slug:
        with contextlib.suppress(OSError):
            os.unlink(_path(paths, old_slug))
    return new_slug


def delete(paths, name):
    slug = slug_of(name)
    if not slug or not load(paths, slug):
        raise PresetError("missing")
    os.makedirs(paths.presets_trash, mode=0o700, exist_ok=True)
    os.replace(_path(paths, slug), _path(paths, slug, True))
    return slug


def undelete(paths, name):
    slug = slug_of(name)
    trashed = _path(paths, slug, True)
    if not slug or not os.path.exists(trashed):
        raise PresetError("missing")
    if load(paths, slug):
        raise PresetError("exists")
    os.replace(trashed, _path(paths, slug))
    return slug


def all_presets(paths):
    """Every stored preset, sorted by name (case-insensitive)."""
    out = []
    try:
        names = os.listdir(paths.presets)
    except OSError:
        names = []
    for n in names:
        if not n.endswith(".json"):
            continue
        data = st.read_json(os.path.join(paths.presets, n))
        if isinstance(data, dict) and isinstance(data.get("preset"), dict):
            out.append((n[:-5], data))
    out.sort(key=lambda sd: (sd[1]["preset"].get("name", sd[0]).lower(), sd[0]))
    return out


# -- the face ----------------------------------------------------------------------------------------------------------
def _ws_sort(ws):
    key = ws["key"]
    return (2 if ws["special"] else 0 if str(key).isdigit() else 1, int(key) if str(key).isdigit() else 0, str(key))


def face(snap):
    """{"monitors": [{name, w, h}], "workspaces": [{key, name, special, monitor, windows: [...]}]} of a snapshot.
    Monitor sizes are LOGICAL (pixels / scale); a window's `at` is relative to its monitor, its size as stored."""
    monitors = []
    for m in snap.get("monitors", []):
        scale = m.get("scale") or 1
        monitors.append({"name": m.get("name"), "w": int(round(m.get("width", 0) / scale)),
                         "h": int(round(m.get("height", 0) / scale))})
    group_size = {}
    for w in snap.get("windows", []):
        g = w.get("group")
        if g:
            group_size[g["id"]] = group_size.get(g["id"], 0) + 1
    spaces = {}
    for w in sorted(snap.get("windows", []), key=planlib._order):
        k = w["workspace"]["key"]
        ws = spaces.get(k)
        if not ws:
            ws = spaces[k] = {"key": str(k), "name": w["workspace"].get("name") or str(k),
                              "special": bool(w["workspace"].get("special")), "monitor": w.get("monitor"), "windows": []}
        g = w.get("group")
        ws["windows"].append({
            "class": w.get("class"), "title": w.get("title"), "at": list(w.get("at") or [0, 0]),
            "size": list(w.get("size") or [0, 0]), "floating": bool(w.get("floating")),
            "fullscreen": int(w.get("fullscreen") or 0), "pinned": bool(w.get("pinned")),
            "group": {"id": g["id"], "index": g["index"], "active": bool(g["active"]), "size": group_size[g["id"]],
                      "locked": bool(g.get("locked"))} if g else None,
        })
    return {"monitors": monitors, "workspaces": sorted(spaces.values(), key=_ws_sort)}


def counts(snap):
    wins = snap.get("windows", [])
    return {"windows": len(wins), "workspaces": len({str(w["workspace"]["key"]) for w in wins})}


def listing(paths):
    out = []
    for slug, data in all_presets(paths):
        meta = data["preset"]
        out.append(dict({"name": meta.get("name", slug), "slug": slug, "created": meta.get("created"),
                         "updated": meta.get("updated")}, **counts(data), face=face(data)))
    return out
