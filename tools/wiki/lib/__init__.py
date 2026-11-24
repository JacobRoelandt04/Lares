"""Wiki module tool library (Python 3 stdlib only, plus PIL in the image steps of wiki.py).

Import as `from lib import http, mw, ...` with tools/wiki on sys.path (wiki.py and the tests do).
Never run a script that lives in this directory: its own http.py would shadow the standard
library's `http` package.

Layering (each layer imports only the ones above it):
    env, paths            secrets, XDG directories, slugs
    atomic, ndjson        atomic files and flocks; NDJSON events on stdout
    http                  every network call: UA, throttle, 429, gzip, WIKI_HTTP_MAP, Offline
    mw                    MediaWiki api.php (formatversion 2, maxlag, continuation)
    entry, index          the entry v1 record and the pool index
    sources/*             one module per wiki; fetch and parse API JSON, return plain dicts
"""
