"""A decoder that survives its device (round 8, the user's take of 2026-11-13: the iGPU's OpenVINO raised `[GPU] clWaitForEvents, error
code: -14` in the middle of a take, the helper's main loop died with it, and the take ran into the stop timer with half a sentence
written).

`Guarded(inner, ...)` stands for a decoder of a model (it has the same `decode` / `scored` / `id` / `device` / `forceable` /
`autolang`). While the inner one runs on a GPU (OpenVINO's iGPU, onnxruntime's CUDA) and an inference raises, the guard says so
(`fallback`, with the cause in plain words), loads the model on the CPU, and runs the SAME audio again through it: the policy that
called `decode` for the open sentence gets its words, and the take goes on -- nothing the user said is lost, because the engine
decodes from the buffer of the whole utterance. What it falls back to stays for the helper's life (the GPU is tried again at the
next helper start: the shell restarts the helper at rest). A decoder already on the CPU that raises, or a CPU one that raises after
the fallback, is no device fault: the exception goes up (the helper ends the take with a stated reason).

    plain_cause(exc, device) -> (words, detail)    "the iGPU stopped responding" / "the NVIDIA card ran out of memory" / ...
"""
import re

_OOM = re.compile(r"out of memory|memory allocation|bad_alloc|CUDA_ERROR_OUT_OF_MEMORY|cudaErrorMemoryAllocation|CL_OUT_OF_RESOURCES"
                  r"|CL_MEM_OBJECT_ALLOCATION_FAILURE|ENOMEM", re.I)
_HANG = re.compile(r"clWaitForEvents|CL_EXEC_STATUS_ERROR|device lost|GPU hang|context reset|unspecified launch failure|"
                   r"cudaErrorLaunchTimeout|launch timed out|CUDA_ERROR_LAUNCH|an illegal memory access|ECC", re.I)


def is_gpu(device):
    d = str(device or "")
    return "GPU" in d or "CUDA" in d


def plain_cause(exc, device):
    """(words for a toast, the exception's own first lines): what a person can read, and what to keep in the log."""
    msg = " ".join(str(exc).split())
    detail = (type(exc).__name__ + ": " + msg)[:240]
    dev = "NVIDIA card" if "CUDA" in str(device) else "iGPU"
    if _OOM.search(msg):
        return "the %s ran out of memory" % dev, detail
    if _HANG.search(msg):
        return "the %s stopped responding" % dev, detail
    return "the %s failed (%s)" % (dev, msg[:80] or type(exc).__name__), detail


class Guarded:
    """See the module docstring. `say(ev)`: where the `fallback` event goes (the helper adds the take); `load_cpu()`: the model on
    the CPU, called once, on the thread that met the error; `note(why)`: tells the helper the GPU is out for its life."""

    def __init__(self, inner, say, load_cpu, note=None):
        self._d = inner
        self._say, self._load_cpu, self._note = say, load_cpu, note
        self.id = inner.id
        self.forceable, self.autolang = inner.forceable, inner.autolang
        self.fell = ""                    # why it fell to the CPU ("" while it runs where it was made)
        self.faults = 0

    @property
    def device(self):
        return self._d.device

    def __getattr__(self, name):          # anything else the inner decoder has (the bench's, a stub's)
        return getattr(self._d, name)

    def decode(self, audio, lang):
        return self._call("decode", audio, lang)

    def scored(self, audio, lang):
        return self._call("scored", audio, lang)

    def _call(self, name, audio, lang):
        try:
            return getattr(self._d, name)(audio, lang)
        except Exception as e:  # noqa: BLE001 -- only a GPU's fault is recovered; anything else goes up
            if not is_gpu(self._d.device):
                raise
            self._fall(e)
        return getattr(self._d, name)(audio, lang)

    def _fall(self, exc):
        dev = self._d.device
        why, detail = plain_cause(exc, dev)
        self.faults += 1
        # said BEFORE the load: the shell tells the user at once, and the CPU model takes seconds
        self._say({"ev": "fallback", "from": dev, "to": "CPU", "why": why, "detail": detail, "model": self.id})
        if self._note is not None:
            self._note(why)
        self._d = self._load_cpu()        # a load that fails raises: the device's decoder stays, and the helper ends the take
        self.fell = why
