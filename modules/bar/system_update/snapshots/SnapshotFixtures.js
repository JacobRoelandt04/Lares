.pragma library

// Rows for the mock service and the mockup: records as `lares-snapshot-root list` prints them (docs/contracts/snapshots.md section 5),
// real package names, the first snapshot 12 GB and the rest 0.6 to 4 GB.
var GB = 1000 * 1000 * 1000
var NOW = 1795000000   // overridden by records(now)

function _ch(name, from, to) { return { name: name, from: from, to: to } }
var _LIB = ["glib2", "gtk4", "cairo", "pango", "harfbuzz", "freetype2", "fontconfig", "libpng", "libjpeg-turbo", "libtiff", "libwebp",
    "ffmpeg", "x265", "x264", "libvpx", "svt-av1", "dav1d", "vulkan-icd-loader", "vulkan-intel", "libdrm", "wayland-protocols",
    "xorg-xwayland", "qt6-svg", "qt6-wayland", "qt6-shadertools", "qt6-multimedia", "qt6-5compat", "python-numpy", "python-pillow",
    "python-setuptools", "git", "curl", "openssh", "gnupg", "zstd", "xz", "lz4", "sqlite", "nss", "ca-certificates-mozilla"]
function _many(n, seed) {
    var out = []
    for (var i = 0; i < n; i++) {
        var name = _LIB[(i + seed) % _LIB.length] + (i >= _LIB.length ? "-" + (Math.floor(i / _LIB.length) + 1) : "")
        out.push(_ch(name, "1." + (i % 9) + "." + (i % 5), "1." + (i % 9) + "." + ((i % 5) + 1) + "-1"))
    }
    return out
}

function records(now) {
    var t = Math.floor(now / 1000), H = 3600, D = 86400
    var crit1 = [_ch("linux", "7.3.4.arch1-1", "7.3.5.arch1-1"), _ch("mesa", "26.2.1-1", "26.2.2-1"), _ch("nvidia-open", "615.35.01-1", "615.40.02-1"),
                 _ch("glibc", "2.43-2", "2.43-3")]
    return [
        { version: 1, id: "6a493314" + "0".repeat(56), short: "6a493314", time: t - 20 * H, reason: "update", run: null, count: 112,
          critical: ["linux", "mesa", "nvidia-open", "glibc"], targets: [], changed: crit1.concat(_many(108, 0)), state: "done", keep: false,
          note: "", added: 2.4 * GB, files: 41000, bytes: 11 * GB, seconds: 61 },
        { version: 1, id: "b01c7e22" + "0".repeat(56), short: "b01c7e22", time: t - 4 * D - 3 * H, reason: "update", run: null, count: 179,
          critical: ["linux", "systemd", "pacman"], changed: [_ch("linux", "7.3.3.arch1-1", "7.3.4.arch1-1"), _ch("systemd", "259.1-1", "259.2-1"),
          _ch("pacman", "7.1.0-1", "7.1.1-1")].concat(_many(176, 7)), state: "done", keep: true, note: "", added: 1.1 * GB, files: 38000, bytes: 11 * GB, seconds: 40 },
        { version: 1, id: "c3d4e5f6" + "0".repeat(56), short: "c3d4e5f6", time: t - 6 * D, reason: "manual", critical: [], changed: [], state: "done",
          keep: false, note: "", count: 0, added: 0.6 * GB, files: 38000, bytes: 11 * GB, seconds: 33 },
        { version: 1, id: "d7e8f9a0" + "0".repeat(56), short: "d7e8f9a0", time: t - 9 * D, reason: "update", critical: ["python", "openssl"],
          changed: [_ch("python", "3.14.0-1", "3.14.1-1"), _ch("openssl", "3.6.0-1", "3.6.1-1")].concat(_many(51, 3)), count: 53, state: "done", keep: false,
          note: "", added: 3.9 * GB, files: 39000, bytes: 11 * GB, seconds: 70 },
        { version: 1, id: "e1f2a3b4" + "0".repeat(56), short: "e1f2a3b4", time: t - 12 * D, reason: "undo", critical: ["mesa"],
          changed: [_ch("mesa", "26.2.2-1", "26.2.1-1")], count: 1, state: "done", keep: false, note: "d7e8f9a0", undoneTime: t - 12 * D - 5 * H, added: 0.8 * GB,
          files: 38000, bytes: 11 * GB, seconds: 30 },
        { version: 1, id: "f5a6b7c8" + "0".repeat(56), short: "f5a6b7c8", time: t - 17 * D, reason: "update", critical: [], changed: _many(61, 11), count: 61,
          state: "done", keep: false, note: "", added: 2.2 * GB, files: 37000, bytes: 11 * GB, seconds: 52 },
        { version: 1, id: "0a1b2c3d" + "0".repeat(56), short: "0a1b2c3d", time: t - 24 * D, reason: "rescue", critical: [], changed: [], count: 0,
          state: "done", keep: false, note: "", added: 0.7 * GB, files: 36000, bytes: 11 * GB, seconds: 28 },
        { version: 1, id: "1d2e3f40" + "0".repeat(56), short: "1d2e3f40", time: t - 31 * D, reason: "update", critical: ["hyprland", "quickshell-git"],
          changed: [_ch("hyprland", "0.57.1-1", "0.57.2-1"), _ch("quickshell-git", "0.3.1.r12-1", "0.3.2.r4-1")].concat(_many(70, 5)), count: 72, state: "done",
          keep: false, note: "", added: 12 * GB, files: 36000, bytes: 11 * GB, seconds: 524 }
    ]
}

function plan(short, rec) {
    if (rec && !(rec.changed && rec.changed.length)) return { ok: true, short: short, files: [], missing: [], newSince: [], removedSince: [] }
    return { ok: true, short: short, files: [ { name: "linux", now: "7.3.5.arch1-1", to: "7.3.4.arch1-1", source: "pacman", path: "/var/cache/pacman/pkg/linux" },
        { name: "mesa", now: "26.2.2-1", to: "26.2.1-1", source: "pacman", path: "/var/cache/pacman/pkg/mesa" } ],
        missing: [ { name: "nvidia-open", now: "615.40.02-1", to: "615.35.01-1" } ], newSince: [], removedSince: [] }
}
