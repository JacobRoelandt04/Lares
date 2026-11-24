"""The secret, and the one rule about it: the Jev key lives in memory only.

It is read here from the wiki's config (`jevKey` in ~/.config/quickshell/config/wiki.jsonc, the file the shell reads too; config/ is
never committed), used as a request header by http.post_json, and never placed in argv, a child's environment, a log line, an NDJSON
event or a file. Everything that leaves the process by text goes through `scrub`: ndjson.emit, atomic.write_json, log() and the
excepthook below all do. `child_env()` is what a subprocess must be given as its environment.

The key once lived in `.env` beside the config (JEV_API_KEY=...). That file is read no more: when the config has no key and an old
`.env` still names one, `old_env_hint()` says where it must go (docs/wiki.md).
"""
import os
import re
import sys

from . import paths

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "lib"))
import jsonc  # noqa: E402  (tools/lib/jsonc.py: the shell's comment stripper and file rule; `lib` here is the wiki's own package)

KEY_NAME = "JEV_API_KEY"                           # the name a launcher's environment could carry it under (child_env strips it)
CONFIG_KEY = "jevKey"
REDACTED = chr(0x2039) + "key" + chr(0x203A)         # the text: single angle quotes round "key"
_SECRET_NAME = re.compile(r"(KEY|TOKEN|SECRET|PASSWORD)$", re.I)
_SHAPES = (re.compile(r"\bdk-[A-Za-z0-9]{16,}"), re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"))
_MIN_SECRET = 6                                    # never scrub a value so short it would eat ordinary text
_cache = {"sig": None, "key": None}


def _config_key():
    """`jevKey` of the wiki config, or None. Re-read when the file changes (a key added while the tool runs is covered); a file
    that does not parse holds no key."""
    path = paths.config_path()
    try:
        sig = (path, os.stat(path).st_mtime_ns)
    except OSError:
        sig = (path, None)
    if _cache["sig"] != sig:
        key = None
        if sig[1] is not None:
            try:
                v = jsonc.load(path).get(CONFIG_KEY)
                key = v.strip() if isinstance(v, str) and v.strip() else None
            except (OSError, ValueError, AttributeError):
                key = None
        _cache["sig"], _cache["key"] = sig, key
    return _cache["key"]


def jev_key():
    """The Jev key from config/wiki.jsonc (`jevKey`), or None."""
    return _config_key()


def old_env_hint():
    """When an old `.env` beside the config still names JEV_API_KEY: the words that say where the key goes now, else ""."""
    p = os.path.join(paths.config_dir(), ".env")
    try:
        with open(p, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ""
    if re.search(r"^\s*(export\s+)?" + KEY_NAME + r"\s*=", text, re.M):
        return "%s is no longer read: move JEV_API_KEY's value into %s as \"%s\" (chmod 600), then delete the .env" % (
            p, os.path.join(paths.config_dir(), "config", "wiki.jsonc"), CONFIG_KEY)
    return ""


def _secrets():
    """The Jev key of the config, plus JEV_API_KEY from the environment if a launcher put it there."""
    vals = set()
    k = _config_key()
    if k:
        vals.add(k)
    if os.environ.get(KEY_NAME):
        vals.add(os.environ[KEY_NAME])
    return sorted((v for v in vals if len(v) >= _MIN_SECRET), key=len, reverse=True)


def scrub(text):
    """`text` with every known secret, and anything shaped like the Jev key or a Bearer token, replaced
    by ‹key›. Non-strings are converted first."""
    s = text if isinstance(text, str) else str(text)
    for v in _secrets():
        if v in s:
            s = s.replace(v, REDACTED)
    for rx in _SHAPES:
        s = rx.sub(lambda m: ("Bearer " if m.group(0).lower().startswith("bearer") else "") + REDACTED, s)
    return s


def child_env(base=None):
    """The environment a child process may be given: `base` (default os.environ) without any secret
    variable. The key is not in os.environ unless the launcher put it there; this makes sure a child
    never inherits it."""
    src = dict(os.environ if base is None else base)
    return {k: v for k, v in src.items() if not _SECRET_NAME.search(k)}


def log(msg):
    """One scrubbed line on stderr (stdout is the NDJSON channel)."""
    print(scrub(msg), file=sys.stderr, flush=True)


def install_excepthook():
    """Uncaught exceptions print their traceback through scrub()."""
    import traceback

    def hook(etype, value, tb):
        sys.stderr.write(scrub("".join(traceback.format_exception(etype, value, tb))))
        sys.stderr.flush()

    sys.excepthook = hook
