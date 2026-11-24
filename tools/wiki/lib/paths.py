"""Where everything lives (CONTRACT.md "Paths") and how an entry id becomes a file name.

Every directory is computed at CALL time from XDG_STATE_HOME / XDG_CACHE_HOME / XDG_CONFIG_HOME, so a
probe that sets private ones (it must: CLAUDE.md, a test must never write the user's state) is
honoured whenever it sets them. Getters never create anything; the writers (atomic.py) make the
parent directory.
"""
import hashlib
import json
import os
import re
import unicodedata

TABS = ("discover", "deepen")
SLUG_MAX_BYTES = 150       # of the slug; the longest suffix added to it is "-9-thumb.jpg", far under NAME_MAX


def _home():
    return os.path.expanduser("~")


def state_home():
    return os.environ.get("XDG_STATE_HOME") or os.path.join(_home(), ".local", "state")


def cache_home():
    return os.environ.get("XDG_CACHE_HOME") or os.path.join(_home(), ".cache")


def config_home():
    return os.environ.get("XDG_CONFIG_HOME") or os.path.join(_home(), ".config")


# ----------------------------------------------------------------------------- state (tool-written)

def state_dir():
    return os.path.join(state_home(), "lares", "wiki")


def entries_dir(tab):
    _check_tab(tab)
    return os.path.join(state_dir(), "entries", tab)


def entry_path(tab, ident):
    """Entry file for an id (`en.wikipedia.org/Battle_of_Hastings`) or an already-made slug."""
    name = ident if _is_slug(ident) else slug(ident)
    return os.path.join(entries_dir(tab), name + ".json")


def img_dir():
    return os.path.join(state_dir(), "img")


def index_path():
    return os.path.join(state_dir(), "index.json")


def index_lock_path():
    return os.path.join(state_dir(), "index.json.lock")


def state_path():
    """state.json belongs to the QML service; the tool only ever reads it."""
    return os.path.join(state_dir(), "state.json")


def batch_dir():
    return os.path.join(state_dir(), "batch")


def progress_path(tab):
    _check_tab(tab)
    return os.path.join(batch_dir(), tab + ".progress.json")


def lock_path(tab):
    _check_tab(tab)
    return os.path.join(batch_dir(), tab + ".lock")


# ----------------------------------------------------------------------------- cache (disposable)

def cache_dir():
    return os.path.join(cache_home(), "lares", "wiki")


def daily_path(day):
    return os.path.join(cache_dir(), "daily", str(day) + ".json")


def live_path(ident):
    return os.path.join(cache_dir(), "live", (ident if _is_slug(ident) else slug(ident)) + ".json")


def arch_titles_path():
    return os.path.join(cache_dir(), "arch_titles.json")


def kernel_docs_path():
    return os.path.join(cache_dir(), "kernel_docs.json")


# ----------------------------------------------------------------------------- user config (it holds the Jev key: lib/env.py)

def config_dir():
    return os.path.join(config_home(), "quickshell")


def config_path():
    """The user's wiki config, where the shell reads it (tools/lib/jsonc.py, ConfigFile): config/wiki.jsonc, the .json beside it,
    then the old places in the config's root (wiki.jsonc, wiki.json); the first that exists, else config/wiki.jsonc."""
    cands = [os.path.join(config_dir(), "config", "wiki.jsonc"), os.path.join(config_dir(), "config", "wiki.json"),
             os.path.join(config_dir(), "wiki.jsonc"), os.path.join(config_dir(), "wiki.json")]
    return next((c for c in cands if os.path.exists(c)), cands[0])


# ----------------------------------------------------------------------------- the repository

def tools_dir():
    """tools/wiki (this file is tools/wiki/lib/paths.py)."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def repo_root():
    return os.path.dirname(os.path.dirname(tools_dir()))


def data_path(name):
    return os.path.join(tools_dir(), "data", name)


def families_path():
    return os.path.join(repo_root(), "modules", "wiki", "data", "families.json")


_json_cache = {}


def _load_json(path):
    key = (path, os.stat(path).st_mtime_ns)
    if key not in _json_cache:
        with open(path, encoding="utf-8") as f:
            _json_cache[key] = json.load(f)
    return _json_cache[key]


def families():
    """families.json: the one source of families for QML, node and Python."""
    return _load_json(families_path())


def static_pages():
    """tools/wiki/data/static_pages.json: the curated lists (why each is there is in the file)."""
    return _load_json(data_path("static_pages.json"))


# ----------------------------------------------------------------------------- slugs

_UNSAFE = re.compile(r"[^\w.()',+&@!=~-]")   # \w is Unicode: letters, digits, "_"


def _is_slug(s):
    return "/" not in s and "#" not in s


def slug(ident):
    """Host-prefixed, filesystem-safe, deterministic file stem for an entry id.

        en.wikipedia.org/Battle_of_Hastings        -> en.wikipedia.org__Battle_of_Hastings
        wiki.archlinux.org/Pacman#Tips_and_tricks  -> wiki.archlinux.org__Pacman--Tips_and_tricks
        wiki.gentoo.org/Xfce/Guide                 -> wiki.gentoo.org__Xfce__Guide

    "/" becomes "__" (MediaWiki collapses "__" inside a title, so `A/B` and `A__B` cannot meet) and
    "#" becomes "--" (a "#" would end a file:// URL). Unicode letters stay (NFC-normalised). Any other
    character that is unsafe in a path, a shell or a URL becomes "_", which is lossy, so a hash of the
    original id is appended whenever that happened. Over SLUG_MAX_BYTES (UTF-8, because NAME_MAX is
    in bytes) the stem is cut at a character boundary and the same hash is appended.
    """
    s = unicodedata.normalize("NFC", ident.strip())
    s = s.replace("/", "__").replace("#", "--")
    safe = _UNSAFE.sub("_", s)
    tag = ""
    if safe != s or len(safe.encode("utf-8")) > SLUG_MAX_BYTES:
        tag = "~" + hashlib.sha1(unicodedata.normalize("NFC", ident).encode("utf-8")).hexdigest()[:8]
    room = SLUG_MAX_BYTES - len(tag.encode("utf-8"))
    if len(safe.encode("utf-8")) > room:
        cut, used = [], 0
        for ch in safe:
            n = len(ch.encode("utf-8"))
            if used + n > room:
                break
            cut.append(ch)
            used += n
        safe = "".join(cut)
    return safe + tag


def _check_tab(tab):
    if tab not in TABS:
        raise ValueError(f"tab must be one of {TABS}, not {tab!r}")
