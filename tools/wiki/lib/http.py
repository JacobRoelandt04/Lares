"""Every network call of the tool goes through here (urllib only).

    get(url, *, params=None, accept="json"|"bytes"|"text", timeout=20, headers=None, gap=None)
    post_json(url, body, headers=None, timeout=30)

What it does, and why (docs/contracts/wiki_api_notes.md):
  * User-Agent `lares-wiki/0.1 (https://github.com/JacobRoelandt04/Lares)`. Wikimedia treats a UA whose
    contact is not a full URL or an email as unidentified and limits it to 10 requests/min; with a URL it
    is 200/min. Do not shorten it to "(+github.com/...)".
  * A per-host pause of at least GAP seconds (0.45) between requests, measured from the end of the last
    one. Wikimedia's API hosts (Wikipedia, Commons, Wikidata, api.wikimedia.org, mediawiki.org) share one
    limiter, so they share one clock here too. WIKI_HTTP_GAP (seconds) overrides it: probes against a stub
    set it to 0.
  * 429: wait Retry-After (never more than MAX_WAIT) and try again, MAX_429_RETRIES times, then raise
    RateLimited. 5xx: two short retries. A connection failure is `Offline` (the tool exits 4).
  * gzip. Redirects are followed, and WIKI_HTTP_MAP applies to them too.
  * WIKI_HTTP_MAP: JSON {"en.wikipedia.org": "http://127.0.0.1:PORT/en.wikipedia.org", ...} rewrites
    scheme+host of matching URLs, so a probe can put a stub server behind every host.

Nothing here puts a header in a message: the Jev key travels as a header of post_json and every message
is scrubbed anyway (env.scrub).
"""
import gzip
import http.client
import json
import os
import re
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from . import env

UA = "lares-wiki/0.1 (https://github.com/JacobRoelandt04/Lares)"
DEFAULT_GAP = 0.45
MAX_429_RETRIES = 3
MAX_WAIT = 90.0            # the longest Retry-After that is waited out; a longer one raises at once
RETRY_5XX = (1.0, 3.0)     # seconds before each retry of a 500/502/503/504
_ACCEPT = {"json": "application/json", "text": "text/html,text/plain;q=0.9,*/*;q=0.5", "bytes": "*/*"}

_clock = time.monotonic    # tests replace both, to check the pauses without waiting for them
_sleep = time.sleep
_last = {}
_lock = threading.Lock()


class NetError(Exception):
    """Base of everything this module raises."""


class HttpError(NetError):
    """A non-2xx answer (or a 2xx that is not what was asked for). `status` 0 = not an HTTP status."""

    def __init__(self, message, status=0, url=None, body=None, retry_after=None):
        super().__init__(env.scrub(message))
        self.status = status
        self.url = url
        self.body = env.scrub(body) if isinstance(body, str) else body
        self.retry_after = retry_after


class RateLimited(HttpError):
    """429 after every allowed wait."""


class Offline(NetError):
    """No network: DNS failure, connection refused or unreachable, timeout, reset. `retryable` marks the
    ones that are worth one more try (a timeout, a reset) as against a DNS failure or a refusal."""

    retryable = False


# ----------------------------------------------------------------------------- urls

def build_url(url, params=None):
    """url plus an encoded query. Space is %20 and "|" is %7C (the form the fixtures were captured in);
    None values are dropped; a list/tuple is joined with "|"; a bool is 1/0 (MediaWiki's flags)."""
    if not params:
        return url
    items = []
    for k, v in params.items():
        if v is None:
            continue
        if isinstance(v, bool):
            v = "1" if v else "0"
        elif isinstance(v, (list, tuple)):
            v = "|".join(str(x) for x in v)
        items.append((k, str(v)))
    q = urllib.parse.urlencode(items, quote_via=urllib.parse.quote)
    return url + ("&" if "?" in url else "?") + q if q else url


def _map():
    raw = os.environ.get("WIKI_HTTP_MAP")
    if not raw:
        return {}
    try:
        m = json.loads(raw)
    except ValueError:
        raise NetError("WIKI_HTTP_MAP is not valid JSON") from None
    return m if isinstance(m, dict) else {}


def map_url(url):
    """WIKI_HTTP_MAP applied: the scheme and host of `url` replaced by the mapped base URL."""
    m = _map()
    if not m:
        return url
    p = urllib.parse.urlsplit(url)
    base = m.get(p.hostname or "")
    if not base:
        return url
    b = urllib.parse.urlsplit(base)
    path = b.path.rstrip("/") + p.path
    return urllib.parse.urlunsplit((b.scheme, b.netloc, path, p.query, ""))


def throttle_key(host):
    """Hosts that share a rate limiter share a key. upload/thumb have their own (600 000/min, api_notes)."""
    h = (host or "").lower()
    if h in ("upload.wikimedia.org", "thumb.wikimedia.org"):
        return h
    if h.endswith((".wikipedia.org", ".wikimedia.org", ".wikidata.org", ".mediawiki.org")) or h in (
            "wikimedia.org", "wikidata.org", "mediawiki.org"):
        return "wikimedia-api"
    return h


def _gap(override):
    if override is not None:
        return float(override)
    raw = os.environ.get("WIKI_HTTP_GAP")
    if raw:
        try:
            return max(0.0, float(raw))
        except ValueError:
            pass
    return DEFAULT_GAP


def _throttle(key, gap):
    with _lock:
        wait = _last.get(key, -1e9) + gap - _clock()
        if wait > 0:
            _sleep(wait)
        _last[key] = _clock()


def _stamp(key):
    with _lock:
        _last[key] = _clock()


# ----------------------------------------------------------------------------- transport

class _Redirect(urllib.request.HTTPRedirectHandler):
    """Follows redirects, sending the new URL through WIKI_HTTP_MAP as well."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return super().redirect_request(req, fp, code, msg, headers, map_url(newurl))


def _opener(mapped):
    handlers = [_Redirect()]
    if mapped:
        handlers.append(urllib.request.ProxyHandler({}))    # a stub on loopback is never behind a proxy
    return urllib.request.build_opener(*handlers)


def _retry_after(headers):
    v = headers.get("Retry-After") if headers is not None else None
    if v is None:
        return None
    try:
        return max(0.0, float(v))
    except ValueError:
        return None                                          # an HTTP-date: fall back to the backoff


def _send(req, timeout, mapped):
    """One request -> (status, headers, body bytes). HTTP error statuses are returned, not raised;
    transport failures raise Offline."""
    try:
        with _opener(mapped).open(req, timeout=timeout) as r:
            body = r.read()
            status, headers = r.status, r.headers
    except urllib.error.HTTPError as e:
        try:
            body = e.read()
        except (OSError, http.client.HTTPException):
            body = b""
        finally:
            e.close()
        status, headers = e.code, e.headers
    except (urllib.error.URLError, socket.timeout, http.client.HTTPException, OSError) as e:
        reason = getattr(e, "reason", e)
        off = Offline(env.scrub(f"{type(reason).__name__}: {reason}"))
        off.retryable = isinstance(reason, (TimeoutError, ConnectionResetError, http.client.HTTPException))
        raise off from None
    if headers.get("Content-Encoding", "").lower() == "gzip":
        try:
            body = gzip.decompress(body)
        except (OSError, EOFError):
            raise HttpError("gzip body did not decode", status=status) from None
    return status, headers, body


def _request(method, url, body, headers, timeout, gap):
    real = urllib.parse.urlsplit(url)
    target = map_url(url)
    key = throttle_key(real.hostname)
    hdrs = {"User-Agent": UA, "Accept-Encoding": "gzip"}
    hdrs.update(headers or {})
    req_body = body
    attempt429 = attempt5xx = 0
    transport_retried = False
    while True:
        _throttle(key, _gap(gap))
        req = urllib.request.Request(target, data=req_body, headers=hdrs, method=method)
        try:
            status, resp_headers, data = _send(req, timeout, target != url)
        except Offline as off:
            _stamp(key)
            if transport_retried or not off.retryable:
                raise
            transport_retried = True
            _sleep(0.5)                                      # one retry: a reset or a slow first byte
            continue
        _stamp(key)
        if 200 <= status < 300:
            return status, resp_headers, data
        ra = _retry_after(resp_headers)
        text = data[:400].decode("utf-8", "replace")
        if status == 429:
            wait = ra if ra is not None else 5.0 * (2 ** attempt429)
            if attempt429 < MAX_429_RETRIES and wait <= MAX_WAIT:
                attempt429 += 1
                env.log(f"429 from {real.hostname}: waiting {wait:.0f}s (try {attempt429}/{MAX_429_RETRIES})")
                _sleep(wait)
                continue
            raise RateLimited(f"HTTP 429 from {real.hostname} (Retry-After {ra})", status=429, url=url,
                              body=text, retry_after=ra)
        if status in (500, 502, 503, 504) and method == "GET" and attempt5xx < len(RETRY_5XX):
            _sleep(RETRY_5XX[attempt5xx])
            attempt5xx += 1
            continue
        raise HttpError(f"HTTP {status} from {real.hostname}{real.path}: {text[:160]}", status=status,
                        url=url, body=text)


def _decode(data, resp_headers):
    ctype = resp_headers.get("Content-Type", "") if resp_headers is not None else ""
    m = re.search(r"charset=([\w-]+)", ctype, re.I)
    try:
        return data.decode(m.group(1) if m else "utf-8", "replace")
    except LookupError:
        return data.decode("utf-8", "replace")


def get(url, *, params=None, accept="json", timeout=20, headers=None, gap=None):
    """GET `url` (+ `params`). accept "json" -> parsed object, "text" -> str, "bytes" -> bytes."""
    if accept not in _ACCEPT:
        raise ValueError(f"accept must be one of {sorted(_ACCEPT)}")
    full = build_url(url, params)
    h = {"Accept": _ACCEPT[accept]}
    h.update(headers or {})
    status, resp_headers, data = _request("GET", full, None, h, timeout, gap)
    if accept == "bytes":
        return data
    text = _decode(data, resp_headers)
    if accept == "text":
        return text
    try:
        return json.loads(text)
    except ValueError:
        raise HttpError(f"not JSON from {urllib.parse.urlsplit(full).hostname}: {text[:80]!r}",
                        status=status, url=full, body=text[:400]) from None


def post_json(url, body, headers=None, timeout=30):
    """POST `body` as JSON, return the parsed JSON answer. No retries: the caller decides (Jev's rule is
    one retry on 5xx/429). `headers` carries the Authorization header; it is never echoed."""
    h = {"Content-Type": "application/json", "Accept": "application/json"}
    h.update(headers or {})
    payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
    status, resp_headers, data = _request("POST", url, payload, h, timeout, None)
    text = _decode(data, resp_headers)
    try:
        return json.loads(text)
    except ValueError:
        raise HttpError(f"not JSON from {urllib.parse.urlsplit(url).hostname}: {text[:80]!r}",
                        status=status, url=url, body=text[:400]) from None
