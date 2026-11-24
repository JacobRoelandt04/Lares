"""Is this copy a secret? Decided before anything is written.

Three reasons, strongest first:
  app        the focused window's class is in `sealApps` (a password manager, as a backstop for its
             own sensitive hint);
  heuristic  the text is a known token, a password-shaped string or a memorable passphrase;
  (hint is decided by the caller from CLIPBOARD_STATE=sensitive.)

The heuristic only sees single-line text (a PEM private key may span lines). A password shape is 8-128
characters without whitespace and at least three of lower / upper / digit / symbol, with a Shannon
entropy of at least `4 * threshold + 0.5` bits per character (2.5 at the default 0.5), and is NOT any
of the things that look random and are not: URL, path, file name, email, UUID, hex digest or commit
SHA, number, version, colour, data URI, or an identifier whose every word is wordlike (snake, camel,
kebab, CONSTANT). The exclusion list is the false-positive budget: a wrong seal hides a copy for two
minutes, a wrong keep writes a password to disk, so the shape errs towards sealing.
"""
import math
import re

_PEM = re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----")
_TOKENS = (
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bglpat-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bxox[abpr]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{35}\b"),
    re.compile(r"\b(?:npm|hf|pypi)_[A-Za-z0-9]{30,}"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*"),
)
_SK = re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")

_URL = re.compile(r"^(?:[A-Za-z][A-Za-z0-9+.-]*://|www\.|mailto:|tel:|magnet:)\S+$")
_EMAIL = re.compile(r"^[\w.+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+$")
_UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_NUMBER = re.compile(r"^[-+]?[\d.,_:]+(?:[eE][-+]?\d+)?%?$")
_VERSION = re.compile(r"^v?\d+(?:\.\d+)+(?:[-+~.][\w.]+)*$")
_COLOUR = re.compile(r"^(?:#[0-9a-fA-F]{3,8}|(?:rgb|rgba|hsl|hsla)\([^)\s]*\))$")
_WINPATH = re.compile(r"^[A-Za-z]:\\[^\s]*$")
_HOSTPORT = re.compile(r"^[\w.-]+:\d{1,5}$")
_TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\d[T ]\d\d:\d\d(?::\d\d)?(?:\.\d+)?(?:Z|[+-]\d\d:?\d\d)?$")
_DATA_URI = re.compile(r"^data:[\w/+.-]+(?:;[\w=.-]+)*,")
_PATH_SAFE = re.compile(r"^[\w.@+%,=~-]+$")
_DIGEST_LENS = {32, 40, 56, 64, 96, 128}
_FILE_EXT = set("""txt md rst log csv tsv json yml yaml toml ini conf cfg xml html htm css js mjs ts tsx jsx py rb
go rs c h cc cpp hpp java kt sh bash zsh fish lua pl php sql qml svg png jpg jpeg gif webp bmp ico pdf doc
docx odt xls xlsx ods ppt pptx zip tar gz xz bz2 zst 7z rar iso img deb rpm mp3 mp4 mkv webm wav ogg flac avi
mov so a o bin exe dll lock service desktop pkg rules patch diff""".split())

_ABBR = set("""str cfg ctx src dst btn msg tmp num idx pkg lib bin usr var dir env cmd srv svc mgr ptr buf len sql css
npm rpm svg png jpg gif pdf xml jpg mpv vlm gpu cpu ram ssd hdd tcp udp ssh ssl tls dns url uri api sdk cli gui
http https html json yaml toml nginx pgsql nth ctl fmt arg args kbd mnt sys prj lst obj val btn pwd src txt pdf""".split())
_SHORT_WORDS = set("by id to of in on is or an as at do go if no ok so up us we db io ui os my me it he be qt kb mb gb tb hz px em".split())
_CAMEL = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+")
_VOWELS = set("aeiouyAEIOUY")
_PARTS = re.compile(r"[A-Za-z]+|[0-9]+")
_PASS_WORD = re.compile(r"^([A-Za-z]{3,})([0-9]{0,4})$")
_JOINERS = "-._ "


def _classes(s):
    return (any(c.islower() for c in s) + any(c.isupper() for c in s)
            + any(c.isdigit() for c in s) + any(not c.isalnum() for c in s))


def _entropy(s):
    n = len(s)
    counts = {}
    for c in s:
        counts[c] = counts.get(c, 0) + 1
    return -sum(k / n * math.log2(k / n) for k in counts.values())


def _wordlike(run):
    if len(run) == 1:
        return False
    if 2 <= len(run) <= 6 and run.isupper() and (len(run) <= 3 or set(run) & _VOWELS or run.lower() in _ABBR):
        return True                                               # HTTP, UTF, ISO: an acronym
    if len(run) == 2:
        return run.lower() in _SHORT_WORDS
    low = run.lower()
    if low in _ABBR:
        return True
    clusters = re.findall(r"[^aeiouy]{4,}", low)             # real words: no 4 consonants in a row (but "length")
    return bool(set(run) & _VOWELS) and all("ngth" in low for _ in clusters)


def _segment_ident(seg):
    """One `-_.`-separated piece of an identifier: digits only, or words (camel allowed) with up to four
    trailing digits."""
    parts = _PARTS.findall(seg)
    if len(parts) > 1 and parts[0].isdigit():
        return False                                              # 2Go8Gix: not how anything is named
    if "".join(parts) != seg:
        return False
    if len(parts) == 2 and len(parts[0]) == 1 and parts[1].isdigit() and len(parts[1]) <= 4:
        return True                                               # v2, x86
    if len(parts) == 1:
        return True if seg.isdigit() or len(seg) == 1 else _camel_words(seg)
    return all(len(p) <= 4 if p.isdigit() else _camel_words(p) for p in parts) and len(seg) >= 2


def _camel_words(alpha):
    runs = _CAMEL.findall(alpha)
    return "".join(runs) == alpha and all(_wordlike(r) for r in runs)


def _is_assignment(s):
    """key=value where both sides are identifiers or numbers (sysctl, env, a CLI flag)."""
    k, eq, v = s.lstrip("-").partition("=")
    return bool(eq) and is_identifier(k) and (is_identifier(v) or v.isdigit() or v == "")


def is_identifier(s):
    segs = [p for p in re.split(r"[-_.]", s) if p]
    return bool(segs) and re.fullmatch(r"[A-Za-z0-9_.-]+", s) is not None and all(_segment_ident(p) for p in segs)


def _is_path(s):
    if "/" not in s:
        return False
    segs = [p for p in s.split("/") if p and p != "~" and set(p) != {"."}]
    if not segs:
        return True
    if not all(_PATH_SAFE.match(p) for p in segs):
        return False
    return all(is_identifier(p) or _is_filename(p) for p in segs)


def _is_filename(s):
    stem, dot, ext = s.rpartition(".")
    return bool(dot) and ext.lower() in _FILE_EXT and bool(stem) and bool(_PATH_SAFE.match(stem)) \
        and not any(c in stem for c in "@+%,=~")


def _is_hex_digest(s):
    return (re.fullmatch(r"[0-9a-fA-F]+", s) is not None
            and (len(s) in _DIGEST_LENS or 7 <= len(s) <= 40)
            and (s == s.lower() or s == s.upper()))


def _not_a_password(s):
    return bool(_URL.match(s) or _EMAIL.match(s) or _UUID.match(s) or _NUMBER.match(s) or _VERSION.match(s)
                or _COLOUR.match(s) or _DATA_URI.match(s) or _is_hex_digest(s) or _is_path(s)
                or _WINPATH.match(s) or _HOSTPORT.match(s) or _TIMESTAMP.match(s) or _is_assignment(s)
                or _is_filename(s) or is_identifier(s))


_TLDS = {"org", "com", "net", "io", "de", "be", "nl", "fr", "uk", "dev", "app", "edu", "gov"}


def _is_passphrase(s):
    if s.split(".", 1)[0].lower() in _TLDS and s.count(".") >= 2 and not any(c.isdigit() for c in s):
        return False                                              # org.freedesktop.Notifications
    for j in _JOINERS:
        words = s.split(j)
        if not 3 <= len(words) <= 8 or any(not w for w in words):
            continue
        if any(c in s for c in _JOINERS if c != j):
            continue
        digits_only = [w for w in words if w.isdigit() and len(w) <= 4]
        real = [w for w in words if w not in digits_only]
        if len(digits_only) > 1 or len(real) < 3 or not all(_PASS_WORD.match(w) for w in real):
            continue
        letters = ["".join(c for c in w if c.isalpha()) for w in real]
        if not all(set(w) & _VOWELS for w in letters):
            continue
        if all(w.isupper() for w in letters):
            continue                                              # CONSTANT_CASE
        capital = any(w[0].isupper() for w in letters)
        digit = any(c.isdigit() for c in s)
        if not (digit or (capital and j in "-.")):
            continue                                              # "New York City" is a place, not a secret
        if not capital and (len(real) < 4 or j == "_"):
            continue                                              # snake_case_with2 is an identifier
        return True
    return False


def _known_token(text):
    if _PEM.search(text):
        return True
    if "\n" in text.strip():
        return False
    if any(p.search(text) for p in _TOKENS):
        return True
    m = _SK.search(text)
    return bool(m) and any(c.isdigit() for c in m.group(0)) and not is_identifier(m.group(0)[3:])


def _is_text_mime(mime):
    return mime.startswith("text/") or mime in ("UTF8_STRING", "STRING", "TEXT")


def heuristic(text, threshold=0.5):
    """True when `text` looks like a credential."""
    if _known_token(text):
        return True
    s = text.strip()
    if not s or len(s) > 128 or len(s) < 8 or any(c.isspace() and c != " " for c in s):
        return False
    if " " in s:
        return _is_passphrase(s)
    if _is_passphrase(s):
        return True
    if _classes(s) < 3 or _entropy(s) < 4 * threshold + 0.5:
        return False
    return not _not_a_password(s)


def listed(cls, apps):
    """A window class is one of `apps`: whole, whatever the case."""
    cls = (cls or "").lower()
    return cls != "" and any(cls == a.lower() for a in apps)


def classify(data, mime, source_cls, cfg):
    """(sealed, reason): reason is "app" or "heuristic" when sealed, else None."""
    if listed(source_cls, cfg.get("sealApps", [])):
        return True, "app"
    sec = cfg.get("secrets", {})
    if not sec.get("heuristic", True) or not _is_text_mime(mime or "text/plain"):
        return False, None
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return False, None
    if heuristic(text, float(sec.get("threshold", 0.5))):
        return True, "heuristic"
    return False, None
