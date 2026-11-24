"""NDJSON on stdout: one JSON object per line, flushed, UTF-8, never carrying the Jev key."""
import json
import sys

from . import env


def _default(o):
    if isinstance(o, (set, frozenset, tuple)):
        return list(o)
    if isinstance(o, bytes):
        return o.decode("utf-8", "replace")
    return str(o)


def dumps(ev):
    """The wire form of one event (no trailing newline). Scrubbed; U+2028/2029 are escaped because a
    reader that splits lines the JavaScript way would cut a string there."""
    line = json.dumps(ev, ensure_ascii=False, separators=(",", ":"), default=_default)
    line = env.scrub(line)
    return line.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


def emit(ev, stream=None):
    """Write one event as a line and flush. Bytes go to stream.buffer when it has one, so the encoding
    is UTF-8 whatever the locale is."""
    data = dumps(ev) + "\n"
    out = stream if stream is not None else sys.stdout
    buf = getattr(out, "buffer", None)
    if buf is not None:
        out.flush()
        buf.write(data.encode("utf-8"))
        buf.flush()
    else:
        out.write(data)
        out.flush()
