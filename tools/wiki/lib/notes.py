"""Save an entry as a note in the Notes module's folder (the notes service only scans while its popup is open,
so the tool writes the file itself, by the notes' own conventions: NotesScan.sanitize, the O_EXCL name with the
Obsidian suffix, images under `<root>/.attachments`).

    save(tab, ident, notes_root, folder="Wiki") -> {"path": absolute, "key": "Wiki/<Title>.md"}

The file is `<root>/<folder>/<Title>.md` (`Title 1.md`, `Title 2.md` ... when the name is taken: the file is created
with O_EXCL, so it can never be somebody else's), holding

    # Title

    ![](../.attachments/wiki-<slug>.jpg)        the hero, copied to <root>/.attachments/ (photos only)

    the intro, its links as markdown links; paragraphs are separated by a blank line

    Source: <url>
    Image: <credit>

The entry is read from the pool (`entries/<tab>/<slug>.json`) or, for a page followed with Ctrl+click, from the
rabbit hole's cache (`live/<slug>.json`, whose `upgrade` -- a written intro -- replaces the intro when there is
one). `folder` is a relative path inside the root; anything that climbs out of it is refused.
"""
import os

from . import atomic, env, paths

MAX_NAME_BYTES = 200


class NoteError(Exception):
    pass


def sanitize(title):
    """NotesScan.sanitize: control characters become spaces, "/" becomes "-", leading dots go, at most 200 bytes."""
    t = "".join(" " if (ord(c) < 32 or ord(c) == 127) else c for c in str(title or "")).replace("/", "-")
    t = t.strip().lstrip(".").strip()
    if not t:
        return ""
    out, used = [], 0
    for ch in t:
        n = len(ch.encode("utf-8"))
        if used + n > MAX_NAME_BYTES:
            break
        out.append(ch)
        used += n
    return "".join(out).strip()


def _folder(folder):
    parts = [p for p in str(folder or "").replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts) or os.path.isabs(str(folder)):
        raise NoteError("the notes folder must be a plain relative path, got %r" % (folder,))
    return parts


def load_entry(tab, ident):
    """The entry (with a written intro from the cache when the page was followed) or NoteError."""
    if tab not in paths.TABS:
        raise NoteError("no such tab: %r" % (tab,))
    e = atomic.read_json(paths.entry_path(tab, ident))
    if isinstance(e, dict):
        return e
    live = atomic.read_json(paths.live_path(ident))
    if isinstance(live, dict) and isinstance(live.get("entry"), dict):
        e = dict(live["entry"])
        if isinstance(live.get("upgrade"), dict):
            e["intro"] = live["upgrade"]
        return e
    raise NoteError("no such entry: %s" % ident)


def _url_safe(url):
    return url.replace("(", "%28").replace(")", "%29").replace(" ", "%20")


def linked_text(intro):
    """The intro's text with each link as `[text](url)` (offsets are UTF-16 code units) and a blank line between
    paragraphs."""
    text = intro.get("text") or ""
    links = sorted((l for l in intro.get("links") or () if isinstance(l, dict)), key=lambda l: l.get("s", 0),
                   reverse=True)
    if links:
        u16 = text.encode("utf-16-le")
        for l in links:
            s, e = int(l["s"]), int(l["e"])
            if not (0 <= s < e <= len(u16) // 2) or not l.get("url"):
                continue
            label = u16[2 * s:2 * e].decode("utf-16-le")
            md = "[%s](%s)" % (label.replace("[", "\\[").replace("]", "\\]"), _url_safe(l["url"]))
            u16 = u16[:2 * s] + md.encode("utf-16-le") + u16[2 * e:]
        text = u16.decode("utf-16-le")
    return "\n\n".join(p for p in text.split("\n") if p.strip())


def body(e, hero_name):
    lines = ["# " + (e.get("title") or ""), ""]
    if hero_name:
        lines += ["![](../.attachments/%s)" % hero_name, ""]
    lines += [linked_text(e.get("intro") or {}), ""]
    lines.append("Source: " + ((e.get("source") or {}).get("url") or ""))
    credit = next((im.get("credit") for im in e.get("images", []) if im.get("kind") == "photo" and im.get("credit")),
                  "")
    if credit:
        lines.append("Image: " + credit)
    return "\n".join(lines) + "\n"


def _create_exclusive(directory, base, text):
    """`<base>.md`, else `<base> 1.md` ...; the name is taken with O_EXCL. -> the file name."""
    data = env.scrub(text).encode("utf-8")               # like every other output path of the tool
    for n in range(10000):
        name = base + (".md" if n == 0 else " %d.md" % n)
        try:
            fd = os.open(os.path.join(directory, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except FileExistsError:
            continue
        try:
            view = memoryview(data)
            while len(view):
                view = view[os.write(fd, view):]
            os.fsync(fd)
        finally:
            os.close(fd)
        return name
    raise NoteError("no free name for %r under %s" % (base, directory))


def save(tab, ident, notes_root, folder="Wiki"):
    parts = _folder(folder)
    e = load_entry(tab, ident)
    root = os.path.abspath(os.path.expanduser(notes_root))
    directory = os.path.join(root, *parts)
    os.makedirs(directory, exist_ok=True)
    hero_name = None
    photo = next((im for im in e.get("images", []) if im.get("kind") == "photo" and im.get("file")), None)
    if photo:
        src = os.path.join(paths.state_dir(), photo["file"])
        if os.path.isfile(src):
            hero_name = "wiki-%s.jpg" % paths.slug(e["id"])
            with open(src, "rb") as f:
                atomic.write_bytes(os.path.join(root, ".attachments", hero_name), f.read())
    base = sanitize(e.get("title")) or "Untitled"
    name = _create_exclusive(directory, base, body(e, hero_name))
    return {"path": os.path.join(directory, name), "key": "/".join(parts + [name])}
