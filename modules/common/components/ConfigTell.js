.pragma library

// =============================================================================
// ConfigTell.js -- what every ConfigFile has read, told to the one listener that checks it (modules/common/config/ConfigWatch).
//
// A loader reads its file through a ConfigFile; the ConfigFile says here which file it is (`path`: the first candidate,
// .../config/<name>.jsonc, whatever file is in force) and the text in force ("" when there is none). Nothing listens in a mockup, in the
// lock or in a probe: then this only remembers. A second ConfigFile on the same path says nothing new.
// =============================================================================

var _seen = {};
var _listener = null;

function saw(path, text) {
    if (!path || _seen[path] === text)
        return;
    _seen[path] = text;
    if (_listener)
        _listener(path, text);
}

// `fn(path, text)` for everything read so far and from now on; null lets go.
function listen(fn) {
    _listener = fn;
    if (!fn)
        return;
    for (const p in _seen)
        fn(p, _seen[p]);
}
