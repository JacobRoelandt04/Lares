#!/usr/bin/env python3
"""The clipboard store's only writer.

    clip.py ingest                 one clipboard change (run by `wl-paste --watch`; env CLIPBOARD_STATE)
    clip.py keep [--mime M --source-cls C --source-title T --source-address A --via V]   stdin bytes
    clip.py seal <id> | pin <id> | unpin <id> | rename <id> <title> | tag <id> <via>
    clip.py delete <id>... | prune | import-cliphist

Output is NDJSON on stdout, one event per line, flushed (contract: CONTRACT.md). `ingest` always exits
0 so the watcher loop never sees a failure; the one-shots exit 0, 1 (bad argument, unknown id) or 2
(store error). A secret never touches disk or argv, and no event or stderr line carries clipboard
bytes: errors name the exception class only.
"""
import base64
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lib import config, kinds, secret, store, wl            # noqa: E402


def emit(ev):
    line = json.dumps(ev, ensure_ascii=False, separators=(",", ":"))
    line = line.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    out = sys.stdout
    out.flush()
    out.buffer.write((line + "\n").encode("utf-8"))
    out.buffer.flush()


def _err(e):
    """An error event that cannot carry bytes: the class, and the OS's own words for an OSError."""
    msg = type(e).__name__
    if isinstance(e, OSError) and e.strerror:
        msg += ": " + e.strerror
    emit({"ev": "error", "msg": msg})


def _read_stdin():
    try:
        if sys.stdin is None or sys.stdin.isatty():
            return b""
        return sys.stdin.buffer.read()
    except (OSError, ValueError):
        return b""


def _too_large(size, mime, cfg):
    cap = int(cfg["maxImageMB"]) * 1024 * 1024 if mime.startswith("image/") else config.MAX_OTHER_BYTES
    return size > cap


def _text_of(data, mime):
    return data.decode("utf-8", "replace") if kinds.is_text_type(mime) else None


def _sealed_event(data, mime, reason, source, t):
    return {"ev": "secret", "b64": base64.b64encode(data).decode("ascii"), "mime": mime, "reason": reason,
            "source": {"cls": source.get("cls", ""), "title": source.get("title", "")}, "t": t}


def _store_copy(st, data, picked, types, source, via, **kw):
    if _too_large(len(data), picked, st.cfg):
        emit({"ev": "skip", "why": "toolarge"})
        return None
    kind, payload = st.add(data, picked, types, _text_of(data, picked), source, via, **kw)
    return kind, payload


def _emit_prune(st, gone):
    """What prune() did: the records it removed, and the ones that only lost their thumbnail (an update, so
    the shelf swaps the picture for its placeholder)."""
    if gone:
        emit({"ev": "remove", "ids": gone, "why": "prune"})
    for e in st.thumbs_lost:
        if e["id"] not in gone:
            emit({"ev": "update", "entry": e})


def _announce(st, kind, payload):
    if kind == "add":
        emit({"ev": "add", "entry": payload})
    elif kind == "fold":                               # the twin goes, the copy made last takes its place on top
        emit({"ev": "remove", "ids": [payload["replaced"]], "why": "fold"})
        emit({"ev": "add", "entry": payload["entry"]})
    else:
        emit({"ev": "bump", **payload})
        if st.rethumbed is not None:                   # copied again: its thumbnail is cut anew
            emit({"ev": "update", "entry": st.rethumbed})
    _emit_prune(st, st.prune())
    st.save()


# ----------------------------------------------------------------------------- commands

def cmd_ingest(cfg):
    state = os.environ.get("CLIPBOARD_STATE", "data")
    t = store.now_ms()
    if state in ("nil", "clear"):
        emit({"ev": state, "t": t})
        return 0
    stdin = _read_stdin()
    source = wl.active_window()
    if secret.listed(source["cls"], cfg["ignoreApps"]):
        emit({"ev": "skip", "why": "ignored"})        # nothing of it is kept, sealed or not
        return 0
    if state == "sensitive":
        emit(_sealed_event(stdin, "text/plain;charset=utf-8", "hint", source, t))
        return 0
    types = wl.list_types()
    picked = kinds.pick_type(types)
    if picked is None and stdin:
        picked = "text/plain;charset=utf-8"           # no wl-paste to ask: the watch's own stdin is text
    if picked is None:
        emit({"ev": "empty", "t": t, "source": {"cls": source["cls"], "title": source["title"]}}
             if not types and not stdin else {"ev": "skip", "why": "unsupported"})
        return 0
    data = wl.paste(picked)
    if data is None and kinds.is_text_type(picked):
        data = stdin
    if not data:
        emit({"ev": "empty", "t": t, "source": {"cls": source["cls"], "title": source["title"]}})
        return 0
    if _too_large(len(data), picked, cfg):
        emit({"ev": "skip", "why": "toolarge"})
        return 0
    sealed, reason = secret.classify(data, picked, source["cls"], cfg)
    if sealed:
        emit(_sealed_event(data, kinds.canonical_mime(picked), reason, source, t))
        return 0
    with store.Store(config.state_dir(), cfg) as st:
        kind, payload = st.add(data, picked, types, _text_of(data, picked), source, "copy", last=t)
        _announce(st, kind, payload)
    return 0


def _flag(args, name, default=""):
    if name in args:
        i = args.index(name)
        if i + 1 < len(args):
            return args[i + 1]
    return default


def cmd_keep(cfg, args):
    data = _read_stdin()
    mime = _flag(args, "--mime", "text/plain;charset=utf-8")
    if not data:
        emit({"ev": "empty", "t": store.now_ms(), "source": {"cls": "", "title": ""}})
        return 0
    source = {"cls": _flag(args, "--source-cls"), "title": _flag(args, "--source-title"),
              "address": _flag(args, "--source-address")}
    with store.Store(config.state_dir(), cfg) as st:
        res = _store_copy(st, data, mime, [mime], source, _flag(args, "--via", "copy"))
        if res:
            _announce(st, *res)
    return 0


def _edit(cfg, ident, fn):
    with store.Store(config.state_dir(), cfg) as st:
        e = st.get(ident)
        if e is None:
            emit({"ev": "error", "msg": "unknown id"})
            return 1
        fn(st, e)
        st.save()
        emit({"ev": "update", "entry": e})
    return 0


def _pin(st, e, on):
    """A pinned image keeps (or gets back) its thumbnail; an unpinned one goes back under thumbsMax."""
    e["pinned"] = on
    if on:
        st.rethumb(e)
    else:
        st.prune_thumbs()


def cmd_seal(cfg, ident):
    with store.Store(config.state_dir(), cfg) as st:
        gone = st.remove([ident])
        if not gone:
            emit({"ev": "error", "msg": "unknown id"})
            return 1
        st.save()
        emit({"ev": "remove", "ids": gone, "why": "seal"})
    return 0


def cmd_delete(cfg, ids):
    with store.Store(config.state_dir(), cfg) as st:
        gone = st.remove(ids)
        st.save()
        if gone:
            emit({"ev": "remove", "ids": gone, "why": "delete"})
        if len(gone) != len(set(ids)):
            emit({"ev": "error", "msg": "unknown id"})
            return 1
    return 0


def cmd_prune(cfg):
    with store.Store(config.state_dir(), cfg) as st:
        gone = st.prune()
        st.save()
        _emit_prune(st, gone)
    return 0


def _sniff(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return "text/plain;charset=utf-8"


def cmd_import(cfg):
    ids = wl.cliphist_list()
    if ids is None:
        emit({"ev": "error", "msg": "cliphist not available"})
        return 1
    added = dropped = 0
    now = store.now_ms()
    with store.Store(config.state_dir(), cfg) as st:
        for i, ident in enumerate(ids):
            data = wl.cliphist_decode(ident)
            if not data:
                dropped += 1
                continue
            mime = _sniff(data)
            sealed, _ = secret.classify(data, mime, "", cfg)
            if sealed or _too_large(len(data), mime, cfg):
                dropped += 1
                continue
            kind, _p = st.add(data, mime, [mime], _text_of(data, mime), {}, "import", first=0, last=now - i - 1)
            added += kind == "add"
        st.prune()
        st.save()
    emit({"ev": "import", "added": added, "dropped": dropped})
    return 0


# ----------------------------------------------------------------------------- main

def main(argv):
    if len(argv) < 2:
        print("usage: clip.py <ingest|keep|seal|pin|unpin|rename|tag|delete|prune|import-cliphist|config>", file=sys.stderr)
        return 1
    cmd, args = argv[1], argv[2:]
    cfg = config.load()
    if cmd == "ingest":
        try:
            return cmd_ingest(cfg)
        except BaseException as e:                     # noqa: BLE001 - ingest never fails the watcher
            if not isinstance(e, (SystemExit, KeyboardInterrupt)):
                _err(e)
            return 0
    try:
        return _one_shot(cfg, cmd, args)
    except (OSError, ValueError) as e:
        _err(e)
        return 2


def _one_shot(cfg, cmd, args):
    need = {"seal": 1, "pin": 1, "unpin": 1, "rename": 2, "tag": 2}
    if cmd in need and len(args) < need[cmd]:
        print("clip.py %s: missing argument" % cmd, file=sys.stderr)
        return 1
    if cmd == "keep":
        return cmd_keep(cfg, args)
    if cmd == "seal":
        return cmd_seal(cfg, args[0])
    if cmd in ("pin", "unpin"):
        return _edit(cfg, args[0], lambda st, e: _pin(st, e, cmd == "pin"))
    if cmd == "rename":
        return _edit(cfg, args[0], lambda st, e: e.update(title=args[1]))
    if cmd == "tag":
        return _edit(cfg, args[0], lambda st, e: e.update(via=args[1]))
    if cmd == "delete":
        if not args:
            print("clip.py delete: missing id", file=sys.stderr)
            return 1
        return cmd_delete(cfg, args)
    if cmd == "prune":
        return cmd_prune(cfg)
    if cmd == "import-cliphist":
        return cmd_import(cfg)
    if cmd == "config":
        # The merged config, so the shell takes its defaults from here and nowhere else.
        emit({"ev": "config", "config": cfg, "stateDir": config.state_dir(), "configPath": config.config_path()})
        return 0
    print("clip.py: unknown command", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
