.pragma library

// =============================================================================
// MpdFidelity.js
//
// One song's audio format turned into a TIER — the chip the player shows next
// to the track, in Tidal's vocabulary, with the numbers behind it kept for the
// hover tip.
//
// The input is what MPD gives and nothing else: `Format:` from the database
// record (or `audio:` from `status` once the decoder is running), the live
// `bitrate:`, and the song's `file`. All three are cheap and always present;
// nothing here opens a file.
//
// WHY THE FILE EXTENSION DECIDES LOSSLESSNESS, NOT THE BIT FIELD. MPD's
// `RATE:BITS:CHANNELS` reports the DECODER's output, not the file's coding.
// Measured on this library:
//     .flac -> flac plugin   -> 44100:24:2   the file's true depth
//     .m4a  -> ffmpeg plugin -> 44100:f:2    AAC decoded to 32-bit float
//     .mp3  -> mpg123 plugin -> 48000:16:2   a LOSSY file with a NUMERIC depth
// So "bits is a number" does not mean lossless — mpg123 fixes every MP3 at 16.
// The codec (from the extension) is the only honest signal, and the bit field
// is used only to break the one genuine ambiguity: an `.m4a` is AAC when the
// decoder hands back float and ALAC when it hands back integers.
//
// THE max / hires SPLIT. The build contract defines `max` as "bits >= 24 OR
// rate > 48000" and `hires` as "lossless 24-bit at <= 48 kHz" — the two
// overlap on 24-bit/44.1, and first-match-wins would leave `hires` unreachable.
// The tie is broken by SAMPLE RATE, which is the axis the two rules disagree
// on: above 48 kHz is `max`, hi-res depth at CD/DAT rates is `hires`. That
// split is worth something on this library — 50 files really are 96/192 kHz
// and 166 are 24-bit at 44.1/48 — where folding them together would label
// four fifths of the collection identically.
//
// TWO LABELS, BECAUSE THE CHIP AND THE TIP SAY DIFFERENT THINGS. The chip shows
// the FORMAT -- `24-BIT 96kHZ FLAC`, and `44.1kHZ AAC` for a lossy file (the
// bitrate is the chip's hover lobe) -- so `label` is that string and the tier's
// own word is `tierLabel`. The casing is unit letter lower-case and the rest
// upper ("kHZ", "kBPS"); it is a badge, not a sentence. `tier` is what colours
// the chip, so the grading is on screen too.
//
// `label` is EMPTY only when the format itself is unknown. A queue row carries
// `Format:` but no bitrate, which makes the TIER unknown while the format is
// perfectly well known -- and the format is the fact the chip shows, so it
// reads `44.1kHZ AAC` there and the bitrate joins it once the decoder is running.
//
// A LOSSY STREAM WITH NO BITRATE IS `unknown`, NOT `low`. The lossless tiers
// are read off the format alone, but the lossy ones are a bitrate reading and
// nothing else — and `bitrate:` lives in `status` only: it is absent the
// moment the transport stops and no song RECORD carries it. Calling
// that `low` would put a Low chip on every 320 kbps AAC in the queue view.
// =============================================================================

// Codecs that carry the whole signal. `DSD` is here for completeness; nothing
// in this library is DSD, and its rate field counts BYTES, not samples.
var _LOSSLESS = { FLAC: 1, ALAC: 1, WAV: 1, AIFF: 1, APE: 1, WV: 1, TAK: 1, TTA: 1, DSD: 1 };

// Extension -> codec. `m4a`/`m4b`/`mp4` are deliberately AAC here and get
// rewritten to ALAC by _resolve when the decoder reports an integer depth.
var _EXT = {
    flac: "FLAC", ogg: "VORBIS", oga: "VORBIS", opus: "OPUS",
    mp3: "MP3", mp2: "MP2",
    m4a: "AAC", m4b: "AAC", mp4: "AAC", aac: "AAC",
    wav: "WAV", aif: "AIFF", aiff: "AIFF",
    ape: "APE", wv: "WV", tak: "TAK", tta: "TTA",
    wma: "WMA", dsf: "DSD", dff: "DSD", alac: "ALAC"
};

// The tier's own word — `tierLabel`, which opens the hover tip. The chip
// itself reads the FORMAT; see the header.
var _LABELS = { max: "Max", hires: "Hi-Res", lossless: "Lossless",
                high: "High", low: "Low", unknown: "Unknown" };

// "…/03. Artist - Title.flac" -> "FLAC". "" when there is no extension we
// recognise; the caller then falls back to the bit field alone.
function codecOf(file) {
    if (!file) return "";
    var s = String(file);
    var dot = s.lastIndexOf(".");
    if (dot < 0 || dot === s.length - 1) return "";
    var ext = s.substring(dot + 1).toLowerCase();
    return _EXT[ext] || "";
}

// "96000:24:2" -> { ok, rate, bitsText, bits, channels }. `bits` is 0 whenever
// the depth is not a plain integer ("f", "dsd"); `bitsText` keeps the wire's
// own word so a caller can tell the two apart.
function parseFormat(format) {
    var out = { ok: false, rate: 0, bitsText: "", bits: 0, channels: 0 };
    if (!format) return out;
    var p = String(format).split(":");
    if (p.length < 3) return out;
    var rate = parseInt(p[0], 10);
    var ch = parseInt(p[2], 10);
    if (!isFinite(rate) || rate <= 0) return out;
    out.ok = true;
    out.rate = rate;
    out.bitsText = p[1];
    out.bits = /^\d+$/.test(p[1]) ? parseInt(p[1], 10) : 0;
    out.channels = isFinite(ch) ? ch : 0;
    return out;
}

// Decide codec + losslessness together, because the m4a case changes both.
function _resolve(codec, f) {
    var ext = codec;
    if (ext === "AAC" && f.ok && f.bits > 0)
        return { codec: "ALAC", lossless: true };     // integers out of an m4a
    if (ext && _LOSSLESS[ext]) return { codec: ext, lossless: true };
    if (ext) return { codec: ext, lossless: false };
    // Unknown extension: the bit field is all there is. Float out means the
    // decoder is reconstructing a lossy stream; integers mean it is not.
    if (!f.ok) return { codec: "", lossless: false };
    return { codec: "", lossless: f.bits > 0 };
}

// 44100 -> "44.1 kHz", 48000 -> "48 kHz", 96000 -> "96 kHz". One decimal, and
// a trailing ".0" is dropped rather than printed.
function rateText(hz) {
    if (!(hz > 0)) return "";
    var k = Math.round(hz / 100) / 10;
    return String(k) + " kHz";
}

// The same number in the CHIP's casing: "44.1kHZ", "96kHZ". No space -- the
// figure and its unit are one token on a badge, and the badge is letter-spaced
// already.
function rateLabel(hz) {
    if (!(hz > 0)) return "";
    return String(Math.round(hz / 100) / 10) + "kHZ";
}

// The whole object the chip and its hover tip read. `format` is MPD's
// `Format:`/`audio:`, `bitrate` its live kbps (0 when stopped), `file` the
// song's uri.
function classify(format, bitrate, file) {
    var f = parseFormat(format);
    var br = Math.round(Number(bitrate) || 0);
    if (br < 0) br = 0;
    var r = _resolve(codecOf(file), f);

    var tier;
    if (!f.ok) {
        tier = "unknown";
    } else if (r.lossless) {
        if (f.rate > 48000) tier = "max";
        else if (f.bits >= 24) tier = "hires";
        else tier = "lossless";
    } else if (br > 0) {
        tier = br >= 256 ? "high" : "low";
    } else {
        // A lossy tier IS a bitrate reading, and there is none: `bitrate:` is
        // absent from `status` whenever the transport is stopped, and no song
        // RECORD carries it. "low" here would be an invention, and
        // the one every queue and library row would show — this library's
        // m4a's are 320 kbps and would all read Low. Unknown is the truth,
        // and a chip that renders nothing for it is the right answer.
        tier = "unknown";
    }

    // The hover line: codec, rate, depth WHEN KNOWN, live bitrate when the
    // decoder is running. Nothing is padded — this is a tip, not a figure slot.
    var parts = [];
    var head = r.codec;
    if (f.ok) head = head ? head + " " + rateText(f.rate) : rateText(f.rate);
    if (f.ok && f.bits > 0) head += " / " + f.bits + "-bit";
    if (head) parts.push(head);
    if (br > 0) parts.push(br + " kbps");

    // The chip's own line: the figures that are properties of the FILE. A
    // lossless file leads with its depth; a lossy one has none to state (a bit
    // depth on an AAC stream is the DECODER's word and says nothing about the
    // file -- the mp3 that decodes to 16-bit integers is the standing proof), so
    // it says its rate and codec and no more. The bitrate is on neither chip:
    // it is the lobe that grows out of the chip on hover (PlayerFidelityChip),
    // for lossless and lossy alike, read from `bitrate` below: one place for
    // one fact.
    var chip = [];
    if (r.lossless && f.bits > 0) chip.push(f.bits + "-BIT");
    if (f.ok) chip.push(rateLabel(f.rate));
    if (r.codec) chip.push(r.codec);

    return {
        tier: tier,
        // The format, for the chip. Empty when the format could not be parsed
        // at all — there is then nothing true to print, and the chip collapses
        // rather than inventing a word.
        label: f.ok ? chip.join(" ") : "",
        // The grading, for the tip's opening word.
        tierLabel: _LABELS[tier],
        detail: parts.join(" · "),
        sampleRate: f.rate,
        bits: f.bits,
        channels: f.channels,
        bitrate: br,
        codec: r.codec
    };
}
