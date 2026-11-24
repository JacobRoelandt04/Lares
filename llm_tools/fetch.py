#!/usr/bin/env python3
"""fetch_url: one http(s) GET, HTML reduced to text, capped.

    python3 -I fetch.py -- <url> <cap>

urllib, 20 s socket timeout, at most 2 MB read; an HTML body is reduced to
its text with html.parser (script, style, noscript and head dropped, block
elements separated by newlines, whitespace collapsed); any other text body is
passed through; a binary body is reported and not shown. The output is cut at
<cap> bytes, and the cut is said out loud.
"""
import html
import re
import sys
import urllib.request
import urllib.error
from html.parser import HTMLParser

MAX_READ = 2 * 1024 * 1024
BLOCK = {"p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6",
         "tr", "td", "th", "table", "section", "article", "header", "footer",
         "nav", "pre", "blockquote", "hr", "dt", "dd", "title"}
SKIP = {"script", "style", "noscript", "head", "svg", "template"}


class Text(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.skip += 1
        elif tag in BLOCK:
            self.out.append("\n")

    def handle_endtag(self, tag):
        if tag in SKIP and self.skip > 0:
            self.skip -= 1
        elif tag in BLOCK:
            self.out.append("\n")

    def handle_data(self, data):
        if self.skip == 0:
            self.out.append(data)


def main():
    args = sys.argv[1:]
    if args and args[0] == "--":
        args = args[1:]
    if not args:
        print("usage: fetch.py -- <url> [cap]", file=sys.stderr)
        return 2
    url = args[0]
    cap = int(args[1]) if len(args) > 1 and args[1].isdigit() else 65536
    if not re.match(r"^https?://", url):
        print("only http(s) URLs are fetched", file=sys.stderr)
        return 2
    req = urllib.request.Request(url, headers={"User-Agent": "lares-llm/1 (+fetch_url)",
                                               "Accept": "text/html, text/plain;q=0.9, */*;q=0.5"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            ctype = r.headers.get("Content-Type", "") or ""
            body = r.read(MAX_READ + 1)
            final = r.geturl()
    except urllib.error.HTTPError as e:
        print("HTTP %d %s" % (e.code, e.reason), file=sys.stderr)
        return 1
    except Exception as e:  # noqa: BLE001 - one line for the model, whatever it was
        print("fetch failed: %s" % e, file=sys.stderr)
        return 1
    cut_read = len(body) > MAX_READ
    body = body[:MAX_READ]
    m = re.search(r"charset=([A-Za-z0-9_-]+)", ctype)
    enc = m.group(1) if m else "utf-8"
    try:
        text = body.decode(enc, errors="replace")
    except LookupError:
        text = body.decode("utf-8", errors="replace")
    if b"\x00" in body[:4096]:
        print("%s: binary body (%s), %d bytes, not shown" % (final, ctype.split(";")[0], len(body)))
        return 0
    if "html" in ctype or text.lstrip()[:200].lower().find("<html") >= 0 or text.lstrip()[:15].lower().startswith("<!doctype"):
        p = Text()
        p.feed(text)
        text = "".join(p.out)
        text = re.sub(r"[ \t\r\f\v]+", " ", text)
        text = re.sub(r" *\n *", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text).strip()
    head = "%s (%s)\n" % (final, ctype.split(";")[0] or "unknown type")
    out = head + text
    data = out.encode("utf-8")
    if len(data) > cap:
        keep = data[:cap].decode("utf-8", errors="ignore")
        print(keep)
        print("\n[fetch_url cut the page at %d bytes of %d]" % (cap, len(data)))
    else:
        print(out)
    if cut_read:
        print("\n[fetch_url read only the first 2 MB of the body]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
