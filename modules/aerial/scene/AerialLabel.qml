pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../../common/components/Mix.js" as Mix
import "../../common/theme"
import "AerialFacts.js" as Facts

// =============================================================================
// AerialLabel.qml -- the AX210's label as LIVE QML, laid on the shield's plane (the card's own frame: the scene puts it under the camera's affine map, which follows the
// card when it tilts; crisp text, a hole in the board where the label is). Units: 1 design px = 1/`kPx` mm of the label, the scene scales it. The text reads along +x.
//
// THREE BANDS (round 3; AerialGeometry LABEL_HEAD / LABEL_BT / LABEL_ZONE, here label-local mm):
//   the HEAD        Intel's name line and the MAIN / AUX marks under the two connectors
//   the BLUETOOTH   the CONNECTED devices (`label.bt`): one = a large row (glyph, name, percent, the parts under it), two = two rows, three or four = a 2 x 2 grid, more = three
//                   and "+n". With none it carries Intel's small print (part numbers, the real MACs, the Data Matrix), faint. A row keeps its identity (its address) while the
//                   zone reorganises: places and sizes ease on ONE clock (`_m`, 260 ms OutCubic), a row that comes or goes only fades (160 ms), words swap at once.
//   the WI-FI       what is docked: the name over the full width (it shrinks to fit, then a MIDDLE cut keeps the telling end), band . channel . standard, dBm . rate, and
//                   "via NL . NL#42" with a small shield while tunnelled; a dashed drop hint when nothing is docked.
//
// THE TUNNEL'S SHIELD (`chrome`, 0 paper .. 1 metal, 1.5 s when `label.vpn` turns: slow and gradual, the user's call): the ground under the print is label_plate.frag --
// paper, or brushed chrome behind a front that wipes the label's length. The chrome is a mirror lying flat: it shows a room laid out on the SCREEN (`axes`), which slides
// when the card tilts (`tilt`), shifts a little against the pointer (`lead`) and carries the cloud's front as it leaves the label (`pulseRadius`): the shader's header has
// the room. The print on chrome is a ROUGHENING: the same live text in a matte tone (`etch`: dark on the bright plate of light mode, a pale frost on the dark plate of dark
// mode) with a hairline lip (the Text's own raised copy, one label px: half a device px on screen; `lipColour`), so the gloss dies under every letter. Colours are mixed by
// the fraction (Mix.js), never eased by themselves.
//
// FOR THE DRAG: `btDeviceAt(lx, ly)` (card-local mm -> the address of the device row there), `btDeviceSpot(address)` (its row's middle, card-local mm), `carriedBt` (that
// row is in the hand: not drawn), `hint` ("wifi" | "bt" | "": that zone shows where a carried thing may be dropped).
// Everything is a function of its properties; the only clocks are the wipe, the rows' places and the presences.
// =============================================================================
Item {
    id: root

    // ---- in ----
    property real kPx: 20                         // px per mm of the label
    property int family: 0                        // 0 Material (a paper sticker, chrome), 1 Blueprint (drafted paper, a drafted plate)
    property color paper: "#F4F5F7"
    property color ink: "#2B2D33"
    property color btHue: "#3D6FE0"               // Bluetooth's hue (the glyphs, the gauges)
    property color accent: "#4480F4"              // the drop glow
    property color lowColour: "#EC0000"           // a gauge at 20 % or under
    property color chromeSky: "#F3F6FB"           // the plate (label_plate.frag names each)
    property color chromeBase: "#D0D6E0"
    property color chromeDeep: "#A9B1BE"
    property color etch: "#3A3E47"                // the print roughened into the chrome
    property color hot: "#FFFFFF"                 // the wipe's front, the rim's light
    property color lipColour: "#FFFFFF"           // the engraving's lip: the plate's light edge under a dark letter, its dark edge under a pale one
    property color pulseColour: "#4480F4"         // the cloud's hue (its front mirrored in the chrome)
    property color plateInk: "#2B2D33"            // Blueprint: the drafted plate's frame
    property bool lip: true                       // the engraving's pale lip (Material)
    property string wfm: "F44EE394DA40"           // the real Wi-Fi MAC (no colons), from the service's facts
    property string bdm: "F44EE394DA44"
    property var label: ({ docked: false, name: "", lineA: "", lineB: "", via: "", hint: true, vpn: false, bt: [] })
    property string fontFamily: "Inter"
    property bool animate: true                   // false: every clock snaps (a gate, a popup that opens)
    property bool dark: false
    property real time: 0                         // the scene's clock, s (the front's ripple while the wipe runs)
    property real live: 1                         // the scene's live layer (0 at rest): the mirrored pulse's strength
    // THE ROOM IN THE CHROME: the plate's x and y axes on screen (px per mm; the scene's label map), the card's tilt (rad), where the pointer leads the room (-1..1 each
    // way) and the cloud's front (its radius on screen in the same px, < 0 while none is in flight; its strength 0..1)
    property vector4d axes: Qt.vector4d(10, 0, 0, 10)
    property real tilt: 0
    property vector2d lead: Qt.vector2d(0, 0)
    property real pulseRadius: -1
    property real pulseStrength: 0
    property real pulseSpan: 1.08                 // the fan's half angle, rad
    property real devPx: 0.1                      // mm per DEVICE px along the text (the plate's antialiasing)
    property vector2d lampSide: Qt.vector2d(-0.5, -0.87)    // the lamp's side in the label's plane
    // the label's size in mm (AerialGeometry LABEL), its corner on the card, and the three bands, x0 y0 x1 y1 in mm from the label's corner
    property real labelW: 20.0
    property real labelH: 20.85
    property real radius: 0.4
    property real originX: 1.0
    property real originY: 4.05
    property var head: [0.2, 0.2, 19.8, 2.65]
    property var btZone: [0.2, 2.85, 19.8, 9.45]
    property var zone: [0.2, 9.85, 19.8, 20.55]
    // ---- the drag ----
    property string carriedBt: ""
    property string hint: ""

    width: root.labelW * root.kPx
    height: root.labelH * root.kPx

    function _t(mm: real): real {
        return mm * root.kPx;
    }
    // ONE margin for every band: the print starts and ends this far from the label's edges
    readonly property real padX: 0.9
    function _px(mm: real): int {
        return Math.max(1, Math.round(mm * root.kPx));
    }

    // ---- the tunnel's shield: one clock ----
    property real chrome: 0
    property bool _built: false
    readonly property bool _vpn: !!root.label && root.label.vpn === true
    on_VpnChanged: root._aimChrome()
    function _aimChrome(): void {
        const to = root._vpn ? 1 : 0;
        if (!root.animate || !root._built) {
            chromeAnim.stop();
            root.chrome = to;
            return;
        }
        if (root.chrome === to && !chromeAnim.running)
            return;
        chromeAnim.to = to;
        chromeAnim.restart();
    }
    NumberAnimation {
        id: chromeAnim
        target: root
        property: "chrome"
        duration: 1500
        easing.type: Easing.InOutSine
        // (a theme crossfade is a still picture of the frame before: the wipe waits for it)
        paused: chromeAnim.running && Theme.crossfading
    }
    readonly property bool wiping: chromeAnim.running

    // the print's colours: ink on paper, the matte roughening on chrome
    readonly property color inkNow: Mix.c(root.ink, root.etch, root.chrome)
    readonly property color btInk: Mix.c(Mix.c(root.btHue, root.ink, 0.22), root.etch, root.chrome * 0.8)
    readonly property bool _lipOn: root.lip && root.chrome > 0.01
    readonly property color _lipColour: Qt.rgba(root.lipColour.r, root.lipColour.g, root.lipColour.b, 0.72 * root.chrome * root.chrome)

    // one printed text
    component Ink: Text {
        color: root.inkNow
        style: root._lipOn ? Text.Raised : Text.Normal
        styleColor: root._lipColour
        font.family: root.fontFamily
        renderType: Text.QtRendering
    }
    // one printed line of the label's own frame: x, top y (mm), size (mm)
    component Line: Ink {
        required property real mx
        required property real my
        required property real msize
        x: root._t(mx)
        y: root._t(my)
        font.pixelSize: root._px(msize)
    }

    // ---- the ground: paper, or the plate behind the wipe ----
    ShaderEffect {
        anchors.fill: parent
        vertexShader: "../shaders/label_plate.vert.qsb"
        fragmentShader: "../shaders/label_plate.frag.qsb"
        property vector4d plate: Qt.vector4d(root.labelW, root.labelH, root.radius, root.family)
        // (the clock reaches the plate only while the front is on it; the room's inputs only while there is metal to show it: paper is still, and a uniform that
        // changes redraws the frame)
        readonly property bool metal: root.chrome > 0
        property vector4d wipe: Qt.vector4d(root.chrome, root.wiping ? root.time : 0, root.dark ? 1 : 0, root.devPx)
        property vector4d lamp: Qt.vector4d(root.lampSide.x, root.lampSide.y, root.live, 1)
        property vector4d axes: root.axes
        property vector4d env: metal ? Qt.vector4d(root.tilt, root.lead.x, root.lead.y, 0) : Qt.vector4d(0, 0, 0, 0)
        property vector4d pulse: metal ? Qt.vector4d(root.pulseRadius, root.pulseStrength, root.pulseSpan, 0) : Qt.vector4d(-1, 0, 0, 0)
        property color colPulse: root.pulseColour
        property color colPaper: root.paper
        property color colSky: root.chromeSky
        property color colBase: root.chromeBase
        property color colDeep: root.chromeDeep
        property color colInk: root.plateInk
        property color colHot: root.hot
    }

    // the two rules between the bands (a hairline; an engraved line on chrome)
    Repeater {
        model: [(root.head[3] + root.btZone[1]) / 2, (root.btZone[3] + root.zone[1]) / 2]
        delegate: Rectangle {
            required property real modelData
            x: root._t(root.padX)
            y: Math.round(root._t(modelData) - height / 2)
            width: root._t(root.labelW - 2 * root.padX)
            height: Math.max(1, Math.round(root._t(0.06)))
            color: root.inkNow
            opacity: 0.24 + 0.2 * root.chrome
        }
    }

    // =============================================================================
    // the head: Intel's name, MAIN (a solid triangle, the LEFT connector's) and AUX (an outline one)
    // =============================================================================
    Item {
        id: headBox
        x: root._t(root.head[0])
        y: root._t(root.head[1])
        width: root._t(root.head[2] - root.head[0])
        height: root._t(root.head[3] - root.head[1])
        Line { mx: root.padX - root.head[0]; my: 0.12; msize: 1.05; text: "Intel® Wi-Fi 6E AX210"; font.bold: true }
        Line { mx: root.padX - root.head[0]; my: 1.52; msize: 0.72; text: "Model: AX210NGW"; opacity: 0.7 }
        // the marks stand under the two connectors (card-local x 15.35 and 19.85; AUX's is pulled in from the label's edge)
        readonly property real mainX: 15.35 - root.originX - root.head[0]
        readonly property real auxX: 18.55 - root.originX - root.head[0]
        Shape {
            preferredRendererType: Shape.CurveRenderer
            ShapePath {
                fillColor: root.inkNow
                strokeColor: "transparent"
                PathMove { x: root._t(headBox.mainX); y: root._t(0.22) }
                PathLine { x: root._t(headBox.mainX + 0.78); y: root._t(1.08) }
                PathLine { x: root._t(headBox.mainX - 0.78); y: root._t(1.08) }
                PathLine { x: root._t(headBox.mainX); y: root._t(0.22) }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.inkNow
                strokeWidth: Math.max(1, root._t(0.11))
                joinStyle: ShapePath.MiterJoin
                PathMove { x: root._t(headBox.auxX); y: root._t(0.3) }
                PathLine { x: root._t(headBox.auxX + 0.7); y: root._t(1.03) }
                PathLine { x: root._t(headBox.auxX - 0.7); y: root._t(1.03) }
                PathLine { x: root._t(headBox.auxX); y: root._t(0.3) }
            }
        }
        Ink {
            x: Math.round(root._t(headBox.mainX) - width / 2)
            y: root._t(1.32)
            text: "MAIN"
            font.bold: true
            font.pixelSize: root._px(0.66)
        }
        Ink {
            x: Math.round(root._t(headBox.auxX) - width / 2)
            y: root._t(1.32)
            text: "AUX"
            font.bold: true
            font.pixelSize: root._px(0.66)
        }
    }

    // =============================================================================
    // the Bluetooth zone
    // =============================================================================
    readonly property var _devs: root.label && root.label.bt ? root.label.bt : []
    readonly property string _devKey: JSON.stringify(root._devs)
    on_DevKeyChanged: root._sync()
    // some / none, eased: Intel's small print gives way to the devices
    property real devT: 0
    readonly property bool _some: root._devs.length > 0
    on_SomeChanged: {
        if (!root.animate || !root._built) {
            devAnim.stop();
            root.devT = root._some ? 1 : 0;
        } else {
            devAnim.to = root._some ? 1 : 0;
            devAnim.restart();
        }
    }
    NumberAnimation { id: devAnim; target: root; property: "devT"; duration: 160 }

    // THE SLOTS (mm in the zone's own frame): { x, y, w, h, mode } per row, by how many cells are shown (devices, and the "+n" cell)
    readonly property real _zw: root.btZone[2] - root.btZone[0]
    readonly property real _zh: root.btZone[3] - root.btZone[1]
    function slotsFor(n: int): var {
        const W = root._zw, H = root._zh, px = root.padX - root.btZone[0];
        if (n <= 0)
            return [];
        if (n === 1)
            return [{ x: px, y: 0.5, w: W - 2 * px, h: H - 1.0, mode: 0 }];
        const gap = 0.3, rh = (H - 0.9 - gap) / 2, y0 = 0.45, y1 = 0.45 + rh + gap;
        if (n === 2)
            return [{ x: px, y: y0, w: W - 2 * px, h: rh, mode: 1 }, { x: px, y: y1, w: W - 2 * px, h: rh, mode: 1 }];
        const cg = 0.5, cw = (W - 2 * px - cg) / 2, out = [];
        for (let i = 0; i < Math.min(4, n); i++)
            out.push({ x: px + (i % 2) * (cw + cg), y: i < 2 ? y0 : y1, w: cw, h: rh, mode: 2 });
        return out;
    }
    // what the zone shows: every device up to four; more, the first three and a "+n" cell (key "+")
    function _cells(): var {
        const d = root._devs;
        if (d.length <= 4)
            return d.map(x => ({ key: x.address, d: x }));
        const out = d.slice(0, 3).map(x => ({ key: x.address, d: x }));
        out.push({ key: "+", d: { plus: d.length - 3 } });
        return out;
    }
    // the three layouts' numbers (mm in a row's frame): one device, two rows, the grid
    readonly property var rowGlyph: [3.3, 2.0, 1.75]
    readonly property var rowNameX: [4.5, 3.0, 2.3]
    readonly property var rowNameMax: [2.0, 1.5, 1.2]
    readonly property var rowNameMin: [1.4, 1.1, 0.98]
    readonly property var rowPctSlot: [4.4, 3.3, 0]
    readonly property var rowPct: [1.7, 1.3, 0]
    readonly property real rowBar: 2.6                 // two rows: the gauge before the percent
    function rowNameAvail(mode: int, w: real, gauged: bool): real {
        if (mode === 2)
            return w - root.rowNameX[2];
        return w - root.rowNameX[mode] - (gauged ? root.rowPctSlot[mode] + (mode === 1 ? root.rowBar + 1.2 : 0.7) : 0);
    }
    // ONE name size for every row shown (the smallest any of them needs): two names side by side in two sizes read as two ranks
    FontMetrics {
        id: rowFm
        font.family: root.fontFamily
        font.bold: true
        font.pixelSize: 100
    }
    function _rowNameMm(cells: var, slots: var): real {
        const fam = rowFm.font.family;              // (the metrics' own font: the dependency and the guarantee)
        let mm = 1e9;
        cells.forEach((c, i) => {
            if (c.key === "+" || fam === undefined)
                return;
            const s = slots[i], adv = Math.max(1, rowFm.advanceWidth(c.d.name));
            const fit = root.rowNameAvail(s.mode, s.w, c.d.battery >= 0) * 0.985 / adv * 100;
            mm = Math.min(mm, Math.max(root.rowNameMin[s.mode], Math.min(root.rowNameMax[s.mode], fit)));
        });
        return mm > 1e8 ? 1 : mm;
    }
    // the rows' ONE clock
    property real _m: 1
    property real rowNameMm: 1.5
    NumberAnimation { id: placeAnim; target: root; property: "_m"; from: 0; to: 1; duration: 260; easing.type: Easing.OutCubic }
    // THE ROWS ARRIVE IN ANY ORDER, OVER SEVERAL TURNS: the engine incubates a popup's content asynchronously, and a Repeater's delegates are then nested incubators that need not
    // finish in index order nor before this label's own completion (the last row came first on the desktop, and a placement that read the others threw -- in
    // Component.onCompleted, so `_built` never turned true and every motion of the label snapped for its whole life: round 4, "the transition never appears"). So a placement
    // waits until EVERY row is there, each arrival asks again, and the first placement that runs snaps whenever it comes (`_placed`).
    property bool _placed: false
    function _sync(): void {
        const rows = [];
        for (let i = 0; i < pool.count; i++) {
            const r = pool.itemAt(i);
            if (!r)
                return;                             // (a row is not built yet: its arrival calls again)
            rows.push(r);
        }
        if (rows.length === 0)
            return;
        const cells = root._cells(), slots = root.slotsFor(cells.length), want = {};
        cells.forEach((c, i) => want[c.key] = { d: c.d, s: slots[i] });
        root.rowNameMm = root._rowNameMm(cells, slots);
        // HOLD first: where every row is drawn right now
        const held = rows.map(r => ({ x: r.cx, y: r.cy, w: r.tw, h: r.ch }));
        placeAnim.stop();
        const snap = !root.animate || !root._built || !root._placed;
        root._placed = true;
        let moved = false;
        const used = {};
        rows.forEach((r, i) => {
            if (r.key === "")
                return;
            const w = want[r.key];
            if (w && !used[r.key]) {
                used[r.key] = true;
                moved = moved || Math.abs(held[i].x - w.s.x) + Math.abs(held[i].y - w.s.y) + Math.abs(held[i].h - w.s.h) > 0.01;
                r.place(held[i], w.s, w.d);
                r.come(snap);
            } else {
                r.place(held[i], { x: held[i].x, y: held[i].y, w: held[i].w, h: held[i].h, mode: r.mode }, r.d);
                r.go(snap);                         // it goes: a fade at its place
            }
        });
        cells.forEach(c => {
            if (used[c.key])
                return;
            // a row for a newcomer: a free one, else the one that has faded furthest
            let best = null;
            rows.forEach(r => {
                if (r.wanted)
                    return;
                if (!best || (r.key === "" && best.key !== "") || (r.key !== "" && best.key !== "" && r.pres < best.pres))
                    best = r;
            });
            if (!best)
                return;
            const s = want[c.key].s;
            best.fresh();
            best.key = c.key;
            best.place(s, s, c.d);
            best.come(snap);
            used[c.key] = true;
        });
        if (snap || !moved) {
            root._m = 1;
        } else {
            root._m = 0;
            placeAnim.restart();
        }
    }

    Item {
        id: btBox
        x: root._t(root.btZone[0])
        y: root._t(root.btZone[1])
        width: root._t(root._zw)
        height: root._t(root._zh)

        // ---- Intel's small print (no device connected) ----
        Item {
            anchors.fill: parent
            opacity: 0.5 * (1 - root.devT)
            visible: opacity > 0.005
            Line { mx: root.padX - root.btZone[0]; my: 0.42; msize: 0.82; text: "T P/N: G86C00080410" }
            Line { mx: root.padX - root.btZone[0]; my: 1.56; msize: 0.82; text: "SPS: M27269-005 0A" }
            Line { mx: root.padX - root.btZone[0]; my: 2.70; msize: 0.82; text: "WFM: " + root.wfm }
            Line { mx: root.padX - root.btZone[0]; my: 3.84; msize: 0.82; text: "BDM: " + root.bdm }
            Line { mx: root.padX - root.btZone[0]; my: 4.98; msize: 0.82; text: "FRU P/N: 5W10V25784" }
            // the small Data Matrix (a fixed pattern: finder L on two edges, clock dashes on the others, the rest by a fixed hash of the MACs)
            Shape {
                id: dm
                x: root._t(root._zw - (root.padX - root.btZone[0]) - 4.0)
                y: root._t(0.55)
                width: root._t(4.0)
                height: root._t(4.0)
                readonly property int n: 14
                readonly property real m: root._t(4.0) / dm.n
                readonly property string bits: {
                    const seed = root.wfm + root.bdm;
                    let h = 17;
                    for (let i = 0; i < seed.length; i++)
                        h = (h * 31 + seed.charCodeAt(i)) % 65521;
                    let d = "";
                    for (let r = 0; r < dm.n; r++)
                        for (let c = 0; c < dm.n; c++) {
                            let on;
                            if (c === 0 || r === dm.n - 1)
                                on = true;                                   // the finder L
                            else if (r === 0)
                                on = c % 2 === 1;                            // the clock track
                            else if (c === dm.n - 1)
                                on = r % 2 === 0;
                            else {
                                h = (h * 1103 + 12345 + r * 7 + c * 13) % 65521;
                                on = h % 2 === 1;
                            }
                            if (on)
                                d += "M " + (c * dm.m) + " " + (r * dm.m) + " h " + dm.m + " v " + dm.m + " h " + (-dm.m) + " z ";
                        }
                    return d;
                }
                ShapePath {
                    fillColor: root.inkNow
                    strokeColor: "transparent"
                    PathSvg { path: dm.bits }
                }
            }
            Ink {
                x: root._t(root._zw - (root.padX - root.btZone[0])) - width
                y: root._t(5.0)
                text: "FCC ID: PD9AX210NG"
                font.pixelSize: root._px(0.62)
            }
        }

        // ---- the connected devices: a pool of rows, each keyed by its device's address ----
        Repeater {
            id: pool
            model: 6
            onItemAdded: (index, item) => root._sync()
            delegate: Item {
                id: row
                required property int index
                property string key: ""
                property var d: null
                property int mode: 0
                // from / to (mm, the zone's frame); the drawn place is between them on the zone's one clock
                property real fx: 0
                property real fy: 0
                property real fh: 1
                property real tx: 0
                property real ty: 0
                property real tw: 1
                property real th: 1
                readonly property real cx: row.fx + (row.tx - row.fx) * root._m
                readonly property real cy: row.fy + (row.ty - row.fy) * root._m
                readonly property real ch: row.fh + (row.th - row.fh) * root._m
                // its presence: it only fades (160 ms), on its own small clock; `wanted` is what the zone asked last
                property bool wanted: false
                property real pres: 0
                NumberAnimation { id: presAnim; target: row; property: "pres"; duration: 160 }
                function _aim(to: real, snap: bool): void {
                    if (snap) {
                        presAnim.stop();
                        row.pres = to;
                    } else if (row.pres !== to || presAnim.running) {
                        presAnim.to = to;
                        presAnim.restart();
                    }
                }
                function come(snap: bool): void {
                    row.wanted = true;
                    row._aim(1, snap);
                }
                function go(snap: bool): void {
                    row.wanted = false;
                    row._aim(0, snap);
                }
                // taken over for a newcomer: unseen, whatever it was showing
                function fresh(): void {
                    presAnim.stop();
                    row.wanted = false;
                    row.pres = 0;
                }
                function place(from: var, to: var, data: var): void {
                    row.fx = from.x;
                    row.fy = from.y;
                    row.fh = from.h;
                    row.tx = to.x;
                    row.ty = to.y;
                    row.tw = to.w;
                    row.th = to.h;
                    row.mode = to.mode;
                    row.d = data;
                }
                onPresChanged: if (row.pres === 0 && !row.wanted) row.key = ""

                x: root._t(row.cx)
                y: root._t(row.cy)
                width: root._t(row.tw)
                height: root._t(row.th)
                opacity: row.key === root.carriedBt && row.key !== "" ? 0 : row.pres
                visible: row.key !== "" && row.opacity > 0.005
                // the new layout at once, scaled from the size the row had (text never re-lays out through a morph)
                scale: row.th > 0 ? row.ch / row.th : 1
                transformOrigin: Item.TopLeft

                readonly property bool plus: !!row.d && row.d.plus !== undefined
                readonly property string name: row.d && !row.plus ? row.d.name : ""
                readonly property real battery: row.d && !row.plus && row.d.battery !== undefined ? row.d.battery : -1
                readonly property bool gauged: row.battery >= 0
                readonly property color gaugeInk: row.battery <= 20 ? Mix.c(root.lowColour, root.etch, root.chrome * 0.6) : root.btInk
                readonly property real glyphMm: root.rowGlyph[row.mode]
                readonly property real nameX: root.rowNameX[row.mode]
                readonly property real pctSlot: root.rowPctSlot[row.mode]
                readonly property real pctMm: root.rowPct[row.mode]
                readonly property real nameAvail: root.rowNameAvail(row.mode, row.tw, row.gauged)
                readonly property int namePx: Math.max(1, Math.floor(root._t(root.rowNameMm)))
                TextMetrics {
                    id: cut
                    font.family: root.fontFamily
                    font.bold: true
                    font.pixelSize: row.namePx
                    text: row.name
                    elide: Text.ElideMiddle
                    elideWidth: root._t(row.nameAvail)
                }

                // the kind's glyph
                Text {
                    visible: !row.plus
                    x: 0
                    y: 0
                    width: root._t(row.nameX - (row.mode === 0 ? 1.0 : 0.55))
                    height: row.height
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: row.d && !row.plus ? Facts.glyphOf(row.d.kind) : ""
                    color: root.btInk
                    style: root._lipOn ? Text.Raised : Text.Normal
                    styleColor: root._lipColour
                    font.family: "Symbols Nerd Font"
                    font.pixelSize: root._px(row.glyphMm)
                    renderType: Text.QtRendering
                }
                // the name
                Ink {
                    visible: !row.plus
                    x: root._t(row.nameX)
                    y: row.mode === 0 ? Math.round(root._t(1.55) - height / 2) : (row.mode === 1 ? Math.round((row.height - height) / 2) : Math.round(root._t(0.95) - height / 2))
                    text: cut.elidedText
                    font.bold: true
                    font.pixelSize: row.namePx
                }
                // one device alone: what it is, or its parts
                Ink {
                    visible: !row.plus && row.mode === 0
                    x: root._t(row.nameX)
                    y: Math.round(root._t(3.5) - height / 2)
                    width: root._t(row.tw - row.nameX)
                    elide: Text.ElideRight
                    text: row.d && !row.plus ? Facts.deviceSub(row.d) : ""
                    opacity: 0.72
                    font.pixelSize: root._px(1.05)
                }
                // the percent, right-aligned in a slot that never moves
                Ink {
                    visible: row.gauged && row.mode < 2
                    x: root._t(row.tw - row.pctSlot)
                    width: root._t(row.pctSlot)
                    y: row.mode === 0 ? Math.round(root._t(1.55) - height / 2) : Math.round((row.height - height) / 2)
                    horizontalAlignment: Text.AlignRight
                    text: Math.round(Math.max(0, Math.min(100, row.battery))) + "%"
                    font.bold: true
                    font.pixelSize: root._px(Math.max(0.5, row.pctMm))
                }
                // the gauge: a bar under the name and its sub-line (one device; the grid) or before the percent (two rows)
                Rectangle {
                    id: gauge
                    visible: row.gauged && !row.plus
                    readonly property real gw: row.mode === 1 ? root.rowBar : row.tw - row.nameX
                    readonly property real gh: row.mode === 0 ? 0.5 : (row.mode === 1 ? 0.5 : 0.32)
                    x: root._t(row.mode === 1 ? row.tw - row.pctSlot - 0.6 - root.rowBar : row.nameX)
                    y: row.mode === 0 ? Math.round(root._t(4.85)) : (row.mode === 1 ? Math.round((row.height - height) / 2) : Math.round(root._t(2.0)))
                    width: root._t(gauge.gw)
                    height: Math.max(2, Math.round(root._t(gauge.gh)))
                    radius: height / 2
                    color: Qt.rgba(root.inkNow.r, root.inkNow.g, root.inkNow.b, 0.16 + 0.1 * root.chrome)
                    Rectangle {
                        width: Math.max(parent.height, Math.round(parent.width * Math.max(0, Math.min(100, row.battery)) / 100))
                        height: parent.height
                        radius: height / 2
                        color: row.gaugeInk
                    }
                }
                // the "+n" cell
                Row {
                    visible: row.plus
                    x: root._t(0.5)
                    height: row.height
                    spacing: root._t(0.45)
                    Ink {
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.plus ? "+" + row.d.plus : ""
                        font.bold: true
                        font.pixelSize: root._px(1.6)
                        opacity: 0.8
                    }
                    Ink {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "more"
                        font.pixelSize: root._px(1.02)
                        opacity: 0.6
                    }
                }
            }
        }

        // a device is in the hand: where it may be dropped
        Rectangle {
            anchors.fill: parent
            anchors.margins: root._t(0.2)
            radius: root._t(0.55)
            color: root.accent
            opacity: 0.12 * btHint.t
            visible: btHint.t > 0.005
        }
        DropFrame {
            id: btHint
            on: root.hint === "bt"
            rest: 0
        }
    }

    // =============================================================================
    // the Wi-Fi zone
    // =============================================================================
    // THE NAME takes the zone's full width: the type shrinks to fit (3.0 mm down to 1.5), then a MIDDLE cut keeps the end ("homenet-...5Ghz": the distinguishing suffix always
    // shows). Both are measured with TextMetrics (never a drawn Text's width): the advance of the whole name at 100 px scales to the size that fits, the elided text at that size is the cut's.
    readonly property real _wPad: root.padX - root.zone[0]
    readonly property real nameAvail: (root.zone[2] - root.zone[0] - 2 * root._wPad) * root.kPx * 0.985
    readonly property int namePx: Math.max(1, Math.floor(Math.max(root._t(1.5), Math.min(root._t(3.0), root.nameAvail / Math.max(nameRef.advanceWidth, 1) * 100))))
    TextMetrics {
        id: nameRef
        font.family: root.fontFamily
        font.bold: true
        font.pixelSize: 100
        text: root.label.name
    }
    TextMetrics {
        id: nameCut
        font.family: root.fontFamily
        font.bold: true
        font.pixelSize: root.namePx
        text: root.label.name
        elide: Text.ElideMiddle
        elideWidth: root.nameAvail
    }
    readonly property alias nameShown: nameCut.elidedText
    // the "via" line's room opens and closes on a fraction (the block stays centred in the zone: space above equals space below)
    property real viaT: 0
    readonly property bool _via: !!root.label && root.label.via !== undefined && root.label.via !== ""
    on_ViaChanged: {
        if (!root.animate || !root._built) {
            viaAnim.stop();
            root.viaT = root._via ? 1 : 0;
        } else {
            // with the tunnel's wipe (the tunnel turned in the same facts: `_vpn` is not where `chrome` stands) the line's room opens on the wipe's own time and curve, so the
            // print moves once, with the front; alone (a network docked under a standing tunnel) it is the label's quick 260 ms
            // (read from the facts themselves: this handler can run before the `_vpn` binding has followed the same change)
            const vpnNow = !!root.label && root.label.vpn === true;
            const withWipe = vpnNow !== (root.chrome > 0.5) || chromeAnim.running;
            viaAnim.duration = withWipe ? chromeAnim.duration : 260;
            viaAnim.easing.type = withWipe ? Easing.InOutSine : Easing.OutCubic;
            viaAnim.to = root._via ? 1 : 0;
            viaAnim.restart();
        }
    }
    NumberAnimation { id: viaAnim; target: root; property: "viaT"; duration: 260; easing.type: Easing.OutCubic }
    property string _viaHeld: ""                // the words stay while the line closes
    readonly property string _idle: root.label && root.label.idle ? String(root.label.idle) : ""
    readonly property string _viaText: root._via ? root.label.via : root._viaHeld
    onLabelChanged: if (root._via) root._viaHeld = root.label.via

    Item {
        id: zoneBox
        x: root._t(root.zone[0])
        y: root._t(root.zone[1])
        width: root._t(root.zone[2] - root.zone[0])
        height: root._t(root.zone[3] - root.zone[1])

        // a network / the hotspot / a country is in the hand: where it may be dropped
        Rectangle {
            anchors.fill: parent
            anchors.margins: root._t(0.2)
            radius: root._t(0.55)
            color: root.accent
            opacity: 0.12 * wifiHint.t
            visible: wifiHint.t > 0.005
        }
        // nothing docked: a dashed drop hint (it turns to the accent while something is carried)
        DropFrame {
            id: wifiHint
            on: root.hint === "wifi"
            rest: root.label.docked || root._idle !== "" ? 0 : 0.55
        }
        Ink {
            anchors.centerIn: parent
            visible: !root.label.docked
            // (airplane, or the Wi-Fi latch off: nothing can be dropped, so it says why instead of asking)
            text: root._idle !== "" ? root._idle : "drop a network here"
            opacity: 0.55
            font.pixelSize: root._px(1.25)
        }

        // what is docked
        Item {
            id: docked
            visible: root.label.docked
            x: root._t(root._wPad)
            width: zoneBox.width - 2 * root._t(root._wPad)
            readonly property real lineH: root._t(1.72)
            readonly property real gap: root._t(0.22)
            readonly property real nameH: nameText.implicitHeight
            readonly property real blockH: docked.nameH + root._t(0.3) + 2 * docked.lineH + docked.gap + root.viaT * (docked.lineH + docked.gap)
            y: Math.round((zoneBox.height - docked.blockH) / 2)
            height: docked.blockH
            Ink {
                id: nameText
                width: parent.width
                text: nameCut.elidedText
                font.bold: true
                font.pixelSize: root.namePx
            }
            Ink {
                y: docked.nameH + root._t(0.3)
                width: parent.width
                text: root.label.lineA
                elide: Text.ElideRight
                font.pixelSize: root._px(1.25)
            }
            Ink {
                y: docked.nameH + root._t(0.3) + docked.lineH + docked.gap
                width: parent.width
                text: root.label.lineB
                elide: Text.ElideRight
                font.pixelSize: root._px(1.25)
            }
            // tunnelled: a small shield and where the traffic leaves
            Item {
                y: docked.nameH + root._t(0.3) + 2 * (docked.lineH + docked.gap)
                width: parent.width
                height: docked.lineH
                opacity: root.viaT
                visible: root.viaT > 0.005
                Text {
                    id: shield
                    anchors.verticalCenter: viaWords.verticalCenter
                    text: String.fromCodePoint(0xF099D)
                    color: root.inkNow
                    style: root._lipOn ? Text.Raised : Text.Normal
                    styleColor: root._lipColour
                    font.family: "Symbols Nerd Font"
                    font.pixelSize: root._px(1.45)
                    renderType: Text.QtRendering
                }
                Ink {
                    id: viaWords
                    x: root._t(1.95)
                    width: parent.width - x
                    text: root._viaText
                    elide: Text.ElideRight
                    font.bold: true
                    font.pixelSize: root._px(1.25)
                }
            }
        }
    }

    // a zone's dashed frame: at `rest` in ink (the Wi-Fi zone with nothing docked), in the accent while a carried thing may be dropped there (`on`); presence only fades
    component DropFrame: Shape {
        id: frame
        property bool on: false
        property real rest: 0
        property real t: 0
        onOnChanged: {
            if (!root.animate || !root._built) {
                frameAnim.stop();
                frame.t = frame.on ? 1 : 0;
            } else {
                frameAnim.to = frame.on ? 1 : 0;
                frameAnim.restart();
            }
        }
        NumberAnimation { id: frameAnim; target: frame; property: "t"; duration: 160 }
        anchors.fill: parent
        opacity: Math.max(frame.rest, frame.t)
        visible: frame.opacity > 0.005
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            fillColor: "transparent"
            strokeColor: Mix.c(root.inkNow, root.accent, frame.t)
            strokeWidth: Math.max(1, root._t(0.11))
            strokeStyle: ShapePath.DashLine
            dashPattern: [4, 3]
            capStyle: ShapePath.FlatCap
            PathRectangle { x: root._t(0.2); y: root._t(0.2); width: frame.width - root._t(0.4); height: frame.height - root._t(0.4); radius: root._t(0.55) }
        }
    }

    // ---- for the drag (card-local mm) ----
    function _rowOf(address: string): var {
        for (let i = 0; i < pool.count; i++) {
            const r = pool.itemAt(i);
            if (r && r.key === address && r.wanted && address !== "+" && address !== "")
                return r;
        }
        return null;
    }
    // the address of the device row at a point, "" for none (the "+n" cell and a row in the hand answer nothing)
    function btDeviceAt(lx: real, ly: real): string {
        const zx = lx - root.originX - root.btZone[0], zy = ly - root.originY - root.btZone[1];
        for (let i = 0; i < pool.count; i++) {
            const r = pool.itemAt(i);
            if (!r || !r.wanted || r.key === "" || r.key === "+" || r.key === root.carriedBt)
                continue;
            if (zx >= r.tx && zx <= r.tx + r.tw && zy >= r.ty && zy <= r.ty + r.th)
                return r.key;
        }
        return "";
    }
    // the middle of a device's row, [lx, ly], or null when it has none
    function btDeviceSpot(address: string): var {
        const r = root._rowOf(address);
        if (!r)
            return null;
        return [root.originX + root.btZone[0] + r.tx + r.tw / 2, root.originY + root.btZone[1] + r.ty + r.th / 2];
    }

    Component.onCompleted: {
        root.chrome = root._vpn ? 1 : 0;
        root.devT = root._some ? 1 : 0;
        root.viaT = root._via ? 1 : 0;
        // (the flag first: nothing after it may keep the label "being built")
        root._built = true;
        root._sync();
    }
}
