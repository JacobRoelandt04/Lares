"""Atomic files and flocks: the wiki's view of the shared `tools/lib/atomic.py`.

The implementation moved there so the clipboard tool uses the same one (one material, no copy). What
stays here is the wiki's rule: its `write_json` scrubs the text with `env.scrub`, so a file never holds
the Jev key whatever a caller put in the object. The shared module is loaded by path because each tool
has its own package called `lib`.
"""
import importlib.util
import os
import sys

from . import env

_NAME = "_tools_shared_atomic"
_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib", "atomic.py")


def _shared():
    mod = sys.modules.get(_NAME)
    if mod is None:
        spec = importlib.util.spec_from_file_location(_NAME, os.path.normpath(_PATH))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[_NAME] = mod
        spec.loader.exec_module(mod)
    return mod


_a = _shared()
Busy = _a.Busy
Lock = _a.Lock
_fsync_dir = _a._fsync_dir


def write_bytes(path, data):
    _a.write_bytes(path, data)            # looked up at call time: a patched shared module is the one that runs


def read_json(path, default=None):
    return _a.read_json(path, default)


def write_json(path, obj, indent=1):
    """The shared write_json with the wiki's scrub applied to the text first."""
    _a.write_json(path, obj, indent=indent, scrub=env.scrub)
