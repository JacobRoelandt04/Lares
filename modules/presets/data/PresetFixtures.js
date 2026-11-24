// =============================================================================
// PresetFixtures.js -- the mock's presets, shaped like the user's own desktop (one 2880 x 1620 panel at 1.25: 2304 x 1296 logical, the bar's
// 46 px on top, gaps 12): a six-tab kitty group with VS Code in it (locked), zen alone, two tiles side by side, a kitty on the special workspace, a
// floating window. `presets()` and `current()` hand out FRESH objects (a caller may keep and change them).
// =============================================================================
.pragma library

var MON = [{ name: "eDP-1", w: 2304, h: 1296 }];
var FULL = { at: [12, 46], size: [2280, 1238] };
var LEFT = { at: [12, 46], size: [1134, 1238] };
var RIGHT = { at: [1158, 46], size: [1134, 1238] };
var TOP_R = { at: [1158, 46], size: [1134, 613] };
var BOT_R = { at: [1158, 671], size: [1134, 613] };

function _w(cls, title, geo, extra) {
    var w = { "class": cls, title: title, at: geo.at.slice(), size: geo.size.slice(), floating: false, fullscreen: 0, pinned: false, group: null };
    for (var k in (extra || {}))
        w[k] = extra[k];
    return w;
}
function _group(id, members, active, locked) {
    return members.map(function (m, i) {
        return _w(m[0], m[1], FULL, { group: { id: id, index: i, active: i === active, size: members.length, locked: !!locked } });
    });
}
function _ws(key, windows, special) {
    return { key: String(key), name: special ? "special" : String(key), special: !!special, monitor: "eDP-1", windows: windows };
}
function _count(face) {
    var n = 0, w = 0;
    for (var i = 0; i < face.workspaces.length; i++) {
        if (face.workspaces[i].windows.length > 0)
            w++;
        n += face.workspaces[i].windows.length;
    }
    return { windows: n, workspaces: w };
}
function _preset(name, created, workspaces) {
    var face = { monitors: JSON.parse(JSON.stringify(MON)), workspaces: workspaces };
    var c = _count(face);
    return { name: name, slug: name.toLowerCase().replace(/[^a-z0-9]+/g, "-"), created: created, updated: created, windows: c.windows,
        workspaces: c.workspaces, face: face };
}

function presets() {
    return [
        _preset("dev", 1763600000, [
            _ws(1, _group("g1", [["kitty", "nvim"], ["kitty", "lazygit"], ["kitty", "claude"], ["kitty", "btop"], ["kitty", "yazi"], ["com.microsoft.VSCode", "quickshell - Visual Studio Code"]], 2, true)),
            _ws(2, [_w("zen", "Zen Browser", FULL)]),
            _ws(3, [_w("com.microsoft.VSCode", "bridge - Visual Studio Code", LEFT), _w("kitty", "~/bridge", RIGHT)]),
            _ws("special:default", [_w("kitty", "scratch", FULL)], true)
        ]),
        _preset("Writing", 1763500000, [
            _ws(1, [_w("org.gnome.Evince", "thesis.pdf", LEFT), _w("kitty", "nvim thesis.md", TOP_R), _w("kitty", "~/thesis", BOT_R)]),
            _ws(2, [_w("zen", "Zen Browser", FULL), _w("org.gnome.Loupe", "figure.png", { at: [700, 300], size: [900, 640] }, { floating: true })])
        ]),
        _preset("Media", 1763400000, [
            _ws(4, [_w("mpv", "film.mkv", FULL, { fullscreen: 2 })]),
            _ws(5, [_w("vesktop", "Discord", LEFT), _w("easytag", "EasyTAG", RIGHT)])
        ]),
        _preset("Everything", 1763300000, [
            _ws(1, [_w("kitty", "a", FULL)]),
            _ws(2, [_w("zen", "Zen Browser", FULL)]),
            _ws(3, [_w("com.microsoft.VSCode", "x", FULL)]),
            _ws(4, [_w("kitty", "b", LEFT), _w("kitty", "c", RIGHT)]),
            _ws(5, [_w("vesktop", "Discord", FULL)]),
            _ws(6, [_w("Postman", "Postman", FULL)]),
            _ws(7, [_w("kitty", "d", FULL)])
        ])
    ];
}

function current() {
    var p = _preset("now", 0, [
        _ws(1, _group("g9", [["kitty", "nvim"], ["kitty", "claude"], ["com.microsoft.VSCode", "quickshell - Visual Studio Code"]], 0)),
        _ws(2, [_w("zen", "Zen Browser", FULL)]),
        _ws(3, [_w("kitty", "~", FULL)])
    ]);
    return { windows: p.windows, workspaces: p.workspaces, face: p.face };
}
