"""FLV muxing for one client: header, onMetaData, AVC / AAC sequence headers and frames. Pure functions."""
import struct


def header(video=True, audio=False):
    return b"FLV" + bytes([1, (1 if video else 0) | (4 if audio else 0)]) + struct.pack(">I", 9) + struct.pack(">I", 0)


def tag(kind, ts_ms, data):
    """kind 8 audio, 9 video, 18 script. ts_ms is clamped to 32 bits; the extension byte carries bits 24-31."""
    ts_ms &= 0xFFFFFFFF
    return (bytes([kind]) + struct.pack(">I", len(data))[1:] + struct.pack(">I", ts_ms & 0xFFFFFF)[1:] + bytes([ts_ms >> 24])
            + b"\0\0\0" + data + struct.pack(">I", 11 + len(data)))


def _amf_str(s):
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def metadata(width, height):
    props = [("width", float(width)), ("height", float(height)), ("videocodecid", 7.0)]
    d = b"\x02" + _amf_str("onMetaData") + b"\x08" + struct.pack(">I", len(props))
    for k, v in props:
        d += _amf_str(k) + b"\x00" + struct.pack(">d", v)
    return tag(18, 0, d + b"\x00\x00\x09")


def avc_sequence(ts_ms, record):
    return tag(9, ts_ms, bytes([0x17, 0, 0, 0, 0]) + record)


def avc_frame(ts_ms, key, avcc):
    return tag(9, ts_ms, bytes([0x17 if key else 0x27, 1, 0, 0, 0]) + avcc)


def aac_sequence(ts_ms, asc):
    return tag(8, ts_ms, bytes([0xAF, 0]) + asc)


def aac_frame(ts_ms, raw):
    return tag(8, ts_ms, bytes([0xAF, 1]) + raw)
