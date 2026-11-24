"""Streaming Silero VAD (the onnx-asr copy of silero_vad.onnx): one probability per 32 ms frame of 16 kHz audio.

The model wants each 512-sample frame with the 64 samples before it as context and carries a (2, 1, 128) state from frame to frame
(the same call onnx-asr's SileroVad makes over a whole file, here one frame at a time as audio arrives).
"""
from pathlib import Path

import numpy as np

RATE = 16000
HOP = 512          # 32 ms
CONTEXT = 64


class StreamingVad:
    def __init__(self, model_dir: Path, threads: int = 1):
        import onnxruntime as rt

        so = rt.SessionOptions()
        so.intra_op_num_threads = threads
        so.inter_op_num_threads = 1
        path = Path(model_dir) / "silero_vad.onnx"
        self._sess = rt.InferenceSession(str(path), sess_options=so, providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self):
        self._state = np.zeros((2, 1, 128), dtype=np.float32)
        self._ctx = np.zeros(CONTEXT, dtype=np.float32)
        self._pending = np.zeros(0, dtype=np.float32)
        self.frames = 0

    def feed(self, samples: np.ndarray) -> list:
        """Feed float32 samples; returns one probability per completed frame."""
        if samples.size:
            self._pending = np.concatenate((self._pending, samples.astype(np.float32, copy=False)))
        out = []
        sr = np.array(RATE, dtype=np.int64)
        while self._pending.size >= HOP:
            frame = self._pending[:HOP]
            self._pending = self._pending[HOP:]
            x = np.concatenate((self._ctx, frame))[None, :]
            prob, self._state = self._sess.run(["output", "stateN"], {"input": x, "state": self._state, "sr": sr})
            self._ctx = frame[-CONTEXT:]
            out.append(float(prob[0, 0]))
            self.frames += 1
        return out
