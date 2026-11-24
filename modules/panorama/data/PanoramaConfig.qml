pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments

// =============================================================================
// PanoramaConfig.qml -- the user's panorama.jsonc, READ HOT (tunables only; the setups are the popup's, in setups.json).
// .examples/panorama.jsonc has every key. Every key is optional: a missing file IS the defaults; a value of the wrong kind is
// its default, a number out of range is clamped; a file that does not parse keeps the previous settings and `lastError` says
// where.
//
//   keepSeconds        15 (5..60)   the "Keep these display settings?" toast's countdown (decision 18)
//   identifyDelayMs    250 (0..2000) a pointer resting this long on a tile identifies that screen (decision 16)
//   toasts.newDisplay  true         a never-seen display says so with Mirror / Only external / Arrange (decision 3)
//   toasts.unplug      true         "<display> disconnected" (decision 22)
//   cast               false        casting to a TV from the Displays view (docs/contracts/panorama.md section 10): OFF until the user's own try
//   portLabels         {}           overrides of the port words: { laptop, hdmi, usbc, displaylink, dvi, vga, virtual, other }
//
// `live: false` reads no file and `apply(obj)` sets the object (a probe, the mock).
// =============================================================================
Item {
    id: root

    property bool live: true
    property string configPath: ""

    readonly property var settings: root._settings
    readonly property string lastError: root._lastError

    function apply(obj: var): void {
        root._settings = root.parse(obj);
    }

    function parse(o: var): var {
        const src = o && typeof o === "object" && !Array.isArray(o) ? o : {};
        function num(v, d, lo, hi) {
            return typeof v === "number" && isFinite(v) ? Math.max(lo, Math.min(hi, v)) : d;
        }
        const t = src.toasts && typeof src.toasts === "object" ? src.toasts : {};
        const pl = {};
        if (src.portLabels && typeof src.portLabels === "object")
            for (const k in src.portLabels)
                if (typeof src.portLabels[k] === "string" && src.portLabels[k] !== "")
                    pl[k] = src.portLabels[k];
        const cq = src.castQuality && typeof src.castQuality === "object" ? src.castQuality : {};
        return {
            keepSeconds: Math.round(num(src.keepSeconds, 15, 5, 60)),
            // the tab a click opens on (PanoramaBarOwner)
            openTab: ["situation", "displays", "presets", "last"].indexOf(src.openTab) >= 0 ? src.openTab : "situation",
            // a TV not set up yet (PanoramaStaging.castQuality fills a stored setup's gaps from it)
            castQuality: {
                res: typeof cq.res === "string" && /^\d{3,5}x\d{3,5}$/.test(cq.res) ? cq.res : "1920x1080",
                fps: Math.round(num(cq.fps, 30, 10, 60)),
                bitrate: typeof cq.bitrate === "string" && /^\d+[MK]$/.test(cq.bitrate) ? cq.bitrate : "8M",
                audio: cq.audio !== false
            },
            identifyDelayMs: Math.round(num(src.identifyDelayMs, 250, 0, 2000)),
            toasts: { newDisplay: t.newDisplay !== false, unplug: t.unplug !== false },
            cast: src.cast === true,
            portLabels: pl
        };
    }

    property var _settings: root.parse({})
    property string _lastError: ""

    function _read(txt: string): void {
        const s = String(txt || "");
        if (s.trim() === "") {
            root._settings = root.parse({});
            root._lastError = "";
            return;
        }
        try {
            root._settings = root.parse(JSON.parse(JsonComments.strip(s)));
            root._lastError = "";
        } catch (e) {
            const at = JsonComments.locate(s);
            root._lastError = at ? "panorama.jsonc line " + at.line + ", column " + at.column + ": " + at.reason
                                 : "panorama.jsonc: " + e.message;
            console.warn("PanoramaConfig: " + root._lastError + " -- the previous settings are kept");
        }
    }

    Loader {
        id: fvLoader
        active: root.live && root.configPath !== ""
        sourceComponent: Component {
            ConfigFile {
                id: fv
                path: root.configPath
                watchChanges: true
                onLoaded: root._read(fv.text())
                onLoadFailed: root._read("")
            }
        }
        // qmllint disable missing-property
        onLoaded: root._read(fvLoader.item.text())
    }
}
