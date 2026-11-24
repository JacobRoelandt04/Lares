"""A QR code, byte mode, error correction M, versions 1-6 (up to 106 bytes), drawn as a PNG. Standard library only.

Used for ONE thing: the Wireless debugging pairing code Android's "Pair device with QR code" scans (`WIFI:T:ADB;S:<name>;P:<pw>;;`).
Proven by decoding with OpenCV in tools/dev/bridge_cases.py (group qr): an encoder no decoder read back proves nothing.
Algorithm after ISO/IEC 18004 as laid out by Project Nayuki's reference implementation (function patterns, Reed-Solomon over
GF(256) / 0x11D, interleaving, zigzag placement, the eight masks and the four penalty rules).
"""
import struct
import zlib

# version -> (EC codewords per block, data codewords of each block), level M
_BLOCKS = {1: (10, [16]), 2: (16, [28]), 3: (26, [44]), 4: (18, [32, 32]), 5: (24, [43, 43]), 6: (16, [27, 27, 27, 27])}
_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34]}
_M_FORMAT_BITS = 0  # level M


def _mul(x, y):
    z = 0
    for i in range(7, -1, -1):
        z = (z << 1) ^ ((z >> 7) * 0x11D)
        z ^= ((y >> i) & 1) * x
    return z & 0xFF


def _divisor(degree):
    r = [0] * (degree - 1) + [1]
    root = 1
    for _ in range(degree):
        for j in range(len(r)):
            r[j] = _mul(r[j], root)
            if j + 1 < len(r):
                r[j] ^= r[j + 1]
        root = _mul(root, 0x02)
    return r


def _remainder(data, div):
    r = [0] * len(div)
    for b in data:
        f = b ^ r.pop(0)
        r.append(0)
        for i, c in enumerate(div):
            r[i] ^= _mul(c, f)
    return r


def _codewords(data, version):
    ec, blocks = _BLOCKS[version]
    cap = sum(blocks)
    bits = [0, 1, 0, 0] + [(len(data) >> i) & 1 for i in range(7, -1, -1)]
    for b in data:
        bits += [(b >> i) & 1 for i in range(7, -1, -1)]
    bits += [0] * min(4, cap * 8 - len(bits))
    bits += [0] * (-len(bits) % 8)
    words = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = 0xEC
    while len(words) < cap:
        words.append(pad)
        pad ^= 0xEC ^ 0x11
    div = _divisor(ec)
    parts, at = [], 0
    for n in blocks:
        d = words[at:at + n]
        at += n
        parts.append((d, _remainder(d, div)))
    out = []
    for i in range(max(blocks)):
        out += [d[i] for d, _ in parts if i < len(d)]
    for i in range(ec):
        out += [e[i] for _, e in parts]
    return out


class _Grid:
    def __init__(self, version):
        self.n = version * 4 + 17
        self.dark = [[False] * self.n for _ in range(self.n)]
        self.fixed = [[False] * self.n for _ in range(self.n)]

    def put(self, x, y, dark):
        self.dark[y][x] = dark
        self.fixed[y][x] = True


def _functions(g, version):
    n = g.n
    for i in range(n):
        g.put(6, i, i % 2 == 0)
        g.put(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (n - 4, 3), (3, n - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < n and 0 <= y < n:
                    g.put(x, y, max(abs(dx), abs(dy)) not in (2, 4))
    pos = _ALIGN[version]
    for i, cx in enumerate(pos):
        for j, cy in enumerate(pos):
            if (i == 0 and j == 0) or (i == 0 and j == len(pos) - 1) or (i == len(pos) - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    g.put(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)
    _format(g, 0)


def _format(g, mask):
    n = g.n
    data = _M_FORMAT_BITS << 3 | mask
    rem = data
    for _ in range(10):
        rem = (rem << 1) ^ ((rem >> 9) * 0x537)
    bits = (data << 10 | rem) ^ 0x5412
    bit = lambda i: (bits >> i) & 1 == 1  # noqa: E731
    for i in range(6):
        g.put(8, i, bit(i))
    g.put(8, 7, bit(6))
    g.put(8, 8, bit(7))
    g.put(7, 8, bit(8))
    for i in range(9, 15):
        g.put(14 - i, 8, bit(i))
    for i in range(8):
        g.put(n - 1 - i, 8, bit(i))
    for i in range(8, 15):
        g.put(8, n - 15 + i, bit(i))
    g.put(8, n - 8, True)


def _place(g, words):
    n = g.n
    i = 0
    total = len(words) * 8
    right = n - 1
    while right >= 1:
        if right == 6:
            right = 5
        for vert in range(n):
            for j in range(2):
                x = right - j
                up = ((right + 1) & 2) == 0
                y = n - 1 - vert if up else vert
                if not g.fixed[y][x] and i < total:
                    g.dark[y][x] = (words[i >> 3] >> (7 - (i & 7))) & 1 == 1
                    i += 1
        right -= 2


_MASKS = [
    lambda x, y: (x + y) % 2 == 0,
    lambda x, y: y % 2 == 0,
    lambda x, y: x % 3 == 0,
    lambda x, y: (x + y) % 3 == 0,
    lambda x, y: (x // 3 + y // 2) % 2 == 0,
    lambda x, y: x * y % 2 + x * y % 3 == 0,
    lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
    lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0,
]


def _apply(g, mask):
    f = _MASKS[mask]
    for y in range(g.n):
        for x in range(g.n):
            if not g.fixed[y][x] and f(x, y):
                g.dark[y][x] = not g.dark[y][x]


def _penalty(rows):
    n = len(rows)
    p = 0
    for line in list(rows) + [list(c) for c in zip(*rows)]:
        run, prev = 0, None
        for v in line:
            if v == prev:
                run += 1
            else:
                if run >= 5:
                    p += run - 2
                run, prev = 1, v
        if run >= 5:
            p += run - 2
        s = "".join("1" if v else "0" for v in line)
        p += 40 * (s.count("1011101") and (s.count("00001011101") + s.count("10111010000")))
    for y in range(n - 1):
        for x in range(n - 1):
            if rows[y][x] == rows[y][x + 1] == rows[y + 1][x] == rows[y + 1][x + 1]:
                p += 3
    dark = sum(sum(r) for r in rows)
    p += 10 * (abs(dark * 20 - n * n * 10) // (n * n))
    return p


def encode(text):
    """-> the module grid (rows of bools, True = dark), without the quiet zone. Raises ValueError past 106 bytes."""
    data = str(text).encode("utf-8")
    version = next((v for v in sorted(_BLOCKS) if 4 + 8 + 8 * len(data) <= sum(_BLOCKS[v][1]) * 8), None)
    if version is None:
        raise ValueError("too long for a version 1-6 QR code: %d bytes" % len(data))
    words = _codewords(data, version)
    best = None
    for mask in range(8):
        g = _Grid(version)
        _functions(g, version)
        _place(g, words)
        _apply(g, mask)
        _format(g, mask)
        score = _penalty(g.dark)
        if best is None or score < best[0]:
            best = (score, g.dark)
    return best[1]


def png(text, path, scale=8, quiet=4):
    """Writes the code as a black-on-white greyscale PNG (scanners want dark on light), `scale` px a module."""
    rows = encode(text)
    n = len(rows) + 2 * quiet
    raw = bytearray()
    for y in range(n * scale):
        my = y // scale - quiet
        raw.append(0)
        for x in range(n * scale):
            mx = x // scale - quiet
            on = 0 <= my < len(rows) and 0 <= mx < len(rows) and rows[my][mx]
            raw.append(0 if on else 255)
    side = n * scale

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    blob = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 0, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(blob)
    import os
    os.replace(tmp, path)
    return path
