"""Configuration and paths.

`clipboard.jsonc` (or the older `clipboard.json`; the .jsonc wins when both exist, comments allowed in either) is the
user's file; every key is optional and takes the default below, so a half-written
file (or none) never stops the tool. A value of the wrong type is ignored for that key rather than
trusted: the tool runs once per copy and a bad config must not turn into a stream of errors.
"""
import copy
import os

from . import jsonc

DEFAULTS = {
    "maxItems": 1000, "maxAgeDays": 30, "maxImageMB": 25, "maxTotalMB": 500, "thumbPx": 320,
    "thumbsMax": 48,
    "textIndexKB": 16,
    "secrets": {"ttlS": 120, "dropOnLock": True, "dropOnSourceClear": True,
                "heuristic": True, "threshold": 0.5},
    "ignoreApps": [],
    "sealApps": ["Proton Pass", "proton-pass"],
    "pasteKeys": {"default": "CTRL,V",
                  "classes": {"kitty": "CTRL SHIFT,V", "foot": "CTRL SHIFT,V", "Alacritty": "CTRL SHIFT,V",
                              "org.wezfurlong.wezterm": "CTRL SHIFT,V", "com.mitchellh.ghostty": "CTRL SHIFT,V"}},
    "reofferOnClose": True,
    "openOverFullscreen": True,
    "pasteDelayMs": 120,                 # after the popup lets go of the keyboard, before the paste key
    "enter": "paste",
    "joiner": "\n",
    "copyOnClose": True,
    "restoreAtStart": True,
    "pinnedFirst": True,
    "openOn": "all",
    "undoSec": 8,
}
# What a value of the right kind may be.
RANGE = {
    "enter": lambda v: v in ("paste", "copy"),
    "openOn": lambda v: v in ("all", "text", "image", "link", "pinned"),
    "undoSec": lambda v: 1 <= v <= 120,
}
MAX_OTHER_BYTES = 8 * 1024 * 1024        # anything that is not an image


def state_dir(env=None):
    env = os.environ if env is None else env
    if env.get("CLIP_STATE"):
        return env["CLIP_STATE"]
    base = env.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "lares", "clipboard")


def config_path(env=None):
    env = os.environ if env is None else env
    if env.get("CLIP_CONFIG"):
        return env["CLIP_CONFIG"]
    base = env.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "quickshell", "config", "clipboard.jsonc")


def _same_kind(a, b):
    if isinstance(b, bool) or isinstance(a, bool):
        return isinstance(a, bool) and isinstance(b, bool)
    if isinstance(b, (int, float)):
        return isinstance(a, (int, float))
    return isinstance(a, type(b))


def _merge(default, user):
    out = copy.deepcopy(default)
    if not isinstance(user, dict):
        return out
    for key, val in user.items():
        if key not in default:
            continue                                  # an unknown key is not ours to carry
        dv = default[key]
        if isinstance(dv, dict):
            if key == "classes":
                out[key].update({k: v for k, v in val.items() if isinstance(v, str)} if isinstance(val, dict) else {})
            else:
                out[key] = _merge(dv, val)
        elif _same_kind(val, dv):
            out[key] = val
    return out


def _merge_paste_keys(user):
    base = _merge({k: v for k, v in DEFAULTS["pasteKeys"].items() if k != "classes"}, user)
    classes = copy.deepcopy(DEFAULTS["pasteKeys"]["classes"])
    if isinstance(user, dict) and isinstance(user.get("classes"), dict):
        classes.update({k: v for k, v in user["classes"].items() if isinstance(v, str)})
    base["classes"] = classes
    return base


def load(path=None):
    """The merged configuration. A missing or unreadable file is the defaults."""
    path = path or config_path()
    try:
        user = jsonc.load(path)
    except (OSError, ValueError):
        user = {}
    if not isinstance(user, dict):
        user = {}
    cfg = _merge({k: v for k, v in DEFAULTS.items() if k != "pasteKeys"}, user)
    for key, fits in RANGE.items():
        if not fits(cfg[key]):
            cfg[key] = DEFAULTS[key]
    for key in ("ignoreApps", "sealApps"):
        cfg[key] = [a for a in cfg[key] if isinstance(a, str)]
    cfg["pasteKeys"] = _merge_paste_keys(user.get("pasteKeys"))
    return cfg
