"""The dictation helper's library: audio capture, the VAD, the decoders, the language test and the revision policy.

lares_stt.py (the helper the shell runs) and bench.py (the bench) are its two users; both drive one `Engine` (policy.py), the helper on
the wall clock with audio from pw-record, the bench on a simulated clock with audio from a file.
"""
