pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// PackageIcons.qml
//
// Central icon registry for packages and package categories.
//
// Resolution order, first match wins:
//   1. exactIcons[name]        exact package name
//   2. patternIcons[]          first regex whose `re` matches the name
//   3. categoryIcons[category] the package's category (core / aur / …)
//   4. defaultIcon             everything else
//
// Glyphs are Nerd Font codepoints written as \u escapes rather than pasted
// private-use characters, so the source stays readable, greppable and
// diffable. Codepoints are from the Font Awesome 4 block, which every Nerd
// Font ships and which renders consistently across patches.
//
// Everything here is a plain property, so a host can extend or replace any
// layer without editing this file:
//
//   PackageIcons {
//       id: icons
//       exactIcons: Object.assign({}, icons.exactIcons, { "my-pkg": "" })
//   }
//
// Usage: `glyphFor(name, category)` returns a single-character string.
// =============================================================================
QtObject {
    id: registry

    // Fallback for anything unrecognised: a generic package/archive box.
    property string defaultIcon: ""          // archive

    // Per-category fallbacks.
    property var categoryIcons: ({
        core:     "",   // cog        — system core
        extra:    "",   // archive    — general packages
        multilib: "",   // clone      — 32-bit companions
        aur:      "",   // github     — community/source builds
        flatpak:  ""    // cubes      — sandboxed bundles
    })

    // Exact-name overrides for packages worth recognising at a glance.
    property var exactIcons: ({
        "linux":              "",   // linux
        "linux-lts":          "",
        "linux-zen":          "",
        "linux-hardened":     "",
        "linux-firmware":     "",   // microchip
        "pacman":             "",
        "yay":                "",   // terminal
        "paru":               "",
        "git":                "",   // git
        "docker":             "",   // ship
        "docker-desktop":     "",
        "firefox":            "",   // firefox
        "chromium":           "",   // chrome
        "code":               "",   // code
        "nano":               "",   // pencil-square
        "vim":                "",
        "neovim":             "",
        "tar":                "",
        "systemd":            ""    // cogs
    })

    // Regex rules, evaluated in order. Broad families live here so a whole
    // ecosystem picks up one icon without listing every package.
    property var patternIcons: [
        { re: /^linux(-|$)/,                    glyph: "" },  // linux
        { re: /^(nvidia|mesa|vulkan|libva)/,    glyph: "" },  // desktop
        { re: /^(qt[0-9]?|kf[0-9]|plasma|kde)/, glyph: "" },  // windows-ish UI
        { re: /^(hypr|wayland|xorg|wlroots)/,   glyph: "" },
        { re: /^(python|py3?-)/,                glyph: "" },
        { re: /^(node|npm|electron)/,           glyph: "" },  // file-code
        { re: /^(rust|cargo)/,                  glyph: "" },
        { re: /^(gcc|clang|llvm|binutils)/,     glyph: "" },  // wrench
        { re: /^lib/,                           glyph: "" },  // file-archive
        { re: /^(font|ttf-|otf-|noto)/,         glyph: "" },  // font
        { re: /(-bin|-git)$/,                   glyph: "" },  // github
        { re: /^(ffmpeg|gstreamer|vlc|mpv)/,    glyph: "" },  // film
        { re: /^(pipewire|pulseaudio|alsa)/,    glyph: "" },  // music
        { re: /^(openssl|gnupg|gpg|ca-cert)/,   glyph: "" },  // lock
        { re: /^(browser|zen-|brave|vivaldi)/,  glyph: "" }
    ]

    // Memoised, because the answer never changes for a given package and the
    // question is asked constantly: once per row delegate created, so every
    // category open re-runs the fifteen-regex scan for every package, and a
    // 218-package transaction that drains and refills asks thousands of
    // times. The cache is keyed on both arguments, since the category is the
    // fallback. Not notifying and never read by a binding, so mutating it in
    // place is safe -- it is a pure function's memo, not state.
    property var _glyphMemo: ({})

    function glyphFor(name, category) {
        if (!name) return registry.defaultIcon;

        const key = category ? name + "\u0000" + category : name;
        const hit = registry._glyphMemo[key];
        if (hit !== undefined) return hit;

        let out = registry.defaultIcon;
        const exact = registry.exactIcons[name];
        if (exact !== undefined) {
            out = exact;
        } else {
            let matched = false;
            for (let i = 0; i < registry.patternIcons.length; i++) {
                const rule = registry.patternIcons[i];
                if (rule && rule.re && rule.re.test(name)) {
                    out = rule.glyph;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                const byCat = category ? registry.categoryIcons[category] : undefined;
                if (byCat !== undefined)
                    out = byCat;
            }
        }
        registry._glyphMemo[key] = out;
        return out;
    }
}
