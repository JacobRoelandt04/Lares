.pragma library

// =============================================================================
// LlmServerUrl.js -- the address of the chat's server (llm.jsonc "server"). Pure; tools/dev/llm_voice_cases.js has its cases.
//
//   clean(url)           the address as it is asked: no credentials (none is ever sent), no slash at its end
//   isLocal(url, name)   it is this machine's (`name`: this machine's own name)
// =============================================================================

function _authority(url) {
    const m = /^https?:\/\/([^\/?#]*)/i.exec(String(url || ""));
    return m ? m[1] : "";
}

function clean(url) {
    const a = _authority(url);
    const u = String(url || "").replace(/\/+$/, "");
    const at = a.lastIndexOf("@");
    return at < 0 ? u : u.replace(a, a.substring(at + 1));
}

function _host(url) {
    const a = _authority(clean(url)).toLowerCase();
    if (a.charAt(0) === "[") {
        const e = a.indexOf("]");
        return e < 0 ? a : a.substring(1, e);
    }
    const c = a.indexOf(":");
    return c < 0 ? a : a.substring(0, c);
}

function isLocal(url, name) {
    const h = _host(url);
    const me = String(name || "").trim().toLowerCase();
    return h === "localhost" || /\.localhost$/.test(h) || /^127\.\d+\.\d+\.\d+$/.test(h) || h === "::1" || h === "0.0.0.0"
        || (me !== "" && (h === me || h === me + ".local"));
}
