#!/usr/bin/env python3
"""Fetch the dictation models (and, for the bench, public speech clips) into the private cache.

Everything lands under ~/.cache/lares-stt (override: LARES_STT_HOME): models/<id>/ and clips/<lang>/. Run with the private
venv's interpreter (~/.local/share/lares/stt/venv/bin/python); nothing here needs root or touches the system.

    fetch.py pick                  everything the helper's `auto` may use (lares_stt.py PICK): the live and final models (Parakeet's
                                   fp32 encoder serves the iGPU and the NVIDIA card alike) and the tidy pass's model (`tidy`)
    fetch.py tidy [<id> ...]       the tidy pass's model (sttlib/tidy.py TIDY_PICK, or the ids named: TIDY_MODELS)
    fetch.py models [<id> ...]     the shortlisted models (default: every id in MODELS)
    fetch.py clips [--n 30]        FLEURS test clips, en_us and nl_nl (CC-BY-4.0), 6-20 s each
    fetch.py remove <id> ...       delete a model directory (the bench's losers)
    fetch.py list                  what is there, with sizes

Every step prints `ok <what>` or `FAIL <what>: <reason>`; the exit status is the number of FAILs.
"""
import csv
import os
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

HOME = Path(os.environ.get("LARES_STT_HOME", Path.home() / ".cache" / "lares-stt"))
MODELS_DIR = HOME / "models"
CLIPS_DIR = HOME / "clips"
os.environ.setdefault("HF_HOME", str(HOME / "hf"))

# id -> (kind, onnx_asr name, extra files of its repo). The int8 export always (the CPU path); `extra` for the iGPU path.
MODELS = {
    "canary-1b-v2": ("onnx-asr", "nemo-canary-1b-v2", None),
    # + the fp32 encoder (2.4 GB): the iGPU runs it at f16 (the int8 one decodes to garbage there)
    "parakeet-tdt-0.6b-v3": ("onnx-asr", "nemo-parakeet-tdt-0.6b-v3", ["encoder-model.onnx", "encoder-model.onnx.data"]),
    "silero-vad": ("onnx-asr-vad", "silero", None),
}

FLEURS = {"en": "en_us", "nl": "nl_nl"}

# onnx_asr loads what it fetched, and with no providers named it asks for every one onnxruntime-gpu has (TensorRT, CUDA, CPU):
# with the NVIDIA card off the bus (Integrated mode) the CUDA session RAISES ("CUDA failure 100: no CUDA-capable device") and
# a model that is all there reads FAIL. The load only proves the files; the helper picks the device per take (decoders.py).
CHECK_PROVIDERS = ["CPUExecutionProvider"]

fails = 0


def say(ok, what, why=""):
    global fails
    if ok:
        print(f"ok {what}", flush=True)
    else:
        fails += 1
        print(f"FAIL {what}: {why}", flush=True)


def du(p: Path) -> int:
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file()) if p.exists() else 0


def fetch_model(mid: str):
    kind, src, extra = MODELS[mid]
    dest = MODELS_DIR / mid
    try:
        if kind == "onnx-asr":
            import onnx_asr

            onnx_asr.load_model(src, path=dest, quantization="int8", providers=CHECK_PROVIDERS)
            if extra:
                from huggingface_hub import hf_hub_download
                from onnx_asr.resolver import model_repos

                for f in extra:
                    hf_hub_download(model_repos[src], f, local_dir=dest)
        elif kind == "onnx-asr-vad":
            import onnx_asr

            onnx_asr.load_vad(src, path=dest, providers=CHECK_PROVIDERS)
        say(True, f"model {mid} ({du(dest) / 1e9:.2f} GB)")
    except Exception as e:  # noqa: BLE001 -- every failure is a stated FAIL line
        say(False, f"model {mid}", repr(e))


def fetch_tidy(tid: str):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from sttlib.tidy import TIDY_MODELS

    if tid not in TIDY_MODELS:
        say(False, f"tidy {tid}", "unknown id")
        return
    spec = TIDY_MODELS[tid]
    dest = MODELS_DIR / tid
    try:
        from huggingface_hub import hf_hub_download

        for f in spec["files"]:
            hf_hub_download(spec["repo"], f, revision=spec["rev"], local_dir=dest)
        say(True, f"tidy {tid} ({du(dest) / 1e9:.2f} GB)")
    except Exception as e:  # noqa: BLE001
        say(False, f"tidy {tid}", repr(e))


def fetch_clips(n: int):
    from huggingface_hub import hf_hub_download

    for lang, code in FLEURS.items():
        dest = CLIPS_DIR / lang
        try:
            if (dest / "refs.tsv").exists() and len(list(dest.glob("*.wav"))) >= n:
                say(True, f"clips {lang} (present)")
                continue
            dest.mkdir(parents=True, exist_ok=True)
            tsv = hf_hub_download("google/fleurs", f"data/{code}/test.tsv", repo_type="dataset")
            rows = []
            with open(tsv, encoding="utf-8") as f:
                for r in csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
                    # id, file, raw transcription, normalised transcription, phonemes, samples, gender
                    if len(r) < 6:
                        continue
                    secs = int(r[5]) / 16000
                    if 6.0 <= secs <= 20.0:
                        rows.append((r[1], r[2], r[3], secs))
            # FLEURS repeats each sentence for several speakers: one recording per sentence, spread evenly over the set.
            seen, uniq = set(), []
            for row in sorted(rows):
                if row[2] not in seen:
                    seen.add(row[2])
                    uniq.append(row)
            step = max(1, len(uniq) // n)
            pick = uniq[::step][:n]
            want = {p[0] for p in pick}
            arc = hf_hub_download("google/fleurs", f"data/{code}/audio/test.tar.gz", repo_type="dataset")
            with tempfile.TemporaryDirectory(dir=HOME) as tmp:
                with tarfile.open(arc) as t:
                    members = [m for m in t.getmembers() if Path(m.name).name in want and m.isfile()]
                    t.extractall(tmp, members=members, filter="data")
                for m in members:
                    shutil.move(str(Path(tmp) / m.name), dest / Path(m.name).name)
            with open(dest / "refs.tsv", "w", encoding="utf-8") as f:
                for file, raw, norm, secs in pick:
                    f.write(f"{file}\t{secs:.2f}\t{raw}\t{norm}\n")
            # The archive in the HF cache is 159 / 290 MB: the picked clips are all the bench needs.
            blob = Path(arc).resolve()
            Path(arc).unlink(missing_ok=True)
            blob.unlink(missing_ok=True)
            say(True, f"clips {lang} ({len(pick)} clips, {sum(p[3] for p in pick):.0f} s)")
        except Exception as e:  # noqa: BLE001
            say(False, f"clips {lang}", repr(e))


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    HOME.mkdir(parents=True, exist_ok=True)
    cmd, rest = argv[0], argv[1:]
    if cmd == "pick":
        sys.path.insert(0, str(Path(__file__).resolve().parent))

        from lares_stt import PICK
        from sttlib.tidy import TIDY_PICK

        want = ["silero-vad"] + sorted({m for spec in PICK.values() for m in [spec["live"], *spec["final"].values()]})
        for mid in want:
            fetch_model(mid)
        fetch_tidy(TIDY_PICK)
    elif cmd == "tidy":
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from sttlib.tidy import TIDY_PICK

        for tid in rest or [TIDY_PICK]:
            fetch_tidy(tid)
    elif cmd == "models":
        for mid in rest or list(MODELS):
            if mid not in MODELS:
                say(False, f"model {mid}", "unknown id")
                continue
            fetch_model(mid)
    elif cmd == "clips":
        n = int(rest[rest.index("--n") + 1]) if "--n" in rest else 30
        fetch_clips(n)
    elif cmd == "remove":
        for mid in rest:
            p = MODELS_DIR / mid
            if p.exists():
                shutil.rmtree(p)
            say(True, f"removed {mid}")
    elif cmd == "list":
        for p in sorted(MODELS_DIR.glob("*")):
            print(f"{p.name}\t{du(p) / 1e9:.2f} GB")
        for p in sorted(CLIPS_DIR.glob("*")):
            print(f"clips/{p.name}\t{len(list(p.glob('*.wav')))} wav\t{du(p) / 1e6:.0f} MB")
        print(f"total\t{du(HOME) / 1e9:.2f} GB")
    else:
        print(__doc__)
        return 100
    return fails


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
