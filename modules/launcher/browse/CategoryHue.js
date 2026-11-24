.pragma library

// =============================================================================
// CategoryHue.js -- the hue a COLOURLESS app icon borrows, from its category.
//
// Some icons carry no hue of their own (a grey plate with a white symbol:
// Inkscape, Files), so the inset-hue treatment leaves them colourless and
// they stop being told apart at a glance. So they get a fallback hue,
// one per category where the .desktop file says which (its Categories list;
// the first freedesktop MAIN category in it decides). Returned as a THEME
// TOKEN NAME, resolved by the delegate (`Theme[token]`): the eight markdown
// hues are themed in both modes, and a model never carries a colour.
// =============================================================================

var TOKENS = {
    Game: "mdRed",
    Network: "mdOrange",
    Education: "mdYellow",
    Science: "mdYellow",
    Settings: "mdGreen",
    System: "mdGreen",
    Office: "mdTeal",
    Utility: "mdTeal",
    Development: "mdBlue",
    Graphics: "mdPurple",
    AudioVideo: "mdPink",
    Audio: "mdPink",
    Video: "mdPink"
};

// No main category (a script, a folder, an app that names none): the accent.
var DEFAULT_TOKEN = "accent";

function tokenFor(categories) {
    for (var i = 0; categories && i < categories.length; i++) {
        var t = TOKENS[categories[i]];
        if (t)
            return t;
    }
    return DEFAULT_TOKEN;
}
