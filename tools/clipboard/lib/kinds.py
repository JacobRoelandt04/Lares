"""What a copy is, and which of the offered types to read.

The picker prefers what a person copied on purpose over what an application adds beside it: a browser
offers text/html next to the image, a file manager a uri-list next to its own types. The kind drives
the card's face; it never decides whether something is stored (secret.py does that).
"""
import re

_IMAGE_PREF = ("image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/svg+xml")
_TEXT_ORDER = ("text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING", "TEXT")
_EXT = {"image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif",
        "image/bmp": "bmp", "image/svg+xml": "svg", "image/tiff": "tiff", "image/avif": "avif",
        "text/uri-list": "uri"}

_URL = re.compile(r"^(?:https?|ftp|ftps|sftp|ssh|git|file|magnet|mailto|tel)(?::|:/{1,3})\S+$", re.I)
_COLOUR = re.compile(
    r"^(?:#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})"
    r"|(?:rgb|rgba|hsl|hsla)\(\s*[-+0-9.%]+(?:\s*[, /]\s*[-+0-9.%a-z]+){2,3}\s*\))$", re.I)
_CODE_WORDS = re.compile(
    r"(?:^|\s)(?:def|function|class|import|from|return|const|let|var|fn|pub|struct|enum|impl|package|"
    r"public|private|static|void|int|elif|else|while|for|if|try|except|catch|switch|case)\b"
    r"|#include|=>|->|\bself\.|\bthis\.|\(\)|\):|\{\s*$|;\s*$|</?[a-z][^>]*>|^\s*[$#]\s|::")


def pick_type(types):
    """The type to read, or None when nothing offered is something we keep."""
    images = [t for t in types if t.startswith("image/")]
    for pref in _IMAGE_PREF:
        if pref in images:
            return pref
    if images:
        return images[0]
    if "text/uri-list" in types:
        return "text/uri-list"
    for t in _TEXT_ORDER:
        if t in types:
            return t
    return None


def ext_for(mime):
    base = mime.split(";", 1)[0].strip().lower()
    if base in _EXT:
        return _EXT[base]
    return "txt" if base.startswith("text/") or mime in _TEXT_ORDER else "bin"


def is_text_type(mime):
    return mime.startswith("text/") or mime in _TEXT_ORDER


def canonical_mime(picked):
    """The record's mime: the old X11 names mean utf-8 text."""
    return "text/plain;charset=utf-8" if picked in ("UTF8_STRING", "STRING", "TEXT") else picked


def is_code(text):
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        return False
    hits = sum(1 for ln in lines if _CODE_WORDS.search(ln))
    indented = sum(1 for ln in lines if ln.startswith(("    ", "\t")))
    if len(lines) == 1:
        ln = lines[0]
        return bool(re.search(r"[;{}]\s*$|=>|\)\s*\{|^\s*(?:def|function|const|let|var|import|from|class)\b.*[:({=]", ln)) \
            and " " in ln
    return hits >= 2 and (hits + indented) / len(lines) >= 0.4


def kind_of(text, picked):
    """link | colour | code | files | image | text for a copy read as `picked`."""
    if picked.startswith("image/"):
        return "image"
    if picked == "text/uri-list":
        return "files"
    t = text.strip()
    if t and "\n" not in t:
        if _URL.match(t):
            return "link"
        if _COLOUR.match(t):
            return "colour"
    if is_code(text):
        return "code"
    return "text"
