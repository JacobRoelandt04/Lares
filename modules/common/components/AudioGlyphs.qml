import QtQuick

// =============================================================================
// AudioGlyphs.qml -- which Nerd Font glyph says what an audio device is doing.
// The bar button and the OSD read one set of glyphs from this table.
//
//   outputGlyph(type, volume, muted)   type: "speaker" | "headphone" | "headset"
//                                      | "hands-free" | "phone" | "portable"
//                                      | "car" | "hdmi" | "bluetooth". Muted wins;
//                                      only "speaker" varies with the level.
//   inputGlyph(muted)                  the microphone; muted or not
//   inputGlyphAt(volume, muted)        the same with the level slots (all one
//                                      glyph by default, a pack can differ)
//   deviceType(node)                   a Pipewire node -> "speaker" | "headphone"
//                                      | "headset" | "hdmi" | "bluetooth"
//
// Codepoints are Material Design Nerd Font (4-byte UTF-8, written as \u{XXXXX}
// escapes so the source survives any 3-byte PUA mangling), each checked against the installed font BY NAME -- a codepoint that
// is merely present is not the glyph meant (md-volume_off is F0581, md-microphone_off is F036D, and the portable speaker is
// md-speaker, not md-vector_polyline). The slots are
// properties so a CSV / icon pack can replace them without code changes.
// =============================================================================
QtObject {
    id: root

    // ---- Output: device-type families ---------------------------------------
    property string outputGlyphMute:        "\u{F0581}"   // md-volume_off (F075F is md-volume_mute: no slash)
    property string outputGlyphSpeakerLow:  "\u{F057F}"   // volume-low
    property string outputGlyphSpeakerMed:  "\u{F0580}"   // volume-medium
    property string outputGlyphSpeakerHigh: "\u{F057E}"   // volume-high
    property string outputGlyphHeadphone:   "\u{F02CB}"   // headphones
    property string outputGlyphHeadset:     "\u{F02CE}"   // headset
    property string outputGlyphHandsFree:   "\u{F02CF}"   // headset-dock
    property string outputGlyphPhone:       "\u{F011C}"   // phone
    property string outputGlyphPortable:    "\u{F04C3}"   // md-speaker (F0561 is md-vector_polyline)
    property string outputGlyphCar:         "\u{F010B}"   // car
    property string outputGlyphHdmi:        "\u{F0841}"   // video-input-hdmi
    property string outputGlyphBluetooth:   "\u{F00AF}"   // bluetooth

    // ---- Input: full level support so a Nerd-Font pack with mic-level variants
    // can override per level. Defaults all map to the same glyph since stock
    // Nerd Fonts do not provide mic-level glyphs distinct from the default.
    property string inputGlyphMute: "\u{F036D}"   // md-microphone_off (F036E is md-microphone_outline)
    property string inputGlyphLow:  "\u{F036C}"   // md-microphone
    property string inputGlyphMed:  "\u{F036C}"
    property string inputGlyphHigh: "\u{F036C}"

    // Volume thresholds for the level glyph swap (0..1). The speaker's glyphs are the quiet one (no wave), one wave and two waves (the
    // font has no third): a sound at all is a wave. `levelLowMax` is the volume BELOW which the speaker is silent -- half a percent, where
    // the figure rounds to 0 % -- and `levelMedMax` the volume up to which it shows one wave (above it, two; the boost range above 100 %
    // stays at two).
    property real levelLowMax: 0.005
    property real levelMedMax: 0.5

    function outputGlyph(type, volume, muted) {
        if (muted) return root.outputGlyphMute;
        switch (type) {
            case "headphone":   return root.outputGlyphHeadphone;
            case "headset":     return root.outputGlyphHeadset;
            case "hands-free":  return root.outputGlyphHandsFree;
            case "phone":       return root.outputGlyphPhone;
            case "portable":    return root.outputGlyphPortable;
            case "car":         return root.outputGlyphCar;
            case "hdmi":        return root.outputGlyphHdmi;
            case "bluetooth":   return root.outputGlyphBluetooth;
            case "speaker":
            default: {
                if (volume < root.levelLowMax) return root.outputGlyphSpeakerLow;
                if (volume <= root.levelMedMax) return root.outputGlyphSpeakerMed;
                return root.outputGlyphSpeakerHigh;
            }
        }
    }

    function inputGlyphAt(volume, muted) {
        if (muted) return root.inputGlyphMute;
        if (volume < root.levelLowMax) return root.inputGlyphLow;
        if (volume <= root.levelMedMax) return root.inputGlyphMed;
        return root.inputGlyphHigh;
    }

    function inputGlyph(muted) {
        return root.inputGlyphAt(0, muted);
    }

    // What a Pipewire node (a PwNode, or anything with `properties`, `name`,
    // `description`, `nickname`) is. HDMI first (its nodes name themselves so and
    // carry no useful form factor), then the form factor when it is a headphone
    // or a headset (a Bluetooth headset is a headset, not "bluetooth"), then the
    // bus, then the words "headphone" / "headset" in the names, else a speaker.
    // PulseAudio's other form factors fold in: hands-free and handset are headsets.
    function deviceType(node) {
        if (!node) return "speaker";
        const props = node.properties || {};
        const text = [node.name, node.description, node.nickname,
                      props["node.name"], props["node.description"],
                      props["device.description"]]
            .map(s => String(s || "").toLowerCase()).join(" ");
        const form = String(props["device.form-factor"] || "").toLowerCase();
        const bus = String(props["device.bus"] || "").toLowerCase();
        if (text.indexOf("hdmi") >= 0) return "hdmi";
        if (form === "headphone") return "headphone";
        if (form === "headset" || form === "hands-free" || form === "handset") return "headset";
        if (bus === "bluetooth" || String(node.name || props["node.name"] || "").indexOf("bluez") === 0)
            return "bluetooth";
        // ALSA UCM names its jack "...__Headphones__sink" and sets no form factor.
        if (text.indexOf("headphone") >= 0) return "headphone";
        if (text.indexOf("headset") >= 0) return "headset";
        return "speaker";
    }
}
