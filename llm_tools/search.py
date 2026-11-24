#!/usr/bin/env python3
"""web_search: one query through the SearXNG on this machine, as plain text.

    python3 -I search.py -- <query> [count]

SearXNG is the user's own metasearch instance (127.0.0.1:8888 by default,
SEARXNG_URL overrides): it asks a set of engines and merges the answers, so
nothing here talks to a search engine directly and no API key exists to leak.
The JSON API is asked for, which an instance only serves when `json` is in
its `search.formats` -- the error says exactly that when it is not, because
that one line of settings is the whole setup.

The output is what a model reads best: any direct answer first, then numbered
results as title, url and a one-line snippet. HTML in a snippet is stripped;
the engines that found each result are named, because a result three engines
agree on is worth more than one.
"""
import html
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_URL = "http://127.0.0.1:8888"
DEFAULT_COUNT = 8
MAX_COUNT = 20
TIMEOUT = 15
TAG = re.compile(r"<[^>]+>")
WS = re.compile(r"\s+")


def clean(s):
    return WS.sub(" ", html.unescape(TAG.sub(" ", str(s or "")))).strip()


def main():
    args = sys.argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    if not args or not args[0].strip():
        print("usage: search.py -- <query> [count]", file=sys.stderr)
        return 2
    query = args[0].strip()
    count = DEFAULT_COUNT
    if len(args) > 1 and args[1].isdigit():
        count = max(1, min(MAX_COUNT, int(args[1])))

    base = (os.environ.get("SEARXNG_URL") or DEFAULT_URL).rstrip("/")
    url = base + "/search?" + urllib.parse.urlencode({
        "q": query,
        "format": "json",
        "safesearch": "1",
    })
    req = urllib.request.Request(url, headers={
        "User-Agent": "lares-llm/1 (+web_search)",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = json.loads(r.read(4 * 1024 * 1024).decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as e:
        if e.code == 403:
            print("SearXNG refused the JSON API (HTTP 403). Its settings.yml needs\n"
                  "  search:\n      formats:\n          - html\n          - json\n"
                  "and a restart of the searxng service.", file=sys.stderr)
            return 1
        print("SearXNG answered HTTP %d %s" % (e.code, e.reason), file=sys.stderr)
        return 1
    except urllib.error.URLError as e:
        print("no SearXNG at %s (%s). The searxng service may not be running."
              % (base, e.reason), file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 - one honest line, whatever it was
        print("search failed: %s" % e, file=sys.stderr)
        return 1

    results = data.get("results") or []
    answers = data.get("answers") or []
    infoboxes = data.get("infoboxes") or []
    dead = data.get("unresponsive_engines") or []

    out = []
    total = data.get("number_of_results") or 0
    shown = min(len(results), count)
    head = "%d result%s for \"%s\"" % (shown, "" if shown == 1 else "s", query)
    if total and total > shown:
        head += " (of about %s)" % format(int(total), ",").replace(",", " ")
    out.append(head)

    for a in answers[:3]:
        # Newer SearXNG returns objects here, older ones plain strings.
        text = clean(a.get("answer") if isinstance(a, dict) else a)
        if text:
            out.append("\nAnswer: " + text)

    for b in infoboxes[:1]:
        text = clean(b.get("content"))
        if text:
            out.append("\n%s: %s" % (clean(b.get("infobox")) or "About", text[:600]))

    for i, r in enumerate(results[:count], 1):
        title = clean(r.get("title")) or "(no title)"
        link = str(r.get("url") or "").strip()
        snippet = clean(r.get("content"))
        engines = [str(e) for e in (r.get("engines") or []) if e]
        line = "\n%d. %s\n   %s" % (i, title, link)
        if snippet:
            line += "\n   " + snippet[:400]
        if engines:
            line += "\n   [%s]" % ", ".join(engines[:4])
        out.append(line)

    if not results:
        out.append("\nNothing came back. The engines that failed: %s"
                   % (", ".join(str(d.get("name", d)) if isinstance(d, dict) else str(d)
                                for d in dead[:6]) or "none reported"))
    elif dead:
        out.append("\n(%d engine%s did not answer in time.)"
                   % (len(dead), "" if len(dead) == 1 else "s"))

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
