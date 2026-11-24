"""The GPU guard: a batch NEVER spills VRAM into system RAM, and never runs on somebody else's model.

    guard(model, ollama_url) -> {ok, reason, freeMiB, others, ...}     BEFORE a batch loads its model
    unload(model, ollama_url)                                          keep_alive 0, waits until gone
    nvidia_smi() -> {totalMiB, usedMiB, freeMiB} | None

The three-part rule (PLAN.md "Facts established"; `/api/ps size` under-reports what the card holds, so
size_vram == size alone is not enough):

  BEFORE the load
    * `/api/ps` shows no OTHER model resident  ->  else refuse, reason "gpu-busy", `others` names them
      (the user may be using their LLM; a second model on an 8 GiB card measures nothing and evicts
      theirs).
    * `nvidia-smi --query-gpu=memory.total,memory.used,memory.free` answers  ->  else "no-gpu" (the
      dGPU can be cardwire-blocked; nvidia-smi then fails or hangs).
  AFTER the load (a warm-up request with an empty prompt, which loads the model and generates nothing)
    * `/api/ps` entry for the model has size_vram == size  AND  nvidia-smi free >= headroom (256 MiB)
      ->  else "spill": the model is unloaded (keep_alive 0) and the guard refuses.
    * no other model appeared while it loaded  ->  else "gpu-busy" (and it is unloaded).

Ollama is spoken to through http.post_json / http.get (loopback, so `gap=0`); nvidia-smi through an argv
list with the secret-free environment (env.child_env). Nothing here touches the Jev key.

`api` and `nvidia` are injectable (an object with ps()/warmup()/unload(), a callable returning the
smi dict or None): the eval's --dry mode and the unit tests use them.
"""
from __future__ import annotations

import shutil
import subprocess
import time

from . import env, http

DEFAULT_URL = "http://127.0.0.1:11434"
HEADROOM_MIB = 256
NVIDIA_ARGS = ["--query-gpu=memory.total,memory.used,memory.free", "--format=csv,noheader,nounits"]
MiB = 1024 * 1024


def same_model(a, b):
    """Ollama names a model with its tag, and `:latest` is the implied one."""
    def norm(s):
        s = (s or "").strip()
        return s[:-7] if s.endswith(":latest") else s
    return norm(a) == norm(b)


class OllamaAPI:
    """The three calls the guard makes."""

    def __init__(self, url=DEFAULT_URL):
        self.url = url.rstrip("/")

    def ps(self):
        """[{name, size, size_vram}] of the resident models. Raises http.NetError when Ollama is down."""
        d = http.get(self.url + "/api/ps", gap=0, timeout=10)
        out = []
        for m in (d or {}).get("models") or ():
            out.append({"name": m.get("name") or m.get("model") or "?",
                        "size": int(m.get("size") or 0), "size_vram": int(m.get("size_vram") or 0)})
        return out

    def warmup(self, model, num_ctx=8192, keep_alive="5m"):
        """Load `model` (empty prompt: nothing is generated) at the context the batch will use."""
        return http.post_json(self.url + "/api/generate",
                              {"model": model, "prompt": "", "stream": False, "keep_alive": keep_alive,
                               "options": {"num_ctx": num_ctx}}, timeout=600)

    def unload(self, model):
        return http.post_json(self.url + "/api/generate",
                              {"model": model, "prompt": "", "stream": False, "keep_alive": 0}, timeout=120)


def nvidia_smi(timeout=10):
    """{totalMiB, usedMiB, freeMiB} of the first NVIDIA GPU, or None when nvidia-smi is missing, fails,
    hangs or prints something else (a cardwire-blocked dGPU)."""
    exe = shutil.which("nvidia-smi")
    if not exe:
        return None
    try:
        r = subprocess.run([exe] + NVIDIA_ARGS, capture_output=True, text=True, timeout=timeout,
                           env=env.child_env(), stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    for line in r.stdout.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) >= 3:
            try:
                total, used, free = (int(float(p)) for p in parts[:3])
            except ValueError:
                return None
            return {"totalMiB": total, "usedMiB": used, "freeMiB": free}
    return None


def unload(model, ollama_url=DEFAULT_URL, *, api=None, wait_s=30.0):
    """Unload `model` (keep_alive 0) and wait until /api/ps no longer lists it. True when it is gone."""
    api = api or OllamaAPI(ollama_url)
    try:
        api.unload(model)
    except http.NetError:
        return False
    deadline = time.monotonic() + wait_s
    while True:
        try:
            if not any(same_model(m["name"], model) for m in api.ps()):
                return True
        except http.NetError:
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.25)


def _result(ok, reason, model, **kw):
    r = {"ok": ok, "reason": reason, "model": model, "freeMiB": None, "others": [], "sizeMiB": None,
         "vramMiB": None, "usedMiB": None, "usedBeforeMiB": None, "totalMiB": None, "loadMs": None,
         "detail": ""}
    r.update(kw)
    return r


def guard(model, ollama_url=DEFAULT_URL, *, num_ctx=8192, headroom_mib=HEADROOM_MIB, api=None,
          nvidia=None):
    """Load `model` for a batch, or refuse. See the module docstring. The model is left LOADED and
    resident when ok (the caller unloads it at the end of the batch); on any refusal after the load it
    has been unloaded."""
    api = api or OllamaAPI(ollama_url)
    nvidia = nvidia or nvidia_smi

    try:
        resident = api.ps()
    except http.NetError as e:
        return _result(False, "ollama-down", model, detail=str(e))
    others = [m["name"] for m in resident if not same_model(m["name"], model)]
    if others:
        return _result(False, "gpu-busy", model, others=others, detail="resident: " + ", ".join(others))

    before = nvidia()
    if before is None:
        return _result(False, "no-gpu", model, detail="nvidia-smi is missing or does not answer")

    t0 = time.monotonic()
    try:
        api.warmup(model, num_ctx)
    except http.NetError as e:
        unload(model, ollama_url, api=api, wait_s=5)
        return _result(False, "load-failed", model, usedBeforeMiB=before["usedMiB"], detail=str(e))
    load_ms = (time.monotonic() - t0) * 1000.0

    try:
        resident = api.ps()
    except http.NetError as e:
        return _result(False, "ollama-down", model, detail=str(e))
    others = [m["name"] for m in resident if not same_model(m["name"], model)]
    entry = next((m for m in resident if same_model(m["name"], model)), None)
    after = nvidia()
    info = {"usedBeforeMiB": before["usedMiB"], "loadMs": round(load_ms),
            "freeMiB": after["freeMiB"] if after else None,
            "usedMiB": after["usedMiB"] if after else None,
            "totalMiB": after["totalMiB"] if after else before["totalMiB"],
            "others": others}
    if entry is not None:
        info["sizeMiB"] = round(entry["size"] / MiB)
        info["vramMiB"] = round(entry["size_vram"] / MiB)

    if others:
        unload(model, ollama_url, api=api)
        return _result(False, "gpu-busy", model, detail="another model appeared while loading", **info)
    if entry is None:
        return _result(False, "load-failed", model, detail="the model is not in /api/ps after the warm-up",
                       **info)
    if entry["size_vram"] < entry["size"]:
        unload(model, ollama_url, api=api)
        return _result(False, "spill", model,
                       detail="size_vram %d MiB < size %d MiB: part of the model is in system RAM"
                              % (info["vramMiB"], info["sizeMiB"]), **info)
    if after is None:
        unload(model, ollama_url, api=api)
        return _result(False, "no-gpu", model, detail="nvidia-smi stopped answering after the load", **info)
    if after["freeMiB"] < headroom_mib:
        unload(model, ollama_url, api=api)
        return _result(False, "spill", model,
                       detail="nvidia-smi free %d MiB < %d MiB headroom" % (after["freeMiB"], headroom_mib),
                       **info)
    return _result(True, "ok", model, **info)
