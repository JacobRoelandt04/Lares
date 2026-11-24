pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// MathOverlays.qml -- the formulas of ONE rich-text edit, drawn over their placeholders.
//
//   MathOverlays { edit: _edit; records: [{ n, u, w, h, d, px, t }, ...]; ink: root.textColor; viewScale: 1 }
//
// WHY AN OVERLAY. A TextEdit lays out an <img> but cannot tint it, and the tint is the whole point: a
// formula's picture is a mask (white, alpha = coverage) that a shader colours, so a light/dark switch
// moves the ink and re-renders nothing. So Markdown.js leaves a TRANSPARENT image of the formula's size
// in the text (the line breaks around it, the selection covers it, the line grows to hold it) and this
// puts the real picture on top of it.
//
// WHERE IT GOES. `n` is the placeholder's ordinal among ALL the images of the block; an image is one
// U+FFFC in the document's text, so the n-th U+FFFC is it, and positionToRectangle(that) gives the
// line's rectangle and the placeholder's left edge. The placeholder is as tall as the picture's part
// ABOVE its baseline (the default image alignment puts an image's bottom ON the text baseline), so the
// picture's top is the baseline minus that, and the baseline is the line's bottom minus the font's
// descent (a line's descent is the font's, since nothing in it reaches below the baseline). `px` is the
// size of the font the block was written in (a heading's is bigger than the body's). Calibrated against a
// real opaque image in the same document.
//
// WHEN. On everything that can move a character: the text, the edit's width (a wrap), its content
// height, the records. Only an edit that HAS records pays: `records` is empty for nearly every block.
// =============================================================================
Item {
    id: root

    property TextEdit edit
    property var records: []
    property color ink: "black"
    property real viewScale: 1
    property string family: "Inter"

    // [{x, y} | null] per record, in this item's own coordinates (the edit's parent's).
    property var places: []

    onRecordsChanged: root.sync()
    onViewScaleChanged: root.sync()

    Connections {
        target: root.edit
        enabled: root.records.length > 0
        function onTextChanged() { root.sync(); }
        function onWidthChanged() { root.sync(); }
        function onContentHeightChanged() { root.sync(); }
    }

    FontMetrics {
        id: _fm
        font.family: root.family
    }

    function sync() {
        const e = root.edit;
        const recs = root.records;
        if (!e || recs.length === 0) {
            if (root.places.length > 0)
                root.places = [];
            return;
        }
        const txt = e.getText(0, e.length);
        const pos = [];
        for (let i = txt.indexOf("￼"); i >= 0; i = txt.indexOf("￼", i + 1))
            pos.push(i);
        const vs = root.viewScale;
        const rects = [];
        // a line's descent is the font's, or the below-the-baseline part of a formula when one reaches further
        // (see Markdown._mathHtml); records on one line share its y.
        const lineDescent = {};
        for (let k = 0; k < recs.length; k++) {
            const at = pos[recs[k].n];
            if (at === undefined) {
                rects.push(null);
                continue;
            }
            const r = e.positionToRectangle(at);
            rects.push(r);
            _fm.font.pixelSize = Math.max(1, Math.round(recs[k].px));
            const dsc = Math.max(_fm.descent, recs[k].dd);
            if (!(r.y in lineDescent) || dsc > lineDescent[r.y])
                lineDescent[r.y] = dsc;
        }
        const out = [];
        for (let k = 0; k < recs.length; k++) {
            const r = rects[k];
            if (r === null) {
                out.push(null);
                continue;
            }
            const rec = recs[k];
            const baseline = r.y + r.height - lineDescent[r.y];
            // the edit's own scale is 1 / viewScale around its top-left: its space to ours
            const x = e.x + r.x * e.scale;
            const y = e.y + baseline * e.scale - (rec.h - rec.d);
            out.push({ "x": Math.round(x * vs) / vs, "y": Math.round(y * vs) / vs });
        }
        root.places = out;
    }

    Repeater {
        model: root.records.length
        delegate: MathInk {
            id: _m
            required property int index
            readonly property var rec: root.records[_m.index]
            readonly property var place: _m.index < root.places.length ? root.places[_m.index] : null
            visible: _m.place !== null && _m.place !== undefined
            x: _m.place ? _m.place.x : 0
            y: _m.place ? _m.place.y : 0
            source: _m.rec.u
            pw: _m.rec.w
            ph: _m.rec.h
            ink: root.ink
            renderScale: root.viewScale
        }
    }
}
