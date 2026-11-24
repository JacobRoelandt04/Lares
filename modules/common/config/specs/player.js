.pragma library

// The spec of config/player.jsonc (the grammar: ../ConfigCheck.js). Its words are .examples/player.jsonc's; the gate tools/dev/config_spec_check.js holds the two together.

var SPEC = {
    open: {
        view: ["word", "player", ["player", "mini"]],
        sidebar: ["bool", false],
        panel: ["word", "queue", ["queue", "library", "data"]],
        remember: ["bool", true]
    },
    library: {
        grouping: ["word", "albums", ["albums", "artists", "genres", "playlists", "recent"]],
        sort: {
            albums: ["word", "artist", ["artist", "title", "year", "length", "songs"]],
            artists: ["word", "name", ["name", "albums", "songs", "length"]],
            genres: ["word", "name", ["name", "albums", "songs", "length"]],
            playlists: ["word", "order", ["order", "name", "songs"]]
        },
        ascending: ["bool", true],
        looseArtists: ["bool", false]
    },
    autoplay: ["bool", true],
    holdForRecord: ["bool", true],
    prevRestartSec: ["num", 3, 0, 60],
    musicSparks: ["bool", true],
    shuffle: { artistGap: ["int", 3, 0, 20], albumGap: ["int", 2, 0, 20] },
    paths: {
        music: ["path", "~/Music", { start: true }],
        albums: ["text", "Albums", { start: true }],
        tracks: ["text", "Tracks", { start: true }],
        playlists: ["text", "Playlists", { start: true }],
        favorites: ["text", "Favorites", { start: true }],
        covers: ["list", ["cover.jpg", "cover.png", "cover.webp"], ["text", undefined], { start: true }],
        socket: ["path", "", { start: true }]
    }
};
