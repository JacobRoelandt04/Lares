"""The decoders: one class per runtime, one registry entry per model.

    decode(audio, lang) -> text      audio: float32 mono 16 kHz in [-1, 1]; lang: "en" | "nl" | None (the model decides)

`forceable`: the language can be given (Canary must be told: it has no detection). `autolang`: given no language, the model
transcribes in the one it hears (Parakeet always, and it cannot be told).

THE DEVICE (research section 11.5), chosen per take from one cheap fact read at the take's start (`dgpu_fact`): the NVIDIA card is on
the PCI bus with its driver bound -- Hybrid or Smart; in Integrated mode cardwire takes it off the bus. A sysfs read (~1 ms) that
opens no device node and wakes nothing; CUDA is never tried to find out (a CUDA start on a missing card costs ~2.6 s to fail).
On the card the take may wake it, on AC and on battery (the user's answer): CUDA there, else the Arc iGPU (OpenVINO), else the CPU.
A CUDA load that fails anyway (a Smart-mode policy that blocks the helper) falls back to the iGPU for that take, and says why.

THE LOAD (round 5). On the card and on the iGPU only the fp32 encoder runs, so the int8 encoder onnx-asr would also build (652 MB,
thrown away at once) is never made (`_no_int8_encoder`). OpenVINO's device list is read once per process (`ov_devices`: ~0.2 s warm,
~2.5 s cold, and it was asked on every resolve).

THE SCRIPT MASK (round 5). Parakeet cannot be told the language, and now and then writes English speech in Cyrillic ("Эндэ мочул."
for "in the module"). A take is English or Dutch, so in an en / nl decode every vocabulary token holding a letter outside the
Latin script (Cyrillic, Greek: 1720 of Parakeet's 8193) is masked out of the TDT greedy decode's joint logits (`_latin_tokens`): the
model writes the likeliest Latin token instead. A decode given no language (the bench's, the language test's) is not masked.
"""
import os
import unicodedata
from pathlib import Path

import numpy as np

HOME = Path(os.environ.get("LARES_STT_HOME", Path.home() / ".cache" / "lares-stt"))
MODELS_DIR = HOME / "models"

# `cuda`: how the model runs on the card -- "encoder-fp32" (the fp32 encoder on CUDA, the int8 decoding loop on the CPU: a
# transducer's loop is hundreds of tiny calls, cheaper on the CPU than as kernel launches). `cudaFiles`: what that needs. A model
# with no `cuda` runs on the card's takes as on the iGPU's. Canary has none: its fp16 export (ysdede's port) decoded Dutch at
# 24.5 % WER on CUDA against Parakeet's 8.0, and alone ran out of the card's 8 GB (dGPU bench, 2026-11-08, research 11.5).
MODELS = {
    "canary-1b-v2": {"kind": "onnx-asr", "name": "nemo-canary-1b-v2", "forceable": True, "autolang": False,
                     },
    "parakeet-tdt-0.6b-v3": {"kind": "onnx-asr", "name": "nemo-parakeet-tdt-0.6b-v3", "forceable": False, "autolang": True,
                             "cuda": "encoder-fp32", "cudaFiles": ["encoder-model.onnx", "encoder-model.onnx.data"],
                             "latinMask": True},
}
# THE SCRIPT MASK's languages: a decode told one of these writes Latin letters only (LARES_STT_SCRIPT_MASK=0 turns it off: the bench's
# before / after)
LATIN_LANGS = ("en", "nl")
SCRIPT_MASK = os.environ.get("LARES_STT_SCRIPT_MASK", "1") != "0"
# the probe's stand-in decoder (sttlib/stubs.py), never there unless LARES_STT_STUBS=1
STUBS = os.environ.get("LARES_STT_STUBS") == "1"
if STUBS:
    MODELS["stub-speaker"] = {"kind": "stub", "forceable": False, "autolang": True}
PCI_ROOT = Path(os.environ.get("LARES_STT_PCI_ROOT", "/sys/bus/pci/devices"))
CUDA_OPTIONS = {"device_id": 0, "cudnn_conv_algo_search": "HEURISTIC", "arena_extend_strategy": "kSameAsRequested"}


def present():
    """The registry's models whose files are on disk (and the probe's stand-in when it is registered)."""
    return [m for m in MODELS if MODELS[m]["kind"] == "stub" or ((MODELS_DIR / m).is_dir() and any((MODELS_DIR / m).iterdir()))]


_OV = None


def ov_devices():
    """OpenVINO's devices, read once per process (an `ov.Core()` enumerates the GPU plugin: ~0.2 s warm, ~2.5 s cold)."""
    global _OV
    if _OV is None:
        try:
            import openvino as ov

            _OV = list(ov.Core().available_devices)
        except Exception:  # noqa: BLE001 -- no OpenVINO is "no OpenVINO devices"
            _OV = []
    return list(_OV)


def dgpu_fact() -> dict:
    """The NVIDIA card as a take sees it, from sysfs alone: {"present", "pci", "driver", "why"}. `vendor`, `class` and the `driver`
    link are the kernel's own copies (no config-space read), so a card asleep in D3cold stays asleep. LARES_STT_PCI_ROOT points a probe
    at a fake tree."""
    try:
        devs = sorted(PCI_ROOT.iterdir())
    except OSError as e:
        return {"present": False, "pci": "", "driver": "", "why": "no PCI tree: " + str(e)}
    for d in devs:
        try:
            if (d / "vendor").read_text().strip() != "0x10de" or not (d / "class").read_text().strip().startswith("0x03"):
                continue
        except OSError:
            continue
        drv = os.path.basename(os.readlink(d / "driver")) if (d / "driver").is_symlink() else ""
        ok = drv == "nvidia"
        return {"present": ok, "pci": d.name, "driver": drv, "why": "" if ok else "the card has driver '%s', not nvidia" % drv}
    return {"present": False, "pci": "", "driver": "", "why": "the NVIDIA card is not on the PCI bus (Integrated mode)"}


_CUDA = None


def cuda_runtime() -> str:
    """"" when onnxruntime's CUDA provider can be asked for (the onnxruntime-gpu build, cuDNN preloaded from the venv), else why
    not. Asks no device: the card is only touched when a session is made on it."""
    global _CUDA
    if _CUDA is None:
        try:
            import onnxruntime as rt

            if "CUDAExecutionProvider" not in rt.get_available_providers():
                _CUDA = "onnxruntime has no CUDA provider (tools/stt/setup.sh installs onnxruntime-gpu)"
            else:
                rt.preload_dlls(cuda=False, cudnn=True)     # cuDNN from the venv; CUDA's own libraries are the system's
                _CUDA = ""
        except Exception as e:  # noqa: BLE001
            _CUDA = "onnxruntime: " + str(e)[:160]
    return _CUDA


_CUDA_OK = None


def _cuda_devices() -> str:
    """"" when the CUDA runtime counts a device, else its own words for why not (onnxruntime would only print them and carry on
    on the CPU): "no CUDA-capable device is detected" in Integrated mode, a refusal when a Smart-mode policy blocks the helper."""
    import ctypes

    try:
        lib = ctypes.CDLL("libcudart.so.13")
        n = ctypes.c_int(0)
        err = lib.cudaGetDeviceCount(ctypes.byref(n))
        if err:
            lib.cudaGetErrorString.restype = ctypes.c_char_p
            return "CUDA: " + lib.cudaGetErrorString(err).decode()
        return "" if n.value > 0 else "CUDA: no device"
    except OSError as e:
        return "CUDA runtime: " + str(e)[:120]


def cuda_check():
    """The card answers CUDA: a 2 MB session (the VAD) on the CUDA provider alone, once per process. Raises with the reason when
    it does not -- before any big model is read, which onnxruntime would otherwise quietly build on the CPU instead (~2.6 s to
    learn it on a missing card, measured)."""
    global _CUDA_OK
    if _CUDA_OK is None:
        why = cuda_runtime() or _cuda_devices()
        if not why:
            try:
                import onnxruntime as rt

                s = rt.InferenceSession(str(MODELS_DIR / "silero-vad" / "silero_vad.onnx"),
                                        providers=[("CUDAExecutionProvider", CUDA_OPTIONS)])
                if s.get_providers()[0] != "CUDAExecutionProvider":
                    why = "the CUDA provider did not start"
            except Exception as e:  # noqa: BLE001
                why = str(e).strip().splitlines()[0][:200] if str(e).strip() else repr(e)
        _CUDA_OK = why
    if _CUDA_OK:
        raise RuntimeError(_CUDA_OK)


def cuda_files_ready(model: str) -> bool:
    spec = MODELS.get(model, {})
    return bool(spec.get("cudaFiles")) and all((MODELS_DIR / model / f).exists() for f in spec["cudaFiles"])


def device_class(want: str, fact: dict) -> tuple:
    """(class, why): "cuda" | "igpu" | "cpu" for a take, from the config's `device` and the card's fact. `auto` takes the card
    when it is there and CUDA can run; `cuda` asks for it (and is `auto` without it); `gpu` / `igpu` is the Arc iGPU; `cpu`."""
    want = (want or "auto").lower()
    if want == "cpu":
        return "cpu", "asked"
    if want in ("gpu", "igpu"):
        return "igpu", "asked"
    if not fact.get("present"):
        return "igpu", fact.get("why") or "no card"
    why = cuda_runtime()
    if why:
        return "igpu", why
    return "cuda", "the card is on the bus"


def gpu_encoder_ready(model: str) -> bool:
    """An ONNX model's encoder can run on the iGPU: OpenVINO sees one and the fp32 export is on disk (fetch.py fetches it)."""
    return (MODELS_DIR / model / "encoder-model.onnx.data").exists() and "GPU" in ov_devices()


def resolve_device(model: str, cls: str) -> str:
    """Where a model runs for a take of device class `cls` (`device_class`): "CUDA" on the card when the model has its CUDA files;
    "GPU" (the Arc iGPU through OpenVINO, the encoder only) when the fp32 export is there; else "CPU". The decoding loop stays on
    onnxruntime's CPU provider (MODELS `cuda`). The NPU waits for its
    user-space driver (research section 4).
    """
    if cls == "cuda" and cuda_files_ready(model):
        return "CUDA"
    if cls in ("cuda", "igpu") and gpu_encoder_ready(model):
        return "GPU"
    return "CPU"


def threads_for(power: str) -> int:
    """CPU threads a decode may use: fewer on battery (section 8.10)."""
    n = os.cpu_count() or 4
    return min(4, n) if power == "battery" else min(8, n)


class OvEncoder:
    """An onnxruntime-shaped stand-in for an ONNX encoder compiled by OpenVINO on another device (the Arc iGPU): `run(names, feeds)`.

    The audio length is padded up to a whole bucket of feature frames (the encoders take the true `length` and mask the rest), so
    the device compiles one kernel set per bucket instead of one per utterance length; compiled models are cached on disk.
    """
    BUCKET = 100            # feature frames: 1 s of audio at the 10 ms hop

    def __init__(self, path, device, cache):
        import openvino as ov

        core = ov.Core()
        core.set_property({"CACHE_DIR": str(cache)})
        cfg = {"PERFORMANCE_HINT": "LATENCY"}
        if os.environ.get("LARES_STT_OV_PRECISION"):
            cfg["INFERENCE_PRECISION_HINT"] = os.environ["LARES_STT_OV_PRECISION"]
        self._m = core.compile_model(core.read_model(str(path)), device, cfg)
        self._req = self._m.create_infer_request()
        self._names = [o.get_any_name() for o in self._m.outputs]

    def run(self, names, feeds):
        feeds = dict(feeds)
        sig = feeds.get("audio_signal")
        if sig is not None:
            t = sig.shape[-1]
            pad = (-t) % self.BUCKET
            if pad:
                feeds["audio_signal"] = np.pad(sig, ((0, 0), (0, 0), (0, pad)))
        r = self._req.infer(feeds)
        out = {self._names[i]: v for i, v in enumerate(r.values())}
        return [out[n] for n in names]


class _NoEncoder:
    """Where onnx-asr would keep the int8 encoder on the card's and the iGPU's paths: never run (the fp32 one replaces it)."""

    def run(self, *a, **kw):
        raise RuntimeError("the int8 encoder was not loaded (the fp32 encoder runs this model)")


class _no_int8_encoder:
    """For one load: onnx-asr's NeMo models make their sessions through their module's `rt.InferenceSession`; inside this block an
    encoder file gets the stand-in above instead of a session, everything else a real one (only the loader thread loads)."""

    def __enter__(self):
        import onnx_asr.models.nemo as nemo

        self._nemo, real = nemo, nemo.rt

        class _Rt:
            def __getattr__(self, name):
                return getattr(real, name)

            @staticmethod
            def InferenceSession(path, *a, **kw):  # noqa: N802 -- onnxruntime's own name
                if Path(str(path)).name.startswith("encoder-model"):
                    return _NoEncoder()
                return real.InferenceSession(path, *a, **kw)

        self._real = real
        nemo.rt = _Rt()
        return self

    def __exit__(self, *exc):
        self._nemo.rt = self._real
        return False


def _latin_tokens(vocab: dict, size: int):
    """True for each token id that holds a letter of another script than Latin (THE SCRIPT MASK)."""
    import numpy as np

    mask = np.zeros(size, dtype=bool)
    for i, tok in vocab.items():
        if 0 <= i < size and any(unicodedata.category(c).startswith("L") and not unicodedata.name(c, "").startswith("LATIN")
                                 for c in tok if c not in " \u2581"):
            mask[i] = True
    return mask


def _on_cuda(sess, what):
    got = sess.get_providers()[0]
    if got != "CUDAExecutionProvider":
        # onnxruntime falls back to the CPU by itself, with a printed "EP Error": a fallback the take must know about
        raise RuntimeError("CUDA did not take the %s (it runs on %s)" % (what, got))


class OnnxAsrDecoder:
    def __init__(self, mid: str, threads: int, encoder_device: str = "CPU"):
        import onnx_asr
        import onnxruntime as rt

        spec = MODELS[mid]
        if encoder_device == "CUDA":
            cuda_check()
        so = rt.SessionOptions()
        # no thread spins while it waits (ORT's default spinning kept ~11 cores busy around a decode whose encoder ran on the iGPU);
        # the threads stay: Canary's decoding loop is most of its decode (~1.1 of 1.8 s for 10 s of speech) and wants them
        so.intra_op_num_threads = threads
        so.inter_op_num_threads = 1
        so.add_session_config_entry("session.intra_op.allow_spinning", "0")
        self.id, self.device = mid, "CPU"
        self.forceable, self.autolang = spec["forceable"], spec["autolang"]
        if encoder_device == "CPU":
            self._m = onnx_asr.load_model(spec["name"], path=MODELS_DIR / mid, quantization="int8", sess_options=so,
                                          providers=["CPUExecutionProvider"])
        else:
            with _no_int8_encoder():
                self._m = onnx_asr.load_model(spec["name"], path=MODELS_DIR / mid, quantization="int8", sess_options=so,
                                              providers=["CPUExecutionProvider"])
        self._mt = self._m.with_timestamps()
        # THE SCRIPT MASK (top of the file): the joint's token logits of a TDT decode, before its greedy argmax
        self._latin = False
        self.masked = 0
        asr = self._m.asr
        if spec.get("latinMask") and SCRIPT_MASK and hasattr(asr, "_vocab"):
            mask = _latin_tokens(asr._vocab, asr._vocab_size)
            self.masked = int(mask.sum())
            inner = asr._decode

            def _decode(prev_tokens, prev_state, encoder_out):
                logits, step, state = inner(prev_tokens, prev_state, encoder_out)
                if self._latin:
                    logits = np.where(mask[: logits.shape[-1]], np.float32(-1e30), logits)
                return logits, step, state

            asr._decode = _decode
        if encoder_device == "CUDA":
            # the fp32 encoder on the card, the int8 decoding loop on the CPU (MODELS `cuda`)
            enc = rt.InferenceSession(str(MODELS_DIR / mid / "encoder-model.onnx"), sess_options=so,
                                      providers=[("CUDAExecutionProvider", CUDA_OPTIONS), "CPUExecutionProvider"])
            _on_cuda(enc, "encoder")
            self._m.asr._encoder = enc
            self.device = "CUDA+CPU"
            self.decode(np.zeros(16000, np.float32), None)
        elif encoder_device != "CPU":
            # the encoder is the bulk of a decode: on the iGPU through OpenVINO; the decoding loop stays on onnxruntime's CPU
            # the fp32 export: the int8 one (dynamically quantised) decodes to garbage on the Arc iGPU at its default f16 precision
            # and is no faster than the CPU at f32 (bench, 2026-11-08)
            enc = MODELS_DIR / mid / "encoder-model.onnx"
            cache = HOME / "ov-cache" / mid / encoder_device
            cache.mkdir(parents=True, exist_ok=True)
            self._m.asr._encoder = OvEncoder(enc, encoder_device, cache)
            self.device = encoder_device + "+CPU"

    def decode(self, audio: np.ndarray, lang):
        if audio.size < 1600:            # under 0.1 s: nothing to say
            return ""
        kw = {"language": lang} if (self.forceable and lang) else {}
        self._latin = lang in LATIN_LANGS
        return str(self._m.recognize(audio.astype(np.float32, copy=False), sample_rate=16000, **kw)).strip()

    def scored(self, audio: np.ndarray, lang):
        """(text, mean token log-probability): the language test that forces each language and keeps the likelier."""
        kw = {"language": lang} if (self.forceable and lang) else {}
        self._latin = lang in LATIN_LANGS
        r = self._mt.recognize(audio.astype(np.float32, copy=False), sample_rate=16000, **kw)
        lp = list(r.logprobs or [])
        return r.text.strip(), (sum(lp) / len(lp) if lp else -99.0)


def load(mid: str, cls: str = "igpu", power: str = "ac"):
    """A decoder for a take of device class `cls` ("cuda" | "igpu" | "cpu"; the bench's old `auto` / `gpu` mean "igpu")."""
    if MODELS.get(mid, {}).get("kind") == "stub":
        from .stubs import STUBS as stubs

        # a probe's slow load (tools/dev/dictation_probe.sh L): the ms in the file LARES_STT_STUB_LOAD_FILE names, when it is there
        try:
            import time

            time.sleep(int(Path(os.environ.get("LARES_STT_STUB_LOAD_FILE", "")).read_text().strip() or 0) / 1000)
        except (OSError, ValueError):
            pass
        # round 8's probe: a GPU class whose decoder fails after N decodes (the file's number), to prove the CPU fallback
        try:
            n = int(Path(os.environ.get("LARES_STT_STUB_GPUFAIL_FILE", "")).read_text().strip())
        except (OSError, ValueError):
            n = -1
        if n >= 0 and (cls or "igpu").lower() in ("igpu", "gpu", "cuda", "auto"):
            from .stubs import StubGpu

            return StubGpu(n)
        return stubs[mid]()
    cls = {"auto": "igpu", "gpu": "igpu"}.get((cls or "igpu").lower(), (cls or "igpu").lower())
    return OnnxAsrDecoder(mid, threads_for(power), resolve_device(mid, cls))
