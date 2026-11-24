#!/usr/bin/env python3
"""The dictation bench (research section 7.3): every shortlisted model on the FLEURS clips, one model per process.

    bench.py model <id> [--device igpu|cpu|cuda] [--clips N] [--out file.json]   one model: quality, cost, live, language, load
    bench.py model <live>+<final> | <live>+nl:<final> ...     the second pass: every final from <final>, or only Dutch ones
    bench.py tidy <tidy id> [--device cpu|cuda] [--out file.json]      the tidy pass on tools/stt/tidy_cases.tsv
    bench.py table <file.json> ...                                         the markdown table of several runs

`--device cuda` runs on the NVIDIA card (CUDA) and fails the row when the model does not land there (never a silent CPU number).

Measured per model:
  1 quality   WER per language over the clips (whole clip, forced language where the model takes one), punctuation / casing
  2 cost      one decode of a 5 / 10 / 20 s window (warm, median of 5); CPU % of one core and the iGPU's busy share (1 - rc6) over
              those decodes; peak RSS of the process
  3 live      each clip through the policy (sttlib/policy.py) on a SIMULATED clock -- audio arrives at 1x, every decode costs its
              measured wall time -- 1 s of silence before and 1.5 s after: first word on screen after the speech onset, final text
              after the speech ends, hypotheses and revised words, WER of the committed text
  4 language  each detector of sttlib/lang.py on the first 1.5 s and 3 s of speech of every clip
  5 load      first load in the process and a second one (OpenVINO: compile, then the compiled-model cache)

Everything reads the private cache (~/.cache/lares-stt); no microphone, no PipeWire, no network.
"""
import json
import os

# numpy's BLAS (the mel features) starts one thread per core and spins them: 19 cores busy for a decode measured with 8 ONNX threads.
# The pool is sized when numpy loads, so before any import that loads it; the decoders size their own ONNX threads.
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "4")
import resource
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

from sttlib import decoders, lang as langlib  # noqa: E402
from sttlib.audio import read_wav  # noqa: E402
from sttlib.policy import Engine, norm, words_of  # noqa: E402
from sttlib.vad import StreamingVad  # noqa: E402

RATE = 16000
CLIPS = decoders.HOME / "clips"
RC6 = Path("/sys/class/drm/card1/gt/gt0/rc6_residency_ms")


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def clips(lang, n):
    rows = []
    for line in open(CLIPS / lang / "refs.tsv", encoding="utf-8"):
        f, secs, raw, normd = line.rstrip("\n").split("\t")
        rows.append({"file": str(CLIPS / lang / f), "secs": float(secs), "raw": raw, "ref": normd, "lang": lang})
    return rows[:n]


def normtext(t):
    return " ".join(norm(w) for w in words_of(t) if norm(w))


def wer(refs, hyps):
    import jiwer

    pairs = [(r, h) for r, h in zip(refs, hyps) if r.strip()]
    return 100.0 * jiwer.wer([r for r, _ in pairs], [h if h.strip() else "<empty>" for _, h in pairs])


def cpu_s():
    r = resource.getrusage(resource.RUSAGE_SELF)
    return r.ru_utime + r.ru_stime


def rc6_ms():
    try:
        return int(RC6.read_text())
    except OSError:
        return None


def simulate(dec, vad, audio, lang, cfg=None, detector=None, prior="en", final_decoder=None, final_decoders=None, tidier=None):
    """One clip through the policy on a simulated clock. Returns the timed events and the onset / speech-end instants."""
    full = np.concatenate((np.zeros(RATE, np.float32), audio, np.zeros(int(1.5 * RATE), np.float32)))
    out, pending = [], []
    eng = Engine(dec, vad, pending.append, cfg, detector, final_decoder, final_decoders, tidier)
    eng.start(1, lang or "auto", prior, 0.0)
    t, pos, onset, speech_end = 0.0, 0, None, None
    step = 0.032
    while True:
        upto = min(full.size, int(t * RATE))
        w0 = time.perf_counter()
        eng.feed(full[pos:upto], t)
        pos = upto
        if eng.open and onset is None:
            onset = eng.onset_sample / RATE
        if eng.pending_final is not None:
            speech_end = eng.last_speech / RATE
        did = eng.tick(t)
        d = time.perf_counter() - w0
        t += d if did else max(step, d)
        for ev in pending:
            out.append((t, ev))
        pending.clear()
        if pos >= full.size and not eng.open and eng.pending_final is None:
            break
        if t > full.size / RATE + 60:
            break
    eng.stop(t)
    for ev in pending:
        out.append((t, ev))
    return out, onset, speech_end


def revisions(events):
    """Hypotheses, the hypotheses that changed a word already shown, and the words so changed (the final decode included)."""
    hyps = revised = words = 0
    last = {}
    for _, ev in events:
        if ev["ev"] not in ("hyp", "seg"):
            continue
        seg = ev["seg"]
        new = [norm(w) for w in words_of(ev["text"])]
        old = last.get(seg)
        if ev["ev"] == "hyp":
            hyps += 1
        if old is not None:
            ch = sum(1 for a, b in zip(old, new) if a != b) + max(0, len(old) - len(new))
            if ch:
                revised += 1
                words += ch
        last[seg] = new
    return hyps, revised, words


def live_rows(res, mid, dec, vad, sets, audio, final_decoder=None, final_decoders=None):
    """Section 3: every clip through the policy on the simulated clock, per language."""
    for lg, rows in sets.items():
        first, final, committed, h_n, r_n, w_n = [], [], [], 0, 0, 0
        for c in rows:
            ev, onset, end = simulate(dec, vad, audio[c["file"]], lg, final_decoder=final_decoder, final_decoders=final_decoders)
            hyp_t = [t for t, e in ev if e["ev"] == "hyp" and e["text"]]
            seg_t = [t for t, e in ev if e["ev"] == "seg"]
            if onset is not None and hyp_t:
                first.append(hyp_t[0] - onset)
            if end is not None and seg_t:
                final.append(seg_t[-1] - end)
            committed.append(" ".join(e["text"] for _, e in ev if e["ev"] == "seg"))
            h, r, w = revisions(ev)
            h_n, r_n, w_n = h_n + h, r_n + r, w_n + w
        res[f"live_wer_{lg}"] = round(wer([c["ref"] for c in rows], [normtext(x) for x in committed]), 2)
        res[f"first_word_{lg}_s"] = round(statistics.median(first), 2) if first else None
        res[f"first_word_{lg}_p90_s"] = round(sorted(first)[int(0.9 * (len(first) - 1))], 2) if first else None
        res[f"final_{lg}_s"] = round(statistics.median(final), 2) if final else None
        res[f"hyps_{lg}"], res[f"revising_hyps_{lg}"], res[f"revised_words_{lg}"] = h_n, r_n, w_n
        log(f"{mid}: live {lg}: first {res[f'first_word_{lg}_s']} s, final {res[f'final_{lg}_s']} s, WER {res[f'live_wer_{lg}']}, "
            f"{r_n} of {h_n} hypotheses revised {w_n} words")


def _load(mid, device):
    d = decoders.load(mid, device, "ac")
    if device == "cuda" and not d.device.startswith("CUDA"):
        raise SystemExit(f"{mid} did not land on the card (it runs on {d.device}): no CPU number is a CUDA number")
    return d


def vram_mb():
    """This process's memory on the NVIDIA card (nvidia-smi, read once, with the card already awake), or None."""
    import subprocess

    try:
        out = subprocess.run(["timeout", "10", "nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"],
                             capture_output=True, text=True).stdout
        return sum(int(m) for p, m in (ln.split(",") for ln in out.splitlines() if "," in ln) if int(p) == os.getpid())
    except Exception:  # noqa: BLE001
        return None


def bench_two_pass(mid, n, device="igpu"):
    """`<live>+<final>`: the live hypotheses from one model, each utterance's final decode from the other; `<live>+nl:<final>`:
    the other only for Dutch (the pick on the card). Only the live section: quality, cost and load are the single-model runs'."""
    live_id, final_spec = mid.split("+")
    only_nl = final_spec.startswith("nl:")
    final_id = final_spec[3:] if only_nl else final_spec
    res = {"model": mid, "when": time.strftime("%Y-%m-%d %H:%M"), "cpu": os.cpu_count()}
    vad = StreamingVad(decoders.MODELS_DIR / "silero-vad")
    live, fin = _load(live_id, device), _load(final_id, device)
    res["device"] = live.device + " / " + fin.device
    sets = {lg: clips(lg, n) for lg in ("en", "nl")}
    audio = {c["file"]: read_wav(c["file"]) for lg in sets for c in sets[lg]}
    if only_nl:
        live_rows(res, mid, live, vad, sets, audio, final_decoders={"nl": fin})
    else:
        live_rows(res, mid, live, vad, sets, audio, fin)
    res["peak_rss_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    if device == "cuda":
        res["vram_mb"] = vram_mb()
    return res


def bench_tidy(tid, device, budget_ms=10000):
    """The tidy pass on the test sentences: exact (as a careful typist would write it), refused by the guard, HARM (passed the
    guard yet neither the expected sentence nor the one heard), the time per sentence."""
    from sttlib import tidy

    rows = [ln.rstrip("\n").split("\t") for ln in open(Path(__file__).resolve().parent / "tidy_cases.tsv", encoding="utf-8")
            if ln.strip() and not ln.startswith("#")]
    t0 = time.perf_counter()
    t = tidy.load(tid, "CUDA" if device == "cuda" else "CPU", decoders.threads_for("ac"))
    if device == "cuda" and t.device != "CUDA":
        raise SystemExit(f"{tid} did not land on the card")
    t.budget_ms = budget_ms
    res = {"kind": "tidy", "model": tid, "device": t.device, "when": time.strftime("%Y-%m-%d %H:%M"),
           "load_s": round(time.perf_counter() - t0, 2)}
    t("A first sentence to warm it up, warm it up.", "en")
    exact = refused = harm = 0
    ms, cases = [], []
    for lang, src, want in rows:
        out, info = t(src, lang)
        ms.append(info["ms"])
        exact += out == want
        refused += not info["ok"]
        harm += info["ok"] and out != want and out != src
        cases.append({"lang": lang, "in": src, "out": out, "want": want, "ok": info["ok"], "why": info["why"], "ms": info["ms"]})
        log(f"{tid}: {'==' if out == want else '!='} {info['ms']} ms {info['why'] or 'ok'} | {src} -> {info['proposed']}")
    ms.sort()
    res.update({"cases": len(rows), "exact": exact, "refused": refused, "harm": harm, "ms_median": ms[len(ms) // 2],
                "ms_p90": ms[int(0.9 * (len(ms) - 1))], "samples": cases,
                "peak_rss_mb": round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)})
    if device == "cuda":
        res["vram_mb"] = vram_mb()
    log(f"{tid} on {t.device}: exact {exact}/{len(rows)}, refused {refused}, harm {harm}, median {res['ms_median']} ms")
    return res


def bench_model(mid, device, n):
    if "+" in mid:
        return bench_two_pass(mid, n, device)
    res = {"model": mid, "when": time.strftime("%Y-%m-%d %H:%M"), "cpu": os.cpu_count()}
    vad = StreamingVad(decoders.MODELS_DIR / "silero-vad")

    # 5 load: the first one compiles for the iGPU (its cache cleared), the second reads the compiled model from the cache
    import shutil

    shutil.rmtree(decoders.HOME / "ov-cache" / mid, ignore_errors=True)
    t0 = time.perf_counter()
    dec = _load(mid, device)
    res["load_first_s"] = round(time.perf_counter() - t0, 2)
    del dec
    t0 = time.perf_counter()
    dec = _load(mid, device)
    res["load_again_s"] = round(time.perf_counter() - t0, 2)
    res["device"] = dec.device
    log(f"{mid}: loaded on {dec.device} ({res['load_first_s']} s, again {res['load_again_s']} s)")

    sets = {lg: clips(lg, n) for lg in ("en", "nl")}
    audio = {c["file"]: read_wav(c["file"]) for lg in sets for c in sets[lg]}

    # 1 quality
    for lg, rows in sets.items():
        hyps, punct, cased = [], 0, 0
        for c in rows:
            h = dec.decode(audio[c["file"]], lg)
            hyps.append(h)
            punct += any(ch in h for ch in ".,?!")
            cased += bool(h[:1].isupper())
        res[f"wer_{lg}"] = round(wer([c["ref"] for c in rows], [normtext(h) for h in hyps]), 2)
        res[f"punct_{lg}"] = f"{punct}/{len(rows)}"
        res[f"cased_{lg}"] = f"{cased}/{len(rows)}"
        res[f"samples_{lg}"] = [{"ref": rows[i]["raw"], "hyp": hyps[i]} for i in range(min(3, len(rows)))]
        log(f"{mid}: WER {lg} {res[f'wer_{lg}']}")

    # 2 cost: windows from concatenated Dutch clips
    long = np.concatenate([audio[c["file"]] for c in sets["nl"]])
    for secs in (5, 10, 20):
        w = long[: secs * RATE]
        dec.decode(w, "nl")
        c0, g0, w0 = cpu_s(), rc6_ms(), time.perf_counter()
        ts = []
        for _ in range(5):
            a = time.perf_counter()
            dec.decode(w, "nl")
            ts.append((time.perf_counter() - a) * 1000)
        wall = time.perf_counter() - w0
        res[f"decode_{secs}s_ms"] = round(statistics.median(ts))
        res[f"cpu_{secs}s_pct"] = round(100 * (cpu_s() - c0) / wall)
        g1 = rc6_ms()
        res[f"gpu_{secs}s_pct"] = None if g0 is None or g1 is None else round(100 * (1 - (g1 - g0) / (wall * 1000)))
    log(f"{mid}: decode 5/10/20 s = {res['decode_5s_ms']}/{res['decode_10s_ms']}/{res['decode_20s_ms']} ms")

    # 3 live
    live_rows(res, mid, dec, vad, sets, audio)

    # 4 language
    methods = ["score"] if decoders.MODELS[mid]["forceable"] else ["self-fw"]
    for m in methods:
        det = langlib.detector(m, dec)
        for secs in (1.5, 3.0):
            ok = total = 0
            ms = []
            for lg, rows in sets.items():
                for c in rows:
                    a = audio[c["file"]]
                    vad.reset()
                    p = vad.feed(a)
                    on = next((i for i, x in enumerate(p) if x >= 0.5), 0) * 512
                    seg = a[max(0, on - 4800): on + int(secs * RATE)]
                    t0 = time.perf_counter()
                    got, _, _ = det(seg)
                    ms.append((time.perf_counter() - t0) * 1000)
                    ok += got == lg
                    total += 1
            res[f"lid_{m}_{secs}s"] = f"{ok}/{total}"
            res[f"lid_{m}_{secs}s_ms"] = round(statistics.median(ms))
            log(f"{mid}: language {m} at {secs} s: {ok}/{total} ({res[f'lid_{m}_{secs}s_ms']} ms)")

    res["peak_rss_mb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
    if device == "cuda":
        res["vram_mb"] = vram_mb()
    return res


def table(files):
    allruns = [json.load(open(f)) for f in files]
    runs = [r for r in allruns if r.get("kind") != "tidy"]
    tidies = [r for r in allruns if r.get("kind") == "tidy"]
    cols = [
        ("model", "Model"), ("device", "Device"), ("wer_en", "WER en"), ("wer_nl", "WER nl"),
        ("live_wer_en", "live WER en"), ("live_wer_nl", "live WER nl"), ("punct_nl", "punct. nl"),
        ("decode_5s_ms", "5 s ms"), ("decode_10s_ms", "10 s ms"), ("decode_20s_ms", "20 s ms"),
        ("cpu_10s_pct", "CPU % (10 s)"), ("gpu_10s_pct", "iGPU busy % (10 s)"),
        ("first_word_en_s", "first word en s"), ("first_word_nl_s", "first word nl s"), ("final_nl_s", "final nl s"),
        ("revised_words_nl", "revised words nl"), ("final_en_s", "final en s"), ("peak_rss_mb", "RSS MB"), ("vram_mb", "VRAM MB"),
        ("load_first_s", "load s"), ("load_again_s", "reload s"),
    ]
    out = ["| " + " | ".join(c[1] for c in cols) + " |", "|" + "---|" * len(cols)]
    for r in runs:
        out.append("| " + " | ".join("" if r.get(k) is None else str(r.get(k)) for k, _ in cols) + " |")
    lid = sorted({k for r in runs for k in r if k.startswith("lid_") and not k.endswith("_ms")})
    if lid:
        out += ["", "| Model | " + " | ".join(k[4:] for k in lid) + " |", "|---|" + "---|" * len(lid)]
        for r in runs:
            out.append("| " + r["model"] + " | " + " | ".join(
                (f"{r[k]} ({r.get(k + '_ms')} ms)" if k in r else "") for k in lid) + " |")
    if tidies:
        out += ["", "| Tidy model | Device | exact | refused | harm | median ms | p90 ms | load s | RSS MB | VRAM MB |",
                "|---|---|---|---|---|---|---|---|---|---|"]
        for r in tidies:
            out.append(f"| {r['model']} | {r['device']} | {r['exact']}/{r['cases']} | {r['refused']} | {r['harm']} | {r['ms_median']} | "
                       f"{r['ms_p90']} | {r['load_s']} | {r['peak_rss_mb']} | {r.get('vram_mb') or ''} |")
    return "\n".join(out)


def main(argv):
    if len(argv) >= 2 and argv[0] == "model":
        mid = argv[1]
        dev = (argv[argv.index("--device") + 1] if "--device" in argv else "igpu").lower()
        n = int(argv[argv.index("--clips") + 1]) if "--clips" in argv else 30
        res = bench_model(mid, dev, n)
        s = json.dumps(res, indent=1, ensure_ascii=False)
        if "--out" in argv:
            Path(argv[argv.index("--out") + 1]).write_text(s + "\n", encoding="utf-8")
        print(s)
        return 0
    if len(argv) >= 2 and argv[0] == "tidy":
        dev = argv[argv.index("--device") + 1] if "--device" in argv else "cpu"
        res = bench_tidy(argv[1], dev)
        s = json.dumps(res, indent=1, ensure_ascii=False)
        if "--out" in argv:
            Path(argv[argv.index("--out") + 1]).write_text(s + "\n", encoding="utf-8")
        print(s)
        return 0
    if len(argv) >= 2 and argv[0] == "table":
        print(table(argv[1:]))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
