#!/usr/bin/env python3
"""tok/s of ONE model on this machine, honestly.

    tools/llm/llm_tokps.py <model> [--predict N] [--runs K] [--ctx C] [--wait S]

Round 14 (RESEARCH). The "on this card" figures in LlmModelNotes.qml come
from here, so the method is fixed and printed with the result:

  * Refuses to start while /api/ps shows ANY model resident or another
    test_llm_*probe.qml is running (waits up to --wait seconds, then exits
    2). Two models on one 8 GB card measure neither -- the same rule as
    tools/dev/perf/scenario.sh -- and a running probe evicts what it finds.
  * One warm-up call (16 tokens) loads the model; /api/ps is then read for
    size / size_vram so the figure is reported WITH its residency (a model
    half in system RAM is a different machine from a model on the card).
  * --runs measured calls, same prompt, same seed, temperature 0, thinking
    off, --predict tokens each, num_ctx --ctx. tok/s = eval_count /
    eval_duration per the server's own counters; the MEDIAN is the figure.
  * keep_alive 0 afterwards and /api/ps polled until the model is gone --
    the machine is left as it was found.

Prints one machine-readable line at the end:
  RESULT model=<m> tokps=<median> runs=<a,b,c> prompt_tokps=<p> \
         size_gib=<s> vram_gib=<v> on_card=<pct>% load_s=<t> ctx=<C> predict=<N>
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

HOST = "http://127.0.0.1:11434"
PROMPT = ("Explain in plain words why the sky is blue during the day and "
          "red at sunset. Write about two hundred words.")


def api(path, body=None, timeout=900):
    req = urllib.request.Request(HOST + path,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"},
                                 method="GET" if body is None else "POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode() or "{}")


def resident():
    return [(m["name"], m.get("size", 0), m.get("size_vram", 0))
            for m in api("/api/ps").get("models", [])]


def probes():
    """Other LLM probes on this machine (pids). A tune/unload probe loads and
    EVICTS models while it runs: it took gemma4:26b off the card between the
    warm-up and /api/ps once, so /api/ps being empty is not the whole test."""
    try:
        out = subprocess.run(["pgrep", "-f", r"test_llm_\S*probe\.qml"],
                             capture_output=True, text=True).stdout.split()
        return [int(x) for x in out if int(x) != os.getpid()]
    except (OSError, ValueError):
        return []


def gen(model, predict, ctx, think):
    body = {"model": model, "prompt": PROMPT, "stream": False,
            "keep_alive": "10m",
            "options": {"num_predict": predict, "num_ctx": ctx,
                        "temperature": 0, "seed": 1}}
    if think is not None:
        body["think"] = think
    try:
        return api("/api/generate", body)
    except urllib.error.HTTPError as e:
        if think is not None and e.code == 400:
            # the model has no thinking switch; measure it as it is
            return gen(model, predict, ctx, None)
        raise


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--predict", type=int, default=128)
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--wait", type=int, default=120)
    a = ap.parse_args()

    t0 = time.time()
    while True:
        r = resident()
        p = probes()
        if not r and not p:
            break
        if time.time() - t0 > a.wait:
            print(f"REFUSED: resident {r} / probes running {p}")
            return 2
        print(f"waiting: resident {[n for n, _, _ in r]} probes {p}")
        time.sleep(5)

    t = time.time()
    first = gen(a.model, 16, a.ctx, False)
    load_s = time.time() - t
    if first.get("error"):
        print(f"FAIL: warm-up error: {first['error']}")
        return 1
    ps = [x for x in resident() if x[0] == a.model or x[0].startswith(a.model)]
    if not ps:
        print(f"FAIL: {a.model} not in /api/ps after the warm-up: {resident()} "
              f"(probes running: {probes()})")
        return 1
    _, size, vram = ps[0]
    gib = 1024 ** 3
    print(f"loaded {a.model} in {load_s:.1f}s  size {size/gib:.2f} GiB  "
          f"vram {vram/gib:.2f} GiB  on card {100*vram/size:.0f}%  "
          f"(warm-up load_duration {first.get('load_duration',0)/1e9:.1f}s)")

    tokps, ptokps = [], []
    for i in range(a.runs):
        r = gen(a.model, a.predict, a.ctx, False)
        ec, ed = r.get("eval_count", 0), r.get("eval_duration", 1)
        pc, pd = r.get("prompt_eval_count", 0), r.get("prompt_eval_duration", 1)
        tokps.append(ec / (ed / 1e9))
        ptokps.append(pc / (pd / 1e9) if pd else 0)
        reload = r.get("load_duration", 0) / 1e9
        print(f"run {i+1}: {ec} tok in {ed/1e9:.2f}s = {tokps[-1]:.2f} tok/s   "
              f"prompt {pc} tok = {ptokps[-1]:.1f} tok/s   "
              f"done={r.get('done_reason')}"
              + (f"   RELOADED ({reload:.1f}s) -- something evicted it between runs"
                 if reload > 1.0 else ""))

    # A second model appearing mid-run means the figures were shared with it.
    others = [x for x in resident() if not x[0].startswith(a.model)]
    if others:
        print(f"CONTAMINATED: another model was resident during the runs: {others}")

    # leave the machine as found
    api("/api/generate", {"model": a.model, "keep_alive": 0}, timeout=120)
    for _ in range(60):
        if not resident():
            break
        time.sleep(1)
    left = resident()
    print(f"unloaded: /api/ps {'empty' if not left else left}")

    med = statistics.median(tokps)
    print(f"RESULT model={a.model} tokps={med:.2f} "
          f"runs={','.join(f'{x:.2f}' for x in tokps)} "
          f"prompt_tokps={statistics.median(ptokps):.1f} "
          f"size_gib={size/gib:.2f} vram_gib={vram/gib:.2f} "
          f"on_card={100*vram/size:.0f}% load_s={load_s:.1f} "
          f"ctx={a.ctx} predict={a.predict}")
    return 0 if not left else 1


if __name__ == "__main__":
    sys.exit(main())
