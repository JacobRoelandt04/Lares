.pragma library

// =============================================================================
// ClipParse.js -- what a card's face reads out of a record's text, pure.
//
//   colour(text)   -> { ok, r, g, b, a }  (0..1)  the copied CSS colour
//   link(text)     -> { scheme, host, path }      "https://www.a.b/c?d" -> a.b, /c?d
//   fileNames(text)-> [ "name.ext", ... ]         a text/uri-list, decoded
//
// The colour is DATA (what the user copied), never a theme token. CSS reads
// #rrggbbaa as alpha LAST where QML's Qt.color reads it first, so it is parsed
// here and handed over as numbers.
// =============================================================================

function _byte(h) {
    return parseInt(h, 16) / 255;
}

function _clamp(v) {
    return Math.max(0, Math.min(1, v));
}

function _num(tok, scale) {
    const t = String(tok).trim();
    if (t.charAt(t.length - 1) === "%")
        return _clamp(parseFloat(t) / 100);
    return _clamp(parseFloat(t) / scale);
}

function _hsl(h, s, l) {
    h = ((h % 360) + 360) % 360 / 360;
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    function hue(t) {
        if (t < 0) t += 1;
        if (t > 1) t -= 1;
        if (t < 1 / 6) return p + (q - p) * 6 * t;
        if (t < 1 / 2) return q;
        if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
        return p;
    }
    if (s === 0)
        return [l, l, l];
    return [hue(h + 1 / 3), hue(h), hue(h - 1 / 3)];
}

function colour(text) {
    const none = { ok: false, r: 0, g: 0, b: 0, a: 1 };
    const t = String(text === undefined || text === null ? "" : text).trim();
    let m = /^#([0-9a-fA-F]{3,8})$/.exec(t);
    if (m) {
        const h = m[1];
        if (h.length === 3 || h.length === 4) {
            const e = h.split("").map(function (c) { return c + c; });
            return { ok: true, r: _byte(e[0]), g: _byte(e[1]), b: _byte(e[2]), a: e.length === 4 ? _byte(e[3]) : 1 };
        }
        if (h.length === 6 || h.length === 8)
            return { ok: true, r: _byte(h.substr(0, 2)), g: _byte(h.substr(2, 2)), b: _byte(h.substr(4, 2)),
                     a: h.length === 8 ? _byte(h.substr(6, 2)) : 1 };
        return none;
    }
    m = /^(rgba?|hsla?)\(\s*([^)]*)\)$/i.exec(t);
    if (!m)
        return none;
    const fn = m[1].toLowerCase();
    const parts = m[2].split(/[\s,\/]+/).filter(function (p) { return p.length > 0; });
    if (parts.length < 3 || parts.length > 4)
        return none;
    const a = parts.length === 4 ? _num(parts[3], 1) : 1;
    if (fn.charAt(0) === "r")
        return { ok: true, r: _num(parts[0], 255), g: _num(parts[1], 255), b: _num(parts[2], 255), a: a };
    const rgb = _hsl(parseFloat(parts[0]), _num(parts[1], 100), _num(parts[2], 100));
    return { ok: true, r: rgb[0], g: rgb[1], b: rgb[2], a: a };
}

function link(text) {
    const t = String(text === undefined || text === null ? "" : text).trim();
    const m = /^([a-zA-Z][a-zA-Z0-9+.-]*):\/\/([^\/?#]*)(.*)$/.exec(t);
    if (!m)
        return { scheme: "", host: t, path: "" };
    let host = m[2].replace(/^[^@]*@/, "").replace(/^www\./i, "");
    return { scheme: m[1].toLowerCase(), host: host, path: m[3] };
}

function fileNames(text) {
    const out = [];
    const lines = String(text === undefined || text === null ? "" : text).split("\n");
    for (let i = 0; i < lines.length; i++) {
        const l = lines[i].replace(/\r$/, "").trim();
        if (l.length === 0 || l.charAt(0) === "#")
            continue;
        let p = l.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\/]*/, "");
        if (p.charAt(p.length - 1) === "/" && p.length > 1)
            p = p.substring(0, p.length - 1);
        const name = p.substring(p.lastIndexOf("/") + 1);
        let dec = name;
        try {
            dec = decodeURIComponent(name);
        } catch (e) {
            dec = name;
        }
        out.push(dec.length > 0 ? dec : l);
    }
    return out;
}
