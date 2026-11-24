"""specifications.freedesktop.org: the list of specifications and their pages.

The index (`/`) has an `<h4>` per specification followed by a "Latest Version" link and dated versions.
Three link off the site (appstream, dbus, polkit). The pages are DocBook/DAPS: one page for a short spec,
a table of contents plus chapters for a long one, and in both the Introduction is on the page fetched
here (`desktop-entry/latest/` holds `id="introduction"` beside its TOC).
"""
import re

from .. import http, paths

BASE = "https://specifications.freedesktop.org"
_H4 = re.compile(r"<h4>\s*([^<]+?)\s*</h4>")
_HREF = re.compile(r'href="([^"]+)"')
_VERSION = re.compile(r">\s*version\s+([^<\s]+)\s*<", re.I)


def parse_index(html):
    """The index page -> [{id, url (the latest version, trailing slash), external (bool), versions}]."""
    out = []
    marks = list(_H4.finditer(html))
    for i, m in enumerate(marks):
        block = html[m.end(): marks[i + 1].start() if i + 1 < len(marks) else len(html)]
        sid = m.group(1)
        latest = None
        external = None
        for href in _HREF.findall(block):
            if href == f"{sid}/latest":
                latest = f"{BASE}/{sid}/latest/"
                break
            if href.startswith("http") and external is None:
                external = href
        out.append({
            "id": sid, "url": latest or external, "external": latest is None,
            "versions": _VERSION.findall(block),
        })
    return out


def specs(curated=True):
    """The specifications of the index (33), in index order. `curated` drops what
    static_pages.json freedesktop.exclude names (off-site pages and X11-only specs)."""
    listing = parse_index(http.get(BASE + "/", accept="text"))
    if not curated:
        return listing
    skip = paths.static_pages()["freedesktop"]["exclude"]
    return [s for s in listing if s["id"] not in skip and not s["external"]]


def page_html(spec):
    """The page of a specification: `spec` is an entry of specs() or an id. HTML, whole."""
    if isinstance(spec, dict):
        if spec.get("external"):
            raise ValueError(f"{spec['id']} is not on {BASE}: {spec['url']}")
        url = spec["url"]
    else:
        url = f"{BASE}/{spec}/latest/"
    return http.get(url, accept="text")
