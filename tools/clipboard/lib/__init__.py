"""The clipboard tool's modules.

    config   defaults merged with clipboard.jsonc (or clipboard.json); the state directory
    kinds    what a copy is (link, colour, code, files, image, text) and which offered type to read
    secret   the detector that decides, before anything is written, that a copy is a secret
    store    index.json, blobs, thumbs; prune, sweep, corrupt backup; the only writer
    wl       the outside programs (wl-paste, hyprctl, cliphist), looked up on PATH
"""
import importlib.util
import os
import sys


def _load_shared(name):
    """tools/lib/<name>.py, loaded by path: this package is itself called `lib`, as the wiki's is."""
    key = "_tools_shared_" + name
    mod = sys.modules.get(key)
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib", name + ".py")
        spec = importlib.util.spec_from_file_location(key, os.path.normpath(path))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[key] = mod
        spec.loader.exec_module(mod)
    return mod


atomic = _load_shared("atomic")
jsonc = _load_shared("jsonc")
