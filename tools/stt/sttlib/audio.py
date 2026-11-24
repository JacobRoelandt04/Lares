"""Audio in: pw-record on a source (the helper) or a WAV file (the bench and the tests).

PwRecord runs `pw-record --raw` (16 kHz mono s16 to stdout) under PR_SET_PDEATHSIG, so the capture dies with the helper however the
helper dies; a reader thread collects the bytes, and `read()` hands over what arrived since the last call as float32. The stream is
named `lares-dictation` (media.name Dictation): the shell's mixer lists can filter it like the peak monitor.

THE CAPTURE STARTS FIRST (round 5): the helper starts PwRecord before anything heavy is imported, so this module imports nothing
but the standard library -- the reader keeps raw bytes, and numpy is first read by `read()`, once the helper has loaded it anyway.
`first_at` is the monotonic time the first bytes came (None until then).

THE WINDOW TAKE (round 5, fn+Ctrl+F10): `PwRecord(window=True)` records STEREO with `node.autoconnect = false` and no target, node
`lares-dictation-window` -- nothing links it but the take's own StreamWatch (sttlib/sources.py), which links the focused window's
output streams into it -- and `read()` averages the two channels into the mono the model hears (an average, not a sum: a loud stereo
stream does not clip). `pid` is the pw-record's own: the StreamWatch finds its node by it.
"""
import ctypes
import signal
import subprocess
import threading
import time

RATE = 16000
NODE_NAME = "lares-dictation"
WINDOW_NODE_NAME = "lares-dictation-window"


def _pdeathsig():
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    libc.prctl(1, signal.SIGTERM)       # PR_SET_PDEATHSIG


class PwRecord:
    def __init__(self, target: str = "", latency_ms: int = 32, window: bool = False):
        self.channels = 2 if window else 1
        props = ("{ node.name = %s media.name = \"Dictation (window)\" node.description = \"Dictation (window)\" node.autoconnect = false }"
                 % WINDOW_NODE_NAME) if window else "{ node.name = %s media.name = Dictation node.description = Dictation }" % NODE_NAME
        cmd = ["pw-record", "--raw", "--rate", str(RATE), "--channels", str(self.channels), "--format", "s16", "--latency",
               f"{latency_ms}ms", "-P", props]
        if window:
            cmd += ["--target", "0"]          # never linked by the session manager: the take's StreamWatch links it
        elif target:
            cmd += ["--target", target]
        cmd.append("-")
        self._p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                   preexec_fn=_pdeathsig)
        self.pid = self._p.pid
        self._lock = threading.Lock()
        self._chunks = []
        self._carry = b""
        self.samples = 0
        self.first_at = None
        self.error = ""
        self._t = threading.Thread(target=self._reader, daemon=True)
        self._t.start()
        self._e = threading.Thread(target=self._errreader, daemon=True)
        self._e.start()

    def _reader(self):
        out = self._p.stdout
        while True:
            b = out.read1(4096) if hasattr(out, "read1") else out.read(4096)
            if not b:
                break
            b = self._carry + b
            n = len(b) // (2 * self.channels) * (2 * self.channels)       # whole frames only
            self._carry = b[n:]
            if not n:
                continue
            with self._lock:
                if self.first_at is None:
                    self.first_at = time.monotonic()
                self._chunks.append(b[:n])
                self.samples += n // (2 * self.channels)

    def _errreader(self):
        for line in self._p.stderr:
            self.error = line.decode("utf-8", "replace").strip()

    def read(self):
        """What arrived since the last call, float32 mono in [-1, 1] (a numpy array; numpy is imported here, not above)."""
        import numpy as np

        with self._lock:
            chunks, self._chunks = self._chunks, []
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        a = np.frombuffer(b"".join(chunks), dtype="<i2").astype(np.float32) / 32768.0
        if self.channels > 1:
            a = a.reshape(-1, self.channels).mean(axis=1)
        return a

    @property
    def alive(self) -> bool:
        return self._p.poll() is None

    def close(self):
        """Ends the capture; what it had already sent stays readable (the reader is joined, so nothing is still on its way)."""
        if self._p.poll() is None:
            self._p.terminate()
            try:
                self._p.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self._p.kill()
        self._t.join(timeout=1)


def read_wav(path):
    """A sound file as float32 mono 16 kHz (FLEURS ships 32-bit float WAV, which the wave module cannot read)."""
    import numpy as np
    import soundfile

    a, rate = soundfile.read(str(path), dtype="float32", always_2d=True)
    a = a.mean(axis=1).astype(np.float32)
    if rate != RATE:
        # linear resampling is enough for a test clip (FLEURS is 16 kHz already)
        n = int(round(a.size * RATE / rate))
        a = np.interp(np.linspace(0, a.size - 1, n), np.arange(a.size), a).astype(np.float32)
    return a
