"""Which folder a VS Code window has open (pure but for reading workspaceStorage).

One VS Code process owns every window, so the capture sees ONE app with several windows, and what VS Code reopens
by itself after a session that ended without its own quit is only the last window it had active (storage.json). The
window title names the root ("bridge.md - quickshell - Visual Studio Code", the default `window.title`; a multi-root
workspace is "<file stem> (Workspace)"), and `workspaceStorage/*/workspace.json` maps every root VS Code ever opened to
its folder (`folder`: a file:// URI) or `.code-workspace` file (`workspace`). A title is resolved against that list:
the root name must end the title before the app name; several folders of one name -> the newest storage entry; no
match -> None (never a guess; the app is then restored as before).
"""
import glob
import json
import os
import urllib.parse


def _uri_path(uri):
    if not isinstance(uri, str) or not uri.startswith("file://"):
        return None
    return urllib.parse.unquote(uri[len("file://"):])


def roots(storage_dir):
    """[(display name, path, mtime)] of every root in workspaceStorage that still exists."""
    out = []
    for f in glob.glob(os.path.join(storage_dir, "*", "workspace.json")):
        try:
            with open(f, encoding="utf-8") as h:
                j = json.load(h)
            mt = os.stat(f).st_mtime
        except (OSError, ValueError):
            continue
        if not isinstance(j, dict):
            continue
        path = _uri_path(j.get("folder"))
        if path:
            name = os.path.basename(path.rstrip("/"))
        else:
            path = _uri_path(j.get("workspace"))
            name = os.path.splitext(os.path.basename(path))[0] + " (Workspace)" if path else None
        if path and name and os.path.exists(path):
            out.append((name, path, mt))
    return out


def title_has_root(title, name, app_name):
    """Does a window title end in `<name> - <app name>` (or is it `<name> - <app name>` alone)?"""
    t = (title or "").strip()
    suffix = " - " + app_name
    if not t.endswith(suffix):
        return False
    rest = t[:-len(suffix)]
    return rest == name or rest.endswith(" - " + name)


def resolve(title, app_name, storage_dir, known=None):
    """The folder (or .code-workspace file) of a window with this title, or None."""
    best = None
    for name, path, mt in (known if known is not None else roots(storage_dir)):
        if title_has_root(title, name, app_name):
            key = (len(name), mt)               # the longest name wins ("a - b" over "b"), then the newest entry
            if best is None or key > best[0]:
                best = (key, path)
    return best[1] if best else None
