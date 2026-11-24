pragma ComponentBehavior: Bound

import QtQuick
import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// LlmPdfMenu.qml
//
// The pdf chip's settings, as a small carved panel that opens ABOVE the chip:
// what the loader may take out of the document before it is sent. One slider
// per setting that matters in the CURRENT mode -- in embedded mode how many of
// the pdf's own pictures ride and the smallest picture kept, in pages mode how
// many pages are rendered -- then a divider, then the facts the loader has
// already established about this pdf.
//
// THE FACTS ARE A TABLE OF METRICS, NOT PROSE. The chip's sentences printed
// under the sliders would change the panel's shape every time a value moved:
// "12 pictures from 13 pages" reflows when a digit is added, and it collapses
// to one line the moment the pictures are switched off -- so the divider, the
// panel's floor and the panel's whole position under the pointer would jump
// while the slider that caused it is being dragged. So the facts are five
// FIXED ROWS -- what is being sent, how many ride of how many this file may
// send, from how many of the document's pages, how many duplicates were
// dropped, what it costs in tokens -- each label left, each figure
// right-aligned in a slot measured from the widest value that metric can ever
// hold, with the numerator padded to the total's width so the slash never
// moves either. The panel's height is then a constant of the MODE, and only
// the digits change. Every row carries a tip saying what the metric is; the
// loader's REASONS (what was cut and why, mask-drawn figures) are prose and
// stay prose, in the tip beside the table.
//
// EVERY TIP IN THIS PANEL OPENS BESIDE IT, NOT OVER IT. A title is two words
// -- "pictures", "smallest kept" -- and what the setting actually does is a
// sentence, which belongs in a tip; but a tip above the facts covers the
// sliders it is explaining, and a tip over a slider is worse. So every tip
// here is `side: "right"` with `gap` = the panel's padding + 6, which puts it
// clear of the panel's own edge whatever it is anchored to inside it, and
// HoverTip flips it to the left when the popup's right edge is nearer.
//
// WHY IT FLOATS IN THE OVERLAY. The same reason the model list does: an item
// that paints outside an ancestor's bounds receives no input there -- Qt
// prunes pointer delivery at ancestor bounds -- and a menu above a chip is
// entirely outside the composer. So the panel and its dismiss layer are
// reparented into the host's `overlayItem` while open; with no overlay they
// fall back to this item's parent, which is fine for a harness and wrong for
// a popup.
//
// THE SLIDER IS GrooveSlider with the MUTE MECHANIC OFF (`muteEnabled:
// false`): a setting has nothing to mute, and `muted: false` alone only stops
// the state, not the machinery -- the snap zone, the ball's travel toward the
// mute track and the 600 ms thickness swap would all still run and spring
// back. With the mechanic off there is one bar, the ball bends and squishes it
// against a bounded soft limit, and nothing else moves. The row is as tall as
// the slider SAYS it needs to be (`neededCross`) rather than a literal, so a
// fully bent ball is never clipped by the panel's floor.
//
// WHAT THE PANEL SAYS WHILE THE LOADER IS RE-READING. Measured on a 74-page
// deck, with the real loader behind the real composer: a settled slider
// reaches `resolved` 2.1 s later, and for those 2.1 s the table would go on
// printing the OLD figures as if they were current. `facts` follows the
// resolve to the frame; what nothing says is that the figures are stale: the
// loader writes `pending` on the HOST's attachment object, and a Repeater
// hands its delegate a COPY, so the chip's `pdfFactFigures` cannot see it and
// keeps answering "pictures, 21". Two seconds of a slider that appears to do
// nothing reads as "the setting is global". So the MENU latches the flight
// itself -- it is the thing that asked -- from the moment it emits
// `settingChanged` until `att` comes back as a fresh object, and while it is
// latched every figure the re-extract can change is an em dash and the state
// row says "re-reading…". `flightTimeoutMs` only unsticks a host that never
// answers. 2.1 s is far too long to re-extract per frame, which is why the
// signal fires on release and not while dragging.
//
// WHOSE VALUE IS ON THE ROW. Every file would show the same number until it
// was changed, and nothing would say whether that number is the file's own or
// the default it inherits. So the panel NAMES the file it is editing at the
// top, and every setting carries the shell's own mark in a fixed slot left of
// its figure: `*` when the value is this file's own override (the control
// panel's convention for "differs from the file default"), and NOTHING when
// the file has none and is running on the panel's. A word like "default" on
// every untouched row -- the common case -- would say that nothing had
// happened; the absence of a mark says it without ink. The mark appears the
// moment the user moves the slider -- the value on the row is then theirs,
// whatever the host has caught up with.
//
// ONE COLUMN EDGE. Every line in the panel -- the file's name, the titles, the
// figures, the dividers, the table -- starts at the slider's GROOVE start and
// ends at its groove end, not at the item's box: `neededEndPad` insets the
// groove by 11.6 px inside the slider, so a title at the panel's padding would
// sit 11.6 px left of the bar it names. The sliders still take the full
// padded width (that is what puts their grooves on that column) and
// everything else is inset by `_grooveInset`, which one Binding reads off the
// first slider so a host that rescales the sliders moves the whole column
// with them. The title also drops into the slack GrooveSlider leaves above its
// bent ball (`neededCross` carries 4 px either side beyond the ink), so a
// title sits closer to the slider it names than to the one above it.
//
// WHEN A CHANGE IS EMITTED. A re-extract on a large deck costs 2.1 s, so
// `settingChanged` must not follow the ball frame by frame. The figure in the
// title DOES follow it -- the user sees the value they are choosing -- but the
// signal fires on RELEASE, or after `settleMs` (250 ms) of the ball standing
// still while held (a wheel step has no release, and a user who pauses
// mid-drag to look at the figure gets the answer without letting go). Release
// is observed by a passive PointHandler in front of the slider's own
// MouseArea, so nothing is stolen from the slider. The loader coalesces a
// second call while one runs, so a pause-then-drag-on costs one extra
// extraction, never a queue.
//
// THE SETTINGS ARE THIS FILE'S, NOT THE SHELL'S. The menu edits the
// attachment it was opened on: `att.opts` holds that file's own overrides and
// `imageCap` / `imageMinArea` / `pageCap` / `mode` are only the DEFAULTS a
// file with no override of its own runs under (the panel keeps editing those,
// and a newly attached file starts from them). `settingChanged` carries an
// OPTS KEY -- "imageCap" | "imageMinArea" | "pageCap" -- which the host hands
// to `LlmAttachmentLoader.setOpts(att, { key: value })`; two chips therefore
// keep two different settings, and changing one re-extracts one. Until the
// host's value catches up, the row shows the value the user set; the moment
// the host agrees the row follows the host again -- so the figure never steps
// back through the old value.
//
// Every colour is a property with a `Theme.<token>` default; nothing animates
// a colour. Presence fades (160 ms); everything else is instant.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    property bool   open: false
    // The chip: the panel opens above it, centred on it.
    property Item   anchorItem: null
    // The host's floating layer (LlmPopup.overlayItem). Null = parent
    // fallback (harness only -- see the header).
    property Item   overlayItem: null

    // THE ATTACHMENT this menu was opened on: its `opts` are the settings
    // shown and edited; everything below is only the fallback.
    property var    att: null
    // "embedded" | "pages" -- the DEFAULT mode; a file that has its own
    // (`opts.imageMode`, or the mode the loader stamped on it when it last
    // extracted) shows the sliders of ITS mode.
    property string mode: "embedded"
    property int    imageCap: 32
    property int    imageMinArea: 10000
    property int    pageCap: 24
    // The facts. `facts` is the chip's raw figure object
    // (LlmAttachmentChip.pdfFactFigures): { state, count, pageSpan,
    // pageCount, dupes, tokens }, where -1 means "not known yet" and 0 means
    // "none" -- this file turns it into the table. `advancedLines` is the
    // chip's prose (LlmAttachmentChip.pdfFactsAdvanced); empty = no tip.
    property var    facts: ({})
    property var    advancedLines: []

    // A slider's value moved and settled (see the header). `key` is the
    // attachment's own opts key -- "imageCap" | "imageMinArea" | "pageCap" --
    // so the host's whole job is
    // `loader.setOpts(att, { [key]: Math.round(value) })`.
    signal settingChanged(string key, real value)

    // ---- Ranges (tunables) ----
    property int    imageCapMax: 80
    property int    imageMinAreaMax: 40000
    property int    imageMinAreaStep: 500
    property int    pageCapMax: 60

    // ---- Sizes (tunables) ----
    property string fontFamily: "Inter"
    property real   menuWidth: 224
    property real   padding: 10
    property real   radius: 10
    property real   gap: 6            // between the panel and the chip
    // Between one setting and the next TITLE: a title names the slider under
    // it, so the air above it has to be plainly larger than the air below it,
    // and below it is the slider's own slack.
    property real   rowGap: 10        // between a slider and the next title
    // How far the title row drops into the slider row. GrooveSlider sizes
    // `neededCross` as 2*(cross travel + ball half-extent) + 8, i.e. 4 px of
    // slack past the furthest ink either side; 3 of those 4 close the gap and
    // the fourth stays as margin.
    property real   titleSliderOverlap: 3
    // The air between a line of text and the slider under it. The slider's
    // own row is mostly air already (it is `neededCross` tall so a bent ball
    // is never cut), so the TEXT's padding is what is left to tighten: 4 px
    // above and below a 10 px title would read as a gap on top of a gap.
    property real   textGap: 2
    // The air either side of the divider between the sliders and the table.
    property real   dividerGap: 6
    property real   sliderScale: 0.8  // GrooveSlider.sizeScale
    property real   sliderBall: 12    // GrooveSlider.ballSize (before the scale)
    property real   sliderEdgePadding: 8
    property int    titlePixelSize: 10
    property int    figurePixelSize: 10
    property int    settleMs: 250
    // The stuck-state guard on the re-extract the menu asked for: a host that
    // never answers must not leave the table reading "re-reading…" for ever.
    // Not a timing assumption -- the measured re-extract is 2.1 s.
    property int    flightTimeoutMs: 20000
    property int    tipDelayMs: 250
    // What a tip anchored INSIDE the panel has to be pushed out by to clear
    // the panel's own edge: the padding, plus the column's inset (every line
    // ends at the groove, not at the padding), plus 6.
    readonly property real _tipGap: root.padding + root._grooveInset + 6
    property int    fadeMs: 160

    // ---- Palette ----
    property color surfaceColor: Theme.listBox      // what the panel floats over
    property color fieldColor: Theme.panelSunk      // the panel's fill
    property color grooveColor: Theme.headerBox     // the slider's channel
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color ballShadowColor: Theme.ballShadow
    property color tipSurfaceColor: Theme.surface

    // ONE COLUMN EDGE (see the header): how far the slider's groove is inset
    // inside the slider, read off the first slider by the Binding in its row
    // so a rescale moves every line with it. 0 until the first row exists.
    property real _grooveInset: 0

    // Renders nothing where it is declared: the panel lives in the host.
    width: 0
    height: 0

    // ======================================================================
    // THE SETTINGS OF THE CURRENT MODE
    // ======================================================================
    // THIS FILE's own override, or the default it inherits, per key.
    readonly property var _opts: (root.att && root.att.opts) ? root.att.opts : ({})
    // The file this panel is editing, named at the top of it.
    readonly property string _path: root.att ? String(root.att.path || "") : ""
    readonly property string _fileName: {
        if (root.att && root.att.name)
            return String(root.att.name);
        const p = root._path;
        const i = p.lastIndexOf("/");
        return i >= 0 ? p.substring(i + 1) : p;
    }
    // Does THIS file own the value of `key`, or is it running on the default?
    function _isOwn(key) {
        const v = root._opts[key];
        return v !== undefined && v !== null;
    }
    function _opt(key, dflt) {
        const v = root._opts[key];
        return (v !== undefined && v !== null) ? v : dflt;
    }
    // The mode this FILE is in: its own override, else the mode the loader
    // stamped on it when it extracted, else the default. A panel change to
    // the default does not reach a file that has already been read -- that
    // is what per-file means.
    readonly property string _mode: {
        const o = root._opts.imageMode;
        if (o) return String(o);
        if (root.att && root.att.imageMode) return String(root.att.imageMode);
        return root.mode;
    }

    // The title is two words; the sentence under it is the tip.
    readonly property var _settings: root._mode === "pages"
        ? [{ name: "pageCap", label: "pages",
             tip: "how many pages are rendered and sent as images, from page 1",
             from: 0, to: root.pageCapMax, step: 1, unit: "" }]
        : [{ name: "imageCap", label: "images",
             tip: "the most images this file may send",
             from: 0, to: root.imageCapMax, step: 1, unit: "" },
           { name: "imageMinArea", label: "smallest kept",
             // What the number DOES, in the loader's own terms: an area, in
             // pixels, under which a picture is furniture. Broken onto lines
             // at the meaning, like every other explanation in this module.
             tip: "an image smaller than this many pixels of area\n"
                + "is treated as decoration and not sent",
             from: 0, to: root.imageMinAreaMax, step: root.imageMinAreaStep, unit: " px²" }]

    // WHAT THE ROW IS SHOWING, which is not always what the host holds: while
    // a slider is being dragged the figure in its title is the user's, and the
    // table's denominator ("21 / 32") is the same setting, so it has to be the
    // same number. One key at a time -- one pointer, one slider.
    property string _dragKey: ""
    property real   _dragVal: -1
    function _valueShown(name) {
        return (name === root._dragKey && root._dragVal >= 0)
            ? root._dragVal : root._valueOf(name);
    }
    function _valueOf(name) {
        switch (name) {
        case "imageCap":     return root._opt("imageCap", root.imageCap);
        case "imageMinArea": return root._opt("imageMinArea", root.imageMinArea);
        case "pageCap":      return root._opt("pageCap", root.pageCap);
        }
        return 0;
    }
    // 10000 -> "10 000", grouped with a NO-BREAK space so the figure is one
    // token, like every figure in the chip's tip.
    function _group(n) {
        return String(Math.round(n)).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
    }
    function _format(setting, v) {
        return root._group(v) + setting.unit;
    }

    // ======================================================================
    // THE METRICS TABLE
    // ======================================================================
    // Five rows, the same five whatever the sliders say. A figure that is not
    // known yet is an em dash, not a zero -- "no pictures in this pdf" and
    // "nobody has looked yet" are different answers and the reader must not
    // read one as the other; `state` names which of them this is.
    //
    // FIXED SLOTS, twice over. The row's slot is measured from `slot` -- the
    // widest string that METRIC can ever hold, never from the value it holds
    // now -- so the label above never moves; and inside a ratio the numerator
    // is padded with U+2007 FIGURE SPACE (a digit's width) to the total's
    // width, so the slash and the total stay on one column as the numerator
    // walks 9 -> 12 -> 128. Same discipline as DownloadStats.
    // ---- The re-extract this panel asked for ------------------------------
    // Latched when a setting is emitted, released when the host answers with a
    // fresh attachment object -- which is the only signal in this direction
    // the menu gets, and the same one the metrics themselves ride on.
    property bool _inFlight: false
    function _beginFlight() {
        root._inFlight = true;
        flightGuard.restart();
    }
    // Which file the panel was last showing, and a counter the rows watch.
    // A resolve hands the menu a FRESH OBJECT for the same file, which must
    // not disturb a value the user is still choosing; the menu being pointed
    // at a DIFFERENT file must, because a drag left on the last one would
    // otherwise show as this one's figure and wear this one's `*`.
    property string _openPath: ""
    property int    _fileGen: 0
    onAttChanged: {
        root._inFlight = false;
        flightGuard.stop();
        // The path is read off the OBJECT, not off `_path`: a change handler
        // and a binding on the same property are notified in an order QML
        // does not promise, and `_path` still holds the last file's value
        // here on one switch in three (measured).
        const p = root.att ? String(root.att.path || "") : "";
        if (p !== root._openPath) {
            root._openPath = p;
            root._fileGen += 1;
            root._dragKey = "";
            root._dragVal = -1;
        }
    }
    Timer {
        id: flightGuard
        interval: root.flightTimeoutMs
        onTriggered: root._inFlight = false
    }

    readonly property string _figSpace: "\u2007"
    readonly property string _dash: "—"
    function _padTo(str, n) {
        let out = String(str);
        while (out.length < n) out = root._figSpace + out;
        return out;
    }
    // "12 / 32". Unknown numerator -> a dash in the numerator's slot; unknown
    // total -> a dash for the row, because a share of nothing says nothing.
    function _ratio(n, total) {
        const t = Math.max(0, Math.round(Number(total) || 0));
        if (t <= 0) return root._dash;
        const ts = root._group(t);
        const ns = (Number(n) >= 0) ? root._group(Math.round(Number(n))) : root._dash;
        return root._padTo(ns, ts.length) + " / " + ts;
    }
    function _ratioSlot(total) {
        const t = Math.max(0, Math.round(Number(total) || 0));
        if (t <= 0) return root._dash;
        const ts = root._group(t);
        return ts + " / " + ts;
    }
    function _count(n) {
        return (Number(n) >= 0) ? root._group(Math.round(Number(n))) : root._dash;
    }

    readonly property var _metrics: {
        // In flight, every figure the re-extract can change is unknown again:
        // the old ones are not the answer to the question just asked, and an
        // em dash is what this table already says for "nobody knows yet".
        const f = root._inFlight
            ? ({ state: "re-reading…", count: -1, pageSpan: -1,
                 pageCount: (root.facts && root.facts.pageCount) || 0,
                 dupes: -1, tokens: -1 })
            : (root.facts ? root.facts : ({}));
        const pages = root._mode === "pages";
        const cap = pages ? root._valueShown("pageCap") : root._valueShown("imageCap");
        const capMax = pages ? root.pageCapMax : root.imageCapMax;
        const pageCount = Math.max(0, Number(f.pageCount) || 0);
        return [
            { label: "sending",
              value: f.state ? String(f.state) : root._dash,
              // The widest word this row can hold; every state fits it.
              slot: "re-reading…",
              // THE LOADER'S REASONS RIDE HERE. They are prose -- what was
              // cut and why, which figures are drawn as masks, why a repeated
              // picture rides once -- so they cannot be a metric; and they
              // explain exactly this row, which says what is being sent. One
              // tip per row and no second tip over the table: a hover on the
              // table would arm at the same time as a row's and open two
              // bubbles on one pointer.
              tip: "what actually goes to the model from this pdf"
                   + (root.advancedLines.length > 0
                      ? "\n\n" + root.advancedLines.join("\n") : "") },
            { label: pages ? "pages" : "images",
              value: root._ratio(f.count, cap),
              // The slider above can be dragged to its maximum, so the slot
              // is measured there and not at the current cap.
              slot: root._ratioSlot(capMax),
              tip: pages ? "how many pages are rendered, of the most this file may render"
                         : "how many images ride, of the most this file may send" },
            { label: "from pages",
              value: root._ratio(f.pageSpan, pageCount),
              slot: root._ratioSlot(pageCount),
              tip: "how many of the document's pages those images come from" },
            { label: "duplicates",
              value: root._count(f.dupes),
              slot: "000",
              tip: "an image repeated on several pages rides once, at the page it first appears on" },
            { label: "tokens",
              value: root._count(f.tokens),
              slot: "000 000",
              tip: "what those images add to the prompt, give or take" }
        ];
    }

    // ======================================================================
    // PLACEMENT
    // ======================================================================
    readonly property Item _floatHost: root.overlayItem ? root.overlayItem
                                     : (root.parent ? root.parent : root)
    // The chip's rectangle in the host, mapped once per open (the chip does
    // not move while its menu is up -- the strip under it is not scrolled
    // through a dismiss layer).
    property rect _anchor: Qt.rect(0, 0, 0, 0)
    onOpenChanged: {
        if (root.open) {
            root._built = true;
            const a = root.anchorItem;
            const h = root._floatHost;
            if (a && h) {
                const p = a.mapToItem(h, 0, 0);
                root._anchor = Qt.rect(p.x, p.y, a.width, a.height);
            }
        } else {
            // A panel put away is not waiting for anything.
            root._inFlight = false;
            flightGuard.stop();
        }
    }

    // Dismiss layer: full-bleed over the host, any button. It sits UNDER the
    // panel (z 299 / 300), so a click on a slider is the slider's and a click
    // anywhere else shuts the menu -- and still reaches what it was aimed at.
    LlmDismissLayer {
        parent: root._floatHost
        anchors.fill: parent
        open: root.open
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onDismissed: root.open = false
    }

    // Escape, wherever the focus is: the panel takes none (the prompt keeps
    // it), so a Keys handler here would never fire. Same idiom as the picker.
    Shortcut {
        sequence: "Escape"
        enabled: root.open
        onActivated: root.open = false
    }

    // The divider: the shell's own line, on the same column as every other
    // line in the panel.
    component Divider: Item {
        width: parent ? parent.width : 0
        height: root.dividerGap * 2 + 1
        Rectangle {
            x: root._grooveInset
            width: Math.max(0, parent.width - root._grooveInset * 2)
            anchors.verticalCenter: parent.verticalCenter
            height: 1
            color: root.shadowColor
        }
    }

    // THE PANEL IS BUILT THE FIRST TIME THE MENU OPENS. It is two GrooveSliders (a particle system, canvases and a bloom each) and a
    // metrics table -- a third of a composer's objects -- for a menu that only a pdf chip's right click ever shows; and a built
    // slider's ParticleSystem is a thing that RUNS, which a parked chat may not. Once built it stays: the close is a fade, and the
    // next open is the same panel.
    property bool _built: false
    Loader {
        active: root._built
        sourceComponent: panelComponent
    }
    Component {
        id: panelComponent

        Item {
            id: panel
            parent: root._floatHost
            z: 300
            width: root.menuWidth
            height: Math.round(root.padding * 2 + column.implicitHeight)
            // Centred on the chip, clamped inside the host; above it, or below
            // when there is no room above.
            x: Math.round(Math.max(2, Math.min(parent.width - width - 2,
                                               root._anchor.x + root._anchor.width / 2 - width / 2)))
            y: Math.round(root._anchor.y - height - root.gap >= 2
                          ? root._anchor.y - height - root.gap
                          : root._anchor.y + root._anchor.height + root.gap)

            // `_armed` comes a turn after the panel exists, so that the FIRST open fades in like every later one (a Behavior does not
            // animate the value a thing is born with).
            property bool _armed: false
            Component.onCompleted: Qt.callLater(() => panel._armed = true)
            opacity: root.open && panel._armed ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic } }

            ShadowBox {
                anchors.fill: parent
                baseRadius: root.radius
                surfaceColor: root.surfaceColor
                backgroundColor: root.fieldColor
                bevelColor: root.bevelColor
                shadowColor: root.shadowColor
                bevelWidth: 1
                shadowWidth: 3
            }

            Column {
                id: column
                x: root.padding
                y: root.padding
                width: panel.width - root.padding * 2
                // The column every LINE reads from: the slider's groove, not the
                // item's box (see the header). The sliders themselves still take
                // the full width -- that is what puts their grooves here.
                readonly property real inset: root._grooveInset
                readonly property real lineWidth: column.width - column.inset * 2
                spacing: 0

                // WHICH FILE THIS IS. The settings are the file's, so the file is
                // named where they are edited; the whole path is the tip.
                Item {
                    id: nameRow
                    width: column.width
                    height: root.titlePixelSize + root.textGap * 2
                    Text {
                        id: nameText
                        x: column.inset
                        width: column.lineWidth
                        anchors.verticalCenter: parent.verticalCenter
                        elide: Text.ElideRight
                        text: root._fileName
                        color: root.primaryText
                        font.family: root.fontFamily
                        font.pixelSize: root.titlePixelSize
                        font.bold: true
                        HoverHandler { id: nameHover }
                    }
                    HoverTip {
                        show: nameHover.hovered && root._path.length > 0
                        delayMs: root.tipDelayMs
                        side: "right"
                        gap: root._tipGap
                        anchorItem: nameRow
                        overlayItem: root.overlayItem
                        text: root._path
                        fontFamily: root.fontFamily
                        fontPixelSize: root.figurePixelSize
                        surfaceColor: root.tipSurfaceColor
                        bevelColor: root.bevelColor
                        shadowColor: root.shadowColor
                        textColor: root.primaryText
                    }
                }

                Divider {}

                Repeater {
                    model: root._settings

                    Item {
                        id: srow
                        required property var modelData
                        required property int index
                        width: column.width
                        height: titleRow.height + sliderRow.height - root.titleSliderOverlap
                                + (srow.index < root._settings.length - 1 ? root.rowGap : 0)

                        readonly property string name: srow.modelData.name
                        readonly property real from: srow.modelData.from
                        readonly property real to: srow.modelData.to
                        readonly property real step: srow.modelData.step
                        readonly property real hostValue: root._valueOf(srow.name)
                        // What the user set and the host has not yet confirmed;
                        // -1 = follow the host. Cleared the moment they agree.
                        property real dragValue: -1
                        readonly property real value: srow.dragValue >= 0 ? srow.dragValue : srow.hostValue
                        // Is the value on this row THIS FILE's own? The host's
                        // override says so once it has landed; until then the
                        // user's own drag does -- the number on the row is
                        // theirs the moment they move it.
                        readonly property bool own: srow.dragValue >= 0 || root._isOwn(srow.name)
                        // The panel moved to another file: this row's unconfirmed
                        // drag belonged to the last one.
                        readonly property int fileGen: root._fileGen
                        onFileGenChanged: srow.dragValue = -1
                        onHostValueChanged: {
                            if (srow.dragValue >= 0 && srow.hostValue === srow.dragValue)
                                srow.dragValue = -1;
                        }
                        // The table reads this row's setting too (see
                        // `_valueShown`), so what the user is choosing has to
                        // reach it.
                        onDragValueChanged: {
                            if (srow.dragValue >= 0) {
                                root._dragKey = srow.name;
                                root._dragVal = srow.dragValue;
                            } else if (root._dragKey === srow.name) {
                                root._dragKey = "";
                                root._dragVal = -1;
                            }
                        }

                        // The slider owns its `value` while dragged (it assigns
                        // it, which severs any binding), so the row drives it
                        // imperatively both ways -- the TabSelector idiom.
                        readonly property real norm: (srow.value - srow.from) / Math.max(1, srow.to - srow.from)
                        onNormChanged: slider.value = srow.norm
                        Component.onCompleted: slider.value = srow.norm

                        function quantise(n) {
                            const raw = srow.from + Math.max(0, Math.min(1, n)) * (srow.to - srow.from);
                            const q = srow.from + Math.round((raw - srow.from) / srow.step) * srow.step;
                            return Math.max(srow.from, Math.min(srow.to, q));
                        }
                        function flush() {
                            settle.stop();
                            if (srow.dragValue >= 0 && srow.dragValue !== srow.hostValue) {
                                root.settingChanged(srow.name, srow.dragValue);
                                root._beginFlight();
                            }
                        }
                        Timer {
                            id: settle
                            interval: root.settleMs
                            onTriggered: srow.flush()
                        }

                        // The title row: the setting's name at the groove's
                        // start, its figure right-aligned against the groove's
                        // end in a slot as wide as the widest value it can take,
                        // and between them the mark saying whose value this is.
                        Item {
                            id: titleRow
                            x: column.inset
                            width: column.lineWidth
                            height: root.titlePixelSize + root.textGap * 2
                            Text {
                                id: titleText
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: srow.modelData.label
                                color: root.primaryText
                                font.family: root.fontFamily
                                font.pixelSize: root.titlePixelSize
                                HoverHandler { id: titleHover }
                            }
                            // Beside the PANEL, never over the sliders: the tip is
                            // anchored to the title but pushed out by the panel's
                            // padding, so it clears the panel's edge (see header).
                            HoverTip {
                                show: titleHover.hovered
                                delayMs: root.tipDelayMs
                                side: "right"
                                gap: root._tipGap
                                anchorItem: titleRow
                                overlayItem: root.overlayItem
                                text: srow.modelData.tip
                                fontFamily: root.fontFamily
                                fontPixelSize: root.figurePixelSize
                                surfaceColor: root.tipSurfaceColor
                                bevelColor: root.bevelColor
                                shadowColor: root.shadowColor
                                textColor: root.primaryText
                            }
                            Text {
                                id: figureText
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.ceil(figureMetrics.advanceWidth(root._format(srow.modelData, srow.to)))
                                horizontalAlignment: Text.AlignRight
                                text: root._format(srow.modelData, srow.value)
                                color: root.mutedText
                                font.family: root.fontFamily
                                font.pixelSize: root.figurePixelSize
                            }
                            // WHOSE VALUE THIS IS, in a slot of its own left of
                            // the figure so the figure's right edge stays on the
                            // groove's end whichever state it is in. `*` is the
                            // control panel's own mark for a value that differs
                            // from the file default; a value that does not differ
                            // wears nothing.
                            Text {
                                id: markText
                                anchors.right: figureText.left
                                anchors.rightMargin: root.textGap * 2
                                anchors.verticalCenter: parent.verticalCenter
                                // A SLOT, like every figure here: the mark is
                                // there or it is not, and neither state may move
                                // the figure beside it.
                                width: root._markSlot
                                horizontalAlignment: Text.AlignRight
                                text: srow.own ? root._ownMark : ""
                                color: root.faintText
                                font.family: root.fontFamily
                                font.pixelSize: root.figurePixelSize
                                HoverHandler { id: markHover }
                            }
                            // Anchored to the ROW, not to the mark: a tip beside
                            // a mark in the middle of the row would open over the
                            // figure next to it.
                            HoverTip {
                                // Only where there IS a mark: an empty slot is
                                // the absence of a fact, not a fact with a tip.
                                show: markHover.hovered && srow.own
                                delayMs: root.tipDelayMs
                                side: "right"
                                gap: root._tipGap
                                anchorItem: titleRow
                                overlayItem: root.overlayItem
                                text: "this file's own setting"
                                fontFamily: root.fontFamily
                                fontPixelSize: root.figurePixelSize
                                surfaceColor: root.tipSurfaceColor
                                bevelColor: root.bevelColor
                                shadowColor: root.shadowColor
                                textColor: root.primaryText
                            }
                        }

                        Item {
                            id: sliderRow
                            width: srow.width
                            // Dropped into its own title by the slack the slider
                            // carries above its ink, so the title reads as this
                            // slider's and not as the one above it.
                            y: titleRow.height - root.titleSliderOverlap
                            // AS TALL AS THE SLIDER SAYS IT NEEDS TO BE: the ball
                            // bends to a bounded soft limit and `neededCross` is
                            // that extent, so nothing is ever cut off at the
                            // panel's floor.
                            height: Math.round(slider.neededCross)

                            GrooveSlider {
                                id: slider
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                height: Math.round(slider.neededCross)
                                orientation: "horizontal"
                                sizeScale: root.sliderScale
                                ballSize: root.sliderBall
                                edgePadding: root.sliderEdgePadding
                                // No mute track, no snap, no thickness swap: a
                                // setting has nothing to mute.
                                muteEnabled: false
                                allowBoost: false
                                sparksEnabled: false
                                maxValue: 1

                                surfaceColor: root.fieldColor
                                grooveColor: root.grooveColor
                                grooveBevelColor: root.bevelColor
                                grooveShadowColor: root.shadowColor
                                ballColor: root.accent
                                ballShadowColor: root.ballShadowColor

                                onUserChangedValue: v => {
                                    const q = srow.quantise(v);
                                    if (q !== srow.dragValue)
                                        srow.dragValue = q;
                                    settle.restart();
                                }

                            }

                            // ONE COLUMN EDGE: the first row publishes where the
                            // groove starts and every other line reads it.
                            Binding {
                                target: root
                                property: "_grooveInset"
                                value: slider.grooveStart
                                when: srow.index === 0
                            }

                            // Release, observed passively IN FRONT of the slider
                            // (a passive grab takes nothing from the exclusive
                            // one the slider's MouseArea takes next): the moment
                            // the button goes up, whatever was chosen is sent.
                            // MEASURED: a PointHandler on the slider itself sits
                            // behind that MouseArea in delivery order and never
                            // sees the press once the area has accepted it.
                            Item {
                                anchors.fill: slider
                                z: 1
                                PointHandler {
                                    onActiveChanged: if (!active) srow.flush()
                                }
                            }
                        }
                    }
                }

                Divider {}

                // The facts: the metrics table, the loader's reasons in a tip
                // BESIDE the panel -- above them is over the sliders.
                Column {
                    id: facts
                    x: column.inset
                    width: column.lineWidth
                    // A table's rows touch: the row itself carries the leading.
                    spacing: 0

                    Repeater {
                        model: root._metrics

                        Item {
                            id: mrow
                            required property var modelData
                            width: facts.width
                            // A table row's leading is the TITLE row's leading:
                            // the same air above and below a line of text
                            // everywhere in the panel, so the space under the
                            // last figure equals the space over the first title.
                            height: root.figurePixelSize + root.textGap * 2

                            Text {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: mrow.modelData.label
                                color: root.mutedText
                                font.family: root.fontFamily
                                font.pixelSize: root.figurePixelSize
                            }
                            // The figure, right-aligned in a slot as wide as the
                            // widest value this metric can hold -- never as wide
                            // as the value it holds now.
                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.ceil(figureMetrics.advanceWidth(mrow.modelData.slot))
                                horizontalAlignment: Text.AlignRight
                                text: mrow.modelData.value
                                color: root.primaryText
                                font.family: root.fontFamily
                                font.pixelSize: root.figurePixelSize
                            }

                            HoverHandler { id: mrowHover }
                            HoverTip {
                                show: mrowHover.hovered
                                delayMs: root.tipDelayMs
                                side: "right"
                                gap: root._tipGap
                                anchorItem: mrow
                                overlayItem: root.overlayItem
                                text: mrow.modelData.tip
                                fontFamily: root.fontFamily
                                fontPixelSize: root.figurePixelSize
                                surfaceColor: root.tipSurfaceColor
                                bevelColor: root.bevelColor
                                shadowColor: root.shadowColor
                                textColor: root.primaryText
                            }
                        }
                    }

                }
            }
        }
    }

    FontMetrics {
        id: figureMetrics
        font.family: root.fontFamily
        font.pixelSize: root.figurePixelSize
    }
    // The override mark's slot: as wide as the mark, so the mark lands on one
    // x whether or not the row is wearing it.
    readonly property string _ownMark: "*"
    readonly property real _markSlot: Math.ceil(figureMetrics.advanceWidth(root._ownMark))
}
