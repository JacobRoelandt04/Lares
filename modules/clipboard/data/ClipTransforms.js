.pragma library

// =============================================================================
// ClipTransforms.js -- what can be done to a copied text before it is pasted.
//
//   available(record)   the names that apply to THIS record (a transform that
//                       would change nothing, or cannot read the text, is not
//                       offered); a secret, an image, or a text the store
//                       truncated gets none
//   apply(name, text)   the new text; the input unchanged when the name does
//                       not apply to it
//
// Names: trim, oneLine, upper, lower, title, stripTracking, jsonPretty,
// jsonMinify, urlDecode, urlEncode, base64Decode, base64Encode, pathFromUri
// (kind "files" only). Pure, no Qt.
// =============================================================================

var TEXT_KINDS = { text: true, code: true, link: true, colour: true };

// Query parameters that only say where a link was clicked from.
var TRACKING = { fbclid: 1, gclid: 1, dclid: 1, mc_eid: 1, igshid: 1, si: 1,
                 ref_src: 1, _hsenc: 1, _hsmi: 1 };

function _isTracking(name) {
    let n = name;
    try {
        n = decodeURIComponent(name);
    } catch (e) {
        n = name;
    }
    n = n.toLowerCase();
    return n.indexOf("utm_") === 0 || TRACKING[n] === 1;
}

function stripTracking(text) {
    return String(text).replace(/https?:\/\/[^\s<>"']+/g, function (url) {
        let frag = "";
        const h = url.indexOf("#");
        if (h >= 0) {
            frag = url.slice(h);
            url = url.slice(0, h);
        }
        const q = url.indexOf("?");
        if (q < 0)
            return url + frag;
        const base = url.slice(0, q);
        const keep = url.slice(q + 1).split("&").filter(function (p) {
            if (p.length === 0)
                return false;
            const eq = p.indexOf("=");
            return !_isTracking(eq < 0 ? p : p.slice(0, eq));
        });
        return base + (keep.length > 0 ? "?" + keep.join("&") : "") + frag;
    });
}

// ---------------------------------------------------------------- UTF-8 / b64

var _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

function _utf8Bytes(s) {
    const out = [];
    for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < s.length) {
            const d = s.charCodeAt(i + 1);
            if (d >= 0xDC00 && d < 0xE000) {
                c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00);
                i++;
            }
        }
        if (c < 0x80) {
            out.push(c);
        } else if (c < 0x800) {
            out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
        } else if (c < 0x10000) {
            out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        } else {
            out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
    }
    return out;
}

// Strict: null on an invalid sequence, an overlong form or a surrogate.
function _utf8Text(b) {
    let s = "";
    let i = 0;
    while (i < b.length) {
        const c = b[i];
        let n = 0, cp = 0, min = 0;
        if (c < 0x80) {
            s += String.fromCharCode(c);
            i++;
            continue;
        } else if (c >= 0xC2 && c < 0xE0) {
            n = 1; cp = c & 0x1F; min = 0x80;
        } else if (c >= 0xE0 && c < 0xF0) {
            n = 2; cp = c & 0x0F; min = 0x800;
        } else if (c >= 0xF0 && c < 0xF5) {
            n = 3; cp = c & 0x07; min = 0x10000;
        } else {
            return null;
        }
        if (i + n >= b.length)
            return null;
        for (let k = 1; k <= n; k++) {
            const d = b[i + k];
            if ((d & 0xC0) !== 0x80)
                return null;
            cp = (cp << 6) | (d & 63);
        }
        if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp < 0xE000))
            return null;
        if (cp >= 0x10000) {
            cp -= 0x10000;
            s += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
        } else {
            s += String.fromCharCode(cp);
        }
        i += n + 1;
    }
    return s;
}

function _b64Encode(text) {
    const b = _utf8Bytes(String(text));
    let out = "";
    for (let i = 0; i < b.length; i += 3) {
        const x = b[i], y = i + 1 < b.length ? b[i + 1] : -1, z = i + 2 < b.length ? b[i + 2] : -1;
        out += _B64.charAt(x >> 2);
        out += _B64.charAt(((x & 3) << 4) | (y < 0 ? 0 : y >> 4));
        out += y < 0 ? "=" : _B64.charAt(((y & 15) << 2) | (z < 0 ? 0 : z >> 6));
        out += z < 0 ? "=" : _B64.charAt(z & 63);
    }
    return out;
}

// The bytes a base64 string holds, or null when it is not base64.
function _b64Bytes(text, minLen) {
    let s = String(text).replace(/\s+/g, "");
    if (!new RegExp("^[A-Za-z0-9+\\/_-]{" + minLen + ",}={0,2}$").test(s))
        return null;
    s = s.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
    if (s.length % 4 === 1)
        return null;
    const bytes = [];
    let acc = 0, bits = 0;
    for (let i = 0; i < s.length; i++) {
        acc = (acc << 6) | _B64.indexOf(s.charAt(i));
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            bytes.push((acc >> bits) & 255);
            acc &= (1 << bits) - 1;
        }
    }
    return bytes;
}

// The UTF-8 text a base64 string holds -- a sealed copy's bytes, as the tool's `secret` event carries
// them -- or null when they are not UTF-8. No printable test: a password may hold anything.
function utf8FromBase64(b64) {
    const bytes = _b64Bytes(b64, 0);
    return bytes === null ? null : (bytes.length === 0 ? "" : _utf8Text(bytes));
}

// The text the base64 holds, or null when it is not base64 or not text.
function _b64Decode(text) {
    const bytes = _b64Bytes(text, 4);
    if (bytes === null || bytes.length === 0)
        return null;
    const t = _utf8Text(bytes);
    if (t === null || t.length === 0)
        return null;
    // Printable: no control character but tab / newline / return, no U+FFFD.
    if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F\uFFFD]/.test(t))
        return null;
    return t;
}

// ------------------------------------------------------------------ the rest

function _json(text) {
    const t = String(text).trim();
    if (t.length < 2 || (t.charAt(0) !== "{" && t.charAt(0) !== "["))
        return undefined;
    try {
        return JSON.parse(t);
    } catch (e) {
        return undefined;
    }
}

function _urlDecode(text) {
    if (!/%[0-9a-fA-F]{2}/.test(text))
        return null;
    try {
        return decodeURIComponent(text);
    } catch (e) {
        return null;
    }
}

function _pathFromUri(text) {
    const lines = String(text).split(/\r?\n/).filter(function (l) {
        return l.length > 0 && l.charAt(0) !== "#";
    });
    const out = [];
    for (let i = 0; i < lines.length; i++) {
        const m = /^file:\/\/[^\/]*(\/.*)$/.exec(lines[i]);
        if (!m)
            return null;
        try {
            out.push(decodeURIComponent(m[1]));
        } catch (e) {
            return null;
        }
    }
    return out.length > 0 ? out.join("\n") : null;
}

var _TITLE = function (s) {
    return s.toLowerCase().replace(/(^|\s)(\S)/g, function (m, a, b) {
        return a + b.toUpperCase();
    });
};

// name -> (text -> string|null). null: it does not apply to this text.
var _FUNCS = {
    trim: function (t) {
        return t.trim();
    },
    oneLine: function (t) {
        return t.replace(/\s*[\r\n]+\s*/g, " ").trim();
    },
    upper: function (t) {
        return t.toUpperCase();
    },
    lower: function (t) {
        return t.toLowerCase();
    },
    title: _TITLE,
    stripTracking: stripTracking,
    jsonPretty: function (t) {
        const j = _json(t);
        return j === undefined ? null : JSON.stringify(j, null, 2);
    },
    jsonMinify: function (t) {
        const j = _json(t);
        return j === undefined ? null : JSON.stringify(j);
    },
    urlDecode: _urlDecode,
    urlEncode: function (t) {
        return encodeURIComponent(t);
    },
    base64Decode: _b64Decode,
    base64Encode: _b64Encode,
    pathFromUri: _pathFromUri
};

var ORDER = ["trim", "oneLine", "upper", "lower", "title", "stripTracking", "jsonPretty",
             "jsonMinify", "urlDecode", "urlEncode", "base64Decode", "base64Encode", "pathFromUri"];

function apply(name, text) {
    const t = String(text === undefined || text === null ? "" : text);
    const f = _FUNCS[name];
    if (f === undefined)
        return t;
    const r = f(t);
    return r === null || r === undefined ? t : String(r);
}

function available(record) {
    if (!record || record.truncated === true || typeof record.text !== "string")
        return [];
    const t = record.text;
    if (record.kind === "files")
        return _pathFromUri(t) !== null ? ["pathFromUri"] : [];
    if (TEXT_KINDS[record.kind] !== true || t.length === 0)
        return [];
    const out = [];
    for (let i = 0; i < ORDER.length; i++) {
        const name = ORDER[i];
        if (name === "pathFromUri")
            continue;
        const r = _FUNCS[name](t);
        if (r !== null && r !== undefined && r !== t)
            out.push(name);
    }
    return out;
}
