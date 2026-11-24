"""The clipboard store: index.json, blobs/, thumbs/.

One writer, the tool, under `flock` on index.lock: every command takes the lock, loads the index,
changes it and writes it back atomically, so the watcher's per-copy processes and a one-shot `pin` never
interleave. Secrets never reach this module (secret.py decides first); nothing here logs.

    index.json       {"version":1,"entries":[record,...]}, newest first
    blobs/<id>.<ext> the full bytes of an entry whose text is truncated, and of every non-text entry
    thumbs/<id>.webp images only, when PIL is importable: small, low quality (THUMB_QUALITY), the newest
                     `thumbsMax` unpinned images and every pinned one; older images keep their blob (pasting
                     never needs the thumb) and lose theirs

A corrupt index is moved to index.json.corrupt and the store starts empty; at load, blobs and thumbs no
record names are swept (a crash between a blob and its index write, or a leftover .part).
"""
import hashlib
import io
import os
import struct
import time

from . import atomic, kinds

try:                                                   # optional: thumbnails and image sizes
    from PIL import Image
except Exception:                                      # noqa: BLE001
    Image = None

VERSION = 1
THUMB_QUALITY = 60


def now_ms():
    return int(time.time() * 1000)


def entry_id(data):
    return hashlib.sha256(data).hexdigest()[:16]


class Store:
    def __init__(self, root, cfg):
        self.root = root
        self.cfg = cfg
        self.index_path = os.path.join(root, "index.json")
        self.blobs = os.path.join(root, "blobs")
        self.thumbs = os.path.join(root, "thumbs")
        self.entries = []
        self.corrupt = False
        self.rethumbed = None                              # the record add() gave a thumb back, if it did
        self.thumbs_lost = []                              # the records prune() took a thumb from
        self._lock = None

    # ----------------------------------------------------------------------------- open / save

    def __enter__(self):
        self._lock = atomic.Lock(os.path.join(self.root, "index.lock")).acquire()
        self.load()
        return self

    def __exit__(self, *exc):
        self._lock.release()

    def load(self):
        raw = atomic.read_json(self.index_path)
        self.entries = []
        if raw is None and os.path.exists(self.index_path):
            self._quarantine()
        elif raw is not None:
            ok = isinstance(raw, dict) and isinstance(raw.get("entries"), list)
            if not ok:
                self._quarantine()
            else:
                self.entries = [e for e in raw["entries"] if isinstance(e, dict) and isinstance(e.get("id"), str)]
        self.sweep()

    def _quarantine(self):
        self.corrupt = True
        try:
            os.replace(self.index_path, self.index_path + ".corrupt")
        except OSError:
            pass

    def save(self):
        self.entries.sort(key=lambda e: e.get("last", 0), reverse=True)
        atomic.write_json(self.index_path, {"version": VERSION, "entries": self.entries}, indent=None)

    def sweep(self):
        """Delete blobs and thumbs that no record names."""
        named = set()
        for e in self.entries:
            named.add(e.get("blob"))
            named.add(e.get("thumb"))
        for d in (self.blobs, self.thumbs):
            try:
                names = os.listdir(d)
            except OSError:
                continue
            for n in names:
                if n not in named:
                    self._unlink(os.path.join(d, n))

    @staticmethod
    def _unlink(path):
        try:
            os.unlink(path)
        except OSError:
            pass

    # ----------------------------------------------------------------------------- lookup

    def get(self, ident):
        for e in self.entries:
            if e["id"] == ident:
                return e
        return None

    def _drop_files(self, e):
        if e.get("blob"):
            self._unlink(os.path.join(self.blobs, e["blob"]))
        if e.get("thumb"):
            self._unlink(os.path.join(self.thumbs, e["thumb"]))

    # ----------------------------------------------------------------------------- add / bump

    def add(self, data, mime, types, text, source, via="copy", first=None, last=None):
        """Store one copy. ("add", entry) for a new record, ("bump", {id,last,uses}) for known bytes, ("fold",
        {entry, replaced}) for a text that differs from a stored one only by whitespace at its ends.
        `mime` is the type the bytes were read as; `text` the decoded text (text types only)."""
        ident = entry_id(data)
        last = now_ms() if last is None else last
        old = self.get(ident)
        self.rethumbed = None
        if old is not None:
            old["last"] = last
            old["uses"] = old.get("uses", 1) + 1
            if self.rethumb(old):                          # copied again after its thumb was pruned
                self.rethumbed = old
            return "bump", {"id": ident, "last": old["last"], "uses": old["uses"]}
        e = self._record(ident, data, mime, types, text, source, via, last if first is None else first, last)
        twin = self._edge_twin(e)
        if twin is not None:
            # THE SAME TEXT BUT FOR ITS ENDS IS ONE ENTRY: an identical entry is not added again, the existing
            # entry gets its recency updated to now and becomes the active content. Byte-identical copies are
            # bumps; what would pile up are copies a newline apart -- VS Code copies a whole line WITH its "\n"
            # when nothing is selected, and a selection of the same words without it (12 such groups in 886
            # entries, 1 byte-identical). The entry keeps its history (first, uses, pin, title) and takes the bytes copied LAST,
            # because that is what the clipboard holds now. A copy older than the twin (an import) only counts as a use.
            if e["last"] <= twin.get("last", 0):
                twin["uses"] = twin.get("uses", 1) + 1
                return "bump", {"id": twin["id"], "last": twin["last"], "uses": twin["uses"]}
            e["first"] = twin.get("first", e["first"])
            e["uses"] = twin.get("uses", 1) + 1
            e["pinned"] = bool(twin.get("pinned"))
            e["title"] = twin.get("title", "")
            self.entries.remove(twin)
            self._drop_files(twin)
            self.entries.append(e)
            return "fold", {"entry": e, "replaced": twin["id"]}
        self.entries.append(e)
        return "add", e

    def _edge_twin(self, e):
        """The stored text entry whose text equals e's but for whitespace at the two ends, or None. Images, cut
        (truncated) texts and texts that are only whitespace have no twin."""
        if e.get("mime", "").startswith("image/") or e.get("truncated"):
            return None
        core = e["text"].strip()
        if not core:
            return None
        for x in self.entries:
            if x["id"] != e["id"] and not x.get("truncated") and not x.get("mime", "").startswith("image/") \
                    and x.get("text", "").strip() == core:
                return x
        return None

    def _record(self, ident, data, mime, types, text, source, via, first, last):
        picked = mime
        is_image = picked.startswith("image/")
        limit = int(self.cfg["textIndexKB"]) * 1024
        e = {"id": ident, "kind": "text", "mime": kinds.canonical_mime(picked), "types": list(types),
             "text": "", "truncated": False, "blob": None, "thumb": None, "bytes": len(data), "lines": 0,
             "w": 0, "h": 0, "source": _source(source), "via": via, "first": first, "last": last,
             "uses": 1, "pinned": False, "title": ""}
        if is_image:
            self._add_image(e, data)
        else:
            full = text if text is not None else data.decode("utf-8", "replace")
            raw = full.encode("utf-8")
            if len(raw) > limit:
                e["text"] = raw[:limit].decode("utf-8", "ignore")
                e["truncated"] = True
                self._write_blob(e, data, "txt")
            else:
                e["text"] = full
            e["lines"] = len(full.rstrip("\n").split("\n")) if full else 0
        e["kind"] = kinds.kind_of(e["text"], picked)
        return e

    def _write_blob(self, e, data, ext):
        name = "%s.%s" % (e["id"], ext)
        atomic.write_bytes(os.path.join(self.blobs, name), data)
        e["blob"] = name

    def _add_image(self, e, data):
        self._write_blob(e, data, kinds.ext_for(e["mime"]))
        w, h = _png_size(data) if data[:8] == b"\x89PNG\r\n\x1a\n" else (0, 0)
        if Image is not None:
            try:
                with Image.open(io.BytesIO(data)) as im:
                    w, h = im.size
            except Exception:                          # noqa: BLE001 - an undecodable image keeps its blob
                pass
        e["w"], e["h"] = w, h
        self._write_thumb(e, data)

    def _write_thumb(self, e, data):
        """thumbs/<id>.webp from the image's bytes; e["thumb"] stays None when there is no PIL, thumbsMax is
        0 or the image does not decode."""
        if Image is None or int(self.cfg["thumbsMax"]) <= 0:
            return False
        try:
            px = int(self.cfg["thumbPx"])
            with Image.open(io.BytesIO(data)) as im:
                t = im.copy()
            t.thumbnail((px, px))
            if t.mode not in ("RGB", "RGBA"):
                t = t.convert("RGBA" if "A" in t.getbands() or t.mode == "P" and "transparency" in t.info else "RGB")
            buf = io.BytesIO()
            t.save(buf, "WEBP", quality=THUMB_QUALITY, method=4)
            name = e["id"] + ".webp"
            atomic.write_bytes(os.path.join(self.thumbs, name), buf.getvalue())
            e["thumb"] = name
            return True
        except Exception:                              # noqa: BLE001
            return False

    def rethumb(self, e):
        """Give an image record that has lost its thumb a new one, cut from its blob. True if it got one."""
        if e.get("kind") != "image" or e.get("thumb") or not e.get("blob"):
            return False
        try:
            with open(os.path.join(self.blobs, e["blob"]), "rb") as f:
                data = f.read()
        except OSError:
            return False
        return self._write_thumb(e, data)

    def prune_thumbs(self):
        """Keep thumbnails for the newest `thumbsMax` unpinned images (by last copy) and for every pinned
        one: a pin is the user keeping the thing, and pins never expire. The records that lost theirs."""
        n = max(0, int(self.cfg["thumbsMax"]))
        imgs = sorted((e for e in self.entries if e.get("kind") == "image" and not e.get("pinned")),
                      key=lambda e: e.get("last", 0), reverse=True)
        lost = []
        for e in imgs[n:]:
            if e.get("thumb"):
                self._unlink(os.path.join(self.thumbs, e["thumb"]))
                e["thumb"] = None
                lost.append(e)
        return lost

    # ----------------------------------------------------------------------------- edits

    def update(self, ident, **fields):
        e = self.get(ident)
        if e is None:
            return None
        e.update(fields)
        return e

    def remove(self, ids):
        """Drop the records and their files; the ids that existed."""
        gone = []
        for ident in ids:
            e = self.get(ident)
            if e is not None:
                self.entries.remove(e)
                self._drop_files(e)
                gone.append(ident)
        return gone

    def prune(self, now=None):
        """Apply maxAgeDays, maxItems and maxTotalMB to the unpinned records, oldest first; the ids dropped.
        Then the thumbnail rule (`thumbs_lost` holds the records that lost one)."""
        now = now_ms() if now is None else now
        cfg = self.cfg
        free = sorted((e for e in self.entries if not e.get("pinned")), key=lambda e: e.get("last", 0), reverse=True)
        cutoff = now - int(cfg["maxAgeDays"]) * 86400000
        drop = [e for e in free if e.get("last", 0) < cutoff]
        keep = [e for e in free if e not in drop]
        drop += keep[int(cfg["maxItems"]):]
        keep = keep[:int(cfg["maxItems"])]
        total = sum(e.get("bytes", 0) for e in keep)
        cap = int(cfg["maxTotalMB"]) * 1024 * 1024
        while keep and total > cap:
            e = keep.pop()
            total -= e.get("bytes", 0)
            drop.append(e)
        gone = self.remove([e["id"] for e in drop])
        self.thumbs_lost = self.prune_thumbs()
        return gone


def _source(src):
    src = src or {}
    return {"cls": str(src.get("cls") or ""), "title": str(src.get("title") or ""),
            "address": str(src.get("address") or "")}


def _png_size(data):
    try:
        return struct.unpack(">II", data[16:24])
    except struct.error:
        return 0, 0
