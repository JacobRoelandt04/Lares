"""scrcpy 5.0.1 wire formats: stream headers, control messages, Annex-B -> AVCC. Pure functions, no I/O (castlib cases hold them)."""
import struct

CODEC_H264 = 0x68323634
CODEC_AAC = 0x00616163

PKT_CONFIG = 1 << 62
PKT_KEY = 1 << 61
PTS_MASK = (1 << 61) - 1

# Android keycodes
KEYCODES = {"back": 4, "home": 3, "recents": 187, "power": 26, "enter": 66, "backspace": 67, "del": 112, "tab": 61,
            "escape": 111, "up": 19, "down": 20, "left": 21, "right": 22, "wakeup": 224}

CT_KEYCODE, CT_TEXT, CT_TOUCH, CT_SCROLL, CT_BACK_OR_SCREEN_ON, CT_DISPLAY_POWER, CT_RESET_VIDEO = 0, 1, 2, 3, 4, 10, 17
CT_RESIZE_DISPLAY = 21     # scrcpy 5.0.1, only with flex_display=true on the server
FINGER_ID = 0xFFFFFFFFFFFFFFFE
TEXT_MAX = 300


def parse_session(b):
    """The 12-byte session packet -> (width, height, client_resized). Raises ValueError when bit 63 is not set."""
    if len(b) != 12 or not b[0] & 0x80:
        raise ValueError("not a session packet")
    w, h = struct.unpack(">II", b[4:12])
    return w, h, bool(b[3] & 1)


def build_session(w, h, resized=False):
    return bytes([0x80, 0, 0, 1 if resized else 0]) + struct.pack(">II", w, h)


def parse_media_header(b):
    """The 12-byte media header -> (config, key, pts_us, size). A session packet (bit 63) is the caller's to tell first."""
    v, size = struct.unpack(">QI", b)
    return bool(v & PKT_CONFIG), bool(v & PKT_KEY), v & PTS_MASK, size


def build_media_header(pts, size, config=False, key=False):
    v = (pts & PTS_MASK) | (PKT_CONFIG if config else 0) | (PKT_KEY if key else 0)
    return struct.pack(">QI", v, size)


def is_session(first_byte):
    return bool(first_byte & 0x80)


# ---- control messages -------------------------------------------------------------------------------------------------

def keycode(action, code, repeat=0, meta=0):
    """action 0 = down, 1 = up."""
    return struct.pack(">BBIII", CT_KEYCODE, action, code, repeat, meta)


def text(s):
    """INJECT_TEXT messages for s, each at most 300 bytes of UTF-8, never cutting a character."""
    out, cur = [], b""
    for ch in s:
        e = ch.encode("utf-8")
        if len(cur) + len(e) > TEXT_MAX:
            out.append(cur)
            cur = b""
        cur += e
    if cur:
        out.append(cur)
    return [struct.pack(">BI", CT_TEXT, len(b)) + b for b in out]


def touch(kind, x, y, w, h):
    action = {"down": 0, "up": 1, "move": 2}[kind]
    pressure = 0 if kind == "up" else 0xFFFF
    return struct.pack(">BBQiiHHHII", CT_TOUCH, action, FINGER_ID, int(x), int(y), w, h, pressure, 0, 0)


def _scroll_i16(v):
    n = max(-1.0, min(1.0, v / 16.0))
    return 32767 if n >= 1.0 else int(n * 32768)


def scroll(x, y, w, h, hs, vs):
    hs = max(-16.0, min(16.0, hs))
    vs = max(-16.0, min(16.0, vs))
    return struct.pack(">BiiHHhhI", CT_SCROLL, int(x), int(y), w, h, _scroll_i16(hs), _scroll_i16(vs), 0)


def back_or_screen_on(action):
    return struct.pack(">BB", CT_BACK_OR_SCREEN_ON, action)


def display_power(on):
    return struct.pack(">BB", CT_DISPLAY_POWER, 1 if on else 0)


def reset_video():
    return bytes([CT_RESET_VIDEO])


def resize_display(w, h):
    """RESIZE_DISPLAY (type 21, u16 width, u16 height, big-endian): the virtual display's new size, its dpi unchanged."""
    return struct.pack(">BHH", CT_RESIZE_DISPLAY, int(w), int(h))


# ---- device messages (read and thrown away) ----------------------------------------------------------------------------

DM_CLIPBOARD, DM_ACK_CLIPBOARD, DM_UHID_OUTPUT = 0, 1, 2


def device_msg_need(buf):
    """How many bytes the device message at the start of buf takes, or None when more is needed to tell, or -1 for an unknown type."""
    if not buf:
        return None
    t = buf[0]
    if t == DM_CLIPBOARD:
        return None if len(buf) < 5 else 5 + struct.unpack(">I", buf[1:5])[0]
    if t == DM_ACK_CLIPBOARD:
        return 9
    if t == DM_UHID_OUTPUT:
        return None if len(buf) < 5 else 5 + struct.unpack(">H", buf[3:5])[0]
    return -1


# ---- H.264 ------------------------------------------------------------------------------------------------------------

def split_annexb(data):
    """Annex-B -> list of NAL units (no start codes)."""
    nals, i, n = [], 0, len(data)
    starts = []
    while i + 3 <= n:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append((i, i + 3))
            i += 3
        else:
            i += 1
    for k, (s, body) in enumerate(starts):
        end = starts[k + 1][0] if k + 1 < len(starts) else n
        nal = data[body:end]
        while nal and nal[-1] == 0:     # a NAL never ends in 0: that is the next 4-byte start code's zero, or trailing padding
            nal = nal[:-1]
        if nal:
            nals.append(bytes(nal))
    return nals


def annexb_to_avcc(data):
    """Annex-B access unit -> 4-byte-length NAL units."""
    return b"".join(struct.pack(">I", len(n)) + n for n in split_annexb(data))


def avc_config(config_annexb):
    """AVCDecoderConfigurationRecord from scrcpy's config packet (SPS + PPS in Annex-B)."""
    sps = [n for n in split_annexb(config_annexb) if n[0] & 0x1F == 7]
    pps = [n for n in split_annexb(config_annexb) if n[0] & 0x1F == 8]
    if not sps or not pps:
        raise ValueError("config packet holds no SPS/PPS")
    s = sps[0]
    r = bytes([1, s[1], s[2], s[3], 0xFF, 0xE0 | len(sps)])
    for n in sps:
        r += struct.pack(">H", len(n)) + n
    r += bytes([len(pps)])
    for n in pps:
        r += struct.pack(">H", len(n)) + n
    return r


def avcc_params(record):
    """The SPS and PPS of an AVCDecoderConfigurationRecord as length-prefixed NAL units (AVCC), to go in-band in front of a key frame."""
    out, i = b"", 6
    for count in (record[5] & 0x1F, None):
        if count is None:
            count, i = record[i], i + 1
        for _ in range(count):
            n = struct.unpack(">H", record[i:i + 2])[0]
            out += struct.pack(">I", n) + record[i + 2:i + 2 + n]
            i += 2 + n
    return out
