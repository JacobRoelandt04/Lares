#!/usr/bin/env python3
"""The wiki module's tool: every network, text and model step of the module (stdlib + PIL; NDJSON on stdout).

    wiki.py batch --tab discover|deepen --n 30 [--resume]     stdin: {"plan": [...], "recent": [...], "n": 30,
                                                                       "sources": {...}}
    wiki.py load --url URL --tab T [--allow-generate]         the rabbit hole
    wiki.py daily [--day YYYY-MM-DD]                          On this day + the Picture of the day
    wiki.py save-note --tab T --id ID --notes-root DIR --folder Wiki
    wiki.py installed | gpu | index | validate                debug: what the tool sees

Events and files: docs/contracts/wiki.md. Exit: 0 done (even with skips and failures), 1 the
request could not be served (no such entry, no such page), 2 usage or a batch of that tab already running, 3
blocked (a local model was needed and the GPU was busy or would spill, and nothing could be produced), 4 network
down.

Environment (the service sets WIKI_OLLAMA_URL, WIKI_JEV, WIKI_SOURCES, WIKI_JEV_CAP_USD and the two models on every job; the rest are for probes):
    WIKI_OLLAMA_URL   Ollama's base URL                       WIKI_JEV       "0" = never ask Jev, local judge only
    WIKI_SOURCES      JSON of the source toggles              WIKI_SEED      an integer: every random choice follows it
                                                              (item i of a batch draws from Random("<seed>:<i>"))
    WIKI_HTTP_MAP, WIKI_HTTP_GAP   (lib/http.py)
    WIKI_JEV_CAP_USD  the Jev spend cap of one batch (0.04)   WIKI_TODAY      the day whose picture a batch reads
    WIKI_MODEL_WRITE, WIKI_MODEL_JUDGE   the local writer / judge ("" = models.json's: pipeline.models)
    XDG_STATE_HOME / XDG_CACHE_HOME / XDG_CONFIG_HOME         where everything lives

The Jev key (`jevKey` in config/wiki.jsonc, lib/env.py) is read by lib/judge_jev, kept in memory and put in one request header; it is in no
argv, no child's environment, no log line, event or file (lib/env.scrub covers every output path below).
"""
import argparse
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lib import env                                                    # noqa: E402

env.install_excepthook()

from lib import (atomic, batch, daily, entry, gpu, http, index, installed, judge, mw, ndjson, notes, paths,   # noqa: E402
                 pipeline, title as titlelib)


def emit(ev):
    """One event on stdout; a reader that has gone away (a shell reload) does not stop the work."""
    try:
        ndjson.emit(ev)
    except BrokenPipeError:
        try:
            sys.stdout = open(os.devnull, "w")
        except OSError:
            pass


def read_stdin_json():
    if sys.stdin is None or sys.stdin.isatty():
        return {}
    try:
        text = sys.stdin.read()
    except OSError:
        return {}
    if not text.strip():
        return {}
    try:
        d = json.loads(text)
    except ValueError:
        env.log("stdin is not JSON")
        return None
    return d if isinstance(d, dict) else None


def make_ctx_factory(tab, payload):
    def make(batch_id, _payload, seed):
        return pipeline.Ctx(tab, batch_id, emit=emit, log=env.log, seed=seed, sources=(payload or {}).get("sources"),
                            recent=(payload or {}).get("recent"))
    return make


# ----------------------------------------------------------------------------- commands

def cmd_batch(a):
    payload = read_stdin_json()
    if payload is None:
        return 2
    return batch.run(a.tab, a.resume, payload, make_ctx=make_ctx_factory(a.tab, payload),
                     process_item=pipeline.process_item, emit=emit, log=env.log, n_cap=a.n)


def cmd_load(a):
    ctx = pipeline.Ctx(a.tab, "follow", emit=emit, log=env.log)
    try:
        return pipeline.load(a.url, a.tab, a.allow_generate, ctx)
    finally:
        ctx.close()


def _resident_title_chat():
    """The chat of title.short_title on the writer model, ONLY when Ollama already has it loaded: a standalone `daily`
    never takes the card or wakes the dGPU for a title (the batch does that through its GpuSession). None otherwise."""
    url = os.environ.get("WIKI_OLLAMA_URL") or gpu.DEFAULT_URL
    model = pipeline.models()["write"]["model"]
    try:
        loaded = gpu.OllamaAPI(url).ps()
    except http.NetError:
        return None
    if not any(gpu.same_model(m["name"], model) for m in loaded):
        return None
    return titlelib.ollama_chat(model, url)


def cmd_daily(a):
    day = a.day or os.environ.get("WIKI_TODAY") or time.strftime("%Y-%m-%d", time.gmtime())
    try:
        time.strptime(day, "%Y-%m-%d")
    except ValueError:
        env.log("--day must be YYYY-MM-DD, got %r" % day)
        return 2
    d = daily.build(day, deny=paths.families()["guest"]["deny"], log=env.log, shorten=_resident_title_chat())
    emit({"ev": "daily", "daily": d})
    return 0


def cmd_save_note(a):
    try:
        r = notes.save(a.tab, a.id, a.notes_root, a.folder)
    except notes.NoteError as e:
        env.log(str(e))
        return 1
    emit({"ev": "saved", "path": r["path"], "key": r["key"]})
    return 0


def cmd_installed(a):
    s = installed.snapshot()
    emit({"ev": "installed", "packages": len(s["pkgs"]), "repo": len(s["repo"]), "units": len(s["units"]),
          "asOf": s["asOf"], "sample": sorted(s["pkgs"])[:10]})
    return 0


def cmd_gpu(a):
    url = os.environ.get("WIKI_OLLAMA_URL") or gpu.DEFAULT_URL
    smi = gpu.nvidia_smi()
    try:
        models = [m["name"] for m in gpu.OllamaAPI(url).ps()]
        state = "busy" if models else "free"
    except http.NetError as e:
        models, state = [], "unknown"
        env.log("ollama: %s" % e)
    emit({"ev": "gpu", "state": state, "models": models, "freeMiB": smi["freeMiB"] if smi else None})
    return 0


def cmd_index(a):
    idx = index.read()
    out = {"ev": "index", "tabs": {}}
    for tab in paths.TABS:
        fams = {}
        for r in idx["tabs"][tab]:
            fams[r.get("family")] = fams.get(r.get("family"), 0) + 1
        out["tabs"][tab] = {"n": len(idx["tabs"][tab]), "families": fams}
    emit(out)
    return 0


def cmd_validate(a):
    """Every entry file validated (files included), and the index checked against them."""
    ok, bad, on_disk = 0, [], {}
    for tab in paths.TABS:
        d = paths.entries_dir(tab)
        try:
            names = sorted(f for f in os.listdir(d) if f.endswith(".json"))
        except OSError:
            names = []
        for f in names:
            e = atomic.read_json(os.path.join(d, f))
            errs = entry.validate(e, check_files=True) if e is not None else ["not JSON"]
            if e is not None and paths.slug(e.get("id", "")) + ".json" != f:
                errs.append("file name does not match the id")
            if errs:
                bad.append({"file": f, "tab": tab, "errors": errs})
            else:
                ok += 1
                on_disk[(tab, e["id"])] = f
    idx = index.read()
    rows = {(t, r["id"]) for t in paths.TABS for r in idx["tabs"][t]}
    missing = sorted(i for t, i in rows - set(on_disk))
    orphans = sorted(i for t, i in set(on_disk) - rows)
    emit({"ev": "validate", "ok": ok, "bad": bad, "indexMissingEntry": missing, "entryNotIndexed": orphans})
    return 0 if not bad and not missing else 1


def parser():
    p = argparse.ArgumentParser(prog="wiki.py", description="the wiki module's tool")
    sub = p.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("batch")
    b.add_argument("--tab", required=True, choices=paths.TABS)
    b.add_argument("--n", type=int, default=30)
    b.add_argument("--resume", action="store_true")
    b.set_defaults(fn=cmd_batch)
    l = sub.add_parser("load")
    l.add_argument("--url", required=True)
    l.add_argument("--tab", required=True, choices=paths.TABS)
    l.add_argument("--allow-generate", action="store_true")
    l.set_defaults(fn=cmd_load)
    d = sub.add_parser("daily")
    d.add_argument("--day")
    d.set_defaults(fn=cmd_daily)
    s = sub.add_parser("save-note")
    s.add_argument("--tab", required=True, choices=paths.TABS)
    s.add_argument("--id", required=True)
    s.add_argument("--notes-root", required=True)
    s.add_argument("--folder", default="Wiki")
    s.set_defaults(fn=cmd_save_note)
    for name, fn in (("installed", cmd_installed), ("gpu", cmd_gpu), ("index", cmd_index), ("validate", cmd_validate)):
        sub.add_parser(name).set_defaults(fn=fn)
    return p


def main(argv=None):
    a = parser().parse_args(argv)
    try:
        return a.fn(a)
    except http.Offline as e:
        env.log("no network: %s" % e)
        return 4
    except (http.NetError, mw.MwError) as e:
        env.log("%s failed: %s" % (a.cmd, e))
        return 1


if __name__ == "__main__":
    sys.exit(main())
