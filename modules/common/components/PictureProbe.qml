pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// PictureProbe.qml -- does a captured picture hold anything? The one check behind every capture that feeds a picture (the sleep veil's
// SleepCapture, the lock's S0 in DesktopLayer): a ScreencopyView copied through a ShaderEffectSource can come out EMPTY -- all transparent
// (the copy never got the frame) or all black (the frame was black) -- and drawn as a picture that is a black screen.
//
// HOW. A tiny item (`cols` x `rows`, never drawn: `visible: false`) draws `source` over OPAQUE BLACK with Qt's default ShaderEffect pass,
// and `judge()` grabs it at that size. The source is mipmapped (both captures are), so each sample is the average of its region of the
// picture: a picture with ink anywhere has non-black samples. Over black, "transparent" and "black" are one answer and the grab is opaque
// (a grab of a transparent item lies about its faint pixels: CLAUDE.md). The grab is written as XPM -- text -- and read back by a
// FileView, so the verdict needs no process. The grab renders the probe's own pass, whose sampling of `source` is what brings a
// scheduled copy in: the texture judged IS the one the picture then draws (a ShaderEffectSource with `live: false` copies once).
//
//   source       the texture provider to judge (a ShaderEffectSource of a capture, mipmapped)
//   file         where the grab is written to be read back (one file per probe; it is overwritten)
//   judge()      start; `judged(verdict, inked, samples)` follows a frame or two later
//                verdict "ink" (some sample is brighter than `inkLevel`), "empty" (none is), "unknown" (no grab could be made or read:
//                the caller keeps the picture, as it did before there was a check)
// =============================================================================
Item {
    id: root

    property var source: null
    property string file: ""
    property int cols: 16
    property int rows: 9
    // the brightest channel of a sample, 0..255, at or below which it is no ink
    property int inkLevel: 2

    readonly property bool busy: root._busy

    signal judged(string verdict, int inked, int samples)

    width: root.cols
    height: root.rows
    visible: false

    property bool _busy: false

    function judge(): void {
        if (root._busy)
            return;
        if (!root.source || root.file === "") {
            root.judged("unknown", 0, 0);
            return;
        }
        root._busy = true;
        const asked = root.grabToImage(result => {
            root._busy = false;
            if (!result.saveToFile(root.file)) {
                root.judged("unknown", 0, 0);
                return;
            }
            back.reload();
            const r = root._read(back.text());
            root.judged(r.samples === 0 ? "unknown" : (r.inked > 0 ? "ink" : "empty"), r.inked, r.samples);
        }, Qt.size(root.cols, root.rows));
        if (!asked) {
            root._busy = false;
            root.judged("unknown", 0, 0);
        }
    }

    // An XPM: a header "w h ncolors cpp", the colour table ("<code> c #rrggbb" or "c None"), then one quoted row per line. Counts the
    // samples whose colour has a channel above inkLevel.
    function _read(text: string): var {
        const q = [];
        const re = /"([^"]*)"/g;
        let m;
        while ((m = re.exec(text)) !== null)
            q.push(m[1]);
        if (q.length < 1)
            return { inked: 0, samples: 0 };
        const head = q[0].trim().split(/\s+/).map(x => parseInt(x));
        const w = head[0], h = head[1], n = head[2], cpp = head[3];
        if (!(w > 0 && h > 0 && n > 0 && cpp > 0) || q.length < 1 + n + h)
            return { inked: 0, samples: 0 };
        const ink = {};
        for (let i = 1; i <= n; i++) {
            const line = q[i];
            const code = line.substring(0, cpp);
            const hex = /\bc\s+#([0-9A-Fa-f]{6})\b/.exec(line.substring(cpp));
            let lit = false;
            if (hex) {
                const v = parseInt(hex[1], 16);
                lit = Math.max((v >> 16) & 255, (v >> 8) & 255, v & 255) > root.inkLevel;
            }
            ink[code] = lit;
        }
        let inked = 0, samples = 0;
        for (let y = 0; y < h; y++) {
            const row = q[1 + n + y];
            for (let x = 0; x + cpp <= row.length; x += cpp) {
                samples++;
                if (ink[row.substring(x, x + cpp)] === true)
                    inked++;
            }
        }
        return { inked: inked, samples: samples };
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
    }
    // Qt's default ShaderEffect pass: `source`, premultiplied, over the black
    ShaderEffect {
        anchors.fill: parent
        property var source: root.source
    }
    FileView {
        id: back
        path: root.file
        blockAllReads: true
        printErrors: false
    }
}
