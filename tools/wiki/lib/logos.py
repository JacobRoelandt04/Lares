"""The relief logo of a piece of software (Deepen): Wikidata's P154 file, baked into a carved-relief texture.

    find(titles, qid=None)   -> {qid, file, file_title, url, filepath_url, svg, license, credit, ...} | None
    bake(logo, slug)         -> the entry's image record (kind relief, src logo) | None

`titles` are English Wikipedia titles to try in order (the page's own title, then the package's name); the first
with a Wikidata item that carries a logo statement wins (sources.wikidata.logo_for: qid -> P154 -> Commons info).
An Arch or Gentoo title is only a GUESS at a Wikipedia title (`Pacman` is the arcade game there): with
`software_only` the article's short description must say software, else it is not the subject.
`bake` downloads the file (the Commons URL, or Special:FilePath when Commons gave no info), runs
tools/bake_logo_relief.py on it (an argv list, the secret-free environment, a scratch directory of its own) and
writes the PNG as `img/<slug>-logo.png`: the carve is a texture (LogoRelief.qml reads it), 320 px, opaque RGB.
Anything that goes wrong (no logo, a network error, the baker failing, an unreadable result) answers None and the
caller shows the family glyph instead; a logo is decoration, never a reason to lose an entry.
"""
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image

from . import atomic, env, http, mw, paths
from .sources import wikidata, wikipedia

BAKE_TIMEOUT = 180

_SOFTWARE = re.compile(r"(?i)software|program|package manager|shell|editor|browser|manager|server|daemon|framework|"
                       r"librar|kernel|distribution|emulator|compositor|system|protocol|language|tool|utility|"
                       r"application|client|player|engine|toolkit|bootloader|firewall|terminal|desktop|platform|"
                       r"service|suite|interpreter|compiler|standard|specification|command")


def _lookup(title):
    """(qid, Wikipedia's short description) of an English title, redirects followed: one request."""
    q = mw.call(wikipedia.HOST, {"action": "query", "titles": title, "prop": "pageprops",
                                 "ppprop": "wikibase_item|wikibase-shortdesc", "redirects": 1}).get("query", {})
    pages = q.get("pages") or []
    props = (pages[0].get("pageprops") if pages else None) or {}
    return props.get("wikibase_item"), props.get("wikibase-shortdesc") or ""


def _logo_for(title, qid=None, software_only=False):
    """sources.wikidata.logo_for, with one guard. `software_only`: the title is a GUESS (an Arch page's name is not a
    Wikipedia title: `Pacman` is a video game there), so the article found must describe software by its short
    description, else there is no logo."""
    if qid is None:
        qid, desc = _lookup(title)
        if software_only and not _SOFTWARE.search(desc):
            return None
    if not qid:
        return None
    return wikidata.logo_for(title, qid=qid)


def find(titles, qid=None, log=lambda m: None, software_only=False):
    seen = set()
    for i, t in enumerate(titles):
        if not t or t in seen:
            continue
        seen.add(t)
        try:
            logo = _logo_for(t, qid=qid if i == 0 else None, software_only=software_only)
        except (http.NetError, mw.MwError, KeyError) as e:
            log("logo of %s: %s" % (t, e))
            continue
        if logo:
            return logo
    return None


def baker():
    return os.path.join(paths.repo_root(), "tools", "bake_logo_relief.py")


def bake(logo, slug, log=lambda m: None):
    ext = ".svg" if logo.get("svg") else os.path.splitext(logo.get("file") or "")[1].lower() or ".png"
    if ext not in (".svg", ".png"):
        return None
    data = None
    for url in (logo.get("url"), logo.get("filepath_url")):
        if not url:
            continue
        try:
            data = http.get(url, accept="bytes", timeout=40)
            break
        except http.NetError as e:
            log("logo file %s: %s" % (url, e))
    if not data:
        return None
    tmp = tempfile.mkdtemp(prefix="wikilogo-")
    try:
        src, dst = os.path.join(tmp, "logo" + ext), os.path.join(tmp, "logo.png")
        with open(src, "wb") as f:
            f.write(data)
        try:
            r = subprocess.run([sys.executable, baker(), src, dst], capture_output=True, text=True,
                               timeout=BAKE_TIMEOUT, env=env.child_env(), stdin=subprocess.DEVNULL)
        except (OSError, subprocess.SubprocessError) as e:
            log("bake_logo_relief: %s" % e)
            return None
        if r.returncode != 0 or not os.path.isfile(dst):
            log("bake_logo_relief exited %s: %s" % (r.returncode, env.scrub((r.stderr or "")[-300:])))
            return None
        with open(dst, "rb") as f:
            png = f.read()
        with Image.open(io.BytesIO(png)) as im:
            im.load()
            w, h = im.size
    except (OSError, ValueError) as e:
        log("baked logo unreadable: %s" % e)
        return None
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    rel = "img/%s-logo.png" % slug
    atomic.write_bytes(os.path.join(paths.state_dir(), rel), png)
    return {"kind": "relief", "file": rel, "thumb": rel, "w": w, "h": h, "aspect": round(w / h, 2), "focusY": 0.5,
            "credit": logo.get("credit") or logo.get("artist") or "", "license": logo.get("license") or "",
            "src": "logo", "fileTitle": logo.get("file_title")}
